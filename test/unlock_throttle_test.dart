import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The lock screen slows password guessing down, and the counter
/// survives a restart.
void main() {
  late MemorySecurityCredentialsStore store;
  late DateTime now;
  late Duration steady;

  UnlockThrottle throttle() => UnlockThrottle(store, monotonic: () => steady);

  /// Time that really passes: both clocks move.
  void pass(Duration time) {
    now = now.add(time);
    steady += time;
  }

  setUp(() {
    store = MemorySecurityCredentialsStore();
    now = DateTime.utc(2026, 10, 21, 12);
    steady = Duration.zero;
  });

  test('the waits: none for five failures, then 30 s doubling to a cap', () {
    expect(UnlockThrottle.delayAfter(0), Duration.zero);
    expect(UnlockThrottle.delayAfter(4), Duration.zero);
    expect(UnlockThrottle.delayAfter(5), const Duration(seconds: 30));
    expect(UnlockThrottle.delayAfter(6), const Duration(seconds: 60));
    expect(UnlockThrottle.delayAfter(7), const Duration(seconds: 120));
    expect(UnlockThrottle.delayAfter(10), const Duration(minutes: 16));
    expect(UnlockThrottle.delayAfter(11), UnlockThrottle.maxDelay);
    expect(UnlockThrottle.delayAfter(500), UnlockThrottle.maxDelay);
    expect(UnlockThrottle.maxDelay, const Duration(minutes: 30));
  });

  test('four failures cost nothing, the fifth starts a wait', () async {
    final UnlockThrottle counter = throttle();
    for (int i = 0; i < 4; i++) {
      expect(await counter.recordFailure(), Duration.zero);
      expect(await counter.remaining(), Duration.zero);
    }
    expect(await counter.recordFailure(), const Duration(seconds: 30));
    expect(await counter.remaining(), const Duration(seconds: 30));
  });

  test(
    'the wait runs down with the clock and the next one is longer',
    () async {
      final UnlockThrottle counter = throttle();
      for (int i = 0; i < 5; i++) {
        await counter.recordFailure();
      }
      pass(const Duration(seconds: 12));
      expect(await counter.remaining(), const Duration(seconds: 18));
      pass(const Duration(seconds: 18));
      expect(await counter.remaining(), Duration.zero);

      expect(await counter.recordFailure(), const Duration(seconds: 60));
      pass(const Duration(seconds: 59));
      expect(await counter.remaining(), const Duration(seconds: 1));
    },
  );

  test('it lives in the secure storage: a new object sees it', () async {
    for (int i = 0; i < 6; i++) {
      await throttle().recordFailure();
    }
    expect(await store.read(appSecurityUnlockFailuresStorageKey), isNotNull);
    final UnlockThrottle afterRestart = throttle();
    expect(await afterRestart.remaining(), const Duration(seconds: 60));
  });

  test('the right password starts the count again', () async {
    final UnlockThrottle counter = throttle();
    for (int i = 0; i < 7; i++) {
      await counter.recordFailure();
    }
    await counter.clear();
    expect(await store.read(appSecurityUnlockFailuresStorageKey), isNull);
    expect(await counter.remaining(), Duration.zero);
    expect(await counter.recordFailure(), Duration.zero);
  });

  test('setting the clock back does not shorten the wait', () async {
    final UnlockThrottle counter = throttle();
    for (int i = 0; i < 5; i++) {
      await counter.recordFailure();
    }
    now = now.subtract(const Duration(days: 1));
    expect(await counter.remaining(), const Duration(seconds: 30));
  });

  test('setting the clock forward does not end the wait early', () async {
    final UnlockThrottle counter = throttle();
    for (int i = 0; i < 5; i++) {
      await counter.recordFailure();
    }
    pass(const Duration(seconds: 10));
    // The system clock jumps a day ahead; the monotonic one does not.
    now = now.add(const Duration(days: 1));
    expect(await counter.remaining(), const Duration(seconds: 20));
    pass(const Duration(seconds: 20));
    expect(await counter.remaining(), Duration.zero);
  });

  test('a restart with the clock set forward keeps the whole wait', () async {
    final UnlockThrottle first = throttle();
    for (int i = 0; i < 12; i++) {
      await first.recordFailure();
    }
    expect(await first.remaining(), UnlockThrottle.maxDelay);
    // A restart (a new counter, its monotonic clock from zero) an hour
    // later by the system clock.
    now = now.add(const Duration(hours: 1));
    steady = Duration.zero;
    final UnlockThrottle restarted = throttle();
    expect(await restarted.remaining(), UnlockThrottle.maxDelay);
    pass(const Duration(minutes: 10));
    expect(await restarted.remaining(), const Duration(minutes: 20));
  });

  test('after a restart the wait left at the last look starts again in '
      'full, whichever way the clock was moved', () async {
    final UnlockThrottle counter = throttle();
    for (int i = 0; i < 5; i++) {
      await counter.recordFailure();
    }
    pass(const Duration(seconds: 12));
    expect(await counter.remaining(), const Duration(seconds: 18));
    for (final Duration moved in <Duration>[
      const Duration(days: -1),
      const Duration(days: 2),
    ]) {
      now = now.add(moved);
      steady = Duration.zero;
      final UnlockThrottle restarted = throttle();
      expect(await restarted.remaining(), const Duration(seconds: 18));
      pass(const Duration(seconds: 8));
      expect(await restarted.remaining(), const Duration(seconds: 10));
      // The next restart goes on from there.
      steady = Duration.zero;
      expect(await throttle().remaining(), const Duration(seconds: 10));
      pass(const Duration(seconds: 10));
      expect(await throttle().remaining(), const Duration(seconds: 10));
      await store.write(appSecurityUnlockFailuresStorageKey, '5;18000');
    }
  });

  test('a count an earlier version kept keeps its whole wait', () async {
    await store.write(
      appSecurityUnlockFailuresStorageKey,
      '6:${now.millisecondsSinceEpoch}',
    );
    now = now.add(const Duration(days: 3));
    expect(await throttle().remaining(), const Duration(seconds: 60));
  });

  test('there is no lock-out: any wait ends', () async {
    final UnlockThrottle counter = throttle();
    for (int i = 0; i < 40; i++) {
      await counter.recordFailure();
    }
    expect(await counter.remaining(), UnlockThrottle.maxDelay);
    pass(UnlockThrottle.maxDelay);
    expect(await counter.remaining(), Duration.zero);
  });

  test('garbage in the storage counts as no failures', () async {
    await store.write(appSecurityUnlockFailuresStorageKey, 'wat');
    expect(await throttle().remaining(), Duration.zero);
    await store.write(appSecurityUnlockFailuresStorageKey, '-3:0');
    expect(await throttle().remaining(), Duration.zero);
  });

  group('counted before the password is checked', () {
    test('Zen closed during the check leaves the attempt counted', () async {
      final List<String?> seenByCheck = <String?>[];
      Future<bool> closedDuringCheck() async {
        // What a start after this moment would find.
        seenByCheck.add(await store.read(appSecurityUnlockFailuresStorageKey));
        throw StateError('Zen was closed');
      }

      await expectLater(
        tryPassword(throttle(), closedDuringCheck),
        throwsStateError,
      );
      expect(seenByCheck, <String?>['1;0']);
      await expectLater(
        tryPassword(throttle(), closedDuringCheck),
        throwsStateError,
      );
      expect(seenByCheck.last, '2;0');
    });

    test('the right password clears the count, or takes back only its own '
        'attempt', () async {
      final UnlockThrottle counter = throttle();
      for (int i = 0; i < 3; i++) {
        await counter.recordFailure();
      }
      final String? before = await store.read(
        appSecurityUnlockFailuresStorageKey,
      );
      String? duringCheck;
      Future<bool> right() async {
        duringCheck = await store.read(appSecurityUnlockFailuresStorageKey);
        return true;
      }

      expect(await tryPassword(counter, right, clears: false), (
        right: true,
        wait: Duration.zero,
      ));
      expect(duringCheck, startsWith('4;'));
      expect(await store.read(appSecurityUnlockFailuresStorageKey), before);
      expect(await counter.recordFailure(), Duration.zero);
      expect(await counter.recordFailure(), UnlockThrottle.baseDelay);

      pass(UnlockThrottle.baseDelay);
      expect(await tryPassword(counter, right), (
        right: true,
        wait: Duration.zero,
      ));
      expect(duringCheck, startsWith('6;'));
      expect(await store.read(appSecurityUnlockFailuresStorageKey), isNull);
    });

    test('a wrong password gets the wait its attempt started', () async {
      final UnlockThrottle counter = throttle();
      for (int i = 0; i < 4; i++) {
        expect(await tryPassword(counter, () async => false), (
          right: false,
          wait: Duration.zero,
        ));
      }
      expect(await tryPassword(counter, () async => false), (
        right: false,
        wait: UnlockThrottle.baseDelay,
      ));
      int checks = 0;
      expect(await tryPassword(counter, () async => ++checks > 0), (
        right: false,
        wait: UnlockThrottle.baseDelay,
      ));
      expect(checks, 0);
    });
  });

  group('guesses at another account are forgiven slowly', () {
    UnlockThrottle others() => UnlockThrottle.otherAccounts(
      store: store,
      monotonic: () => steady,
      wallClock: () => now,
    );

    Future<String?> stored() =>
        store.read(UnlockThrottle.otherAccountsStorageKey);

    Future<void> fail(UnlockThrottle counter, int times) async {
      for (int i = 0; i < times; i++) {
        await counter.remaining();
        await counter.recordFailure();
      }
    }

    test('one for every day without a wrong one, never below zero; a wrong '
        'one starts the day again', () async {
      final UnlockThrottle counter = others();
      await fail(counter, 6);
      expect(await counter.remaining(), const Duration(seconds: 60));
      pass(const Duration(hours: 23, minutes: 59));
      expect(await counter.remaining(), Duration.zero);
      expect(await stored(), startsWith('6;'));
      pass(const Duration(minutes: 1));
      await counter.remaining();
      expect(await stored(), startsWith('5;'));
      pass(UnlockThrottle.forgivenAfter);
      await counter.remaining();
      expect(await stored(), startsWith('4;'));

      // A wrong one: counted, and the next day starts from it.
      pass(const Duration(hours: 20));
      await fail(counter, 1);
      expect(await stored(), startsWith('5;'));
      pass(const Duration(hours: 23));
      await counter.remaining();
      expect(await stored(), startsWith('5;'));
      pass(const Duration(hours: 1));
      await counter.remaining();
      expect(await stored(), startsWith('4;'));

      pass(const Duration(days: 30));
      expect(await counter.remaining(), Duration.zero);
      expect(await stored(), isNull);
      expect(await counter.recordFailure(), Duration.zero);
      expect(await stored(), startsWith('1;'));
    });

    test('days Zen was closed count once it has run for the longest wait '
        'since the last wrong one', () async {
      await fail(others(), 6);
      pass(const Duration(minutes: 1));
      await others().remaining();
      // Closed for three days, then started again.
      now = now.add(const Duration(days: 3));
      steady = Duration.zero;
      final UnlockThrottle restarted = others();
      expect(await restarted.remaining(), const Duration(seconds: 60));
      pass(const Duration(seconds: 60));
      expect(await restarted.remaining(), Duration.zero);
      expect(await stored(), startsWith('6;'));
      pass(UnlockThrottle.forgivingRunTime);
      await restarted.remaining();
      expect(await stored(), startsWith('5;'));
      pass(UnlockThrottle.forgivingRunTime);
      await restarted.remaining();
      expect(await stored(), startsWith('4;'));
      pass(UnlockThrottle.forgivingRunTime);
      await restarted.remaining();
      expect(await stored(), startsWith('3;'));
      // Three days, three forgiven: the fourth needs a fourth day.
      pass(UnlockThrottle.forgivingRunTime * 4);
      await restarted.remaining();
      expect(await stored(), startsWith('3;'));
    });

    test('setting the clock ahead, once or at every start, forgives no more '
        'than one per longest wait Zen really ran', () async {
      final UnlockThrottle counter = others();
      await fail(counter, 12);
      pass(UnlockThrottle.maxDelay);
      expect(await counter.remaining(), Duration.zero);
      expect(await stored(), startsWith('12;'));
      // Years ahead at once: one forgiven, for the half hour Zen ran.
      now = now.add(const Duration(days: 1000));
      await counter.remaining();
      expect(await stored(), startsWith('11;'));
      await counter.remaining();
      expect(await stored(), startsWith('11;'));

      // Started again and again, the clock set a few days ahead each time:
      // no running time, nothing forgiven.
      for (int i = 0; i < 50; i++) {
        now = now.add(const Duration(days: 3));
        steady = Duration.zero;
        final UnlockThrottle restarted = others();
        await restarted.remaining();
        pass(const Duration(seconds: 20));
        await restarted.remaining();
      }
      expect(await stored(), startsWith('11;'));

      final UnlockThrottle running = others();
      await running.remaining();
      pass(UnlockThrottle.forgivingRunTime - const Duration(seconds: 1));
      await running.remaining();
      expect(await stored(), startsWith('11;'));
      pass(const Duration(seconds: 1));
      await running.remaining();
      expect(await stored(), startsWith('10;'));
    });

    test(
      'a clock set back forgives nothing; a day of running time does',
      () async {
        final UnlockThrottle counter = others();
        await fail(counter, 6);
        pass(const Duration(hours: 1));
        now = now.subtract(const Duration(days: 10));
        await counter.remaining();
        expect(await stored(), startsWith('6;'));
        // Running time alone: a full day of it.
        pass(const Duration(hours: 22, minutes: 59));
        await counter.remaining();
        expect(await stored(), startsWith('6;'));
        pass(const Duration(minutes: 1));
        await counter.remaining();
        expect(await stored(), startsWith('5;'));
      },
    );

    test('never during a wait', () async {
      final int dayBefore = now
          .subtract(const Duration(days: 3))
          .millisecondsSinceEpoch;
      // A minute of the wait left, hours of running time and days on the
      // wall clock.
      await store.write(
        UnlockThrottle.otherAccountsStorageKey,
        '12;60000;$dayBefore;${const Duration(hours: 5).inMilliseconds}',
      );
      final UnlockThrottle counter = others();
      expect(await counter.remaining(), const Duration(minutes: 1));
      expect(await stored(), startsWith('12;'));
      pass(const Duration(minutes: 1));
      expect(await counter.remaining(), Duration.zero);
      expect(await stored(), startsWith('9;'));
    });

    test('the lock screen count is not forgiven: the right password '
        'clears it', () async {
      final UnlockThrottle counter = UnlockThrottle(
        store,
        monotonic: () => steady,
        wallClock: () => now,
      );
      for (int i = 0; i < 6; i++) {
        await counter.recordFailure();
      }
      pass(const Duration(days: 10));
      await counter.remaining();
      expect(
        await store.read(appSecurityUnlockFailuresStorageKey),
        startsWith('6;'),
      );
    });

    test('a count kept by an earlier version starts its day at the first '
        'look', () async {
      await store.write(UnlockThrottle.otherAccountsStorageKey, '7;0');
      final UnlockThrottle counter = others();
      expect(await counter.remaining(), Duration.zero);
      expect(await stored(), '7;0;${now.millisecondsSinceEpoch};0');
      pass(UnlockThrottle.forgivenAfter);
      await counter.remaining();
      expect(await stored(), startsWith('6;'));
    });

    test('two copies of Zen looking in turn add up the time that passed, '
        'not each its own', () async {
      final UnlockThrottle first = others();
      await fail(first, 12);
      final UnlockThrottle second = others();
      now = now.add(const Duration(days: 5));
      for (int minute = 0; minute < 29; minute++) {
        pass(const Duration(minutes: 1));
        await first.remaining();
        await second.remaining();
      }
      expect(await stored(), startsWith('12;'));
      pass(const Duration(minutes: 1));
      await first.remaining();
      expect(await stored(), startsWith('11;'));
    });

    test('an attempt taken back leaves the entry as it was, forgiveness '
        'earned until then included', () async {
      final UnlockThrottle counter = others();
      await fail(counter, 3);
      pass(const Duration(hours: 2));
      await counter.remaining();
      final String? before = await stored();
      await counter.recordFailure();
      expect(await stored(), startsWith('4;'));
      await counter.withdrawFailure();
      expect(await stored(), before);
      pass(const Duration(hours: 21, minutes: 59));
      await counter.remaining();
      expect(await stored(), startsWith('3;'));
      pass(const Duration(minutes: 1));
      await counter.remaining();
      expect(await stored(), startsWith('2;'));
      // Taken back once only.
      await counter.withdrawFailure();
      expect(await stored(), startsWith('2;'));
    });

    test(
      'an attempt counted by someone else meanwhile is not taken back',
      () async {
        final UnlockThrottle counter = others();
        await fail(counter, 2);
        await counter.recordFailure();
        await others().recordFailure();
        await counter.withdrawFailure();
        expect(await stored(), startsWith('4;'));
      },
    );
  });

  test('erasing the device also erases the counter', () async {
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: store,
      passwordIterations: 10,
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('sekret12');
    for (int i = 0; i < 5; i++) {
      await throttle().recordFailure();
    }
    expect(await throttle().remaining(), isNot(Duration.zero));

    await security.reset();
    expect(await store.read(appSecurityUnlockFailuresStorageKey), isNull);
    expect(await throttle().remaining(), Duration.zero);
  });
}
