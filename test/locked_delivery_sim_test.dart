import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/relay/locked_outbox.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';

// Phones that are all in the background: each one only runs its locked
// service (the receiver, its mailbox for friends, the outbox the app left),
// and each one wakes on its own beat. The beats are not in step: the phones
// locked at different times, the polls stretch while nothing comes, and
// every alarm comes late by a random share of its wait, up to the 75% an
// inexact alarm may be put off on Android. Between wakes the node stays
// reachable (the foreground service keeps its links up and a packet that
// arrives wakes the phone), except while a phone has no network at all.
//
// Real LockedReceiver, LockedMailbox and LockedOutbox over a SimNetwork on a
// virtual clock; only the platform's alarms are faked.

/// Alarms on the virtual clock, each one put off at random within Android's
/// window for an inexact alarm (up to 75% of its wait).
final class _SimAlarms implements ZenWakePlatform {
  _SimAlarms(this._random, this._now);

  final Random _random;
  final int Function() _now;
  final List<_SimAlarm> _alarms = <_SimAlarm>[];

  /// When the next alarm rings (`null`: none set).
  int? get nextAt {
    int? at;
    for (final _SimAlarm a in _alarms) {
      if (a.isActive && (at == null || a.at < at)) {
        at = a.at;
      }
    }
    return at;
  }

  /// Rings every alarm due by now, earliest first, and waits for its work.
  Future<void> ringDue() async {
    while (true) {
      _alarms.removeWhere((_SimAlarm a) => !a.isActive);
      _alarms.sort((_SimAlarm a, _SimAlarm b) => a.at.compareTo(b.at));
      if (_alarms.isEmpty || _alarms.first.at > _now()) {
        return;
      }
      final _SimAlarm alarm = _alarms.removeAt(0)..fired = true;
      await alarm.fire();
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
    final int wait = max(0, delay.inMilliseconds);
    final int late = exact ? 0 : _random.nextInt(wait * 3 ~/ 4 + 1);
    final _SimAlarm alarm = _SimAlarm(_now() + wait + late, fire);
    _alarms.add(alarm);
    return alarm;
  }

  @override
  Future<void> hold(String tag, Duration duration) async {}

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {}

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();
}

final class _SimAlarm implements WakeTimer {
  _SimAlarm(this.at, this.fire);

  final int at;
  final FutureOr<void> Function() fire;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() => cancelled = true;
}

/// What a phone's node sends: nothing leaves a phone without network.
final class _SimLink implements SignalTransport {
  _SimLink(this.sim, this.onSend);

  final SimPhone sim;
  final void Function(String to, Map<String, dynamic> payload) onSend;

  @override
  Stream<SignalTransportFrame> get frames =>
      const Stream<SignalTransportFrame>.empty();

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    if (!sim.online) {
      return;
    }
    onSend(remoteAddress, payload);
    await sim.send(remoteAddress, payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

/// A mailbox envelope as it travels (sealed contents made up).
Map<String, dynamic> _envelope(
  String id, {
  required String from,
  required String to,
  required int now,
}) => <String, dynamic>{
  'id': id,
  's': from,
  'r': to,
  'c': now,
  'x': now + const Duration(days: 7).inMilliseconds,
  'q': base64Url.encode(List<int>.filled(kHybridCiphertextBytes, 1)),
  'n': base64Url.encode(List<int>.filled(12, 1)),
  'b': base64Url.encode(List<int>.filled(40, 1)),
};

/// One device of the world: Android phones run the whole locked service on
/// a beat of their own; an iPhone in the background runs nothing (iOS
/// suspends it) and only asks its mailboxes for mail when it is opened.
final class _Device {
  _Device(this.name, this.sim, {required this.iphone});

  final String name;
  final SimPhone sim;
  final bool iphone;
  final WakeBeat beat = WakeBeat();
  late final Uint8List masterKey;
  late final File inboxFile;
  late final LockedReceiver receiver;
  late final LockedMailbox mailbox;
  LockedOutbox? outbox;

  /// Whom this device's own mail waits at (its six close friends).
  List<String> mailboxes = const <String>[];

  String get address => sim.address;
}

/// Phones that are all in the background, on a [SimNetwork].
final class _BackgroundWorld {
  _BackgroundWorld(int seed)
    : random = Random(seed),
      net = SimNetwork(seed: seed, holdForOffline: false);

  final Random random;
  final SimNetwork net;
  late final _SimAlarms alarms = _SimAlarms(random, () => net.now);
  final Map<String, _Device> byName = <String, _Device>{};
  final Map<String, _Device> byAddress = <String, _Device>{};
  late final Directory folder;

  /// Message id -> when its recipient had it on the disk (it confirms with
  /// `rly_mail_ack` only then).
  final Map<String, int> keptAt = <String, int>{};

  /// Message id -> when it was queued.
  final Map<String, int> queuedAt = <String, int>{};

  /// Things that happen at a time (network lost or back, an iPhone opened).
  final List<({int at, Future<void> Function() run})> _events =
      <({int at, Future<void> Function() run})>[];

  int get now => net.now;

  _Device operator [](String name) => byName[name]!;

  Future<void> setUp(Map<String, bool> devices) async {
    folder = await Directory.systemTemp.createTemp('zen-sim-');
    addTearDown(() async {
      try {
        await folder.delete(recursive: true);
      } on FileSystemException {
        // Still open on Windows: left to the system's temp cleaning.
      }
    });
    devices.forEach((String name, bool iphone) {
      final _Device d = _Device(name, net.phone(name), iphone: iphone);
      byName[name] = d;
      byAddress[d.address] = d;
    });
    int seed = 11;
    for (final _Device d in byName.values) {
      d.masterKey = Uint8List.fromList(
        List<int>.generate(32, (int i) => (i * 7 + seed) & 0xff),
      );
      seed += 1;
      d.inboxFile = File('${folder.path}/${d.name}.zbox');
    }
  }

  /// [mailboxesOf] says whose mail waits where (mailboxes are phones only).
  void chooseMailboxes(Map<String, List<String>> mailboxesOf) {
    for (final _Device d in byName.values) {
      d.mailboxes = <String>[
        for (final String m in mailboxesOf[d.name] ?? const <String>[])
          this[m].address,
      ];
    }
  }

  /// Everyone is friends with everyone. Each phone locks at [lockedAt] (from
  /// now; its app wrote what it queued for the service then), an iPhone
  /// goes to the background.
  Future<void> lockAll(Map<String, Duration> lockedAt) async {
    for (final _Device d in byName.values) {
      final Set<String> friends = <String>{
        for (final _Device o in byName.values)
          if (o != d) o.address,
      };
      final BackgroundCapability capability = BackgroundCapability.fromDraft(
        BackgroundCapabilityDraft(
          inboxPublicKey: await inboxPublicKeyFor(d.masterKey),
          friends: friends,
          mailboxes: d.mailboxes,
        ),
        backgroundKey: Uint8List.fromList(
          List<int>.generate(32, (int i) => i ^ d.name.codeUnitAt(0)),
        ),
      );
      final _SimLink link = _SimLink(d.sim, (
        String to,
        Map<String, dynamic> p,
      ) {
        if (p['type'] == 'rly_mail_ack') {
          for (final Object? id in p['ids'] as List<Object?>) {
            keptAt.putIfAbsent(id! as String, () => net.now);
          }
        }
      });
      d.mailbox = LockedMailbox(
        transport: link,
        kit: LockedMailboxKit(
          self: d.address,
          served: <String, LockedMailboxPeer>{
            for (final _Device o in byName.values)
              if (o.mailboxes.contains(d.address))
                o.address: LockedMailboxPeer(relays: o.mailboxes),
          },
        ),
        isFriend: friends.contains,
        isContact: friends.contains,
        save: (LockedMailboxKit kit) async {},
        now: () => net.now,
      );
      d.receiver = LockedReceiver(
        transport: link,
        capability: capability,
        inbox: SealedInboxWriter(
          file: d.inboxFile,
          recipientPublicKey: capability.inboxPublicKey,
        ),
        notices: MemoryRuntimeSystemNotificationService(),
        mailbox: d.iphone ? null : d.mailbox,
        now: () => net.now,
        pollAnswerGrace: Duration.zero,
        // A suspended iPhone has no beat: it asks when it is opened.
        mailboxPollInterval: d.iphone
            ? Duration.zero
            : kLockedMailboxPollInterval,
        beat: d.beat,
      );
      d.sim.attach((SignalTransportFrame frame) async {
        await d.receiver.handleFrame(frame);
        d.outbox?.handleFrame(frame);
        return true;
      });
      if (d.iphone) {
        d.sim.online = false;
      }
    }
    // Before it locks the app receives as well: the receiver stands in for
    // it from the start; the outbox the app leaves starts at the lock.
    for (final _Device d in byName.values) {
      await d.receiver.start();
    }
    for (final _Device d in byName.values) {
      final Duration at = lockedAt[d.name] ?? Duration.zero;
      if (at == Duration.zero) {
        await _lock(d);
      } else {
        at_(at, () => _lock(d));
      }
    }
  }

  /// [from]'s app queued [count] messages to [to] before it locked.
  final Map<String, List<LockedOutboxItem>> _queued =
      <String, List<LockedOutboxItem>>{};

  void queue(String from, String to, int count) {
    final _Device s = this[from];
    final _Device r = this[to];
    for (int i = 0; i < count; i++) {
      final String id = '$from>$to#$i';
      queuedAt[id] = net.now;
      (_queued[from] ??= <LockedOutboxItem>[]).add(
        LockedOutboxItem(
          id: id,
          recipient: r.address,
          envelope: _envelope(id, from: s.address, to: r.address, now: now),
          expiresAtMillis: now + const Duration(days: 7).inMilliseconds,
          // The recipient's mailboxes, but not the sender itself.
          mailboxes: <String>[
            for (final String m in r.mailboxes)
              if (m != s.address) m,
          ],
        ),
      );
    }
  }

  Future<void> _lock(_Device d) async {
    if (d.iphone) {
      return;
    }
    final List<LockedOutboxItem> items =
        _queued[d.name] ?? const <LockedOutboxItem>[];
    if (items.isNotEmpty) {
      d.outbox = LockedOutbox(
        transport: _SimLink(d.sim, (_, _) {}),
        kit: LockedOutboxKit(items: items, writtenAtMillis: now),
        now: () => net.now,
        beat: d.beat,
      );
    }
    await d.outbox?.start();
  }

  /// Runs [run] [after] from the start.
  void at_(Duration after, Future<void> Function() run) =>
      _events.add((at: net.now + after.inMilliseconds, run: run));

  /// [name] has no network from [from] for [lasting].
  void offline(String name, Duration from, Duration lasting) {
    final SimPhone sim = this[name].sim;
    at_(from, () async => net.setOnline(sim, false));
    at_(from + lasting, () async => net.setOnline(sim, true));
  }

  /// The iPhone [name] is opened at [at] for [lasting]: it asks its
  /// mailboxes for mail as it comes up.
  void open(String name, Duration at, Duration lasting) {
    final _Device d = this[name];
    at_(at, () async {
      net.setOnline(d.sim, true);
      await d.receiver.pollMailboxes();
    });
    at_(at + lasting, () async => net.setOnline(d.sim, false));
  }

  /// Lets everything in flight land and every handler finish (inbox writes
  /// are real files).
  Future<void> settle() async {
    for (int round = 0; round < 500; round++) {
      final int before = net.stats.sent;
      await net.run();
      await pumpEventQueue();
      if (net.stats.sent == before) {
        return;
      }
    }
    fail('the simulated network did not settle');
  }

  /// Moves the clock on to [end]: every alarm and event on its time.
  Future<void> runFor(Duration duration) async {
    final int end = net.now + duration.inMilliseconds;
    while (true) {
      await settle();
      int next = end;
      final int? alarm = alarms.nextAt;
      if (alarm != null && alarm < next) {
        next = alarm;
      }
      for (final ({int at, Future<void> Function() run}) e in _events) {
        if (e.at < next) {
          next = e.at;
        }
      }
      if (next > net.now) {
        await net.run(forAtMost: Duration(milliseconds: next - net.now));
      }
      final List<({int at, Future<void> Function() run})> due =
          <({int at, Future<void> Function() run})>[
            for (final ({int at, Future<void> Function() run}) e in _events)
              if (e.at <= net.now) e,
          ];
      _events.removeWhere(due.contains);
      for (final ({int at, Future<void> Function() run}) e in due) {
        await e.run();
        await settle();
      }
      await alarms.ringDue();
      if (net.now >= end && due.isEmpty) {
        await settle();
        return;
      }
    }
  }

  /// How many times each message is in [d]'s sealed inbox.
  Future<Map<String, int>> keptBy(_Device d) async {
    final Map<String, int> count = <String, int>{};
    final List<Uint8List> records = await readSealedInbox(
      d.inboxFile,
      await inboxKeyPairFor(d.masterKey),
    );
    for (final Uint8List record in records) {
      final SignalTransportFrame? frame = decodeInboxFrame(record);
      if (frame == null || frame.payload['type'] != 'rly_mail') {
        continue;
      }
      for (final Object? item in frame.payload['items'] as List<Object?>) {
        final String id = (item! as Map<Object?, Object?>)['id']! as String;
        count[id] = (count[id] ?? 0) + 1;
      }
    }
    return count;
  }

  Future<void> stop() async {
    for (final _Device d in byName.values) {
      await d.outbox?.stop();
      await d.receiver.stop();
    }
  }
}

/// Starts the shared wake on the world's clock and alarms.
void _useWorldWake(_BackgroundWorld w) {
  ZenWake.platform = w.alarms;
  ZenWake.nowMillis = () => w.net.now;
  addTearDown(() {
    ZenWake.resetForTest();
    ZenWake.platform = const TimerWakePlatform();
    ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
  });
}

/// Network outages of [name] over the first [span]: online and offline in
/// turns of random length, as a phone that goes underground, into a lift
/// or out of range does.
void _randomOutages(_BackgroundWorld w, String name, Duration span) {
  int at = w.random.nextInt(const Duration(minutes: 30).inMilliseconds);
  while (at < span.inMilliseconds) {
    final int off =
        const Duration(minutes: 5).inMilliseconds +
        w.random.nextInt(const Duration(minutes: 70).inMilliseconds);
    final int lasting = min(off, span.inMilliseconds - at);
    w.offline(
      name,
      Duration(milliseconds: at),
      Duration(milliseconds: lasting),
    );
    at +=
        lasting +
        const Duration(minutes: 10).inMilliseconds +
        w.random.nextInt(const Duration(minutes: 80).inMilliseconds);
  }
}

const List<String> _phones = <String>['A', 'B', 'C'];

/// Each phone's mail waits at the two others: mailboxes only on phones.
const Map<String, List<String>> _eachAtTheOthers = <String, List<String>>{
  'A': <String>['B', 'C'],
  'B': <String>['A', 'C'],
  'C': <String>['A', 'B'],
};

/// The messages meant for [name].
Set<String> _meantFor(_BackgroundWorld w, String name) => <String>{
  for (final String id in w.queuedAt.keys)
    if (id.contains('>$name#')) id,
};

/// Every message is in its recipient's sealed inbox exactly once, and no
/// mailbox still holds a copy of one.
Future<void> _expectEachKeptOnce(_BackgroundWorld w) async {
  for (final _Device d in w.byName.values) {
    final Map<String, int> kept = await w.keptBy(d);
    expect(kept.keys.toSet(), _meantFor(w, d.name), reason: d.name);
    kept.forEach((String id, int times) {
      expect(times, 1, reason: '$id kept $times times');
    });
    if (!d.iphone) {
      expect(d.mailbox.heldCount, 0, reason: '${d.name} still holds copies');
    }
  }
}

void main() {
  test(
    'beats out of step do not hold messages up: with the network up, each '
    'one reaches its locked recipient on its sender\'s first round',
    () async {
      final _BackgroundWorld w = _BackgroundWorld(7);
      _useWorldWake(w);
      await w.setUp(<String, bool>{for (final String p in _phones) p: false});
      w.chooseMailboxes(_eachAtTheOthers);
      for (final String from in _phones) {
        for (final String to in _phones) {
          if (from != to) {
            w.queue(from, to, 3);
          }
        }
      }
      const Map<String, Duration> lockedAt = <String, Duration>{
        'A': Duration.zero,
        'B': Duration(minutes: 3, seconds: 17),
        'C': Duration(minutes: 11, seconds: 41),
      };
      final int start = w.now;
      await w.lockAll(lockedAt);
      await w.runFor(const Duration(hours: 2));

      // The first round comes 20 s after the lock, 35 s at worst (an inexact
      // alarm put off by 75%), whatever the recipient's beat is doing.
      for (final String id in w.queuedAt.keys) {
        final String from = id.substring(0, 1);
        final int lock = start + lockedAt[from]!.inMilliseconds;
        final int? at = w.keptAt[id];
        expect(at, isNotNull, reason: '$id never arrived');
        expect(
          at! - lock,
          lessThanOrEqualTo(const Duration(seconds: 36).inMilliseconds),
          reason: '$id took ${at - lock} ms after its sender locked',
        );
      }
      await _expectEachKeptOnce(w);
      for (final String p in _phones) {
        expect(w[p].outbox!.pendingCount, 0, reason: '$p heard every ack');
      }
      await w.stop();
    },
  );

  // The longest a message waits once the phones are back on the network for
  // good: the sender's longest wait between rounds (an hour) put off by an
  // inexact alarm (75%). It also covers the recipient's longest wait between
  // polls of its mailboxes (30 minutes, 52.5 at worst).
  const Duration bound = Duration(minutes: 105);
  const Duration outages = Duration(hours: 6);

  for (final int seed in <int>[1, 2, 3, 4, 5, 6, 7, 8]) {
    test('three phones in the background, beats out of step, each with '
        'outages of its own for ${outages.inHours} hours: every message '
        'arrives exactly once, at most ${bound.inMinutes} minutes after the '
        'network is back (seed $seed)', () async {
      final _BackgroundWorld w = _BackgroundWorld(seed);
      _useWorldWake(w);
      await w.setUp(<String, bool>{for (final String p in _phones) p: false});
      w.chooseMailboxes(_eachAtTheOthers);
      for (final String from in _phones) {
        for (final String to in _phones) {
          if (from != to) {
            w.queue(from, to, 3);
          }
        }
      }
      for (final String p in _phones) {
        _randomOutages(w, p, outages);
      }
      final int start = w.now;
      await w.lockAll(<String, Duration>{
        'A': Duration.zero,
        'B': Duration(seconds: 97 + w.random.nextInt(600)),
        'C': Duration(seconds: 211 + w.random.nextInt(600)),
      });
      await w.runFor(outages + bound);

      final int back = start + outages.inMilliseconds;
      int latest = 0;
      int afterBack = 0;
      for (final String id in w.queuedAt.keys) {
        final int? at = w.keptAt[id];
        expect(at, isNotNull, reason: '$id never arrived');
        latest = max(latest, at! - start);
        if (at > back) {
          afterBack += 1;
        }
      }
      await _expectEachKeptOnce(w);
      debugPrint(
        'seed $seed: ${w.queuedAt.length} messages, the last one '
        '${Duration(milliseconds: latest).inMinutes} min after the start, '
        '$afterBack after the outages ended',
      );
      await w.stop();
    });
  }

  // A recipient back on the network gets what waits at its mailboxes at its
  // next poll: at most the longest wait between polls (30 minutes) put off
  // by an inexact alarm (75%).
  const Duration pollBound = Duration(minutes: 52, seconds: 30);

  for (final int seed in <int>[11, 12, 13, 14, 15]) {
    test('a locked phone three hours without network, its senders and '
        'mailboxes locked too: everything waits at the mailboxes and arrives '
        'once, at most ${pollBound.inMinutes} minutes after it is back (seed '
        '$seed)', () async {
      final _BackgroundWorld w = _BackgroundWorld(seed);
      _useWorldWake(w);
      await w.setUp(<String, bool>{for (final String p in _phones) p: false});
      w.chooseMailboxes(_eachAtTheOthers);
      w.queue('A', 'B', 3);
      w.queue('C', 'B', 3);
      const Duration away = Duration(hours: 3);
      w.offline('B', Duration.zero, away);
      // Without network before anyone locks (its first poll would be a
      // sign of life that sends the mail at once).
      await w.runFor(Duration.zero);
      final int start = w.now;
      await w.lockAll(<String, Duration>{
        'B': Duration(seconds: 30 + w.random.nextInt(600)),
        'C': Duration(seconds: 60 + w.random.nextInt(600)),
      });
      await w.runFor(away + pollBound + const Duration(minutes: 1));

      final int back = start + away.inMilliseconds;
      int latest = 0;
      for (final String id in _meantFor(w, 'B')) {
        final int? at = w.keptAt[id];
        expect(at, isNotNull, reason: '$id never arrived');
        expect(at, greaterThan(back), reason: '$id reached B without network');
        latest = max(latest, at! - back);
      }
      expect(latest, lessThanOrEqualTo(pollBound.inMilliseconds));
      await _expectEachKeptOnce(w);
      debugPrint(
        'seed $seed: B had everything '
        '${Duration(milliseconds: latest).inMinutes} min after it was back',
      );
      await w.stop();
    });
  }

  test('an iPhone in the background gets nothing until it is opened; then '
      'its mailboxes on the phones hand everything over, once', () async {
    final _BackgroundWorld w = _BackgroundWorld(3);
    _useWorldWake(w);
    await w.setUp(<String, bool>{
      for (final String p in _phones) p: false,
      'D': true,
    });
    w.chooseMailboxes(<String, List<String>>{
      ..._eachAtTheOthers,
      'D': <String>['A', 'C'],
    });
    w.queue('A', 'D', 3);
    w.queue('B', 'D', 3);
    w.open('D', const Duration(hours: 5), const Duration(minutes: 1));
    await w.lockAll(<String, Duration>{
      'B': const Duration(minutes: 4),
      'C': const Duration(minutes: 9),
    });
    await w.runFor(const Duration(hours: 4, minutes: 59));
    expect(w.keptAt, isEmpty, reason: 'nothing reaches a suspended iPhone');

    final int opened = w.now + const Duration(minutes: 1).inMilliseconds;
    await w.runFor(const Duration(hours: 1));
    for (final String id in _meantFor(w, 'D')) {
      final int? at = w.keptAt[id];
      expect(at, isNotNull, reason: '$id never arrived');
      expect(
        at! - opened,
        lessThan(const Duration(seconds: 5).inMilliseconds),
        reason: '$id came ${at - opened} ms after the iPhone was opened',
      );
    }
    await _expectEachKeptOnce(w);
    await w.stop();
  });
}
