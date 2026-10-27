import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';

export 'package:zen/src/app/theme/zen_borders.dart';

/// How cards, groups, tiles and chat bubbles are filled.
enum ZenSurfaceStyle {
  /// A filled surface, soft tints and gradients (Klasyczny).
  filled,

  /// Near-black with a thin lit outline (Neon, Neonowa siatka).
  outlined,

  /// A flat panel in a bevelled chrome frame (Odtwarzacz).
  bevelled,

  /// See-through frosted panels over the backdrop (Perła).
  glass,

  /// One plain colour, no gradients (Atrament, terminals, Onyks).
  flat,
}

/// The outline of panels, fields and floating sheets.
enum ZenBorderStyle {
  /// No line: panels stand apart by colour and space.
  none,

  /// A thin 1px line.
  hairline,

  /// Two thin lines with a narrow gap.
  doubleLine,

  /// A lit line with a glow around it.
  glow,

  /// A bevelled chrome frame.
  bevel,

  /// Chamfered (cut) corners and a lit line.
  cut,

  /// Cut corners, a lit line and solder pads at the corners, like a
  /// circuit board.
  circuit,

  /// A stepped pixel frame, thick like an old game.
  pixel,

  /// A thick dark ink line, like a drawn comic panel.
  ink,

  /// A fine double gold line with little ornaments at the corners.
  filigree,

  /// A bevelled metal plate with a rivet in each corner.
  rivets,

  /// An old desktop window: an outline and a colour bar along the top.
  window,

  /// A thin line shimmering in all colours (iridescent).
  sheen,

  /// A line with a row of stitches inside it, like sewn leather.
  stitch,

  /// A leaf: two opposite corners deeply rounded, the others nearly
  /// square.
  leaf,

  /// Little round scallops along the edge, like a doily.
  scallop,

  /// A ticket: a half circle bitten out of the middle of each side.
  notch,

  /// A drawing board: heavier corner marks and a ruler along the top.
  blueprint,
}

/// What lifts raised things (the main button, menus, highlighted cards).
enum ZenElevation {
  /// Nothing: flat colour only.
  flat,

  /// A soft drop shadow.
  shadow,

  /// A glow of the accent instead of a shadow.
  glow,

  /// A hard, unblurred offset shadow (games, comics).
  hard,
}

/// How rows of a list are separated.
enum ZenDividerStyle {
  /// Only space (a barely visible line).
  none,

  /// A full-width thin line.
  hairline,

  /// A thin line inset from the edges.
  inset,

  /// A dashed line.
  dashed,

  /// A carved double line (dark over light).
  groove,

  /// A lit line fading out at both ends.
  glow,
}

/// The outline of buttons.
enum ZenButtonShape {
  /// Fully rounded capsules.
  pill,

  /// Softly rounded rectangles.
  rounded,

  /// Sharp rectangles.
  square,

  /// Chrome keys that press in.
  bevel,

  /// Chamfered (cut) corners.
  cut,

  /// Stepped pixel corners.
  pixel,
}

/// How the main (filled) button is painted.
enum ZenButtonFill {
  /// One solid accent colour.
  solid,

  /// The accent gradient.
  gradient,

  /// An accent outline on a dark fill (a lit line in a glowing look).
  line,

  /// A chrome key with an accent label.
  chrome,
}

/// How chips, pills and small labels look.
enum ZenChipStyle {
  /// Capsules.
  pill,

  /// Small rounded tags.
  tag,

  /// Outlines only.
  outline,

  /// Little chrome keys.
  bevel,

  /// Chamfered tags.
  cut,

  /// Stepped pixel tags.
  pixel,
}

/// How the selected tab of the side rail is marked.
enum ZenNavStyle {
  /// A soft gradient capsule.
  pill,

  /// A bar along the edge.
  underline,

  /// A sharp block with an outline.
  block,

  /// A chrome key, pressed in.
  bevel,

  /// A lit outline with a light running along it.
  glow,
}

/// How text fields are drawn.
enum ZenFieldStyle {
  /// A filled box with an outline.
  outline,

  /// Only a line under the text.
  underline,
}

/// A decorative layer behind the whole app (only where the page itself
/// shows; text sits on panels above it).
enum ZenBackdrop {
  /// Nothing.
  none,

  /// Green signs running down in columns.
  rain,

  /// A neon floor grid in perspective.
  grid,

  /// Monitor scan lines with a slow rolling band.
  scanlines,

  /// Soft blooms of colour drifting slowly (behind glass panels).
  aurora,

  /// Dense columns of signs running down, a few glitching.
  cipher,

  /// A neon floor grid with light trails racing to the horizon.
  lightcycle,

  /// A night sky in violet, twinkling stars and a falling sparkle.
  fairy,

  /// A striped sunset sun over a moving grid.
  synthwave,

  /// Slanted rain over a glowing city skyline.
  city,

  /// Blinking pixel stars in a curved old screen.
  arcade,

  /// A drifting star field in layers and nebula glow.
  space,

  /// A pastel sky, a banded sun and a grid floor.
  vapor,

  /// Deep water: light rays and glowing specks rising.
  deepSea,

  /// Printed halftone dots.
  halftone,

  /// Old paper and slowly turning gears.
  steam,

  /// Slow bands of shifting rainbow sheen.
  holo,

  /// Embers rising from glowing cracks.
  embers,

  /// Brushed metal.
  brushed,

  /// Leaves and petals sinking slowly down.
  petals,

  /// Soft bubbles rising, like fizz in a glass.
  bubbles,

  /// A drawing board's grid drifting slowly, with crosshair marks.
  blueprint,

  /// Two projector beams swaying over drifting dust.
  spotlight,
}

/// What stands next to the title of a main section ([ZenSectionBar]).
enum ZenHeaderStyle {
  /// The short accent bar.
  bar,

  /// A glowing tube that flickers on once with the title.
  neonTube,

  /// The title on an LCD strip with a spectrum-analyzer bar strip.
  spectrum,

  /// A command prompt: a chevron, the title and a blinking cursor.
  prompt,

  /// HUD corner marks around the title.
  brackets,

  /// A short fine rule under the title.
  underline,

  /// Wide-spaced capitals in a chrome gradient.
  chrome,

  /// The title split into shifted colour ghosts.
  glitch,

  /// Heavy capitals with a hard pixel shadow.
  pixel,

  /// Glowing title between two little diamonds.
  ornament,

  /// Capitals on a tilted ink-framed banner.
  banner,

  /// The title on an LCD strip.
  lcd,
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

  /// A tiny title bar: small caps on a bevelled strip.
  titleBar,

  /// A comment line of a terminal (`// LABEL`).
  prompt,

  /// Small caps between fine rules.
  ruled,

  /// A diamond, glowing caps and a fading gold line.
  ornament,

  /// A pixel block and heavy capitals with a hard shadow.
  pixel,

  /// Capitals stamped on an accent block.
  stamp,
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

  /// A few glitchy flickers with shifted slices, then the page.
  glitch,

  /// A light streak racing across while the page slides in.
  streak,

  /// The page swells in softly, like a bubble.
  bubble,
}

/// The component character of a palette, next to its colours
/// ([ZenColors]): shapes (corner scale), borders, surfaces, elevation,
/// dividers, buttons, chips, the tab rail, fields, a backdrop, headers and
/// motion. Screens never ask which palette is on; they use the kit and
/// these helpers, and the Material component themes are built from them
/// ([ZenTheme]). The font is the same in every look.
@immutable
final class ZenLook extends ThemeExtension<ZenLook> {
  const ZenLook({
    this.surfaces = ZenSurfaceStyle.filled,
    this.borders = ZenBorderStyle.hairline,
    this.elevation = ZenElevation.shadow,
    this.dividers = ZenDividerStyle.inset,
    this.buttons = ZenButtonShape.pill,
    this.buttonFill = ZenButtonFill.solid,
    this.chips = ZenChipStyle.pill,
    this.nav = ZenNavStyle.pill,
    this.fields = ZenFieldStyle.outline,
    this.backdrop = ZenBackdrop.none,
    this.header = ZenHeaderStyle.bar,
    this.numbers = ZenNumberStyle.plain,
    this.sections = ZenSectionStyle.caps,
    this.pages = ZenPageMotion.platform,
    this.corner = 1,
    this.tempo = 1,
    this.curve = Curves.easeOutCubic,
    this.breathe = false,
    this.flickerOn = false,
    this.tabSweep = false,
    this.ambient = false,
    this.navEqualizer = false,
  });

  /// Klasyczny (the default).
  static const ZenLook classic = ZenLook();

  /// The calm fixed palettes: soft transitions, flat lift.
  static const ZenLook soft = ZenLook(
    elevation: ZenElevation.flat,
    pages: ZenPageMotion.soft,
  );

  /// Neon: black, thin lit lines, glow and light motion.
  static const ZenLook neon = ZenLook(
    surfaces: ZenSurfaceStyle.outlined,
    borders: ZenBorderStyle.glow,
    elevation: ZenElevation.glow,
    dividers: ZenDividerStyle.glow,
    chips: ZenChipStyle.outline,
    nav: ZenNavStyle.glow,
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
    borders: ZenBorderStyle.bevel,
    elevation: ZenElevation.flat,
    dividers: ZenDividerStyle.groove,
    buttons: ZenButtonShape.bevel,
    buttonFill: ZenButtonFill.chrome,
    chips: ZenChipStyle.bevel,
    nav: ZenNavStyle.bevel,
    backdrop: ZenBackdrop.brushed,
    header: ZenHeaderStyle.lcd,
    numbers: ZenNumberStyle.led,
    sections: ZenSectionStyle.titleBar,
    pages: ZenPageMotion.stepped,
    corner: 0,
    tempo: 0.8,
    curve: Curves.linear,
    navEqualizer: true,
  );

  final ZenSurfaceStyle surfaces;
  final ZenBorderStyle borders;
  final ZenElevation elevation;
  final ZenDividerStyle dividers;
  final ZenButtonShape buttons;
  final ZenButtonFill buttonFill;
  final ZenChipStyle chips;
  final ZenNavStyle nav;
  final ZenFieldStyle fields;
  final ZenBackdrop backdrop;
  final ZenHeaderStyle header;
  final ZenNumberStyle numbers;
  final ZenSectionStyle sections;
  final ZenPageMotion pages;

  /// Scale of the corner radii (1 = the rounded default, 0 = square).
  final double corner;

  /// Length of the component animations (1 = default, more is slower).
  final double tempo;

  /// The curve of the component animations.
  final Curve curve;

  /// The primary action and unread badges breathe a glow.
  final bool breathe;

  /// Section headers flicker on once when they appear.
  final bool flickerOn;

  /// A light runs along the active tab's underline.
  final bool tabSweep;

  /// Hero cards and empty states get a slow drifting field behind them.
  final bool ambient;

  /// Tiny equalizer bars play in the selected tab of the rail.
  final bool navEqualizer;

  static ZenLook of(BuildContext context) =>
      Theme.of(context).extension<ZenLook>() ?? classic;

  /// The look of [palette].
  static ZenLook forPalette(AppPalette palette) => ZenPalettes.look(palette);

  bool get outlined => surfaces == ZenSurfaceStyle.outlined;
  bool get bevelled => surfaces == ZenSurfaceStyle.bevelled;
  bool get glass => surfaces == ZenSurfaceStyle.glass;
  bool get flat => surfaces == ZenSurfaceStyle.flat;

  /// Lit (glowing) outlines.
  bool get lit =>
      borders == ZenBorderStyle.glow ||
      borders == ZenBorderStyle.cut ||
      borders == ZenBorderStyle.circuit;

  /// A bevelled metal frame (chrome or riveted).
  bool get metal =>
      borders == ZenBorderStyle.bevel || borders == ZenBorderStyle.rivets;

  /// Square corners everywhere (avatars and badges too).
  bool get sharp => corner <= 0.05;

  /// Outgoing text bubbles are filled with the accent gradient.
  bool get filledBubbles =>
      surfaces == ZenSurfaceStyle.filled || surfaces == ZenSurfaceStyle.glass;

  /// The corner radius [r] of the rounded default, in this look.
  double radius(double r) => r * corner;

  /// [radius] as a [BorderRadius].
  BorderRadius br(double r) => BorderRadius.circular(radius(r));

  /// A component animation of [ms] milliseconds in this look's tempo.
  Duration duration(int ms) => Duration(milliseconds: (ms * tempo).round());

  /// The line of a panel's outline (hairline and glow looks); a tone
  /// highlights it.
  BorderSide outlineSide(ZenColors zen, {Color? tone}) {
    return switch (borders) {
      ZenBorderStyle.none =>
        tone == null
            ? BorderSide.none
            : BorderSide(color: tone.withValues(alpha: 0.35)),
      ZenBorderStyle.glow ||
      ZenBorderStyle.cut ||
      ZenBorderStyle.circuit => BorderSide(
        color: tone == null ? zen.outline : tone.withValues(alpha: 0.75),
      ),
      ZenBorderStyle.ink || ZenBorderStyle.pixel => BorderSide(
        color: tone ?? zen.outlineStrong,
        width: 2.5,
      ),
      ZenBorderStyle.hairline ||
      ZenBorderStyle.doubleLine ||
      ZenBorderStyle.bevel ||
      ZenBorderStyle.rivets ||
      ZenBorderStyle.filigree ||
      ZenBorderStyle.window ||
      ZenBorderStyle.sheen ||
      ZenBorderStyle.stitch ||
      ZenBorderStyle.leaf ||
      ZenBorderStyle.scallop ||
      ZenBorderStyle.notch ||
      ZenBorderStyle.blueprint => BorderSide(
        color: tone != null
            ? tone.withValues(alpha: 0.35)
            : flat
            ? zen.outline
            : zen.outlineSoft,
      ),
    };
  }

  /// The outline of a card-like panel ([tone] highlights it; [sunken]
  /// presses a bevelled one in).
  ShapeBorder panelShape(
    ZenColors zen, {
    double radius = 22,
    Color? tone,
    bool sunken = false,
  }) {
    final BorderRadius r = br(radius);
    return switch (borders) {
      ZenBorderStyle.bevel => ZenBevelBorder.of(zen, sunken: sunken),
      ZenBorderStyle.rivets => ZenBevelBorder.of(
        zen,
        sunken: sunken,
        rivets: true,
      ),
      ZenBorderStyle.doubleLine => ZenDoubleBorder(
        borderRadius: r,
        color: tone ?? zen.outlineStrong,
        inner: (tone ?? zen.outline).withValues(alpha: 0.6),
      ),
      ZenBorderStyle.filigree => ZenDoubleBorder(
        borderRadius: r,
        color: tone ?? zen.accent.withValues(alpha: 0.8),
        inner: (tone ?? zen.accent).withValues(alpha: 0.35),
        ornaments: true,
      ),
      ZenBorderStyle.cut || ZenBorderStyle.circuit => ZenCutBorder(
        cut: radius >= 20 ? 12 : 8,
        color: tone?.withValues(alpha: 0.85) ?? zen.outlineStrong,
        pads: borders == ZenBorderStyle.circuit,
      ),
      ZenBorderStyle.pixel => ZenPixelBorder(color: tone ?? zen.outlineStrong),
      ZenBorderStyle.window => ZenWindowBorder(
        borderRadius: r,
        color: tone ?? zen.outlineStrong,
        bar: <Color>[zen.accent, zen.accentSecondary],
      ),
      ZenBorderStyle.sheen => ZenSheenBorder(
        borderRadius: r,
        colors: <Color>[
          zen.accent,
          zen.accentSecondary,
          zen.accentTertiary,
          zen.accent,
        ],
      ),
      ZenBorderStyle.stitch => ZenStitchBorder(
        borderRadius: r,
        color: tone ?? zen.outlineStrong,
        thread: (tone ?? zen.accentSecondary).withValues(alpha: 0.85),
      ),
      ZenBorderStyle.leaf => ZenLeafBorder.of(
        radius: this.radius(radius),
        color: tone?.withValues(alpha: 0.6) ?? zen.outline,
        vein: tone ?? zen.accent.withValues(alpha: 0.75),
      ),
      ZenBorderStyle.scallop => ZenScallopBorder(
        color: tone?.withValues(alpha: 0.75) ?? zen.outlineStrong,
      ),
      ZenBorderStyle.notch => ZenNotchBorder(
        borderRadius: r,
        color: tone?.withValues(alpha: 0.8) ?? zen.outlineStrong,
      ),
      ZenBorderStyle.blueprint => ZenBlueprintBorder(
        color: tone?.withValues(alpha: 0.85) ?? zen.outlineStrong,
      ),
      ZenBorderStyle.none ||
      ZenBorderStyle.hairline ||
      ZenBorderStyle.ink ||
      ZenBorderStyle.glow => RoundedRectangleBorder(
        borderRadius: r,
        side: outlineSide(zen, tone: tone),
      ),
    };
  }

  /// The fill of a card-like panel.
  Color panelColor(ZenColors zen, {Color? tone, bool sunken = false}) {
    if (sunken && (bevelled || flat || metal)) {
      return zen.surfaceSunk;
    }
    final double alpha = switch (surfaces) {
      ZenSurfaceStyle.outlined => 0.05,
      ZenSurfaceStyle.bevelled => 0.08,
      ZenSurfaceStyle.flat => 0.08,
      ZenSurfaceStyle.glass => 0.10,
      ZenSurfaceStyle.filled => 0.10,
    };
    final Color base = glass
        ? zen.surface.withValues(alpha: 0.74)
        : zen.surface;
    return tone == null
        ? base
        : Color.alphaBlend(tone.withValues(alpha: alpha), base);
  }

  /// What lifts a raised element of [tone] (the accent when null): a glow,
  /// a soft shadow or nothing.
  List<BoxShadow>? lift(ZenColors zen, {Color? tone, double radius = 14}) {
    return switch (elevation) {
      ZenElevation.flat => null,
      ZenElevation.glow => zen.neonGlow(tone ?? zen.accent, radius: radius),
      ZenElevation.hard => <BoxShadow>[
        BoxShadow(color: zen.outlineStrong, offset: const Offset(4, 4)),
      ],
      ZenElevation.shadow => <BoxShadow>[
        BoxShadow(
          color: const Color(0xFF000000).withValues(
            alpha: zen.background.computeLuminance() > 0.4 ? 0.08 : 0.32,
          ),
          blurRadius: radius,
          offset: Offset(0, radius * 0.25),
        ),
      ],
    };
  }

  /// A coloured lift under an element of [tone] (a hero card, a big
  /// button, a floating bar): a soft tinted shadow, a glow in a glowing
  /// look, a hard offset shadow in a drawn look, nothing in a flat one.
  List<BoxShadow>? tinted(
    ZenColors zen,
    Color tone, {
    double radius = 20,
    double alpha = 0.2,
    Offset offset = Offset.zero,
  }) {
    return switch (elevation) {
      ZenElevation.flat => null,
      ZenElevation.hard => lift(zen),
      ZenElevation.glow => zen.neonGlow(tone, radius: radius),
      ZenElevation.shadow => <BoxShadow>[
        BoxShadow(
          color: tone.withValues(alpha: alpha),
          blurRadius: radius,
          spreadRadius: -4,
          offset: offset,
        ),
      ],
    };
  }

  /// A panel as a decoration (fill, outline and, for a highlighted lit
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
      shadows: elevation == ZenElevation.hard
          ? lift(zen)
          : lit && tone != null
          ? zen.neonGlow(tone, radius: 14)
          : null,
    );
  }

  /// [child] (a panel of [shape]) with the look's hard offset shadow under
  /// it, if the look has one; soft shadows and glows come from Material.
  Widget raise(ZenColors zen, ShapeBorder shape, Widget child) {
    if (elevation != ZenElevation.hard) {
      return child;
    }
    return DecoratedBox(
      decoration: ShapeDecoration(shape: shape, shadows: lift(zen)),
      child: child,
    );
  }

  /// The outline of a button ([pressed] presses a chrome key in).
  OutlinedBorder buttonBorder(ZenColors zen, {bool pressed = false}) {
    return switch (buttons) {
      ZenButtonShape.bevel => ZenBevelBorder.of(zen, sunken: pressed),
      ZenButtonShape.pill => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius(999)),
      ),
      ZenButtonShape.rounded => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius(12)),
      ),
      ZenButtonShape.square => const RoundedRectangleBorder(),
      ZenButtonShape.cut => ZenCutBorder(cut: 8, color: zen.accent, width: 0),
      ZenButtonShape.pixel => ZenPixelBorder(
        color: zen.outlineStrong,
        width: 0,
      ),
    };
  }

  /// The outline of a chip or a small label.
  OutlinedBorder chipBorder(ZenColors zen, {BorderSide? side}) {
    final BorderSide s = side ?? BorderSide.none;
    return switch (chips) {
      ZenChipStyle.bevel => ZenBevelBorder.of(zen),
      ZenChipStyle.pill => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius(999)),
        side: s,
      ),
      ZenChipStyle.tag || ZenChipStyle.outline => RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius(8)),
        side: s,
      ),
      ZenChipStyle.cut => ZenCutBorder(cut: 6, color: s.color, width: s.width),
      ZenChipStyle.pixel => ZenPixelBorder(
        color: s.color,
        width: s.width,
        step: 2,
      ),
    };
  }

  /// The corner radius of chips and pills.
  BorderRadius get chipRadius => switch (chips) {
    ZenChipStyle.bevel ||
    ZenChipStyle.cut ||
    ZenChipStyle.pixel => BorderRadius.zero,
    ZenChipStyle.pill => BorderRadius.circular(radius(999)),
    ZenChipStyle.tag ||
    ZenChipStyle.outline => BorderRadius.circular(radius(8)),
  };

  /// The outline of dialogs, menus and sheets ([topOnly]: a sheet rising
  /// from the bottom edge).
  ShapeBorder floatingShape(
    ZenColors zen, {
    double radius = 28,
    bool topOnly = false,
  }) {
    final BorderRadius r = topOnly
        ? BorderRadius.vertical(top: Radius.circular(this.radius(radius)))
        : BorderRadius.circular(this.radius(radius));
    return switch (borders) {
      ZenBorderStyle.bevel => ZenBevelBorder.of(zen),
      ZenBorderStyle.rivets => ZenBevelBorder.of(zen, rivets: true),
      ZenBorderStyle.doubleLine => ZenDoubleBorder(
        borderRadius: r,
        color: zen.outlineStrong,
        inner: zen.outline,
      ),
      ZenBorderStyle.filigree => ZenDoubleBorder(
        borderRadius: r,
        color: zen.accent.withValues(alpha: 0.8),
        inner: zen.accent.withValues(alpha: 0.35),
        ornaments: !topOnly,
      ),
      ZenBorderStyle.cut || ZenBorderStyle.circuit =>
        topOnly
            ? RoundedRectangleBorder(
                side: BorderSide(color: zen.accent.withValues(alpha: 0.45)),
              )
            : ZenCutBorder(
                cut: 14,
                color: zen.accent.withValues(alpha: 0.6),
                pads: borders == ZenBorderStyle.circuit,
              ),
      ZenBorderStyle.pixel => ZenPixelBorder(color: zen.outlineStrong),
      ZenBorderStyle.ink => RoundedRectangleBorder(
        borderRadius: r,
        side: BorderSide(color: zen.outlineStrong, width: 2.5),
      ),
      ZenBorderStyle.window => ZenWindowBorder(
        borderRadius: r,
        color: zen.outlineStrong,
        bar: <Color>[zen.accent, zen.accentSecondary],
      ),
      ZenBorderStyle.sheen => ZenSheenBorder(
        borderRadius: r,
        colors: <Color>[
          zen.accent,
          zen.accentSecondary,
          zen.accentTertiary,
          zen.accent,
        ],
      ),
      // A sheet keeps a plain top edge; the frames with a shape of their
      // own come back on dialogs and menus.
      ZenBorderStyle.stitch =>
        topOnly
            ? RoundedRectangleBorder(
                borderRadius: r,
                side: BorderSide(color: zen.outlineStrong),
              )
            : ZenStitchBorder(
                borderRadius: r,
                color: zen.outlineStrong,
                thread: zen.accentSecondary.withValues(alpha: 0.85),
              ),
      ZenBorderStyle.leaf =>
        topOnly
            ? RoundedRectangleBorder(
                borderRadius: r,
                side: BorderSide(color: zen.outline),
              )
            : ZenLeafBorder.of(
                radius: this.radius(radius),
                color: zen.outline,
                vein: zen.accent.withValues(alpha: 0.75),
              ),
      ZenBorderStyle.scallop =>
        topOnly
            ? RoundedRectangleBorder(
                borderRadius: r,
                side: BorderSide(color: zen.outlineStrong),
              )
            : ZenScallopBorder(color: zen.outlineStrong),
      ZenBorderStyle.notch =>
        topOnly
            ? RoundedRectangleBorder(
                borderRadius: r,
                side: BorderSide(color: zen.outlineStrong),
              )
            : ZenNotchBorder(borderRadius: r, color: zen.outlineStrong),
      ZenBorderStyle.blueprint =>
        topOnly
            ? RoundedRectangleBorder(side: BorderSide(color: zen.outlineStrong))
            : ZenBlueprintBorder(color: zen.outlineStrong),
      ZenBorderStyle.glow => RoundedRectangleBorder(
        borderRadius: r,
        side: BorderSide(color: zen.accent.withValues(alpha: 0.45)),
      ),
      ZenBorderStyle.hairline => RoundedRectangleBorder(
        borderRadius: r,
        side: topOnly ? BorderSide.none : BorderSide(color: zen.outlineSoft),
      ),
      ZenBorderStyle.none => RoundedRectangleBorder(borderRadius: r),
    };
  }

  /// The colour of a divider line in this look.
  Color dividerColor(ZenColors zen) => switch (dividers) {
    ZenDividerStyle.none => zen.outlineSoft.withValues(alpha: 0.45),
    ZenDividerStyle.glow => zen.accent.withValues(alpha: 0.35),
    ZenDividerStyle.groove => zen.surfaceSunk,
    ZenDividerStyle.dashed => zen.outline,
    ZenDividerStyle.hairline || ZenDividerStyle.inset => zen.outlineSoft,
  };

  /// The decoration of the side tab rail.
  Decoration railDecoration(ZenColors zen) {
    final Color edge = switch (borders) {
      ZenBorderStyle.glow ||
      ZenBorderStyle.cut ||
      ZenBorderStyle.circuit => zen.accent.withValues(alpha: 0.35),
      ZenBorderStyle.bevel ||
      ZenBorderStyle.rivets ||
      ZenBorderStyle.ink ||
      ZenBorderStyle.pixel ||
      ZenBorderStyle.window => zen.outlineStrong,
      ZenBorderStyle.filigree => zen.accent.withValues(alpha: 0.5),
      ZenBorderStyle.sheen => zen.accentSecondary.withValues(alpha: 0.5),
      ZenBorderStyle.stitch ||
      ZenBorderStyle.scallop ||
      ZenBorderStyle.blueprint => zen.outlineStrong,
      ZenBorderStyle.leaf || ZenBorderStyle.notch => zen.outline,
      ZenBorderStyle.doubleLine => zen.outline,
      ZenBorderStyle.none => zen.surfaceSunk,
      ZenBorderStyle.hairline => zen.outlineSoft,
    };
    final bool thick =
        borders == ZenBorderStyle.ink || borders == ZenBorderStyle.pixel;
    return BoxDecoration(
      color: bevelled ? zen.surface : zen.surfaceSunk,
      // The rail's edge towards the page (on its right; on its left in a
      // right-to-left language).
      border: BorderDirectional(
        end: BorderSide(color: edge, width: thick ? 2.5 : 1),
      ),
      boxShadow: lit
          ? <BoxShadow>[
              BoxShadow(
                color: zen.accent.withValues(alpha: 0.12 * zen.glow),
                blurRadius: 10,
              ),
            ]
          : null,
    );
  }

  /// The corners of a chat bubble: rounded, with one small corner on the
  /// side of the sender.
  BorderRadiusDirectional bubbleRadius({required bool outgoing}) => outgoing
      ? BorderRadiusDirectional.only(
          topStart: Radius.circular(radius(22)),
          topEnd: Radius.circular(radius(22)),
          bottomEnd: Radius.circular(radius(5)),
          bottomStart: Radius.circular(radius(22)),
        )
      : BorderRadiusDirectional.only(
          topStart: Radius.circular(radius(22)),
          topEnd: Radius.circular(radius(22)),
          bottomEnd: Radius.circular(radius(22)),
          bottomStart: Radius.circular(radius(5)),
        );

  /// The decoration of a chat bubble in this look; null keeps the default
  /// gradient bubbles of the filled looks.
  BoxDecoration? bubble(ZenColors zen, {required bool outgoing}) {
    final BorderRadiusGeometry r = bubbleRadius(outgoing: outgoing);
    switch (surfaces) {
      case ZenSurfaceStyle.filled:
      case ZenSurfaceStyle.glass:
        return null;
      case ZenSurfaceStyle.flat:
        return BoxDecoration(
          color: outgoing ? zen.accentSoft : zen.surface,
          borderRadius: r,
          border: borders == ZenBorderStyle.none
              ? null
              : Border.all(
                  color: outgoing
                      ? zen.accent.withValues(alpha: 0.55)
                      : zen.outline,
                ),
        );
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
    ZenBorderStyle? borders,
    ZenElevation? elevation,
    ZenDividerStyle? dividers,
    ZenButtonShape? buttons,
    ZenButtonFill? buttonFill,
    ZenChipStyle? chips,
    ZenNavStyle? nav,
    ZenFieldStyle? fields,
    ZenBackdrop? backdrop,
    ZenHeaderStyle? header,
    ZenNumberStyle? numbers,
    ZenSectionStyle? sections,
    ZenPageMotion? pages,
    double? corner,
    double? tempo,
    Curve? curve,
    bool? breathe,
    bool? flickerOn,
    bool? tabSweep,
    bool? ambient,
    bool? navEqualizer,
  }) {
    return ZenLook(
      surfaces: surfaces ?? this.surfaces,
      borders: borders ?? this.borders,
      elevation: elevation ?? this.elevation,
      dividers: dividers ?? this.dividers,
      buttons: buttons ?? this.buttons,
      buttonFill: buttonFill ?? this.buttonFill,
      chips: chips ?? this.chips,
      nav: nav ?? this.nav,
      fields: fields ?? this.fields,
      backdrop: backdrop ?? this.backdrop,
      header: header ?? this.header,
      numbers: numbers ?? this.numbers,
      sections: sections ?? this.sections,
      pages: pages ?? this.pages,
      corner: corner ?? this.corner,
      tempo: tempo ?? this.tempo,
      curve: curve ?? this.curve,
      breathe: breathe ?? this.breathe,
      flickerOn: flickerOn ?? this.flickerOn,
      tabSweep: tabSweep ?? this.tabSweep,
      ambient: ambient ?? this.ambient,
      navEqualizer: navEqualizer ?? this.navEqualizer,
    );
  }

  @override
  ZenLook lerp(ZenLook? other, double t) {
    if (other == null) {
      return this;
    }
    final ZenLook pick = t < 0.5 ? this : other;
    return pick.copyWith(
      corner: lerpDouble(corner, other.corner, t),
      tempo: lerpDouble(tempo, other.tempo, t),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ZenLook &&
      other.surfaces == surfaces &&
      other.borders == borders &&
      other.elevation == elevation &&
      other.dividers == dividers &&
      other.buttons == buttons &&
      other.buttonFill == buttonFill &&
      other.chips == chips &&
      other.nav == nav &&
      other.fields == fields &&
      other.backdrop == backdrop &&
      other.header == header &&
      other.numbers == numbers &&
      other.sections == sections &&
      other.pages == pages &&
      other.corner == corner &&
      other.tempo == tempo &&
      other.curve == curve &&
      other.breathe == breathe &&
      other.flickerOn == flickerOn &&
      other.tabSweep == tabSweep &&
      other.ambient == ambient &&
      other.navEqualizer == navEqualizer;

  @override
  int get hashCode => Object.hashAll(<Object?>[
    surfaces,
    borders,
    elevation,
    dividers,
    buttons,
    buttonFill,
    chips,
    nav,
    fields,
    backdrop,
    header,
    numbers,
    sections,
    pages,
    corner,
    tempo,
    curve,
    breathe,
    flickerOn,
    tabSweep,
    ambient,
    navEqualizer,
  ]);
}

/// The current look's shapes, for screens: corner radii written for the
/// rounded default follow the look (square in a sharp one).
extension ZenLookContext on BuildContext {
  /// The corner radius [r] of the rounded default, in the current look.
  BorderRadius zenRadius(double r) => ZenLook.of(this).br(r);

  /// Rounded top corners [r] (a sheet rising from the bottom edge), in the
  /// current look.
  BorderRadius zenTopRadius(double r) =>
      BorderRadius.vertical(top: Radius.circular(ZenLook.of(this).radius(r)));

  /// The outline of a bottom sheet in the current look.
  ShapeBorder zenSheetShape() =>
      ZenLook.of(this).floatingShape(ZenColors.of(this), topOnly: true);
}
