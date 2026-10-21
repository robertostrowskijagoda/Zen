import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The component style shared by the fixed palettes: their motion and lit
/// accents, picked by the palette's [ZenLook]. Klasyczny does not use any
/// of it. Every animation
/// here stands still when the system asks for reduced motion
/// ([ZenMotion.allowedIn]).

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

/// Wraps the transition of [inner] for see-through pages (a look with a
/// backdrop): the page below fades out while a new page covers it, so two
/// pages never show through each other. Under reduced motion the page below
/// is hidden at once.
class ZenFadeBehindTransitionsBuilder extends PageTransitionsBuilder {
  const ZenFadeBehindTransitionsBuilder(this.inner);

  final PageTransitionsBuilder inner;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final Widget page = inner.buildTransitions<T>(
      route,
      context,
      animation,
      secondaryAnimation,
      child,
    );
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return FadeTransition(
      opacity: still
          ? secondaryAnimation.drive(const _HiddenOnceCovered())
          : ReverseAnimation(secondaryAnimation),
      child: page,
    );
  }
}

class _HiddenOnceCovered extends Animatable<double> {
  const _HiddenOnceCovered();

  @override
  double transform(double t) => t > 0 ? 0 : 1;
}

/// Tab indicator: a short bar under the label (rounded unless [rounded] is
/// off), with a glow when [glow] is above 0. With [sweepColor] the bar is a
/// tube of [color] and [sweepColor] whose colours are laid out along the
/// whole tab bar, so a light runs along it whenever it slides to another
/// tab. The tab bar slides it from tab to tab.
@immutable
class ZenTabIndicator extends Decoration {
  const ZenTabIndicator({
    required this.color,
    this.glow = 0,
    this.thickness = 3,
    this.sweepColor,
    this.rounded = true,
  });

  final Color color;
  final double glow;
  final double thickness;
  final Color? sweepColor;
  final bool rounded;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _ZenTabIndicatorPainter(this, onChanged);

  @override
  bool operator ==(Object other) =>
      other is ZenTabIndicator &&
      other.color == color &&
      other.glow == glow &&
      other.thickness == thickness &&
      other.sweepColor == sweepColor &&
      other.rounded == rounded;

  @override
  int get hashCode => Object.hash(color, glow, thickness, sweepColor, rounded);
}

class _ZenTabIndicatorPainter extends BoxPainter {
  _ZenTabIndicatorPainter(this.decoration, super.onChanged);

  final ZenTabIndicator decoration;

  /// One period of the sweep gradient, in logical pixels along the bar.
  static const double _sweepSpan = 220;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final Size? size = configuration.size;
    if (size == null || size.isEmpty) {
      return;
    }
    final double t = decoration.thickness;
    final Rect rect = Rect.fromLTWH(
      offset.dx + 4,
      offset.dy + size.height - t,
      math.max(0, size.width - 8),
      t,
    );
    final RRect bar = RRect.fromRectAndRadius(
      rect,
      Radius.circular(decoration.rounded ? t : 0),
    );
    final Color? sweep = decoration.sweepColor;
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
    final Paint fill = Paint()..color = decoration.color;
    if (sweep != null) {
      // Anchored to the tab bar, not to the bar: as the bar slides, the
      // light runs along it.
      fill.shader = LinearGradient(
        colors: <Color>[
          decoration.color,
          Color.lerp(decoration.color, const Color(0xFFFFFFFF), 0.7)!,
          sweep,
          decoration.color,
        ],
        stops: const <double>[0, 0.18, 0.5, 1],
        tileMode: TileMode.mirror,
      ).createShader(Rect.fromLTWH(0, rect.top, _sweepSpan, t));
    }
    canvas.drawRRect(bar, fill);
  }
}

/// Neon page transition: the new screen is wiped in behind a glowing edge
/// and lights up like a tube (two quick flickers, once). Reduced motion
/// shows it at once.
class ZenNeonWipeTransitionsBuilder extends PageTransitionsBuilder {
  const ZenNeonWipeTransitionsBuilder();

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
    return _ZenNeonWipe(
      animation: animation,
      color: ZenColors.of(context).accent,
      child: child,
    );
  }
}

class _ZenNeonWipe extends StatelessWidget {
  const _ZenNeonWipe({
    required this.animation,
    required this.color,
    required this.child,
  });

  final Animation<double> animation;
  final Color color;
  final Widget child;

  /// Brightness of a tube lighting up over [t] (0..1): two failed
  /// ignitions, then steady.
  static double flicker(double t) {
    if (t >= 0.62) {
      return 1;
    }
    const List<double> steps = <double>[
      0.0,
      0.75,
      0.2,
      0.9,
      0.45,
      1.0,
      0.8,
      1.0,
    ];
    final int i = (t / 0.62 * steps.length).floor();
    return steps[math.max(0, math.min(steps.length - 1, i))];
  }

  @override
  Widget build(BuildContext context) {
    // The tree keeps one shape through the whole transition, so the page
    // below never loses its state.
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? page) {
        final double v = animation.value;
        final double wipe = Curves.easeOutCubic.transform(
          (v / 0.7).clamp(0.0, 1.0),
        );
        final bool done = v >= 1;
        final bool forward = animation.status != AnimationStatus.reverse;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            ClipRect(
              clipBehavior: done ? Clip.none : Clip.hardEdge,
              clipper: _WipeClipper(done ? 1 : wipe),
              child: Opacity(
                opacity: done || !forward ? 1 : flicker(v),
                child: page,
              ),
            ),
            if (!done && wipe > 0 && wipe < 1)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment(-1 + 2 * wipe, 0),
                    child: SizedBox(
                      width: 2,
                      height: double.infinity,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: color,
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: color.withValues(alpha: 0.85),
                              blurRadius: 10,
                              spreadRadius: 1,
                            ),
                            BoxShadow(
                              color: color.withValues(alpha: 0.35),
                              blurRadius: 28,
                              spreadRadius: 4,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _WipeClipper extends CustomClipper<Rect> {
  const _WipeClipper(this.progress);

  final double progress;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * progress, size.height);

  @override
  bool shouldReclip(_WipeClipper oldClipper) => oldClipper.progress != progress;
}

/// Retro page transition: a fade in four hard steps, like a low frame
/// rate.
class ZenSteppedPageTransitionsBuilder extends PageTransitionsBuilder {
  const ZenSteppedPageTransitionsBuilder();

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
      opacity: animation.drive(const _StepTween(4)),
      child: child,
    );
  }
}

class _StepTween extends Animatable<double> {
  const _StepTween(this.steps);

  final int steps;

  @override
  double transform(double t) => t >= 1 ? 1 : (t * steps).floor() / steps;
}

/// Lights [child] up once like a neon tube (a few quick flickers, then
/// steady) when it first appears, in a look with [ZenLook.flickerOn].
/// Elsewhere, under reduced motion and in tests it is simply shown.
class ZenFlickerOn extends StatefulWidget {
  const ZenFlickerOn({required this.child, super.key});

  final Widget child;

  @override
  State<ZenFlickerOn> createState() => _ZenFlickerOnState();
}

class _ZenFlickerOnState extends State<ZenFlickerOn>
    with SingleTickerProviderStateMixin {
  AnimationController? _on;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) {
      return;
    }
    _decided = true;
    if (ZenLook.of(context).flickerOn && ZenMotion.allowedIn(context)) {
      _on = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 560),
      )..forward();
    }
  }

  @override
  void dispose() {
    _on?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AnimationController? on = _on;
    if (on == null) {
      return widget.child;
    }
    return AnimatedBuilder(
      animation: on,
      child: widget.child,
      builder: (BuildContext context, Widget? child) => Opacity(
        opacity: on.isCompleted ? 1 : _ZenNeonWipe.flicker(on.value * 0.62),
        child: child,
      ),
    );
  }
}

/// A glow of [color] that breathes slowly behind [child] (the primary
/// action) while [active], in a look with [ZenLook.breathe]. The glow is
/// its own layer: the child is never repainted for it. Elsewhere, under
/// reduced motion and in tests the glow stands still (or is absent).
class ZenBreathingGlow extends StatefulWidget {
  const ZenBreathingGlow({
    required this.child,
    this.color,
    this.active = true,
    this.shape = const CircleBorder(),
    super.key,
  });

  final Widget child;

  /// The accent when null.
  final Color? color;
  final bool active;
  final ShapeBorder shape;

  @override
  State<ZenBreathingGlow> createState() => _ZenBreathingGlowState();
}

// Not the single-ticker mixin: the controller is dropped when the look
// stops breathing and made again when it breathes once more.
class _ZenBreathingGlowState extends State<ZenBreathingGlow>
    with TickerProviderStateMixin {
  AnimationController? _breath;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ZenBreathingGlow oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    final bool animate =
        widget.active &&
        ZenLook.of(context).breathe &&
        ZenMotion.allowedIn(context);
    if (animate && _breath == null) {
      _breath = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 2200),
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
    final ZenLook look = ZenLook.of(context);
    if (!look.breathe) {
      return widget.child;
    }
    final ZenColors zen = ZenColors.of(context);
    final Color color = widget.color ?? zen.accent;
    final AnimationController? breath = _breath;
    Widget glow(double v) => DecoratedBox(
      decoration: ShapeDecoration(
        shape: widget.shape,
        shadows: widget.active
            ? <BoxShadow>[
                BoxShadow(
                  color: color.withValues(
                    alpha: ((0.30 + 0.45 * v) * zen.glow).clamp(0.0, 1.0),
                  ),
                  blurRadius: 8 + 14 * v,
                  spreadRadius: -1 + 2 * v,
                ),
              ]
            : null,
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: breath == null
                  ? glow(0.5)
                  : AnimatedBuilder(
                      animation: breath,
                      builder: (BuildContext context, Widget? _) =>
                          glow(Curves.easeInOutSine.transform(breath.value)),
                    ),
            ),
          ),
        ),
        RepaintBoundary(child: widget.child),
      ],
    );
  }
}

/// A slow field of drifting sparks over a faint grid behind [child] (hero
/// cards, empty states), in a look with [ZenLook.ambient]. One ticker, its
/// own layers (the grid is painted once, the sparks repaint without a
/// rebuild or layout), paused off screen; still under reduced motion and
/// in tests.
class ZenAmbientField extends StatefulWidget {
  const ZenAmbientField({required this.child, this.tone, super.key});

  final Widget child;

  /// The accent when null.
  final Color? tone;

  @override
  State<ZenAmbientField> createState() => _ZenAmbientFieldState();
}

class _ZenAmbientFieldState extends State<ZenAmbientField>
    with TickerProviderStateMixin {
  /// One loop of the field: every spark's path repeats exactly in it.
  static const Duration _loop = Duration(seconds: 60);

  AnimationController? _clock;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool animate =
        ZenLook.of(context).ambient && ZenMotion.allowedIn(context);
    if (animate && _clock == null) {
      _clock = AnimationController(vsync: this, duration: _loop)..repeat();
    } else if (!animate && _clock != null) {
      _clock!.dispose();
      _clock = null;
    }
  }

  @override
  void dispose() {
    _clock?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!ZenLook.of(context).ambient) {
      return widget.child;
    }
    final ZenColors zen = ZenColors.of(context);
    final Color tone = widget.tone ?? zen.accent;
    final Animation<double> clock =
        _clock ?? const AlwaysStoppedAnimation<double>(0.18);
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _GridPainter(tone.withValues(alpha: 0.07)),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _SparkPainter(
                  clock: clock,
                  tone: tone,
                  partner: zen.accentSecondary,
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  const _GridPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // The grid fades out towards the edges.
    final Paint line = Paint()
      ..strokeWidth = 1
      ..shader = RadialGradient(
        colors: <Color>[color, color.withValues(alpha: 0)],
      ).createShader(Offset.zero & size);
    const double step = 26;
    for (double x = step / 2; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), line);
    }
    for (double y = step / 2; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), line);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) => oldDelegate.color != color;
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.clock,
    required this.tone,
    required this.partner,
  }) : super(repaint: clock);

  final Animation<double> clock;
  final Color tone;
  final Color partner;

  static const int _count = 14;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final double phase = clock.value;
    final Paint halo = Paint();
    final Paint core = Paint();
    for (int i = 0; i < _count; i++) {
      // Whole cycles per loop, so the field repeats without a seam.
      final int rise = 1 + (i * 7) % 3;
      final int sway = 2 + (i * 5) % 4;
      final double seed = (i * 0.6180339887) % 1;
      final double y = (seed - phase * rise) % 1;
      final double x =
          (seed * 0.86 + 0.07) +
          0.035 * math.sin(2 * math.pi * (phase * sway + seed));
      // Fade in at the bottom, out at the top.
      final double life = math.sin(math.pi * y).clamp(0.0, 1.0);
      final Color c = i % 5 == 2 ? partner : tone;
      final Offset p = Offset(x * size.width, y * size.height);
      final double r = 1.1 + (i % 3) * 0.5;
      halo.color = c.withValues(alpha: 0.16 * life);
      core.color = c.withValues(alpha: 0.75 * life);
      canvas
        ..drawCircle(p, r * 3.2, halo)
        ..drawCircle(p, r, core);
    }
  }

  @override
  bool shouldRepaint(_SparkPainter oldDelegate) =>
      oldDelegate.clock != clock ||
      oldDelegate.tone != tone ||
      oldDelegate.partner != partner;
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
    with TickerProviderStateMixin {
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

/// Glitch page transition (the hacker and city looks): for the first part
/// of the push the page flickers in a few hard steps, shifted sideways with
/// bright slices and scan lines across it, then settles. Reduced motion
/// shows it at once.
class ZenGlitchPageTransitionsBuilder extends PageTransitionsBuilder {
  const ZenGlitchPageTransitionsBuilder();

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
    final ZenColors zen = ZenColors.of(context);
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? page) {
        final double v = animation.value;
        final bool done =
            v >= 0.5 || animation.status == AnimationStatus.reverse;
        // Six hard steps: jumps sideways and flicker.
        final int step = (v / 0.5 * 6).floor().clamp(0, 5);
        const List<double> shift = <double>[-14, 9, -5, 12, -3, 0];
        const List<double> light = <double>[0.2, 0.7, 0.35, 0.9, 0.6, 1];
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            Opacity(
              opacity: done ? 1 : light[step],
              child: Transform.translate(
                offset: Offset(done ? 0 : shift[step], 0),
                child: page,
              ),
            ),
            if (!done)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _GlitchSlicesPainter(
                      seed: step,
                      color: zen.accent,
                      partner: zen.accentSecondary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GlitchSlicesPainter extends CustomPainter {
  const _GlitchSlicesPainter({
    required this.seed,
    required this.color,
    required this.partner,
  });

  final int seed;
  final Color color;
  final Color partner;

  @override
  void paint(Canvas canvas, Size size) {
    final math.Random r = math.Random(seed * 31 + 7);
    final Paint p = Paint();
    // Scan lines over the whole page.
    p.color = color.withValues(alpha: 0.10);
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), p);
    }
    // A few bright slices, shifted.
    for (int i = 0; i < 4; i++) {
      final double y = r.nextDouble() * size.height;
      final double h = 3 + r.nextDouble() * 14;
      final double dx = (r.nextDouble() - 0.5) * 40;
      p.color = (i.isEven ? color : partner).withValues(alpha: 0.28);
      canvas.drawRect(Rect.fromLTWH(dx, y, size.width, h), p);
    }
  }

  @override
  bool shouldRepaint(_GlitchSlicesPainter oldDelegate) =>
      oldDelegate.seed != seed ||
      oldDelegate.color != color ||
      oldDelegate.partner != partner;
}

/// Light-trail page transition: the page slides in from the side while a
/// bright streak of the accent races across it ahead of it.
class ZenStreakPageTransitionsBuilder extends PageTransitionsBuilder {
  const ZenStreakPageTransitionsBuilder();

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
    final ZenColors zen = ZenColors.of(context);
    final Animation<double> eased = animation.drive(
      CurveTween(curve: Curves.easeOutExpo),
    );
    return AnimatedBuilder(
      animation: animation,
      child: child,
      builder: (BuildContext context, Widget? page) {
        final double v = eased.value;
        final bool streak =
            animation.value < 0.7 &&
            animation.status != AnimationStatus.reverse;
        return Stack(
          fit: StackFit.passthrough,
          children: <Widget>[
            FractionalTranslation(
              translation: Offset((1 - v) * 0.12, 0),
              child: Opacity(opacity: v.clamp(0.0, 1.0), child: page),
            ),
            if (streak)
              Positioned.fill(
                child: IgnorePointer(
                  child: Align(
                    alignment: Alignment(-1.4 + 2.8 * v, -0.2),
                    child: FractionallySizedBox(
                      widthFactor: 0.6,
                      child: Container(
                        height: 3,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: <Color>[
                              zen.accentSecondary.withValues(alpha: 0),
                              zen.accentSecondary,
                              zen.accent,
                            ],
                          ),
                          boxShadow: zen.neonGlow(zen.accent, radius: 12),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Bubble page transition (the deep-sea look): the page swells in softly
/// from a little smaller, with a light overshoot.
class ZenBubblePageTransitionsBuilder extends PageTransitionsBuilder {
  const ZenBubblePageTransitionsBuilder();

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
      opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
      child: ScaleTransition(
        scale: animation.drive(
          Tween<double>(
            begin: 0.92,
            end: 1,
          ).chain(CurveTween(curve: Curves.easeOutBack)),
        ),
        child: child,
      ),
    );
  }
}
