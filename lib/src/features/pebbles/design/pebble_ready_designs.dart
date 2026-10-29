import 'dart:math' as math;
import 'dart:typed_data';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/design/pebble_paths.dart';
import 'package:zen/src/features/pebbles/design/pebble_patterns.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';
import 'package:zen/src/features/pebbles/design/pebble_stamps.dart';

/// Stamps the ready designs use, by their place in [PebbleStamps.all].
abstract final class PebbleStampIds {
  static const int cat = 0;
  static const int owl = 2;
  static const int fish = 3;
  static const int turtle = 5;
  static const int fox = 7;
  static const int penguin = 11;
  static const int hedgehog = 13;
  static const int whale = 14;
  static const int butterfly = 16;
  static const int ladybird = 18;
  static const int bee = 19;
  static const int daisy = 25;
  static const int sunflower = 28;
  static const int fivePetals = 29;
  static const int fern = 39;
  static const int clover = 40;
  static const int twig = 42;
  static const int star = 45;
  static const int sparkle = 47;
  static const int shootingStar = 49;
  static const int sparkles = 51;
  static const int heart = 53;
  static const int heartOutline = 54;
  static const int smile = 59;
  static const int sun = 69;
  static const int cloud = 70;
  static const int rainbow = 74;
  static const int moon = 75;
  static const int strawberry = 80;
  static const int mushroom = 84;
  static const int circle = 90;
  static const int ring = 91;
  static const int triangle = 92;
  static const int spiral = 98;
}

/// Builds a design step by step in plain numbers (face units, radians).
final class PebbleSketch {
  PebbleSketch(this.design);

  PebbleDesign design;
  final List<PebbleOp> _ops = <PebbleOp>[];

  PebbleDesign build() => design.copyWith(
    ops: List<PebbleOp>.unmodifiable(<PebbleOp>[...design.ops, ..._ops]),
  );

  void fill(PebbleFace f, int colour) =>
      _ops.add(PebbleFaceFill(face: f.index, colour: colour));

  void fillAll(List<PebbleFace> faces, int colour) {
    for (final PebbleFace f in faces) {
      fill(f, colour);
    }
  }

  void pattern(
    PebbleFace f,
    PebblePattern p,
    int colour, {
    int colour2 = 0,
    int scale = 48,
    double angle = 0,
  }) => _ops.add(
    PebblePatternOp(
      face: f.index,
      pattern: p.index,
      colour: colour,
      colour2: colour2,
      scale: scale,
      angle: _angle(angle),
    ),
  );

  void patternAll(
    List<PebbleFace> faces,
    PebblePattern p,
    int colour, {
    int colour2 = 0,
    int scale = 48,
    double angle = 0,
  }) {
    for (final PebbleFace f in faces) {
      pattern(f, p, colour, colour2: colour2, scale: scale, angle: angle);
    }
  }

  void stamp(
    PebbleFace f,
    int id,
    double s,
    double t,
    double half, {
    double angle = 0,
    int colour = 0,
    int ink = 0,
    bool mirror = false,
    bool flip = false,
  }) => _ops.add(
    PebbleStampOp(
      stamp: id,
      face: f.index,
      s: PebbleQ.of(s),
      t: PebbleQ.of(t),
      size: (half * 200).round().clamp(1, 255),
      angle: _angle(angle),
      colour: colour,
      ink: ink,
      mirror: mirror,
      flip: flip,
    ),
  );

  void line(
    PebbleFace f,
    List<double> st,
    int colour,
    double radius, {
    bool mirror = false,
    PebbleStrokeTool tool = PebbleStrokeTool.brush,
  }) => _ops.add(
    PebbleStroke(
      tool: tool,
      colour: colour,
      size: (radius * 256).round().clamp(1, 255),
      face: f.index,
      points: Uint16List.fromList(<int>[
        for (final double v in st) PebbleQ.of(v),
      ]),
      mirror: mirror,
    ),
  );

  void dot(
    PebbleFace f,
    double s,
    double t,
    double radius,
    int colour, {
    bool mirror = false,
  }) => line(f, <double>[s, t], colour, radius, mirror: mirror);

  void text(
    PebbleFace f,
    double s,
    double t,
    String text,
    int colour,
    double height, {
    int curve = 0,
    int font = 0,
    double angle = 0,
  }) => _ops.add(
    PebbleTextOp(
      face: f.index,
      s: PebbleQ.of(s),
      t: PebbleQ.of(t),
      size: (height * 200).round().clamp(1, 255),
      text: text,
      colour: colour,
      curve: curve,
      font: font,
      angle: _angle(angle),
    ),
  );

  void region(PebbleFace f, double s, double t, int colour) => _ops.add(
    PebbleRegionFill(
      face: f.index,
      s: PebbleQ.of(s),
      t: PebbleQ.of(t),
      colour: colour,
    ),
  );

  /// A band around the four sides at height [t].
  void band(double t, int colour, double radius) {
    for (final PebbleFace f in _sides) {
      line(f, <double>[-1.05, t, 1.05, t], colour, radius);
    }
  }

  static int _angle(double radians) =>
      ((radians / (2 * math.pi)) * 256).round() & 0xFF;
}

const List<PebbleFace> _sides = <PebbleFace>[
  PebbleFace.front,
  PebbleFace.right,
  PebbleFace.back,
  PebbleFace.left,
];

const List<PebbleFace> _all = PebbleFace.values;

PebbleDesign _stone(
  PebbleShapePreset shape,
  PebbleMaterial material, {
  int seed = 7,
}) => PebbleDesign.stone(
  shape: shape.index,
  seed: seed,
  material: material.index,
);

/// The complete designs offered ready to use.
enum PebbleReadyDesign {
  ladybird,
  watermelon,
  planet,
  owl,
  cat,
  flower,
  rainbow,
  bee,
  galaxy,
  seaGlass,
  mandala,
  turtle,
  strawberry,
  penguin,
  moon,
  sun,
  butterfly,
  heart,
  fish,
  fox,
  hedgehog,
  smiley,
  polka,
  ocean,
  forest,
  mushroom;

  String get label => switch (this) {
    ladybird => t('Biedronka'),
    watermelon => t('Arbuz'),
    planet => t('Planeta'),
    owl => t('Sowa'),
    cat => t('Kot'),
    flower => t('Kwiat'),
    rainbow => t('Tęcza'),
    bee => t('Pszczoła'),
    galaxy => t('Galaktyka'),
    seaGlass => t('Morskie szkło'),
    mandala => t('Mandala'),
    turtle => t('Żółw'),
    strawberry => t('Truskawka'),
    penguin => t('Pingwin'),
    moon => t('Księżyc'),
    sun => t('Słońce'),
    butterfly => t('Motyl'),
    heart => t('Serce'),
    fish => t('Rybka'),
    fox => t('Lis'),
    hedgehog => t('Jeż'),
    smiley => t('Uśmiech'),
    polka => t('Groszki'),
    ocean => t('Ocean'),
    forest => t('Las'),
    mushroom => t('Muchomor'),
  };

  PebbleDesign build() {
    switch (this) {
      case ladybird:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.dome, PebbleMaterial.glossRed),
        );
        k
          ..fill(PebbleFace.front, 0xFF1A1A1A)
          ..fill(PebbleFace.bottom, 0xFF1A1A1A)
          ..dot(PebbleFace.front, -0.35, 0.15, 0.13, 0xFFFFFFFF)
          ..dot(PebbleFace.front, 0.35, 0.15, 0.13, 0xFFFFFFFF)
          ..line(PebbleFace.top, <double>[0, 1.3, 0, -1.3], 0xFF1A1A1A, 0.035)
          ..line(PebbleFace.back, <double>[0, 1.2, 0, -0.6], 0xFF1A1A1A, 0.035);
        for (final (double s, double t, double r) in <(double, double, double)>[
          (-0.5, 0.45, 0.17),
          (-0.55, -0.25, 0.15),
          (-0.25, -0.7, 0.12),
          (-0.25, 0.05, 0.11),
        ]) {
          k.stamp(
            PebbleFace.top,
            PebbleStampIds.circle,
            s,
            t,
            r,
            colour: 0xFF1A1A1A,
            mirror: true,
          );
        }
        k
          ..stamp(
            PebbleFace.right,
            PebbleStampIds.circle,
            0.1,
            0.2,
            0.18,
            colour: 0xFF1A1A1A,
            mirror: true,
          )
          ..stamp(
            PebbleFace.back,
            PebbleStampIds.circle,
            -0.5,
            0.1,
            0.14,
            colour: 0xFF1A1A1A,
            mirror: true,
          );
        return k.build();
      case watermelon:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.egg, PebbleMaterial.glossGreen),
        );
        k.patternAll(
          <PebbleFace>[PebbleFace.top, ..._sides],
          PebblePattern.waves,
          0xFF145A2A,
          scale: 40,
          angle: math.pi / 2,
        );
        k
          ..fill(PebbleFace.bottom, 0xFFF4F1D0)
          ..stamp(
            PebbleFace.bottom,
            PebbleStampIds.circle,
            0,
            0,
            0.92,
            colour: 0xFFFF4D5E,
          );
        for (final (double s, double t) in <(double, double)>[
          (-0.4, 0.3),
          (0.0, 0.5),
          (0.4, 0.25),
          (-0.2, -0.2),
          (0.25, -0.35),
          (-0.5, -0.45),
          (0.55, -0.1),
        ]) {
          k.stamp(
            PebbleFace.bottom,
            PebbleStampIds.circle,
            s,
            t,
            0.05,
            colour: 0xFF1A1A1A,
          );
        }
        return k.build();
      case planet:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.chubby, PebbleMaterial.glossOrange),
        );
        k.patternAll(
          _all,
          PebblePattern.waves,
          0xFFFFC27A,
          colour2: 0xFFC0531A,
          scale: 70,
        );
        k
          ..band(0.0, 0xFFF3E3C3, 0.09)
          ..band(-0.12, 0xFF7A3F1A, 0.025)
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.sparkle,
            -0.6,
            0.6,
            0.12,
            colour: 0xFFFFFFFF,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.circle,
            0.35,
            -0.3,
            0.2,
            colour: 0xFFA8461A,
          );
        return k.build();
      case owl:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.pear, PebbleMaterial.brownRiver),
        );
        k
          ..patternAll(
            _sides,
            PebblePattern.scales,
            0xFF5A3A20,
            colour2: 0xFFB08A63,
            scale: 36,
          )
          ..stamp(PebbleFace.top, PebbleStampIds.owl, 0, 0, 0.95)
          ..fill(PebbleFace.bottom, 0xFF5A3A20);
        return k.build();
      case cat:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.river, PebbleMaterial.pastelPeach),
        );
        k
          ..patternAll(
            _sides,
            PebblePattern.zigzag,
            0xFFE07B2E,
            scale: 44,
            angle: math.pi / 2,
          )
          ..stamp(PebbleFace.top, PebbleStampIds.cat, 0, 0, 0.92)
          ..fill(PebbleFace.bottom, 0xFFFFFFFF)
          ..stamp(
            PebbleFace.bottom,
            PebbleStampIds.heart,
            0,
            0,
            0.4,
            colour: 0xFFFF7A9C,
          );
        return k.build();
      case flower:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.wide, PebbleMaterial.pastelMint),
        );
        k
          ..patternAll(
            _sides,
            PebblePattern.flowers,
            0xFFFFFFFF,
            colour2: 0xFFFFD21F,
            scale: 30,
          )
          ..stamp(PebbleFace.top, PebbleStampIds.daisy, 0, 0, 0.85)
          ..stamp(PebbleFace.bottom, PebbleStampIds.fivePetals, 0, 0, 0.6);
        return k.build();
      case rainbow:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.river, PebbleMaterial.glossWhite),
        );
        const List<int> bands = <int>[
          0xFFE5243B,
          0xFFFF7F11,
          0xFFFFD21F,
          0xFF6BCB3B,
          0xFF3E8EEA,
          0xFF9B5DE5,
        ];
        for (int i = 0; i < bands.length; i++) {
          k.band(0.75 - i * 0.3, bands[i], 0.08);
        }
        k
          ..stamp(PebbleFace.top, PebbleStampIds.rainbow, 0, 0.1, 0.85)
          ..stamp(PebbleFace.top, PebbleStampIds.cloud, -0.55, -0.45, 0.32)
          ..stamp(PebbleFace.top, PebbleStampIds.cloud, 0.6, -0.5, 0.28);
        return k.build();
      case bee:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.egg, PebbleMaterial.glossYellow),
        );
        for (final PebbleFace f in <PebbleFace>[
          PebbleFace.top,
          PebbleFace.front,
          PebbleFace.bottom,
          PebbleFace.back,
        ]) {
          for (final double s in <double>[-0.35, 0.25, 0.85]) {
            k.line(f, <double>[s, -1.3, s, 1.3], 0xFF1A1A1A, 0.11);
          }
        }
        k
          ..fill(PebbleFace.right, 0xFF1A1A1A)
          ..dot(PebbleFace.right, -0.35, 0.2, 0.14, 0xFFFFFFFF)
          ..dot(PebbleFace.right, 0.35, 0.2, 0.14, 0xFFFFFFFF)
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.cloud,
            -0.45,
            0.45,
            0.42,
            colour: 0xCCFFFFFF,
            ink: 0x99B0BEC5,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.cloud,
            -0.45,
            -0.45,
            0.42,
            colour: 0xCCFFFFFF,
            ink: 0x99B0BEC5,
          );
        return k.build();
      case galaxy:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.river, PebbleMaterial.nightSky, seed: 11),
        );
        k
          ..line(
            PebbleFace.top,
            <double>[-1.1, -0.6, -0.3, -0.1, 0.4, 0.2, 1.1, 0.7],
            0xFFB06BFF,
            0.22,
            tool: PebbleStrokeTool.spray,
          )
          ..line(
            PebbleFace.top,
            <double>[-1.0, -0.3, 0.0, 0.1, 1.0, 0.4],
            0xFFFF7AD9,
            0.14,
            tool: PebbleStrokeTool.spray,
          )
          ..patternAll(
            _all,
            PebblePattern.stars,
            0xCCFFFFFF,
            scale: 70,
            angle: 0.4,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.spiral,
            0.1,
            0.05,
            0.38,
            colour: 0xFFE9D8FF,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.sparkles,
            -0.6,
            0.55,
            0.25,
            colour: 0xFFFFF09A,
            ink: 0xFFFFFFFF,
          )
          ..stamp(PebbleFace.front, PebbleStampIds.shootingStar, 0, 0, 0.45);
        return k.build();
      case seaGlass:
        final PebbleSketch k = PebbleSketch(
          _stone(
            PebbleShapePreset.skipping,
            PebbleMaterial.seaGlassGreen,
            seed: 3,
          ),
        );
        k
          ..pattern(PebbleFace.top, PebblePattern.waves, 0x55FFFFFF, scale: 50)
          ..line(
            PebbleFace.top,
            <double>[-0.6, 0.4, 0.5, -0.3],
            0x88FFFFFF,
            0.18,
            tool: PebbleStrokeTool.spray,
          );
        return k.build();
      case mandala:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.wide, PebbleMaterial.glossBlack),
        );
        k
          ..pattern(
            PebbleFace.top,
            PebblePattern.mandala,
            0xFFFFFFFF,
            colour2: 0xFFD4A93A,
            scale: 26,
          )
          ..patternAll(_sides, PebblePattern.dots, 0xFFD4A93A, scale: 22)
          ..pattern(
            PebbleFace.bottom,
            PebblePattern.rings,
            0xFFFFFFFF,
            colour2: 0xFFD4A93A,
            scale: 30,
          );
        return k.build();
      case turtle:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.dome, PebbleMaterial.greenMarble),
        );
        k
          ..stamp(PebbleFace.top, PebbleStampIds.turtle, 0, 0, 0.95)
          ..patternAll(_sides, PebblePattern.triangles, 0xFF2E6B47, scale: 30)
          ..fill(PebbleFace.bottom, 0xFFDCE8DF);
        return k.build();
      case strawberry:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.teardrop, PebbleMaterial.glossRed),
        );
        k
          ..patternAll(
            <PebbleFace>[
              PebbleFace.top,
              PebbleFace.bottom,
              PebbleFace.front,
              PebbleFace.back,
              PebbleFace.right,
            ],
            PebblePattern.dots,
            0xFFFFE066,
            scale: 26,
          )
          ..fill(PebbleFace.left, 0xFF2E8B3E)
          ..stamp(PebbleFace.top, PebbleStampIds.strawberry, 0.1, 0, 0.5);
        for (int i = 0; i < 6; i++) {
          final double a = i * math.pi / 3;
          k.line(
            PebbleFace.left,
            <double>[0, 0, math.cos(a) * 1.25, math.sin(a) * 1.25],
            0xFF2E8B3E,
            0.18,
          );
        }
        return k.build();
      case penguin:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.tall, PebbleMaterial.glossBlack),
        );
        k
          ..stamp(
            PebbleFace.front,
            PebbleStampIds.circle,
            0,
            -0.2,
            0.85,
            colour: 0xFFFFFFFF,
          )
          ..dot(PebbleFace.front, -0.3, 0.55, 0.1, 0xFFFFFFFF)
          ..dot(PebbleFace.front, 0.3, 0.55, 0.1, 0xFFFFFFFF)
          ..dot(PebbleFace.front, -0.3, 0.55, 0.05, 0xFF1A1A1A)
          ..dot(PebbleFace.front, 0.3, 0.55, 0.05, 0xFF1A1A1A)
          ..stamp(
            PebbleFace.front,
            PebbleStampIds.triangle,
            0,
            0.3,
            0.14,
            angle: math.pi,
            colour: 0xFFFF8A1F,
          )
          ..fill(PebbleFace.bottom, 0xFFFF8A1F)
          ..stamp(PebbleFace.top, PebbleStampIds.penguin, 0, 0, 0.7);
        return k.build();
      case moon:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.chubby, PebbleMaterial.greyGranite, seed: 5),
        );
        final PebbleRandom r = PebbleRandom(42);
        for (final PebbleFace f in _all) {
          for (int i = 0; i < 4; i++) {
            final double s = r.range(-0.8, 0.8),
                t = r.range(-0.8, 0.8),
                h = r.range(0.08, 0.25);
            k
              ..stamp(f, PebbleStampIds.circle, s, t, h, colour: 0x55000000)
              ..stamp(
                f,
                PebbleStampIds.ring,
                s,
                t,
                h * 1.05,
                colour: 0x66FFFFFF,
              );
          }
        }
        k.stamp(
          PebbleFace.top,
          PebbleStampIds.moon,
          0,
          0,
          0.5,
          colour: 0xFFFFF09A,
        );
        return k.build();
      case sun:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.disc, PebbleMaterial.glossYellow),
        );
        k
          ..pattern(PebbleFace.top, PebblePattern.rays, 0xFFFFB300, scale: 60)
          ..stamp(PebbleFace.top, PebbleStampIds.sun, 0, 0, 0.8)
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.smile,
            0,
            0,
            0.36,
            colour: 0xFFFFD21F,
            ink: 0xFF8A4B00,
          )
          ..patternAll(_sides, PebblePattern.zigzag, 0xFFFF7F11, scale: 30)
          ..fill(PebbleFace.bottom, 0xFFFF7F11);
        return k.build();
      case butterfly:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.river, PebbleMaterial.pastelLavender),
        );
        k
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.butterfly,
            0,
            0,
            0.9,
            colour: 0xFF9B5DE5,
          )
          ..patternAll(
            _sides,
            PebblePattern.flowers,
            0xFFFFFFFF,
            colour2: 0xFFFF7A9C,
            scale: 28,
          )
          ..stamp(PebbleFace.bottom, PebbleStampIds.butterfly, 0, 0, 0.5);
        return k.build();
      case heart:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.heart, PebbleMaterial.glossRed),
        );
        k
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.heartOutline,
            0,
            0,
            0.6,
            colour: 0xFFFFFFFF,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.heart,
            0,
            0.02,
            0.3,
            colour: 0xFFFF9FB5,
          )
          ..patternAll(
            _sides,
            PebblePattern.hearts,
            0xFFFF9FB5,
            colour2: 0xFFFFFFFF,
            scale: 26,
          )
          ..fill(PebbleFace.bottom, 0xFFFFD6DE);
        return k.build();
      case fish:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.cigar, PebbleMaterial.glossBlue),
        );
        k
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.fish,
            0,
            0,
            0.8,
            colour: 0xFFFF7F11,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.ring,
            -0.7,
            0.55,
            0.1,
            colour: 0xAAFFFFFF,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.ring,
            -0.85,
            0.25,
            0.07,
            colour: 0xAAFFFFFF,
          )
          ..patternAll(_sides, PebblePattern.waves, 0xFF8ECAE6, scale: 30)
          ..pattern(
            PebbleFace.bottom,
            PebblePattern.bubbles,
            0xFFAED8FF,
            scale: 50,
          );
        return k.build();
      case fox:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.triangle, PebbleMaterial.glossOrange),
        );
        k
          ..stamp(PebbleFace.top, PebbleStampIds.fox, 0, 0.05, 0.9)
          ..fill(PebbleFace.bottom, 0xFFFFFFFF)
          ..patternAll(
            _sides,
            PebblePattern.leaves,
            0xFFC05A0A,
            colour2: 0xFFFFB27A,
            scale: 34,
          );
        return k.build();
      case hedgehog:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.dome, PebbleMaterial.brownRiver, seed: 9),
        );
        k
          ..patternAll(
            <PebbleFace>[
              PebbleFace.top,
              PebbleFace.back,
              PebbleFace.left,
              PebbleFace.right,
            ],
            PebblePattern.zigzag,
            0xFF3E2723,
            scale: 22,
            angle: 0.5,
          )
          ..fill(PebbleFace.front, 0xFFE0C29A)
          ..dot(PebbleFace.front, -0.3, 0.2, 0.09, 0xFF1A1A1A)
          ..dot(PebbleFace.front, 0.3, 0.2, 0.09, 0xFF1A1A1A)
          ..dot(PebbleFace.front, 0, -0.15, 0.12, 0xFF1A1A1A)
          ..stamp(PebbleFace.top, PebbleStampIds.hedgehog, 0, 0, 0.55);
        return k.build();
      case smiley:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.plump, PebbleMaterial.glossYellow),
        );
        k
          ..dot(PebbleFace.front, -0.35, 0.3, 0.13, 0xFF3A2A1A)
          ..dot(PebbleFace.front, 0.35, 0.3, 0.13, 0xFF3A2A1A)
          ..line(
            PebbleFace.front,
            <double>[
              -0.55,
              -0.1,
              -0.3,
              -0.42,
              0,
              -0.52,
              0.3,
              -0.42,
              0.55,
              -0.1,
            ],
            0xFF3A2A1A,
            0.06,
          )
          ..dot(PebbleFace.front, -0.62, -0.05, 0.12, 0x88FF7A9C)
          ..dot(PebbleFace.front, 0.62, -0.05, 0.12, 0x88FF7A9C)
          ..text(PebbleFace.top, 0, 0, 'HEJ!', 0xFFE5243B, 0.42, curve: 40)
          ..pattern(
            PebbleFace.bottom,
            PebblePattern.confetti,
            0xFFFF7A9C,
            colour2: 0xFF3E8EEA,
            scale: 40,
          );
        return k.build();
      case polka:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.pillow, PebbleMaterial.glossWhite),
        );
        k.patternAll(_all, PebblePattern.dots, 0xFFE5243B, scale: 40);
        return k.build();
      case ocean:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.palm, PebbleMaterial.seaGlassBlue),
        );
        k
          ..patternAll(
            _sides,
            PebblePattern.waves,
            0xFFFFFFFF,
            colour2: 0xFF1846A8,
            scale: 32,
          )
          ..stamp(
            PebbleFace.top,
            PebbleStampIds.whale,
            0,
            0,
            0.8,
            colour: 0xFF1846A8,
          )
          ..pattern(
            PebbleFace.bottom,
            PebblePattern.bubbles,
            0xFFFFFFFF,
            scale: 40,
          );
        return k.build();
      case forest:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.beach, PebbleMaterial.greyRiver, seed: 4),
        );
        for (final PebbleFace f in _sides) {
          k
            ..stamp(f, PebbleStampIds.fern, -0.45, 0, 0.6)
            ..stamp(f, PebbleStampIds.twig, 0.45, 0.05, 0.5, angle: -0.6);
        }
        k
          ..stamp(PebbleFace.top, PebbleStampIds.clover, 0, 0, 0.6)
          ..stamp(PebbleFace.top, PebbleStampIds.mushroom, 0.6, 0.55, 0.25)
          ..text(PebbleFace.bottom, 0, 0, 'LAS', 0xFF2E8B3E, 0.4);
        return k.build();
      case mushroom:
        final PebbleSketch k = PebbleSketch(
          _stone(PebbleShapePreset.dome, PebbleMaterial.glossRed, seed: 2),
        );
        k.fill(PebbleFace.bottom, 0xFFF3EEE3);
        final PebbleRandom r = PebbleRandom(17);
        for (final PebbleFace f in <PebbleFace>[PebbleFace.top, ..._sides]) {
          for (int i = 0; i < 5; i++) {
            k.stamp(
              f,
              PebbleStampIds.circle,
              r.range(-0.8, 0.8),
              r.range(-0.8, 0.8),
              r.range(0.07, 0.17),
              colour: 0xFFFFFFFF,
            );
          }
        }
        return k.build();
    }
  }
}

/// A random, good-looking design ("Losuj"), the same for the same [seed].
PebbleDesign pebbleRandomDesign(int seed) {
  final PebbleRandom r = PebbleRandom(seed);
  final List<int> palette = r.pick(pebblePalettes);
  int colour(int i) => palette[i % palette.length];
  const List<PebbleShapePreset> shapes = <PebbleShapePreset>[
    PebbleShapePreset.river,
    PebbleShapePreset.skipping,
    PebbleShapePreset.egg,
    PebbleShapePreset.heart,
    PebbleShapePreset.wide,
    PebbleShapePreset.dented,
    PebbleShapePreset.pillow,
    PebbleShapePreset.disc,
    PebbleShapePreset.palm,
    PebbleShapePreset.dome,
    PebbleShapePreset.plump,
    PebbleShapePreset.beach,
    PebbleShapePreset.chubby,
    PebbleShapePreset.cushion,
    PebbleShapePreset.lens,
  ];
  final PebbleShapePreset shape = r.pick(shapes);
  final List<PebbleMaterial> materials = PebbleMaterial.values
      .where((PebbleMaterial m) => m.finish != PebbleFinish.metallic)
      .toList();
  final PebbleMaterial material = r.pick(materials);
  final bool ownColour = r.chance(0.6);
  final PebbleDesign stone = PebbleDesign(
    shape: shape.index,
    seed: r.nextInt32(),
    material: material.index,
    mainColour: ownColour ? colour(0) | 0xFF000000 : material.main,
    secondColour: ownColour ? colour(1) | 0xFF000000 : material.second,
  );
  final PebbleSketch k = PebbleSketch(stone);
  const List<PebbleStampCategory> motifs = <PebbleStampCategory>[
    PebbleStampCategory.animals,
    PebbleStampCategory.insects,
    PebbleStampCategory.flowers,
    PebbleStampCategory.stars,
    PebbleStampCategory.hearts,
    PebbleStampCategory.weather,
    PebbleStampCategory.food,
    PebbleStampCategory.leaves,
    PebbleStampCategory.faces,
  ];
  final List<PebblePattern> patterns = PebblePattern.values;
  switch (r.nextInt(5)) {
    case 0:
      // A motif on top, a pattern round the sides.
      final int motif = r.pick(PebbleStamps.inCategory(r.pick(motifs)));
      k.stamp(
        PebbleFace.top,
        motif,
        0,
        0,
        r.range(0.7, 0.92),
        colour: r.chance(0.5) ? 0 : colour(2),
      );
      final PebblePattern p = r.pick(
        patterns
            .where(
              (PebblePattern p) =>
                  p != PebblePattern.mandala && p != PebblePattern.rays,
            )
            .toList(),
      );
      k
        ..patternAll(
          _sides,
          p,
          colour(2),
          colour2: r.chance(0.5) ? colour(3) : 0,
          scale: 24 + r.nextInt(30),
          angle: r.range(0, math.pi),
        )
        ..fill(PebbleFace.bottom, colour(3))
        ..stamp(PebbleFace.bottom, motif, 0, 0, 0.45, colour: colour(4));
    case 1:
      // Every face its own pattern.
      for (final PebbleFace f in _all) {
        k.pattern(
          f,
          r.pick(patterns),
          colour(1 + r.nextInt(4)),
          colour2: r.chance(0.5) ? colour(r.nextInt(5)) : 0,
          scale: 20 + r.nextInt(40),
          angle: r.range(0, math.pi),
        );
      }
      k.stamp(
        PebbleFace.top,
        r.pick(PebbleStamps.inCategory(PebbleStampCategory.stars)),
        0,
        0,
        0.35,
        colour: colour(4),
      );
    case 2:
      // A mandala.
      k
        ..pattern(
          PebbleFace.top,
          PebblePattern.mandala,
          colour(2),
          colour2: colour(3),
          scale: 18 + r.nextInt(16),
        )
        ..patternAll(
          _sides,
          r.pick(<PebblePattern>[
            PebblePattern.dots,
            PebblePattern.rings,
            PebblePattern.scales,
            PebblePattern.zigzag,
          ]),
          colour(3),
          scale: 20 + r.nextInt(20),
        )
        ..pattern(
          PebbleFace.bottom,
          PebblePattern.flowers,
          colour(4),
          colour2: colour(2),
          scale: 30,
        );
    case 3:
      // Small stamps of one kind all over, mirrored.
      final List<int> kind = PebbleStamps.inCategory(r.pick(motifs));
      for (final PebbleFace f in <PebbleFace>[
        PebbleFace.top,
        PebbleFace.front,
        PebbleFace.left,
        PebbleFace.bottom,
        PebbleFace.back,
      ]) {
        for (int i = 0; i < 3; i++) {
          k.stamp(
            f,
            r.pick(kind),
            r.range(-0.75, -0.1),
            r.range(-0.7, 0.7),
            r.range(0.15, 0.3),
            angle: r.range(-0.5, 0.5),
            colour: r.chance(0.6) ? 0 : colour(2 + i),
            mirror: true,
          );
        }
      }
    default:
      // Bands round the stone and a motif on top.
      final int n = 2 + r.nextInt(3);
      for (int i = 0; i < n; i++) {
        k.band(
          0.7 - i * 1.4 / math.max(1, n - 1),
          colour(1 + i),
          r.range(0.04, 0.1),
        );
      }
      k
        ..stamp(
          PebbleFace.top,
          r.pick(PebbleStamps.inCategory(r.pick(motifs))),
          0,
          0,
          0.8,
        )
        ..pattern(PebbleFace.bottom, r.pick(patterns), colour(2), scale: 40);
  }
  return k.build();
}
