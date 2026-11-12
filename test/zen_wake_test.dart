import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/meet/nearby_crypto.dart';
import 'package:zen/src/features/meet/nearby_look_policy.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/update/background_update_check.dart';

final class _Alarm implements WakeTimer {
  _Alarm(
    this.name,
    this.delay,
    this.fire, {
    required this.hold,
    required this.whileIdle,
    this.exact = false,
  });

  final String name;
  final bool exact;
  final Duration delay;
  final FutureOr<void> Function() fire;
  final Duration hold;
  final bool whileIdle;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  /// The alarm goes off (it is spent then, as on the phone).
  FutureOr<void> ring() {
    fired = true;
    return fire();
  }

  @override
  void cancel() => cancelled = true;
}

/// Alarms and holds as the phone would get them.
final class _Platform implements ZenWakePlatform {
  final List<_Alarm> alarms = <_Alarm>[];
  final List<String> calls = <String>[];

  List<_Alarm> get live =>
      alarms.where((_Alarm a) => a.isActive).toList(growable: false);

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    final _Alarm alarm = _Alarm(
      name,
      delay,
      fire,
      hold: hold,
      whileIdle: whileIdle,
      exact: exact,
    );
    alarms.add(alarm);
    return alarm;
  }

  @override
  Future<void> hold(String tag, Duration duration) async =>
      calls.add('hold $tag ${duration.inSeconds}');

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async =>
      calls.add('release $tag ${after.inMilliseconds}');

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

/// Lets channel messages and microtasks go round.
Future<void> _settle() async {
  for (int i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

const int _sec = 1000;
const int _min = 60 * _sec;
const int _hour = 60 * _min;

/// An alarm as Android's AlarmManager keeps it: from [at] on it may go
/// off; alone it goes off at [maxAt], the end of its window.
final class _PhoneAlarm implements WakeTimer {
  _PhoneAlarm(this.at, this.maxAt, this.fire);

  final int at;
  final int maxAt;
  final FutureOr<void> Function() fire;
  bool done = false;

  @override
  bool get isActive => !done;

  @override
  void cancel() => done = true;
}

/// A phone's alarms on the virtual clock, in one of two models: every
/// alarm on time (as the tests above take them), or Android's (12 and
/// later): an inexact alarm (`setAndAllowWhileIdle`, `set`) gets a window
/// of 3/4 of its delay (from 10 s on) and goes off at the window's end,
/// unless the phone wakes before for anything else, which takes along every
/// alarm whose window has begun; an exact one goes off on time. Holds keep
/// the phone awake for their time, under their tag.
final class _PhoneAlarms implements ZenWakePlatform {
  _PhoneAlarms({required this.windows, required this.now});

  final bool windows;
  final int Function() now;
  final List<_PhoneAlarm> alarms = <_PhoneAlarm>[];
  final Map<String, int> holds = <String, int>{};

  List<_PhoneAlarm> get live =>
      alarms.where((_PhoneAlarm a) => a.isActive).toList(growable: false);

  /// Until when the phone is held awake.
  int get awakeUntil =>
      holds.values.fold<int>(-1 << 40, (int a, int b) => math.max(a, b));

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    final int t = now();
    final int d = math.max(0, delay.inMilliseconds);
    final int window = windows && !exact && d >= 10 * _sec
        ? (d * 0.75).round()
        : 0;
    final _PhoneAlarm alarm = _PhoneAlarm(t + d, t + d + window, fire);
    alarms.add(alarm);
    return alarm;
  }

  @override
  Future<void> hold(String tag, Duration duration) async {
    holds[tag] = math.max(holds[tag] ?? 0, now() + duration.inMilliseconds);
  }

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {
    holds[tag] = now() + after.inMilliseconds;
  }

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

/// What a locked phone did in [_lockedPhoneHours]: when the phone woke for
/// Zen, and when the rounds, looks and polls ran.
final class _Hours {
  final List<int> wakes = <int>[];
  final List<int> rounds = <int>[];
  final List<int> looks = <int>[];
  final List<int> polls = <int>[];

  double perHour(List<int> times, int from, int to) =>
      times.where((int t) => t >= from && t < to).length /
      ((to - from) / _hour);

  List<int> gaps(List<int> times, int from, int to) {
    final List<int> t = times.where((int x) => x >= from && x < to).toList();
    return <int>[for (int i = 1; i < t.length; i++) t[i] - t[i - 1]];
  }

  int maxGap(List<int> times, int from, int to) =>
      gaps(times, from, to).fold<int>(0, math.max);

  /// The longest a friend goes without a round when one round in a row is
  /// lost (the link dead between wakes: only the rounds reach them).
  int maxGapOneLost(List<int> times, int from, int to) {
    final List<int> t = times.where((int x) => x >= from && x < to).toList();
    int most = 0;
    for (int i = 2; i < t.length; i++) {
      most = math.max(most, t[i] - t[i - 2]);
    }
    return most;
  }
}

/// Signals of the locked phone, with the time each one went.
final class _FriendAir extends MemorySignalTransport {
  _FriendAir(this.now);

  final int Function() now;
  final List<int> sentAt = <int>[];

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) {
    sentAt.add(now());
    return super.send(remoteAddress: remoteAddress, payload: payload);
  }
}

const String _simFriend = '200:1111:2222:3333:4444:5555:6666:7777';
const String _simMailbox = '200:1111:2222:3333:4444:5555:6666:aaaa';

/// A locked phone with nobody around for [hours]: the real receiver (polls
/// with their back-off, rounds to one friend who answers), the look around
/// by the default policy (each look keeps the phone 8 s + 1 s), a work as
/// often as the update check, and the link check on every wake, on the
/// shared beat, its alarms delivered by [alarms]' model. [timing]: what
/// the beat is told of the alarms (`null`: plain timers, as before this
/// version). [rotation]: the phone is shown nearby, so the token changes on
/// an exact alarm 0.5 s past every 10-minute boundary. [latencyMs]: how
/// long after the phone wakes the beat reads its clock. [otherPerHour]:
/// other apps' wakes, which take along every alarm whose window has begun
/// (not counted as Zen's).
Future<_Hours> _lockedPhoneHours({
  required bool windows,
  required bool rotation,
  required WakeAlarmTiming? timing,
  int hours = 13,
  int startAt = 1000 * _hour + 7 * _min + 13 * _sec,
  int latencyMs = 0,
  double otherPerHour = 0,
  int seed = 3,
}) async {
  final math.Random random = math.Random(seed);
  int nextOther(int t) => otherPerHour <= 0
      ? 1 << 62
      : t + (-math.log(1 - random.nextDouble()) / otherPerHour * _hour).round();
  int clock = startAt;
  int wakeAt = clock;
  final _PhoneAlarms phone = _PhoneAlarms(windows: windows, now: () => clock);
  ZenWake.platform = phone;
  ZenWake.nowMillis = () => clock;
  ZenWake.alarmTiming = () => timing;
  final Directory dir = await Directory.systemTemp.createTemp('zen-wake-');
  final _FriendAir air = _FriendAir(() => clock);
  final _Hours result = _Hours();
  final LockedReceiver receiver = LockedReceiver(
    transport: air,
    capability: BackgroundCapability.fromDraft(
      BackgroundCapabilityDraft(
        inboxPublicKey: Uint8List(32),
        friends: const <String>{_simFriend},
        mailboxes: const <String>[_simMailbox],
      ),
      backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
    ),
    inbox: SealedInboxWriter(
      file: File('${dir.path}/inbox.zbox'),
      recipientPublicKey: Uint8List(32),
    ),
    presenceSnapshot: SealedSnapshotWriter(
      file: File('${dir.path}/presence.zbox'),
      recipientPublicKey: await inboxPublicKeyFor(
        Uint8List.fromList(List<int>.generate(32, (int i) => i + 7)),
      ),
    ),
    notices: MemoryRuntimeSystemNotificationService(),
    presence: const LockedPresenceKit(shownTo: <String>{_simFriend}),
    pollAnswerGrace: Duration.zero,
    now: () => clock,
  );
  await receiver.start();
  const NearbyLookPolicy policy = NearbyLookPolicy();
  late BeatTimer look;
  look = ZenWake.beat(
    'nearby-look',
    policy.every,
    () async {
      result.looks.add(clock);
      // The scan keeps the phone awake for its window and a moment more.
      clock = math.max(clock, wakeAt + policy.window.inMilliseconds + _sec);
      final Duration next = nextNearbyLookWait(
        last: look.every,
        fresh: false,
        base: policy.every,
        max: policy.longest,
      );
      if (next != look.every) {
        look.setEvery(next);
      }
    },
    hold: policy.window + const Duration(seconds: 5),
    whileIdle: false,
  );
  final BeatTimer update = ZenWake.beat(
    'update-check',
    kUpdateBeatAtMost,
    () async {},
    whileIdle: false,
  );
  final WakeTimer links = checkLinksOnWakes(
    () async => <String, dynamic>{'probed': 1, 'answered': 1, 'dropped': 0},
  );
  final int slot = kWakeGrid.inMilliseconds;
  int nextRotation(int t) =>
      (t ~/ slot + 1) * slot + kWakeGridRotationLag.inMilliseconds;
  int rot = nextRotation(clock);
  int other = nextOther(clock);
  int seen = 0;
  final int end = startAt + hours * _hour;
  while (true) {
    final List<_PhoneAlarm> live = phone.live;
    int next = live.isEmpty
        ? end
        : live.map((_PhoneAlarm a) => a.maxAt).reduce(math.min);
    bool byOther = false;
    if (rotation && rot <= next) {
      next = rot;
    }
    if (other < next) {
      next = other;
      byOther = true;
    }
    if (next >= end) {
      break;
    }
    clock = math.max(clock, next);
    wakeAt = clock;
    if (byOther) {
      other = nextOther(clock);
    } else if (clock > phone.awakeUntil) {
      result.wakes.add(clock);
    }
    if (rotation && rot <= clock) {
      rot = nextRotation(clock);
      // The token's change: a moment's work under its own hold.
      await phone.hold('rotation', const Duration(milliseconds: 200));
    }
    final List<_PhoneAlarm> due =
        phone.live.where((_PhoneAlarm a) => a.at <= clock).toList()
          ..sort((_PhoneAlarm a, _PhoneAlarm b) => a.at.compareTo(b.at));
    if (due.isNotEmpty) {
      // The wake reaches Dart a moment later.
      clock += latencyMs;
    }
    for (final _PhoneAlarm a in due) {
      if (!a.isActive) {
        continue;
      }
      a.done = true;
      final FutureOr<void> work = a.fire();
      if (work is Future<void>) {
        await work;
      }
      await _settle();
      // Dart lets the alarm's hold go a second after the work.
      await phone.hold('alarm', const Duration(seconds: 1));
    }
    await _settle();
    // The friend's phone answers each ping at once.
    final int sent = air.sentSignals.length;
    for (int k = seen; k < sent; k++) {
      final ({String remoteAddress, Map<String, dynamic> payload}) s =
          air.sentSignals[k];
      if (s.payload['type'] == 'ping' && s.remoteAddress == _simFriend) {
        result.rounds.add(air.sentAt[k]);
        await receiver.handleFrame(
          SignalTransportFrame(
            from: _simFriend,
            payload: <String, dynamic>{
              'type': 'pong',
              'state': 'background',
              'sq': clock,
            },
            receivedAtMillis: clock,
          ),
        );
      } else if (s.payload['type'] == 'rly_poll') {
        result.polls.add(air.sentAt[k]);
      }
    }
    seen = sent;
  }
  update.cancel();
  links.cancel();
  look.cancel();
  await receiver.stop();
  ZenWake.resetForTest();
  await dir.delete(recursive: true);
  return result;
}

String _mmss(int ms) =>
    '${ms ~/ _min}:${((ms % _min) ~/ _sec).toString().padLeft(2, '0')}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const MethodChannel power = MethodChannel('zen/power');
  const EventChannel events = EventChannel('zen/power/events');

  late _Platform platform;
  int now = 0;

  setUp(() {
    platform = _Platform();
    now = 0;
    ZenWake.platform = platform;
    ZenWake.nowMillis = () => now;
  });

  tearDown(() {
    ZenWake.resetForTest();
    ZenWake.platform = const TimerWakePlatform();
    ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
    messenger.setMockMethodCallHandler(power, null);
    messenger.setMockStreamHandler(events, null);
  });

  test('the mailbox poll and the look around share one wake', () async {
    final List<String> ran = <String>[];
    final WakeTimer poll = ZenWake.beat(
      'mailbox-poll',
      const Duration(minutes: 5),
      () async => ran.add('poll'),
      hold: const Duration(seconds: 15),
    );
    now = 60 * 1000;
    final WakeTimer look = ZenWake.beat(
      'nearby-look',
      const Duration(minutes: 5),
      () async => ran.add('look'),
      hold: const Duration(seconds: 15),
      whileIdle: false,
    );
    expect(platform.live, hasLength(1), reason: 'one alarm for both');
    final _Alarm wake = platform.live.single;
    expect(wake.delay, const Duration(minutes: 4));
    expect(wake.hold, const Duration(seconds: 15));
    // The poll must run in Doze too: so the shared wake does.
    expect(wake.whileIdle, isTrue);
    // Inexact: Android may wake the phone once for this and others' alarms.
    expect(wake.exact, isFalse);
    expect(ZenWake.plannedBeat, <String>['mailbox-poll', 'nearby-look']);

    now = 5 * 60 * 1000;
    await wake.ring();
    expect(ran, <String>['poll', 'look'], reason: 'the look a minute early');
    final _Alarm next = platform.live.single;
    expect(next.delay, const Duration(minutes: 5));
    expect(ZenWake.plannedBeat, <String>['mailbox-poll', 'nearby-look']);

    look.cancel();
    expect(ZenWake.plannedBeat, <String>['mailbox-poll']);
    poll.cancel();
    expect(platform.live, isEmpty);
  });

  test('work alongside the beat runs on every wake and never wakes the phone '
      'itself', () async {
    final List<String> ran = <String>[];
    final WakeTimer check = ZenWake.alongsideBeat('link-check', () async {
      ran.add('check');
    });
    expect(platform.live, isEmpty, reason: 'no wake of its own');
    final WakeTimer update = ZenWake.beat(
      'update-check',
      const Duration(minutes: 15),
      () async => ran.add('update'),
    );
    ZenWake.beat(
      'mailbox-poll',
      const Duration(minutes: 30),
      () async => ran.add('poll'),
    );
    for (int i = 0; i < 4; i++) {
      final _Alarm next = platform.live.single;
      now += next.delay.inMilliseconds;
      await next.ring();
    }
    expect(
      ran.where((String r) => r == 'check'),
      hasLength(4),
      reason: 'every wake, also the ones without the poll',
    );
    expect(ran.where((String r) => r == 'poll'), hasLength(2));
    expect(ZenWake.plannedBeat, isNot(contains('link-check')));

    // The wake lets go only once the check is done too.
    expect(check.isActive, isTrue);
    check.cancel();
    expect(check.isActive, isFalse);
    check.cancel();
    final Completer<void> slow = Completer<void>();
    final WakeTimer slowCheck = ZenWake.alongsideBeat(
      'link-check',
      () => slow.future,
    );
    final _Alarm next = platform.live.single;
    now += next.delay.inMilliseconds;
    bool done = false;
    unawaited((next.ring() as Future<void>).then((_) => done = true));
    await _settle();
    expect(done, isFalse, reason: 'the check still runs');
    slow.complete();
    await _settle();
    expect(done, isTrue);
    expect(ran.where((String r) => r == 'check'), hasLength(4));

    slowCheck.cancel();
    update.cancel();
  });

  test('the link check holds the phone under its own tag while the bridge '
      'checks, and a failed check spoils no wake', () async {
    final List<String> ran = <String>[];
    int checks = 0;
    final WakeTimer check = checkLinksOnWakes(() async {
      checks++;
      if (checks == 2) {
        throw StateError('the bridge is gone');
      }
      return <String, dynamic>{'probed': 1, 'dropped': checks == 3 ? 1 : 0};
    });
    ZenWake.beat(
      'update-check',
      const Duration(minutes: 15),
      () async => ran.add('update'),
    );
    for (int i = 0; i < 3; i++) {
      final _Alarm next = platform.live.single;
      now += next.delay.inMilliseconds;
      await next.ring();
      await _settle();
    }
    expect(checks, 3);
    expect(ran, hasLength(3), reason: 'the failed check stopped nothing');
    expect(
      platform.calls.where((String c) => c == 'hold link-check 20'),
      hasLength(3),
    );
    expect(
      platform.calls.where((String c) => c.startsWith('release link-check')),
      hasLength(3),
    );
    check.cancel();
  });

  test('a clock set back does not stop the works', () async {
    final List<String> ran = <String>[];
    ZenWake.beat(
      'mailbox-poll',
      const Duration(minutes: 5),
      () async => ran.add('poll'),
    );
    now = 5 * 60 * 1000;
    await platform.live.single.ring();
    expect(ran, <String>['poll']);
    // The clock goes back a day: the next wake still comes a period on,
    // and runs the poll then.
    now -= const Duration(days: 1).inMilliseconds;
    now += 60 * 1000;
    await platform.live.single.ring();
    final _Alarm next = platform.live.single;
    expect(next.delay, const Duration(minutes: 5));
    now += 5 * 60 * 1000;
    await next.ring();
    expect(ran, <String>['poll', 'poll']);
  });

  test('the look alone waits for Doze\'s own window', () {
    ZenWake.beat(
      'nearby-look',
      const Duration(minutes: 5),
      () async {},
      hold: const Duration(seconds: 15),
      whileIdle: false,
    );
    expect(platform.live.single.whileIdle, isFalse);
  });

  test('the shared wake ends when every work on it is done', () async {
    final Completer<void> slow = Completer<void>();
    ZenWake.beat(
      'a',
      const Duration(minutes: 5),
      () => slow.future,
      hold: const Duration(seconds: 15),
    );
    ZenWake.beat(
      'b',
      const Duration(minutes: 5),
      () async => throw StateError('broken'),
      hold: const Duration(seconds: 15),
    );
    now = 5 * 60 * 1000;
    bool done = false;
    final FutureOr<void> wake = platform.live.single.ring();
    expect(wake, isA<Future<void>>());
    unawaited((wake as Future<void>).then((_) => done = true));
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: 'a is still working');
    slow.complete();
    await Future<void>.delayed(Duration.zero);
    expect(done, isTrue, reason: 'a failure in b does not keep it awake');
  });

  test('a poll that backs off still rides the look\'s wakes', () async {
    final List<String> ran = <String>[];
    late BeatTimer poll;
    poll = ZenWake.beat('mailbox-poll', const Duration(minutes: 5), () async {
      ran.add('poll');
      // Nothing came: the poll waits longer from now on.
      poll.setEvery(const Duration(minutes: 20));
    });
    ZenWake.beat(
      'nearby-look',
      const Duration(minutes: 5),
      () async => ran.add('look'),
      whileIdle: false,
    );
    now = 5 * 60 * 1000;
    await platform.live.single.ring();
    expect(ran, <String>['poll', 'look']);
    int wakes = 1;
    ran.clear();
    // An hour on: one wake every five minutes, the poll on every fourth.
    while (now < 65 * 60 * 1000) {
      final _Alarm next = platform.live.first;
      now += next.delay.inMilliseconds;
      await next.ring();
      wakes++;
    }
    expect(wakes, 13, reason: 'the look\'s wakes only');
    expect(ran.where((String r) => r == 'poll'), hasLength(3));
    expect(ran.where((String r) => r == 'look'), hasLength(12));
  });

  test('with nobody around a locked phone wakes only for the presence rounds: '
      'the look and the update check ride them', () async {
    final Map<String, int> runs = <String, int>{};
    void count(String name) => runs[name] = (runs[name] ?? 0) + 1;
    const NearbyLookPolicy policy = NearbyLookPolicy();
    late BeatTimer poll;
    poll = ZenWake.beat('mailbox-poll', kLockedMailboxPollInterval, () async {
      count('poll');
      final Duration next = nextMailboxPollWait(
        last: poll.every,
        keptSince: false,
      );
      if (next != poll.every) {
        poll.setEvery(next);
      }
    }, hold: const Duration(seconds: 10));
    ZenWake.beat(
      'presence-round',
      kLockedPresenceRoundEvery,
      () async => count('round'),
    );
    late BeatTimer look;
    look = ZenWake.beat(
      'nearby-look',
      policy.every,
      () async {
        count('look');
        final Duration next = nextNearbyLookWait(
          last: look.every,
          fresh: false,
          base: policy.every,
          max: policy.longest,
        );
        if (next != look.every) {
          look.setEvery(next);
        }
      },
      hold: policy.window + const Duration(seconds: 5),
      whileIdle: false,
    );
    ZenWake.beat(
      'update-check',
      kUpdateBeatAtMost,
      () async => count('update'),
      whileIdle: false,
    );
    const int hour = 60 * 60 * 1000;
    final List<int> wakesPerHour = <int>[];
    for (int h = 0; h < 6; h++) {
      int wakes = 0;
      runs.clear();
      while (now < (h + 1) * hour) {
        final List<_Alarm> live = platform.live.toList()
          ..sort((_Alarm a, _Alarm b) => a.delay.compareTo(b.delay));
        now += live.first.delay.inMilliseconds;
        await live.first.ring();
        wakes++;
      }
      wakesPerHour.add(wakes);
    }
    // Once the polls and the looks have backed off (the first hour): one
    // wake every ten minutes.
    expect(wakesPerHour.skip(1), everyElement(6));
    expect(runs['round'], 6);
    expect(runs['look'], 3, reason: 'every 20 minutes');
    expect(runs['update'], 6, reason: 'early on the rounds, never its own');
    expect(runs['poll'], 2);
  });

  test('periods that are multiples of one another share their wakes', () async {
    final Map<String, int> runs = <String, int>{};
    void count(String name) => runs[name] = (runs[name] ?? 0) + 1;
    ZenWake.beat(
      'mailbox-poll',
      const Duration(minutes: 10),
      () async => count('poll'),
    );
    ZenWake.beat(
      'locked-outbox',
      const Duration(hours: 1),
      () async => count('outbox'),
    );
    ZenWake.beat(
      'update-check',
      const Duration(minutes: 45),
      () async => count('update'),
      whileIdle: false,
    );
    int wakes = 0;
    while (now < 3 * 60 * 60 * 1000) {
      final _Alarm next = platform.live.first;
      now += next.delay.inMilliseconds;
      await next.ring();
      wakes++;
    }
    expect(wakes, 18, reason: 'every ten minutes, nothing in between');
    expect(runs['poll'], 18);
    expect(runs['outbox'], 3);
    expect(runs['update'], 4);
  });

  test('work that waits for Doze\'s window does not hold up work that may '
      'not wait', () async {
    final List<String> ran = <String>[];
    ZenWake.beat(
      'nearby-look',
      const Duration(minutes: 5),
      () async => ran.add('look'),
      whileIdle: false,
    );
    ZenWake.beat(
      'mailbox-poll',
      const Duration(minutes: 20),
      () async => ran.add('poll'),
    );
    expect(platform.live, hasLength(2));
    final _Alarm look = platform.live.firstWhere((_Alarm a) => !a.whileIdle);
    final _Alarm poll = platform.live.firstWhere((_Alarm a) => a.whileIdle);
    expect(look.delay, const Duration(minutes: 5));
    expect(poll.name, 'beat-doze');
    expect(poll.delay, const Duration(minutes: 20));

    // Doze put the look's alarm off: the poll's own alarm comes on time,
    // and the overdue look rides it.
    now = 20 * 60 * 1000;
    await poll.ring();
    expect(ran, <String>['look', 'poll']);
    expect(look.cancelled, isTrue);
    // And again: the look's wake, and the poll's own for Doze.
    expect(
      platform.live.map((_Alarm a) => '${a.name} ${a.delay.inMinutes}'),
      <String>['beat 5', 'beat-doze 20'],
    );
  });

  test('a period changed during a wake plans the next wake once', () async {
    late BeatTimer poll;
    poll = ZenWake.beat('mailbox-poll', const Duration(minutes: 5), () async {
      poll.setEvery(const Duration(minutes: 10));
    });
    now = 5 * 60 * 1000;
    final int before = platform.alarms.length;
    await platform.live.single.ring();
    expect(platform.alarms.length - before, 1);
    expect(platform.live.single.delay, const Duration(minutes: 10));

    // Shortened again outside a wake: from now.
    now += 60 * 1000;
    poll.setEvery(const Duration(minutes: 5));
    expect(platform.live.single.delay, const Duration(minutes: 5));
  });

  test('default holds are short: only a safety limit', () {
    expect(ZenWake.defaultHold, lessThanOrEqualTo(const Duration(seconds: 5)));
    ZenWake.after('x', const Duration(minutes: 1), () {});
    ZenWake.beat('y', const Duration(minutes: 5), () async {});
    expect(
      platform.alarms.map((_Alarm a) => a.hold),
      everyElement(ZenWake.defaultHold),
    );
  });

  test('work that keeps something holds the phone until it is done', () async {
    final Completer<void> first = Completer<void>();
    final Completer<void> second = Completer<void>();
    final Future<void> a = ZenWake.holdWhile(
      () => first.future,
      tag: 'keep',
      limit: const Duration(seconds: 20),
    );
    final Future<void> b = ZenWake.holdWhile(
      () => second.future,
      tag: 'keep',
      limit: const Duration(seconds: 20),
    );
    first.complete();
    await a;
    expect(platform.calls, <String>['hold keep 20', 'hold keep 20']);
    second.complete();
    await b;
    expect(platform.calls.last, 'release keep 1000');
    expect(platform.calls.where((String c) => c.startsWith('release')), [
      'release keep 1000',
    ]);
  });

  test('a wake is inexact and comes in Doze unless asked otherwise', () {
    ZenWake.after('reminder', const Duration(minutes: 1), () {});
    final _Alarm alarm = platform.live.single;
    expect(alarm.exact, isFalse, reason: 'Android may wake once for several');
    expect(alarm.whileIdle, isTrue);
    expect(alarm.hold, ZenWake.defaultHold);
    ZenWake.after(
      'alarm',
      const Duration(minutes: 1),
      () {},
      exact: true,
      whileIdle: false,
    );
    expect(platform.live.last.exact, isTrue);
    expect(platform.live.last.whileIdle, isFalse);
  });

  test('a signal holds the phone only a moment', () {
    expect(ZenWake.signalHold, lessThanOrEqualTo(const Duration(seconds: 3)));
    ZenWake.signalArrived();
    ZenWake.signalArrived();
    expect(platform.calls, <String>['hold signal 3']);
  });

  group('a locked phone, its alarms as Android delivers them', () {
    // Hours 2..13: past the first hour's back-offs.
    const int from = 1000 * _hour + 7 * _min + 13 * _sec + _hour;
    const int to = from + 12 * _hour;
    const WakeAlarmTiming android12 = WakeAlarmTiming(
      exactAllowed: true,
      lateWindows: true,
    );
    const WakeAlarmTiming android12Nearby = WakeAlarmTiming(
      exactAllowed: true,
      lateWindows: true,
      rotation: true,
    );
    const WakeAlarmTiming noExactAlarms = WakeAlarmTiming(lateWindows: true);

    test('the grid is the nearby token\'s slot', () {
      expect(kWakeGrid, kNearbySlot);
      expect(
        kLockedPresenceRoundEvery.inMilliseconds % kWakeGrid.inMilliseconds,
        0,
      );
      expect(
        kLockedMailboxPollMaxInterval.inMilliseconds % kWakeGrid.inMilliseconds,
        0,
      );
      expect(
        const NearbyLookPolicy().longest.inMilliseconds %
            kWakeGrid.inMilliseconds,
        0,
      );
    });

    /// What a phone must do, whatever delivers its alarms: a round at
    /// least every 10 minutes and a moment (never two within the early
    /// rule), a look at least every 20 and a moment (the documents' words),
    /// and a friend who hears only the rounds never sees "poza siecią" when
    /// one of them is lost.
    void expectAsDocumented(_Hours r, String label) {
      for (final int gap in r.gaps(r.rounds, from, to)) {
        expect(gap, greaterThanOrEqualTo(6 * _min + 39 * _sec), reason: label);
      }
      // A wake asked for again less than 17.5 s before the boundary
      // (another app's alarm took Zen's along early) gets no window that
      // could end there, and may come up to 3/4 of that late.
      expect(
        r.maxGap(r.rounds, from, to),
        lessThanOrEqualTo(10 * _min + 14 * _sec),
        reason: '$label: rounds',
      );
      expect(
        r.maxGap(r.looks, from, to),
        lessThanOrEqualTo(20 * _min + 14 * _sec),
        reason: '$label: looks',
      );
      expect(
        r.maxGapOneLost(r.rounds, from, to),
        lessThan(kPresenceBackgroundFor.inMilliseconds),
        reason: '$label: one round lost',
      );
    }

    String line(_Hours r) =>
        'wakes/h=${r.perHour(r.wakes, from, to).toStringAsFixed(2)} '
        'rounds/h=${r.perHour(r.rounds, from, to).toStringAsFixed(2)} '
        'longest round gap=${_mmss(r.maxGap(r.rounds, from, to))} '
        'one lost=${_mmss(r.maxGapOneLost(r.rounds, from, to))} '
        'looks/h=${r.perHour(r.looks, from, to).toStringAsFixed(2)} '
        'longest look gap=${_mmss(r.maxGap(r.looks, from, to))} '
        'polls/h=${r.perHour(r.polls, from, to).toStringAsFixed(2)}';

    test('alarms on time, not shown nearby: a wake every 10 minutes, as '
        'before', () async {
      final _Hours r = await _lockedPhoneHours(
        windows: false,
        rotation: false,
        timing: null,
      );
      // ignore: avoid_print
      print('on time, not shown: ${line(r)}');
      expect(r.perHour(r.wakes, from, to), closeTo(6, 0.1));
      expectAsDocumented(r, 'on time');
    });

    test('alarms on time, shown nearby: the beat and the token\'s change '
        'share their wakes (12 an hour before, 6 now)', () async {
      final _Hours before = await _lockedPhoneHours(
        windows: false,
        rotation: true,
        timing: null,
      );
      final _Hours now = await _lockedPhoneHours(
        windows: false,
        rotation: true,
        timing: const WakeAlarmTiming(exactAllowed: true, rotation: true),
      );
      // ignore: avoid_print
      print('on time, shown: before ${line(before)}\n  now ${line(now)}');
      expect(before.perHour(before.wakes, from, to), closeTo(12, 0.1));
      expect(now.perHour(now.wakes, from, to), closeTo(6, 0.1));
      expectAsDocumented(now, 'on time, shown');
    });

    test('Android, shown nearby: 8.25 wakes an hour and rounds up to 17:30 '
        'apart before; now 6, on the token\'s wakes', () async {
      for (final double others in <double>[0, 12]) {
        final _Hours before = await _lockedPhoneHours(
          windows: true,
          rotation: true,
          timing: null,
          latencyMs: 150,
          otherPerHour: others,
        );
        final _Hours now = await _lockedPhoneHours(
          windows: true,
          rotation: true,
          timing: android12Nearby,
          latencyMs: 150,
          otherPerHour: others,
        );
        // ignore: avoid_print
        print(
          'Android, shown, other apps $others/h: before ${line(before)}\n'
          '  now ${line(now)}',
        );
        if (others == 0) {
          expect(before.perHour(before.wakes, from, to), closeTo(8.25, 0.1));
          expect(
            before.maxGap(before.rounds, from, to),
            greaterThan(17 * _min),
          );
        }
        expect(now.perHour(now.wakes, from, to), lessThanOrEqualTo(6.01));
        expectAsDocumented(now, 'Android, shown, others $others');
      }
    });

    test('Android, not shown nearby: rounds up to 17:23 apart before (3.42 '
        'wakes an hour); now every 10 minutes, on exact alarms where they '
        'are allowed and on the end of the window where not', () async {
      for (final double others in <double>[0, 12, 60]) {
        final _Hours before = await _lockedPhoneHours(
          windows: true,
          rotation: false,
          timing: null,
          latencyMs: 150,
          otherPerHour: others,
        );
        if (others == 0) {
          expect(before.perHour(before.wakes, from, to), closeTo(3.42, 0.05));
          expect(
            before.maxGapOneLost(before.rounds, from, to),
            greaterThanOrEqualTo(kPresenceBackgroundFor.inMilliseconds),
            reason: 'a friend saw "poza siecią" after one lost round',
          );
        }
        for (final WakeAlarmTiming timing in <WakeAlarmTiming>[
          android12,
          noExactAlarms,
        ]) {
          final _Hours now = await _lockedPhoneHours(
            windows: true,
            rotation: false,
            timing: timing,
            latencyMs: 150,
            otherPerHour: others,
          );
          // ignore: avoid_print
          print(
            'Android, not shown, exact ${timing.exactAllowed}, other apps '
            '$others/h: before ${line(before)}\n  now ${line(now)}',
          );
          expect(now.perHour(now.wakes, from, to), lessThanOrEqualTo(6.01));
          expectAsDocumented(
            now,
            'Android, not shown, exact ${timing.exactAllowed}, others $others',
          );
        }
      }
    });

    test('a wake on the grid runs what it was planned for, and the round '
        'keeps to the grid', () async {
      int clock = 1000 * _hour + 3 * _min + 7 * _sec;
      final _PhoneAlarms phone = _PhoneAlarms(windows: false, now: () => clock);
      ZenWake.platform = phone;
      ZenWake.nowMillis = () => clock;
      ZenWake.alarmTiming = () => android12;
      final List<int> ran = <int>[];
      ZenWake.beat(
        'presence-round',
        kLockedPresenceRoundEvery,
        () async => ran.add(clock),
      );
      for (int i = 0; i < 6; i++) {
        final _PhoneAlarm next = phone.live.single;
        clock = next.at;
        await next.fire();
      }
      // Early by a third of the period at most, towards the boundary,
      // then a second before each boundary's token change.
      final int grid = kWakeGrid.inMilliseconds;
      final List<int> offsets = <int>[
        for (final int t in ran) (t + _sec - 500) % grid,
      ];
      expect(offsets.skip(2), everyElement(0));
      for (int i = 1; i < ran.length; i++) {
        expect(
          ran[i] - ran[i - 1],
          greaterThanOrEqualTo(
            (kLockedPresenceRoundEvery -
                    wakeBeatEarly(kLockedPresenceRoundEvery))
                .inMilliseconds,
          ),
        );
        expect(
          ran[i] - ran[i - 1],
          lessThanOrEqualTo(kLockedPresenceRoundEvery.inMilliseconds),
        );
      }
      // Work due every few minutes (here, the first polls; the parked
      // service's watchdog) is asked for when due, as before.
      ZenWake.beat('mailbox-poll', const Duration(minutes: 5), () async {});
      final _PhoneAlarm poll = phone.live.single;
      expect(poll.at - clock, 5 * _min);
    });

    /// Where a wake on the grid lies: half a second before each 10-minute
    /// boundary of the epoch (a second before the token's change).
    int gridOffset(int t) {
      final int grid = kWakeGrid.inMilliseconds;
      final int off =
          (t +
              kWakeGridLead.inMilliseconds -
              kWakeGridRotationLag.inMilliseconds) %
          grid;
      return off > grid ~/ 2 ? off - grid : off;
    }

    /// On the grid, to Android's rounding of the window (a millisecond or
    /// two).
    final Matcher onGrid = closeTo(0, 2);

    /// The presence round alone on the beat from [start], its alarms as
    /// Android delivers them (each at the end of its window), [rounds]
    /// times. After round [jumpAfter] the wall clock jumps by [jump]: the
    /// alarm asked for before still comes after its delay.
    Future<({_PhoneAlarms phone, List<int> ran, int now})> roundsOn(
      WakeAlarmTiming timing, {
      required int start,
      int rounds = 4,
      int jumpAfter = -1,
      int jump = 0,
    }) async {
      int clock = start;
      final _PhoneAlarms phone = _PhoneAlarms(windows: true, now: () => clock);
      ZenWake.platform = phone;
      ZenWake.nowMillis = () => clock;
      ZenWake.alarmTiming = () => timing;
      final List<int> ran = <int>[];
      ZenWake.beat(
        'presence-round',
        kLockedPresenceRoundEvery,
        () async => ran.add(clock),
      );
      int shift = 0;
      for (int i = 0; i < rounds; i++) {
        final _PhoneAlarm next = phone.live.single;
        clock = next.maxAt + shift;
        shift = 0;
        await next.fire();
        await _settle();
        if (i == jumpAfter) {
          clock += jump;
          shift = jump;
        }
      }
      return (phone: phone, ran: ran, now: clock);
    }

    test(
      'without exact alarms a wake on the grid is asked for so that its '
      "window ends on the boundary, where friends' exact alarms come",
      () async {
        // Started off the grid (3:07 past a boundary).
        const int start = 1000 * _hour + 3 * _min + 7 * _sec;
        final r = await roundsOn(noExactAlarms, start: start);
        final _PhoneAlarm alarm = r.phone.live.single;
        // The window ends on the grid; Android delivers the alarm from the
        // time asked for on, never before.
        expect(gridOffset(alarm.maxAt), onGrid);
        expect(alarm.maxAt - alarm.at, closeTo((alarm.at - r.now) * 0.75, 2));
        // The rounds came onto the grid within two periods of the start and
        // stayed there, a period apart.
        expect(r.ran.skip(2).map(gridOffset), everyElement(onGrid));
        for (int i = 1; i < r.ran.length; i++) {
          expect(
            r.ran[i] - r.ran[i - 1],
            inInclusiveRange(
              (kLockedPresenceRoundEvery -
                      wakeBeatEarly(kLockedPresenceRoundEvery))
                  .inMilliseconds,
              kLockedPresenceRoundEvery.inMilliseconds,
            ),
          );
        }
        // With exact alarms: the same boundaries, on an exact alarm.
        ZenWake.resetForTest();
        final r2 = await roundsOn(android12, start: start);
        final _PhoneAlarm exact = r2.phone.live.single;
        expect(exact.at, exact.maxAt);
        expect(gridOffset(exact.at), onGrid);
        for (int i = 2; i < r.ran.length; i++) {
          expect(r2.ran[i], closeTo(r.ran[i], 2));
        }
      },
    );

    test('work due every few minutes is asked for when it is due, as '
        'before', () {
      const int clock = 1000 * _hour + 2 * _min;
      final _PhoneAlarms phone = _PhoneAlarms(windows: true, now: () => clock);
      ZenWake.platform = phone;
      ZenWake.nowMillis = () => clock;
      ZenWake.alarmTiming = () => noExactAlarms;
      ZenWake.beat('mailbox-poll', const Duration(minutes: 5), () async {});
      // Not on the grid: asked for when due, its window as Android gives it.
      expect(phone.live.single.at - clock, 5 * _min);
      // Plain timers are asked for when the work is due, as before.
      ZenWake.resetForTest();
      ZenWake.alarmTiming = () => null;
      ZenWake.beat('presence-round', kLockedPresenceRoundEvery, () async {});
      expect(phone.live.last.at - clock, 10 * _min);
    });

    test('a wake on the grid that Android delivers early runs nothing early: '
        'the round keeps to the boundary, on a wake asked for anew', () async {
      int clock = 1000 * _hour + 9 * _min + 59 * _sec + 500;
      final _PhoneAlarms phone = _PhoneAlarms(windows: true, now: () => clock);
      ZenWake.platform = phone;
      ZenWake.nowMillis = () => clock;
      ZenWake.alarmTiming = () => noExactAlarms;
      final List<int> ran = <int>[];
      ZenWake.beat(
        'presence-round',
        kLockedPresenceRoundEvery,
        () async => ran.add(clock),
      );
      final _PhoneAlarm first = phone.live.single;
      final int boundary = first.maxAt;
      expect(gridOffset(boundary), onGrid);
      // Another app's alarm wakes the phone inside the window, two minutes
      // before the boundary, and Android takes Zen's alarm along.
      clock = boundary - 2 * _min;
      expect(clock, greaterThanOrEqualTo(first.at));
      await first.fire();
      await _settle();
      expect(ran, isEmpty, reason: 'before, the round ran 2 minutes early');
      final _PhoneAlarm again = phone.live.single;
      expect(again.maxAt, closeTo(boundary, 2));
      clock = again.maxAt;
      await again.fire();
      await _settle();
      expect(ran.single, closeTo(boundary, 2));
    });

    test('the grid is on epoch time: a time zone or daylight saving time does '
        'not move it, and a clock set back or forward finds it again', () async {
      // 25 October 2026, 01:00 UTC: Poland goes from summer to winter time.
      final int dst = DateTime.utc(
        2026,
        10,
        25,
        0,
        57,
        13,
      ).millisecondsSinceEpoch;
      for (final WakeAlarmTiming timing in <WakeAlarmTiming>[
        noExactAlarms,
        android12,
      ]) {
        ZenWake.resetForTest();
        final r = await roundsOn(timing, start: dst, rounds: 5);
        expect(gridOffset(r.phone.live.single.maxAt), onGrid);
        // Onto the grid within two periods of the start (7:13 past a boundary).
        expect(r.ran.skip(2).map(gridOffset), everyElement(onGrid));
        // The clock set back 37 minutes or forward an hour and 13 seconds
        // (by hand, or by the network's time) after the second round.
        for (final int jump in <int>[-37 * _min, _hour + 13 * _sec]) {
          ZenWake.resetForTest();
          final r2 = await roundsOn(
            timing,
            start: dst,
            rounds: 6,
            jumpAfter: 1,
            jump: jump,
          );
          expect(
            r2.ran.skip(4).map(gridOffset),
            everyElement(onGrid),
            reason:
                'jump ${jump ~/ _sec} s, exact ${timing.exactAllowed}: '
                '${r2.ran.map(gridOffset).toList()}',
          );
          expect(gridOffset(r2.phone.live.single.maxAt), onGrid);
        }
      }
    });
  });

  group('Android', () {
    late List<MethodCall> calls;
    MockStreamHandlerEventSink? sink;

    void mockPower() {
      calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(power, (MethodCall call) async {
        calls.add(call);
        return call.method == 'schedule' ? true : null;
      });
      messenger.setMockStreamHandler(
        events,
        MockStreamHandler.inline(
          onListen: (Object? arguments, MockStreamHandlerEventSink events) {
            sink = events;
          },
        ),
      );
    }

    Map<Object?, Object?> argsOf(String method) =>
        calls.lastWhere((MethodCall c) => c.method == method).arguments
            as Map<Object?, Object?>;

    test('a wake holds under its own tag and lets go once the work is '
        'done', () async {
      mockPower();
      final AndroidWakePlatform android = AndroidWakePlatform();
      final Completer<void> work = Completer<void>();
      bool fired = false;
      final WakeTimer timer = android.after(
        'beat',
        const Duration(minutes: 5),
        () {
          fired = true;
          return work.future;
        },
        hold: const Duration(seconds: 15),
        exact: false,
        whileIdle: false,
      );
      await _settle();
      expect(timer.isActive, isTrue);
      final Map<Object?, Object?> scheduled = argsOf('schedule');
      expect(scheduled['holdMs'], 15000);
      expect(scheduled['whileIdle'], isFalse);
      final String tag = scheduled['tag']! as String;
      expect(tag, startsWith('wake.'));
      expect(tag, endsWith('.beat'));

      sink!.success(<String, Object?>{'type': 'wake', 'id': scheduled['id']});
      await _settle();
      expect(fired, isTrue);
      expect(timer.isActive, isFalse, reason: 'spent once it rang');
      expect(calls.where((MethodCall c) => c.method == 'release'), isEmpty);
      work.complete();
      await _settle();
      final Map<Object?, Object?> released = argsOf('release');
      expect(released['tag'], tag);
      expect(released['afterMs'], 1000);
      // Not by the backup timer: the alarm already came.
      expect(calls.where((MethodCall c) => c.method == 'cancel'), isEmpty);
    });

    test('the beat lets go of a wake as soon as its works are done', () async {
      mockPower();
      ZenWake.platform = AndroidWakePlatform();
      final Completer<void> sends = Completer<void>();
      ZenWake.beat(
        'locked-outbox',
        const Duration(minutes: 10),
        () => sends.future,
        hold: const Duration(seconds: 10),
      );
      await _settle();
      final Map<Object?, Object?> scheduled = argsOf('schedule');
      expect(scheduled['holdMs'], 10000);
      now = 10 * 60 * 1000;
      sink!.success(<String, Object?>{'type': 'wake', 'id': scheduled['id']});
      await _settle();
      expect(calls.where((MethodCall c) => c.method == 'release'), isEmpty);
      sends.complete();
      await _settle();
      final Map<Object?, Object?> released = argsOf('release');
      expect(released['tag'], scheduled['tag']);
      expect(released['afterMs'], 1000);
    });

    test('a wake whose work fails lets go too', () async {
      mockPower();
      final AndroidWakePlatform android = AndroidWakePlatform();
      android.after(
        'broken',
        const Duration(minutes: 1),
        () => throw StateError('broken'),
        hold: const Duration(seconds: 8),
        exact: false,
      );
      await _settle();
      final Map<Object?, Object?> scheduled = argsOf('schedule');
      expect(
        scheduled['whileIdle'],
        isTrue,
        reason: 'unless asked otherwise, Doze does not put a wake off',
      );
      sink!.success(<String, Object?>{'type': 'wake', 'id': scheduled['id']});
      await _settle();
      expect(argsOf('release')['tag'], scheduled['tag']);
    });

    testWidgets('without alarms a plain timer runs the work and holds '
        'nothing', (WidgetTester tester) async {
      calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(power, (MethodCall call) async {
        calls.add(call);
        if (call.method == 'schedule') {
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      final AndroidWakePlatform android = AndroidWakePlatform();
      int runs = 0;
      final WakeTimer timer = android.after(
        'look',
        const Duration(seconds: 30),
        () async => runs++,
        hold: const Duration(seconds: 5),
        exact: false,
      );
      await tester.pump();
      expect(timer.isActive, isTrue);
      await tester.pump(const Duration(seconds: 31));
      expect(runs, 1, reason: 'the timer, long before the backup');
      expect(timer.isActive, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(
        calls.where((MethodCall c) => c.method == 'release'),
        isEmpty,
        reason: 'no alarm held the phone: nothing to let go',
      );
      expect(calls.where((MethodCall c) => c.method == 'cancel'), isEmpty);
    });

    testWidgets('the backup timer that came first cancels the alarm', (
      WidgetTester tester,
    ) async {
      mockPower();
      final AndroidWakePlatform android = AndroidWakePlatform();
      int runs = 0;
      android.after(
        'outbox',
        const Duration(seconds: 1),
        () => runs++,
        hold: const Duration(seconds: 5),
        exact: false,
      );
      await tester.pump();
      final Object? id = argsOf('schedule')['id'];
      await tester.pump(const Duration(minutes: 2));
      expect(runs, 1);
      expect(argsOf('cancel')['id'], id, reason: 'no empty wake later');
      // A late alarm does nothing more.
      sink?.success(<String, Object?>{'type': 'wake', 'id': id});
      await tester.pump();
      expect(runs, 1);
    });
  });
}
