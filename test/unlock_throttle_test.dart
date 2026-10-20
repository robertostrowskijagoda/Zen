import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// Z2-9: the lock screen slows password guessing down, and the counter
/// survives a restart.
void main() {
  late MemorySecurityCredentialsStore store;
  late DateTime now;
  late Duration steady;

  UnlockThrottle throttle() =>
      UnlockThrottle(store, now: () => now, monotonic: () => steady);

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
