import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The backdrops of the wild looks ([ZenBackdrop]), painted by
/// [ZenBackdropPainter]: one function each, a pure picture of the time [t]
/// in seconds. Every mark stays at or under the look's strongest opacity
/// ([ZenEffects.maxAlpha]) in one of its colours ([ZenEffects.marks]), so
/// text over the backdrop keeps its contrast (the theme test checks it).
/// Nothing here allocates more than a few paths a frame; positions come
/// from a fixed hash, not from a random generator.
abstract final class ZenEffects {
  /// Frames a second of an animated effect (0: a still picture).
  static int fps(ZenBackdrop kind) => switch (kind) {
    ZenBackdrop.cipher => 14,
    ZenBackdrop.lightcycle => 20,
    ZenBackdrop.fairy => 10,
    ZenBackdrop.synthwave => 15,
    ZenBackdrop.city => 15,
    ZenBackdrop.arcade => 4,
    ZenBackdrop.space => 12,
    ZenBackdrop.vapor => 12,
    ZenBackdrop.deepSea => 12,
    ZenBackdrop.steam => 10,
    ZenBackdrop.holo => 8,
    ZenBackdrop.embers => 14,
    ZenBackdrop.aurora => 8,
    ZenBackdrop.petals => 10,
    ZenBackdrop.bubbles => 12,
    ZenBackdrop.blueprint => 6,
    ZenBackdrop.spotlight => 12,
    ZenBackdrop.halftone ||
    ZenBackdrop.brushed ||
    ZenBackdrop.rain ||
    ZenBackdrop.grid ||
    ZenBackdrop.scanlines ||
    ZenBackdrop.none => 0,
  };

  /// The strongest opacity of a mark of [kind].
  static double maxAlpha(ZenBackdrop kind) => switch (kind) {
    ZenBackdrop.cipher => 0.35,
    ZenBackdrop.lightcycle => 0.38,
    ZenBackdrop.fairy => 0.27,
    ZenBackdrop.synthwave => 0.40,
    ZenBackdrop.city => 0.30,
    ZenBackdrop.arcade => 0.28,
    ZenBackdrop.space => 0.28,
    ZenBackdrop.vapor => 0.30,
    ZenBackdrop.deepSea => 0.32,
    ZenBackdrop.halftone => 0.22,
    ZenBackdrop.steam => 0.22,
    ZenBackdrop.holo => 0.26,
    ZenBackdrop.embers => 0.34,
    ZenBackdrop.brushed => 0.08,
    ZenBackdrop.rain => 0.32,
    ZenBackdrop.grid => 0.30,
    ZenBackdrop.scanlines => 0.10,
    ZenBackdrop.aurora => 0.16,
    ZenBackdrop.petals => 0.30,
    ZenBackdrop.bubbles => 0.30,
    ZenBackdrop.blueprint => 0.22,
    ZenBackdrop.spotlight => 0.20,
    ZenBackdrop.none => 0,
  };

  /// The colours the marks of [kind] are painted in.
  static List<Color> marks(ZenBackdrop kind, ZenColors c) => switch (kind) {
    ZenBackdrop.rain || ZenBackdrop.cipher => <Color>[
      c.accent,
      Color.lerp(c.accent, c.textPrimary, 0.5)!,
    ],
    ZenBackdrop.grid ||
    ZenBackdrop.lightcycle => <Color>[c.accent, c.accentSecondary],
    ZenBackdrop.scanlines => <Color>[c.accent],
    ZenBackdrop.fairy => <Color>[c.accentSecondary, c.accent, _star(c)],
    ZenBackdrop.synthwave => <Color>[
      c.accent,
      c.accentSecondary,
      c.outlineStrong,
    ],
    ZenBackdrop.city => <Color>[c.textSecondary, c.accentSecondary, c.accent],
    ZenBackdrop.arcade || ZenBackdrop.space => <Color>[
      _star(c),
      c.accentSecondary,
      c.accentTertiary,
      c.accent,
    ],
    ZenBackdrop.vapor ||
    ZenBackdrop.halftone ||
    ZenBackdrop.embers ||
    ZenBackdrop.petals ||
    ZenBackdrop.bubbles => <Color>[c.accent, c.accentSecondary],
    ZenBackdrop.blueprint => <Color>[c.accent],
    ZenBackdrop.spotlight => <Color>[c.accentSecondary, c.accent],
    ZenBackdrop.steam => <Color>[c.outlineStrong, c.textMuted],
    ZenBackdrop.brushed => <Color>[c.outlineStrong],
    ZenBackdrop.deepSea ||
    ZenBackdrop.holo ||
    ZenBackdrop.aurora => c.accentTrio,
    ZenBackdrop.none => const <Color>[],
  };

  /// Paints a wild effect; false for the kinds [ZenBackdropPainter] paints
  /// itself.
  static bool paint(
    ZenBackdrop kind,
    Canvas canvas,
    Size size,
    double t,
    ZenColors c,
  ) {
    final double a = maxAlpha(kind);
    switch (kind) {
      case ZenBackdrop.fairy:
        _fairy(canvas, size, t, c, a);
      case ZenBackdrop.synthwave:
        _synthwave(canvas, size, t, c, a);
      case ZenBackdrop.city:
        _city(canvas, size, t, c, a);
      case ZenBackdrop.arcade:
        _arcade(canvas, size, t, c, a);
      case ZenBackdrop.space:
        _space(canvas, size, t, c, a);
      case ZenBackdrop.vapor:
        _vapor(canvas, size, t, c, a);
      case ZenBackdrop.deepSea:
        _deepSea(canvas, size, t, c, a);
      case ZenBackdrop.halftone:
        _halftone(canvas, size, c, a);
      case ZenBackdrop.steam:
        _steam(canvas, size, t, c, a);
      case ZenBackdrop.holo:
        _holo(canvas, size, t, c, a);
      case ZenBackdrop.embers:
        _embers(canvas, size, t, c, a);
      case ZenBackdrop.brushed:
        _brushed(canvas, size, c, a);
      case ZenBackdrop.petals:
        _petals(canvas, size, t, c, a);
      case ZenBackdrop.bubbles:
        _bubbles(canvas, size, t, c, a);
      case ZenBackdrop.blueprint:
        _blueprint(canvas, size, t, c, a);
      case ZenBackdrop.spotlight:
        _spotlight(canvas, size, t, c, a);
      case ZenBackdrop.cipher:
      case ZenBackdrop.lightcycle:
      case ZenBackdrop.rain:
      case ZenBackdrop.grid:
      case ZenBackdrop.scanlines:
      case ZenBackdrop.aurora:
      case ZenBackdrop.none:
        return false;
    }
    return true;
  }

  /// The colour of stars: pale on a dark sky, a deep accent on a light
  /// (dawn, paper) one.
  static Color _star(ZenColors c) =>
      c.background.computeLuminance() > 0.3 ? c.accentSecondary : c.textPrimary;

  /// A fixed pseudo-random number in 0..1 for [i] and [salt].
  static double _h(int i, int salt) {
    int x = (i * 374761393 + salt * 668265263) & 0x7fffffff;
    x = ((x ^ (x >> 13)) * 1274126177) & 0x7fffffff;
    return (x ^ (x >> 16)) / 0x7fffffff;
  }

  static void _vertical(
    Canvas canvas,
    Rect r,
    List<Color> colors, [
    List<double>? stops,
  ]) {
    canvas.drawRect(
      r,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stops,
        ).createShader(r),
    );
  }

  static void _bloom(
    Canvas canvas,
    Size size,
    Offset center,
    double radius,
    Color color,
  ) {
    final Rect r = Rect.fromCircle(center: center, radius: radius);
    canvas.drawRect(
      r.intersect(Offset.zero & size),
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[color, color.withValues(alpha: 0)],
        ).createShader(r),
    );
  }

  /// A four-pointed sparkle.
  static void _sparkle(Canvas canvas, Offset p, double r, Paint paint) {
    canvas.drawPath(
      Path()
        ..moveTo(p.dx, p.dy - r)
        ..quadraticBezierTo(p.dx, p.dy, p.dx + r, p.dy)
        ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy + r)
        ..quadraticBezierTo(p.dx, p.dy, p.dx - r, p.dy)
        ..quadraticBezierTo(p.dx, p.dy, p.dx, p.dy - r)
        ..close(),
      paint,
    );
  }

  // A night sky in violet: twinkling stars, a few golden sparkles and now
  // and then a falling sparkle with a trail.
  static void _fairy(Canvas canvas, Size s, double t, ZenColors c, double a) {
    _vertical(canvas, Offset.zero & s, <Color>[
      c.accentSecondary.withValues(alpha: a * 0.6),
      c.accentSecondary.withValues(alpha: 0),
    ]);
    final Paint star = Paint();
    for (int i = 0; i < 70; i++) {
      final Offset p = Offset(_h(i, 1) * s.width, _h(i, 2) * s.height);
      final double tw = 0.5 + 0.5 * math.sin(t * (1 + _h(i, 3) * 2) + i);
      star.color = (i % 7 == 0 ? c.accent : _star(c)).withValues(
        alpha: a * (0.25 + 0.75 * tw),
      );
      if (i % 9 == 0) {
        _sparkle(canvas, p, 3 + 3 * tw, star);
      } else {
        canvas.drawCircle(p, 0.8 + _h(i, 4), star);
      }
    }
    // A falling sparkle every 7 s, for 1.4 s.
    final double cycle = t % 7;
    if (cycle < 1.4) {
      final int n = (t / 7).floor();
      final double k = cycle / 1.4;
      final Offset from = Offset(
        _h(n, 5) * s.width * 0.6,
        _h(n, 6) * s.height * 0.3,
      );
      final Offset head =
          from + Offset(k * s.width * 0.45, k * s.height * 0.22);
      final double back = math.max(0.0, k - 0.35);
      final Offset tail =
          from + Offset(back * s.width * 0.45, back * s.height * 0.22);
      canvas.drawLine(
        tail,
        head,
        Paint()
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..shader = LinearGradient(
            colors: <Color>[
              c.accent.withValues(alpha: 0),
              c.accent.withValues(alpha: a),
            ],
          ).createShader(Rect.fromPoints(tail, head)),
      );
      _sparkle(canvas, head, 5, Paint()..color = c.accent.withValues(alpha: a));
    }
  }

  // A striped sun setting behind a purple grid that runs towards you.
  static void _synthwave(
    Canvas canvas,
    Size s,
    double t,
    ZenColors c,
    double a,
  ) {
    final double horizon = s.height * 0.6;
    _vertical(canvas, Rect.fromLTWH(0, 0, s.width, horizon), <Color>[
      c.accent.withValues(alpha: 0),
      c.accent.withValues(alpha: a * 0.45),
    ]);
    final double r = s.width * 0.3;
    final Offset center = Offset(s.width / 2, horizon - r * 0.35);
    final Rect sun = Rect.fromCircle(center: center, radius: r);
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, s.width, horizon));
    // The sun, cut by bands that widen towards the horizon.
    final Path cut = Path()..addOval(sun);
    for (int i = 0; i < 7; i++) {
      final double y = center.dy + r * (0.05 + i * 0.14);
      cut.addRect(Rect.fromLTWH(sun.left, y, sun.width, 1.5 + i * 1.6));
    }
    canvas
      ..drawPath(
        cut..fillType = PathFillType.evenOdd,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              c.accentSecondary.withValues(alpha: a),
              c.accent.withValues(alpha: a),
            ],
          ).createShader(sun),
      )
      ..restore();
    // The grid floor.
    final Paint line = Paint()
      ..strokeWidth = 1.2
      ..color = c.outlineStrong.withValues(alpha: a);
    canvas.drawLine(Offset(0, horizon), Offset(s.width, horizon), line);
    final double shift = (t * 0.7) % 1;
    for (int i = 0; i < 12; i++) {
      final double d = i + 1 - shift;
      if (d < 0.2) {
        continue;
      }
      final double y = horizon + (s.height - horizon) / d;
      if (y <= s.height) {
        canvas.drawLine(Offset(0, y), Offset(s.width, y), line);
      }
    }
    for (int j = -8; j <= 8; j++) {
      canvas.drawLine(
        Offset(s.width / 2 + j * s.width * 0.02, horizon),
        Offset(s.width / 2 + j * s.width * 0.25, s.height),
        line,
      );
    }
  }

  // A neon city in the rain: a dark skyline with lit windows and slanted
  // streaks of rain falling over everything.
  static void _city(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final double base = s.height;
    final Paint building = Paint()..color = c.surfaceMuted;
    final Paint window = Paint();
    final Paint roof = Paint()
      ..strokeWidth = 1.5
      ..color = c.accent.withValues(alpha: a);
    double x = 0;
    int i = 0;
    while (x < s.width) {
      final double w = 26 + _h(i, 1) * 40;
      final double h = s.height * (0.12 + _h(i, 2) * 0.22);
      final Rect r = Rect.fromLTWH(x, base - h, w - 3, h);
      canvas
        ..drawRect(r, building)
        ..drawLine(r.topLeft, r.topRight, roof);
      // Windows, a few flickering.
      for (double wy = r.top + 6; wy < r.bottom - 4; wy += 9) {
        for (double wx = r.left + 4; wx < r.right - 4; wx += 7) {
          final int k = (wx * 7 + wy * 13).floor();
          final double lit = _h(k, (t * 0.5).floor() + (k % 3 == 0 ? 1 : 0));
          if (lit > 0.62) {
            window.color = (k % 4 == 0 ? c.accent : c.accentSecondary)
                .withValues(alpha: a * 0.9);
            canvas.drawRect(Rect.fromLTWH(wx, wy, 3, 4), window);
          }
        }
      }
      x += w;
      i++;
    }
    // Rain.
    final Paint drop = Paint()
      ..strokeWidth = 1
      ..color = c.textSecondary.withValues(alpha: a * 0.7);
    for (int k = 0; k < 90; k++) {
      final double speed = 0.6 + _h(k, 3) * 0.6;
      final double y = ((_h(k, 4) + t * speed) % 1.2 - 0.1) * s.height;
      final double px = (_h(k, 5) * 1.2 - 0.1) * s.width - y * 0.18;
      canvas.drawLine(Offset(px, y), Offset(px - 4, y + 18), drop);
    }
  }

  // Blinking pixel stars in a curved old screen.
  static void _arcade(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final Paint p = Paint();
    final int beat = (t * 2).floor();
    final List<Color> tones = <Color>[
      _star(c),
      c.accent,
      c.accentTertiary,
      c.accentSecondary,
    ];
    for (int i = 0; i < 60; i++) {
      final bool on = _h(i, beat % 5) > 0.35;
      if (!on) {
        continue;
      }
      final double size = i % 6 == 0 ? 4 : 2;
      final double x = (_h(i, 1) * s.width / 4).floorToDouble() * 4;
      final double y = (_h(i, 2) * s.height / 4).floorToDouble() * 4;
      p.color = tones[i % tones.length].withValues(alpha: a);
      canvas.drawRect(Rect.fromLTWH(x, y, size, size), p);
      if (size == 4) {
        // A plus-shaped twinkle.
        canvas
          ..drawRect(Rect.fromLTWH(x - 4, y + 1, 3, 2), p)
          ..drawRect(Rect.fromLTWH(x + 5, y + 1, 3, 2), p);
      }
    }
    final Paint scan = Paint()..color = c.surfaceSunk.withValues(alpha: 0.35);
    for (double y = 0; y < s.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, s.width, 1), scan);
    }
    final Rect all = Offset.zero & s;
    canvas.drawRect(
      all,
      Paint()
        ..shader = RadialGradient(
          radius: 0.9,
          colors: <Color>[
            c.surfaceSunk.withValues(alpha: 0),
            c.surfaceSunk.withValues(alpha: 0.85),
          ],
          stops: const <double>[0.65, 1],
        ).createShader(all),
    );
  }

  // Three layers of stars drifting at their own speeds over slow nebulae.
  static void _space(Canvas canvas, Size s, double t, ZenColors c, double a) {
    _bloom(
      canvas,
      s,
      Offset(s.width * (0.2 + 0.05 * math.sin(t * 0.05)), s.height * 0.3),
      s.width * 0.7,
      c.accentSecondary.withValues(alpha: a * 0.55),
    );
    _bloom(
      canvas,
      s,
      Offset(s.width * 0.85, s.height * (0.75 + 0.04 * math.cos(t * 0.04))),
      s.width * 0.6,
      c.accentTertiary.withValues(alpha: a * 0.45),
    );
    final Paint star = Paint();
    for (int layer = 0; layer < 3; layer++) {
      final double speed = 6.0 + layer * 10;
      final double radius = 0.6 + layer * 0.5;
      star.color = (layer == 2 ? c.accent : _star(c)).withValues(
        alpha: a * (0.4 + layer * 0.3),
      );
      for (int i = 0; i < 40; i++) {
        final double x = _h(i, 10 + layer) * s.width;
        final double y = (_h(i, 20 + layer) * s.height + t * speed) % s.height;
        canvas.drawCircle(Offset(x, y), radius, star);
      }
    }
  }

  // A pastel sky, a banded sun and a teal grid floor (light).
  static void _vapor(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final double horizon = s.height * 0.62;
    _vertical(canvas, Rect.fromLTWH(0, 0, s.width, horizon), <Color>[
      c.accentSecondary.withValues(alpha: a * 0.3),
      c.accent.withValues(alpha: a * 0.35),
    ]);
    final double r = s.width * 0.22;
    final Offset center = Offset(s.width * 0.5, horizon - r * 0.6);
    final Rect sun = Rect.fromCircle(center: center, radius: r);
    final Path disc = Path()..addOval(sun);
    for (int i = 0; i < 5; i++) {
      disc.addRect(
        Rect.fromLTWH(sun.left, center.dy + r * (0.1 + i * 0.18), sun.width, 3),
      );
    }
    // The sun sets behind the horizon: nothing of it shows on the floor.
    canvas
      ..save()
      ..clipRect(Rect.fromLTWH(0, 0, s.width, horizon))
      ..drawPath(
        disc..fillType = PathFillType.evenOdd,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              c.accent.withValues(alpha: a * 0.7),
              c.accentSecondary.withValues(alpha: a * 0.7),
            ],
          ).createShader(sun),
      )
      ..restore();
    final Paint line = Paint()
      ..strokeWidth = 1
      ..color = c.accentSecondary.withValues(alpha: a);
    final double shift = (t * 0.4) % 1;
    for (int i = 0; i < 10; i++) {
      final double d = i + 1 - shift;
      if (d < 0.2) {
        continue;
      }
      final double y = horizon + (s.height - horizon) / d;
      if (y <= s.height) {
        canvas.drawLine(Offset(0, y), Offset(s.width, y), line);
      }
    }
    for (int j = -7; j <= 7; j++) {
      canvas.drawLine(
        Offset(s.width / 2 + j * s.width * 0.03, horizon),
        Offset(s.width / 2 + j * s.width * 0.22, s.height),
        line,
      );
    }
  }

  // Light rays swaying down into the deep, glowing specks rising.
  static void _deepSea(Canvas canvas, Size s, double t, ZenColors c, double a) {
    for (int i = 0; i < 4; i++) {
      final double x = s.width * (0.15 + i * 0.25) + 20 * math.sin(t * 0.3 + i);
      final Path ray = Path()
        ..moveTo(x - 10, 0)
        ..lineTo(x + 26, 0)
        ..lineTo(x + 90, s.height * 0.8)
        ..lineTo(x - 20, s.height * 0.8)
        ..close();
      canvas.drawPath(
        ray,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: <Color>[
              c.accent.withValues(alpha: a * 0.35),
              c.accent.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromLTWH(0, 0, s.width, s.height * 0.8)),
      );
    }
    final Paint glow = Paint();
    final Paint core = Paint();
    final List<Color> tones = c.accentTrio;
    for (int i = 0; i < 40; i++) {
      final double speed = 8 + _h(i, 1) * 18;
      final double y =
          s.height - ((_h(i, 2) * s.height + t * speed) % (s.height + 20));
      final double x = _h(i, 3) * s.width + 10 * math.sin(t * 0.8 + i);
      final double r = 1 + _h(i, 4) * 2;
      final Color tone = tones[i % 3];
      glow.color = tone.withValues(alpha: a * 0.3);
      core.color = tone.withValues(alpha: a);
      canvas
        ..drawCircle(Offset(x, y), r * 3, glow)
        ..drawCircle(Offset(x, y), r, core);
    }
  }

  // Printed halftone dots growing towards two corners (still).
  static void _halftone(Canvas canvas, Size s, ZenColors c, double a) {
    final Paint red = Paint()..color = c.accent.withValues(alpha: a);
    final Paint blue = Paint()..color = c.accentSecondary.withValues(alpha: a);
    const double step = 12;
    final double far = math.sqrt(s.width * s.width + s.height * s.height);
    for (double y = 0; y < s.height; y += step) {
      final double shiftX = (y / step).floor().isEven ? 0 : step / 2;
      for (double x = shiftX; x < s.width; x += step) {
        final double dTop = Offset(x, y).distance / far;
        final double dBottom = Offset(s.width - x, s.height - y).distance / far;
        if (dTop < 0.45) {
          canvas.drawCircle(Offset(x, y), (0.45 - dTop) * 10, red);
        } else if (dBottom < 0.45) {
          canvas.drawCircle(Offset(x, y), (0.45 - dBottom) * 10, blue);
        }
      }
    }
  }

  static Path _gear(Offset c, double r, int teeth, double turn) {
    final Path p = Path();
    for (int i = 0; i <= teeth * 4; i++) {
      final double ang = turn + i / (teeth * 4) * 2 * math.pi;
      final double rr = (i ~/ 2).isEven ? r : r * 0.84;
      final Offset q = c + Offset(math.cos(ang), math.sin(ang)) * rr;
      if (i == 0) {
        p.moveTo(q.dx, q.dy);
      } else {
        p.lineTo(q.dx, q.dy);
      }
    }
    return p
      ..close()
      ..addOval(Rect.fromCircle(center: c, radius: r * 0.3));
  }

  // Old paper with slowly turning gears and drifting puffs of steam.
  static void _steam(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = c.outlineStrong.withValues(alpha: a);
    canvas
      ..drawPath(
        _gear(Offset(s.width * 0.95, s.height * 0.12), 70, 12, t * 0.12),
        line,
      )
      ..drawPath(
        _gear(Offset(s.width * 0.78, s.height * 0.22), 40, 8, -t * 0.21),
        line,
      )
      ..drawPath(
        _gear(Offset(s.width * 0.05, s.height * 0.92), 90, 14, -t * 0.09),
        line,
      );
    // Soft puffs: dense in the middle, fading out, thinning as they rise.
    for (int i = 0; i < 6; i++) {
      final double k = (t * 0.05 + _h(i, 1)) % 1;
      final Offset p = Offset(
        s.width * (0.1 + _h(i, 2) * 0.8) + 14 * math.sin(t * 0.4 + i),
        s.height * (1.05 - k * 1.1),
      );
      _bloom(
        canvas,
        s,
        p,
        24 + k * 40,
        c.textMuted.withValues(alpha: a * 0.5 * (1 - k * 0.6)),
      );
    }
  }

  // Slow bands of rainbow sheen moving across the screen.
  static void _holo(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final Rect all = Offset.zero & s;
    final double shift = (t * 0.03) % 1;
    canvas.drawRect(
      all,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment(-1 + shift * 2, -1),
          end: Alignment(1 + shift * 2, 1),
          colors: <Color>[
            c.accent.withValues(alpha: a),
            c.accentSecondary.withValues(alpha: a * 0.4),
            c.accentTertiary.withValues(alpha: a),
            c.accent.withValues(alpha: a * 0.4),
          ],
          tileMode: TileMode.mirror,
        ).createShader(all),
    );
  }

  // Embers rising from glowing cracks at the bottom.
  static void _embers(Canvas canvas, Size s, double t, ZenColors c, double a) {
    _vertical(
      canvas,
      Rect.fromLTWH(0, s.height * 0.6, s.width, s.height * 0.4),
      <Color>[
        c.accent.withValues(alpha: 0),
        c.accent.withValues(alpha: a * 0.55),
      ],
    );
    final double pulse = 0.65 + 0.35 * math.sin(t * 1.3);
    final Paint crack = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeJoin = StrokeJoin.round
      ..color = c.accentSecondary.withValues(alpha: a * pulse);
    for (int k = 0; k < 3; k++) {
      final Path p = Path();
      double x = s.width * (0.1 + k * 0.35);
      double y = s.height;
      p.moveTo(x, y);
      for (int i = 0; i < 6; i++) {
        x += (_h(k * 10 + i, 1) - 0.5) * 50;
        y -= 18 + _h(k * 10 + i, 2) * 26;
        p.lineTo(x, y);
      }
      canvas.drawPath(p, crack);
    }
    final Paint ember = Paint();
    for (int i = 0; i < 50; i++) {
      final double speed = 20 + _h(i, 3) * 40;
      final double life =
          ((_h(i, 4) * s.height + t * speed) % s.height) / s.height;
      final double y = s.height * (1 - life);
      final double x = _h(i, 5) * s.width + 12 * math.sin(t * 1.7 + i);
      final double flick = 0.5 + 0.5 * math.sin(t * 9 + i * 3);
      ember.color = (i.isEven ? c.accent : c.accentSecondary).withValues(
        alpha: a * (1 - life) * (0.5 + 0.5 * flick),
      );
      canvas.drawRect(Rect.fromLTWH(x, y, 2, 2), ember);
    }
  }

  // Fine horizontal strokes of brushed metal (still).
  static void _brushed(Canvas canvas, Size s, ZenColors c, double a) {
    final Paint p = Paint()..strokeWidth = 1;
    for (int i = 0; i < (s.height / 2).floor(); i++) {
      final double y = i * 2.0 + 0.5;
      final double from = _h(i, 1) * s.width * 0.6;
      final double len = s.width * (0.2 + _h(i, 2) * 0.8);
      p.color = c.outlineStrong.withValues(alpha: a * _h(i, 3));
      canvas.drawLine(Offset(from, y), Offset(from + len, y), p);
    }
  }

  /// A leaf: a lens with the point up, one unit long.
  static final Path _leaf = Path()
    ..moveTo(0, -1)
    ..quadraticBezierTo(0.9, -0.15, 0, 1)
    ..quadraticBezierTo(-0.9, -0.15, 0, -1)
    ..close();

  // Leaves and petals sinking slowly, swaying and turning as they fall.
  static void _petals(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final Paint leaf = Paint();
    final double span = s.height + 40;
    for (int i = 0; i < 26; i++) {
      final double size = 5 + _h(i, 1) * 8;
      final double y = (_h(i, 3) * span + t * (8 + _h(i, 2) * 14)) % span - 20;
      final double x =
          _h(i, 4) * s.width + 16 * math.sin(t * (0.4 + _h(i, 5) * 0.4) + i);
      final double turn = t * (0.3 + _h(i, 6) * 0.6) * (i.isEven ? 1 : -1) + i;
      leaf.color = (i % 3 == 0 ? c.accentSecondary : c.accent).withValues(
        alpha: a * (0.45 + 0.55 * _h(i, 7)),
      );
      canvas
        ..save()
        ..translate(x, y)
        ..rotate(turn)
        ..scale(size * 0.6, size)
        ..drawPath(_leaf, leaf)
        ..restore();
    }
  }

  // Soft bubbles rising with a little sway, each with a ring and a glint.
  static void _bubbles(Canvas canvas, Size s, double t, ZenColors c, double a) {
    final Paint fill = Paint();
    final Paint ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final Paint glint = Paint();
    for (int i = 0; i < 28; i++) {
      final double r = 4 + _h(i, 1) * 12;
      final double span = s.height + 2 * r;
      final double rise = (_h(i, 3) * span + t * (12 + _h(i, 2) * 22)) % span;
      final Offset p = Offset(
        _h(i, 4) * s.width + 10 * math.sin(t * 0.7 + i),
        s.height + r - rise,
      );
      final Color tone = i.isEven ? c.accent : c.accentSecondary;
      fill.color = tone.withValues(alpha: a * 0.3);
      ring.color = tone.withValues(alpha: a * 0.9);
      glint.color = tone.withValues(alpha: a);
      canvas
        ..drawCircle(p, r, fill)
        ..drawCircle(p, r, ring)
        ..drawCircle(p + Offset(-r * 0.35, -r * 0.35), r * 0.16, glint);
    }
  }

  // A drawing board: a grid drifting slowly with a heavier line every fifth,
  // crosshairs where the heavy lines meet and a compass turning its needle.
  static void _blueprint(
    Canvas canvas,
    Size s,
    double t,
    ZenColors c,
    double a,
  ) {
    const double minor = 20;
    const double major = minor * 5;
    final Paint fine = Paint()
      ..strokeWidth = 1
      ..color = c.accent.withValues(alpha: a * 0.4);
    final Paint bold = Paint()
      ..strokeWidth = 1
      ..color = c.accent.withValues(alpha: a * 0.85);
    // The grid repeats every [major]: the drift wraps without a jump.
    final double dx = (t * 2.5) % major;
    final double dy = (t * 1.5) % major;
    for (int k = 0; k * minor - dx < s.width; k++) {
      final double x = k * minor - dx;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, s.height),
        k % 5 == 0 ? bold : fine,
      );
    }
    for (int k = 0; k * minor - dy < s.height; k++) {
      final double y = k * minor - dy;
      canvas.drawLine(
        Offset(0, y),
        Offset(s.width, y),
        k % 5 == 0 ? bold : fine,
      );
    }
    final Paint cross = Paint()
      ..strokeWidth = 1.5
      ..color = c.accent.withValues(alpha: a);
    for (int i = 0; i < 4; i++) {
      final double x =
          (1 + (_h(i, 1) * (s.width / major - 1)).floor()) * major - dx;
      final double y =
          (1 + (_h(i, 2) * (s.height / major - 1)).floor()) * major - dy;
      canvas
        ..drawLine(Offset(x - 5, y), Offset(x + 5, y), cross)
        ..drawLine(Offset(x, y - 5), Offset(x, y + 5), cross);
    }
    final Offset hub = Offset(s.width * 0.78, s.height * 0.2);
    final double radius = s.width * 0.3;
    final Paint arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = c.accent.withValues(alpha: a * 0.7);
    final double turn = t * 0.25;
    canvas
      ..drawCircle(hub, radius, arc)
      ..drawCircle(hub, radius * 0.6, arc)
      ..drawLine(
        hub,
        hub + Offset(math.cos(turn), math.sin(turn)) * radius,
        Paint()
          ..strokeWidth = 1.5
          ..color = c.accent.withValues(alpha: a),
      )
      ..drawCircle(hub, 3, Paint()..color = c.accent.withValues(alpha: a));
  }

  // Two projector beams swaying from the top corners over drifting dust.
  static void _spotlight(
    Canvas canvas,
    Size s,
    double t,
    ZenColors c,
    double a,
  ) {
    final double length = s.height * 1.1;
    for (int k = 0; k < 2; k++) {
      final Offset from = Offset(s.width * (k == 0 ? 0.12 : 0.88), -8);
      final double centre =
          (k == 0 ? 0.32 : -0.32) +
          0.26 * math.sin(t * (0.22 + k * 0.07) + k * 2);
      final double spread = 0.12 + 0.02 * math.sin(t * 0.3 + k);
      Offset reach(double angle) =>
          from + Offset(math.sin(angle), math.cos(angle)) * length;
      final Color tone = k == 0 ? c.accentSecondary : c.accent;
      final Offset left = reach(centre - spread);
      final Offset right = reach(centre + spread);
      canvas.drawPath(
        Path()
          ..moveTo(from.dx, from.dy)
          ..lineTo(left.dx, left.dy)
          ..lineTo(right.dx, right.dy)
          ..close(),
        Paint()
          ..shader = ui.Gradient.linear(from, reach(centre), <Color>[
            tone.withValues(alpha: a * 0.5),
            tone.withValues(alpha: 0),
          ]),
      );
    }
    final Paint dust = Paint();
    for (int i = 0; i < 30; i++) {
      final double rise = (_h(i, 1) * s.height + t * (4 + _h(i, 2) * 8));
      final Offset p = Offset(
        _h(i, 3) * s.width + 8 * math.sin(t * 0.5 + i),
        s.height - rise % s.height,
      );
      final double glow = 0.5 + 0.5 * math.sin(t * (0.8 + _h(i, 4)) + i);
      dust.color = c.accentSecondary.withValues(alpha: a * (0.3 + 0.7 * glow));
      canvas.drawCircle(p, 0.7 + _h(i, 5) * 1.1, dust);
    }
  }
}
