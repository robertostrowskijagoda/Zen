import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// The pyramid, its power and money (§20–24), and crisis mode (§28.1).
final Provider<PyramidService> pyramidServiceProvider =
    Provider<PyramidService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      final NearbyService nearby = ref.watch(nearbyServiceProvider);
      final PyramidService pyramid = PyramidService(
        host: appEventHost(ref, meet),
        disk: ref.read(ledgerDiskProvider),
        // Crisis announcements hop from phone to phone over Bluetooth.
        crisisBroadcast: nearby.waveAll,
        // Friends of friends get their own market prices (§24).
        friendsOf: (String f) => meet.book.friendsOf(f),
      );
      unawaitedLogged(
        pyramid.load().then((_) => pyramid.greet()),
        context: 'Odczyt piramidy',
      );
      listenFrames(ref, pyramid.handle, 'Piramida');
      void onWave(Map<dynamic, dynamic> json) => unawaitedLogged(
        pyramid.onCrisisWave(json),
        context: 'Komunikat kryzysowy',
      );
      nearby.otherWaveHandlers.add(onWave);
      ref.onDispose(() {
        nearby.otherWaveHandlers.remove(onWave);
        pyramid.dispose();
      });
      return pyramid;
    });

/// The pyramid's minute (called by a widget's timer): duties every 5
/// minutes, hello to friends every 3 hours.
void pyramidMinute(PyramidService pyramid, int minute) {
  if (minute % 5 == 0) {
    unawaitedLogged(pyramid.duties(), context: 'Piramida: obowiązki');
  }
  if (minute % 180 == 0) {
    unawaitedLogged(pyramid.greet(), context: 'Piramida: powitanie');
  }
}
