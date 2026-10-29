import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/atomic_file.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/relay/locked_outbox_writer.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Whether this is a computer (Zen in the tray): background reception
/// for accounts that are not open runs in the app's own process there.
bool get zenDesktopBackgroundPlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// Seals with [primary]; opens what either sealed. A computer seals an
/// account's node config with the account's background key while
/// "Odbieraj w tle" is on (the tray opens it without the password) and
/// with the master key otherwise; a config sealed the other way (the
/// switch flipped, its reseal cut short) still opens and is sealed again
/// the current way.
final class FallbackKeyedProtector implements KeyedBinaryPayloadProtector {
  FallbackKeyedProtector(this.primary, this.secondary);

  final KeyedBinaryPayloadProtector primary;
  final KeyedBinaryPayloadProtector secondary;

  @override
  bool isSealed(Uint8List payload) => primary.isSealed(payload);

  @override
  Future<Uint8List> seal(Uint8List payload) => primary.seal(payload);

  @override
  Future<Uint8List> unseal(Uint8List payload) async {
    try {
      return await primary.unseal(payload);
    } on Object {
      return secondary.unseal(payload);
    }
  }

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) =>
      primary.sealFor(storageKey, payload);

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async {
    if (primary.isSealed(payload)) {
      return primary.unsealFor(storageKey, payload);
    }
    return secondary.unsealFor(storageKey, payload);
  }
}

/// The node config of the account in [support], opened with [from] and
/// sealed again with [to] (the file and its backup). Nothing when there is
/// no config yet.
Future<void> resealNodeConfig({
  required Directory support,
  required KeyedBinaryPayloadProtector from,
  required KeyedBinaryPayloadProtector to,
}) async {
  final String sep = Platform.pathSeparator;
  final File file = File(
    '${support.path}${sep}runtime${sep}yggdrasil.config.json',
  );
  if (!await file.exists()) {
    return;
  }
  final Uint8List stored = await file.readAsBytes();
  final Uint8List plain = to.isSealed(stored)
      ? await to.unsealFor(kNodeConfigStorageKey, stored)
      : await from.unsealFor(kNodeConfigStorageKey, stored);
  final Uint8List sealed = await to.sealFor(kNodeConfigStorageKey, plain);
  for (final File target in <File>[file, File('${file.path}.bak')]) {
    await writeFileAtomically(target, sealed);
  }
}

/// The background nodes on a computer: while Zen runs (in the tray too),
/// every account with "Odbieraj w tle" on receives with its receive-only
/// node — except the account open and unlocked in the window, which runs
/// its own full node. Locking the window hands the default account over
/// to its background node too.
final class DesktopBackgroundAccounts {
  DesktopBackgroundAccounts();

  static final DesktopBackgroundAccounts instance = DesktopBackgroundAccounts();

  List<BackgroundAccountNode> _nodes = const <BackgroundAccountNode>[];
  Future<void> _work = Future<void>.value();
  String? _signature;

  /// How many background nodes run (tests, diagnostics).
  int get running => _nodes.length;

  /// Runs the background accounts again for [open] being on screen,
  /// [openUnlocked] or not. Waits for anything asked before.
  Future<void> update({
    required ZenAccountScope open,
    required bool openUnlocked,
    required RuntimeSystemNotificationService notices,
    ZenBackgroundAccounts? settings,
    Future<Directory> Function()? instanceDirectory,
    SecureStorageCredentialsStore secrets =
        const SecureStorageCredentialsStore.device(),
    bool force = false,
  }) {
    return _work = _work.then((_) async {
      try {
        final ZenBackgroundAccountList list =
            await (settings ?? ZenBackgroundAccounts()).load();
        final String skip = openUnlocked ? (open.folder ?? '') : '-';
        final String signature = <String>[
          skip,
          '${list.defaultOn}',
          for (final ZenBackgroundAccount a in list.additional) a.folder,
        ].join('|');
        if (!force && signature == _signature) {
          return;
        }
        await _stopAll();
        _signature = signature;
        final Directory instance =
            await (instanceDirectory ?? ZenInstance.instanceDirectory)();
        final List<BackgroundAccountNode> nodes = <BackgroundAccountNode>[];
        if (list.defaultOn && skip != '') {
          final BackgroundAccountNode? own = await BackgroundAccountNode.openAt(
            support: instance,
            credentials: secrets.forAccount(null),
            notices: notices,
          );
          if (own != null) {
            nodes.add(own);
          }
        }
        nodes.addAll(
          await BackgroundAccountNode.openAll(
            list,
            accounts: Directory(
              '${instance.path}${Platform.pathSeparator}'
              '${ZenInstance.accountsFolder}',
            ),
            notices: notices,
            skip: skip,
            secrets: secrets,
          ),
        );
        for (final BackgroundAccountNode node in nodes) {
          try {
            await node.start();
          } on Object catch (error, stackTrace) {
            logZenError('Starting a background node failed', error, stackTrace);
          }
        }
        _nodes = nodes;
      } on Object catch (error, stackTrace) {
        logZenError(
          'Running the background accounts failed',
          error,
          stackTrace,
        );
      }
    });
  }

  /// Stops every background node (before a wipe, at exit).
  Future<void> stop() => _work = _work.then((_) async {
    _signature = null;
    await _stopAll();
  });

  Future<void> _stopAll() async {
    final List<BackgroundAccountNode> nodes = _nodes;
    _nodes = const <BackgroundAccountNode>[];
    for (final BackgroundAccountNode node in nodes) {
      try {
        await node.stop();
      } on Object catch (error, stackTrace) {
        logZenError('Stopping a background node failed', error, stackTrace);
      }
    }
  }
}

final Provider<DesktopBackgroundAccounts> desktopBackgroundAccountsProvider =
    Provider<DesktopBackgroundAccounts>(
      (Ref ref) => DesktopBackgroundAccounts.instance,
    );

/// Whether this account's background parts are kept on a computer; off in
/// tests and on phones (Android has its own bridge).
final Provider<bool> desktopBackgroundBridgeEnabledProvider = Provider<bool>(
  (Ref ref) =>
      zenDesktopBackgroundPlatform &&
      !Platform.environment.containsKey('FLUTTER_TEST'),
);

/// On a computer, for the account open in the window: while it is
/// unlocked with "Odbieraj w tle" on, keeps what its background node needs
/// (the background capability, the door kit, the outbox kit, sealed with
/// its background key in the system's secret store); when it unlocks,
/// takes back what that node kept meanwhile; and tells the tray's
/// background nodes whether this account runs its own node now.
class DesktopBackgroundBridge extends ConsumerStatefulWidget {
  const DesktopBackgroundBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<DesktopBackgroundBridge> createState() =>
      _DesktopBackgroundBridgeState();
}

class _DesktopBackgroundBridgeState
    extends ConsumerState<DesktopBackgroundBridge> {
  AppSecurityService? _security;
  bool? _unlocked;
  bool _backgroundOn = false;
  Timer? _publishTimer;
  Timer? _changed;
  LockedOutboxKitWriter? _outboxWriter;
  String? _publishedSignature;
  String? _doorSignature;
  Future<void> _work = Future<void>.value();

  bool get _enabled => ref.read(desktopBackgroundBridgeEnabledProvider);

  @override
  void initState() {
    super.initState();
    if (!_enabled) {
      return;
    }
    final AppSecurityService security = ref.read(appSecurityServiceProvider)
      ..addListener(_onSecurity);
    _security = security;
    _publishTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _schedule(),
    );
    _onSecurity();
  }

  @override
  void dispose() {
    _security?.removeListener(_onSecurity);
    _publishTimer?.cancel();
    _changed?.cancel();
    _outboxWriter?.detach();
    super.dispose();
  }

  void _onSecurity() {
    final AppSecurityService? security = _security;
    if (security == null || !security.isReady) {
      return;
    }
    final bool unlocked = !isSecurityBlockingUi(security);
    if (unlocked == _unlocked) {
      return;
    }
    _unlocked = unlocked;
    _schedule(lockChanged: true);
  }

  void _schedule({bool lockChanged = false}) {
    if (!mounted) {
      return;
    }
    final ZenAccountScope account = ref.read(zenAccountProvider);
    final RuntimeSystemNotificationService notices = ref.read(
      runtimeSystemNotificationServiceProvider,
    );
    final DesktopBackgroundAccounts runner = ref.read(
      desktopBackgroundAccountsProvider,
    );
    final ZenBackgroundAccounts settings = ref.read(
      zenBackgroundAccountsProvider,
    );
    final bool unlocked = _unlocked ?? false;
    _work = _work.then((_) async {
      if (!mounted) {
        return;
      }
      try {
        _backgroundOn = await settings.isOn(account);
        // Its own node runs here only while unlocked: the background one
        // stops first, so the two never keep the same inbox at once.
        await runner.update(
          open: account,
          openUnlocked: unlocked,
          notices: notices,
          settings: settings,
          force: lockChanged,
        );
        if (unlocked && _backgroundOn && mounted) {
          await _publish();
          await _drain();
        }
      } on Object catch (error, stackTrace) {
        logZenError('Desktop background work failed', error, stackTrace);
      }
    });
  }

  /// Writes the capability, the door kit and the outbox kit (only while
  /// unlocked, the friends read, the core running).
  Future<void> _publish() async {
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final ZenCore core = ref.read(zenCoreProvider);
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    if (isSecurityBlockingUi(security) || !core.isStarted || !hub.isHydrated) {
      return;
    }
    final SocialHubState state = ref.read(socialHubControllerProvider);
    if (state.snapshotUnreadable) {
      return;
    }
    final SupportDirectoryResolver support = ref.read(
      supportDirectoryResolverProvider,
    );
    final AppSecurityCredentialsStore credentials = security.credentialsStore;
    final RelayEngine? relay = ref.read(relayEngineProvider);
    final AccountDirectoryHolder directories = ref.read(
      accountDirectoryHolderProvider,
    );
    final NeighborsService neighbors = ref.read(neighborsServiceProvider);
    final Uint8List? masterKey = await security.currentEncryptionKey();
    if (masterKey == null) {
      return;
    }
    final Uint8List publicKey = await inboxPublicKeyFor(masterKey);
    final BackgroundCapabilityDraft draft = backgroundCapabilityDraftOf(
      state,
      inboxPublicKey: publicKey,
      directory: directories.directory,
      mailboxes: relay?.overview.value.relays ?? const <String>[],
    );
    String sorted(Iterable<String> values) =>
        (values.toList()..sort()).join(',');
    final String signature = <String>[
      base64Url.encode(publicKey),
      sorted(draft.friends),
      sorted(draft.groupMembers),
      sorted(draft.blocked),
      draft.mailboxes.join(','),
    ].join('|');
    if (signature != _publishedSignature) {
      await FileBackgroundVault(
        supportDirectory: support,
        credentials: credentials,
        createKey: true,
      ).publish(draft);
      _publishedSignature = signature;
    }
    if (neighbors.isLoaded) {
      final LockedDoorKit door = LockedDoorKit(
        doorKey: neighbors.doorKey,
        mailboxDoorKeys: neighbors.hostedDoorKeys,
        flatKey: neighbors.doorKey == null ? null : neighbors.profile?.key,
        doorToken: neighbors.doorKey == null ? null : neighbors.door,
        sealSeed: neighbors.doorKey == null ? null : neighbors.sealSeed,
        tempTokens: neighbors.tempDoorTokens,
      );
      final String doorSignature = jsonEncode(door.toJson());
      if (doorSignature != _doorSignature) {
        await lockedDoorKitFile(
          supportDirectory: support,
          credentials: credentials,
          createKey: true,
        ).write(door.toJson());
        _doorSignature = doorSignature;
      }
    }
    if (relay != null && _outboxWriter == null) {
      _outboxWriter = LockedOutboxKitWriter(
        engine: relay,
        write: (Object? json) => lockedOutboxKitFile(
          supportDirectory: support,
          credentials: credentials,
          createKey: true,
        ).write(json),
      )..attach();
    }
  }

  /// Hands what the background node kept to the app, as if it had just
  /// arrived (the node of this account is stopped by then).
  Future<void> _drain() async {
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    final RuntimeSystemNotificationService notices = ref.read(
      runtimeSystemNotificationServiceProvider,
    );
    final FileBackgroundVault vault = FileBackgroundVault(
      supportDirectory: ref.read(supportDirectoryResolverProvider),
      credentials: security.credentialsStore,
    );
    final Uint8List? masterKey = await security.currentEncryptionKey();
    if (masterKey == null ||
        !runtime.snapshot.serviceRunning ||
        !await vault.hasInbox()) {
      return;
    }
    final int delivered = await vault.drain(
      masterKey: masterKey,
      deliver: (Uint8List record) async {
        final SignalTransportFrame? frame = decodeInboxFrame(record);
        if (frame != null) {
          runtime.replayReceived(frame);
        }
      },
    );
    for (final String slot in kLockedReceiverSlots) {
      await notices.dismissSlot(slot);
    }
    logZenMessage('Drained $delivered frame(s) kept in the tray.');
  }

  @override
  Widget build(BuildContext context) {
    if (_enabled) {
      // The friends and the mailboxes change what the node may take in.
      ref.listen<SocialHubState>(socialHubControllerProvider, (
        SocialHubState? previous,
        SocialHubState next,
      ) {
        if (_backgroundOn && (_unlocked ?? false)) {
          _changed?.cancel();
          _changed = Timer(const Duration(seconds: 5), _schedule);
        }
      });
    }
    return widget.child;
  }
}

/// "Odbieraj w tle" turned on or off on a computer for the open, unlocked
/// [account]: the node config is sealed again (with the background key,
/// or back with the master key), and turned off, what the background node
/// used — capability, kits, inbox, background key — goes.
Future<void> applyDesktopBackgroundSetting({
  required ZenAccountScope account,
  required bool on,
  required AppSecurityService security,
  required Directory support,
}) async {
  final KeyedBinaryPayloadProtector master = EncryptedBinaryPayloadProtector(
    security,
  );
  final KeyedBinaryPayloadProtector background = BackgroundKeyProtector(
    security.credentialsStore,
    createKey: true,
  );
  try {
    await resealNodeConfig(
      support: support,
      from: on ? master : background,
      to: on ? background : master,
    );
  } on Object catch (error, stackTrace) {
    logZenError('Sealing the node config again failed', error, stackTrace);
  }
  if (on) {
    return;
  }
  final Directory kept = Directory(
    '${support.path}${Platform.pathSeparator}${FileBackgroundVault.folderName}',
  );
  try {
    if (await kept.exists()) {
      await kept.delete(recursive: true);
    }
  } on FileSystemException catch (error) {
    logZenWarning('Deleting the background files failed: $error');
  }
  await security.credentialsStore.delete(appSecurityBackgroundKeyStorageKey);
}
