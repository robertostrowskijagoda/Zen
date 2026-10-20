import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// "Sekcja sąsiedzka" (§18).
final Provider<NeighborsService> neighborsServiceProvider =
    Provider<NeighborsService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      // The flat's door runs next to the node (§18.2): the door QR carries
      // its address, never a resident's.
      final RuntimeNodeRuntime runtime = ref.watch(runtimeNodeRuntimeProvider);
      final NeighborsService neighbors = NeighborsService(
        host: appEventHost(ref, meet),
        disk: ref.read(ledgerDiskProvider),
        doorInbox: () => runtime.doorAddress,
      );
      void syncDoorKey() => runtime.setDoorKey(neighbors.doorKey);
      String? door = runtime.doorAddress;
      void onRuntime() {
        if (runtime.doorAddress != door) {
          door = runtime.doorAddress;
          neighbors.doorInboxChanged();
        }
      }

      neighbors.addListener(syncDoorKey);
      runtime.addListener(onRuntime);
      unawaitedLogged(neighbors.load(), context: 'Odczyt sąsiadów');
      listenFrames(ref, neighbors.handle, 'Sąsiedzi');
      // Knocks on the door come only here (never to the other services).
      final StreamSubscription<SignalTransportFrame> knocks = runtime.doorFrames
          .listen(
            (SignalTransportFrame f) =>
                unawaitedLogged(neighbors.handle(f), context: 'Pukanie'),
          );
      // Invitations from flats nearby come over Bluetooth.
      final NearbyService nearby = ref.watch(nearbyServiceProvider);
      void onWave(Map<dynamic, dynamic> json) => unawaitedLogged(
        neighbors.onNearbyWave(json),
        context: 'Zaproszenie w pobliżu',
      );
      nearby.otherWaveHandlers.add(onWave);
      ref.onDispose(() {
        unawaited(knocks.cancel());
        nearby.otherWaveHandlers.remove(onWave);
        runtime.removeListener(onRuntime);
        neighbors.removeListener(syncDoorKey);
        runtime.setDoorKey(null);
        neighbors.dispose();
      });
      return neighbors;
    });
