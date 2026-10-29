import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_backdrop.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The theme picker of Ustawienia → Wygląd: the palettes in their groups
/// ([ZenThemeCategory]), each as a live miniature of the app drawn with
/// that palette's own theme (rail, header, a card with a badge, a chat
/// bubble, a button, a label and its backdrop). One tap applies it.
class ZenThemePicker extends StatelessWidget {
  const ZenThemePicker({
    required this.selected,
    required this.accent,
    required this.brightness,
    required this.onSelect,
    super.key,
  });

  final AppPalette selected;

  /// The accent of Klasyczny.
  final AppAccentTheme accent;

  /// The mode the previews are shown in (a dark-only palette stays dark).
  final Brightness brightness;
  final ValueChanged<AppPalette> onSelect;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      key: const Key('settings-palette-picker'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final ZenThemeCategory category in ZenThemeCategory.values)
          Padding(
            key: Key('settings-palette-category-${category.name}'),
            padding: EdgeInsets.only(
              top: category == ZenThemeCategory.values.first ? 0 : 18,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  category.label,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  category.caption,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 12.5,
                    height: 1.3,
                  ),
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints c) {
                    // Two previews per row on a phone, more on a wide window.
                    const double gap = 10;
                    final int columns = (c.maxWidth / 170).floor().clamp(2, 6);
                    final double width =
                        (c.maxWidth - gap * (columns - 1)) / columns;
                    return Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: <Widget>[
                        for (final AppPalette p in category.palettes)
                          SizedBox(
                            width: width,
                            child: ZenThemeCard(
                              palette: p,
                              accent: accent,
                              brightness: brightness,
                              selected: selected == p,
                              onTap: () => onSelect(p),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One palette to pick: its miniature, name and character.
class ZenThemeCard extends StatelessWidget {
  const ZenThemeCard({
    required this.palette,
    required this.accent,
    required this.brightness,
    required this.selected,
    required this.onTap,
    super.key,
  });

  final AppPalette palette;
  final AppAccentTheme accent;
  final Brightness brightness;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final ShapeBorder shape = RoundedRectangleBorder(
      borderRadius: look.br(18),
      side: BorderSide(
        color: selected ? zen.accent : zen.outlineSoft,
        width: selected ? 2 : 1,
      ),
    );
    return Semantics(
      selected: selected,
      button: true,
      label: palette.label,
      child: Material(
        color: look.panelColor(zen),
        shape: shape,
        child: InkWell(
          key: Key('settings-palette-${palette.name}'),
          customBorder: shape,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ClipRRect(
                  borderRadius: look.br(12),
                  child: ZenThemePreview(
                    palette: palette,
                    accent: accent,
                    brightness: brightness,
                  ),
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(6, 8, 4, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              palette.label,
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 14.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              palette.tagline,
                              style: TextStyle(
                                color: zen.textSecondary,
                                fontSize: 12,
                                height: 1.25,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (selected)
                        Padding(
                          padding: const EdgeInsetsDirectional.only(start: 4),
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 20,
                            color: zen.accent,
                          ),
                        ),
                    ],
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

/// A still miniature of the app in [palette]: built from the real kit
/// pieces under that palette's theme, then scaled down. It does not
/// animate and takes no taps.
class ZenThemePreview extends StatelessWidget {
  const ZenThemePreview({
    required this.palette,
    required this.accent,
    required this.brightness,
    super.key,
  });

  final AppPalette palette;
  final AppAccentTheme accent;
  final Brightness brightness;

  /// The logical size the miniature is laid out at before scaling.
  static const Size layoutSize = Size(220, 150);

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = ZenTheme.forPalette(palette, accent, brightness);
    return ExcludeSemantics(
      child: IgnorePointer(
        child: TickerMode(
          enabled: false,
          child: AspectRatio(
            aspectRatio: layoutSize.width / layoutSize.height,
            child: FittedBox(
              child: SizedBox.fromSize(
                size: layoutSize,
                child: Theme(
                  data: theme,
                  child: DefaultTextStyle(
                    style: theme.textTheme.bodyMedium ?? const TextStyle(),
                    child: const _MiniApp(),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniApp extends StatelessWidget {
  const _MiniApp();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final BoxDecoration? themed = look.bubble(zen, outgoing: true);
    final Decoration bubble =
        themed ??
        BoxDecoration(
          gradient: zen.accentGradient,
          borderRadius: BorderRadiusDirectional.only(
            topStart: Radius.circular(look.radius(12)),
            topEnd: Radius.circular(look.radius(12)),
            bottomStart: Radius.circular(look.radius(12)),
            bottomEnd: Radius.circular(look.radius(3)),
          ),
        );
    return ColoredBox(
      color: zen.background,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (look.backdrop != ZenBackdrop.none)
            ZenBackdropLayer(kind: look.backdrop, colors: zen, still: true),
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // The tab rail with its active tab.
              DecoratedBox(
                decoration: look.railDecoration(zen),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(3, 8, 3, 8),
                  child: Column(
                    children: <Widget>[
                      for (final (int i, IconData icon) in <IconData>[
                        Icons.dynamic_feed_rounded,
                        Icons.chat_bubble_rounded,
                        Icons.people_alt_rounded,
                        Icons.person_rounded,
                      ].indexed)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5),
                          child: ZenRailTabFrame(
                            selected: i == 1,
                            padding: const EdgeInsets.all(3),
                            child: Icon(
                              icon,
                              size: 13,
                              color: i == 1 ? zen.accent : zen.textMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _MiniHeader(zen: zen, look: look),
                      const SizedBox(height: 7),
                      ZenCard(
                        margin: EdgeInsets.zero,
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          children: <Widget>[
                            const ZenBlobAvatar(
                              name: 'Ada',
                              online: true,
                              size: 20,
                              showStatus: false,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    'Ada',
                                    maxLines: 1,
                                    style: TextStyle(
                                      color: zen.textPrimary,
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  Container(
                                    margin: const EdgeInsets.only(top: 3),
                                    height: 3,
                                    width: 46,
                                    color: zen.textMuted,
                                  ),
                                ],
                              ),
                            ),
                            const ZenCountBadge(2),
                          ],
                        ),
                      ),
                      const SizedBox(height: 7),
                      Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: bubble,
                          child: Text(
                            t('Cześć!'),
                            maxLines: 1,
                            style: TextStyle(
                              color: themed == null
                                  ? zen.onAccent
                                  : zen.textPrimary,
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Row(
                        children: <Widget>[
                          FilledButton(
                            onPressed: () {},
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 22),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              visualDensity: VisualDensity.compact,
                            ),
                            // The size only: the look's font stays.
                            child: Text(
                              t('Zapisz'),
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Flexible(child: ZenPill(text: t('nowe'))),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// The section header of the look, in miniature.
class _MiniHeader extends StatelessWidget {
  const _MiniHeader({required this.zen, required this.look});

  final ZenColors zen;
  final ZenLook look;

  @override
  Widget build(BuildContext context) {
    final ZenHeaderStyle h = look.header;
    final bool upper =
        h == ZenHeaderStyle.chrome ||
        h == ZenHeaderStyle.glitch ||
        h == ZenHeaderStyle.pixel ||
        h == ZenHeaderStyle.banner;
    final bool lcd = h == ZenHeaderStyle.spectrum || h == ZenHeaderStyle.lcd;
    TextStyle style = zen.display(
      color: h == ZenHeaderStyle.banner
          ? zen.onAccent
          : lcd
          ? zen.accent
          : zen.textPrimary,
      size: upper ? 12 : 14,
      weight: upper ? FontWeight.w800 : FontWeight.w600,
      letterSpacing: upper ? 1.5 : 0,
    );
    style = switch (h) {
      ZenHeaderStyle.glitch => style.copyWith(
        shadows: <Shadow>[
          Shadow(color: zen.accent, offset: const Offset(-1.5, 0)),
          Shadow(color: zen.accentTertiary, offset: const Offset(1.5, 0)),
        ],
      ),
      ZenHeaderStyle.pixel => style.copyWith(
        shadows: <Shadow>[
          Shadow(color: zen.accentSecondary, offset: const Offset(2, 2)),
        ],
      ),
      ZenHeaderStyle.ornament ||
      ZenHeaderStyle.neonTube ||
      ZenHeaderStyle.brackets => style.copyWith(
        shadows: zen.glow > 0
            ? <Shadow>[
                Shadow(color: zen.accent.withValues(alpha: 0.7), blurRadius: 6),
              ]
            : null,
      ),
      _ => style,
    };
    Widget text = Text(upper ? 'ZEN' : 'Zen', maxLines: 1, style: style);
    if (h == ZenHeaderStyle.chrome) {
      text = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (Rect b) => LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[zen.textPrimary, zen.accent, zen.accentSecondary],
        ).createShader(b),
        child: text,
      );
    }
    Widget diamond() => Transform.rotate(
      angle: 0.785398,
      child: Container(width: 5, height: 5, color: zen.accent),
    );
    return Row(
      children: <Widget>[
        switch (h) {
          ZenHeaderStyle.bar || ZenHeaderStyle.neonTube => Container(
            width: 3,
            height: 13,
            margin: const EdgeInsetsDirectional.only(end: 6),
            decoration: BoxDecoration(
              color: zen.accent,
              borderRadius: look.br(2),
              boxShadow: zen.neonGlow(zen.accent, radius: 6),
            ),
          ),
          ZenHeaderStyle.prompt => Padding(
            padding: const EdgeInsetsDirectional.only(end: 5),
            child: Text('>', style: style.copyWith(color: zen.accent)),
          ),
          ZenHeaderStyle.pixel => Container(
            width: 7,
            height: 7,
            margin: const EdgeInsetsDirectional.only(end: 6),
            color: zen.accent,
          ),
          ZenHeaderStyle.ornament => Padding(
            padding: const EdgeInsetsDirectional.only(end: 6),
            child: diamond(),
          ),
          _ => const SizedBox.shrink(),
        },
        switch (h) {
          ZenHeaderStyle.banner => Transform.rotate(
            angle: -0.04,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: zen.accent,
                border: Border.all(color: zen.outlineStrong, width: 1.5),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: zen.outlineStrong,
                    offset: const Offset(2, 2),
                  ),
                ],
              ),
              child: text,
            ),
          ),
          ZenHeaderStyle.brackets => Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              border: Border.all(color: zen.accent.withValues(alpha: 0.8)),
              boxShadow: zen.neonGlow(zen.accent, radius: 6),
            ),
            child: text,
          ),
          ZenHeaderStyle.spectrum || ZenHeaderStyle.lcd => Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: ShapeDecoration(
              color: zen.surfaceSunk,
              shape: ZenBevelBorder.of(zen, sunken: true),
            ),
            child: text,
          ),
          ZenHeaderStyle.underline => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              text,
              Container(
                margin: const EdgeInsets.only(top: 2),
                width: 16,
                height: 1,
                color: zen.accent,
              ),
            ],
          ),
          _ => text,
        },
        if (h == ZenHeaderStyle.prompt)
          Container(
            margin: const EdgeInsetsDirectional.only(start: 3),
            width: 6,
            height: 12,
            color: zen.accent,
          ),
        if (h == ZenHeaderStyle.ornament)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 6),
            child: diamond(),
          ),
      ],
    );
  }
}
