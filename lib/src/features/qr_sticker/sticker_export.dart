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

/// A page of [page] (turned with [landscape]) and where the square artwork
/// sits on it: centred both ways, so cutting along the square leaves the
/// whole sticker.
final class StickerSheet {
  factory StickerSheet(StickerPage page, {bool landscape = false}) {
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
    final double short = math.min(w, h);
    final double sideMm = switch (page) {
      StickerPage.a4 ||
      StickerPage.a5 ||
      StickerPage.letter => short - 2 * paperMarginMm,
      StickerPage.square || StickerPage.sticker => short,
      StickerPage.wallpaper => short * 0.86,
    };
    final int sidePx = math.min(_px(sideMm), math.min(wPx, hPx));
    return StickerSheet._(
      page: page,
      widthMm: w,
      heightMm: h,
      widthPx: wPx,
      heightPx: hPx,
      sideMm: sideMm,
      sidePx: sidePx,
      leftPx: (wPx - sidePx) ~/ 2,
      topPx: (hPx - sidePx) ~/ 2,
    );
  }

  StickerSheet._({
    required this.page,
    required this.widthMm,
    required this.heightMm,
    required this.widthPx,
    required this.heightPx,
    required this.sideMm,
    required this.sidePx,
    required this.leftPx,
    required this.topPx,
  });

  /// The printer's edge on paper formats (most printers leave 3–5 mm).
  static const double paperMarginMm = 12;

  static int _px(double mm) => (mm / 25.4 * kStickerDpi).round();

  final StickerPage page;
  final double widthMm;
  final double heightMm;
  final int widthPx;
  final int heightPx;
  final double sideMm;
  final int sidePx;
  final int leftPx;
  final int topPx;

  double get leftMm => (widthMm - sideMm) / 2;
  double get topMm => (heightMm - sideMm) / 2;

  /// Points (1/72 inch), for the PDF.
  static double pt(double mm) => mm / 25.4 * 72;

  /// The cutting marks for [cropMarks], in millimetres from the top left:
  /// short lines in the margin, in line with the square's edges.
  List<(double, double, double, double)> marks(bool cropMarks) {
    if (!cropMarks || !page.hasMargins) {
      return const <(double, double, double, double)>[];
    }
    const double near = 2;
    const double far = 9;
    final double l = leftMm;
    final double t = topMm;
    final double r = l + sideMm;
    final double b = t + sideMm;
    return <(double, double, double, double)>[
      for (final double y in <double>[
        t,
        b,
      ]) ...<(double, double, double, double)>[
        (l - far, y, l - near, y),
        (r + near, y, r + far, y),
      ],
      for (final double x in <double>[
        l,
        r,
      ]) ...<(double, double, double, double)>[
        (x, t - far, x, t - near),
        (x, b + near, x, b + far),
      ],
    ];
  }
}

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

/// The whole page of [sheet]: white, the artwork in the middle and, when
/// asked, the cutting marks.
Future<ui.Image> renderStickerSheet(
  StickerScene scene,
  StickerSheet sheet, {
  bool cropMarks = true,
}) {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final Canvas canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, sheet.widthPx.toDouble(), sheet.heightPx.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  final double perMm = kStickerDpi / 25.4;
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
  canvas
    ..save()
    ..translate(sheet.leftPx.toDouble(), sheet.topPx.toDouble())
    ..clipRect(
      Rect.fromLTWH(0, 0, sheet.sidePx.toDouble(), sheet.sidePx.toDouble()),
    )
    ..scale(sheet.sidePx / StickerScene.side);
  paintStickerScene(canvas, scene);
  canvas.restore();
  final ui.Picture picture = recorder.endRecording();
  return picture
      .toImage(sheet.widthPx, sheet.heightPx)
      .whenComplete(picture.dispose);
}

/// [scene] as a file of [format] on the page [design] chose.
Future<Uint8List> exportSticker(
  StickerScene scene,
  StickerDesign design, {
  StickerFormat? format,
}) async {
  final StickerSheet sheet = StickerSheet(
    design.page,
    landscape: design.landscape,
  );
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
          imageLeftPt: StickerSheet.pt(sheet.leftMm),
          imageTopPt: StickerSheet.pt(sheet.topMm),
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
  out.writeln(
    '<g transform="translate(${_n(sheet.leftMm)} ${_n(sheet.topMm)}) '
    'scale(${(sheet.sideMm / StickerScene.side).toStringAsFixed(5)})">',
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
  out
    ..writeln('</g>')
    ..writeln('</svg>');
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
