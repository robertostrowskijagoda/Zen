import 'dart:math' as math;
import 'dart:ui' show PathMetric, lerpDouble;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The outlines a look can draw around its panels, besides the plain
/// rounded rectangle: a bevelled chrome (or riveted) frame, an elegant
/// double line (with ornaments), cut corners (with circuit pads), stepped
/// pixel corners, an old window with its title bar, an iridescent line,
/// leather stitches, a leaf, scallops, a ticket with bites and the corner
/// marks of a drawing board.

/// A 1px bevelled chrome frame with square corners: lit on the top and
/// left, shaded on the bottom and right ([sunken] swaps them, a pressed
/// button or an LCD well).
@immutable
class ZenBevelBorder extends OutlinedBorder {
  const ZenBevelBorder({
    required this.light,
    required this.dark,
    this.width = 1,
    this.sunken = false,
    this.rivets = false,
    super.side,
  });

  /// The frame in the colours of [zen] ([rivets]: a riveted metal plate).
  /// The lit edge is the brighter colour of the palette: its strong outline
  /// on a dark one, its surface on a light one (a silver or paper skin).
  factory ZenBevelBorder.of(
    ZenColors zen, {
    bool sunken = false,
    bool rivets = false,
  }) {
    final bool lightPalette = zen.background.computeLuminance() > 0.3;
    return ZenBevelBorder(
      light: lightPalette ? zen.surface : zen.outlineStrong,
      dark: lightPalette ? zen.outlineStrong : zen.surfaceSunk,
      sunken: sunken,
      rivets: rivets,
    );
  }

  final Color light;
  final Color dark;
  final double width;
  final bool sunken;

  /// A small domed rivet in each corner.
  final bool rivets;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect.deflate(width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty || width <= 0) {
      return;
    }
    final Paint lit = Paint()..color = sunken ? dark : light;
    final Paint shade = Paint()..color = sunken ? light : dark;
    canvas
      ..drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, width), lit)
      ..drawRect(Rect.fromLTWH(rect.left, rect.top, width, rect.height), lit)
      ..drawRect(
        Rect.fromLTWH(rect.left, rect.bottom - width, rect.width, width),
        shade,
      )
      ..drawRect(
        Rect.fromLTWH(rect.right - width, rect.top, width, rect.height),
        shade,
      );
    if (rivets && rect.width > 24 && rect.height > 24) {
      final Paint head = Paint()..color = light;
      final Paint rim = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = dark;
      for (final Offset c in <Offset>[
        rect.topLeft + const Offset(6, 6),
        rect.topRight + const Offset(-6, 6),
        rect.bottomLeft + const Offset(6, -6),
        rect.bottomRight + const Offset(-6, -6),
      ]) {
        canvas
          ..drawCircle(c, 2.2, head)
          ..drawCircle(c, 2.2, rim);
      }
    }
  }

  @override
  ShapeBorder scale(double t) => ZenBevelBorder(
    light: light,
    dark: dark,
    width: width * t,
    sunken: sunken,
    rivets: rivets,
    side: side.scale(t),
  );

  @override
  ZenBevelBorder copyWith({BorderSide? side}) => ZenBevelBorder(
    light: light,
    dark: dark,
    width: width,
    sunken: sunken,
    rivets: rivets,
    side: side ?? this.side,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is ZenBevelBorder) {
      return ZenBevelBorder(
        light: Color.lerp(a.light, light, t)!,
        dark: Color.lerp(a.dark, dark, t)!,
        width: lerpDouble(a.width, width, t)!,
        sunken: t < 0.5 ? a.sunken : sunken,
        rivets: t < 0.5 ? a.rivets : rivets,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  bool operator ==(Object other) =>
      other is ZenBevelBorder &&
      other.light == light &&
      other.dark == dark &&
      other.width == width &&
      other.sunken == sunken &&
      other.rivets == rivets &&
      other.side == side;

  @override
  int get hashCode => Object.hash(light, dark, width, sunken, rivets, side);
}

/// Two thin lines with a narrow gap between them, following a rounded
/// rectangle: the frame of the elegant looks. The inner line is fainter.
@immutable
class ZenDoubleBorder extends OutlinedBorder {
  const ZenDoubleBorder({
    this.borderRadius = BorderRadius.zero,
    this.color = const Color(0xFF000000),
    this.inner,
    this.gap = 2,
    this.width = 1,
    this.ornaments = false,
    super.side,
  });

  final BorderRadius borderRadius;
  final Color color;

  /// A little diamond with two flourishes at each corner.
  final bool ornaments;

  /// The inner line; [color] at 55% when null.
  final Color? inner;
  final double gap;
  final double width;

  Color get _innerColor => inner ?? color.withValues(alpha: 0.55);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width * 2 + gap);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.toRRect(rect).deflate(width * 2 + gap));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.toRRect(rect));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty || width <= 0) {
      return;
    }
    final RRect outer = borderRadius.toRRect(rect);
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    canvas.drawRRect(outer.deflate(width / 2), line);
    line.color = _innerColor;
    canvas.drawRRect(outer.deflate(width * 1.5 + gap), line);
    if (ornaments && rect.width > 40 && rect.height > 30) {
      final Paint fill = Paint()..color = color;
      line
        ..color = color
        ..strokeCap = StrokeCap.round;
      final double inset = 4 + borderRadius.topLeft.x * 0.3;
      for (final (Offset c, double sx, double sy) in <(Offset, double, double)>[
        (rect.topLeft + Offset(inset, inset), 1, 1),
        (rect.topRight + Offset(-inset, inset), -1, 1),
        (rect.bottomLeft + Offset(inset, -inset), 1, -1),
        (rect.bottomRight + Offset(-inset, -inset), -1, -1),
      ]) {
        canvas
          ..drawPath(
            Path()
              ..moveTo(c.dx, c.dy - 3)
              ..lineTo(c.dx + 3, c.dy)
              ..lineTo(c.dx, c.dy + 3)
              ..lineTo(c.dx - 3, c.dy)
              ..close(),
            fill,
          )
          ..drawLine(c + Offset(5 * sx, 0), c + Offset(14 * sx, 0), line)
          ..drawLine(c + Offset(0, 5 * sy), c + Offset(0, 14 * sy), line);
      }
    }
  }

  @override
  ShapeBorder scale(double t) => ZenDoubleBorder(
    borderRadius: borderRadius * t,
    color: color,
    inner: inner,
    gap: gap * t,
    width: width * t,
    ornaments: ornaments,
    side: side.scale(t),
  );

  @override
  ZenDoubleBorder copyWith({BorderSide? side}) => ZenDoubleBorder(
    borderRadius: borderRadius,
    color: color,
    inner: inner,
    gap: gap,
    width: width,
    ornaments: ornaments,
    side: side ?? this.side,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is ZenDoubleBorder) {
      return ZenDoubleBorder(
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        color: Color.lerp(a.color, color, t)!,
        inner: Color.lerp(a._innerColor, _innerColor, t),
        gap: lerpDouble(a.gap, gap, t)!,
        width: lerpDouble(a.width, width, t)!,
        ornaments: t < 0.5 ? a.ornaments : ornaments,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  bool operator ==(Object other) =>
      other is ZenDoubleBorder &&
      other.borderRadius == borderRadius &&
      other.color == color &&
      other.inner == inner &&
      other.gap == gap &&
      other.width == width &&
      other.ornaments == ornaments &&
      other.side == side;

  @override
  int get hashCode =>
      Object.hash(borderRadius, color, inner, gap, width, ornaments, side);
}

/// A polygon outline the line of which is [side] when a button set one,
/// else [color] at [width] (0: no line).
abstract class _ZenPolygonBorder extends OutlinedBorder {
  const _ZenPolygonBorder({
    required this.color,
    required this.width,
    super.side,
  });

  final Color color;
  final double width;

  Path polygon(Rect rect);

  double get _line => side.style != BorderStyle.none ? side.width : width;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(_line);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => polygon(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      polygon(rect.deflate(_line));

  /// The stroke of the outline, or null without a line.
  Paint? stroke() {
    final double w = _line;
    if (w <= 0) {
      return null;
    }
    return Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeJoin = StrokeJoin.miter
      ..color = side.style != BorderStyle.none ? side.color : color;
  }
}

/// Chamfered corners of [cut] (an angular, sci-fi plate); [pads] adds a
/// solder pad at each chamfer, like a trace on a circuit board.
@immutable
class ZenCutBorder extends _ZenPolygonBorder {
  const ZenCutBorder({
    this.cut = 10,
    super.color = const Color(0xFF000000),
    super.width = 1,
    this.pads = false,
    super.side,
  });

  final double cut;
  final bool pads;

  @override
  Path polygon(Rect r) {
    final double c = cut.clamp(0.0, r.shortestSide / 2);
    return Path()
      ..moveTo(r.left + c, r.top)
      ..lineTo(r.right, r.top)
      ..lineTo(r.right, r.bottom - c)
      ..lineTo(r.right - c, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..lineTo(r.left, r.top + c)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final Paint? line = stroke();
    if (rect.isEmpty || line == null) {
      return;
    }
    final Rect r = rect.deflate(line.strokeWidth / 2);
    canvas.drawPath(polygon(r), line);
    if (pads && r.shortestSide > 2 * cut + 8) {
      final Paint pad = Paint()..color = line.color;
      final double c = cut.clamp(0.0, r.shortestSide / 2);
      for (final Offset o in <Offset>[
        Offset(r.left + c, r.top),
        Offset(r.left, r.top + c),
        Offset(r.right, r.bottom - c),
        Offset(r.right - c, r.bottom),
      ]) {
        canvas.drawCircle(o, 2.4, pad);
      }
      // Two short traces leaving the corners.
      canvas
        ..drawLine(
          Offset(r.left + c + 10, r.top),
          Offset(r.left + c + 10, r.top + 6),
          line,
        )
        ..drawLine(
          Offset(r.right - c - 10, r.bottom),
          Offset(r.right - c - 10, r.bottom - 6),
          line,
        );
    }
  }

  @override
  ShapeBorder scale(double t) => ZenCutBorder(
    cut: cut * t,
    color: color,
    width: width * t,
    pads: pads,
    side: side.scale(t),
  );

  @override
  ZenCutBorder copyWith({BorderSide? side}) => ZenCutBorder(
    cut: cut,
    color: color,
    width: width,
    pads: pads,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenCutBorder &&
      other.cut == cut &&
      other.color == color &&
      other.width == width &&
      other.pads == pads &&
      other.side == side;

  @override
  int get hashCode => Object.hash(cut, color, width, pads, side);
}

/// A thick frame with stepped corners, drawn in whole pixels like an old
/// game ([step]: the size of one stair).
@immutable
class ZenPixelBorder extends _ZenPolygonBorder {
  const ZenPixelBorder({
    super.color = const Color(0xFF000000),
    super.width = 3,
    this.step = 4,
    super.side,
  });

  final double step;

  @override
  Path polygon(Rect r) {
    final double s = step.clamp(0.0, r.shortestSide / 4);
    return Path()
      ..moveTo(r.left + 2 * s, r.top)
      ..lineTo(r.right - 2 * s, r.top)
      ..lineTo(r.right - 2 * s, r.top + s)
      ..lineTo(r.right - s, r.top + s)
      ..lineTo(r.right - s, r.top + 2 * s)
      ..lineTo(r.right, r.top + 2 * s)
      ..lineTo(r.right, r.bottom - 2 * s)
      ..lineTo(r.right - s, r.bottom - 2 * s)
      ..lineTo(r.right - s, r.bottom - s)
      ..lineTo(r.right - 2 * s, r.bottom - s)
      ..lineTo(r.right - 2 * s, r.bottom)
      ..lineTo(r.left + 2 * s, r.bottom)
      ..lineTo(r.left + 2 * s, r.bottom - s)
      ..lineTo(r.left + s, r.bottom - s)
      ..lineTo(r.left + s, r.bottom - 2 * s)
      ..lineTo(r.left, r.bottom - 2 * s)
      ..lineTo(r.left, r.top + 2 * s)
      ..lineTo(r.left + s, r.top + 2 * s)
      ..lineTo(r.left + s, r.top + s)
      ..lineTo(r.left + 2 * s, r.top + s)
      ..close();
  }

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    final Paint? line = stroke();
    if (rect.isEmpty || line == null) {
      return;
    }
    canvas.drawPath(polygon(rect.deflate(line.strokeWidth / 2)), line);
  }

  @override
  ShapeBorder scale(double t) => ZenPixelBorder(
    color: color,
    width: width * t,
    step: step * t,
    side: side.scale(t),
  );

  @override
  ZenPixelBorder copyWith({BorderSide? side}) => ZenPixelBorder(
    color: color,
    width: width,
    step: step,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenPixelBorder &&
      other.color == color &&
      other.width == width &&
      other.step == step &&
      other.side == side;

  @override
  int get hashCode => Object.hash(color, width, step, side);
}

/// An old desktop window: an outline, a thin colour bar along the top
/// ([bar], a gradient) and three tiny window buttons on it.
@immutable
class ZenWindowBorder extends OutlinedBorder {
  const ZenWindowBorder({
    this.borderRadius = BorderRadius.zero,
    this.color = const Color(0xFF000000),
    this.bar = const <Color>[Color(0xFF000000), Color(0xFF000000)],
    this.barHeight = 7,
    super.side,
  });

  final BorderRadius borderRadius;
  final Color color;
  final List<Color> bar;
  final double barHeight;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.fromLTRB(1, barHeight, 1, 1);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.toRRect(rect));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(
        borderRadius.toRRect(
          Rect.fromLTRB(
            rect.left + 1,
            rect.top + barHeight,
            rect.right - 1,
            rect.bottom - 1,
          ),
        ),
      );

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty) {
      return;
    }
    final RRect outer = borderRadius.toRRect(rect);
    final Rect band = Rect.fromLTWH(rect.left, rect.top, rect.width, barHeight);
    canvas
      ..save()
      ..clipRRect(outer)
      ..drawRect(
        band,
        Paint()..shader = LinearGradient(colors: bar).createShader(band),
      );
    // Three tiny window buttons on the right of the bar.
    final Paint key = Paint()..color = color.withValues(alpha: 0.55);
    for (int i = 0; i < 3; i++) {
      canvas.drawRect(
        Rect.fromLTWH(
          rect.right - 12 - i * 7 - borderRadius.topRight.x * 0.5,
          rect.top + 2,
          4,
          barHeight - 4,
        ),
        key,
      );
    }
    canvas
      ..restore()
      ..drawRRect(
        outer.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = color,
      );
  }

  @override
  ShapeBorder scale(double t) => ZenWindowBorder(
    borderRadius: borderRadius * t,
    color: color,
    bar: bar,
    barHeight: barHeight * t,
    side: side.scale(t),
  );

  @override
  ZenWindowBorder copyWith({BorderSide? side}) => ZenWindowBorder(
    borderRadius: borderRadius,
    color: color,
    bar: bar,
    barHeight: barHeight,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenWindowBorder &&
      other.borderRadius == borderRadius &&
      other.color == color &&
      _sameColors(other.bar, bar) &&
      other.barHeight == barHeight &&
      other.side == side;

  @override
  int get hashCode =>
      Object.hash(borderRadius, color, Object.hashAll(bar), barHeight, side);
}

/// A thin line shimmering through [colors] around a rounded rectangle
/// (an iridescent, holographic edge).
@immutable
class ZenSheenBorder extends OutlinedBorder {
  const ZenSheenBorder({
    this.borderRadius = BorderRadius.zero,
    this.colors = const <Color>[Color(0xFF000000), Color(0xFFFFFFFF)],
    this.width = 1.5,
    super.side,
  });

  final BorderRadius borderRadius;
  final List<Color> colors;
  final double width;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.toRRect(rect));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.toRRect(rect).deflate(width));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty || width <= 0) {
      return;
    }
    canvas.drawRRect(
      borderRadius.toRRect(rect).deflate(width / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = SweepGradient(colors: colors).createShader(rect),
    );
  }

  @override
  ShapeBorder scale(double t) => ZenSheenBorder(
    borderRadius: borderRadius * t,
    colors: colors,
    width: width * t,
    side: side.scale(t),
  );

  @override
  ZenSheenBorder copyWith({BorderSide? side}) => ZenSheenBorder(
    borderRadius: borderRadius,
    colors: colors,
    width: width,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenSheenBorder &&
      other.borderRadius == borderRadius &&
      _sameColors(other.colors, colors) &&
      other.width == width &&
      other.side == side;

  @override
  int get hashCode =>
      Object.hash(borderRadius, Object.hashAll(colors), width, side);
}

/// A rounded (or square) base with a line around it: what the frames below
/// share. [outline] is the shape the fill and the clip follow, the line
/// runs along it, [paintDetails] adds the frame's own marks.
abstract class _ZenFrameBorder extends OutlinedBorder {
  const _ZenFrameBorder({
    required this.borderRadius,
    required this.color,
    required this.width,
    super.side,
  });

  final BorderRadius borderRadius;
  final Color color;
  final double width;

  /// How far the frame reaches into the panel.
  double get inset => width;

  Path outline(Rect rect) => Path()..addRRect(borderRadius.toRRect(rect));

  void paintDetails(Canvas canvas, Rect rect) {}

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(inset);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => outline(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRRect(borderRadius.toRRect(rect).deflate(inset));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty || width <= 0) {
      return;
    }
    final Rect r = rect.deflate(width / 2);
    canvas.drawPath(
      outline(r),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..strokeJoin = StrokeJoin.round
        ..color = color,
    );
    paintDetails(canvas, r);
  }
}

/// A line with a row of stitches running inside it, like leather sewn
/// with thread ([thread]: the colour of the stitches, [color] when null).
@immutable
class ZenStitchBorder extends _ZenFrameBorder {
  const ZenStitchBorder({
    super.borderRadius = BorderRadius.zero,
    required super.color,
    super.width = 1,
    this.thread,
    this.gap = 3,
    super.side,
  });

  final Color? thread;

  /// The distance between the line and the stitches.
  final double gap;

  @override
  double get inset => width + gap + 2;

  @override
  void paintDetails(Canvas canvas, Rect rect) {
    final RRect inner = borderRadius.toRRect(rect).deflate(gap + width / 2);
    if (inner.width < 12 || inner.height < 12) {
      return;
    }
    const double stitch = 4;
    const double space = 3;
    final Path dashed = Path();
    for (final PathMetric m in (Path()..addRRect(inner)).computeMetrics()) {
      for (double d = 0; d < m.length; d += stitch + space) {
        dashed.addPath(
          m.extractPath(d, math.min(d + stitch, m.length)),
          Offset.zero,
        );
      }
    }
    canvas.drawPath(
      dashed,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..strokeCap = StrokeCap.round
        ..color = thread ?? color,
    );
  }

  @override
  ShapeBorder scale(double t) => ZenStitchBorder(
    borderRadius: borderRadius * t,
    color: color,
    width: width * t,
    thread: thread,
    gap: gap * t,
    side: side.scale(t),
  );

  @override
  ZenStitchBorder copyWith({BorderSide? side}) => ZenStitchBorder(
    borderRadius: borderRadius,
    color: color,
    width: width,
    thread: thread,
    gap: gap,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenStitchBorder &&
      other.borderRadius == borderRadius &&
      other.color == color &&
      other.width == width &&
      other.thread == thread &&
      other.gap == gap &&
      other.side == side;

  @override
  int get hashCode =>
      Object.hash(borderRadius, color, width, thread, gap, side);
}

/// A leaf: two opposite corners deeply rounded, the other two almost
/// square, the long curves drawn heavier in [vein].
@immutable
class ZenLeafBorder extends _ZenFrameBorder {
  const ZenLeafBorder({
    required super.borderRadius,
    required super.color,
    required this.vein,
    super.width = 1,
    super.side,
  });

  /// A leaf of [radius] in the long corners.
  factory ZenLeafBorder.of({
    required double radius,
    required Color color,
    required Color vein,
  }) => ZenLeafBorder(
    borderRadius: BorderRadius.only(
      topLeft: Radius.circular(radius),
      bottomRight: Radius.circular(radius),
      topRight: Radius.circular(radius * 0.2),
      bottomLeft: Radius.circular(radius * 0.2),
    ),
    color: color,
    vein: vein,
  );

  final Color vein;

  /// A little air inside the line, so the vein in the long corners does not
  /// touch what is written there.
  @override
  double get inset => width + 3;

  @override
  void paintDetails(Canvas canvas, Rect rect) {
    final RRect rr = borderRadius.toRRect(rect).scaleRadii();
    final Path arcs = Path();
    if (rr.tlRadiusX > 1) {
      arcs
        ..moveTo(rect.left, rect.top + rr.tlRadiusY)
        ..arcTo(
          Rect.fromLTWH(
            rect.left,
            rect.top,
            rr.tlRadiusX * 2,
            rr.tlRadiusY * 2,
          ),
          math.pi,
          math.pi / 2,
          false,
        );
    }
    if (rr.brRadiusX > 1) {
      arcs
        ..moveTo(rect.right, rect.bottom - rr.brRadiusY)
        ..arcTo(
          Rect.fromLTRB(
            rect.right - rr.brRadiusX * 2,
            rect.bottom - rr.brRadiusY * 2,
            rect.right,
            rect.bottom,
          ),
          0,
          math.pi / 2,
          false,
        );
    }
    canvas.drawPath(
      arcs,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 2.2
        ..strokeCap = StrokeCap.round
        ..color = vein,
    );
  }

  @override
  ShapeBorder scale(double t) => ZenLeafBorder(
    borderRadius: borderRadius * t,
    color: color,
    vein: vein,
    width: width * t,
    side: side.scale(t),
  );

  @override
  ZenLeafBorder copyWith({BorderSide? side}) => ZenLeafBorder(
    borderRadius: borderRadius,
    color: color,
    vein: vein,
    width: width,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenLeafBorder &&
      other.borderRadius == borderRadius &&
      other.color == color &&
      other.vein == vein &&
      other.width == width &&
      other.side == side;

  @override
  int get hashCode => Object.hash(borderRadius, color, vein, width, side);
}

/// An edge of little round scallops, like a doily or the rim of a pie
/// ([bite]: how deep each scallop is). A panel too small for them is a
/// plain rounded rectangle.
@immutable
class ZenScallopBorder extends _ZenFrameBorder {
  const ZenScallopBorder({
    required super.color,
    super.width = 1,
    this.bite = 3,
    super.side,
  }) : super(borderRadius: BorderRadius.zero);

  final double bite;

  @override
  double get inset => bite + width + 2;

  @override
  Path outline(Rect rect) {
    if (rect.shortestSide < bite * 8) {
      return Path()
        ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(bite * 2)));
    }
    final Rect base = rect.deflate(bite);
    final Path path = Path()..moveTo(base.left, base.top);
    void edge(Offset from, Offset to) {
      final double length = (to - from).distance;
      final int count = math.max(1, (length / (bite * 4.5)).round());
      final Offset step = (to - from) / count.toDouble();
      final double chord = length / count;
      // The circle through the chord with a sagitta of [bite].
      final double radius = (chord * chord / 4 + bite * bite) / (2 * bite);
      for (int i = 1; i <= count; i++) {
        path.arcToPoint(
          from + step * i.toDouble(),
          radius: Radius.circular(radius),
        );
      }
    }

    edge(base.topLeft, base.topRight);
    edge(base.topRight, base.bottomRight);
    edge(base.bottomRight, base.bottomLeft);
    edge(base.bottomLeft, base.topLeft);
    return path..close();
  }

  @override
  ShapeBorder scale(double t) => ZenScallopBorder(
    color: color,
    width: width * t,
    bite: bite * t,
    side: side.scale(t),
  );

  @override
  ZenScallopBorder copyWith({BorderSide? side}) => ZenScallopBorder(
    color: color,
    width: width,
    bite: bite,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenScallopBorder &&
      other.color == color &&
      other.width == width &&
      other.bite == bite &&
      other.side == side;

  @override
  int get hashCode => Object.hash(color, width, bite, side);
}

/// A ticket: a rounded rectangle with a half circle bitten out of the
/// middle of each side ([notch]: its radius). A panel too small for the
/// bites is a plain rounded rectangle.
@immutable
class ZenNotchBorder extends _ZenFrameBorder {
  const ZenNotchBorder({
    super.borderRadius = BorderRadius.zero,
    required super.color,
    super.width = 1,
    this.notch = 6,
    super.side,
  });

  final double notch;

  @override
  double get inset => notch + 2;

  @override
  Path outline(Rect rect) {
    final Path card = Path()..addRRect(borderRadius.toRRect(rect));
    if (rect.height < notch * 6 || rect.width < notch * 8) {
      return card;
    }
    final Path bites = Path()
      ..addOval(Rect.fromCircle(center: rect.centerLeft, radius: notch))
      ..addOval(Rect.fromCircle(center: rect.centerRight, radius: notch));
    return Path.combine(PathOperation.difference, card, bites);
  }

  @override
  ShapeBorder scale(double t) => ZenNotchBorder(
    borderRadius: borderRadius * t,
    color: color,
    width: width * t,
    notch: notch * t,
    side: side.scale(t),
  );

  @override
  ZenNotchBorder copyWith({BorderSide? side}) => ZenNotchBorder(
    borderRadius: borderRadius,
    color: color,
    width: width,
    notch: notch,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenNotchBorder &&
      other.borderRadius == borderRadius &&
      other.color == color &&
      other.width == width &&
      other.notch == notch &&
      other.side == side;

  @override
  int get hashCode => Object.hash(borderRadius, color, width, notch, side);
}

/// A drawing-board frame: a fine line, heavier corner marks and a ruler
/// scale along the top edge.
@immutable
class ZenBlueprintBorder extends _ZenFrameBorder {
  const ZenBlueprintBorder({
    required super.color,
    super.width = 1,
    this.mark = 10,
    super.side,
  }) : super(borderRadius: BorderRadius.zero);

  /// The length of the corner marks.
  final double mark;

  @override
  double get inset => width + 1;

  @override
  void paintDetails(Canvas canvas, Rect rect) {
    if (rect.width < mark * 3 || rect.height < mark * 3) {
      return;
    }
    final Path corners = Path();
    for (final (Offset c, double sx, double sy) in <(Offset, double, double)>[
      (rect.topLeft, 1, 1),
      (rect.topRight, -1, 1),
      (rect.bottomLeft, 1, -1),
      (rect.bottomRight, -1, -1),
    ]) {
      corners
        ..moveTo(c.dx + mark * sx, c.dy)
        ..lineTo(c.dx, c.dy)
        ..lineTo(c.dx, c.dy + mark * sy);
    }
    canvas.drawPath(
      corners,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width * 2.2
        ..strokeCap = StrokeCap.square
        ..color = color,
    );
    // The ruler: a tick every 6, a longer one every 30.
    final Paint tick = Paint()
      ..strokeWidth = width
      ..color = color.withValues(alpha: 0.55);
    int i = 0;
    for (
      double x = rect.left + mark * 1.6;
      x < rect.right - mark * 1.6;
      x += 6
    ) {
      final double h = i % 5 == 0 ? 5 : 2.5;
      canvas.drawLine(
        Offset(x, rect.top + width),
        Offset(x, rect.top + width + h),
        tick,
      );
      i++;
    }
  }

  @override
  ShapeBorder scale(double t) => ZenBlueprintBorder(
    color: color,
    width: width * t,
    mark: mark * t,
    side: side.scale(t),
  );

  @override
  ZenBlueprintBorder copyWith({BorderSide? side}) => ZenBlueprintBorder(
    color: color,
    width: width,
    mark: mark,
    side: side ?? this.side,
  );

  @override
  bool operator ==(Object other) =>
      other is ZenBlueprintBorder &&
      other.color == color &&
      other.width == width &&
      other.mark == mark &&
      other.side == side;

  @override
  int get hashCode => Object.hash(color, width, mark, side);
}

bool _sameColors(List<Color> a, List<Color> b) {
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// A square slider thumb (the sharp looks): a small block, bevelled when
/// [light] and [dark] are given.
class ZenSquareThumbShape extends SliderComponentShape {
  const ZenSquareThumbShape({this.size = 14, this.light, this.dark});

  final double size;
  final Color? light;
  final Color? dark;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => Size.square(size);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final Canvas canvas = context.canvas;
    final Rect r = Rect.fromCenter(center: center, width: size, height: size);
    canvas.drawRect(
      r,
      Paint()..color = sliderTheme.thumbColor ?? const Color(0xFF888888),
    );
    final Color? l = light;
    final Color? d = dark;
    if (l != null && d != null) {
      ZenBevelBorder(light: l, dark: d).paint(canvas, r);
    }
  }
}
