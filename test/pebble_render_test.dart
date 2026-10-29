import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_ready_designs.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';
import 'package:zen/src/features/pebbles/render/pebble_mesh.dart';
import 'package:zen/src/features/pebbles/render/pebble_renderer.dart';
import 'package:zen/src/features/pebbles/render/pebble_texture.dart';
import 'package:zen/src/features/pebbles/render/pebble_thumbnail.dart';

const ui.Rect _box = ui.Rect.fromLTWH(0, 0, 400, 400);

PebbleRenderer _renderer(
  PebbleDesign d, [
  PebbleAtlas atlas = PebbleAtlas.small,
]) => PebbleRenderer(
  PebbleMesh.of(PebbleShapeKey.of(d)),
  d.finish,
  atlas,
  tint: d.mainColour,
);

/// Draws [d] once (so the renderer knows its projection) and returns the
/// picture's pixels.
Future<Uint8List> _pixels(
  PebbleDesign d,
  PebbleRotation rotation, {
  int px = 96,
}) async {
  final ui.Image texture = PebbleTextures.of(d, PebbleAtlas.small);
  final ui.PictureRecorder rec = ui.PictureRecorder();
  _renderer(d).paint(
    ui.Canvas(rec),
    ui.Rect.fromLTWH(0, 0, px.toDouble(), px.toDouble()),
    rotation,
    texture,
  );
  final ui.Image image = await rec.endRecording().toImage(px, px);
  final ByteData data = (await image.toByteData())!;
  image.dispose();
  texture.dispose();
  return data.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('mesh', () {
    test(
      'is the same for the same shape and seed, different for another seed',
      () {
        for (final PebbleShapePreset s in PebbleShapePreset.values) {
          final PebbleShapeKey key = PebbleShapeKey(shape: s.index, seed: 99);
          final PebbleMesh a = PebbleMesh.build(key);
          final PebbleMesh b = PebbleMesh.build(key);
          expect(a.positions, b.positions, reason: s.name);
          expect(a.normals, b.normals, reason: s.name);
          final PebbleMesh c = PebbleMesh.build(
            PebbleShapeKey(shape: s.index, seed: 100),
          );
          expect(c.positions, isNot(a.positions), reason: s.name);
        }
      },
    );

    test('has 2–4k triangles, fits the unit ball, no NaN, unit normals', () {
      for (final PebbleShapePreset s in PebbleShapePreset.values) {
        final PebbleMesh m = PebbleMesh.build(
          PebbleShapeKey(shape: s.index, seed: 7, width: 30, height: -20),
        );
        expect(m.triangleCount, inInclusiveRange(2000, 4000));
        for (int v = 0; v < m.vertexCount; v++) {
          final double x = m.positions[v * 3],
              y = m.positions[v * 3 + 1],
              z = m.positions[v * 3 + 2];
          expect(
            x.isFinite && y.isFinite && z.isFinite,
            isTrue,
            reason: s.name,
          );
          expect(
            x * x + y * y + z * z,
            lessThanOrEqualTo(1.0001),
            reason: s.name,
          );
          final double nx = m.normals[v * 3],
              ny = m.normals[v * 3 + 1],
              nz = m.normals[v * 3 + 2];
          expect(nx * nx + ny * ny + nz * nz, closeTo(1, 1e-4), reason: s.name);
        }
      }
    });

    test('is closed: welded at the seams, every edge shared by two triangles, '
        'faces outwards, normals agree with the triangles', () {
      for (final PebbleShapePreset s in PebbleShapePreset.values) {
        final PebbleMesh m = PebbleMesh.build(
          PebbleShapeKey(shape: s.index, seed: 3),
        );
        // Weld equal positions.
        final Map<String, int> ids = <String, int>{};
        final List<int> weld = List<int>.generate(m.vertexCount, (int v) {
          String k(int i) => (m.positions[v * 3 + i] * 1e4).round().toString();
          return ids.putIfAbsent('${k(0)},${k(1)},${k(2)}', () => ids.length);
        });
        final Map<(int, int), int> edges = <(int, int), int>{};
        double volume = 0;
        int agree = 0;
        for (int tri = 0; tri < m.triangleCount; tri++) {
          final List<int> v = <int>[
            m.indices[tri * 3],
            m.indices[tri * 3 + 1],
            m.indices[tri * 3 + 2],
          ];
          for (int e = 0; e < 3; e++) {
            final int a = weld[v[e]], b = weld[v[(e + 1) % 3]];
            final (int, int) key = a < b ? (a, b) : (b, a);
            edges[key] = (edges[key] ?? 0) + 1;
          }
          double p(int i, int c) => m.positions[v[i] * 3 + c];
          final double ux = p(1, 0) - p(0, 0),
              uy = p(1, 1) - p(0, 1),
              uz = p(1, 2) - p(0, 2);
          final double wx = p(2, 0) - p(0, 0),
              wy = p(2, 1) - p(0, 1),
              wz = p(2, 2) - p(0, 2);
          final double nx = uy * wz - uz * wy,
              ny = uz * wx - ux * wz,
              nz = ux * wy - uy * wx;
          volume += p(0, 0) * nx + p(0, 1) * ny + p(0, 2) * nz;
          final double dot =
              nx * m.normals[v[0] * 3] +
              ny * m.normals[v[0] * 3 + 1] +
              nz * m.normals[v[0] * 3 + 2];
          if (dot > 0) {
            agree++;
          }
        }
        expect(
          ids.length,
          6 * 16 * 16 + 2,
          reason: '${s.name}: welded vertices',
        );
        expect(edges.values.every((int n) => n == 2), isTrue, reason: s.name);
        expect(volume, greaterThan(0), reason: s.name);
        expect(agree / m.triangleCount, greaterThan(0.99), reason: s.name);
      }
    });
  });

  group('texture mapping', () {
    test('every triangle maps inside its own face square, and each face is '
        'covered whole', () {
      const PebbleAtlas atlas = PebbleAtlas.large;
      final PebbleDesign d = PebbleDesign.stone(shape: 6, seed: 2);
      final PebbleRenderer r = _renderer(d, atlas);
      final Float32List uv = r.textureCoordinates;
      final PebbleMesh m = r.mesh;
      final List<double> area = List<double>.filled(6, 0);
      for (int tri = 0; tri < m.triangleCount; tri++) {
        final int f = PebbleMesh.faceOfTriangle(tri);
        final ui.Rect tile = atlas.tileRect(f).deflate(atlas.gutter - 0.01);
        final List<int> v = <int>[
          m.indices[tri * 3],
          m.indices[tri * 3 + 1],
          m.indices[tri * 3 + 2],
        ];
        for (final int i in v) {
          expect(
            tile.contains(ui.Offset(uv[i * 2], uv[i * 2 + 1])) ||
                (uv[i * 2] - tile.right).abs() < 0.02 ||
                (uv[i * 2 + 1] - tile.bottom).abs() < 0.02,
            isTrue,
          );
        }
        final double ax = uv[v[0] * 2], ay = uv[v[0] * 2 + 1];
        area[f] +=
            ((uv[v[1] * 2] - ax) * (uv[v[2] * 2 + 1] - ay) -
                    (uv[v[1] * 2 + 1] - ay) * (uv[v[2] * 2] - ax))
                .abs() /
            2;
      }
      final double full = math.pow(atlas.half * 2, 2).toDouble();
      for (final double a in area) {
        expect(a, closeTo(full, full * 1e-6));
      }
    });
  });

  group('picking', () {
    test('a tap lands on the face and (s, t) under it', () {
      final PebbleDesign d = PebbleDesign.stone(
        shape: PebbleShapePreset.river.index,
        seed: 5,
      );
      final ui.Image texture = PebbleTextures.of(d, PebbleAtlas.small);
      for (int f = 0; f < 6; f++) {
        final PebbleRenderer r = _renderer(d);
        r.paint(
          ui.Canvas(ui.PictureRecorder()),
          _box,
          PebbleRotation.facing(f),
          texture,
        );
        // Facing the face: the middle of the view is about its middle.
        final PebbleSurfacePoint mid = r.pick(
          _box.center.translate(0, -400 * 0.03),
        )!;
        expect(mid.face, f);
        expect(mid.s.abs(), lessThan(0.25));
        expect(mid.t.abs(), lessThan(0.25));
        // Points of the face land where they are drawn, and back.
        for (final (double s, double t) in <(double, double)>[
          (0.5, 0.3),
          (-0.6, -0.4),
          (0.1, 0.8),
          (-0.85, 0.7),
        ]) {
          final ui.Offset at = r.project(f, s, t)!;
          final PebbleSurfacePoint p = r.pick(at)!;
          expect(p.face, f, reason: 'face $f at ($s, $t)');
          expect(p.s, closeTo(s, 1e-3));
          expect(p.t, closeTo(t, 1e-3));
        }
        // Up on screen is up on the face; right is right.
        final PebbleSurfacePoint up = r.pick(_box.center.translate(0, -60))!;
        final PebbleSurfacePoint right = r.pick(
          _box.center.translate(50, -12),
        )!;
        expect(up.t, greaterThan(mid.t));
        expect(right.s, greaterThan(mid.s));
        // Outside the stone there is nothing.
        expect(r.pick(const ui.Offset(2, 2)), isNull);
      }
      texture.dispose();
    });

    test('the far side is never picked', () {
      final PebbleDesign d = PebbleDesign.stone(
        shape: PebbleShapePreset.dented.index,
        seed: 8,
      );
      final ui.Image texture = PebbleTextures.of(d, PebbleAtlas.small);
      final PebbleRenderer r = _renderer(d);
      r.paint(
        ui.Canvas(ui.PictureRecorder()),
        _box,
        PebbleRotation.facing(0),
        texture,
      );
      for (int y = 40; y < 360; y += 16) {
        for (int x = 40; x < 360; x += 16) {
          final PebbleSurfacePoint? p = r.pick(
            ui.Offset(x.toDouble(), y.toDouble()),
          );
          if (p != null) {
            expect(p.face, isNot(PebbleFace.bottom.index));
          }
        }
      }
      texture.dispose();
    });
  });

  group('drawing', () {
    test(
      'every ready design and many random ones paint a visible stone',
      () async {
        final List<PebbleDesign> designs = <PebbleDesign>[
          for (final PebbleReadyDesign r in PebbleReadyDesign.values) r.build(),
          for (int i = 0; i < 12; i++) pebbleRandomDesign(i * 7919),
        ];
        for (final PebbleDesign d in designs) {
          final Uint8List px = await _pixels(d, PebbleRotation.resting);
          int opaque = 0;
          for (int i = 3; i < px.length; i += 4) {
            if (px[i] > 200) {
              opaque++;
            }
          }
          // The stone covers a good part of the view, the corners stay empty.
          expect(opaque, greaterThan(96 * 96 * 0.2));
          expect(px[3], 0);
        }
      },
    );

    test('paint on the top shows from above, not from below', () async {
      final PebbleDesign plain = PebbleDesign.stone(material: 18);
      final PebbleDesign painted = plain.withOp(
        const PebbleFaceFill(face: 0, colour: 0xFFFF0000),
      );
      int red(Uint8List px) {
        int n = 0;
        for (int i = 0; i < px.length; i += 4) {
          if (px[i] > 150 && px[i + 1] < 90 && px[i + 2] < 90) {
            n++;
          }
        }
        return n;
      }

      expect(red(await _pixels(plain, PebbleRotation.facing(0))), 0);
      expect(
        red(await _pixels(painted, PebbleRotation.facing(0))),
        greaterThan(500),
      );
      expect(red(await _pixels(painted, PebbleRotation.facing(1))), 0);
    });

    test('a stroke across a seam continues on the neighbour', () async {
      // A thick line along the top face, running off its front edge.
      final PebbleDesign d = PebbleDesign.stone(material: 18).withOp(
        PebbleStroke(
          tool: PebbleStrokeTool.brush,
          colour: 0xFF0000FF,
          size: 30,
          face: PebbleFace.top.index,
          points: Uint16List.fromList(<int>[
            PebbleQ.of(0),
            PebbleQ.of(0),
            PebbleQ.of(0),
            PebbleQ.of(-1.6),
          ]),
        ),
      );
      // Seen from the front, the line comes down over the front face.
      final ui.Image texture = PebbleTextures.of(d, PebbleAtlas.small);
      final PebbleRenderer r = _renderer(d);
      r.paint(
        ui.Canvas(ui.PictureRecorder()),
        _box,
        PebbleRotation.facing(2),
        texture,
      );
      final ui.Offset onFront = r.project(PebbleFace.front.index, 0, 0.6)!;
      texture.dispose();
      final Uint8List px = await _pixels(d, PebbleRotation.facing(2), px: 400);
      final int o = (onFront.dy.round() * 400 + onFront.dx.round()) * 4;
      expect(px[o + 2], greaterThan(150), reason: 'blue on the front face');
      expect(px[o], lessThan(100));
    });

    test('100 frames draw quickly', () {
      final PebbleDesign d = PebbleReadyDesign.galaxy.build();
      final ui.Image texture = PebbleTextures.of(d, PebbleAtlas.large);
      final PebbleRenderer r = _renderer(d, PebbleAtlas.large);
      final Stopwatch watch = Stopwatch()..start();
      PebbleRotation rot = PebbleRotation.resting;
      final PebbleRotation step = PebbleRotation.axisAngle(0.3, 1, 0.1, 0.05);
      for (int i = 0; i < 100; i++) {
        rot = step.times(rot);
        final ui.PictureRecorder rec = ui.PictureRecorder();
        r.paint(ui.Canvas(rec), _box, rot, texture);
        rec.endRecording().dispose();
      }
      watch.stop();
      texture.dispose();
      // Debug-mode tests are several times slower than a release build.
      expect(watch.elapsedMilliseconds, lessThan(3000));
      expect(r.visibleTriangles, inInclusiveRange(1000, 2500));
    });
  });

  group('thumbnail', () {
    test('rows from the top, the left pixel in the high nibble, 0 outside', () {
      // A 64×64 picture: transparent top row of blocks, then red on the
      // left half and blue on the right half.
      const int px = 64;
      final Uint8List rgba = Uint8List(px * px * 4);
      for (int y = 4; y < px; y++) {
        for (int x = 0; x < px; x++) {
          final int o = (y * px + x) * 4;
          if (x < 32) {
            rgba[o] = 255;
          } else {
            rgba[o + 2] = 255;
          }
          rgba[o + 3] = 255;
        }
      }
      final Uint8List t = thumbnailFromRgba(rgba, px);
      expect(t.length, 176);
      int index(int x, int y) {
        final int b = t[48 + (y * 16 + x) ~/ 2];
        return x.isEven ? b >> 4 : b & 15;
      }

      int rgb(int i) => (t[i * 3] << 16) | (t[i * 3 + 1] << 8) | t[i * 3 + 2];
      expect(t.sublist(0, 3), <int>[0, 0, 0]);
      for (int x = 0; x < 16; x++) {
        expect(index(x, 0), 0, reason: 'the top row is outside the stone');
      }
      expect(rgb(index(0, 5)), 0xFF0000);
      expect(rgb(index(15, 5)), 0x0000FF);
      // Each byte holds an even pixel (high nibble) and the next one.
      final int red = index(0, 5), blue = index(15, 5);
      expect(t[48 + (5 * 16 + 6) ~/ 2], (red << 4) | red);
      expect(t[48 + (5 * 16 + 8) ~/ 2], (blue << 4) | blue);
      // Decoding gives the same picture back.
      final Uint32List back = PebbleThumbnail.decode(t)!;
      expect(back[5 * 16], 0xFFFF0000);
      expect(back[5 * 16 + 15], 0xFF0000FF);
      expect(back[3], 0);
    });

    test('a pixel pair with different colours puts the left one high', () {
      final List<int> pixels = List<int>.filled(256, 0);
      pixels[0] = 5;
      pixels[1] = 10;
      pixels[16 * 15 + 14] = 1;
      final Uint8List t = PebbleThumbnail.encode(
        List<int>.generate(15, (int i) => i + 1),
        pixels,
      );
      expect(t[48], 0x5A);
      expect(t[48 + (16 * 15 + 14) ~/ 2], 0x10);
    });

    test(
      'is 176 bytes: the top view in 16 colours with a transparent edge',
      () async {
        final Uint8List t = await pebbleThumbnail(
          PebbleReadyDesign.ladybird.build(),
        );
        expect(t.length, PebbleThumbnail.bytes);
        expect(t.length, 176);
        expect(t.sublist(0, 3), <int>[0, 0, 0]);
        final Uint32List px = PebbleThumbnail.decode(t)!;
        expect(px[0], 0, reason: 'corner transparent');
        expect(px[8 * 16 + 8], isNot(0), reason: 'middle painted');
        // The ladybird is red with black: both show in the top view.
        final (int, int) colours = thumbnailColours(t)!;
        final int main = colours.$1;
        expect((main >> 16) & 0xFF, greaterThan((main >> 8) & 0xFF));
        expect(await pebbleThumbnail(PebbleReadyDesign.ladybird.build()), t);
      },
    );
  });
}
