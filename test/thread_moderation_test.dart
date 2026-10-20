import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
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
  final String bob = PeerShareCodec.normalizeAddress('200::b');
  final String cel = PeerShareCodec.normalizeAddress('200::c');
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

  String names(String x) => x == ada
      ? 'Ada'
      : x == bob
      ? 'Bob'
      : x == cel
      ? 'Cela'
      : x;

  FeedPost postOn(LedgerNode n, String id, {ReshareCache? reshares}) =>
      buildFeed(
        n,
        nameOf: names,
        reshares: reshares,
      ).firstWhere((FeedPost p) => p.id == id);

  setUp(() => nodes = <String, _Linked>{});

  test('the latest decision about a comment or a person wins', () {
    final ThreadModeration none = threadModerationOf(const <LogEntry>[]);
    expect(none.isEmpty, isTrue);
    const ThreadModeration a = ThreadModeration(
      hidden: <String, Set<String>>{
        'p': <String>{'c1'},
      },
    );
    const ThreadModeration b = ThreadModeration(
      blocked: <String, String>{'x': 'X'},
    );
    final ThreadModeration both = a.merge(b);
    expect(both.hidesComment('p', 'c1'), isTrue);
    expect(both.hidesComment('p', 'c2'), isFalse);
    expect(both.blocks('x'), isTrue);
    expect(commentHideBody('p', 'c', on: false)['on'], 0);
    expect(threadBlockBody('x', name: 'X')['n'], 'X');
  });

  test('the author hides a comment and blocks a person', () async {
    final LedgerNode a = await make(ada, <String>[bob, cel]);
    final LedgerNode b = await make(bob, <String>[ada, cel]);
    final LedgerNode c = await make(cel, <String>[ada, bob]);
    await _settle();
    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle();
    final LogEntry rude = await b.publish(
      kCommentKind,
      commentBody(post.id, 'Brzydko'),
      spaceKind: 'acts',
    );
    await c.publish(
      kCommentKind,
      commentBody(post.id, 'Miło'),
      spaceKind: 'acts',
    );
    await b.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await c.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await a.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await _settle();

    // You first, then friends; the summary names friends.
    FeedPost onAda = postOn(a, post.id);
    expect(onAda.likers.first, 'Ty');
    expect(onAda.likes.every((FeedLiker l) => l.friend), isTrue);
    expect(likeSummary(onAda), startsWith('Lubią to: Ty, '));
    expect(likeSummary(onAda), endsWith(' i 1 inna osoba'));

    await a.publish(
      kCommentHideKind,
      commentHideBody(post.id, rude.id),
      spaceKind: 'acts',
    );
    await _settle();
    // The author still sees it, marked; everyone else does not.
    onAda = postOn(a, post.id);
    expect(
      onAda.comments
          .firstWhere((FeedComment x) => x.id == rude.id)
          .hiddenByAuthor,
      isTrue,
    );
    expect(onAda.commentTotal, 1);
    expect(postOn(c, post.id).comments.map((FeedComment x) => x.text), <String>[
      'Miło',
    ]);
    expect(postOn(b, post.id).comments.map((FeedComment x) => x.text), <String>[
      'Miło',
    ]);

    // Shown again.
    await a.publish(
      kCommentHideKind,
      commentHideBody(post.id, rude.id, on: false),
      spaceKind: 'acts',
    );
    await _settle();
    expect(postOn(c, post.id).comments, hasLength(2));

    // Blocking Bob takes his like and comment out of Ada's threads.
    await a.publish(
      kThreadBlockKind,
      threadBlockBody(b.account, name: 'Bob'),
      spaceKind: 'acts',
    );
    await _settle();
    for (final LedgerNode n in <LedgerNode>[a, c]) {
      final FeedPost p = postOn(n, post.id);
      expect(
        p.likes.map((FeedLiker l) => l.account),
        isNot(contains(b.account)),
      );
      expect(p.comments.map((FeedComment x) => x.text), <String>['Miło']);
    }
  });

  test('bundles have pages, totals and the author\'s decisions', () async {
    final LedgerNode a = await make(ada, <String>[bob]);
    final LedgerNode b = await make(bob, <String>[ada, cel]);
    final LedgerNode c = await make(cel, <String>[bob]);
    await publishProfileIfChanged(a, profileBody(name: 'Ada'));
    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle();
    await b.publish(kReshareKind, reshareBody(post));
    await _settle();

    // Ada's circle is big: 250 likes on two pages, and one comment from
    // outside that she hid.
    Map<String, dynamic> like(int i) => <String, dynamic>{
      'a': 'x${i.toString().padLeft(3, '0')}',
      'n': 'Osoba $i',
    };
    await a.publish(kReactionsKind, <String, dynamic>{
      'post': post.id,
      'likes': <Map<String, dynamic>>[for (int i = 0; i < 200; i++) like(i)],
      'comments': <Map<String, dynamic>>[],
      'nl': 250,
      'np': 2,
      'hid': <String>['hidden-comment'],
      'blk': <String>['troll'],
    }, spaceKind: 'acts');
    await a.publish(kReactionsPageKind, <String, dynamic>{
      'post': post.id,
      'pg': 1,
      'likes': <Map<String, dynamic>>[for (int i = 200; i < 250; i++) like(i)],
      'comments': <Map<String, dynamic>>[],
    }, spaceKind: 'acts');
    await _settle();

    final PostReactions read = readBundles(
      b.entriesOf(spaceKind: 'acts', ofAccount: a.account),
    )[post.id]!;
    expect(read.likes, hasLength(250));
    expect(read.likeTotal, 250);
    expect(read.moderation.hidesComment(post.id, 'hidden-comment'), isTrue);
    expect(read.moderation.blocks('troll'), isTrue);

    // Someone in Bob's circle is the troll Ada blocked, another wrote the
    // comment she hid: Bob does not pass them on, and passes on her pages
    // and decisions.
    await b.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await _settle();
    expect(await relayReactions(b, nameOf: names), greaterThanOrEqualTo(2));
    final Map<String, LogEntry> bobs = latestBundles(
      b.entriesOf(spaceKind: 'acts'),
    );
    expect(bobs[post.id]!.body['np'], 2);
    expect(bobs[post.id]!.body['nl'], 251);
    expect(bobs[post.id]!.body['hid'], <String>['hidden-comment']);
    expect(bobs[post.id]!.body['blk'], <String>['troll']);
    await _settle();

    final ReshareCache cache = ReshareCache();
    await cache.checkAll(c.entriesOf(ofAccount: b.account));
    final FeedPost onCela = postOn(c, post.id, reshares: cache);
    expect(onCela.likeTotal, 251);
    expect(onCela.likes, hasLength(251));
    // Bob is Cela's friend: named first.
    expect(onCela.likers.first, 'Bob');
    expect(likeSummary(onCela), 'Lubią to: Bob i 250 innych osób');
    // Old readers: page 0 alone still reads as before.
    expect(readBundle(bobs[post.id]!)!.likes, hasLength(kMaxBundleLikers));
  });

  test('a removed post disappears for friends of a resharer too', () async {
    final LedgerNode a = await make(ada, <String>[bob]);
    final LedgerNode b = await make(bob, <String>[ada, cel]);
    final LedgerNode c = await make(cel, <String>[bob]);
    final LogEntry post = await a.publish(kPostKind, newPostBody('Ups'));
    await _settle();
    await b.publish(kReshareKind, reshareBody(post));
    await _settle();
    final ReshareCache cache = ReshareCache();
    await cache.checkAll(c.entriesOf(ofAccount: b.account));
    expect(
      buildFeed(c, nameOf: names, reshares: cache).map((FeedPost p) => p.id),
      contains(post.id),
    );

    await a.publish(kPostDeleteKind, deletePostBody(post.id));
    await _settle();
    // Bob holds Ada's tombstone and passes it on (once).
    expect(await relayTombstones(b), 1);
    expect(await relayTombstones(b), 0);
    await _settle();

    final ReshareCache later = ReshareCache();
    await later.checkAll(c.entriesOf(ofAccount: b.account));
    expect(later.isRemoved(post), isTrue);
    expect(
      buildFeed(c, nameOf: names, reshares: later).map((FeedPost p) => p.id),
      isNot(contains(post.id)),
    );
  });

  test('a passed-on tombstone must be signed by the author', () async {
    final LedgerNode a = await make(ada, <String>[bob]);
    final LedgerNode b = await make(bob, <String>[ada]);
    final LogEntry post = await a.publish(kPostKind, newPostBody('Moje'));
    // Bob removes his own post and claims it is Ada's.
    final LogEntry own = await b.publish(kPostKind, newPostBody('Bob'));
    final LogEntry tomb = await b.publish(
      kPostDeleteKind,
      deletePostBody(own.id),
    );
    final LogEntry fake = await b.publish(kReshareDeleteKind, <String, dynamic>{
      'post': post.id,
      'entry': tomb.toJson(),
    });
    expect(await unpackTombstone(fake), isNull);
    final ReshareCache cache = ReshareCache();
    await cache.checkAll(<LogEntry>[fake]);
    expect(cache.isRemoved(post), isFalse);
    expect(() => reshareDeleteBody(post), throwsArgumentError);
  });
}
