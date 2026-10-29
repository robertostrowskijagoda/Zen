// Owner report R5-#17 (28.10.2026, after 1.14.0): "spotkani?" shown for someone who is already a friend.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in meet_service.dart / nearby.dart (every device of a friend is
// that friend), encounters_section.dart and nearby_screen.dart (a friend's
// other device is the friend, met or not; no invitation to a friend) and
// met_level_prompt.dart (confirming keeps the level), 0fe709dd; guarded by
// the tests below, test/nearby_test.dart and test/nearby_screen_test.dart.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/encounters_section.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import '../support/nearby_fakes.dart';

void main() {
  test('R5-#17: a friend nearby is that friend by each of their devices, '
      'never someone new to meet', () async {
    final FakeAir air = FakeAir();
    final NearbyPhone ania = NearbyPhone(air, 'ania', <String>['bob']);
    // Ania's computer, an own device of her account.
    final NearbyPhone laptop = NearbyPhone(air, 'ania2', <String>['bob']);
    final NearbyPhone bob = NearbyPhone(air, 'bob', <String>['ania']);
    await ania.meet.nearbyPrivateKey();
    await laptop.meet.nearbyPrivateKey();
    Future<void> keysOf(NearbyPhone device) => bob.meet.handle(
      SignalTransportFrame(
        from: 'ania',
        device: device == ania ? null : device.address,
        payload: <String, dynamic>{
          'type': MeetTypes.nearbyKey,
          'z': device.meet.nearbyKeysFor('bob'),
        },
        receivedAtMillis: 0,
      ),
    );
    // Her phone's keys, then the computer's (the account routing hands
    // them over as from Ania). Before, the second replaced the first.
    await keysOf(ania);
    await keysOf(laptop);
    await bob.nearby.startScanning();

    // Only her phone is around.
    await ania.nearby.setVisible(true);
    ania.radio.broadcast(rssi: -60);
    await settleNearby();
    expect(bob.nearby.people.single.friend, 'ania');

    // Later only her computer.
    bob.clock = ania.clock = laptop.clock += 3 * kNearbySlot.inMilliseconds;
    await laptop.nearby.setVisible(true);
    laptop.radio.broadcast(rssi: -70);
    await settleNearby();
    expect(bob.nearby.people.single.friend, 'ania');
  });

  testWidgets('R5-#17: a friend is never offered as "spotkani?" by another '
      'of their devices', (WidgetTester tester) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final EncounterLog log = EncounterLog(
      disk: MemoryLedgerDisk(),
      flushAfter: const Duration(days: 1),
    );
    // Passed Ania's phone and then her computer; she is met already.
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
              hasMet: (String a) => a == 'ania',
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
    expect(find.text('Spotkani?'), findsNothing);
    expect(find.byIcon(Icons.verified_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    log.dispose();
  });
}
