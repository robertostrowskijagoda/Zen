import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/nearby_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

final class _Radio implements NearbyRadio {
  _Radio({required this.on});

  final bool on;
  final List<bool> scans = <bool>[];
  bool scanning = false;
  Uint8List? advertised;

  @override
  Stream<Map<Object?, Object?>> get events =>
      const Stream<Map<Object?, Object?>>.empty();

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
    advertised = on ? token : null;
    return on;
  }

  @override
  Future<bool> startAdvertisingSchedule(
    int firstSlot,
    Uint8List adverts,
  ) async => on;

  @override
  Future<void> stopAdvertising() async => advertised = null;

  @override
  Future<bool> startScan({bool lowPower = false}) async {
    scans.add(lowPower);
    return scanning = on;
  }

  @override
  Future<void> stopScan() async => scanning = false;

  @override
  Future<bool> wave(String device, Uint8List data) async => false;
}

final class _Net implements NearbyNetwork {
  Uint8List? adverts;
  bool looking = false;
  List<(Uint8List, int)> around = const <(Uint8List, int)>[];

  @override
  void update({
    required int firstSlot,
    required Uint8List? adverts,
    required bool looking,
  }) {
    this.adverts = adverts;
    this.looking = looking;
  }

  @override
  List<(Uint8List, int)> heard() => around;
}

final class _Host implements MeetHost {
  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>[];

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) => false;

  @override
  bool isSelf(String a) => a == 'bob';

  @override
  String nameOf(String a) => a;

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

Future<(NearbyService, _Radio, _Net)> _open(
  WidgetTester tester, {
  required bool bluetooth,
}) async {
  final MeetService meet = MeetService(
    host: _Host(),
    store: MeetStore(MemoryLedgerDisk()),
  );
  final _Radio radio = _Radio(on: bluetooth);
  final _Net net = _Net();
  final NearbyService nearby = NearbyService(
    radio: radio,
    network: net,
    meet: meet,
    ownAddress: () => 'bob',
    sendMesh: (String to, Map<String, dynamic> p) async {},
    frames: const Stream<SignalTransportFrame>.empty(),
  );
  final EncounterLog log = EncounterLog(disk: MemoryLedgerDisk());
  addTearDown(log.dispose);
  tester.view.physicalSize = const Size(720, 6000);
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        meetServiceProvider.overrideWithValue(meet),
        nearbyServiceProvider.overrideWithValue(nearby),
        encounterLogProvider.overrideWithValue(log),
        ledgerNodeProvider.overrideWithValue(null),
      ],
      child: MaterialApp(theme: ZenTheme.light(), home: const NearbyScreen()),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  return (nearby, radio, net);
}

/// Leaves the screen and stops what it started (the service's own timers
/// go with it).
Future<void> _close(WidgetTester tester, NearbyService nearby) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  await tester.runAsync(nearby.close);
}

void main() {
  testWidgets('the screen scans in full (not batched) and shows this phone', (
    WidgetTester tester,
  ) async {
    final (NearbyService nearby, _Radio radio, _Net net) = await _open(
      tester,
      bluetooth: true,
    );
    expect(radio.scans, <bool>[false], reason: 'a full scan, not low power');
    expect(radio.advertised, isNotNull);
    expect(net.looking, isTrue);
    expect(net.adverts, isNotNull);
    expect(find.text('Szukam'), findsOneWidget);

    await _close(tester, nearby);
    expect(radio.scanning, isFalse);
    expect(net.looking, isFalse);
  });

  testWidgets('with Bluetooth off it still looks on the same Wi-Fi', (
    WidgetTester tester,
  ) async {
    final (NearbyService nearby, _Radio radio, _Net net) = await _open(
      tester,
      bluetooth: false,
    );
    expect(nearby.scanning, isFalse);
    expect(net.looking, isTrue);
    expect(net.adverts, isNotNull, reason: 'shown on the Wi-Fi');
    expect(find.text('Szukam'), findsOneWidget);
    expect(
      find.textContaining('tylko w tej samej sieci Wi-Fi'),
      findsOneWidget,
    );

    final Uint8List stranger = Uint8List.fromList(
      List<int>.generate(kNearbyAdvertBytes, (int i) => 100 + i),
    );
    net.around = <(Uint8List, int)>[
      (stranger, DateTime.now().millisecondsSinceEpoch),
    ];
    await tester.pump(kNearbyNetworkRead);
    await tester.pump();
    final String pseudonym = nearbyPseudonym(stranger.sublist(0, 16));
    expect(find.text(pseudonym), findsOneWidget);
    expect(find.text('w tej samej sieci'), findsOneWidget);
    // Nobody is written to over the Wi-Fi.
    expect(find.text('Napisz'), findsNothing);

    await _close(tester, nearby);
    expect(net.looking, isFalse);
  });
}
