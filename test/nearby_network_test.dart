import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/runtime/local_link.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// One Wi-Fi: what a visible phone shows, the phones looking around hear
/// (as the bridge's LAN beacons do, lan_nearby.go).
final class _WiFi {
  final List<_Net> nets = <_Net>[];
}

final class _Net implements NearbyNetwork {
  _Net(this.wifi, this.clock) {
    wifi.nets.add(this);
  }

  final _WiFi wifi;
  final int Function() clock;
  int firstSlot = 0;
  Uint8List? adverts;
  bool looking = false;
  int updates = 0;

  @override
  void update({
    required int firstSlot,
    required Uint8List? adverts,
    required bool looking,
  }) {
    this.firstSlot = firstSlot;
    this.adverts = adverts;
    this.looking = looking;
    updates++;
  }

  /// What the bridge shows now: the advert of the slot it is in.
  Uint8List? get shown {
    final Uint8List? all = adverts;
    if (all == null) {
      return null;
    }
    final int i = nearbySlot(clock()) - firstSlot;
    if (i < 0 || i >= all.length ~/ kNearbyAdvertBytes) {
      return null;
    }
    return Uint8List.sublistView(
      all,
      i * kNearbyAdvertBytes,
      (i + 1) * kNearbyAdvertBytes,
    );
  }

  @override
  List<(Uint8List, int)> heard() => <(Uint8List, int)>[
    if (looking)
      for (final _Net other in wifi.nets)
        if (other != this && other.shown != null) (other.shown!, clock()),
  ];
}

/// Bluetooth: off unless [on]; what is shown and seen goes through
/// [broadcast].
final class _Radio implements NearbyRadio {
  _Radio(this.device);

  final String device;
  bool on = false;
  Uint8List? advertised;
  final List<String> wroteTo = <String>[];
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': on,
    'permitted': true,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestEnable() async => on;

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    if (!on) {
      return false;
    }
    advertised = token;
    return true;
  }

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async => on;

  @override
  Future<void> stopAdvertising() async => advertised = null;

  @override
  Future<bool> startScan({bool lowPower = false}) async => on;

  @override
  Future<void> stopScan() async {}

  /// [other] sees this phone's advert over Bluetooth.
  void broadcastTo(_Radio other, {int rssi = -55}) =>
      other._events.add(<Object?, Object?>{
        'type': 'seen',
        'token': advertised,
        'rssi': rssi,
        'device': device,
      });

  @override
  Future<bool> wave(String device, Uint8List data) async {
    wroteTo.add(device);
    return on;
  }
}

final class _Phone implements MeetHost {
  _Phone(_WiFi wifi, this.mesh, this.address, this.friendList) {
    mesh[address] = this;
    radio = _Radio('mac-$address');
    net = _Net(wifi, () => clock);
    meet = MeetService(
      host: this,
      store: MeetStore(MemoryLedgerDisk()),
      now: () => clock,
    );
    nearby = NearbyService(
      radio: radio,
      network: net,
      meet: meet,
      ownAddress: () => address,
      sendMesh: send,
      frames: frames.stream,
      now: () => clock,
    )..networkEvery = const Duration(milliseconds: 5);
  }

  final Map<String, _Phone> mesh;
  final String address;
  final List<String> friendList;
  late final _Radio radio;
  late final _Net net;
  late final MeetService meet;
  late final NearbyService nearby;
  int clock = 1700000000000;
  final StreamController<SignalTransportFrame> frames =
      StreamController<SignalTransportFrame>.broadcast();

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {
    final _Phone? other = mesh[to];
    if (other == null) {
      return;
    }
    final SignalTransportFrame f = SignalTransportFrame(
      from: address,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
      receivedAtMillis: 0,
    );
    await other.meet.handle(f);
    other.frames.add(f);
  }

  @override
  List<String> friends() => friendList;

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => friendList.contains(a);

  @override
  bool isSelf(String a) => a == address;

  @override
  String nameOf(String a) => a.toUpperCase();

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

/// Waits (in real time: the network is read on a timer) until [done].
Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 400 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('on the same Wi-Fi a friend is recognised and a stranger gets a '
      'pseudonym, also with Bluetooth off', () async {
    final _WiFi wifi = _WiFi();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final _Phone ania = _Phone(wifi, mesh, 'ania', <String>['bob']);
    final _Phone bob = _Phone(wifi, mesh, 'bob', <String>['ania']);
    final _Phone obcy = _Phone(wifi, mesh, 'obcy', <String>[]);
    addTearDown(() async {
      for (final _Phone p in <_Phone>[ania, bob, obcy]) {
        await p.nearby.close();
      }
    });

    await ania.meet.shareNearbySecret('bob');
    expect(await ania.nearby.setVisible(true), isFalse, reason: 'no radio');
    await obcy.nearby.setVisible(true);

    // The network shows exactly the radio's advert of this slot, worked out
    // for the day ahead (the bridge moves on by itself).
    final int slot = nearbySlot(ania.clock);
    final NearbyOwnKeys keys = NearbyOwnKeys(ania.meet.book.nearbyPrivate!);
    expect(ania.net.firstSlot, slot);
    expect(
      ania.net.adverts,
      hasLength(kNearbyNetworkSlots * kNearbyAdvertBytes),
    );
    expect(ania.net.shown, keys.advert(slot));
    expect(ania.net.looking, isFalse, reason: 'shown, not looking');

    expect(await bob.nearby.startScanning(), isFalse, reason: 'no radio');
    expect(bob.nearby.scanning, isFalse);
    expect(bob.nearby.looking, isTrue);
    expect(bob.net.looking, isTrue);
    await _until(() => bob.nearby.people.length == 2);

    final List<NearbyPerson> seen = bob.nearby.people;
    expect(seen, hasLength(2));
    expect(seen.first.friend, 'ania', reason: 'friends first');
    expect(seen.first.overBluetooth, isFalse);
    expect(seen.first.distance, 'w tej samej sieci');
    expect(seen.last.friend, isNull);
    expect(seen.last.pseudonym, obcy.nearby.myPseudonym);
    expect(
      seen.map((NearbyPerson p) => p.token),
      isNot(contains(bob.nearby.myToken)),
    );

    // 15 minutes later Ania's token on the network is a new one, without
    // her app doing anything; Bob still knows her.
    final int updates = ania.net.updates;
    for (final _Phone p in <_Phone>[ania, bob, obcy]) {
      p.clock += 15 * 60 * 1000;
    }
    final String newToken = nearbyHex(ania.net.shown!.sublist(0, 16));
    expect(newToken, isNot(seen.first.token));
    await _until(
      () => bob.nearby.people.any((NearbyPerson p) => p.token == newToken),
    );
    expect(
      bob.nearby.people.singleWhere((NearbyPerson p) => p.token == newToken),
      isA<NearbyPerson>().having(
        (NearbyPerson p) => p.friend,
        'friend',
        'ania',
      ),
    );
    expect(ania.net.updates, updates);

    await bob.nearby.stopScanning();
    expect(bob.net.looking, isFalse);
    expect(bob.nearby.looking, isFalse);
  });

  test('a hidden phone is not on the network, and nobody there is written '
      'to', () async {
    final _WiFi wifi = _WiFi();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final _Phone ania = _Phone(wifi, mesh, 'ania', <String>[]);
    final _Phone bob = _Phone(wifi, mesh, 'bob', <String>[]);
    addTearDown(() async {
      await ania.nearby.close();
      await bob.nearby.close();
    });
    await ania.nearby.setVisible(true);
    bob.radio.on = true;
    await bob.nearby.startScanning();
    await _until(() => bob.nearby.people.isNotEmpty);
    final NearbyPerson there = bob.nearby.people.single;
    expect(there.overBluetooth, isFalse);

    // A hello goes over Bluetooth only: none to a phone only on the Wi-Fi.
    expect(await bob.nearby.wave(there, 'Cześć!'), isNull);
    expect(await bob.nearby.waveAll(<String, dynamic>{'v': 99}), 0);
    expect(bob.radio.wroteTo, isEmpty);

    await ania.nearby.setVisible(false);
    expect(ania.net.adverts, isNull);
    expect(ania.net.shown, isNull);
  });

  test('a phone seen over Bluetooth and on the Wi-Fi is one person who can '
      'be written to', () async {
    final _WiFi wifi = _WiFi();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final _Phone ania = _Phone(wifi, mesh, 'ania', <String>[]);
    final _Phone bob = _Phone(wifi, mesh, 'bob', <String>[]);
    addTearDown(() async {
      await ania.nearby.close();
      await bob.nearby.close();
    });
    ania.radio.on = true;
    bob.radio.on = true;
    await ania.nearby.setVisible(true);
    await bob.nearby.startScanning();
    await _until(() => bob.nearby.people.isNotEmpty);
    expect(bob.nearby.people.single.overBluetooth, isFalse);
    ania.radio.broadcastTo(bob.radio, rssi: -50);
    await _until(() => bob.nearby.people.single.overBluetooth);

    final NearbyPerson both = bob.nearby.people.single;
    expect(both.device, 'mac-ania');
    expect(both.distance, 'blisko');
    expect(both.networkSeenAt, greaterThan(0));
    expect(await bob.nearby.waveAll(<String, dynamic>{'v': 99}), 1);
  });

  test('a short look in the background looks on the network too and stops '
      'with it', () async {
    final _WiFi wifi = _WiFi();
    final Map<String, _Phone> mesh = <String, _Phone>{};
    final _Phone ania = _Phone(wifi, mesh, 'ania', <String>[]);
    final _Phone bob = _Phone(wifi, mesh, 'bob', <String>[]);
    addTearDown(() async {
      await ania.nearby.close();
      await bob.nearby.close();
    });
    await ania.nearby.setVisible(true);
    bob.radio.on = true;
    final Future<bool> look = bob.nearby.scanWindow(
      const Duration(milliseconds: 60),
    );
    await Future<void>.delayed(Duration.zero);
    expect(bob.net.looking, isTrue);
    expect(await look, isTrue);
    expect(bob.net.looking, isFalse);
    expect(bob.nearby.people, hasLength(1));

    // Bluetooth off: no look in the background at all.
    bob.radio.on = false;
    expect(
      await bob.nearby.scanWindow(const Duration(milliseconds: 10)),
      isFalse,
    );
    expect(bob.net.looking, isFalse);
  });

  test('the network adapter hands the adverts to the local links and reads '
      'what they heard', () {
    final ValueNotifier<LocalNearbyAdverts?> nearby =
        ValueNotifier<LocalNearbyAdverts?>(null);
    addTearDown(nearby.dispose);
    LocalLinksStatus status = LocalLinksStatus.empty;
    final LocalLinksNearbyNetwork network = LocalLinksNearbyNetwork(
      nearby: nearby,
      status: () => status,
    );
    final Uint8List adverts = Uint8List(2 * kNearbyAdvertBytes);
    network.update(firstSlot: 7, adverts: adverts, looking: false);
    expect(nearby.value, LocalNearbyAdverts(firstSlot: 7, adverts: adverts));
    network.update(firstSlot: 7, adverts: null, looking: true);
    expect(nearby.value?.looking, isTrue);
    expect(nearby.value?.adverts, isNull);
    network.update(firstSlot: 7, adverts: null, looking: false);
    expect(nearby.value, isNull, reason: 'neither shown nor looking');

    final String hex = List<String>.filled(kNearbyAdvertBytes, 'ab').join();
    status = LocalLinksStatus.fromJson(<String, dynamic>{
      'lan': <String, dynamic>{'on': true, 'running': true},
      'nearby': <Object?>[
        <String, Object?>{'advert': hex, 'at': 1234},
        <String, Object?>{'advert': 'zz', 'at': 1},
        'junk',
      ],
    });
    final List<(Uint8List, int)> heard = network.heard();
    expect(heard, hasLength(1));
    expect(heard.single.$1, List<int>.filled(kNearbyAdvertBytes, 0xab));
    expect(heard.single.$2, 1234);
  });
}
