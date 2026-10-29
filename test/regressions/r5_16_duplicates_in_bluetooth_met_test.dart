// Owner report R5-#16 (28.10.2026, after 1.14.0): duplicate people in the Bluetooth "met" list.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in nearby.dart (one row per friend and per Bluetooth device),
// meet_service.dart / meet_book.dart (each of a friend's devices keeps its
// own keys) and encounters_section.dart (one row per friend in "Mijani"),
// 0fe709dd; guarded by the tests below, test/nearby_test.dart,
// test/nearby_background_test.dart and test/nearby_screen_test.dart.
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import '../support/nearby_fakes.dart';

void main() {
  test('R5-#16: a person met over Bluetooth is listed once, also when '
      'their token changes', () async {
    final FakeAir air = FakeAir();
    final NearbyPhone stranger = NearbyPhone(air, 'obcy', <String>[]);
    final NearbyPhone bob = NearbyPhone(air, 'bob', <String>[]);
    // Twenty seconds before the token's slot ends.
    final int slot = kNearbySlot.inMilliseconds;
    final int edge = (bob.clock ~/ slot + 1) * slot;
    stranger.clock = bob.clock = edge - 20 * 1000;
    await stranger.nearby.setVisible(true);
    await bob.nearby.startScanning();
    stranger.radio.broadcast();
    await settleNearby();
    expect(bob.nearby.people, hasLength(1));

    // Forty seconds on: the next slot, a new token from the same phone,
    // while the old one is still fresh. Before: two people.
    stranger.clock = bob.clock = edge + 20 * 1000;
    await stranger.nearby.setVisible(true);
    stranger.radio.broadcast();
    await settleNearby();

    final NearbyPerson row = bob.nearby.people.single;
    expect(row.pseudonym, stranger.nearby.myPseudonym, reason: 'the newest');
  });

  test('R5-#16: a friend passed with two of their devices is listed once, '
      'under their name', () async {
    final FakeAir air = FakeAir();
    final NearbyPhone ania = NearbyPhone(air, 'ania', <String>['bob']);
    // Ania's computer, an own device of her account at its own address.
    final NearbyPhone laptop = NearbyPhone(air, 'ania2', <String>['bob']);
    final NearbyPhone bob = NearbyPhone(air, 'bob', <String>['ania']);
    await ania.meet.nearbyPrivateKey();
    await bob.meet.handle(
      SignalTransportFrame(
        from: 'ania',
        payload: <String, dynamic>{
          'type': MeetTypes.nearbyKey,
          'z': ania.meet.nearbyKeysFor('bob'),
        },
        receivedAtMillis: 0,
      ),
    );
    await laptop.meet.nearbyPrivateKey();
    // The account routing hands the computer's keys over as from Ania.
    await bob.meet.handle(
      SignalTransportFrame(
        from: 'ania',
        device: 'ania2',
        payload: <String, dynamic>{
          'type': MeetTypes.nearbyKey,
          'z': laptop.meet.nearbyKeysFor('bob'),
        },
        receivedAtMillis: 0,
      ),
    );
    await ania.nearby.setVisible(true);
    await laptop.nearby.setVisible(true);
    await bob.nearby.startScanning();
    ania.radio.broadcast(rssi: -60);
    laptop.radio.broadcast(rssi: -75);
    await settleNearby();

    final NearbyPerson row = bob.nearby.people.single;
    expect(row.friend, 'ania');
  });
}
