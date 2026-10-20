import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Slows down password guessing on the lock screen (Z2-9): the number of
/// failed attempts lives in the secure storage, so restarting the app does
/// not reset it, and from the fifth failure on every further one makes the
/// wait twice as long, up to [maxDelay]. There is never a permanent
/// lock-out: "Nie pamiętam hasła" (erasing this device) is the way out.
///
/// The wait is counted with the wall clock (the only thing that survives a
/// restart) and, while the app keeps running, also with a monotonic clock:
/// the shorter of the two counts, so moving the system clock forward does
/// not end a wait early, and moving it back never shortens it.
final class UnlockThrottle {
  UnlockThrottle(
    this._store, {
    DateTime Function()? now,
    Duration Function()? monotonic,
  }) : _now = now ?? DateTime.now,
       _monotonic = monotonic ?? _processClock();

  final AppSecurityCredentialsStore _store;
  final DateTime Function() _now;
  final Duration Function() _monotonic;

  /// When the last failure of this run was counted, on the monotonic clock,
  /// and the failure count it made (so a count written by someone else is
  /// not mistaken for it).
  Duration? _monoAt;
  int _monoFailures = 0;

  static Duration Function() _processClock() {
    final Stopwatch watch = Stopwatch()..start();
    return () => watch.elapsed;
  }

  /// Failures without any wait.
  static const int freeFailures = 5;

  /// The wait after the [freeFailures]th failure.
  static const Duration baseDelay = Duration(seconds: 30);

  static const Duration maxDelay = Duration(minutes: 30);

  /// How long a person must wait after [failures] failed attempts in a row.
  static Duration delayAfter(int failures) {
    if (failures < freeFailures) {
      return Duration.zero;
    }
    final int doublings = failures - freeFailures;
    // 30 s doubled 6 times is already past the cap.
    if (doublings >= 6) {
      return maxDelay;
    }
    final Duration delay = baseDelay * (1 << doublings);
    return delay > maxDelay ? maxDelay : delay;
  }

  /// How much of the wait after the last failure is still left (zero:
  /// the password may be tried).
  Future<Duration> remaining() async {
    final ({int failures, DateTime? at}) state = await _read();
    final Duration wait = delayAfter(state.failures);
    final DateTime? at = state.at;
    if (wait == Duration.zero || at == null) {
      return Duration.zero;
    }
    Duration elapsed = _now().difference(at);
    final Duration? since = _monoAt;
    if (since != null && _monoFailures == state.failures) {
      final Duration steady = _monotonic() - since;
      if (steady < elapsed) {
        elapsed = steady;
      }
    }
    if (elapsed.isNegative) {
      // The clock was set back: the wait counts in full.
      return wait;
    }
    final Duration left = wait - elapsed;
    return left.isNegative ? Duration.zero : left;
  }

  /// Counts one more failed attempt; returns the wait it starts.
  Future<Duration> recordFailure() async {
    final ({int failures, DateTime? at}) state = await _read();
    final int failures = state.failures + 1;
    _monoAt = _monotonic();
    _monoFailures = failures;
    try {
      await _store.write(
        appSecurityUnlockFailuresStorageKey,
        '$failures:${_now().millisecondsSinceEpoch}',
      );
    } on Object catch (error, stackTrace) {
      logZenError('Saving the failed attempts failed', error, stackTrace);
    }
    return delayAfter(failures);
  }

  /// The right password (or the fingerprint) was given.
  Future<void> clear() async {
    _monoAt = null;
    try {
      await _store.delete(appSecurityUnlockFailuresStorageKey);
    } on Object catch (error, stackTrace) {
      logZenError('Clearing the failed attempts failed', error, stackTrace);
    }
  }

  Future<({int failures, DateTime? at})> _read() async {
    final String? stored;
    try {
      stored = await _store.read(appSecurityUnlockFailuresStorageKey);
    } on Object catch (error, stackTrace) {
      logZenError('Reading the failed attempts failed', error, stackTrace);
      return (failures: 0, at: null);
    }
    if (stored == null) {
      return (failures: 0, at: null);
    }
    final List<String> parts = stored.split(':');
    final int? failures = int.tryParse(parts.first);
    final int? millis = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (failures == null || failures < 0 || millis == null) {
      return (failures: 0, at: null);
    }
    return (
      failures: failures,
      at: DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }
}

/// The lock screen's attempt counter, kept next to the credentials of the
/// current [appSecurityServiceProvider]. Tests override it to set the clock.
final Provider<UnlockThrottle> unlockThrottleProvider =
    Provider<UnlockThrottle>(
      (Ref ref) => UnlockThrottle(
        ref.watch(appSecurityServiceProvider).credentialsStore,
      ),
    );
