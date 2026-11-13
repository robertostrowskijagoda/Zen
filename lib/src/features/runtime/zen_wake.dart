import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';

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

/// How the phone's alarms keep time, as far as the shared beat plans by it
/// ([WakeBeat]); `null` from [ZenWake.alarmTiming]: plain timers, on time.
@immutable
final class WakeAlarmTiming {
  const WakeAlarmTiming({
    this.exactAllowed = false,
    this.lateWindows = false,
    this.rotation = false,
  });

  /// An exact alarm comes on time, also in Doze (Android 12 and later:
  /// the person allowed exact alarms; before, always).
  final bool exactAllowed;

  /// An inexact alarm comes as late as its window lets it unless something
  /// else wakes the phone first (Android 12 and later): up to 3/4 of its
  /// delay late, so a wake asked for in 10 minutes comes after 17 or 18.
  final bool lateWindows;

  /// The nearby token changes on an exact alarm at every [kWakeGrid]
  /// boundary of the wall clock ([kWakeGridRotationLag] past it): the phone
  /// is shown nearby, and exact alarms are allowed.
  final bool rotation;

  static WakeAlarmTiming fromMap(Map<Object?, Object?>? map) => WakeAlarmTiming(
    exactAllowed: map?['exact'] == true,
    lateWindows: map?['lateWindows'] == true,
    rotation: map?['rotation'] == true,
  );
}

/// The grid the beat's wakes keep to on Android ([WakeAlarmTiming]): the
/// nearby token changes on every 10-minute boundary of the wall clock
/// (kNearbySlot; an exact alarm in ZenNearbyBridge.kt), and the locked
/// phones of friends, whose clocks go by the network's time, wake on the
/// same boundaries (on time where exact alarms are allowed, at the end of
/// an inexact alarm's window where not), so a presence round reaches a
/// friend's phone while it is awake for its own. The grid is on epoch
/// time: time zones and daylight saving time do not move it.
const Duration kWakeGrid = Duration(minutes: 10);

/// How long after a [kWakeGrid] boundary the token's alarm comes
/// (ROTATION_MARGIN_MS in ZenNearbyBridge.kt).
const Duration kWakeGridRotationLag = Duration(milliseconds: 500);

/// How much before the token's alarm the beat's wake on the grid is asked
/// for: an inexact alarm whose window has begun goes off with the exact one,
/// and an exact one comes while the phone is still awake for it.
const Duration kWakeGridLead = Duration(seconds: 1);

/// What part of its delay an inexact alarm may come late at most (Android's
/// window for alarms set without one): a wake is asked for this much
/// sooner, so its window ends when it is due.
const double kInexactWindowStretch = 1.75;

/// Shorter delays get no window on Android.
const Duration kInexactWindowFrom = Duration(seconds: 10);

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

  /// How the alarms keep time, as Kotlin told it last: until it answers,
  /// inexact alarms that come when asked (the beat plans as it always did).
  WakeAlarmTiming _timing = const WakeAlarmTiming();
  final Stopwatch _sinceTiming = Stopwatch();
  bool _askingTiming = false;

  /// Asked again at most this often (the person may allow exact alarms, or
  /// show the phone nearby, while the service runs).
  static const Duration _timingEvery = Duration(minutes: 1);

  /// The last answer; a new one is asked for in the background, for the
  /// next plan of the beat (the beat plans synchronously, on its wakes).
  WakeAlarmTiming get timing {
    _refreshTiming();
    return _timing;
  }

  void _refreshTiming() {
    if (_askingTiming ||
        (_sinceTiming.isRunning && _sinceTiming.elapsed < _timingEvery)) {
      return;
    }
    _askingTiming = true;
    _sinceTiming
      ..reset()
      ..start();
    unawaited(
      _channel
          .invokeMapMethod<Object?, Object?>('alarmTiming')
          .then<void>(
            (Map<Object?, Object?>? map) =>
                _timing = WakeAlarmTiming.fromMap(map),
            // An older service, or a test host: as before.
            onError: (Object _) {},
          )
          .whenComplete(() => _askingTiming = false),
    );
  }

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
    // Work that returns nothing keeps the alarm's hold to its limit: it may
    // have started more than it waits for.
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

/// How much before it is due the shared beat may run a work of period
/// [every], on another work's wake, rather than wake the phone for it
/// alone: a third of the period, so works whose periods are multiples of
/// one another settle on the same wakes. Work that minds how long it has
/// been since it last ran takes a run this early as on time, or it loses
/// the run and waits a whole period more.
Duration wakeBeatEarly(Duration every) => every ~/ 3;

/// Work on the shared beat ([ZenWake.beat]); how often it comes may change.
abstract interface class BeatTimer implements WakeTimer {
  /// How long it waits between runs now.
  Duration get every;

  /// Runs next [every] from now, and then every [every]: longer while there
  /// is nothing to do, short again once there is.
  void setEvery(Duration every);
}

/// One piece of work on the shared beat.
final class _BeatWork implements BeatTimer {
  _BeatWork(
    this._beat,
    this.name,
    this._every,
    this.tick, {
    required this.hold,
    required this.whileIdle,
    required this.dueAt,
  });

  final WakeBeat _beat;
  final String name;
  Duration _every;
  final Future<void> Function() tick;
  final Duration hold;
  final bool whileIdle;

  /// When it runs next (wall time, milliseconds).
  int dueAt;
  bool _cancelled = false;

  @override
  Duration get every => _every;

  /// It may run up to this much before it is due ([wakeBeatEarly]).
  int get slackMs => wakeBeatEarly(_every).inMilliseconds;

  @override
  bool get isActive => !_cancelled;

  @override
  void setEvery(Duration every) {
    if (_cancelled) {
      return;
    }
    _every = every;
    dueAt = ZenWake.nowMillis() + every.inMilliseconds;
    _beat._plan();
  }

  @override
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _beat._remove(this);
  }
}

/// Work that runs on every wake of the beat and never wakes the phone itself
/// ([ZenWake.alongsideBeat]).
final class _BeatCompanion implements WakeTimer {
  _BeatCompanion(this._beat, this.name, this.tick);

  final WakeBeat _beat;
  final String name;
  final Future<void> Function() tick;
  bool _cancelled = false;

  @override
  bool get isActive => !_cancelled;

  @override
  void cancel() {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _beat._companions.remove(this);
  }
}

/// Work that comes back every few minutes (asking the mailboxes for mail,
/// for every account; the locked outbox's rounds; a look around nearby; the
/// parked service's watchdog; the update check), all on one alarm: one wake
/// of the phone runs everything due by then, or due a little later, instead
/// of one wake for each.
///
/// The app has one ([ZenWake.beat]); a test that runs several phones in one
/// process gives each of them a beat of its own.
final class WakeBeat {
  WakeBeat();

  final List<_BeatWork> _works = <_BeatWork>[];

  /// What runs on every wake besides what is due ([alongside]).
  final List<_BeatCompanion> _companions = <_BeatCompanion>[];

  /// The next wake, for whatever is due first.
  WakeTimer? _alarm;

  /// The next wake for work that has to run in Doze, while [_alarm] is one
  /// Doze may put off (only work that may wait is due on it): a look around
  /// that waits for Doze's window must not hold up the mailbox poll.
  WakeTimer? _dozeAlarm;

  /// A wake runs its works: they may change their periods meanwhile, and
  /// the alarms are planned once, after them.
  bool _firing = false;

  /// What runs on the next wake (tests).
  List<String> get planned {
    final int? at = _nextAt(_works);
    return <String>[
      if (at != null)
        for (final _BeatWork w in _dueBy(at)) w.name,
    ];
  }

  BeatTimer add(
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

  /// Runs [tick] on every wake of this beat, beside the work due then; it
  /// never wakes the phone itself. The wake lets the phone sleep once
  /// [tick]'s future completes too.
  WakeTimer alongside(String name, Future<void> Function() tick) {
    final _BeatCompanion companion = _BeatCompanion(this, name, tick);
    _companions.add(companion);
    return companion;
  }

  void _remove(_BeatWork work) {
    _works.remove(work);
    _plan();
  }

  void clear() {
    _works.clear();
    _companions.clear();
    _firing = false;
    _cancelAlarms();
  }

  /// What runs on a wake at [at]: what is due by then, and what is due a
  /// little later (within its slack) when it would otherwise take a wake
  /// of its own, i.e. when no other wake comes before it is due. Where the
  /// wakes keep to the grid (Android), work whose period is a whole number
  /// of [kWakeGrid]s rides along early only on a wake on the grid: on any
  /// other (the update check's, a poll's of the first hour) it would leave
  /// the grid for a period or two, and the friends' phones wake on it.
  List<_BeatWork> _dueBy(int at) {
    final List<_BeatWork> due = <_BeatWork>[];
    final List<_BeatWork> early = <_BeatWork>[];
    final bool offGrid = ZenWake.alarmTiming() != null && !_nearGrid(at);
    for (final _BeatWork w in _works) {
      if (w.dueAt <= at) {
        due.add(w);
      } else if (w.dueAt - w.slackMs <= at && !(offGrid && _gridPeriod(w))) {
        early.add(w);
      }
    }
    early.sort((_BeatWork a, _BeatWork b) => a.dueAt.compareTo(b.dueAt));
    for (final _BeatWork w in early) {
      // The next wake without it: what runs now comes again a period on.
      int? next;
      for (final _BeatWork other in _works) {
        if (identical(other, w)) {
          continue;
        }
        final int t = due.contains(other)
            ? at + other.every.inMilliseconds
            : other.dueAt;
        if (next == null || t < next) {
          next = t;
        }
      }
      if (next == null || w.dueAt < next) {
        due.add(w);
      }
    }
    return due;
  }

  /// When the next wake for [works] comes: the earliest due, but never
  /// later than a period away (a clock set back must not push it far out).
  int? _nextAt(Iterable<_BeatWork> works) {
    final int now = ZenWake.nowMillis();
    int? at;
    for (final _BeatWork w in works) {
      final int due = math.min(w.dueAt, now + w.every.inMilliseconds);
      if (at == null || due < at) {
        at = due;
      }
    }
    return at == null ? null : math.max(now, at);
  }

  /// No work due later than a period from [now]: a clock set back (by hand,
  /// or by the network's time) would otherwise leave every work waiting
  /// for the old time to come again, and nothing would run meanwhile.
  void _clampDue(int now) {
    for (final _BeatWork w in _works) {
      final int latest = now + w.every.inMilliseconds;
      if (w.dueAt > latest) {
        w.dueAt = latest;
      }
    }
  }

  void _cancelAlarms() {
    _alarm?.cancel();
    _alarm = null;
    _dozeAlarm?.cancel();
    _dozeAlarm = null;
  }

  void _plan() {
    if (_firing) {
      return;
    }
    _cancelAlarms();
    _clampDue(ZenWake.nowMillis());
    final int? at = _nextAt(_works);
    if (at == null) {
      return;
    }
    final List<_BeatWork> due = _dueBy(at);
    // Doze puts the wake off unless something due must run in it.
    final bool inDoze = due.any((_BeatWork w) => w.whileIdle);
    _alarm = _wake('beat', at, due, whileIdle: inDoze);
    if (inDoze) {
      return;
    }
    final int? dozeAt = _nextAt(_works.where((_BeatWork w) => w.whileIdle));
    if (dozeAt != null) {
      _dozeAlarm = _wake('beat-doze', dozeAt, _dueBy(dozeAt), whileIdle: true);
    }
  }

  /// The wake for [due] at [at]. Where the platform says nothing of its
  /// alarms (plain timers) an inexact alarm at [at]: nothing on the beat
  /// needs the minute, and Android may then wake the phone for other apps'
  /// alarms at the same time. That too on Android ([WakeAlarmTiming]) for
  /// wakes only for work due every minute or quarter of an hour (the parked
  /// service's watchdog, the update check, the first hour's polls). Work
  /// whose period is a whole number of [kWakeGrid]s (the presence rounds,
  /// the backed-off polls and looks, the locked outbox) keeps to the
  /// documented periods there:
  ///
  /// * When it is all that is due by [at], it wakes on the grid's
  ///   boundaries, a little early within the slack of each work due: with
  ///   the nearby token's change when the phone is shown nearby (an inexact
  ///   alarm asked a moment before the token's exact one goes off with it,
  ///   so the two share one wake), else on an exact alarm where those are
  ///   allowed and the work must run in Doze, else (exact alarms not
  ///   allowed: Android 14's default) on an inexact alarm whose window ends
  ///   on the boundary, so friends' phones without exact alarms wake on the
  ///   same boundaries as those with them, unless something else woke them
  ///   a little before. A wake off the grid is asked for as early as its
  ///   works allow, which brings it onto the grid within two periods, and
  ///   keeps it there.
  /// * Otherwise, where an inexact alarm comes as late as its window lets
  ///   it, it is asked for sooner, so the window ends when the work is due:
  ///   a 10-minute round would come after 17 or 18 minutes.
  WakeTimer _wake(
    String name,
    int at,
    List<_BeatWork> due, {
    required bool whileIdle,
  }) {
    Duration hold = Duration.zero;
    for (final _BeatWork w in due) {
      if (w.hold > hold) {
        hold = w.hold;
      }
    }
    final int now = ZenWake.nowMillis();
    final WakeAlarmTiming? timing = ZenWake.alarmTiming();
    int askAt = at;
    bool exact = false;
    int? rotationAt;
    int? gridAt;
    if (timing != null && !whileIdle && !due.any(_gridPeriod)) {
      // Only work that may wait for Doze's own window (the update check):
      // it may wait for the next wake on the grid as well, and shares it
      // instead of waking the phone between two of them.
      gridAt = _nextGridWake(at);
      askAt = _inexactAskAt(gridAt, now, timing);
    } else if (timing != null && due.any(_gridPeriod)) {
      final int? grid = _onGridPeriods(at, due)
          ? _gridWake(at, due, now)
          : null;
      if (grid != null && timing.rotation && _onGrid(grid)) {
        askAt = gridAt = grid;
        rotationAt = grid + kWakeGridLead.inMilliseconds;
      } else if (grid != null && timing.exactAllowed && whileIdle) {
        askAt = gridAt = grid;
        exact = true;
      } else {
        // No exact alarm: the wake still aims at the grid (or, off it, at
        // the moment the works are due), and is asked for so early that
        // Android's window for it ends there.
        // A wake due a few seconds before one on the grid waits for it.
        final int next = _nextGridWake(at);
        gridAt =
            grid ??
            (next - at <= kInexactWindowFrom.inMilliseconds ? next : null);
        askAt = _inexactAskAt(gridAt ?? at, now, timing);
      }
    }
    final List<_BeatWork> planned = List<_BeatWork>.of(due);
    return ZenWake.platform.after(
      name,
      Duration(milliseconds: askAt - now),
      () => _fire(planned: planned, from: gridAt, rotationAt: rotationAt),
      hold: hold,
      exact: exact,
      whileIdle: whileIdle,
    );
  }

  /// When an inexact alarm is asked for so that it comes by [target]: where
  /// it may come as late as its window lets it ([WakeAlarmTiming.lateWindows]:
  /// 3/4 of its delay, from [kInexactWindowFrom] on), so much sooner that the
  /// window ends at [target]; elsewhere at [target]. Android never delivers
  /// it before the time asked for, so the wake comes within the window's
  /// last 3/7 of the wait, at its end unless something else wakes the phone
  /// first.
  static int _inexactAskAt(int target, int now, WakeAlarmTiming timing) {
    final int ms = target - now;
    final int sooner = (ms / kInexactWindowStretch).ceil();
    if (!timing.lateWindows || sooner < kInexactWindowFrom.inMilliseconds) {
      // No window that could end there: so short a delay gets none and
      // would come seconds early (and the wake on the grid after it would
      // be a second one); the target itself comes on time, or at most a
      // few seconds late.
      return target;
    }
    return now + sooner;
  }

  /// How long after the token's alarm a wake planned to go off with it
  /// keeps the phone awake, should it come first: the token's alarm then
  /// comes during the same wake.
  static const int _rotationWait = 1000;

  /// Whether [at] is a wake on the grid (a [kWakeGridLead] before the
  /// token's change after a [kWakeGrid] boundary).
  static bool _onGrid(int at) =>
      (at - _gridOffsetMs) % kWakeGrid.inMilliseconds == 0;

  /// The first wake on the grid at or after [at].
  static int _nextGridWake(int at) {
    final int grid = kWakeGrid.inMilliseconds;
    final int off = (at - _gridOffsetMs) % grid;
    return off == 0 ? at : at + grid - off;
  }

  /// Whether [at] is within [kInexactWindowFrom] of a wake on the grid (the
  /// moment a wake on the grid reads the clock, a moment after the alarm).
  static bool _nearGrid(int at) {
    final int grid = kWakeGrid.inMilliseconds;
    final int off = (at - _gridOffsetMs) % grid;
    return math.min(off, grid - off) <= kInexactWindowFrom.inMilliseconds;
  }

  /// Where a wake on the grid lies after its boundary (negative: before
  /// it).
  static int get _gridOffsetMs =>
      kWakeGridRotationLag.inMilliseconds - kWakeGridLead.inMilliseconds;

  /// Whether every work of [due] due by [at] comes every whole number of
  /// [kWakeGrid]s (what rides along early, [_dueBy], may come at any
  /// period): a shorter or odd period would be cut short on every wake
  /// that keeps to the grid.
  static bool _onGridPeriods(int at, List<_BeatWork> due) {
    bool any = false;
    for (final _BeatWork w in due) {
      if (w.dueAt > at) {
        continue;
      }
      if (!_gridPeriod(w)) {
        return false;
      }
      any = true;
    }
    return any;
  }

  /// Whether [w] comes every whole number of [kWakeGrid]s.
  static bool _gridPeriod(_BeatWork w) {
    final int grid = kWakeGrid.inMilliseconds;
    final int every = w.every.inMilliseconds;
    return every >= grid && every % grid == 0;
  }

  /// The wake for [due] (due at [at], [_onGridPeriods]) towards the grid,
  /// or `null` when it keeps to [at]: the latest wake on the grid by [at]
  /// when every work due by [at] may run then (within its slack,
  /// [wakeBeatEarly]), else the earliest moment they all may, which comes a
  /// slack nearer to the grid each period. What rides along early comes
  /// with them.
  static int? _gridWake(int at, List<_BeatWork> due, int now) {
    final int grid = kWakeGrid.inMilliseconds;
    int earliest = now;
    for (final _BeatWork w in due) {
      if (w.dueAt <= at) {
        earliest = math.max(earliest, w.dueAt - w.slackMs);
      }
    }
    if (earliest >= at) {
      return null;
    }
    final int offset = _gridOffsetMs;
    final int onGrid = ((at - offset) ~/ grid) * grid + offset;
    if (onGrid >= earliest && onGrid > now) {
      return onGrid;
    }
    return earliest > now ? earliest : null;
  }

  /// [planned]: what the wake was planned for. A wake towards the grid
  /// ([from]: the moment it was asked for) runs all of it once that moment
  /// has come, as it would have run it when due; any other wake runs each
  /// only if it may by now. [rotationAt]: the nearby token's alarm this
  /// wake was planned to go off with; should it come first, the phone stays
  /// awake until that one has come too.
  Future<void> _fire({
    List<_BeatWork> planned = const <_BeatWork>[],
    int? from,
    int? rotationAt,
  }) {
    final int now = ZenWake.nowMillis();
    final List<Future<void>> running = <Future<void>>[];
    // How long each work took, for the technical log.
    final Map<String, int> took = <String, int>{};
    final Stopwatch wake = Stopwatch()..start();
    _clampDue(now);
    if (rotationAt != null && now < rotationAt + _rotationWait) {
      unawaited(
        ZenWake.platform.hold(
          'beat-rotation',
          Duration(
            milliseconds: math.min(rotationAt + _rotationWait - now, 3000),
          ),
        ),
      );
    }
    // A wake towards the grid that comes well before it (an inexact alarm
    // Android delivered early, inside its window, with something else that
    // woke the phone) runs only what is due by now: run early, the rest
    // would leave the grid, where the friends' phones wake, for a period or
    // two, and every ping of it would wake them. It keeps to the grid on a
    // wake asked for anew, which costs no wake of its own: the phone would
    // have woken for it at the window's end anyway.
    final bool early =
        from != null && now < from - kWakeGridLead.inMilliseconds;
    final List<_BeatWork> dueNow = early
        ? <_BeatWork>[
            for (final _BeatWork w in _works)
              if (w.dueAt <= now) w,
          ]
        : _dueBy(now);
    final bool asPlanned = from != null && now >= from;
    // In the order they were added, as always.
    final List<_BeatWork> works = <_BeatWork>[
      for (final _BeatWork w in _works)
        if (dueNow.contains(w) ||
            (!early &&
                planned.contains(w) &&
                (asPlanned || w.dueAt - w.slackMs <= now)))
          w,
    ];
    // A wake that came when it was asked for (a moment late: the alarm
    // reaches Dart after it went off) counts from that moment for work on
    // the grid: from the moment Dart reads the clock, the work would come
    // due a moment after the next wake on the grid, and not ride it.
    final int since =
        from != null &&
            asPlanned &&
            now - from < kInexactWindowFrom.inMilliseconds
        ? from
        : now;
    _firing = true;
    try {
      for (final _BeatWork w in works) {
        if (w._cancelled) {
          continue;
        }
        w.dueAt = (_gridPeriod(w) ? since : now) + w.every.inMilliseconds;
        running.add(
          Future<void>.sync(w.tick)
              .catchError((Object error, StackTrace st) {
                logZenError('Work on the wake (${w.name}) failed', error, st);
              })
              .whenComplete(() => took[w.name] = wake.elapsedMilliseconds),
        );
      }
      if (running.isNotEmpty) {
        for (final _BeatCompanion c in List<_BeatCompanion>.of(_companions)) {
          running.add(
            Future<void>.sync(c.tick)
                .catchError((Object error, StackTrace st) {
                  logZenError('Work on the wake (${c.name}) failed', error, st);
                })
                .whenComplete(() => took[c.name] = wake.elapsedMilliseconds),
          );
        }
      }
    } finally {
      _firing = false;
    }
    _plan();
    // The phone may sleep again once everything that ran is done.
    return Future.wait(running).whenComplete(
      () => ZenTechLog.event('beat', <String, Object?>{
        'ms': wake.elapsedMilliseconds,
        'jobs': took,
      }),
    );
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

  /// How the platform's alarms keep time, for the shared beat's plans
  /// (`null`: plain timers, which come on time); tests set it.
  @visibleForTesting
  static WakeAlarmTiming? Function() alarmTiming = _platformTiming;

  static WakeAlarmTiming? _platformTiming() {
    final ZenWakePlatform current = platform;
    return current is AndroidWakePlatform ? current.timing : null;
  }

  /// How long the phone stays awake for a signal that came: long enough to
  /// read it and drop it (most of what reaches a locked phone: answers to
  /// pings, "away", ledger hellos it does not take). What is kept (the
  /// inbox, a notice, a ring) holds the phone itself until it is done
  /// ([holdWhile]).
  static const Duration signalHold = Duration(seconds: 3);
  static final Stopwatch _sinceSignalHold = Stopwatch();

  static final WakeBeat _beat = WakeBeat();
  static final Map<String, int> _busy = <String, int>{};

  /// A wake's hold when its work says nothing else: only a safety limit,
  /// as the phone sleeps again as soon as the work is done.
  static const Duration defaultHold = Duration(seconds: 5);

  /// Runs [fire] once after [delay], also while the phone sleeps, and
  /// keeps it awake until the future [fire] returns completes, never longer
  /// than [hold] (work that returns nothing: for [hold]; so return the
  /// future of what the wake is for). [whileIdle] false: Doze may put it
  /// off. [exact] only where the minute matters (a reminder the person
  /// set): an inexact alarm lets Android wake the phone once for several
  /// apps.
  static WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    Duration hold = defaultHold,
    bool exact = false,
    bool whileIdle = true,
  }) => platform.after(
    name,
    delay,
    _timed(name, fire),
    hold: hold,
    exact: exact,
    whileIdle: whileIdle,
  );

  /// [fire], with how long its work took in the technical log (work that
  /// returns a future: until it completes).
  static FutureOr<void> Function() _timed(
    String name,
    FutureOr<void> Function() fire,
  ) => () {
    final Stopwatch took = Stopwatch()..start();
    final FutureOr<void> work = fire();
    if (work is Future<void>) {
      return work.whenComplete(() => ZenTechLog.wake(name, took.elapsed));
    }
    ZenTechLog.wake(name, took.elapsed);
  };

  /// Runs [tick] about every [every] on the shared beat: one wake of the
  /// phone for everything due about then (mailbox polls of every account,
  /// the locked outbox, the look around nearby, the watchdog, the update
  /// check). Periods that are multiples of one another share their wakes.
  /// It holds the phone for at most [hold] and lets it sleep once [tick]'s
  /// future completes. [whileIdle] false: this work alone does not wake the
  /// phone in Doze. The period may change later ([BeatTimer.setEvery]).
  static BeatTimer beat(
    String name,
    Duration every,
    Future<void> Function() tick, {
    Duration hold = defaultHold,
    bool whileIdle = true,
  }) => _beat.add(name, every, tick, hold: hold, whileIdle: whileIdle);

  /// Runs [tick] on every wake of the shared beat, whatever work it is for,
  /// and never wakes the phone itself ([WakeBeat.alongside]): work worth
  /// doing whenever the phone is awake anyway, such as checking that its
  /// links still answer.
  static WakeTimer alongsideBeat(String name, Future<void> Function() tick) =>
      _beat.alongside(name, tick);

  /// Names of the works the next beat runs (tests).
  @visibleForTesting
  static List<String> get plannedBeat => _beat.planned;

  @visibleForTesting
  static void resetForTest() {
    _beat.clear();
    _busy.clear();
    alarmTiming = _platformTiming;
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
