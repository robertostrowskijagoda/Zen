import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_keeper.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// A Bluetooth radio that records what it is asked to do.
final class _Radio implements NearbyRadio {
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();
  bool permitted = true;
  bool enabled = true;
  Uint8List? advertised;
  bool scanning = false;
  bool? lowPower;
  int scansStarted = 0;

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
  };

  @override
  Future<bool> requestPermissions() async => permitted;

  @override
  Future<bool> requestEnable() async => enabled;

  /// Bluetooth switched on or off on this phone.
  void bluetooth(bool on) {
    enabled = on;
    _events.add(<Object?, Object?>{'type': 'bluetooth', 'on': on});
  }

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    advertised = token;
    return true;
  }

  @override
  Future<void> stopAdvertising() async => advertised = null;

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

  /// A phone nearby ([device]) waved [json] at this one. [elsewhere]: the
  /// other side of the app answers alarm waves now.
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
    );
    nearby = NearbyService(
      radio: radio,
      meet: meet,
      ownAddress: () => address,
      sendMesh: send,
      frames: const Stream<SignalTransportFrame>.empty(),
      onMet: (String friend) async => met.add(friend),
      now: () => clock,
    );
  }

  /// Friends this phone signed "met in person" for (§6.2).
  final List<String> met = <String>[];

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

void main() {
  test('with "Alarm do pobliża" on, the background service shows the phone '
      'and a friend\'s alarm wave rings like one from the network', () async {
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

    final List<bool> announced = <bool>[];
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: bob.nearby,
      inService: true,
      announceAlarmReceiver: (bool on) async => announced.add(on),
      now: () => bob.clock,
    );
    await keeper.start();
    expect(keeper.receivesAlarms, isTrue);
    expect(announced, <bool>[true]);
    expect(
      bob.radio.advertised,
      isNotNull,
      reason: 'phones around wave only at phones they see',
    );
    expect(bob.meet.nearbyBroadcast, isNotNull);

    final AlarmRecord alarm = await ania.meet.raiseAlarm(note: 'pomocy');
    expect(bob.meet.book.alarm(alarm.id), isNull);
    // The wave for everyone is unsigned; Bob, who has her keys for him
    // alone, gets one signed for the pair (S6).
    expect(ania.meet.alarmWave(alarm), isNot(contains('t')));
    final Map<String, dynamic> wave = ania.meet.alarmWave(alarm, to: 'bob');
    expect(wave['v'], kAlarmWaveVersion);
    expect(wave['m'], isA<String>());
    final String aniaToken = wave['t'] as String;
    bob.radio.hear(wave, device: 'mac-ania');
    await _settle();
    await keeper.pendingWave;
    final AlarmRecord heard = bob.meet.book.alarm(alarm.id)!;
    expect(heard.from, 'ania');
    expect(heard.nearby, isTrue);
    expect(heard.isActive, isTrue);
    expect(bob.shown.single.isRingingCall, isTrue);
    expect(bob.shown.single.category, RuntimeSystemNotificationCategory.alarm);
    expect(bob.shown.single.title, contains('ANIA'));

    // Heard again (the same wave from another try): it rings once.
    bob.radio.hear(wave, device: 'mac-ania');
    await _settle();
    await keeper.pendingWave;
    expect(bob.shown, hasLength(1));

    // Someone who saw her wave knows her token, not her key: a wave
    // with a made-up signature never rings, it is a quiet unchecked note.
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'falszywy1',
      'at': bob.clock,
      't': aniaToken,
      'm': '0' * 32,
    }, device: 'mac-obcy');
    await _settle();
    await keeper.pendingWave;
    expect(bob.meet.book.alarm('falszywy1'), isNull);
    expect(bob.shown, hasLength(2));
    expect(bob.shown.last.title, contains('Niesprawdzone'));
    expect(bob.shown.last.isRingingCall, isFalse);
    expect(
      bob.shown.last.category,
      isNot(RuntimeSystemNotificationCategory.alarm),
    );

    // The same phone again within 10 minutes: nothing more.
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'falszywy2',
      'at': bob.clock,
    }, device: 'mac-obcy');
    await _settle();
    await keeper.pendingWave;
    expect(bob.shown, hasLength(2));

    // While the app answers alarm waves itself, the service leaves them.
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'obcy2',
      'at': bob.clock,
    }, elsewhere: true);
    await _settle();
    expect(bob.shown, hasLength(2));

    await keeper.close();
    expect(announced, <bool>[true, false]);
    expect(bob.meet.nearbyBroadcast, isNull);
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'obcy3',
      'at': bob.clock,
    });
    await _settle();
    expect(bob.shown, hasLength(2));
    await bob.nearby.close();
  });

  test('without "Alarm do pobliża", hidden, or without Bluetooth permission '
      'the background service does not answer alarm waves; while visible '
      'it shows the phone all the time', () async {
    final _Net net = _Net();
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    // Neither the look around nor alarms: visible still means shown (cheap
    // low-power advertising).
    await bob.meet.setNearbyBackgroundScan(false);
    final List<bool> announced = <bool>[];
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: bob.nearby,
      inService: true,
      announceAlarmReceiver: (bool on) async => announced.add(on),
      now: () => bob.clock,
    );
    await keeper.start();
    expect(keeper.receivesAlarms, isFalse);
    expect(bob.radio.advertised, isNotNull);
    bob.radio.hear(<String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': 'x1',
      'at': bob.clock,
    });
    await _settle();
    expect(bob.shown, isEmpty);

    // Hidden stays hidden, even with the option on.
    await bob.meet.setNearbyVisible(false);
    await bob.meet.setAlarmNearby(true);
    await keeper.refresh();
    expect(keeper.receivesAlarms, isFalse);
    expect(bob.radio.advertised, isNull);

    // No Activity in the background to ask for Bluetooth: nothing then.
    await bob.meet.setNearbyVisible(true);
    bob.radio.permitted = false;
    await keeper.refresh();
    expect(keeper.receivesAlarms, isFalse);
    expect(bob.radio.advertised, isNull);

    bob.radio.permitted = true;
    await keeper.refresh();
    expect(keeper.receivesAlarms, isTrue);
    expect(bob.radio.advertised, isNotNull);
    expect(announced, <bool>[true]);

    // Turned off in the app: the next look at the settings lets go of the
    // alarm waves; the phone stays visible.
    await bob.meet.setAlarmNearby(false);
    await keeper.refresh();
    expect(keeper.receivesAlarms, isFalse);
    expect(bob.radio.advertised, isNotNull);
    expect(announced, <bool>[true, false]);
    await keeper.close();
    await bob.nearby.close();
  });

  test('Bluetooth switched off and on again: the background service shows '
      'the phone again by itself', () async {
    final _Net net = _Net();
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await bob.meet.setAlarmNearby(true);
    bob.radio.enabled = false;
    final List<bool> announced = <bool>[];
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: bob.nearby,
      inService: true,
      announceAlarmReceiver: (bool on) async => announced.add(on),
      now: () => bob.clock,
    );
    await keeper.start();
    expect(bob.radio.advertised, isNull);
    expect(keeper.receivesAlarms, isFalse);

    bob.radio.bluetooth(true);
    await _settle();
    expect(bob.radio.advertised, isNotNull);
    expect(keeper.receivesAlarms, isTrue);

    bob.radio.bluetooth(false);
    await _settle();
    expect(bob.radio.advertised, isNull);
    expect(keeper.receivesAlarms, isFalse);
    expect(announced, <bool>[true, false]);

    await keeper.close();
    bob.radio.bluetooth(true);
    await _settle();
    expect(bob.radio.advertised, isNull, reason: 'closed: nothing applied');
    await bob.nearby.close();
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
    expect(bob.shown.last.title, contains('PIN-em panicznym'));

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

  test('an alarm raised in the background service goes to phones nearby '
      'too, when chosen', () async {
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
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: ania.nearby,
      inService: true,
      waveListen: Duration.zero,
      now: () => ania.clock,
    );
    await keeper.start();

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
    await keeper.close();
    await ania.nearby.close();
  });

  test('the look around runs every few minutes only when allowed, marks '
      'friends met in person and leaves other scans alone', () async {
    final _Net net = _Net();
    final _Phone ania = _Phone(net, 'ania', <String>['bob']);
    final _Phone bob = _Phone(net, 'bob', <String>['ania']);
    await ania.meet.shareNearbySecret('bob');
    bob.radio.around.add(<Object?, Object?>{
      'type': 'seen',
      // Her token and hint now (S6), as her phone shows them.
      'token': NearbyOwnKeys(
        ania.meet.book.nearbyPrivate!,
      ).advert(nearbySlot(bob.clock)),
      'rssi': -65,
      'device': 'mac-ania',
    });
    bool onScreen = true;
    final NearbyKeeper keeper = NearbyKeeper(
      nearby: bob.nearby,
      inService: false,
      active: () => onScreen,
      lookFor: const Duration(milliseconds: 5),
      now: () => bob.clock,
    );
    // Off by default (scanning is for the "W pobliżu" screen): nothing.
    expect(bob.meet.book.nearbyBackgroundScan, isFalse);
    await keeper.start();

    bob.clock += kNearbyLookEvery.inMilliseconds;
    expect(await keeper.lookIfDue(), isFalse);
    expect(bob.radio.scansStarted, 0);

    await bob.meet.setNearbyBackgroundScan(true);
    expect(await keeper.lookIfDue(), isFalse, reason: 'not due yet');
    bob.clock += kNearbyLookEvery.inMilliseconds;
    onScreen = false;
    expect(
      await keeper.lookIfDue(),
      isFalse,
      reason: 'the background service looks while the app is away',
    );
    onScreen = true;
    expect(await keeper.lookIfDue(), isTrue);
    expect(bob.radio.scansStarted, 1);
    expect(bob.radio.lowPower, isTrue);
    expect(bob.radio.scanning, isFalse, reason: 'only a short look');
    expect(bob.nearby.scanning, isFalse);
    expect(bob.met, contains('ania'));

    // "W pobliżu" opened during a look around: its scan stays on.
    bob.clock += kNearbyLookEvery.inMilliseconds;
    final Future<bool> look = keeper.lookIfDue();
    await Future<void>.delayed(Duration.zero);
    await bob.nearby.startScanning();
    expect(await look, isTrue);
    expect(bob.nearby.scanning, isTrue);
    expect(bob.radio.scanning, isTrue);
    expect(bob.radio.lowPower, isFalse);

    // And while it is open, no look around at all.
    bob.clock += kNearbyLookEvery.inMilliseconds;
    expect(await keeper.lookIfDue(), isFalse);

    // Remembered; off in a new book and in a book from before the setting.
    expect(
      MeetBook.fromJson(
        jsonDecode(jsonEncode(bob.meet.book.toJson())),
      ).nearbyBackgroundScan,
      isTrue,
    );
    expect(
      MeetBook.fromJson(
        jsonDecode(jsonEncode(MeetBook().toJson())),
      ).nearbyBackgroundScan,
      isFalse,
    );
    expect(
      MeetBook.fromJson(<String, dynamic>{'v': 1}).nearbyBackgroundScan,
      isFalse,
    );
    await bob.meet.setNearbyBackgroundScan(false);
    expect(
      MeetBook.fromJson(
        jsonDecode(jsonEncode(bob.meet.book.toJson())),
      ).nearbyBackgroundScan,
      isFalse,
    );
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
