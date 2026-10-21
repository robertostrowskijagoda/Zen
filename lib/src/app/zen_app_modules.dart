import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/dating/dating_providers.dart';
import 'package:zen/src/features/feed/feed_maintenance.dart';
import 'package:zen/src/features/groups/group_board_providers.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/circle/food_providers.dart';
import 'package:zen/src/features/meet/graph/graph_providers.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/plan/plan_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/runtime/local_links_controller.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/update/update_service.dart';

/// The app's `ZenCore`, created once. `RuntimeSignalBridge` starts it when
/// the security gate lets the app through and stops it when the gate closes;
/// `ZenRewriteApp` forwards flag changes and the return to the screen.
///
/// The Android background service does not run it: while the app is locked
/// or gone the service only receives, without the master key, into a sealed
/// inbox the app drains after unlock (`LockedReceiver`).
final Provider<ZenCore> zenCoreProvider = Provider<ZenCore>((Ref ref) {
  final ZenCore core = ZenCore(
    modules: zenAppModules(ref),
    loadFlags: () async => ref.read(featureFlagsProvider),
  );
  ref.onDispose(() {
    unawaitedLogged(core.stop(), context: 'Stopping ZenCore failed');
  });
  return core;
});

/// The module registry of the app, in start order: the signal transport
/// first, then the services that send and receive through it.
List<ZenModule> zenAppModules(Ref ref) => <ZenModule>[
  RuntimeSignalModule(ref),
  ServicesModule(
    id: 'ledger',
    start: () {
      // Starts the ledger (posts, profiles) once the transport is up.
      ref.read(ledgerNodeProvider);
      ref.read(recoveryServiceProvider);
      // A computer offers itself as a mesh bridge.
      ref.read(bridgeHostProvider);
      // New versions of the app from friends.
      ref.read(updateServiceProvider);
    },
  ),
  // Friends nearby without internet: same Wi-Fi, Wi-Fi Direct.
  LocalLinksModule(ref),
  ServicesModule(
    id: 'feed',
    // Notifications about reactions and the storage limits.
    start: () {
      ref.read(feedMaintenanceProvider)?.start();
    },
    minute: (int minute) {
      ref.read(feedMaintenanceProvider)?.minute(minute);
    },
  ),
  ServicesModule(
    id: 'meet',
    start: () {
      // Friends' statuses and alarms; this phone shown nearby.
      ref.read(meetServiceProvider);
      ref.read(nearbyServiceProvider);
      ref.read(eventServiceProvider);
      ref.read(askServiceProvider);
      ref.read(tableServiceProvider);
      ref.read(circleServiceProvider);
      ref.read(foodServiceProvider);
      // Introductions and letters through friends.
      ref.read(introServiceProvider);
      // "Otwarci na poznanie" on the graph (friends pass it on).
      ref.read(openToMeetServiceProvider);
      // Group boards.
      ref.read(groupBoardServiceProvider);
    },
    // The Android background service may have taken frames meanwhile.
    resume: () {
      unawaited(ref.read(meetServiceProvider).reload());
      unawaited(ref.read(eventServiceProvider).load());
      unawaited(ref.read(askServiceProvider).load());
      unawaited(ref.read(tableServiceProvider).load());
      unawaited(ref.read(circleServiceProvider).load());
      unawaited(ref.read(foodServiceProvider).load());
    },
    // Gates and payments that wait, now and then.
    minute: (int minute) => introMinute(ref, minute),
  ),
  ServicesModule(
    id: 'neighbors',
    // Flats and neighbours: core, always on.
    start: () {
      ref.read(neighborsServiceProvider);
    },
    resume: () {
      unawaited(ref.read(neighborsServiceProvider).load());
    },
  ),
  ServicesModule(
    id: 'dating',
    feature: ZenFeature.dating,
    // Dating packages pass through every phone.
    start: () {
      ref.read(datingServiceProvider);
    },
    resume: () {
      unawaited(ref.read(datingServiceProvider).load());
    },
    // Deadlines and the weekly package run while the app does.
    minute: (int minute) {
      datingMinute(ref.read(datingServiceProvider), minute);
    },
  ),
  ServicesModule(
    id: 'pyramid',
    feature: ZenFeature.pyramid,
    // The pyramid, its money and crisis mode.
    start: () {
      ref.read(pyramidServiceProvider);
    },
    resume: () {
      unawaited(ref.read(pyramidServiceProvider).load());
    },
    minute: (int minute) {
      pyramidMinute(ref.read(pyramidServiceProvider), minute);
    },
  ),
  ServicesModule(
    id: 'plan',
    // Plan na weekend.
    start: () {
      ref.read(planServiceProvider);
    },
  ),
];

/// A module whose services are providers: starting it creates them (their
/// providers load and subscribe), and they live as long as the container.
final class ServicesModule extends ZenModule {
  ServicesModule({
    required this.id,
    required void Function() start,
    this.feature,
    void Function()? resume,
    void Function(int minute)? minute,
  }) : _start = start,
       _resume = resume,
       _minute = minute;

  @override
  final String id;

  @override
  final ZenFeature? feature;

  final void Function() _start;
  final void Function()? _resume;
  final void Function(int minute)? _minute;
  bool _running = false;

  @override
  void start() {
    _start();
    _running = true;
  }

  @override
  void stop() {
    // The services stay with the container; only the duties stop.
    _running = false;
  }

  @override
  void onResume() {
    if (_running) {
      _resume?.call();
    }
  }

  @override
  void onMinute(int minute) {
    if (_running) {
      _minute?.call(minute);
    }
  }
}
