import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Slows down password guessing: the number of failed attempts lives in
/// the secure storage, so restarting the app does not reset it, and from
/// the fifth failure on every further one makes the wait twice as long, up
/// to [maxDelay]. There is never a permanent lock-out: "Nie pamiętam hasła"
/// (erasing this device) is the way out.
///
/// What is kept is the wait still left, not a moment on the wall clock:
/// while the app runs it is counted down on a monotonic clock (moving the
/// system clock either way changes nothing), and after a restart the wait
/// left at the last look starts again in full.
final class UnlockThrottle {
  UnlockThrottle(
    this._store, {
    Duration Function()? monotonic,
    this.storageKey = appSecurityUnlockFailuresStorageKey,
  }) : _monotonic = monotonic ?? _processClock();

  /// The guesses at "Inne konto": one count for the device (its own entry
  /// in the secret store, whatever account is open), which no unlock
  /// clears, so knowing one account's password buys no free guesses at
  /// another.
  UnlockThrottle.otherAccounts({
    AppSecurityCredentialsStore store =
        const SecureStorageCredentialsStore.device(),
    Duration Function()? monotonic,
  }) : this(store, monotonic: monotonic, storageKey: otherAccountsStorageKey);

  final AppSecurityCredentialsStore _store;
  final Duration Function() _monotonic;

  /// The entry the count is kept in.
  final String storageKey;

  /// The device's entry of the guesses at "Inne konto".
  static const String otherAccountsStorageKey =
      'zen_rewrite_other_account_failures';

  /// When this run first looked at the count, on the monotonic clock, and
  /// the count and the wait left it saw then.
  Duration? _since;
  int _failures = -1;
  Duration _leftThen = Duration.zero;

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
  /// the password may be tried). The first look after a restart starts
  /// the wait left before it again; what is left is kept at every look.
  Future<Duration> remaining() async {
    final ({int failures, Duration left}) state = await _read();
    final Duration? since = _since;
    if (since == null || _failures != state.failures) {
      // Not counted in this run yet (a restart, or a count written by
      // someone else): from now, in full.
      _since = _monotonic();
      _failures = state.failures;
      _leftThen = state.left;
      return state.left;
    }
    Duration left = _leftThen - (_monotonic() - since);
    if (left.isNegative) {
      left = Duration.zero;
    }
    if (left < state.left - const Duration(seconds: 1) ||
        (left == Duration.zero && state.left > Duration.zero)) {
      await _write(state.failures, left);
    }
    return left;
  }

  /// Counts one more failed attempt; returns the wait it starts.
  Future<Duration> recordFailure() async {
    final ({int failures, Duration left}) state = await _read();
    final int failures = state.failures + 1;
    final Duration wait = delayAfter(failures);
    _since = _monotonic();
    _failures = failures;
    _leftThen = wait;
    await _write(failures, wait);
    return wait;
  }

  /// The right password (or the fingerprint) was given.
  Future<void> clear() async {
    _since = null;
    _failures = -1;
    try {
      await _store.delete(storageKey);
    } on Object catch (error, stackTrace) {
      logZenError('Clearing the failed attempts failed', error, stackTrace);
    }
  }

  Future<void> _write(int failures, Duration left) async {
    try {
      await _store.write(storageKey, '$failures;${left.inMilliseconds}');
    } on Object catch (error, stackTrace) {
      logZenError('Saving the failed attempts failed', error, stackTrace);
    }
  }

  /// The count and the wait left: `<count>;<ms left>`, or as earlier
  /// versions kept it, `<count>:<epoch ms>` (the whole wait is left then).
  Future<({int failures, Duration left})> _read() async {
    final String? stored;
    try {
      stored = await _store.read(storageKey);
    } on Object catch (error, stackTrace) {
      logZenError('Reading the failed attempts failed', error, stackTrace);
      return (failures: 0, left: Duration.zero);
    }
    if (stored == null) {
      return (failures: 0, left: Duration.zero);
    }
    final bool earlier = !stored.contains(';');
    final List<String> parts = stored.split(earlier ? ':' : ';');
    final int? failures = int.tryParse(parts.first);
    final int? second = parts.length == 2 ? int.tryParse(parts[1]) : null;
    if (failures == null || failures < 0 || second == null || second < 0) {
      return (failures: 0, left: Duration.zero);
    }
    final Duration wait = delayAfter(failures);
    if (earlier) {
      return (failures: failures, left: wait);
    }
    final Duration left = Duration(milliseconds: second);
    return (failures: failures, left: left > wait ? wait : left);
  }
}

/// What one try of a password came to: [right], or the wait it left
/// ([wait] zero: just wrong).
typedef PasswordTry = ({bool right, Duration wait});

/// One try of a password inside the unlocked app (a confirmation before a
/// sensitive place or a security setting), counted with the lock screen's
/// attempts in [throttle]: while a wait is on [check] is not even run, a
/// wrong password counts (and may start a wait), the right one clears the
/// count when [clears] (the app password; another password proves less).
Future<PasswordTry> tryPassword(
  UnlockThrottle throttle,
  Future<bool> Function() check, {
  bool clears = true,
}) async {
  final Duration left = await throttle.remaining();
  if (left > Duration.zero) {
    return (right: false, wait: left);
  }
  if (await check()) {
    if (clears) {
      await throttle.clear();
    }
    return (right: true, wait: Duration.zero);
  }
  return (right: false, wait: await throttle.recordFailure());
}

/// A wait as the lock screen shows it: "0:30", rounded up to the second.
String formatUnlockWait(Duration wait) {
  final int seconds = wait.inSeconds + (wait.inMilliseconds % 1000 > 0 ? 1 : 0);
  final String rest = (seconds % 60).toString().padLeft(2, '0');
  return '${seconds ~/ 60}:$rest';
}

/// The lock screen's attempt counter, kept next to the credentials of the
/// current [appSecurityServiceProvider]. Tests override it to set the clock.
final Provider<UnlockThrottle> unlockThrottleProvider =
    Provider<UnlockThrottle>(
      (Ref ref) => UnlockThrottle(
        ref.watch(appSecurityServiceProvider).credentialsStore,
      ),
    );

/// The count of guesses at "Inne konto" ([UnlockThrottle.otherAccounts]).
final Provider<UnlockThrottle> otherAccountThrottleProvider =
    Provider<UnlockThrottle>((Ref ref) => UnlockThrottle.otherAccounts());
