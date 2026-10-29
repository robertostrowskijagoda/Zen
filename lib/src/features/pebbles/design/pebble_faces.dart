import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The six faces a pebble is painted on. The stone's surface is a cube
/// blown up into a ball (a "cube sphere"): every point belongs to the face
/// of the cube its direction points through, and each face has its own
/// square of the texture with coordinates (s, t) in -1…1. The ids are part
/// of the design format: never reorder them.
enum PebbleFace {
  top,
  bottom,
  front,
  back,
  left,
  right;

  static const int count = 6;
}

/// The frame of each face: its centre (the outward axis) and the axes of s
/// (right) and t (up) as the face is seen from outside. right × up = centre,
/// so triangles laid out counter-clockwise in (s, t) face outwards.
///
/// Up on the top face is the back of the stone, so a stone tilted towards
/// the viewer shows its top the right way up; up on the bottom face is the
/// front.
const List<List<double>> _centre = <List<double>>[
  <double>[0, 1, 0],
  <double>[0, -1, 0],
  <double>[0, 0, 1],
  <double>[0, 0, -1],
  <double>[-1, 0, 0],
  <double>[1, 0, 0],
];
const List<List<double>> _right = <List<double>>[
  <double>[1, 0, 0],
  <double>[1, 0, 0],
  <double>[1, 0, 0],
  <double>[-1, 0, 0],
  <double>[0, 0, 1],
  <double>[0, 0, -1],
];
const List<List<double>> _up = <List<double>>[
  <double>[0, 0, -1],
  <double>[0, 0, 1],
  <double>[0, 1, 0],
  <double>[0, 1, 0],
  <double>[0, 1, 0],
  <double>[0, 1, 0],
];

/// A 2D affine map, laid out like a canvas matrix:
/// x' = a·x + c·y + e, y' = b·x + d·y + f.
@immutable
final class Affine2 {
  const Affine2(this.a, this.b, this.c, this.d, this.e, this.f);

  /// The map that sends (0, 0), (1, 0) and (0, 1) to [o], [x] and [y].
  factory Affine2.fromPoints(
    (double, double) o,
    (double, double) x,
    (double, double) y,
  ) => Affine2(x.$1 - o.$1, x.$2 - o.$2, y.$1 - o.$1, y.$2 - o.$2, o.$1, o.$2);

  factory Affine2.translation(double x, double y) => Affine2(1, 0, 0, 1, x, y);

  factory Affine2.scaling(double x, [double? y]) =>
      Affine2(x, 0, 0, y ?? x, 0, 0);

  factory Affine2.rotation(double radians) {
    final double cs = math.cos(radians);
    final double sn = math.sin(radians);
    return Affine2(cs, sn, -sn, cs, 0, 0);
  }

  static const Affine2 identity = Affine2(1, 0, 0, 1, 0, 0);

  final double a;
  final double b;
  final double c;
  final double d;
  final double e;
  final double f;

  double x(double px, double py) => a * px + c * py + e;
  double y(double px, double py) => b * px + d * py + f;

  (double, double) apply(double px, double py) => (x(px, py), y(px, py));

  /// This map after [inner]: p ↦ this(inner(p)).
  Affine2 after(Affine2 inner) => Affine2(
    a * inner.a + c * inner.b,
    b * inner.a + d * inner.b,
    a * inner.c + c * inner.d,
    b * inner.c + d * inner.d,
    a * inner.e + c * inner.f + e,
    b * inner.e + d * inner.f + f,
  );

  double get determinant => a * d - b * c;

  Affine2 get inverse {
    final double det = determinant;
    final double ia = d / det;
    final double ib = -b / det;
    final double ic = -c / det;
    final double id = a / det;
    return Affine2(ia, ib, ic, id, -(ia * e + ic * f), -(ib * e + id * f));
  }

  /// The column-major 4×4 matrix Canvas.transform and shaders take.
  Float64List toMatrix4() => Float64List.fromList(<double>[
    a, b, 0, 0, //
    c, d, 0, 0,
    0, 0, 1, 0,
    e, f, 0, 1,
  ]);

  /// Flips t into a canvas's y (down): the drawing space of a face is
  /// (X, Y) = (s, -t).
  static const Affine2 flip = Affine2(1, 0, 0, -1, 0, 0);
}

/// Geometry of the cube sphere: face frames, points, and the maps between
/// neighbouring faces that keep paint continuous across their seams.
abstract final class PebbleFaces {
  static List<double> centre(int face) => _centre[face];
  static List<double> right(int face) => _right[face];
  static List<double> up(int face) => _up[face];

  static int opposite(int face) => face ^ 1;

  /// The four faces that share an edge with [face].
  static List<int> neighbours(int face) => _neighbours[face];

  static final List<List<int>> _neighbours = <List<int>>[
    for (int f = 0; f < PebbleFace.count; f++)
      <int>[
        for (int g = 0; g < PebbleFace.count; g++)
          if (g != f && g != opposite(f)) g,
      ],
  ];

  /// The unit direction through (s, t) of [face]. The coordinates are
  /// equal-angle (s = 1 is 45° from the centre), which spreads texels more
  /// evenly than the plain cube; any |s|, |t| < 2 is valid, so a point just
  /// past an edge continues onto the neighbour.
  static void direction(int face, double s, double t, Float64List out) {
    final List<double> c = _centre[face];
    final List<double> r = _right[face];
    final List<double> u = _up[face];
    final double gs = math.tan(s * math.pi / 4);
    final double gt = math.tan(t * math.pi / 4);
    final double x = c[0] + gs * r[0] + gt * u[0];
    final double y = c[1] + gs * r[1] + gt * u[1];
    final double z = c[2] + gs * r[2] + gt * u[2];
    final double len = math.sqrt(x * x + y * y + z * z);
    out[0] = x / len;
    out[1] = y / len;
    out[2] = z / len;
  }

  /// The face a direction points through and its (s, t) there.
  static (int, double, double) locate(double x, double y, double z) {
    final double ax = x.abs();
    final double ay = y.abs();
    final double az = z.abs();
    final int face;
    if (ay >= ax && ay >= az) {
      face = y >= 0 ? 0 : 1;
    } else if (az >= ax) {
      face = z >= 0 ? 2 : 3;
    } else {
      face = x >= 0 ? 5 : 4;
    }
    final List<double> c = _centre[face];
    final List<double> r = _right[face];
    final List<double> u = _up[face];
    final double depth = x * c[0] + y * c[1] + z * c[2];
    final double gs = (x * r[0] + y * r[1] + z * r[2]) / depth;
    final double gt = (x * u[0] + y * u[1] + z * u[2]) / depth;
    return (face, math.atan(gs) * 4 / math.pi, math.atan(gt) * 4 / math.pi);
  }

  /// Maps (s, t) of [from], continued past their shared edge, into (s, t)
  /// of its neighbour [to]: the cube's surface folded flat across the edge.
  /// Paint drawn on one face is drawn through this onto its neighbours, so
  /// a stroke crossing a seam carries on without a break.
  static Affine2 unfold(int from, int to) => _unfold[from * 6 + to]!;

  static final List<Affine2?> _unfold = <Affine2?>[
    for (int f = 0; f < 6; f++)
      for (int g = 0; g < 6; g++)
        if (g == f)
          Affine2.identity
        else if (g == opposite(f))
          null
        else
          _computeUnfold(f, g),
  ];

  static Affine2 _computeUnfold(int from, int to) {
    final List<double> cf = _centre[from];
    final List<double> rf = _right[from];
    final List<double> uf = _up[from];
    final List<double> a = _centre[to];
    final List<double> rt = _right[to];
    final List<double> ut = _up[to];
    (double, double) map(double s, double t) {
      final List<double> p = <double>[
        for (int i = 0; i < 3; i++) cf[i] + s * rf[i] + t * uf[i],
      ];
      final double k = p[0] * a[0] + p[1] * a[1] + p[2] * a[2];
      final List<double> q = <double>[
        for (int i = 0; i < 3; i++) p[i] - k * a[i] + a[i] - (k - 1) * cf[i],
      ];
      return (
        q[0] * rt[0] + q[1] * rt[1] + q[2] * rt[2],
        q[0] * ut[0] + q[1] * ut[1] + q[2] * ut[2],
      );
    }

    return Affine2.fromPoints(map(0, 0), map(1, 0), map(0, 1));
  }

  /// The mirror image across the stone's middle (x ↦ -x): the face [face]
  /// lands on and the map of its (s, t) there. Left and right swap; the
  /// other faces map onto themselves, flipped.
  static (int, Affine2) mirror(int face) => _mirror[face];

  static final List<(int, Affine2)> _mirror = <(int, Affine2)>[
    for (int f = 0; f < 6; f++) _computeMirror(f),
  ];

  static (int, Affine2) _computeMirror(int face) {
    List<double> m(List<double> v) => <double>[-v[0], v[1], v[2]];
    final List<double> c = m(_centre[face]);
    final List<double> r = m(_right[face]);
    final List<double> u = m(_up[face]);
    final (int g, _, _) = locate(c[0], c[1], c[2]);
    final List<double> rg = _right[g];
    final List<double> ug = _up[g];
    double dot(List<double> p, List<double> q) =>
        p[0] * q[0] + p[1] * q[1] + p[2] * q[2];
    (double, double) map(double s, double t) {
      final List<double> p = <double>[
        for (int i = 0; i < 3; i++) c[i] + s * r[i] + t * u[i],
      ];
      return (dot(p, rg), dot(p, ug));
    }

    return (g, Affine2.fromPoints(map(0, 0), map(1, 0), map(0, 1)));
  }
}
