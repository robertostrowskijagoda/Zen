import 'package:flutter/foundation.dart';

/// How often the look around runs without the "W pobliżu" screen, at the
/// most (in the locked service: at first, and again once a look finds
/// someone new, [nextNearbyLookWait]).
const Duration kNearbyLookEvery = Duration(minutes: 5);

/// How long one such look around lasts: a few seconds, so every phone
/// shown nearby (an advert about once a second) is heard several times.
const Duration kNearbyLookFor = Duration(seconds: 8);

/// The longest wait between looks in the locked service, whatever was
/// chosen.
const Duration kNearbyLookMaxWait = Duration(minutes: 30);

/// The longest wait between looks in the locked service for looks chosen
/// [every]: three times it, at most [kNearbyLookMaxWait], never shorter
/// than [every] (5 min: up to 15; 2 min: up to 6; 10: up to 30; 30: 30).
Duration nearbyLookMaxWait(Duration every) {
  final Duration tripled = every * 3;
  final Duration capped = tripled > kNearbyLookMaxWait
      ? kNearbyLookMaxWait
      : tripled;
  return capped < every ? every : capped;
}

/// The wait before the next look in the locked service, after one that
/// waited [last]: [base] (the chosen period) when the look found someone
/// new or the screen was on (the phone is in use, maybe on the move);
/// otherwise twice [last], at most [max] ([nearbyLookMaxWait]). With 5
/// minutes chosen and nobody new around: 5, 10, 15, 15… minutes, all
/// multiples of the chosen period, so the looks keep sharing their wakes
/// with the mailbox polls.
Duration nextNearbyLookWait({
  required Duration last,
  required bool fresh,
  required Duration base,
  Duration? max,
}) {
  final Duration longest = max ?? nearbyLookMaxWait(base);
  if (fresh || last < base) {
    return base;
  }
  final Duration doubled = last * 2;
  return doubled > longest ? longest : doubled;
}

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

/// Typical current of a phone's Bluetooth LE radio while it listens.
const double kBleListenMilliamps = 10;

/// The share of time the radio listens for the background look around:
/// [window] of every [every] (the look's scan listens all the time it
/// runs: `SCAN_MODE_LOW_LATENCY`, ZenNearbyBridge.kt). With the defaults:
/// 8 s / 300 s ≈ 2.7 %.
double nearbyLookDutyCycle({
  Duration every = kNearbyLookEvery,
  Duration window = kNearbyLookFor,
}) {
  if (every <= Duration.zero) {
    return 0;
  }
  return (window.inMilliseconds / every.inMilliseconds)
      .clamp(0.0, 1.0)
      .toDouble();
}

/// What a phone draws while a look around keeps it awake with the screen
/// off (processor, memory, radio driver): tens of milliamps on most phones.
const double kAwakeMilliamps = 40;

/// How long a look keeps the phone awake besides its own window: the last
/// results on their way from the radio ([kLookLateResults]: they are never
/// batched, so a moment is enough), and waking up, reading the radio's
/// state and letting go ([kLookWakeOverhead]).
const Duration kLookLateResults = Duration(seconds: 1);
const Duration kLookWakeOverhead = Duration(seconds: 2);

/// What showing this phone nearby costs ("W pobliżu": a low-power,
/// connectable advert about once a second, all the time it is on), on
/// average.
const double kBleAdvertMilliamps = 0.1;

/// Roughly what the background look around costs a day, in mAh: each look
/// wakes the sleeping phone for its window plus [kLookLateResults] and
/// [kLookWakeOverhead] at [kAwakeMilliamps], and the radio listens through
/// the window. The awake phone is the larger part. An estimate for a
/// typical phone, not a measurement: phones differ.
///
/// An upper bound: with nobody new around, the locked service looks up to
/// three times less often ([nextNearbyLookWait]); the look shares its wake
/// with the mailbox polls (`LockedReceiver`), which wake the phone anyway,
/// and then adds only its window. In deep sleep (Doze) its alarm waits for
/// Doze's own window and the look is skipped then. With Bluetooth off or no
/// permission no look is planned at all.
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
      (window + kLookLateResults + kLookWakeOverhead).inMilliseconds / 1000;
  final double listenSeconds = window.inMilliseconds / 1000;
  final double milliampSeconds =
      awakeSeconds * kAwakeMilliamps + listenSeconds * kBleListenMilliamps;
  return looksPerDay * milliampSeconds / 3600;
}

/// Roughly what showing this phone nearby costs a day, in mAh (the advert
/// goes out while the phone sleeps; it needs no awake processor).
double nearbyAdvertMilliampHoursPerDay() => kBleAdvertMilliamps * 24;

/// The phone's power as the radio side reports it with `state`
/// (`battery` in per cent, `charging`, `powerSave` for battery saver,
/// `idle` for Doze, `interactive` for the screen on).
@immutable
final class NearbyPower {
  const NearbyPower({
    this.battery,
    this.charging = false,
    this.powerSave = false,
    this.idle = false,
    this.screenOn = false,
  });

  /// Per cent; `null` when unknown (a desktop, an old radio side).
  final int? battery;
  final bool charging;
  final bool powerSave;
  final bool idle;
  final bool screenOn;

  static NearbyPower fromState(Map<Object?, Object?> state) {
    final Object? battery = state['battery'];
    return NearbyPower(
      battery: battery is int && battery >= 0 && battery <= 100
          ? battery
          : null,
      charging: state['charging'] == true,
      powerSave: state['powerSave'] == true,
      idle: state['idle'] == true,
      screenOn: state['interactive'] == true,
    );
  }
}

/// Whether the radio's [state] says a scan hears nobody because location
/// is switched off (Android 11 and older need it on for Bluetooth scans).
bool nearbyNeedsLocationOn(Map<Object?, Object?> state) =>
    state['needsLocation'] == true && state['locationOn'] == false;

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

  /// Location is off where scans need it ([nearbyNeedsLocationOn]).
  locationOff,

  /// Below [NearbyLookPolicy.minBattery] and not charging.
  lowBattery,

  /// Battery saver on and not charging.
  powerSave,

  /// The phone sleeps (Doze).
  idle,

  /// Something else scans or holds the radio now.
  busy,
}

/// When the short background look around runs: every [every] for
/// [window] (in the locked service up to [longest] apart while nobody new
/// is around), never on low battery, in battery saver, while the phone
/// sleeps (unless it charges — then battery and saver do not matter, Doze
/// never comes while charging) or with location off where scans need it.
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

  /// The longest wait between looks while nobody new is around
  /// ([nextNearbyLookWait]).
  Duration get longest => nearbyLookMaxWait(every);

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
    if (nearbyNeedsLocationOn(state)) {
      return NearbyLookSkip.locationOff;
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
