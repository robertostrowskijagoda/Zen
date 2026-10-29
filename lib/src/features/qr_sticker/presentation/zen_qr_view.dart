import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zen/src/app/theme/zen_fixed.dart';
import 'package:zen/src/features/qr_sticker/zen_qr_code.dart';

/// A QR code on screen, drawn for the camera of another phone: the lowest
/// version the data fits ([zenQrCode], L on screen only when that makes it
/// smaller), dark square modules on white, the standard quiet zone of four
/// modules around it, and every module a whole number of the screen's
/// pixels (a module of 3.4 pixels smears into grey edges that cameras
/// misread). The code takes the largest such size up to [size].
class ZenQrView extends StatelessWidget {
  const ZenQrView({
    required this.data,
    required this.size,
    this.medium = ZenQrMedium.screen,
    this.quietZone = 4,
    super.key,
  });

  /// What the code says.
  final String data;

  /// The most space it takes on a side (logical pixels), quiet zone
  /// included.
  final double size;

  final ZenQrMedium medium;

  /// Light modules around the code (the standard asks for 4).
  final int quietZone;

  @override
  Widget build(BuildContext context) {
    final QrImage image = QrImage(zenQrCode(data, medium: medium));
    final double ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final int modules = image.moduleCount + quietZone * 2;
    final int pixels = math.max(1, (size * ratio / modules).floor());
    final double side = pixels * modules / ratio;
    return Semantics(
      image: true,
      label: 'QR',
      // A layer of its own: the code is painted once, not with every frame
      // of what moves around it.
      child: RepaintBoundary(
        child: SizedBox.square(
          dimension: side,
          child: CustomPaint(
            painter: ZenQrPainter(
              image: image,
              quietZone: quietZone,
              modulePixels: pixels,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints [image] with a quiet zone, each module [modulePixels] device
/// pixels and its edges on whole device pixels.
class ZenQrPainter extends CustomPainter {
  const ZenQrPainter({
    required this.image,
    required this.quietZone,
    required this.modulePixels,
  });

  final QrImage image;
  final int quietZone;
  final int modulePixels;

  /// The QR version (1–40).
  int get version => image.typeNumber;

  @override
  void paint(Canvas canvas, Size size) {
    final int count = image.moduleCount;
    final double module = size.width / (count + quietZone * 2);
    canvas.drawRect(Offset.zero & size, Paint()..color = ZenFixed.qrPaper);
    // Where the code starts may fall between two device pixels: move it
    // onto the nearest one, so every module edge is sharp.
    final List<double> m = canvas.getTransform();
    final double scale = m[0] == 0 ? 1 : m[0];
    final double dx = (m[12].roundToDouble() - m[12]) / scale;
    final double dy = (m[13].roundToDouble() - m[13]) / scale;
    final Paint ink = Paint()
      ..color = ZenFixed.qrInk
      ..isAntiAlias = false;
    final Path path = Path();
    for (int r = 0; r < count; r++) {
      for (int c = 0; c < count; c++) {
        if (image.isDark(r, c)) {
          path.addRect(
            Rect.fromLTWH(
              dx + (c + quietZone) * module,
              dy + (r + quietZone) * module,
              module,
              module,
            ),
          );
        }
      }
    }
    canvas.drawPath(path, ink);
  }

  @override
  bool shouldRepaint(ZenQrPainter old) =>
      old.image != image ||
      old.quietZone != quietZone ||
      old.modulePixels != modulePixels;
}
