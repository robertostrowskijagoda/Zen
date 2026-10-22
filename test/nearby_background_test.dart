import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/locked_nearby.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_keeper.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// A Bluetooth radio that records what it is asked to do.
final class _Radio implements NearbyRadio {
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();
  bool permitted = true;
  bool enabled = true;
  Uint8List? advertised;

  /// The tokens handed over in advance, and the slot of the first.
  Uint8List? schedule;
  int? scheduleStart;
  bool scanning = false;
  bool? lowPower;
  int scansStarted = 0;

  /// Battery, battery saver and Doze as the radio side reports them.
  Map<Object?, Object?> power = <Object?, Object?>{};

  /// Phones in range: a scan sees them as soon as it starts.
  final List<Map<Object?, Object?>> around = <Map<Object?, Object?>>[];

  /// Waves sent: device and what was in them.
  final List<(String, Map<String, dynamic>)> waves =
      <(String, Map<String, dynamic>)>[];

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': enabled,
    'permitted': permitted,
    ...power,
  };

  @override
  Future<bool> requestPermissions() async => permitted;

  @override
  Future<bool> requestEnable() async => enabled;

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    advertised = token;
    schedule = null;
    return true;
  }

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async {
    advertised = null;
    schedule = adverts;
    scheduleStart = firstSlot;
    return true;
  }

  @override
  Future<void> stopAdvertising() async {
    advertised = null;
    schedule = null;
  }

  @override
  Future<bool> startScan({bool lowPower = false}) async {
    scanning = true;
    this.lowPower = lowPower;
    scansStarted++;
    for (final Map<Object?, Object?> seen in around) {
      scheduleMicrotask(() => _events.add(seen));
    }
    return true;
  }

  @override
  Future<void> stopScan() async => scanning = false;

  @override
  Future<bool> wave(String device, Uint8List data) async {
    waves.add((device, jsonDecode(utf8.decode(data)) as Map<String, dynamic>));
    return true;
  }

  /// Bluetooth switched on or off (the radio side tells the engines).
  void turn({required bool on}) {
    enabled = on;
    _events.add(<Object?, Object?>{'type': 'bluetooth', 'on': on});
  }

  /// A phone nearby ([device]) waved [json] at this one. [elsewhere]: the
  /// other engine answers alarm waves now.
  void hear(
    Map<String, dynamic> json, {
    bool elsewhere = false,
    String device = 'mac-x',
  }) {
    _events.add(<Object?, Object?>{
      'type': 'wave',
      'device': device,
      'data': Uint8List.fromList(utf8.encode(jsonEncode(json))),
      'elsewhere': elsewhere,
    });
  }
}

final class _Net {
  final Map<String, _Phone> phones = <String, _Phone>{};
}

/// A phone: its meeting service with a fake host, and its radio.
final class _Phone implements MeetHost {
  _Phone(
    this.net,
    this.address,
    this.friendList, {
    this.close = const <String>[],
  }) {
    net.phones[address] = this;
    meet = MeetService(
      host: this,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => clock,
    )..ownAddress = () => address;
    nearby = NearbyService(
      radio: radio,
      meet: meet,
      ownAddress: () => address,
      sendMesh: send,
      frames: const Stream<SignalTransportFrame>.empty(),
      now: () => clock,
    );
  }

  final _Net net;
  final String address;
  final List<String> friendList;
  final List<String> close;
  final _Radio radio = _Radio();
  late final MeetService meet;
  late final NearbyService nearby;
  int clock = 1000000;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<String> dismissed = <String>[];
  final List<(String, Map<String, dynamic>)> sent =
      <(String, Map<String, dynamic>)>[];

  int get alarmsSent => sent
      .where(
        ((String, Map<String, dynamic>) s) => s.$2['type'] == MeetTypes.alarm,
      )
      .length;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    sent.add((to, payload));
    await net.phones[to]?.meet.handle(
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
  Future<void> dismissNotification(String slotKey) async =>
      dismissed.add(slotKey);
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// The nearby kit [phone]'s app would leave the service, as the service
/// reads it back.
Future<NearbyKit> _kitOf(_Phone phone, {bool recording = true}) async {
  NearbyKit? written;
  final NearbyKitKeeper keeper = NearbyKitKeeper(
    meet: phone.meet,
    write: (NearbyKit kit) async => written = kit,
    now: () => phone.clock,
  );
  expect(await keeper.refresh(recording: recording), isTrue);
  return NearbyKit.fromJson(jsonDecode(jsonEncode(written!.toJson())))!;
}

/// The service's records, as the inbox keeps them.
final class _Kept {
  final List<SignalTransportFrame> records = <SignalTransportFrame>[];

  Future<bool> keep(SignalTransportFrame record) async {
    records.add(decodeInboxFrame(encodeInboxFrame(record))!);
    return true;
  }
}

void main() {
  test('the tokens worked out in advance are the very tokens of each slot, '
      'across a chain\'s end too', () {
    final NearbyOwnKeys keys = NearbyOwnKeys(newNearbyPrivateKey(Random(3)));
    final int first = kNearbyChainSlots - 3;
    final Uint8List all = keys.adverts(first, 6);
    expect(all.length, 6 * kNearbyAdvertBytes);
    for (int i = 0; i < 6; i++) {
      expect(
        all.sublist(i * kNearbyAdvertBytes, (i + 1) * kNearbyAdvertBytes),
        keys.advert(first + i),
      );
    }
    expect(keys.adverts(5, 0), isEmpty);
  });

  test('the nearby kit holds a week of tokens but no key of this person, '
      'friends\' keys only, and is written again only on a change or a new '
      'day', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await ania.meet.shareNearbySecret('bob');
    await bob.meet.setNearbyVisible(true);
    await bob.meet.setAlarmNearby(true);

    int writes = 0;
    NearbyKit? kit;
    final NearbyKitKeeper keeper = NearbyKitKeeper(
      meet: bob.meet,
      write: (NearbyKit k) async {
        writes++;
        kit = k;
      },
      now: () => bob.clock,
    );
    expect(await keeper.refresh(recording: true), isTrue);
    final NearbyKit written = kit!;
    final String private = bob.meet.book.nearbyPrivate!;
    final int slot = nearbySlot(bob.clock);
    expect(written.visible, isTrue);
    expect(written.alarms, isTrue);
    expect(written.covers(slot), isTrue);
    expect(written.covers(slot + 7 * 144), isTrue, reason: 'a week ahead');
    expect(written.advertAt(slot), NearbyOwnKeys(private).advert(slot));
    expect(written.friends.keys.toList(), <String>['ania']);
    final String json = jsonEncode(written.toJson());
    expect(json, isNot(contains(private)));
    expect(
      NearbyKit.fromJson(jsonDecode(json))!.advertAt(slot + 10),
      isNotNull,
    );

    expect(await keeper.refresh(recording: true), isFalse);
    expect(writes, 1);
    // A friend's key from someone who is no friend (any more) stays out.
    await bob.meet.handle(
      SignalTransportFrame(
        from: 'cyryl',
        payload: <String, dynamic>{
          'type': MeetTypes.nearbyKey,
          'z': NearbyOwnKeys(
            newNearbyPrivateKey(Random(5)),
          ).materialFor('bob', bob.clock),
        },
        receivedAtMillis: 0,
      ),
    );
    expect(await keeper.refresh(recording: true), isFalse);

    expect(kit!.look, isTrue, reason: 'on by default');
    await bob.meet.setNearbyBackgroundScan(false);
    expect(await keeper.refresh(recording: true), isTrue);
    expect(kit!.look, isFalse);
    bob.clock += Duration.millisecondsPerDay;
    expect(await keeper.refresh(recording: true), isTrue);
    expect(kit!.firstSlot, greaterThan(written.firstSlot));

    // Hidden: no tokens at all, and no alarm waves (nobody waves at a phone
    // they cannot see).
    await bob.meet.setNearbyVisible(false);
    expect(await keeper.refresh(recording: true), isTrue);
    expect(kit!.adverts, isNull);
    expect(kit!.visible, isFalse);
    expect(kit!.alarms, isFalse);
  });

  test(
    'locked or closed, the service shows the phone from the kit and rings '
    'a friend\'s checked alarm wave; the app takes it after unlock',
    () async {
      final _Net net = _Net();
      // Bob is Ania's friend but not "przyjaciel": her alarm reaches him only
      // over Bluetooth.
      final _Phone ania = _Phone(
        net,
        'ania',
        <String>['bob', 'cyryl'],
        close: <String>['cyryl'],
      );
      final _Phone bob = _Phone(net, 'bob', <String>['ania']);
      await ania.meet.shareNearbySecret('bob');
      await bob.meet.setAlarmNearby(true);
      await bob.meet.setNearbyVisible(true);
      final NearbyKit kit = await _kitOf(bob);

      final _Kept kept = _Kept();
      final MemoryRuntimeSystemNotificationService notices =
          MemoryRuntimeSystemNotificationService();
      final List<bool> claimed = <bool>[];
      final List<List<String>> keys = <List<String>>[];
      final LockedNearby locked = LockedNearby(
        kit: kit,
        radio: bob.radio,
        keep: kept.keep,
        notices: notices,
        claimAlarms: (bool on) async => claimed.add(on),
        alarmKeys: (List<String> k) async => keys.add(k),
        now: () => bob.clock,
      );
      await locked.start();
      expect(locked.receivesAlarms, isTrue);
      expect(claimed, <bool>[true]);
      expect(keys.single, <String>[
        FriendNearbyKey.parse(
          bob.meet.book.friendNearbySecrets['ania'],
        )!.radioKey,
      ]);
      // Shown from the tokens worked out in advance: the radio side changes
      // them by itself.
      expect(bob.radio.schedule, kit.adverts);
      expect(bob.radio.scheduleStart, kit.firstSlot);

      final AlarmRecord alarm = await ania.meet.raiseAlarm(note: 'pomocy');
      expect(bob.meet.book.alarm(alarm.id), isNull);
      final Map<String, dynamic> wave = ania.meet.alarmWave(alarm, to: 'bob');
      final String aniaToken = wave['t'] as String;
      bob.radio.hear(wave, device: 'mac-ania');
      await _settle();
      await locked.pendingWave;
      final RuntimeSystemNotification ring = notices.activeNotifications.single;
      expect(ring.isRingingCall, isTrue);
      expect(ring.category, RuntimeSystemNotificationCategory.alarm);
      expect(ring.slotKey, kLockedAlarmSlot);
      expect(
        '${ring.title} ${ring.body}',
        isNot(anyOf(contains('ANIA'), contains('ania'))),
        reason: 'no names while locked',
      );
      final SignalTransportFrame record = kept.records.single;
      expect(record.from, 'bob');
      expect(record.payload['type'], MeetTypes.ownNearbyAlarm);
      expect(record.payload['f'], 'ania');
      expect(record.payload['id'], alarm.id);

      // Heard again: it rings once.
      bob.radio.hear(wave, device: 'mac-ania');
      await _settle();
      await locked.pendingWave;
      expect(kept.records, hasLength(1));

      // Her token with a made-up signature never rings: a quiet unchecked
      // note, once per phone.
      bob.radio.hear(<String, dynamic>{
        'v': kAlarmWaveVersion,
        'id': 'falszywy1',
        'at': bob.clock,
        't': aniaToken,
        'm': '0' * 32,
      }, device: 'mac-obcy');
      await _settle();
      await locked.pendingWave;
      expect(kept.records, hasLength(1));
      final RuntimeSystemNotification note = notices.activeNotifications
          .firstWhere(
            (RuntimeSystemNotification n) =>
                n.slotKey == MeetService.unverifiedWaveSlot,
          );
      expect(note.title, contains('Niesprawdzone'));
      expect(note.isRingingCall, isFalse);
      bob.radio.hear(<String, dynamic>{
        'v': kAlarmWaveVersion,
        'id': 'falszywy2',
        'at': bob.clock,
      }, device: 'mac-obcy');
      await _settle();
      await locked.pendingWave;
      expect(notices.activeNotifications, hasLength(2));
      expect(note.id, 'alarm-near-falszywy1');

      // The app's engine answers them now: left alone.
      bob.radio.hear(<String, dynamic>{
        'v': kAlarmWaveVersion,
        'id': 'obcy2',
        'at': bob.clock,
      }, elsewhere: true);
      await _settle();
      expect(kept.records, hasLength(1));

      await locked.stop();
      expect(claimed, <bool>[true, false]);
      expect(bob.radio.schedule, isNull, reason: 'the app shows it again');

      // After unlock the app takes the alarm as heard nearby, from its own
      // service only, and confirms it to her; it rang already.
      await bob.meet.handle(
        SignalTransportFrame(
          from: 'ania',
          payload: <String, dynamic>{
            'type': MeetTypes.ownNearbyAlarm,
            'f': 'ania',
            'id': 'podrobiony',
            'at': bob.clock,
          },
          receivedAtMillis: 0,
        ),
      );
      expect(bob.meet.book.alarm('podrobiony'), isNull);
      await bob.meet.handle(record);
      final AlarmRecord heard = bob.meet.book.alarm(alarm.id)!;
      expect(heard.from, 'ania');
      expect(heard.nearby, isTrue);
      expect(heard.isActive, isTrue);
      expect(bob.shown, isEmpty);
      expect(bob.sent.last.$1, 'ania');
      expect(bob.sent.last.$2['type'], MeetTypes.alarmAck);
    },
  );

  test('without "Alarm do pobliża" the locked service leaves alarm waves; '
      'hidden, it shows nothing', () async {
    final _Net net = _Net();
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await bob.meet.setNearbyVisible(true);
    await bob.meet.setNearbyBackgroundScan(false);
    final _Kept kept = _Kept();
    final MemoryRuntimeSystemNotificationService notices =
        MemoryRuntimeSystemNotificationService();
    final List<bool> claimed = <bool>[];
    LockedNearby locked = LockedNearby(
      kit: await _kitOf(bob),
      radio: bob.radio,
      keep: kept.keep,
      notices: notices,
      claimAlarms: (bool on) async => claimed.add(on),
      now: () => bob.clock,
    );
    await locked.start();
    expect(locked.receivesAlarms, isFalse);
    expect(bob.radio.schedule, isNotNull, reason: 'visible means shown');
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'x1',
      'at': bob.clock,
    });
    await _settle();
    expect(notices.activeNotifications, isEmpty);
    expect(await locked.lookNow(), isFalse, reason: 'no look around chosen');
    expect(bob.radio.scansStarted, 0);
    await locked.stop();

    // Hidden stays hidden, even with the alarm option on.
    await bob.meet.setNearbyVisible(false);
    await bob.meet.setAlarmNearby(true);
    locked = LockedNearby(
      kit: await _kitOf(bob),
      radio: bob.radio,
      keep: kept.keep,
      notices: notices,
      claimAlarms: (bool on) async => claimed.add(on),
      now: () => bob.clock,
    );
    await locked.start();
    expect(locked.receivesAlarms, isFalse);
    expect(bob.radio.schedule, isNull);
    expect(bob.radio.advertised, isNull);
    await locked.stop();
    expect(claimed, isEmpty);
    expect(kept.records, isEmpty);
  });

  test('locked, the look around runs only with "Mijani" on, keeps friends '
      'passed and the crowd count for the app, which merges them', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await ania.meet.shareNearbySecret('bob');
    await bob.meet.setNearbyBackgroundScan(true);
    bob.radio.around
      ..add(<Object?, Object?>{
        'type': 'seen',
        'token': NearbyOwnKeys(
          ania.meet.book.nearbyPrivate!,
        ).advert(nearbySlot(bob.clock)),
        'rssi': -65,
        'device': 'mac-ania',
      })
      ..add(<Object?, Object?>{
        'type': 'seen',
        'token': Uint8List.fromList(List<int>.generate(20, (int i) => i + 1)),
        'rssi': -80,
        'device': 'mac-obcy',
      });

    final _Kept kept = _Kept();
    final MemoryRuntimeSystemNotificationService notices =
        MemoryRuntimeSystemNotificationService();
    final LockedNearby off = LockedNearby(
      kit: await _kitOf(bob, recording: false),
      radio: bob.radio,
      keep: kept.keep,
      notices: notices,
      lookFor: const Duration(milliseconds: 5),
      now: () => bob.clock,
    );
    await off.start();
    expect(await off.lookNow(), isFalse, reason: '"Mijani" is off');
    await off.stop();
    expect(bob.radio.scansStarted, 0);

    final LockedNearby locked = LockedNearby(
      kit: await _kitOf(bob),
      radio: bob.radio,
      keep: kept.keep,
      notices: notices,
      place: () async => EncounterPlace.approximate(52.22971, 21.01224),
      lookFor: const Duration(milliseconds: 5),
      keepEvery: Duration.zero,
      now: () => bob.clock,
    );
    await locked.start();
    expect(await locked.lookNow(), isTrue);
    expect(bob.radio.lowPower, isTrue);
    expect(bob.radio.scanning, isFalse, reason: 'only a short look');
    final SignalTransportFrame record = kept.records.single;
    expect(record.from, 'bob');
    expect(record.payload['type'], kKeptEncountersType);
    expect(jsonEncode(record.payload), isNot(contains('mac-')));

    // This person's own alarm wave looks around too: no look meanwhile.
    final Completer<void> waving = Completer<void>();
    final Future<int> held = locked.holdingRadio<int>(() async {
      await waving.future;
      return 1;
    });
    expect(await locked.lookNow(), isFalse);
    waving.complete();
    expect(await held, 1);
    await locked.stop();

    // After unlock the app merges it into "Mijani".
    final EncounterLog log = EncounterLog(
      disk: MemoryLedgerDisk(),
      now: () => bob.clock,
    );
    await log.load();
    await log.takeKept(record.payload);
    final Encounter met = log.encounters.single;
    expect(met.friend, 'ania');
    expect(met.place, EncounterPlace.approximate(52.22971, 21.01224));
    expect(log.crowds.single.count, 1);

    // Off in the app: nothing is taken.
    await log.setRecording(false);
    await log.clear();
    await log.takeKept(record.payload);
    expect(log.encounters, isEmpty);
    log.dispose();
  });

  test('locked, no look around is planned while Bluetooth is off or not '
      'allowed', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await ania.meet.shareNearbySecret('bob');
    await bob.meet.setNearbyBackgroundScan(true);
    final MemoryRuntimeSystemNotificationService notices =
        MemoryRuntimeSystemNotificationService();
    final _Kept kept = _Kept();
    final NearbyKit kit = await _kitOf(bob);
    LockedNearby lockedWith() => LockedNearby(
      kit: kit,
      radio: bob.radio,
      keep: kept.keep,
      notices: notices,
      now: () => bob.clock,
    );

    bob.radio.enabled = false;
    final LockedNearby locked = lockedWith();
    await locked.start();
    expect(locked.looksPlanned, isFalse, reason: 'no wake for nothing');
    bob.radio.turn(on: true);
    await Future<void>.delayed(Duration.zero);
    expect(locked.looksPlanned, isTrue);
    bob.radio.turn(on: false);
    await Future<void>.delayed(Duration.zero);
    expect(locked.looksPlanned, isFalse);
    await locked.stop();

    // Not allowed to use Bluetooth: nothing planned, whatever comes.
    bob.radio
      ..enabled = true
      ..permitted = false;
    final LockedNearby denied = lockedWith();
    await denied.start();
    expect(denied.looksPlanned, isFalse);
    bob.radio.turn(on: true);
    await Future<void>.delayed(Duration.zero);
    expect(denied.looksPlanned, isFalse);
    await denied.stop();
    expect(denied.looksPlanned, isFalse);
  });

  test('the power-button shortcut raises the very alarm of the button: off '
      'by default, needs the PINs, ends only with a PIN', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(
      net,
      'ania',
      <String>['bob'],
      close: <String>['bob'],
    );
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);

    expect(await raiseAlarmFromShortcut(ania.meet), ShortcutAlarmResult.off);
    await ania.meet.setAlarmPowerButton(true);
    expect(await raiseAlarmFromShortcut(ania.meet), ShortcutAlarmResult.noPin);
    expect(ania.meet.book.ownActiveAlarm, isNull);

    await ania.meet.setAlarmPin('1234', '9999');
    expect(await raiseAlarmFromShortcut(ania.meet), ShortcutAlarmResult.raised);
    final AlarmRecord alarm = ania.meet.book.ownActiveAlarm!;
    expect(bob.meet.book.alarm(alarm.id)!.isActive, isTrue);
    expect(bob.shown.last.isRingingCall, isTrue);

    // Pressing again starts nothing new.
    expect(
      await raiseAlarmFromShortcut(ania.meet),
      ShortcutAlarmResult.alreadyRunning,
    );
    expect(ania.meet.book.alarms, hasLength(1));

    // A mistyped PIN changes nothing; the panic PIN ends it on screen and
    // warns friends.
    expect(await ania.meet.endAlarm('0000'), AlarmEndResult.wrongPin);
    expect(bob.meet.book.alarm(alarm.id)!.isActive, isTrue);
    expect(await ania.meet.endAlarm('9999'), AlarmEndResult.ended);
    expect(ania.meet.book.ownActiveAlarm, isNull);
    expect(bob.meet.book.alarm(alarm.id)!.duress, isTrue);
    expect(bob.shown.last.title, contains('PIN-em przymusu'));

    // Remembered; off in a new book.
    final MeetBook again = MeetBook.fromJson(
      jsonDecode(jsonEncode(ania.meet.book.toJson())),
    );
    expect(again.alarmPowerButton, isTrue);
    expect(
      MeetBook.fromJson(
        jsonDecode(jsonEncode(MeetBook().toJson())),
      ).alarmPowerButton,
      isFalse,
    );
  });

  test('an alarm raised in the app goes to phones nearby too, when '
      'chosen', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(
      net,
      'ania',
      <String>['bob'],
      close: <String>['bob'],
    );
    await ania.meet.setAlarmPin('1234', '9999');
    await ania.meet.setAlarmPowerButton(true);
    await ania.meet.setAlarmNearby(true);
    ania.radio.around.add(<Object?, Object?>{
      'type': 'seen',
      'token': Uint8List.fromList(List<int>.generate(20, (int i) => i + 1)),
      'rssi': -60,
      'device': 'mac-obcy',
    });
    // As `AlarmWatcher` wires it.
    ania.meet.nearbyBroadcast = (Map<String, dynamic> wave) =>
        ania.nearby.waveAround(wave, listen: Duration.zero);

    expect(await raiseAlarmFromShortcut(ania.meet), ShortcutAlarmResult.raised);
    expect(await ania.meet.pendingNearbyWave, 1);
    final (String device, Map<String, dynamic> wave) = ania.radio.waves.single;
    expect(device, 'mac-obcy');
    expect(wave['v'], kAlarmWaveVersion);
    expect(wave['id'], ania.meet.book.ownActiveAlarm!.id);
    // A stranger gets the wave for everyone: unsigned.
    expect(wave, isNot(contains('t')));
    expect(wave['at'], ania.clock);
    expect(AlarmWave.parse(wave)!.signed, isFalse);
    expect(
      ania.radio.scanning,
      isFalse,
      reason: 'it looked around only to send',
    );
    await ania.nearby.close();
  });

  test('in the app, the look around runs every few minutes only when allowed '
      'and unlocked, sees friends without signing anything and leaves other '
      'scans alone', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await ania.meet.shareNearbySecret('bob');
    // Her token and hint now, as her phone shows them (it changes every
    // slot, so it is shown again whenever the clock moves on).
    void herTokenNow() => bob.radio.around
      ..clear()
      ..add(<Object?, Object?>{
        'type': 'seen',
        'token': NearbyOwnKeys(
          ania.meet.book.nearbyPrivate!,
        ).advert(nearbySlot(bob.clock)),
        'rssi': -65,
        'device': 'mac-ania',
      });
    herTokenNow();
    bool unlocked = true;
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: bob.nearby,
      active: () => unlocked,
      lookFor: const Duration(milliseconds: 5),
      now: () => bob.clock,
    );
    // On by default; turned off: nothing.
    expect(bob.meet.book.nearbyBackgroundScan, isTrue);
    await bob.meet.setNearbyBackgroundScan(false);
    await keeper.start();

    bob.clock += kNearbyLookEvery.inMilliseconds;
    expect(await keeper.lookIfDue(), isFalse);
    expect(keeper.lastSkip, NearbyLookSkip.off);
    expect(bob.radio.scansStarted, 0);

    await bob.meet.setNearbyBackgroundScan(true);
    expect(await keeper.lookIfDue(), isFalse, reason: 'not due yet');
    bob.clock += kNearbyLookEvery.inMilliseconds;
    unlocked = false;
    expect(
      await keeper.lookIfDue(),
      isFalse,
      reason: 'the background service looks while the app is locked',
    );
    unlocked = true;
    // Low battery: skipped, and tried again only at the next turn.
    bob.radio.power = <Object?, Object?>{'battery': 10};
    expect(await keeper.lookIfDue(), isFalse);
    expect(keeper.lastSkip, NearbyLookSkip.lowBattery);
    bob.radio.power = <Object?, Object?>{'battery': 10, 'charging': true};
    expect(await keeper.lookIfDue(), isFalse, reason: 'not due yet');
    bob.clock += kNearbyLookEvery.inMilliseconds;
    herTokenNow();
    expect(await keeper.lookIfDue(), isTrue);
    expect(keeper.stats.looks, 1);
    expect(keeper.stats.skipped[NearbyLookSkip.lowBattery], 1);
    expect(bob.radio.scansStarted, 1);
    expect(bob.radio.lowPower, isTrue);
    expect(bob.radio.scanning, isFalse, reason: 'only a short look');
    expect(bob.nearby.scanning, isFalse);
    // Seen nearby is only a hint: nothing is signed in the background.
    expect(
      bob.nearby.people.map((NearbyPerson p) => p.friend),
      contains('ania'),
    );

    // "W pobliżu" opened during a look around: its scan stays on.
    bob.clock += kNearbyLookEvery.inMilliseconds;
    final Future<bool> look = keeper.lookIfDue();
    await Future<void>.delayed(const Duration(milliseconds: 2));
    await bob.nearby.startScanning();
    expect(await look, isTrue);
    expect(bob.nearby.scanning, isTrue);
    expect(bob.radio.scanning, isTrue);
    expect(bob.radio.lowPower, isFalse);

    // And while it is open, no look around at all.
    bob.clock += kNearbyLookEvery.inMilliseconds;
    expect(await keeper.lookIfDue(), isFalse);

    // Remembered; on in a new book and in a book from before the setting.
    expect(
      MeetBook.fromJson(
        jsonDecode(jsonEncode(bob.meet.book.toJson())),
      ).nearbyBackgroundScan,
      isTrue,
    );
    expect(
      MeetBook.fromJson(
        jsonDecode(
          jsonEncode((MeetBook()..nearbyBackgroundScan = false).toJson()),
        ),
      ).nearbyBackgroundScan,
      isFalse,
    );
    expect(
      MeetBook.fromJson(<String, dynamic>{'v': 1}).nearbyBackgroundScan,
      isTrue,
    );
    // How often and how long follow the person's choice.
    final NearbyKeeper chosen = NearbyKeeper(nearby: bob.nearby);
    expect(chosen.lookEvery, kNearbyLookEvery);
    expect(chosen.lookFor, kNearbyLookFor);
    await bob.meet.setNearbyLook(minutes: 15, seconds: 4);
    expect(chosen.lookEvery, const Duration(minutes: 15));
    expect(chosen.lookFor, const Duration(seconds: 4));
    await bob.meet.setNearbyLook(minutes: 7, seconds: 9);
    expect(
      chosen.lookEvery,
      const Duration(minutes: 15),
      reason: 'not offered',
    );
    await chosen.close();
    await keeper.close();
    await bob.nearby.close();
  });

  test('in the app, alarm waves the background service answers are left '
      'alone; other waves still arrive', () async {
    final _Net net = _Net();
    final _Phone bob = _Phone(net, 'bob', <String>[]);
    final List<Map<dynamic, dynamic>> got = <Map<dynamic, dynamic>>[];
    final List<(Object?, String)> alarms = <(Object?, String)>[];
    bob.nearby.otherWaveHandlers.add(got.add);
    bob.nearby.alarmWaveHandlers.add(
      (Map<dynamic, dynamic> json, String device) =>
          alarms.add((json['id'], device)),
    );
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'a1',
    }, elsewhere: true);
    bob.radio.hear(<String, dynamic>{'v': 99, 'id': 'inna'}, elsewhere: true);
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'a2',
    }, device: 'mac-a2');
    await _settle();
    expect(got.map((Map<dynamic, dynamic> m) => m['id']).toList(), <Object?>[
      'inna',
    ]);
    expect(alarms, <(Object?, String)>[('a2', 'mac-a2')]);
    await bob.nearby.close();
  });

  test('a running alarm is sent once more when the background service takes '
      'the network over; friends do not ring twice', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(
      net,
      'ania',
      <String>['bob'],
      close: <String>['bob'],
    );
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await ania.meet.raiseAlarm();
    expect(bob.shown, hasLength(1));
    final int sentBefore = ania.alarmsSent;

    await ania.meet.resendOwnAlarm();
    expect(ania.alarmsSent, sentBefore + 1);
    expect(bob.shown, hasLength(1));

    await ania.meet.endAlarm('');
    await ania.meet.resendOwnAlarm();
    expect(ania.alarmsSent, sentBefore + 2, reason: 'only the end went out');
  });
}
