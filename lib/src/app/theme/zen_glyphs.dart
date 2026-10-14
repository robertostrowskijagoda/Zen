import 'package:flutter/material.dart';

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
