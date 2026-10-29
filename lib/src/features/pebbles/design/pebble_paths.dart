import 'dart:math' as math;
import 'dart:ui';

/// Small path builders shared by the stamps and the patterns. Everything
/// is drawn in a box around (0, 0), y down.
abstract final class PebblePaths {
  /// A heart of width about 2·[r] centred on ([x], [y]).
  static Path heart(double x, double y, double r) {
    final Path p = Path()
      ..moveTo(x, y + r * 0.95)
      ..cubicTo(
        x - r * 1.35,
        y + r * 0.05,
        x - r * 0.95,
        y - r * 1.05,
        x,
        y - r * 0.45,
      )
      ..cubicTo(
        x + r * 0.95,
        y - r * 1.05,
        x + r * 1.35,
        y + r * 0.05,
        x,
        y + r * 0.95,
      )
      ..close();
    return p;
  }

  /// A star with [points] points, outer radius [r] and inner [inner]·r.
  static Path star(
    double x,
    double y,
    double r, {
    int points = 5,
    double inner = 0.45,
    double turn = 0,
  }) {
    final Path p = Path();
    for (int i = 0; i < points * 2; i++) {
      final double a = -math.pi / 2 + turn + i * math.pi / points;
      final double rr = i.isEven ? r : r * inner;
      final double px = x + math.cos(a) * rr;
      final double py = y + math.sin(a) * rr;
      if (i == 0) {
        p.moveTo(px, py);
      } else {
        p.lineTo(px, py);
      }
    }
    return p..close();
  }

  /// A regular polygon with [sides] sides.
  static Path polygon(
    double x,
    double y,
    double r,
    int sides, {
    double turn = 0,
  }) {
    final Path p = Path();
    for (int i = 0; i < sides; i++) {
      final double a = -math.pi / 2 + turn + i * 2 * math.pi / sides;
      final double px = x + math.cos(a) * r;
      final double py = y + math.sin(a) * r;
      if (i == 0) {
        p.moveTo(px, py);
      } else {
        p.lineTo(px, py);
      }
    }
    return p..close();
  }

  /// A closed path through [xy] (x0, y0, x1, y1, …).
  static Path poly(List<double> xy, {bool close = true}) {
    final Path p = Path()..moveTo(xy[0], xy[1]);
    for (int i = 2; i + 1 < xy.length; i += 2) {
      p.lineTo(xy[i], xy[i + 1]);
    }
    if (close) {
      p.close();
    }
    return p;
  }

  /// A smooth closed blob through [xy] (Catmull-Rom).
  static Path blob(List<double> xy) {
    final int n = xy.length ~/ 2;
    final Path p = Path()..moveTo(xy[0], xy[1]);
    for (int i = 0; i < n; i++) {
      final int i0 = (i - 1 + n) % n;
      final int i2 = (i + 1) % n;
      final int i3 = (i + 2) % n;
      final double x1 = xy[i * 2], y1 = xy[i * 2 + 1];
      final double x2 = xy[i2 * 2], y2 = xy[i2 * 2 + 1];
      p.cubicTo(
        x1 + (x2 - xy[i0 * 2]) / 6,
        y1 + (y2 - xy[i0 * 2 + 1]) / 6,
        x2 - (xy[i3 * 2] - x1) / 6,
        y2 - (xy[i3 * 2 + 1] - y1) / 6,
        x2,
        y2,
      );
    }
    return p..close();
  }

  /// A petal from ([x], [y]) outwards at [angle], [length] long.
  static Path petal(
    double x,
    double y,
    double angle,
    double length,
    double width,
  ) {
    final double cs = math.cos(angle);
    final double sn = math.sin(angle);
    final double tx = x + cs * length;
    final double ty = y + sn * length;
    final double mx = x + cs * length * 0.5;
    final double my = y + sn * length * 0.5;
    final double nx = -sn * width;
    final double ny = cs * width;
    return Path()
      ..moveTo(x, y)
      ..quadraticBezierTo(mx + nx, my + ny, tx, ty)
      ..quadraticBezierTo(mx - nx, my - ny, x, y)
      ..close();
  }

  /// A circle.
  static Path circle(double x, double y, double r) =>
      Path()..addOval(Rect.fromCircle(center: Offset(x, y), radius: r));

  /// An ellipse.
  static Path oval(double x, double y, double rx, double ry) => Path()
    ..addOval(
      Rect.fromCenter(center: Offset(x, y), width: rx * 2, height: ry * 2),
    );
}

/// A small deterministic random generator (splitmix32), so the same seed
/// gives the same stone on every device.
final class PebbleRandom {
  PebbleRandom(int seed) : _state = seed & 0xFFFFFFFF;

  int _state;

  int nextInt32() {
    _state = (_state + 0x9E3779B9) & 0xFFFFFFFF;
    int z = _state;
    z = ((z ^ (z >> 16)) * 0x85EBCA6B) & 0xFFFFFFFF;
    z = ((z ^ (z >> 13)) * 0xC2B2AE35) & 0xFFFFFFFF;
    return (z ^ (z >> 16)) & 0xFFFFFFFF;
  }

  /// 0 ≤ x < 1.
  double next() => nextInt32() / 4294967296.0;

  /// [lo] ≤ x < [hi].
  double range(double lo, double hi) => lo + (hi - lo) * next();

  /// 0 ≤ n < [max].
  int nextInt(int max) => nextInt32() % max;

  bool chance(double p) => next() < p;

  T pick<T>(List<T> items) => items[nextInt(items.length)];
}
