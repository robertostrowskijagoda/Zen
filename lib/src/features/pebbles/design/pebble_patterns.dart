import 'dart:math' as math;
import 'dart:ui';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pebbles/design/pebble_paths.dart';

/// Patterns laid over a whole face. The index is stored in designs: add new
/// ones at the end only.
enum PebblePattern {
  dots,
  stripes,
  checks,
  mandala,
  waves,
  zigzag,
  scales,
  confetti,
  grid,
  spiral,
  hearts,
  stars,
  diamonds,
  rings,
  rays,
  crosshatch,
  triangles,
  flowers,
  bubbles,
  leaves;

  static PebblePattern byId(int id) =>
      id >= 0 && id < values.length ? values[id] : dots;

  String get label => switch (this) {
    dots => t('Groszki'),
    stripes => t('Paski'),
    checks => t('Kratka'),
    mandala => t('Mandala'),
    waves => t('Fale'),
    zigzag => t('Zygzak'),
    scales => t('Łuski'),
    confetti => t('Konfetti'),
    grid => t('Siatka'),
    spiral => t('Spirala'),
    hearts => t('Serduszka'),
    stars => t('Gwiazdki'),
    diamonds => t('Romby'),
    rings => t('Kręgi'),
    rays => t('Promienie'),
    crosshatch => t('Kreskowanie'),
    triangles => t('Trójkąty'),
    flowers => t('Kwiatuszki'),
    bubbles => t('Bąbelki'),
    leaves => t('Listki'),
  };

  /// Paints the pattern around (0, 0) so it covers at least the square
  /// ±[extent]. [cell] is the size of one repeat; [colour2] (may be null)
  /// is the second colour of the patterns that have one.
  void paint(
    Canvas canvas, {
    required double extent,
    required Color colour,
    required Color? colour2,
    required double cell,
    required double angle,
    required int seed,
  }) {
    final double c = cell.clamp(0.04, 2.0);
    final double r = extent * 1.5;
    final int n = (r / c).ceil() + 1;
    final Paint fill = Paint()
      ..color = colour
      ..isAntiAlias = true;
    final Paint fill2 = Paint()
      ..color = colour2 ?? colour
      ..isAntiAlias = true;
    Paint line(double w, [Color? col]) => Paint()
      ..color = col ?? colour
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas
      ..save()
      ..rotate(angle);
    switch (this) {
      case dots:
        for (int j = -n; j <= n; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            canvas.drawCircle(Offset(x, j * c * 0.87), c * 0.22, fill);
          }
        }
      case stripes:
        for (int i = -n; i <= n; i++) {
          canvas.drawRect(
            Rect.fromLTRB(i * c, -r, i * c + c / 2, r),
            i.isEven || colour2 == null ? fill : fill2,
          );
        }
      case checks:
        for (int j = -n; j <= n; j++) {
          for (int i = -n; i <= n; i++) {
            if ((i + j).isEven) {
              canvas.drawRect(Rect.fromLTWH(i * c, j * c, c, c), fill);
            } else if (colour2 != null) {
              canvas.drawRect(Rect.fromLTWH(i * c, j * c, c, c), fill2);
            }
          }
        }
      case mandala:
        _mandala(canvas, c, extent, fill, fill2, line);
      case waves:
        final Paint p = line(c * 0.18);
        final Paint p2 = line(c * 0.18, colour2 ?? colour);
        for (int j = -n; j <= n; j++) {
          final Path path = Path();
          for (int k = 0; k <= n * 8; k++) {
            final double x = -r + k * c / 4;
            final double y = j * c * 0.6 + math.sin(x / c * math.pi) * c * 0.2;
            if (k == 0) {
              path.moveTo(x, y);
            } else {
              path.lineTo(x, y);
            }
          }
          canvas.drawPath(path, j.isEven ? p : p2);
        }
      case zigzag:
        final Paint p = line(c * 0.16);
        final Paint p2 = line(c * 0.16, colour2 ?? colour);
        for (int j = -n; j <= n; j++) {
          final Path path = Path()..moveTo(-r, j * c * 0.6);
          for (int k = 0; k <= n * 4; k++) {
            path.lineTo(
              -r + k * c / 2,
              j * c * 0.6 + (k.isOdd ? -c * 0.2 : c * 0.2),
            );
          }
          canvas.drawPath(path, j.isEven ? p : p2);
        }
      case scales:
        final Paint p = line(c * 0.08);
        for (int j = -n; j <= n * 2; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            final double y = -r + j * c * 0.35;
            if (colour2 != null && (i + j) % 3 == 0) {
              canvas.drawArc(
                Rect.fromCircle(center: Offset(x, y), radius: c / 2),
                0,
                math.pi,
                true,
                fill2,
              );
            }
            canvas.drawArc(
              Rect.fromCircle(center: Offset(x, y), radius: c / 2),
              0,
              math.pi,
              false,
              p,
            );
          }
        }
      case confetti:
        final PebbleRandom rnd = PebbleRandom(seed);
        final int count = (((2 * r) / c) * ((2 * r) / c) * 0.7).round().clamp(
          4,
          900,
        );
        for (int k = 0; k < count; k++) {
          final double x = rnd.range(-r, r);
          final double y = rnd.range(-r, r);
          final Paint p = rnd.chance(0.5) ? fill : fill2;
          canvas
            ..save()
            ..translate(x, y)
            ..rotate(rnd.range(0, math.pi));
          if (rnd.chance(0.5)) {
            canvas.drawRect(
              Rect.fromCenter(
                center: Offset.zero,
                width: c * 0.32,
                height: c * 0.14,
              ),
              p,
            );
          } else {
            canvas.drawCircle(Offset.zero, c * 0.09, p);
          }
          canvas.restore();
        }
      case grid:
        final Paint p = line(c * 0.07);
        for (int i = -n; i <= n; i++) {
          canvas
            ..drawLine(Offset(i * c, -r), Offset(i * c, r), p)
            ..drawLine(Offset(-r, i * c), Offset(r, i * c), p);
        }
      case spiral:
        final Path path = Path()..moveTo(0, 0);
        final double turns = extent * 1.5 / c;
        for (int k = 1; k <= (turns * 60).ceil(); k++) {
          final double a = k / 60 * 2 * math.pi;
          final double rr = c * a / (2 * math.pi);
          path.lineTo(math.cos(a) * rr, math.sin(a) * rr);
        }
        canvas.drawPath(path, line(c * 0.22));
      case hearts:
        for (int j = -n; j <= n; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            canvas.drawPath(
              PebblePaths.heart(x, j * c * 0.9, c * 0.28),
              (i + j).isEven ? fill : fill2,
            );
          }
        }
      case stars:
        for (int j = -n; j <= n; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            canvas.drawPath(
              PebblePaths.star(x, j * c * 0.9, c * 0.3),
              (i + j).isEven ? fill : fill2,
            );
          }
        }
      case diamonds:
        for (int j = -n; j <= n * 2; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            final double y = j * c * 0.5;
            if ((i + j).isEven || colour2 != null) {
              canvas.drawPath(
                PebblePaths.poly(<double>[
                  x,
                  y - c * 0.48,
                  x + c * 0.3,
                  y,
                  x,
                  y + c * 0.48,
                  x - c * 0.3,
                  y,
                ]),
                (i + j).isEven ? fill : fill2,
              );
            }
          }
        }
      case rings:
        for (int k = 1; k <= n; k++) {
          canvas.drawCircle(
            Offset.zero,
            k * c * 0.6,
            line(c * 0.14, k.isEven ? colour : (colour2 ?? colour)),
          );
        }
      case rays:
        const int count = 24;
        for (int k = 0; k < count; k += 2) {
          final double a0 = k * 2 * math.pi / count;
          final double a1 = (k + 1) * 2 * math.pi / count;
          canvas.drawPath(
            PebblePaths.poly(<double>[
              0,
              0,
              math.cos(a0) * r * 1.5,
              math.sin(a0) * r * 1.5,
              math.cos(a1) * r * 1.5,
              math.sin(a1) * r * 1.5,
            ]),
            (k ~/ 2).isEven ? fill : fill2,
          );
        }
      case crosshatch:
        final Paint p = line(c * 0.06);
        for (int i = -n * 2; i <= n * 2; i++) {
          canvas
            ..drawLine(Offset(i * c / 2 - r, -r), Offset(i * c / 2 + r, r), p)
            ..drawLine(Offset(i * c / 2 + r, -r), Offset(i * c / 2 - r, r), p);
        }
      case triangles:
        for (int j = -n; j <= n; j++) {
          for (int i = -n * 2; i <= n * 2; i++) {
            final double x = i * c / 2;
            final double y = j * c * 0.87;
            final bool upward = (i + j).isEven;
            final List<double> xy = upward
                ? <double>[
                    x - c / 2,
                    y + c * 0.435,
                    x + c / 2,
                    y + c * 0.435,
                    x,
                    y - c * 0.435,
                  ]
                : <double>[
                    x - c / 2,
                    y - c * 0.435,
                    x + c / 2,
                    y - c * 0.435,
                    x,
                    y + c * 0.435,
                  ];
            if (upward) {
              canvas.drawPath(PebblePaths.poly(xy), fill);
            } else if (colour2 != null) {
              canvas.drawPath(PebblePaths.poly(xy), fill2);
            }
          }
        }
      case flowers:
        for (int j = -n; j <= n; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            final double y = j * c * 0.9;
            for (int k = 0; k < 5; k++) {
              final double a = k * 2 * math.pi / 5;
              canvas.drawCircle(
                Offset(x + math.cos(a) * c * 0.16, y + math.sin(a) * c * 0.16),
                c * 0.11,
                fill,
              );
            }
            canvas.drawCircle(Offset(x, y), c * 0.08, fill2);
          }
        }
      case bubbles:
        final PebbleRandom rnd = PebbleRandom(seed ^ 0x5bd1e995);
        final int count = (((2 * r) / c) * ((2 * r) / c) * 0.45).round().clamp(
          4,
          600,
        );
        for (int k = 0; k < count; k++) {
          final double rr = c * rnd.range(0.08, 0.32);
          canvas.drawCircle(
            Offset(rnd.range(-r, r), rnd.range(-r, r)),
            rr,
            line(rr * 0.35, rnd.chance(0.5) ? colour : (colour2 ?? colour)),
          );
        }
      case leaves:
        for (int j = -n; j <= n; j++) {
          for (int i = -n; i <= n; i++) {
            final double x = i * c + (j.isOdd ? c / 2 : 0);
            final double y = j * c * 0.8;
            final double a = (i + j).isEven ? -0.6 : -2.5;
            canvas.drawPath(
              PebblePaths.petal(x, y, a, c * 0.55, c * 0.16),
              (i + j).isEven ? fill : fill2,
            );
          }
        }
    }
    canvas.restore();
  }

  static void _mandala(
    Canvas canvas,
    double c,
    double extent,
    Paint fill,
    Paint fill2,
    Paint Function(double, [Color?]) line,
  ) {
    canvas.drawCircle(Offset.zero, c * 0.35, fill);
    canvas.drawCircle(Offset.zero, c * 0.18, fill2);
    final int rings = (extent * 1.45 / (c * 0.9)).ceil();
    for (int k = 1; k <= rings; k++) {
      final double rr = k * c * 0.9;
      final int petals = 6 + 4 * k;
      final Paint p = k.isOdd ? fill : fill2;
      for (int i = 0; i < petals; i++) {
        final double a =
            i * 2 * math.pi / petals + (k.isEven ? math.pi / petals : 0);
        if (k % 3 == 0) {
          canvas.drawCircle(
            Offset(math.cos(a) * rr, math.sin(a) * rr),
            c * 0.13,
            p,
          );
        } else {
          canvas.drawPath(
            PebblePaths.petal(
              math.cos(a) * (rr - c * 0.42),
              math.sin(a) * (rr - c * 0.42),
              a,
              c * 0.8,
              c * (0.9 * math.pi / petals).clamp(0.08, 0.3),
            ),
            p,
          );
        }
      }
      canvas.drawCircle(
        Offset.zero,
        rr + c * 0.42,
        line(c * 0.05, (k.isOdd ? fill2 : fill).color),
      );
    }
  }
}
