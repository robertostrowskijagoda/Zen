import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';

/// A stone drawn from its card alone (shape seed, colours, the painted
/// thumbnail), standing in for the 3D renderer until it is there: same
/// constructor, so swapping it is one line in `pebble_parts.dart`.
class PebbleView extends StatefulWidget {
  const PebbleView({
    required this.design,
    required this.card,
    this.size = 160,
    this.interactive = false,
    super.key,
  });

  /// The full design, `null` while only the card is here.
  final Uint8List? design;
  final PebbleCard card;
  final double size;

  /// Drag to turn the stone.
  final bool interactive;

  @override
  State<PebbleView> createState() => _PebbleViewState();
}

class _PebbleViewState extends State<PebbleView> {
  Offset _turn = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final Widget stone = SizedBox.square(
      dimension: widget.size,
      child: CustomPaint(painter: _StonePainter(widget.card)),
    );
    final Widget turned = Transform(
      alignment: Alignment.center,
      transform: Matrix4.identity()
        ..setEntry(3, 2, 0.0015)
        ..rotateX(_turn.dy)
        ..rotateY(_turn.dx),
      child: stone,
    );
    return Semantics(
      label: widget.card.name,
      image: true,
      child: widget.interactive
          ? GestureDetector(
              key: const Key('pebble-view-drag'),
              onPanUpdate: (DragUpdateDetails d) => setState(() {
                _turn += Offset(d.delta.dx / 120, -d.delta.dy / 120);
              }),
              child: turned,
            )
          : turned,
    );
  }
}

final class _StonePainter extends CustomPainter {
  _StonePainter(this.card);

  final PebbleCard card;

  @override
  void paint(Canvas canvas, Size size) {
    final Random r = Random(card.look.shapeSeed);
    final double w = size.width * (0.78 + r.nextDouble() * 0.2);
    final double h = size.height * (0.55 + r.nextDouble() * 0.25);
    final Rect oval = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: w,
      height: h,
    );
    final Color main = Color(0xFF000000 | card.look.mainColor);
    final Color second = Color(0xFF000000 | card.look.secondColor);
    canvas.drawOval(
      oval.shift(Offset(0, h * 0.06)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawOval(
      oval,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 0.95,
          colors: <Color>[
            Color.lerp(main, Colors.white, 0.35)!,
            main,
            Color.lerp(main, Colors.black, 0.35)!,
          ],
        ).createShader(oval),
    );
    canvas.save();
    canvas.clipPath(Path()..addOval(oval));
    final Paint dot = Paint()..color = second.withValues(alpha: 0.55);
    for (int i = 0; i < 18; i++) {
      canvas.drawCircle(
        Offset(
          oval.left + r.nextDouble() * oval.width,
          oval.top + r.nextDouble() * oval.height,
        ),
        1 + r.nextDouble() * size.width * 0.02,
        dot,
      );
    }
    final ({List<int> palette, List<int> pixels})? thumb =
        decodePebbleThumbnail(card.thumbnail);
    if (thumb != null) {
      final double cell = min(oval.width, oval.height) * 0.8 / 16;
      final Offset origin = oval.center - Offset(cell * 8, cell * 8);
      for (int i = 0; i < 256; i++) {
        final int index = thumb.pixels[i];
        if (index == 0) {
          continue;
        }
        canvas.drawRect(
          Rect.fromLTWH(
            origin.dx + (i % 16) * cell,
            origin.dy + (i ~/ 16) * cell,
            cell + 0.5,
            cell + 0.5,
          ),
          Paint()..color = Color(0xFF000000 | thumb.palette[index]),
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StonePainter old) => old.card != card;
}
