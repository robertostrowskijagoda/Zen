import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/feed/feed_memo.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_notifier.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// Someone blocked in the messenger stays out of the wall: their likes and
// comments under the posts of friends they share, the totals, and the
// notifications about reactions to one's own posts.

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
  final String ania = PeerShareCodec.normalizeAddress('200::a');
  final String bob = PeerShareCodec.normalizeAddress('200::b');
  final String eve = PeerShareCodec.normalizeAddress('200::e');
  late Map<String, _Linked> nodes;

  Future<LedgerNode> make(String address, List<String> friends) async {
    final _Linked t = nodes[address] = _Linked(address, nodes);
    await t.start();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => friends,
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(n.stop);
    await n.start();
    return n;
  }

  String names(String x) => x == ania
      ? 'Ania'
      : x == bob
      ? 'Bob'
      : x == eve
      ? 'Ewa'
      : x;

  setUp(() => nodes = <String, _Linked>{});

  /// Ania and Ewa were friends; Ania blocked Ewa, who stays a friend of
  /// Bob's. Ania's blocked accounts, as the app works them out.
  Future<(LedgerNode, LedgerNode, LedgerNode, Set<String>)> world() async {
    final List<String> aniasFriends = <String>[bob, eve];
    final LedgerNode a = await make(ania, aniasFriends);
    final LedgerNode b = await make(bob, <String>[ania, eve]);
    final LedgerNode e = await make(eve, <String>[bob, ania]);
    await _settle();
    expect(a.accountOf(eve), e.account);
    aniasFriends.remove(eve);
    await a.onFriendsChanged();
    expect(a.friendAccounts.values, isNot(contains(e.account)));
    expect(a.formerAccountOf(eve), e.account);
    final SocialHubState social = SocialHubState.empty().copyWith(
      book: FriendshipBook.restore(
        profiles: <String, FriendProfile>{
          bob: FriendProfile(
            address: bob,
            displayName: 'Bob',
            status: FriendRelationshipStatus.accepted,
          ),
          eve: FriendProfile(
            address: eve,
            displayName: 'Ewa',
            status: FriendRelationshipStatus.blocked,
          ),
        },
      ),
    );
    final Set<String> blocked = blockedAccountsOf(a, social);
    expect(blocked, <String>{e.account});
    return (a, b, e, blocked);
  }

  test('the blocked person\'s likes and comments under a shared friend\'s '
      'post are left out, also from the totals', () async {
    final (LedgerNode a, LedgerNode b, LedgerNode e, Set<String> blocked) =
        await world();
    final LogEntry post = await b.publish(kPostKind, newPostBody('Hej'));
    await _settle();
    await e.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await e.publish(
      kCommentKind,
      commentBody(post.id, 'Ania, znowu Ty?'),
      spaceKind: 'acts',
    );
    await a.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await a.publish(
      kCommentKind,
      commentBody(post.id, 'Hej!'),
      spaceKind: 'acts',
    );
    await _settle();
    expect(await relayReactions(b, nameOf: names), 1);
    await _settle();

    FeedPost on(Set<String> blockedAccounts) => buildFeed(
      a,
      nameOf: names,
      blockedAccounts: blockedAccounts,
    ).firstWhere((FeedPost p) => p.id == post.id);

    // Without the block Ewa shows, passed on by Bob.
    final FeedPost open = on(const <String>{});
    expect(open.likers, contains('Ewa (przez Bob)'));
    expect(
      open.comments.map((FeedComment c) => c.authorLabel),
      contains('Ewa (przez Bob)'),
    );

    final FeedPost shown = on(blocked);
    expect(shown.likers, <String>['Ty']);
    expect(shown.likeTotal, 1);
    expect(
      <String>[
        for (final FeedComment c in shown.comments)
          '${c.authorLabel}: ${c.text}',
      ],
      <String>['Ty: Hej!'],
    );
    expect(shown.commentTotal, 1);
    expect(likeSummary(shown), 'Lubią to: Ty');

    // The wall as the feed screen builds it.
    final List<FeedPost> wall = FeedMemo().wallOf(
      a,
      revision: 1,
      nameOf: names,
      blockedAccounts: blocked,
    );
    final FeedPost onWall = wall.firstWhere((FeedPost p) => p.id == post.id);
    expect(
      onWall.likes.map((FeedLiker l) => l.account),
      isNot(contains(e.account)),
    );
    expect(
      onWall.comments.map((FeedComment c) => c.account),
      isNot(contains(e.account)),
    );
  });

  test('reactions of the blocked person to one\'s own post are not '
      'announced', () async {
    final (LedgerNode a, LedgerNode b, LedgerNode e, Set<String> blocked) =
        await world();
    final List<RuntimeSystemNotification> posted =
        <RuntimeSystemNotification>[];
    ReactionSystemNotifier notifier({Set<String> blocks = const <String>{}}) {
      final ReactionSystemNotifier n = ReactionSystemNotifier(
        node: a,
        nameOf: names,
        notify: (RuntimeSystemNotification n) async => posted.add(n),
        shouldNotify: () => true,
        blockedAccounts: () => blocks,
        now: () => 42,
      );
      addTearDown(n.dispose);
      return n;
    }

    final ReactionSystemNotifier blocking = notifier(blocks: blocked);
    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle();
    expect(await blocking.check(), 0);
    // Bob passes the post on; Ewa reacts to it through him.
    await b.publish(kReshareKind, reshareBody(post));
    await _settle();
    await e.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await e.publish(
      kCommentKind,
      commentBody(post.id, 'Ania, znowu Ty?'),
      spaceKind: 'acts',
    );
    await _settle();
    expect(await relayReactions(b, nameOf: names), 1);
    await _settle();

    expect(await blocking.check(), 0);
    expect(posted, isEmpty);
    // Not blocked, the same reactions are news.
    expect(await notifier().check(), 1);
    expect(posted.single.title, contains('Ewa'));
  });
}
