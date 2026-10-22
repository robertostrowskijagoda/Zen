import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

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
  /// phone and keeps it awake for at most [hold]: when [fire] returns a
  /// future, the phone may sleep again as soon as it completes (the work is
  /// done). [exact]: on time even in Doze (when the person allowed exact
  /// alarms). [whileIdle]: it wakes the phone in Doze too; otherwise Doze
  /// puts it off to its next window (for work Doze would skip anyway).
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  });

  /// Keeps the phone awake for [duration] under [tag] (the longest wins).
  Future<void> hold(String tag, Duration duration);

  /// Lets the phone sleep as far as [tag] goes, or ends [tag]'s hold in
  /// [after] (instead of at its old time limit).
  Future<void> release(String tag, {Duration after = Duration.zero});

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
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) => _DartWakeTimer(Timer(delay, () => unawaited(Future<void>.sync(fire))));

  @override
  Future<void> hold(String tag, Duration duration) async {}

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {}

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
  final String _token = math.Random().nextInt(1 << 30).toRadixString(36);
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
          _pending.remove(id)?._fire(byAlarm: true);
        }
      case 'appGone':
        _appGone.add(null);
    }
  }

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    _listen();
    _sequence += 1;
    final String id = '$_token.$name.$_sequence';
    // The alarm's own hold: released once the work is done, not shared
    // with other alarms (each one's work ends on its own).
    final String tag = 'wake.$_token.$name';
    final _AlarmWakeTimer timer = _AlarmWakeTimer(
      id: id,
      fire: fire,
      onDone: () => _pending.remove(id),
      cancelAlarm: () => unawaited(_cancelAlarm(id)),
      // A moment more for what the work set off (an answer on its way).
      release: () => unawaited(release(tag, after: const Duration(seconds: 1))),
    );
    _pending[id] = timer;
    // A Dart timer as well, later than any inexact alarm would come: if the
    // alarm is lost, the work still runs the next time the phone is awake.
    timer._backup = Timer(
      delay * 2 + const Duration(minutes: 1),
      () => timer._fire(byAlarm: false),
    );
    unawaited(
      _channel
          .invokeMethod<bool>('schedule', <String, Object?>{
            'id': id,
            'delayMs': delay.inMilliseconds,
            'exact': exact,
            'holdMs': hold.inMilliseconds,
            'tag': tag,
            'whileIdle': whileIdle,
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
  Future<void> release(String tag, {Duration after = Duration.zero}) async {
    try {
      await _channel.invokeMethod<void>('release', <String, Object?>{
        'tag': tag,
        if (after > Duration.zero) 'afterMs': after.inMilliseconds,
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
    required FutureOr<void> Function() fire,
    required void Function() onDone,
    required void Function() cancelAlarm,
    required void Function() release,
  }) : _onFire = fire,
       _onDone = onDone,
       _cancelAlarm = cancelAlarm,
       _release = release;

  final String id;
  final FutureOr<void> Function() _onFire;
  final void Function() _onDone;
  final void Function() _cancelAlarm;
  final void Function() _release;
  Timer? _backup;
  bool _done = false;

  /// An alarm is set (not when setting it failed: a plain timer then).
  bool _alarmSet = true;

  @override
  bool get isActive => !_done;

  /// Runs the work. [byAlarm]: the alarm woke the phone and holds it awake;
  /// work that tells when it is done ([_onFire] returns a future) lets it
  /// sleep again right then. Otherwise the backup timer came first: the
  /// alarm is cancelled, or it would wake the phone later for nothing.
  void _fire({required bool byAlarm}) {
    if (_done) {
      return;
    }
    _done = true;
    _backup?.cancel();
    _onDone();
    if (!byAlarm && _alarmSet) {
      _cancelAlarm();
    }
    final FutureOr<void> work;
    try {
      work = _onFire();
    } on Object catch (error, stackTrace) {
      logZenError('Woken work failed', error, stackTrace);
      if (byAlarm) {
        _release();
      }
      return;
    }
    if (work is Future<void>) {
      unawaited(
        work
            .then<void>(
              (_) {},
              onError: (Object error, StackTrace stackTrace) =>
                  logZenError('Woken work failed', error, stackTrace),
            )
            .whenComplete(() {
              if (byAlarm) {
                _release();
              }
            }),
      );
    }
  }

  void _fallBackTo(Duration delay) {
    if (_done) {
      return;
    }
    _alarmSet = false;
    _backup?.cancel();
    _backup = Timer(delay, () => _fire(byAlarm: false));
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
  final FutureOr<void> Function() tick;
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
          return Future<void>.value();
        }
        _next();
        return tick();
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

/// One piece of work on the shared beat ([ZenWake.beat]).
final class _BeatWork implements WakeTimer {
  _BeatWork(
    this._beat,
    this.name,
    this.every,
    this.tick, {
    required this.hold,
    required this.whileIdle,
    required this.dueAt,
  });

  final _Beat _beat;
  final String name;
  final Duration every;
  final Future<void> Function() tick;
  final Duration hold;
  final bool whileIdle;

  /// When it runs next (wall time, milliseconds).
  int dueAt;
  bool _cancelled = false;

  /// It may run this much before it is due, on another work's wake: so
  /// works with the same period settle on one wake.
  int get slackMs => every.inMilliseconds ~/ 3;

  @override
  bool get isActive => !_cancelled;

  @override
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _beat._remove(this);
  }
}

/// Work that comes back every few minutes (asking the mailboxes for mail,
/// for every account; a look around nearby), all on one alarm: one wake of
/// the phone runs everything due by then, or due a little later, instead
/// of one wake for each.
final class _Beat {
  final List<_BeatWork> _works = <_BeatWork>[];
  WakeTimer? _alarm;

  /// What runs on the next wake (tests).
  List<String> get planned => <String>[
    for (final _BeatWork w in _dueBy(_nextAt())) w.name,
  ];

  WakeTimer add(
    String name,
    Duration every,
    Future<void> Function() tick, {
    required Duration hold,
    required bool whileIdle,
  }) {
    final _BeatWork work = _BeatWork(
      this,
      name,
      every,
      tick,
      hold: hold,
      whileIdle: whileIdle,
      dueAt: ZenWake.nowMillis() + every.inMilliseconds,
    );
    _works.add(work);
    _plan();
    return work;
  }

  void _remove(_BeatWork work) {
    _works.remove(work);
    _plan();
  }

  void clear() {
    _works.clear();
    _alarm?.cancel();
    _alarm = null;
  }

  List<_BeatWork> _dueBy(int at) => <_BeatWork>[
    for (final _BeatWork w in _works)
      if (w.dueAt - w.slackMs <= at) w,
  ];

  /// When the next wake comes: the earliest work due, but never later than
  /// a period away (a clock set back must not push it far out).
  int _nextAt() {
    final int now = ZenWake.nowMillis();
    int? at;
    for (final _BeatWork w in _works) {
      final int due = math.min(w.dueAt, now + w.every.inMilliseconds);
      if (at == null || due < at) {
        at = due;
      }
    }
    return math.max(now, at ?? now);
  }

  void _plan() {
    _alarm?.cancel();
    _alarm = null;
    if (_works.isEmpty) {
      return;
    }
    final int now = ZenWake.nowMillis();
    final int at = _nextAt();
    final List<_BeatWork> due = _dueBy(at);
    Duration hold = Duration.zero;
    for (final _BeatWork w in due) {
      if (w.hold > hold) {
        hold = w.hold;
      }
    }
    _alarm = ZenWake.platform.after(
      'beat',
      Duration(milliseconds: at - now),
      _fire,
      hold: hold,
      exact: false,
      // Doze puts the wake off unless something due must run in it.
      whileIdle: due.any((_BeatWork w) => w.whileIdle),
    );
  }

  Future<void> _fire() {
    _alarm = null;
    final int now = ZenWake.nowMillis();
    final List<Future<void>> running = <Future<void>>[];
    for (final _BeatWork w in _dueBy(now)) {
      w.dueAt = now + w.every.inMilliseconds;
      running.add(
        Future<void>.sync(w.tick).catchError((Object error, StackTrace st) {
          logZenError('Work on the wake (${w.name}) failed', error, st);
        }),
      );
    }
    _plan();
    // The phone may sleep again once everything that ran is done.
    return Future.wait(running);
  }
}

/// Zen's work while the phone sleeps (see [ZenWakePlatform]).
abstract final class ZenWake {
  /// Android: alarms and holds; elsewhere plain timers.
  static ZenWakePlatform platform = !kIsWeb && Platform.isAndroid
      ? AndroidWakePlatform()
      : const TimerWakePlatform();

  /// Wall time for the shared beat (tests set it).
  @visibleForTesting
  static int Function() nowMillis = _wallMillis;

  static int _wallMillis() => DateTime.now().millisecondsSinceEpoch;

  /// How long the phone stays awake for a signal that came: long enough to
  /// read it and drop it (most of what reaches a locked phone: answers to
  /// pings, "away", ledger hellos it does not take). What is kept (the
  /// inbox, a notice, a ring) holds the phone itself until it is done
  /// ([holdWhile]).
  static const Duration signalHold = Duration(seconds: 3);
  static final Stopwatch _sinceSignalHold = Stopwatch();

  static final _Beat _beat = _Beat();
  static final Map<String, int> _busy = <String, int>{};

  /// Runs [fire] once after [delay], also while the phone sleeps, and
  /// keeps it awake for [hold] then, or until the future [fire] returns
  /// completes. [whileIdle] false: Doze may put it off.
  static WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    Duration hold = const Duration(seconds: 10),
    bool exact = false,
    bool whileIdle = true,
  }) => platform.after(
    name,
    delay,
    fire,
    hold: hold,
    exact: exact,
    whileIdle: whileIdle,
  );

  /// Runs [tick] every [every], also while the phone sleeps.
  static WakeTimer every(
    String name,
    Duration every,
    FutureOr<void> Function() tick, {
    Duration hold = const Duration(seconds: 10),
    bool exact = false,
  }) => _RepeatingWakeTimer(name, every, tick, hold: hold, exact: exact);

  /// Runs [tick] about every [every] on the shared beat: one wake of the
  /// phone for everything due about then (mailbox polls of every account,
  /// the look around nearby). It holds the phone for at most [hold] and
  /// lets it sleep once [tick]'s future completes. [whileIdle] false: this
  /// work alone does not wake the phone in Doze.
  static WakeTimer beat(
    String name,
    Duration every,
    Future<void> Function() tick, {
    Duration hold = const Duration(seconds: 10),
    bool whileIdle = true,
  }) => _beat.add(name, every, tick, hold: hold, whileIdle: whileIdle);

  /// Names of the works the next beat runs (tests).
  @visibleForTesting
  static List<String> get plannedBeat => _beat.planned;

  @visibleForTesting
  static void resetForTest() {
    _beat.clear();
    _busy.clear();
    _sinceSignalHold
      ..stop()
      ..reset();
  }

  /// Keeps the phone awake for [duration] (a piece of work that needs the
  /// processor until it ends).
  static Future<void> hold(Duration duration, {String tag = 'work'}) =>
      platform.hold(tag, duration);

  /// Lets the phone sleep (after [after]: what the work set off, such as an
  /// answer on its way, still has a moment).
  static Future<void> release({
    String tag = 'work',
    Duration after = Duration.zero,
  }) => platform.release(tag, after: after);

  /// Keeps the phone awake under [tag] while [work] runs (at most [limit]),
  /// then [linger] more for what it set off.
  static Future<T> holdWhile<T>(
    Future<T> Function() work, {
    String tag = 'work',
    Duration limit = const Duration(seconds: 30),
    Duration linger = const Duration(seconds: 1),
  }) async {
    _busy[tag] = (_busy[tag] ?? 0) + 1;
    unawaited(platform.hold(tag, limit));
    try {
      return await work();
    } finally {
      final int left = (_busy[tag] ?? 1) - 1;
      if (left > 0) {
        _busy[tag] = left;
      } else {
        _busy.remove(tag);
        unawaited(platform.release(tag, after: linger));
      }
    }
  }

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
