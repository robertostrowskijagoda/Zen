import 'package:flutter/material.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

/// Corner recipes from the grayscale canvas.
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
    return AppBar(
      key: const Key('section-bar'),
      actions: actions,
      bottom: bottom,
      titleSpacing: 20,
      toolbarHeight: kToolbarHeight + 8,
      title: Row(
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
              borderRadius: BorderRadius.circular(3),
              boxShadow: zen.neonGlow(zen.accent, radius: 10),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              title,
              key: const Key('section-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: zen.display(
                color: zen.textPrimary,
                size: 26,
                weight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
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
    final String initial =
        (glyph ?? (name.trim().isEmpty ? '?' : name.trim().characters.first))
            .toUpperCase();
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: <Widget>[
          // A true circle: the border is drawn on the same shape as the clip
          // (a square border inside a rounded clip showed its corners).
          ClipOval(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: zen.surfaceSunk,
                shape: BoxShape.circle,
                border: Border.all(color: zen.outline),
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
        borderRadius: ZenRadii.pill,
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
