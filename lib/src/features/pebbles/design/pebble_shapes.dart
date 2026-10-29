import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// How a stone shape is built: a superellipsoid (radii and roundness)
/// pushed about by smooth noise and a few deformations. Everything is a
/// function of the direction from the stone's middle, so the surface
/// stays closed whatever the numbers.
@immutable
final class PebbleShapeParams {
  const PebbleShapeParams({
    this.ax = 1,
    this.ay = 0.55,
    this.az = 0.8,
    this.e1 = 1,
    this.e2 = 1,
    this.noise = 0.04,
    this.noiseFreq = 1.6,
    this.rough = 0,
    this.taper = 0,
    this.egg = 0,
    this.heart = 0,
    this.lobes = 0,
    this.lobeCount = 0,
    this.waist = 0,
    this.bend = 0,
    this.dent = 0,
    this.flatBottom = 0,
  });

  /// Radii across (x), up (y) and along (z).
  final double ax;
  final double ay;
  final double az;

  /// Roundness top-to-bottom and around: 1 is an ellipsoid, below 1 boxier,
  /// above 1 pinched towards a diamond.
  final double e1;
  final double e2;

  /// Smooth bumps (fraction of the radius) and their frequency.
  final double noise;
  final double noiseFreq;

  /// Fine, rocky bumps.
  final double rough;

  /// The top narrower than the bottom.
  final double taper;

  /// One end fatter than the other (along x).
  final double egg;

  /// A heart outline seen from above.
  final double heart;

  /// Soft lobes around the stone seen from above.
  final double lobes;
  final int lobeCount;

  /// A waist in the middle (a peanut).
  final double waist;

  /// Bent like a bean.
  final double bend;

  /// A hollow in the top.
  final double dent;

  /// The bottom squashed flat.
  final double flatBottom;
}

/// The stone shapes on offer. The index is stored in designs and cards:
/// add new shapes at the end only.
enum PebbleShapePreset {
  river(PebbleShapeParams(e1: 0.9, noise: 0.05)),
  skipping(PebbleShapeParams(ay: 0.28, az: 0.85, e1: 0.8, noise: 0.03)),
  egg(PebbleShapeParams(ay: 0.72, az: 0.72, egg: 0.25, noise: 0.02)),
  heart(PebbleShapeParams(ay: 0.45, az: 1, e1: 0.85, heart: 1, noise: 0.02)),
  tall(PebbleShapeParams(ax: 0.6, ay: 1, az: 0.62, taper: 0.15)),
  wide(PebbleShapeParams(ay: 0.45, az: 1, e2: 0.9, noise: 0.03)),
  dented(PebbleShapeParams(ay: 0.6, e1: 0.9, dent: 0.22, noise: 0.04)),
  bean(PebbleShapeParams(ay: 0.5, az: 0.55, bend: 0.35, noise: 0.03)),
  triangle(PebbleShapeParams(ay: 0.45, az: 1, lobes: 0.16, lobeCount: 3)),
  pillow(PebbleShapeParams(ay: 0.5, az: 1, e1: 0.6, e2: 0.5, noise: 0.02)),
  disc(PebbleShapeParams(ay: 0.22, az: 1, e1: 0.5, noise: 0.015)),
  lens(PebbleShapeParams(ay: 0.36, az: 1, e1: 1.6, noise: 0.015)),
  pear(PebbleShapeParams(ax: 1, ay: 0.7, az: 0.75, egg: 0.4, taper: 0.05)),
  potato(PebbleShapeParams(ay: 0.65, noise: 0.12, noiseFreq: 1.2)),
  rock(
    PebbleShapeParams(
      ax: 0.9,
      ay: 0.7,
      az: 0.85,
      e1: 0.7,
      e2: 0.7,
      noise: 0.08,
      rough: 0.035,
    ),
  ),
  cigar(PebbleShapeParams(ay: 0.38, az: 0.45, noise: 0.03)),
  cushion(PebbleShapeParams(az: 0.9, e1: 0.55, e2: 0.8, flatBottom: 0.3)),
  teardrop(PebbleShapeParams(ay: 0.5, az: 0.7, egg: 0.5, noise: 0.02)),
  chubby(PebbleShapeParams(ax: 0.8, ay: 0.8, az: 0.8, e1: 0.45, noise: 0.03)),
  beach(PebbleShapeParams(ay: 0.5, az: 0.7, noise: 0.07, egg: 0.12, bend: 0.1)),
  crescent(PebbleShapeParams(ay: 0.42, az: 0.6, bend: 0.65, noise: 0.02)),
  dome(PebbleShapeParams(ay: 0.62, az: 1, flatBottom: 0.7, noise: 0.03)),
  star(PebbleShapeParams(ay: 0.4, az: 1, lobes: 0.17, lobeCount: 5)),
  peanut(PebbleShapeParams(ay: 0.5, az: 0.62, waist: 0.38, noise: 0.03)),
  palm(PebbleShapeParams(ay: 0.4, az: 0.7, e1: 1.1, noise: 0.03)),
  dice(
    PebbleShapeParams(
      ax: 0.85,
      ay: 0.85,
      az: 0.85,
      e1: 0.35,
      e2: 0.35,
      noise: 0.025,
    ),
  ),
  clover(PebbleShapeParams(ay: 0.42, az: 1, lobes: 0.14, lobeCount: 4)),
  plump(PebbleShapeParams(ay: 0.75, az: 0.9, e1: 0.8, noise: 0.05));

  const PebbleShapePreset(this.params);

  final PebbleShapeParams params;

  static PebbleShapePreset byId(int id) =>
      id >= 0 && id < values.length ? values[id] : river;

  String get label => switch (this) {
    river => t('Okrągły z rzeki'),
    skipping => t('Płaski do puszczania kaczek'),
    egg => t('Jajko'),
    heart => t('Serce'),
    tall => t('Wysoki'),
    wide => t('Szeroki'),
    dented => t('Z wgłębieniem'),
    bean => t('Fasolka'),
    triangle => t('Trójkątny'),
    pillow => t('Poduszka'),
    disc => t('Krążek'),
    lens => t('Soczewka'),
    pear => t('Gruszka'),
    potato => t('Ziemniak'),
    rock => t('Skała'),
    cigar => t('Podłużny'),
    cushion => t('Pufa'),
    teardrop => t('Kropla'),
    chubby => t('Pękaty'),
    beach => t('Plażowy'),
    crescent => t('Rogalik'),
    dome => t('Kopułka'),
    star => t('Gwiazdka'),
    peanut => t('Orzeszek'),
    palm => t('Na dłoń'),
    dice => t('Kostka'),
    clover => t('Koniczyna'),
    plump => t('Pulchny'),
  };
}
