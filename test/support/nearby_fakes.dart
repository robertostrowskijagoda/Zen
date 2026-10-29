import 'dart:async';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// The air between [FakeNearbyRadio]s: what one shows, the scanning others
/// see.
final class FakeAir {
  final List<FakeNearbyRadio> radios = <FakeNearbyRadio>[];
}

/// A Bluetooth radio that only shows its token and sees the others'.
final class FakeNearbyRadio implements NearbyRadio {
  FakeNearbyRadio(this.air, this.device) {
    air.radios.add(this);
  }

  final FakeAir air;

  /// The Bluetooth device it is (one per phone or computer).
  final String device;
  Uint8List? advertised;
  bool scanning = false;
  final StreamController<Map<Object?, Object?>> _events =
      StreamController<Map<Object?, Object?>>.broadcast();

  @override
  Stream<Map<Object?, Object?>> get events => _events.stream;

  @override
  Future<Map<Object?, Object?>> state() async => <Object?, Object?>{
    'supported': true,
    'enabled': true,
    'permitted': true,
  };

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<bool> requestEnable() async => true;

  @override
  Future<bool> startAdvertising(Uint8List token) async {
    advertised = token;
    return true;
  }

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async => true;

  @override
  Future<void> stopAdvertising() async => advertised = null;

  @override
  Future<bool> startScan({bool lowPower = false}) async => scanning = true;

  @override
  Future<void> stopScan() async => scanning = false;

  @override
  Future<bool> wave(String device, Uint8List data) async => false;

  /// Everyone scanning sees this radio's token.
  void broadcast({int rssi = -55}) {
    for (final FakeNearbyRadio other in air.radios) {
      if (other != this && other.scanning && advertised != null) {
        other._events.add(<Object?, Object?>{
          'type': 'seen',
          'token': advertised,
          'rssi': rssi,
          'device': device,
        });
      }
    }
  }
}

/// One device with Zen's meeting and nearby services on a [FakeAir]; its
/// own clock, its friends as listed.
final class NearbyPhone implements MeetHost {
  NearbyPhone(this.air, this.address, this.friendList) {
    radio = FakeNearbyRadio(air, 'mac-$address');
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
      now: () => clock,
    );
  }

  final FakeAir air;
  final String address;
  final List<String> friendList;
  late final FakeNearbyRadio radio;
  late final MeetService meet;
  late final NearbyService nearby;
  int clock = 1000000;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

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

/// Lets the radio events and the services' answers to them run.
Future<void> settleNearby() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
