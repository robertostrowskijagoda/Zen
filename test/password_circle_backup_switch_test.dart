import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/presentation/circle_backup_card.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/self_notes.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// "Hasła w kopii u znajomych": on by default, the passwords go sealed into
// the copy friends keep; switched off, the app's copy has none, the copy
// the friends hold is replaced at once (its chunks with the passwords
// deleted there), and every device of the account agrees, so none of them
// puts the passwords back. The notes stay in the copy either way.

const PasswordFields _bank = PasswordFields(
  name: 'Bank',
  login: 'ania',
  password: 'tajne-haslo-banku',
  address: 'https://bank.example.com',
);

// ---- the account's devices, with the real settings sync ----

final class _Net {
  final List<_Channel> devices = <_Channel>[];
  final List<(String, Map<String, dynamic>)> log =
      <(String, Map<String, dynamic>)>[];

  void deliver() {
    for (final _Channel d in devices) {
      for (int i = d.delivered; i < log.length; i++) {
        final (String from, Map<String, dynamic> body) = log[i];
        if (from != d.device) {
          d.inbox.add(body);
        }
      }
      d.delivered = log.length;
    }
  }
}

final class _Channel implements AccountSyncChannel {
  _Channel(this.net, this.device) {
    net.devices.add(this);
  }

  final _Net net;
  @override
  final String device;
  int delivered = 0;
  final StreamController<Map<String, dynamic>> inbox =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get hasOtherDevices => net.devices.length > 1;

  @override
  Iterable<Map<String, dynamic>> existing() => const <Map<String, dynamic>>[];

  @override
  Stream<Map<String, dynamic>> get incoming => inbox.stream;

  @override
  Stream<void> get devicesChanged => const Stream<void>.empty();

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    net.log.add((device, jsonDecode(jsonEncode(body)) as Map<String, dynamic>));
    return true;
  }
}

/// One device of the account: the app's settings, passwords and notes,
/// the copy's contents as the app collects them, and the settings sync.
final class _Device {
  _Device._(this.container, this.data, this.sync);

  final ProviderContainer container;
  final AppCircleBackupData data;
  final AccountStateSync sync;

  static Future<_Device> create(_Net net, String id) async {
    final Directory dir = Directory.systemTemp.createTempSync('zen-switch-');
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
        // Both devices have saved their settings (the defaults).
        appSettingsStoreProvider.overrideWithValue(
          MemoryAppSettingsStore(const AppSettings()),
        ),
        appSecurityServiceProvider.overrideWithValue(
          MemoryAppSecurityService(passwordIterations: 10),
        ),
        passwordVaultServiceProvider.overrideWithValue(
          PasswordVaultService(disk: MemoryLedgerDisk()),
        ),
        selfNotesServiceProvider.overrideWithValue(
          SelfNotesService(disk: MemoryLedgerDisk()),
        ),
      ],
    );
    await container.read(socialHubControllerProvider.notifier).whenHydrated;
    final LedgerNode node = LedgerNode(
      transport: MemorySignalTransport(),
      disk: MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => PeerShareCodec.normalizeAddress('200::f$id'),
      syncInterval: Duration.zero,
    );
    final AppCircleBackupData data = container.read(
      Provider<AppCircleBackupData>(
        (Ref ref) => AppCircleBackupData(ref, node),
      ),
    );
    final SettingsSyncDomain settings = container.read(
      Provider<SettingsSyncDomain>((Ref ref) => SettingsSyncDomain(ref)),
    );
    // As the app does: a change of the settings is sent to the others.
    container.listen<AppSettings>(
      appSettingsControllerProvider,
      (_, _) => settings.poke(),
    );
    final AccountStateSync sync = AccountStateSync(
      channel: _Channel(net, id),
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[settings],
      delay: const Duration(milliseconds: 1),
      scanEvery: const Duration(hours: 1),
    );
    await sync.start();
    addTearDown(() async {
      await sync.stop();
      container.dispose();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Still open on Windows: left to the system's temp cleaning.
      }
    });
    return _Device._(container, data, sync);
  }

  AppSettingsController get settings =>
      container.read(appSettingsControllerProvider.notifier);

  bool get passwordsInCopy =>
      container.read(appSettingsControllerProvider).passwordsInCircleBackup;

  Future<CircleBackupContent> copy() => data.collect(chats: false);
}

Future<void> _settle(_Net net, List<_Device> devices) async {
  for (int round = 0; round < 8; round++) {
    net.deliver();
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final _Device d in devices) {
      await d.sync.flush();
    }
  }
}

// ---- a copy with a friend ----

final class _Linked extends MemorySignalTransport {
  _Linked(String address) : address = PeerShareCodec.normalizeAddress(address) {
    nodes[this.address] = this;
  }

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      final Map<String, dynamic> wire =
          jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: wire),
      );
    }
  }
}

/// A copy's contents: a profile, the notes, and the passwords while
/// [withPasswords] says so (as the app's switch does).
final class _Data implements CircleBackupData {
  bool withPasswords = true;

  @override
  Future<CircleBackupContent> collect({required bool chats}) async =>
      CircleBackupContent(
        sections: <String, Object?>{
          CircleBackupSections.profile: <String, Object?>{'displayName': 'A'},
          CircleBackupSections.notes: <String, Object?>{'n': 'notatka'},
          if (withPasswords)
            CircleBackupSections.passwords: <String, Object?>{
              'v': 'tajne-haslo-banku',
            },
        },
      );

  @override
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  ) async {}
}

Future<void> _settleCircle(List<CircleBackupService> services) async {
  for (int i = 0; i < 100; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (final CircleBackupService s in services) {
      await s.idle;
    }
  }
}

void main() {
  test('on by default: the app\'s copy carries the passwords and the notes; '
      'off, the notes only', () async {
    final _Net net = _Net();
    final _Device phone = await _Device.create(net, 'phone');
    expect(phone.passwordsInCopy, isTrue);
    await phone.container.read(passwordVaultServiceProvider).add(_bank);
    await phone.container.read(selfNotesServiceProvider).add('kod 4321');

    final CircleBackupContent on = await phone.copy();
    expect(on.sections[CircleBackupSections.passwords], isNotNull);
    expect(on.sections[CircleBackupSections.notes], isNotNull);

    await phone.settings.setPasswordsInCircleBackup(false);
    final CircleBackupContent off = await phone.copy();
    expect(off.sections.containsKey(CircleBackupSections.passwords), isFalse);
    expect(jsonEncode(off.sections), isNot(contains('tajne-haslo-banku')));
    // The notes are a matter of their own: they stay.
    expect(off.sections[CircleBackupSections.notes], isNotNull);
    // The setting goes with the account's settings in the copy itself.
    expect(
      (off.sections[CircleBackupSections.settings]!
          as Map<String, dynamic>)['passwordsInCircleBackup'],
      isFalse,
    );
  });

  test('switched off on one device, the other agrees and makes no copy with '
      'the passwords either; on again, both put them back', () async {
    final _Net net = _Net();
    final _Device phone = await _Device.create(net, 'phone');
    final _Device laptop = await _Device.create(net, 'laptop');
    await laptop.container.read(passwordVaultServiceProvider).add(_bank);
    await _settle(net, <_Device>[phone, laptop]);
    expect(
      (await laptop.copy()).sections[CircleBackupSections.passwords],
      isNotNull,
    );

    await phone.settings.setPasswordsInCircleBackup(false);
    await _settle(net, <_Device>[phone, laptop]);
    expect(laptop.passwordsInCopy, isFalse);
    expect(
      (await laptop.copy()).sections.containsKey(
        CircleBackupSections.passwords,
      ),
      isFalse,
    );

    await laptop.settings.setPasswordsInCircleBackup(true);
    await _settle(net, <_Device>[phone, laptop]);
    expect(phone.passwordsInCopy, isTrue);
    expect(laptop.passwordsInCopy, isTrue);
  });

  test('the switch is saved with the settings, and data from before it '
      'keeps the passwords in the copy', () {
    expect(const AppSettings().passwordsInCircleBackup, isTrue);
    // 1.16.5 wrote no such field.
    expect(
      AppSettings.fromJson(<String, dynamic>{
        'showLastOpened': false,
      }).passwordsInCircleBackup,
      isTrue,
    );
    final AppSettings off = const AppSettings().copyWith(
      passwordsInCircleBackup: false,
    );
    expect(AppSettings.fromJson(off.toJson()).passwordsInCircleBackup, isFalse);
    expect(kSyncedSettingKeys, contains('passwordsInCircleBackup'));
    expect(kDeviceSettingKeys, isNot(contains('passwordsInCircleBackup')));
  });

  test('switched off, a copy without the passwords replaces the friend\'s at '
      'once, and the friend deletes the chunks that held them', () async {
    _Linked.nodes.clear();
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final _Linked tOwner = _Linked('200::a');
    final _Linked tHolder = _Linked('200::b');
    await tOwner.start();
    await tHolder.start();
    // A real clock's time: the first copy is due at once.
    int now = DateTime.utc(2026, 11, 12).millisecondsSinceEpoch;
    final _Data data = _Data();
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: data,
      identity: () => CircleBackupIdentity(
        account: me.account,
        selfKey: me.selfKey!,
        deviceKey: me.deviceKey,
        certificate: me.certificate,
      ),
      holders: () => const <String>[],
      friendHolders: () => <String>[tHolder.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    final CircleBackupService holder = CircleBackupService(
      transport: tHolder,
      disk: MemoryLedgerDisk(),
      data: _Data(),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      isFriend: (String a) => a == me.account,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    await holder.start();
    await owner.start();
    await _settleCircle(<CircleBackupService>[owner, holder]);
    final CircleBackupManifest first = holder.holder.manifestOf(me.account)!;

    Future<CircleBackupContent> kept() async {
      final CircleBackupManifest m = holder.holder.manifestOf(me.account)!;
      final CircleBackupOpened opened = await openCircleBackup(
        manifest: m,
        chunks: <String, Uint8List>{
          for (final String id in m.chunks.keys)
            id: (await holder.holder.chunk(me.account, id))!,
        },
        account: me.account,
        selfKey: me.selfKey!,
      );
      return opened.content!;
    }

    expect((await kept()).sections[CircleBackupSections.passwords], isNotNull);

    // A minute later, well within the hour between two copies.
    now += const Duration(minutes: 1).inMilliseconds;
    data.withPasswords = false;
    owner.contentChanged();
    await _settleCircle(<CircleBackupService>[owner, holder]);

    final CircleBackupManifest second = holder.holder.manifestOf(me.account)!;
    expect(second.createdAt, greaterThan(first.createdAt));
    final CircleBackupContent replaced = await kept();
    expect(
      replaced.sections.containsKey(CircleBackupSections.passwords),
      isFalse,
    );
    expect(replaced.sections[CircleBackupSections.notes], isNotNull);
    // Nothing of the first copy that the second does not use is left.
    for (final String id in first.chunks.keys) {
      if (!second.chunks.containsKey(id)) {
        expect(await holder.holder.chunk(me.account, id), isNull, reason: id);
      }
    }
    await owner.stop();
    await holder.stop();
  });

  testWidgets('the switch sits beside the conversations\' one, says what '
      'turning it off does, and is the account\'s setting', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    final CircleBackupService service = CircleBackupService(
      transport: MemorySignalTransport(),
      disk: MemoryLedgerDisk(),
      data: _Data(),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    addTearDown(service.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          circleBackupServiceProvider.overrideWithValue(service),
          appSettingsStoreProvider.overrideWithValue(store),
          appSecurityServiceProvider.overrideWithValue(
            MemoryAppSecurityService(passwordIterations: 10),
          ),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: CircleBackupCard()),
          ),
        ),
      ),
    );
    await tester.pump();
    final Finder passwords = find.byKey(const Key('circle-backup-passwords'));
    expect(passwords, findsOneWidget);
    expect(find.byKey(const Key('circle-backup-chats')), findsOneWidget);
    expect(tester.widget<SwitchListTile>(passwords).value, isTrue);
    expect(find.text('Hasła w kopii u znajomych'), findsOneWidget);
    expect(
      find.textContaining('takie samo na wszystkich Twoich urządzeniach'),
      findsOneWidget,
    );

    await tester.tap(passwords);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(passwords).value, isFalse);
    expect((await store.load())!.passwordsInCircleBackup, isFalse);
    expect(
      find.textContaining('nowa kopia bez haseł od razu zastępuje'),
      findsOneWidget,
    );
    expect(find.textContaining('— bez haseł'), findsOneWidget);
  });
}
