import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

/// "Sekcja sąsiedzka" (§18).
final Provider<NeighborsService> neighborsServiceProvider =
    Provider<NeighborsService>((Ref ref) {
      final MeetService meet = ref.watch(meetServiceProvider);
      // The flat's door runs next to the node (§18.2): the door QR and the
      // flat's profile carry its address, never a resident's, and
      // everything to neighbour flats goes out from it.
      final RuntimeNodeRuntime runtime = ref.watch(runtimeNodeRuntimeProvider);
      // The friends holding this phone's mailboxes (§7) run the door's
      // mailbox doors, for knocks while the phone is offline; unknown until
      // the relay layer has its state.
      final RelayEngine? relay = ref.watch(relayEngineProvider);
      List<String>? boxes;
      final NeighborsService neighbors = NeighborsService(
        host: appEventHost(ref, meet),
        disk: ref.read(ledgerDiskProvider),
        doorInbox: () => runtime.doorAddress,
        doorSend: runtime.sendFromDoor,
        mailboxes: () => boxes,
      );
      void syncDoorKey() {
        runtime
          ..setDoorKey(neighbors.doorKey)
          ..setMailboxDoorKeys(neighbors.hostedDoorKeys);
      }

      void onRelays() {
        final List<String> next = relay!.overview.value.relays;
        if (boxes == null || !listEquals(next, boxes)) {
          boxes = next;
          unawaitedLogged(neighbors.mailboxesChanged(), context: 'Skrzynki');
        }
      }

      relay?.overview.addListener(onRelays);
      if (relay != null && relay.isActive) {
        onRelays();
      }
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
      // What went out from the door and was not confirmed yet is retried.
      final Timer retries = Timer.periodic(
        const Duration(seconds: 30),
        (_) => unawaitedLogged(
          neighbors.retryDoorSends(),
          context: 'Sąsiedzi: ponowienia',
        ),
      );
      // What comes to the doors comes only here (never to the other
      // services).
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
        retries.cancel();
        unawaited(knocks.cancel());
        nearby.otherWaveHandlers.remove(onWave);
        runtime.removeListener(onRuntime);
        relay?.overview.removeListener(onRelays);
        neighbors.removeListener(syncDoorKey);
        runtime
          ..setDoorKey(null)
          ..setMailboxDoorKeys(const <String>[]);
        neighbors.dispose();
      });
      return neighbors;
    });
