import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Who can keep a locked phone awake. Its node hands every signal over
// without holding the phone (YggdrasilSignalTransport.holdOnArrival off on
// a node that only receives); the receiver holds it a moment for a friend's
// or a mailbox's frame, and for anyone else's only while what the frame set
// off runs. Strangers' signals reach it only within the node's hourly
// budget (stranger_signals.go, tested in the bridge).

const int _sec = 1000;
const int _min = 60 * _sec;
const int _hour = 60 * _min;

String _address(int i) => PeerShareCodec.normalizeAddress(
  '200:1111:2222:3333:4444:5555:${(0x3000 + i).toRadixString(16)}:1',
);

final String _friend = _address(1);
final String _member = _address(2);
final String _stranger = _address(3);
final String _formerFriend = _address(4);

/// The phone's holds on a virtual clock: how long it was kept awake.
final class _Holds implements ZenWakePlatform {
  _Holds(this.now);

  final int Function() now;
  final Map<String, int> until = <String, int>{};
  final List<(String, int)> taken = <(String, int)>[];

  /// Awake time from the holds, as intervals [from, to) per tag.
  final List<(String, int, int)> awake = <(String, int, int)>[];

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) => _NoAlarm();

  @override
  Future<void> hold(String tag, Duration duration) async {
    taken.add((tag, now()));
    final int to = math.max(until[tag] ?? 0, now() + duration.inMilliseconds);
    until[tag] = to;
    awake.add((tag, now(), to));
  }

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {
    until[tag] = now() + after.inMilliseconds;
    // A release ends the tag's holds early.
    final int end = now() + after.inMilliseconds;
    for (int i = 0; i < awake.length; i++) {
      final (String, int, int) h = awake[i];
      if (h.$1 == tag && h.$3 > end) {
        awake[i] = (tag, h.$2, math.max(h.$2, end));
      }
    }
  }

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();

  int tagged(String tag) =>
      taken.where(((String, int) t) => t.$1 == tag).length;

  /// Milliseconds awake in total (overlaps counted once).
  int get awakeMs {
    final List<(String, int, int)> sorted = List<(String, int, int)>.of(awake)
      ..sort(
        ((String, int, int) a, (String, int, int) b) => a.$2.compareTo(b.$2),
      );
    int total = 0;
    int end = -1 << 40;
    for (final (String, int, int) i in sorted) {
      final int from = math.max(i.$2, end);
      if (i.$3 > from) {
        total += i.$3 - from;
        end = i.$3;
      }
    }
    return total;
  }
}

final class _NoAlarm implements WakeTimer {
  @override
  bool get isActive => false;

  @override
  void cancel() {}
}

/// A transport that names contacts to the node, as a locked phone's does.
final class _Node extends MemorySignalTransport
    implements SignalSenderAdmission {
  final List<String> admitted = <String>[];

  @override
  void admitSender(String address) => admitted.add(address);
}

void main() {
  late Directory dir;
  late int clock;
  late _Holds holds;
  late _Node node;
  late LockedReceiver receiver;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zen-flood-');
    clock = 1000 * _hour;
    holds = _Holds(() => clock);
    ZenWake.platform = holds;
    ZenWake.nowMillis = () => clock;
    node = _Node();
    receiver = LockedReceiver(
      transport: node,
      capability: BackgroundCapability.fromDraft(
        BackgroundCapabilityDraft(
          inboxPublicKey: Uint8List(32),
          friends: <String>{_friend},
          groupMembers: <String>{_member},
        ),
        backgroundKey: Uint8List.fromList(List<int>.filled(32, 7)),
      ),
      inbox: SealedInboxWriter(
        file: File('${dir.path}/inbox.zbox'),
        recipientPublicKey: await inboxPublicKeyFor(
          Uint8List.fromList(List<int>.generate(32, (int i) => i + 7)),
        ),
      ),
      notices: MemoryRuntimeSystemNotificationService(),
      presence: LockedPresenceKit(shownTo: <String>{_friend}),
      mailboxPollInterval: Duration.zero,
      presenceRoundEvery: Duration.zero,
      now: () => clock,
    );
    await receiver.start();
  });

  tearDown(() async {
    await receiver.stop();
    ZenWake.resetForTest();
    ZenWake.platform = const TimerWakePlatform();
    ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
    await dir.delete(recursive: true);
  });

  Future<void> frame(String from, Map<String, dynamic> payload) =>
      receiver.handleFrame(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: clock,
        ),
      );

  int pongsTo(String to) => node.sentSignals
      .where(
        (({String remoteAddress, Map<String, dynamic> payload}) s) =>
            s.payload['type'] == 'pong' &&
            PeerShareCodec.normalizeAddress(s.remoteAddress) == to,
      )
      .length;

  test('a friend\'s frame holds the phone at once; a stranger\'s, a former '
      'friend\'s and a group member\'s ping does not', () async {
    await frame(_stranger, <String, dynamic>{'type': 'ping'});
    await frame(_formerFriend, <String, dynamic>{'type': 'ping', 'fs': true});
    await frame(_member, <String, dynamic>{'type': 'ping'});
    await frame(_stranger, <String, dynamic>{'type': 'hello'});
    expect(holds.tagged('signal'), 0);
    await frame(_friend, <String, dynamic>{'type': 'ping'});
    expect(holds.tagged('signal'), 1);
    expect(pongsTo(_friend), 1);
    // The node is told who is a contact, once each: the member's signals
    // are then not counted against the strangers' budget.
    expect(node.admitted, <String>[_member, _friend]);
  });

  test('a group member\'s "just started" ping gets no pong every 20 '
      'seconds; a friend\'s does', () async {
    for (int i = 0; i < 30; i++) {
      await frame(_member, <String, dynamic>{
        'type': 'ping',
        kPresenceFreshKey: true,
      });
      await frame(_friend, <String, dynamic>{
        'type': 'ping',
        kPresenceFreshKey: true,
      });
      clock += 20 * _sec;
    }
    // Ten minutes: the member gets a pong as any ping does
    // (kLockedPongEvery), the friend one each time Zen restarts.
    expect(pongsTo(_member), lessThanOrEqualTo(3));
    expect(pongsTo(_friend), 30);
  });

  test('an hour of frames from a stranger and a group member that set '
      'nothing off keeps the phone awake not at all', () async {
    // 1200 frames in an hour: pings marked "just started", answers,
    // statuses, mailbox polls with no mailbox here. Before, each held the
    // phone 3 s as it arrived: awake for the whole hour.
    final List<Map<String, dynamic>> kinds = <Map<String, dynamic>>[
      <String, dynamic>{'type': 'ping', kPresenceFreshKey: true},
      <String, dynamic>{'type': 'pong'},
      <String, dynamic>{'type': 'away'},
      <String, dynamic>{'type': 'rly_poll'},
    ];
    for (int i = 0; i < 1200; i++) {
      final String from = i.isEven ? _stranger : _member;
      await frame(from, kinds[i % kinds.length]);
      clock += 3 * _sec;
    }
    // ignore: avoid_print
    print(
      'an hour of 1200 frames from a stranger and a group member: awake '
      '${holds.awakeMs} ms, signal holds ${holds.tagged('signal')}',
    );
    expect(holds.tagged('signal'), 0);
    expect(holds.awakeMs, 0);
    // A friend's frame still holds the phone at once.
    await frame(_friend, <String, dynamic>{'type': 'pong'});
    expect(holds.tagged('signal'), 1);
  });

  test('a group member sending message after message holds the phone at '
      'most $kLockedWorkHoldsPerHour times an hour; nothing is dropped for '
      'it', () async {
    for (int i = 0; i < 600; i++) {
      await frame(_member, <String, dynamic>{
        'type': 'group_message',
        'text': 'x$i',
        kReliableIdKey: 'r$i',
      });
      clock += 6 * _sec;
    }
    // ignore: avoid_print
    print(
      'an hour of 600 messages from a group member: holds '
      '${holds.tagged('locked-keep')}, awake ${holds.awakeMs ~/ _sec} s, '
      'kept ${receiver.keptCount}',
    );
    expect(holds.tagged('locked-keep'), kLockedWorkHoldsPerHour);
    // Each hold: the work and a second more.
    expect(
      holds.awakeMs,
      lessThanOrEqualTo(kLockedWorkHoldsPerHour * 2 * _sec),
    );
    expect(receiver.keptCount, greaterThan(kLockedWorkHoldsPerHour));
    // A friend's never run out.
    for (int i = 0; i < 100; i++) {
      await frame(_friend, <String, dynamic>{
        'type': 'message',
        'text': 'y$i',
        kReliableIdKey: 'f$i',
      });
    }
    expect(holds.tagged('locked-keep'), kLockedWorkHoldsPerHour + 100);
    // The next hour, the member's work holds the phone again.
    clock += 5 * _min;
    await frame(_member, <String, dynamic>{
      'type': 'group_message',
      'text': 'later',
      kReliableIdKey: 'later',
    });
    expect(holds.tagged('locked-keep'), kLockedWorkHoldsPerHour + 101);
    // 701 messages sealed and written to the disk: a few seconds alone,
    // over the 30 a test has beside the heavy ones on a busy computer.
  }, timeout: const Timeout(Duration(minutes: 5)));
}
