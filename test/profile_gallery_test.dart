import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/profile_gallery.dart';
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
  test(
    'the gallery is separate from posts; followers see only what is for everyone',
    () async {
      final String ada = PeerShareCodec.normalizeAddress('200::a');
      final String bob = PeerShareCodec.normalizeAddress('200::b');
      final String cel = PeerShareCodec.normalizeAddress('200::c');
      final Map<String, _Linked> nodes = <String, _Linked>{};
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

      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      final LedgerNode c = await make(cel, <String>[]);
      await c.follow(ada);
      await _settle();

      final Uint8List jpeg = Uint8List.fromList(<int>[0xFF, 0xD8, 1, 2, 3]);
      await addToGallery(a, <({Uint8List bytes, String mime})>[
        (bytes: jpeg, mime: 'image/jpeg'),
        (bytes: jpeg, mime: 'video/mp4'),
      ]);
      // A post with a photo stays a post.
      await a.publish(kPostKind, newPostBody('Na tablicy'));
      await _settle();

      final List<GalleryItem> mine = galleryOf(a);
      expect(mine.single.media.length, 2);
      expect(mine.single.audience, Audience.all);
      expect(
        buildFeed(a, nameOf: (_) => '?').map((FeedPost p) => p.text),
        <String>['Na tablicy'],
      );

      // A friend sees it in the gallery, never on the wall.
      final List<GalleryItem> seen = galleryOf(b, account: a.account);
      expect(seen.single.media.map((MediaRef m) => m.mime), <String>[
        'image/jpeg',
        'video/mp4',
      ]);
      expect(
        buildFeed(b, nameOf: (_) => 'Ada').map((FeedPost p) => p.text),
        <String>['Na tablicy'],
      );
      // A follower who is not a friend does not.
      expect(galleryOf(c, account: a.account), isEmpty);

      // "Wszyscy": followers see it too; narrowing it back hides it again.
      await addToGallery(a, <({Uint8List bytes, String mime})>[
        (bytes: jpeg, mime: 'image/jpeg'),
      ], audience: Audience.public);
      // A follower gets new entries at the next greeting.
      await c.greetFriends();
      await _settle();
      final GalleryItem open = galleryOf(c, account: a.account).single;
      expect(open.audience, Audience.public);
      await changeGalleryAudience(
        a,
        galleryOf(
          a,
        ).firstWhere((GalleryItem g) => g.audience == Audience.public),
        Audience.all,
      );
      await c.greetFriends();
      await _settle();
      expect(galleryOf(c, account: a.account), isEmpty);
      expect(galleryOf(b, account: a.account).length, 2);
      await removeFromGallery(
        a,
        galleryOf(a).firstWhere((GalleryItem g) => g.media.length == 1).id,
      );
      await _settle();

      await removeFromGallery(a, mine.single.id);
      await _settle();
      expect(galleryOf(a), isEmpty);
      expect(galleryOf(b, account: a.account), isEmpty);
    },
  );
}
