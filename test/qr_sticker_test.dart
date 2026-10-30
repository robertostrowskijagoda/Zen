import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/zen_web.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/neighbors/flat_door_mail.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/qr_sticker/qr_matrix.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';
import 'package:zen/src/features/qr_sticker/sticker_export.dart';
import 'package:zen/src/features/qr_sticker/sticker_pdf.dart';
import 'package:zen/src/features/qr_sticker/sticker_scene.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/qr_frame_decoder.dart';
import 'package:zen/src/features/update/presentation/install_guide_screen.dart';

import 'support/text_fit.dart' show loadAppFonts;

/// A door code as the app makes it, with [doors] doors in its sealed-knock
/// list.
FlatDoorCode _door(int doors) => FlatDoorCode(
  key: base64Url.encode(List<int>.generate(32, (int i) => i * 7)),
  door: base64Url
      .encode(List<int>.generate(12, (int i) => i * 3))
      .replaceAll('=', ''),
  inbox: PeerShareCodec.normalizeAddress('200:5d1a:9c2e::7f3b'),
  name: 'Kowalscy, m. 12',
  mail: FlatMailDoor(
    slots: <String>[
      for (int i = 1; i <= doors; i++)
        PeerShareCodec.normalizeAddress('202:${i}a1:4b2c::${i}d'),
    ],
    seal: base64Url.encode(List<int>.generate(32, (int i) => 255 - i)),
  ),
);

/// What each kind of sticker carries, as long as the app makes it (the door
/// code with every door a sticker lists: the longest).
Map<StickerKind, String> _payloads() {
  final String ada = PeerShareCodec.normalizeAddress('201:5d1a:9c2e::7f3b');
  final FlatDoorCode door = _door(kStickerSealDoors);
  return <StickerKind, String>{
    StickerKind.friendInvite: PeerShareCodec.buildLocalProfile(
      address: ada,
    )!.qrData,
    StickerKind.door: door.toLink(),
    StickerKind.installPage: kInstallPageUrl,
    StickerKind.donation: kDonationUrl,
    StickerKind.zenAbout: zenPageUrl('about/'),
    StickerKind.pebble: _pebbleLink(),
  };
}

/// A pebble's link as its sticker carries it: the pebble page with the
/// digits of a QR card (the ladybird of tool/ci/pebble_cards.py).
String _pebbleLink() {
  final Map<String, dynamic> cards =
      jsonDecode(File('tool/ci/pebble_card_vectors.json').readAsStringSync())
          as Map<String, dynamic>;
  final Map<String, dynamic> ladybird = (cards['vectors'] as List<dynamic>)
      .cast<Map<String, dynamic>>()
      .firstWhere((Map<String, dynamic> v) => v['name'] == 'qr-ladybird');
  return '${cards['link']}${ladybird['card']}';
}

const StickerTexts _texts = StickerTexts(
  top: 'Dom Kowalskich',
  caption: 'Bez serwerów · bez reklam',
  bottom: 'Zeskanuj QR, aby nas poznać',
);

Future<(Uint8List, int)> _rgba(StickerScene scene, int side) async {
  final ui.Image image = await renderStickerArtwork(scene, side);
  final ByteData data = (await image.toByteData())!;
  image.dispose();
  return (data.buffer.asUint8List(), side);
}

LumaFrame _luma(Uint8List rgba, int width, int height) {
  final Uint8List gray = Uint8List(width * height);
  for (int i = 0; i < gray.length; i++) {
    gray[i] =
        (rgba[4 * i] * 77 + rgba[4 * i + 1] * 150 + rgba[4 * i + 2] * 29) >> 8;
  }
  return LumaFrame(width: width, height: height, bytes: gray);
}

/// Every module read back from the picture at its centre (light or dark
/// by half the brightness) is the module that was encoded, outside the
/// logo; the quiet zone is all light.
List<String> _misreadModules(StickerScene scene, LumaFrame frame) {
  final double k = frame.width / StickerScene.side;
  bool darkAt(Offset p) =>
      frame.bytes[(p.dy * k).floor() * frame.width + (p.dx * k).floor()] < 128;
  final QrMatrix m = scene.matrix;
  final List<String> wrong = <String>[];
  for (int r = -QrMatrix.quietZone; r < m.size + QrMatrix.quietZone; r++) {
    for (int c = -QrMatrix.quietZone; c < m.size + QrMatrix.quietZone; c++) {
      final bool inside = r >= 0 && c >= 0 && r < m.size && c < m.size;
      if (inside && (scene.hole?.contains(r, c) ?? false)) {
        continue;
      }
      final bool expected = inside && m.isDark(r, c);
      if (darkAt(scene.moduleCentre(r, c)) != expected) {
        wrong.add('($r, $c)');
      }
    }
  }
  return wrong;
}

void main() {
  setUpAll(loadAppFonts);

  test('the alignment marks sit where the encoder put them', () {
    for (final String data in _payloads().values) {
      for (final bool robust in <bool>[false, true]) {
        final QrMatrix m = QrMatrix.encode(data, robust: robust);
        expect(m.size, m.version * 4 + 17);
        for (final (int r, int c) in m.alignmentMarks) {
          // A dark centre, a light ring, a dark ring.
          expect(m.isDark(r, c), isTrue, reason: '$data ($r, $c)');
          expect(m.isDark(r - 1, c), isFalse);
          expect(m.isDark(r + 2, c + 2), isTrue);
          expect(m.isFunction(r, c), isTrue);
        }
      }
    }
    expect(QrMatrix.alignmentCentresFor(1), isEmpty);
    expect(QrMatrix.alignmentCentresFor(7), <int>[6, 22, 38]);
    expect(QrMatrix.alignmentCentresFor(32), <int>[6, 34, 60, 86, 112, 138]);
    expect(QrMatrix.alignmentCentresFor(40), <int>[
      6,
      30,
      58,
      86,
      114,
      142,
      170,
    ]);
  });

  test('a logo goes only on a code with error correction H, off every '
      'pattern, under a tenth of the code', () {
    final Map<StickerKind, String> payloads = _payloads();
    for (final MapEntry<StickerKind, String> e in payloads.entries) {
      expect(QrMatrix.encode(e.value).logoHole, isNull, reason: e.key.name);
      final QrMatrix m = QrMatrix.encode(e.value, robust: true);
      final QrHole? hole = m.logoHole;
      if (hole == null) {
        continue;
      }
      expect(m.shareOf(hole), lessThan(0.2), reason: e.key.name);
      expect(m.shareOf(hole), lessThanOrEqualTo(QrMatrix.maxLogoShare));
      for (int r = hole.first - 1; r <= hole.first + hole.side; r++) {
        for (int c = hole.first - 1; c <= hole.first + hole.side; c++) {
          expect(m.isFunction(r, c), isFalse, reason: '${e.key.name} $r $c');
        }
      }
    }
    // The short links carry one; the page about Zen is the promotional
    // sticker's.
    expect(
      QrMatrix.encode(payloads[StickerKind.zenAbout]!, robust: true).logoHole,
      isNotNull,
    );
    expect(
      QrMatrix.encode(payloads[StickerKind.donation]!, robust: true).logoHole,
      isNotNull,
    );
  });

  test('every colour keeps the code and the texts dark enough on light', () {
    for (final StickerTheme theme in StickerTheme.values) {
      expect(
        QrMatrix.contrast(theme.ink, StickerTheme.plate),
        greaterThanOrEqualTo(QrMatrix.minContrast),
        reason: theme.name,
      );
      expect(
        QrMatrix.contrast(theme.ink, theme.paper),
        greaterThanOrEqualTo(QrMatrix.minContrast),
        reason: theme.name,
      );
    }
  });

  test('nothing but the code sits on the code or its quiet zone, the '
      'patterns stay in the margins and away from the texts', () {
    final Map<StickerKind, String> payloads = _payloads();
    for (final StickerPattern pattern in StickerPattern.values) {
      for (final StickerTexts texts in <StickerTexts>[
        _texts,
        const StickerTexts(),
        const StickerTexts(
          top: 'Bardzo długi napis na górze naklejki, który musi się zmieścić',
          bottom:
              'Prywatna sieć społecznościowa — zeskanuj i dołącz do nas '
              'jeszcze dziś, zapraszamy serdecznie',
        ),
      ]) {
        for (final MapEntry<StickerKind, String> e in payloads.entries) {
          final StickerDesign design = StickerDesign(
            texts: texts,
            pattern: pattern,
          );
          final StickerScene scene = StickerScene.build(
            StickerScene.matrixFor(e.value, design),
            design,
            kind: e.key,
          );
          // A pebble's stone lies under the white plate.
          final int plate = scene.shapes.indexWhere(
            (StickerShape s) => s.role == ShapeRole.plate,
          );
          for (final (int i, StickerShape s) in scene.shapes.indexed) {
            if (s.role == ShapeRole.frame) {
              expect(i, lessThan(plate), reason: e.key.name);
            }
          }
          const Rect art = Rect.fromLTWH(
            0,
            0,
            StickerScene.side,
            StickerScene.side,
          );
          // The quiet zone is the 4 modules around the code.
          expect(
            scene.qrRect.left - scene.quietRect.left,
            closeTo(QrMatrix.quietZone * scene.module, 1e-6),
          );
          expect(scene.quietRect.center, art.center);
          final List<StickerShape> others = <StickerShape>[
            for (final StickerShape s in scene.shapes)
              if (s.role != ShapeRole.background &&
                  s.role != ShapeRole.plate &&
                  s.role != ShapeRole.qr &&
                  s.role != ShapeRole.logo &&
                  s.role != ShapeRole.frame)
                s,
          ];
          for (final StickerShape s in others) {
            expect(
              s.bounds.overlaps(scene.quietRect),
              isFalse,
              reason: '${pattern.name} ${s.role.name} ${s.bounds}',
            );
            expect(art.contains(s.bounds.topLeft), isTrue);
            expect(art.contains(s.bounds.bottomRight), isTrue);
          }
          for (final StickerShape s in scene.withRole(ShapeRole.frame)) {
            expect(
              art.deflate(StickerScene.margin).contains(s.bounds.topLeft),
              isTrue,
            );
            expect(
              art.deflate(StickerScene.margin).contains(s.bounds.bottomRight),
              isTrue,
            );
          }
          final List<StickerShape> words = <StickerShape>[
            ...scene.withRole(ShapeRole.text),
            ...scene.withRole(ShapeRole.signature),
            ...scene.withRole(ShapeRole.mark),
            ...scene.withRole(ShapeRole.frame),
          ];
          for (final StickerShape d in scene.withRole(ShapeRole.decoration)) {
            for (final StickerShape w in words) {
              expect(
                d.bounds.overlaps(w.bounds),
                isFalse,
                reason: '${pattern.name}: ${d.bounds} on "$w"',
              );
            }
          }
          for (final StickerShape s in scene.withRole(ShapeRole.qr)) {
            expect(
              scene.quietRect
                  .deflate(QrMatrix.quietZone * scene.module - 1e-6)
                  .contains(s.bounds.center),
              isTrue,
            );
          }
          if (pattern != StickerPattern.none) {
            expect(
              scene.withRole(ShapeRole.decoration),
              isNotEmpty,
              reason: pattern.name,
            );
          }
        }
      }
    }
  });

  test('texts shrink to fit: long ones stay inside the artwork, on at most '
      'two lines', () {
    final StickerDesign design = StickerDesign(
      texts: StickerTexts(
        top: 'Dom ' * 30,
        caption: 'mały napis ' * 10,
        bottom: 'Zeskanuj QR, aby nas poznać ' * 4,
      ),
    );
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(kDonationUrl, design),
      design,
    );
    final List<StickerText> texts = scene
        .withRole(ShapeRole.text)
        .cast<StickerText>()
        .toList();
    expect(texts, hasLength(3));
    for (final StickerText text in texts) {
      expect(text.lines.length, lessThanOrEqualTo(text.maxLines));
      expect(text.bounds.left, greaterThanOrEqualTo(StickerScene.margin - 1));
      expect(
        text.bounds.right,
        lessThanOrEqualTo(StickerScene.side - StickerScene.margin + 1),
      );
    }
    // Above the code, the caption right under it, the rest below.
    expect(texts[0].bounds.bottom, lessThanOrEqualTo(scene.quietRect.top));
    expect(texts[1].bounds.top, greaterThanOrEqualTo(scene.quietRect.bottom));
    expect(texts[2].bounds.top, greaterThanOrEqualTo(texts[1].bounds.bottom));
    // A short text is set large, a long one smaller.
    final StickerDesign short = design.copyWith(
      texts: const StickerTexts(top: 'Zen'),
    );
    final StickerText big =
        StickerScene.build(
              StickerScene.matrixFor(kDonationUrl, short),
              short,
            ).withRole(ShapeRole.text).single
            as StickerText;
    expect(big.size, greaterThan(texts[0].size));
  });

  test('the signature is on by default and can be switched off', () {
    const StickerDesign design = StickerDesign();
    expect(design.signature, isTrue);
    final QrMatrix m = StickerScene.matrixFor(kDonationUrl, design);
    expect(
      StickerScene.build(m, design).withRole(ShapeRole.signature),
      hasLength(2),
    );
    expect(
      StickerScene.build(
        m,
        design.copyWith(signature: false),
      ).withRole(ShapeRole.signature),
      isEmpty,
    );
  });

  test('every style of every kind reads back module by module and '
      'decodes', () async {
    final Map<StickerKind, String> payloads = _payloads();
    for (final MapEntry<StickerKind, String> e in payloads.entries) {
      for (final QrStyle style in QrStyle.values) {
        for (final bool logo in <bool>[false, true]) {
          final StickerDesign design = StickerDesign(
            texts: _texts,
            style: style,
            logo: logo,
            pattern: StickerPattern.values[(style.index + 1) % 7],
            theme:
                StickerTheme.values[style.index % StickerTheme.values.length],
          );
          final QrMatrix m = StickerScene.matrixFor(e.value, design);
          final StickerScene scene = StickerScene.build(m, design, kind: e.key);
          final String what = '${e.key.name} ${style.name} logo: $logo';
          expect(scene.hole != null, logo && m.logoHole != null, reason: what);
          final (Uint8List rgba, int side) = await _rgba(scene, 1200);
          final LumaFrame frame = _luma(rgba, side, side);
          expect(_misreadModules(scene, frame), isEmpty, reason: what);
          expect(decodeQrLuma(frame), e.value, reason: what);
        }
      }
    }
  });

  test('every colour decodes', () async {
    for (final StickerTheme theme in StickerTheme.values) {
      final StickerDesign design = StickerDesign(
        texts: _texts,
        theme: theme,
        style: QrStyle.dots,
        pattern: StickerPattern.butterflies,
      );
      final String data = zenPageUrl('about/');
      final StickerScene scene = StickerScene.build(
        StickerScene.matrixFor(data, design),
        design,
      );
      final (Uint8List rgba, int side) = await _rgba(scene, 900);
      final LumaFrame frame = _luma(rgba, side, side);
      expect(_misreadModules(scene, frame), isEmpty, reason: theme.name);
      expect(decodeQrLuma(frame), data, reason: theme.name);
    }
  });

  test('the dots keep most of a module', () {
    expect(StickerScene.dotFill, greaterThanOrEqualTo(0.86));
  });

  test('pages: A4 at 300 dpi is 2480 × 3508 with the artwork square in '
      'the middle', () {
    final StickerSheet a4 = StickerSheet(StickerPage.a4);
    expect((a4.widthPx, a4.heightPx), (2480, 3508));
    final StickerSheet across = StickerSheet(StickerPage.a4, landscape: true);
    expect((across.widthPx, across.heightPx), (3508, 2480));
    for (final StickerPage page in StickerPage.values) {
      for (final bool landscape in <bool>[false, true]) {
        final StickerSheet s = StickerSheet(page, landscape: landscape);
        final int right = s.widthPx - s.leftPx - s.sidePx;
        final int bottom = s.heightPx - s.topPx - s.sidePx;
        expect((s.leftPx - right).abs(), lessThanOrEqualTo(1), reason: '$page');
        expect((s.topPx - bottom).abs(), lessThanOrEqualTo(1), reason: '$page');
        expect(s.sidePx, lessThanOrEqualTo(s.widthPx));
        expect(s.sidePx, lessThanOrEqualTo(s.heightPx));
        if (page.hasMargins) {
          // The printer's edge stays clear on paper.
          expect(s.leftPx, greaterThanOrEqualTo(141));
          expect(s.topPx, greaterThanOrEqualTo(141));
        }
      }
    }
    expect(StickerSheet(StickerPage.a5).widthPx, 1748);
    expect(StickerSheet(StickerPage.letter).widthPx, 2550);
    expect(StickerSheet(StickerPage.sticker).sidePx, 1181);
    final StickerSheet wall = StickerSheet(StickerPage.wallpaper);
    expect((wall.widthPx, wall.heightPx), (1080, 2340));
    // Cutting marks only on paper with margins, outside the square.
    expect(a4.marks(true), hasLength(8));
    expect(a4.marks(false), isEmpty);
    expect(StickerSheet(StickerPage.sticker).marks(true), isEmpty);
    for (final (double x1, double y1, double x2, double y2) in a4.marks(true)) {
      final Rect square = Rect.fromLTWH(
        a4.leftMm,
        a4.topMm,
        a4.sideMm,
        a4.sideMm,
      );
      expect(square.deflate(0.01).contains(Offset(x1, y1)), isFalse);
      expect(square.deflate(0.01).contains(Offset(x2, y2)), isFalse);
    }
  });

  test('sizes: each page offers the sizes it holds within its margins, and '
      'a size it cannot hold prints as the largest', () {
    expect(StickerSheet.sizesMm(StickerPage.a4), <int>[
      40,
      50,
      60,
      80,
      100,
      120,
      150,
    ]);
    expect(StickerSheet.sizesMm(StickerPage.letter), <int>[
      40,
      50,
      60,
      80,
      100,
      120,
      150,
    ]);
    expect(StickerSheet.sizesMm(StickerPage.a5), <int>[
      40,
      50,
      60,
      80,
      100,
      120,
    ]);
    // The fixed formats: the whole of them as today, or smaller, centred.
    expect(StickerSheet.sizesMm(StickerPage.square), <int>[
      40,
      50,
      60,
      80,
      100,
      120,
      150,
    ]);
    expect(StickerSheet.sizesMm(StickerPage.sticker), <int>[40, 50, 60, 80]);
    // A wallpaper is not printed: it keeps filling the screen.
    expect(StickerSheet.sizesMm(StickerPage.wallpaper), isEmpty);
    expect(
      StickerSheet(StickerPage.wallpaper, sizeMm: 40).sidePx,
      StickerSheet(StickerPage.wallpaper).sidePx,
    );

    expect(StickerSheet.largestSideMm(StickerPage.a4), 186);
    expect(StickerSheet.largestSideMm(StickerPage.a5), 124);
    expect(StickerSheet.largestSideMm(StickerPage.square), 200);
    expect(StickerSheet.largestSideMm(StickerPage.sticker), 100);
    for (final StickerPage page in StickerPage.values) {
      for (final int mm in StickerSheet.sizesMm(page)) {
        for (final bool landscape in <bool>[false, true]) {
          final StickerSheet s = StickerSheet(
            page,
            landscape: landscape,
            sizeMm: mm,
          );
          expect(s.largest, isFalse);
          expect(s.sideMm, mm.toDouble());
          if (page.hasMargins) {
            // The printer's edge stays clear.
            expect(s.leftMm, greaterThanOrEqualTo(12), reason: '$page $mm');
            expect(s.topMm, greaterThanOrEqualTo(12), reason: '$page $mm');
          }
          // Centred.
          final int right = s.widthPx - s.leftPx - s.sidePx;
          final int bottom = s.heightPx - s.topPx - s.sidePx;
          expect((s.leftPx - right).abs(), lessThanOrEqualTo(1));
          expect((s.topPx - bottom).abs(), lessThanOrEqualTo(1));
        }
      }
    }
    // The largest is today's look.
    final StickerSheet a4 = StickerSheet(StickerPage.a4);
    expect((a4.largest, a4.sideMm, a4.sidePx), (true, 186, 2197));
    final StickerSheet tooLarge = StickerSheet(StickerPage.a5, sizeMm: 150);
    expect((tooLarge.largest, tooLarge.sideMm), (true, 124));
    expect(StickerSheet(StickerPage.sticker, sizeMm: 100).largest, isTrue);
    // Only the offered sizes are kept.
    expect(StickerDesign.fromJson(<String, Object>{'sizeMm': 77}).sizeMm, 0);
    expect(StickerDesign.fromJson(<String, Object>{'sizeMm': 50}).sizeMm, 50);
    expect(const StickerDesign().sizeMm, StickerDesign.largest);
    expect(const StickerDesign().tile, isFalse);
  });

  test('every size exports at exactly its side at 300 dpi: the pixels of '
      'the picture and the points it is placed at', () async {
    const StickerDesign design = StickerDesign(texts: _texts);
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(kDonationUrl, design),
      design,
    );
    // mm → (pixels at 300 dpi, PDF points).
    const Map<int, (int, String)> sizes = <int, (int, String)>{
      40: (472, '113.39'),
      50: (591, '141.73'),
      60: (709, '170.08'),
      80: (945, '226.77'),
      100: (1181, '283.46'),
      120: (1417, '340.16'),
      150: (1772, '425.2'),
      200: (2362, '566.93'),
    };
    for (final MapEntry<int, (int, String)> e in sizes.entries) {
      final StickerPage page = e.key <= 150
          ? StickerPage.a4
          : StickerPage.square;
      final (int px, String pt) = e.value;
      final StickerSheet sheet = StickerSheet(page, sizeMm: e.key);
      expect(sheet.sidePx, px, reason: '${e.key} mm');
      final String pdf = latin1.decode(
        await exportSticker(
          scene,
          design.copyWith(page: page, sizeMm: e.key),
          format: StickerFormat.pdf,
        ),
      );
      expect(pdf, contains('/Width $px /Height $px'), reason: '${e.key} mm');
      expect(pdf, contains('$pt 0 0 $pt '), reason: '${e.key} mm');
      expect(RegExp(r'/Im0 Do').allMatches(pdf), hasLength(1));
    }
    // The page keeps its size; the artwork sits in its middle.
    final StickerDesign small = design.copyWith(
      page: StickerPage.sticker,
      sizeMm: 40,
    );
    final ui.ImageDescriptor png = await ui.ImageDescriptor.encoded(
      await ui.ImmutableBuffer.fromUint8List(
        await exportSticker(scene, small, format: StickerFormat.png),
      ),
    );
    expect((png.width, png.height), (1181, 1181));
    final StickerSheet sheet = StickerSheet.of(small);
    expect((sheet.leftPx, sheet.topPx, sheet.sidePx), (354, 354, 472));
    final String svg = utf8.decode(
      await exportSticker(scene, small, format: StickerFormat.svg),
    );
    expect(svg, contains('width="100mm" height="100mm"'));
    expect(svg, contains('translate(30 30) scale(0.04000)'));
  });

  test('several on a page: A4 with 5 cm stickers holds 3 × 5, centred, '
      '5 mm apart, with cutting marks along every edge', () {
    final StickerSheet a4 = StickerSheet(
      StickerPage.a4,
      sizeMm: 50,
      tile: true,
    );
    expect((a4.columns, a4.rows, a4.tiles.length), (3, 5, 15));
    expect(
      <double>[for (final StickerTile t in a4.tiles.take(3)) t.leftMm],
      <double>[25, 80, 135],
    );
    expect(
      <double>[for (int r = 0; r < 5; r++) a4.tiles[r * 3].topMm],
      <double>[13.5, 68.5, 123.5, 178.5, 233.5],
    );
    expect(
      <int>[for (final StickerTile t in a4.tiles.take(3)) t.leftPx],
      <int>[294, 944, 1594],
    );
    expect(
      <int>[for (int r = 0; r < 5; r++) a4.tiles[r * 3].topPx],
      <int>[158, 808, 1458, 2108, 2758],
    );
    // Every copy whole on the page, inside the margins, none overlapping.
    for (final StickerTile t in a4.tiles) {
      expect(t.leftMm, greaterThanOrEqualTo(12));
      expect(t.topMm, greaterThanOrEqualTo(12));
      expect(t.leftMm + 50, lessThanOrEqualTo(210 - 12));
      expect(t.topMm + 50, lessThanOrEqualTo(297 - 12));
      expect(t.leftPx + a4.sidePx, lessThanOrEqualTo(a4.widthPx));
      expect(t.topPx + a4.sidePx, lessThanOrEqualTo(a4.heightPx));
    }

    // Turned, and the other pages and sizes.
    final StickerSheet across = StickerSheet(
      StickerPage.a4,
      landscape: true,
      sizeMm: 50,
      tile: true,
    );
    expect((across.columns, across.rows), (5, 3));
    int count(StickerPage page, int mm) =>
        StickerSheet(page, sizeMm: mm, tile: true).tiles.length;
    expect(count(StickerPage.a4, 40), 24);
    expect(count(StickerPage.a4, 80), 6);
    expect(count(StickerPage.a4, 100), 2);
    expect(count(StickerPage.a5, 50), 6);
    expect(count(StickerPage.letter, 40), 20);
    // Too large for two, the largest, and the fixed formats: one copy.
    expect(count(StickerPage.a4, 150), 1);
    expect(StickerSheet(StickerPage.a4, tile: true).tiles, hasLength(1));
    expect(count(StickerPage.sticker, 40), 1);
    expect(count(StickerPage.square, 50), 1);
    // Untiled: one copy in the middle.
    expect(StickerSheet(StickerPage.a4, sizeMm: 50).tiles, hasLength(1));

    // Marks: every edge in the margins (4 a column, 4 a row) and across
    // every gap, never on a copy.
    final List<(double, double, double, double)> marks = a4.marks(true);
    expect(marks, hasLength(4 * 3 + 4 * 5 + 2 * 3 * 4 + 2 * 5 * 2));
    expect(a4.marks(false), isEmpty);
    for (final (double x1, double y1, double x2, double y2) in marks) {
      for (final StickerTile t in a4.tiles) {
        final Rect copy = Rect.fromLTWH(t.leftMm, t.topMm, 50, 50).deflate(.01);
        expect(copy.contains(Offset(x1, y1)), isFalse);
        expect(copy.contains(Offset(x2, y2)), isFalse);
        expect(copy.contains(Offset((x1 + x2) / 2, (y1 + y2) / 2)), isFalse);
      }
      for (final double v in <double>[x1, x2]) {
        expect(v, inInclusiveRange(0, 210));
      }
      for (final double v in <double>[y1, y2]) {
        expect(v, inInclusiveRange(0, 297));
      }
    }
    // Each cut of the grid has its marks: the left edge of the middle
    // column, in the top margin and across the first gap.
    expect(marks, contains((80.0, 13.5 - 9, 80.0, 13.5 - 2)));
    expect(marks, contains((80.0, 63.5 + 1, 80.0, 68.5 - 1)));
    // One copy keeps the 8 marks around it.
    expect(StickerSheet(StickerPage.a4, sizeMm: 50).marks(true), hasLength(8));
  });

  test('several on a page in every file: the picture once in the PDF, '
      'placed on each copy, the PNG with every copy and the SVG with one '
      'drawing used on each', () async {
    const StickerDesign design = StickerDesign(
      texts: _texts,
      theme: StickerTheme.ocean,
      page: StickerPage.a4,
      sizeMm: 50,
      tile: true,
    );
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(kDonationUrl, design),
      design,
    );
    final StickerSheet sheet = StickerSheet.of(design);
    final Uint8List pdf = await exportSticker(scene, design);
    _expectValidPdf(pdf, widthPt: '595.28', heightPt: '841.89');
    final String text = latin1.decode(pdf);
    expect(RegExp('/Subtype /Image').allMatches(text), hasLength(1));
    expect(text, contains('/Width 591 /Height 591'));
    expect(RegExp(r'/Im0 Do').allMatches(text), hasLength(15));
    // The first copy 25 mm from the left, 13.5 mm from the top.
    expect(text, contains('141.73 0 0 141.73 70.87 661.89 cm'));
    expect(RegExp(r' l S\n').allMatches(text), hasLength(76));

    final ui.Image page = await renderStickerSheet(scene, sheet);
    expect((page.width, page.height), (2480, 3508));
    final ByteData rgba = (await page.toByteData())!;
    page.dispose();
    int at(int x, int y) {
      final int i = 4 * (y * sheet.widthPx + x);
      return 0xFF000000 |
          rgba.getUint8(i) << 16 |
          rgba.getUint8(i + 1) << 8 |
          rgba.getUint8(i + 2);
    }

    for (final StickerTile t in sheet.tiles) {
      // The sticker's paper just inside each copy's corner, white paper in
      // the gap beside it.
      expect(at(t.leftPx + 4, t.topPx + 4), StickerTheme.ocean.paper);
      expect(at(t.leftPx - 25, t.topPx + 4), 0xFFFFFFFF);
    }
    // A copy cut out of the page reads as the code.
    final StickerTile middle = sheet.tiles[7];
    final int side = sheet.sidePx;
    final Uint8List gray = Uint8List(side * side);
    for (int y = 0; y < side; y++) {
      for (int x = 0; x < side; x++) {
        final int c = at(middle.leftPx + x, middle.topPx + y);
        gray[y * side + x] =
            ((c >> 16 & 0xFF) * 77 + (c >> 8 & 0xFF) * 150 + (c & 0xFF) * 29) >>
            8;
      }
    }
    expect(
      decodeQrLuma(LumaFrame(width: side, height: side, bytes: gray)),
      kDonationUrl,
    );

    final String svg = utf8.decode(
      await exportSticker(scene, design, format: StickerFormat.svg),
    );
    expect(RegExp('<defs>').allMatches(svg), hasLength(1));
    expect(RegExp('<use ').allMatches(svg), hasLength(15));
    expect(svg, contains('<use xlink:href="#sticker" href="#sticker" x="25" '));
    expect(RegExp('>Dom Kowalskich</text>').allMatches(svg), hasLength(1));
    expect(RegExp('<line ').allMatches(svg), hasLength(76));
    final String single = utf8.decode(
      await exportSticker(
        scene,
        design.copyWith(tile: false),
        format: StickerFormat.svg,
      ),
    );
    expect(single, isNot(contains('<use ')));
  });

  test('the printed dot: the module of the actual code at the chosen size, '
      'with a warning under 0.5 mm and a note under 0.7 mm', () {
    expect(ModuleSize.of(0.3), ModuleSize.tiny);
    expect(ModuleSize.of(0.499), ModuleSize.tiny);
    expect(ModuleSize.of(0.5), ModuleSize.small);
    expect(ModuleSize.of(0.699), ModuleSize.small);
    expect(ModuleSize.of(0.7), ModuleSize.fine);
    expect(ModuleSize.of(2), ModuleSize.fine);

    final String link = _door(kDoorSlots).toLink();
    final StickerDesign design = StickerDesign(
      texts: stickerPresets(StickerKind.door).first,
    );
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(link, design),
      design,
      kind: StickerKind.door,
    );
    final int grid = scene.matrix.size;
    expect(grid, QrMatrix.encode(link).size);
    expect(grid % 4, 1);
    // The code with its quiet zone takes a fixed share of the artwork.
    final double share = scene.module / StickerScene.side;
    expect(share, closeTo(540 / 1000 / (grid + 8), 1e-12));
    for (final int mm in StickerSheet.sizesMm(StickerPage.a4)) {
      final StickerSheet sheet = StickerSheet(StickerPage.a4, sizeMm: mm);
      expect(printedModuleMm(scene, sheet), closeTo(share * mm, 1e-9));
    }
    // A door's code: too small at 4 cm, fine at 15 cm, and
    // the largest on A4 is fine.
    double at(int mm) =>
        printedModuleMm(scene, StickerSheet(StickerPage.a4, sizeMm: mm));
    expect(ModuleSize.of(at(40)), ModuleSize.tiny);
    expect(ModuleSize.of(at(150)), ModuleSize.fine);
    expect(
      ModuleSize.of(printedModuleMm(scene, StickerSheet(StickerPage.a4))),
      ModuleSize.fine,
    );
    // The short install link has larger dots at the same size.
    final StickerScene install = StickerScene.build(
      StickerScene.matrixFor(kInstallPageUrl, design),
      design,
    );
    expect(install.matrix.size, lessThan(grid));
    expect(
      printedModuleMm(install, StickerSheet(StickerPage.a4, sizeMm: 40)),
      greaterThan(at(40)),
    );
  });

  test('the PDF has a valid structure, the page size in points and the '
      'picture at 300 dpi', () async {
    const StickerDesign design = StickerDesign(texts: _texts);
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(kDonationUrl, design),
      design,
    );
    final Uint8List pdf = await exportSticker(scene, design);
    _expectValidPdf(pdf, widthPt: '595.28', heightPt: '841.89');
    final String text = latin1.decode(pdf);
    final StickerSheet a4 = StickerSheet(StickerPage.a4);
    expect(text, contains('/Width ${a4.sidePx} /Height ${a4.sidePx}'));
    // The square, centred: 12 mm from the sides.
    final double side = StickerSheet.pt(a4.sideMm);
    expect(
      text,
      contains('${side.toStringAsFixed(2)} 0 0 ${side.toStringAsFixed(2)} '),
    );
    // 8 cutting marks.
    expect(RegExp(r' l S\n').allMatches(text), hasLength(8));

    final Uint8List letter = await exportSticker(
      scene,
      design.copyWith(page: StickerPage.letter, landscape: true),
    );
    _expectValidPdf(letter, widthPt: '792', heightPt: '612');
  });

  test('a small PDF built by hand reads back', () {
    final Uint8List pdf = buildStickerPdf(
      widthPt: 100,
      heightPt: 50.5,
      rgb: Uint8List(2 * 2 * 3),
      pixelsWide: 2,
      pixelsHigh: 2,
      imagePlacesPt: const <(double, double)>[(10, 5)],
      imageSidePt: 40,
      lines: const <(double, double, double, double)>[(0, 0, 5, 0)],
    );
    _expectValidPdf(pdf, widthPt: '100', heightPt: '50.5');
    expect(latin1.decode(pdf), contains('40 0 0 40 10 5.5 cm'));
    // One picture, placed twice.
    final String twice = latin1.decode(
      buildStickerPdf(
        widthPt: 100,
        heightPt: 50.5,
        rgb: Uint8List(2 * 2 * 3),
        pixelsWide: 2,
        pixelsHigh: 2,
        imagePlacesPt: const <(double, double)>[(5, 5), (55, 5)],
        imageSidePt: 40,
      ),
    );
    expect(twice, contains('40 0 0 40 5 5.5 cm\n/Im0 Do'));
    expect(twice, contains('40 0 0 40 55 5.5 cm\n/Im0 Do'));
    expect(RegExp('/Subtype /Image').allMatches(twice), hasLength(1));
    expect(
      () => buildStickerPdf(
        widthPt: 1,
        heightPt: 1,
        rgb: Uint8List(5),
        pixelsWide: 2,
        pixelsHigh: 2,
        imagePlacesPt: const <(double, double)>[(0, 0)],
        imageSidePt: 1,
      ),
      throwsArgumentError,
    );
  });

  test('PNG and JPG come at the page size, SVG at the page size in mm with '
      'the texts', () async {
    const StickerDesign design = StickerDesign(
      texts: _texts,
      page: StickerPage.sticker,
      pattern: StickerPattern.hearts,
      style: QrStyle.rounded,
    );
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(kDonationUrl, design),
      design,
    );
    final Uint8List png = await exportSticker(
      scene,
      design,
      format: StickerFormat.png,
    );
    expect(png.sublist(0, 4), <int>[0x89, 0x50, 0x4E, 0x47]);
    final ui.ImmutableBuffer pngBuffer = await ui.ImmutableBuffer.fromUint8List(
      png,
    );
    final ui.ImageDescriptor pngInfo = await ui.ImageDescriptor.encoded(
      pngBuffer,
    );
    expect((pngInfo.width, pngInfo.height), (1181, 1181));

    final Uint8List jpg = await exportSticker(
      scene,
      design.copyWith(page: StickerPage.wallpaper),
      format: StickerFormat.jpg,
    );
    expect(jpg.sublist(0, 3), <int>[0xFF, 0xD8, 0xFF]);
    final LumaFrame? wall = lumaFromImage(jpg, maxWidth: 1080);
    expect((wall!.width, wall.height), (1080, 2340));
    expect(decodeQrLuma(wall), kDonationUrl);

    final String svg = utf8.decode(
      await exportSticker(scene, design, format: StickerFormat.svg),
    );
    expect(svg, contains('width="100mm" height="100mm"'));
    expect(svg, contains('Dom Kowalskich'));
    expect(svg, contains('>Zeskanuj QR, aby nas poznać</text>'));
    expect(svg.trimRight(), endsWith('</svg>'));
  });

  test('the designs keep their choices through a save', () {
    const StickerDesign design = StickerDesign(
      texts: _texts,
      signature: false,
      style: QrStyle.dots,
      theme: StickerTheme.forest,
      pattern: StickerPattern.leaves,
      logo: true,
      page: StickerPage.letter,
      landscape: true,
      cropMarks: false,
      format: StickerFormat.svg,
      sizeMm: 60,
      tile: true,
    );
    expect(
      StickerDesign.fromJson(jsonDecode(jsonEncode(design.toJson())) as Map),
      design,
    );
    expect(
      StickerDesign.fromJson(const <String, Object>{}),
      const StickerDesign(),
    );
    expect(
      StickerDesign.fromJson(<String, Object>{
        'top': 'x' * 500,
        'style': 'nope',
        'logo': 'yes',
      }),
      StickerDesign(texts: StickerTexts(top: 'x' * StickerDesign.maxText)),
    );
  });

  test('presets: every kind has ready texts, the name goes in, and texts '
      'that need a name wait for one', () {
    for (final StickerKind kind in StickerKind.values) {
      expect(stickerPresets(kind), isNotEmpty, reason: kind.name);
      expect(StickerDesign.initial(kind).texts, stickerPresets(kind).first);
      for (final StickerTexts p in stickerPresets(kind, name: 'Kowalscy')) {
        expect('${p.top}${p.caption}${p.bottom}', isNot(contains('{')));
      }
    }
    final List<StickerTexts> door = stickerPresets(
      StickerKind.door,
      name: 'Dom Kowalskich',
    );
    expect(door.first.top, 'Dom Kowalskich');
    expect(door.first.bottom, 'Zeskanuj, żeby nas poznać');
    expect(
      door.map((StickerTexts p) => p.bottom),
      contains('Dom Kowalskich — zeskanuj QR, aby nas poznać'),
    );
    // Without a name only the texts that need none.
    expect(door, hasLength(5));
    expect(stickerPresets(StickerKind.door), hasLength(2));
    expect(
      stickerPresets(StickerKind.friendInvite, name: 'Ada').first,
      const StickerTexts(top: 'Ada', bottom: 'Dodaj mnie w Zen'),
    );
    expect(
      stickerPresets(StickerKind.zenAbout).map((StickerTexts p) => p.bottom),
      contains('Prywatna sieć społecznościowa — zeskanuj'),
    );
  });

  test('a pebble\'s sticker puts the code on a stone labelled "kamyczek '
      'Zen", around the quiet zone and clear of every text', () {
    final String link = _pebbleLink();
    for (final StickerTexts texts in <StickerTexts>[
      const StickerTexts(),
      stickerPresets(StickerKind.pebble).first,
      _texts,
      const StickerTexts(
        top: 'Bardzo długi napis na górze naklejki, który musi się zmieścić',
        bottom:
            'Kasia zostawiła tu kamyczek, zeskanuj go i zbierz, nikomu go '
            'nie zabierasz',
      ),
    ]) {
      for (final StickerTheme theme in StickerTheme.values) {
        final StickerDesign design = StickerDesign(
          texts: texts,
          theme: theme,
          pattern: StickerPattern.values[theme.index % 7],
        );
        final StickerScene scene = StickerScene.build(
          StickerScene.matrixFor(link, design),
          design,
          kind: StickerKind.pebble,
        );
        final PebbleStone stone = scene.stone!;
        final Rect quiet = scene.quietRect;
        final String what = '${theme.name} "${texts.top}"';
        // The whole quiet zone lies on the stone, inside its rim.
        for (final Offset corner in <Offset>[
          quiet.topLeft,
          quiet.topRight,
          quiet.bottomLeft,
          quiet.bottomRight,
        ]) {
          expect(stone.contains(corner, inside: true), isTrue, reason: what);
        }
        // The label and its little stone: under the code, on the stone.
        final List<StickerShape> mark = scene.withRole(ShapeRole.mark).toList();
        expect(mark, hasLength(4), reason: what);
        for (final StickerShape s in mark) {
          expect(s.bounds.top, greaterThanOrEqualTo(quiet.bottom));
          for (final Offset corner in <Offset>[
            s.bounds.topLeft,
            s.bounds.topRight,
            s.bounds.bottomLeft,
            s.bounds.bottomRight,
          ]) {
            expect(stone.contains(corner, inside: true), isTrue, reason: what);
          }
        }
        final StickerText label = mark.whereType<StickerText>().single;
        expect(label.text, 'Kamyk Zen');
        expect(label.lines.single.text, 'Kamyk Zen', reason: 'not cut');
        expect(label.size, greaterThanOrEqualTo(24), reason: what);
        // The label says "Zen": no signature in the corner.
        expect(design.signature, isTrue);
        expect(scene.withRole(ShapeRole.signature), isEmpty);
        for (final StickerShape t in scene.withRole(ShapeRole.text)) {
          expect(t.bounds.overlaps(stone.bounds), isFalse, reason: what);
        }
        // The label reads on the stone.
        expect(
          QrMatrix.contrast(theme.ink, theme.accentSoft),
          greaterThanOrEqualTo(4.5),
          reason: theme.name,
        );
      }
    }
    // Only a pebble's sticker has it.
    const StickerDesign plain = StickerDesign(texts: _texts);
    final StickerScene door = StickerScene.build(
      StickerScene.matrixFor(link, plain),
      plain,
      kind: StickerKind.door,
    );
    expect(door.stone, isNull);
    expect(door.withRole(ShapeRole.frame), isEmpty);
    expect(door.withRole(ShapeRole.mark), isEmpty);
    expect(door.withRole(ShapeRole.signature), hasLength(2));
  });

  test('a pebble\'s code keeps modules a camera reads on a 5 cm sticker', () {
    final StickerDesign design = StickerDesign(
      texts: stickerPresets(StickerKind.pebble).first,
    );
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(_pebbleLink(), design),
      design,
      kind: StickerKind.pebble,
    );
    // The artwork 50 mm across: a module of 0.4 mm or more (the QR card;
    // the whole signed card of the first builds made about 0.26 mm).
    expect(scene.module / StickerScene.side * 50, greaterThanOrEqualTo(0.4));
  });

  test("a door's code keeps modules a camera reads on a 5 cm sticker", () {
    // Six mailbox doors, as a phone has: link format 2 in digits (the JSON
    // of 1.14's stickers made about 0.29 mm).
    final FlatDoorCode door = _door(kDoorSlots);
    expect(door.toLink(), endsWith('#${door.linkCode}'));
    final StickerDesign design = StickerDesign(
      texts: stickerPresets(StickerKind.door).first,
    );
    final StickerScene scene = StickerScene.build(
      StickerScene.matrixFor(door.toLink(), design),
      design,
      kind: StickerKind.door,
    );
    expect(scene.module / StickerScene.side * 50, greaterThanOrEqualTo(0.38));
  });

  test('a pebble\'s ready texts: the owner\'s, with its name and author when '
      'there are', () {
    expect(stickerPresets(StickerKind.pebble), const <StickerTexts>[
      StickerTexts(
        top: 'Znalazłeś kamyczek!',
        bottom: 'Zeskanuj, żeby go zebrać',
      ),
    ]);
    expect(
      stickerPresets(
        StickerKind.pebble,
        name: ' Biedronka ',
        author: 'Kasia',
      ).map((StickerTexts p) => p.bottom),
      <String>[
        'Zeskanuj, żeby go zebrać',
        'Kamyczek Biedronka — zeskanuj i zbierz',
        'Kasia zostawił(a) tu kamyczek',
      ],
    );
    expect(StickerKind.pebble.fileStem, 'zen-kamyczek');
    expect(StickerKind.pebble.keepsTexts, isFalse);
    expect(
      <StickerKind>[
        for (final StickerKind k in StickerKind.values)
          if (k.pebbleMark) k,
      ],
      <StickerKind>[StickerKind.pebble],
    );
  });

  // CI decodes these pictures again with another decoder (zbar), which
  // also reads them on the phones' cameras' terms: every style of every
  // kind, as printed (tool/ci/decode_qr_stickers.py).
  test('writes the pictures for the CI decoder when asked', () async {
    final String? folder = Platform.environment['ZEN_QR_STICKER_OUT'];
    if (folder == null || folder.isEmpty) {
      return;
    }
    final Directory out = Directory(folder)..createSync(recursive: true);
    final Map<String, String> expected = <String, String>{};
    for (final MapEntry<StickerKind, String> e in _payloads().entries) {
      for (final QrStyle style in QrStyle.values) {
        for (final bool logo in <bool>[false, true]) {
          final StickerDesign design = StickerDesign(
            texts: _texts,
            style: style,
            logo: logo,
            page: StickerPage.sticker,
            pattern: StickerPattern.values[(style.index + 1) % 7],
            theme:
                StickerTheme.values[style.index % StickerTheme.values.length],
          );
          final StickerScene scene = StickerScene.build(
            StickerScene.matrixFor(e.value, design),
            design,
            kind: e.key,
          );
          final String name =
              '${e.key.name}-${style.name}${logo ? '-logo' : ''}.png';
          File('${out.path}/$name').writeAsBytesSync(
            await exportSticker(scene, design, format: StickerFormat.png),
          );
          expected[name] = e.value;
        }
      }
    }
    File(
      '${out.path}/expected.json',
    ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(expected));
  });
}

/// [pdf] starts and ends like a PDF, its cross-reference table points at
/// every object, and its page is [widthPt] × [heightPt].
void _expectValidPdf(
  Uint8List pdf, {
  required String widthPt,
  required String heightPt,
}) {
  final String text = latin1.decode(pdf);
  expect(text, startsWith('%PDF-1.4\n'));
  expect(text.trimRight(), endsWith('%%EOF'));
  final Match start = RegExp(r'startxref\n(\d+)\n%%EOF').firstMatch(text)!;
  final int xref = int.parse(start.group(1)!);
  expect(text.substring(xref, xref + 5), 'xref\n');
  final Match head = RegExp(r'xref\n0 (\d+)\n').matchAsPrefix(text, xref)!;
  final int count = int.parse(head.group(1)!);
  final List<String> rows = text
      .substring(head.end)
      .split('\n')
      .take(count)
      .toList();
  expect(rows.first, '0000000000 65535 f ');
  for (int i = 1; i < count; i++) {
    expect(rows[i], matches(RegExp(r'^\d{10} 00000 n $')));
    final int offset = int.parse(rows[i].substring(0, 10));
    expect(text.substring(offset), startsWith('$i 0 obj\n'), reason: 'obj $i');
  }
  expect(text, contains('/Size $count /Root 1 0 R'));
  expect(text, contains('/MediaBox [0 0 $widthPt $heightPt]'));
  // Each stream is as long as it says.
  for (final Match m in RegExp(
    r'/Length (\d+)[^>]*>>\nstream\n',
  ).allMatches(text)) {
    final int length = int.parse(m.group(1)!);
    expect(text.substring(m.end + length, m.end + length + 10), '\nendstream');
  }
}
