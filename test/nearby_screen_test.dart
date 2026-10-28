import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/encounters_section.dart';
import 'package:zen/src/features/meet/presentation/met_level_prompt.dart';
import 'package:zen/src/features/meet/presentation/nearby_screen.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

final class _Radio implements NearbyRadio {
  _Radio({required this.on, this.locationOff = false});

  final bool on;

  /// An Android 11 phone with location switched off.
  final bool locationOff;
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
    if (locationOff) ...<Object?, Object?>{
      'needsLocation': true,
      'locationOn': false,
    },
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
  bool locationOff = false,
}) async {
  final MeetService meet = MeetService(
    host: _Host(),
    store: MeetStore(MemoryLedgerDisk()),
  );
  final _Radio radio = _Radio(on: bluetooth, locationOff: locationOff);
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
    expect(find.byKey(const Key('nearby-location-off')), findsNothing);

    await _close(tester, nearby);
    expect(radio.scanning, isFalse);
    expect(net.looking, isFalse);
  });

  testWidgets('where scans need location and it is off, the screen says so', (
    WidgetTester tester,
  ) async {
    final (NearbyService nearby, _, _) = await _open(
      tester,
      bluetooth: true,
      locationOff: true,
    );
    expect(find.byKey(const Key('nearby-location-off')), findsOneWidget);
    expect(find.text('Włącz lokalizację'), findsOneWidget);
    await _close(tester, nearby);
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

  testWidgets('"Spotkani?" for a close friend starts at "Bliski": confirming '
      'the meeting keeps the level they have', (WidgetTester tester) async {
    FriendLevel? chosen;
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => chosen = await showDialog<FriendLevel>(
              context: context,
              builder: (BuildContext context) => const MetLevelDialog(
                name: 'Ania',
                initial: FriendLevel.close,
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('met-level-close')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('met-level-save')));
    await tester.pumpAndSettle();
    expect(chosen, FriendLevel.close);
  });

  testWidgets('"Mijani": one friend passed with two of their devices is one '
      'row under one name', (WidgetTester tester) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EncounterLog log = EncounterLog(
      disk: MemoryLedgerDisk(),
      flushAfter: const Duration(days: 1),
    );
    log
      ..saw(token: 'a', at: now - 60000, friend: 'ania')
      ..saw(token: 'b', at: now - 30000, friend: 'ania2');
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: EncountersSection(
              log: log,
              nameOf: (String a) => a == 'ania' ? 'Ania' : 'Ktoś',
              friendOf: (String a) => a == 'ania2' ? 'ania' : a,
              hasMet: (String a) => false,
              onOpen: (String a) {},
              onMet: (String a) {},
              onPlace: (EncounterPlace p) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Ania'), findsOneWidget);
    expect(find.text('Ktoś'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    log.dispose();
  });
}
