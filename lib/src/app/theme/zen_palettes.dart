import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_palettes_framed.dart';
import 'package:zen/src/app/theme/zen_palettes_wild.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The groups of the theme picker (Ustawienia → Wygląd).
enum ZenThemeCategory {
  classic,
  wild,
  toned,
  cool,
  elegant;

  String get label => switch (this) {
    ZenThemeCategory.classic => t('Klasyczne'),
    ZenThemeCategory.wild => t('Odjechane'),
    ZenThemeCategory.toned => t('Stonowane'),
    ZenThemeCategory.cool => t('Cool'),
    ZenThemeCategory.elegant => t('Eleganckie'),
  };

  String get caption => switch (this) {
    ZenThemeCategory.classic => t('Czytelne, zwyczajne, do wszystkiego.'),
    ZenThemeCategory.wild => t('Efekty, kształty i światło bez umiaru.'),
    ZenThemeCategory.toned => t('Ciche kolory, miękkie kształty.'),
    ZenThemeCategory.cool => t('Świecące linie, ekrany i maszyny.'),
    ZenThemeCategory.elegant => t('Szlachetne kolory, cienkie linie.'),
  };

  /// The palettes of this group, in picker order.
  List<AppPalette> get palettes => <AppPalette>[
    for (final AppPalette p in AppPalette.values)
      if (ZenPalettes.categoryOf(p) == this) p,
  ];
}

/// The palettes of Ustawienia → Wygląd: colours ([resolve]) and component
/// character ([look]). Klasyczny is computed from the chosen accent
/// ([ZenColors.resolve]); the others are hand-tuned, in a light and a dark
/// variant each (every theme has both, keeping its identity); the wild
/// ones are in [ZenWildPalettes] and the ones known by their frames in
/// [ZenFramedPalettes]. Every variant
/// keeps the contrast the theme test checks (body text 4.5:1 on every
/// surface, labels on the accent 4.5:1, faint text 3:1).
abstract final class ZenPalettes {
  static ZenColors resolve(
    AppPalette palette,
    AppAccentTheme accent,
    Brightness brightness,
  ) {
    final bool dark = brightness == Brightness.dark;
    return switch (palette) {
      AppPalette.classic => ZenColors.resolve(accent, brightness),
      AppPalette.ink => dark ? _inkDark : _inkLight,
      AppPalette.graphite => dark ? _graphiteDark : _graphiteLight,
      AppPalette.calm => dark ? _calmDark : _calmLight,
      AppPalette.forest => dark ? _forestDark : _forestLight,
      AppPalette.mist => dark ? _mistDark : _mistLight,
      AppPalette.neon => dark ? _neonDark : _neonLight,
      AppPalette.grid => dark ? _gridDark : _gridLight,
      AppPalette.rain => dark ? _rainDark : _rainLight,
      AppPalette.player => dark ? _retroDark : _retroLight,
      AppPalette.phosphor => dark ? _phosphorDark : _phosphorLight,
      AppPalette.dusk => dark ? _duskDark : _duskLight,
      AppPalette.onyx => dark ? _onyxDark : _onyxLight,
      AppPalette.pearl => dark ? _pearlDark : _pearlLight,
      AppPalette.cipher =>
        dark ? ZenWildPalettes.cipher : ZenWildPalettes.cipherLight,
      AppPalette.lightcycle =>
        dark ? ZenWildPalettes.lightcycle : ZenWildPalettes.lightcycleLight,
      AppPalette.fairy =>
        dark ? ZenWildPalettes.fairy : ZenWildPalettes.fairyLight,
      AppPalette.synthwave =>
        dark ? ZenWildPalettes.synthwave : ZenWildPalettes.synthwaveLight,
      AppPalette.neonCity =>
        dark ? ZenWildPalettes.neonCity : ZenWildPalettes.neonCityLight,
      AppPalette.arcade =>
        dark ? ZenWildPalettes.arcade : ZenWildPalettes.arcadeLight,
      AppPalette.space =>
        dark ? ZenWildPalettes.space : ZenWildPalettes.spaceLight,
      AppPalette.vapor =>
        dark ? ZenWildPalettes.vaporDark : ZenWildPalettes.vapor,
      AppPalette.deepSea =>
        dark ? ZenWildPalettes.deepSea : ZenWildPalettes.deepSeaLight,
      AppPalette.comic =>
        dark ? ZenWildPalettes.comicDark : ZenWildPalettes.comic,
      AppPalette.steam =>
        dark ? ZenWildPalettes.steamDark : ZenWildPalettes.steam,
      AppPalette.holo =>
        dark ? ZenWildPalettes.holo : ZenWildPalettes.holoLight,
      AppPalette.volcano =>
        dark ? ZenWildPalettes.volcano : ZenWildPalettes.volcanoLight,
      AppPalette.herbarium =>
        dark
            ? ZenFramedPalettes.herbariumDark
            : ZenFramedPalettes.herbariumLight,
      AppPalette.sweets =>
        dark ? ZenFramedPalettes.sweetsDark : ZenFramedPalettes.sweetsLight,
      AppPalette.cinema =>
        dark ? ZenFramedPalettes.cinemaDark : ZenFramedPalettes.cinemaLight,
      AppPalette.blueprint =>
        dark
            ? ZenFramedPalettes.blueprintDark
            : ZenFramedPalettes.blueprintLight,
      AppPalette.leather =>
        dark ? ZenFramedPalettes.leatherDark : ZenFramedPalettes.leatherLight,
    };
  }

  /// The picker group of [palette].
  static ZenThemeCategory categoryOf(AppPalette palette) => switch (palette) {
    AppPalette.classic ||
    AppPalette.ink ||
    AppPalette.graphite => ZenThemeCategory.classic,
    AppPalette.calm ||
    AppPalette.forest ||
    AppPalette.mist ||
    AppPalette.herbarium => ZenThemeCategory.toned,
    AppPalette.neon ||
    AppPalette.grid ||
    AppPalette.rain ||
    AppPalette.player ||
    AppPalette.phosphor ||
    AppPalette.blueprint => ZenThemeCategory.cool,
    AppPalette.dusk ||
    AppPalette.onyx ||
    AppPalette.pearl ||
    AppPalette.leather => ZenThemeCategory.elegant,
    AppPalette.cipher ||
    AppPalette.lightcycle ||
    AppPalette.fairy ||
    AppPalette.synthwave ||
    AppPalette.neonCity ||
    AppPalette.arcade ||
    AppPalette.space ||
    AppPalette.vapor ||
    AppPalette.deepSea ||
    AppPalette.comic ||
    AppPalette.steam ||
    AppPalette.holo ||
    AppPalette.volcano ||
    AppPalette.sweets ||
    AppPalette.cinema => ZenThemeCategory.wild,
  };

  /// The component character of [palette].
  static ZenLook look(AppPalette palette) => switch (palette) {
    AppPalette.classic => ZenLook.classic,
    AppPalette.ink => _ink,
    AppPalette.graphite => _graphite,
    AppPalette.calm => _calm,
    AppPalette.forest => ZenLook.soft,
    AppPalette.mist => _mist,
    AppPalette.neon => ZenLook.neon,
    AppPalette.grid => _grid,
    AppPalette.rain => _rain,
    AppPalette.player => ZenLook.retro,
    AppPalette.phosphor => _phosphor,
    AppPalette.dusk => _dusk,
    AppPalette.onyx => _onyx,
    AppPalette.pearl => _pearl,
    AppPalette.cipher => ZenWildPalettes.cipherLook,
    AppPalette.lightcycle => ZenWildPalettes.lightcycleLook,
    AppPalette.fairy => ZenWildPalettes.fairyLook,
    AppPalette.synthwave => ZenWildPalettes.synthwaveLook,
    AppPalette.neonCity => ZenWildPalettes.neonCityLook,
    AppPalette.arcade => ZenWildPalettes.arcadeLook,
    AppPalette.space => ZenWildPalettes.spaceLook,
    AppPalette.vapor => ZenWildPalettes.vaporLook,
    AppPalette.deepSea => ZenWildPalettes.deepSeaLook,
    AppPalette.comic => ZenWildPalettes.comicLook,
    AppPalette.steam => ZenWildPalettes.steamLook,
    AppPalette.holo => ZenWildPalettes.holoLook,
    AppPalette.volcano => ZenWildPalettes.volcanoLook,
    AppPalette.herbarium => ZenFramedPalettes.herbariumLook,
    AppPalette.sweets => ZenFramedPalettes.sweetsLook,
    AppPalette.cinema => ZenFramedPalettes.cinemaLook,
    AppPalette.blueprint => ZenFramedPalettes.blueprintLook,
    AppPalette.leather => ZenFramedPalettes.leatherLook,
  };

  // Atrament: paper and ink, nearly sharp corners, flat panels with a
  // clear line, underlined tabs.
  static const ZenLook _ink = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.hairline,
    buttons: ZenButtonShape.rounded,
    chips: ZenChipStyle.tag,
    nav: ZenNavStyle.underline,
    pages: ZenPageMotion.soft,
    corner: 0.25,
    tempo: 0.85,
  );

  // Grafit: the soft look with a thin glow of its neon accents.
  static const ZenLook _graphite = ZenLook(
    elevation: ZenElevation.glow,
    chips: ZenChipStyle.tag,
    pages: ZenPageMotion.soft,
    corner: 0.8,
  );

  // Cisza: rounder, slower, nothing lifted.
  static const ZenLook _calm = ZenLook(
    elevation: ZenElevation.flat,
    pages: ZenPageMotion.soft,
    corner: 1.15,
    tempo: 1.2,
    curve: Curves.easeInOutCubic,
  );

  // Mgła: very round, borderless panels apart by colour and space.
  static const ZenLook _mist = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    borders: ZenBorderStyle.none,
    dividers: ZenDividerStyle.none,
    pages: ZenPageMotion.soft,
    corner: 1.3,
    tempo: 1.25,
    curve: Curves.easeInOutCubic,
  );

  // Neonowa siatka: black, sharp corners, thin glowing cyan lines with an
  // orange counterpart, a floor grid running to the horizon.
  static const ZenLook _grid = ZenLook(
    surfaces: ZenSurfaceStyle.outlined,
    borders: ZenBorderStyle.glow,
    elevation: ZenElevation.glow,
    dividers: ZenDividerStyle.glow,
    buttons: ZenButtonShape.square,
    buttonFill: ZenButtonFill.line,
    chips: ZenChipStyle.outline,
    nav: ZenNavStyle.glow,
    backdrop: ZenBackdrop.grid,
    header: ZenHeaderStyle.brackets,
    sections: ZenSectionStyle.neonRule,
    pages: ZenPageMotion.neonWipe,
    corner: 0,
    tempo: 0.85,
    curve: Curves.easeOutExpo,
    breathe: true,
    flickerOn: true,
    tabSweep: true,
  );

  // Cyfrowy deszcz: a terminal, green signs running down behind it.
  static const ZenLook _rain = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.dashed,
    buttons: ZenButtonShape.square,
    buttonFill: ZenButtonFill.line,
    chips: ZenChipStyle.outline,
    nav: ZenNavStyle.block,
    fields: ZenFieldStyle.underline,
    backdrop: ZenBackdrop.rain,
    header: ZenHeaderStyle.prompt,
    sections: ZenSectionStyle.prompt,
    pages: ZenPageMotion.stepped,
    corner: 0,
    tempo: 0.7,
    curve: Curves.linear,
  );

  // Fosfor: an amber monitor, inverse-video buttons, scan lines.
  static const ZenLook _phosphor = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.dashed,
    buttons: ZenButtonShape.square,
    chips: ZenChipStyle.tag,
    nav: ZenNavStyle.block,
    fields: ZenFieldStyle.underline,
    backdrop: ZenBackdrop.scanlines,
    header: ZenHeaderStyle.prompt,
    sections: ZenSectionStyle.prompt,
    numbers: ZenNumberStyle.led,
    pages: ZenPageMotion.stepped,
    corner: 0.12,
    tempo: 0.8,
    curve: Curves.linear,
  );

  // Zmierzch: soft gradients, slow and smooth.
  static const ZenLook _dusk = ZenLook(
    elevation: ZenElevation.flat,
    buttonFill: ZenButtonFill.gradient,
    sections: ZenSectionStyle.ruled,
    header: ZenHeaderStyle.underline,
    pages: ZenPageMotion.soft,
    tempo: 1.2,
    curve: Curves.easeInOutCubic,
  );

  // Onyks: black and gold, double fine lines, underlined fields.
  static const ZenLook _onyx = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    borders: ZenBorderStyle.doubleLine,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.hairline,
    buttons: ZenButtonShape.rounded,
    chips: ZenChipStyle.outline,
    nav: ZenNavStyle.underline,
    fields: ZenFieldStyle.underline,
    header: ZenHeaderStyle.underline,
    sections: ZenSectionStyle.ruled,
    pages: ZenPageMotion.soft,
    corner: 0.35,
    tempo: 1.3,
    curve: Curves.easeInOutCubic,
  );

  // Perła: frosted glass over slowly drifting blooms of colour.
  static const ZenLook _pearl = ZenLook(
    surfaces: ZenSurfaceStyle.glass,
    buttonFill: ZenButtonFill.gradient,
    backdrop: ZenBackdrop.aurora,
    header: ZenHeaderStyle.underline,
    sections: ZenSectionStyle.ruled,
    pages: ZenPageMotion.soft,
    corner: 1.2,
    tempo: 1.2,
    curve: Curves.easeInOutCubic,
  );

  // Atrament, light: warm paper, navy ink and a red pencil.
  static const ZenColors _inkLight = ZenColors(
    background: Color(0xFFF7F6F2),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF0EFEA),
    surfaceMuted: Color(0xFFE7E5DE),
    surfaceSunk: Color(0xFFEFEDE7),
    outline: Color(0xFFCFCBC0),
    outlineSoft: Color(0xFFE0DDD4),
    outlineStrong: Color(0xFF9C978A),
    textPrimary: Color(0xFF14171F),
    textSecondary: Color(0xFF474C59),
    textMuted: Color(0xFF6E7380),
    accent: Color(0xFF1F3B8C),
    accentSecondary: Color(0xFFB3261E),
    accentTertiary: Color(0xFF2E6B5E),
    accentSoft: Color(0xFFE6EAF5),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1E7A4C),
    warning: Color(0xFF9A5B00),
    danger: Color(0xFFB3261E),
    concept: true,
    gradient: 0,
    toneSaturation: 0.45,
  );

  // Atrament, dark: night desk, pale blue ink.
  static const ZenColors _inkDark = ZenColors(
    background: Color(0xFF0F1115),
    surface: Color(0xFF161920),
    surfaceRaised: Color(0xFF1C2029),
    surfaceMuted: Color(0xFF232834),
    surfaceSunk: Color(0xFF0B0D10),
    outline: Color(0xFF2C3240),
    outlineSoft: Color(0xFF222733),
    outlineStrong: Color(0xFF465066),
    textPrimary: Color(0xFFECEEF2),
    textSecondary: Color(0xFFA9B0BE),
    textMuted: Color(0xFF7D8597),
    accent: Color(0xFF8FB0FF),
    accentSecondary: Color(0xFFFF8A80),
    accentTertiary: Color(0xFF7FD1B9),
    accentSoft: Color(0xFF1E2740),
    onAccent: Color(0xFF0F1115),
    success: Color(0xFF6FD6A0),
    warning: Color(0xFFF0C060),
    danger: Color(0xFFFF8A80),
    concept: true,
    gradient: 0,
    toneSaturation: 0.45,
  );

  // Mgła, light: fog over water, a muted blue-grey.
  static const ZenColors _mistLight = ZenColors(
    background: Color(0xFFEEF1F4),
    surface: Color(0xFFF8FAFB),
    surfaceRaised: Color(0xFFE7EBEF),
    surfaceMuted: Color(0xFFDEE3E8),
    surfaceSunk: Color(0xFFE9EDF1),
    outline: Color(0xFFD3D9E0),
    outlineSoft: Color(0xFFE1E6EB),
    outlineStrong: Color(0xFFA9B3BE),
    textPrimary: Color(0xFF1E2630),
    textSecondary: Color(0xFF4E5A67),
    textMuted: Color(0xFF6E7985),
    accent: Color(0xFF4F7390),
    accentSecondary: Color(0xFF6F7F96),
    accentTertiary: Color(0xFF6F8C82),
    accentSoft: Color(0xFFE3EAF0),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF3F7F66),
    warning: Color(0xFF9A7432),
    danger: Color(0xFFA65454),
    concept: true,
    gradient: 0.2,
    toneSaturation: 0.2,
  );

  // Mgła, dark: fog at night.
  static const ZenColors _mistDark = ZenColors(
    background: Color(0xFF14181D),
    surface: Color(0xFF1A1F25),
    surfaceRaised: Color(0xFF20262D),
    surfaceMuted: Color(0xFF272E36),
    surfaceSunk: Color(0xFF101317),
    outline: Color(0xFF2E3640),
    outlineSoft: Color(0xFF252C34),
    outlineStrong: Color(0xFF46515D),
    textPrimary: Color(0xFFE3E8ED),
    textSecondary: Color(0xFFA3AEB9),
    textMuted: Color(0xFF7D8893),
    accent: Color(0xFF9DB7CC),
    accentSecondary: Color(0xFFAAB4C6),
    accentTertiary: Color(0xFFA9C2B8),
    accentSoft: Color(0xFF2A333C),
    onAccent: Color(0xFF14181D),
    success: Color(0xFF8CC7AB),
    warning: Color(0xFFD8BA82),
    danger: Color(0xFFE09A96),
    concept: true,
    gradient: 0.2,
    toneSaturation: 0.2,
  );

  // Neonowa siatka: black, an electric cyan and a hot orange.
  static const ZenColors _gridDark = ZenColors(
    background: Color(0xFF02040A),
    surface: Color(0xFF050A12),
    surfaceRaised: Color(0xFF08111C),
    surfaceMuted: Color(0xFF0C1826),
    surfaceSunk: Color(0xFF000000),
    outline: Color(0xFF0F3A4A),
    outlineSoft: Color(0xFF0A2532),
    outlineStrong: Color(0xFF1A7590),
    textPrimary: Color(0xFFE6FBFF),
    textSecondary: Color(0xFF9CC9D6),
    textMuted: Color(0xFF5E8D9B),
    accent: Color(0xFF18E6FF),
    accentSecondary: Color(0xFFFF8A1F),
    accentTertiary: Color(0xFF7FF4FF),
    accentSoft: Color(0xFF032530),
    onAccent: Color(0xFF000000),
    success: Color(0xFF3DFFB8),
    warning: Color(0xFFFFB020),
    danger: Color(0xFFFF4D3D),
    concept: true,
    glow: 1.2,
    gradient: 0,
    toneSaturation: 0.7,
    duotone: true,
  );

  // Cyfrowy deszcz: black, phosphor green, a pale green-white for text.
  static const ZenColors _rainDark = ZenColors(
    background: Color(0xFF000300),
    surface: Color(0xFF020A03),
    surfaceRaised: Color(0xFF041206),
    surfaceMuted: Color(0xFF071A0A),
    surfaceSunk: Color(0xFF000000),
    outline: Color(0xFF0D3A14),
    outlineSoft: Color(0xFF08260D),
    outlineStrong: Color(0xFF17702A),
    textPrimary: Color(0xFFD7FFD9),
    textSecondary: Color(0xFF7FD88A),
    textMuted: Color(0xFF4E9A58),
    accent: Color(0xFF3BFF5A),
    accentSecondary: Color(0xFFB6FF3B),
    accentTertiary: Color(0xFF00D27A),
    accentSoft: Color(0xFF062A0C),
    onAccent: Color(0xFF000000),
    success: Color(0xFF3BFF5A),
    warning: Color(0xFFE8FF5A),
    danger: Color(0xFFFF4B3B),
    concept: true,
    glow: 0.6,
    gradient: 0,
    toneSaturation: 0.6,
    duotone: true,
  );

  // Fosfor: an amber monitor.
  static const ZenColors _phosphorDark = ZenColors(
    background: Color(0xFF0A0602),
    surface: Color(0xFF120C04),
    surfaceRaised: Color(0xFF1A1206),
    surfaceMuted: Color(0xFF231908),
    surfaceSunk: Color(0xFF050301),
    outline: Color(0xFF3A2A0E),
    outlineSoft: Color(0xFF2A1E09),
    outlineStrong: Color(0xFF6B4E17),
    textPrimary: Color(0xFFFFE3B0),
    textSecondary: Color(0xFFE0AE5C),
    textMuted: Color(0xFFA87D3A),
    accent: Color(0xFFFFB000),
    accentSecondary: Color(0xFFFFD27A),
    accentTertiary: Color(0xFFFF7A1A),
    accentSoft: Color(0xFF2E1F05),
    onAccent: Color(0xFF000000),
    success: Color(0xFFC8E05A),
    warning: Color(0xFFFFD27A),
    danger: Color(0xFFFF5A3A),
    concept: true,
    glow: 0.4,
    gradient: 0,
    toneSaturation: 0.55,
    duotone: true,
  );

  // Onyks, dark: black stone and gold.
  static const ZenColors _onyxDark = ZenColors(
    background: Color(0xFF0B0B0C),
    surface: Color(0xFF121214),
    surfaceRaised: Color(0xFF18181B),
    surfaceMuted: Color(0xFF1F1F23),
    surfaceSunk: Color(0xFF070708),
    outline: Color(0xFF3A3324),
    outlineSoft: Color(0xFF26231C),
    outlineStrong: Color(0xFF6E5E3A),
    textPrimary: Color(0xFFF3EEE4),
    textSecondary: Color(0xFFB8AF9E),
    textMuted: Color(0xFF857D6E),
    accent: Color(0xFFD4B26A),
    accentSecondary: Color(0xFFB9A27A),
    accentTertiary: Color(0xFF8FA3A8),
    accentSoft: Color(0xFF2A2518),
    onAccent: Color(0xFF0B0B0C),
    success: Color(0xFF8FC79A),
    warning: Color(0xFFE3C278),
    danger: Color(0xFFE0806F),
    concept: true,
    gradient: 0.15,
    toneSaturation: 0.3,
    duotone: true,
  );

  // Onyks, light: ivory paper and dark gold.
  static const ZenColors _onyxLight = ZenColors(
    background: Color(0xFFF6F2EA),
    surface: Color(0xFFFFFDF8),
    surfaceRaised: Color(0xFFEFE9DD),
    surfaceMuted: Color(0xFFE6DFD0),
    surfaceSunk: Color(0xFFF0EBE1),
    outline: Color(0xFFD6CBB3),
    outlineSoft: Color(0xFFE5DDCB),
    outlineStrong: Color(0xFFA8946A),
    textPrimary: Color(0xFF1A1814),
    textSecondary: Color(0xFF4F493E),
    textMuted: Color(0xFF756D5E),
    accent: Color(0xFF7A5A14),
    accentSecondary: Color(0xFF5E5440),
    accentTertiary: Color(0xFF3F5D63),
    accentSoft: Color(0xFFF0E8D6),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF3E7A4E),
    warning: Color(0xFF8A6110),
    danger: Color(0xFFA3402F),
    concept: true,
    gradient: 0.15,
    toneSaturation: 0.3,
    duotone: true,
  );

  // Perła, light: pearl white, rose and lilac.
  static const ZenColors _pearlLight = ZenColors(
    background: Color(0xFFF7F1F2),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF4ECEE),
    surfaceMuted: Color(0xFFEDE3E6),
    surfaceSunk: Color(0xFFF2EAEC),
    outline: Color(0xFFE6D8DC),
    outlineSoft: Color(0xFFEFE5E8),
    outlineStrong: Color(0xFFC3AEB4),
    textPrimary: Color(0xFF2A1E22),
    textSecondary: Color(0xFF5E4C52),
    textMuted: Color(0xFF85727A),
    accent: Color(0xFFA4506A),
    accentSecondary: Color(0xFF7E5DB0),
    accentTertiary: Color(0xFFA8703F),
    accentSoft: Color(0xFFF6E7EC),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF3C8A6A),
    warning: Color(0xFFA0701C),
    danger: Color(0xFFC23B4E),
    concept: true,
    gradient: 0.6,
    toneSaturation: 0.4,
  );

  // Perła, dark: deep plum glass.
  static const ZenColors _pearlDark = ZenColors(
    background: Color(0xFF17121A),
    surface: Color(0xFF1E1822),
    surfaceRaised: Color(0xFF251E2A),
    surfaceMuted: Color(0xFF2D2533),
    surfaceSunk: Color(0xFF120E15),
    outline: Color(0xFF3A3040),
    outlineSoft: Color(0xFF2C2532),
    outlineStrong: Color(0xFF5A4C62),
    textPrimary: Color(0xFFF4ECF1),
    textSecondary: Color(0xFFBFAFBA),
    textMuted: Color(0xFF928390),
    accent: Color(0xFFE79AB4),
    accentSecondary: Color(0xFFB9A0E6),
    accentTertiary: Color(0xFFE2B48C),
    accentSoft: Color(0xFF3A2632),
    onAccent: Color(0xFF17121A),
    success: Color(0xFF86D2AE),
    warning: Color(0xFFE8C27C),
    danger: Color(0xFFF0919E),
    concept: true,
    gradient: 0.6,
    toneSaturation: 0.4,
  );

  // Neon: true black, almost no greys, one electric cyan and a hot
  // magenta kept for a few accents; off-white text.
  static const ZenColors _neonDark = ZenColors(
    background: Color(0xFF000000),
    surface: Color(0xFF050508),
    surfaceRaised: Color(0xFF0A0B10),
    surfaceMuted: Color(0xFF101219),
    surfaceSunk: Color(0xFF000000),
    outline: Color(0xFF113A42),
    outlineSoft: Color(0xFF0B252B),
    outlineStrong: Color(0xFF1B6C78),
    textPrimary: Color(0xFFF2F8FA),
    textSecondary: Color(0xFFA6C2CA),
    textMuted: Color(0xFF63848D),
    accent: Color(0xFF00F0FF),
    accentSecondary: Color(0xFFFF2BD6),
    accentTertiary: Color(0xFF7DF9FF),
    accentSoft: Color(0xFF00262B),
    onAccent: Color(0xFF000000),
    success: Color(0xFF2BFFC6),
    warning: Color(0xFFFFE45C),
    danger: Color(0xFFFF2B6B),
    concept: true,
    glow: 1.3,
    gradient: 0,
    toneSaturation: 0.7,
    duotone: true,
  );

  // Neon, light: a deliberately plain companion, white with ink-dark cyan
  // lines and the same few accents.
  static const ZenColors _neonLight = ZenColors(
    background: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFF4FAFB),
    surfaceMuted: Color(0xFFE9F4F6),
    surfaceSunk: Color(0xFFF6FBFC),
    outline: Color(0xFFA6DCE3),
    outlineSoft: Color(0xFFCFEDF1),
    outlineStrong: Color(0xFF4FAFBC),
    textPrimary: Color(0xFF04080A),
    textSecondary: Color(0xFF3A5157),
    textMuted: Color(0xFF6A8389),
    accent: Color(0xFF007C8A),
    accentSecondary: Color(0xFFC2008F),
    accentTertiary: Color(0xFF00636E),
    accentSoft: Color(0xFFE0F5F7),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF00806A),
    warning: Color(0xFF9A6A00),
    danger: Color(0xFFC8004F),
    concept: true,
    glow: 0.45,
    gradient: 0,
    toneSaturation: 0.7,
    duotone: true,
  );

  // Retro: charcoal chrome around black LCD wells, LCD green with a
  // yellow-green and an orange peak, like an old desktop music player.
  static const ZenColors _retroDark = ZenColors(
    background: Color(0xFF0B0C0F),
    surface: Color(0xFF17181E),
    surfaceRaised: Color(0xFF22232B),
    surfaceMuted: Color(0xFF2B2C36),
    surfaceSunk: Color(0xFF000000),
    outline: Color(0xFF34363F),
    outlineSoft: Color(0xFF26272F),
    outlineStrong: Color(0xFF5B5E6B),
    textPrimary: Color(0xFFDCEBD4),
    textSecondary: Color(0xFF9AB192),
    textMuted: Color(0xFF6C7E65),
    accent: Color(0xFF4AF626),
    accentSecondary: Color(0xFFDCE93A),
    accentTertiary: Color(0xFFFF9F1C),
    accentSoft: Color(0xFF12260F),
    onAccent: Color(0xFF000000),
    success: Color(0xFF4AF626),
    warning: Color(0xFFDCE93A),
    danger: Color(0xFFFF4A3A),
    concept: true,
    glow: 0.35,
    gradient: 0.2,
    toneSaturation: 0.5,
    duotone: true,
  );

  // Cisza, light: sand and stone, one slate accent.
  static const ZenColors _calmLight = ZenColors(
    background: Color(0xFFF3F0EA),
    surface: Color(0xFFFBFAF7),
    surfaceRaised: Color(0xFFEEEAE3),
    surfaceMuted: Color(0xFFE6E1D9),
    surfaceSunk: Color(0xFFEDE9E2),
    outline: Color(0xFFDCD6CC),
    outlineSoft: Color(0xFFE7E2DA),
    outlineStrong: Color(0xFFB8B0A4),
    textPrimary: Color(0xFF2A2825),
    textSecondary: Color(0xFF625C54),
    textMuted: Color(0xFF8C857B),
    accent: Color(0xFF52707F),
    accentSecondary: Color(0xFF7D9A8C),
    accentTertiary: Color(0xFFA88B74),
    accentSoft: Color(0xFFE7E9E9),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF4F8A6A),
    warning: Color(0xFFA87A2E),
    danger: Color(0xFFB2504A),
    concept: true,
    gradient: 0,
    toneSaturation: 0.22,
  );

  // Cisza, dark: warm graphite, a muted slate.
  static const ZenColors _calmDark = ZenColors(
    background: Color(0xFF151413),
    surface: Color(0xFF1C1B19),
    surfaceRaised: Color(0xFF232220),
    surfaceMuted: Color(0xFF2B2926),
    surfaceSunk: Color(0xFF111010),
    outline: Color(0xFF33302C),
    outlineSoft: Color(0xFF292724),
    outlineStrong: Color(0xFF4A4640),
    textPrimary: Color(0xFFEAE6DF),
    textSecondary: Color(0xFFA9A298),
    textMuted: Color(0xFF7C766D),
    accent: Color(0xFF9FB5C1),
    accentSecondary: Color(0xFFA7BCAF),
    accentTertiary: Color(0xFFC9B39D),
    accentSoft: Color(0xFF313434),
    onAccent: Color(0xFF151413),
    success: Color(0xFF8CC2A2),
    warning: Color(0xFFD9B675),
    danger: Color(0xFFE08A80),
    concept: true,
    gradient: 0,
    toneSaturation: 0.22,
  );

  // Grafit, light: pale grey with the same cyan and magenta lines.
  static const ZenColors _graphiteLight = ZenColors(
    background: Color(0xFFF2F4F7),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFECEFF3),
    surfaceMuted: Color(0xFFE3E7ED),
    surfaceSunk: Color(0xFFEDF0F4),
    outline: Color(0xFFD5DBE3),
    outlineSoft: Color(0xFFE2E7ED),
    outlineStrong: Color(0xFFA8B2BE),
    textPrimary: Color(0xFF12161B),
    textSecondary: Color(0xFF4C5763),
    textMuted: Color(0xFF7A8591),
    accent: Color(0xFF00A3BD),
    accentSecondary: Color(0xFFD639B3),
    accentTertiary: Color(0xFF7356F0),
    accentSoft: Color(0xFFE0F4F7),
    onAccent: Color(0xFF0A0C0E),
    success: Color(0xFF0E9F6E),
    warning: Color(0xFFB87500),
    danger: Color(0xFFD92550),
    concept: true,
    glow: 0.5,
    gradient: 0.35,
    toneSaturation: 0.7,
  );

  // Grafit: muted charcoal, thin cyan and magenta neon.
  static const ZenColors _graphiteDark = ZenColors(
    background: Color(0xFF0D0F12),
    surface: Color(0xFF13161A),
    surfaceRaised: Color(0xFF191D22),
    surfaceMuted: Color(0xFF20252B),
    surfaceSunk: Color(0xFF090B0D),
    outline: Color(0xFF252A31),
    outlineSoft: Color(0xFF1C2026),
    outlineStrong: Color(0xFF39404A),
    textPrimary: Color(0xFFE6ECF0),
    textSecondary: Color(0xFF98A4AE),
    textMuted: Color(0xFF69737E),
    accent: Color(0xFF2FE3F2),
    accentSecondary: Color(0xFFFF52D9),
    accentTertiary: Color(0xFF9E80FF),
    accentSoft: Color(0xFF17373D),
    onAccent: Color(0xFF06080A),
    success: Color(0xFF3DF2A0),
    warning: Color(0xFFFFD166),
    danger: Color(0xFFFF5C7A),
    concept: true,
    glow: 1.0,
    gradient: 0.35,
    toneSaturation: 0.7,
  );

  // Las, light: warm paper, deep green ink.
  static const ZenColors _forestLight = ZenColors(
    background: Color(0xFFF4F0E6),
    surface: Color(0xFFFBF8F0),
    surfaceRaised: Color(0xFFEEE9DC),
    surfaceMuted: Color(0xFFE6E0D1),
    surfaceSunk: Color(0xFFEFEADE),
    outline: Color(0xFFDBD3C1),
    outlineSoft: Color(0xFFE6DFCF),
    outlineStrong: Color(0xFFB4AA94),
    textPrimary: Color(0xFF1D2920),
    textSecondary: Color(0xFF535E4D),
    textMuted: Color(0xFF838A79),
    accent: Color(0xFF3B6A4A),
    accentSecondary: Color(0xFF8A6E3C),
    accentTertiary: Color(0xFF5A8878),
    accentSoft: Color(0xFFE4E7DC),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2F7D4F),
    warning: Color(0xFFA06A10),
    danger: Color(0xFFB14A3A),
    concept: true,
    gradient: 0.3,
    toneSaturation: 0.3,
  );

  // Las, dark: deep moss, warm off-white.
  static const ZenColors _forestDark = ZenColors(
    background: Color(0xFF0E1411),
    surface: Color(0xFF141C18),
    surfaceRaised: Color(0xFF1A241F),
    surfaceMuted: Color(0xFF212C26),
    surfaceSunk: Color(0xFF0A0F0C),
    outline: Color(0xFF29352E),
    outlineSoft: Color(0xFF1F2923),
    outlineStrong: Color(0xFF3E4D44),
    textPrimary: Color(0xFFEBECE3),
    textSecondary: Color(0xFFA7AFA0),
    textMuted: Color(0xFF767E6E),
    accent: Color(0xFF9CC48A),
    accentSecondary: Color(0xFFCDBB8C),
    accentTertiary: Color(0xFF84B4A3),
    accentSoft: Color(0xFF2A372A),
    onAccent: Color(0xFF0E1411),
    success: Color(0xFF8FD49F),
    warning: Color(0xFFE2C277),
    danger: Color(0xFFE6907F),
    concept: true,
    gradient: 0.3,
    toneSaturation: 0.3,
  );

  // Zmierzch, light: lavender white, the logo violet toned down.
  static const ZenColors _duskLight = ZenColors(
    background: Color(0xFFF6F4FA),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFEFECF6),
    surfaceMuted: Color(0xFFE6E2F0),
    surfaceSunk: Color(0xFFF0EDF6),
    outline: Color(0xFFDAD4E8),
    outlineSoft: Color(0xFFE6E1F0),
    outlineStrong: Color(0xFFACA4C4),
    textPrimary: Color(0xFF1A1726),
    textSecondary: Color(0xFF56506F),
    textMuted: Color(0xFF847E99),
    accent: Color(0xFF6252C4),
    accentSecondary: Color(0xFF4E62C2),
    accentTertiary: Color(0xFFB0628F),
    accentSoft: Color(0xFFECEAF8),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F9A6A),
    warning: Color(0xFFB07410),
    danger: Color(0xFFD0345C),
    concept: true,
    gradient: 0.75,
    toneSaturation: 0.42,
  );

  // Zmierzch, dark: night indigo, the logo violet.
  static const ZenColors _duskDark = ZenColors(
    background: Color(0xFF110F19),
    surface: Color(0xFF171522),
    surfaceRaised: Color(0xFF1E1B2C),
    surfaceMuted: Color(0xFF262236),
    surfaceSunk: Color(0xFF0C0B12),
    outline: Color(0xFF2D2841),
    outlineSoft: Color(0xFF221F32),
    outlineStrong: Color(0xFF453D5D),
    textPrimary: Color(0xFFEDE9F6),
    textSecondary: Color(0xFFACA5C1),
    textMuted: Color(0xFF7B7490),
    accent: Color(0xFFA898F0),
    accentSecondary: Color(0xFF7E91E6),
    accentTertiary: Color(0xFFDDA0C6),
    accentSoft: Color(0xFF2E2A43),
    onAccent: Color(0xFF110F19),
    success: Color(0xFF6FD9A8),
    warning: Color(0xFFF2C46D),
    danger: Color(0xFFF2838F),
    concept: true,
    gradient: 0.75,
    toneSaturation: 0.42,
  );

  // Neonowa siatka, light: white floor, ink-cyan lines, an orange trace.
  static const ZenColors _gridLight = ZenColors(
    background: Color(0xFFF4FBFD),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFEAF6F9),
    surfaceMuted: Color(0xFFDDEFF3),
    surfaceSunk: Color(0xFFEEF8FA),
    outline: Color(0xFFA9D9E3),
    outlineSoft: Color(0xFFCFEAF0),
    outlineStrong: Color(0xFF3E9DB0),
    textPrimary: Color(0xFF03151A),
    textSecondary: Color(0xFF25525C),
    textMuted: Color(0xFF4E7680),
    accent: Color(0xFF007A8C),
    accentSecondary: Color(0xFFB85400),
    accentTertiary: Color(0xFF005F6D),
    accentSoft: Color(0xFFDDF3F7),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF007A55),
    warning: Color(0xFF8F5A00),
    danger: Color(0xFFC2261A),
    concept: true,
    glow: 0.6,
    gradient: 0,
    toneSaturation: 0.7,
    duotone: true,
  );

  // Cyfrowy deszcz, light: dark green signs on pale phosphor paper.
  static const ZenColors _rainLight = ZenColors(
    background: Color(0xFFEEF7EC),
    surface: Color(0xFFF8FCF6),
    surfaceRaised: Color(0xFFE4F0E1),
    surfaceMuted: Color(0xFFD8E8D4),
    surfaceSunk: Color(0xFFE9F3E6),
    outline: Color(0xFFB5D1AE),
    outlineSoft: Color(0xFFCFE3CA),
    outlineStrong: Color(0xFF5E8F55),
    textPrimary: Color(0xFF0A1F0C),
    textSecondary: Color(0xFF2E4F31),
    textMuted: Color(0xFF4F6F52),
    accent: Color(0xFF1F7A2E),
    accentSecondary: Color(0xFF4F6B00),
    accentTertiary: Color(0xFF007A55),
    accentSoft: Color(0xFFDCEFD8),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F7A2E),
    warning: Color(0xFF7A6200),
    danger: Color(0xFFB3261E),
    concept: true,
    glow: 0.3,
    gradient: 0,
    toneSaturation: 0.6,
    duotone: true,
  );

  // Odtwarzacz, light: a silver aluminium skin with reflective LCD wells.
  static const ZenColors _retroLight = ZenColors(
    background: Color(0xFFD9DCE1),
    surface: Color(0xFFE8EAEE),
    surfaceRaised: Color(0xFFF2F3F6),
    surfaceMuted: Color(0xFFCFD3D9),
    surfaceSunk: Color(0xFFC4D0B0),
    outline: Color(0xFFA8ADB6),
    outlineSoft: Color(0xFFBFC3CA),
    outlineStrong: Color(0xFF6E7480),
    textPrimary: Color(0xFF15171C),
    textSecondary: Color(0xFF3A3F48),
    textMuted: Color(0xFF5C626C),
    accent: Color(0xFF2B5E12),
    accentSecondary: Color(0xFF5C5E00),
    accentTertiary: Color(0xFF9A4A00),
    accentSoft: Color(0xFFD2DEC0),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2B6E12),
    warning: Color(0xFF7A5A00),
    danger: Color(0xFFB02A1E),
    concept: true,
    gradient: 0.2,
    toneSaturation: 0.5,
    duotone: true,
  );

  // Fosfor, light: brown-amber type on cream printer paper.
  static const ZenColors _phosphorLight = ZenColors(
    background: Color(0xFFFBF4E6),
    surface: Color(0xFFFFFBF2),
    surfaceRaised: Color(0xFFF4EAD6),
    surfaceMuted: Color(0xFFEADCC0),
    surfaceSunk: Color(0xFFF6EDDB),
    outline: Color(0xFFD9C39A),
    outlineSoft: Color(0xFFE8D9BA),
    outlineStrong: Color(0xFF9C7838),
    textPrimary: Color(0xFF2A1800),
    textSecondary: Color(0xFF5A3E10),
    textMuted: Color(0xFF7A5C2A),
    accent: Color(0xFF8A5300),
    accentSecondary: Color(0xFF6E4A00),
    accentTertiary: Color(0xFFA0430A),
    accentSoft: Color(0xFFF5E5C3),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF4F6B00),
    warning: Color(0xFF7A5200),
    danger: Color(0xFFA8301C),
    concept: true,
    glow: 0.2,
    gradient: 0,
    toneSaturation: 0.55,
    duotone: true,
  );
}
