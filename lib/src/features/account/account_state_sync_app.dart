import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_media.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/dating/dating_model.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/dating/dating_service.dart';
import 'package:zen/src/features/feed/feed_model.dart' show deletedCommentIds;
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/meet/circle/food_providers.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/plan/plan_providers.dart';
import 'package:zen/src/features/neighbors/household_sync.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Settings that belong to the account and so are the same on all its
/// devices. Everything else stays on each device: the lock (biometrics,
/// delay, a missing app password), the storage limit, media over mobile
/// data, the disguised icon, offering this device as a bridge, the radios
/// (LAN, Wi-Fi Direct, Bluetooth, Multipeer), the first-start steps;
/// background reception, the window and notification permissions are not
/// settings of the account at all.
const Set<String> kSyncedSettingKeys = <String>{
  'autoCleanupDays',
  'themeMode',
  'accentTheme',
  'palette',
  'gifApiKey',
  'gifSearch',
  'notificationPrivacy',
  'inAppSounds',
  'secureScreens',
  'paperBackupDone',
  'legalAcceptedVersion',
  'legalAcceptedAtMillis',
  'groupInviteFrom',
  'showLastOpened',
};

/// Stored states of meetings and circles kept the same on every device.
const List<String> kSyncedMeetKeys = <String>[
  'meet/questions',
  'meet/plans',
  'meet/events',
  'meet/intros',
  'meet/table',
  'meet/food',
  'meet/circles',
];

/// Copies kept on the other devices for a recovery (not taken into use
/// there): the household (one phone runs it, the door; the others take it
/// over by hand, [HouseholdSyncDomain]) and chats with people who are not
/// friends.
const String kHeldHousehold = 'held/household';
const String kHeldStrangers = 'held/chat/strangers';

String _heldKey(String id) => 'account/sync/$id';

Map<String, Object?>? _json(Uint8List? raw) {
  if (raw == null) {
    return null;
  }
  try {
    final Object? json = jsonDecode(utf8.decode(raw));
    return json is Map ? Map<String, Object?>.from(json) : null;
  } on FormatException {
    return null;
  }
}

Uint8List _bytes(Object? json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// A domain whose [changes] come from [poke].
abstract base class _PokedDomain implements AccountSyncDomain {
  final StreamController<void> _changes = StreamController<void>.broadcast();

  void poke() {
    if (!_changes.isClosed) {
      _changes.add(null);
    }
  }

  @override
  Stream<void> get changes => _changes.stream;

  Future<void> close() => _changes.close();
}

/// The account's settings ([kSyncedSettingKeys]).
final class SettingsSyncDomain extends _PokedDomain {
  SettingsSyncDomain(this.ref);

  final Ref ref;

  @override
  String get id => 'settings';

  @override
  Set<String> get wholeKeys => const <String>{};

  @override
  Future<Map<String, Object?>?> read() async {
    // What is saved (the controller starts with defaults until it loads).
    final AppSettings? saved = await ref.read(appSettingsStoreProvider).load();
    if (saved == null) {
      return null;
    }
    return <String, Object?>{
      for (final MapEntry<String, Object> e in saved.toJson().entries)
        if (kSyncedSettingKeys.contains(e.key)) e.key: e.value,
    };
  }

  @override
  Future<void> write(Map<String, Object?> state) async {
    final AppSettings now = ref.read(appSettingsControllerProvider);
    final Map<String, dynamic> merged = <String, dynamic>{
      ...now.toJson(),
      for (final MapEntry<String, Object?> e in state.entries)
        if (kSyncedSettingKeys.contains(e.key)) e.key: e.value,
    };
    await ref
        .read(appSettingsControllerProvider.notifier)
        .restoreAll(AppSettings.fromJson(merged));
  }
}

/// The mailboxes picked by hand: the friends (by the addresses the app
/// knows them by), the same on all the account's devices, so a new phone
/// starts with the person's choice. Each device has mailboxes of its own
/// (its own key, its own announcement), served by the best device of each
/// friend; an automatic choice is each device's own.
final class RelayMailboxSyncDomain extends _PokedDomain {
  RelayMailboxSyncDomain(this.engine);

  final RelayEngine engine;

  @override
  String get id => 'relay';

  /// The friends in their order.
  @override
  Set<String> get wholeKeys => const <String>{'manual'};

  @override
  Future<Map<String, Object?>?> read() async {
    final List<String>? manual = await engine.manualMailboxes();
    return <String, Object?>{'auto': manual == null, 'manual': ?manual};
  }

  @override
  Future<void> write(Map<String, Object?> state) async {
    final Object? manual = state['manual'];
    await engine.setManualRelays(
      state['auto'] == false && manual is List
          ? manual.whereType<String>().toList()
          : null,
    );
  }
}

/// The dating profile and its settings (with the photos).
final class DatingSyncDomain extends _PokedDomain {
  DatingSyncDomain(this.ref, this.disk);

  final Ref ref;
  final LedgerDisk disk;

  @override
  String get id => 'dating';

  /// Photos in their order; the wishes as one.
  @override
  Set<String> get wholeKeys => const <String>{'ph', 'want'};

  @override
  Future<Map<String, Object?>?> read() async {
    final Object? me = _json(await disk.read('dating/state'))?['me'];
    return me is Map ? Map<String, Object?>.from(me) : null;
  }

  @override
  Future<void> write(Map<String, Object?> state) async {
    final DatingService service = ref.read(datingServiceProvider);
    final MyDating from = MyDating.fromJson(state);
    await service.saveMine((MyDating me) {
      restoreDatingProfile(me, from);
      me.photos
        ..clear()
        ..addAll(from.photos);
    });
  }
}

/// A stored state of meetings and circles: written where its service keeps
/// it, which then reads it again.
final class StoredStateSyncDomain extends _PokedDomain {
  StoredStateSyncDomain(this.key, this.disk, this.reload);

  final String key;
  final LedgerDisk disk;
  final Future<void> Function() reload;

  @override
  String get id => key;

  @override
  Set<String> get wholeKeys => const <String>{};

  @override
  Future<Map<String, Object?>?> read() async => _json(await disk.read(key));

  @override
  Future<void> write(Map<String, Object?> state) async {
    await disk.write(key, _bytes(state));
    await reload();
  }
}

/// A copy kept for a recovery: the newest state of the device that uses
/// it, never taken into use on the others.
final class HeldStateSyncDomain extends _PokedDomain {
  HeldStateSyncDomain(this.id, this.disk, this.live);

  @override
  final String id;
  final LedgerDisk disk;

  /// The state on a device that uses it; null on the others.
  final Future<Map<String, Object?>?> Function() live;

  @override
  Set<String> get wholeKeys => const <String>{};

  @override
  Future<Map<String, Object?>?> read() async =>
      await live() ?? _json(await disk.read(_heldKey(id)));

  @override
  Future<void> write(Map<String, Object?> state) async {
    if (await live() == null) {
      await disk.write(_heldKey(id), _bytes(state));
    }
  }
}

/// The held copy [id] on this device, if any.
Future<Map<String, Object?>?> heldAccountState(
  LedgerDisk disk,
  String id,
) async => _json(await disk.read(_heldKey(id)));

/// The profile: name, status, about, visibility, nationalities and the
/// photos (as files sealed for the account's devices).
final class ProfileSyncDomain extends _PokedDomain {
  ProfileSyncDomain(this.ref, this.node, {this.policy});

  final Ref ref;
  final LedgerNode node;
  final AccountMediaPolicy? policy;

  static const String _photosKey = 'account/sync/photos';

  @override
  String get id => 'profile';

  @override
  Set<String> get wholeKeys => const <String>{'avatar', 'cover'};

  /// Vault path → the photo's `{h, r}` (hash, sealed file).
  Future<Map<String, Object?>> _photos() async =>
      _json(await node.disk.read(_photosKey)) ?? <String, Object?>{};

  Future<Map<String, Object?>?> _photo(String? path) async {
    if (path == null || path.trim().isEmpty) {
      return null;
    }
    final Map<String, Object?> known = await _photos();
    final Object? had = known[path];
    if (had is Map) {
      return Map<String, Object?>.from(had);
    }
    final AccountFileReader reader = AccountFileReader(
      MediaVault.current ?? ref.read(mediaVaultProvider),
    );
    final int? size = await reader.size(path);
    if (size == null) {
      return null;
    }
    final AccountArchiveBlob blob = AccountArchiveBlob(
      size,
      (int start, int end) => reader.range(path, start, end),
    );
    final String hash = await accountBlobIdOf(blob);
    final Map<String, dynamic>? sealed = await storeMediaStreamed(
      node.blobs,
      size: size,
      range: blob.range,
      mime: 'image/jpeg',
    );
    if (sealed == null) {
      return null;
    }
    final Map<String, Object?> value = <String, Object?>{
      'h': hash,
      'r': sealed,
    };
    known[path] = value;
    await node.disk.write(_photosKey, _bytes(known));
    return value;
  }

  @override
  Future<Map<String, Object?>?> read() async {
    final UserProfile? saved = await ref.read(userProfileStoreProvider).load();
    if (saved == null) {
      return null;
    }
    final Map<String, dynamic> json = saved.toJson()
      ..remove('avatarPath')
      ..remove('coverPath')
      ..remove('updatedAtMillis');
    final Map<String, Object?>? avatar = await _photo(saved.avatarPath);
    final Map<String, Object?>? cover = await _photo(saved.coverPath);
    return <String, Object?>{...json, 'avatar': ?avatar, 'cover': ?cover};
  }

  /// The photo [value] put into the media vault for the profile, or null
  /// when it is the one here already; throws when it has not come yet.
  Future<String?> _takePhoto(
    Object? value,
    String? currentPath, {
    required bool cover,
  }) async {
    if (value is! Map) {
      return null;
    }
    final Map<String, Object?>? current = await _photo(currentPath);
    if (current != null && current['h'] == value['h']) {
      return null;
    }
    final MediaRef? media = mediaRefFromJson(value['r']);
    if (media == null) {
      return null;
    }
    if (policy != null && !await policy!.mayFetchNow()) {
      throw StateError('The photo waits for Wi-Fi.');
    }
    if (!await node.waitForBlob(
      media.id,
      timeout: const Duration(minutes: 2),
    )) {
      throw StateError('The photo has not come yet.');
    }
    // Straight into the vault: no plain copy outlives this.
    return sealIncomingProfileImage(
      MediaVault.current ?? ref.read(mediaVaultProvider),
      openMediaStreamed(node.blobs, media),
      cover: cover,
    );
  }

  @override
  Future<void> write(Map<String, Object?> state) async {
    final UserProfile now = ref.read(userProfileControllerProvider);
    final UserProfile p = UserProfile.fromJson(
      Map<String, dynamic>.from(state),
    );
    final String? avatar = await _takePhoto(
      state['avatar'],
      now.avatarPath,
      cover: false,
    );
    final String? cover;
    try {
      cover = await _takePhoto(state['cover'], now.coverPath, cover: true);
    } on Object {
      // Tried again later, from the start: no stray copy of the photo.
      if (avatar != null) {
        final MediaVault vault =
            MediaVault.current ?? ref.read(mediaVaultProvider);
        await vault.delete(avatar);
      }
      rethrow;
    }
    await ref
        .read(userProfileControllerProvider.notifier)
        .updateProfile(
          displayName: p.displayName,
          avatarPreset: p.avatarPreset,
          customStatus: p.customStatus,
          bio: p.bio,
          visibility: p.visibility,
          nationalities: p.nationalities,
          avatarPath: avatar,
          coverPath: cover,
          clearAvatarPath: state['avatar'] == null && now.avatarPath != null,
          clearCoverPath: state['cover'] == null && now.coverPath != null,
        );
    final UserProfile after = ref.read(userProfileControllerProvider);
    // The photo sealed again here is the same photo: remembered so.
    final Map<String, Object?> known = await _photos();
    for (final (String? path, Object? value) in <(String?, Object?)>[
      if (avatar != null) (after.avatarPath, state['avatar']),
      if (cover != null) (after.coverPath, state['cover']),
    ]) {
      if (path != null && value is Map) {
        known[path] = Map<String, Object?>.from(value);
      }
    }
    await node.disk.write(_photosKey, _bytes(known));
  }
}

/// The ledger between the account's devices: sealed entries in its `own`
/// space.
final class LedgerAccountSyncChannel implements AccountSyncChannel {
  LedgerAccountSyncChannel(this.node);

  final LedgerNode node;

  @override
  String get device => node.identity.deviceKey.id;

  @override
  bool get hasOtherDevices => node.ownDevices.length > 1;

  @override
  Iterable<Map<String, dynamic>> existing() sync* {
    for (final LogEntry e in node.store.entries(
      accountSpace('own', node.account),
    )) {
      if (e.kind != kAccountStateKind || e.device == device) {
        continue;
      }
      final Map<String, dynamic>? body = node.bodyOf(e);
      if (body != null) {
        yield body;
      }
    }
  }

  @override
  Stream<Map<String, dynamic>> get incoming => node.ownEntries
      .where((LogEntry e) => e.kind == kAccountStateKind)
      .map(node.bodyOf)
      .where((Map<String, dynamic>? b) => b != null)
      .cast<Map<String, dynamic>>();

  @override
  Stream<void> get devicesChanged => node.devicesChanged;

  @override
  Future<bool> publish(Map<String, dynamic> body) async =>
      await node.publishForOwnDevices(kAccountStateKind, body) != null;
}

/// Every file of the account's posts, gallery, films and profile, fetched
/// from its other devices as soon as they may travel (on Wi-Fi, or over
/// mobile data when "Media tylko przez Wi-Fi" is off): each device holds
/// all of it, not only what was opened there.
final class OwnMediaKeeper {
  OwnMediaKeeper({
    required this.node,
    this.policy,
    this.every = const Duration(minutes: 15),
  });

  final LedgerNode node;
  final AccountMediaPolicy? policy;
  final Duration every;

  static const List<String> spaces = <String>['feed', 'profile', 'acts'];

  Timer? _timer;
  StreamSubscription<LogEntry>? _added;
  Timer? _soon;
  bool _stopped = false;

  /// Whether its periodic look runs (tests).
  @visibleForTesting
  bool get ticking => _timer != null;

  Future<void> start() async {
    await node.start();
    if (_stopped) {
      // Stopped while the node was starting: nothing may outlive the stop.
      return;
    }
    _timer = Timer.periodic(every, (_) => unawaited(check()));
    _added = node.store.added.listen((LogEntry e) {
      if (e.account == node.account && e.blobs.isNotEmpty) {
        _soon?.cancel();
        _soon = Timer(const Duration(seconds: 5), () => unawaited(check()));
      }
    });
    unawaited(check());
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _soon?.cancel();
    _soon = null;
    unawaited(_added?.cancel());
    _added = null;
  }

  /// The files of the account's own entries this device does not hold
  /// (not those of comments removed since).
  List<String> missing() {
    final Set<String> removed = deletedCommentIds(
      node.store.entries(accountSpace('acts', node.account)),
    );
    return <String>[
      for (final String kind in spaces)
        for (final LogEntry e in node.store.entries(
          accountSpace(kind, node.account),
        ))
          if (!removed.contains(e.id))
            for (final String id in e.blobs)
              if (!node.blobs.isComplete(id) &&
                  !node.blobs.refused.contains(id))
                id,
    ];
  }

  /// Asks the account's other devices for what is missing, when files may
  /// travel now.
  Future<void> check() async {
    try {
      if (!node.isReady || node.siblingAddresses.isEmpty) {
        return;
      }
      if (policy != null && !await policy!.mayFetchNow()) {
        return;
      }
      final List<String> ids = missing();
      if (ids.isNotEmpty) {
        node.fetchFromOwnDevices(ids.toSet());
      }
    } on Object catch (error) {
      logZenWarning('Pliki konta z innych urządzeń: $error');
    }
  }
}

/// The account's states between its devices, and its files kept on all of
/// them: started with the account's services.
final class AccountDevicesKeeper {
  AccountDevicesKeeper(this.ref);

  final Ref ref;
  AccountStateSync? _sync;
  OwnMediaKeeper? _media;
  HouseholdSyncDomain? _household;
  final List<_PokedDomain> _domains = <_PokedDomain>[];
  final List<void Function()> _unlisten = <void Function()>[];

  /// Stopped with its owner: a start still going on stops at its next
  /// step instead of leaving timers behind.
  bool _stopped = false;

  void _listen(Listenable l, _PokedDomain d) {
    l.addListener(d.poke);
    _unlisten.add(() => l.removeListener(d.poke));
  }

  Future<void> start() async {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (node == null || _sync != null || _stopped) {
      return;
    }
    await node.start();
    if (_stopped) {
      return;
    }
    final LedgerDisk disk = ref.read(ledgerDiskProvider);
    final AccountMediaPolicy policy = ref.read(accountMediaPolicyProvider);
    final SettingsSyncDomain settings = SettingsSyncDomain(ref);
    ref.listen(appSettingsControllerProvider, (_, _) => settings.poke());
    // Dating only where it is on (it starts its service).
    final DatingSyncDomain? dating =
        ref.read(featureFlagsProvider).isEnabled(ZenFeature.dating)
        ? DatingSyncDomain(ref, disk)
        : null;
    if (dating != null) {
      _listen(ref.read(datingServiceProvider), dating);
    }
    final ProfileSyncDomain profile = ProfileSyncDomain(
      ref,
      node,
      policy: policy,
    );
    ref.listen(userProfileControllerProvider, (_, _) => profile.poke());
    // Each service of meetings reads its stored state again with load().
    final Map<String, (Listenable Function(), Future<void> Function())>
    services = <String, (Listenable Function(), Future<void> Function())>{
      'meet/questions': (
        () => ref.read(askServiceProvider),
        () => ref.read(askServiceProvider).load(),
      ),
      'meet/plans': (
        () => ref.read(planServiceProvider),
        () => ref.read(planServiceProvider).load(),
      ),
      'meet/events': (
        () => ref.read(eventServiceProvider),
        () => ref.read(eventServiceProvider).load(),
      ),
      'meet/intros': (
        () => ref.read(introServiceProvider),
        () => ref.read(introServiceProvider).load(),
      ),
      'meet/table': (
        () => ref.read(tableServiceProvider),
        () => ref.read(tableServiceProvider).load(),
      ),
      'meet/food': (
        () => ref.read(foodServiceProvider),
        () => ref.read(foodServiceProvider).load(),
      ),
      'meet/circles': (
        () => ref.read(circleServiceProvider),
        () => ref.read(circleServiceProvider).load(),
      ),
    };
    final List<StoredStateSyncDomain> meet = <StoredStateSyncDomain>[
      for (final String key in kSyncedMeetKeys)
        StoredStateSyncDomain(key, disk, services[key]!.$2),
    ];
    for (final StoredStateSyncDomain d in meet) {
      _listen(services[d.key]!.$1(), d);
    }
    // The hand-picked mailboxes (where store-and-forward runs).
    final RelayEngine? relay = ref.read(relayEngineProvider);
    final RelayMailboxSyncDomain? mailboxes = relay == null
        ? null
        : RelayMailboxSyncDomain(relay);
    if (relay != null && mailboxes != null) {
      _listen(relay.mailboxChoiceRevision, mailboxes);
    }
    final HouseholdSyncDomain household = HouseholdSyncDomain(
      kHeldHousehold,
      ref.read(neighborsServiceProvider),
    );
    _household = household;
    final HeldStateSyncDomain strangers = HeldStateSyncDomain(
      kHeldStrangers,
      disk,
      () async => _json(await disk.read('chat/strangers')),
    );
    _domains.addAll(<_PokedDomain>[
      settings,
      ?dating,
      profile,
      ...meet,
      strangers,
      ?mailboxes,
    ]);
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final AccountStateSync sync = AccountStateSync(
      channel: LedgerAccountSyncChannel(node),
      disk: disk,
      domains: <AccountSyncDomain>[..._domains, household],
      // Locked: the stores do not open (nothing to scan until the unlock).
      mayRead: () async => await security.currentEncryptionKey() != null,
    );
    _sync = sync;
    await sync.start();
    if (_stopped) {
      await sync.stop();
      return;
    }
    final OwnMediaKeeper media = OwnMediaKeeper(node: node, policy: policy);
    _media = media;
    await media.start();
  }

  Future<void> stop() async {
    _stopped = true;
    for (final void Function() u in _unlisten) {
      u();
    }
    _unlisten.clear();
    _media?.stop();
    await _sync?.stop();
    for (final _PokedDomain d in _domains) {
      await d.close();
    }
    await _household?.close();
    _household = null;
  }
}

final Provider<AccountDevicesKeeper> accountDevicesKeeperProvider =
    Provider<AccountDevicesKeeper>((Ref ref) {
      final AccountDevicesKeeper keeper = AccountDevicesKeeper(ref);
      ref.onDispose(() => unawaited(keeper.stop()));
      return keeper;
    });
