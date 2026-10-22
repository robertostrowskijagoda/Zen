import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_guard.dart';

/// A two-frame looping GIF, as the image package writes it.
Uint8List _gif({int width = 8, int height = 8}) {
  final img.Image first = img.Image(width: width, height: height)
    ..frameDuration = 40;
  img.fill(first, color: img.ColorRgb8(255, 0, 0));
  final img.Image second = img.Image(width: width, height: height)
    ..frameDuration = 40;
  img.fill(second, color: img.ColorRgb8(0, 0, 255));
  first.addFrame(second);
  return img.encodeGif(first);
}

/// Where the first block after the header and global colour table starts.
int _firstBlock(Uint8List gif) {
  final int packed = gif[10];
  return 13 + ((packed & 0x80) != 0 ? 3 * (1 << ((packed & 0x07) + 1)) : 0);
}

/// [gif] with a comment and an XMP block after its header, and something
/// appended after its end.
Uint8List _withMetadata(Uint8List gif) {
  final int at = _firstBlock(gif);
  final List<int> comment = <int>[
    0x21, 0xFE, 11, ...'Krakow 50.0'.codeUnits, 0x00, //
  ];
  final List<int> xmp = <int>[
    0x21, 0xFF, 11, ...'XMP DataXMP'.codeUnits, //
    5, ...'<x:a>'.codeUnits, 0x00,
  ];
  return Uint8List.fromList(<int>[
    ...gif.sublist(0, at),
    ...comment,
    ...xmp,
    ...gif.sublist(at),
    ...'ukryty dopisek'.codeUnits,
  ]);
}

bool _contains(Uint8List haystack, String needle) =>
    String.fromCharCodes(haystack).contains(needle);

void main() {
  test('metadata is dropped and the animation is kept', () {
    final Uint8List gif = _gif();
    final Uint8List dirty = _withMetadata(gif);
    expect(_contains(dirty, 'Krakow'), isTrue);

    final Uint8List clean = stripGifMetadata(dirty)!;
    expect(clean, stripGifMetadata(gif));
    expect(_contains(clean, 'Krakow'), isFalse);
    expect(_contains(clean, 'XMP'), isFalse);
    expect(_contains(clean, 'dopisek'), isFalse);
    expect(clean.last, 0x3B);
    expect(isAcceptableGif(clean), isTrue);
    final img.Image decoded = img.decodeGif(clean)!;
    expect(decoded.numFrames, 2);
  });

  test('a GIF without its trailer gets one; a cut one is broken', () {
    final Uint8List gif = _gif();
    final Uint8List clean = stripGifMetadata(gif)!;
    expect(
      stripGifMetadata(Uint8List.sublistView(gif, 0, gif.length - 1)),
      clean,
    );
    final Uint8List cut = Uint8List.sublistView(gif, 0, gif.length - 6);
    expect(stripGifMetadata(cut), isNull);
    expect(preparePickedGif(cut).status, PickedGifStatus.broken);
  });

  test('picked files: GIFs ready or over the limits, photos untouched', () {
    final PickedGif ready = preparePickedGif(_withMetadata(_gif()));
    expect(ready.status, PickedGifStatus.ready);
    expect(_contains(ready.bytes!, 'Krakow'), isFalse);

    final Uint8List png = Uint8List.fromList(
      img.encodePng(img.Image(width: 4, height: 4)),
    );
    expect(preparePickedGif(png).status, PickedGifStatus.notGif);

    // Over the size limit: not even read further.
    final Uint8List huge = Uint8List(kMaxSentGifBytes + 1)
      ..setRange(0, 6, 'GIF89a'.codeUnits);
    expect(preparePickedGif(huge).status, PickedGifStatus.tooLarge);

    // A canvas wider than any phone plays.
    final Uint8List wide = Uint8List.fromList(_gif());
    wide[6] = (kMaxGifSide + 100) & 0xFF;
    wide[7] = (kMaxGifSide + 100) >> 8;
    expect(preparePickedGif(wide).status, PickedGifStatus.tooLarge);
  });

  test('file names end in .gif', () {
    expect(gifFileName('kot.jpg'), 'kot.gif');
    expect(gifFileName('taniec'), 'taniec.gif');
    expect(gifFileName('  '), 'gif.gif');
  });

  test(
    'pictures for posts: a GIF stays a GIF, a photo becomes a JPEG',
    () async {
      final DraftMedia gif = await pictureForPost(_withMetadata(_gif()));
      expect(gif.mime, 'image/gif');
      expect(_contains(gif.bytes, 'Krakow'), isFalse);

      final DraftMedia photo = await pictureForPost(
        Uint8List.fromList(img.encodePng(img.Image(width: 6, height: 6))),
      );
      expect(photo.mime, 'image/jpeg');

      final Uint8List wide = Uint8List.fromList(_gif());
      wide[7] = 0x20; // 8192 px wide
      await expectLater(pictureForPost(wide), throwsArgumentError);
      await expectLater(
        pictureForPost(Uint8List.fromList(<int>[1, 2, 3])),
        throwsArgumentError,
      );
    },
  );

  testWidgets('a GIF picked for a post goes out as an animated GIF', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Uint8List picked = _withMetadata(_gif());
    PostDraft? sent;
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          pickPhotos: () async => <Uint8List>[picked],
          onSubmit: (PostDraft d) async {
            sent = d;
            return null;
          },
        ),
      ),
    );
    await tester.pump();
    await tester.enterText(find.byKey(const Key('post-text')), 'Taniec');
    await tester.tap(find.byKey(const Key('post-tool-photo')));
    for (int i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump();
      if (find.byKey(const Key('post-editor-gif')).evaluate().isNotEmpty) {
        break;
      }
    }
    expect(find.byKey(const Key('post-editor-gif')), findsOneWidget);
    await tester.tap(find.byKey(const Key('post-publish')));
    await tester.pump();
    final DraftMedia media = sent!.media.single;
    expect(media.mime, 'image/gif');
    expect(media.bytes, stripGifMetadata(picked));
    await tester.pumpWidget(const SizedBox());
  });
}
