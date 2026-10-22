import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/presentation/comment_composer.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/media/media_transfer.dart';
import 'package:zen/src/features/meet/events/event_photo.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/profile_card.dart';
import 'package:zen/src/features/profile/profile_cover.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
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
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A GIF of [frames] pictures, plain colours or noise.
Uint8List _gif({int frames = 2, int width = 8, int height = 8}) {
  img.Image? first;
  for (int f = 0; f < frames; f++) {
    final img.Image frame = img.Image(width: width, height: height)
      ..frameDuration = 40;
    img.fill(frame, color: img.ColorRgb8((60 * f) % 256, 0, 200));
    if (first == null) {
      first = frame;
    } else {
      first.addFrame(frame);
    }
  }
  return img.encodeGif(first!);
}

Uint8List _noisyGif({required int frames, required int side}) {
  final math.Random random = math.Random(7);
  img.Image? first;
  for (int f = 0; f < frames; f++) {
    final img.Image frame = img.Image(width: side, height: side)
      ..frameDuration = 50;
    for (int y = 0; y < side; y++) {
      for (int x = 0; x < side; x++) {
        frame.setPixelRgb(
          x,
          y,
          random.nextInt(256),
          random.nextInt(256),
          random.nextInt(256),
        );
      }
    }
    if (first == null) {
      first = frame;
    } else {
      first.addFrame(frame);
    }
  }
  return img.encodeGif(first!);
}

final class _FakeTransfer implements MediaTransferPlatform {
  final StreamController<MediaDrop> controller =
      StreamController<MediaDrop>.broadcast();
  List<TransferItem> clipboard = const <TransferItem>[];

  @override
  Stream<MediaDrop> get drops => controller.stream;

  @override
  Future<List<TransferItem>> readClipboard({bool textFirst = false}) async =>
      clipboard;
}

void main() {
  group('GIFs stay animated', () {
    test('a GIF made smaller keeps its frames and fits the limits', () {
      final Uint8List big = _gif(frames: 3, width: 400, height: 300);
      final Uint8List small = shrinkGif(big, maxSide: 100, maxBytes: 64000)!;
      final ({int width, int height, int frames}) shape = gifShape(small)!;
      expect(shape.frames, 3);
      expect(shape.width, 100);
      expect(shape.height, 75);
      expect(img.decodeGif(small)!.numFrames, greaterThan(1));
      // Already small enough: only its metadata goes.
      final Uint8List tiny = _gif();
      expect(shrinkGif(tiny, maxSide: 100, maxBytes: 64000), isNotNull);
      expect(
        gifShape(shrinkGif(tiny, maxSide: 100, maxBytes: 64000)!)!.frames,
        2,
      );
    });

    test('over the byte limit it gets smaller and thinner, never still', () {
      final Uint8List noisy = _noisyGif(frames: 16, side: 120);
      expect(noisy.length, greaterThan(30 * 1024));
      final Uint8List small = shrinkGif(
        noisy,
        maxSide: 480,
        maxBytes: 30 * 1024,
      )!;
      expect(small.length, lessThanOrEqualTo(30 * 1024));
      expect(gifShape(small)!.frames, greaterThanOrEqualTo(2));
      // However hard the limit, a result is never a single frame.
      final Uint8List? hard = shrinkGif(
        _noisyGif(frames: 3, side: 64),
        maxSide: 64,
        maxBytes: 600,
      );
      expect(hard == null || gifShape(hard)!.frames >= 2, isTrue);
    });

    test('a cropped GIF has the shape asked for, every frame', () {
      final Uint8List wide = _gif(frames: 2, width: 300, height: 300);
      final Uint8List band = shrinkGif(
        wide,
        maxSide: 150,
        maxBytes: 1 << 20,
        aspect: 3,
      )!;
      final ({int width, int height, int frames}) shape = gifShape(band)!;
      expect(shape.width, 150);
      expect(shape.height, 50);
      expect(shape.frames, 2);
    });

    test('avatars, covers, event and flat photos keep a GIF animated', () {
      final Uint8List avatar = makeAvatarThumbnail(
        _gif(width: 300, height: 200),
      )!;
      expect(gifShape(avatar), (
        width: kProfileAvatarSize,
        height: kProfileAvatarSize,
        frames: 2,
      ));
      expect(sanitizeIncomingAvatar(avatar), isNotNull);

      final Uint8List cover = makeCoverImage(_gif(width: 300, height: 200))!;
      expect(gifShape(cover), (width: 300, height: 100, frames: 2));

      final Uint8List event = compressEventPhoto(
        _gif(width: 1000, height: 500),
      )!;
      expect(gifShape(event), (
        width: kEventGifSide,
        height: kEventGifSide ~/ 2,
        frames: 2,
      ));
      // What a phone of this app sends is taken by the others as it is.
      expect(gifShape(compressRemoteEventPhoto(event)!)!.frames, 2);
      // A flat's photo is smaller: an event's GIF is too big for one.
      expect(compressRemoteFlatPhoto(event), isNull);
      final Uint8List flat = compressFlatPhoto(_gif(width: 1000, height: 500))!;
      expect(gifShape(flat)!.width, kFlatGifSide);
      expect(gifShape(flat)!.frames, 2);
      expect(gifShape(compressRemoteFlatPhoto(flat)!)!.frames, 2);
    });

    test(
      'a GIF profile photo is kept animated, without its metadata',
      () async {
        final Directory dir = Directory.systemTemp.createTempSync(
          'zen-avatar-',
        );
        addTearDown(() => dir.deleteSync(recursive: true));
        final Uint8List gif = _gif();
        final int packed = gif[10];
        final int at =
            13 + ((packed & 0x80) != 0 ? 3 * (1 << ((packed & 0x07) + 1)) : 0);
        final File source = File('${dir.path}/ja.gif')
          ..writeAsBytesSync(<int>[
            ...gif.sublist(0, at),
            0x21, 0xFE, 6, ...'Gdynia'.codeUnits, 0x00, //
            ...gif.sublist(at),
          ]);
        final String stored = await AvatarSanitizer.validateAndStoreAvatar(
          sourcePath: source.path,
          storageDir: dir,
        );
        final Uint8List kept = File(stored).readAsBytesSync();
        expect(stored.endsWith('.gif'), isTrue);
        expect(gifShape(kept)!.frames, 2);
        expect(String.fromCharCodes(kept).contains('Gdynia'), isFalse);

        final File broken = File('${dir.path}/zly.gif')
          ..writeAsBytesSync(gif.sublist(0, gif.length ~/ 2));
        await expectLater(
          AvatarSanitizer.validateAndStoreAvatar(
            sourcePath: broken.path,
            storageDir: dir,
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('a GIF from another phone is taken only within the limits', () {
      final Uint8List ok = _gif(width: 100, height: 100);
      expect(acceptSmallGif(ok, maxSide: 100, maxBytes: 64000), isNotNull);
      expect(acceptSmallGif(ok, maxSide: 99, maxBytes: 64000), isNull);
      expect(acceptSmallGif(ok, maxSide: 100, maxBytes: 10), isNull);
      expect(
        acceptSmallGif(
          Uint8List.fromList(ok.sublist(0, ok.length - 20)),
          maxSide: 100,
          maxBytes: 64000,
        ),
        isNull,
        reason: 'cut short',
      );
    });

    test('a comment keeps a GIF as a GIF and makes a photo a JPEG', () async {
      final CommentPicture gif = await commentPicture(_gif());
      expect(gif.mime, 'image/gif');
      expect(gifShape(gif.bytes)!.frames, 2);
      final CommentPicture photo = await commentPicture(
        Uint8List.fromList(img.encodePng(img.Image(width: 6, height: 4))),
      );
      expect(photo.mime, 'image/jpeg');
      expect(photo.bytes.sublist(0, 2), <int>[0xFF, 0xD8]);
      expect(
        () => commentPicture(Uint8List.fromList('nie obraz'.codeUnits)),
        throwsArgumentError,
      );
    });
  });

  group('comment bodies', () {
    final Map<String, dynamic> ref = <String, dynamic>{
      'id': 'a' * 64,
      'k': b64(Uint8List(32)),
      'n': b64(Uint8List(12)),
      'mime': 'image/gif',
    };

    test('a comment may be pictures alone, up to the limit', () {
      final Map<String, dynamic> body = commentBody(
        'p',
        '  ',
        images: <Map<String, dynamic>>[ref],
      );
      expect(body['text'], '');
      expect((body['img'] as List<dynamic>).single, ref);
      expect(commentBody('p', 'Hej').containsKey('img'), isFalse);
      expect(() => commentBody('p', ' '), throwsArgumentError);
      expect(
        () => commentBody(
          'p',
          'Hej',
          images: List<Map<String, dynamic>>.filled(kMaxCommentImages + 1, ref),
        ),
        throwsArgumentError,
      );
      expect(
        () => checkCommentPictures(
          List<CommentPicture>.filled(kMaxCommentImages + 1, (
            bytes: _gif(),
            mime: 'image/gif',
          )),
        ),
        throwsArgumentError,
      );
      expect(
        () => checkCommentPictures(<CommentPicture>[
          (bytes: Uint8List(kMaxCommentImageBytes + 1), mime: 'image/jpeg'),
        ]),
        throwsArgumentError,
      );
    });

    test('only pictures are read from a comment, at most the limit', () {
      final List<MediaRef> read = commentImagesOf(<Object?>[
        ref,
        <String, dynamic>{...ref, 'mime': 'video/mp4'},
        'nie mapa',
        ...List<Map<String, dynamic>>.filled(kMaxCommentImages, ref),
      ]);
      // The first four entries are looked at; two of them are pictures.
      expect(read, hasLength(2));
      expect(read.every((MediaRef m) => m.mime == 'image/gif'), isTrue);
      expect(commentImagesOf(null), isEmpty);
    });
  });

  test('a pyramid comment keeps well-formed picture references only', () {
    final Map<String, dynamic> ref = <String, dynamic>{
      'id': 'b' * 64,
      'k': 'k' * 44,
      'n': 'n' * 16,
      'mime': 'image/jpeg',
    };
    final List<Map<String, dynamic>> got = pyrCommentMedia(<Object?>[
      ref,
      <String, dynamic>{...ref, 'mime': 'application/x-msdownload'},
      <String, dynamic>{...ref, 'id': ''},
      7,
    ]);
    expect(got, <Map<String, dynamic>>[ref]);
    expect(
      pyrCommentMedia(List<Object?>.filled(kMaxPyrCommentMedia + 2, ref)),
      hasLength(kMaxPyrCommentMedia),
    );
  });

  group('on a real ledger', () {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');

    Future<(LedgerNode, LedgerNode)> pair() async {
      final Map<String, _Linked> nodes = <String, _Linked>{};
      final _Linked ta = nodes[ada] = _Linked(ada, nodes);
      final _Linked tb = nodes[bob] = _Linked(bob, nodes);
      await ta.start();
      await tb.start();
      final LedgerNode a = LedgerNode(
        transport: ta,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => <String>[bob],
        bridges: BridgeBook(probe: (String _) async => null),
      );
      final LedgerNode b = LedgerNode(
        transport: tb,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => <String>[ada],
        bridges: BridgeBook(probe: (String _) async => null),
      );
      addTearDown(a.stop);
      addTearDown(b.stop);
      await a.start();
      await b.start();
      return (a, b);
    }

    test('a comment\'s GIF travels like a post\'s photo, plays, and goes '
        'everywhere with the comment', () async {
      final (LedgerNode a, LedgerNode b) = await pair();
      await a.publish(kPostKind, newPostBody('Jak wam minął dzień?'));
      await _settle();
      final String postId = buildFeed(b, nameOf: (_) => 'Ada').single.id;

      final LogEntry entry = await publishComment(
        b,
        postId,
        'Tak!',
        pictures: <CommentPicture>[await commentPicture(_gif(frames: 3))],
      );
      expect(entry.blobs, hasLength(1));
      final String file = entry.blobs.single;
      await _settle();

      // Ada sees the comment with its picture, fetched and still a GIF.
      FeedComment got = buildFeed(
        a,
        nameOf: (_) => 'Bob',
      ).single.comments.single;
      expect(got.text, 'Tak!');
      expect(got.images.single.mime, 'image/gif');
      expect(a.blobs.isComplete(file), isTrue);
      final Uint8List shown = (await openSafeImage(
        a.blobs,
        got.images.single,
      ))!;
      expect(gifShape(shown)!.frames, 3);

      // Friends of friends get it in Ada's bundle, which names the file.
      await relayReactions(a, nameOf: (_) => 'Bob');
      final LogEntry bundle = latestBundles(
        a.entriesOf(spaceKind: 'acts'),
      )[postId]!;
      expect(bundle.blobs, contains(file));
      final BundleComment passed = readBundles(
        a.entriesOf(spaceKind: 'acts'),
      )[postId]!.comments.single;
      expect(passed.images.single.id, file);

      // Bob removes it: gone from his phone at once, from Ada's at the
      // next round of the limits, and from the wall and the bundles.
      got = buildFeed(b, nameOf: (_) => 'Ada').single.comments.single;
      expect(canDeleteComment(b, got), isTrue);
      expect(canDeleteComment(a, got), isFalse);
      await deleteComment(b, postId, got);
      expect(b.blobs.refused, contains(file));
      await _settle();
      expect(buildFeed(a, nameOf: (_) => 'Bob').single.comments, isEmpty);
      // Ada's bundle still passes it on until it is written again.
      expect(removedCommentMedia(a), isNot(contains(file)));
      await relayReactions(a, nameOf: (_) => 'Bob');
      expect(
        readBundles(a.entriesOf(spaceKind: 'acts'))[postId]?.comments ??
            const <BundleComment>[],
        isEmpty,
      );
      expect(removedCommentMedia(a), contains(file));
      final RetentionResult result = await enforceStorageLimits(a);
      expect(result.expiredFiles, greaterThanOrEqualTo(1));
      expect(a.blobs.isComplete(file), isFalse);
      expect(a.blobs.refused, contains(file));
    });

    test('nothing is stored for a comment that cannot go', () async {
      final (LedgerNode a, LedgerNode _) = await pair();
      await expectLater(
        publishComment(
          a,
          'p',
          'x' * (kMaxCommentChars + 1),
          pictures: <CommentPicture>[(bytes: _gif(), mime: 'image/gif')],
        ),
        throwsArgumentError,
      );
      expect(storedMediaOf(a), isEmpty);
    });
  });

  testWidgets('a GIF dropped on the comment field goes with the comment', (
    WidgetTester tester,
  ) async {
    final _FakeTransfer fake = _FakeTransfer();
    MediaTransfer.platform = fake;
    final List<(String, List<CommentPicture>)> sent =
        <(String, List<CommentPicture>)>[];
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: CommentComposer(
              fieldKey: const Key('field'),
              sendKey: const Key('send'),
              onSend: (String text, List<CommentPicture> pictures) async {
                sent.add((text, pictures));
                return null;
              },
            ),
          ),
        ),
      ),
    );
    final Uint8List gif = _gif();
    fake.controller.add(
      MediaDrop(<TransferItem>[TransferItem(name: 'kot.gif', bytes: gif)]),
    );
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('comment-pending-0')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('field')), 'Patrz');
    await tester.tap(find.byKey(const Key('send')));
    await tester.pump();
    expect(sent.single.$1, 'Patrz');
    expect(sent.single.$2.single.mime, 'image/gif');
    expect(gifShape(sent.single.$2.single.bytes)!.frames, 2);
    expect(find.byKey(const Key('comment-pending-0')), findsNothing);
    await fake.controller.close();
  });

  testWidgets('on an iPhone the field\'s menu pastes a copied GIF', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final Future<bool> Function() asked = clipboardHasPicture;
    clipboardHasPicture = () async => true;
    final _FakeTransfer fake = _FakeTransfer()
      ..clipboard = <TransferItem>[
        TransferItem(name: 'schowek.gif', bytes: _gif()),
      ];
    MediaTransfer.platform = fake;
    try {
      final List<String> got = <String>[];
      final TextEditingController text = TextEditingController(text: 'hej');
      addTearDown(text.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: TextField(
                controller: text,
                contextMenuBuilder: picturePasteMenu(
                  (List<TransferItem> items) =>
                      got.addAll(items.map((TransferItem i) => i.name)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(TextField));
      await tester.pumpAndSettle();
      expect(find.text('Wklej obrazek'), findsOneWidget);
      await tester.tap(find.text('Wklej obrazek'));
      await tester.pumpAndSettle();
      expect(got, <String>['schowek.gif']);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      clipboardHasPicture = asked;
    }
  });
}
