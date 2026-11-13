import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Wakes an hour of locked phones whose friends are locked too, each phone
// with its own WakeBeat planning its alarms (the grid, the token's change,
// Android's late windows) and the real LockedReceiver on it (mailbox polls
// with their back-off, presence rounds, pongs), on a virtual clock. Not a
// device.
//
// The model of Android's alarms (as zen_wake_test.dart's, for many phones):
// * an exact alarm goes off on time; an inexact one (Android 12 and later)
//   gets a window of 3/4 of its delay (from 10 s on) and goes off at the
//   window's end unless the phone wakes before for one of its other alarms,
//   which takes along every alarm whose window has begun; whether a packet
//   that wakes the phone takes them along too, Android does not say, so
//   both are run ([framesTakeAlarms]);
// * an alarm that may not wake the phone in Doze (the update check) goes off
//   only while the phone is awake anyway;
// * a phone shown nearby changes its token on an exact alarm 0.5 s past
//   every 10-minute boundary of ITS wall clock;
// * a frame reaches its phone 80 ms after it was sent; a frame that comes
//   while its phone sleeps wakes it and holds it 3 s (ZenWake.signalHold);
//   a wake for alarms holds it 2 s past the work (the linger and the link
//   check's answer);
// * a star: one phone (the "centre") with N friends, each friend with the
//   centre as its only friend here. For the centre that is the same as N
//   friends who are friends among themselves too: only frames to the centre
//   wake it. The centre is a mailbox of min(6, N) friends and polls min(6,
//   N) of them as its mailboxes.

const int _sec = 1000;
const int _min = 60 * _sec;
const int _hour = 60 * _min;

String _address(int i) => PeerShareCodec.normalizeAddress(
  '200:1111:2222:3333:4444:5555:${(0x2000 + i).toRadixString(16)}:1',
);

final class _Alarm implements WakeTimer {
  _Alarm(this.at, this.maxAt, this.whileIdle, this.fire);

  final int at;
  final int maxAt;
  final bool whileIdle;
  final FutureOr<void> Function() fire;
  bool done = false;

  @override
  bool get isActive => !done;

  @override
  void cancel() => done = true;
}

final class _Phone {
  _Phone(this.index, this.timing, this.skew);

  final int index;
  final WakeAlarmTiming timing;

  /// This phone's wall clock minus the true time.
  final int skew;
  final WakeBeat beat = WakeBeat();
  final List<_Alarm> alarms = <_Alarm>[];
  final Map<String, int> holds = <String, int>{};
  late LockedReceiver receiver;
  int awakeUntil = -1 << 40;
  int wakesByFrame = 0;
  int wakesByAlarm = 0;

  /// When this phone last heard a ping or pong from each phone (true time).
  final Map<int, int> heardAt = <int, int>{};

  /// The longest it went without one, per phone, in the measured hours.
  final Map<int, int> silence = <int, int>{};

  int get heldUntil =>
      holds.values.fold<int>(awakeUntil, (int a, int b) => math.max(a, b));
}

final class _World implements ZenWakePlatform {
  _World();

  int clock = 1000 * _hour + 3 * _min + 17 * _sec;
  final List<_Phone> phones = <_Phone>[];
  int current = 0;
  final List<(int, int, SignalTransportFrame)> air =
      <(int, int, SignalTransportFrame)>[];

  _Phone get phone => phones[current];

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    final int d = math.max(0, delay.inMilliseconds);
    final int window = !exact && d >= 10 * _sec ? (d * 0.75).round() : 0;
    final _Alarm a = _Alarm(clock + d, clock + d + window, whileIdle, fire);
    phone.alarms.add(a);
    return a;
  }

  @override
  Future<void> hold(String tag, Duration duration) async {
    phone.holds[tag] = math.max(
      phone.holds[tag] ?? 0,
      clock + duration.inMilliseconds,
    );
  }

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {
    phone.holds[tag] = clock + after.inMilliseconds;
  }

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

final class _Air extends MemorySignalTransport {
  _Air(this.world, this.self, this.index);

  final _World world;
  final int self;
  final Map<String, int> index;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final int? to = index[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (to == null) {
      return;
    }
    world.air.add((
      world.clock + 80,
      to,
      SignalTransportFrame(
        from: _address(self),
        payload: Map<String, dynamic>.from(payload),
        receivedAtMillis: world.clock + 80 + world.phones[to].skew,
      ),
    ));
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

typedef _Run = ({
  double centreWakes,
  double centreByFrames,
  double friendWakes,
  double friendByFrames,
  int longestSilence,
});

Future<_Run> _simulate({
  required int friends,
  required WakeAlarmTiming Function(int phone) timing,
  required int Function(int phone, math.Random r) skew,
  int hours = 3,
  int awakeAfterMs = 2 * _sec,
  int seed = 1,
  bool framesTakeAlarms = true,
  double otherPerHour = 0,
}) async {
  final math.Random random = math.Random(seed);
  final _World world = _World();
  ZenWake.platform = world;
  ZenWake.nowMillis = () => world.clock + world.phone.skew;
  ZenWake.alarmTiming = () => world.phone.timing;
  final Directory dir = await Directory.systemTemp.createTemp('zen-grid-');
  final int phones = friends + 1;
  final Map<String, int> index = <String, int>{
    for (int i = 0; i < phones; i++) _address(i): i,
  };
  final Uint8List key = await inboxPublicKeyFor(
    Uint8List.fromList(List<int>.generate(32, (int i) => i + 7)),
  );
  for (int i = 0; i < phones; i++) {
    world.phones.add(_Phone(i, timing(i), skew(i, random)));
  }
  final int mailboxes = math.min(6, friends);
  for (int i = 0; i < phones; i++) {
    world.current = i;
    final _Phone p = world.phones[i];
    final Set<String> mine = i == 0
        ? <String>{for (int j = 1; j < phones; j++) _address(j)}
        : <String>{_address(0)};
    p.receiver = LockedReceiver(
      transport: _Air(world, i, index),
      capability: BackgroundCapability.fromDraft(
        BackgroundCapabilityDraft(
          inboxPublicKey: Uint8List(32),
          friends: mine,
          mailboxes: i == 0
              ? <String>[for (int j = 1; j <= mailboxes; j++) _address(j)]
              : (i <= mailboxes ? <String>[_address(0)] : const <String>[]),
        ),
        backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
      inbox: SealedInboxWriter(
        file: File('${dir.path}/i$i.zbox'),
        recipientPublicKey: Uint8List(32),
      ),
      presenceSnapshot: SealedSnapshotWriter(
        file: File('${dir.path}/p$i.zbox'),
        recipientPublicKey: key,
      ),
      notices: MemoryRuntimeSystemNotificationService(),
      presence: LockedPresenceKit(shownTo: mine),
      pollAnswerGrace: Duration.zero,
      beat: p.beat,
      now: () => world.clock + p.skew,
    );
    // The update check rides the beat (whileIdle false, 15 min).
    p.beat.add(
      'update-check',
      const Duration(minutes: 15),
      () async {},
      hold: const Duration(seconds: 30),
      whileIdle: false,
    );
    // Phones lock at different moments over half an hour.
    world.clock += random.nextInt(30 * _min ~/ phones);
    await p.receiver.start();
    await _settle();
  }
  final int from = world.clock + 40 * _min;
  final int end = world.clock + hours * _hour;
  int nextRotation(_Phone p, int t) {
    // The phone's wall-clock boundary + 0.5 s, in true time.
    final int local = t + p.skew;
    final int b =
        (local ~/ kWakeGrid.inMilliseconds + 1) * kWakeGrid.inMilliseconds +
        kWakeGridRotationLag.inMilliseconds;
    return b - p.skew;
  }

  final List<int> rotation = <int>[
    for (final _Phone p in world.phones)
      p.timing.rotation ? nextRotation(p, world.clock) : 1 << 62,
  ];
  // Other apps' alarms wake each phone now and then (at random), and
  // Android delivers along every alarm of Zen's whose window has begun.
  int nextOther(int t) => otherPerHour <= 0
      ? 1 << 62
      : t + (-math.log(1 - random.nextDouble()) / otherPerHour * _hour).round();
  final List<int> other = <int>[
    for (final _Phone _ in world.phones) nextOther(world.clock),
  ];

  Future<void> fireDue(_Phone p) async {
    world.current = p.index;
    final List<_Alarm> due =
        p.alarms.where((_Alarm a) => a.isActive && a.at <= world.clock).toList()
          ..sort((_Alarm a, _Alarm b) => a.at.compareTo(b.at));
    for (final _Alarm a in due) {
      if (!a.isActive) {
        continue;
      }
      a.done = true;
      world.current = p.index;
      final FutureOr<void> work = a.fire();
      if (work is Future<void>) {
        await work;
      }
      await _settle();
      p.awakeUntil = math.max(p.awakeUntil, world.clock + awakeAfterMs);
    }
    p.alarms.removeWhere((_Alarm a) => !a.isActive);
  }

  void heard(_Phone p, int j) {
    final int last = p.heardAt[j] ?? from;
    if (world.clock >= from) {
      p.silence[j] = math.max(p.silence[j] ?? 0, world.clock - last);
    }
    p.heardAt[j] = world.clock;
  }

  while (true) {
    // The next thing: a frame, an alarm that wakes its phone, a rotation.
    int next = end;
    int kind = 0; // 1 frame, 2 alarm, 3 rotation
    int who = -1;
    for (final (int, int, SignalTransportFrame) f in world.air) {
      if (f.$1 < next) {
        next = f.$1;
        kind = 1;
        who = f.$2;
      }
    }
    for (final _Phone p in world.phones) {
      for (final _Alarm a in p.alarms) {
        if (!a.isActive) {
          continue;
        }
        // Asleep, an alarm wakes the phone at the end of its window (an
        // exact one: on time); one that may not wake it in Doze waits.
        final int t = a.whileIdle ? a.maxAt : 1 << 62;
        if (t < next) {
          next = t;
          kind = 2;
          who = p.index;
        }
      }
      if (rotation[p.index] < next) {
        next = rotation[p.index];
        kind = 3;
        who = p.index;
      }
      if (other[p.index] < next) {
        next = other[p.index];
        kind = 4;
        who = p.index;
      }
    }
    if (next >= end || who < 0) {
      break;
    }
    world.clock = next;
    final _Phone p = world.phones[who];
    final bool asleep = world.clock > p.heldUntil;
    final bool counted = world.clock >= from;
    if (kind == 1) {
      final int k = world.air.indexWhere(
        ((int, int, SignalTransportFrame) f) => f.$1 == next && f.$2 == who,
      );
      final SignalTransportFrame frame = world.air.removeAt(k).$3;
      if (counted && asleep) {
        p.wakesByFrame += 1;
      }
      final Object? type = frame.payload['type'];
      if (type == 'ping' || type == 'pong') {
        heard(p, index[PeerShareCodec.normalizeAddress(frame.from)]!);
      }
      p.awakeUntil = math.max(p.awakeUntil, world.clock + 3 * _sec);
      if (framesTakeAlarms) {
        await fireDue(p);
      }
      world.current = who;
      await p.receiver.handleFrame(frame);
      await _settle();
    } else if (kind == 4) {
      // Not Zen's wake: another app's, for a moment.
      other[who] = nextOther(world.clock);
      p.awakeUntil = math.max(p.awakeUntil, world.clock + 500);
      await fireDue(p);
    } else {
      if (counted && asleep) {
        p.wakesByAlarm += 1;
      }
      if (kind == 3) {
        rotation[who] = nextRotation(p, world.clock + _sec);
        p.awakeUntil = math.max(p.awakeUntil, world.clock + 200);
      }
      await fireDue(p);
    }
  }
  world.clock = end;
  int longest = 0;
  for (final _Phone p in world.phones) {
    final Iterable<int> others = p.index == 0
        ? List<int>.generate(friends, (int j) => j + 1)
        : const <int>[0];
    for (final int j in others) {
      heard(p, j);
      longest = math.max(longest, p.silence[j] ?? 0);
    }
  }
  final double h = (end - from) / _hour;
  final _Phone c = world.phones[0];
  final List<_Phone> rest = world.phones.sublist(1);
  double avg(int Function(_Phone) f) =>
      rest.map(f).fold<int>(0, (int a, int b) => a + b) / rest.length / h;
  for (final _Phone p in world.phones) {
    world.current = p.index;
    await p.receiver.stop();
    p.beat.clear();
  }
  ZenWake.resetForTest();
  ZenWake.platform = const TimerWakePlatform();
  ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
  await dir.delete(recursive: true);
  return (
    centreWakes: (c.wakesByAlarm + c.wakesByFrame) / h,
    centreByFrames: c.wakesByFrame / h,
    friendWakes: avg((_Phone p) => p.wakesByAlarm + p.wakesByFrame),
    friendByFrames: avg((_Phone p) => p.wakesByFrame),
    longestSilence: longest,
  );
}

const WakeAlarmTiming _exactNearby = WakeAlarmTiming(
  exactAllowed: true,
  lateWindows: true,
  rotation: true,
);
const WakeAlarmTiming _exact = WakeAlarmTiming(
  exactAllowed: true,
  lateWindows: true,
);
const WakeAlarmTiming _noExact = WakeAlarmTiming(lateWindows: true);

int _within(int ms, math.Random r) => r.nextInt(2 * ms + 1) - ms;

typedef _Scenario = ({
  String name,
  WakeAlarmTiming Function(int) timing,
  int Function(int, math.Random) skew,
  bool framesTakeAlarms,
  double otherPerHour,
  double centreAtMost,
  double friendAtMost,
});

_Scenario _scenario(
  String name,
  WakeAlarmTiming Function(int) timing, {
  required double centreAtMost,
  required double friendAtMost,
  int skewMs = _sec,
  bool framesTakeAlarms = false,
  double otherPerHour = 0,
}) => (
  name: name,
  timing: timing,
  skew: (int _, math.Random r) => _within(skewMs, r),
  framesTakeAlarms: framesTakeAlarms,
  otherPerHour: otherPerHour,
  centreAtMost: centreAtMost,
  friendAtMost: friendAtMost,
);

// Wakes an hour of the phone in the middle and of an average friend, at
// most, for 5, 10, 30 and 100 friends (the measured numbers are printed).
// Before this version, without exact alarms, a phone kept its own phase:
// 7.7 / 18 / 8.1 / 7.7 wakes an hour in the middle with no exact alarms
// anywhere (36 / 72 at 10 / 30 friends when a packet takes no alarms
// along), and 30 / 39 / 66 / 126 when it had exact alarms and its friends
// did not.
final List<_Scenario> _scenarios = <_Scenario>[
  _scenario(
    'all exact alarms, shown nearby, clocks within 1 s',
    (int _) => _exactNearby,
    centreAtMost: 6.01,
    friendAtMost: 6.01,
  ),
  _scenario(
    'all exact alarms, not shown nearby, clocks within 1 s',
    (int _) => _exact,
    centreAtMost: 6.01,
    friendAtMost: 6.01,
  ),
  // Android 14's default; a packet that wakes the phone takes no alarm
  // along (AlarmManager delivers alarms on its own timer only).
  _scenario(
    'no exact alarms anywhere (Android 14+ default)',
    (int _) => _noExact,
    centreAtMost: 6.01,
    friendAtMost: 6.01,
  ),
  // Other apps' alarms take Zen's along early, inside their windows: the
  // grid's wakes keep to the boundary (an early one runs nothing early).
  _scenario(
    'no exact alarms anywhere, other apps wake each phone 12 times an hour',
    (int _) => _noExact,
    otherPerHour: 12,
    centreAtMost: 10,
    friendAtMost: 6.5,
  ),
  // The model before: a packet takes along every alarm whose window began.
  _scenario(
    'no exact alarms anywhere, a packet takes alarms along',
    (int _) => _noExact,
    framesTakeAlarms: true,
    centreAtMost: 19,
    friendAtMost: 10,
  ),
  _scenario(
    'centre exact+nearby, friends without exact alarms',
    (int i) => i == 0 ? _exactNearby : _noExact,
    centreAtMost: 6.01,
    friendAtMost: 6.01,
  ),
  _scenario(
    'centre exact+nearby, friends without, other apps 12 times an hour',
    (int i) => i == 0 ? _exactNearby : _noExact,
    otherPerHour: 12,
    centreAtMost: 10,
    friendAtMost: 6.5,
  ),
  _scenario(
    'centre exact+nearby, friends without, a packet takes alarms along',
    (int i) => i == 0 ? _exactNearby : _noExact,
    framesTakeAlarms: true,
    centreAtMost: 19,
    friendAtMost: 8.5,
  ),
  // Clocks apart: within the 3 s a frame holds the phone, friends share
  // their wakes; further apart, each pair's ping wakes one of the two.
  _scenario(
    'all exact+nearby, clocks up to 5 s apart',
    (int _) => _exactNearby,
    skewMs: 5 * _sec,
    centreAtMost: 10,
    friendAtMost: 11,
  ),
  _scenario(
    'all exact+nearby, clocks up to 30 s apart',
    (int _) => _exactNearby,
    skewMs: 30 * _sec,
    centreAtMost: 40,
    friendAtMost: 13,
  ),
  _scenario(
    'all exact+nearby, clocks up to 90 s apart (time set by hand)',
    (int _) => _exactNearby,
    skewMs: 90 * _sec,
    centreAtMost: 40,
    friendAtMost: 13,
  ),
];

String _mmss(int ms) =>
    '${ms ~/ _min}:${((ms % _min) ~/ _sec).toString().padLeft(2, '0')}';

void main() {
  for (final int friends in <int>[5, 10, 30, 100]) {
    for (final _Scenario s in _scenarios) {
      test('$friends friends: ${s.name}', () async {
        final _Run r = await _simulate(
          friends: friends,
          timing: s.timing,
          skew: s.skew,
          seed: friends,
          framesTakeAlarms: s.framesTakeAlarms,
          otherPerHour: s.otherPerHour,
        );
        // ignore: avoid_print
        print(
          'grid friends=$friends [${s.name}]: centre wakes/h '
          '${r.centreWakes.toStringAsFixed(1)} (by frames '
          '${r.centreByFrames.toStringAsFixed(1)}); a friend phone wakes/h '
          '${r.friendWakes.toStringAsFixed(1)} (by frames '
          '${r.friendByFrames.toStringAsFixed(1)}); longest silence '
          '${_mmss(r.longestSilence)}',
        );
        expect(r.centreWakes, lessThanOrEqualTo(s.centreAtMost));
        expect(r.friendWakes, lessThanOrEqualTo(s.friendAtMost));
        // A word from every friend every round, and a moment: nobody shows
        // "poza siecią", and "w tle" never runs out.
        expect(r.longestSilence, lessThanOrEqualTo(10 * _min + 15 * _sec));
      }, timeout: const Timeout(Duration(minutes: 30)));
    }
  }
}
