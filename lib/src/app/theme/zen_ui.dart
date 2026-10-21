import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_backdrop.dart';
import 'package:zen/src/app/theme/zen_concept.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_retro.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Corner recipes of the rounded default look (Klasyczny). Code with a
/// context scales them to the current look ([ZenLook.br],
/// [ZenLook.radius]).
abstract final class ZenRadii {
  static const BorderRadius pill = BorderRadius.all(Radius.circular(999));
  static const BorderRadius card = BorderRadius.all(Radius.circular(20));
  static const BorderRadius cardLg = BorderRadius.all(Radius.circular(24));

  /// Incoming bubble: `1.4rem 1.4rem 1.4rem 0.3rem`.
  static const BorderRadius drop = BorderRadius.only(
    topLeft: Radius.circular(22),
    topRight: Radius.circular(22),
    bottomRight: Radius.circular(22),
    bottomLeft: Radius.circular(5),
  );

  /// Outgoing bubble: `1.4rem 1.4rem 0.3rem 1.4rem`.
  static const BorderRadius dropEnd = BorderRadius.only(
    topLeft: Radius.circular(22),
    topRight: Radius.circular(22),
    bottomRight: Radius.circular(5),
    bottomLeft: Radius.circular(22),
  );
}

class ZenBlobClipper extends CustomClipper<Path> {
  const ZenBlobClipper({this.alt = false});

  final bool alt;

  @override
  Path getClip(Size size) {
    final double w = size.width;
    final double h = size.height;
    final Path path = Path();
    if (alt) {
      path.moveTo(w * 0.57, 0);
      path.cubicTo(w * 0.86, 0, w, h * 0.28, w, h * 0.56);
      path.cubicTo(w, h * 0.84, w * 0.72, h, w * 0.43, h);
      path.cubicTo(w * 0.16, h, 0, h * 0.72, 0, h * 0.44);
      path.cubicTo(0, h * 0.16, w * 0.22, 0, w * 0.57, 0);
    } else {
      path.moveTo(w * 0.46, 0);
      path.cubicTo(w * 0.74, 0, w, h * 0.22, w, h * 0.48);
      path.cubicTo(w, h * 0.78, w * 0.70, h, w * 0.45, h);
      path.cubicTo(w * 0.18, h, 0, h * 0.74, 0, h * 0.52);
      path.cubicTo(0, h * 0.20, w * 0.18, 0, w * 0.46, 0);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant ZenBlobClipper oldClipper) =>
      oldClipper.alt != alt;
}

/// The header of a main section (Profil, Skrzynka, Tablica, Zaproś,
/// Ustawienia): the same bar, font and size everywhere.
class ZenSectionBar extends StatelessWidget implements PreferredSizeWidget {
  const ZenSectionBar({
    required this.title,
    this.actions = const <Widget>[],
    this.bottom,
    super.key,
  });

  final String title;
  final List<Widget> actions;

  /// Tabs under the title (e.g. a TabBar).
  final PreferredSizeWidget? bottom;

  @override
  Size get preferredSize =>
      Size.fromHeight(kToolbarHeight + 8 + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    return AppBar(
      key: const Key('section-bar'),
      actions: actions,
      bottom: bottom,
      titleSpacing:
          look.header == ZenHeaderStyle.spectrum ||
              look.header == ZenHeaderStyle.lcd
          ? 12
          : 20,
      toolbarHeight: kToolbarHeight + 8,
      title: switch (look.header) {
        ZenHeaderStyle.bar => _bar(zen, look),
        ZenHeaderStyle.neonTube => _neonTube(zen),
        ZenHeaderStyle.spectrum => _spectrum(zen, strip: true),
        ZenHeaderStyle.lcd => _spectrum(zen, strip: false),
        ZenHeaderStyle.prompt => _prompt(zen),
        ZenHeaderStyle.brackets => _brackets(zen),
        ZenHeaderStyle.underline => _underline(zen),
        ZenHeaderStyle.chrome => _chrome(zen),
        ZenHeaderStyle.glitch => _glitch(zen),
        ZenHeaderStyle.pixel => _pixel(zen),
        ZenHeaderStyle.ornament => _ornament(zen),
        ZenHeaderStyle.banner => _banner(zen),
      },
    );
  }

  /// Wide-spaced capitals in a chrome gradient (sunset, vapour, hologram).
  Widget _chrome(ZenColors zen) {
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (Rect b) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: <Color>[
          zen.textPrimary,
          zen.accentTertiary,
          zen.accent,
          zen.accentSecondary,
        ],
        stops: const <double>[0, 0.45, 0.55, 1],
      ).createShader(b),
      child: _titleText(
        zen.display(
          color: zen.textPrimary,
          size: 23,
          weight: FontWeight.w700,
          letterSpacing: 3,
        ),
        upper: true,
      ),
    );
  }

  /// The title with two shifted colour ghosts (the city, the hacker).
  Widget _glitch(ZenColors zen) {
    return _titleText(
      zen
          .display(
            color: zen.textPrimary,
            size: 24,
            weight: FontWeight.w700,
            letterSpacing: 1.6,
          )
          .copyWith(
            shadows: <Shadow>[
              Shadow(
                color: zen.accent.withValues(alpha: 0.85),
                offset: const Offset(-2.5, 0),
              ),
              Shadow(
                color: zen.accentTertiary.withValues(alpha: 0.85),
                offset: const Offset(2.5, 0.5),
              ),
            ],
          ),
      upper: true,
    );
  }

  /// Heavy capitals with a hard pixel shadow and a pixel block (arcade).
  Widget _pixel(ZenColors zen) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: zen.accent,
            boxShadow: <BoxShadow>[
              BoxShadow(color: zen.accentSecondary, offset: const Offset(3, 3)),
            ],
          ),
        ),
        const SizedBox(width: 14),
        Flexible(
          child: _titleText(
            zen
                .display(
                  color: zen.textPrimary,
                  size: 23,
                  weight: FontWeight.w800,
                  letterSpacing: 2,
                )
                .copyWith(
                  shadows: <Shadow>[
                    Shadow(
                      color: zen.accentSecondary,
                      offset: const Offset(3, 3),
                    ),
                  ],
                ),
            upper: true,
          ),
        ),
      ],
    );
  }

  /// A glowing title between two little diamonds (fairy tale, brass).
  Widget _ornament(ZenColors zen) {
    Widget diamond() => Transform.rotate(
      angle: 0.785398,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: zen.accent,
          boxShadow: zen.neonGlow(zen.accent, radius: 8),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        diamond(),
        const SizedBox(width: 12),
        Flexible(
          child: _titleText(
            zen
                .display(
                  color: zen.textPrimary,
                  size: 25,
                  weight: FontWeight.w600,
                  letterSpacing: 1,
                )
                .copyWith(
                  shadows: zen.glow > 0
                      ? <Shadow>[
                          Shadow(
                            color: zen.accent.withValues(alpha: 0.55),
                            blurRadius: 12,
                          ),
                        ]
                      : null,
                ),
          ),
        ),
        const SizedBox(width: 12),
        diamond(),
      ],
    );
  }

  /// Capitals on a tilted, ink-framed banner (comics).
  Widget _banner(ZenColors zen) {
    return Transform.rotate(
      angle: -0.035,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 3, 12, 4),
        decoration: BoxDecoration(
          color: zen.accent,
          border: Border.all(color: zen.outlineStrong, width: 2.5),
          boxShadow: <BoxShadow>[
            BoxShadow(color: zen.outlineStrong, offset: const Offset(4, 4)),
          ],
        ),
        child: _titleText(
          zen.display(
            color: zen.onAccent,
            size: 21,
            weight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
          upper: true,
        ),
      ),
    );
  }

  /// Terminals: a chevron, the title and a blinking block cursor.
  Widget _prompt(ZenColors zen) {
    final TextStyle style = zen.display(
      color: zen.textPrimary,
      size: 24,
      weight: FontWeight.w500,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text('>', style: style.copyWith(color: zen.accent)),
        const SizedBox(width: 10),
        Flexible(child: _titleText(style)),
        const SizedBox(width: 6),
        ZenBlinkingCursor(color: zen.accent, height: 22),
      ],
    );
  }

  /// HUD corner marks around a lit title, lighting up once.
  Widget _brackets(ZenColors zen) {
    return ZenFlickerOn(
      child: CustomPaint(
        painter: _BracketPainter(color: zen.accent, glow: zen.glow),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: _titleText(
            zen
                .display(
                  color: zen.textPrimary,
                  size: 24,
                  weight: FontWeight.w500,
                  letterSpacing: 1.6,
                )
                .copyWith(
                  shadows: <Shadow>[
                    Shadow(
                      color: zen.accent.withValues(alpha: 0.7),
                      blurRadius: 10,
                    ),
                  ],
                ),
          ),
        ),
      ),
    );
  }

  /// Elegant: the title over a short fine rule and a dash.
  Widget _underline(ZenColors zen) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _titleText(
          zen.display(
            color: zen.textPrimary,
            size: 25,
            weight: FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(width: 28, height: 1.5, color: zen.accent),
            const SizedBox(width: 4),
            Container(
              width: 6,
              height: 1.5,
              color: zen.accent.withValues(alpha: 0.5),
            ),
          ],
        ),
      ],
    );
  }

  Widget _titleText(TextStyle style, {bool upper = false}) => Text(
    upper ? title.toUpperCase() : title,
    key: const Key('section-title'),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: style,
  );

  Widget _bar(ZenColors zen, ZenLook look) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 5,
          height: 24,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[
                zen.accent,
                zen.gradientPartner(zen.accent, zen.accentSecondary),
              ],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: look.br(3),
            boxShadow: zen.neonGlow(zen.accent, radius: 10),
          ),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: _titleText(
            zen.display(
              color: zen.textPrimary,
              size: 26,
              weight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  /// Neon: a thin lit tube and a glowing title, lighting up once.
  Widget _neonTube(ZenColors zen) {
    return ZenFlickerOn(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 3,
            height: 26,
            decoration: BoxDecoration(
              color: zen.accent,
              borderRadius: BorderRadius.circular(2),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: zen.accent.withValues(alpha: 0.9),
                  blurRadius: 6,
                ),
                BoxShadow(
                  color: zen.accent.withValues(alpha: 0.45),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Flexible(
            child: _titleText(
              zen
                  .display(
                    color: zen.textPrimary,
                    size: 26,
                    weight: FontWeight.w500,
                    letterSpacing: 1.2,
                  )
                  .copyWith(
                    shadows: <Shadow>[
                      Shadow(
                        color: zen.accent.withValues(alpha: 0.75),
                        blurRadius: 12,
                      ),
                      Shadow(
                        color: zen.accent.withValues(alpha: 0.35),
                        blurRadius: 26,
                      ),
                    ],
                  ),
            ),
          ),
        ],
      ),
    );
  }

  /// Retro: the title on an LCD strip ([strip]: a spectrum analyzer
  /// beside it).
  Widget _spectrum(ZenColors zen, {required bool strip}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: Container(
            padding: const EdgeInsets.fromLTRB(10, 2, 12, 2),
            decoration: ShapeDecoration(
              color: zen.surfaceSunk,
              shape: ZenBevelBorder.of(zen, sunken: true),
            ),
            child: _titleText(
              zen
                  .display(
                    color: zen.accent,
                    size: 26,
                    weight: FontWeight.w400,
                    letterSpacing: 1,
                    height: 1.1,
                  )
                  .copyWith(
                    shadows: <Shadow>[
                      Shadow(
                        color: zen.accent.withValues(alpha: 0.45),
                        blurRadius: 6,
                      ),
                    ],
                  ),
            ),
          ),
        ),
        if (strip) ...<Widget>[
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: ShapeDecoration(
              color: zen.surfaceSunk,
              shape: ZenBevelBorder.of(zen, sunken: true),
            ),
            child: const ZenSpectrumStrip(),
          ),
        ],
      ],
    );
  }
}

class ZenLabel extends StatelessWidget {
  const ZenLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Text(
      text.toUpperCase(),
      style: zen.label(color: color ?? zen.textSecondary),
    );
  }
}

class ZenHairline extends StatelessWidget {
  const ZenHairline({super.key, this.opacity = 0.4});

  final double opacity;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Opacity(
      opacity: opacity,
      child: SizedBox(
        height: 1,
        width: double.infinity,
        child: DecoratedBox(
          decoration: BoxDecoration(gradient: zen.accentRule()),
        ),
      ),
    );
  }
}

class ZenStatusDot extends StatelessWidget {
  const ZenStatusDot({super.key, required this.on, this.size = 6});

  final bool on;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (on) {
      return ZenPulsingDot(
        color: zen.success,
        active: true,
        dimension: size + 6,
        dotSize: size,
      );
    }
    return SizedBox.square(
      dimension: size + 6,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: zen.outlineStrong),
          ),
          child: SizedBox.square(dimension: size),
        ),
      ),
    );
  }
}

class ZenBlobAvatar extends StatelessWidget {
  const ZenBlobAvatar({
    super.key,
    required this.name,
    this.online = false,
    this.size = 44,
    this.glyph,
    this.image,
    this.showStatus = true,
  });

  final String name;
  final bool online;

  /// The online dot (not for your own avatar).
  final bool showStatus;
  final double size;
  final String? glyph;
  final ImageProvider? image;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final String initial =
        (glyph ?? (name.trim().isEmpty ? '?' : name.trim().characters.first))
            .toUpperCase();
    // Neon: a lit ring, glowing while the person is online.
    final Color ring = look.lit
        ? zen.accent.withValues(alpha: online ? 0.95 : 0.55)
        : look.bevelled
        ? zen.outlineStrong
        : zen.outline;
    // Round in the rounded looks; a rounded square, down to a sharp one,
    // in the angular looks.
    final bool round = look.corner >= 0.5;
    final BorderRadius corners = look.br(size * 0.5);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          if (look.lit && online)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: round ? BoxShape.circle : BoxShape.rectangle,
                  borderRadius: round ? null : corners,
                  boxShadow: zen.neonGlow(zen.accent, radius: 12),
                ),
              ),
            ),
          // The border is drawn on the same shape as the clip (a square
          // border inside a rounded clip showed its corners).
          ClipRRect(
            borderRadius: round ? BorderRadius.circular(size / 2) : corners,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: zen.surfaceSunk,
                shape: round ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: round ? null : corners,
                border: Border.all(color: ring, width: look.lit ? 1.4 : 1),
                image: image == null
                    ? null
                    : DecorationImage(image: image!, fit: BoxFit.cover),
              ),
              child: SizedBox.square(
                dimension: size,
                child: image == null
                    ? Center(
                        child: Text(
                          initial,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: size * 0.38,
                            weight: FontWeight.w600,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
          ),
          if (showStatus)
            Positioned(
              right: -2,
              bottom: -2,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: zen.background,
                  shape: BoxShape.circle,
                  border: Border.all(color: zen.background, width: 2),
                ),
                child: ZenStatusDot(on: online, size: 6),
              ),
            ),
        ],
      ),
    );
  }
}

class ZenCanvasBackdrop extends StatelessWidget {
  const ZenCanvasBackdrop({
    super.key,
    required this.child,
    this.scanlines = false,
    this.grid = false,
  });

  final Widget child;
  final bool scanlines;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    Widget content = child;
    if (grid) {
      content = CustomPaint(
        painter: _ZenGridPainter(
          color: zen.textPrimary.withValues(alpha: 0.06),
        ),
        child: content,
      );
    }
    if (scanlines) {
      content = CustomPaint(
        foregroundPainter: _ZenScanlinePainter(
          color: zen.textPrimary.withValues(alpha: 0.05),
        ),
        child: content,
      );
    }
    return content;
  }
}

class _ZenGridPainter extends CustomPainter {
  const _ZenGridPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const double step = 22;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ZenGridPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _ZenScanlinePainter extends CustomPainter {
  const _ZenScanlinePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()..color = color;
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ZenScanlinePainter oldDelegate) =>
      oldDelegate.color != color;
}

class ZenBadge extends StatelessWidget {
  const ZenBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: ZenLook.of(context).chipRadius,
        border: Border.all(color: zen.outlineStrong),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          text.toUpperCase(),
          style: zen.mono(
            color: zen.textSecondary,
            size: 10,
            letterSpacing: 0.6,
          ),
        ),
      ),
    );
  }
}

class ZenUnreadBlob extends StatelessWidget {
  const ZenUnreadBlob(this.count, {super.key});

  final int count;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ClipPath(
      clipper: const ZenBlobClipper(),
      child: ColoredBox(
        color: zen.accent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text(
              '$count',
              textAlign: TextAlign.center,
              style: zen.mono(
                color: zen.onAccent,
                size: 10,
                weight: FontWeight.w700,
                letterSpacing: 0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// HUD corner marks at the four corners of the box, lit.
class _BracketPainter extends CustomPainter {
  const _BracketPainter({required this.color, required this.glow});

  final Color color;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    const double arm = 8;
    final Path p = Path()
      ..moveTo(0, arm)
      ..lineTo(0, 0)
      ..lineTo(arm, 0)
      ..moveTo(size.width - arm, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width, arm)
      ..moveTo(size.width, size.height - arm)
      ..lineTo(size.width, size.height)
      ..lineTo(size.width - arm, size.height)
      ..moveTo(arm, size.height)
      ..lineTo(0, size.height)
      ..lineTo(0, size.height - arm);
    final Paint line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = color;
    if (glow > 0) {
      canvas.drawPath(
        p,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = color.withValues(alpha: (0.4 * glow).clamp(0.0, 1.0))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );
    }
    canvas.drawPath(p, line);
  }

  @override
  bool shouldRepaint(_BracketPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.glow != glow;
}
