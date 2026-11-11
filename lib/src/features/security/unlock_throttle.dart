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
///
/// An attempt is counted before its password is checked
/// ([recordFailure]), so closing Zen during the check leaves it counted;
/// the right password then [clear]s the count, or takes back only its own
/// attempt ([withdrawFailure]).
///
/// With [forgives] (the guesses at "Inne konto", which no unlock clears)
/// the count also goes down slowly: one failure is forgiven for every full
/// [forgivenAfter] without a failed attempt, never during a wait and never
/// below zero; a failure starts the time again. Neither clock is trusted
/// alone. Time Zen saw pass on its monotonic clock while it ran (added up
/// at every look, across restarts) counts in full: [forgivenAfter] of it
/// forgives one. Time on the wall clock (the only one that also runs while
/// Zen is closed, and one anybody holding the device may set) forgives
/// one for every [forgivenAfter] it moved forward only together with
/// [forgivingRunTime] of running time, so setting the clock ahead, once
/// or at every start, earns at most one forgiveness per [forgivingRunTime]
/// Zen really ran: no more than the longest wait would let through anyway.
/// A wall clock that went back counts nothing.
final class UnlockThrottle {
  UnlockThrottle(
    this._store, {
    Duration Function()? monotonic,
    DateTime Function()? wallClock,
    this.storageKey = appSecurityUnlockFailuresStorageKey,
    this.forgives = false,
  }) : _monotonic = monotonic ?? _processClock(),
       _wallClock = wallClock ?? DateTime.now;

  /// The guesses at "Inne konto": one count for the device (its own entry
  /// in the secret store, whatever account is open), which no unlock
  /// clears, so knowing one account's password buys no free guesses at
  /// another. It is forgiven slowly instead ([forgives]).
  UnlockThrottle.otherAccounts({
    AppSecurityCredentialsStore store =
        const SecureStorageCredentialsStore.device(),
    Duration Function()? monotonic,
    DateTime Function()? wallClock,
  }) : this(
         store,
         monotonic: monotonic,
         wallClock: wallClock,
         storageKey: otherAccountsStorageKey,
         forgives: true,
       );

  final AppSecurityCredentialsStore _store;
  final Duration Function() _monotonic;
  final DateTime Function() _wallClock;

  /// The entry the count is kept in.
  final String storageKey;

  /// Whether failures are forgiven with time (see the class).
  final bool forgives;

  /// The device's entry of the guesses at "Inne konto".
  static const String otherAccountsStorageKey =
      'zen_rewrite_other_account_failures';

  /// Without a failed attempt for this long, one failure is forgiven.
  static const Duration forgivenAfter = Duration(hours: 24);

  /// The running time a forgiveness the wall clock vouches for costs too:
  /// the longest wait.
  static const Duration forgivingRunTime = maxDelay;

  /// When this run last looked at the count, on the monotonic clock; what
  /// it found then (time and forgiveness applied) and the entry as it was
  /// stored.
  Duration? _lookedAt;
  _Count? _seen;
  String? _seenText;

  /// Before the last [recordFailure], for [withdrawFailure].
  ({String? text, _Count count, Duration lookedAt})? _beforeFailure;

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
  Future<Duration> remaining() async => (await _look()).left;

  /// Counts one more failed attempt; returns the wait it starts. Called
  /// before the password is checked: should Zen be closed during the
  /// check, the attempt stays counted.
  Future<Duration> recordFailure() async {
    final _Count before = await _look(save: false);
    _beforeFailure = (
      text: _seenText,
      count: before,
      lookedAt: _lookedAt ?? _monotonic(),
    );
    final int failures = before.failures + 1;
    final Duration wait = delayAfter(failures);
    final _Count counted = (
      failures: failures,
      left: wait,
      since: forgives ? _wallClock().millisecondsSinceEpoch : null,
      ran: Duration.zero,
    );
    _lookedAt = _monotonic();
    _seen = counted;
    await _save(counted);
    return wait;
  }

  /// The password the last [recordFailure] counted was right after all,
  /// and it must not clear the count: the entry goes back to what it was
  /// before (forgiveness earned until then included). Nothing changes when
  /// someone else wrote the entry since.
  Future<void> withdrawFailure() async {
    final ({String? text, _Count count, Duration lookedAt})? before =
        _beforeFailure;
    _beforeFailure = null;
    if (before == null) {
      return;
    }
    try {
      if (await _store.read(storageKey) != _seenText) {
        return;
      }
      final String? text = before.text;
      if (text == null) {
        await _store.delete(storageKey);
      } else {
        await _store.write(storageKey, text);
      }
    } on Object catch (error, stackTrace) {
      logZenError('Taking back a counted attempt failed', error, stackTrace);
      return;
    }
    _seenText = before.text;
    _seen = before.count;
    _lookedAt = before.lookedAt;
  }

  /// The right password (or the fingerprint) was given.
  Future<void> clear() async {
    _lookedAt = null;
    _seen = null;
    _seenText = null;
    _beforeFailure = null;
    try {
      await _store.delete(storageKey);
    } on Object catch (error, stackTrace) {
      logZenError('Clearing the failed attempts failed', error, stackTrace);
    }
  }

  /// The count now: the time passed since this run's last look counted
  /// down from the wait (and, with [forgives], added to the running time),
  /// forgiveness applied; kept when [save] and it changed enough.
  Future<_Count> _look({bool save = true}) async {
    final ({String? text, _Count count}) stored = await _read();
    final Duration now = _monotonic();
    final Duration? lookedAt = _lookedAt;
    final _Count? seen = _seen;
    _Count count;
    if (lookedAt == null || seen == null || stored.text != _seenText) {
      // Not looked at in this run yet (a restart), or written by someone
      // else since: from now, in full, and no time passed.
      count = stored.count;
    } else {
      Duration passed = now - lookedAt;
      if (passed.isNegative) {
        passed = Duration.zero;
      }
      final Duration left = seen.left - passed;
      count = (
        failures: seen.failures,
        left: left.isNegative ? Duration.zero : left,
        since: seen.since,
        ran: seen.ran + passed,
      );
    }
    if (forgives) {
      count = _forgive(count);
    }
    _lookedAt = now;
    _seen = count;
    _seenText = stored.text;
    if (save && _worthSaving(stored.count, count)) {
      await _save(count);
    }
    return count;
  }

  /// [count] with what the time since its last failure forgives.
  _Count _forgive(_Count count) {
    if (count.failures == 0) {
      return _none;
    }
    final int wall = _wallClock().millisecondsSinceEpoch;
    // A count kept without the time (by an earlier version): the time
    // starts now. A wall clock behind it went back: what it was ahead by
    // counts nothing.
    int since = count.since ?? wall;
    if (wall < since) {
      since = wall;
    }
    int failures = count.failures;
    Duration ran = count.ran;
    // Never during a wait: forgiveness does not shorten one.
    while (failures > 0 && count.left == Duration.zero) {
      if (ran >= forgivenAfter) {
        ran -= forgivenAfter;
      } else if (wall - since >= forgivenAfter.inMilliseconds &&
          ran >= forgivingRunTime) {
        ran -= forgivingRunTime;
      } else {
        break;
      }
      failures--;
      since += forgivenAfter.inMilliseconds;
    }
    if (failures == 0) {
      return _none;
    }
    return (failures: failures, left: count.left, since: since, ran: ran);
  }

  /// Whether [count] differs enough from the [stored] one to be written:
  /// another count, a wait shorter by more than a second (or over), or
  /// with [forgives] another start of the time or a minute more of it.
  bool _worthSaving(_Count stored, _Count count) {
    if (count.failures != stored.failures) {
      return true;
    }
    if (count.failures == 0) {
      return false;
    }
    if (count.left < stored.left - const Duration(seconds: 1) ||
        (count.left == Duration.zero && stored.left > Duration.zero)) {
      return true;
    }
    return forgives &&
        (count.since != stored.since ||
            count.ran - stored.ran >= const Duration(minutes: 1));
  }

  /// Writes [count] (no failures left: the entry goes).
  Future<void> _save(_Count count) async {
    try {
      if (count.failures == 0) {
        await _store.delete(storageKey);
        _seenText = null;
        return;
      }
      final String text = forgives
          ? '${count.failures};${count.left.inMilliseconds};'
                '${count.since ?? _wallClock().millisecondsSinceEpoch};'
                '${count.ran.inMilliseconds}'
          : '${count.failures};${count.left.inMilliseconds}';
      await _store.write(storageKey, text);
      _seenText = text;
    } on Object catch (error, stackTrace) {
      logZenError('Saving the failed attempts failed', error, stackTrace);
    }
  }

  static const _Count _none = (
    failures: 0,
    left: Duration.zero,
    since: null,
    ran: Duration.zero,
  );

  /// The entry as stored and what it says.
  Future<({String? text, _Count count})> _read() async {
    final String? stored;
    try {
      stored = await _store.read(storageKey);
    } on Object catch (error, stackTrace) {
      logZenError('Reading the failed attempts failed', error, stackTrace);
      return (text: null, count: _none);
    }
    return (text: stored, count: _parse(stored));
  }

  /// The count and the wait left: `<count>;<ms left>`; with forgiveness
  /// `<count>;<ms left>;<since>;<ran>` (`since`: epoch ms of the last
  /// failure or forgiveness, `ran`: ms Zen ran since); or as earlier
  /// versions kept it, `<count>:<epoch ms>` (the whole wait is left then).
  static _Count _parse(String? stored) {
    if (stored == null) {
      return _none;
    }
    final bool earlier = !stored.contains(';');
    final List<String> parts = stored.split(earlier ? ':' : ';');
    final int? failures = int.tryParse(parts.first);
    final int? second = parts.length == 2 || parts.length == 4
        ? int.tryParse(parts[1])
        : null;
    if (failures == null ||
        failures < 0 ||
        second == null ||
        second < 0 ||
        (earlier && parts.length != 2)) {
      return _none;
    }
    final Duration wait = delayAfter(failures);
    if (earlier) {
      return (failures: failures, left: wait, since: null, ran: Duration.zero);
    }
    int? since;
    Duration ran = Duration.zero;
    if (parts.length == 4) {
      final int? ranMs = int.tryParse(parts[3]);
      since = int.tryParse(parts[2]);
      if (since == null || ranMs == null || ranMs < 0) {
        // Unreadable: the time starts again.
        since = null;
      } else {
        ran = Duration(milliseconds: ranMs);
      }
    }
    final Duration left = Duration(milliseconds: second);
    return (
      failures: failures,
      left: left > wait ? wait : left,
      since: since,
      ran: ran,
    );
  }
}

/// A count of failed attempts: the wait left after the last one and, for
/// forgiveness, when (on the wall clock, epoch ms) the time without a
/// failure started and how long Zen ran since.
typedef _Count = ({int failures, Duration left, int? since, Duration ran});

/// What one try of a password came to: [right], or the wait it left
/// ([wait] zero: just wrong).
typedef PasswordTry = ({bool right, Duration wait});

/// One try of a password inside the unlocked app (a confirmation before a
/// sensitive place or a security setting), counted with the lock screen's
/// attempts in [throttle]: while a wait is on [check] is not even run, an
/// attempt counts before [check] runs (and may start a wait), and the
/// right password clears the count when [clears] (the app password;
/// another password proves less, and takes back only its own attempt).
Future<PasswordTry> tryPassword(
  UnlockThrottle throttle,
  Future<bool> Function() check, {
  bool clears = true,
}) async {
  final Duration left = await throttle.remaining();
  if (left > Duration.zero) {
    return (right: false, wait: left);
  }
  final Duration wait = await throttle.recordFailure();
  if (await check()) {
    if (clears) {
      await throttle.clear();
    } else {
      await throttle.withdrawFailure();
    }
    return (right: true, wait: Duration.zero);
  }
  return (right: false, wait: wait);
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
