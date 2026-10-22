import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/relay/locked_outbox.dart';
import 'package:zen/src/features/relay/locked_outbox_writer.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';

/// An additional account that receives in the background: where its data
/// is and the secret that names its entries in the secret store. Never its
/// ID.
@immutable
final class ZenBackgroundAccount {
  const ZenBackgroundAccount({required this.folder, required this.secret});

  final String folder;
  final Uint8List secret;

  Map<String, String> toJson() => <String, String>{
    'f': folder,
    's': _hex(secret),
  };

  static ZenBackgroundAccount? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? folder = json['f'];
    final Object? secret = json['s'];
    if (folder is! String ||
        !RegExp(r'^[0-9a-f]{32}$').hasMatch(folder) ||
        secret is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(secret)) {
      return null;
    }
    return ZenBackgroundAccount(
      folder: folder,
      secret: Uint8List.fromList(<int>[
        for (int i = 0; i < 64; i += 2)
          int.parse(secret.substring(i, i + 2), radix: 16),
      ]),
    );
  }

  bool matches(ZenAccountScope scope) => scope.folder == folder;
}

/// Who receives in the background ("Odbieraj w tle"), as the background
/// service (or a computer's tray) reads it, with no password at hand.
@immutable
final class ZenBackgroundAccountList {
  const ZenBackgroundAccountList({
    this.defaultOn = true,
    this.additional = const <ZenBackgroundAccount>[],
  });

  /// The default account (on unless turned off).
  final bool defaultOn;

  /// Additional accounts — real ones and the padding among them: an entry
  /// whose folder holds no background capability under its secret simply
  /// opens nothing.
  final List<ZenBackgroundAccount> additional;
}

/// The per-account "Odbieraj w tle" setting.
///
/// Kept in the system's secret store (the device's own entry), as one list
/// always [slots] entries long: the accounts that receive in the
/// background, padded with entries that point at decoy folders (or at
/// other folders with a random secret). Nothing in it is an ID or a name;
/// without full access to the device nothing tells which entries are
/// real. With it — the secret store and the files — one can tell that an
/// account receiving in the background exists, read its mesh address and
/// whom it accepts messages from (what the background key opens); its
/// conversations and everything else stay under its password.
final class ZenBackgroundAccounts {
  ZenBackgroundAccounts({
    ZenAccountRegistry? registry,
    SecureStorageCredentialsStore secrets =
        const SecureStorageCredentialsStore.device(),
    Random? random,
  }) : _registry = registry ?? ZenAccountRegistry(secrets: secrets),
       _secrets = secrets.forDevice(),
       _random = random ?? Random.secure();

  final ZenAccountRegistry _registry;
  final SecureStorageCredentialsStore _secrets;
  final Random _random;

  static const String storageKey = 'zen_rewrite_accounts_background';

  /// Entries in the list, real or padding (at most this many additional
  /// accounts receive in the background).
  static const int slots = 6;

  /// The list as the service reads it: padding included (it cannot tell
  /// and does not need to: padding opens nothing).
  Future<ZenBackgroundAccountList> load() async {
    final _Stored stored = await _read();
    return ZenBackgroundAccountList(
      defaultOn: stored.defaultOn,
      additional: stored.entries,
    );
  }

  /// Whether [scope] receives in the background.
  Future<bool> isOn(ZenAccountScope scope) async {
    final _Stored stored = await _read();
    if (scope.isDefault) {
      return stored.defaultOn;
    }
    return stored.entries.any(
      (ZenBackgroundAccount a) =>
          a.matches(scope) && listEquals(a.secret, scope.secret),
    );
  }

  /// Turns "Odbieraj w tle" on or off for [scope]. Returns false when no
  /// slot is left for another additional account.
  Future<bool> setOn(ZenAccountScope scope, bool on) async {
    final _Stored stored = await _read();
    bool defaultOn = stored.defaultOn;
    final List<ZenBackgroundAccount> real = <ZenBackgroundAccount>[
      for (final ZenBackgroundAccount a in stored.entries)
        if (!a.matches(scope) && await _isReal(a)) a,
    ];
    if (scope.isDefault) {
      defaultOn = on;
    } else if (on) {
      if (real.length >= slots) {
        return false;
      }
      real.add(
        ZenBackgroundAccount(folder: scope.folder!, secret: scope.secret!),
      );
    }
    await _write(defaultOn, real);
    return true;
  }

  /// Forgets [scope] (its account was wiped).
  Future<void> forget(ZenAccountScope scope) async {
    if (!scope.isDefault && await isOn(scope)) {
      await setOn(scope, false);
    }
  }

  /// A real entry: its account keeps a background key under its secret
  /// (padding has a random secret, so nothing is there). Whoever can read
  /// the secret store can do the same check — the padding only keeps the
  /// list itself from telling.
  Future<bool> _isReal(ZenBackgroundAccount a) async =>
      await _secrets
          .forAccount(a.secret)
          .read(appSecurityBackgroundKeyStorageKey) !=
      null;

  Future<_Stored> _read() async {
    final String? raw = await _secrets.read(storageKey);
    if (raw == null) {
      return const _Stored(true, <ZenBackgroundAccount>[]);
    }
    try {
      final Object? json = jsonDecode(raw);
      if (json is! Map) {
        return const _Stored(true, <ZenBackgroundAccount>[]);
      }
      final List<ZenBackgroundAccount> entries = <ZenBackgroundAccount>[
        if (json['a'] is List)
          for (final Object? item in json['a'] as List)
            ?ZenBackgroundAccount.fromJson(item),
      ];
      return _Stored(json['d'] != false, entries);
    } on FormatException {
      return const _Stored(true, <ZenBackgroundAccount>[]);
    }
  }

  Future<void> _write(bool defaultOn, List<ZenBackgroundAccount> real) async {
    final List<ZenBackgroundAccount> all = <ZenBackgroundAccount>[
      ...real,
      ...await _padding(slots - real.length, real),
    ]..shuffle(_random);
    await _secrets.write(
      storageKey,
      jsonEncode(<String, Object>{
        'd': defaultOn,
        'a': <Map<String, String>>[
          for (final ZenBackgroundAccount a in all) a.toJson(),
        ],
      }),
    );
  }

  /// [count] entries pointing at decoy (or other) folders, with random
  /// secrets.
  Future<List<ZenBackgroundAccount>> _padding(
    int count,
    List<ZenBackgroundAccount> real,
  ) async {
    final List<String> folders = <String>[];
    try {
      final Directory dir = await _registry.accountsDirectory();
      if (await dir.exists()) {
        await for (final FileSystemEntity e in dir.list(followLinks: false)) {
          final String name = e.uri.pathSegments
              .where((String s) => s.isNotEmpty)
              .last;
          if (e is Directory &&
              RegExp(r'^[0-9a-f]{32}$').hasMatch(name) &&
              !real.any((ZenBackgroundAccount a) => a.folder == name)) {
            folders.add(name);
          }
        }
      }
    } on FileSystemException catch (error) {
      logZenWarning('Listing the accounts folder failed: $error');
    }
    return <ZenBackgroundAccount>[
      for (int i = 0; i < count; i++)
        ZenBackgroundAccount(
          folder: folders.isEmpty
              ? _hex(_bytes(16))
              : folders[_random.nextInt(folders.length)],
          secret: _bytes(32),
        ),
    ];
  }

  Uint8List _bytes(int n) =>
      Uint8List.fromList(List<int>.generate(n, (_) => _random.nextInt(256)));
}

/// The list as stored: the default account's flag and every entry.
@immutable
final class _Stored {
  const _Stored(this.defaultOn, this.entries);

  final bool defaultOn;
  final List<ZenBackgroundAccount> entries;
}

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

final Provider<ZenBackgroundAccounts> zenBackgroundAccountsProvider =
    Provider<ZenBackgroundAccounts>(
      (Ref ref) =>
          ZenBackgroundAccounts(registry: ref.read(zenAccountRegistryProvider)),
    );

/// What an additional account's notifications look like while it receives
/// in the background: no name, no content, no account — the same generic
/// line whatever account it is ("Nowe powiadomienie" / "Nowa wiadomość").
/// Tapping one opens Zen at the lock screen.
final class GenericAccountNotices implements RuntimeSystemNotificationService {
  GenericAccountNotices(this.delegate, {required this.slot});

  final RuntimeSystemNotificationService delegate;

  /// Keeps one account's notifications apart from another's (never
  /// shown).
  final int slot;

  String _id(String id) => 'bg$slot-${id.hashCode.toRadixString(36)}';

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) async {}

  @override
  Future<bool> show(RuntimeSystemNotification notification) {
    return delegate.show(
      RuntimeSystemNotification(
        id: _id(notification.id),
        title: PrivacyRedactingNotificationService.genericTitle,
        body: PrivacyRedactingNotificationService.genericBodyFor(
          notification.category == RuntimeSystemNotificationCategory.message
              ? RuntimeSystemNotificationCategory.message
              : RuntimeSystemNotificationCategory.social,
        ),
        createdAtMillis: notification.createdAtMillis,
        category: notification.category,
        slotKey: notification.slotKey == null
            ? null
            : _id(notification.slotKey!),
        isRingingCall: notification.isRingingCall,
        contentRedacted: true,
      ),
    );
  }

  @override
  Future<void> dismiss(String id) => delegate.dismiss(_id(id));

  @override
  Future<void> dismissSlot(String slotKey) =>
      delegate.dismissSlot(_id(slotKey));

  @override
  Future<void> clear() async {}
}

/// An additional account's receive-only node, run without its password:
/// the node under its background key, the sealed inbox, the doors of its
/// door kit and its outbox kit — what the default account's locked
/// receiver does, without the nearby radio and the alarm (one radio, one
/// alarm shortcut: the default account's).
final class BackgroundAccountNode {
  BackgroundAccountNode._(this._runtime, this._receiver, this._outbox);

  final RuntimeNodeRuntime _runtime;
  final LockedReceiver _receiver;
  final LockedOutbox? _outbox;

  /// `null` when [account]'s folder holds no background capability under
  /// its secret (padding, or an account never opened since it was turned
  /// on).
  static Future<BackgroundAccountNode?> open({
    required Directory accounts,
    required ZenBackgroundAccount account,
    required RuntimeSystemNotificationService notices,
    Duration waitTimeout = const Duration(seconds: 30),
    SecureStorageCredentialsStore secrets =
        const SecureStorageCredentialsStore.device(),
  }) async {
    final Directory support = Directory(
      '${accounts.path}${Platform.pathSeparator}${account.folder}',
    );
    if (!await support.exists()) {
      return null;
    }
    return openAt(
      support: support,
      credentials: secrets.forAccount(account.secret),
      notices: notices,
      waitTimeout: waitTimeout,
    );
  }

  /// The node of the account whose data is in [support] and whose entries
  /// [credentials] reads (a computer's default account while its window is
  /// locked, too).
  static Future<BackgroundAccountNode?> openAt({
    required Directory support,
    required AppSecurityCredentialsStore credentials,
    required RuntimeSystemNotificationService notices,
    Duration waitTimeout = const Duration(seconds: 30),
  }) async {
    Future<Directory> folder() async => support;
    final FileBackgroundVault vault = FileBackgroundVault(
      supportDirectory: folder,
      credentials: credentials,
    );
    final BackgroundCapability? capability = await vault.load();
    if (capability == null) {
      return null;
    }
    final LockedDoorKit? doorKit = LockedDoorKit.fromJson(
      await lockedDoorKitFile(
        supportDirectory: folder,
        credentials: credentials,
      ).read(),
    );
    final LockedOutboxKit? outboxKit = LockedOutboxKit.fromJson(
      await lockedOutboxKitFile(
        supportDirectory: folder,
        credentials: credentials,
      ).read(),
    );
    final RuntimeNodeRuntime runtime = buildDefaultRuntimeNodeRuntime(
      config: RuntimeSignalBootstrapConfig(
        waitTimeout: waitTimeout,
        nodeConfigProtector: BackgroundKeyProtector(credentials),
        fallbackPollInterval: const Duration(seconds: 2),
        supportDirectory: folder,
        // Only receives: two public peers do (a phone's main node dials
        // four; computers keep their own number).
        peerTarget: 2,
      ),
    );
    if (doorKit != null && !doorKit.isEmpty) {
      runtime
        ..setDoorKey(doorKit.doorKey)
        ..setMailboxDoorKeys(doorKit.mailboxDoorKeys);
    }
    final SealedInboxWriter inbox = SealedInboxWriter(
      file: await vault.inboxFile(),
      recipientPublicKey: capability.inboxPublicKey,
    );
    return BackgroundAccountNode._(
      runtime,
      LockedReceiver(
        transport: runtime,
        capability: capability,
        inbox: inbox,
        notices: notices,
        doorFrames: runtime.doorFrames,
        knocks: doorKit?.knockWatch(),
      ),
      outboxKit == null || outboxKit.items.isEmpty
          ? null
          : LockedOutbox(transport: runtime, kit: outboxKit),
    );
  }

  /// Opens every additional account of [list] that has something to
  /// receive with, except [skip] (the account open in the app, whose own
  /// node runs there). One that fails is logged and left out.
  static Future<List<BackgroundAccountNode>> openAll(
    ZenBackgroundAccountList list, {
    required Directory accounts,
    required RuntimeSystemNotificationService notices,
    String? skip,
    Duration waitTimeout = const Duration(seconds: 30),
    SecureStorageCredentialsStore secrets =
        const SecureStorageCredentialsStore.device(),
  }) async {
    final List<BackgroundAccountNode> nodes = <BackgroundAccountNode>[];
    int slot = 0;
    for (final ZenBackgroundAccount account in list.additional) {
      slot++;
      if (account.folder == skip) {
        continue;
      }
      try {
        final BackgroundAccountNode? node = await open(
          accounts: accounts,
          account: account,
          notices: GenericAccountNotices(notices, slot: slot),
          waitTimeout: waitTimeout,
          secrets: secrets,
        );
        if (node != null) {
          nodes.add(node);
        }
      } on Object catch (error, stackTrace) {
        logZenError('Opening a background account failed', error, stackTrace);
      }
    }
    return nodes;
  }

  SignalTransport get transport => _runtime;

  Future<void> start() async {
    await _receiver.start();
    await _outbox?.start();
  }

  Future<void> stop() async {
    await _outbox?.stop();
    await _receiver.stop();
    _runtime.dispose();
  }
}
