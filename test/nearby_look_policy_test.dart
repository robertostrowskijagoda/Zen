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

  test('the duty cycle stays far below one per cent of the time', () {
    final double duty = nearbyLookDutyCycle();
    // 8 s of every 300 s, the low-power scan listening a tenth of it.
    expect(duty, closeTo(8 / 300 * 0.1, 1e-9));
    expect(duty, lessThan(0.005));
    // The radio alone would cost well under 1 mAh a day; the phone kept
    // awake for each look is what counts: tens of mAh with the defaults.
    final double radioOnly = 10 * duty * 24;
    expect(radioOnly, lessThan(1.0));
    final double perDay = nearbyLookMilliampHoursPerDay();
    expect(perDay, greaterThan(20));
    expect(perDay, lessThan(80));
    // 288 looks of 8 s + 5 s awake at 40 mA, plus the radio's share.
    expect(perDay, closeTo(288 * (13 * 40 + 0.8 * 10) / 3600, 0.01));
    expect(nearbyAdvertMilliampHoursPerDay(), closeTo(2.4, 0.01));
    expect(nearbyLookDutyCycle(every: Duration.zero), 0);
    expect(
      nearbyLookDutyCycle(
        every: const Duration(seconds: 1),
        window: const Duration(seconds: 5),
      ),
      closeTo(0.1, 1e-9),
      reason: 'never more than the scan mode itself',
    );
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
