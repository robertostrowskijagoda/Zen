import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/meet/nearby_look_policy.dart';

Map<Object?, Object?> _state({
  bool supported = true,
  bool permitted = true,
  bool enabled = true,
  Object? battery,
  bool charging = false,
  bool powerSave = false,
  bool idle = false,
}) => <Object?, Object?>{
  'supported': supported,
  'permitted': permitted,
  'enabled': enabled,
  'battery': ?battery,
  'charging': charging,
  'powerSave': powerSave,
  'idle': idle,
};

void main() {
  const NearbyLookPolicy policy = NearbyLookPolicy();

  test('a look is due every five minutes, for a few seconds', () {
    expect(policy.every, const Duration(minutes: 5));
    expect(policy.window.inSeconds, inInclusiveRange(3, 10));
    const int t0 = 1000000;
    expect(policy.due(t0 + 299999, t0), isFalse);
    expect(policy.due(t0 + 300000, t0), isTrue);
  });

  test('the radio must be there, allowed and on', () {
    expect(policy.skipFor(_state()), isNull);
    expect(
      policy.skipFor(_state(supported: false)),
      NearbyLookSkip.unsupported,
    );
    expect(
      policy.skipFor(const <Object?, Object?>{'supported': false}),
      NearbyLookSkip.unsupported,
      reason: 'desktops: no radio for this',
    );
    expect(
      policy.skipFor(_state(permitted: false)),
      NearbyLookSkip.noPermission,
    );
    expect(policy.skipFor(_state(enabled: false)), NearbyLookSkip.bluetoothOff);
  });

  test('low battery, battery saver and Doze stop it; charging lifts the '
      'first two', () {
    expect(policy.skipFor(_state(battery: 15)), isNull);
    expect(policy.skipFor(_state(battery: 14)), NearbyLookSkip.lowBattery);
    expect(policy.skipFor(_state(battery: 3, charging: true)), isNull);
    expect(policy.skipFor(_state(powerSave: true)), NearbyLookSkip.powerSave);
    expect(policy.skipFor(_state(powerSave: true, charging: true)), isNull);
    expect(policy.skipFor(_state(idle: true)), NearbyLookSkip.idle);
    expect(
      policy.skipFor(_state(idle: true, charging: true)),
      NearbyLookSkip.idle,
    );
    // Unknown battery (an old radio side) does not stop it; nonsense is
    // ignored.
    expect(policy.skipFor(_state(battery: 'x')), isNull);
    expect(policy.skipFor(_state(battery: 250)), isNull);
    expect(NearbyPower.fromState(_state(battery: 250)).battery, isNull);
  });

  test('a look listens all its window and costs mostly the awake phone', () {
    final double duty = nearbyLookDutyCycle();
    // 8 s of every 300 s: the look's scan listens all the time it runs.
    expect(duty, closeTo(8 / 300, 1e-9));
    // The phone kept awake for each look is the larger part: tens of mAh a
    // day with the defaults.
    final double radioOnly = 10 * duty * 24;
    final double perDay = nearbyLookMilliampHoursPerDay();
    expect(radioOnly, lessThan(perDay / 4));
    expect(perDay, greaterThan(20));
    expect(perDay, lessThan(80));
    // 288 looks of 8 s + 3 s awake at 40 mA, the radio listening 8 s at
    // 10 mA: less than the batched low-power look it replaced (8 s + 5 s
    // awake, the radio a tenth of 8 s).
    expect(perDay, closeTo(288 * (11 * 40 + 8 * 10) / 3600, 0.01));
    expect(perDay, lessThan(288 * (13 * 40 + 0.8 * 10) / 3600));
    expect(nearbyAdvertMilliampHoursPerDay(), closeTo(2.4, 0.01));
    expect(nearbyLookDutyCycle(every: Duration.zero), 0);
    expect(
      nearbyLookDutyCycle(
        every: const Duration(seconds: 1),
        window: const Duration(seconds: 5),
      ),
      1.0,
      reason: 'never more than all the time',
    );
  });

  test('with nobody new the wait doubles up to three times the chosen one '
      '(at most 30 min), and comes back at once', () {
    const Duration five = Duration(minutes: 5);
    expect(policy.longest, const Duration(minutes: 15));
    expect(nearbyLookMaxWait(const Duration(minutes: 2)).inMinutes, 6);
    expect(nearbyLookMaxWait(const Duration(minutes: 10)).inMinutes, 30);
    expect(nearbyLookMaxWait(const Duration(minutes: 15)).inMinutes, 30);
    expect(nearbyLookMaxWait(const Duration(minutes: 30)).inMinutes, 30);
    Duration wait = five;
    final List<int> waits = <int>[];
    for (int i = 0; i < 4; i++) {
      wait = nextNearbyLookWait(last: wait, fresh: false, base: five);
      waits.add(wait.inMinutes);
    }
    expect(waits, <int>[10, 15, 15, 15]);
    // Each a multiple of the chosen period: the looks keep sharing wakes.
    for (final int w in waits) {
      expect(w % 5, 0);
    }
    expect(nextNearbyLookWait(last: wait, fresh: true, base: five), five);
    // A shorter period chosen meanwhile is taken at once.
    expect(
      nextNearbyLookWait(
        last: const Duration(minutes: 2),
        fresh: false,
        base: five,
      ),
      five,
    );
    // 2 minutes chosen: 2, 4, 6; 30 minutes: always 30.
    expect(
      nextNearbyLookWait(
        last: const Duration(minutes: 4),
        fresh: false,
        base: const Duration(minutes: 2),
      ).inMinutes,
      6,
    );
    expect(
      nextNearbyLookWait(
        last: const Duration(minutes: 30),
        fresh: false,
        base: const Duration(minutes: 30),
      ).inMinutes,
      30,
    );
  });

  test('location off stops it where scans need location; the screen on is '
      'read', () {
    expect(
      policy.skipFor(<Object?, Object?>{
        ..._state(),
        'needsLocation': true,
        'locationOn': false,
      }),
      NearbyLookSkip.locationOff,
    );
    expect(
      policy.skipFor(<Object?, Object?>{
        ..._state(),
        'needsLocation': true,
        'locationOn': true,
      }),
      isNull,
    );
    expect(
      policy.skipFor(<Object?, Object?>{
        ..._state(),
        'needsLocation': false,
        'locationOn': false,
      }),
      isNull,
      reason: 'Android 12 and newer scan without location',
    );
    expect(
      NearbyPower.fromState(<Object?, Object?>{'interactive': true}).screenOn,
      isTrue,
    );
    expect(NearbyPower.fromState(_state()).screenOn, isFalse);
  });

  test('the stats count looks, scanning time and skips', () {
    final NearbyLookStats stats = NearbyLookStats()
      ..ran(const Duration(seconds: 8))
      ..ran(const Duration(seconds: 8))
      ..skip(NearbyLookSkip.lowBattery);
    expect(stats.looks, 2);
    expect(stats.scannedMillis, 16000);
    expect(stats.skipped[NearbyLookSkip.lowBattery], 1);
    expect(stats.toString(), contains('lowBattery 1'));
  });
}
