import 'package:flutter/material.dart';

/// The Material icon that stands for the pyramid anywhere an [IconData] is
/// taken ([ZenIcon] draws it as [PyramidGlyph]).
const IconData kPyramidIcon = Icons.change_history_rounded;

/// An [Icon], except that [kPyramidIcon] is drawn as the pyramid glyph, so
/// the pyramid looks the same in the rail, headers, badges and chips.
class ZenIcon extends StatelessWidget {
  const ZenIcon(this.icon, {this.color, this.size, this.shadows, super.key});

  final IconData icon;
  final Color? color;
  final double? size;

  /// A glow under the glyph (the neon look); the pyramid glyph has none.
  final List<Shadow>? shadows;

  @override
  Widget build(BuildContext context) {
    if (icon != kPyramidIcon) {
      return Icon(icon, color: color, size: size, shadows: shadows);
    }
    final IconThemeData theme = IconTheme.of(context);
    return PyramidGlyph(
      color: color ?? theme.color ?? const Color(0xFF888888),
      size: size ?? theme.size ?? 24,
    );
  }
}

/// The pyramid: three people (circles on the corners) joined into one cell
/// (the triangle's sides) — the 2-of-3 cell everything in it is built from.
/// [filled] draws the circles solid (the selected state of a tab).
class PyramidGlyph extends StatelessWidget {
  const PyramidGlyph({
    required this.color,
    this.size = 24,
    this.filled = false,
    super.key,
  });

  final Color color;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PyramidPainter(color: color, filled: filled),
      ),
    );
  }
}

class _PyramidPainter extends CustomPainter {
  const _PyramidPainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24;
    final double r = 3.3 * u;
    final double stroke = 1.9 * u;
    final List<Offset> corners = <Offset>[
      Offset(12 * u, 4.6 * u),
      Offset(4.4 * u, 18.6 * u),
      Offset(19.6 * u, 18.6 * u),
    ];
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    // The sides stop at the circles, so hollow circles stay clean.
    for (int i = 0; i < 3; i++) {
      final Offset a = corners[i];
      final Offset b = corners[(i + 1) % 3];
      final Offset dir = (b - a) / (b - a).distance;
      canvas.drawLine(a + dir * r, b - dir * r, line);
    }
    final Paint dot = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..style = filled ? PaintingStyle.fill : PaintingStyle.stroke;
    for (final Offset c in corners) {
      canvas.drawCircle(c, filled ? r : r - stroke / 2, dot);
    }
  }

  @override
  bool shouldRepaint(_PyramidPainter old) =>
      old.color != color || old.filled != filled;
}

/// A pebble: a flat, slightly lopsided stone with a sheen on its upper
/// left edge (Kamyczki). [filled] draws the stone solid, its sheen cut out
/// (the selected state of a tab).
class PebbleGlyph extends StatelessWidget {
  const PebbleGlyph({
    required this.color,
    this.size = 24,
    this.filled = false,
    super.key,
  });

  final Color color;
  final double size;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _PebblePainter(color: color, filled: filled),
      ),
    );
  }
}

class _PebblePainter extends CustomPainter {
  const _PebblePainter({required this.color, required this.filled});

  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    final double u = size.width / 24;
    final double stroke = 1.9 * u;
    final Path stone = Path()
      ..moveTo(3.4 * u, 13.6 * u)
      ..cubicTo(3.2 * u, 9.6 * u, 7.6 * u, 6.9 * u, 12.6 * u, 7.1 * u)
      ..cubicTo(17.6 * u, 7.3 * u, 21.0 * u, 9.7 * u, 20.6 * u, 13.3 * u)
      ..cubicTo(20.2 * u, 16.9 * u, 16.4 * u, 18.7 * u, 11.7 * u, 18.5 * u)
      ..cubicTo(6.9 * u, 18.3 * u, 3.6 * u, 16.9 * u, 3.4 * u, 13.6 * u)
      ..close();
    // The sheen of a smooth stone, along its upper left edge.
    final Path paintStroke = Path()
      ..moveTo(7.0 * u, 13.0 * u)
      ..quadraticBezierTo(7.6 * u, 10.4 * u, 11.0 * u, 10.0 * u);
    final Paint line = Paint()
      ..color = color
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    if (!filled) {
      canvas.drawPath(stone, line);
      canvas.drawPath(paintStroke, line);
      return;
    }
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawPath(stone, Paint()..color = color);
    canvas.drawPath(paintStroke, line..blendMode = BlendMode.clear);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PebblePainter old) =>
      old.color != color || old.filled != filled;
}
