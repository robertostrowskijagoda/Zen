import 'dart:async';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';

/// How often the optional look around runs without the "W pobliżu" screen
/// (§15).
const Duration kNearbyLookEvery = Duration(minutes: 5);

/// How long one such look around lasts.
const Duration kNearbyLookFor = Duration(seconds: 10);

/// Keeps "people nearby" working where no "W pobliżu" screen is open.
///
/// In the Android background service ([inService]), while the app is
/// closed or away:
///  - while the person is visible ([MeetBook.nearbyVisible]) it shows this
///    phone all the time (low-power advertising: cheap, unlike scanning),
///    and again as soon as Bluetooth is back on;
///  - with "Alarm do pobliża" on (§16.3) it answers alarm waves from
///    phones around through [MeetService.onAlarmWave]: a friend's signed
///    wave rings like an alarm from the network, anything else is at most
///    a quiet unchecked note;
///  - this person's own alarm raised here (the power-button shortcut, a
///    dating deadline) goes out nearby too.
///
/// Anywhere, when the person allowed it ([MeetBook.nearbyBackgroundScan]):
/// a short low-power look around every [lookEvery], which only marks
/// friends in range met in person. Friends' alarms heard only over
/// Bluetooth end after [kNearbyAlarmLife].
final class NearbyKeeper {
  NearbyKeeper({
    required this.nearby,
    required this.inService,
    this.announceAlarmReceiver,
    this.active,
    this.lookEvery = kNearbyLookEvery,
    this.lookFor = kNearbyLookFor,
    this.tick = const Duration(minutes: 1),
    this.waveListen = const Duration(seconds: 6),
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final NearbyService nearby;

  /// Runs in the Android background service (shows this phone and answers
  /// alarm waves); in the app only the look around runs.
  final bool inService;

  /// Tells the radio side that alarm waves are answered here from now on
  /// (or no longer), so the app leaves them alone.
  final Future<void> Function(bool on)? announceAlarmReceiver;

  /// Whether a look around may run now (the app: only while on screen —
  /// the background service covers the rest).
  final bool Function()? active;

  final Duration lookEvery;
  final Duration lookFor;

  /// How often [lookIfDue] is checked.
  final Duration tick;

  /// How long this person's own alarm first looks for phones around.
  final Duration waveListen;
  final int Function() _now;

  Timer? _timer;
  bool _closed = false;
  bool _alarms = false;
  int _lastLookAt = 0;

  /// The last alarm wave being handled (tests wait for it).
  Future<void>? pendingWave;

  MeetService get meet => nearby.meet;

  /// Whether alarm waves are answered here now.
  bool get receivesAlarms => _alarms;

  Future<void> start() async {
    _lastLookAt = _now();
    if (inService) {
      // This person's own alarm raised here goes nearby too (when they
      // chose that: [MeetService.raiseAlarm] checks).
      meet.nearbyBroadcast = _broadcast;
      // Bluetooth back on: shown again (the radio forgot it).
      nearby.bluetoothHandlers.add(_onBluetooth);
    }
    await refresh();
    if (_closed) {
      return;
    }
    _timer = Timer.periodic(tick, (_) {
      unawaitedLogged(
        meet.expireNearbyAlarms(),
        context: 'Alarm w pobliżu: wygasanie',
      );
      unawaitedLogged(lookIfDue(), context: 'W pobliżu: rozglądanie');
    });
  }

  void _onBluetooth(bool on) {
    unawaitedLogged(refresh(), context: 'W pobliżu: Bluetooth');
  }

  /// Reads the settings again (the app may have changed them) and applies
  /// them. Only the background service has anything to apply.
  Future<void> refresh() async {
    if (_closed || !inService) {
      return;
    }
    await meet.reload();
    nearby.friendsChanged();
    final Map<Object?, Object?> state = await nearby.radio.state();
    if (_closed) {
      return;
    }
    final MeetBook book = meet.book;
    final bool usable = state['permitted'] == true && state['enabled'] == true;
    final bool alarms = usable && book.alarmNearby && book.nearbyVisible;
    if (alarms != _alarms) {
      _alarms = alarms;
      if (alarms) {
        nearby.alarmWaveHandlers.add(_onWave);
      } else {
        nearby.alarmWaveHandlers.remove(_onWave);
      }
      await announceAlarmReceiver?.call(alarms);
    }
    // Shown whenever the person is visible: low-power advertising costs
    // little (scanning is what drains the battery), and friends' phones
    // can then send an alarm here and mark this phone met in person.
    final bool visible = usable && book.nearbyVisible;
    if (visible != nearby.visible) {
      await nearby.setVisible(visible);
    }
  }

  /// Runs the look around when it is due and allowed. Returns whether it
  /// ran.
  Future<bool> lookIfDue() async {
    if (_closed || !(active?.call() ?? true)) {
      return false;
    }
    final int t = _now();
    if (t - _lastLookAt < lookEvery.inMilliseconds) {
      return false;
    }
    _lastLookAt = t;
    await refresh();
    if (_closed || !meet.book.nearbyBackgroundScan) {
      return false;
    }
    return nearby.scanWindow(lookFor);
  }

  void _onWave(Map<dynamic, dynamic> json, String device) {
    final Future<void> handled = _onAlarmWave(json, device);
    pendingWave = handled;
    unawaitedLogged(handled, context: 'Alarm w pobliżu (w tle)');
  }

  Future<void> _onAlarmWave(Map<dynamic, dynamic> json, String device) async {
    // The app may have written the book meanwhile (a friend's secret, or
    // the network copy of this very alarm).
    await meet.reload();
    nearby.friendsChanged();
    await meet.onAlarmWave(
      json,
      friend: nearby.friendOfToken(json['t']),
      source: device,
    );
  }

  /// The wave already carries this phone's token and signature
  /// ([MeetService.alarmWave]).
  Future<int> _broadcast(Map<String, dynamic> wave) =>
      nearby.waveAround(wave, listen: waveListen);

  /// Stops; the [NearbyService] itself stays with its owner.
  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    _timer = null;
    nearby.alarmWaveHandlers.remove(_onWave);
    nearby.bluetoothHandlers.remove(_onBluetooth);
    if (inService) {
      meet.nearbyBroadcast = null;
    }
    if (_alarms) {
      _alarms = false;
      await announceAlarmReceiver?.call(false);
    }
  }
}
