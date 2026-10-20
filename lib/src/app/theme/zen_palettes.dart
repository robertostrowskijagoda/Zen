import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The fixed palettes of Ustawienia → Wygląd. Klasyczny is computed from
/// the chosen accent ([ZenColors.resolve]); the others are hand-tuned, each
/// in a light and a dark variant, and share the calmer component style
/// ([ZenColors.concept]). Every pair keeps the contrast the theme test
/// checks (labels on the accent 4.5:1, body text 4.5:1, secondary 3:1).
abstract final class ZenPalettes {
  static ZenColors resolve(
    AppPalette palette,
    AppAccentTheme accent,
    Brightness brightness,
  ) {
    final bool dark = brightness == Brightness.dark;
    return switch (palette) {
      AppPalette.classic => ZenColors.resolve(accent, brightness),
      AppPalette.calm => dark ? _calmDark : _calmLight,
      AppPalette.neon => dark ? _neonDark : _neonLight,
      AppPalette.forest => dark ? _forestDark : _forestLight,
      AppPalette.dusk => dark ? _duskDark : _duskLight,
    };
  }

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
    typeface: ZenTypefaces.zen,
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
    typeface: ZenTypefaces.zen,
    concept: true,
    gradient: 0,
    toneSaturation: 0.22,
  );

  // Neon nocą, light: pale grey with the same cyan and magenta lines.
  static const ZenColors _neonLight = ZenColors(
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
    typeface: ZenTypefaces.zen,
    concept: true,
    glow: 0.5,
    gradient: 0.35,
    toneSaturation: 0.7,
  );

  // Neon nocą: muted charcoal, thin cyan and magenta neon.
  static const ZenColors _neonDark = ZenColors(
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
    typeface: ZenTypefaces.zen,
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
    typeface: ZenTypefaces.zen,
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
    typeface: ZenTypefaces.zen,
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
    typeface: ZenTypefaces.zen,
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
    typeface: ZenTypefaces.zen,
    concept: true,
    gradient: 0.75,
    toneSaturation: 0.42,
  );
}
