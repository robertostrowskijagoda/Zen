import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// How cards, groups, tiles and chat bubbles are drawn.
enum ZenSurfaceStyle {
  /// A filled surface with a soft outline.
  filled,

  /// Near-black with a thin lit 1px outline (Neon).
  outlined,

  /// A flat panel in a bevelled 1px chrome frame, square corners (Retro).
  bevelled,
}

/// What stands next to the title of a main section ([ZenSectionBar]).
enum ZenHeaderStyle {
  /// The short accent bar.
  bar,

  /// A glowing tube that flickers on once with the title.
  neonTube,

  /// The title on an LCD strip with a spectrum-analyzer bar strip.
  spectrum,
}

/// How counts (unread messages, tile badges) are drawn.
enum ZenNumberStyle {
  /// Plain text.
  plain,

  /// Seven-segment LED digits.
  led,
}

/// How a section label inside a screen looks ([ZenSection]).
enum ZenSectionStyle {
  /// Small bold caps.
  caps,

  /// Lit caps followed by a fading neon line.
  neonRule,

  /// A tiny title bar: pixel caps and pinstripes.
  titleBar,
}

/// How a pushed screen comes in.
enum ZenPageMotion {
  /// The platform's own transition (Klasyczny).
  platform,

  /// Fade and rise a few pixels.
  soft,

  /// A quick wipe behind a glowing edge, the page lighting up like a tube.
  neonWipe,

  /// A stepped, low-frame-rate fade.
  stepped,
}

/// The component character of a palette, next to its colours
/// ([ZenColors]): what the shared widgets draw (outline or fill, a header
/// decoration, LED numbers) and which animations play. Screens never ask
/// which palette is on; they use the kit, and the kit asks this.
@immutable
final class ZenLook extends ThemeExtension<ZenLook> {
  const ZenLook({
    this.surfaces = ZenSurfaceStyle.filled,
    this.header = ZenHeaderStyle.bar,
    this.numbers = ZenNumberStyle.plain,
    this.sections = ZenSectionStyle.caps,
    this.pages = ZenPageMotion.platform,
    this.corner = 1,
    this.breathe = false,
    this.flickerOn = false,
    this.tabSweep = false,
    this.ambient = false,
  });

  /// Klasyczny.
  static const ZenLook classic = ZenLook();

  /// The calm fixed palettes (Cisza, Grafit, Las, Zmierzch).
  static const ZenLook soft = ZenLook(pages: ZenPageMotion.soft);

  /// Neon: black, thin lit lines, glow and light motion.
  static const ZenLook neon = ZenLook(
    surfaces: ZenSurfaceStyle.outlined,
    header: ZenHeaderStyle.neonTube,
    sections: ZenSectionStyle.neonRule,
    pages: ZenPageMotion.neonWipe,
    corner: 0.65,
    breathe: true,
    flickerOn: true,
    tabSweep: true,
    ambient: true,
  );

  /// Retro: an old desktop player skin.
  static const ZenLook retro = ZenLook(
    surfaces: ZenSurfaceStyle.bevelled,
    header: ZenHeaderStyle.spectrum,
    numbers: ZenNumberStyle.led,
    sections: ZenSectionStyle.titleBar,
    pages: ZenPageMotion.stepped,
    corner: 0,
  );

  final ZenSurfaceStyle surfaces;
  final ZenHeaderStyle header;
  final ZenNumberStyle numbers;
  final ZenSectionStyle sections;
  final ZenPageMotion pages;

  /// Scale of the corner radii (1 = the rounded default, 0 = square).
  final double corner;

  /// The primary action and unread badges breathe a glow.
  final bool breathe;

  /// Section headers flicker on once when they appear.
  final bool flickerOn;

  /// A light runs along the active tab's underline.
  final bool tabSweep;

  /// Hero cards and empty states get a slow drifting field behind them.
  final bool ambient;

  static ZenLook of(BuildContext context) =>
      Theme.of(context).extension<ZenLook>() ?? classic;

  /// The look of [palette].
  static ZenLook forPalette(AppPalette palette) => ZenPalettes.look(palette);

  bool get outlined => surfaces == ZenSurfaceStyle.outlined;
  bool get bevelled => surfaces == ZenSurfaceStyle.bevelled;

  /// Outgoing text bubbles are filled with the accent gradient.
  bool get filledBubbles => surfaces == ZenSurfaceStyle.filled;

  /// The corner radius [r] of the rounded default, in this look.
  double radius(double r) => r * corner;

  /// The outline of a card-like panel ([tone] highlights it; [sunken]
  /// presses a bevelled one in).
  ShapeBorder panelShape(
    ZenColors zen, {
    double radius = 22,
    Color? tone,
    bool sunken = false,
  }) {
    return switch (surfaces) {
      ZenSurfaceStyle.bevelled => ZenBevelBorder.of(zen, sunken: sunken),
      ZenSurfaceStyle.outlined => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(this.radius(radius)),
        side: BorderSide(
          color: tone == null ? zen.outline : tone.withValues(alpha: 0.75),
        ),
      ),
      ZenSurfaceStyle.filled => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
        side: BorderSide(
          color: tone == null ? zen.outlineSoft : tone.withValues(alpha: 0.35),
        ),
      ),
    };
  }

  /// The fill of a card-like panel.
  Color panelColor(ZenColors zen, {Color? tone, bool sunken = false}) {
    if (sunken && bevelled) {
      return zen.surfaceSunk;
    }
    final double alpha = switch (surfaces) {
      ZenSurfaceStyle.outlined => 0.05,
      ZenSurfaceStyle.bevelled => 0.08,
      ZenSurfaceStyle.filled => 0.10,
    };
    return tone == null
        ? zen.surface
        : Color.alphaBlend(tone.withValues(alpha: alpha), zen.surface);
  }

  /// A panel as a decoration (fill, outline and, for a highlighted neon
  /// panel, its glow).
  ShapeDecoration panel(
    ZenColors zen, {
    double radius = 22,
    Color? tone,
    bool sunken = false,
  }) {
    return ShapeDecoration(
      color: panelColor(zen, tone: tone, sunken: sunken),
      shape: panelShape(zen, radius: radius, tone: tone, sunken: sunken),
      shadows: outlined && tone != null ? zen.neonGlow(tone, radius: 14) : null,
    );
  }

  /// The decoration of a chat bubble in this look; null keeps the default
  /// bubbles of the filled look.
  BoxDecoration? bubble(ZenColors zen, {required bool outgoing}) {
    final BorderRadius r = outgoing
        ? BorderRadius.only(
            topLeft: Radius.circular(radius(22)),
            topRight: Radius.circular(radius(22)),
            bottomRight: Radius.circular(radius(5)),
            bottomLeft: Radius.circular(radius(22)),
          )
        : BorderRadius.only(
            topLeft: Radius.circular(radius(22)),
            topRight: Radius.circular(radius(22)),
            bottomRight: Radius.circular(radius(22)),
            bottomLeft: Radius.circular(radius(5)),
          );
    switch (surfaces) {
      case ZenSurfaceStyle.filled:
        return null;
      case ZenSurfaceStyle.outlined:
        return BoxDecoration(
          color: outgoing
              ? Color.alphaBlend(
                  zen.accent.withValues(alpha: 0.07),
                  zen.background,
                )
              : zen.surface,
          borderRadius: r,
          border: Border.all(
            color: outgoing
                ? zen.accent.withValues(alpha: 0.9)
                : zen.outlineStrong,
          ),
          boxShadow: outgoing ? zen.neonGlow(zen.accent, radius: 12) : null,
        );
      case ZenSurfaceStyle.bevelled:
        return BoxDecoration(
          color: outgoing ? zen.accentSoft : zen.surfaceRaised,
          border: Border(
            top: BorderSide(
              color: outgoing
                  ? zen.accent.withValues(alpha: 0.7)
                  : zen.outlineStrong,
            ),
            left: BorderSide(
              color: outgoing
                  ? zen.accent.withValues(alpha: 0.7)
                  : zen.outlineStrong,
            ),
            right: BorderSide(color: zen.surfaceSunk),
            bottom: BorderSide(color: zen.surfaceSunk),
          ),
        );
    }
  }

  @override
  ZenLook copyWith({
    ZenSurfaceStyle? surfaces,
    ZenHeaderStyle? header,
    ZenNumberStyle? numbers,
    ZenSectionStyle? sections,
    ZenPageMotion? pages,
    double? corner,
    bool? breathe,
    bool? flickerOn,
    bool? tabSweep,
    bool? ambient,
  }) {
    return ZenLook(
      surfaces: surfaces ?? this.surfaces,
      header: header ?? this.header,
      numbers: numbers ?? this.numbers,
      sections: sections ?? this.sections,
      pages: pages ?? this.pages,
      corner: corner ?? this.corner,
      breathe: breathe ?? this.breathe,
      flickerOn: flickerOn ?? this.flickerOn,
      tabSweep: tabSweep ?? this.tabSweep,
      ambient: ambient ?? this.ambient,
    );
  }

  @override
  ZenLook lerp(ZenLook? other, double t) {
    if (other == null) {
      return this;
    }
    final ZenLook pick = t < 0.5 ? this : other;
    return pick.copyWith(corner: lerpDouble(corner, other.corner, t));
  }
}

/// A 1px bevelled chrome frame with square corners: lit on the top and
/// left, shaded on the bottom and right ([sunken] swaps them, a pressed
/// button or an LCD well).
@immutable
class ZenBevelBorder extends OutlinedBorder {
  const ZenBevelBorder({
    required this.light,
    required this.dark,
    this.width = 1,
    this.sunken = false,
    super.side,
  });

  /// The frame in the colours of [zen].
  factory ZenBevelBorder.of(ZenColors zen, {bool sunken = false}) =>
      ZenBevelBorder(
        light: zen.outlineStrong,
        dark: zen.surfaceSunk,
        sunken: sunken,
      );

  final Color light;
  final Color dark;
  final double width;
  final bool sunken;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect.deflate(width));

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addRect(rect);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (rect.isEmpty || width <= 0) {
      return;
    }
    final Paint lit = Paint()..color = sunken ? dark : light;
    final Paint shade = Paint()..color = sunken ? light : dark;
    canvas
      ..drawRect(Rect.fromLTWH(rect.left, rect.top, rect.width, width), lit)
      ..drawRect(Rect.fromLTWH(rect.left, rect.top, width, rect.height), lit)
      ..drawRect(
        Rect.fromLTWH(rect.left, rect.bottom - width, rect.width, width),
        shade,
      )
      ..drawRect(
        Rect.fromLTWH(rect.right - width, rect.top, width, rect.height),
        shade,
      );
  }

  @override
  ShapeBorder scale(double t) => ZenBevelBorder(
    light: light,
    dark: dark,
    width: width * t,
    sunken: sunken,
    side: side.scale(t),
  );

  @override
  ZenBevelBorder copyWith({BorderSide? side}) => ZenBevelBorder(
    light: light,
    dark: dark,
    width: width,
    sunken: sunken,
    side: side ?? this.side,
  );

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) {
    if (a is ZenBevelBorder) {
      return ZenBevelBorder(
        light: Color.lerp(a.light, light, t)!,
        dark: Color.lerp(a.dark, dark, t)!,
        width: lerpDouble(a.width, width, t)!,
        sunken: t < 0.5 ? a.sunken : sunken,
      );
    }
    return super.lerpFrom(a, t);
  }

  @override
  bool operator ==(Object other) =>
      other is ZenBevelBorder &&
      other.light == light &&
      other.dark == dark &&
      other.width == width &&
      other.sunken == sunken &&
      other.side == side;

  @override
  int get hashCode => Object.hash(light, dark, width, sunken, side);
}
