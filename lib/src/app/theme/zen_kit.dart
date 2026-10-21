import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_concept.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_retro.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Building blocks of the app's look: feature tiles, section headers, hero
/// cards, empty states and explanations. Every screen uses these, so the
/// whole app reads as one piece.

/// The numbered feature colour [i] (lists of things without a meaning of
/// their own: avatars, groups, graph nodes): one of the theme's tones
/// ([ZenTones.numbered]), so it is always a colour of the palette. Things
/// with a meaning use [ZenToneColors.tone] with their [ZenTone] instead.
Color zenTone(ZenColors zen, int i) =>
    zen.tone(ZenTones.numbered[i.abs() % ZenTones.numbered.length]);

/// An icon in a soft rounded square of its tone.
class ZenIconBadge extends StatelessWidget {
  const ZenIconBadge({
    required this.icon,
    this.tone,
    this.size = 44,
    super.key,
  });

  final IconData icon;
  final Color? tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color t = tone ?? zen.accent;
    if (look.outlined) {
      // Neon: a lit outline and a glowing glyph, no fill.
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          borderRadius: look.br(size * 0.32),
          border: Border.all(color: t.withValues(alpha: 0.7)),
          boxShadow: zen.neonGlow(t, radius: 8),
          color: zen.background,
        ),
        child: ZenIcon(
          icon,
          color: t,
          size: size * 0.5,
          shadows: <Shadow>[
            Shadow(color: t.withValues(alpha: 0.8), blurRadius: 8),
          ],
        ),
      );
    }
    if (look.bevelled) {
      // Retro: the glyph in a small LCD well.
      return Container(
        width: size,
        height: size,
        decoration: ShapeDecoration(
          color: zen.surfaceSunk,
          shape: ZenBevelBorder.of(zen, sunken: true),
        ),
        child: ZenIcon(icon, color: t, size: size * 0.5),
      );
    }
    if (look.flat) {
      // Flat looks: an even tint, a clear line unless the look has none.
      return Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Color.alphaBlend(t.withValues(alpha: 0.12), zen.surface),
          borderRadius: look.br(size * 0.32),
          border: look.borders == ZenBorderStyle.none
              ? null
              : Border.all(color: t.withValues(alpha: 0.45)),
        ),
        child: ZenIcon(icon, color: t, size: size * 0.5),
      );
    }
    final double top = zen.gradient >= 1 ? 0.26 : 0.14 + 0.12 * zen.gradient;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: look.br(size * 0.32),
        gradient: LinearGradient(
          colors: <Color>[
            t.withValues(alpha: top),
            t.withValues(alpha: 0.10),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: t.withValues(alpha: 0.28)),
      ),
      child: ZenIcon(icon, color: t, size: size * 0.5),
    );
  }
}

/// A row-shaped feature card: badge, title, up to two lines of subtitle.
class ZenTile extends StatelessWidget {
  const ZenTile({
    required this.icon,
    required this.title,
    this.subtitle,
    this.tone,
    this.onTap,
    this.trailing,
    this.badge,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Color? tone;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// A small count or word on the right ("3", "nowe").
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final ShapeBorder shape = look.panelShape(zen, radius: 20);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: look.panelColor(zen),
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: Ink(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 12, 14),
              child: Row(
                children: <Widget>[
                  ZenIconBadge(icon: icon, tone: tone),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (subtitle != null &&
                            subtitle!.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13.5,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (badge != null) ...<Widget>[
                    const SizedBox(width: 8),
                    // Never takes the title's room: a long badge shortens.
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 112),
                      child:
                          look.numbers == ZenNumberStyle.led &&
                              int.tryParse(badge!) != null
                          ? ZenCountBadge(int.parse(badge!), tone: tone)
                          : ZenPill(
                              text: badge!,
                              tone: tone ?? zen.accent,
                              filled: true,
                            ),
                    ),
                  ],
                  const SizedBox(width: 6),
                  trailing ??
                      (onTap == null
                          ? const SizedBox.shrink()
                          : Icon(
                              Icons.chevron_right_rounded,
                              color: zen.textMuted,
                            )),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A square-ish tile for a 2-column hub grid.
class ZenGridTile extends StatelessWidget {
  const ZenGridTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.tone,
    this.onTap,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final ShapeBorder shape = look.panelShape(zen);
    return Material(
      color: look.panelColor(zen),
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Ink(
          decoration: look.filledBubbles
              ? BoxDecoration(
                  borderRadius: look.br(22),
                  gradient: LinearGradient(
                    colors: <Color>[
                      tone.withValues(
                        alpha: zen.gradient >= 1
                            ? 0.13
                            : 0.04 + 0.09 * zen.gradient,
                      ),
                      zen.surface,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    stops: const <double>[0, 0.75],
                  ),
                )
              : null,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ZenIconBadge(icon: icon, tone: tone, size: 40),
                const Spacer(),
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 12.5,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A 2-column grid of [ZenGridTile]s that sizes itself (no overflow at any
/// text scale: tiles grow with the text).
class ZenTileGrid extends StatelessWidget {
  const ZenTileGrid({required this.children, this.spacing = 10, super.key});

  final List<Widget> children;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final double scale = MediaQuery.textScalerOf(context).scale(1);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        // Two columns while a tile can still hold its title in whole words;
        // a narrow phone or large text gets one tile per row instead of
        // words broken in half.
        final int columns = c.maxWidth > 640
            ? 3
            : (c.maxWidth - spacing) / 2 / scale >= 120
            ? 2
            : 1;
        final double w = (c.maxWidth - spacing * (columns - 1)) / columns;
        final double h = (columns == 1 ? 132 : 150) * scale.clamp(1, 1.6);
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: <Widget>[
            for (final Widget child in children)
              SizedBox(width: w, height: h, child: child),
          ],
        );
      },
    );
  }
}

/// A section label with an optional action on the right.
class ZenSection extends StatelessWidget {
  const ZenSection(
    this.title, {
    this.action,
    this.onAction,
    this.top = 20,
    super.key,
  });

  final String title;
  final String? action;
  final VoidCallback? onAction;
  final double top;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Widget? button = action == null
        ? null
        : TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(action!),
          );
    if (look.sections == ZenSectionStyle.titleBar) {
      return Padding(
        padding: EdgeInsets.fromLTRB(0, top, 0, 8),
        child: ZenTitleBar(title, trailing: button),
      );
    }
    if (look.sections == ZenSectionStyle.prompt) {
      // A terminal comment line.
      return Padding(
        padding: EdgeInsets.fromLTRB(4, top, 0, 8),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '// ${title.toUpperCase()}',
                style: zen
                    .label(color: zen.accent)
                    .copyWith(letterSpacing: 1.4),
              ),
            ),
            ?button,
          ],
        ),
      );
    }
    if (look.sections == ZenSectionStyle.ruled) {
      // Small caps between fine rules.
      final Widget rule = Container(height: 1, color: zen.outline);
      return Padding(
        padding: EdgeInsets.fromLTRB(4, top, 0, 8),
        child: Row(
          children: <Widget>[
            SizedBox(width: 14, child: rule),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title.toUpperCase(),
                style: zen
                    .label(color: zen.textSecondary)
                    .copyWith(letterSpacing: 1.8),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(child: rule),
            ?button,
          ],
        ),
      );
    }
    final bool rule = look.sections == ZenSectionStyle.neonRule;
    final Text label = Text(
      title.toUpperCase(),
      style: rule
          ? zen
                .label(color: zen.accent)
                .copyWith(
                  letterSpacing: 2,
                  shadows: <Shadow>[
                    Shadow(
                      color: zen.accent.withValues(alpha: 0.6),
                      blurRadius: 8,
                    ),
                  ],
                )
          : zen.label(color: zen.textMuted),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 0, 8),
      child: Row(
        children: <Widget>[
          if (rule) ...<Widget>[
            Flexible(child: label),
            const SizedBox(width: 10),
            // A neon line fading out after the label.
            Expanded(
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: <Color>[
                      zen.accent.withValues(alpha: 0.7),
                      zen.accent.withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
          ] else
            Expanded(child: label),
          ?button,
        ],
      ),
    );
  }
}

/// A gradient card that opens a screen: icon, title, a sentence of what it
/// is for, optional actions below.
class ZenHero extends StatelessWidget {
  const ZenHero({
    required this.title,
    required this.text,
    this.icon,
    this.tone,
    this.actions = const <Widget>[],
    super.key,
  });

  final String title;
  final String text;
  final IconData? icon;
  final Color? tone;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color t = tone ?? zen.accent;
    // The hero keeps a soft gradient in every filled palette; flat ones
    // (Cisza) get an even tint instead. Neon draws a lit frame over a
    // drifting field, retro an LCD panel.
    final double g = zen.gradient;
    final Color base = look.glass
        ? zen.surface.withValues(alpha: 0.74)
        : zen.surface;
    final Decoration decoration = switch (look.surfaces) {
      ZenSurfaceStyle.outlined => ShapeDecoration(
        color: zen.surface,
        shape: RoundedRectangleBorder(
          borderRadius: look.br(26),
          side: BorderSide(color: t.withValues(alpha: 0.85)),
        ),
        shadows: zen.neonGlow(t, radius: 18),
      ),
      ZenSurfaceStyle.bevelled => ShapeDecoration(
        color: zen.surfaceSunk,
        shape: ZenBevelBorder.of(zen, sunken: true),
      ),
      // Flat: an even tint in the look's own frame.
      ZenSurfaceStyle.flat => ShapeDecoration(
        color: Color.alphaBlend(t.withValues(alpha: 0.08), zen.surface),
        shape: look.panelShape(zen, radius: 26, tone: t),
      ),
      ZenSurfaceStyle.filled || ZenSurfaceStyle.glass => BoxDecoration(
        borderRadius: look.br(26),
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(
              t.withValues(alpha: g >= 1 ? 0.30 : 0.12 + 0.18 * g),
              base,
            ),
            Color.alphaBlend(
              zen
                  .gradientPartner(t, zen.accentSecondary)
                  .withValues(alpha: 0.10),
              base,
            ),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
          color: t.withValues(alpha: g >= 1 ? 0.30 : 0.18 + 0.12 * g),
        ),
      ),
    };
    final TextStyle titleStyle = zen.display(
      color: look.bevelled ? t : zen.textPrimary,
      size: 22,
      weight: look.bevelled ? FontWeight.w400 : FontWeight.w600,
    );
    final Widget content = Padding(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Text(
                  title,
                  // Lit, LCD and terminal looks: the title glows a little.
                  style:
                      !(look.outlined ||
                          look.bevelled ||
                          (look.flat && zen.glow > 0))
                      ? titleStyle
                      : titleStyle.copyWith(
                          shadows: <Shadow>[
                            Shadow(
                              color: t.withValues(alpha: 0.55),
                              blurRadius: look.outlined ? 12 : 5,
                            ),
                          ],
                        ),
                ),
              ),
              if (icon != null) ...<Widget>[
                const SizedBox(width: 12),
                ZenIcon(icon!, color: t, size: 30),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Text(
            text,
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          if (actions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 14),
            Wrap(spacing: 8, runSpacing: 8, children: actions),
          ],
        ],
      ),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: decoration,
      child: look.ambient
          ? ClipRRect(
              borderRadius: look.br(26),
              child: ZenAmbientField(tone: t, child: content),
            )
          : content,
    );
  }
}

/// Nothing here yet: a friendly picture, a line of text and what to do.
class ZenEmpty extends StatelessWidget {
  const ZenEmpty({
    required this.icon,
    required this.title,
    this.text,
    this.action,
    this.tone,
    super.key,
  });

  final IconData icon;
  final String title;
  final String? text;
  final Widget? action;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color t = tone ?? zen.accent;
    // Square looks get a square picture.
    final BoxShape round = look.sharp ? BoxShape.rectangle : BoxShape.circle;
    final Decoration picture = switch (look.surfaces) {
      // Neon: a lit ring.
      ZenSurfaceStyle.outlined => BoxDecoration(
        shape: round,
        color: zen.background,
        border: Border.all(color: t.withValues(alpha: 0.9), width: 1.4),
        boxShadow: zen.neonGlow(t, radius: 20),
      ),
      // Retro: an LCD well.
      ZenSurfaceStyle.bevelled => ShapeDecoration(
        color: zen.surfaceSunk,
        shape: ZenBevelBorder.of(zen, sunken: true),
      ),
      // Flat: an even tint and the look's line.
      ZenSurfaceStyle.flat => BoxDecoration(
        shape: round,
        color: Color.alphaBlend(t.withValues(alpha: 0.10), zen.surface),
        border: look.borders == ZenBorderStyle.none
            ? null
            : Border.all(color: t.withValues(alpha: 0.5)),
      ),
      ZenSurfaceStyle.filled || ZenSurfaceStyle.glass => BoxDecoration(
        shape: round,
        gradient: RadialGradient(
          colors: <Color>[t.withValues(alpha: 0.30), t.withValues(alpha: 0.04)],
        ),
      ),
    };
    final Widget content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 84,
            height: 84,
            decoration: picture,
            child: ZenIcon(
              icon,
              size: 38,
              color: t,
              shadows: look.outlined
                  ? <Shadow>[
                      Shadow(color: t.withValues(alpha: 0.8), blurRadius: 10),
                    ]
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (text != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              text!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
          if (action != null) ...<Widget>[const SizedBox(height: 18), action!],
        ],
      ),
    );
    return look.ambient ? ZenAmbientField(tone: t, child: content) : content;
  }
}

/// "What is this?" — a tinted box with an explanation.
class ZenInfo extends StatelessWidget {
  const ZenInfo({
    required this.text,
    this.title,
    this.icon = Icons.lightbulb_outline_rounded,
    this.tone,
    super.key,
  });

  final String? title;
  final String text;
  final IconData icon;
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color t = tone ?? zen.accent;
    final Decoration decoration = switch (look.surfaces) {
      ZenSurfaceStyle.outlined => BoxDecoration(
        color: zen.surface,
        borderRadius: look.br(18),
        border: Border.all(color: t.withValues(alpha: 0.5)),
      ),
      ZenSurfaceStyle.bevelled => ShapeDecoration(
        color: zen.surfaceSunk,
        shape: ZenBevelBorder.of(zen, sunken: true),
      ),
      ZenSurfaceStyle.flat => look.panel(zen, radius: 18, tone: t),
      ZenSurfaceStyle.filled || ZenSurfaceStyle.glass => BoxDecoration(
        color: look.glass
            ? Color.alphaBlend(t.withValues(alpha: 0.09), look.panelColor(zen))
            : t.withValues(alpha: 0.09),
        borderRadius: look.br(18),
        border: Border.all(color: t.withValues(alpha: 0.22)),
      ),
    };
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: decoration,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ZenIcon(icon, color: t, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                if (title != null) ...<Widget>[
                  Text(
                    title!,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 14.5,
                    ),
                  ),
                  const SizedBox(height: 3),
                ],
                Text(
                  text,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A small rounded label.
class ZenPill extends StatelessWidget {
  const ZenPill({
    required this.text,
    this.tone,
    this.filled = false,
    this.icon,
    super.key,
  });

  final String text;
  final Color? tone;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color t = tone ?? zen.accent;
    // Neon: a lit outline instead of a tint.
    // Outline chips: a line instead of a tint.
    final bool line = look.chips == ZenChipStyle.outline && !filled;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: filled
            ? t
            : line
            ? const Color(0x00000000)
            : t.withValues(alpha: 0.13),
        borderRadius: look.chipRadius,
        border: line
            ? Border.all(color: t.withValues(alpha: 0.75))
            : !filled &&
                  (look.chips == ZenChipStyle.bevel ||
                      look.chips == ZenChipStyle.tag)
            ? Border.all(color: t.withValues(alpha: 0.35))
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            ZenIcon(
              icon!,
              size: 13,
              color: filled ? ZenColors.foregroundFor(t) : t,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: filled ? ZenColors.foregroundFor(t) : t,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A grouped list in one rounded card (settings-style), with hairlines
/// between rows.
class ZenGroup extends StatelessWidget {
  const ZenGroup({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    // A Material (not a decorated box): list tiles inside paint their ink
    // and backgrounds on it.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: look.panelColor(zen),
        shape: look.panelShape(zen),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            for (int i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0) const ZenDivider(),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

/// Disposes text controllers of a dialog once its closing animation is
/// over (disposing them right after `await showDialog` crashes: the
/// fields are still on screen for a few frames).
void disposeLater(Object items) {
  final List<ChangeNotifier> list = items is ChangeNotifier
      ? <ChangeNotifier>[items]
      : (items as Iterable<Object?>).whereType<ChangeNotifier>().toList();
  Future<void>.delayed(const Duration(milliseconds: 800), () {
    for (final ChangeNotifier c in list) {
      c.dispose();
    }
  });
}

/// A plain rounded card of the app (surface, soft outline).
class ZenCard extends StatelessWidget {
  const ZenCard({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.tone,
    this.onTap,
    this.margin = const EdgeInsets.symmetric(vertical: 5),
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// Tints the card (a highlighted item).
  final Color? tone;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final ShapeBorder shape = look.panelShape(zen, tone: tone);
    Widget card = Material(
      color: look.panelColor(zen, tone: tone),
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
    if (look.lit && tone != null) {
      // Lit looks: a highlighted card glows.
      card = DecoratedBox(
        decoration: ShapeDecoration(
          shape: shape,
          shadows: zen.neonGlow(tone!, radius: 14),
        ),
        child: card,
      );
    }
    return Padding(padding: margin, child: card);
  }
}

/// The unread count of a chat or a tile: an accent capsule that breathes
/// (a glow in Neon), LED digits in an LCD well in Retro.
class ZenCountBadge extends StatelessWidget {
  const ZenCountBadge(this.count, {this.tone, super.key});

  final int count;

  /// The accent when null.
  final Color? tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color t = tone ?? zen.accent;
    final String text = count > 99 ? '99+' : '$count';
    if (look.numbers == ZenNumberStyle.led) {
      return Semantics(
        label: text,
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.fromLTRB(5, 4, 4, 4),
          decoration: ShapeDecoration(
            color: zen.surfaceSunk,
            shape: ZenBevelBorder.of(zen, sunken: true),
          ),
          child: ZenLedNumber(text, color: t, height: 13),
        ),
      );
    }
    return ZenSoftPulse(
      color: t,
      child: Container(
        constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
        padding: const EdgeInsets.symmetric(horizontal: 7),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: <Color>[t, zen.gradientPartner(t, zen.accentSecondary)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: look.br(999),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: t.withValues(alpha: 0.35),
              blurRadius: 10,
              spreadRadius: -3,
            ),
          ],
        ),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: ZenColors.foregroundFor(t),
            fontSize: 12,
            fontWeight: FontWeight.w800,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// The frame of a tab in the side rail, in the look's nav style
/// ([ZenNavStyle]): a soft gradient capsule; a lit outline with a glow and
/// a light running along its underline; a chrome key, pressed in when
/// selected; a bar along the edge; or a sharp block. [danger] (the alarm)
/// is always red.
class ZenRailTabFrame extends StatelessWidget {
  const ZenRailTabFrame({
    required this.selected,
    required this.child,
    this.danger = false,
    this.padding = EdgeInsets.zero,
    super.key,
  });

  final bool selected;
  final bool danger;
  final EdgeInsetsGeometry padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color hue = danger ? zen.danger : zen.accent;
    final Color hue2 = danger ? zen.danger : zen.accentSecondary;
    const Color clear = Color(0x00000000);
    final Duration duration = look.duration(200);
    final Color idleEdge = danger ? zen.danger.withValues(alpha: 0.30) : clear;
    switch (look.nav) {
      case ZenNavStyle.bevel:
        return AnimatedContainer(
          duration: duration,
          padding: padding,
          decoration: ShapeDecoration(
            color: selected ? zen.surfaceSunk : zen.surfaceRaised,
            shape: ZenBevelBorder.of(zen, sunken: selected),
          ),
          child: child,
        );
      case ZenNavStyle.glow:
        return Stack(
          children: <Widget>[
            AnimatedContainer(
              duration: duration,
              curve: look.curve,
              padding: padding,
              decoration: BoxDecoration(
                color: selected ? zen.background : clear,
                borderRadius: look.br(16),
                border: Border.all(
                  color: selected ? hue.withValues(alpha: 0.9) : idleEdge,
                ),
                boxShadow: selected ? zen.neonGlow(hue, radius: 14) : null,
              ),
              child: child,
            ),
            if (selected && look.tabSweep)
              Positioned(
                left: 8,
                right: 8,
                bottom: 4,
                height: 2,
                child: _ZenSweepLine(color: hue, partner: hue2),
              ),
          ],
        );
      case ZenNavStyle.underline:
        // A bar along the leading edge, a faint tint behind the glyph.
        return AnimatedContainer(
          duration: duration,
          curve: look.curve,
          padding: padding,
          decoration: BoxDecoration(
            color: selected ? hue.withValues(alpha: 0.08) : clear,
            border: Border(
              left: BorderSide(color: selected ? hue : idleEdge, width: 3),
            ),
          ),
          child: child,
        );
      case ZenNavStyle.block:
        // A sharp block with an outline, like a selected menu entry.
        return AnimatedContainer(
          duration: duration,
          curve: look.curve,
          padding: padding,
          decoration: BoxDecoration(
            color: selected ? hue.withValues(alpha: 0.16) : clear,
            borderRadius: look.br(4),
            border: Border.all(color: selected ? hue : idleEdge),
          ),
          child: child,
        );
      case ZenNavStyle.pill:
        return AnimatedContainer(
          duration: duration,
          curve: look.curve,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: look.br(16),
            gradient: selected
                ? LinearGradient(
                    colors: <Color>[
                      hue.withValues(alpha: 0.28),
                      hue2.withValues(alpha: 0.14),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            border: Border.all(
              color: selected ? hue.withValues(alpha: 0.35) : idleEdge,
            ),
            boxShadow: selected ? zen.neonGlow(hue) : null,
          ),
          child: child,
        );
    }
  }
}

/// A line between rows, in the look's divider style ([ZenDividerStyle]):
/// a hairline (full width or inset), a dashed line, a carved groove, a lit
/// line fading out at both ends, or almost nothing.
class ZenDivider extends StatelessWidget {
  const ZenDivider({this.indent = 16, this.endIndent, super.key});

  /// The inset of an inset divider at the start.
  final double indent;

  /// The inset at the end ([indent] when null).
  final double? endIndent;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final Color color = look.dividerColor(zen);
    switch (look.dividers) {
      case ZenDividerStyle.none:
      case ZenDividerStyle.inset:
        return Divider(
          height: 1,
          thickness: 1,
          indent: indent,
          endIndent: endIndent ?? indent,
          color: color,
        );
      case ZenDividerStyle.hairline:
        return Divider(height: 1, thickness: 1, color: color);
      case ZenDividerStyle.dashed:
        return Padding(
          padding: EdgeInsetsDirectional.only(
            start: indent,
            end: endIndent ?? indent,
          ),
          child: SizedBox(
            height: 1,
            width: double.infinity,
            child: CustomPaint(painter: _DashPainter(color)),
          ),
        );
      case ZenDividerStyle.groove:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(height: 1, color: zen.surfaceSunk),
            Container(
              height: 1,
              color: zen.outlineStrong.withValues(alpha: 0.45),
            ),
          ],
        );
      case ZenDividerStyle.glow:
        return Container(
          height: 1,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[
                zen.accent.withValues(alpha: 0),
                zen.accent.withValues(alpha: 0.45),
                zen.accent.withValues(alpha: 0),
              ],
            ),
          ),
        );
    }
  }
}

class _DashPainter extends CustomPainter {
  const _DashPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()..color = color;
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 4, size.height), p);
    }
  }

  @override
  bool shouldRepaint(_DashPainter oldDelegate) => oldDelegate.color != color;
}

/// A lit underline with a bright spot sweeping along it now and then
/// (1.1 s of sweep, then a rest). One ticker, its own layer, paused off
/// screen; a steady line under reduced motion and in tests.
class _ZenSweepLine extends StatefulWidget {
  const _ZenSweepLine({required this.color, required this.partner});

  final Color color;
  final Color partner;

  @override
  State<_ZenSweepLine> createState() => _ZenSweepLineState();
}

class _ZenSweepLineState extends State<_ZenSweepLine>
    with SingleTickerProviderStateMixin {
  AnimationController? _sweep;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool animate = ZenMotion.allowedIn(context);
    if (animate && _sweep == null) {
      _sweep = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 3600),
      )..repeat();
    } else if (!animate && _sweep != null) {
      _sweep!.dispose();
      _sweep = null;
    }
  }

  @override
  void dispose() {
    _sweep?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _SweepLinePainter(
          sweep: _sweep ?? const AlwaysStoppedAnimation<double>(1),
          color: widget.color,
          partner: widget.partner,
        ),
      ),
    );
  }
}

class _SweepLinePainter extends CustomPainter {
  _SweepLinePainter({
    required this.sweep,
    required this.color,
    required this.partner,
  }) : super(repaint: sweep);

  final Animation<double> sweep;
  final Color color;
  final Color partner;

  /// The part of a cycle the light spends running; the rest it rests.
  static const double _run = 0.3;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) {
      return;
    }
    final Rect line = Offset.zero & size;
    final RRect bar = RRect.fromRectAndRadius(
      line,
      Radius.circular(size.height),
    );
    canvas.drawRRect(
      bar.inflate(1),
      Paint()
        ..color = color.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(bar, Paint()..color = color);
    final double v = sweep.value;
    if (v >= _run) {
      return;
    }
    final double x = Curves.easeInOutCubic.transform(v / _run) * size.width;
    final double w = size.width * 0.45;
    canvas.drawRRect(
      bar,
      Paint()
        ..shader = LinearGradient(
          colors: <Color>[
            partner.withValues(alpha: 0),
            partner,
            const Color(0xFFFFFFFF),
            partner,
            partner.withValues(alpha: 0),
          ],
          stops: const <double>[0, 0.35, 0.5, 0.65, 1],
        ).createShader(Rect.fromLTWH(x - w / 2, 0, w, size.height)),
    );
  }

  @override
  bool shouldRepaint(_SweepLinePainter oldDelegate) =>
      oldDelegate.sweep != sweep ||
      oldDelegate.color != color ||
      oldDelegate.partner != partner;
}
