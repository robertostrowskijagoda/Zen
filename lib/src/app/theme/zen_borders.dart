import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The outlines a look can draw around its panels, besides the plain
/// rounded rectangle: a bevelled chrome frame and an elegant double line.

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
    super.side,
  });

  /// The frame in the colours of [zen].
  factory ZenBevelBorder.of(ZenColors zen, {bool sunken = false}) =>
      ZenBevelBorder(
        light: zen.outlineStrong,
        dark: zen.surfaceSunk,
        sunken: sunken,
      );

  final Color light;
  final Color dark;
  final double width;
  final bool sunken;

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
  }

  @override
  ShapeBorder scale(double t) => ZenBevelBorder(
    light: light,
    dark: dark,
    width: width * t,
    sunken: sunken,
    side: side.scale(t),
  );

  @override
  ZenBevelBorder copyWith({BorderSide? side}) => ZenBevelBorder(
    light: light,
    dark: dark,
    width: width,
    sunken: sunken,
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
      other.side == side;

  @override
  int get hashCode => Object.hash(light, dark, width, sunken, side);
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
    super.side,
  });

  final BorderRadius borderRadius;
  final Color color;

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
  }

  @override
  ShapeBorder scale(double t) => ZenDoubleBorder(
    borderRadius: borderRadius * t,
    color: color,
    inner: inner,
    gap: gap * t,
    width: width * t,
    side: side.scale(t),
  );

  @override
  ZenDoubleBorder copyWith({BorderSide? side}) => ZenDoubleBorder(
    borderRadius: borderRadius,
    color: color,
    inner: inner,
    gap: gap,
    width: width,
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
      other.side == side;

  @override
  int get hashCode => Object.hash(borderRadius, color, inner, gap, width, side);
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
