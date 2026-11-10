import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/media/crop_region.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/presentation/image_crop_screen.dart';
import 'package:zen/src/features/profile/profile_cover.dart';

// Framing one's photo and cover before they are kept: the part chosen on
// the screen is the part kept, made the right shape.

/// A [w] x [h] PNG: red in the left half, blue in the right one (or red on
/// top, blue below with [vertical]).
Uint8List _halves(int w, int h, {bool vertical = false}) {
  final img.Image image = img.Image(width: w, height: h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final bool first = vertical ? y < h / 2 : x < w / 2;
      image.setPixelRgb(x, y, first ? 255 : 0, 0, first ? 0 : 255);
    }
  }
  return img.encodePng(image);
}

bool _reddish(img.Pixel p) => p.r > 200 && p.b < 60;
bool _bluish(img.Pixel p) => p.b > 200 && p.r < 60;

void main() {
  test('a region in pixels stays inside the picture and takes the shape '
      'asked for around its middle', () {
    expect(
      const CropRegion(
        left: 0.25,
        top: 0,
        width: 0.5,
        height: 1,
      ).pixels(400, 200, aspect: 1),
      (x: 100, y: 0, width: 200, height: 200),
    );
    // Off the edges: clamped.
    expect(
      const CropRegion(
        left: -0.5,
        top: 0.9,
        width: 2,
        height: 0.5,
      ).pixels(100, 100),
      (x: 0, y: 90, width: 100, height: 10),
    );
    // The whole of a wide picture made square: its middle.
    expect(CropRegion.full.pixels(300, 100, aspect: 1), (
      x: 100,
      y: 0,
      width: 100,
      height: 100,
    ));
    expect(CropRegion.full.isFull, isTrue);
  });

  test('a region at the far edge is the last pixel; regions differ by '
      'every side', () {
    expect(
      const CropRegion(
        left: 1,
        top: 1,
        width: 0.5,
        height: 0.5,
      ).pixels(100, 100),
      (x: 99, y: 99, width: 1, height: 1),
    );
    const CropRegion r = CropRegion(
      left: 0.1,
      top: 0.2,
      width: 0.3,
      height: 0.4,
    );
    expect(r, const CropRegion(left: 0.1, top: 0.2, width: 0.3, height: 0.4));
    for (final CropRegion other in <CropRegion>[
      const CropRegion(left: 0.9, top: 0.2, width: 0.3, height: 0.4),
      const CropRegion(left: 0.1, top: 0.9, width: 0.3, height: 0.4),
      const CropRegion(left: 0.1, top: 0.2, width: 0.9, height: 0.4),
      const CropRegion(left: 0.1, top: 0.2, width: 0.3, height: 0.9),
    ]) {
      expect(r == other, isFalse, reason: '$other');
    }
  });

  test('a photo with see-through parts stays a PNG, an opaque one with an '
      'alpha channel becomes a JPEG', () {
    img.Image four(bool hole) {
      final img.Image i = img.Image(width: 40, height: 40, numChannels: 4);
      for (final img.Pixel p in i) {
        p
          ..r = 200
          ..g = 10
          ..b = 10
          ..a = 255;
      }
      if (hole) {
        i.setPixelRgba(5, 5, 0, 0, 0, 0);
      }
      return i;
    }

    final Uint8List clear = makeAvatarImage((
      img.encodePng(four(true)),
      CropRegion.full,
    ))!;
    expect(clear.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    final Uint8List opaque = makeAvatarImage((
      img.encodePng(four(false)),
      CropRegion.full,
    ))!;
    expect(opaque.sublist(0, 2), <int>[0xFF, 0xD8]);
  });

  test('a framed WebP or GIF photo keeps its own extension', () async {
    final Directory dir = Directory.systemTemp.createTempSync('zen-crop-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final Uint8List webp = Uint8List.fromList(<int>[
      ...'RIFF'.codeUnits,
      0x10,
      0,
      0,
      0,
      ...'WEBP'.codeUnits,
      ...List<int>.filled(16, 0),
    ]);
    expect(
      await AvatarSanitizer.validateAndStoreAvatarBytes(
        rawBytes: webp,
        folder: () async => dir,
      ),
      endsWith('.webp'),
    );
    final img.Image frame = img.Image(width: 8, height: 8);
    expect(
      await AvatarSanitizer.validateAndStoreAvatarBytes(
        rawBytes: img.encodeGif(frame),
        folder: () async => dir,
      ),
      endsWith('.gif'),
    );
  });

  test('the photo is the framed square: the red half chosen, red is kept', () {
    final Uint8List picked = _halves(400, 200);
    final Uint8List left = makeAvatarImage((
      picked,
      const CropRegion(left: 0, top: 0, width: 0.5, height: 1),
    ))!;
    final img.Image a = img.decodeImage(left)!;
    expect(a.width, a.height);
    expect(a.width, 200);
    expect(_reddish(a.getPixel(100, 100)), isTrue);
    // A JPEG: nothing but pixels (no EXIF).
    expect(left[0] == 0xFF && left[1] == 0xD8, isTrue);

    final img.Image b = img.decodeImage(
      makeAvatarImage((
        picked,
        const CropRegion(left: 0.5, top: 0, width: 0.5, height: 1),
      ))!,
    )!;
    expect(_bluish(b.getPixel(100, 100)), isTrue);
  });

  test('a big photo is made at most $kAvatarSide a side; not a picture is '
      'refused', () {
    final img.Image big = img.Image(width: 2400, height: 2400);
    final img.Image out = img.decodeImage(
      makeAvatarImage((img.encodeJpg(big), CropRegion.full))!,
    )!;
    expect(out.width, kAvatarSide);
    expect(out.height, kAvatarSide);
    expect(
      makeAvatarImage((Uint8List.fromList(<int>[1, 2, 3, 4]), null)),
      isNull,
    );
  });

  test('the cover is the framed 3:1 band: the top chosen, the top is kept', () {
    final Uint8List picked = _halves(900, 900, vertical: true);
    final img.Image top = img.decodeImage(
      makeCoverImage(
        picked,
        region: const CropRegion(left: 0, top: 0, width: 1, height: 1 / 3),
      )!,
    )!;
    expect(top.width, 900);
    expect(top.height, 300);
    expect(_reddish(top.getPixel(450, 150)), isTrue);
    final img.Image bottom = img.decodeImage(
      makeCoverImage(
        picked,
        region: const CropRegion(left: 0, top: 2 / 3, width: 1, height: 1 / 3),
      )!,
    )!;
    expect(_bluish(bottom.getPixel(450, 150)), isTrue);
    // Without a region: the middle band, as before.
    expect(img.decodeImage(makeCoverImage(picked)!)!.height, 300);
  });

  test('a GIF is cut to the framed part and still plays', () {
    final img.Image first = img.Image(width: 200, height: 100);
    for (int y = 0; y < 100; y++) {
      for (int x = 0; x < 200; x++) {
        first.setPixelRgb(x, y, x < 100 ? 255 : 0, 0, x < 100 ? 0 : 255);
      }
    }
    final img.Image second = img.Image.from(first);
    first.addFrame(second);
    final Uint8List gif = img.encodeGif(first);
    final Uint8List out = shrinkGif(
      gif,
      maxSide: 512,
      maxBytes: 1024 * 1024,
      aspect: 1,
      region: const CropRegion(left: 0.5, top: 0, width: 0.5, height: 1),
    )!;
    final ({int width, int height, int frames}) shape = gifShape(out)!;
    expect(shape.width, 100);
    expect(shape.height, 100);
    expect(shape.frames, 2);
    expect(_bluish(img.decodeGif(out)!.getPixel(50, 50)), isTrue);
  });

  group('the framing screen', () {
    Future<CropRegion?> frame(
      WidgetTester tester,
      Uint8List bytes, {
      required double aspect,
      Future<void> Function()? before,
    }) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CropRegion? result;
      bool closed = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ZenTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await ImageCropScreen.open(
                  context,
                  bytes: bytes,
                  aspect: aspect,
                  title: 'Kadruj',
                  round: aspect == 1,
                );
                closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      // The picture is decoded for real (a spinner meanwhile).
      for (
        int i = 0;
        i < 20 && tester.any(find.byType(RawImage)) == false;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('image-crop-screen')), findsOneWidget);
      await before?.call();
      await tester.tap(find.byKey(const Key('image-crop-done')));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
      return result;
    }

    testWidgets('a wide picture under a square frame: its middle, filling '
        'the frame', (WidgetTester tester) async {
      final CropRegion r = (await frame(tester, _halves(400, 200), aspect: 1))!;
      expect(r.top, closeTo(0, 0.01));
      expect(r.height, closeTo(1, 0.01));
      expect(r.width, closeTo(0.5, 0.01));
      expect(r.left, closeTo(0.25, 0.01));
    });

    testWidgets('dragging moves the picture under the frame, and no further '
        'than its edge', (WidgetTester tester) async {
      final CropRegion r = (await frame(
        tester,
        _halves(400, 200),
        aspect: 1,
        before: () async {
          // The picture to the right: its left part comes under the frame.
          await tester.drag(
            find.byKey(const Key('image-crop-area')),
            const Offset(2000, 0),
          );
          await tester.pumpAndSettle();
        },
      ))!;
      expect(r.left, closeTo(0, 0.01));
      expect(r.width, closeTo(0.5, 0.01));
    });

    testWidgets('zooming in with the slider frames a smaller part, still '
        'around the middle', (WidgetTester tester) async {
      final CropRegion r = (await frame(
        tester,
        _halves(300, 300),
        aspect: 3,
        before: () async {
          final Slider slider = tester.widget(
            find.byKey(const Key('image-crop-zoom')),
          );
          slider.onChanged!(2);
          await tester.pumpAndSettle();
        },
      ))!;
      expect(r.width, closeTo(0.5, 0.01));
      expect(r.height, closeTo(0.5 / 3, 0.01));
      expect(r.left + r.width / 2, closeTo(0.5, 0.01));
      expect(r.top + r.height / 2, closeTo(0.5, 0.01));
    });

    testWidgets('a picture claiming to be huge (a decompression bomb) is not '
        'decoded: the framing gives up at once', (WidgetTester tester) async {
      // A 1x1 PNG whose header says 20000 x 20000.
      final Uint8List png = Uint8List.fromList(
        img.encodePng(img.Image(width: 1, height: 1)),
      );
      final ByteData header = ByteData.sublistView(png);
      header
        ..setUint32(16, 20000)
        ..setUint32(20, 20000)
        ..setUint32(29, _crc32(png.sublist(12, 29)));
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CropRegion? result;
      await tester.pumpWidget(
        MaterialApp(
          theme: ZenTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await ImageCropScreen.open(
                  context,
                  bytes: png,
                  aspect: 1,
                  title: 'Kadruj',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      for (int i = 0; i < 20 && result == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(result, CropRegion.full);
      expect(find.byType(RawImage), findsNothing);
    });

    testWidgets('back without "Gotowe": nothing is framed', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      CropRegion? result = CropRegion.full;
      await tester.pumpWidget(
        MaterialApp(
          theme: ZenTheme.dark(),
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () async {
                result = await ImageCropScreen.open(
                  context,
                  bytes: _halves(100, 100),
                  aspect: 1,
                  title: 'Kadruj',
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(CloseButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(result, isNull);
    });
  });
}

/// CRC-32 of [bytes] (a PNG chunk's type and data).
int _crc32(List<int> bytes) {
  int crc = 0xFFFFFFFF;
  for (final int b in bytes) {
    crc ^= b;
    for (int k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
