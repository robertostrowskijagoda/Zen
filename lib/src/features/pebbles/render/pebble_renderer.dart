import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/render/pebble_mesh.dart';
import 'package:zen/src/features/pebbles/render/pebble_texture.dart';

/// A rotation as a unit quaternion.
@immutable
final class PebbleRotation {
  const PebbleRotation(this.w, this.x, this.y, this.z);

  factory PebbleRotation.axisAngle(double ax, double ay, double az, double a) {
    final double len = math.sqrt(ax * ax + ay * ay + az * az);
    if (len < 1e-12 || a == 0) {
      return identity;
    }
    final double s = math.sin(a / 2) / len;
    return PebbleRotation(math.cos(a / 2), ax * s, ay * s, az * s);
  }

  static const PebbleRotation identity = PebbleRotation(1, 0, 0, 0);

  /// The resting view: the top tilted towards the viewer, turned a little.
  static final PebbleRotation resting = PebbleRotation.axisAngle(
    1,
    0,
    0,
    0.95,
  ).times(PebbleRotation.axisAngle(0, 1, 0, -0.45));

  /// Looking straight at [face] (its up pointing up).
  static PebbleRotation facing(int face) => switch (PebbleFace.values[face]) {
    PebbleFace.top => PebbleRotation.axisAngle(1, 0, 0, math.pi / 2),
    PebbleFace.bottom => PebbleRotation.axisAngle(1, 0, 0, -math.pi / 2),
    PebbleFace.front => identity,
    PebbleFace.back => PebbleRotation.axisAngle(0, 1, 0, math.pi),
    PebbleFace.left => PebbleRotation.axisAngle(0, 1, 0, math.pi / 2),
    PebbleFace.right => PebbleRotation.axisAngle(0, 1, 0, -math.pi / 2),
  };

  final double w;
  final double x;
  final double y;
  final double z;

  /// This rotation after [o] (applied to a vector: first [o], then this).
  PebbleRotation times(PebbleRotation o) => PebbleRotation(
    w * o.w - x * o.x - y * o.y - z * o.z,
    w * o.x + x * o.w + y * o.z - z * o.y,
    w * o.y - x * o.z + y * o.w + z * o.x,
    w * o.z + x * o.y - y * o.x + z * o.w,
  ).normalized();

  PebbleRotation normalized() {
    final double len = math.sqrt(w * w + x * x + y * y + z * z);
    return len == 0
        ? identity
        : PebbleRotation(w / len, x / len, y / len, z / len);
  }

  /// The shortest way from this rotation to [o], [k] of the way.
  PebbleRotation slerp(PebbleRotation o, double k) {
    double ow = o.w, ox = o.x, oy = o.y, oz = o.z;
    double dot = w * ow + x * ox + y * oy + z * oz;
    if (dot < 0) {
      dot = -dot;
      ow = -ow;
      ox = -ox;
      oy = -oy;
      oz = -oz;
    }
    if (dot > 0.9995) {
      return PebbleRotation(
        w + (ow - w) * k,
        x + (ox - x) * k,
        y + (oy - y) * k,
        z + (oz - z) * k,
      ).normalized();
    }
    final double th = math.acos(dot.clamp(-1.0, 1.0));
    final double s = math.sin(th);
    final double a = math.sin((1 - k) * th) / s;
    final double b = math.sin(k * th) / s;
    return PebbleRotation(
      w * a + ow * b,
      x * a + ox * b,
      y * a + oy * b,
      z * a + oz * b,
    );
  }

  /// The angle between this rotation and [o].
  double distance(PebbleRotation o) {
    final double dot = (w * o.w + x * o.x + y * o.y + z * o.z).abs();
    return 2 * math.acos(dot.clamp(0.0, 1.0));
  }

  /// Writes the 3×3 matrix (row-major) into [m].
  void matrix(Float64List m) {
    m[0] = 1 - 2 * (y * y + z * z);
    m[1] = 2 * (x * y - w * z);
    m[2] = 2 * (x * z + w * y);
    m[3] = 2 * (x * y + w * z);
    m[4] = 1 - 2 * (x * x + z * z);
    m[5] = 2 * (y * z - w * x);
    m[6] = 2 * (x * z - w * y);
    m[7] = 2 * (y * z + w * x);
    m[8] = 1 - 2 * (x * x + y * y);
  }
}

/// A point on the stone's surface: its face and (s, t) there.
@immutable
final class PebbleSurfacePoint {
  const PebbleSurfacePoint(this.face, this.s, this.t);

  final int face;
  final double s;
  final double t;

  @override
  String toString() => 'PebbleSurfacePoint($face, $s, $t)';
}

/// Draws a stone mesh with its texture: projection, diffuse and specular
/// light per vertex, a soft shadow, back faces culled and the rest sorted
/// far to near. Every buffer is allocated once, so a frame allocates
/// nothing but the two vertex objects the canvas needs. Remembers the last
/// frame's projection for [pick].
final class PebbleRenderer {
  PebbleRenderer(this.mesh, this.finish, this.atlas, {required this.tint})
    : _screen = Float32List(mesh.vertexCount * 2),
      _depth = Float32List(mesh.vertexCount),
      _diffuse = Int32List(mesh.vertexCount),
      _spec = Int32List(mesh.vertexCount),
      _order = Uint16List(mesh.indices.length),
      _tris = Int32List(mesh.triangleCount),
      _keys = Uint8List(mesh.triangleCount),
      _texCoords = _texCoordsOf(mesh, atlas);

  final PebbleMesh mesh;
  final PebbleFinish finish;
  final PebbleAtlas atlas;

  /// The stone's colour (tinted highlights, sea glass rim), 0xAARRGGBB.
  final int tint;

  final Float32List _screen;
  final Float32List _depth;
  final Int32List _diffuse;
  final Int32List _spec;
  final Uint16List _order;
  final Int32List _tris;
  final Uint8List _keys;
  final Float32List _texCoords;
  final Int32List _buckets = Int32List(257);
  final Float64List _m = Float64List(9);
  int _visible = 0;
  ui.Image? _shaderImage;
  final ui.Paint _texturePaint = ui.Paint()..isAntiAlias = false;
  final ui.Paint _specPaint = ui.Paint()..blendMode = ui.BlendMode.plus;
  final ui.Paint _shadowPaint = ui.Paint()
    ..color = const ui.Color(0x40000000)
    ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6);

  static Float32List _texCoordsOf(PebbleMesh mesh, PebbleAtlas atlas) {
    final Float32List out = Float32List(mesh.vertexCount * 2);
    for (int v = 0; v < mesh.vertexCount; v++) {
      final int f = PebbleMesh.faceOfVertex(v);
      out[v * 2] = atlas.u(f, mesh.faceCoords[v * 2]);
      out[v * 2 + 1] = atlas.v(f, mesh.faceCoords[v * 2 + 1]);
    }
    return out;
  }

  /// The texture coordinates of every vertex.
  Float32List get textureCoordinates => _texCoords;

  /// Triangles drawn in the last frame.
  int get visibleTriangles => _visible;

  // The light, in view space (from the upper left, in front).
  static const double _lx = -0.45, _ly = 0.65, _lz = 0.62;
  static final double _ll = math.sqrt(_lx * _lx + _ly * _ly + _lz * _lz);

  /// Draws the stone into [box] turned by [rotation].
  void paint(
    ui.Canvas canvas,
    ui.Rect box,
    PebbleRotation rotation,
    ui.Image texture, {
    double zoom = 1,
    bool shadow = true,
  }) {
    final double side = box.shortestSide;
    final double k = side * 0.43 * zoom;
    final double cx = box.center.dx;
    final double cy = box.center.dy - (shadow ? side * 0.03 : 0);
    if (shadow) {
      _shadowPaint.maskFilter = ui.MaskFilter.blur(
        ui.BlurStyle.normal,
        math.max(1, side * 0.035),
      );
      canvas.drawOval(
        ui.Rect.fromCenter(
          center: ui.Offset(cx, cy + k * 0.88),
          width: k * 1.55,
          height: k * 0.3,
        ),
        _shadowPaint,
      );
    }
    _project(rotation, k, cx, cy);
    _sort();
    if (_visible == 0) {
      return;
    }
    if (!identical(_shaderImage, texture)) {
      _shaderImage = texture;
      _texturePaint.shader = ui.ImageShader(
        texture,
        ui.TileMode.clamp,
        ui.TileMode.clamp,
        Float64List.fromList(const <double>[
          1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, //
        ]),
        filterQuality: ui.FilterQuality.low,
      );
    }
    final Uint16List indices = Uint16List.sublistView(_order, 0, _visible * 3);
    final ui.Vertices lit = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _screen,
      textureCoordinates: _texCoords,
      colors: _diffuse,
      indices: indices,
    );
    canvas.drawVertices(lit, ui.BlendMode.modulate, _texturePaint);
    lit.dispose();
    final ui.Vertices shine = ui.Vertices.raw(
      ui.VertexMode.triangles,
      _screen,
      colors: _spec,
      indices: indices,
    );
    canvas.drawVertices(shine, ui.BlendMode.dst, _specPaint);
    shine.dispose();
  }

  void _project(PebbleRotation rotation, double k, double cx, double cy) {
    rotation.matrix(_m);
    final Float64List m = _m;
    final Float32List pos = mesh.positions;
    final Float32List nor = mesh.normals;
    const double eye = 5;
    final double lx = _lx / _ll, ly = _ly / _ll, lz = _lz / _ll;
    // Half-way vector between the light and the eye (0, 0, 1).
    double hx = lx, hy = ly, hz = lz + 1;
    final double hl = math.sqrt(hx * hx + hy * hy + hz * hz);
    hx /= hl;
    hy /= hl;
    hz /= hl;
    final PebbleFinish f = finish;
    final int tr = (tint >> 16) & 0xFF,
        tg = (tint >> 8) & 0xFF,
        tb = tint & 0xFF;
    final double sr = 255 + (tr - 255) * f.specTint;
    final double sg = 255 + (tg - 255) * f.specTint;
    final double sb = 255 + (tb - 255) * f.specTint;
    final double rr = 255 + (tr - 255) * f.rimTint;
    final double rg = 255 + (tg - 255) * f.rimTint;
    final double rb = 255 + (tb - 255) * f.rimTint;
    final int n = mesh.vertexCount;
    for (int v = 0; v < n; v++) {
      final double px = pos[v * 3], py = pos[v * 3 + 1], pz = pos[v * 3 + 2];
      final double x = m[0] * px + m[1] * py + m[2] * pz;
      final double y = m[3] * px + m[4] * py + m[5] * pz;
      final double z = m[6] * px + m[7] * py + m[8] * pz;
      final double persp = eye / (eye - z);
      _screen[v * 2] = cx + x * k * persp;
      _screen[v * 2 + 1] = cy - y * k * persp;
      _depth[v] = z;
      final double qx = nor[v * 3], qy = nor[v * 3 + 1], qz = nor[v * 3 + 2];
      final double nx = m[0] * qx + m[1] * qy + m[2] * qz;
      final double ny = m[3] * qx + m[4] * qy + m[5] * qz;
      final double nz = m[6] * qx + m[7] * qy + m[8] * qz;
      final double ndl = nx * lx + ny * ly + nz * lz;
      double light = f.ambient + f.diffuse * (ndl > 0 ? ndl : 0);
      if (light > 1) {
        light = 1;
      }
      final int d = (light * 255).round();
      _diffuse[v] = 0xFF000000 | (d << 16) | (d << 8) | d;
      final double ndh = nx * hx + ny * hy + nz * hz;
      final double spec = ndh > 0
          ? f.specular * math.pow(ndh, f.shininess).toDouble()
          : 0;
      double r = spec * sr, g = spec * sg, b = spec * sb;
      if (f.rim > 0) {
        final double edge = 1 - (nz > 0 ? nz : 0);
        final double rim = f.rim * edge * edge * edge;
        r += rim * rr;
        g += rim * rg;
        b += rim * rb;
      }
      if (f.env > 0) {
        // The horizon reflected: a bright band where the reflected ray
        // turns level.
        final double ry = 2 * nz * ny;
        final double band = math.exp(-(ry - 0.25) * (ry - 0.25) / 0.02);
        r += f.env * band * sr;
        g += f.env * band * sg;
        b += f.env * band * sb;
      }
      final int ir = r > 255 ? 255 : r.round();
      final int ig = g > 255 ? 255 : g.round();
      final int ib = b > 255 ? 255 : b.round();
      _spec[v] = 0xFF000000 | (ir << 16) | (ig << 8) | ib;
    }
  }

  void _sort() {
    final Uint16List idx = mesh.indices;
    final int count = mesh.triangleCount;
    final Int32List buckets = _buckets;
    buckets.fillRange(0, buckets.length, 0);
    int visible = 0;
    for (int tri = 0; tri < count; tri++) {
      final int a = idx[tri * 3], b = idx[tri * 3 + 1], c = idx[tri * 3 + 2];
      final double ax = _screen[a * 2], ay = _screen[a * 2 + 1];
      final double cross =
          (_screen[b * 2] - ax) * (_screen[c * 2 + 1] - ay) -
          (_screen[b * 2 + 1] - ay) * (_screen[c * 2] - ax);
      // Screen y points down, so outward (counter-clockwise) triangles
      // turn clockwise on screen: their cross product is negative.
      if (cross >= 0) {
        _keys[tri] = 255;
        continue;
      }
      final double z = (_depth[a] + _depth[b] + _depth[c]) / 3;
      final int key = ((z + 1.05) / 2.1 * 254).floor().clamp(0, 254);
      _keys[tri] = key;
      buckets[key + 1]++;
      visible++;
    }
    for (int i = 1; i < buckets.length; i++) {
      buckets[i] += buckets[i - 1];
    }
    for (int tri = 0; tri < count; tri++) {
      final int key = _keys[tri];
      if (key == 255) {
        continue;
      }
      _tris[buckets[key]++] = tri;
    }
    for (int i = 0; i < visible; i++) {
      final int tri = _tris[i];
      _order[i * 3] = idx[tri * 3];
      _order[i * 3 + 1] = idx[tri * 3 + 1];
      _order[i * 3 + 2] = idx[tri * 3 + 2];
    }
    _visible = visible;
  }

  /// The surface point under [p] in the last frame, or null off the stone.
  PebbleSurfacePoint? pick(ui.Offset p) {
    final Uint16List idx = mesh.indices;
    final Float32List st = mesh.faceCoords;
    for (int i = _visible - 1; i >= 0; i--) {
      final int tri = _tris[i];
      final int a = idx[tri * 3], b = idx[tri * 3 + 1], c = idx[tri * 3 + 2];
      final double ax = _screen[a * 2], ay = _screen[a * 2 + 1];
      final double bx = _screen[b * 2], by = _screen[b * 2 + 1];
      final double cx = _screen[c * 2], cy = _screen[c * 2 + 1];
      final double det = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
      if (det.abs() < 1e-9) {
        continue;
      }
      final double wa =
          ((by - cy) * (p.dx - cx) + (cx - bx) * (p.dy - cy)) / det;
      final double wb =
          ((cy - ay) * (p.dx - cx) + (ax - cx) * (p.dy - cy)) / det;
      final double wc = 1 - wa - wb;
      const double e = -1e-6;
      if (wa < e || wb < e || wc < e) {
        continue;
      }
      return PebbleSurfacePoint(
        PebbleMesh.faceOfTriangle(tri),
        wa * st[a * 2] + wb * st[b * 2] + wc * st[c * 2],
        wa * st[a * 2 + 1] + wb * st[b * 2 + 1] + wc * st[c * 2 + 1],
      );
    }
    return null;
  }

  /// Where (s, t) of [face] lands on screen in the last frame, or null
  /// when it faces away (tests, the editor's hints).
  ui.Offset? project(int face, double s, double t) {
    final Float32List st = mesh.faceCoords;
    final Uint16List idx = mesh.indices;
    for (int i = _visible - 1; i >= 0; i--) {
      final int tri = _tris[i];
      if (PebbleMesh.faceOfTriangle(tri) != face) {
        continue;
      }
      final int a = idx[tri * 3], b = idx[tri * 3 + 1], c = idx[tri * 3 + 2];
      final double as = st[a * 2], at = st[a * 2 + 1];
      final double bs = st[b * 2], bt = st[b * 2 + 1];
      final double cs = st[c * 2], ct = st[c * 2 + 1];
      final double det = (bt - ct) * (as - cs) + (cs - bs) * (at - ct);
      final double wa = ((bt - ct) * (s - cs) + (cs - bs) * (t - ct)) / det;
      final double wb = ((ct - at) * (s - cs) + (as - cs) * (t - ct)) / det;
      final double wc = 1 - wa - wb;
      if (wa < -1e-6 || wb < -1e-6 || wc < -1e-6) {
        continue;
      }
      return ui.Offset(
        wa * _screen[a * 2] + wb * _screen[b * 2] + wc * _screen[c * 2],
        wa * _screen[a * 2 + 1] +
            wb * _screen[b * 2 + 1] +
            wc * _screen[c * 2 + 1],
      );
    }
    return null;
  }
}
