import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Work that runs later, also while an Android phone sleeps.
abstract interface class WakeTimer {
  bool get isActive;

  void cancel();
}

/// How work reaches a sleeping phone, and how long the phone stays awake.
///
/// On Android nothing holds the processor awake for good (the background
/// service's own lock is off): with the screen off the phone sleeps, Dart
/// timers stand still, and only an alarm ([after]) or an arriving packet
/// wakes it. Each wake holds the phone awake for a short, limited time
/// ([hold]); a call holds it for as long as it runs ([holdForCall]).
/// Elsewhere (and in tests) these are plain timers and the holds do
/// nothing.
abstract interface class ZenWakePlatform {
  /// Runs [fire] once after [delay]; on Android an alarm that wakes the
  /// phone and keeps it awake for [hold]. [exact]: on time even in Doze
  /// (when the person allowed exact alarms).
  WakeTimer after(
    String name,
    Duration delay,
    void Function() fire, {
    required Duration hold,
    required bool exact,
  });

  /// Keeps the phone awake for [duration] under [tag] (the longest wins).
  Future<void> hold(String tag, Duration duration);

  Future<void> release(String tag);

  /// Keeps the phone and Wi-Fi awake while a call runs.
  Future<void> holdForCall(bool on);

  /// The app's engine went away (Android): the background service should
  /// take the node over now.
  Stream<void> get appGone;
}

/// Plain timers: computers, iOS and tests.
final class TimerWakePlatform implements ZenWakePlatform {
  const TimerWakePlatform();

  @override
  WakeTimer after(
    String name,
    Duration delay,
    void Function() fire, {
    required Duration hold,
    required bool exact,
  }) => _DartWakeTimer(Timer(delay, fire));

  @override
  Future<void> hold(String tag, Duration duration) async {}

  @override
  Future<void> release(String tag) async {}

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

final class _DartWakeTimer implements WakeTimer {
  _DartWakeTimer(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

/// Android: alarms and timed holds through `zen/power` (ZenPower.kt).
final class AndroidWakePlatform implements ZenWakePlatform {
  AndroidWakePlatform({
    MethodChannel channel = const MethodChannel('zen/power'),
    EventChannel events = const EventChannel('zen/power/events'),
  }) : _channel = channel,
       _events = events;

  final MethodChannel _channel;
  final EventChannel _events;

  /// Tells this isolate's alarms from the other engine's (both hear every
  /// wake).
  final String _token = Random().nextInt(1 << 30).toRadixString(36);
  int _sequence = 0;
  final Map<String, _AlarmWakeTimer> _pending = <String, _AlarmWakeTimer>{};
  final StreamController<void> _appGone = StreamController<void>.broadcast();
  StreamSubscription<Object?>? _subscription;

  void _listen() {
    _subscription ??= _events.receiveBroadcastStream().listen(
      _onEvent,
      onError: (Object error) {
        logZenWarning('Wake events failed: $error');
      },
    );
  }

  void _onEvent(Object? event) {
    if (event is! Map) {
      return;
    }
    switch (event['type']) {
      case 'wake':
        final Object? id = event['id'];
        if (id is String) {
          _pending.remove(id)?._fire();
        }
      case 'appGone':
        _appGone.add(null);
    }
  }

  @override
  WakeTimer after(
    String name,
    Duration delay,
    void Function() fire, {
    required Duration hold,
    required bool exact,
  }) {
    _listen();
    _sequence += 1;
    final String id = '$_token.$name.$_sequence';
    final _AlarmWakeTimer timer = _AlarmWakeTimer(
      id: id,
      fire: fire,
      onDone: () => _pending.remove(id),
      cancelAlarm: () => unawaited(_cancelAlarm(id)),
    );
    _pending[id] = timer;
    // A Dart timer as well, later than any inexact alarm would come: if the
    // alarm is lost, the work still runs the next time the phone is awake.
    timer._backup = Timer(delay * 2 + const Duration(minutes: 1), timer._fire);
    unawaited(
      _channel
          .invokeMethod<bool>('schedule', <String, Object?>{
            'id': id,
            'delayMs': delay.inMilliseconds,
            'exact': exact,
            'holdMs': hold.inMilliseconds,
          })
          .then<void>(
            (_) {},
            onError: (Object error) {
              // No alarms here (an old build, a test host): a plain timer.
              logZenWarning('A wake alarm was not set ($name): $error');
              timer._fallBackTo(delay);
            },
          ),
    );
    return timer;
  }

  Future<void> _cancelAlarm(String id) async {
    try {
      await _channel.invokeMethod<void>('cancel', <String, Object?>{'id': id});
    } on Object catch (error) {
      logZenWarning('A wake alarm was not cancelled: $error');
    }
  }

  @override
  Future<void> hold(String tag, Duration duration) async {
    try {
      await _channel.invokeMethod<void>('hold', <String, Object?>{
        'tag': tag,
        'ms': duration.inMilliseconds,
      });
    } on Object catch (error) {
      logZenWarning('The phone was not held awake: $error');
    }
  }

  @override
  Future<void> release(String tag) async {
    try {
      await _channel.invokeMethod<void>('release', <String, Object?>{
        'tag': tag,
      });
    } on Object catch (error) {
      logZenWarning('A hold was not released: $error');
    }
  }

  @override
  Future<void> holdForCall(bool on) async {
    try {
      await _channel.invokeMethod<void>('holdForCall', on);
    } on Object catch (error) {
      logZenWarning('The call hold did not change: $error');
    }
  }

  @override
  Stream<void> get appGone {
    _listen();
    return _appGone.stream;
  }
}

final class _AlarmWakeTimer implements WakeTimer {
  _AlarmWakeTimer({
    required this.id,
    required void Function() fire,
    required void Function() onDone,
    required void Function() cancelAlarm,
  }) : _onFire = fire,
       _onDone = onDone,
       _cancelAlarm = cancelAlarm;

  final String id;
  final void Function() _onFire;
  final void Function() _onDone;
  final void Function() _cancelAlarm;
  Timer? _backup;
  bool _done = false;

  @override
  bool get isActive => !_done;

  void _fire() {
    if (_done) {
      return;
    }
    _done = true;
    _backup?.cancel();
    _onDone();
    _onFire();
  }

  void _fallBackTo(Duration delay) {
    if (_done) {
      return;
    }
    _backup?.cancel();
    _backup = Timer(delay, _fire);
  }

  @override
  void cancel() {
    if (_done) {
      return;
    }
    _done = true;
    _backup?.cancel();
    _onDone();
    _cancelAlarm();
  }
}

/// A [WakeTimer] that runs again every [every] until cancelled.
final class _RepeatingWakeTimer implements WakeTimer {
  _RepeatingWakeTimer(
    this.name,
    this.every,
    this.tick, {
    required this.hold,
    required this.exact,
  }) {
    _next();
  }

  final String name;
  final Duration every;
  final void Function() tick;
  final Duration hold;
  final bool exact;
  WakeTimer? _current;
  bool _cancelled = false;

  void _next() {
    _current = ZenWake.platform.after(
      name,
      every,
      () {
        if (_cancelled) {
          return;
        }
        _next();
        tick();
      },
      hold: hold,
      exact: exact,
    );
  }

  @override
  bool get isActive => !_cancelled;

  @override
  void cancel() {
    _cancelled = true;
    _current?.cancel();
    _current = null;
  }
}

/// Zen's work while the phone sleeps (see [ZenWakePlatform]).
abstract final class ZenWake {
  /// Android: alarms and holds; elsewhere plain timers.
  static ZenWakePlatform platform = !kIsWeb && Platform.isAndroid
      ? AndroidWakePlatform()
      : const TimerWakePlatform();

  /// How long the phone stays awake for a signal that came.
  static const Duration signalHold = Duration(seconds: 10);
  static final Stopwatch _sinceSignalHold = Stopwatch();

  /// Runs [fire] once after [delay], also while the phone sleeps, and
  /// keeps it awake for [hold] then.
  static WakeTimer after(
    String name,
    Duration delay,
    void Function() fire, {
    Duration hold = const Duration(seconds: 10),
    bool exact = false,
  }) => platform.after(name, delay, fire, hold: hold, exact: exact);

  /// Runs [tick] every [every], also while the phone sleeps.
  static WakeTimer every(
    String name,
    Duration every,
    void Function() tick, {
    Duration hold = const Duration(seconds: 10),
    bool exact = false,
  }) => _RepeatingWakeTimer(name, every, tick, hold: hold, exact: exact);

  /// Keeps the phone awake for [duration] (a piece of work that needs the
  /// processor until it ends).
  static Future<void> hold(Duration duration, {String tag = 'work'}) =>
      platform.hold(tag, duration);

  static Future<void> release({String tag = 'work'}) => platform.release(tag);

  /// A signal arrived: the packet woke the phone, and it stays awake a few
  /// seconds so the signal is handled (at most one call every few seconds).
  static void signalArrived() {
    if (_sinceSignalHold.isRunning &&
        _sinceSignalHold.elapsed < signalHold ~/ 2) {
      return;
    }
    _sinceSignalHold
      ..reset()
      ..start();
    unawaited(platform.hold('signal', signalHold));
  }

  static Future<void> holdForCall(bool on) => platform.holdForCall(on);

  static Stream<void> get appGone => platform.appGone;
}
