import 'package:flutter/foundation.dart';

/// How often the look around runs without the "W pobliżu" screen.
const Duration kNearbyLookEvery = Duration(minutes: 5);

/// How long one such look around lasts: a few seconds, so the
/// low-power scan opens one or two of its listening windows.
const Duration kNearbyLookFor = Duration(seconds: 8);

/// What the person may choose: minutes between looks ("Wyłączone" is the
/// switch, [MeetBook.nearbyBackgroundScan]) and seconds one look lasts.
const List<int> kNearbyLookEveryChoices = <int>[2, 5, 10, 15, 30];
const List<int> kNearbyLookForChoices = <int>[4, 8, 15];

/// [value] when it is one of [kNearbyLookEveryChoices], else the default.
int nearbyLookMinutesOf(Object? value) =>
    value is int && kNearbyLookEveryChoices.contains(value)
    ? value
    : kNearbyLookEvery.inMinutes;

/// [value] when it is one of [kNearbyLookForChoices], else the default.
int nearbyLookSecondsOf(Object? value) =>
    value is int && kNearbyLookForChoices.contains(value)
    ? value
    : kNearbyLookFor.inSeconds;

/// The battery the estimates are shown against.
const int kTypicalBatteryMah = 3000;

/// Below this battery level (per cent, not charging) no look runs.
const int kNearbyLookMinBattery = 15;

/// What `SCAN_MODE_LOW_POWER` does on Android: the radio listens
/// [kLowPowerScanListen] out of every [kLowPowerScanInterval].
const Duration kLowPowerScanListen = Duration(milliseconds: 512);
const Duration kLowPowerScanInterval = Duration(milliseconds: 5120);

/// Typical current of a phone's Bluetooth LE radio while it listens.
const double kBleListenMilliamps = 10;

/// The share of time the radio listens for the background look around:
/// [window] of every [every], and within it the low-power scan's own
/// listening share. With the defaults: 8 s / 300 s × 512 / 5120 ≈ 0.27 %.
double nearbyLookDutyCycle({
  Duration every = kNearbyLookEvery,
  Duration window = kNearbyLookFor,
}) {
  if (every <= Duration.zero) {
    return 0;
  }
  final double share = (window.inMilliseconds / every.inMilliseconds)
      .clamp(0.0, 1.0)
      .toDouble();
  return share *
      kLowPowerScanListen.inMilliseconds /
      kLowPowerScanInterval.inMilliseconds;
}

/// What a phone draws while a look around keeps it awake with the screen
/// off (processor, memory, radio driver): tens of milliamps on most phones.
const double kAwakeMilliamps = 40;

/// How long a look keeps the phone awake besides its own window: waking up,
/// the results the low-power scan batches ([kLookBatchGrace]) and handing
/// them over.
const Duration kLookBatchGrace = Duration(seconds: 3);
const Duration kLookWakeOverhead = Duration(seconds: 2);

/// What showing this phone nearby costs ("W pobliżu": a low-power,
/// connectable advert about once a second, all the time it is on), on
/// average.
const double kBleAdvertMilliamps = 0.1;

/// Roughly what the background look around costs a day, in mAh: each look
/// wakes the sleeping phone for its window plus [kLookBatchGrace] and
/// [kLookWakeOverhead] at [kAwakeMilliamps], and the radio listens for its
/// share of the window. The awake phone is by far the larger part (the
/// radio alone would be well under 1 mAh). An estimate for a typical
/// phone, not a measurement: phones differ, and no look runs while the
/// phone sleeps deeply (Doze) — then it costs nothing.
double nearbyLookMilliampHoursPerDay({
  Duration every = kNearbyLookEvery,
  Duration window = kNearbyLookFor,
}) {
  if (every <= Duration.zero) {
    return 0;
  }
  final double looksPerDay =
      const Duration(days: 1).inMilliseconds / every.inMilliseconds;
  final double awakeSeconds =
      (window + kLookBatchGrace + kLookWakeOverhead).inMilliseconds / 1000;
  final double listenSeconds =
      window.inMilliseconds /
      1000 *
      kLowPowerScanListen.inMilliseconds /
      kLowPowerScanInterval.inMilliseconds;
  final double milliampSeconds =
      awakeSeconds * kAwakeMilliamps + listenSeconds * kBleListenMilliamps;
  return looksPerDay * milliampSeconds / 3600;
}

/// Roughly what showing this phone nearby costs a day, in mAh (the advert
/// goes out while the phone sleeps; it needs no awake processor).
double nearbyAdvertMilliampHoursPerDay() => kBleAdvertMilliamps * 24;

/// The phone's power as the radio side reports it with `state`
/// (`battery` in per cent, `charging`, `powerSave` for battery saver,
/// `idle` for Doze).
@immutable
final class NearbyPower {
  const NearbyPower({
    this.battery,
    this.charging = false,
    this.powerSave = false,
    this.idle = false,
  });

  /// Per cent; `null` when unknown (a desktop, an old radio side).
  final int? battery;
  final bool charging;
  final bool powerSave;
  final bool idle;

  static NearbyPower fromState(Map<Object?, Object?> state) {
    final Object? battery = state['battery'];
    return NearbyPower(
      battery: battery is int && battery >= 0 && battery <= 100
          ? battery
          : null,
      charging: state['charging'] == true,
      powerSave: state['powerSave'] == true,
      idle: state['idle'] == true,
    );
  }
}

/// Why a look around did not run.
enum NearbyLookSkip {
  /// Not [NearbyLookPolicy.every] since the last one.
  notDue,

  /// "Rozglądaj się też w tle" is off (or "Mijani" in the locked service).
  off,

  /// No Bluetooth LE radio here (desktops, iOS: never in the background).
  unsupported,
  noPermission,
  bluetoothOff,

  /// Below [NearbyLookPolicy.minBattery] and not charging.
  lowBattery,

  /// Battery saver on and not charging.
  powerSave,

  /// The phone sleeps (Doze).
  idle,

  /// Something else scans or holds the radio now.
  busy,
}

/// When the cheap background look around runs: every [every] for
/// [window], in the radio's low-power mode, never on low battery, in
/// battery saver or while the phone sleeps (unless it charges — then
/// battery and saver do not matter, Doze never comes while charging).
@immutable
final class NearbyLookPolicy {
  const NearbyLookPolicy({
    this.every = kNearbyLookEvery,
    this.window = kNearbyLookFor,
    this.minBattery = kNearbyLookMinBattery,
  });

  final Duration every;
  final Duration window;
  final int minBattery;

  /// Whether a look is due at [now] after the last one at [lastLookAt].
  bool due(int now, int lastLookAt) => now - lastLookAt >= every.inMilliseconds;

  /// Why the radio's [state] does not allow a look now (`null`: it does).
  NearbyLookSkip? skipFor(Map<Object?, Object?> state) {
    if (state['supported'] == false) {
      return NearbyLookSkip.unsupported;
    }
    if (state['permitted'] != true) {
      return NearbyLookSkip.noPermission;
    }
    if (state['enabled'] != true) {
      return NearbyLookSkip.bluetoothOff;
    }
    final NearbyPower power = NearbyPower.fromState(state);
    if (power.idle) {
      return NearbyLookSkip.idle;
    }
    if (power.charging) {
      return null;
    }
    final int? battery = power.battery;
    if (battery != null && battery < minBattery) {
      return NearbyLookSkip.lowBattery;
    }
    if (power.powerSave) {
      return NearbyLookSkip.powerSave;
    }
    return null;
  }
}

/// What the looks around cost so far (logged now and then, shown to
/// nobody): how many ran, how many were skipped and why, and how long the
/// radio scanned.
final class NearbyLookStats {
  int looks = 0;
  int scannedMillis = 0;
  final Map<NearbyLookSkip, int> skipped = <NearbyLookSkip, int>{};

  void skip(NearbyLookSkip why) => skipped[why] = (skipped[why] ?? 0) + 1;

  void ran(Duration window) {
    looks += 1;
    scannedMillis += window.inMilliseconds;
  }

  @override
  String toString() =>
      '$looks look(s), ${scannedMillis ~/ 1000} s scanning, skipped: '
      '${skipped.entries.map((MapEntry<NearbyLookSkip, int> e) => '${e.key.name} ${e.value}').join(', ')}';
}

/// [nearbyLookMilliampHoursPerDay] as a share of a [kTypicalBatteryMah]
/// battery, in per cent.
double nearbyLookBatteryPercentPerDay({
  Duration every = kNearbyLookEvery,
  Duration window = kNearbyLookFor,
}) =>
    nearbyLookMilliampHoursPerDay(every: every, window: window) /
    kTypicalBatteryMah *
    100;
