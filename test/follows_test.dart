import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final String ada = PeerShareCodec.normalizeAddress('200::a');
  final String cel = PeerShareCodec.normalizeAddress('200::c');
  final String dan = PeerShareCodec.normalizeAddress('200::d');

  late Map<String, _Linked> nodes;

  Future<LedgerNode> make(
    String address, {
    MemoryLedgerDisk? disk,
    List<String> friends = const <String>[],
  }) async {
    final _Linked t = nodes[address] ??= _Linked(address, nodes);
    await t.start();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: disk ?? MemoryLedgerDisk(),
      friendAddresses: () => friends,
      helloInterval: Duration.zero,
      bridges: BridgeBook(probe: (String _) async => null),
      // Hellos prove the address they come from.
      localAddress: () => address,
    );
    addTearDown(n.stop);
    await n.start();
    return n;
  }

  setUp(() => nodes = <String, _Linked>{});

  test('a follow is a signed entry and the followed person sees it', () async {
    final LedgerNode a = await make(ada);
    final LedgerNode c = await make(cel);
    await publishProfileIfChanged(c, profileBody(name: 'Cela'));
    final FollowLedger onA = FollowLedger.of(a);
    final FollowLedger onC = FollowLedger.of(c);
    await onA.ready;
    await onC.ready;

    await onC.follow(ada);
    await _settle();

    expect(c.isFollowing(ada), isTrue);
    final Map<String, LogEntry> mine = latestFollows(
      c.entriesOf(spaceKind: 'acts'),
    );
    expect(mine[ada]?.body['on'], 1);
    expect(mine[ada]?.body['n'], 'Cela');

    expect(onA.followers.map((Follower f) => f.account), <String>[c.account]);
    expect(onA.followers.single.name, 'Cela');
    expect(onA.followerCount, 1);

    // Stopping is a signed entry too, and the followed side hears it.
    await onC.unfollow(ada);
    await _settle();
    expect(c.isFollowing(ada), isFalse);
    expect(latestFollows(c.entriesOf(spaceKind: 'acts'))[ada]?.body['on'], 0);
    expect(onA.followers, isEmpty);
  });

  test(
    'every friend follows, also one whose account is not known yet',
    () async {
      // Two friends on the list, neither has greeted yet.
      final LedgerNode a = await make(ada, friends: <String>[cel, dan]);
      final FollowLedger onA = FollowLedger.of(a);
      await onA.ready;

      expect(a.friendAccounts, isEmpty);
      expect(onA.followers, isEmpty);
      expect(onA.friendCount, 2);
      expect(onA.followerCount, 2);
    },
  );

  test(
    'a notice signed by someone else or for someone else is ignored',
    () async {
      final LedgerNode a = await make(ada);
      final LedgerNode c = await make(cel);
      final LedgerNode d = await make(dan);
      final FollowLedger onA = FollowLedger.of(a);
      await onA.ready;
      final LogEntry follow = await c.publish(
        kFollowKind,
        followBody(ada),
        spaceKind: 'acts',
      );
      // D passes C's notice off as its own.
      expect(
        await onA.takeNotice(dan, d.account, follow.toCertifiedJson()),
        isFalse,
      );
      // Not a follow at all.
      final LogEntry like = await c.publish(
        kLikeKind,
        likeBody('x'),
        spaceKind: 'acts',
      );
      expect(
        await onA.takeNotice(cel, c.account, like.toCertifiedJson()),
        isFalse,
      );
      // A follow of somebody else's account.
      final LogEntry other = await c.publish(
        kFollowKind,
        followBody(dan, account: d.account),
        spaceKind: 'acts',
      );
      expect(
        await onA.takeNotice(cel, c.account, other.toCertifiedJson()),
        isFalse,
      );
      // Garbage.
      expect(
        await onA.takeNotice(cel, c.account, <String, dynamic>{}),
        isFalse,
      );
      expect(onA.followers, isEmpty);
      // The real thing.
      expect(
        await onA.takeNotice(cel, c.account, follow.toCertifiedJson()),
        isTrue,
      );
      expect(onA.followers.single.account, c.account);
    },
  );

  test('blocking a follower hides them and writes a thread block', () async {
    final MemoryLedgerDisk aDisk = MemoryLedgerDisk();
    final LedgerNode a = await make(ada, disk: aDisk);
    final LedgerNode c = await make(cel);
    final FollowLedger onA = FollowLedger.of(a);
    await onA.ready;
    await FollowLedger.of(c).follow(ada);
    await _settle();
    expect(onA.followers, hasLength(1));

    await onA.block(c.account, name: 'Cela');
    expect(onA.followers, isEmpty);
    expect(onA.isBlocked(c.account), isTrue);
    expect(
      threadModerationOf(a.entriesOf(spaceKind: 'acts')).blocks(c.account),
      isTrue,
    );
    // Their next greeting does not bring them back.
    c.greet(ada);
    await _settle();
    expect(onA.followers, isEmpty);

    await onA.unblock(c.account);
    expect(
      threadModerationOf(a.entriesOf(spaceKind: 'acts')).blocks(c.account),
      isFalse,
    );
    c.greet(ada);
    await _settle();
    expect(onA.followers, hasLength(1));
  });

  test('followers survive a restart', () async {
    final MemoryLedgerDisk aDisk = MemoryLedgerDisk();
    final LedgerNode a = await make(ada, disk: aDisk);
    final LedgerNode c = await make(cel);
    await FollowLedger.of(a).ready;
    await FollowLedger.of(c).follow(ada);
    await _settle();
    await FollowLedger.of(a).dispose();
    await a.stop();
    nodes.remove(ada);

    final LedgerNode again = await make(ada, disk: aDisk);
    final FollowLedger onAgain = FollowLedger.of(again);
    await onAgain.ready;
    expect(onAgain.followers.single.account, c.account);
  });

  test('followers who stop greeting drop off after a while', () async {
    int now = DateTime(2026, 10, 1).millisecondsSinceEpoch;
    final LedgerNode a = await make(ada);
    final LedgerNode c = await make(cel);
    final FollowLedger onA = FollowLedger.of(a, now: () => now);
    await onA.ready;
    await FollowLedger.of(c).follow(ada);
    await _settle();
    expect(onA.followers, hasLength(1));
    now += kFollowerTtl.inMilliseconds + 1;
    expect(onA.followers, isEmpty);
  });
}
