import 'dart:async';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';

/// How often the optional look around runs without the "W pobliżu" screen.
const Duration kNearbyLookEvery = Duration(minutes: 5);

/// How long one such look around lasts.
const Duration kNearbyLookFor = Duration(seconds: 10);

/// The app's share of "people nearby" without the "W pobliżu" screen, while
/// the app is unlocked — on screen or in the background (its isolate keeps
/// the node then, so it keeps this too):
///  - when the person allowed it ([MeetBook.nearbyBackgroundScan]), a short
///    low-power look around every [lookEvery]; friends in range (and how
///    many others) go to "Mijani" ([NearbyService.encounters]);
///  - friends' alarms heard only over Bluetooth end after
///    [kNearbyAlarmLife].
///
/// Showing this phone and alarm waves are the app's anyway
/// (`nearbyServiceProvider`, `AlarmWatcher`). While the app is locked or
/// closed the Android background service does all of it from the nearby
/// kit (`LockedNearby`), so [active] says "unlocked".
final class NearbyKeeper {
  NearbyKeeper({
    required this.nearby,
    this.active,
    this.lookEvery = kNearbyLookEvery,
    this.lookFor = kNearbyLookFor,
    this.tick = const Duration(minutes: 1),
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NearbyService nearby;

  /// Whether a look around may run now (the app: while unlocked — locked,
  /// the background service looks instead).
  final bool Function()? active;

  final Duration lookEvery;
  final Duration lookFor;

  /// How often [lookIfDue] is checked.
  final Duration tick;
  final int Function() _now;

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

  /// Runs the look around when it is due and allowed. Returns whether it
  /// ran.
  Future<bool> lookIfDue() async {
    if (_closed || !(active?.call() ?? true)) {
      return false;
    }
    final int t = _now();
    if (t - _lastLookAt < lookEvery.inMilliseconds) {
      return false;
    }
    _lastLookAt = t;
    if (!meet.book.nearbyBackgroundScan) {
      return false;
    }
    return nearby.scanWindow(lookFor);
  }

  /// Stops; the [NearbyService] itself stays with its owner.
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
  }
}
