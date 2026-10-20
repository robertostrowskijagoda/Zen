import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The component style shared by the fixed palettes (Cisza, Neon nocą, Las,
/// Zmierzch): calm motion and thin lit accents. Klasyczny does not use any
/// of it. Every animation here stands still when the system asks for
/// reduced motion ([ZenMotion.allowedIn]).

/// Page transition: the new screen fades in while rising a few pixels.
class ZenSoftPageTransitionsBuilder extends PageTransitionsBuilder {
  const ZenSoftPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      return child;
    }
    return FadeTransition(
      opacity: animation.drive(CurveTween(curve: Curves.easeOutCubic)),
      child: SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(0, 0.025),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)),
        ),
        child: child,
      ),
    );
  }
}

/// Tab indicator: a short rounded bar under the label, with a glow when
/// [glow] is above 0. The tab bar slides it from tab to tab.
@immutable
class ZenTabIndicator extends Decoration {
  const ZenTabIndicator({
    required this.color,
    this.glow = 0,
    this.thickness = 3,
  });

  final Color color;
  final double glow;
  final double thickness;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _ZenTabIndicatorPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is ZenTabIndicator &&
      other.color == color &&
      other.glow == glow &&
      other.thickness == thickness;

  @override
  int get hashCode => Object.hash(color, glow, thickness);
}

class _ZenTabIndicatorPainter extends BoxPainter {
  _ZenTabIndicatorPainter(this.decoration, super.onChanged);

  final ZenTabIndicator decoration;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final Size? size = configuration.size;
    if (size == null || size.isEmpty) {
      return;
    }
    final double t = decoration.thickness;
    final RRect bar = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        offset.dx + 4,
        offset.dy + size.height - t,
        math.max(0, size.width - 8),
        t,
      ),
      Radius.circular(t),
    );
    if (decoration.glow > 0) {
      canvas.drawRRect(
        bar.inflate(1),
        Paint()
          ..color = decoration.color.withValues(
            alpha: (0.6 * decoration.glow).clamp(0.0, 1.0),
          )
          ..maskFilter = MaskFilter.blur(
            BlurStyle.normal,
            3 + 3 * decoration.glow,
          ),
      );
    }
    canvas.drawRRect(bar, Paint()..color = decoration.color);
  }
}

/// The focused text field of the neon palette: the outline plus a soft
/// glow of [glowColor] around it.
class ZenGlowInputBorder extends OutlineInputBorder {
  const ZenGlowInputBorder({
    super.borderSide,
    super.borderRadius,
    super.gapPadding,
    this.glowColor = const Color(0x00000000),
    this.glow = 0,
  });

  final Color glowColor;
  final double glow;

  @override
  ZenGlowInputBorder copyWith({
    BorderSide? borderSide,
    BorderRadius? borderRadius,
    double? gapPadding,
  }) {
    return ZenGlowInputBorder(
      borderSide: borderSide ?? this.borderSide,
      borderRadius: borderRadius ?? this.borderRadius,
      gapPadding: gapPadding ?? this.gapPadding,
      glowColor: glowColor,
      glow: glow,
    );
  }

  @override
  ZenGlowInputBorder scale(double t) {
    return ZenGlowInputBorder(
      borderSide: borderSide.scale(t),
      borderRadius: borderRadius * t,
      gapPadding: gapPadding * t,
      glowColor: glowColor,
      glow: glow,
    );
  }

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is OutlineInputBorder) {
      return ZenGlowInputBorder(
        borderRadius: BorderRadius.lerp(a.borderRadius, borderRadius, t)!,
        borderSide: BorderSide.lerp(a.borderSide, borderSide, t),
        gapPadding: lerpDouble(a.gapPadding, gapPadding, t)!,
        glowColor: glowColor,
        glow: lerpDouble(a is ZenGlowInputBorder ? a.glow : 0, glow, t)!,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (glow > 0) {
      canvas.drawRRect(
        borderRadius.toRRect(rect),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = borderSide.width + 2
          ..color = glowColor.withValues(alpha: (0.55 * glow).clamp(0.0, 1.0))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 3 + 4 * glow),
      );
    }
    super.paint(
      canvas,
      rect,
      gapStart: gapStart,
      gapExtent: gapExtent,
      gapPercentage: gapPercentage,
      textDirection: textDirection,
    );
  }

  @override
  bool operator ==(Object other) =>
      super == other &&
      other is ZenGlowInputBorder &&
      other.glow == glow &&
      other.glowColor == glowColor;

  @override
  int get hashCode => Object.hash(super.hashCode, glow, glowColor);
}

/// An unread badge that breathes slowly (a soft swell and, with neon, a
/// glow of [color]). Only in the fixed palettes; in Klasyczny, under
/// reduced motion and in tests it stands still.
class ZenSoftPulse extends StatefulWidget {
  const ZenSoftPulse({required this.child, required this.color, super.key});

  final Widget child;
  final Color color;

  @override
  State<ZenSoftPulse> createState() => _ZenSoftPulseState();
}

class _ZenSoftPulseState extends State<ZenSoftPulse>
    with SingleTickerProviderStateMixin {
  AnimationController? _breath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool animate =
        ZenColors.of(context).concept && ZenMotion.allowedIn(context);
    if (animate && _breath == null) {
      _breath = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2400),
      )..repeat(reverse: true);
    } else if (!animate && _breath != null) {
      _breath!.dispose();
      _breath = null;
    }
  }

  @override
  void dispose() {
    _breath?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (!zen.concept) {
      return widget.child;
    }
    final AnimationController? breath = _breath;
    if (breath == null) {
      return _frame(zen, 0.5);
    }
    return AnimatedBuilder(
      animation: breath,
      builder: (BuildContext context, Widget? _) =>
          _frame(zen, Curves.easeInOutSine.transform(breath.value)),
    );
  }

  Widget _frame(ZenColors zen, double v) {
    final double glow = math.max(zen.glow, 0.35);
    return Transform.scale(
      scale: 1 + 0.06 * v,
      child: DecoratedBox(
        decoration: ShapeDecoration(
          shape: const StadiumBorder(),
          shadows: <BoxShadow>[
            BoxShadow(
              color: widget.color.withValues(
                alpha: ((0.12 + 0.33 * v) * glow).clamp(0.0, 1.0),
              ),
              blurRadius: 6 + 8 * v,
              spreadRadius: -1,
            ),
          ],
        ),
        child: widget.child,
      ),
    );
  }
}
