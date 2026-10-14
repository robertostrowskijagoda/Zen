import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';

/// "Sekcja sąsiedzka" (§18).
final Provider<NeighborsService> neighborsServiceProvider =
    Provider<NeighborsService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      final NeighborsService neighbors = NeighborsService(
        host: appEventHost(ref, meet),
        disk: ref.read(ledgerDiskProvider),
      );
      unawaitedLogged(neighbors.load(), context: 'Odczyt sąsiadów');
      listenFrames(ref, neighbors.handle, 'Sąsiedzi');
      // Invitations from flats nearby come over Bluetooth.
      final NearbyService nearby = ref.watch(nearbyServiceProvider);
      void onWave(Map<dynamic, dynamic> json) => unawaitedLogged(
        neighbors.onNearbyWave(json),
        context: 'Zaproszenie w pobliżu',
      );
      nearby.otherWaveHandlers.add(onWave);
      ref.onDispose(() {
        nearby.otherWaveHandlers.remove(onWave);
        neighbors.dispose();
      });
      return neighbors;
    });
