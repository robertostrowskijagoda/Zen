import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_effects.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The backdrops of the looks ([ZenBackdrop]): digital rain, a neon floor
/// grid, monitor scan lines, slowly drifting blooms of colour and the
/// rest of the effects ([ZenEffects]). They are drawn
/// behind every page (the pages of such a look are see-through), never on
/// top of panels: text sits on cards and groups above them, and the
/// strongest mark of an effect stays faint against the background
/// ([ZenBackdropPainter.maxAlpha]).
///
/// Cost: one layer of its own, repainted by a timer at a low frame rate
/// (12–20 frames a second, no rebuilds or layout), stopped while the app is
/// in the background, under reduced motion and in tests (a still frame is
/// shown then).

/// Puts the backdrop of the current look behind [child] (the navigator).
/// The tree keeps the same shape for every look, so switching themes never
/// rebuilds the screens below.
class ZenBackdropHost extends StatelessWidget {
  const ZenBackdropHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZenLook look = ZenLook.of(context);
    final ZenColors zen = ZenColors.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(
            child: look.backdrop == ZenBackdrop.none
                ? const SizedBox.shrink()
                : ColoredBox(
                    color: zen.background,
                    child: ZenBackdropLayer(kind: look.backdrop, colors: zen),
                  ),
          ),
        ),
        child,
      ],
    );
  }
}

/// One backdrop of [kind] in [colors], animated at a low frame rate when
/// [still] is off and motion is allowed (see the file comment).
class ZenBackdropLayer extends StatefulWidget {
  const ZenBackdropLayer({
    required this.kind,
    required this.colors,
    this.still = false,
    super.key,
  });

  final ZenBackdrop kind;
  final ZenColors colors;

  /// Always a still frame (the theme picker's previews).
  final bool still;

  /// How many backdrops animate right now (a timer each).
  @visibleForTesting
  static int running = 0;

  /// Frames a second of [kind].
  static int framesPerSecond(ZenBackdrop kind) => switch (kind) {
    ZenBackdrop.rain => 12,
    ZenBackdrop.grid => 20,
    ZenBackdrop.scanlines => 12,
    _ => ZenEffects.fps(kind),
  };

  @override
  State<ZenBackdropLayer> createState() => _ZenBackdropLayerState();
}

class _ZenBackdropLayerState extends State<ZenBackdropLayer>
    with WidgetsBindingObserver {
  /// The moment shown when the backdrop stands still.
  static const double _stillSeconds = 7.3;

  final ZenBackdropClock _clock = ZenBackdropClock(_stillSeconds);
  final Stopwatch _watch = Stopwatch();
  Timer? _timer;
  bool _allowed = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final AppLifecycleState? state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed = ZenMotion.allowedIn(context);
    _sync();
  }

  @override
  void didUpdateWidget(ZenBackdropLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.kind != widget.kind && _timer != null) {
      // Another effect: its own frame rate.
      _stopTimer();
    }
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() => _foreground = state == AppLifecycleState.resumed);
    _sync();
  }

  bool get _animate =>
      !widget.still &&
      _allowed &&
      _foreground &&
      ZenBackdropLayer.framesPerSecond(widget.kind) > 0;

  void _sync() {
    if (_animate && _timer == null) {
      final int fps = ZenBackdropLayer.framesPerSecond(widget.kind);
      _watch.start();
      ZenBackdropLayer.running++;
      _timer = Timer.periodic(Duration(milliseconds: 1000 ~/ fps), (_) {
        _clock.seconds = _stillSeconds + _watch.elapsedMicroseconds / 1e6;
      });
    } else if (!_animate && _timer != null) {
      _stopTimer();
    }
  }

  void _stopTimer() {
    _timer!.cancel();
    _timer = null;
    _watch.stop();
    ZenBackdropLayer.running--;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_timer != null) {
      _stopTimer();
    }
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool live = _animate;
    return RepaintBoundary(
      child: CustomPaint(
        key: Key(live ? 'zen-backdrop-live' : 'zen-backdrop-still'),
        isComplex: true,
        willChange: live,
        painter: ZenBackdropPainter(
          kind: widget.kind,
          colors: widget.colors,
          clock: _clock,
        ),
      ),
    );
  }
}

/// The time of a backdrop, in seconds; its painter repaints when it moves.
class ZenBackdropClock extends ChangeNotifier {
  ZenBackdropClock(this._seconds);

  double _seconds;

  double get seconds => _seconds;

  set seconds(double value) {
    if (value == _seconds) {
      return;
    }
    _seconds = value;
    notifyListeners();
  }
}

/// Paints a backdrop at the time of [clock].
class ZenBackdropPainter extends CustomPainter {
  ZenBackdropPainter({
    required this.kind,
    required this.colors,
    required this.clock,
  }) : super(repaint: clock);

  final ZenBackdrop kind;
  final ZenColors colors;
  final ZenBackdropClock clock;

  /// The strongest opacity any mark of [kind] is painted with: text stays
  /// readable over it (the theme test checks body text against the
  /// background with a mark of the accent at this opacity on it).
  static double maxAlpha(ZenBackdrop kind) => ZenEffects.maxAlpha(kind);

  /// The colours the marks of [kind] are painted in.
  static List<Color> marks(ZenBackdrop kind, ZenColors colors) =>
      ZenEffects.marks(kind, colors);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final double t = clock.seconds;
    switch (kind) {
      case ZenBackdrop.rain:
        _paintRain(canvas, size, t);
      case ZenBackdrop.cipher:
        _paintRain(canvas, size, t, dense: true);
      case ZenBackdrop.grid:
        _paintGrid(canvas, size, t);
      case ZenBackdrop.lightcycle:
        _paintGrid(canvas, size, t, trails: 4);
      case ZenBackdrop.scanlines:
        _paintScanlines(canvas, size, t);
      case ZenBackdrop.aurora:
        _paintAurora(canvas, size, t);
      default:
        ZenEffects.paint(kind, canvas, size, t, colors);
    }
  }

  // --- Digital rain --------------------------------------------------------

  static const double _cell = 2;
  static const double _pitchX = 15;
  static const double _pitchY = 17;
  static const int _glyphCount = 24;

  /// Small made-up signs on a 3 × 5 dot grid (no real script).
  static final List<Path> _glyphs = _makeGlyphs();

  static List<Path> _makeGlyphs() {
    final math.Random r = math.Random(23);
    return List<Path>.generate(_glyphCount, (int g) {
      final Path p = Path();
      // A spine down one column, then random dots: reads as a sign.
      final int spine = r.nextInt(3);
      for (int y = 0; y < 5; y++) {
        for (int x = 0; x < 3; x++) {
          final bool on = x == spine
              ? y != 2 || g.isEven
              : r.nextDouble() < 0.42;
          if (on) {
            p.addRect(
              Rect.fromLTWH(x * (_cell + 1), y * (_cell + 1), _cell, _cell),
            );
          }
        }
      }
      return p;
    });
  }

  static int _hash(int a, int b) {
    int x = (a * 73856093) ^ (b * 19349663);
    x = (x ^ (x >> 13)) * 0x5bd1e995;
    return (x ^ (x >> 15)) & 0x7fffffff;
  }

  /// The rain; [dense]: the hacker look's heavier version, columns close
  /// together, longer trails and a glitch line now and then.
  void _paintRain(Canvas canvas, Size size, double t, {bool dense = false}) {
    final double pitchX = dense ? 11 : _pitchX;
    final int columns = (size.width / pitchX).ceil();
    final int rows = (size.height / _pitchY).ceil() + 1;
    const int levels = 5;
    final List<Path> trail = List<Path>.generate(levels, (_) => Path());
    final Path heads = Path();
    final double top = maxAlpha(dense ? ZenBackdrop.cipher : ZenBackdrop.rain);
    for (int c = 0; c < columns; c++) {
      final int h = _hash(c, 7);
      // Each column: its own speed (rows a second), trail and phase; some
      // columns rest now and then.
      final double speed = (dense ? 5 : 3) + (h % 70) / 10;
      final int length = dense ? 10 + h % 18 : 6 + h % 13;
      final double phase = (h % 997) / 13.0;
      final double span = rows + length + (h % 9) * (dense ? 1.0 : 2.0);
      final double head = (t * speed + phase) % span;
      final int headRow = head.floor();
      final double x = c * pitchX + 3;
      for (int k = 0; k < length; k++) {
        final int row = headRow - k;
        if (row < 0 || row >= rows) {
          continue;
        }
        // Signs change now and then, not every frame.
        final int g =
            _hash(c * 131 + row, (t * 0.8).floor() + (h % 5)) % _glyphCount;
        final Offset at = Offset(x, row * _pitchY + 2);
        if (k == 0) {
          heads.addPath(_glyphs[g], at);
        } else {
          final int level = ((k / length) * levels).floor().clamp(
            0,
            levels - 1,
          );
          trail[level].addPath(_glyphs[g], at);
        }
      }
    }
    final Paint paint = Paint();
    for (int i = 0; i < levels; i++) {
      paint.color = colors.accent.withValues(
        alpha: top * 0.62 * (1 - i / levels),
      );
      canvas.drawPath(trail[i], paint);
    }
    paint.color = Color.lerp(
      colors.accent,
      colors.textPrimary,
      0.5,
    )!.withValues(alpha: top);
    canvas.drawPath(heads, paint);
    if (dense && (t * 1.7) % 3 < 0.25) {
      // A glitch line tearing across for a moment.
      final double y = (_hash((t * 1.7 / 3).floor(), 3) % 1000) / 1000;
      paint.color = colors.accent.withValues(alpha: top * 0.8);
      canvas.drawRect(Rect.fromLTWH(0, y * size.height, size.width, 2), paint);
    }
  }

  // --- Neon floor grid -----------------------------------------------------

  /// The floor grid; [trails] light trails race along it (one in the neon
  /// grid look, a pack of them in the light-cycle look).
  void _paintGrid(Canvas canvas, Size size, double t, {int trails = 1}) {
    final double w = size.width;
    final double h = size.height;
    final double horizon = h * (trails > 1 ? 0.56 : 0.62);
    final double cx = w / 2;
    final double top = maxAlpha(
      trails > 1 ? ZenBackdrop.lightcycle : ZenBackdrop.grid,
    );
    // The sky: a faint glow of the second colour along the horizon.
    final Rect sky = Rect.fromLTWH(0, horizon - h * 0.18, w, h * 0.18);
    canvas.drawRect(
      sky,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            colors.accentSecondary.withValues(alpha: 0),
            colors.accentSecondary.withValues(alpha: top * 0.35),
          ],
        ).createShader(sky),
    );
    canvas.drawLine(
      Offset(0, horizon),
      Offset(w, horizon),
      Paint()
        ..color = colors.accentSecondary.withValues(alpha: top * 0.9)
        ..strokeWidth = 1.2,
    );
    final Paint glow = Paint()
      ..strokeWidth = 3
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
    final Paint line = Paint()..strokeWidth = 1;
    // Rows of the floor come towards the viewer (perspective: the row at
    // depth d lies at horizon + (h - horizon) / d).
    const int depthRows = 14;
    final double shift = (t * 0.9) % 1;
    for (int i = 0; i < depthRows; i++) {
      final double d = i + 1 - shift;
      if (d <= 0.15) {
        continue;
      }
      final double y = horizon + (h - horizon) / d;
      if (y > h + 2) {
        continue;
      }
      final double fade = (1 / d).clamp(0.0, 1.0);
      final double a = top * (0.25 + 0.75 * fade);
      glow.color = colors.accent.withValues(alpha: a * 0.35);
      line.color = colors.accent.withValues(alpha: a);
      canvas
        ..drawLine(Offset(0, y), Offset(w, y), glow)
        ..drawLine(Offset(0, y), Offset(w, y), line);
    }
    // Lanes running to the vanishing point.
    const int lanes = 9;
    for (int j = -lanes; j <= lanes; j++) {
      final Offset far = Offset(cx + j * w * 0.012, horizon);
      final Offset near = Offset(cx + j * w * 0.22, h);
      line.color = colors.accent.withValues(alpha: top * 0.7);
      glow.color = colors.accent.withValues(alpha: top * 0.22);
      canvas
        ..drawLine(far, near, glow)
        ..drawLine(far, near, line);
    }
    // Light trails racing along lanes towards the viewer.
    for (int k = 0; k < trails; k++) {
      final double run = (t * (0.35 + k * 0.11) + k * 0.37) % 1;
      final double d0 = 12 * (1 - run) + 0.6;
      final int lane = trails == 1 ? 3 : <int>[3, -2, 6, -5][k % 4];
      final Color tone = k.isEven ? colors.accentSecondary : colors.accent;
      Offset onLane(double d) {
        final double q = (1 / d).clamp(0.0, 1.0);
        final double y = horizon + (h - horizon) * q;
        final double x = cx + lane * w * (0.012 + (0.22 - 0.012) * q);
        return Offset(x, y);
      }

      final Offset a = onLane(d0 + 2.5);
      final Offset b = onLane(d0);
      canvas
        ..drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = 5
            ..color = tone.withValues(alpha: top * 0.4)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        )
        ..drawLine(
          a,
          b,
          Paint()
            ..strokeWidth = 2
            ..strokeCap = StrokeCap.round
            ..color = tone.withValues(alpha: top),
        );
    }
  }

  // --- Scan lines ----------------------------------------------------------

  void _paintScanlines(Canvas canvas, Size size, double t) {
    final double top = maxAlpha(ZenBackdrop.scanlines);
    final Paint line = Paint()
      ..color = colors.accent.withValues(alpha: top * 0.35);
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), line);
    }
    // A slow bright band rolling down the screen.
    const double band = 140;
    final double y = (t * 38) % (size.height + band) - band;
    final Rect r = Rect.fromLTWH(0, y, size.width, band);
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            colors.accent.withValues(alpha: 0),
            colors.accent.withValues(alpha: top * 0.6),
            colors.accent.withValues(alpha: 0),
          ],
        ).createShader(r),
    );
    // The darker corners of a curved screen.
    final Rect all = Offset.zero & size;
    canvas.drawRect(
      all,
      Paint()
        ..shader = RadialGradient(
          radius: 0.95,
          colors: <Color>[
            colors.background.withValues(alpha: 0),
            colors.surfaceSunk.withValues(alpha: 0.7),
          ],
          stops: const <double>[0.6, 1],
        ).createShader(all),
    );
  }

  // --- Aurora --------------------------------------------------------------

  void _paintAurora(Canvas canvas, Size size, double t) {
    final double top = maxAlpha(ZenBackdrop.aurora);
    void bloom(Alignment at, double radius, Color c, double alpha) {
      final Rect all = Offset.zero & size;
      canvas.drawRect(
        all,
        Paint()
          ..shader = RadialGradient(
            center: at,
            radius: radius,
            colors: <Color>[
              c.withValues(alpha: alpha),
              c.withValues(alpha: 0),
            ],
          ).createShader(all),
      );
    }

    // Each bloom wanders slowly on its own slow circle.
    Alignment drift(Alignment home, double speed, double phase) => Alignment(
      home.x + 0.18 * math.sin(t * speed + phase),
      home.y + 0.14 * math.cos(t * speed * 0.8 + phase),
    );
    bloom(
      drift(const Alignment(-0.9, -0.85), 0.11, 0),
      0.9,
      colors.accent,
      top,
    );
    bloom(
      drift(const Alignment(1, -0.1), 0.09, 2),
      0.8,
      colors.accentSecondary,
      top * 0.8,
    );
    bloom(
      drift(const Alignment(-0.4, 1), 0.13, 4),
      0.9,
      colors.accentTertiary,
      top * 0.6,
    );
  }

  @override
  bool shouldRepaint(ZenBackdropPainter oldDelegate) =>
      oldDelegate.kind != kind ||
      oldDelegate.colors != colors ||
      oldDelegate.clock != clock;
}

/// A block cursor blinking about once a second (the terminal looks): a
/// timer flips it, so no frame is drawn in between; a steady block while
/// the app is in the background, under reduced motion and in tests.
class ZenBlinkingCursor extends StatefulWidget {
  const ZenBlinkingCursor({required this.color, this.height = 20, super.key});

  final Color color;
  final double height;

  @override
  State<ZenBlinkingCursor> createState() => _ZenBlinkingCursorState();
}

class _ZenBlinkingCursorState extends State<ZenBlinkingCursor>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _on = true;
  bool _allowed = false;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _allowed = ZenMotion.allowedIn(context);
    _sync();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    setState(() {
      _foreground = state == AppLifecycleState.resumed;
      _sync();
    });
  }

  /// Starts or stops the blinking; the caller rebuilds.
  void _sync() {
    final bool animate = _allowed && _foreground;
    if (animate && _timer == null) {
      _timer = Timer.periodic(const Duration(milliseconds: 530), (_) {
        if (mounted) {
          setState(() => _on = !_on);
        }
      });
    } else if (!animate && _timer != null) {
      _timer!.cancel();
      _timer = null;
      _on = true;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.height * 0.5,
      height: widget.height,
      child: ColoredBox(
        color: _on ? widget.color : widget.color.withValues(alpha: 0),
      ),
    );
  }
}
