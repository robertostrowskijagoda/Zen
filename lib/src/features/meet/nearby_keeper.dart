import 'dart:async';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_look_policy.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';

export 'package:zen/src/features/meet/nearby_look_policy.dart';

/// The app's share of "people nearby" without the "W pobliżu" screen, while
/// the app is unlocked — on screen or in the background (its isolate keeps
/// the node then, so it keeps this too):
///  - when the person allows it ([MeetBook.nearbyBackgroundScan], on by
///    default), a short low-power look around every [lookEvery], only when
///    the [policy] lets it (battery, battery saver, Doze); friends in range
///    (and how many others) go to "Mijani" ([NearbyService.encounters]);
///  - friends' alarms heard only over Bluetooth end after
///    [kNearbyAlarmLife].
///
/// Showing this phone and alarm waves are the app's anyway
/// (`nearbyServiceProvider`, `AlarmWatcher`). While the app is locked or
/// closed, or once the app handed its node over (long in the background),
/// the Android background service does all of it from the nearby kit
/// (`LockedNearby`), so [active] says "unlocked and the app has the node".
final class NearbyKeeper {
  NearbyKeeper({
    required this.nearby,
    this.active,
    Duration? lookEvery,
    Duration? lookFor,
    this.tick = const Duration(minutes: 1),
    int Function()? now,
  }) : _every = lookEvery,
       _for = lookFor,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NearbyService nearby;

  /// Whether a look around may run now (the app: while unlocked — locked,
  /// the background service looks instead).
  final bool Function()? active;

  /// Fixed instead of the person's choice (tests).
  final Duration? _every;
  final Duration? _for;

  /// When a look runs and for how long: as the person chose
  /// ([MeetBook.nearbyLookMinutes], [MeetBook.nearbyLookSeconds]).
  NearbyLookPolicy get policy => NearbyLookPolicy(
    every: _every ?? Duration(minutes: meet.book.nearbyLookMinutes),
    window: _for ?? Duration(seconds: meet.book.nearbyLookSeconds),
  );

  Duration get lookEvery => policy.every;
  Duration get lookFor => policy.window;

  /// How often [lookIfDue] is checked.
  final Duration tick;
  final int Function() _now;

  /// What the looks cost so far.
  final NearbyLookStats stats = NearbyLookStats();

  /// Why the last look did not run (`null`: it ran).
  NearbyLookSkip? lastSkip;

  Timer? _timer;
  bool _closed = false;
  int _lastLookAt = 0;

  MeetService get meet => nearby.meet;

  Future<void> start() async {
    _lastLookAt = _now();
    if (_closed) {
      return;
    }
    _timer = Timer.periodic(tick, (_) {
      unawaitedLogged(
        meet.expireNearbyAlarms(),
        context: 'Alarm w pobliżu: wygasanie',
      );
      unawaitedLogged(lookIfDue(), context: 'W pobliżu: rozglądanie');
    });
  }

  bool _skip(NearbyLookSkip why) {
    lastSkip = why;
    if (why != NearbyLookSkip.notDue) {
      stats.skip(why);
    }
    return false;
  }

  /// Runs the look around when it is due and allowed. Returns whether it
  /// ran.
  Future<bool> lookIfDue() async {
    if (_closed || !(active?.call() ?? true)) {
      return false;
    }
    final int t = _now();
    if (!policy.due(t, _lastLookAt)) {
      return _skip(NearbyLookSkip.notDue);
    }
    // Skipped looks wait for the next turn too: never a tight retry.
    _lastLookAt = t;
    if (!meet.book.nearbyBackgroundScan) {
      return _skip(NearbyLookSkip.off);
    }
    if (nearby.scanning) {
      return _skip(NearbyLookSkip.busy);
    }
    final NearbyLookSkip? why = policy.skipFor(await nearby.radio.state());
    if (why != null) {
      return _skip(why);
    }
    // Started while the phone is awake (this timer stands still while it
    // sleeps); held awake for the window, so the scan is never left on
    // until the next wake.
    final bool ran = await ZenWake.holdWhile(
      () => nearby.scanWindow(lookFor),
      tag: 'nearby-look-app',
      limit: lookFor + const Duration(seconds: 5),
      linger: kLookBatchGrace,
    );
    if (!ran) {
      return _skip(NearbyLookSkip.busy);
    }
    lastSkip = null;
    stats.ran(lookFor);
    if (stats.looks % 48 == 0) {
      logZenMessage('W pobliżu w tle: $stats.');
    }
    return true;
  }

  /// Stops; the [NearbyService] itself stays with its owner.
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
