import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';

final class _Alarm implements WakeTimer {
  _Alarm(
    this.name,
    this.delay,
    this.fire, {
    required this.hold,
    required this.whileIdle,
  });

  final String name;
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

  test('a signal holds the phone only a moment', () {
    expect(ZenWake.signalHold, lessThanOrEqualTo(const Duration(seconds: 3)));
    ZenWake.signalArrived();
    ZenWake.signalArrived();
    expect(platform.calls, <String>['hold signal 3']);
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
      android.after(
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
      final Map<Object?, Object?> scheduled = argsOf('schedule');
      expect(scheduled['holdMs'], 15000);
      expect(scheduled['whileIdle'], isFalse);
      final String tag = scheduled['tag']! as String;
      expect(tag, startsWith('wake.'));
      expect(tag, endsWith('.beat'));

      sink!.success(<String, Object?>{'type': 'wake', 'id': scheduled['id']});
      await _settle();
      expect(fired, isTrue);
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
      sink!.success(<String, Object?>{'type': 'wake', 'id': scheduled['id']});
      await _settle();
      expect(argsOf('release')['tag'], scheduled['tag']);
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
