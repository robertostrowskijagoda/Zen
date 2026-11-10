import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Locked phones of friends, each showing its status to every other one,
// each running its presence round every 10 minutes: the real LockedReceiver
// on a virtual clock (not a device). Frames reach their phone 80 ms after
// they are sent. A frame that comes while its phone sleeps wakes it: a
// phone is awake 5 s from its own round and 3 s from a frame
// (ZenWake.signalHold), and a frame up to 3 s before its own round's alarm
// only brings that wake forward.
//
// A phone on 1.16.4 or earlier is modelled as that version answered and
// pinged: its round pings every friend, and it answers a friend's ping at
// most every kLockedPongEvery. What the same phones did when all of them
// ran 1.16.4 is the "before" of each number.

const int _sec = 1000;
const int _min = 60 * _sec;
const int _hour = 60 * _min;
const int _start = 1000 * _hour;

/// As the app hands addresses to the service (normalized).
String _address(int i) => PeerShareCodec.normalizeAddress(
  '200:1111:2222:3333:4444:5555:${(0x2000 + i).toRadixString(16)}:1',
);

/// A frame on its way, or (no frame) a phone's own round.
final class _Event {
  _Event(this.at, this.to, this.frame);

  final int at;
  final int to;
  final SignalTransportFrame? frame;
}

final class _Air extends MemorySignalTransport {
  _Air(this.self, this.sim);

  final int self;
  final _Sim sim;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    sim.send(self, remoteAddress, payload);
  }
}

/// A phone on 1.16.4: pings every friend on each round, answers a friend's
/// ping at most every kLockedPongEvery.
final class _OldPhone {
  _OldPhone(this.self, this.sim, this.friends);

  final int self;
  final _Sim sim;
  final Set<String> friends;
  final Map<String, int> _pongedAt = <String, int>{};

  Future<void> round() async {
    for (final String f in friends) {
      sim.send(self, f, <String, dynamic>{
        'type': 'ping',
        'state': 'background',
        'sq': sim.clock,
      });
    }
  }

  Future<void> frame(SignalTransportFrame frame) async {
    if (frame.payload['type'] != 'ping') {
      return;
    }
    final int? last = _pongedAt[frame.from];
    if (last != null &&
        sim.clock >= last &&
        sim.clock - last < kLockedPongEvery.inMilliseconds) {
      return;
    }
    _pongedAt[frame.from] = sim.clock;
    sim.send(self, frame.from, <String, dynamic>{
      'type': 'pong',
      'state': 'background',
      'sq': sim.clock,
    });
  }
}

/// What a run measured, per phone and hour after the first 20 minutes.
final class _Result {
  _Result(this.phones, this.hours);

  final int phones;
  final double hours;
  final List<int> wokenBy = <int>[];
  final List<int> framesIn = <int>[];
  final List<int> writes = <int>[];

  /// Pings each phone sent to each friend ([_Sim.pingsTo]).
  final Map<(int, int), int> pings = <(int, int), int>{};

  /// The longest time a phone went without a word (ping or pong) from a
  /// friend, per pair (hearer, friend).
  final Map<(int, int), int> silence = <(int, int), int>{};

  double avg(List<int> v, {Iterable<int>? only}) {
    final List<int> idx = (only ?? List<int>.generate(v.length, (int i) => i))
        .toList();
    return idx.map((int i) => v[i]).fold<int>(0, (int a, int b) => a + b) /
        idx.length /
        hours;
  }

  int maxSilence({bool Function(int hearer, int friend)? where}) {
    int most = 0;
    silence.forEach(((int, int) pair, int gap) {
      if (where == null || where(pair.$1, pair.$2)) {
        most = math.max(most, gap);
      }
    });
    return most;
  }
}

final class _Sim {
  _Sim({
    required this.phones,
    required this.oldPhones,
    required this.grid,
    required this.seed,
    this.off = const <int>{},
    this.lose,
  });

  final int phones;

  /// Which phones run 1.16.4.
  final Set<int> oldPhones;

  /// Rounds on the 10-minute grid of the wall clock (clocks up to 2 s
  /// apart); otherwise each phone at its own phase.
  final bool grid;
  final int seed;

  /// Phones that are off: they send nothing, and nothing reaches them.
  final Set<int> off;

  /// Frames lost on the way (from, to, type, sent at).
  final bool Function(int from, int to, String type, int at)? lose;

  int clock = _start;
  final List<_Event> _queue = <_Event>[];
  late final Map<String, int> _index = <String, int>{
    for (int i = 0; i < phones; i++) _address(i): i,
  };
  final Map<(int, int), int> pingsTo = <(int, int), int>{};
  int _from = _start;

  void send(int from, String to, Map<String, dynamic> payload) {
    final int? j = _index[to];
    final String type = '${payload['type']}';
    if (j == null || off.contains(from)) {
      return;
    }
    if (type == 'ping' && clock >= _from) {
      pingsTo[(from, j)] = (pingsTo[(from, j)] ?? 0) + 1;
    }
    if (off.contains(j) || (lose?.call(from, j, type, clock) ?? false)) {
      return;
    }
    _queue.add(
      _Event(
        clock + 80,
        j,
        SignalTransportFrame(
          from: _address(from),
          payload: Map<String, dynamic>.from(payload),
          receivedAtMillis: clock + 80,
        ),
      ),
    );
  }

  Future<_Result> run({int hours = 3}) async {
    final math.Random random = math.Random(seed);
    final Directory dir = await Directory.systemTemp.createTemp('zen-ps-');
    final Uint8List inboxKey = await inboxPublicKeyFor(
      Uint8List.fromList(List<int>.generate(32, (int i) => i + 7)),
    );
    final List<LockedReceiver?> receivers = <LockedReceiver?>[];
    final List<_OldPhone?> olds = <_OldPhone?>[];
    final List<File> snapshots = <File>[];
    for (int i = 0; i < phones; i++) {
      final Set<String> others = <String>{
        for (int j = 0; j < phones; j++)
          if (j != i) _address(j),
      };
      final File snapshot = File('${dir.path}/p$i.zbox');
      snapshots.add(snapshot);
      if (oldPhones.contains(i)) {
        receivers.add(null);
        olds.add(_OldPhone(i, this, others));
        continue;
      }
      olds.add(null);
      receivers.add(
        LockedReceiver(
          transport: _Air(i, this),
          capability: BackgroundCapability.fromDraft(
            BackgroundCapabilityDraft(
              inboxPublicKey: Uint8List(32),
              friends: others,
            ),
            backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
          ),
          inbox: SealedInboxWriter(
            file: File('${dir.path}/i$i.zbox'),
            recipientPublicKey: Uint8List(32),
          ),
          notices: MemoryRuntimeSystemNotificationService(),
          presence: LockedPresenceKit(shownTo: others),
          presenceSnapshot: SealedSnapshotWriter(
            file: snapshot,
            recipientPublicKey: inboxKey,
          ),
          mailboxPollInterval: Duration.zero,
          // Run by hand below, at each phone's own times.
          presenceRoundEvery: kLockedPresenceRoundEvery,
          now: () => clock,
        ),
      );
    }
    for (final LockedReceiver? r in receivers) {
      await r?.start();
    }
    final int end = _start + hours * _hour;
    _from = _start + 20 * _min;
    final List<List<int>> own = <List<int>>[];
    for (int i = 0; i < phones; i++) {
      // On the grid: the boundary of the token's change, a second early,
      // by clocks up to 2 s apart.
      final int phase = grid
          ? 10 * _min - 500 + random.nextInt(2 * _sec)
          : random.nextInt(10 * _min);
      own.add(<int>[]);
      if (off.contains(i)) {
        continue;
      }
      // Past the end too: a frame at the end may come just before a round.
      for (int t = _start + phase; t < end + 10 * _min; t += 10 * _min) {
        _queue.add(_Event(t, i, null));
        own[i].add(t);
      }
    }
    final _Result result = _Result(phones, (end - _from) / _hour);
    final List<int> awakeUntil = List<int>.filled(phones, -1 << 40);
    bool ownWakeSoon(int i, int t) =>
        own[i].any((int r) => r > t && r <= t + 3 * _sec);
    result.wokenBy.addAll(List<int>.filled(phones, 0));
    result.framesIn.addAll(List<int>.filled(phones, 0));
    result.writes.addAll(List<int>.filled(phones, 0));
    final Map<(int, int), int> heardAt = <(int, int), int>{
      for (int i = 0; i < phones; i++)
        for (int j = 0; j < phones; j++)
          if (i != j) (i, j): _start,
    };
    void heard(int i, int j) {
      final int gap = clock - heardAt[(i, j)]!;
      if (clock >= _from) {
        result.silence[(i, j)] = math.max(result.silence[(i, j)] ?? 0, gap);
      }
      heardAt[(i, j)] = clock;
    }

    Future<void> afterEvent(int i, Future<void> Function() work) async {
      final File snapshot = snapshots[i];
      if (snapshot.existsSync()) {
        snapshot.deleteSync();
      }
      await work();
      await receivers[i]?.presenceKept;
      if (clock >= _from && snapshot.existsSync()) {
        result.writes[i]++;
      }
    }

    while (_queue.isNotEmpty) {
      _queue.sort((_Event a, _Event b) => a.at.compareTo(b.at));
      final _Event e = _queue.removeAt(0);
      if (e.at >= end) {
        continue;
      }
      clock = e.at;
      final int i = e.to;
      final SignalTransportFrame? frame = e.frame;
      if (frame == null) {
        awakeUntil[i] = math.max(awakeUntil[i], clock + 5 * _sec);
        await afterEvent(i, () async {
          await receivers[i]?.presenceRoundForTest();
          await olds[i]?.round();
        });
        continue;
      }
      if (clock >= _from) {
        result.framesIn[i]++;
        if (clock > awakeUntil[i] && !ownWakeSoon(i, clock)) {
          result.wokenBy[i]++;
        }
      }
      awakeUntil[i] = math.max(awakeUntil[i], clock + 3 * _sec);
      final String type = '${frame.payload['type']}';
      if (type == 'ping' || type == 'pong') {
        heard(i, _index[frame.from]!);
      }
      await afterEvent(i, () async {
        await receivers[i]?.handleFrame(frame);
        await olds[i]?.frame(frame);
      });
    }
    clock = end;
    for (final (int, int) pair in heardAt.keys) {
      if (!off.contains(pair.$1) && !off.contains(pair.$2)) {
        heard(pair.$1, pair.$2);
      }
    }
    result.pings.addAll(pingsTo);
    for (final LockedReceiver? r in receivers) {
      await r?.stop();
    }
    await dir.delete(recursive: true);
    return result;
  }
}

String _mmss(int ms) =>
    '${ms ~/ _min}:${((ms % _min) ~/ _sec).toString().padLeft(2, '0')}';

void main() {
  group('locked friends wake each other no more for presence', () {
    // Before (all on 1.16.4, own phases), per phone and hour: wakes caused
    // by friends' rounds 6.0 / 30 / 60 / 154.8 for 1 / 5 / 10 / 30 friends;
    // presence.zbox written 6 / 30 / 54.5 / 116.1 times.
    const Map<int, double> wakesBefore = <int, double>{
      1: 6,
      5: 30,
      10: 60,
      30: 154.8,
    };
    for (final int friends in <int>[1, 5, 10, 30]) {
      test('$friends friends, all locked', () async {
        final int phones = friends + 1;
        final Set<int> everyone = <int>{for (int i = 0; i < phones; i++) i};
        final _Result before = await _Sim(
          phones: phones,
          oldPhones: everyone,
          grid: false,
          seed: friends,
        ).run();
        final _Result ownPhases = await _Sim(
          phones: phones,
          oldPhones: const <int>{},
          grid: false,
          seed: friends,
        ).run();
        final _Result onGrid = await _Sim(
          phones: phones,
          oldPhones: const <int>{},
          grid: true,
          seed: friends,
        ).run();
        // ignore: avoid_print
        print(
          'locked friends=$friends wakes by friends/h per phone: '
          '1.16.4 ${before.avg(before.wokenBy).toStringAsFixed(1)}, '
          'own phases ${ownPhases.avg(ownPhases.wokenBy).toStringAsFixed(1)}, '
          'on the grid ${onGrid.avg(onGrid.wokenBy).toStringAsFixed(1)}; '
          'frames in/h ${before.avg(before.framesIn).toStringAsFixed(1)} -> '
          '${ownPhases.avg(ownPhases.framesIn).toStringAsFixed(1)} / '
          '${onGrid.avg(onGrid.framesIn).toStringAsFixed(1)}; '
          'presence.zbox writes/h '
          '${ownPhases.avg(ownPhases.writes).toStringAsFixed(1)} / '
          '${onGrid.avg(onGrid.writes).toStringAsFixed(1)}; '
          'longest silence ${_mmss(before.maxSilence())} -> '
          '${_mmss(ownPhases.maxSilence())} / ${_mmss(onGrid.maxSilence())}',
        );
        expect(
          before.avg(before.wokenBy),
          closeTo(wakesBefore[friends]!, 0.5),
          reason: 'the model of 1.16.4',
        );
        // A pair of friends exchanges one ping and one pong a round, so
        // one of the two is woken: about half the wakes.
        expect(
          ownPhases.avg(ownPhases.wokenBy),
          lessThanOrEqualTo(wakesBefore[friends]! * 0.55),
        );
        // Both on the grid: each frame comes while its phone is awake for
        // its own round.
        expect(onGrid.avg(onGrid.wokenBy), 0);
        // presence.zbox: at most every 5 minutes, unless a state changes.
        expect(ownPhases.avg(ownPhases.writes), lessThanOrEqualTo(12));
        expect(onGrid.avg(onGrid.writes), lessThanOrEqualTo(12));
        // Every friend keeps hearing every other one within a round and a
        // moment: "w tle" never runs out, and they stay reachable.
        for (final _Result r in <_Result>[ownPhases, onGrid]) {
          expect(
            r.maxSilence(),
            lessThanOrEqualTo(10 * _min + 200),
            reason: 'a word every round',
          );
        }
      }, timeout: const Timeout(Duration(minutes: 20)));
    }
  });

  test('a lost ping or pong: both sides ping on their next round, nobody '
      'shows "poza siecią"', () async {
    int worst = 0;
    for (int seed = 1; seed <= 6; seed++) {
      // Every frame between phone 0 and phone 1 in the second hour's first
      // round is lost (whichever way it went), and once more 25 min on.
      final _Result r = await _Sim(
        phones: 4,
        oldPhones: const <int>{},
        grid: seed.isEven,
        seed: seed,
        lose: (int from, int to, String type, int at) {
          final bool pair = (from == 0 && to == 1) || (from == 1 && to == 0);
          final int t = at - _start;
          return pair &&
              ((t >= 60 * _min && t < 70 * _min) ||
                  (t >= 95 * _min && t < 105 * _min));
        },
      ).run();
      worst = math.max(worst, r.maxSilence());
    }
    // ignore: avoid_print
    print('one round lost twice: longest silence ${_mmss(worst)}');
    // Two rounds without a word, and the next one heard: "w tle" lasts 25.
    expect(worst, lessThan(kPresenceBackgroundFor.inMilliseconds));
    expect(worst, lessThanOrEqualTo(20 * _min + 200));
  }, timeout: const Timeout(Duration(minutes: 10)));

  test(
    'phones on 1.16.4 and on this version see each other as before',
    () async {
      for (final bool grid in <bool>[false, true]) {
        for (int seed = 1; seed <= 3; seed++) {
          // Phones 0-2 on 1.16.4, 3-6 on this version.
          const Set<int> old = <int>{0, 1, 2};
          final _Result r = await _Sim(
            phones: 7,
            oldPhones: old,
            grid: grid,
            seed: seed,
          ).run();
          final int oldHearsNew = r.maxSilence(
            where: (int h, int f) => old.contains(h) && !old.contains(f),
          );
          final int newHearsOld = r.maxSilence(
            where: (int h, int f) => !old.contains(h) && old.contains(f),
          );
          // ignore: avoid_print
          print(
            'mixed versions grid=$grid seed=$seed: 1.16.4 hears this version '
            'within ${_mmss(oldHearsNew)}, this version hears 1.16.4 within '
            '${_mmss(newHearsOld)}',
          );
          // 1.16.4 pings every round and gets the pong: a word every round,
          // and the other way round, as between two phones on 1.16.4.
          expect(oldHearsNew, lessThanOrEqualTo(10 * _min + 200));
          expect(newHearsOld, lessThanOrEqualTo(10 * _min + 200));
        }
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test('a friend silent for over 30 minutes gets a round\'s ping every third '
      'round', () async {
    // Phone 2 is off all the time. Before: 6 pings an hour to it from each
    // phone. Now: after its first 30 minutes of silence, 2.
    final _Result r = await _Sim(
      phones: 3,
      oldPhones: const <int>{},
      grid: false,
      seed: 5,
      off: const <int>{2},
    ).run(hours: 4);
    final double perHour = (r.pings[(0, 2)] ?? 0) / r.hours;
    // ignore: avoid_print
    print(
      'pings an hour to a friend whose phone is off: 6 -> '
      '${perHour.toStringAsFixed(2)}',
    );
    expect(perHour, closeTo(2, 0.35));
    // The others still ping each other as before.
    expect(
      r.maxSilence(where: (int h, int f) => h < 2 && f < 2),
      lessThanOrEqualTo(10 * _min + 200),
    );
  }, timeout: const Timeout(Duration(minutes: 10)));

  group('the round of one locked phone', () {
    late Directory dir;
    late int clock;
    late _Sends air;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zen-round-');
      clock = _start;
      air = _Sends();
    });

    tearDown(() async {
      await dir.delete(recursive: true);
    });

    LockedReceiver phone(Set<String> friends, {SealedSnapshotWriter? kept}) =>
        LockedReceiver(
          transport: air,
          capability: BackgroundCapability.fromDraft(
            BackgroundCapabilityDraft(
              inboxPublicKey: Uint8List(32),
              friends: friends,
            ),
            backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
          ),
          inbox: SealedInboxWriter(
            file: File('${dir.path}/inbox.zbox'),
            recipientPublicKey: Uint8List(32),
          ),
          notices: MemoryRuntimeSystemNotificationService(),
          presence: LockedPresenceKit(shownTo: friends),
          presenceSnapshot: kept,
          mailboxPollInterval: Duration.zero,
          // Run by hand.
          presenceRoundEvery: kLockedPresenceRoundEvery,
          now: () => clock,
        );

    Future<void> from(
      LockedReceiver r,
      String friend,
      String type, {
      String state = 'background',
    }) => r.handleFrame(
      SignalTransportFrame(
        from: friend,
        payload: <String, dynamic>{'type': type, 'state': state, 'sq': clock},
        receivedAtMillis: clock,
      ),
    );

    test('a wall clock set back does not hold the rounds back', () async {
      final String friend = _address(1);
      final LockedReceiver r = phone(<String>{friend});
      await r.start();
      clock += 10 * _min;
      await r.presenceRoundForTest();
      expect(air.pingsTo(friend), 1);
      // The network's time (or a person) sets the clock back 30 minutes;
      // the beat still comes every 10 (it clamps its due times). Before:
      // 1 round in the next 40 minutes; now each one.
      clock -= 30 * _min;
      for (int i = 0; i < 4; i++) {
        clock += 10 * _min;
        await r.presenceRoundForTest();
      }
      expect(air.pingsTo(friend), 5);
      await r.stop();
    });

    test('a friend whose round reached this phone is not pinged again in the '
        'same period, unless Zen is on their screen', () async {
      final String ada = _address(1);
      final String bob = _address(2);
      final LockedReceiver r = phone(<String>{ada, bob});
      await r.start();
      clock += 10 * _min;
      await r.presenceRoundForTest();
      expect(air.pingsTo(ada), 1);
      expect(air.pingsTo(bob), 1);
      // Ada's own round 4 minutes on: her ping gets the pong, and this
      // phone's next round finds the exchange. Bob's ping comes from Zen on
      // his screen.
      clock += 4 * _min;
      await from(r, ada, 'ping');
      expect(air.pongsTo(ada), 1);
      clock += 3 * _min;
      await from(r, bob, 'ping', state: 'foreground');
      expect(air.pongsTo(bob), 1);
      clock += 3 * _min;
      await r.presenceRoundForTest();
      expect(air.pingsTo(ada), 1, reason: 'told and heard 6 minutes ago');
      expect(air.pingsTo(bob), 2, reason: 'on the screen: every round');
      // Her next round's ping is lost: this phone's round pings her.
      clock += 10 * _min;
      await r.presenceRoundForTest();
      expect(air.pingsTo(ada), 2);
      // A pong that could not go does not count as told.
      clock += 3 * _min;
      air.failing = true;
      await from(r, ada, 'ping');
      air.failing = false;
      clock += 4 * _min;
      await r.presenceRoundForTest();
      expect(air.pingsTo(ada), 3);
      await r.stop();
    });

    test('a friend silent for half an hour is pinged every third round, and '
        'every round again once heard', () async {
      final String ada = _address(1);
      final LockedReceiver r = phone(<String>{ada});
      await r.start();
      final List<int> pingedIn = <int>[];
      for (int round = 1; round <= 12; round++) {
        clock += 10 * _min;
        final int before = air.pingsTo(ada);
        await r.presenceRoundForTest();
        if (air.pingsTo(ada) > before) {
          pingedIn.add(round);
        }
        if (round == 9) {
          // Her phone is back: her ping comes between the rounds.
          clock += 5 * _min;
          await from(r, ada, 'ping');
          clock -= 5 * _min;
        }
      }
      // Rounds 1-3: under 30 minutes of silence; then every third; once
      // heard (minute 95), the next round finds the exchange and the ones
      // after ping her, as any friend.
      expect(pingedIn, <int>[1, 2, 3, 6, 9, 11, 12]);
      await r.stop();
    });

    test('presence.zbox: a change at once, the rest at most every 5 minutes, '
        'and what waits when the receiver stops', () async {
      final Uint8List key = await inboxPublicKeyFor(
        Uint8List.fromList(List<int>.generate(32, (int i) => i + 7)),
      );
      for (final int n in <int>[10, 100]) {
        final File file = File('${dir.path}/presence-$n.zbox');
        final List<String> friends = <String>[
          for (int i = 1; i <= n; i++) _address(i),
        ];
        final LockedReceiver r = phone(
          friends.toSet(),
          kept: SealedSnapshotWriter(file: file, recipientPublicKey: key),
        );
        await r.start();
        final int start = clock;
        int writes = 0;
        int writesSecondHour = 0;
        // Two hours: each friend's round ping every 10 minutes at its own
        // phase, each saying "w tle".
        final List<({int at, String from})> pings = <({int at, String from})>[
          for (int i = 0; i < n; i++)
            for (int k = 0; k < 12; k++)
              (
                at: start + k * 10 * _min + (i * 10 * _min) ~/ n,
                from: friends[i],
              ),
        ]..sort((a, b) => a.at.compareTo(b.at));
        for (final ({int at, String from}) p in pings) {
          clock = p.at;
          if (file.existsSync()) {
            file.deleteSync();
          }
          await from(r, p.from, 'ping');
          await r.presenceKept;
          if (file.existsSync()) {
            writes++;
            if (clock >= start + _hour) {
              writesSecondHour++;
            }
          }
        }
        // ignore: avoid_print
        print(
          'presence.zbox, $n friends locked: $writes writes in two hours, '
          '$writesSecondHour in the second (1.16.4: every round ping, '
          '${6 * n} an hour)',
        );
        expect(writesSecondHour, lessThanOrEqualTo(12));
        // A friend's Zen comes on the screen: written at once.
        clock += _sec;
        file.deleteSync();
        await from(r, friends.first, 'ping', state: 'foreground');
        await r.presenceKept;
        expect(file.existsSync(), isTrue);
        // A refresh that waits: written when the receiver stops.
        clock += 6 * _min;
        await from(r, friends.first, 'ping', state: 'foreground');
        await r.presenceKept;
        clock += 30 * _sec;
        file.deleteSync();
        await from(r, friends.last, 'ping');
        await r.presenceKept;
        expect(file.existsSync(), isFalse, reason: 'written 30 s ago');
        await r.stop();
        expect(file.existsSync(), isTrue);
      }
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}

/// Sends of one phone, counted; [failing]: a send throws.
final class _Sends extends MemorySignalTransport {
  bool failing = false;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) {
    if (failing) {
      throw const SocketException('no route');
    }
    return super.send(remoteAddress: remoteAddress, payload: payload);
  }

  int _count(String to, String type) => sentSignals
      .where((s) => s.remoteAddress == to && s.payload['type'] == type)
      .length;

  int pingsTo(String to) => _count(to, 'ping');

  int pongsTo(String to) => _count(to, 'pong');
}
