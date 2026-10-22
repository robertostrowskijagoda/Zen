import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// The few colours that do not follow the theme, on purpose, in one place
/// (everything else comes from [ZenColors], its tones or [ZenLook]).
abstract final class ZenFixed {
  /// QR codes: dark modules on white paper, the way every camera reads
  /// them, whatever the theme.
  static const Color qrPaper = Color(0xFFFFFFFF);
  static const Color qrInk = Color(0xFF111114);

  /// Over photos and video: white type and icons on a dark scrim. The
  /// picture under them has no theme, so neither do they.
  static const Color onPhoto = Color(0xFFFFFFFF);
  static const Color onPhotoSoft = Color(0xB3FFFFFF);
  static const Color onPhotoFaint = Color(0x4DFFFFFF);

  /// The dark scrim under text on a photo, and its stronger and lighter
  /// steps.
  static const Color photoScrim = Color(0x8C000000);
  static const Color photoScrimStrong = Color(0xB3000000);
  static const Color photoScrimLight = Color(0x40000000);
  static const Color photoScrimFaint = Color(0x0D000000);

  /// The transparent end of a scrim gradient.
  static const Color photoClear = Color(0x00000000);

  /// Behind a photo or a video shown whole (letterboxing).
  static const Color photoBackdrop = Color(0xFF000000);

  /// A printed door sticker: black ink on white paper, exactly as it
  /// will come out of a printer.
  static const Color paper = Color(0xFFFFFFFF);
  static const Color ink = Color(0xFF151515);
  static const Color inkSoft = Color(0xFF555555);
  static const Color inkFaint = Color(0xFF8A8A8A);
  static const Color paperTint = Color(0xFFF1F1F1);
  static const Color paperEdge = Color(0x22000000);
}

/// The emergency red of the alarm: the theme's danger colour, made deep
/// and strong enough that white type on it always reads (4.5:1), so the
/// alarm looks like an alarm in every theme and still belongs to it.
abstract final class ZenEmergency {
  static Color red(ZenColors zen) {
    final HSLColor h = HSLColor.fromColor(zen.danger);
    return h
        .withSaturation(h.saturation < 0.7 ? 0.7 : h.saturation)
        .withLightness(0.42)
        .toColor();
  }

  /// A lighter step of [red] for the top of its gradient.
  static Color glow(ZenColors zen) {
    final HSLColor h = HSLColor.fromColor(red(zen));
    return h.withLightness(0.5).toColor();
  }

  /// Type and icons on [red].
  static Color on(ZenColors zen) => ZenColors.foregroundFor(red(zen));
}
