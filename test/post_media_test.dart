import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
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

Future<void> _settle([int rounds = 40]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('photos are re-encoded without EXIF and scaled down', () async {
    final img.Image big = img.Image(width: 3000, height: 1000);
    final Uint8List clean = await sanitizePhoto(
      Uint8List.fromList(img.encodePng(big)),
    );
    final img.Image? back = img.decodeJpg(clean);
    expect(back, isNotNull);
    expect(back!.width, kMaxImageSide);
    expect(back.exif.isEmpty, isTrue);
    await expectLater(
      sanitizePhoto(Uint8List.fromList(<int>[1, 2, 3, 4])),
      throwsArgumentError,
    );
  });

  test('media are stored encrypted and open only with the key', () async {
    final BlobStore blobs = BlobStore();
    final Uint8List plain = randomBytes(1000);
    final Map<String, dynamic> ref = await storeMedia(blobs, plain);
    final MediaRef parsed = mediaRefFromJson(ref)!;
    final Uint8List? stored = await blobs.read(parsed.id);
    expect(stored, isNot(equals(plain)));
    expect(await openMedia(blobs, parsed), plain);
    final MediaRef wrong = MediaRef(
      id: parsed.id,
      key: randomBytes(32),
      nonce: parsed.nonce,
      mime: parsed.mime,
    );
    expect(await openMedia(blobs, wrong), isNull);
    expect(() => newPostBody(''), throwsArgumentError);
    expect(
      newPostBody('', images: <Map<String, dynamic>>[ref])['img'],
      <Map<String, dynamic>>[ref],
    );
  });

  group('on the network', () {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final String cel = PeerShareCodec.normalizeAddress('200::c');
    late Map<String, _Linked> nodes;

    Future<LedgerNode> make(
      String address,
      List<String> friends, {
      bool auto = true,
    }) async {
      final _Linked t = nodes[address] = _Linked(address, nodes);
      await t.start();
      final LedgerNode n = LedgerNode(
        transport: t,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => friends,
        autoDownloadMedia: () => auto,
        bridges: BridgeBook(probe: (String _) async => null),
      );
      addTearDown(n.stop);
      await n.start();
      return n;
    }

    setUp(() => nodes = <String, _Linked>{});

    test('a friend and a follower both get the photo', () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      final LedgerNode c = await make(cel, const <String>[]);
      // Big enough for several rounds of chunks.
      final Uint8List photo = randomBytes(kBlobChunkSize * 6 + 123);
      final Map<String, dynamic> ref = await storeMedia(a.blobs, photo);
      await a.publish(
        kPostKind,
        newPostBody('Zdjęcie', images: <Map<String, dynamic>>[ref]),
        blobs: mediaIds(<Map<String, dynamic>>[ref]),
      );
      await c.follow(ada);
      await _settle(120);

      for (final LedgerNode n in <LedgerNode>[b, c]) {
        final FeedPost post = buildFeed(n, nameOf: (String x) => x).single;
        expect(post.images, hasLength(1));
        expect(await openMedia(n.blobs, post.images.single), photo);
      }
    });

    test('a formatted friends-only post with a photo and a video in place '
        'reaches a friend intact and renders there', () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada]);
      await _settle(20);
      final Uint8List photo = await sanitizePhoto(
        Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 40))),
      );
      final Uint8List video = randomBytes(kBlobChunkSize * 3 + 77);
      final List<Map<String, dynamic>> media = <Map<String, dynamic>>[
        await storeMedia(a.blobs, photo),
        await storeMedia(a.blobs, video, mime: 'video/mp4'),
      ];
      const String text =
          '# Weekend\nBył **super**!\n{{media:1}}\n> cytat\n{{media:0}}\nKoniec';
      await a.publish(
        kPostKind,
        await a.seal(
          Audience.all,
          newPostBody(text, audience: Audience.all, images: media),
        ),
        blobs: mediaIds(media),
      );
      await _settle(150);

      final FeedPost post = buildFeed(b, nameOf: (String x) => 'Ada').single;
      expect(post.text, text);
      expect(post.audience, Audience.all);
      expect(post.images.map((MediaRef m) => m.mime), <String>[
        'image/jpeg',
        'video/mp4',
      ]);
      expect(referencedMedia(post.text), <int>[1, 0]);
      expect(await openMedia(b.blobs, post.images[0]), photo);
      expect(await openMedia(b.blobs, post.images[1]), video);
      final List<RichBlock> blocks = parseBlocks(post.text);
      expect(blocks.first.type, RichBlockType.heading);
      expect(
        visibleRuns(blocks[1].text).firstWhere((RichRun r) => r.bold).text,
        'super',
      );
    });

    testWidgets('the friend sees the formatting and the photo', (
      WidgetTester tester,
    ) async {
      late LedgerNode b;
      await tester.runAsync(() async {
        final LedgerNode a = await make(ada, <String>[bob]);
        b = await make(bob, <String>[ada]);
        await _settle(20);
        final Map<String, dynamic> m = await storeMedia(
          a.blobs,
          await sanitizePhoto(
            Uint8List.fromList(img.encodePng(img.Image(width: 64, height: 40))),
          ),
        );
        await a.publish(
          kPostKind,
          await a.seal(
            Audience.all,
            newPostBody(
              '## Dla znajomych\nTo jest **ważne**\n{{media:0}}',
              audience: Audience.all,
              images: <Map<String, dynamic>>[m],
            ),
          ),
          blobs: mediaIds(<Map<String, dynamic>>[m]),
        );
        await _settle(150);
      });
      final FeedPost post = buildFeed(b, nameOf: (String x) => 'Ada').single;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: PostContent(post: post, node: b),
            ),
          ),
        ),
      );
      for (int i = 0; i < 10; i++) {
        await tester.runAsync(() => _settle(4));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.textContaining('Dla znajomych'), findsOneWidget);
      expect(find.textContaining('ważne'), findsOneWidget);
      expect(find.textContaining('**'), findsNothing);
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Image &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('feed-image-'),
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    });

    test('with automatic download off, media wait for a tap', () async {
      final LedgerNode a = await make(ada, <String>[bob]);
      final LedgerNode b = await make(bob, <String>[ada], auto: false);
      final Uint8List photo = randomBytes(5000);
      final Map<String, dynamic> ref = await storeMedia(a.blobs, photo);
      await a.publish(
        kPostKind,
        newPostBody('', images: <Map<String, dynamic>>[ref]),
        blobs: mediaIds(<Map<String, dynamic>>[ref]),
      );
      await _settle();
      final FeedPost post = buildFeed(b, nameOf: (String x) => x).single;
      expect(await openMedia(b.blobs, post.images.single), isNull);

      b.downloadMedia(post.entry!);
      await _settle();
      expect(await openMedia(b.blobs, post.images.single), photo);
    });
  });
}
