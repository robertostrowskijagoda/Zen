import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_paths.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';

/// What decides a stone's mesh.
@immutable
final class PebbleShapeKey {
  const PebbleShapeKey({
    required this.shape,
    required this.seed,
    this.width = 0,
    this.height = 0,
    this.length = 0,
  });

  factory PebbleShapeKey.of(PebbleDesign d) => PebbleShapeKey(
    shape: d.shape,
    seed: d.seed,
    width: d.width,
    height: d.height,
    length: d.length,
  );

  final int shape;
  final int seed;
  final int width;
  final int height;
  final int length;

  @override
  bool operator ==(Object other) =>
      other is PebbleShapeKey &&
      other.shape == shape &&
      other.seed == seed &&
      other.width == width &&
      other.height == height &&
      other.length == length;

  @override
  int get hashCode => Object.hash(shape, seed, width, height, length);
}

/// A stone's triangle mesh: a cube sphere with [grid]×[grid] cells per
/// face, pushed into the stone's shape. Each face has its own vertices
/// (the seams repeat positions with the neighbour's (s, t)), so every
/// triangle maps into one face's square of the texture.
final class PebbleMesh {
  PebbleMesh._(this.positions, this.normals, this.faceCoords, this.indices);

  /// Cells along a face's edge: 6 × 16 × 16 × 2 = 3072 triangles.
  static const int grid = 16;
  static const int vertsPerFace = (grid + 1) * (grid + 1);
  static const int trisPerFace = grid * grid * 2;

  /// x, y, z per vertex (the stone fits the unit ball, y up).
  final Float32List positions;

  /// Unit outward normals.
  final Float32List normals;

  /// The vertex's (s, t) on its face.
  final Float32List faceCoords;

  final Uint16List indices;

  int get vertexCount => positions.length ~/ 3;
  int get triangleCount => indices.length ~/ 3;

  static int faceOfTriangle(int tri) => tri ~/ trisPerFace;
  static int faceOfVertex(int v) => v ~/ vertsPerFace;

  static final LinkedHashMap<PebbleShapeKey, PebbleMesh> _cache =
      LinkedHashMap<PebbleShapeKey, PebbleMesh>();

  /// The mesh of [key], built once and kept for the last few dozen stones.
  static PebbleMesh of(PebbleShapeKey key) {
    final PebbleMesh? hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit;
      return hit;
    }
    final PebbleMesh mesh = build(key);
    _cache[key] = mesh;
    while (_cache.length > 40) {
      _cache.remove(_cache.keys.first);
    }
    return mesh;
  }

  static PebbleMesh build(PebbleShapeKey key) {
    final _Shape shape = _Shape(key);
    const int n = grid;
    final int vCount = 6 * vertsPerFace;
    final Float32List pos = Float32List(vCount * 3);
    final Float32List nor = Float32List(vCount * 3);
    final Float32List st = Float32List(vCount * 2);
    final Float64List p = Float64List(3);
    final Float64List a = Float64List(3);
    final Float64List b = Float64List(3);
    final Float64List c = Float64List(3);
    final Float64List d = Float64List(3);
    const double eps = 1e-3;
    for (int f = 0; f < 6; f++) {
      for (int j = 0; j <= n; j++) {
        for (int i = 0; i <= n; i++) {
          final int v = f * vertsPerFace + j * (n + 1) + i;
          final double s = -1 + 2 * i / n;
          final double t = -1 + 2 * j / n;
          shape.at(f, s, t, p);
          pos[v * 3] = p[0];
          pos[v * 3 + 1] = p[1];
          pos[v * 3 + 2] = p[2];
          st[v * 2] = s;
          st[v * 2 + 1] = t;
          // The normal from the surface's own tangents (the same function
          // on both sides of a seam, so seams shade without a crease);
          // ds × dt points outwards because right × up is the face's axis.
          shape.at(f, s + eps, t, a);
          shape.at(f, s - eps, t, b);
          shape.at(f, s, t + eps, c);
          shape.at(f, s, t - eps, d);
          final double ux = a[0] - b[0], uy = a[1] - b[1], uz = a[2] - b[2];
          final double vx = c[0] - d[0], vy = c[1] - d[1], vz = c[2] - d[2];
          double nx = uy * vz - uz * vy;
          double ny = uz * vx - ux * vz;
          double nz = ux * vy - uy * vx;
          double len = math.sqrt(nx * nx + ny * ny + nz * nz);
          if (len < 1e-12 || len.isNaN) {
            nx = p[0];
            ny = p[1];
            nz = p[2];
            len = math.sqrt(nx * nx + ny * ny + nz * nz);
          }
          nor[v * 3] = nx / len;
          nor[v * 3 + 1] = ny / len;
          nor[v * 3 + 2] = nz / len;
        }
      }
    }
    // Centre the stone and fit it into the unit ball.
    double minX = double.infinity,
        minY = double.infinity,
        minZ = double.infinity;
    double maxX = -double.infinity,
        maxY = -double.infinity,
        maxZ = -double.infinity;
    for (int v = 0; v < vCount; v++) {
      minX = math.min(minX, pos[v * 3]);
      maxX = math.max(maxX, pos[v * 3]);
      minY = math.min(minY, pos[v * 3 + 1]);
      maxY = math.max(maxY, pos[v * 3 + 1]);
      minZ = math.min(minZ, pos[v * 3 + 2]);
      maxZ = math.max(maxZ, pos[v * 3 + 2]);
    }
    final double cx = (minX + maxX) / 2;
    final double cy = (minY + maxY) / 2;
    final double cz = (minZ + maxZ) / 2;
    double far = 0;
    for (int v = 0; v < vCount; v++) {
      final double x = pos[v * 3] - cx;
      final double y = pos[v * 3 + 1] - cy;
      final double z = pos[v * 3 + 2] - cz;
      far = math.max(far, x * x + y * y + z * z);
    }
    final double scale = 1 / math.sqrt(far);
    for (int v = 0; v < vCount; v++) {
      pos[v * 3] = (pos[v * 3] - cx) * scale;
      pos[v * 3 + 1] = (pos[v * 3 + 1] - cy) * scale;
      pos[v * 3 + 2] = (pos[v * 3 + 2] - cz) * scale;
    }
    final Uint16List idx = Uint16List(6 * trisPerFace * 3);
    int k = 0;
    for (int f = 0; f < 6; f++) {
      final int base = f * vertsPerFace;
      for (int j = 0; j < n; j++) {
        for (int i = 0; i < n; i++) {
          final int v00 = base + j * (n + 1) + i;
          final int v10 = v00 + 1;
          final int v01 = v00 + n + 1;
          final int v11 = v01 + 1;
          // Counter-clockwise in (s, t), which faces outwards.
          idx[k++] = v00;
          idx[k++] = v10;
          idx[k++] = v11;
          idx[k++] = v00;
          idx[k++] = v11;
          idx[k++] = v01;
        }
      }
    }
    return PebbleMesh._(pos, nor, st, idx);
  }
}

/// The stone's surface as a function of the direction from its middle.
final class _Shape {
  _Shape(PebbleShapeKey key)
    : p = PebbleShapePreset.byId(key.shape).params,
      _seed = key.seed {
    final PebbleRandom r = PebbleRandom(key.seed ^ (key.shape * 0x27D4EB2D));
    _ox = r.range(0, 100);
    _oy = r.range(0, 100);
    _oz = r.range(0, 100);
    _sx = (1 + r.range(-0.06, 0.06)) * (1 + key.width / 200);
    _sy = (1 + r.range(-0.06, 0.06)) * (1 + key.height / 200);
    _sz = (1 + r.range(-0.06, 0.06)) * (1 + key.length / 200);
    _phase = r.range(0, math.pi * 2);
    final double da = r.range(0, math.pi * 2);
    final double dr = r.range(0.1, 0.35);
    final double dx = math.cos(da) * dr;
    final double dz = math.sin(da) * dr;
    final double dl = math.sqrt(dx * dx + 1 + dz * dz);
    _dentX = dx / dl;
    _dentY = 1 / dl;
    _dentZ = dz / dl;
  }

  final PebbleShapeParams p;
  final int _seed;
  late final double _ox, _oy, _oz, _sx, _sy, _sz, _phase;
  late final double _dentX, _dentY, _dentZ;
  final Float64List _d = Float64List(3);

  void at(int face, double s, double t, Float64List out) {
    PebbleFaces.direction(face, s, t, _d);
    final double dx = _d[0], dy = _d[1], dz = _d[2];
    // A superellipsoid with unit radii along the direction.
    final double e1 = p.e1, e2 = p.e2;
    final double h =
        math.pow(dx.abs(), 2 / e2).toDouble() +
        math.pow(dz.abs(), 2 / e2).toDouble();
    final double f =
        math.pow(h, e2 / e1).toDouble() + math.pow(dy.abs(), 2 / e1).toDouble();
    double r = math.pow(f, -e1 / 2).toDouble();
    if (p.noise > 0) {
      final double fr = p.noiseFreq;
      final double nz =
          _noise(dx * fr + _ox, dy * fr + _oy, dz * fr + _oz) +
          0.5 * _noise(dx * fr * 2 + _oz, dy * fr * 2 + _ox, dz * fr * 2 + _oy);
      r *= 1 + p.noise * nz / 1.5;
    }
    if (p.rough > 0) {
      final double fr = p.noiseFreq * 4.5;
      r *= 1 + p.rough * _noise(dx * fr + _oy, dy * fr + _oz, dz * fr + _ox);
    }
    if (p.dent > 0) {
      final double dot = dx * _dentX + dy * _dentY + dz * _dentZ;
      r *= 1 - p.dent * math.exp(-(1 - dot) / 0.08);
    }
    double x = r * dx, y = r * dy, z = r * dz;
    if (p.lobes > 0 && p.lobeCount > 0) {
      final double phi = math.atan2(x, z);
      final double k = 1 + p.lobes * math.cos(p.lobeCount * phi + _phase);
      x *= k;
      z *= k;
    }
    x *= p.ax * _sx;
    y *= p.ay * _sy;
    z *= p.az * _sz;
    final double yn = y / (p.ay * _sy);
    final double xn = x / (p.ax * _sx);
    if (p.taper != 0) {
      final double k = 1 - p.taper * yn;
      x *= k;
      z *= k;
    }
    if (p.egg != 0) {
      final double k = 1 - p.egg * xn;
      y *= k;
      z *= k;
    }
    if (p.heart > 0) {
      final double phi = math.atan2(x, z);
      final double dip = math.pi - phi.abs();
      final double shape =
          0.86 +
          0.3 * math.pow(math.sin(phi).abs(), 0.8).toDouble() -
          0.34 * math.exp(-(dip * dip) / 0.12) +
          0.22 * math.exp(-(phi * phi) / 0.18);
      final double k = 1 + p.heart * (shape - 1);
      x *= k;
      z *= k;
    }
    if (p.waist > 0) {
      final double k = 1 - p.waist * math.exp(-(xn * xn) / 0.12);
      z *= k;
      y *= 1 - p.waist * 0.4 * math.exp(-(xn * xn) / 0.12);
    }
    if (p.bend != 0) {
      z += p.bend * (xn * xn - 0.35) * p.az;
    }
    if (p.flatBottom > 0 && y < 0) {
      y *= 1 - p.flatBottom;
    }
    out[0] = x;
    out[1] = y;
    out[2] = z;
  }

  /// Smooth 3D value noise in -1…1.
  double _noise(double x, double y, double z) {
    final int xi = x.floor(), yi = y.floor(), zi = z.floor();
    final double xf = x - xi, yf = y - yi, zf = z - zi;
    final double u = _fade(xf), v = _fade(yf), w = _fade(zf);
    double lerp(double a, double b, double k) => a + (b - a) * k;
    final double x00 = lerp(_hash(xi, yi, zi), _hash(xi + 1, yi, zi), u);
    final double x10 = lerp(
      _hash(xi, yi + 1, zi),
      _hash(xi + 1, yi + 1, zi),
      u,
    );
    final double x01 = lerp(
      _hash(xi, yi, zi + 1),
      _hash(xi + 1, yi, zi + 1),
      u,
    );
    final double x11 = lerp(
      _hash(xi, yi + 1, zi + 1),
      _hash(xi + 1, yi + 1, zi + 1),
      u,
    );
    return lerp(lerp(x00, x10, v), lerp(x01, x11, v), w);
  }

  static double _fade(double t) => t * t * t * (t * (t * 6 - 15) + 10);

  double _hash(int x, int y, int z) {
    int h =
        (x * 374761393 + y * 668265263 + z * 2147483647 + _seed * 1274126177) &
        0xFFFFFFFF;
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF;
    h = h ^ (h >> 16);
    return (h & 0xFFFF) / 32767.5 - 1;
  }
}
