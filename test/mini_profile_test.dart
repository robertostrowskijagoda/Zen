import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
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

  test('a tag is read back, clipped, and empty ones are nothing', () {
    final Map<String, dynamic> body = likeBody(
      'p',
      mini: const MiniProfileTag(name: 'Cela'),
    );
    expect(body['on'], 1);
    expect(MiniProfileTag.fromJson(body[kMiniProfileKey])?.name, 'Cela');
    expect(likeBody('p').containsKey(kMiniProfileKey), isFalse);
    expect(
      commentBody(
        'p',
        'Hej',
        mini: const MiniProfileTag(name: 'Cela'),
      )[kMiniProfileKey],
      <String, dynamic>{'n': 'Cela'},
    );
    expect(MiniProfileTag.fromJson(<String, dynamic>{'n': '  '}), isNull);
    expect(MiniProfileTag.fromJson('x'), isNull);
    expect(
      MiniProfileTag.fromJson(<String, dynamic>{'n': 'x' * 500})?.name.length,
      kMaxProfileName,
    );
  });

  test(
    'a stranger\'s name and photo reach the author with the bundle',
    () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada, cel]);
      final LedgerNode c = await make(cel, <String>[bob]);
      final Uint8List photo = Uint8List.fromList(
        List<int>.generate(2000, (int i) => i % 251),
      );
      final Map<String, dynamic>? ref = await avatarRefFor(c, photo);
      await publishProfileIfChanged(
        c,
        profileBody(name: 'Cela', address: cel, avatar: ref),
      );
      final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
      await _settle();
      await b.publish(kReshareKind, reshareBody(post));
      await _settle();

      final MiniProfileTag? mini = ownMiniProfile(c);
      expect(mini?.name, 'Cela');
      expect(mini?.avatar?.id, ref!['id']);
      await c.publish(
        kLikeKind,
        likeBody(post.id, mini: mini),
        spaceKind: 'acts',
      );
      await c.publish(
        kCommentKind,
        commentBody(post.id, 'Super!', mini: mini),
        spaceKind: 'acts',
      );
      await _settle();
      expect(await relayReactions(b, nameOf: (String x) => 'Bob'), 1);
      await _settle();

      final FeedPost onAda = buildFeed(a, nameOf: (String x) => 'Bob').single;
      // Shown as what Bob relayed (never as a friend), but with her photo.
      expect(onAda.likes.single.name, 'Cela (przez Bob)');
      expect(onAda.likes.single.friend, isFalse);
      expect(onAda.likes.single.avatar?.id, ref['id']);
      expect(onAda.comments.single.avatar?.id, ref['id']);
    },
  );

  test(
    'a like without a mini-profile still falls back to the profile photo',
    () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada, cel]);
      final LedgerNode c = await make(cel, <String>[bob]);
      final Map<String, dynamic>? ref = await avatarRefFor(
        c,
        Uint8List.fromList(List<int>.generate(1500, (int i) => (i * 7) % 251)),
      );
      await publishProfileIfChanged(c, profileBody(name: 'Cela', avatar: ref));
      final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
      await _settle();
      await b.publish(kReshareKind, reshareBody(post));
      await _settle();
      await c.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
      await _settle();
      await relayReactions(b, nameOf: (String x) => 'Bob');
      await _settle();

      final FeedPost onAda = buildFeed(a, nameOf: (String x) => 'Bob').single;
      expect(onAda.likes.single.avatar?.id, ref!['id']);
    },
  );

  test(
    'mutual friends are counted from the addresses known for the account',
    () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      await publishProfileIfChanged(b, profileBody(name: 'Bob', address: bob));
      await _settle();

      int byAddress(String address) => address == bob ? 2 : 0;
      expect(mutualFriendCount(a, b.account, byAddress), 2);
      expect(mutualFriendCount(a, 'nobody', byAddress), 0);
      expect(mutualFriendCount(a, a.account, byAddress), 0);
      expect(mutualFriendsText(0), isNull);
      expect(mutualFriendsText(1), '1 wspólny znajomy');
      expect(mutualFriendsText(3), '3 wspólnych znajomych');
    },
  );
}
