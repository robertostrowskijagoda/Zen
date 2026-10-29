import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/design/pebble_patterns.dart';
import 'package:zen/src/features/pebbles/design/pebble_ready_designs.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';
import 'package:zen/src/features/pebbles/design/pebble_stamps.dart';

PebbleStroke _stroke(int n, {int face = 0, int seed = 1}) {
  final Uint16List p = Uint16List(n * 2);
  int x = 2048, y = 2048;
  for (int i = 0; i < n; i++) {
    x = (x + ((i * 37 + seed) % 61) - 30).clamp(0, PebbleQ.max);
    y = (y + ((i * 53 + seed) % 47) - 23).clamp(0, PebbleQ.max);
    p[i * 2] = x;
    p[i * 2 + 1] = y;
  }
  return PebbleStroke(
    tool: PebbleStrokeTool.brush,
    colour: 0xFF112233,
    size: 12,
    face: face,
    points: p,
  );
}

/// A design with one of every kind of step, including a long jump that
/// needs the absolute escape in the point stream.
PebbleDesign _everything() {
  final Uint16List jump = Uint16List.fromList(<int>[
    0,
    0,
    4095,
    4095,
    4000,
    10,
  ]);
  return PebbleDesign.stone(shape: 3, seed: 0xDEADBEEF, material: 13).copyWith(
    width: -40,
    height: 25,
    length: 100,
    ops: <PebbleOp>[
      _stroke(50),
      PebbleStroke(
        tool: PebbleStrokeTool.spray,
        colour: 0x80FF0000,
        size: 255,
        face: 5,
        points: jump,
        mirror: true,
      ),
      PebbleStroke(
        tool: PebbleStrokeTool.eraser,
        colour: 0,
        size: 1,
        face: 1,
        points: Uint16List.fromList(<int>[100, 200]),
      ),
      const PebbleFaceFill(face: 2, colour: 0xFF00FF00),
      const PebbleRegionFill(face: 3, s: 2048, t: 1000, colour: 0xFF0000FF),
      const PebbleStampOp(
        stamp: 140,
        face: 4,
        s: 1,
        t: 4095,
        size: 200,
        angle: 77,
        colour: 0xFF123456,
        ink: 0xFF654321,
        mirror: true,
        flip: true,
      ),
      const PebbleTextOp(
        face: 0,
        s: 2048,
        t: 2048,
        size: 60,
        text: 'Zażółć gęślą jaźń 🙂',
        colour: 0xFFFFFFFF,
        angle: 12,
        curve: -100,
        font: 3,
      ),
      const PebblePatternOp(
        face: 1,
        pattern: 19,
        colour: 0xFF000000,
        colour2: 0xFFFFFFFF,
        scale: 255,
        angle: 255,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('presets', () {
    test('there are at least 20 shapes, 30 materials, 100 drawn stamps, '
        '8 patterns and 20 ready designs', () {
      expect(PebbleShapePreset.values.length, greaterThanOrEqualTo(20));
      expect(PebbleMaterial.values.length, greaterThanOrEqualTo(30));
      final int drawn = PebbleStamps.all
          .where((PebbleStamp s) => s.glyph == null)
          .length;
      expect(drawn, greaterThanOrEqualTo(100));
      expect(PebbleStamps.count, greaterThanOrEqualTo(140));
      expect(PebblePattern.values.length, greaterThanOrEqualTo(8));
      expect(PebbleReadyDesign.values.length, greaterThanOrEqualTo(20));
      // Every group has stamps, and the categories the brief names exist.
      for (final PebbleStampCategory c in PebbleStampCategory.values) {
        expect(PebbleStamps.inCategory(c), isNotEmpty, reason: c.name);
      }
      // Ids fit the card's u8 fields and the design's u8/u16 fields.
      expect(PebbleShapePreset.values.length, lessThan(256));
      expect(PebbleMaterial.values.length, lessThan(256));
      expect(PebbleStamps.count, lessThan(65536));
    });

    test('every shape is a natural stone, and so is every ready design\'s', () {
      // A figure (a heart, a star, a clover, a crescent, a dice) needs deep
      // lobes, a heart's notch, a strong bend or waist, or sharp corners;
      // a stone has at most a hint of them.
      for (final PebbleShapePreset s in PebbleShapePreset.values) {
        final PebbleShapeParams p = s.params;
        final String what = s.name;
        expect(p.lobes, lessThanOrEqualTo(0.06), reason: what);
        expect(p.waist, lessThanOrEqualTo(0.2), reason: what);
        expect(p.bend.abs(), lessThanOrEqualTo(0.4), reason: what);
        expect(p.egg.abs(), lessThanOrEqualTo(0.32), reason: what);
        expect(
          math.min(p.e1, p.e2),
          greaterThanOrEqualTo(0.45),
          reason: '$what: no box corners',
        );
      }
      for (final PebbleReadyDesign d in PebbleReadyDesign.values) {
        final int shape = d.build().shape;
        expect(PebbleShapePreset.byId(shape).index, shape, reason: d.name);
      }
      // The ids of the first test builds' figures now give stones.
      for (final (int id, PebbleShapePreset now) in <(int, PebbleShapePreset)>[
        (3, PebbleShapePreset.flatOval),
        (8, PebbleShapePreset.wedge),
        (12, PebbleShapePreset.lopsided),
        (17, PebbleShapePreset.almond),
        (20, PebbleShapePreset.chipped),
        (22, PebbleShapePreset.flatRound),
        (25, PebbleShapePreset.blocky),
        (26, PebbleShapePreset.bumpy),
      ]) {
        expect(PebbleShapePreset.byId(id), now);
      }
      expect(PebbleShapePreset.byId(200), PebbleShapePreset.river);
    });

    test('every label is there', () {
      for (final PebbleShapePreset s in PebbleShapePreset.values) {
        expect(s.label, isNotEmpty);
      }
      for (final PebbleMaterial m in PebbleMaterial.values) {
        expect(m.label, isNotEmpty);
      }
      for (final PebblePattern p in PebblePattern.values) {
        expect(p.label, isNotEmpty);
      }
      for (final PebbleReadyDesign d in PebbleReadyDesign.values) {
        expect(d.label, isNotEmpty);
      }
      for (int i = 0; i < PebbleStamps.count; i++) {
        expect(PebbleStamps.label(i), isNotEmpty);
      }
    });

    test('the ready designs refer to the stamps they mean', () {
      PebbleStampCategory of(int id) => PebbleStamps.all[id].category;
      expect(of(PebbleStampIds.cat), PebbleStampCategory.animals);
      expect(of(PebbleStampIds.whale), PebbleStampCategory.animals);
      expect(of(PebbleStampIds.butterfly), PebbleStampCategory.insects);
      expect(of(PebbleStampIds.ladybird), PebbleStampCategory.insects);
      expect(of(PebbleStampIds.bee), PebbleStampCategory.insects);
      expect(of(PebbleStampIds.daisy), PebbleStampCategory.flowers);
      expect(of(PebbleStampIds.fivePetals), PebbleStampCategory.flowers);
      expect(of(PebbleStampIds.fern), PebbleStampCategory.leaves);
      expect(of(PebbleStampIds.twig), PebbleStampCategory.leaves);
      expect(of(PebbleStampIds.star), PebbleStampCategory.stars);
      expect(of(PebbleStampIds.sparkles), PebbleStampCategory.stars);
      expect(of(PebbleStampIds.heart), PebbleStampCategory.hearts);
      expect(of(PebbleStampIds.smile), PebbleStampCategory.faces);
      expect(of(PebbleStampIds.sun), PebbleStampCategory.weather);
      expect(of(PebbleStampIds.moon), PebbleStampCategory.weather);
      expect(of(PebbleStampIds.strawberry), PebbleStampCategory.food);
      expect(of(PebbleStampIds.mushroom), PebbleStampCategory.food);
      expect(of(PebbleStampIds.circle), PebbleStampCategory.geometric);
      expect(of(PebbleStampIds.spiral), PebbleStampCategory.geometric);
      expect(PebbleStamps.all[PebbleStampIds.spiral + 1].glyph, isNull);
    });

    test('every stamp and pattern draws without an error', () {
      final ui.PictureRecorder rec = ui.PictureRecorder();
      final ui.Canvas canvas = ui.Canvas(rec);
      for (int i = 0; i < PebbleStamps.count; i++) {
        PebbleStamps.paint(canvas, i);
        PebbleStamps.paint(
          canvas,
          i,
          main: const ui.Color(0xFF3E8EEA),
          ink: const ui.Color(0xFF000000),
        );
      }
      for (final PebblePattern p in PebblePattern.values) {
        p.paint(
          canvas,
          extent: 1.1,
          colour: const ui.Color(0xFFFFFFFF),
          colour2: const ui.Color(0xFF000000),
          cell: 0.3,
          angle: 0.5,
          seed: 3,
        );
      }
      rec.endRecording().dispose();
    });
  });

  group('encoding', () {
    test('every kind of step reads back exactly', () {
      final PebbleDesign d = _everything();
      final Uint8List bytes = d.encode();
      expect(bytes.length, d.encodedLength);
      final PebbleDesign back = PebbleDesign.decode(bytes);
      expect(back.encode(), bytes);
      expect(back, d);
      expect(back.ops.length, d.ops.length);
      final PebbleTextOp text = back.ops[6] as PebbleTextOp;
      expect(text.text, 'Zażółć gęślą jaźń 🙂');
      expect(text.curve, -100);
      final PebbleStroke spray = back.ops[1] as PebbleStroke;
      expect(spray.points, <int>[0, 0, 4095, 4095, 4000, 10]);
      expect(spray.mirror, isTrue);
      expect(spray.tool, PebbleStrokeTool.spray);
      expect(back.seed, 0xDEADBEEF);
      expect(back.width, -40);
    });

    test('is deterministic and compact', () {
      final PebbleDesign d = PebbleReadyDesign.ladybird.build();
      expect(d.encode(), PebbleReadyDesign.ladybird.build().encode());
      // A 200-point stroke takes about two bytes a point.
      final int one = PebbleDesign.stone().withOp(_stroke(200)).encodedLength;
      expect(one, lessThan(18 + 10 + 4 + 199 * 2 + 1));
    });

    test('every ready design and many random ones read back', () {
      for (final PebbleReadyDesign r in PebbleReadyDesign.values) {
        final PebbleDesign d = r.build();
        final Uint8List bytes = d.encode();
        expect(PebbleDesign.decode(bytes).encode(), bytes, reason: r.name);
        expect(bytes.length, lessThan(PebbleDesign.maxBytes));
      }
      for (int seed = 0; seed < 60; seed++) {
        final PebbleDesign d = pebbleRandomDesign(seed);
        expect(d.encode(), pebbleRandomDesign(seed).encode());
        expect(PebbleDesign.decode(d.encode()), d);
      }
      expect(pebbleRandomDesign(1), isNot(pebbleRandomDesign(2)));
    });

    test('stays under 64 KB: canAdd says no before the cap', () {
      PebbleDesign d = PebbleDesign.stone();
      int i = 0;
      while (true) {
        final PebbleStroke s = _stroke(500, seed: i++);
        if (!d.canAdd(s)) {
          break;
        }
        d = d.withOp(s);
      }
      final Uint8List bytes = d.encode();
      expect(bytes.length, d.encodedLength);
      expect(bytes.length, lessThanOrEqualTo(PebbleDesign.maxBytes));
      expect(bytes.length, greaterThan(PebbleDesign.maxBytes - 1100));
      expect(PebbleDesign.decode(bytes), d);
      // Forcing one more past the cap refuses to encode.
      expect(() => d.withOp(_stroke(1500)).encode(), throwsStateError);
    });

    test('rejects what is not a design', () {
      final Uint8List good = _everything().encode();
      expect(() => PebbleDesign.decode(Uint8List(0)), throwsFormatException);
      expect(
        () =>
            PebbleDesign.decode(Uint8List.fromList(<int>[2, ...good.skip(1)])),
        throwsFormatException,
      );
      expect(
        () => PebbleDesign.decode(
          Uint8List.sublistView(good, 0, good.length - 1),
        ),
        throwsFormatException,
      );
      expect(
        () => PebbleDesign.decode(Uint8List.fromList(<int>[...good, 0])),
        throwsFormatException,
      );
      expect(
        () => PebbleDesign.decode(Uint8List(PebbleDesign.maxBytes + 1)),
        throwsFormatException,
      );
      final Uint8List badStamp = PebbleDesign.stone()
          .withOp(const PebbleStampOp(stamp: 0, face: 0, s: 0, t: 0, size: 9))
          .encode();
      badStamp[18 + 2] = 0xFF;
      badStamp[18 + 3] = 0xFF;
      expect(() => PebbleDesign.decode(badStamp), throwsFormatException);
      expect(
        PebbleDesign.tryDecode(Uint8List.fromList(<int>[1, 2, 3])),
        isNull,
      );
      expect(PebbleDesign.tryDecode(null), isNull);
    });
  });

  group('card look and thumbnail format', () {
    test('the look is the card format\'s 12 bytes', () {
      const PebbleCardLook look = PebbleCardLook(
        shape: 21,
        seed: 0xA1B2C3D4,
        material: 39,
        mainColour: 0x123456,
        secondColour: 0xABCDEF,
      );
      final Uint8List bytes = look.toBytes();
      expect(bytes, <int>[
        21,
        0xA1,
        0xB2,
        0xC3,
        0xD4,
        39,
        0x12,
        0x34,
        0x56,
        0xAB,
        0xCD,
        0xEF,
      ]);
      expect(PebbleCardLook.fromBytes(bytes), look);
      expect(
        PebbleCardLook.fromBytes(Uint8List.fromList(<int>[9, ...bytes]), 1),
        look,
      );
      expect(
        PebbleReadyDesign.bee.build().look.shape,
        PebbleShapePreset.egg.index,
      );
    });

    test('thumbnail bytes: 16 colours, 16×16 nibbles, 176 bytes', () {
      final List<int> pixels = List<int>.generate(256, (int i) => i % 16);
      final Uint8List t = PebbleThumbnail.encode(
        List<int>.generate(15, (int i) => 0x010203 * (i + 1)),
        pixels,
      );
      expect(t.length, 176);
      expect(t.sublist(0, 3), <int>[0, 0, 0]);
      expect(t[48], (0 << 4) | 1);
      final Uint32List px = PebbleThumbnail.decode(t)!;
      expect(px[0], 0);
      expect(px[1], 0xFF010203);
      expect(px[15], 0xFF000000 | (0x010203 * 15));
      expect(PebbleThumbnail.decode(Uint8List(175)), isNull);
    });
  });

  group('faces', () {
    final Float64List a = Float64List(3);
    final Float64List b = Float64List(3);

    test('unfolding across an edge lands on the same point of the stone', () {
      for (int f = 0; f < 6; f++) {
        for (final int g in PebbleFaces.neighbours(f)) {
          final Affine2 m = PebbleFaces.unfold(f, g);
          // Points on the shared edge (where f's coordinate towards g is 1).
          for (double k = -0.9; k <= 0.9; k += 0.3) {
            for (final (double s, double t) in <(double, double)>[
              (1, k),
              (-1, k),
              (k, 1),
              (k, -1),
            ]) {
              final (double gs, double gt) = m.apply(s, t);
              if (gs.abs() > 1.0001 || gt.abs() > 1.0001) {
                continue; // That edge borders another face.
              }
              PebbleFaces.direction(f, s, t, a);
              PebbleFaces.direction(g, gs, gt, b);
              expect(a[0], closeTo(b[0], 1e-9));
              expect(a[1], closeTo(b[1], 1e-9));
              expect(a[2], closeTo(b[2], 1e-9));
            }
          }
          // Folding back undoes it.
          final Affine2 back = PebbleFaces.unfold(g, f).after(m);
          expect(back.apply(0.3, -0.2).$1, closeTo(0.3, 1e-9));
          expect(back.apply(0.3, -0.2).$2, closeTo(-0.2, 1e-9));
        }
      }
    });

    test('the mirror sends a point to its mirror image', () {
      for (int f = 0; f < 6; f++) {
        final (int g, Affine2 m) = PebbleFaces.mirror(f);
        PebbleFaces.direction(f, 0.4, -0.7, a);
        final (double s, double t) = m.apply(0.4, -0.7);
        PebbleFaces.direction(g, s, t, b);
        expect(b[0], closeTo(-a[0], 1e-9));
        expect(b[1], closeTo(a[1], 1e-9));
        expect(b[2], closeTo(a[2], 1e-9));
      }
    });

    test('locate is the inverse of direction', () {
      for (int f = 0; f < 6; f++) {
        PebbleFaces.direction(f, 0.25, -0.6, a);
        final (int g, double s, double t) = PebbleFaces.locate(
          a[0],
          a[1],
          a[2],
        );
        expect(g, f);
        expect(s, closeTo(0.25, 1e-9));
        expect(t, closeTo(-0.6, 1e-9));
      }
    });
  });
}
