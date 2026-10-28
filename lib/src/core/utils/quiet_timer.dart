import 'dart:async';

/// Runs [action] once news stopped coming for [quiet], but never later
/// than [atMost] after the first news since the last run: a burst (a sync
/// catching up) still makes one run, and a steady trickle (a lively
/// thread) cannot hold it off for ever.
final class QuietTimer {
  QuietTimer({required this.quiet, required this.atMost, required this.action})
    : assert(atMost >= quiet, 'atMost must not be shorter than quiet');

  final Duration quiet;
  final Duration atMost;
  final void Function() action;

  Timer? _quiet;
  Timer? _deadline;

  /// Whether a run is waiting.
  bool get isPending => _quiet != null;

  /// Something new came: the run waits [quiet] from now, at most until
  /// [atMost] after the first news it waits for.
  void nudge() {
    _quiet?.cancel();
    _quiet = Timer(quiet, _fire);
    _deadline ??= Timer(atMost, _fire);
  }

  void _fire() {
    cancel();
    action();
  }

  /// Drops the waiting run.
  void cancel() {
    _quiet?.cancel();
    _quiet = null;
    _deadline?.cancel();
    _deadline = null;
  }
}
