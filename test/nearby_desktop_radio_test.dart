import 'dart:async';
import 'dart:typed_data';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/meet/desktop_nearby_radio.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_look_policy.dart';

/// A computer's Bluetooth that records what it is asked to do.
final class _Backend implements NearbyLeBackend {
  bool present = true;
  bool on = true;
  bool canShow = true;

  /// Every advert shown, in order (manufacturer data after the company id).
  final List<Uint8List> adverts = <Uint8List>[];
  int stops = 0;
  bool scanning = false;
  void Function(String device, Uint8List data, int rssi)? onSeen;
  final StreamController<bool> _powered = StreamController<bool>.broadcast();

  void switchTo(bool value) {
    on = value;
    _powered.add(value);
  }

  @override
  Stream<bool> get powered => _powered.stream;

  @override
  Future<({bool present, bool powered, bool canAdvertise})> state() async =>
      (present: present, powered: present && on, canAdvertise: canShow);

  @override
  Future<bool> advertise(Uint8List data) async {
    if (!canShow || !on) {
      return false;
    }
    adverts.add(Uint8List.fromList(data));
    return true;
  }

  @override
  Future<void> stopAdvertising() async => stops++;

  @override
  Future<bool> startScan(
    void Function(String device, Uint8List data, int rssi) onSeen,
  ) async {
    if (!present || !on) {
      return false;
    }
    this.onSeen = onSeen;
    scanning = true;
    return true;
  }

  @override
  Future<void> stopScan() async {
    scanning = false;
    onSeen = null;
  }
}

/// An advert (token and hint) whose bytes all are [b].
Uint8List _advert(int b) =>
    Uint8List.fromList(List<int>.filled(kNearbyAdvertBytes, b));

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  final int slotMs = kNearbySlot.inMilliseconds;
  const int firstSlot = 2950000;

  late _Backend backend;
  late int clock;
  late BackendNearbyRadio radio;
  late List<Map<Object?, Object?>> events;

  setUp(() {
    backend = _Backend();
    clock = firstSlot * slotMs + 1000;
    radio = BackendNearbyRadio(backend, now: () => clock);
    events = <Map<Object?, Object?>>[];
    radio.events.listen(events.add);
  });

  tearDown(() => radio.close());

  test('the advert is "ZN", the token and the hint; read back the same', () {
    final Uint8List advert = Uint8List.fromList(<int>[
      for (int i = 0; i < kNearbyAdvertBytes; i++) i + 1,
    ]);
    final Uint8List data = nearbyManufacturerData(advert);
    expect(data.length, 2 + kNearbyAdvertBytes);
    expect(data.sublist(0, 2), <int>[0x5A, 0x4E]);

    final ({Uint8List token, Uint8List hint})? read =
        parseNearbyManufacturerData(data);
    expect(read, isNotNull);
    expect(read!.token, advert.sublist(0, 16));
    expect(read.hint, advert.sublist(16));

    // Zen's links ("ZL"), other makers' data and cut adverts are not ours.
    expect(parseNearbyManufacturerData(<int>[0x5A, 0x4C, ...advert]), isNull);
    expect(parseNearbyManufacturerData(data.sublist(0, 10)), isNull);
    expect(parseNearbyManufacturerData(const <int>[]), isNull);
  });

  test('the state says what the computer can do; no hellos here', () async {
    Map<Object?, Object?> s = await radio.state();
    expect(s['supported'], isTrue);
    expect(s['enabled'], isTrue);
    expect(s['permitted'], isTrue);
    expect(s['canAdvertise'], isTrue);
    expect(s['canWave'], isFalse);
    // No battery on a computer's radio: the look around in the background
    // is allowed while Zen runs.
    expect(const NearbyLookPolicy().skipFor(s), isNull);

    // A Mac: looks, does not show.
    backend.canShow = false;
    s = await radio.state();
    expect(s['canAdvertise'], isFalse);
    expect(s['supported'], isTrue);

    // Bluetooth off.
    backend.on = false;
    s = await radio.state();
    expect(s['enabled'], isFalse);
    expect(await radio.requestEnable(), isFalse);

    // No Bluetooth LE at all.
    backend.present = false;
    s = await radio.state();
    expect(s['supported'], isFalse);
    expect(await radio.requestPermissions(), isFalse);

    expect(await radio.wave('AA:BB', Uint8List(4)), isFalse);
  });

  test('a single token is shown as it is', () async {
    expect(await radio.startAdvertising(_advert(7)), isTrue);
    expect(backend.adverts, hasLength(1));
    expect(backend.adverts.single, nearbyManufacturerData(_advert(7)));
    expect(radio.shown, _advert(7));

    await radio.stopAdvertising();
    expect(radio.shown, isNull);
    expect(backend.stops, greaterThan(0));
  });

  test('the schedule shows each slot its own token, then nothing', () async {
    final Uint8List schedule = Uint8List.fromList(<int>[
      ..._advert(1),
      ..._advert(2),
      ..._advert(3),
    ]);
    // Wrong sizes are refused.
    expect(
      await radio.startAdvertisingSchedule(firstSlot, Uint8List(5)),
      isFalse,
    );
    expect(
      await radio.startAdvertisingSchedule(firstSlot, Uint8List(0)),
      isFalse,
    );

    // Handed over one slot late: the second token straight away.
    clock = (firstSlot + 1) * slotMs + 5000;
    expect(await radio.startAdvertisingSchedule(firstSlot, schedule), isTrue);
    expect(radio.shown, _advert(2));
    expect(backend.adverts.last, nearbyManufacturerData(_advert(2)));

    clock = (firstSlot + 2) * slotMs + 600;
    await radio.rotateNow();
    expect(radio.shown, _advert(3));
    expect(backend.adverts.last, nearbyManufacturerData(_advert(3)));

    // Past the schedule: nothing is shown (and no stale token either).
    final int stopsBefore = backend.stops;
    clock = (firstSlot + 3) * slotMs + 600;
    expect(await radio.rotateNow(), isTrue);
    expect(radio.shown, isNull);
    expect(backend.stops, stopsBefore + 1);
    expect(backend.adverts, hasLength(2));

    // Before it starts: nothing either.
    clock = (firstSlot - 1) * slotMs;
    await radio.rotateNow();
    expect(radio.shown, isNull);
  });

  test('a computer that cannot show itself still looks around', () async {
    backend.canShow = false;
    expect(await radio.startAdvertising(_advert(9)), isFalse);
    expect(radio.shown, isNull);
    expect(await radio.startScan(), isTrue);
    expect(backend.scanning, isTrue);
  });

  test('what is seen around becomes "seen"; other adverts are left', () async {
    expect(await radio.startScan(), isTrue);
    // A second start does not start twice.
    expect(await radio.startScan(), isTrue);
    final Uint8List advert = Uint8List.fromList(<int>[
      for (int i = 0; i < kNearbyAdvertBytes; i++) 0x30 + i,
    ]);

    backend.onSeen!('11:22:33:44:55:66', nearbyManufacturerData(advert), -61);
    backend.onSeen!(
      'AA:AA:AA:AA:AA:AA',
      Uint8List.fromList(<int>[1, 2, 3]),
      -40,
    );
    backend.onSeen!(
      'BB:BB:BB:BB:BB:BB',
      Uint8List.fromList(<int>[0x5A, 0x4C, ...advert]),
      -40,
    );
    await _settle();

    final List<Map<Object?, Object?>> seen = events
        .where((Map<Object?, Object?> e) => e['type'] == 'seen')
        .toList();
    expect(seen, hasLength(1));
    expect(seen.single['device'], '11:22:33:44:55:66');
    expect(seen.single['rssi'], -61);
    expect(seen.single['token'], advert.sublist(0, 16));
    expect(seen.single['hint'], advert.sublist(16));

    // Stopped: nothing more.
    final void Function(String, Uint8List, int) stale = backend.onSeen!;
    await radio.stopScan();
    expect(backend.scanning, isFalse);
    stale('11:22:33:44:55:66', nearbyManufacturerData(advert), -50);
    await _settle();
    expect(
      events.where((Map<Object?, Object?> e) => e['type'] == 'seen'),
      hasLength(1),
    );
  });

  test('Bluetooth off and on again: told, the advert comes back', () async {
    await radio.startAdvertising(_advert(4));
    expect(backend.adverts, hasLength(1));

    backend.switchTo(false);
    await _settle();
    expect(events.last, <Object?, Object?>{'type': 'bluetooth', 'on': false});

    backend.switchTo(true);
    await _settle();
    await _settle();
    expect(events.last, <Object?, Object?>{'type': 'bluetooth', 'on': true});
    expect(backend.adverts, hasLength(2));
    expect(backend.adverts.last, nearbyManufacturerData(_advert(4)));
  });

  test('BlueZ manufacturer data: Zen\'s advert is found under 0xFFFF', () {
    final Uint8List data = nearbyManufacturerData(_advert(5));
    DBusValue manufacturer(int company, List<int> bytes) => DBusVariant(
      DBusDict(DBusSignature('q'), DBusSignature('v'), <DBusValue, DBusValue>{
        DBusUint16(company): DBusVariant(DBusArray.byte(bytes)),
      }),
    );

    expect(bluezNearbyData(manufacturer(0xFFFF, data)), data);
    // Another maker's id, Zen's links, nothing at all.
    expect(bluezNearbyData(manufacturer(0x004C, data)), isNull);
    expect(
      bluezNearbyData(manufacturer(0xFFFF, <int>[0x5A, 0x4C, ..._advert(5)])),
      isNull,
    );
    expect(bluezNearbyData(null), isNull);
    expect(bluezNearbyData(const DBusString('x')), isNull);
  });

  test('in tests the platform radio is never the computer\'s Bluetooth', () {
    expect(platformNearbyRadio(), isNot(isA<BackendNearbyRadio>()));
  });
}
