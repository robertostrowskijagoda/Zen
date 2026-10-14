import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Building blocks of the app's look: feature tiles, section headers, hero
/// cards, empty states and explanations. Every screen uses these, so the
/// whole app reads as one piece.

/// The tone of feature [i]: hues around the accent, so every theme gets its
/// own, still matching rainbow (icons of the hub, chips, avatars).
Color zenTone(ZenColors zen, int i) {
  final HSLColor a = HSLColor.fromColor(zen.accent);
  if (a.saturation < 0.08) {
    return zen.textPrimary;
  }
  final bool dark = zen.background.computeLuminance() < 0.2;
  // Offsets picked so the default violet gives: violet, magenta, coral,
  // orange, pink, green, teal, blue (dating pink, neighbours green…).
  const List<double> offsets = <double>[0, 45, 105, 140, 72, 210, 255, 320];
  return HSLColor.fromAHSL(
    1,
    (a.hue + offsets[i % offsets.length] + (i ~/ offsets.length) * 20) % 360,
    0.85,
    dark ? 0.68 : 0.45,
  ).toColor();
}

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
    final Color t = tone ?? zen.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.32),
        gradient: LinearGradient(
          colors: <Color>[t.withValues(alpha: 0.26), t.withValues(alpha: 0.10)],
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Material(
        color: zen.surface,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: zen.outlineSoft),
            ),
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
                      child: ZenPill(
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
    return Material(
      color: zen.surface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            border: Border.all(color: zen.outlineSoft),
            gradient: LinearGradient(
              colors: <Color>[tone.withValues(alpha: 0.13), zen.surface],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: const <double>[0, 0.75],
            ),
          ),
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
    return Padding(
      padding: EdgeInsets.fromLTRB(4, top, 0, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              title.toUpperCase(),
              style: zen.label(color: zen.textMuted),
            ),
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: Text(action!),
            ),
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
    final Color t = tone ?? zen.accent;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(26),
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(t.withValues(alpha: 0.30), zen.surface),
            Color.alphaBlend(
              zen.accentSecondary.withValues(alpha: 0.10),
              zen.surface,
            ),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: t.withValues(alpha: 0.30)),
      ),
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
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 22,
                    weight: FontWeight.w600,
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
    final Color t = tone ?? zen.accent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: <Color>[
                  t.withValues(alpha: 0.30),
                  t.withValues(alpha: 0.04),
                ],
              ),
            ),
            child: ZenIcon(icon, size: 38, color: t),
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
    final Color t = tone ?? zen.accent;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: t.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: t.withValues(alpha: 0.22)),
      ),
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
    final Color t = tone ?? zen.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? t : t.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
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
    // A Material (not a decorated box): list tiles inside paint their ink
    // and backgrounds on it.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: zen.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(22),
          side: BorderSide(color: zen.outlineSoft),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: <Widget>[
            for (int i = 0; i < children.length; i++) ...<Widget>[
              if (i > 0)
                Divider(
                  height: 1,
                  indent: 16,
                  endIndent: 16,
                  color: zen.outlineSoft,
                ),
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
    final BorderRadius r = BorderRadius.circular(22);
    return Padding(
      padding: margin,
      child: Material(
        color: tone == null
            ? zen.surface
            : Color.alphaBlend(tone!.withValues(alpha: 0.10), zen.surface),
        borderRadius: r,
        child: InkWell(
          borderRadius: r,
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              borderRadius: r,
              border: Border.all(
                color: tone == null
                    ? zen.outlineSoft
                    : tone!.withValues(alpha: 0.35),
              ),
            ),
            padding: padding,
            child: child,
          ),
        ),
      ),
    );
  }
}
