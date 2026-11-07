import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The part of a picture the person kept when framing it, as fractions of
/// the picture's width and height (0…1), measured on the picture as it is
/// shown: turned upright by its EXIF orientation.
@immutable
final class CropRegion {
  const CropRegion({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// The whole picture.
  static const CropRegion full = CropRegion(
    left: 0,
    top: 0,
    width: 1,
    height: 1,
  );

  final double left;
  final double top;
  final double width;
  final double height;

  /// The region in pixels of a picture [w] x [h]: inside it, at least one
  /// pixel each way. With [aspect] (width / height) it is made that shape
  /// exactly, trimmed around its middle (rounding may have made it a pixel
  /// off).
  ({int x, int y, int width, int height}) pixels(
    int w,
    int h, {
    double? aspect,
  }) {
    double fl(double v) => v.isFinite ? v.clamp(0.0, 1.0) : 0;
    final double l = fl(left);
    final double tp = fl(top);
    final double r = fl(left + width);
    final double b = fl(top + height);
    int x = (l * w).round().clamp(0, math.max(0, w - 1));
    int y = (tp * h).round().clamp(0, math.max(0, h - 1));
    int cw = ((r * w).round() - x).clamp(1, w - x);
    int ch = ((b * h).round() - y).clamp(1, h - y);
    if (aspect != null && aspect > 0) {
      final int wantW = math.min(cw, math.max(1, (ch * aspect).round()));
      final int wantH = math.min(ch, math.max(1, (wantW / aspect).round()));
      x += (cw - wantW) ~/ 2;
      y += (ch - wantH) ~/ 2;
      cw = wantW;
      ch = wantH;
    }
    return (x: x, y: y, width: cw, height: ch);
  }

  /// Whether this is (nearly) the whole picture.
  bool get isFull =>
      left <= 0.001 && top <= 0.001 && width >= 0.999 && height >= 0.999;

  @override
  bool operator ==(Object other) =>
      other is CropRegion &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);

  @override
  String toString() => 'CropRegion($left, $top, $width x $height)';
}
