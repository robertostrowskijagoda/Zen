import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
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

  setUp(() => nodes = <String, _Linked>{});

  test(
    'reactions travel up to the author and down to friends of friends',
    () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada, cel]);
      final LedgerNode c = await make(cel, <String>[bob]);
      await publishProfileIfChanged(c, profileBody(name: 'Cela'));
      await publishProfileIfChanged(a, profileBody(name: 'Ada'));
      final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
      await _settle();
      await b.publish(kReshareKind, reshareBody(post));
      await _settle();

      // Cela (outside Ada's circle) likes and comments.
      await c.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
      await c.publish(
        kCommentKind,
        commentBody(post.id, 'Super!'),
        spaceKind: 'acts',
      );
      await _settle();
      String names(String x) => x == bob ? 'Bob' : x;
      expect(await relayReactions(b, nameOf: names), 1);
      // Nothing changed: no new bundle.
      expect(await relayReactions(b, nameOf: names), 0);
      await _settle();

      FeedPost onAda = buildFeed(a, nameOf: names).single;
      // Cela is not in Ada's circle: she is shown as what Bob relayed.
      expect(onAda.likers, <String>['Cela (przez Bob)']);
      expect(onAda.comments.single.text, 'Super!');
      expect(onAda.comments.single.authorLabel, 'Cela (przez Bob)');

      // Ada likes her own post; her bundle goes down through Bob to Cela.
      await a.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
      await _settle();
      expect(await relayReactions(a, nameOf: names), 1);
      await _settle();
      expect(await relayReactions(b, nameOf: names), 1);
      await _settle();

      final ReshareCache cache = ReshareCache();
      await cache.checkAll(c.entriesOf(ofAccount: b.account));
      final FeedPost onCela = buildFeed(
        c,
        nameOf: names,
        reshares: cache,
      ).single;
      expect(onCela.likers, unorderedEquals(<String>['Ty', 'Ada (przez Bob)']));
      expect(onCela.comments.single.authorLabel, 'Ty');

      // Taking the like back reaches Ada with the next bundle.
      await c.publish(
        kLikeKind,
        likeBody(post.id, on: false),
        spaceKind: 'acts',
      );
      await _settle();
      await relayReactions(b, nameOf: names);
      await _settle();
      onAda = buildFeed(a, nameOf: names).single;
      expect(onAda.likers, <String>['Ty']);
    },
  );

  test('a friend\'s bundle cannot speak for anyone in the circle', () async {
    final LedgerNode a = await make(ada, <String>[bob, cel]);
    final LedgerNode b = await make(bob, <String>[ada]);
    final LedgerNode c = await make(cel, <String>[ada]);
    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle();

    // Bob claims that Ada herself and Cela (her friend) liked the post, and
    // puts words in Cela's mouth. Only "Mama" is someone outside the circle.
    await b.publish(kReactionsKind, <String, dynamic>{
      'post': post.id,
      'likes': <Map<String, dynamic>>[
        <String, dynamic>{'a': a.account, 'n': 'Ada'},
        <String, dynamic>{'a': c.account, 'n': 'Cela'},
        <String, dynamic>{'a': 'outsider-account', 'n': 'Mama'},
      ],
      'comments': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': 'forged-1',
          'a': c.account,
          'n': 'Cela',
          't': 'Przelej mi pieniądze',
          'at': 5,
        },
      ],
    }, spaceKind: 'acts');
    await _settle();

    String names(String x) => x == bob ? 'Bob' : (x == cel ? 'Cela' : x);
    final FeedPost onAda = buildFeed(a, nameOf: names).single;
    // Ada's own account only ever speaks through her own entries.
    expect(onAda.likers, isNot(contains('Ty')));
    expect(onAda.likedByMe, isFalse);
    // Nothing relayed is ever shown as if a friend had said it.
    expect(onAda.likers, isNot(contains('Cela')));
    expect(onAda.likers, everyElement(endsWith('(przez Bob)')));
    expect(onAda.likers, contains('Mama (przez Bob)'));
    for (final FeedComment comment in onAda.comments) {
      expect(comment.authorLabel, endsWith('(przez Bob)'));
    }
  });
}
