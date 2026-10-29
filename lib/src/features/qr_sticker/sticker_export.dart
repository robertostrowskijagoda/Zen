import 'dart:convert';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/qr_sticker/sticker_design.dart';
import 'package:zen/src/features/qr_sticker/sticker_pdf.dart';
import 'package:zen/src/features/qr_sticker/sticker_scene.dart';

/// Print resolution of the exports.
const double kStickerDpi = 300;

/// One copy of the artwork on a [StickerSheet]: its top left corner in
/// millimetres and in pixels at [kStickerDpi].
typedef StickerTile = ({double leftMm, double topMm, int leftPx, int topPx});

/// A page of [page] (turned with [landscape]) and where the square artwork
/// sits on it: [sizeMm] across (see [StickerDesign.sizeMm]), centred both
/// ways, so cutting along the square leaves the whole sticker. With [tile]
/// a paper page carries as many copies as it holds in rows,
/// [StickerSheet.tileGapMm] apart, the whole grid centred (one copy when
/// fewer than two fit).
final class StickerSheet {
  factory StickerSheet(
    StickerPage page, {
    bool landscape = false,
    int sizeMm = StickerDesign.largest,
    bool tile = false,
  }) {
    final bool turn = landscape && page.hasOrientation;
    final double w = turn ? page.heightMm : page.widthMm;
    final double h = turn ? page.widthMm : page.heightMm;
    final int wPx;
    final int hPx;
    if (page == StickerPage.wallpaper) {
      wPx = turn ? 2340 : 1080;
      hPx = turn ? 1080 : 2340;
    } else {
      wPx = _px(w);
      hPx = _px(h);
    }
    final bool chosen = sizesMm(page).contains(sizeMm);
    final double sideMm = chosen ? sizeMm.toDouble() : largestSideMm(page);
    final int sidePx = math.min(_px(sideMm), math.min(wPx, hPx));

    int cols = 1;
    int rows = 1;
    if (tile && chosen && page.hasMargins) {
      int fit(double length) =>
          ((length - 2 * paperMarginMm + tileGapMm) / (sideMm + tileGapMm) +
                  1e-9)
              .floor();
      cols = math.max(1, fit(w));
      rows = math.max(1, fit(h));
      if (cols * rows < 2) {
        cols = rows = 1;
      }
    }
    final int gapPx = _px(tileGapMm);
    final double gridWMm = cols * sideMm + (cols - 1) * tileGapMm;
    final double gridHMm = rows * sideMm + (rows - 1) * tileGapMm;
    final int gridWPx = cols * sidePx + (cols - 1) * gapPx;
    final int gridHPx = rows * sidePx + (rows - 1) * gapPx;
    final double leftMm = (w - gridWMm) / 2;
    final double topMm = (h - gridHMm) / 2;
    final int leftPx = (wPx - gridWPx) ~/ 2;
    final int topPx = (hPx - gridHPx) ~/ 2;
    return StickerSheet._(
      page: page,
      widthMm: w,
      heightMm: h,
      widthPx: wPx,
      heightPx: hPx,
      sideMm: sideMm,
      sidePx: sidePx,
      largest: !chosen,
      columns: cols,
      rows: rows,
      tiles: <StickerTile>[
        for (int r = 0; r < rows; r++)
          for (int c = 0; c < cols; c++)
            (
              leftMm: leftMm + c * (sideMm + tileGapMm),
              topMm: topMm + r * (sideMm + tileGapMm),
              leftPx: leftPx + c * (sidePx + gapPx),
              topPx: topPx + r * (sidePx + gapPx),
            ),
      ],
    );
  }

  /// The page [design] chose, at its size, tiled when it asks.
  factory StickerSheet.of(StickerDesign design) => StickerSheet(
    design.page,
    landscape: design.landscape,
    sizeMm: design.sizeMm,
    tile: design.tile,
  );

  StickerSheet._({
    required this.page,
    required this.widthMm,
    required this.heightMm,
    required this.widthPx,
    required this.heightPx,
    required this.sideMm,
    required this.sidePx,
    required this.largest,
    required this.columns,
    required this.rows,
    required this.tiles,
  });

  /// The printer's edge on paper formats (most printers leave 3–5 mm).
  static const double paperMarginMm = 12;

  /// Between copies on a tiled page: room for a cut on each side.
  static const double tileGapMm = 5;

  static int _px(double mm) => (mm / 25.4 * kStickerDpi).round();

  /// The side of the largest artwork [page] holds (the same either way
  /// round): within the margins on paper, the whole of a sticker format.
  static double largestSideMm(StickerPage page) {
    final double short = math.min(page.widthMm, page.heightMm);
    return switch (page) {
      StickerPage.a4 ||
      StickerPage.a5 ||
      StickerPage.letter => short - 2 * paperMarginMm,
      StickerPage.square || StickerPage.sticker => short,
      StickerPage.wallpaper => short * 0.86,
    };
  }

  /// The sizes of [StickerDesign.sizesMm] smaller than the largest artwork
  /// [page] holds (a wallpaper has none).
  static List<int> sizesMm(StickerPage page) {
    if (!page.sizable) {
      return const <int>[];
    }
    final double largest = largestSideMm(page);
    return <int>[
      for (final int mm in StickerDesign.sizesMm)
        if (mm < largest - 1e-9) mm,
    ];
  }

  final StickerPage page;
  final double widthMm;
  final double heightMm;
  final int widthPx;
  final int heightPx;
  final double sideMm;
  final int sidePx;

  /// The artwork is the largest the page holds.
  final bool largest;
  final int columns;
  final int rows;

  /// Every copy, row by row from the top left (one unless tiled).
  final List<StickerTile> tiles;

  /// The first copy (the only one unless tiled).
  double get leftMm => tiles.first.leftMm;
  double get topMm => tiles.first.topMm;
  int get leftPx => tiles.first.leftPx;
  int get topPx => tiles.first.topPx;

  /// Points (1/72 inch), for the PDF.
  static double pt(double mm) => mm / 25.4 * 72;

  /// The cutting marks for [cropMarks], in millimetres from the top left:
  /// short lines in the margin, in line with every edge of the copies, and
  /// on a tiled page the same lines across the gaps between them (never on
  /// a copy).
  List<(double, double, double, double)> marks(bool cropMarks) {
    if (!cropMarks || !page.hasMargins) {
      return const <(double, double, double, double)>[];
    }
    const double near = 2;
    const double far = 9;
    const double inset = 1;
    final List<double> xs = <double>[
      for (int c = 0; c < columns; c++) ...<double>[
        tiles[c].leftMm,
        tiles[c].leftMm + sideMm,
      ],
    ];
    final List<double> ys = <double>[
      for (int r = 0; r < rows; r++) ...<double>[
        tiles[r * columns].topMm,
        tiles[r * columns].topMm + sideMm,
      ],
    ];
    final double l = xs.first;
    final double r = xs.last;
    final double t = ys.first;
    final double b = ys.last;
    return <(double, double, double, double)>[
      for (final double y in ys) ...<(double, double, double, double)>[
        (l - far, y, l - near, y),
        (r + near, y, r + far, y),
      ],
      for (final double x in xs) ...<(double, double, double, double)>[
        (x, t - far, x, t - near),
        (x, b + near, x, b + far),
      ],
      // Across the gaps: from the end of one copy to the start of the next.
      for (final double x in xs)
        for (int g = 1; g < ys.length - 1; g += 2)
          (x, ys[g] + inset, x, ys[g + 1] - inset),
      for (final double y in ys)
        for (int g = 1; g < xs.length - 1; g += 2)
          (xs[g] + inset, y, xs[g + 1] - inset, y),
    ];
  }
}

/// How the printed code's modules (its "dots") come out for a camera.
enum ModuleSize {
  /// Every camera reads it.
  fine,

  /// Most cameras read it; a larger print reads more surely.
  small,

  /// Too small for many cameras.
  tiny;

  /// Below this a module is [tiny].
  static const double tinyBelowMm = 0.5;

  /// Below this (and from [tinyBelowMm]) a module is [small].
  static const double smallBelowMm = 0.7;

  static ModuleSize of(double moduleMm) => moduleMm < tinyBelowMm
      ? tiny
      : moduleMm < smallBelowMm
      ? small
      : fine;
}

/// The side of one module of [scene]'s code printed on [sheet], in
/// millimetres.
double printedModuleMm(StickerScene scene, StickerSheet sheet) =>
    scene.module / StickerScene.side * sheet.sideMm;

/// [ops] as a [Path] (overlapping parts fill once).
Path stickerPath(List<PathOp> ops) {
  final Path path = Path();
  for (final PathOp op in ops) {
    switch (op) {
      case MoveOp(:final double x, :final double y):
        path.moveTo(x, y);
      case LineOp(:final double x, :final double y):
        path.lineTo(x, y);
      case CubicOp():
        path.cubicTo(op.x1, op.y1, op.x2, op.y2, op.x, op.y);
      case CloseOp():
        path.close();
      case RectOp(:final Rect rect, :final double radius):
        if (radius <= 0) {
          path.addRect(rect);
        } else {
          path.addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));
        }
      case CircleOp(:final Offset center, :final double radius):
        path.addOval(Rect.fromCircle(center: center, radius: radius));
    }
  }
  return path;
}

/// Paints [scene] on [canvas], one scene unit to one canvas unit.
void paintStickerScene(Canvas canvas, StickerScene scene) {
  for (final StickerShape shape in scene.shapes) {
    switch (shape) {
      case StickerPath(:final int color, :final List<PathOp> ops):
        canvas.drawPath(
          stickerPath(ops),
          Paint()
            ..color = Color(color)
            ..isAntiAlias = true,
        );
      case StickerText():
        final TextPainter painter = shape.painter();
        painter.paint(canvas, shape.bounds.topLeft);
        painter.dispose();
    }
  }
}

/// The sticker's artwork alone, [sidePx] square.
Future<ui.Image> renderStickerArtwork(StickerScene scene, int sidePx) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.scale(sidePx / StickerScene.side);
  paintStickerScene(canvas, scene);
  final ui.Picture picture = recorder.endRecording();
  return picture.toImage(sidePx, sidePx).whenComplete(picture.dispose);
}

/// The whole page of [sheet]: white, the artwork in the middle (every copy
/// on a tiled page) and, when asked, the cutting marks.
Future<ui.Image> renderStickerSheet(
  StickerScene scene,
  StickerSheet sheet, {
  bool cropMarks = true,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  paintStickerPage(
    Canvas(recorder),
    scene,
    sheet,
    perMm: kStickerDpi / 25.4,
    cropMarks: cropMarks,
    printPixels: true,
  );
  final ui.Picture picture = recorder.endRecording();
  return picture
      .toImage(sheet.widthPx, sheet.heightPx)
      .whenComplete(picture.dispose);
}

/// Paints the page of [sheet] on [canvas] at [perMm] canvas units a
/// millimetre: the paper, the cutting marks for [cropMarks] and every copy
/// of [scene]. [printPixels] puts the copies on the export's whole pixels
/// ([perMm] being [kStickerDpi] in 25.4 mm then).
void paintStickerPage(
  Canvas canvas,
  StickerScene scene,
  StickerSheet sheet, {
  required double perMm,
  bool cropMarks = true,
  bool printPixels = false,
}) {
  canvas.drawRect(
    Rect.fromLTWH(0, 0, sheet.widthMm * perMm, sheet.heightMm * perMm),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final Paint line = Paint()
    ..color = const Color(0xFF8C8C8C)
    ..strokeWidth = 0.25 * perMm;
  for (final (double x1, double y1, double x2, double y2) in sheet.marks(
    cropMarks,
  )) {
    canvas.drawLine(
      Offset(x1 * perMm, y1 * perMm),
      Offset(x2 * perMm, y2 * perMm),
      line,
    );
  }
  // The artwork is drawn once and placed on every copy.
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  paintStickerScene(Canvas(recorder), scene);
  final ui.Picture art = recorder.endRecording();
  final double side = printPixels
      ? sheet.sidePx.toDouble()
      : sheet.sideMm * perMm;
  for (final StickerTile tile in sheet.tiles) {
    canvas
      ..save()
      ..translate(
        printPixels ? tile.leftPx.toDouble() : tile.leftMm * perMm,
        printPixels ? tile.topPx.toDouble() : tile.topMm * perMm,
      )
      ..clipRect(Rect.fromLTWH(0, 0, side, side))
      ..scale(side / StickerScene.side)
      ..drawPicture(art)
      ..restore();
  }
  art.dispose();
}

/// [scene] as a file of [format] on the page [design] chose, at its size
/// and, when it asks, in as many copies as the page holds.
Future<Uint8List> exportSticker(
  StickerScene scene,
  StickerDesign design, {
  StickerFormat? format,
}) async {
  final StickerSheet sheet = StickerSheet.of(design);
  switch (format ?? design.format) {
    case StickerFormat.svg:
      return utf8.encode(stickerSvg(scene, sheet, cropMarks: design.cropMarks));
    case StickerFormat.pdf:
      final ui.Image art = await renderStickerArtwork(scene, sheet.sidePx);
      final ByteData? rgba = await art.toByteData();
      art.dispose();
      if (rgba == null) {
        throw StateError('The sticker could not be drawn');
      }
      final int side = sheet.sidePx;
      final TransferableTypedData pixels = TransferableTypedData.fromList(
        <TypedData>[rgba],
      );
      final double scale = 72 / 25.4;
      final List<(double, double, double, double)> marks =
          <(double, double, double, double)>[
            for (final (double x1, double y1, double x2, double y2)
                in sheet.marks(design.cropMarks))
              (x1 * scale, y1 * scale, x2 * scale, y2 * scale),
          ];
      final List<(double, double)> places = <(double, double)>[
        for (final StickerTile tile in sheet.tiles)
          (StickerSheet.pt(tile.leftMm), StickerSheet.pt(tile.topMm)),
      ];
      return Isolate.run(() {
        final Uint8List from = pixels.materialize().asUint8List();
        final Uint8List rgb = Uint8List(side * side * 3);
        for (int i = 0, j = 0; j < rgb.length; i += 4, j += 3) {
          rgb[j] = from[i];
          rgb[j + 1] = from[i + 1];
          rgb[j + 2] = from[i + 2];
        }
        return buildStickerPdf(
          widthPt: StickerSheet.pt(sheet.widthMm),
          heightPt: StickerSheet.pt(sheet.heightMm),
          rgb: rgb,
          pixelsWide: side,
          pixelsHigh: side,
          imagePlacesPt: places,
          imageSidePt: StickerSheet.pt(sheet.sideMm),
          lines: marks,
        );
      });
    case StickerFormat.png:
      final ui.Image page = await renderStickerSheet(
        scene,
        sheet,
        cropMarks: design.cropMarks,
      );
      final ByteData? png = await page.toByteData(
        format: ui.ImageByteFormat.png,
      );
      page.dispose();
      if (png == null) {
        throw StateError('The sticker could not be drawn');
      }
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    case StickerFormat.jpg:
      final ui.Image page = await renderStickerSheet(
        scene,
        sheet,
        cropMarks: design.cropMarks,
      );
      final int w = page.width;
      final int h = page.height;
      final ByteData? rgba = await page.toByteData();
      page.dispose();
      if (rgba == null) {
        throw StateError('The sticker could not be drawn');
      }
      final TransferableTypedData pixels = TransferableTypedData.fromList(
        <TypedData>[rgba],
      );
      return Isolate.run(() {
        final img.Image picture = img.Image.fromBytes(
          width: w,
          height: h,
          bytes: pixels.materialize(),
          numChannels: 4,
        );
        return img.encodeJpg(picture, quality: 92);
      });
  }
}

/// [scene] on the page of [sheet] as SVG: the code and the drawings as
/// shapes, the texts as text (in the app's fonts where the viewer has
/// them).
String stickerSvg(
  StickerScene scene,
  StickerSheet sheet, {
  bool cropMarks = true,
}) {
  final StringBuffer out = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" '
      'xmlns:xlink="http://www.w3.org/1999/xlink" '
      'width="${_n(sheet.widthMm)}mm" height="${_n(sheet.heightMm)}mm" '
      'viewBox="0 0 ${_n(sheet.widthMm)} ${_n(sheet.heightMm)}">',
    )
    ..writeln(
      '<rect width="${_n(sheet.widthMm)}" height="${_n(sheet.heightMm)}" '
      'fill="#ffffff"/>',
    );
  for (final (double x1, double y1, double x2, double y2) in sheet.marks(
    cropMarks,
  )) {
    out.writeln(
      '<line x1="${_n(x1)}" y1="${_n(y1)}" x2="${_n(x2)}" y2="${_n(y2)}" '
      'stroke="#8c8c8c" stroke-width="0.25"/>',
    );
  }
  final String scale = (sheet.sideMm / StickerScene.side).toStringAsFixed(5);
  // A tiled page draws the artwork once and places it on every copy.
  final bool tiled = sheet.tiles.length > 1;
  out.writeln(
    tiled
        ? '<defs><g id="sticker" transform="scale($scale)">'
        : '<g transform="translate(${_n(sheet.leftMm)} ${_n(sheet.topMm)}) '
              'scale($scale)">',
  );
  for (final StickerShape shape in scene.shapes) {
    switch (shape) {
      case StickerPath(:final int color, :final List<PathOp> ops):
        out.writeln('<path fill="${_hex(color)}" d="${_d(ops)}"/>');
      case StickerText():
        final String family = shape.family == kStickerDisplayFont
            ? "'Baloo 2', 'Hanken Grotesk', sans-serif"
            : "'Hanken Grotesk', sans-serif";
        for (final StickerTextLine line in shape.lines) {
          out.writeln(
            '<text x="${_n(shape.bounds.left + line.left + line.width / 2)}" '
            'y="${_n(shape.bounds.top + line.baseline)}" '
            'text-anchor="middle" font-family="$family" '
            'font-size="${_n(shape.size)}" font-weight="${shape.weight}" '
            'fill="${_hex(shape.color)}">${_escape(line.text)}</text>',
          );
        }
    }
  }
  out.writeln(tiled ? '</g></defs>' : '</g>');
  if (tiled) {
    for (final StickerTile tile in sheet.tiles) {
      out.writeln(
        '<use xlink:href="#sticker" href="#sticker" '
        'x="${_n(tile.leftMm)}" y="${_n(tile.topMm)}"/>',
      );
    }
  }
  out.writeln('</svg>');
  return out.toString();
}

String _d(List<PathOp> ops) {
  final StringBuffer d = StringBuffer();
  void box(Rect r, double radius) {
    final double k = math.min(radius, math.min(r.width, r.height) / 2);
    if (k <= 0) {
      d.write(
        'M${_n(r.left)} ${_n(r.top)}h${_n(r.width)}v${_n(r.height)}'
        'h${_n(-r.width)}z',
      );
      return;
    }
    final String a = 'a${_n(k)} ${_n(k)} 0 0 1';
    d.write(
      'M${_n(r.left + k)} ${_n(r.top)}h${_n(r.width - 2 * k)}'
      '$a ${_n(k)} ${_n(k)}v${_n(r.height - 2 * k)}'
      '$a ${_n(-k)} ${_n(k)}h${_n(-(r.width - 2 * k))}'
      '$a ${_n(-k)} ${_n(-k)}v${_n(-(r.height - 2 * k))}'
      '$a ${_n(k)} ${_n(-k)}z',
    );
  }

  for (final PathOp op in ops) {
    switch (op) {
      case MoveOp(:final double x, :final double y):
        d.write('M${_n(x)} ${_n(y)}');
      case LineOp(:final double x, :final double y):
        d.write('L${_n(x)} ${_n(y)}');
      case CubicOp():
        d.write(
          'C${_n(op.x1)} ${_n(op.y1)} ${_n(op.x2)} ${_n(op.y2)} '
          '${_n(op.x)} ${_n(op.y)}',
        );
      case CloseOp():
        d.write('z');
      case RectOp(:final Rect rect, :final double radius):
        box(rect, radius);
      case CircleOp(:final Offset center, :final double radius):
        final String r = _n(radius);
        d.write(
          'M${_n(center.dx - radius)} ${_n(center.dy)}'
          'a$r $r 0 1 0 ${_n(2 * radius)} 0'
          'a$r $r 0 1 0 ${_n(-2 * radius)} 0z',
        );
    }
  }
  return d.toString();
}

String _hex(int argb) =>
    '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _n(double v) {
  final String s = v.toStringAsFixed(2);
  final String trimmed = s.replaceFirst(RegExp(r'\.?0+$'), '');
  return trimmed == '-0' ? '0' : trimmed;
}
