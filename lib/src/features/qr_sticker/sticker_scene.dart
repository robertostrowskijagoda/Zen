import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:intl/intl.dart' show Bidi;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/qr_sticker/qr_matrix.dart';
import 'package:zen/src/features/qr_sticker/sticker_design.dart';

// The sticker as a list of plain shapes on a square of [StickerScene.side]
// units: the preview paints it, the exports paint it at print size or
// write it out as SVG, and the tests measure it (nothing but the code
// itself may sit on the code or its quiet zone).

/// One step of a shape's outline.
sealed class PathOp {
  const PathOp();
}

final class MoveOp extends PathOp {
  const MoveOp(this.x, this.y);
  final double x;
  final double y;
}

final class LineOp extends PathOp {
  const LineOp(this.x, this.y);
  final double x;
  final double y;
}

final class CubicOp extends PathOp {
  const CubicOp(this.x1, this.y1, this.x2, this.y2, this.x, this.y);
  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final double x;
  final double y;
}

final class CloseOp extends PathOp {
  const CloseOp();
}

/// A whole rectangle, with corners rounded by [radius] (0: square).
final class RectOp extends PathOp {
  const RectOp(this.rect, [this.radius = 0]);
  final Rect rect;
  final double radius;
}

/// A whole circle.
final class CircleOp extends PathOp {
  const CircleOp(this.center, this.radius);
  final Offset center;
  final double radius;
}

/// What a shape is on the sticker: [frame] is the pebble's stone under the
/// code's white plate, [mark] its label and little stone beside it.
enum ShapeRole {
  background,
  plate,
  qr,
  logo,
  text,
  signature,
  decoration,
  frame,
  mark,
}

sealed class StickerShape {
  const StickerShape(this.role, this.bounds);

  final ShapeRole role;

  /// Everything the shape paints is inside.
  final Rect bounds;
}

/// A filled outline (overlapping parts fill once: the code's modules make
/// one seamless shape).
final class StickerPath extends StickerShape {
  const StickerPath(super.role, super.bounds, this.color, this.ops);

  final int color;
  final List<PathOp> ops;
}

/// A line of text as laid out: [left] and [baseline] from the text's
/// [StickerText.bounds].
final class StickerTextLine {
  const StickerTextLine(this.text, this.left, this.baseline, this.width);

  final String text;
  final double left;
  final double baseline;
  final double width;
}

/// A text, laid out [layoutWidth] wide and painted at [bounds].
final class StickerText extends StickerShape {
  const StickerText(
    super.role,
    super.bounds, {
    required this.text,
    required this.family,
    required this.size,
    required this.weight,
    required this.color,
    required this.maxLines,
    required this.layoutWidth,
    required this.rtl,
    required this.lines,
  });

  final String text;
  final String family;
  final double size;
  final int weight;
  final int color;
  final int maxLines;
  final double layoutWidth;
  final bool rtl;
  final List<StickerTextLine> lines;

  TextStyle get style => stickerTextStyle(family, size, weight, color);

  /// The same layout again, to paint.
  TextPainter painter() =>
      _painter(text, style, maxLines: maxLines, rtl: rtl)
        ..layout(maxWidth: layoutWidth);
}

/// The fonts of the sticker (the app's own, so the print looks the same
/// on every phone).
const String kStickerDisplayFont = 'Baloo 2';
const String kStickerTextFont = 'Hanken Grotesk';

TextStyle stickerTextStyle(String family, double size, int weight, int color) =>
    TextStyle(
      fontFamily: family,
      // The title face draws every Latin letter; the text face stands in for
      // anything else it lacks.
      fontFamilyFallback: family == kStickerDisplayFont
          ? const <String>[kStickerTextFont]
          : null,
      fontSize: size,
      fontWeight: FontWeight.values[(weight ~/ 100 - 1).clamp(0, 8)],
      color: Color(color),
      height: 1.12,
    );

TextPainter _painter(
  String text,
  TextStyle style, {
  required int maxLines,
  required bool rtl,
}) => TextPainter(
  text: TextSpan(text: text, style: style),
  textAlign: TextAlign.center,
  textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
  maxLines: maxLines,
  ellipsis: '…',
);

/// The sticker laid out: [shapes] in painting order.
final class StickerScene {
  StickerScene._({
    required this.matrix,
    required this.design,
    required this.shapes,
    required this.quietRect,
    required this.qrRect,
    required this.module,
    required this.hole,
    required this.stone,
  });

  /// The artwork's side, in the scene's units.
  static const double side = 1000;

  /// The margin of the artwork, kept free of everything but the paper and
  /// the patterns.
  static const double margin = 56;

  /// Between the quiet zone and the texts.
  static const double gap = 20;

  /// The diameter of a module in the dots style, in modules: the centre
  /// stays well inside, and cameras still see a full module.
  static const double dotFill = 0.9;

  final QrMatrix matrix;
  final StickerDesign design;
  final List<StickerShape> shapes;

  /// The code with its quiet zone (white).
  final Rect quietRect;

  /// The modules' square.
  final Rect qrRect;

  /// A module's side.
  final double module;

  /// The modules left empty for the logo, or null.
  final QrHole? hole;

  /// The pebble's stone around the code (a pebble's sticker), or null.
  final PebbleStone? stone;

  Iterable<StickerShape> withRole(ShapeRole role) =>
      shapes.where((StickerShape s) => s.role == role);

  /// The middle of module (row, col).
  Offset moduleCentre(int row, int col) => Offset(
    qrRect.left + (col + 0.5) * module,
    qrRect.top + (row + 0.5) * module,
  );

  /// The QR code for [design]'s choices: with error correction H when it
  /// asks for the logo.
  static QrMatrix matrixFor(String data, StickerDesign design) =>
      QrMatrix.encode(data, robust: design.logo);

  /// Lays out [design] around [matrix] (see [matrixFor]); a [kind] with
  /// [StickerKind.pebbleMark] puts the code on a stone labelled "kamyczek
  /// Zen", which takes the place of the small signature.
  static StickerScene build(
    QrMatrix matrix,
    StickerDesign design, {
    StickerKind? kind,
  }) {
    final StickerTheme theme = design.theme;
    final StickerTexts texts = design.texts;
    final bool pebble = kind?.pebbleMark ?? false;
    final List<StickerShape> shapes = <StickerShape>[
      StickerPath(
        ShapeRole.background,
        const Rect.fromLTWH(0, 0, side, side),
        theme.paper,
        const <PathOp>[RectOp(Rect.fromLTWH(0, 0, side, side))],
      ),
    ];

    final String top = texts.top.trim();
    final String caption = texts.caption.trim();
    final String bottom = texts.bottom.trim();
    final bool anyText =
        top.isNotEmpty || caption.isNotEmpty || bottom.isNotEmpty;

    // The code in the middle, with its quiet zone (a little smaller on a
    // pebble's stone, which needs room around it).
    final double outer = pebble ? (anyText ? 500 : 600) : (anyText ? 540 : 680);
    final int span = matrix.size + 2 * QrMatrix.quietZone;
    final double module = outer / span;
    final Rect quiet = Rect.fromCenter(
      center: const Offset(side / 2, side / 2),
      width: outer,
      height: outer,
    );
    final Rect qr = quiet.deflate(QrMatrix.quietZone * module);
    final QrHole? hole = design.logo ? matrix.logoHole : null;
    final PebbleStone? stone = pebble ? PebbleStone.around(quiet) : null;
    // What the texts keep clear of: the stone, or the code.
    final Rect middle = stone?.bounds ?? quiet;

    // The texts around it.
    final List<StickerShape> words = <StickerShape>[];
    final int ink = theme.ink;
    if (top.isNotEmpty) {
      words.add(
        _fit(
          top,
          Rect.fromLTRB(margin, margin, side - margin, middle.top - gap),
          family: kStickerDisplayFont,
          maxSize: 78,
          minSize: 22,
          weight: 700,
          maxLines: 2,
          color: ink,
        ),
      );
    }
    final bool signed = design.signature && !pebble;
    final double signatureHeight = signed ? 34 : 0;
    double below = middle.bottom + gap;
    if (caption.isNotEmpty) {
      final StickerText line = _fit(
        caption,
        Rect.fromLTRB(margin, below - 6, side - margin, below + 34),
        family: kStickerTextFont,
        maxSize: 28,
        minSize: 14,
        weight: 500,
        maxLines: 1,
        color: ink,
        alignTop: true,
      );
      words.add(line);
      below = line.bounds.bottom + 10;
    }
    if (bottom.isNotEmpty) {
      words.add(
        _fit(
          bottom,
          Rect.fromLTRB(
            margin,
            below,
            side - margin,
            side - margin - (signatureHeight > 0 ? signatureHeight + 6 : 0),
          ),
          family: kStickerTextFont,
          maxSize: 58,
          minSize: 18,
          weight: 700,
          maxLines: 2,
          color: ink,
        ),
      );
    }

    final List<StickerShape> signature = signed
        ? _signature(ink, signatureHeight)
        : const <StickerShape>[];

    // The patterns, only where nothing else is.
    final List<Rect> taken = <Rect>[
      middle.inflate(gap / 2),
      for (final StickerShape w in words) w.bounds.inflate(12),
      for (final StickerShape s in signature) s.bounds.inflate(10),
    ];
    shapes.addAll(_decorations(design.pattern, theme, taken));
    if (stone != null) {
      shapes.addAll(stone.shapes(theme));
    }

    // The white plate: the quiet zone and the code.
    shapes.add(
      StickerPath(ShapeRole.plate, quiet, StickerTheme.plate, <PathOp>[
        RectOp(quiet, module * 1.2),
      ]),
    );
    shapes.addAll(_code(matrix, design.style, qr, module, ink, hole));
    if (hole != null) {
      shapes.addAll(_logo(qr, module, hole, ink));
    }
    shapes
      ..addAll(words)
      ..addAll(signature);
    if (stone != null) {
      shapes.addAll(_pebbleLabel(stone, quiet, theme));
    }
    return StickerScene._(
      matrix: matrix,
      design: design,
      shapes: shapes,
      quietRect: quiet,
      qrRect: qr,
      module: module,
      hole: hole,
      stone: stone,
    );
  }

  /// "kamyczek Zen" with a little painted stone before it, on the stone
  /// under the code: between the quiet zone and the stone's rim.
  static List<StickerShape> _pebbleLabel(
    PebbleStone stone,
    Rect quiet,
    StickerTheme theme,
  ) {
    final double top = quiet.bottom + gap / 2;
    final double bottom = math.min(
      top + quiet.height * 0.12,
      stone.edgeBelow(quiet.center.dx) - 8,
    );
    final (double left, double right) = stone.spanAt(bottom);
    final Rect band = Rect.fromLTRB(left + 14, top, right - 14, bottom);
    final double iconWidth = band.height * 0.95;
    final double space = band.height * 0.22;
    final String label = t('kamyczek Zen');
    StickerText fit(Rect box) => _fit(
      label,
      box,
      family: kStickerDisplayFont,
      maxSize: band.height * 0.68,
      minSize: 8,
      weight: 700,
      maxLines: 1,
      color: theme.ink,
      role: ShapeRole.mark,
    );
    // Measured in the room the icon leaves, then set beside it, the two
    // centred together.
    final StickerText measured = fit(
      Rect.fromLTRB(band.left + iconWidth + space, top, band.right, bottom),
    );
    final double whole = iconWidth + space + measured.bounds.width;
    final double start = band.center.dx - whole / 2;
    final StickerText text = fit(
      Rect.fromLTRB(start + iconWidth + space, top, start + whole + 1, bottom),
    );
    final Rect icon = Rect.fromCenter(
      center: Offset(start + iconWidth / 2, text.bounds.center.dy),
      width: iconWidth,
      height: text.size * 0.82,
    );
    final double rx = icon.width / 2;
    final double ry = icon.height / 2;
    final Offset c = icon.center;
    // The little stone, a painted wave across it and a dot.
    final List<PathOp> wave = <PathOp>[
      MoveOp(c.dx - rx * 0.72, c.dy + ry * 0.18),
      CubicOp(
        c.dx - rx * 0.3,
        c.dy - ry * 0.32,
        c.dx + rx * 0.2,
        c.dy + ry * 0.12,
        c.dx + rx * 0.74,
        c.dy - ry * 0.22,
      ),
      LineOp(c.dx + rx * 0.7, c.dy + ry * 0.06),
      CubicOp(
        c.dx + rx * 0.2,
        c.dy + ry * 0.4,
        c.dx - rx * 0.3,
        c.dy - ry * 0.02,
        c.dx - rx * 0.66,
        c.dy + ry * 0.46,
      ),
      const CloseOp(),
    ];
    final Rect waveBounds = Rect.fromLTRB(
      c.dx - rx * 0.72,
      c.dy - ry * 0.32,
      c.dx + rx * 0.74,
      c.dy + ry * 0.46,
    );
    final Offset dot = Offset(c.dx - rx * 0.28, c.dy - ry * 0.46);
    return <StickerShape>[
      StickerPath(ShapeRole.mark, icon, theme.accent, ellipseOps(icon)),
      StickerPath(ShapeRole.mark, waveBounds, StickerTheme.plate, wave),
      StickerPath(
        ShapeRole.mark,
        Rect.fromCircle(center: dot, radius: ry * 0.16),
        theme.ink,
        <PathOp>[CircleOp(dot, ry * 0.16)],
      ),
      text,
    ];
  }

  /// The modules: the data in the chosen style, the code's own patterns
  /// whole.
  static List<StickerShape> _code(
    QrMatrix m,
    QrStyle style,
    Rect qr,
    double unit,
    int ink,
    QrHole? hole,
  ) {
    final List<PathOp> ops = <PathOp>[];
    Rect cell(int r, int c, [int w = 1]) =>
        Rect.fromLTWH(qr.left + c * unit, qr.top + r * unit, w * unit, unit);
    for (int r = 0; r < m.size; r++) {
      int run = -1;
      void flush(int end) {
        if (run >= 0) {
          ops.add(RectOp(cell(r, run, end - run)));
          run = -1;
        }
      }

      for (int c = 0; c < m.size; c++) {
        final bool dark =
            m.isDark(r, c) &&
            !m.isFinder(r, c) &&
            !(hole?.contains(r, c) ?? false);
        final bool square =
            m.isFunction(r, c) ||
            style == QrStyle.classic ||
            style == QrStyle.softEyes;
        if (dark && square) {
          if (run < 0) {
            run = c;
          }
          continue;
        }
        flush(c);
        if (!dark) {
          continue;
        }
        if (style == QrStyle.dots) {
          ops.add(CircleOp(cell(r, c).center, unit * dotFill / 2));
        } else {
          ops.add(RectOp(cell(r, c), unit * 0.36));
        }
      }
      flush(m.size);
    }
    final List<StickerShape> out = <StickerShape>[
      StickerPath(ShapeRole.qr, qr, ink, ops),
    ];
    // The three eyes: a ring of 7, the light ring of 5, the centre of 3.
    final (double r7, double r5, double r3) = switch (style) {
      QrStyle.classic => (0.0, 0.0, 0.0),
      QrStyle.rounded => (0.8, 0.5, 0.4),
      // Rounder would leave the corner modules' centres light (the
      // limit is 1.7 modules; this leaves room for the edge's blur).
      QrStyle.dots || QrStyle.softEyes => (1.35, 1.0, 0.9),
    };
    for (final (int r0, int c0) in m.finderOrigins) {
      final Rect eye = Rect.fromLTWH(
        qr.left + c0 * unit,
        qr.top + r0 * unit,
        7 * unit,
        7 * unit,
      );
      out
        ..add(
          StickerPath(ShapeRole.qr, eye, ink, <PathOp>[RectOp(eye, r7 * unit)]),
        )
        ..add(
          StickerPath(
            ShapeRole.qr,
            eye.deflate(unit),
            StickerTheme.plate,
            <PathOp>[RectOp(eye.deflate(unit), r5 * unit)],
          ),
        )
        ..add(
          StickerPath(ShapeRole.qr, eye.deflate(2 * unit), ink, <PathOp>[
            RectOp(eye.deflate(2 * unit), r3 * unit),
          ]),
        );
    }
    return out;
  }

  /// Zen's mark in the modules left empty for it.
  static List<StickerShape> _logo(Rect qr, double unit, QrHole hole, int ink) {
    final Rect area = Rect.fromLTWH(
      qr.left + hole.first * unit,
      qr.top + hole.first * unit,
      hole.side * unit,
      hole.side * unit,
    ).deflate(unit * 0.7);
    final StickerText word = _fit(
      'ZEN',
      area.deflate(area.width * 0.14),
      family: kStickerDisplayFont,
      maxSize: area.height * 0.5,
      minSize: 4,
      weight: 700,
      maxLines: 1,
      color: StickerTheme.plate,
      role: ShapeRole.logo,
    );
    return <StickerShape>[
      StickerPath(ShapeRole.logo, area, ink, <PathOp>[
        RectOp(area, area.width * 0.22),
      ]),
      word,
    ];
  }

  /// The small "Zen" in the bottom right corner: the little house of the
  /// logo and the name.
  static List<StickerShape> _signature(int ink, double height) {
    final int soft = Color.alphaBlend(
      Color(ink).withValues(alpha: 0.72),
      const Color(0xFFFFFFFF),
    ).toARGB32();
    final StickerText name = _fit(
      'Zen',
      Rect.fromLTRB(
        side - margin - 120,
        side - margin - height,
        side - margin,
        side - margin,
      ),
      family: kStickerDisplayFont,
      maxSize: 28,
      minSize: 10,
      weight: 700,
      maxLines: 1,
      color: soft,
      role: ShapeRole.signature,
      alignEnd: true,
    );
    // The house, left of the name, standing on its baseline.
    final double h = name.size * 0.8;
    final double right = name.bounds.left - h * 0.3;
    final double base =
        name.bounds.top +
        (name.lines.isEmpty ? name.bounds.height : name.lines.first.baseline);
    final Rect house = Rect.fromLTRB(right - h, base - h, right, base);
    final double w = house.width;
    final List<PathOp> ops = <PathOp>[
      MoveOp(house.left + w * 0.5, house.top),
      LineOp(house.right, house.top + h * 0.48),
      LineOp(house.right - w * 0.14, house.top + h * 0.48),
      LineOp(house.right - w * 0.14, house.bottom),
      LineOp(house.left + w * 0.62, house.bottom),
      LineOp(house.left + w * 0.62, house.bottom - h * 0.3),
      LineOp(house.left + w * 0.38, house.bottom - h * 0.3),
      LineOp(house.left + w * 0.38, house.bottom),
      LineOp(house.left + w * 0.14, house.bottom),
      LineOp(house.left + w * 0.14, house.top + h * 0.48),
      LineOp(house.left, house.top + h * 0.48),
      const CloseOp(),
    ];
    return <StickerShape>[
      StickerPath(ShapeRole.signature, house, soft, ops),
      name,
    ];
  }

  /// [text] at the largest size from [maxSize] down that fits [box] in
  /// [maxLines] lines (at [minSize] it is cut with "…"), centred in the box
  /// (at its top with [alignTop], at its right with [alignEnd]).
  static StickerText _fit(
    String text,
    Rect box, {
    required String family,
    required double maxSize,
    required double minSize,
    required int weight,
    required int maxLines,
    required int color,
    ShapeRole role = ShapeRole.text,
    bool alignTop = false,
    bool alignEnd = false,
  }) {
    final bool rtl = Bidi.detectRtlDirectionality(text);
    final double width = math.max(1, box.width);
    double size = maxSize;
    TextPainter painter;
    while (true) {
      painter = _painter(
        text,
        stickerTextStyle(family, size, weight, color),
        maxLines: maxLines,
        rtl: rtl,
      )..layout(maxWidth: width);
      final bool fits =
          !painter.didExceedMaxLines &&
          painter.height <= box.height &&
          painter.width <= width;
      if (fits || size <= minSize) {
        break;
      }
      painter.dispose();
      size = math.max(minSize, size - 1.5);
    }
    final double w = painter.width;
    final double h = painter.height;
    final double left = alignEnd ? box.right - w : box.center.dx - w / 2;
    final double top = alignTop ? box.top : box.center.dy - h / 2;
    final List<StickerTextLine> lines = <StickerTextLine>[];
    final List<ui.LineMetrics> metrics = painter.computeLineMetrics();
    for (int i = 0; i < metrics.length; i++) {
      final ui.LineMetrics lm = metrics[i];
      final TextRange range = painter.getLineBoundary(
        painter.getPositionForOffset(
          Offset(lm.left + lm.width / 2, lm.baseline - lm.ascent / 2),
        ),
      );
      String line = range.isValid && !range.isCollapsed
          ? text.substring(range.start, range.end).trimRight()
          : '';
      if (i == metrics.length - 1 && painter.didExceedMaxLines) {
        line = '$line…';
      }
      lines.add(StickerTextLine(line, lm.left, lm.baseline, lm.width));
    }
    painter.dispose();
    return StickerText(
      role,
      Rect.fromLTWH(left, top, w, h),
      text: text,
      family: family,
      size: size,
      weight: weight,
      color: color,
      maxLines: maxLines,
      layoutWidth: width,
      rtl: rtl,
      lines: lines,
    );
  }

  /// The pattern's little drawings, scattered where they touch nothing in
  /// [taken] (always the same for the same layout).
  static List<StickerShape> _decorations(
    StickerPattern pattern,
    StickerTheme theme,
    List<Rect> taken,
  ) {
    if (pattern == StickerPattern.none) {
      return const <StickerShape>[];
    }
    final math.Random random = math.Random(31 + pattern.index);
    const Rect inside = Rect.fromLTRB(14, 14, side - 14, side - 14);
    final List<Offset> spots = <Offset>[
      for (double y = 40; y < side - 20; y += 64)
        for (double x = 40; x < side - 20; x += 64)
          Offset(
            x + random.nextDouble() * 24 - 12,
            y + random.nextDouble() * 24 - 12,
          ),
    ]..shuffle(random);
    final List<Rect> placed = <Rect>[];
    final List<StickerShape> out = <StickerShape>[];
    final int most = pattern == StickerPattern.waves ? 8 : 22;
    for (final Offset spot in spots) {
      final double radius = pattern == StickerPattern.waves
          ? 46 + random.nextDouble() * 18
          : 18 + random.nextDouble() * 20;
      final double turn = (random.nextDouble() - 0.5) * 1.2;
      final int variant = random.nextInt(3);
      final List<(List<Offset> points, List<PathOp> ops, bool soft)> parts =
          _motif(pattern, variant, spot, radius, turn);
      Rect? bounds;
      for (final (List<Offset> points, _, _) in parts) {
        for (final Offset p in points) {
          final Rect dot = Rect.fromCenter(center: p, width: 0, height: 0);
          bounds = bounds == null ? dot : bounds.expandToInclude(dot);
        }
      }
      if (bounds == null) {
        continue;
      }
      final Rect b = bounds;
      if (!_within(inside, b) ||
          taken.any((Rect t) => t.overlaps(b)) ||
          placed.any((Rect p) => p.inflate(10).overlaps(b))) {
        continue;
      }
      placed.add(b);
      for (final (List<Offset> points, List<PathOp> ops, bool soft) in parts) {
        Rect pb = Rect.fromCenter(center: points.first, width: 0, height: 0);
        for (final Offset p in points) {
          pb = pb.expandToInclude(
            Rect.fromCenter(center: p, width: 0, height: 0),
          );
        }
        out.add(
          StickerPath(
            ShapeRole.decoration,
            pb,
            soft ? theme.accentSoft : theme.accent,
            ops,
          ),
        );
      }
      if (placed.length >= most) {
        break;
      }
    }
    return out;
  }

  static bool _within(Rect outer, Rect inner) =>
      inner.left >= outer.left &&
      inner.top >= outer.top &&
      inner.right <= outer.right &&
      inner.bottom <= outer.bottom;

  /// One drawing of [pattern] at [at], [radius] across and turned by
  /// [turn]: its parts, each with every point it touches (its bounds) and
  /// whether it takes the softer accent.
  static List<(List<Offset>, List<PathOp>, bool)> _motif(
    StickerPattern pattern,
    int variant,
    Offset at,
    double radius,
    double turn,
  ) {
    final double cs = math.cos(turn);
    final double sn = math.sin(turn);
    Offset map(double x, double y) => Offset(
      at.dx + (x * cs - y * sn) * radius,
      at.dy + (x * sn + y * cs) * radius,
    );

    // A part from unit points: m(x, y), l(x, y), c(x1, y1, x2, y2, x, y).
    (List<Offset>, List<PathOp>, bool) part(
      List<List<double>> steps,
      bool soft,
    ) {
      final List<Offset> points = <Offset>[];
      final List<PathOp> ops = <PathOp>[];
      for (final List<double> s in steps) {
        if (s.isEmpty) {
          ops.add(const CloseOp());
          continue;
        }
        final List<Offset> p = <Offset>[
          for (int i = 0; i + 1 < s.length; i += 2) map(s[i], s[i + 1]),
        ];
        points.addAll(p);
        ops.add(switch (p.length) {
          1 when ops.isEmpty || ops.last is CloseOp => MoveOp(p[0].dx, p[0].dy),
          1 => LineOp(p[0].dx, p[0].dy),
          _ => CubicOp(p[0].dx, p[0].dy, p[1].dx, p[1].dy, p[2].dx, p[2].dy),
        });
      }
      return (points, ops, soft);
    }

    (List<Offset>, List<PathOp>, bool) circle(
      double x,
      double y,
      double r,
      bool soft,
    ) {
      final Offset c = map(x, y);
      final double rr = r * radius;
      return (
        <Offset>[c - Offset(rr, rr), c + Offset(rr, rr)],
        <PathOp>[CircleOp(c, rr)],
        soft,
      );
    }

    List<List<double>> mirror(List<List<double>> steps) => <List<double>>[
      for (final List<double> s in steps)
        <double>[for (int i = 0; i < s.length; i++) i.isEven ? -s[i] : s[i]],
    ];

    List<List<double>> star(int points, double inner) => <List<double>>[
      for (int i = 0; i < points * 2; i++)
        <double>[
          (i.isEven ? 1.0 : inner) * math.sin(i * math.pi / points),
          -(i.isEven ? 1.0 : inner) * math.cos(i * math.pi / points),
        ],
      <double>[],
    ];

    switch (pattern) {
      case StickerPattern.none:
        return const <(List<Offset>, List<PathOp>, bool)>[];
      case StickerPattern.butterflies:
        const List<List<double>> upper = <List<double>>[
          <double>[-0.04, -0.12],
          <double>[-0.3, -0.95, -1.0, -0.95, -0.92, -0.35],
          <double>[-0.86, 0.0, -0.4, 0.06, -0.04, 0.02],
          <double>[],
        ];
        const List<List<double>> lower = <List<double>>[
          <double>[-0.04, 0.04],
          <double>[-0.5, 0.12, -0.86, 0.5, -0.62, 0.8],
          <double>[-0.4, 0.96, -0.12, 0.52, -0.04, 0.12],
          <double>[],
        ];
        return <(List<Offset>, List<PathOp>, bool)>[
          part(upper, variant != 0),
          part(mirror(upper), variant != 0),
          part(lower, variant == 0),
          part(mirror(lower), variant == 0),
          part(const <List<double>>[
            <double>[-0.07, -0.42],
            <double>[0.07, -0.42],
            <double>[0.05, 0.6],
            <double>[-0.05, 0.6],
            <double>[],
          ], false),
        ];
      case StickerPattern.leaves:
        return <(List<Offset>, List<PathOp>, bool)>[
          part(const <List<double>>[
            <double>[0, -1],
            <double>[0.72, -0.55, 0.72, 0.42, 0, 0.92],
            <double>[-0.72, 0.42, -0.72, -0.55, 0, -1],
            <double>[],
          ], variant == 1),
          part(const <List<double>>[
            <double>[-0.03, -0.72],
            <double>[0.03, -0.72],
            <double>[0.035, 1.0],
            <double>[-0.035, 1.0],
            <double>[],
          ], variant != 1),
        ];
      case StickerPattern.confetti:
        return switch (variant) {
          0 => <(List<Offset>, List<PathOp>, bool)>[circle(0, 0, 0.38, false)],
          1 => <(List<Offset>, List<PathOp>, bool)>[
            part(const <List<double>>[
              <double>[-0.7, -0.18],
              <double>[0.7, -0.18],
              <double>[0.7, 0.18],
              <double>[-0.7, 0.18],
              <double>[],
            ], true),
          ],
          _ => <(List<Offset>, List<PathOp>, bool)>[
            part(const <List<double>>[
              <double>[0, -0.55],
              <double>[0.5, 0.35],
              <double>[-0.5, 0.35],
              <double>[],
            ], false),
          ],
        };
      case StickerPattern.stars:
        return <(List<Offset>, List<PathOp>, bool)>[
          part(
            star(variant == 2 ? 4 : 5, variant == 2 ? 0.36 : 0.44),
            variant == 1,
          ),
        ];
      case StickerPattern.hearts:
        return <(List<Offset>, List<PathOp>, bool)>[
          part(const <List<double>>[
            <double>[0, 0.86],
            <double>[-1.05, 0.08, -0.72, -0.94, 0, -0.36],
            <double>[0.72, -0.94, 1.05, 0.08, 0, 0.86],
            <double>[],
          ], variant == 1),
        ];
      case StickerPattern.waves:
        return <(List<Offset>, List<PathOp>, bool)>[
          for (int i = 0; i < 2; i++)
            part(<List<double>>[
              <double>[-1, -0.2 + i * 0.32],
              <double>[
                -0.75,
                -0.48 + i * 0.32,
                -0.25,
                -0.48 + i * 0.32,
                0,
                -0.2 + i * 0.32,
              ],
              <double>[
                0.25,
                0.08 + i * 0.32,
                0.75,
                0.08 + i * 0.32,
                1,
                -0.2 + i * 0.32,
              ],
              <double>[1, -0.08 + i * 0.32],
              <double>[
                0.75,
                0.2 + i * 0.32,
                0.25,
                0.2 + i * 0.32,
                0,
                -0.08 + i * 0.32,
              ],
              <double>[
                -0.25,
                -0.36 + i * 0.32,
                -0.75,
                -0.36 + i * 0.32,
                -1,
                -0.08 + i * 0.32,
              ],
              <double>[],
            ], i == 1),
        ];
    }
  }
}

/// An ellipse filling [r], as four curves.
List<PathOp> ellipseOps(Rect r) {
  const double k = 0.5523;
  final double cx = r.center.dx;
  final double cy = r.center.dy;
  final double rx = r.width / 2;
  final double ry = r.height / 2;
  return <PathOp>[
    MoveOp(cx + rx, cy),
    CubicOp(cx + rx, cy + k * ry, cx + k * rx, cy + ry, cx, cy + ry),
    CubicOp(cx - k * rx, cy + ry, cx - rx, cy + k * ry, cx - rx, cy),
    CubicOp(cx - rx, cy - k * ry, cx - k * rx, cy - ry, cx, cy - ry),
    CubicOp(cx + k * rx, cy - ry, cx + rx, cy - k * ry, cx + rx, cy),
    const CloseOp(),
  ];
}

/// The stone of a pebble's sticker: a rounded, slightly uneven
/// superellipse around the code's quiet zone, a little lower than the code
/// so that its label fits under it. It lies under the white plate, so the
/// quiet zone stays white; only its rim and the band around the plate show.
final class PebbleStone {
  PebbleStone.around(Rect quiet)
    : center = Offset(quiet.center.dx, quiet.center.dy + quiet.height * 0.03),
      rx = quiet.width * 0.63,
      ry = quiet.height * 0.65 {
    outline = _points(0);
    inner = _points(rim);
    bounds = _around(outline);
    innerBounds = _around(inner);
  }

  static Rect _around(List<Offset> points) {
    double l = double.infinity, t = double.infinity;
    double r = -double.infinity, b = -double.infinity;
    for (final Offset p in points) {
      l = math.min(l, p.dx);
      t = math.min(t, p.dy);
      r = math.max(r, p.dx);
      b = math.max(b, p.dy);
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  /// How square the stone is (2 would be an ellipse).
  static const double exponent = 4.6;

  /// The darker rim, in the scene's units.
  static const double rim = 9;

  static const int _steps = 180;

  final Offset center;
  final double rx;
  final double ry;

  /// The edge, and the edge inside the rim, as points around.
  late final List<Offset> outline;
  late final List<Offset> inner;
  late final Rect bounds;
  late final Rect innerBounds;

  List<Offset> _points(double inset) => <Offset>[
    for (int i = 0; i < _steps; i++) _point(i * 2 * math.pi / _steps, inset),
  ];

  Offset _point(double a, double inset) {
    double power(double v) =>
        (v < 0 ? -1 : 1) * math.pow(v.abs(), 2 / exponent).toDouble();
    // A gentle unevenness, the same on every sticker: a stone, not a
    // rounded square.
    final double wobble =
        1 + 0.022 * math.sin(2 * a + 0.6) + 0.014 * math.cos(3 * a + 1.1);
    final double x = rx * power(math.cos(a)) * wobble;
    final double y = ry * power(math.sin(a)) * wobble;
    final double length = math.sqrt(x * x + y * y);
    final double k = length > inset ? (length - inset) / length : 0;
    return Offset(center.dx + x * k, center.dy + y * k);
  }

  /// [p] lies inside the edge (inside the rim with [inside]).
  bool contains(Offset p, {bool inside = false}) {
    final List<Offset> poly = inside ? inner : outline;
    bool odd = false;
    for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final Offset a = poly[i];
      final Offset b = poly[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        odd = !odd;
      }
    }
    return odd;
  }

  /// Where the inner edge crosses the height [y]: its left and right.
  (double, double) spanAt(double y) {
    double left = double.infinity;
    double right = -double.infinity;
    for (int i = 0, j = inner.length - 1; i < inner.length; j = i++) {
      final Offset a = inner[i];
      final Offset b = inner[j];
      if ((a.dy > y) != (b.dy > y)) {
        final double x = a.dx + (b.dx - a.dx) * (y - a.dy) / (b.dy - a.dy);
        left = math.min(left, x);
        right = math.max(right, x);
      }
    }
    return (left, right);
  }

  /// The lowest point of the inner edge straight below [x].
  double edgeBelow(double x) {
    double lowest = center.dy;
    for (int i = 0, j = inner.length - 1; i < inner.length; j = i++) {
      final Offset a = inner[i];
      final Offset b = inner[j];
      if ((a.dx > x) != (b.dx > x)) {
        final double y = a.dy + (b.dy - a.dy) * (x - a.dx) / (b.dx - a.dx);
        lowest = math.max(lowest, y);
      }
    }
    return lowest;
  }

  /// The rim and the stone in [theme]'s colours, painted before the plate.
  List<StickerShape> shapes(StickerTheme theme) {
    List<PathOp> path(List<Offset> points) => <PathOp>[
      MoveOp(points.first.dx, points.first.dy),
      for (final Offset p in points.skip(1)) LineOp(p.dx, p.dy),
      const CloseOp(),
    ];
    return <StickerShape>[
      StickerPath(ShapeRole.frame, bounds, theme.accent, path(outline)),
      StickerPath(ShapeRole.frame, innerBounds, theme.accentSoft, path(inner)),
    ];
  }
}
