import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_fonts.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/design/pebble_paths.dart';
import 'package:zen/src/features/pebbles/design/pebble_patterns.dart';
import 'package:zen/src/features/pebbles/design/pebble_stamps.dart';

/// The texture's layout: the six faces' squares in 3 columns × 2 rows, each
/// with a gutter around the face where the neighbours' paint continues, so
/// filtering at a seam never reaches an unrelated colour.
final class PebbleAtlas {
  const PebbleAtlas(this.tile);

  /// The editor's and the full-screen stone's texture.
  static const PebbleAtlas large = PebbleAtlas(320);

  /// Small stones in grids.
  static const PebbleAtlas small = PebbleAtlas(128);

  final int tile;

  int get gutter => (tile / 16).round().clamp(2, 32);
  int get width => tile * 3;
  int get height => tile * 2;

  /// Pixels per face unit.
  double get half => (tile - 2 * gutter) / 2;

  /// The gutter in face units.
  double get gutterUnits => gutter / half;

  double centreX(int face) => (face % 3) * tile + tile / 2;
  double centreY(int face) => (face ~/ 3) * tile + tile / 2;

  ui.Rect tileRect(int face) => ui.Rect.fromLTWH(
    (face % 3) * tile.toDouble(),
    (face ~/ 3) * tile.toDouble(),
    tile.toDouble(),
    tile.toDouble(),
  );

  /// The texture position of (s, t) on [face].
  double u(int face, double s) => centreX(face) + s * half;
  double v(int face, double t) => centreY(face) - t * half;

  /// The canvas transform that draws in a face's drawing space (X, Y) =
  /// (s, -t) of the op's face, mapped by [st] into (s, t) of [face], onto
  /// [face]'s square.
  Affine2 drawMatrix(int face, Affine2 st) => Affine2(
    half,
    0,
    0,
    half,
    centreX(face),
    centreY(face),
  ).after(Affine2.flip).after(st).after(Affine2.flip);

  @override
  bool operator ==(Object other) => other is PebbleAtlas && other.tile == tile;

  @override
  int get hashCode => tile.hashCode;
}

/// Paints designs into textures. Textures are kept for the last stones
/// drawn; every image handed out is the caller's own handle (dispose it).
abstract final class PebbleTextures {
  static final LinkedHashMap<String, ui.Image> _cache =
      LinkedHashMap<String, ui.Image>();
  static final LinkedHashMap<String, ui.Image> _bases =
      LinkedHashMap<String, ui.Image>();

  /// Kept textures may take this many bytes together.
  static const int _budget = 64 << 20;

  static ui.Image _remember(
    LinkedHashMap<String, ui.Image> cache,
    String key,
    ui.Image Function() make,
  ) {
    final ui.Image? hit = cache.remove(key);
    if (hit != null) {
      cache[key] = hit;
      return hit.clone();
    }
    final ui.Image image = make();
    cache[key] = image;
    int bytes = 0;
    for (final ui.Image i in cache.values) {
      bytes += i.width * i.height * 4;
    }
    while (bytes > _budget ~/ 2 && cache.length > 1) {
      final ui.Image old = cache.remove(cache.keys.first)!;
      bytes -= old.width * old.height * 4;
      old.dispose();
    }
    return image.clone();
  }

  /// Drops every kept texture (tests, memory pressure).
  static void clear() {
    for (final ui.Image i in _cache.values) {
      i.dispose();
    }
    for (final ui.Image i in _bases.values) {
      i.dispose();
    }
    _cache.clear();
    _bases.clear();
  }

  /// The bare stone: material and colours, no paint.
  static ui.Image base(PebbleDesign d, PebbleAtlas atlas) => _remember(
    _bases,
    '${atlas.tile}:${d.material}:${d.mainColour}:${d.secondColour}:${d.seed}',
    () {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      paintBase(ui.Canvas(rec), d, atlas);
      return rec.endRecording().toImageSync(atlas.width, atlas.height);
    },
  );

  /// The painted stone. [thumbnail] (16×16 colours, 0 transparent) is laid
  /// over the top when there is no paint (a stone known only from its card).
  static ui.Image of(
    PebbleDesign d,
    PebbleAtlas atlas, {
    Uint32List? thumbnail,
  }) {
    final String key =
        '${atlas.tile}:${base64.encode(d.encode())}'
        '${thumbnail == null ? '' : ':${thumbnail.join(',')}'}';
    return _remember(_cache, key, () {
      final ui.Image under = base(d, atlas);
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(rec)
        ..drawImage(under, ui.Offset.zero, ui.Paint());
      final _OpPainter painter = _OpPainter(atlas, under, d);
      for (int i = 0; i < d.ops.length; i++) {
        painter.paint(canvas, d.ops[i], i);
      }
      if (thumbnail != null) {
        painter.thumbnail(canvas, thumbnail);
      }
      final ui.Image out = rec.endRecording().toImageSync(
        atlas.width,
        atlas.height,
      );
      under.dispose();
      return out;
    });
  }

  /// [under] with [op] painted on top ([d] is the design [op] is added to,
  /// for fills that look at the strokes before them). Not kept.
  static ui.Image overlay(
    ui.Image under,
    PebbleDesign d,
    PebbleOp op,
    PebbleAtlas atlas, {
    required ui.Image base,
  }) {
    final ui.PictureRecorder rec = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(rec)
      ..drawImage(under, ui.Offset.zero, ui.Paint());
    _OpPainter(atlas, base, d).paint(canvas, op, d.ops.length);
    return rec.endRecording().toImageSync(atlas.width, atlas.height);
  }

  /// Paints the bare stone of [d] into [canvas] (the whole atlas).
  static void paintBase(ui.Canvas canvas, PebbleDesign d, PebbleAtlas atlas) {
    final ui.Color main = ui.Color(d.mainColour | 0xFF000000);
    final ui.Color second = ui.Color(d.secondColour | 0xFF000000);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, atlas.width.toDouble(), atlas.height.toDouble()),
      ui.Paint()..color = main,
    );
    final PebbleRandom rnd = PebbleRandom(d.seed ^ 0xB5297A4D);
    final _Placer place = _Placer(atlas);
    final PebbleFinish finish = d.finish;
    // Soft mottling, everywhere but on metal.
    if (finish != PebbleFinish.metallic) {
      final double strength = switch (finish) {
        PebbleFinish.gloss => 0.05,
        PebbleFinish.seaGlass => 0.14,
        _ => 0.09,
      };
      for (int f = 0; f < 6; f++) {
        for (int i = 0; i < 14; i++) {
          final double s = rnd.range(-1, 1), t = rnd.range(-1, 1);
          final double r = rnd.range(0.2, 0.6);
          final ui.Color tone = rnd.chance(0.5)
              ? ui.Color.lerp(main, const ui.Color(0xFFFFFFFF), strength)!
              : ui.Color.lerp(main, const ui.Color(0xFF000000), strength)!;
          final ui.Paint p = ui.Paint()
            ..shader = ui.Gradient.radial(ui.Offset(s, -t), r, <ui.Color>[
              tone,
              tone.withValues(alpha: 0),
            ]);
          place.onFace(canvas, f, false, true, (ui.Canvas c, Affine2 _) {
            c.drawCircle(ui.Offset(s, -t), r, p);
          });
        }
      }
    }
    switch (finish) {
      case PebbleFinish.granite:
        _speckles(canvas, place, rnd, <(ui.Color, double, int)>[
          (ui.Color.lerp(second, const ui.Color(0xFF000000), 0.2)!, 0.022, 500),
          (second, 0.014, 900),
          (ui.Color.lerp(main, const ui.Color(0xFFFFFFFF), 0.55)!, 0.016, 500),
          (ui.Color.lerp(main, const ui.Color(0xFF000000), 0.3)!, 0.01, 900),
        ]);
      case PebbleFinish.seaGlass:
        _speckles(canvas, place, rnd, <(ui.Color, double, int)>[
          (second.withValues(alpha: 0.35), 0.012, 900),
          (const ui.Color(0x22FFFFFF), 0.03, 300),
        ]);
      case PebbleFinish.metallic:
        for (int f = 0; f < 6; f++) {
          final List<(double, ui.Paint)> lines = <(double, ui.Paint)>[
            for (int i = 0; i < 70; i++)
              (
                rnd.range(-1.2, 1.2),
                ui.Paint()
                  ..color =
                      (rnd.chance(0.5) ? const ui.Color(0xFFFFFFFF) : second)
                          .withValues(alpha: rnd.range(0.05, 0.16))
                  ..strokeWidth = rnd.range(0.006, 0.02),
              ),
          ];
          place.onFace(canvas, f, false, false, (ui.Canvas c, Affine2 _) {
            for (final (double y, ui.Paint p) in lines) {
              c.drawLine(ui.Offset(-1.3, y), ui.Offset(1.3, y), p);
            }
          });
        }
      case PebbleFinish.marble:
        for (int k = 0; k < 9; k++) {
          final int f = rnd.nextInt(6);
          double s = rnd.range(-1, 1), t = rnd.range(-1, 1);
          double a = rnd.range(0, math.pi * 2);
          final ui.Path path = ui.Path()..moveTo(s, -t);
          final int steps = 18 + rnd.nextInt(20);
          for (int i = 0; i < steps; i++) {
            a += rnd.range(-0.6, 0.6);
            s += math.cos(a) * 0.08;
            t += math.sin(a) * 0.08;
            path.lineTo(s, -t);
          }
          final ui.Paint p = ui.Paint()
            ..color = second.withValues(alpha: rnd.range(0.35, 0.75))
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = rnd.range(0.008, 0.03)
            ..strokeJoin = ui.StrokeJoin.round;
          place.onFace(canvas, f, false, true, (ui.Canvas c, Affine2 _) {
            c.drawPath(path, p);
          });
        }
      case PebbleFinish.river:
        final int bands = 1 + rnd.nextInt(2);
        for (int k = 0; k < bands; k++) {
          double nx = rnd.range(-1, 1), ny = rnd.range(-0.4, 0.4);
          double nz = rnd.range(-1, 1);
          final double len = math.sqrt(nx * nx + ny * ny + nz * nz);
          nx /= len;
          ny /= len;
          nz /= len;
          final ui.Paint p = ui.Paint()
            ..color = second.withValues(alpha: 0.85)
            ..style = ui.PaintingStyle.stroke
            ..strokeWidth = rnd.range(0.035, 0.08);
          for (int f = 0; f < 6; f++) {
            final ui.Path? band = _greatCircle(f, nx, ny, nz);
            if (band != null) {
              place.onFace(canvas, f, false, false, (ui.Canvas c, Affine2 _) {
                c.drawPath(band, p);
              });
            }
          }
        }
        _speckles(canvas, place, rnd, <(ui.Color, double, int)>[
          (ui.Color.lerp(main, const ui.Color(0xFF000000), 0.25)!, 0.01, 250),
        ]);
      case PebbleFinish.matte:
      case PebbleFinish.gloss:
        break;
    }
  }

  static void _speckles(
    ui.Canvas canvas,
    _Placer place,
    PebbleRandom rnd,
    List<(ui.Color, double, int)> sets,
  ) {
    for (int f = 0; f < 6; f++) {
      for (final (ui.Color colour, double size, int count) in sets) {
        final Float32List pts = Float32List(count * 2);
        for (int i = 0; i < count; i++) {
          pts[i * 2] = rnd.range(-1, 1);
          pts[i * 2 + 1] = rnd.range(-1, 1);
        }
        final ui.Paint p = ui.Paint()
          ..color = colour
          ..strokeWidth = size
          ..strokeCap = ui.StrokeCap.round;
        place.onFace(canvas, f, false, true, (ui.Canvas c, Affine2 _) {
          c.drawRawPoints(ui.PointMode.points, pts, p);
        });
      }
    }
  }

  /// The great circle with normal (nx, ny, nz) on [face], in its drawing
  /// space, or null when it misses the face.
  static ui.Path? _greatCircle(int face, double nx, double ny, double nz) {
    final List<double> c = PebbleFaces.centre(face);
    final List<double> r = PebbleFaces.right(face);
    final List<double> u = PebbleFaces.up(face);
    final double cn = c[0] * nx + c[1] * ny + c[2] * nz;
    final double rn = r[0] * nx + r[1] * ny + r[2] * nz;
    final double un = u[0] * nx + u[1] * ny + u[2] * nz;
    // On the cube's face plane the circle is the line cn + gs·rn + gt·un = 0.
    final ui.Path path = ui.Path();
    bool any = false;
    bool pen = false;
    const double lim = 1.7;
    final bool alongS = un.abs() >= rn.abs();
    for (int i = 0; i <= 80; i++) {
      final double a = -lim + 2 * lim * i / 80;
      final double gs, gt;
      if (alongS) {
        gs = a;
        gt = -(cn + a * rn) / un;
      } else {
        gt = a;
        gs = -(cn + a * un) / rn;
      }
      final double s = math.atan(gs) * 4 / math.pi;
      final double t = math.atan(gt) * 4 / math.pi;
      if (s.abs() > 1.3 || t.abs() > 1.3) {
        pen = false;
        continue;
      }
      if (pen) {
        path.lineTo(s, -t);
      } else {
        path.moveTo(s, -t);
        pen = true;
      }
      any = true;
    }
    return any ? path : null;
  }
}

/// Places drawing onto the faces' squares: on the face itself, optionally
/// mirrored across the stone, and continued across the seams onto the
/// neighbours ("spill").
final class _Placer {
  _Placer(this.atlas);

  final PebbleAtlas atlas;

  void onFace(
    ui.Canvas canvas,
    int face,
    bool mirror,
    bool spill,
    void Function(ui.Canvas canvas, Affine2 matrix) draw,
  ) {
    void target(int f, Affine2 pre) {
      for (int g = -1; g < (spill ? 4 : 0); g++) {
        final int to = g < 0 ? f : PebbleFaces.neighbours(f)[g];
        final Affine2 st = g < 0 ? pre : PebbleFaces.unfold(f, to).after(pre);
        final Affine2 m = atlas.drawMatrix(to, st);
        canvas
          ..save()
          ..clipRect(atlas.tileRect(to))
          ..transform(m.toMatrix4());
        draw(canvas, m);
        canvas.restore();
      }
    }

    target(face, Affine2.identity);
    if (mirror) {
      final (int f, Affine2 pre) = PebbleFaces.mirror(face);
      target(f, pre);
    }
  }
}

/// Paints one design step.
final class _OpPainter {
  _OpPainter(this.atlas, this.base, this.design) : place = _Placer(atlas);

  final PebbleAtlas atlas;
  final ui.Image base;
  final PebbleDesign design;
  final _Placer place;

  void paint(ui.Canvas canvas, PebbleOp op, int index) {
    switch (op) {
      case PebbleStroke():
        _stroke(canvas, op);
      case PebbleFaceFill():
        final double g = 1 + atlas.gutterUnits + 0.05;
        place.onFace(canvas, op.face, false, false, (ui.Canvas c, Affine2 _) {
          c.drawRect(
            ui.Rect.fromLTRB(-g, -g, g, g),
            ui.Paint()..color = ui.Color(op.colour),
          );
        });
      case PebbleRegionFill():
        _region(canvas, op, index);
      case PebbleStampOp():
        final double a = op.angle * 2 * math.pi / 256;
        final double h = op.halfSize;
        place.onFace(canvas, op.face, op.mirror, true, (
          ui.Canvas c,
          Affine2 _,
        ) {
          c
            ..save()
            ..translate(PebbleQ.value(op.s), -PebbleQ.value(op.t))
            ..rotate(a)
            ..scale(op.flip ? -h : h, h);
          PebbleStamps.paint(
            c,
            op.stamp,
            main: op.colour == 0 ? null : ui.Color(op.colour),
            ink: op.ink == 0 ? null : ui.Color(op.ink),
          );
          c.restore();
        });
      case PebbleTextOp():
        _text(canvas, op);
      case PebblePatternOp():
        final double g = 1 + atlas.gutterUnits + 0.05;
        place.onFace(canvas, op.face, false, false, (ui.Canvas c, Affine2 _) {
          c
            ..save()
            ..clipRect(ui.Rect.fromLTRB(-g, -g, g, g));
          PebblePattern.byId(op.pattern).paint(
            c,
            extent: g,
            colour: ui.Color(op.colour),
            colour2: op.colour2 == 0 ? null : ui.Color(op.colour2),
            cell: op.cell,
            angle: op.angle * 2 * math.pi / 256,
            seed: op.face * 7919 + op.pattern * 31 + op.scale,
          );
          c.restore();
        });
    }
  }

  ui.Path _polyline(Uint16List p) {
    final ui.Path path = ui.Path()
      ..moveTo(PebbleQ.value(p[0]), -PebbleQ.value(p[1]));
    for (int i = 2; i < p.length; i += 2) {
      path.lineTo(PebbleQ.value(p[i]), -PebbleQ.value(p[i + 1]));
    }
    return path;
  }

  void _stroke(ui.Canvas canvas, PebbleStroke op) {
    final double r = op.radius;
    final Uint16List p = op.points;
    if (op.tool == PebbleStrokeTool.spray) {
      final Float32List dots = _sprayDots(op);
      final ui.Paint paint = ui.Paint()
        ..color = ui.Color(op.colour)
        ..strokeWidth = r * 0.16
        ..strokeCap = ui.StrokeCap.round;
      place.onFace(canvas, op.face, op.mirror, true, (ui.Canvas c, Affine2 _) {
        c.drawRawPoints(ui.PointMode.points, dots, paint);
      });
      return;
    }
    final ui.Path path = _polyline(p);
    final bool dot =
        p.length == 2 || (p.length == 4 && p[0] == p[2] && p[1] == p[3]);
    place.onFace(canvas, op.face, op.mirror, true, (ui.Canvas c, Affine2 m) {
      final ui.Paint paint = ui.Paint()
        ..isAntiAlias = true
        ..strokeCap = ui.StrokeCap.round
        ..strokeJoin = ui.StrokeJoin.round;
      if (op.tool == PebbleStrokeTool.eraser) {
        paint.shader = ui.ImageShader(
          base,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          m.inverse.toMatrix4(),
        );
      } else {
        paint.color = ui.Color(op.colour);
      }
      if (dot) {
        c.drawCircle(
          ui.Offset(PebbleQ.value(p[0]), -PebbleQ.value(p[1])),
          r,
          paint,
        );
      } else {
        paint
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = r * 2;
        c.drawPath(path, paint);
      }
    });
  }

  static Float32List _sprayDots(PebbleStroke op) {
    final Uint16List p = op.points;
    final double r = op.radius;
    final PebbleRandom rnd = PebbleRandom(
      p[0] * 7919 + p[1] * 104729 + op.colour + op.pointCount * 31,
    );
    final List<double> out = <double>[];
    void around(double x, double y, int count) {
      for (int k = 0; k < count; k++) {
        final double a = rnd.range(0, math.pi * 2);
        final double d = r * math.sqrt(rnd.next());
        out
          ..add(x + math.cos(a) * d)
          ..add(-(y + math.sin(a) * d));
      }
    }

    around(PebbleQ.value(p[0]), PebbleQ.value(p[1]), 10);
    for (int i = 2; i < p.length; i += 2) {
      final double x0 = PebbleQ.value(p[i - 2]), y0 = PebbleQ.value(p[i - 1]);
      final double x1 = PebbleQ.value(p[i]), y1 = PebbleQ.value(p[i + 1]);
      final double len = math.sqrt(
        (x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0),
      );
      final int steps = (len / (r * 0.3)).ceil().clamp(1, 400);
      for (int k = 1; k <= steps; k++) {
        final double f = k / steps;
        around(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f, 6);
      }
      if (out.length > 40000) {
        break;
      }
    }
    return Float32List.fromList(out);
  }

  void _text(ui.Canvas canvas, PebbleTextOp op) {
    final PebbleFont font = PebbleFont.byId(op.font);
    final List<TextPainter> glyphs = <TextPainter>[
      for (final String ch in op.text.characters)
        TextPainter(
          text: TextSpan(
            text: ch,
            style: TextStyle(
              fontFamily: font.family,
              fontSize: 100,
              height: 1.1,
              fontWeight: font.weight,
              color: ui.Color(op.colour),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(),
    ];
    if (glyphs.isEmpty) {
      return;
    }
    final double scale = op.height / 100;
    double total = 0;
    for (final TextPainter g in glyphs) {
      total += g.width * scale;
    }
    final double angle = op.angle * 2 * math.pi / 256;
    final double bendRadius = op.curve == 0
        ? double.infinity
        : 1 / (op.curve.abs() / 100 * 2.2);
    final double sign = op.curve >= 0 ? 1 : -1;
    place.onFace(canvas, op.face, false, true, (ui.Canvas c, Affine2 _) {
      c
        ..save()
        ..translate(PebbleQ.value(op.s), -PebbleQ.value(op.t))
        ..rotate(angle);
      double l = -total / 2;
      for (final TextPainter g in glyphs) {
        final double w = g.width * scale;
        final double mid = l + w / 2;
        double x = mid, y = 0, turn = 0;
        if (bendRadius.isFinite) {
          final double th = mid / bendRadius;
          x = bendRadius * math.sin(th);
          y = sign * bendRadius * (1 - math.cos(th));
          turn = sign * th;
        }
        c
          ..save()
          ..translate(x, y)
          ..rotate(turn)
          ..scale(scale);
        g.paint(c, ui.Offset(-g.width / 2, -g.height / 2));
        c.restore();
        l += w;
      }
      c.restore();
    });
    for (final TextPainter g in glyphs) {
      g.dispose();
    }
  }

  // ---- Region fill

  static const int _cells = 128;

  void _region(ui.Canvas canvas, PebbleRegionFill op, int index) {
    final Uint8List ink = inkOf(design, op.face, index);
    final Uint8List filled = flood(
      ink,
      PebbleQ.value(op.s),
      PebbleQ.value(op.t),
    );
    const double cell = 2 / _cells;
    final double g = atlas.gutterUnits + 0.05;
    final ui.Path path = ui.Path();
    for (int j = 0; j < _cells; j++) {
      int i = 0;
      while (i < _cells) {
        if (filled[j * _cells + i] == 0) {
          i++;
          continue;
        }
        final int start = i;
        while (i < _cells && filled[j * _cells + i] != 0) {
          i++;
        }
        double s0 = -1 + start * cell - cell * 0.5;
        double s1 = -1 + i * cell + cell * 0.5;
        double t0 = -1 + j * cell - cell * 0.5;
        double t1 = -1 + (j + 1) * cell + cell * 0.5;
        if (start == 0) s0 = -1 - g;
        if (i == _cells) s1 = 1 + g;
        if (j == 0) t0 = -1 - g;
        if (j == _cells - 1) t1 = 1 + g;
        path.addRect(ui.Rect.fromLTRB(s0, -t1, s1, -t0));
      }
    }
    final ui.Paint paint = ui.Paint()..color = ui.Color(op.colour);
    place.onFace(canvas, op.face, false, false, (ui.Canvas c, Affine2 _) {
      c.drawPath(path, paint);
    });
  }

  /// Which cells of [face] (128 × 128 over s, t in -1…1, row 0 at t = -1)
  /// the strokes before step [upTo] cover.
  static Uint8List inkOf(PebbleDesign design, int face, int upTo) {
    final Uint8List ink = Uint8List(_cells * _cells);
    const double cell = 2 / _cells;
    for (int k = 0; k < upTo && k < design.ops.length; k++) {
      final PebbleOp op = design.ops[k];
      if (op is PebbleFaceFill && op.face == face) {
        ink.fillRange(0, ink.length, 0);
        continue;
      }
      if (op is! PebbleStroke) {
        continue;
      }
      final int mark = op.tool == PebbleStrokeTool.eraser ? 0 : 1;
      final double r = op.radius + cell * 0.5;
      void along(Affine2 a) {
        final Uint16List p = op.points;
        double px = 0, py = 0;
        for (int i = 0; i < p.length; i += 2) {
          final double s = PebbleQ.value(p[i]), t = PebbleQ.value(p[i + 1]);
          final double x = a.x(s, t), y = a.y(s, t);
          if (i == 0) {
            _segment(ink, x, y, x, y, r, mark);
          } else {
            _segment(ink, px, py, x, y, r, mark);
          }
          px = x;
          py = y;
        }
      }

      final List<(int, Affine2)> targets = <(int, Affine2)>[
        (op.face, Affine2.identity),
        if (op.mirror) PebbleFaces.mirror(op.face),
      ];
      for (final (int f, Affine2 pre) in targets) {
        if (f == face) {
          along(pre);
        } else if (PebbleFaces.neighbours(f).contains(face)) {
          along(PebbleFaces.unfold(f, face).after(pre));
        }
      }
    }
    return ink;
  }

  static void _segment(
    Uint8List ink,
    double x0,
    double y0,
    double x1,
    double y1,
    double r,
    int mark,
  ) {
    const double cell = 2 / _cells;
    final int i0 = ((math.min(x0, x1) - r + 1) / cell).floor().clamp(
      0,
      _cells - 1,
    );
    final int i1 = ((math.max(x0, x1) + r + 1) / cell).floor().clamp(
      0,
      _cells - 1,
    );
    final int j0 = ((math.min(y0, y1) - r + 1) / cell).floor().clamp(
      0,
      _cells - 1,
    );
    final int j1 = ((math.max(y0, y1) + r + 1) / cell).floor().clamp(
      0,
      _cells - 1,
    );
    if (math.max(x0, x1) + r < -1 || math.min(x0, x1) - r > 1) return;
    if (math.max(y0, y1) + r < -1 || math.min(y0, y1) - r > 1) return;
    final double dx = x1 - x0, dy = y1 - y0;
    final double len2 = dx * dx + dy * dy;
    for (int j = j0; j <= j1; j++) {
      final double cy = -1 + (j + 0.5) * cell;
      for (int i = i0; i <= i1; i++) {
        final double cx = -1 + (i + 0.5) * cell;
        double k = len2 == 0 ? 0 : ((cx - x0) * dx + (cy - y0) * dy) / len2;
        k = k.clamp(0.0, 1.0);
        final double ex = x0 + dx * k - cx, ey = y0 + dy * k - cy;
        if (ex * ex + ey * ey <= r * r) {
          ink[j * _cells + i] = mark;
        }
      }
    }
  }

  /// The cells connected to (s, t) with the same ink as it.
  static Uint8List flood(Uint8List ink, double s, double t) {
    const double cell = 2 / _cells;
    final int si = ((s + 1) / cell).floor().clamp(0, _cells - 1);
    final int sj = ((t + 1) / cell).floor().clamp(0, _cells - 1);
    final Uint8List out = Uint8List(_cells * _cells);
    final int want = ink[sj * _cells + si];
    final Int32List queue = Int32List(_cells * _cells);
    int head = 0, tail = 0;
    queue[tail++] = sj * _cells + si;
    out[sj * _cells + si] = 1;
    while (head < tail) {
      final int at = queue[head++];
      final int i = at % _cells, j = at ~/ _cells;
      void visit(int n) {
        if (out[n] == 0 && ink[n] == want) {
          out[n] = 1;
          queue[tail++] = n;
        }
      }

      if (i > 0) visit(at - 1);
      if (i < _cells - 1) visit(at + 1);
      if (j > 0) visit(at - _cells);
      if (j < _cells - 1) visit(at + _cells);
    }
    return out;
  }

  /// A card's 16×16 top view laid over the top face.
  void thumbnail(ui.Canvas canvas, Uint32List pixels) {
    // Smoothed, not as 16 x 16 squares: each pixel in 4 x 4 cells, coloured
    // by blending its painted neighbours (bilinear); a cell more empty than
    // painted stays empty, so the drawing keeps its outline.
    const double extent = 1.35;
    const int sub = 4;
    const int cells = 16 * sub;
    const double cell = extent * 2 / cells;
    final ui.Paint paint = ui.Paint();
    int at(int i, int j) => pixels[j.clamp(0, 15) * 16 + i.clamp(0, 15)];
    place.onFace(canvas, PebbleFace.top.index, false, true, (
      ui.Canvas c,
      Affine2 _,
    ) {
      for (int v = 0; v < cells; v++) {
        final double y = (v + 0.5) / sub - 0.5;
        final int j0 = y.floor();
        final double fy = y - j0;
        for (int u = 0; u < cells; u++) {
          final double x = (u + 0.5) / sub - 0.5;
          final int i0 = x.floor();
          final double fx = x - i0;
          double r = 0, g = 0, b = 0, painted = 0;
          for (final (int di, int dj, double w) in <(int, int, double)>[
            (0, 0, (1 - fx) * (1 - fy)),
            (1, 0, fx * (1 - fy)),
            (0, 1, (1 - fx) * fy),
            (1, 1, fx * fy),
          ]) {
            final int argb = at(i0 + di, j0 + dj);
            if (argb == 0 || w == 0) {
              continue;
            }
            r += ((argb >> 16) & 0xFF) * w;
            g += ((argb >> 8) & 0xFF) * w;
            b += (argb & 0xFF) * w;
            painted += w;
          }
          if (painted < 0.5) {
            continue;
          }
          paint.color = ui.Color.fromARGB(
            0xFF,
            (r / painted).round(),
            (g / painted).round(),
            (b / painted).round(),
          );
          c.drawRect(
            ui.Rect.fromLTWH(
              -extent + u * cell,
              -extent + v * cell,
              cell + 0.002,
              cell + 0.002,
            ),
            paint,
          );
        }
      }
    });
  }
}
