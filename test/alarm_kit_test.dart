import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/meet/alarm_kit.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/locked_alarm.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';

// Not IPv6: kept as they are by the address normalization.
const String _ania = 'ania.ygg';
const String _bob = 'bob.ygg';
const String _bob2 = 'bob2.ygg';
const String _cyryl = 'cyryl.ygg';
const String _mailbox = 'mailbox.ygg';

Uint8List _masterKey() =>
    Uint8List.fromList(List<int>.generate(32, (int i) => i + 11));

/// A phone on a small network: frames go straight to the other phone's
/// meeting service while it is [online].
final class _Phone implements MeetHost {
  _Phone(this.net, this.address, this.friendList, {List<String>? close})
    : close = close ?? <String>[] {
    net[address] = this;
    service = MeetService(host: this, store: MeetStore(disk), now: () => clock)
      ..ownAddress = () => address;
  }

  final Map<String, _Phone> net;
  final String address;
  final List<String> friendList;
  final List<String> close;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  late final MeetService service;
  int clock = 1000;
  bool online = true;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add((to, payload));
    final _Phone? other = net[to];
    if (other == null || !other.online) {
      return;
    }
    await other.service.handle(
      SignalTransportFrame(
        from: address,
        payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
        receivedAtMillis: 0,
      ),
    );
  }

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => close;

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  bool isSelf(String a) => a == address;

  @override
  String nameOf(String a) => a.toUpperCase();

  @override
  Future<void> notify(RuntimeSystemNotification n) async => shown.add(n);

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

final class _KitStore implements AlarmKitStore {
  AlarmKit? kit;

  @override
  Future<void> write(AlarmKit kit) async {
    this.kit = AlarmKit.fromJson(jsonDecode(jsonEncode(kit)));
  }

  @override
  Future<AlarmKit?> read() async => kit;
}

/// The mailbox copies, as the relay layer would seal them (here: the
/// template itself, to look at).
final List<Map<String, dynamic>> _templates = <Map<String, dynamic>>[];

Future<List<({String mailbox, String id, Map<String, dynamic> frame})>>
_preseal(String to, Map<String, dynamic> payload) async {
  _templates.add(payload);
  return <({String mailbox, String id, Map<String, dynamic> frame})>[
    (
      mailbox: _mailbox,
      id: 'env-$to',
      frame: <String, dynamic>{
        'type': 'rly_deposit',
        'env': <String, dynamic>{'id': 'env-$to'},
      },
    ),
  ];
}

List<String> _devices(String friend) =>
    friend == _bob ? const <String>[_bob, _bob2] : const <String>[];

void main() {
  late Map<String, _Phone> net;
  late _Phone ania;
  late _Phone bob;
  late _Phone cyryl;
  late _KitStore store;
  late AlarmKitKeeper keeper;

  setUp(() async {
    _templates.clear();
    net = <String, _Phone>{};
    ania = _Phone(net, _ania, <String>[_bob, _cyryl], close: <String>[_bob]);
    bob = _Phone(net, _bob, <String>[_ania]);
    cyryl = _Phone(net, _cyryl, <String>[_ania]);
    // The device key that certifies the alarm key.
    await LedgerIdentity.loadOrCreate(ania.disk);
    await ania.service.setAlarmPin('1111', '9999');
    await ania.service.setAlarmPowerButton(true);
    store = _KitStore();
    keeper = AlarmKitKeeper(meet: ania.service, store: store, now: () => 1000);
  });

  Future<AlarmKit> writeKit() async {
    await keeper.refresh(devicesOf: _devices, preseal: _preseal);
    return store.kit!;
  }

  test('the kit holds whom to send to and the alarm key, no other key; '
      'friends learn the alarm key, certified by the device key', () async {
    final AlarmKit kit = await writeKit();
    expect(kit.self, _ania);
    expect(kit.shortcut, isTrue);
    expect(kit.running, isNull);
    final AlarmKitRecipient r = kit.recipients.single;
    expect(r.address, _bob, reason: 'close friends get the alarm');
    expect(r.devices, <String>[_bob, _bob2]);
    expect(r.deposits.single.mailbox, _mailbox);
    // The copy for the mailboxes: signed, marked as made in advance.
    final Map<String, dynamic> template = _templates.single;
    expect(template['type'], MeetTypes.alarm);
    expect(template['id'], kit.alarmId);
    expect(template['kit'], isTrue);
    final LedgerKeyPair alarmKey = await LedgerKeyPair.fromSeed(
      unb64(kit.alarmKeySeed, length: 32)!,
    );
    expect(template['sk'], alarmKey.id);
    expect(await verifyAlarmFrame(alarmKey.id, template), isTrue);

    // No master key, account key, device key or anything derived from them.
    final LedgerIdentity identity = (await LedgerIdentity.read(ania.disk))!;
    final String json = jsonEncode(kit);
    for (final List<int> secret in <List<int>>[
      identity.deviceKey.seed,
      identity.accountKey!.seed,
      identity.selfKey!,
      identity.pyramidSeed,
      _masterKey(),
    ]) {
      expect(json, isNot(contains(b64(secret))));
    }
    expect(kit.alarmKeySeed, isNot(b64(identity.deviceKey.seed)));

    // Friends got the alarm key's public part, checked against the
    // certificate.
    expect(bob.service.book.friendAlarmKeys[_ania], <String>[alarmKey.id]);
    expect(cyryl.service.book.friendAlarmKeys[_ania], <String>[alarmKey.id]);
  });

  test('a certificate that does not check out is not taken', () async {
    final AlarmKit kit = await writeKit();
    final LedgerKeyPair alarmKey = await LedgerKeyPair.fromSeed(
      unb64(kit.alarmKeySeed, length: 32)!,
    );
    final LedgerIdentity identity = (await LedgerIdentity.read(ania.disk))!;
    final AlarmKeyCertificate good = await AlarmKeyCertificate.issue(
      deviceKey: identity.deviceKey,
      certificate: identity.certificate,
      address: _ania,
      alarmKey: alarmKey.id,
      issued: 5,
    );
    expect(await good.verify(from: _ania), isTrue);
    // For another address, with an account this phone does not know for
    // the sender, or altered: refused.
    expect(await good.verify(from: _cyryl), isFalse);
    expect(await good.verify(from: _ania, account: 'someone-else'), isFalse);
    final LedgerKeyPair other = await LedgerKeyPair.generate();
    final Map<String, dynamic> forged = good.toJson()..['k'] = other.id;
    final _Phone dora = _Phone(net, 'dora.ygg', <String>[_ania]);
    await dora.service.handle(
      SignalTransportFrame(
        from: _ania,
        payload: <String, dynamic>{'type': MeetTypes.alarmKey, 'c': forged},
        receivedAtMillis: 0,
      ),
    );
    expect(dora.service.book.friendAlarmKeys, isEmpty);
    // The same certificate from someone else's address: refused too.
    await bob.service.handle(
      SignalTransportFrame(
        from: _ania,
        payload: <String, dynamic>{
          'type': MeetTypes.alarmKey,
          'c': (await AlarmKeyCertificate.issue(
            deviceKey: identity.deviceKey,
            certificate: identity.certificate,
            address: _cyryl,
            alarmKey: other.id,
            issued: 6,
          )).toJson(),
        },
        receivedAtMillis: 0,
      ),
    );
    expect(bob.service.book.friendAlarmKeys[_ania], <String>[alarmKey.id]);
  });

  test('the kit is written again when the alarm setup changes, and only '
      'then', () async {
    expect(
      await keeper.refresh(devicesOf: _devices, preseal: _preseal),
      isTrue,
    );
    expect(
      await keeper.refresh(devicesOf: _devices, preseal: _preseal),
      isFalse,
    );
    // Something that is not the alarm's business.
    await ania.service.setMyIntent(
      const IntentStatus(kind: IntentKind.talk, setAt: 1000, until: 5000),
    );
    expect(
      await keeper.refresh(devicesOf: _devices, preseal: _preseal),
      isFalse,
    );
    // Sound, Bluetooth, the shortcut, whom it goes to, their devices.
    await ania.service.setAlarmRecordAudio(true);
    expect(await keeper.refresh(devicesOf: _devices), isTrue);
    expect(store.kit!.recordAudio, isTrue);
    await ania.service.setAlarmNearby(true);
    expect(await keeper.refresh(devicesOf: _devices), isTrue);
    ania.close.add(_cyryl);
    expect(await keeper.refresh(devicesOf: _devices), isTrue);
    expect(
      store.kit!.recipients.map((AlarmKitRecipient r) => r.address),
      <String>[_bob, _cyryl],
    );
    expect(await keeper.refresh(), isTrue, reason: 'bob2 is gone');
    expect(store.kit!.recipients.first.devices, <String>[_bob]);
    // With the shortcut off and no alarm going on the locked service has no
    // use for whom to send to: no friend stays readable without the
    // password.
    await ania.service.setAlarmPowerButton(false);
    expect(await keeper.refresh(devicesOf: _devices), isTrue);
    expect(store.kit!.shortcut, isFalse);
    expect(store.kit!.recipients, isEmpty);
    expect(keeper.writes, 6);
  });

  test('an alarm going on keeps its recipients in the kit with the '
      'shortcut off', () async {
    await ania.service.setAlarmPowerButton(false);
    final AlarmRecord raised = await ania.service.raiseAlarm();
    final AlarmKit kit = await writeKit();
    expect(kit.shortcut, isFalse);
    expect(kit.running?.id, raised.id);
    expect(kit.recipients.single.address, _bob);
  });

  test('the kit is sealed with the background key: the service opens it, '
      'nothing on the disk reads it', () async {
    final Directory support = await Directory.systemTemp.createTemp(
      'zen-alarm-kit-store-',
    );
    addTearDown(() => support.delete(recursive: true));
    final MemorySecurityCredentialsStore credentials =
        MemorySecurityCredentialsStore();
    final AlarmKit kit = await writeKit();
    final FileAlarmKitStore appStore = FileAlarmKitStore(
      supportDirectory: () async => support,
      credentials: credentials,
      createKey: true,
    );
    final FileAlarmKitStore serviceStore = FileAlarmKitStore(
      supportDirectory: () async => support,
      credentials: credentials,
    );
    expect(await serviceStore.read(), isNull);
    await appStore.write(kit);
    final String onDisk = latin1.decode(
      await (await appStore.file()).readAsBytes(),
      allowInvalid: true,
    );
    for (final String secret in <String>[_bob, _bob2, kit.alarmKeySeed]) {
      expect(onDisk, isNot(contains(secret)));
    }
    final AlarmKit? read = await serviceStore.read();
    expect(read?.alarmId, kit.alarmId);
    expect(read?.alarmKeySeed, kit.alarmKeySeed);
    expect(read?.recipients.single.devices, <String>[_bob, _bob2]);
    await credentials.delete(appSecurityBackgroundKeyStorageKey);
    expect(await serviceStore.read(), isNull);
  });

  group('locked', () {
    late Directory support;
    late MemorySecurityCredentialsStore credentials;
    late FileBackgroundVault appVault;
    late MemorySignalTransport transport;
    late MemoryRuntimeSystemNotificationService notices;
    late LockedAlarm alarm;
    late LockedReceiver receiver;

    setUp(() async {
      support = await Directory.systemTemp.createTemp('zen-alarm-kit-');
      credentials = MemorySecurityCredentialsStore();
      appVault = FileBackgroundVault(
        supportDirectory: () async => support,
        credentials: credentials,
        createKey: true,
      );
    });

    tearDown(() async {
      await receiver.stop();
      if (await support.exists()) {
        await support.delete(recursive: true);
      }
    });

    Future<void> lock({AlarmKit? kit}) async {
      await appVault.publish(
        BackgroundCapabilityDraft(
          inboxPublicKey: await inboxPublicKeyFor(_masterKey()),
          friends: const <String>{_bob, _bob2, _cyryl},
        ),
      );
      final FileBackgroundVault serviceVault = FileBackgroundVault(
        supportDirectory: () async => support,
        credentials: credentials,
      );
      final BackgroundCapability capability = (await serviceVault.load())!;
      final SealedInboxWriter inbox = SealedInboxWriter(
        file: await serviceVault.inboxFile(),
        recipientPublicKey: capability.inboxPublicKey,
      );
      transport = MemorySignalTransport();
      notices = MemoryRuntimeSystemNotificationService();
      ania.online = false;
      if (kit != null) {
        alarm = LockedAlarm(
          kit: kit,
          transport: transport,
          keep: (SignalTransportFrame record) =>
              inbox.append(encodeInboxFrame(record)),
          locate: () async => const GeoFix(52.2297, 21.0122, 8),
          now: () => 5000,
          resends: const <Duration>[],
          locationEvery: Duration.zero,
        );
      }
      receiver = LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: inbox,
        notices: notices,
        alarm: kit == null ? null : alarm,
        mailboxPollInterval: Duration.zero,
      );
      await receiver.start();
    }

    Future<void> receive(String from, Map<String, dynamic> payload) =>
        receiver.handleFrame(
          SignalTransportFrame(
            from: from,
            payload: payload,
            receivedAtMillis: 6000,
          ),
        );

    List<({String remoteAddress, Map<String, dynamic> payload})> sentOf(
      String type,
    ) => <({String remoteAddress, Map<String, dynamic> payload})>[
      for (final s in transport.sentSignals)
        if (s.payload['type'] == type) s,
    ];

    test('without a kit the shortcut says the alarm did not go out', () async {
      await lock();
      await receiver.onPowerShortcut();
      expect(notices.activeNotifications.single.slotKey, kLockedPowerAlarmSlot);
    });

    test('the shortcut sends the alarm from the kit; friends check its '
        'signature; the app takes it over after unlock', () async {
      final AlarmKit kit = await writeKit();
      await lock(kit: kit);

      await receiver.onPowerShortcut();
      await alarm.locateNow();
      expect(notices.activeNotifications, isEmpty, reason: 'it went out');
      // To every device of the friend, signed, asking for a confirmation.
      final List<({String remoteAddress, Map<String, dynamic> payload})>
      alarms = sentOf(MeetTypes.alarm);
      expect(alarms.map((s) => s.remoteAddress).toSet(), <String>{_bob, _bob2});
      for (final s in alarms) {
        expect(s.payload['id'], kit.alarmId);
        expect(s.payload['sg'], isA<String>());
        expect(s.payload['cf'], isTrue);
      }
      // The mailbox copy, for a friend who is offline.
      expect(sentOf('rly_deposit').single.remoteAddress, _mailbox);
      final Map<String, dynamic> located = alarms.last.payload;
      expect(located['lat'], closeTo(52.2297, 1e-9));

      // The copy from a mailbox first: its time is when it came.
      bob.clock = 7000;
      await bob.service.handle(
        SignalTransportFrame(
          from: _ania,
          payload: <String, dynamic>{..._templates.single, '_rid': 'env-bob'},
          receivedAtMillis: 0,
        ),
      );
      expect(bob.service.book.alarm(kit.alarmId)!.at, 7000);
      // Then the alarm itself: it rings, with where she is.
      bob.shown.clear();
      await bob.service.handle(
        SignalTransportFrame(
          from: _ania,
          payload: jsonDecode(jsonEncode(located)) as Map<String, dynamic>,
          receivedAtMillis: 0,
        ),
      );
      final AlarmRecord got = bob.service.book.alarm(kit.alarmId)!;
      expect(got.isActive, isTrue);
      expect(got.at, 5000);
      expect(got.hasLocation, isTrue);
      expect(
        bob.sent.any((s) => s.$2['type'] == MeetTypes.alarmAck),
        isTrue,
        reason: 'bob confirms it',
      );

      // An alarm frame altered on the way does not check out: dropped.
      final Map<String, dynamic> altered =
          jsonDecode(jsonEncode(located)) as Map<String, dynamic>;
      altered['lat'] = 50.0;
      await cyryl.service.handle(
        SignalTransportFrame(
          from: _ania,
          payload: altered,
          receivedAtMillis: 0,
        ),
      );
      expect(cyryl.service.book.alarm(kit.alarmId), isNull);
      // Unaltered it is taken.
      await cyryl.service.handle(
        SignalTransportFrame(
          from: _ania,
          payload: jsonDecode(jsonEncode(located)) as Map<String, dynamic>,
          receivedAtMillis: 0,
        ),
      );
      expect(cyryl.service.book.alarm(kit.alarmId), isNotNull);
      // A record of "this person's own alarm" from anyone but this device
      // is never taken.
      await cyryl.service.handle(
        SignalTransportFrame(
          from: _ania,
          payload: <String, dynamic>{
            'type': MeetTypes.ownAlarm,
            'a': AlarmRecord(id: 'fake1', from: 'self', at: 1).toJson(),
          },
          receivedAtMillis: 0,
        ),
      );
      expect(cyryl.service.book.alarm('fake1'), isNull);

      // While locked: bob's other phone confirms, bob answers.
      await receive(_bob2, <String, dynamic>{
        'type': MeetTypes.alarmAck,
        'id': kit.alarmId,
        'k': 'got',
        't': 6000,
      });
      expect(alarm.alarm!.reachOf(_bob), AlarmReach.delivered);
      await receive(_bob, <String, dynamic>{
        'type': MeetTypes.alarmResponse,
        'id': kit.alarmId,
        'r': AlarmResponse.coming.name,
      });
      expect(alarm.alarm!.responses[_bob], AlarmResponse.coming);
      // A second shortcut changes nothing.
      transport.sentSignals.clear();
      await receiver.onPowerShortcut();
      expect(notices.activeNotifications, isEmpty);
      await receiver.stop();

      // Unlocked: the app drains the inbox and takes the alarm over.
      ania
        ..online = true
        ..clock = 9000;
      expect(ania.service.book.ownActiveAlarm, isNull);
      await appVault.drain(
        masterKey: _masterKey(),
        settle: Duration.zero,
        deliver: (Uint8List record) async {
          final SignalTransportFrame? frame = decodeInboxFrame(record);
          if (frame != null) {
            await ania.service.handle(frame);
          }
        },
      );
      final AlarmRecord own = ania.service.book.ownActiveAlarm!;
      expect(own.id, kit.alarmId);
      expect(own.at, 5000);
      expect(own.sentTo, <String>[_bob]);
      expect(own.lat, closeTo(52.2297, 1e-9));
      expect(own.responses[_bob], AlarmResponse.coming);
      expect(
        (await ania.service.store.loadInTurn()).alarm(kit.alarmId),
        isNotNull,
        reason: 'saved',
      );

      // The kit now carries the running alarm; once it is called off with
      // the PIN, a new alarm id.
      await writeKit();
      expect(store.kit!.running?.id, kit.alarmId);
      expect(await ania.service.endAlarm('1111'), AlarmEndResult.ended);
      expect(bob.service.book.alarm(kit.alarmId)!.isActive, isFalse);
      final AlarmKit next = await writeKit();
      expect(next.running, isNull);
      expect(next.alarmId, isNot(kit.alarmId));
    });

    test(
      'an alarm going on when the app locks carries on in the service',
      () async {
        final AlarmRecord raised = await ania.service.raiseAlarm();
        final AlarmKit kit = await writeKit();
        expect(kit.running?.id, raised.id);
        expect(kit.recipients.single.deposits, isEmpty);
        await lock(kit: kit);
        await alarm.locateNow();
        final List<({String remoteAddress, Map<String, dynamic> payload})>
        alarms = sentOf(MeetTypes.alarm);
        expect(alarms, isNotEmpty);
        expect(alarms.last.payload['id'], raised.id);
        expect(alarms.last.payload['lat'], closeTo(52.2297, 1e-9));
        expect(sentOf('rly_deposit'), isEmpty);
        // The shortcut does not raise a second one.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        transport.sentSignals.clear();
        await receiver.onPowerShortcut();
        expect(sentOf(MeetTypes.alarm), isEmpty);
        expect(notices.activeNotifications, isEmpty);
      },
    );
  });
}
