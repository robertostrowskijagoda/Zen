import 'dart:math' as math;

import 'package:flutter/painting.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pebbles/design/pebble_paths.dart';

/// The groups the stamps are offered in.
enum PebbleStampCategory {
  animals,
  insects,
  flowers,
  leaves,
  stars,
  hearts,
  faces,
  weather,
  food,
  geometric,
  letters;

  String get label => switch (this) {
    animals => t('Zwierzęta'),
    insects => t('Owady'),
    flowers => t('Kwiaty'),
    leaves => t('Liście'),
    stars => t('Gwiazdy'),
    hearts => t('Serca'),
    faces => t('Buźki'),
    weather => t('Pogoda'),
    food => t('Jedzenie'),
    geometric => t('Kształty'),
    letters => t('Litery i cyfry'),
  };
}

/// The colours a stamp is drawn with: its main colour and its ink (outlines,
/// eyes, spots). A stamp put on "in natural colours" uses its own.
final class StampInk {
  StampInk(this.main, this.ink);

  final Color main;
  final Color ink;

  static const Color white = Color(0xFFFFFFFF);
  static const Color yellow = Color(0xFFFFD21F);
  static const Color orange = Color(0xFFFF8A1F);
  static const Color pink = Color(0xFFFF8FB1);
  static const Color green = Color(0xFF4CAF50);
  static const Color red = Color(0xFFE5243B);
  static const Color brown = Color(0xFF7A4E2D);

  Paint get m => fill(main);
  Paint get k => fill(ink);

  Paint fill(Color c) => Paint()
    ..color = c
    ..isAntiAlias = true;

  Paint line(Color c, double w) => Paint()
    ..color = c
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  Color get light => Color.lerp(main, white, 0.45)!;
  Color get dark => Color.lerp(main, const Color(0xFF000000), 0.35)!;
}

typedef StampPainter = void Function(Canvas c, StampInk k);

/// One stamp: its group, natural colours (0xAARRGGBB) and how it is drawn
/// in the box ±1 (y down).
final class PebbleStamp {
  const PebbleStamp(
    this.category,
    this.main,
    this.ink,
    this.paint, [
    this.glyph,
  ]);

  final PebbleStampCategory category;
  final int main;
  final int ink;
  final StampPainter paint;

  /// The letter or digit of a letter stamp.
  final String? glyph;
}

void _o(Canvas c, double x, double y, double r, Paint p) =>
    c.drawCircle(Offset(x, y), r, p);

void _e(Canvas c, double x, double y, double rx, double ry, Paint p) =>
    c.drawOval(
      Rect.fromCenter(center: Offset(x, y), width: rx * 2, height: ry * 2),
      p,
    );

void _p(Canvas c, List<double> xy, Paint p) =>
    c.drawPath(PebblePaths.poly(xy), p);

void _b(Canvas c, List<double> xy, Paint p) =>
    c.drawPath(PebblePaths.blob(xy), p);

void _l(Canvas c, double x1, double y1, double x2, double y2, Paint p) =>
    c.drawLine(Offset(x1, y1), Offset(x2, y2), p);

void _arc(
  Canvas c,
  double x,
  double y,
  double r,
  double a0,
  double sweep,
  Paint p,
) => c.drawArc(
  Rect.fromCircle(center: Offset(x, y), radius: r),
  a0,
  sweep,
  false,
  p,
);

/// Two eyes with highlights.
void _eyes(Canvas c, StampInk k, double x, double y, double gap, double r) {
  for (final double dx in <double>[-gap, gap]) {
    _o(c, x + dx, y, r, k.k);
    _o(c, x + dx + r * 0.35, y - r * 0.35, r * 0.35, k.fill(StampInk.white));
  }
}

void _smile(Canvas c, StampInk k, double y, double r, double w) =>
    _arc(c, 0, y - r, r, 0.35, math.pi - 0.7, k.line(k.ink, w));

void _face(Canvas c, StampInk k) {
  _o(c, 0, 0, 0.95, k.m);
  _o(c, 0, 0, 0.95, k.line(k.dark, 0.06));
}

void _petals(
  Canvas c,
  int n,
  double len,
  double w,
  Paint p, {
  double from = 0,
  double turn = 0,
}) {
  for (int i = 0; i < n; i++) {
    final double a = turn + i * 2 * math.pi / n;
    c.drawPath(
      PebblePaths.petal(math.cos(a) * from, math.sin(a) * from, a, len, w),
      p,
    );
  }
}

final List<PebbleStamp> _drawn = <PebbleStamp>[
  // ---- Animals
  PebbleStamp(PebbleStampCategory.animals, 0xFFFF9F43, 0xFF2B2B2B, (
    Canvas c,
    StampInk k,
  ) {
    // Cat
    _p(c, <double>[-0.8, -0.2, -0.7, -0.95, -0.25, -0.55], k.m);
    _p(c, <double>[0.8, -0.2, 0.7, -0.95, 0.25, -0.55], k.m);
    _e(c, 0, 0.1, 0.85, 0.72, k.m);
    _p(c, <double>[
      -0.68,
      -0.35,
      -0.64,
      -0.78,
      -0.38,
      -0.52,
    ], k.fill(StampInk.pink));
    _p(c, <double>[
      0.68,
      -0.35,
      0.64,
      -0.78,
      0.38,
      -0.52,
    ], k.fill(StampInk.pink));
    _e(c, -0.3, -0.02, 0.12, 0.17, k.k);
    _e(c, 0.3, -0.02, 0.12, 0.17, k.k);
    _p(c, <double>[-0.09, 0.2, 0.09, 0.2, 0, 0.3], k.fill(StampInk.pink));
    final Paint w = k.line(k.ink, 0.04);
    _l(c, 0.2, 0.32, 0.85, 0.25, w);
    _l(c, 0.2, 0.4, 0.85, 0.48, w);
    _l(c, -0.2, 0.32, -0.85, 0.25, w);
    _l(c, -0.2, 0.4, -0.85, 0.48, w);
    _arc(c, -0.09, 0.3, 0.09, 0, math.pi, w);
    _arc(c, 0.09, 0.3, 0.09, 0, math.pi, w);
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFFC68B59, 0xFF2B2B2B, (
    Canvas c,
    StampInk k,
  ) {
    // Dog
    _e(c, 0, 0.1, 0.72, 0.78, k.m);
    _e(c, -0.72, 0.05, 0.25, 0.5, k.fill(k.dark));
    _e(c, 0.72, 0.05, 0.25, 0.5, k.fill(k.dark));
    _e(c, 0, 0.42, 0.38, 0.3, k.fill(k.light));
    _eyes(c, k, 0, -0.1, 0.28, 0.1);
    _e(c, 0, 0.28, 0.14, 0.1, k.k);
    _arc(c, 0, 0.42, 0.14, 0.2, math.pi - 0.4, k.line(k.ink, 0.04));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF8D6E63, 0xFF2B2B2B, (
    Canvas c,
    StampInk k,
  ) {
    // Owl
    _p(c, <double>[-0.7, -0.5, -0.6, -0.98, -0.25, -0.7], k.m);
    _p(c, <double>[0.7, -0.5, 0.6, -0.98, 0.25, -0.7], k.m);
    _e(c, 0, 0.08, 0.75, 0.9, k.m);
    _e(c, 0, 0.42, 0.45, 0.45, k.fill(k.light));
    for (int i = 0; i < 3; i++) {
      _arc(c, -0.2 + i * 0.2, 0.35, 0.1, 0, math.pi, k.line(k.dark, 0.04));
      _arc(c, -0.1 + i * 0.2, 0.55, 0.1, 0, math.pi, k.line(k.dark, 0.04));
    }
    _o(c, -0.3, -0.3, 0.27, k.fill(StampInk.white));
    _o(c, 0.3, -0.3, 0.27, k.fill(StampInk.white));
    _o(c, -0.3, -0.3, 0.13, k.k);
    _o(c, 0.3, -0.3, 0.13, k.k);
    _p(c, <double>[-0.1, -0.12, 0.1, -0.12, 0, 0.08], k.fill(StampInk.orange));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF3E8EEA, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Fish
    _e(c, -0.12, 0, 0.68, 0.45, k.m);
    _p(c, <double>[0.45, 0, 0.95, -0.42, 0.95, 0.42], k.m);
    _p(c, <double>[-0.2, -0.4, 0.15, -0.68, 0.2, -0.35], k.fill(k.dark));
    _o(c, -0.5, -0.08, 0.09, k.k);
    for (int i = 0; i < 3; i++) {
      _arc(c, -0.1 + i * 0.18, 0, 0.18, -0.9, 1.8, k.line(k.light, 0.05));
    }
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFFE5243B, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Bird
    _e(c, 0, 0.1, 0.62, 0.52, k.m);
    _o(c, 0.4, -0.32, 0.34, k.m);
    _p(c, <double>[
      0.68,
      -0.38,
      0.98,
      -0.28,
      0.68,
      -0.2,
    ], k.fill(StampInk.orange));
    _o(c, 0.48, -0.4, 0.07, k.k);
    _p(c, <double>[-0.55, 0.0, -0.98, -0.25, -0.9, 0.2], k.m);
    _e(c, -0.08, 0.1, 0.35, 0.22, k.fill(k.dark));
    _l(c, -0.1, 0.6, -0.15, 0.85, k.line(StampInk.orange, 0.05));
    _l(c, 0.12, 0.6, 0.1, 0.85, k.line(StampInk.orange, 0.05));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF4CAF50, 0xFF1B5E20, (
    Canvas c,
    StampInk k,
  ) {
    // Turtle
    _o(c, 0.78, 0, 0.2, k.fill(k.light));
    for (final (double x, double y) in <(double, double)>[
      (-0.45, -0.45),
      (0.45, -0.45),
      (-0.45, 0.45),
      (0.45, 0.45),
    ]) {
      _e(c, x, y, 0.16, 0.13, k.fill(k.light));
    }
    _o(c, 0, 0, 0.62, k.m);
    c.drawPath(PebblePaths.polygon(0, 0, 0.26, 6), k.fill(k.ink));
    for (int i = 0; i < 6; i++) {
      final double a = -math.pi / 2 + i * math.pi / 3;
      _o(c, math.cos(a) * 0.45, math.sin(a) * 0.45, 0.12, k.fill(k.ink));
    }
    _o(c, 0.84, -0.05, 0.04, k.fill(const Color(0xFF000000)));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFFF5F5F5, 0xFF555555, (
    Canvas c,
    StampInk k,
  ) {
    // Rabbit
    _e(c, -0.25, -0.55, 0.15, 0.42, k.m);
    _e(c, 0.25, -0.55, 0.15, 0.42, k.m);
    _e(c, -0.25, -0.55, 0.07, 0.3, k.fill(StampInk.pink));
    _e(c, 0.25, -0.55, 0.07, 0.3, k.fill(StampInk.pink));
    _o(c, 0, 0.25, 0.6, k.m);
    _o(c, 0, 0.25, 0.6, k.line(k.ink, 0.04));
    _eyes(c, k, 0, 0.12, 0.22, 0.08);
    _o(c, 0, 0.35, 0.07, k.fill(StampInk.pink));
    _arc(c, -0.07, 0.42, 0.07, 0, math.pi, k.line(k.ink, 0.035));
    _arc(c, 0.07, 0.42, 0.07, 0, math.pi, k.line(k.ink, 0.035));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFFF57C1F, 0xFF2B2B2B, (
    Canvas c,
    StampInk k,
  ) {
    // Fox
    _p(c, <double>[-0.9, -0.85, -0.2, -0.4, -0.75, 0.05], k.m);
    _p(c, <double>[0.9, -0.85, 0.2, -0.4, 0.75, 0.05], k.m);
    _p(c, <double>[-0.85, -0.3, 0.85, -0.3, 0, 0.9], k.m);
    _p(c, <double>[
      -0.85,
      -0.3,
      -0.05,
      0.15,
      0,
      0.9,
      -0.3,
      0.45,
    ], k.fill(StampInk.white));
    _p(c, <double>[
      0.85,
      -0.3,
      0.05,
      0.15,
      0,
      0.9,
      0.3,
      0.45,
    ], k.fill(StampInk.white));
    _o(c, 0, 0.85, 0.1, k.k);
    _e(c, -0.3, -0.05, 0.07, 0.11, k.k);
    _e(c, 0.3, -0.05, 0.07, 0.11, k.k);
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF8B5A33, 0xFF2B2B2B, (
    Canvas c,
    StampInk k,
  ) {
    // Bear
    _o(c, -0.58, -0.58, 0.26, k.m);
    _o(c, 0.58, -0.58, 0.26, k.m);
    _o(c, -0.58, -0.58, 0.13, k.fill(k.light));
    _o(c, 0.58, -0.58, 0.13, k.fill(k.light));
    _o(c, 0, 0.08, 0.78, k.m);
    _e(c, 0, 0.35, 0.32, 0.25, k.fill(k.light));
    _eyes(c, k, 0, -0.1, 0.3, 0.09);
    _e(c, 0, 0.25, 0.12, 0.08, k.k);
    _arc(c, 0, 0.32, 0.12, 0.3, math.pi - 0.6, k.line(k.ink, 0.04));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFFFFA8C5, 0xFF8E3B5A, (
    Canvas c,
    StampInk k,
  ) {
    // Pig
    _p(c, <double>[-0.75, -0.4, -0.7, -0.92, -0.3, -0.62], k.fill(k.dark));
    _p(c, <double>[0.75, -0.4, 0.7, -0.92, 0.3, -0.62], k.fill(k.dark));
    _o(c, 0, 0.05, 0.8, k.m);
    _e(c, 0, 0.25, 0.32, 0.22, k.fill(k.dark));
    _e(c, -0.12, 0.25, 0.06, 0.09, k.k);
    _e(c, 0.12, 0.25, 0.06, 0.09, k.k);
    _eyes(c, k, 0, -0.2, 0.3, 0.08);
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF9E9E9E, 0xFF2B2B2B, (
    Canvas c,
    StampInk k,
  ) {
    // Mouse
    _o(c, -0.52, -0.45, 0.38, k.m);
    _o(c, 0.52, -0.45, 0.38, k.m);
    _o(c, -0.52, -0.45, 0.24, k.fill(StampInk.pink));
    _o(c, 0.52, -0.45, 0.24, k.fill(StampInk.pink));
    _e(c, 0, 0.2, 0.55, 0.6, k.m);
    _eyes(c, k, 0, 0.05, 0.2, 0.08);
    _o(c, 0, 0.42, 0.08, k.fill(StampInk.pink));
    final Paint w = k.line(k.ink, 0.03);
    _l(c, 0.1, 0.45, 0.7, 0.38, w);
    _l(c, -0.1, 0.45, -0.7, 0.38, w);
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF1A1A1A, 0xFFFF8A1F, (
    Canvas c,
    StampInk k,
  ) {
    // Penguin
    _e(c, 0, 0.05, 0.62, 0.9, k.m);
    _e(c, 0, 0.2, 0.42, 0.68, k.fill(StampInk.white));
    _e(c, -0.62, 0.15, 0.14, 0.42, k.m);
    _e(c, 0.62, 0.15, 0.14, 0.42, k.m);
    _o(c, -0.18, -0.4, 0.07, k.fill(const Color(0xFF000000)));
    _o(c, 0.18, -0.4, 0.07, k.fill(const Color(0xFF000000)));
    _p(c, <double>[-0.12, -0.25, 0.12, -0.25, 0, -0.08], k.k);
    _e(c, -0.22, 0.92, 0.18, 0.07, k.k);
    _e(c, 0.22, 0.92, 0.18, 0.07, k.k);
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFFE0B26E, 0xFF6D4C41, (
    Canvas c,
    StampInk k,
  ) {
    // Snail
    _e(c, 0, 0.62, 0.9, 0.18, k.fill(Color.lerp(k.main, StampInk.white, 0.3)!));
    _l(c, 0.65, 0.5, 0.75, 0.05, k.line(k.ink, 0.05));
    _l(c, 0.8, 0.5, 0.95, 0.1, k.line(k.ink, 0.05));
    _o(c, 0.75, 0.05, 0.06, k.k);
    _o(c, 0.95, 0.1, 0.06, k.k);
    _o(c, -0.1, 0.05, 0.6, k.fill(k.ink));
    final Path s = Path()..moveTo(-0.1, 0.05);
    for (int i = 1; i <= 80; i++) {
      final double a = i / 80 * 5 * math.pi;
      final double r = 0.52 * i / 80;
      s.lineTo(-0.1 + math.cos(a) * r, 0.05 + math.sin(a) * r);
    }
    c.drawPath(s, k.line(k.main, 0.08));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF8D6E63, 0xFF3E2723, (
    Canvas c,
    StampInk k,
  ) {
    // Hedgehog
    final Path spikes = Path()..moveTo(-0.85, 0.4);
    for (int i = 0; i <= 12; i++) {
      final double a = math.pi + i * math.pi / 12;
      final double r = i.isEven ? 0.92 : 0.62;
      spikes.lineTo(math.cos(a) * r * 0.95, 0.35 + math.sin(a) * r * 0.85);
    }
    spikes.close();
    c.drawPath(spikes, k.fill(k.ink));
    _e(c, 0.5, 0.42, 0.42, 0.3, k.m);
    _e(c, -0.1, 0.45, 0.65, 0.3, k.fill(k.ink));
    _o(c, 0.88, 0.42, 0.07, k.fill(const Color(0xFF000000)));
    _o(c, 0.55, 0.32, 0.06, k.fill(const Color(0xFF000000)));
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF4A78C2, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Whale
    _b(c, <double>[
      -0.85,
      0.1,
      -0.5,
      -0.45,
      0.3,
      -0.45,
      0.75,
      0.1,
      0.3,
      0.55,
      -0.5,
      0.5,
    ], k.m);
    _p(c, <double>[0.65, 0.05, 0.98, -0.35, 0.95, 0.3], k.m);
    _b(c, <double>[
      -0.8,
      0.25,
      -0.2,
      0.52,
      0.4,
      0.38,
      -0.2,
      0.3,
    ], k.fill(k.light));
    _o(c, -0.45, -0.08, 0.07, k.k);
    final Paint w = k.line(const Color(0xFF8ECAE6), 0.05);
    _l(c, -0.3, -0.5, -0.3, -0.85, w);
    _arc(c, -0.45, -0.85, 0.15, -math.pi / 2, -math.pi / 2, w);
    _arc(c, -0.15, -0.85, 0.15, -math.pi / 2, math.pi / 2, w);
  }),
  PebbleStamp(PebbleStampCategory.animals, 0xFF6BCB3B, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Frog
    _o(c, -0.42, -0.45, 0.28, k.m);
    _o(c, 0.42, -0.45, 0.28, k.m);
    _e(c, 0, 0.15, 0.85, 0.62, k.m);
    _o(c, -0.42, -0.45, 0.17, k.fill(StampInk.white));
    _o(c, 0.42, -0.45, 0.17, k.fill(StampInk.white));
    _o(c, -0.42, -0.45, 0.09, k.k);
    _o(c, 0.42, -0.45, 0.09, k.k);
    _arc(c, 0, -0.05, 0.5, 0.45, math.pi - 0.9, k.line(k.ink, 0.05));
    _o(c, -0.5, 0.25, 0.08, k.fill(StampInk.pink));
    _o(c, 0.5, 0.25, 0.08, k.fill(StampInk.pink));
  }),
  // ---- Insects
  PebbleStamp(PebbleStampCategory.insects, 0xFFFF7F11, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Butterfly
    _b(c, <double>[-0.05, -0.1, -0.5, -0.9, -0.98, -0.6, -0.7, 0.0], k.m);
    _b(c, <double>[0.05, -0.1, 0.5, -0.9, 0.98, -0.6, 0.7, 0.0], k.m);
    _b(c, <double>[
      -0.05,
      0.05,
      -0.75,
      0.15,
      -0.65,
      0.75,
      -0.2,
      0.55,
    ], k.fill(k.dark));
    _b(c, <double>[
      0.05,
      0.05,
      0.75,
      0.15,
      0.65,
      0.75,
      0.2,
      0.55,
    ], k.fill(k.dark));
    _o(c, -0.55, -0.45, 0.13, k.fill(StampInk.white));
    _o(c, 0.55, -0.45, 0.13, k.fill(StampInk.white));
    _e(c, 0, 0.05, 0.08, 0.6, k.k);
    _l(c, 0, -0.5, -0.25, -0.88, k.line(k.ink, 0.04));
    _l(c, 0, -0.5, 0.25, -0.88, k.line(k.ink, 0.04));
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFF9B5DE5, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Round-winged butterfly
    _o(c, -0.45, -0.35, 0.45, k.m);
    _o(c, 0.45, -0.35, 0.45, k.m);
    _o(c, -0.38, 0.42, 0.32, k.fill(k.light));
    _o(c, 0.38, 0.42, 0.32, k.fill(k.light));
    _o(c, -0.45, -0.35, 0.18, k.fill(StampInk.yellow));
    _o(c, 0.45, -0.35, 0.18, k.fill(StampInk.yellow));
    _e(c, 0, 0.05, 0.08, 0.62, k.k);
    _arc(c, -0.25, -0.75, 0.25, 0, -math.pi / 2, k.line(k.ink, 0.04));
    _arc(c, 0.25, -0.75, 0.25, math.pi, math.pi / 2, k.line(k.ink, 0.04));
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFFE5243B, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Ladybird
    _o(c, 0, -0.62, 0.32, k.k);
    _o(c, 0, 0.12, 0.8, k.m);
    _l(c, 0, -0.65, 0, 0.92, k.line(k.ink, 0.06));
    for (final (double x, double y, double r) in <(double, double, double)>[
      (-0.4, -0.12, 0.15),
      (0.4, -0.12, 0.15),
      (-0.45, 0.35, 0.13),
      (0.45, 0.35, 0.13),
      (-0.18, 0.62, 0.1),
      (0.18, 0.62, 0.1),
    ]) {
      _o(c, x, y, r, k.k);
    }
    _o(c, -0.12, -0.72, 0.06, k.fill(StampInk.white));
    _o(c, 0.12, -0.72, 0.06, k.fill(StampInk.white));
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFFFFD21F, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Bee
    _e(c, -0.2, -0.45, 0.3, 0.38, k.fill(const Color(0xCCFFFFFF)));
    _e(c, 0.25, -0.45, 0.3, 0.38, k.fill(const Color(0xCCFFFFFF)));
    _e(c, 0, 0.15, 0.75, 0.5, k.m);
    c
      ..save()
      ..clipPath(PebblePaths.oval(0, 0.15, 0.75, 0.5));
    for (final double x in <double>[-0.3, 0.05, 0.4]) {
      c.drawRect(Rect.fromLTWH(x, -0.4, 0.15, 1.2), k.k);
    }
    c.restore();
    _o(c, -0.78, 0.1, 0.3, k.k);
    _o(c, -0.85, 0.02, 0.06, k.fill(StampInk.white));
    _p(c, <double>[0.72, 0.1, 0.98, 0.15, 0.72, 0.25], k.k);
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFF1FB5A8, 0xFF0E4D4A, (
    Canvas c,
    StampInk k,
  ) {
    // Dragonfly
    final Paint wing = k.fill(k.light.withValues(alpha: 0.85));
    _e(c, -0.45, -0.3, 0.45, 0.14, wing);
    _e(c, 0.45, -0.3, 0.45, 0.14, wing);
    _e(c, -0.4, 0.0, 0.4, 0.12, wing);
    _e(c, 0.4, 0.0, 0.4, 0.12, wing);
    _e(c, 0, 0.3, 0.07, 0.65, k.m);
    _o(c, 0, -0.5, 0.15, k.fill(k.ink));
    _o(c, -0.08, -0.55, 0.07, k.fill(StampInk.white));
    _o(c, 0.08, -0.55, 0.07, k.fill(StampInk.white));
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFF6BCB3B, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Caterpillar
    for (int i = 0; i < 5; i++) {
      final double x = 0.6 - i * 0.32;
      final double y = 0.25 + (i.isEven ? 0 : -0.15);
      _o(c, x, y, 0.24, i.isEven ? k.m : k.fill(k.dark));
    }
    _o(c, -0.75, 0.0, 0.3, k.m);
    _eyes(c, k, -0.75, -0.05, 0.12, 0.06);
    _l(c, -0.8, -0.28, -0.95, -0.6, k.line(k.ink, 0.04));
    _l(c, -0.65, -0.28, -0.55, -0.6, k.line(k.ink, 0.04));
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFF5A3A20, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Ant
    _o(c, -0.6, 0.0, 0.22, k.m);
    _o(c, -0.15, 0.05, 0.18, k.m);
    _e(c, 0.4, 0.1, 0.42, 0.3, k.m);
    final Paint leg = k.line(k.ink, 0.05);
    for (final double x in <double>[-0.3, -0.15, 0.0]) {
      _l(c, x, 0.05, x - 0.25, 0.55, leg);
      _l(c, x, 0.05, x + 0.15, -0.45, leg);
    }
    _l(c, -0.7, -0.15, -0.95, -0.5, leg);
    _l(c, -0.55, -0.18, -0.6, -0.55, leg);
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFF2E8B3E, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Beetle
    final Paint leg = k.line(k.ink, 0.06);
    for (final double y in <double>[-0.2, 0.15, 0.5]) {
      _l(c, -0.5, y, -0.9, y + 0.1, leg);
      _l(c, 0.5, y, 0.9, y + 0.1, leg);
    }
    _o(c, 0, -0.62, 0.25, k.k);
    _e(c, 0, 0.15, 0.6, 0.72, k.m);
    _l(c, 0, -0.55, 0, 0.85, k.line(k.dark, 0.05));
    _e(c, -0.25, -0.1, 0.12, 0.22, k.fill(k.light.withValues(alpha: 0.6)));
  }),
  PebbleStamp(PebbleStampCategory.insects, 0xFFFFF09A, 0xFF3A3A3A, (
    Canvas c,
    StampInk k,
  ) {
    // Firefly
    _o(c, 0.0, 0.35, 0.6, k.fill(k.main.withValues(alpha: 0.35)));
    _o(c, 0.0, 0.35, 0.35, k.m);
    _e(c, -0.3, -0.35, 0.28, 0.18, k.fill(const Color(0xCCFFFFFF)));
    _e(c, 0.3, -0.35, 0.28, 0.18, k.fill(const Color(0xCCFFFFFF)));
    _e(c, 0, -0.2, 0.17, 0.32, k.k);
    _o(c, 0, -0.55, 0.15, k.k);
  }),
  // ---- Flowers
  PebbleStamp(PebbleStampCategory.flowers, 0xFFFFFFFF, 0xFFFFC107, (
    Canvas c,
    StampInk k,
  ) {
    // Daisy
    _petals(c, 12, 0.9, 0.17, k.m);
    _petals(c, 12, 0.9, 0.17, k.line(const Color(0x22000000), 0.02));
    _o(c, 0, 0, 0.28, k.k);
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFE5243B, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Tulip
    _l(c, 0, 0.0, 0, 0.98, k.line(k.ink, 0.08));
    c.drawPath(PebblePaths.petal(0, 0.95, -2.2, 0.6, 0.18), k.k);
    _p(c, <double>[
      -0.45,
      -0.75,
      -0.2,
      -0.45,
      0,
      -0.8,
      0.2,
      -0.45,
      0.45,
      -0.75,
      0.45,
      -0.15,
      0,
      0.12,
      -0.45,
      -0.15,
    ], k.m);
    _p(c, <double>[-0.2, -0.45, 0, -0.8, 0.2, -0.45, 0, 0.0], k.fill(k.dark));
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFD81B60, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Rose
    c.drawPath(PebblePaths.petal(0, 0.75, 2.4, 0.5, 0.17), k.k);
    c.drawPath(PebblePaths.petal(0, 0.75, 0.7, 0.5, 0.17), k.k);
    _o(c, 0, -0.1, 0.68, k.m);
    final Path s = Path()..moveTo(0, -0.1);
    for (int i = 1; i <= 60; i++) {
      final double a = i / 60 * 4.5 * math.pi;
      final double r = 0.6 * i / 60;
      s.lineTo(math.cos(a) * r, -0.1 + math.sin(a) * r);
    }
    c.drawPath(s, k.line(k.dark, 0.06));
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFFFC107, 0xFF5A3A20, (
    Canvas c,
    StampInk k,
  ) {
    // Sunflower
    _petals(c, 16, 0.95, 0.15, k.m, from: 0.25);
    _petals(c, 16, 0.75, 0.12, k.fill(k.dark), from: 0.25, turn: math.pi / 16);
    _o(c, 0, 0, 0.42, k.k);
    for (int i = 0; i < 14; i++) {
      final double a = i * 2.4;
      final double r = 0.32 * math.sqrt(i / 14);
      _o(c, math.cos(a) * r, math.sin(a) * r, 0.035, k.fill(k.dark));
    }
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFFF7A9C, 0xFFFFD21F, (
    Canvas c,
    StampInk k,
  ) {
    // Five petals
    for (int i = 0; i < 5; i++) {
      final double a = -math.pi / 2 + i * 2 * math.pi / 5;
      _o(c, math.cos(a) * 0.5, math.sin(a) * 0.5, 0.42, k.m);
    }
    _o(c, 0, 0, 0.28, k.k);
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFF9B5DE5, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Lavender
    _l(c, 0, -0.5, 0, 0.98, k.line(k.ink, 0.06));
    for (int i = 0; i < 7; i++) {
      final double y = -0.9 + i * 0.17;
      final double w = 0.12 + i * 0.015;
      _e(c, -w, y, 0.12, 0.09, k.m);
      _e(c, w, y, 0.12, 0.09, k.m);
    }
    c.drawPath(PebblePaths.petal(0, 0.6, -0.6, 0.45, 0.1), k.k);
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFFFC1D6, 0xFFD81B60, (
    Canvas c,
    StampInk k,
  ) {
    // Cherry blossom
    for (int i = 0; i < 5; i++) {
      final double a = -math.pi / 2 + i * 2 * math.pi / 5;
      final Path p = PebblePaths.heart(0, 0, 0.45);
      c
        ..save()
        ..rotate(a + math.pi / 2)
        ..translate(0, -0.5)
        ..rotate(math.pi)
        ..drawPath(p, k.m)
        ..restore();
    }
    _o(c, 0, 0, 0.18, k.k);
    for (int i = 0; i < 5; i++) {
      final double a = -math.pi / 2 + i * 2 * math.pi / 5;
      _o(c, math.cos(a) * 0.3, math.sin(a) * 0.3, 0.05, k.k);
    }
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFE5243B, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Poppy
    for (int i = 0; i < 4; i++) {
      final double a = math.pi / 4 + i * math.pi / 2;
      _o(c, math.cos(a) * 0.4, math.sin(a) * 0.4, 0.55, k.m);
    }
    for (int i = 0; i < 4; i++) {
      final double a = math.pi / 4 + i * math.pi / 2;
      _o(c, math.cos(a) * 0.4, math.sin(a) * 0.4, 0.55, k.line(k.dark, 0.03));
    }
    _o(c, 0, 0, 0.25, k.k);
    for (int i = 0; i < 8; i++) {
      final double a = i * math.pi / 4;
      _o(c, math.cos(a) * 0.35, math.sin(a) * 0.35, 0.05, k.k);
    }
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFF3E8EEA, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Bluebell
    _arc(c, 0.6, -0.4, 0.9, math.pi * 0.6, math.pi * 0.5, k.line(k.ink, 0.06));
    for (final (double x, double y) in <(double, double)>[
      (-0.15, -0.35),
      (0.05, 0.25),
      (0.4, 0.62),
    ]) {
      _p(c, <double>[
        x - 0.22,
        y,
        x - 0.15,
        y - 0.3,
        x + 0.15,
        y - 0.3,
        x + 0.22,
        y,
        x + 0.12,
        y - 0.05,
        x,
        y + 0.02,
        x - 0.12,
        y - 0.05,
      ], k.m);
    }
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFFFD21F, 0xFFFF7F11, (
    Canvas c,
    StampInk k,
  ) {
    // Four petals
    for (int i = 0; i < 4; i++) {
      final double a = i * math.pi / 2;
      c.drawPath(PebblePaths.petal(0, 0, a, 0.95, 0.4), k.m);
    }
    _o(c, 0, 0, 0.22, k.k);
  }),
  PebbleStamp(PebbleStampCategory.flowers, 0xFFF8BBD0, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Lotus
    _e(c, 0, 0.72, 0.9, 0.16, k.k);
    for (final double a in <double>[-2.6, -2.1, -1.57, -1.05, -0.55]) {
      c.drawPath(PebblePaths.petal(0, 0.55, a, 1.05, 0.25), k.m);
    }
    for (final double a in <double>[-2.1, -1.57, -1.05]) {
      c.drawPath(PebblePaths.petal(0, 0.55, a, 0.8, 0.2), k.fill(k.light));
    }
  }),
  // ---- Leaves
  PebbleStamp(PebbleStampCategory.leaves, 0xFF4CAF50, 0xFF1B5E20, (
    Canvas c,
    StampInk k,
  ) {
    // Leaf
    c.drawPath(PebblePaths.petal(-0.75, 0.75, -math.pi / 4, 2.1, 0.55), k.m);
    final Paint v = k.line(k.ink, 0.05);
    _l(c, -0.85, 0.85, 0.7, -0.7, v);
    for (int i = 1; i <= 4; i++) {
      final double x = -0.65 + i * 0.28;
      final double y = 0.65 - i * 0.28;
      _l(c, x, y, x - 0.05, y - 0.32, v);
      _l(c, x, y, x + 0.32, y + 0.05, v);
    }
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFFE76F51, 0xFF8B3A1E, (
    Canvas c,
    StampInk k,
  ) {
    // Maple
    _p(c, <double>[
      0,
      -0.98,
      0.15,
      -0.55,
      0.42,
      -0.7,
      0.35,
      -0.3,
      0.9,
      -0.42,
      0.7,
      -0.05,
      0.85,
      0.05,
      0.4,
      0.3,
      0.45,
      0.5,
      0.05,
      0.4,
      0.05,
      0.98,
      -0.05,
      0.98,
      -0.05,
      0.4,
      -0.45,
      0.5,
      -0.4,
      0.3,
      -0.85,
      0.05,
      -0.7,
      -0.05,
      -0.9,
      -0.42,
      -0.35,
      -0.3,
      -0.42,
      -0.7,
      -0.15,
      -0.55,
    ], k.m);
    final Paint v = k.line(k.ink, 0.04);
    _l(c, 0, 0.6, 0, -0.75, v);
    _l(c, 0, 0.2, 0.6, -0.25, v);
    _l(c, 0, 0.2, -0.6, -0.25, v);
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFF8BAA3C, 0xFF4E6B1A, (
    Canvas c,
    StampInk k,
  ) {
    // Oak leaf
    _b(c, <double>[
      0,
      -0.95,
      0.3,
      -0.7,
      0.2,
      -0.45,
      0.5,
      -0.3,
      0.35,
      -0.05,
      0.6,
      0.15,
      0.35,
      0.35,
      0.4,
      0.6,
      0.05,
      0.6,
      0,
      0.75,
      -0.05,
      0.6,
      -0.4,
      0.6,
      -0.35,
      0.35,
      -0.6,
      0.15,
      -0.35,
      -0.05,
      -0.5,
      -0.3,
      -0.2,
      -0.45,
      -0.3,
      -0.7,
    ], k.m);
    _l(c, 0, -0.85, 0, 0.98, k.line(k.ink, 0.05));
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFF2E8B3E, 0xFF145A2A, (
    Canvas c,
    StampInk k,
  ) {
    // Fern
    final Path stem = Path()
      ..moveTo(0, 0.98)
      ..quadraticBezierTo(0.15, 0, -0.1, -0.95);
    c.drawPath(stem, k.line(k.ink, 0.05));
    for (int i = 0; i < 8; i++) {
      final double tt = i / 8;
      final double y = 0.8 - tt * 1.65;
      final double x = 0.08 * math.sin(tt * math.pi);
      final double len = 0.65 * (1 - tt * 0.7);
      c.drawPath(PebblePaths.petal(x, y, -0.5, len, 0.09), k.m);
      c.drawPath(PebblePaths.petal(x, y, -2.64, len, 0.09), k.m);
    }
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFF43A047, 0xFF1B5E20, (
    Canvas c,
    StampInk k,
  ) {
    // Clover
    for (int i = 0; i < 4; i++) {
      final Path p = PebblePaths.heart(0, 0, 0.36);
      c
        ..save()
        ..rotate(i * math.pi / 2 + math.pi / 4)
        ..translate(0, -0.4)
        ..rotate(math.pi)
        ..drawPath(p, k.m)
        ..restore();
    }
    final Path stem = Path()
      ..moveTo(0, 0)
      ..quadraticBezierTo(0.2, 0.5, 0.05, 0.98);
    c.drawPath(stem, k.line(k.ink, 0.07));
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFFF2C14E, 0xFFB8860B, (
    Canvas c,
    StampInk k,
  ) {
    // Ginkgo
    final Path p = Path()
      ..moveTo(0, 0.35)
      ..lineTo(-0.85, -0.45)
      ..quadraticBezierTo(-0.5, -0.95, 0, -0.75)
      ..quadraticBezierTo(0.5, -0.95, 0.85, -0.45)
      ..close();
    c.drawPath(p, k.m);
    _p(c, <double>[0, -0.75, -0.06, -0.45, 0.06, -0.45], k.fill(k.ink));
    final Paint v = k.line(k.ink, 0.03);
    for (int i = -3; i <= 3; i++) {
      _l(c, 0, 0.3, i * 0.22, -0.6, v);
    }
    _l(c, 0, 0.3, 0, 0.98, k.line(k.ink, 0.06));
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFF6BCB3B, 0xFF5A3A20, (
    Canvas c,
    StampInk k,
  ) {
    // Twig
    _l(c, -0.9, 0.7, 0.9, -0.7, k.line(k.ink, 0.07));
    for (int i = 0; i < 4; i++) {
      final double x = -0.6 + i * 0.42;
      final double y = 0.47 - i * 0.33;
      c.drawPath(PebblePaths.petal(x, y, -2.0, 0.5, 0.17), k.m);
      c.drawPath(PebblePaths.petal(x, y, -0.1, 0.5, 0.17), k.m);
    }
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFF2E7D32, 0xFF1B5E20, (
    Canvas c,
    StampInk k,
  ) {
    // Ivy
    final Path p = Path()
      ..moveTo(0, 0.85)
      ..lineTo(-0.9, -0.05)
      ..lineTo(-0.45, -0.25)
      ..lineTo(-0.55, -0.7)
      ..lineTo(0, -0.95)
      ..lineTo(0.55, -0.7)
      ..lineTo(0.45, -0.25)
      ..lineTo(0.9, -0.05)
      ..close();
    c.drawPath(p, k.m);
    final Paint v = k.line(k.light, 0.04);
    _l(c, 0, 0.8, 0, -0.8, v);
    _l(c, 0, 0.3, -0.7, -0.05, v);
    _l(c, 0, 0.3, 0.7, -0.05, v);
  }),
  PebbleStamp(PebbleStampCategory.leaves, 0xFF66BB6A, 0xFF33691E, (
    Canvas c,
    StampInk k,
  ) {
    // Palm leaf
    final Path stem = Path()
      ..moveTo(-0.2, 0.98)
      ..quadraticBezierTo(0, 0.1, 0.7, -0.6);
    c.drawPath(stem, k.line(k.ink, 0.06));
    for (int i = 0; i < 7; i++) {
      final double tt = 0.25 + i * 0.11;
      final double x = -0.2 + tt * tt * 0.9 + tt * 0.0;
      final double y = 0.98 - tt * 1.6;
      c.drawPath(PebblePaths.petal(x, y, -2.3 + i * 0.05, 0.7, 0.1), k.m);
      c.drawPath(PebblePaths.petal(x, y, -0.35 + i * 0.05, 0.6, 0.1), k.m);
    }
  }),
  // ---- Stars
  PebbleStamp(PebbleStampCategory.stars, 0xFFFFD21F, 0xFFC99A00, (
    Canvas c,
    StampInk k,
  ) {
    c.drawPath(PebblePaths.star(0, 0.05, 0.98), k.m);
    c.drawPath(PebblePaths.star(0, 0.05, 0.98), k.line(k.ink, 0.05));
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFF3E8EEA, 0xFF1846A8, (
    Canvas c,
    StampInk k,
  ) {
    c.drawPath(PebblePaths.star(0, 0, 0.98, points: 6, inner: 0.55), k.m);
    c.drawPath(PebblePaths.polygon(0, 0, 0.4, 6, turn: math.pi / 6), k.k);
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFFFFF09A, 0xFFFFD21F, (
    Canvas c,
    StampInk k,
  ) {
    // Sparkle
    c.drawPath(PebblePaths.star(0, 0, 0.98, points: 4, inner: 0.22), k.m);
    c.drawPath(PebblePaths.star(0, 0, 0.5, points: 4, inner: 0.3), k.k);
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFFFF7F11, 0xFFE5243B, (
    Canvas c,
    StampInk k,
  ) {
    c.drawPath(PebblePaths.star(0, 0, 0.98, points: 8, inner: 0.6), k.m);
    _o(c, 0, 0, 0.35, k.k);
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFFFFD21F, 0xFFFF7F11, (
    Canvas c,
    StampInk k,
  ) {
    // Shooting star
    for (int i = 0; i < 3; i++) {
      _l(
        c,
        -0.95,
        -0.2 + i * 0.3,
        0.05,
        -0.45 + i * 0.3 + 0.2,
        k.line(k.ink.withValues(alpha: 0.8 - i * 0.2), 0.09),
      );
    }
    c.drawPath(PebblePaths.star(0.4, 0.0, 0.58), k.m);
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFFFFFFFF, 0xFFFFD21F, (
    Canvas c,
    StampInk k,
  ) {
    // Star outline
    c.drawPath(PebblePaths.star(0, 0.05, 0.92), k.line(k.main, 0.14));
    c.drawPath(PebblePaths.star(0, 0.05, 0.4), k.k);
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFFFFD21F, 0xFFFFFFFF, (
    Canvas c,
    StampInk k,
  ) {
    // Three sparkles
    c.drawPath(PebblePaths.star(-0.3, 0.2, 0.7, points: 4, inner: 0.25), k.m);
    c.drawPath(
      PebblePaths.star(0.55, -0.45, 0.42, points: 4, inner: 0.25),
      k.m,
    );
    c.drawPath(PebblePaths.star(0.55, 0.62, 0.3, points: 4, inner: 0.25), k.k);
  }),
  PebbleStamp(PebbleStampCategory.stars, 0xFF1A1A1A, 0xFFE5243B, (
    Canvas c,
    StampInk k,
  ) {
    // Compass rose
    c.drawPath(PebblePaths.star(0, 0, 0.98, points: 4, inner: 0.25), k.m);
    c.drawPath(
      PebblePaths.star(0, 0, 0.6, points: 4, inner: 0.3, turn: math.pi / 4),
      k.fill(k.light),
    );
    _p(c, <double>[0, -0.98, 0.12, -0.2, -0.12, -0.2], k.k);
    _o(c, 0, 0, 0.1, k.fill(StampInk.white));
  }),
  // ---- Hearts
  PebbleStamp(PebbleStampCategory.hearts, 0xFFE5243B, 0xFF9E1328, (
    Canvas c,
    StampInk k,
  ) {
    c.drawPath(PebblePaths.heart(0, 0.05, 0.95), k.m);
    _e(
      c,
      -0.45,
      -0.35,
      0.12,
      0.2,
      k.fill(StampInk.white.withValues(alpha: 0.6)),
    );
  }),
  PebbleStamp(PebbleStampCategory.hearts, 0xFFFF7A9C, 0xFFFF7A9C, (
    Canvas c,
    StampInk k,
  ) {
    c.drawPath(PebblePaths.heart(0, 0.05, 0.85), k.line(k.main, 0.16));
  }),
  PebbleStamp(PebbleStampCategory.hearts, 0xFFE5243B, 0xFFFF7A9C, (
    Canvas c,
    StampInk k,
  ) {
    // Two hearts
    c.drawPath(PebblePaths.heart(0.3, 0.2, 0.62), k.k);
    c.drawPath(PebblePaths.heart(-0.25, -0.15, 0.62), k.m);
  }),
  PebbleStamp(PebbleStampCategory.hearts, 0xFFE5243B, 0xFF8B5A33, (
    Canvas c,
    StampInk k,
  ) {
    // Heart with an arrow
    _l(c, -0.95, 0.6, 0.95, -0.6, k.line(k.ink, 0.07));
    c.drawPath(PebblePaths.heart(0, 0.05, 0.72), k.m);
    _p(c, <double>[0.95, -0.6, 0.65, -0.62, 0.85, -0.35], k.k);
    _l(c, 0.35, -0.22, 0.95, -0.6, k.line(k.ink, 0.07));
  }),
  PebbleStamp(PebbleStampCategory.hearts, 0xFF9B5DE5, 0xFFFFFFFF, (
    Canvas c,
    StampInk k,
  ) {
    // Patched heart
    c.drawPath(PebblePaths.heart(0, 0.05, 0.95), k.m);
    final Paint s = k.line(k.ink, 0.06);
    _l(c, -0.3, -0.2, 0.3, 0.3, s);
    _l(c, 0.3, -0.2, -0.3, 0.3, s);
  }),
  PebbleStamp(PebbleStampCategory.hearts, 0xFFFF7A9C, 0xFFE5243B, (
    Canvas c,
    StampInk k,
  ) {
    // Heart with little hearts
    c.drawPath(PebblePaths.heart(0, 0.15, 0.7), k.m);
    c.drawPath(PebblePaths.heart(-0.72, -0.6, 0.22), k.k);
    c.drawPath(PebblePaths.heart(0.72, -0.62, 0.18), k.k);
    c.drawPath(PebblePaths.heart(0.78, 0.55, 0.15), k.k);
  }),
  // ---- Faces
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF3A2A1A, (
    Canvas c,
    StampInk k,
  ) {
    _face(c, k);
    _e(c, -0.32, -0.25, 0.1, 0.16, k.k);
    _e(c, 0.32, -0.25, 0.1, 0.16, k.k);
    _smile(c, k, 0.62, 0.5, 0.09);
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF3A2A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Laughing
    _face(c, k);
    _arc(c, -0.32, -0.2, 0.13, math.pi, math.pi, k.line(k.ink, 0.08));
    _arc(c, 0.32, -0.2, 0.13, math.pi, math.pi, k.line(k.ink, 0.08));
    final Path m = Path()
      ..moveTo(-0.55, 0.12)
      ..quadraticBezierTo(0, 1.0, 0.55, 0.12)
      ..close();
    c.drawPath(m, k.k);
    _e(c, 0, 0.5, 0.2, 0.1, k.fill(StampInk.pink));
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF3A2A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Winking
    _face(c, k);
    _e(c, -0.32, -0.25, 0.1, 0.16, k.k);
    _arc(c, 0.32, -0.15, 0.14, math.pi, math.pi, k.line(k.ink, 0.08));
    _smile(c, k, 0.62, 0.5, 0.09);
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFFE5243B, (
    Canvas c,
    StampInk k,
  ) {
    // In love
    _face(c, k);
    c.drawPath(PebblePaths.heart(-0.34, -0.25, 0.22), k.k);
    c.drawPath(PebblePaths.heart(0.34, -0.25, 0.22), k.k);
    _arc(
      c,
      0,
      0.12,
      0.42,
      0.4,
      math.pi - 0.8,
      k.line(const Color(0xFF3A2A1A), 0.09),
    );
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF3A2A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Surprised
    _face(c, k);
    _o(c, -0.32, -0.25, 0.14, k.k);
    _o(c, 0.32, -0.25, 0.14, k.k);
    _e(c, 0, 0.4, 0.17, 0.24, k.k);
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFB7D9F2, 0xFF2B3A55, (
    Canvas c,
    StampInk k,
  ) {
    // Sleepy
    _face(c, k);
    _arc(c, -0.32, -0.3, 0.14, 0.2, math.pi - 0.4, k.line(k.ink, 0.07));
    _arc(c, 0.32, -0.3, 0.14, 0.2, math.pi - 0.4, k.line(k.ink, 0.07));
    _o(c, 0, 0.4, 0.1, k.k);
    final Paint z = k.line(k.ink, 0.05);
    _p(c, <double>[0.55, -0.85, 0.8, -0.85, 0.55, -0.6, 0.8, -0.6], z);
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Sunglasses
    _face(c, k);
    final Path g = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(-0.72, -0.42, 0.62, 0.36),
          const Radius.circular(0.15),
        ),
      )
      ..addRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(0.1, -0.42, 0.62, 0.36),
          const Radius.circular(0.15),
        ),
      );
    c.drawPath(g, k.k);
    _l(c, -0.15, -0.36, 0.15, -0.36, k.line(k.ink, 0.07));
    _smile(c, k, 0.6, 0.45, 0.08);
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF3A2A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Tongue out
    _face(c, k);
    _e(c, -0.32, -0.25, 0.1, 0.16, k.k);
    _e(c, 0.32, -0.25, 0.1, 0.16, k.k);
    _e(c, 0.05, 0.5, 0.2, 0.25, k.fill(StampInk.pink));
    _l(c, -0.4, 0.3, 0.4, 0.3, k.line(k.ink, 0.08));
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFF8ECAE6, 0xFF1A2A40, (
    Canvas c,
    StampInk k,
  ) {
    // Sad
    _face(c, k);
    _e(c, -0.32, -0.2, 0.1, 0.16, k.k);
    _e(c, 0.32, -0.2, 0.1, 0.16, k.k);
    _arc(c, 0, 0.75, 0.38, -math.pi + 0.5, math.pi - 1.0, k.line(k.ink, 0.08));
    _e(c, 0.45, 0.1, 0.07, 0.13, k.fill(const Color(0xFF3E8EEA)));
  }),
  PebbleStamp(PebbleStampCategory.faces, 0xFFFFD21F, 0xFF3A2A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Blushing
    _face(c, k);
    _arc(c, -0.32, -0.18, 0.13, math.pi, math.pi, k.line(k.ink, 0.08));
    _arc(c, 0.32, -0.18, 0.13, math.pi, math.pi, k.line(k.ink, 0.08));
    _e(c, -0.55, 0.15, 0.17, 0.1, k.fill(StampInk.pink));
    _e(c, 0.55, 0.15, 0.17, 0.1, k.fill(StampInk.pink));
    _smile(c, k, 0.55, 0.3, 0.08);
  }),
  // ---- Weather
  PebbleStamp(PebbleStampCategory.weather, 0xFFFFD21F, 0xFFFF7F11, (
    Canvas c,
    StampInk k,
  ) {
    // Sun
    for (int i = 0; i < 12; i++) {
      final double a = i * math.pi / 6;
      _p(c, <double>[
        math.cos(a - 0.14) * 0.55,
        math.sin(a - 0.14) * 0.55,
        math.cos(a) * 0.98,
        math.sin(a) * 0.98,
        math.cos(a + 0.14) * 0.55,
        math.sin(a + 0.14) * 0.55,
      ], k.k);
    }
    _o(c, 0, 0, 0.55, k.m);
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFFFFFFFF, 0xFFB0BEC5, (
    Canvas c,
    StampInk k,
  ) {
    // Cloud
    _o(c, -0.45, 0.2, 0.35, k.k);
    _o(c, 0.0, -0.05, 0.48, k.k);
    _o(c, 0.48, 0.18, 0.36, k.k);
    _e(c, 0, 0.35, 0.8, 0.25, k.k);
    _o(c, -0.45, 0.15, 0.32, k.m);
    _o(c, 0.0, -0.1, 0.44, k.m);
    _o(c, 0.48, 0.13, 0.32, k.m);
    _e(c, 0, 0.3, 0.76, 0.22, k.m);
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFF90A4AE, 0xFF3E8EEA, (
    Canvas c,
    StampInk k,
  ) {
    // Rain
    _o(c, -0.4, -0.25, 0.3, k.m);
    _o(c, 0.05, -0.45, 0.4, k.m);
    _o(c, 0.45, -0.25, 0.3, k.m);
    _e(c, 0, -0.1, 0.75, 0.2, k.m);
    for (final double x in <double>[-0.45, 0.0, 0.45]) {
      _e(c, x, 0.4, 0.08, 0.14, k.k);
      _e(c, x - 0.15, 0.78, 0.08, 0.14, k.k);
    }
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFFFFD21F, 0xFFC99A00, (
    Canvas c,
    StampInk k,
  ) {
    // Lightning
    _p(c, <double>[
      0.2,
      -0.98,
      -0.55,
      0.15,
      -0.05,
      0.15,
      -0.25,
      0.98,
      0.6,
      -0.2,
      0.1,
      -0.2,
      0.4,
      -0.98,
    ], k.m);
    _p(c, <double>[
      0.2,
      -0.98,
      -0.55,
      0.15,
      -0.05,
      0.15,
      -0.25,
      0.98,
      0.6,
      -0.2,
      0.1,
      -0.2,
      0.4,
      -0.98,
    ], k.line(k.ink, 0.04));
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFF8ECAE6, 0xFF8ECAE6, (
    Canvas c,
    StampInk k,
  ) {
    // Snowflake
    final Paint p = k.line(k.main, 0.1);
    for (int i = 0; i < 6; i++) {
      final double a = i * math.pi / 3;
      final double cs = math.cos(a), sn = math.sin(a);
      _l(c, 0, 0, cs * 0.95, sn * 0.95, p);
      for (final double d in <double>[0.45, 0.7]) {
        final double bx = cs * d, by = sn * d;
        _l(
          c,
          bx,
          by,
          bx + math.cos(a + 0.8) * 0.22,
          by + math.sin(a + 0.8) * 0.22,
          p,
        );
        _l(
          c,
          bx,
          by,
          bx + math.cos(a - 0.8) * 0.22,
          by + math.sin(a - 0.8) * 0.22,
          p,
        );
      }
    }
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFFE5243B, 0xFFFFFFFF, (
    Canvas c,
    StampInk k,
  ) {
    // Rainbow
    const List<Color> bands = <Color>[
      Color(0xFFE5243B),
      Color(0xFFFF7F11),
      Color(0xFFFFD21F),
      Color(0xFF6BCB3B),
      Color(0xFF3E8EEA),
      Color(0xFF9B5DE5),
    ];
    for (int i = 0; i < bands.length; i++) {
      _arc(
        c,
        0,
        0.55,
        0.9 - i * 0.11,
        math.pi,
        math.pi,
        k.line(i == 0 ? k.main : bands[i], 0.12),
      );
    }
    _o(c, -0.75, 0.6, 0.2, k.k);
    _o(c, 0.75, 0.6, 0.2, k.k);
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFFFFF09A, 0xFFFFD21F, (
    Canvas c,
    StampInk k,
  ) {
    // Moon
    final Path moon = Path.combine(
      PathOperation.difference,
      PebblePaths.circle(0, 0, 0.9),
      PebblePaths.circle(0.42, -0.25, 0.75),
    );
    c.drawPath(moon, k.m);
    c.drawPath(PebblePaths.star(0.55, 0.45, 0.2, points: 4, inner: 0.3), k.k);
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFFE5243B, 0xFF5A3A20, (
    Canvas c,
    StampInk k,
  ) {
    // Umbrella
    final Path top = Path()
      ..moveTo(-0.95, 0.05)
      ..quadraticBezierTo(0, -1.2, 0.95, 0.05)
      ..quadraticBezierTo(0.63, -0.15, 0.32, 0.05)
      ..quadraticBezierTo(0, -0.15, -0.32, 0.05)
      ..quadraticBezierTo(-0.63, -0.15, -0.95, 0.05)
      ..close();
    c.drawPath(top, k.m);
    _l(c, 0, -0.45, 0, 0.75, k.line(k.ink, 0.07));
    _arc(c, -0.15, 0.75, 0.15, 0, math.pi, k.line(k.ink, 0.07));
  }),
  PebbleStamp(PebbleStampCategory.weather, 0xFF3E8EEA, 0xFFFFFFFF, (
    Canvas c,
    StampInk k,
  ) {
    // Drop
    final Path d = Path()
      ..moveTo(0, -0.98)
      ..quadraticBezierTo(0.75, 0.0, 0.62, 0.42)
      ..arcToPoint(
        const Offset(-0.62, 0.42),
        radius: const Radius.circular(0.65),
      )
      ..quadraticBezierTo(-0.75, 0.0, 0, -0.98)
      ..close();
    c.drawPath(d, k.m);
    _e(c, -0.25, 0.25, 0.1, 0.2, k.fill(k.ink.withValues(alpha: 0.7)));
  }),
  // ---- Food
  PebbleStamp(PebbleStampCategory.food, 0xFFE5243B, 0xFF5A3A20, (
    Canvas c,
    StampInk k,
  ) {
    // Apple
    _b(c, <double>[
      0,
      -0.45,
      0.6,
      -0.65,
      0.85,
      0.05,
      0.45,
      0.85,
      0,
      0.7,
      -0.45,
      0.85,
      -0.85,
      0.05,
      -0.6,
      -0.65,
    ], k.m);
    _l(c, 0, -0.45, 0.1, -0.9, k.line(k.ink, 0.07));
    c.drawPath(
      PebblePaths.petal(0.08, -0.7, -0.5, 0.5, 0.15),
      k.fill(StampInk.green),
    );
    _e(c, -0.4, -0.2, 0.1, 0.18, k.fill(StampInk.white.withValues(alpha: 0.5)));
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFC2185B, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Cherries
    final Paint st = k.line(k.ink, 0.06);
    final Path s = Path()
      ..moveTo(-0.45, 0.35)
      ..quadraticBezierTo(-0.3, -0.4, 0.2, -0.85)
      ..moveTo(0.4, 0.45)
      ..quadraticBezierTo(0.35, -0.3, 0.2, -0.85);
    c.drawPath(s, st);
    c.drawPath(PebblePaths.petal(0.2, -0.85, -0.3, 0.5, 0.15), k.k);
    _o(c, -0.45, 0.55, 0.36, k.m);
    _o(c, 0.4, 0.62, 0.34, k.m);
    _o(c, -0.55, 0.45, 0.08, k.fill(StampInk.white.withValues(alpha: 0.6)));
    _o(c, 0.3, 0.52, 0.08, k.fill(StampInk.white.withValues(alpha: 0.6)));
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFE5243B, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Strawberry
    final Path b = Path()
      ..moveTo(0, 0.98)
      ..quadraticBezierTo(-0.95, 0.1, -0.7, -0.45)
      ..quadraticBezierTo(0, -0.7, 0.7, -0.45)
      ..quadraticBezierTo(0.95, 0.1, 0, 0.98)
      ..close();
    c.drawPath(b, k.m);
    for (int i = 0; i < 5; i++) {
      c.drawPath(
        PebblePaths.petal(0, -0.55, -math.pi / 2 + (i - 2) * 0.55, 0.42, 0.13),
        k.k,
      );
    }
    for (final (double x, double y) in <(double, double)>[
      (-0.35, -0.15),
      (0.0, -0.1),
      (0.35, -0.15),
      (-0.2, 0.2),
      (0.2, 0.2),
      (0.0, 0.5),
      (-0.45, 0.15),
      (0.45, 0.15),
    ]) {
      _e(c, x, y, 0.035, 0.06, k.fill(StampInk.yellow));
    }
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFF5A6E, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Watermelon slice
    c.drawArc(
      Rect.fromCircle(center: const Offset(0, -0.4), radius: 1.05),
      0.15,
      math.pi - 0.3,
      true,
      k.k,
    );
    c.drawArc(
      Rect.fromCircle(center: const Offset(0, -0.4), radius: 0.95),
      0.15,
      math.pi - 0.3,
      true,
      k.fill(StampInk.white),
    );
    c.drawArc(
      Rect.fromCircle(center: const Offset(0, -0.4), radius: 0.85),
      0.15,
      math.pi - 0.3,
      true,
      k.m,
    );
    for (final (double x, double y) in <(double, double)>[
      (-0.4, -0.05),
      (0.0, 0.05),
      (0.4, -0.05),
      (-0.2, 0.25),
      (0.2, 0.25),
    ]) {
      _e(c, x, y, 0.04, 0.07, k.fill(const Color(0xFF1A1A1A)));
    }
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFC5D86D, 0xFF5A3A20, (
    Canvas c,
    StampInk k,
  ) {
    // Pear
    _b(c, <double>[
      0,
      -0.75,
      0.3,
      -0.45,
      0.65,
      0.35,
      0.3,
      0.9,
      -0.3,
      0.9,
      -0.65,
      0.35,
      -0.3,
      -0.45,
    ], k.m);
    _l(c, 0, -0.72, 0.08, -0.98, k.line(k.ink, 0.06));
    c.drawPath(
      PebblePaths.petal(0.06, -0.85, -0.2, 0.35, 0.1),
      k.fill(StampInk.green),
    );
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFF7F11, 0xFF2E8B3E, (
    Canvas c,
    StampInk k,
  ) {
    // Carrot
    _p(c, <double>[-0.3, -0.45, 0.3, -0.45, 0.02, 0.98, -0.02, 0.98], k.m);
    final Paint l = k.line(k.dark, 0.04);
    _l(c, -0.2, -0.1, 0.0, -0.1, l);
    _l(c, 0.05, 0.25, 0.18, 0.25, l);
    _l(c, -0.12, 0.55, 0.02, 0.55, l);
    for (final double a in <double>[-2.1, -1.57, -1.0]) {
      c.drawPath(PebblePaths.petal(0, -0.45, a, 0.5, 0.12), k.k);
    }
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFE5243B, 0xFFF3EEE3, (
    Canvas c,
    StampInk k,
  ) {
    // Mushroom
    c.drawPath(
      Path()
        ..moveTo(-0.28, 0.0)
        ..lineTo(-0.32, 0.9)
        ..lineTo(0.32, 0.9)
        ..lineTo(0.28, 0.0)
        ..close(),
      k.k,
    );
    c.drawArc(
      Rect.fromCenter(center: const Offset(0, 0.05), width: 1.9, height: 1.7),
      math.pi,
      math.pi,
      true,
      k.m,
    );
    for (final (double x, double y, double r) in <(double, double, double)>[
      (-0.5, -0.25, 0.13),
      (0.1, -0.55, 0.15),
      (0.55, -0.2, 0.11),
      (-0.1, -0.15, 0.09),
    ]) {
      _o(c, x, y, r, k.fill(StampInk.white));
    }
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFF8FB1, 0xFFD9A85B, (
    Canvas c,
    StampInk k,
  ) {
    // Ice cream
    _p(c, <double>[-0.42, -0.05, 0.42, -0.05, 0, 0.98], k.k);
    final Paint g = k.line(k.dark.withValues(alpha: 0.4), 0.03);
    _l(c, -0.3, 0.1, 0.15, 0.6, g);
    _l(c, 0.3, 0.1, -0.15, 0.6, g);
    _o(c, 0, -0.42, 0.45, k.m);
    _o(c, -0.35, -0.12, 0.18, k.m);
    _o(c, 0.0, -0.08, 0.18, k.m);
    _o(c, 0.35, -0.12, 0.18, k.m);
    _o(c, 0.05, -0.92, 0.1, k.fill(StampInk.red));
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFFC1D6, 0xFFD9A85B, (
    Canvas c,
    StampInk k,
  ) {
    // Cupcake
    _p(c, <double>[-0.6, 0.05, 0.6, 0.05, 0.45, 0.95, -0.45, 0.95], k.k);
    for (int i = -2; i <= 2; i++) {
      _l(
        c,
        i * 0.2,
        0.1,
        i * 0.16,
        0.9,
        k.line(k.dark.withValues(alpha: 0.3), 0.04),
      );
    }
    _o(c, -0.4, -0.05, 0.28, k.m);
    _o(c, 0.4, -0.05, 0.28, k.m);
    _o(c, 0, -0.3, 0.4, k.m);
    _o(c, 0, -0.78, 0.13, k.fill(StampInk.red));
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFFE066, 0xFFFFD21F, (
    Canvas c,
    StampInk k,
  ) {
    // Lemon slice
    _o(c, 0, 0, 0.95, k.k);
    _o(c, 0, 0, 0.85, k.fill(StampInk.white));
    for (int i = 0; i < 8; i++) {
      c.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: 0.78),
        i * math.pi / 4 + 0.06,
        math.pi / 4 - 0.12,
        true,
        k.m,
      );
    }
    _o(c, 0, 0, 0.1, k.fill(StampInk.white));
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFF8FB1, 0xFFD9A85B, (
    Canvas c,
    StampInk k,
  ) {
    // Doughnut
    final Path ring = Path.combine(
      PathOperation.difference,
      PebblePaths.circle(0, 0, 0.95),
      PebblePaths.circle(0, 0, 0.32),
    );
    c.drawPath(ring, k.k);
    final Path glaze = Path.combine(
      PathOperation.difference,
      PebblePaths.blob(<double>[
        0,
        -0.85,
        0.65,
        -0.55,
        0.85,
        0.1,
        0.5,
        0.7,
        -0.1,
        0.8,
        -0.7,
        0.5,
        -0.8,
        -0.2,
        -0.5,
        -0.7,
      ]),
      PebblePaths.circle(0, 0, 0.4),
    );
    c.drawPath(glaze, k.m);
    final PebbleRandom rnd = PebbleRandom(7);
    const List<Color> sprinkles = <Color>[
      Color(0xFF3E8EEA),
      Color(0xFFFFD21F),
      Color(0xFF6BCB3B),
      Color(0xFFFFFFFF),
    ];
    for (int i = 0; i < 14; i++) {
      final double a = rnd.range(0, math.pi * 2);
      final double r = rnd.range(0.5, 0.7);
      final double x = math.cos(a) * r, y = math.sin(a) * r;
      final double o = rnd.range(0, math.pi);
      _l(
        c,
        x,
        y,
        x + math.cos(o) * 0.1,
        y + math.sin(o) * 0.1,
        k.line(sprinkles[i % 4], 0.05),
      );
    }
  }),
  PebbleStamp(PebbleStampCategory.food, 0xFFFFC857, 0xFFE5243B, (
    Canvas c,
    StampInk k,
  ) {
    // Pizza slice
    _p(c, <double>[-0.8, -0.65, 0.8, -0.65, 0, 0.98], k.m);
    c.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTRB(-0.88, -0.85, 0.88, -0.55),
        const Radius.circular(0.15),
      ),
      k.fill(const Color(0xFFD9A85B)),
    );
    for (final (double x, double y) in <(double, double)>[
      (-0.3, -0.3),
      (0.28, -0.25),
      (0.0, 0.2),
      (-0.05, 0.6),
    ]) {
      _o(c, x, y, 0.12, k.k);
    }
  }),
  // ---- Geometric
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFF3E8EEA,
    0xFF1846A8,
    (Canvas c, StampInk k) => _o(c, 0, 0, 0.95, k.m),
  ),
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFFFFFFFF,
    0xFFFFFFFF,
    (Canvas c, StampInk k) => _o(c, 0, 0, 0.82, k.line(k.main, 0.24)),
  ),
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFF6BCB3B,
    0xFF2E8B3E,
    (Canvas c, StampInk k) =>
        c.drawPath(PebblePaths.polygon(0, 0.15, 1.0, 3), k.m),
  ),
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFFFF7F11,
    0xFFC05A0A,
    (Canvas c, StampInk k) =>
        c.drawRect(const Rect.fromLTRB(-0.8, -0.8, 0.8, 0.8), k.m),
  ),
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFF9B5DE5,
    0xFF5B2A9E,
    (Canvas c, StampInk k) =>
        _p(c, <double>[0, -0.98, 0.65, 0, 0, 0.98, -0.65, 0], k.m),
  ),
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFFFFD21F,
    0xFFC99A00,
    (Canvas c, StampInk k) =>
        c.drawPath(PebblePaths.polygon(0, 0, 0.95, 6, turn: math.pi / 6), k.m),
  ),
  PebbleStamp(
    PebbleStampCategory.geometric,
    0xFF1FB5A8,
    0xFF0E6E6A,
    (Canvas c, StampInk k) =>
        c.drawPath(PebblePaths.polygon(0, 0.06, 0.95, 5), k.m),
  ),
  PebbleStamp(PebbleStampCategory.geometric, 0xFFE5243B, 0xFF9E1328, (
    Canvas c,
    StampInk k,
  ) {
    c.drawRect(const Rect.fromLTRB(-0.28, -0.9, 0.28, 0.9), k.m);
    c.drawRect(const Rect.fromLTRB(-0.9, -0.28, 0.9, 0.28), k.m);
  }),
  PebbleStamp(PebbleStampCategory.geometric, 0xFF1A1A1A, 0xFF1A1A1A, (
    Canvas c,
    StampInk k,
  ) {
    // Spiral
    final Path s = Path()..moveTo(0, 0);
    for (int i = 1; i <= 120; i++) {
      final double a = i / 120 * 6 * math.pi;
      final double r = 0.9 * i / 120;
      s.lineTo(math.cos(a) * r, math.sin(a) * r);
    }
    c.drawPath(s, k.line(k.main, 0.1));
  }),
  PebbleStamp(PebbleStampCategory.geometric, 0xFF3E8EEA, 0xFF1846A8, (
    Canvas c,
    StampInk k,
  ) {
    // Arrow
    _p(c, <double>[
      -0.9,
      -0.2,
      0.25,
      -0.2,
      0.25,
      -0.6,
      0.95,
      0,
      0.25,
      0.6,
      0.25,
      0.2,
      -0.9,
      0.2,
    ], k.m);
  }),
  PebbleStamp(PebbleStampCategory.geometric, 0xFF1FB5A8, 0xFF1FB5A8, (
    Canvas c,
    StampInk k,
  ) {
    // Wave
    final Path w = Path()..moveTo(-0.95, 0);
    for (int i = 1; i <= 40; i++) {
      final double x = -0.95 + i / 40 * 1.9;
      w.lineTo(x, math.sin(x * math.pi * 1.5) * 0.35);
    }
    c.drawPath(w, k.line(k.main, 0.16));
  }),
  PebbleStamp(PebbleStampCategory.geometric, 0xFFFFFFFF, 0xFFFFFFFF, (
    Canvas c,
    StampInk k,
  ) {
    // Ring of dots
    for (int i = 0; i < 12; i++) {
      final double a = i * math.pi / 6;
      _o(c, math.cos(a) * 0.78, math.sin(a) * 0.78, 0.14, k.m);
    }
    _o(c, 0, 0, 0.2, k.m);
  }),
  PebbleStamp(PebbleStampCategory.geometric, 0xFFE5243B, 0xFFE5243B, (
    Canvas c,
    StampInk k,
  ) {
    // Chevrons
    final Paint p = k.line(k.main, 0.2);
    for (final double y in <double>[-0.45, 0.25]) {
      c.drawPath(
        PebblePaths.poly(<double>[
          -0.75,
          y + 0.4,
          0,
          y - 0.25,
          0.75,
          y + 0.4,
        ], close: false),
        p,
      );
    }
  }),
];

const String _glyphs = 'ABCDEFGHIJKLMNOPQRSTUVWXYZĄĆĘŁŃÓŚŹŻ0123456789';

StampPainter _glyphPainter(String g) => (Canvas c, StampInk k) {
  final TextPainter tp = TextPainter(
    text: TextSpan(
      text: g,
      style: TextStyle(
        fontFamily: 'Baloo 2',
        fontFamilyFallback: const <String>['Hanken Grotesk'],
        fontSize: 100,
        fontWeight: FontWeight.w700,
        color: k.main,
        // Baloo 2's capitals are 0.6 em tall in a 1.6 em line: a shorter
        // line makes the letters as big as they were.
        height: 0.9,
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  final double scale = 1.8 / math.max(tp.height, 1);
  c
    ..save()
    ..scale(scale)
    ..translate(-tp.width / 2, -tp.height / 2);
  tp.paint(c, Offset.zero);
  c.restore();
  tp.dispose();
};

/// All stamps. The index is stored in designs: add new ones at the end only.
abstract final class PebbleStamps {
  static final List<PebbleStamp> all = <PebbleStamp>[
    ..._drawn,
    for (final String g in _glyphs.split(''))
      PebbleStamp(
        PebbleStampCategory.letters,
        0xFF1A1A1A,
        0xFF1A1A1A,
        _glyphPainter(g),
        g,
      ),
  ];

  static int get count => all.length;

  static List<int> inCategory(PebbleStampCategory category) => <int>[
    for (int i = 0; i < all.length; i++)
      if (all[i].category == category) i,
  ];

  /// What a screen reader says for stamp [id]: the letter itself, or the
  /// group and the stamp's number in it.
  static String label(int id) {
    final PebbleStamp s = all[id];
    if (s.glyph != null) {
      return s.glyph!;
    }
    final int n = inCategory(s.category).indexOf(id) + 1;
    return t('{category} {n}', <String, Object?>{
      'category': s.category.label,
      'n': n,
    });
  }

  /// Draws stamp [id] in the box ±1 with [main] and [ink] (null: its own).
  static void paint(Canvas canvas, int id, {Color? main, Color? ink}) {
    final PebbleStamp s = all[id];
    s.paint(canvas, StampInk(main ?? Color(s.main), ink ?? Color(s.ink)));
  }
}
