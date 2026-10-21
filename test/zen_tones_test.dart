import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// Every palette in both modes, and Klasyczny with every accent.
List<(String, ZenColors)> _allPalettes() => <(String, ZenColors)>[
  for (final AppPalette p in AppPalette.values)
    for (final Brightness b in Brightness.values)
      (
        '${p.name}/${b.name}',
        ZenColors.forPalette(p, AppSettings.defaultAccentTheme, b),
      ),
  for (final AppAccentTheme a in AppAccentTheme.values)
    for (final Brightness b in Brightness.values)
      ('classic ${a.name}/${b.name}', ZenColors.resolve(a, b)),
];

/// CIE76 colour difference (Lab, D65).
double _deltaE(Color a, Color b) {
  List<double> lab(Color c) {
    double lin(double v) =>
        v <= 0.04045 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) as double;
    final double r = lin(c.r);
    final double g = lin(c.g);
    final double bl = lin(c.b);
    final double x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047;
    final double y = 0.2126 * r + 0.7152 * g + 0.0722 * bl;
    final double z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883;
    double f(double t) =>
        t > 0.008856 ? math.pow(t, 1 / 3) as double : 7.787 * t + 16 / 116;
    return <double>[116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))];
  }

  final List<double> p = lab(a);
  final List<double> q = lab(b);
  return math.sqrt(
    math.pow(p[0] - q[0], 2) +
        math.pow(p[1] - q[1], 2) +
        math.pow(p[2] - q[2], 2),
  );
}

double _hueGap(double a, double b) {
  final double d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  test('every tone is defined in every palette', () {
    for (final (String name, ZenColors zen) in _allPalettes()) {
      expect(ZenTones.of(zen), hasLength(ZenTone.values.length), reason: name);
      for (final ZenTone tone in ZenTone.values) {
        expect(zen.tone(tone).a, 1, reason: '$name $tone is opaque');
      }
    }
  });

  test('tones read as text and as icons on their grounds', () {
    for (final (String name, ZenColors zen) in _allPalettes()) {
      for (final ZenTone tone in ZenTone.values) {
        final Color c = zen.tone(tone);
        for (final Color ground in <Color>[
          zen.background,
          zen.surface,
          zen.surfaceRaised,
        ]) {
          expect(
            ZenTones.contrast(c, ground),
            greaterThanOrEqualTo(4.5),
            reason: '$name $tone text',
          );
        }
        // The icon in its tinted badge ([ZenIconBadge]).
        final Color badge = Color.alphaBlend(
          c.withValues(alpha: 0.26),
          zen.surface,
        );
        expect(
          ZenTones.contrast(c, badge),
          greaterThanOrEqualTo(3),
          reason: '$name $tone icon on its badge',
        );
      }
    }
  });

  test('colourful palettes keep the tones apart and alike everywhere', () {
    for (final (String name, ZenColors zen) in _allPalettes()) {
      if (zen.duotone) {
        continue;
      }
      final List<Color> tones = ZenTones.of(zen);
      for (int i = 0; i < tones.length; i++) {
        for (int j = i + 1; j < tones.length; j++) {
          expect(
            _deltaE(tones[i], tones[j]),
            greaterThanOrEqualTo(8),
            reason: '$name ${ZenTone.values[i]} vs ${ZenTone.values[j]}',
          );
        }
      }
      // The same meaning has the same hue in every colourful palette.
      for (final ZenTone tone in ZenTone.values) {
        final double? hue = ZenTones.hues[tone.index];
        if (hue == null) {
          continue;
        }
        expect(
          _hueGap(HSLColor.fromColor(zen.tone(tone)).hue, hue),
          lessThan(12),
          reason: '$name $tone',
        );
      }
    }
  });

  test('restricted palettes use only shades of their own colours', () {
    for (final (String name, ZenColors zen) in _allPalettes()) {
      if (!zen.duotone) {
        continue;
      }
      final List<Color> bases = <Color>[
        zen.accent,
        zen.accentSecondary,
        zen.accentTertiary,
        zen.danger,
        zen.textSecondary,
      ];
      for (final ZenTone tone in ZenTone.values) {
        final (int base, double _) = ZenTones.restricted[tone.index];
        final HSLColor want = HSLColor.fromColor(bases[base]);
        final HSLColor got = HSLColor.fromColor(zen.tone(tone));
        // Only the lightness moves: the hue of its base colour (a grey
        // stays a grey).
        if (want.saturation > 0.12 && got.saturation > 0.12) {
          expect(
            _hueGap(got.hue, want.hue),
            lessThan(15),
            reason: '$name $tone',
          );
        } else {
          expect(got.saturation, lessThan(0.3), reason: '$name $tone grey');
        }
      }
    }
  });

  test('safety is the palette red, numbered colours are tones', () {
    for (final (String name, ZenColors zen) in _allPalettes()) {
      final double gap = _hueGap(
        HSLColor.fromColor(zen.tone(ZenTone.safety)).hue,
        HSLColor.fromColor(zen.danger).hue,
      );
      expect(gap, lessThan(15), reason: name);
      final Set<Color> tones = ZenTones.of(zen).toSet();
      for (int i = 0; i < 24; i++) {
        expect(tones, contains(zenTone(zen, i)), reason: '$name $i');
      }
    }
  });
}
