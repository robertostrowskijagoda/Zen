import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The palettes that differ most in their frames ([ZenBorderStyle]): a
/// herbarium with leaf-shaped panels, a candy shop with scalloped edges,
/// a cinema with ticket bites, a drawing board with corner marks and
/// leather with stitches. Each is a palette ([ZenColors]) in a dark and a
/// light variant and a character ([ZenLook]); every variant keeps the
/// contrast the theme test checks.
abstract final class ZenFramedPalettes {
  // Zielnik, light: pressed-flower paper, moss ink, terracotta and plum.
  static const ZenColors herbariumLight = ZenColors(
    background: Color(0xFFF4F1E6),
    surface: Color(0xFFFBF9F1),
    surfaceRaised: Color(0xFFEDE9DA),
    surfaceMuted: Color(0xFFE2DDCB),
    surfaceSunk: Color(0xFFE9E5D5),
    outline: Color(0xFFC9C3AA),
    outlineSoft: Color(0xFFDDD8C2),
    outlineStrong: Color(0xFF817D61),
    textPrimary: Color(0xFF1F2A1C),
    textSecondary: Color(0xFF435040),
    textMuted: Color(0xFF5A6454),
    accent: Color(0xFF3F6B3A),
    accentSecondary: Color(0xFFA85A1A),
    accentTertiary: Color(0xFF7A4B73),
    accentSoft: Color(0xFFE3EAD6),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF286D45),
    warning: Color(0xFF855609),
    danger: Color(0xFFB3261E),
    concept: true,
    gradient: 0.3,
    toneSaturation: 0.5,
  );

  // Zielnik, dark: a greenhouse at night, pale moss and warm amber.
  static const ZenColors herbariumDark = ZenColors(
    background: Color(0xFF121A12),
    surface: Color(0xFF1A241A),
    surfaceRaised: Color(0xFF223022),
    surfaceMuted: Color(0xFF2B3B2B),
    surfaceSunk: Color(0xFF0D140D),
    outline: Color(0xFF3B503B),
    outlineSoft: Color(0xFF2C3E2C),
    outlineStrong: Color(0xFF6E8F6A),
    textPrimary: Color(0xFFEEF3E6),
    textSecondary: Color(0xFFB9C7B0),
    textMuted: Color(0xFF8DA086),
    accent: Color(0xFF9BD18A),
    accentSecondary: Color(0xFFE8B06A),
    accentTertiary: Color(0xFFC9A6E0),
    accentSoft: Color(0xFF24361F),
    onAccent: Color(0xFF10210D),
    success: Color(0xFF8FD19E),
    warning: Color(0xFFE8C26A),
    danger: Color(0xFFF08A7E),
    concept: true,
    gradient: 0.3,
    toneSaturation: 0.5,
  );

  // Cukiernia, light: icing pink, raspberry, mint and caramel.
  static const ZenColors sweetsLight = ZenColors(
    background: Color(0xFFFFF3F7),
    surface: Color(0xFFFFFAFC),
    surfaceRaised: Color(0xFFFFE9F1),
    surfaceMuted: Color(0xFFFADCE8),
    surfaceSunk: Color(0xFFFFEAF2),
    outline: Color(0xFFF0B9CF),
    outlineSoft: Color(0xFFF8D3E2),
    outlineStrong: Color(0xFFBA668B),
    textPrimary: Color(0xFF3A1026),
    textSecondary: Color(0xFF6B3A55),
    textMuted: Color(0xFF86556E),
    accent: Color(0xFFC2185B),
    accentSecondary: Color(0xFF0F8F78),
    accentTertiary: Color(0xFFB8650A),
    accentSoft: Color(0xFFFFE0EC),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1C7347),
    warning: Color(0xFF925600),
    danger: Color(0xFFB3261E),
    concept: true,
    gradient: 0.35,
    toneSaturation: 0.8,
  );

  // Cukiernia, dark: plum chocolate with pink icing and mint.
  static const ZenColors sweetsDark = ZenColors(
    background: Color(0xFF1E0F1A),
    surface: Color(0xFF2A1624),
    surfaceRaised: Color(0xFF351C2E),
    surfaceMuted: Color(0xFF432338),
    surfaceSunk: Color(0xFF150910),
    outline: Color(0xFF5E3350),
    outlineSoft: Color(0xFF46273C),
    outlineStrong: Color(0xFFB5668C),
    textPrimary: Color(0xFFFFEFF6),
    textSecondary: Color(0xFFE8C3D6),
    textMuted: Color(0xFFBF93AD),
    accent: Color(0xFFFF8FBF),
    accentSecondary: Color(0xFF7FE3CE),
    accentTertiary: Color(0xFFFFC76B),
    accentSoft: Color(0xFF4A1F38),
    onAccent: Color(0xFF2A0A1B),
    success: Color(0xFF8EE3B0),
    warning: Color(0xFFFFC76B),
    danger: Color(0xFFFF8A8A),
    concept: true,
    gradient: 0.35,
    toneSaturation: 0.8,
  );

  // Kino, light: cream programme paper, velvet red and old gold.
  static const ZenColors cinemaLight = ZenColors(
    background: Color(0xFFFBF2E4),
    surface: Color(0xFFFFFBF3),
    surfaceRaised: Color(0xFFF4E7D2),
    surfaceMuted: Color(0xFFEBD9BC),
    surfaceSunk: Color(0xFFF1E4CE),
    outline: Color(0xFFD6BF9A),
    outlineSoft: Color(0xFFE6D6B6),
    outlineStrong: Color(0xFF9E732C),
    textPrimary: Color(0xFF2A0D12),
    textSecondary: Color(0xFF5A2B32),
    textMuted: Color(0xFF7A5256),
    accent: Color(0xFF8E1B2D),
    accentSecondary: Color(0xFF946A1A),
    accentTertiary: Color(0xFF4A2C5A),
    accentSoft: Color(0xFFF3DDD3),
    onAccent: Color(0xFFFFF3E0),
    success: Color(0xFF1B6D44),
    warning: Color(0xFF845600),
    danger: Color(0xFFB3261E),
    concept: true,
    gradient: 0.4,
    toneSaturation: 0.6,
  );

  // Kino, dark: a darkened auditorium, gold on wine-black velvet.
  static const ZenColors cinemaDark = ZenColors(
    background: Color(0xFF14070B),
    surface: Color(0xFF200B12),
    surfaceRaised: Color(0xFF2B1018),
    surfaceMuted: Color(0xFF38161F),
    surfaceSunk: Color(0xFF0D0407),
    outline: Color(0xFF5A2432),
    outlineSoft: Color(0xFF40192A),
    outlineStrong: Color(0xFFB8893A),
    textPrimary: Color(0xFFFFF3E0),
    textSecondary: Color(0xFFE8CFA8),
    textMuted: Color(0xFFBC9A78),
    accent: Color(0xFFE0B24D),
    accentSecondary: Color(0xFFE04458),
    accentTertiary: Color(0xFFF4E3C0),
    accentSoft: Color(0xFF3A1A14),
    onAccent: Color(0xFF1F0E04),
    success: Color(0xFF8FD19E),
    warning: Color(0xFFF0C36A),
    danger: Color(0xFFFF6B6B),
    concept: true,
    glow: 0.35,
    gradient: 0.4,
    toneSaturation: 0.6,
  );

  // Rysunek techniczny, light: white drawing paper and blue ink.
  static const ZenColors blueprintLight = ZenColors(
    background: Color(0xFFF6F9FE),
    surface: Color(0xFFFFFFFF),
    surfaceRaised: Color(0xFFEAF1FB),
    surfaceMuted: Color(0xFFDCE7F7),
    surfaceSunk: Color(0xFFE4EDF9),
    outline: Color(0xFFB4C9E8),
    outlineSoft: Color(0xFFD0DEF3),
    outlineStrong: Color(0xFF5E87C2),
    textPrimary: Color(0xFF0B2447),
    textSecondary: Color(0xFF2F4C78),
    textMuted: Color(0xFF53698F),
    accent: Color(0xFF1B4F9C),
    accentSecondary: Color(0xFFB8400C),
    accentTertiary: Color(0xFF0F766E),
    accentSoft: Color(0xFFE1ECFA),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1E7A4C),
    warning: Color(0xFF9A5B00),
    danger: Color(0xFFB3261E),
    concept: true,
    gradient: 0,
    toneSaturation: 0.6,
  );

  // Rysunek techniczny, dark: the classic blueprint, white lines on blue.
  static const ZenColors blueprintDark = ZenColors(
    background: Color(0xFF0A2447),
    surface: Color(0xFF0F315F),
    surfaceRaised: Color(0xFF143B70),
    surfaceMuted: Color(0xFF1A4580),
    surfaceSunk: Color(0xFF071B38),
    outline: Color(0xFF2F5F9E),
    outlineSoft: Color(0xFF234C85),
    outlineStrong: Color(0xFF7FB2F0),
    textPrimary: Color(0xFFF2F8FF),
    textSecondary: Color(0xFFBFD8F6),
    textMuted: Color(0xFF93B6E3),
    accent: Color(0xFF7DE3FF),
    accentSecondary: Color(0xFFFFD84A),
    accentTertiary: Color(0xFFFF9A8A),
    accentSoft: Color(0xFF163F78),
    onAccent: Color(0xFF05203F),
    success: Color(0xFF7DE3A8),
    warning: Color(0xFFFFD84A),
    danger: Color(0xFFFF9A8A),
    concept: true,
    gradient: 0,
    toneSaturation: 0.6,
  );

  // Skóra, light: tanned hide, cognac and cream thread.
  static const ZenColors leatherLight = ZenColors(
    background: Color(0xFFF3EADB),
    surface: Color(0xFFFBF5EA),
    surfaceRaised: Color(0xFFEBDFCB),
    surfaceMuted: Color(0xFFE0D1B7),
    surfaceSunk: Color(0xFFE8DBC4),
    outline: Color(0xFFC9B493),
    outlineSoft: Color(0xFFDCCDB0),
    outlineStrong: Color(0xFF8B6B45),
    textPrimary: Color(0xFF2B1A10),
    textSecondary: Color(0xFF55402F),
    textMuted: Color(0xFF6A5643),
    accent: Color(0xFF8B3A1E),
    accentSecondary: Color(0xFF9A7418),
    accentTertiary: Color(0xFF3F6B5E),
    accentSoft: Color(0xFFF0DCCB),
    onAccent: Color(0xFFFFF6EA),
    success: Color(0xFF336530),
    warning: Color(0xFF7C5100),
    danger: Color(0xFFAC241D),
    concept: true,
    gradient: 0,
    toneSaturation: 0.5,
  );

  // Skóra, dark: oxblood leather, copper and pale thread.
  static const ZenColors leatherDark = ZenColors(
    background: Color(0xFF1A0F0C),
    surface: Color(0xFF26150F),
    surfaceRaised: Color(0xFF311C14),
    surfaceMuted: Color(0xFF3D251A),
    surfaceSunk: Color(0xFF120A07),
    outline: Color(0xFF5E3D2C),
    outlineSoft: Color(0xFF442B1F),
    outlineStrong: Color(0xFFC08A5E),
    textPrimary: Color(0xFFF7EBDD),
    textSecondary: Color(0xFFD8C3AB),
    textMuted: Color(0xFFAF9479),
    accent: Color(0xFFE58A5B),
    accentSecondary: Color(0xFFEAD7B0),
    accentTertiary: Color(0xFF7FB59F),
    accentSoft: Color(0xFF3A2016),
    onAccent: Color(0xFF1A0F0C),
    success: Color(0xFF9CC46A),
    warning: Color(0xFFE8C26A),
    danger: Color(0xFFEE8A74),
    concept: true,
    gradient: 0,
    toneSaturation: 0.5,
  );

  // Zielnik: panels cut like leaves (two long curves, two short corners)
  // with a vein along the long ones, leaves sinking over soft paper, a
  // fine rule under the titles.
  static const ZenLook herbariumLook = ZenLook(
    borders: ZenBorderStyle.leaf,
    elevation: ZenElevation.flat,
    backdrop: ZenBackdrop.petals,
    header: ZenHeaderStyle.underline,
    sections: ZenSectionStyle.ruled,
    pages: ZenPageMotion.soft,
    corner: 1.1,
    tempo: 1.25,
    curve: Curves.easeInOutCubic,
  );

  // Cukiernia: scalloped edges, round pill buttons, stamped labels and
  // bubbles rising like fizz; pages swell in like a bubble.
  static const ZenLook sweetsLook = ZenLook(
    borders: ZenBorderStyle.scallop,
    buttonFill: ZenButtonFill.gradient,
    backdrop: ZenBackdrop.bubbles,
    header: ZenHeaderStyle.underline,
    sections: ZenSectionStyle.stamp,
    pages: ZenPageMotion.bubble,
    corner: 1.4,
    tempo: 1.1,
    curve: Curves.easeOutBack,
    breathe: true,
  );

  // Kino: tickets with a bite out of each side, chrome marquee capitals,
  // gold rules and two projector beams sweeping over the dust; a streak of
  // light races across on page changes.
  static const ZenLook cinemaLook = ZenLook(
    borders: ZenBorderStyle.notch,
    elevation: ZenElevation.glow,
    dividers: ZenDividerStyle.glow,
    buttons: ZenButtonShape.rounded,
    chips: ZenChipStyle.tag,
    nav: ZenNavStyle.underline,
    backdrop: ZenBackdrop.spotlight,
    header: ZenHeaderStyle.chrome,
    sections: ZenSectionStyle.ornament,
    pages: ZenPageMotion.streak,
    corner: 0.6,
    tempo: 1.1,
    curve: Curves.easeOutCubic,
  );

  // Rysunek techniczny: square sheets with corner marks and a ruler,
  // dashed rules, outlined keys and a drifting grid with a compass.
  static const ZenLook blueprintLook = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    borders: ZenBorderStyle.blueprint,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.dashed,
    buttons: ZenButtonShape.square,
    buttonFill: ZenButtonFill.line,
    chips: ZenChipStyle.outline,
    nav: ZenNavStyle.block,
    fields: ZenFieldStyle.underline,
    backdrop: ZenBackdrop.blueprint,
    header: ZenHeaderStyle.underline,
    sections: ZenSectionStyle.ruled,
    pages: ZenPageMotion.stepped,
    corner: 0,
    tempo: 0.8,
    curve: Curves.linear,
  );

  // Skóra: flat panels with a seam of stitches inside the edge, stitched
  // dividers, nothing glowing; no backdrop, the hide is the background.
  static const ZenLook leatherLook = ZenLook(
    surfaces: ZenSurfaceStyle.flat,
    borders: ZenBorderStyle.stitch,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.dashed,
    buttons: ZenButtonShape.rounded,
    chips: ZenChipStyle.tag,
    nav: ZenNavStyle.underline,
    header: ZenHeaderStyle.underline,
    sections: ZenSectionStyle.ruled,
    pages: ZenPageMotion.soft,
    corner: 0.6,
    tempo: 1.2,
    curve: Curves.easeInOutCubic,
  );
}
