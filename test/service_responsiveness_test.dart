import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import 'support/friends_world.dart';

// A phone whose Zen is locked or closed, with its background service on (the
// real LockedReceiver on the simulated network, the real relay engines,
// social controllers and reliable transports on the other phones): it must
// answer whatever its friends send, as fast as the network allows. A ping
// gets a pong ("w tle"), a message, a group message, a reaction, a friend's
// invitation are kept and confirmed at once (the sender's "Czeka u
// Ciebie" turns into delivered), a call rings, nothing is kept twice, and
// after the unlock the app shows each of them once. Also with datagrams
// lost and repeated, several senders at once, the phone off the network
// for a while, and locked for hours.

/// Every message [from] sent is past "Czeka u Ciebie": taken by the
/// recipient's phone (its service), as the sender's relay layer sees.
bool _allTaken(FriendsPhone from) {
  final Iterable<MessageDeliveryProgress> all =
      from.engine.progress.value.messages.values;
  return all.isNotEmpty &&
      all.every(
        (MessageDeliveryProgress p) => p.delivered > 0 || p.pending == 0,
      );
}

/// Waits (virtual time) until [done], failing after [within].
Future<Duration> _within(
  FriendsWorld w,
  bool Function() done,
  Duration within,
  String what,
) async {
  final int start = w.now;
  while (!done()) {
    if (w.now - start > within.inMilliseconds) {
      fail('$what: not within $within');
    }
    await w.advance(const Duration(seconds: 1));
  }
  return Duration(milliseconds: w.now - start);
}

void main() {
  test('a ping gets a pong at once that says "w tle": the friend shows the '
      'locked phone as receiving in the background', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.lock(w['B']);
    await w.ping(w['A'], w['B']);
    expect(
      w['A'].state.friendByAddress(w['B'].address)!.presence,
      PeerPresence.background,
    );
  });

  test('pings from many friends, again and again: each friend is answered, '
      'at most every few minutes each, never left without an answer for '
      'longer', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>[
      'B',
      'F1',
      'F2',
      'F3',
    ]);
    await w.lock(w['B']);
    final Map<String, int> lastAnswer = <String, int>{};
    for (int round = 0; round < 10; round++) {
      for (final String f in <String>['F1', 'F2', 'F3']) {
        final int before = w.net.stats.byType['pong'] ?? 0;
        await w.ping(w[f], w['B']);
        if ((w.net.stats.byType['pong'] ?? 0) > before) {
          lastAnswer[f] = w.now;
        }
        expect(
          w.now - (lastAnswer[f] ?? 0),
          lessThan(const Duration(minutes: 5).inMilliseconds),
          reason: '$f waited too long for a pong',
        );
        expect(
          w[f].state.friendByAddress(w['B'].address)!.presence,
          PeerPresence.background,
        );
      }
      // The app pings every 2 minutes while on the screen.
      await w.advance(const Duration(minutes: 2));
    }
  });

  test('a message is kept and confirmed at once, rings, and is in the chat '
      'once after the unlock', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.lock(w['B']);
    await w.send(w['A'], w['B'], 'jesteś?');
    final Duration took = await _within(
      w,
      () => _allTaken(w['A']),
      const Duration(seconds: 5),
      'the message confirmed',
    );
    expect(took, lessThan(const Duration(seconds: 5)));
    expect((await w['A'].relayStore.load()).outbox, isEmpty);
    expect(w['B'].messageNotices, hasLength(1));
    await w.unlock(w['B']);
    expect(await w['B'].textsFrom(w['A']), <String>['jesteś?']);
  });

  test('a group message, a reaction and a second message all reach the '
      'locked phone and are confirmed', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final String group = await w.createGroup(w['A'], 'Paczka', <FriendsPhone>[
      w['B'],
      w['C'],
    ]);
    await w.send(w['A'], w['B'], 'pierwsza');
    await w.settle();
    await w.lock(w['B']);
    await w.sendGroup(w['C'], group, 'do wszystkich');
    final String firstId = (await w['A'].thread(w['B'])).first.id;
    await w['A'].hub.reactToMessage(
      conversationKey: w['B'].address,
      messageId: firstId,
      emoji: '❤️',
    );
    await w.send(w['A'], w['B'], 'druga');
    await _within(
      w,
      () => _allTaken(w['A']) && _allTaken(w['C']),
      const Duration(seconds: 10),
      'everything confirmed',
    );
    await w.unlock(w['B']);
    expect(await w['B'].textsFrom(w['A']), <String>['pierwsza', 'druga']);
    expect(await w.groupTexts(w['B'], group), <String>['do wszystkich']);
  });

  test('a call to the locked phone rings it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.lock(w['B']);
    // The invitation as the caller's app sends it (no camera or
    // microphone in the simulation).
    await w['A'].container
        .read(signalTransportProvider)
        .send(
          remoteAddress: w['B'].address,
          payload: <String, dynamic>{
            'type': 'call_invite',
            'callId': 'call-1-${w['A'].address}',
            'kind': CallInviteKind.audio.name,
          },
        );
    await w.advance(const Duration(seconds: 3));
    expect(
      w['B'].notices.shade.activeNotifications.where((n) => n.isRingingCall),
      isNotEmpty,
      reason: 'the service rang the call',
    );
  });

  test('a friend\'s invitation from someone new is kept and confirmed, and '
      'waits in the app after the unlock', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>[
      'A',
      'B',
    ], allFriends: false);
    await w.lock(w['B']);
    await w['A'].hub.sendFriendRequest(
      peerAddress: w['B'].address,
      knownName: 'B',
      senderDisplayName: 'A',
    );
    await w.advance(const Duration(seconds: 5));
    expect((await w['A'].relayStore.load()).outbox, isEmpty, reason: 'acked');
    await w.unlock(w['B']);
    expect(
      w['B'].state.friendByAddress(w['A'].address)?.status,
      FriendRelationshipStatus.pendingIncoming,
    );
  });

  for (final double loss in <double>[0.05, 0.15]) {
    test('${(loss * 100).round()}% of datagrams lost and some repeated, five '
        'senders writing at once: every message is confirmed within a '
        'minute and kept exactly once', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'B',
        'S1',
        'S2',
        'S3',
        'S4',
        'S5',
      ], seed: 4);
      await w.lock(w['B']);
      w.dropRate = loss;
      w.net.duplicateRate = 0.1;
      final List<String> senders = <String>['S1', 'S2', 'S3', 'S4', 'S5'];
      for (int i = 0; i < 3; i++) {
        for (final String s in senders) {
          await w.send(w[s], w['B'], '$s:$i');
        }
      }
      await _within(
        w,
        () => senders.every((String s) => _allTaken(w[s])),
        const Duration(minutes: 1),
        'all confirmed',
      );
      w.dropRate = 0;
      await w.unlock(w['B']);
      for (final String s in senders) {
        expect(await w['B'].textsFrom(w[s]), <String>['$s:0', '$s:1', '$s:2']);
      }
    });
  }

  test('locked for six hours with friends writing now and then: each '
      'message confirmed within seconds, all there after the unlock', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    await w.lock(w['B']);
    final List<String> fromA = <String>[];
    final List<String> fromC = <String>[];
    for (int hour = 0; hour < 6; hour++) {
      await w.advance(const Duration(minutes: 59));
      await w.send(w['A'], w['B'], 'A$hour');
      fromA.add('A$hour');
      await w.send(w['C'], w['B'], 'C$hour');
      fromC.add('C$hour');
      await _within(
        w,
        () => _allTaken(w['A']) && _allTaken(w['C']),
        const Duration(seconds: 10),
        'hour $hour confirmed',
      );
    }
    await w.unlock(w['B']);
    expect(await w['B'].textsFrom(w['A']), fromA);
    expect(await w['B'].textsFrom(w['C']), fromC);
  });

  test('off the network now and then while locked: whatever was sent '
      'meanwhile is confirmed within 2 minutes of each return', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.lock(w['B']);
    for (final int minutes in <int>[3, 12, 40]) {
      await w.setOnline(w['B'], false);
      await w.send(w['A'], w['B'], 'po $minutes min');
      await w.advance(Duration(minutes: minutes));
      await w.setOnline(w['B'], true);
      await _within(
        w,
        () => _allTaken(w['A']),
        const Duration(minutes: 2, seconds: 30),
        'confirmed after $minutes min away',
      );
    }
    await w.unlock(w['B']);
    expect(await w['B'].textsFrom(w['A']), <String>[
      'po 3 min',
      'po 12 min',
      'po 40 min',
    ]);
  });
}
