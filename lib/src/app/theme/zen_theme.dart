import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_concept.dart';
import 'package:zen/src/app/theme/zen_look.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/features/settings/app_settings.dart';

export 'package:zen/src/app/theme/zen_fixed.dart';
export 'package:zen/src/app/theme/zen_look.dart';
export 'package:zen/src/app/theme/zen_tones.dart';

/// The faces of the app, the same in every look: display for titles,
/// grotesk for body copy, mono for system labels.
abstract final class ZenText {
  /// Baloo 2: a round title face that draws every Latin letter of every
  /// language Zen speaks (Polish ą ć ę ń ś ź ż, Czech č ř ů, Hungarian ő ű,
  /// Romanian ș ț, Turkish ğ ş, Vietnamese) and Devanagari, in one font.
  /// Scripts it has not (Arabic, Cyrillic, Chinese, Japanese, Korean) come
  /// from the phone's own font, as for every other face of the app.
  static const String displayFamily = 'Baloo 2';
  static const String sansFamily = 'Hanken Grotesk';
  static const String monoFamily = 'JetBrains Mono';
}

/// The app's typography: one family set for every look (a look changes
/// shapes, lines, surfaces and motion, never the font).
@immutable
final class ZenTypeface {
  const ZenTypeface({
    required this.label,
    required this.sans,
    required this.mono,
    this.display = ZenText.displayFamily,
    this.sansFallback = const <String>[ZenText.sansFamily, 'DM Sans'],
    this.monoFallback = const <String>[ZenText.monoFamily, 'Space Mono'],
    this.displayFallback = const <String>[ZenText.sansFamily],
    this.monoTracking = 0.2,
    this.bodyTracking = 0,
    this.titleTracking = -0.4,
    this.monoScale = 1,
    this.displayScale = 1,
  });

  final String label;
  final String sans;
  final String mono;
  final String display;
  final List<String> sansFallback;
  final List<String> monoFallback;
  final List<String> displayFallback;
  final double monoTracking;
  final double bodyTracking;
  final double titleTracking;

  /// Size factors of the mono and display faces.
  final double monoScale;
  final double displayScale;
}

/// The one pairing of the app.
abstract final class ZenTypefaces {
  static const ZenTypeface zen = ZenTypeface(
    label: 'Baloo 2 + Hanken + JetBrains',
    sans: ZenText.sansFamily,
    mono: ZenText.monoFamily,
    display: ZenText.displayFamily,
  );
}

/// The canvas: deep, slightly tinted neutrals and one accent with two
/// gradient partners, per theme (Ustawienia → Wygląd).
@immutable
final class ZenColors extends ThemeExtension<ZenColors> {
  const ZenColors({
    required this.background,
    required this.surface,
    required this.surfaceRaised,
    required this.surfaceMuted,
    required this.surfaceSunk,
    required this.outline,
    required this.outlineSoft,
    required this.outlineStrong,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.accentSecondary,
    required this.accentTertiary,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.warning,
    required this.danger,
    this.concept = false,
    this.glow = 0,
    this.gradient = 1,
    this.toneSaturation = 0.85,
    this.duotone = false,
  });

  final Color background;
  final Color surface;
  final Color surfaceRaised;
  final Color surfaceMuted;
  final Color surfaceSunk;
  final Color outline;
  final Color outlineSoft;
  final Color outlineStrong;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color accent;
  final Color accentSecondary;
  final Color accentTertiary;
  final Color accentSoft;
  final Color onAccent;
  final Color success;
  final Color warning;
  final Color danger;

  /// The typography: the same in every palette.
  ZenTypeface get typeface => ZenTypefaces.zen;

  /// The calmer component style shared by the fixed palettes (everything
  /// but Klasyczny): soft fade-and-rise page transitions, a highlight
  /// instead of ink ripples, a rounded tab indicator, a breathing unread
  /// badge.
  final bool concept;

  /// Strength of the neon glow (0 = none) on the active tab, the focused
  /// field, the FAB, the section bar and unread badges.
  final double glow;

  /// How much of the accent gradients is kept: 1 = the full two-hue
  /// gradients, 0 = flat tints.
  final double gradient;

  /// Saturation of the feature tones around the accent ([zenTone]).
  final double toneSaturation;

  /// A restricted palette: its tones ([ZenTones]) are shades of its own
  /// few colours instead of a hue each.
  final bool duotone;

  /// A soft glow of [tone] behind an active element; null without glow.
  List<BoxShadow>? neonGlow(Color tone, {double radius = 12}) {
    if (glow <= 0) {
      return null;
    }
    return <BoxShadow>[
      BoxShadow(
        color: tone.withValues(alpha: (0.5 * glow).clamp(0.0, 1.0)),
        blurRadius: radius,
        spreadRadius: -2,
      ),
    ];
  }

  /// The second stop of a two-hue gradient from [from] to [to], pulled back
  /// to [from] as far as [gradient] asks (a flat tint at 0).
  Color gradientPartner(Color from, Color to) {
    if (gradient >= 1) {
      return to;
    }
    if (gradient <= 0) {
      return from;
    }
    return Color.lerp(from, to, gradient)!;
  }

  /// Ink-faint labels from the canvas (`oklch(0.52 0 0)`).
  Color get inkFaint => textMuted;

  TextStyle mono({
    required Color color,
    double size = 10,
    FontWeight weight = FontWeight.w400,
    double? letterSpacing,
    double? height,
  }) {
    return TextStyle(
      fontFamily: typeface.mono,
      fontFamilyFallback: typeface.monoFallback,
      fontSize: size * typeface.monoScale,
      color: color,
      fontWeight: weight,
      letterSpacing: letterSpacing ?? typeface.monoTracking,
      height: height,
    );
  }

  TextStyle display({
    required Color color,
    double size = 30,
    FontWeight weight = FontWeight.w700,
    double letterSpacing = -0.2,
    double height = 1.05,
  }) {
    return TextStyle(
      fontFamily: typeface.display,
      fontFamilyFallback: typeface.displayFallback,
      fontSize: size * typeface.displayScale,
      color: color,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      height: height,
    );
  }

  /// Small caps-style section labels: the sans face, bold, lightly tracked
  /// (wide-tracked mono labels did not fit on phones).
  TextStyle label({
    Color? color,
    double size = 10,
    FontWeight weight = FontWeight.w400,
  }) {
    return TextStyle(
      fontFamily: typeface.sans,
      fontFamilyFallback: typeface.sansFallback,
      fontSize: size + 1.5,
      color: color ?? textSecondary,
      fontWeight: weight.value < 600 ? FontWeight.w700 : weight,
      letterSpacing: 0.9,
    );
  }

  /// The colours of [palette] ([accent] picks the colour of
  /// [AppPalette.classic]).
  static ZenColors forPalette(
    AppPalette palette,
    AppAccentTheme accent,
    Brightness brightness,
  ) => ZenPalettes.resolve(palette, accent, brightness);

  static ZenColors of(BuildContext context) {
    return Theme.of(context).extension<ZenColors>() ??
        resolve(AppSettings.defaultAccentTheme, Brightness.dark);
  }

  List<Color> get accentTrio => <Color>[
    accent,
    accentSecondary,
    accentTertiary,
  ];

  Color accentFor(Object key) {
    final int hash = key.hashCode & 0x7FFFFFFF;
    return accentTrio[hash % 3];
  }

  LinearGradient panelGradient({Color? tone, double alpha = 0.05}) {
    final Color hue = tone ?? accent;
    return LinearGradient(
      colors: <Color>[
        Color.alphaBlend(hue.withValues(alpha: alpha * 1.2), surfaceRaised),
        surface,
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }

  LinearGradient accentRule({Color? tone}) {
    final Color hue = tone ?? textPrimary;
    return LinearGradient(
      colors: <Color>[
        hue,
        hue.withValues(alpha: 0.1),
        hue.withValues(alpha: 0),
      ],
      stops: const <double>[0, 0.65, 1],
    );
  }

  Color tintOf(Color tone, {double alpha = 0.14}) =>
      Color.alphaBlend(tone.withValues(alpha: alpha), surface);

  LinearGradient toneGradient(
    Color tone, {
    double from = 0.22,
    double to = 0.06,
  }) {
    // Flatter palettes pull both stops towards their middle.
    final double mid = (from + to) / 2;
    final double a = gradient >= 1 ? from : mid + (from - mid) * gradient;
    final double b = gradient >= 1 ? to : mid + (to - mid) * gradient;
    return LinearGradient(
      colors: <Color>[
        tone.withValues(alpha: a),
        tone.withValues(alpha: b),
      ],
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
    );
  }

  List<BoxShadow> accentGlow({double radius = 14, double alpha = 0.3}) {
    return <BoxShadow>[
      BoxShadow(
        color: accent.withValues(alpha: alpha * 0.6),
        blurRadius: radius,
        spreadRadius: -4,
      ),
    ];
  }

  List<BoxShadow> elevationShadow({
    double elevation = 8,
    Color? ambientColor,
    double ambientAlpha = 0.05,
  }) {
    return <BoxShadow>[
      BoxShadow(
        color: const Color(0x66000000),
        blurRadius: elevation * 1.4,
        offset: Offset(0, elevation * 0.35),
      ),
    ];
  }

  Border topHighlightBorder({Color? highlightColor, double alpha = 0.2}) {
    return Border.all(color: outlineSoft);
  }

  LinearGradient get accentGradient => LinearGradient(
    colors: <Color>[accent, gradientPartner(accent, accentSecondary)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static Color foregroundFor(Color background) {
    return background.computeLuminance() > 0.179
        ? const Color(0xFF171717)
        : const Color(0xFFF5F5F5);
  }

  /// The signature hue of each theme (the accent; the gradient partners
  /// are the next hues around the wheel). Null = monochrome.
  static Color? _hueOf(AppAccentTheme theme) => switch (theme) {
    AppAccentTheme.graphite => const Color(0xFF8B7BFF),
    AppAccentTheme.paper => null,
    AppAccentTheme.carbon => null,
    AppAccentTheme.terminal => const Color(0xFF3DDC84),
    AppAccentTheme.jade => const Color(0xFF2BD9A0),
    AppAccentTheme.moss => const Color(0xFF9BD45A),
    AppAccentTheme.aurora => const Color(0xFF2DE1C2),
    AppAccentTheme.arctic => const Color(0xFF5CD6FF),
    AppAccentTheme.lagoon => const Color(0xFF19C3C9),
    AppAccentTheme.cobalt => const Color(0xFF4C8DFF),
    AppAccentTheme.abyss => const Color(0xFF3A6BFF),
    AppAccentTheme.denim => const Color(0xFF6E9CFF),
    AppAccentTheme.amethyst => const Color(0xFFA47CFF),
    AppAccentTheme.nebula => const Color(0xFF7C6CFF),
    AppAccentTheme.plum => const Color(0xFFC06CFF),
    AppAccentTheme.synthwave => const Color(0xFFFF4FD8),
    AppAccentTheme.sakura => const Color(0xFFFF8FB8),
    AppAccentTheme.ruby => const Color(0xFFFF4D6D),
    AppAccentTheme.magma => const Color(0xFFFF6A3D),
    AppAccentTheme.rust => const Color(0xFFE2733B),
    AppAccentTheme.coral => const Color(0xFFFF7F6B),
    AppAccentTheme.solaris => const Color(0xFFFFC23D),
    AppAccentTheme.honey => const Color(0xFFF2B33D),
    AppAccentTheme.voltage => const Color(0xFFD4F53D),
    AppAccentTheme.amberCrt => const Color(0xFFFFB000),
    AppAccentTheme.nocturne => const Color(0xFF7F8CFF),
    AppAccentTheme.fjord => const Color(0xFF5FA8D3),
  };

  static Color _hsl(double h, double s, double l) =>
      HSLColor.fromAHSL(1, h % 360, s.clamp(0, 1), l.clamp(0, 1)).toColor();

  static ZenColors resolve(AppAccentTheme theme, Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    final Color? hue = _hueOf(theme);
    final HSLColor a = HSLColor.fromColor(hue ?? const Color(0xFF8A8FA0));
    final double h = a.hue;
    // Neutrals carry a whisper of the accent hue, so every theme feels like
    // one piece; monochrome themes stay grey.
    final double tint = hue == null ? 0 : 1;
    Color accent;
    Color second;
    Color third;
    if (hue == null) {
      accent = dark ? const Color(0xFFF2F2F4) : const Color(0xFF16171A);
      second = dark ? const Color(0xFFC9CAD0) : const Color(0xFF3C3E45);
      third = dark ? const Color(0xFF9EA0A8) : const Color(0xFF63666F);
    } else {
      // One accent for both themes: the light theme is the same colour as
      // the dark one (the look people know from the phone), only darkened
      // where a pale accent would vanish on white.
      accent = _hsl(h, a.saturation, a.lightness.clamp(0.58, 0.72));
      second = dark ? _hsl(h + 42, 0.95, 0.66) : _hsl(h + 42, 0.92, 0.58);
      third = dark ? _hsl(h + 84, 0.95, 0.68) : _hsl(h + 84, 0.92, 0.58);
    }
    if (hue != null) {
      // A label on the accent must stay readable (4.5:1): light enough for
      // dark text...
      HSLColor x = HSLColor.fromColor(accent);
      for (int i = 0; i < 40; i++) {
        if (x.toColor().computeLuminance() >= 0.23) {
          break;
        }
        x = x.withLightness((x.lightness + 0.015).clamp(0, 1));
      }
      if (!dark) {
        // ...and on white it must still read (3:1), never landing where
        // neither dark nor white text reaches 4.5:1 on it.
        for (int i = 0; i < 60; i++) {
          final double y = x.toColor().computeLuminance();
          if (y <= 0.30 && (y >= 0.215 || y <= 0.16)) {
            break;
          }
          x = x.withLightness((x.lightness - 0.01).clamp(0, 1));
        }
      }
      accent = x.toColor();
    }
    if (dark) {
      return ZenColors(
        background: _hsl(h, 0.22 * tint, 0.052),
        surface: _hsl(h, 0.18 * tint, 0.082),
        surfaceRaised: _hsl(h, 0.16 * tint, 0.115),
        surfaceMuted: _hsl(h, 0.14 * tint, 0.145),
        surfaceSunk: _hsl(h, 0.22 * tint, 0.036),
        outline: _hsl(h, 0.13 * tint, 0.175),
        outlineSoft: _hsl(h, 0.13 * tint, 0.135),
        outlineStrong: _hsl(h, 0.12 * tint, 0.28),
        textPrimary: _hsl(h, 0.25 * tint, 0.965),
        textSecondary: _hsl(h, 0.12 * tint, 0.72),
        textMuted: _hsl(h, 0.08 * tint, 0.52),
        accent: accent,
        accentSecondary: second,
        accentTertiary: third,
        accentSoft: Color.alphaBlend(
          accent.withValues(alpha: 0.16),
          _hsl(h, 0.18 * tint, 0.082),
        ),
        onAccent: foregroundFor(accent),
        success: const Color(0xFF3DDC97),
        warning: const Color(0xFFFFC857),
        danger: const Color(0xFFFF5A6E),
        // A monochrome accent keeps its tones grey.
        duotone: hue == null,
      );
    }
    return ZenColors(
      background: _hsl(h, 0.3 * tint, 0.972),
      surface: const Color(0xFFFFFFFF),
      surfaceRaised: _hsl(h, 0.3 * tint, 0.948),
      surfaceMuted: _hsl(h, 0.24 * tint, 0.922),
      surfaceSunk: _hsl(h, 0.3 * tint, 0.955),
      outline: _hsl(h, 0.2 * tint, 0.875),
      outlineSoft: _hsl(h, 0.2 * tint, 0.915),
      outlineStrong: _hsl(h, 0.12 * tint, 0.7),
      textPrimary: _hsl(h, 0.3 * tint, 0.085),
      textSecondary: _hsl(h, 0.12 * tint, 0.36),
      textMuted: _hsl(h, 0.08 * tint, 0.5),
      accent: accent,
      accentSecondary: second,
      accentTertiary: third,
      accentSoft: Color.alphaBlend(
        accent.withValues(alpha: 0.12),
        const Color(0xFFFFFFFF),
      ),
      onAccent: foregroundFor(accent),
      success: const Color(0xFF0E9F6E),
      warning: const Color(0xFFC77700),
      danger: const Color(0xFFE02446),
      duotone: hue == null,
    );
  }

  @override
  ZenColors copyWith({
    Color? background,
    Color? surface,
    Color? surfaceRaised,
    Color? surfaceMuted,
    Color? surfaceSunk,
    Color? outline,
    Color? outlineSoft,
    Color? outlineStrong,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? accent,
    Color? accentSecondary,
    Color? accentTertiary,
    Color? accentSoft,
    Color? onAccent,
    Color? success,
    Color? warning,
    Color? danger,
    bool? concept,
    double? glow,
    double? gradient,
    double? toneSaturation,
    bool? duotone,
  }) {
    return ZenColors(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceRaised: surfaceRaised ?? this.surfaceRaised,
      surfaceMuted: surfaceMuted ?? this.surfaceMuted,
      surfaceSunk: surfaceSunk ?? this.surfaceSunk,
      outline: outline ?? this.outline,
      outlineSoft: outlineSoft ?? this.outlineSoft,
      outlineStrong: outlineStrong ?? this.outlineStrong,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textMuted: textMuted ?? this.textMuted,
      accent: accent ?? this.accent,
      accentSecondary: accentSecondary ?? this.accentSecondary,
      accentTertiary: accentTertiary ?? this.accentTertiary,
      accentSoft: accentSoft ?? this.accentSoft,
      onAccent: onAccent ?? this.onAccent,
      success: success ?? this.success,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      concept: concept ?? this.concept,
      glow: glow ?? this.glow,
      gradient: gradient ?? this.gradient,
      toneSaturation: toneSaturation ?? this.toneSaturation,
      duotone: duotone ?? this.duotone,
    );
  }

  @override
  ZenColors lerp(ZenColors? other, double t) {
    if (other == null) {
      return this;
    }
    return ZenColors(
      background: Color.lerp(background, other.background, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceMuted: Color.lerp(surfaceMuted, other.surfaceMuted, t)!,
      surfaceSunk: Color.lerp(surfaceSunk, other.surfaceSunk, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineSoft: Color.lerp(outlineSoft, other.outlineSoft, t)!,
      outlineStrong: Color.lerp(outlineStrong, other.outlineStrong, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      accent: Color.lerp(accent, other.accent, t)!,
      accentSecondary: Color.lerp(accentSecondary, other.accentSecondary, t)!,
      accentTertiary: Color.lerp(accentTertiary, other.accentTertiary, t)!,
      accentSoft: Color.lerp(accentSoft, other.accentSoft, t)!,
      onAccent: Color.lerp(onAccent, other.onAccent, t)!,
      success: Color.lerp(success, other.success, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
      concept: t < 0.5 ? concept : other.concept,
      glow: lerpDouble(glow, other.glow, t)!,
      gradient: lerpDouble(gradient, other.gradient, t)!,
      toneSaturation: lerpDouble(toneSaturation, other.toneSaturation, t)!,
      duotone: t < 0.5 ? duotone : other.duotone,
    );
  }
}

TextTheme _trackedTextTheme(TextTheme base, ZenTypeface typeface) {
  TextStyle? track(TextStyle? style, double delta) {
    if (style == null) {
      return null;
    }
    return style.copyWith(letterSpacing: (style.letterSpacing ?? 0) + delta);
  }

  return base.copyWith(
    displayLarge: track(base.displayLarge, typeface.titleTracking),
    displayMedium: track(base.displayMedium, typeface.titleTracking),
    displaySmall: track(base.displaySmall, typeface.titleTracking),
    headlineLarge: track(base.headlineLarge, typeface.titleTracking),
    headlineMedium: track(base.headlineMedium, typeface.titleTracking),
    headlineSmall: track(base.headlineSmall, typeface.titleTracking),
    titleLarge: track(base.titleLarge, typeface.titleTracking),
    titleMedium: track(base.titleMedium, typeface.titleTracking),
    titleSmall: track(base.titleSmall, typeface.titleTracking),
    bodyLarge: track(base.bodyLarge, typeface.bodyTracking),
    bodyMedium: track(base.bodyMedium, typeface.bodyTracking),
    bodySmall: track(base.bodySmall, typeface.bodyTracking),
    labelLarge: track(base.labelLarge, typeface.bodyTracking),
    labelMedium: track(base.labelMedium, typeface.bodyTracking),
    labelSmall: track(base.labelSmall, typeface.bodyTracking),
  );
}

abstract final class ZenTheme {
  static ThemeData dark([
    AppAccentTheme accent = AppSettings.defaultAccentTheme,
    AppPalette palette = AppSettings.defaultPalette,
  ]) => forPalette(palette, accent, Brightness.dark);

  static ThemeData light([
    AppAccentTheme accent = AppSettings.defaultAccentTheme,
    AppPalette palette = AppSettings.defaultPalette,
  ]) => forPalette(palette, accent, Brightness.light);

  static final Map<String, ThemeData> _cache = <String, ThemeData>{};

  /// The theme of [palette] in [brightness] ([accent] colours Klasyczny).
  /// Built once per combination: the picker shows every palette at once.
  static ThemeData forPalette(
    AppPalette palette,
    AppAccentTheme accent,
    Brightness brightness,
  ) {
    final String key = '${palette.name}/${accent.name}/${brightness.name}';
    return _cache[key] ??= build(
      ZenColors.forPalette(palette, accent, brightness),
      ZenPalettes.look(palette),
    );
  }

  /// The whole Material theme of [colors] in [look]: every component theme
  /// (cards, chips, buttons, fields, dialogs, sheets, the navigation bar
  /// and rail, switches, sliders, tooltips, snack bars, tabs, list tiles,
  /// progress, menus) takes its shape, outline and lift from the look.
  static ThemeData build(ZenColors colors, ZenLook look) {
    final bool compactUi = !kIsWeb;
    final bool bevel = look.metal;
    // Drawn looks (comics, pixel games): thick ink lines, hard shadows.
    final bool inked =
        look.borders == ZenBorderStyle.ink ||
        look.borders == ZenBorderStyle.pixel;
    final bool hard = look.elevation == ZenElevation.hard;
    final bool chrome = look.buttonFill == ZenButtonFill.chrome;
    final bool lineButtons = look.buttonFill == ZenButtonFill.line;
    final bool gradientButtons =
        look.buttonFill == ZenButtonFill.gradient && colors.gradient > 0;
    // A glowing look: lit outlines, the accent glowing instead of shadows.
    final bool glowLift =
        look.elevation == ZenElevation.glow && colors.glow > 0;
    final bool lit = look.lit || glowLift;
    final bool backdrop = look.backdrop != ZenBackdrop.none;
    final double fieldRadius = look.radius(16);
    final Size buttonMinSize = Size(0, compactUi ? 46 : 48);
    final EdgeInsetsGeometry fieldPadding = EdgeInsets.symmetric(
      horizontal: look.fields == ZenFieldStyle.underline
          ? 4
          : compactUi
          ? 16
          : 18,
      vertical: compactUi ? 12 : 14,
    );
    final bool isDark =
        ThemeData.estimateBrightnessForColor(colors.background) ==
        Brightness.dark;

    OutlinedBorder buttonShape([bool pressed = false]) =>
        look.buttonBorder(colors, pressed: pressed);
    // Chrome keys press in.
    final WidgetStateProperty<OutlinedBorder> buttonShapes =
        WidgetStateProperty.resolveWith<OutlinedBorder>(
          (Set<WidgetState> states) =>
              buttonShape(states.contains(WidgetState.pressed)),
        );
    // Text buttons have no frame: a chrome key becomes a plain rectangle.
    final OutlinedBorder plainShape = look.buttons == ZenButtonShape.bevel
        ? const RoundedRectangleBorder()
        : buttonShape();
    final BorderSide lineSide = BorderSide(
      color: lit ? colors.accent.withValues(alpha: 0.9) : colors.accent,
      width: 1.2,
    );

    PageTransitionsBuilder? pages = switch (look.pages) {
      ZenPageMotion.platform => null,
      ZenPageMotion.soft => const ZenSoftPageTransitionsBuilder(),
      ZenPageMotion.neonWipe => const ZenNeonWipeTransitionsBuilder(),
      ZenPageMotion.stepped => const ZenSteppedPageTransitionsBuilder(),
      ZenPageMotion.glitch => const ZenGlitchPageTransitionsBuilder(),
      ZenPageMotion.streak => const ZenStreakPageTransitionsBuilder(),
      ZenPageMotion.bubble => const ZenBubblePageTransitionsBuilder(),
    };
    if (pages != null && backdrop) {
      // The pages are see-through over the backdrop: the page below fades
      // out while the new one comes in.
      pages = ZenFadeBehindTransitionsBuilder(pages);
    }

    final ColorScheme scheme =
        (isDark ? const ColorScheme.dark() : const ColorScheme.light())
            .copyWith(
              primary: colors.accent,
              onPrimary: colors.onAccent,
              primaryContainer: colors.accentSoft,
              onPrimaryContainer: colors.textPrimary,
              secondary: colors.accentSecondary,
              onSecondary: colors.onAccent,
              secondaryContainer: colors.surfaceRaised,
              onSecondaryContainer: colors.textPrimary,
              tertiary: colors.accentTertiary,
              onTertiary: colors.onAccent,
              tertiaryContainer: colors.surfaceMuted,
              onTertiaryContainer: colors.textPrimary,
              surface: colors.surface,
              onSurface: colors.textPrimary,
              onSurfaceVariant: colors.textSecondary,
              surfaceContainerLowest: colors.surfaceSunk,
              surfaceContainerLow: colors.surface,
              surfaceContainer: colors.surfaceRaised,
              surfaceContainerHigh: colors.surfaceRaised,
              surfaceContainerHighest: colors.surfaceMuted,
              outline: colors.outline,
              outlineVariant: colors.outlineSoft,
              inverseSurface: colors.textPrimary,
              onInverseSurface: colors.background,
              inversePrimary: colors.accentSoft,
              error: colors.danger,
              onError: colors.onAccent,
              // Glowing looks: elevation shadows (the FAB, menus) become a
              // glow.
              shadow: glowLift
                  ? colors.accent.withValues(alpha: 0.55 * colors.glow)
                  : null,
            );

    final ThemeData base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // Over a backdrop the pages are see-through; the backdrop paints
      // the background ([ZenBackdropHost]).
      scaffoldBackgroundColor: backdrop
          ? const Color(0x00000000)
          : colors.background,
      canvasColor: colors.background,
      fontFamily: colors.typeface.sans,
      fontFamilyFallback: colors.typeface.sansFallback,
      // The fixed palettes: a quiet highlight instead of ink ripples.
      splashFactory: colors.concept
          ? NoSplash.splashFactory
          : InkRipple.splashFactory,
      highlightColor: colors.concept
          ? colors.accent.withValues(alpha: isDark ? 0.10 : 0.08)
          : null,
      hoverColor: colors.concept
          ? colors.textPrimary.withValues(alpha: 0.04)
          : null,
      focusColor: colors.concept ? colors.accent.withValues(alpha: 0.16) : null,
      pageTransitionsTheme: pages == null
          ? null
          : PageTransitionsTheme(
              builders: <TargetPlatform, PageTransitionsBuilder>{
                for (final TargetPlatform p in TargetPlatform.values) p: pages,
              },
            ),
      visualDensity: compactUi ? VisualDensity.compact : VisualDensity.standard,
      materialTapTargetSize: compactUi
          ? MaterialTapTargetSize.shrinkWrap
          : MaterialTapTargetSize.padded,
    );

    final TextStyle buttonText = TextStyle(
      fontFamily: colors.typeface.sans,
      fontFamilyFallback: colors.typeface.sansFallback,
      fontWeight: FontWeight.w700,
      fontSize: 14,
      letterSpacing: lit || lineButtons ? 0.6 : 0.1,
    );
    final EdgeInsetsGeometry buttonPadding = EdgeInsets.symmetric(
      horizontal: compactUi ? 16 : 18,
      vertical: compactUi ? 10 : 12,
    );

    // Fields: an outlined box, or only a line under the text.
    final bool underline = look.fields == ZenFieldStyle.underline;
    InputBorder field(Color color, {double width = 1}) => underline
        ? UnderlineInputBorder(
            borderSide: BorderSide(color: color, width: width),
          )
        : OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(fieldRadius)),
            borderSide: BorderSide(color: color, width: width),
          );
    final Color fieldLine = look.borders == ZenBorderStyle.none
        ? colors.outlineSoft
        : lit || bevel || look.flat
        ? colors.outline
        : colors.outlineSoft;

    // Filled button: the accent (solid or the gradient), a lit line, or a
    // chrome key with an accent label.
    ButtonStyle filledStyle() {
      final ButtonStyle style = FilledButton.styleFrom(
        backgroundColor: chrome
            ? colors.surfaceRaised
            : lineButtons
            ? colors.accentSoft
            : colors.accent,
        foregroundColor: chrome || lineButtons
            ? colors.accent
            : colors.onAccent,
        disabledBackgroundColor: colors.surfaceMuted,
        disabledForegroundColor: colors.textMuted,
        minimumSize: buttonMinSize,
        padding: buttonPadding,
        textStyle: buttonText,
        elevation: 0,
        shape: buttonShape(),
        backgroundBuilder: gradientButtons || lit || hard
            ? (BuildContext context, Set<WidgetState> states, Widget? child) {
                final bool off = states.contains(WidgetState.disabled);
                final bool pressed = states.contains(WidgetState.pressed);
                return DecoratedBox(
                  decoration: ShapeDecoration(
                    shape: buttonShape(pressed),
                    gradient: gradientButtons && !off
                        ? colors.accentGradient
                        : null,
                    // A hard shadow that the button presses into.
                    shadows: off
                        ? null
                        : hard
                        ? (pressed ? null : look.lift(colors))
                        : lit
                        ? colors.neonGlow(colors.accent, radius: 16)
                        : null,
                  ),
                  child: child,
                );
              }
            : null,
      ).copyWith(shape: buttonShapes);
      if (inked) {
        return style.copyWith(
          side: WidgetStatePropertyAll<BorderSide>(
            BorderSide(color: colors.outlineStrong, width: 2.5),
          ),
        );
      }
      return lineButtons
          ? style.copyWith(
              side: WidgetStateProperty.resolveWith<BorderSide?>(
                (Set<WidgetState> states) =>
                    states.contains(WidgetState.disabled)
                    ? BorderSide(color: colors.outline)
                    : lineSide,
              ),
            )
          : style;
    }

    final Color chipSide = switch (look.chips) {
      ZenChipStyle.outline =>
        lit ? colors.accent.withValues(alpha: 0.55) : colors.outlineStrong,
      ZenChipStyle.tag => colors.outline,
      ZenChipStyle.cut => colors.accent.withValues(alpha: 0.6),
      ZenChipStyle.pixel => colors.outlineStrong,
      ZenChipStyle.pill || ZenChipStyle.bevel =>
        inked
            ? colors.outlineStrong
            : lit
            ? colors.outlineStrong
            : colors.outlineSoft,
    };

    final ShapeBorder navIndicator = switch (look.nav) {
      ZenNavStyle.bevel => ZenBevelBorder.of(colors, sunken: true),
      ZenNavStyle.glow => RoundedRectangleBorder(
        borderRadius: look.br(16),
        side: BorderSide(color: colors.accent.withValues(alpha: 0.8)),
      ),
      ZenNavStyle.block => RoundedRectangleBorder(
        borderRadius: look.br(4),
        side: BorderSide(color: colors.accent),
      ),
      ZenNavStyle.underline => RoundedRectangleBorder(
        borderRadius: look.br(10),
      ),
      ZenNavStyle.pill => RoundedRectangleBorder(borderRadius: look.br(999)),
    };
    final Color navIndicatorColor = switch (look.nav) {
      ZenNavStyle.bevel => colors.surfaceSunk,
      ZenNavStyle.glow => colors.background,
      ZenNavStyle.block => colors.accent.withValues(alpha: 0.16),
      ZenNavStyle.underline || ZenNavStyle.pill => colors.accentSoft,
    };
    final Color navBackground = look.bevelled
        ? colors.surface
        : colors.surfaceSunk;

    final ShapeBorder sheetShape = look.floatingShape(colors, topOnly: true);
    final ShapeBorder dialogShape = look.floatingShape(colors);
    final ShapeBorder menuShape = look.floatingShape(colors, radius: 22);
    // Square looks get a rectangular slider track and a square thumb.
    final bool sharpSlider = look.sharp || bevel;

    final Color appBarEdge = switch (look.dividers) {
      ZenDividerStyle.glow => colors.accent.withValues(alpha: 0.32),
      ZenDividerStyle.groove => colors.surfaceSunk,
      ZenDividerStyle.none => const Color(0x00000000),
      ZenDividerStyle.dashed => colors.outline,
      ZenDividerStyle.hairline || ZenDividerStyle.inset => colors.outlineSoft,
    };

    return base.copyWith(
      extensions: <ThemeExtension<dynamic>>[colors, look],
      cardColor: look.panelColor(colors),
      dividerColor: look.dividerColor(colors),
      dividerTheme: DividerThemeData(
        color: look.dividerColor(colors),
        space: 1,
        thickness: 1,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: bevel
            ? colors.surface
            : colors.background.withValues(alpha: backdrop ? 0.9 : 0.95),
        foregroundColor: colors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: const Color(0x00000000),
        shape: Border(
          bottom: BorderSide(color: bevel ? colors.surfaceSunk : appBarEdge),
        ),
        titleTextStyle: TextStyle(
          fontFamily: colors.typeface.display,
          fontFamilyFallback: colors.typeface.displayFallback,
          color: colors.textPrimary,
          fontSize: 20 * colors.typeface.displayScale,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.1,
          // The face's own line is 1.6 em tall.
          height: 1.2,
        ),
        actionsIconTheme: IconThemeData(
          color: lit ? colors.accent : colors.textSecondary,
        ),
      ),
      iconTheme: IconThemeData(color: colors.textSecondary),
      textTheme: _trackedTextTheme(
        base.textTheme.apply(
          bodyColor: colors.textPrimary,
          displayColor: colors.textPrimary,
        ),
        colors.typeface,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: colors.accent,
        selectionColor: colors.accent.withValues(alpha: 0.35),
        selectionHandleColor: colors.accent,
      ),
      cardTheme: CardThemeData(
        color: look.panelColor(colors),
        surfaceTintColor: const Color(0x00000000),
        elevation: 0,
        margin: const EdgeInsets.symmetric(vertical: 6),
        shape: look.panelShape(colors),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: colors.textSecondary,
        collapsedIconColor: colors.textMuted,
        textColor: colors.textPrimary,
        collapsedTextColor: colors.textPrimary,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: !underline,
        fillColor: look.outlined
            ? colors.surface
            : bevel
            ? colors.surfaceSunk
            : look.glass
            ? colors.surface.withValues(alpha: 0.7)
            : colors.surfaceRaised,
        contentPadding: fieldPadding,
        isDense: false,
        hintStyle: TextStyle(color: colors.textMuted, fontSize: 15),
        helperStyle: TextStyle(
          color: colors.textMuted,
          fontSize: 12,
          height: 1.3,
        ),
        helperMaxLines: 3,
        errorMaxLines: 3,
        prefixIconColor: colors.textMuted,
        suffixIconColor: colors.textMuted,
        labelStyle: TextStyle(color: colors.textSecondary),
        floatingLabelStyle: TextStyle(
          color: colors.accent,
          fontWeight: FontWeight.w600,
        ),
        border: field(fieldLine, width: inked ? 2 : 1),
        enabledBorder: field(fieldLine, width: inked ? 2 : 1),
        disabledBorder: field(colors.outlineSoft),
        focusedBorder: lit && !underline
            ? ZenGlowInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(fieldRadius)),
                borderSide: BorderSide(color: colors.accent, width: 1.4),
                glowColor: colors.accent,
                glow: colors.glow,
              )
            : field(colors.accent, width: bevel ? 1 : 1.6),
        errorBorder: field(colors.danger),
        focusedErrorBorder: field(colors.danger, width: 1.6),
      ),
      filledButtonTheme: FilledButtonThemeData(style: filledStyle()),
      elevatedButtonTheme: ElevatedButtonThemeData(style: filledStyle()),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: lit || lineButtons
              ? colors.accent
              : colors.textPrimary,
          backgroundColor: bevel
              ? colors.surface
              : look.glass
              ? colors.surface.withValues(alpha: 0.5)
              : const Color(0x00000000),
          minimumSize: buttonMinSize,
          padding: buttonPadding,
          textStyle: buttonText,
          side: inked
              ? BorderSide(color: colors.outlineStrong, width: 2.5)
              : BorderSide(
                  color: lit
                      ? colors.accent.withValues(alpha: 0.6)
                      : look.borders == ZenBorderStyle.doubleLine
                      ? colors.outlineStrong
                      : colors.outline,
                  width: lit ? 1 : 1.2,
                ),
          shape: buttonShape(),
        ).copyWith(shape: buttonShapes),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: lit || lineButtons
              ? colors.accent
              : colors.textPrimary,
          minimumSize: Size(0, compactUi ? 36 : 40),
          padding: EdgeInsets.symmetric(
            horizontal: compactUi ? 12 : 16,
            vertical: compactUi ? 8 : 10,
          ),
          textStyle: buttonText,
          shape: plainShape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: lit ? colors.accent : colors.textSecondary,
          minimumSize: Size.square(compactUi ? 34 : 40),
          padding: EdgeInsets.all(compactUi ? 6 : 8),
          visualDensity: compactUi
              ? VisualDensity.compact
              : VisualDensity.standard,
          shape: look.sharp ? const RoundedRectangleBorder() : null,
        ),
      ),
      sliderTheme: base.sliderTheme.copyWith(
        activeTrackColor: colors.accent,
        inactiveTrackColor: colors.outline,
        thumbColor: colors.accent,
        overlayColor: colors.accent.withValues(alpha: 0.14),
        valueIndicatorColor: colors.surfaceMuted,
        valueIndicatorTextStyle: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w700,
        ),
        trackShape: sharpSlider ? const RectangularSliderTrackShape() : null,
        thumbShape: sharpSlider
            ? ZenSquareThumbShape(
                light: bevel ? colors.outlineStrong : null,
                dark: bevel ? colors.surfaceSunk : null,
              )
            : null,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? (lineButtons ? colors.accent : colors.onAccent)
              : colors.textSecondary,
        ),
        trackColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? (lineButtons ? colors.accentSoft : colors.accent)
              : colors.surfaceMuted,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? colors.accent
              : colors.outline,
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? colors.onAccent
                : colors.textSecondary,
          ),
          backgroundColor: WidgetStateProperty.resolveWith<Color>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? colors.accent
                : colors.surface,
          ),
          overlayColor: WidgetStatePropertyAll<Color>(
            colors.textPrimary.withValues(alpha: 0.08),
          ),
          textStyle: WidgetStatePropertyAll<TextStyle>(buttonText),
          side: WidgetStateProperty.resolveWith<BorderSide>(
            (Set<WidgetState> states) => states.contains(WidgetState.selected)
                ? BorderSide(color: colors.accent)
                : BorderSide(color: colors.outline),
          ),
          shape: buttonShapes,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: lit ? colors.surface : colors.surfaceMuted,
        contentTextStyle: TextStyle(color: colors.textPrimary, fontSize: 14),
        actionTextColor: colors.accent,
        behavior: SnackBarBehavior.floating,
        // A swipe to either side puts a notice at the bottom away.
        dismissDirection: DismissDirection.horizontal,
        elevation: look.elevation == ZenElevation.flat ? 0 : null,
        shape: look.floatingShape(colors, radius: 22),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: colors.textSecondary,
        textColor: colors.textPrimary,
        selectedColor: colors.textPrimary,
        selectedTileColor: look.nav == ZenNavStyle.block
            ? colors.accent.withValues(alpha: 0.12)
            : colors.surfaceRaised,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        titleTextStyle: TextStyle(
          color: colors.textPrimary,
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          fontFamily: colors.typeface.sans,
        ),
        subtitleTextStyle: TextStyle(
          color: colors.textSecondary,
          fontSize: 13.5,
          height: 1.3,
          fontFamily: colors.typeface.sans,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: look.chips == ZenChipStyle.outline
            ? const Color(0x00000000)
            : lit
            ? colors.surface
            : colors.surfaceRaised,
        selectedColor: colors.accent,
        checkmarkColor: colors.onAccent,
        side: BorderSide(color: chipSide),
        labelStyle: TextStyle(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
          fontSize: 13.5,
          fontFamily: colors.typeface.sans,
          fontFamilyFallback: colors.typeface.sansFallback,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        secondaryLabelStyle: TextStyle(
          color: colors.onAccent,
          fontWeight: FontWeight.w700,
          fontFamily: colors.typeface.sans,
          fontFamilyFallback: colors.typeface.sansFallback,
        ),
        shape: look.chipBorder(colors),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? colors.accent
              : const Color(0x00000000),
        ),
        checkColor: WidgetStatePropertyAll<Color>(colors.onAccent),
        side: BorderSide(color: colors.outlineStrong, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: look.br(4)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.selected)
              ? colors.accent
              : colors.textMuted,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: colors.accent,
        linearTrackColor: colors.surfaceMuted,
        circularTrackColor: const Color(0x00000000),
        refreshBackgroundColor: colors.surfaceRaised,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith<Color>(
          (Set<WidgetState> states) => states.contains(WidgetState.dragged)
              ? colors.textPrimary.withValues(alpha: 0.55)
              : colors.textPrimary.withValues(alpha: 0.28),
        ),
        radius: Radius.circular(look.radius(999)),
        thickness: const WidgetStatePropertyAll<double>(5),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: colors.surfaceRaised,
          borderRadius: look.br(999),
          border: Border.all(
            color: lit ? colors.accent.withValues(alpha: 0.5) : colors.outline,
          ),
          boxShadow: lit ? colors.neonGlow(colors.accent, radius: 8) : null,
        ),
        textStyle: TextStyle(color: colors.textPrimary, fontSize: 12),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: look.elevation == ZenElevation.flat ? 0 : null,
        shape: menuShape,
      ),
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStatePropertyAll<Color>(colors.surface),
          surfaceTintColor: const WidgetStatePropertyAll<Color>(
            Color(0x00000000),
          ),
          shape: WidgetStatePropertyAll<OutlinedBorder>(
            menuShape is OutlinedBorder
                ? menuShape
                : RoundedRectangleBorder(borderRadius: look.br(22)),
          ),
        ),
      ),
      floatingActionButtonTheme: chrome || bevel
          // A chrome key.
          ? FloatingActionButtonThemeData(
              backgroundColor: colors.surfaceRaised,
              foregroundColor: colors.accent,
              elevation: 0,
              focusElevation: 0,
              hoverElevation: 0,
              highlightElevation: 0,
              extendedTextStyle: TextStyle(
                fontFamily: colors.typeface.sans,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
              shape: ZenBevelBorder.of(colors),
            )
          : glowLift || lineButtons
          // A dark tube with a lit outline; in a glowing look its elevation
          // shadow is the accent glow (see `shadow` above).
          ? FloatingActionButtonThemeData(
              backgroundColor: colors.surfaceRaised,
              foregroundColor: colors.accent,
              elevation: glowLift ? 6 : 0,
              focusElevation: glowLift ? 8 : 0,
              hoverElevation: glowLift ? 8 : 0,
              highlightElevation: glowLift ? 4 : 0,
              extendedTextStyle: TextStyle(
                fontFamily: colors.typeface.sans,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
              shape: look.buttons == ZenButtonShape.pill
                  ? StadiumBorder(
                      side: BorderSide(color: colors.accent, width: 1.4),
                    )
                  : RoundedRectangleBorder(
                      borderRadius: look.br(12),
                      side: BorderSide(color: colors.accent, width: 1.4),
                    ),
            )
          : FloatingActionButtonThemeData(
              backgroundColor: colors.accent,
              foregroundColor: colors.onAccent,
              elevation: look.elevation == ZenElevation.shadow ? 2 : 0,
              focusElevation: look.elevation == ZenElevation.shadow ? 2 : 0,
              hoverElevation: look.elevation == ZenElevation.shadow ? 3 : 1,
              highlightElevation: look.elevation == ZenElevation.shadow ? 3 : 0,
              extendedTextStyle: TextStyle(
                fontFamily: colors.typeface.sans,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
              shape: look.buttons == ZenButtonShape.pill
                  ? const StadiumBorder()
                  : RoundedRectangleBorder(borderRadius: look.br(14)),
            ),
      tabBarTheme: TabBarThemeData(
        labelColor: lit ? colors.accent : colors.textPrimary,
        unselectedLabelColor: colors.textMuted,
        indicatorColor: colors.accent,
        indicatorSize: TabBarIndicatorSize.label,
        // The fixed palettes: a bar (lit and with a light running along it
        // in a glowing look, flat and square in a sharp one) that glides
        // between the tabs, no ripple under the label.
        indicator: colors.concept
            ? ZenTabIndicator(
                color: colors.accent,
                glow: bevel || !lit ? 0 : colors.glow,
                sweepColor: look.tabSweep ? colors.accentSecondary : null,
                thickness: bevel || look.sharp ? 2 : 3,
                rounded: !look.sharp,
              )
            : null,
        splashFactory: colors.concept ? NoSplash.splashFactory : null,
        overlayColor: colors.concept
            ? const WidgetStatePropertyAll<Color>(Color(0x00000000))
            : null,
        dividerColor: appBarEdge,
        labelStyle: TextStyle(
          fontFamily: colors.typeface.sans,
          fontWeight: FontWeight.w700,
          fontSize: 14,
        ),
        unselectedLabelStyle: TextStyle(
          fontFamily: colors.typeface.sans,
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: navBackground,
        surfaceTintColor: const Color(0x00000000),
        indicatorColor: navIndicatorColor,
        indicatorShape: navIndicator,
        elevation: 0,
        iconTheme: WidgetStateProperty.resolveWith<IconThemeData>(
          (Set<WidgetState> states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? colors.accent
                : colors.textMuted,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith<TextStyle>(
          (Set<WidgetState> states) => TextStyle(
            fontFamily: colors.typeface.sans,
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? colors.textPrimary
                : colors.textMuted,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: navBackground,
        indicatorColor: navIndicatorColor,
        indicatorShape: navIndicator,
        selectedIconTheme: IconThemeData(color: colors.accent),
        unselectedIconTheme: IconThemeData(color: colors.textMuted),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: const Color(0x00000000),
        shape: look.sharp ? const RoundedRectangleBorder() : null,
      ),
      badgeTheme: look.numbers == ZenNumberStyle.led
          // LED looks: an LCD count, accent digits on black.
          ? BadgeThemeData(
              backgroundColor: colors.surfaceSunk,
              textColor: colors.accent,
              textStyle: colors.mono(
                color: colors.accent,
                size: 10,
                weight: FontWeight.w700,
                height: 1,
              ),
            )
          : colors.concept
          ? BadgeThemeData(
              backgroundColor: colors.accent,
              textColor: colors.onAccent,
            )
          : null,
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: const Color(0x00000000),
        elevation: bevel ? 0 : null,
        titleTextStyle: TextStyle(
          fontFamily: colors.typeface.display,
          fontFamilyFallback: colors.typeface.displayFallback,
          color: colors.textPrimary,
          fontSize: 21 * colors.typeface.displayScale,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        shape: dialogShape,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: const Color(0x00000000),
        showDragHandle: true,
        dragHandleColor: lit ? colors.accent : colors.outlineStrong,
        shape: sheetShape,
      ),
    );
  }
}
