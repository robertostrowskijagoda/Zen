import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// The modules of one QR code, and which of them are the code's own
/// patterns (the three finder eyes, the timing lines, the alignment
/// marks, the format and version areas) rather than data: the sticker
/// styles shape only the data modules and keep the patterns whole, so a
/// camera finds and reads every style.
@immutable
final class QrMatrix {
  QrMatrix._(this.data, this.version, this.robust, this._dark)
    : size = version * 4 + 17;

  /// [data] as a QR code. [robust] uses the highest error correction (H,
  /// about 30 % of the code can be lost), which a logo in the middle
  /// needs; otherwise M (about 15 %), the better one for print than the
  /// L the app shows on screen.
  factory QrMatrix.encode(String data, {bool robust = false}) {
    final QrCode code = QrCode.fromData(
      data: data,
      errorCorrectLevel: robust ? QrErrorCorrectLevel.H : QrErrorCorrectLevel.M,
    );
    final QrImage image = QrImage(code);
    final int size = image.moduleCount;
    final List<bool> dark = List<bool>.filled(size * size, false);
    for (int r = 0; r < size; r++) {
      for (int c = 0; c < size; c++) {
        dark[r * size + c] = image.isDark(r, c);
      }
    }
    return QrMatrix._(data, image.typeNumber, robust, dark);
  }

  /// Light modules around the code that a camera needs to tell it from
  /// what is next to it (the standard asks for 4).
  static const int quietZone = 4;

  final String data;

  /// The QR version (1–40).
  final int version;

  /// Encoded with error correction H.
  final bool robust;

  /// Modules on a side.
  final int size;

  final List<bool> _dark;

  bool isDark(int row, int col) => _dark[row * size + col];

  /// The centres of the alignment marks on each axis (empty for version 1).
  late final List<int> alignmentCentres = alignmentCentresFor(version);

  /// The alignment centres of [version], as the standard places them.
  static List<int> alignmentCentresFor(int version) {
    if (version == 1) {
      return const <int>[];
    }
    final int count = version ~/ 7 + 2;
    final int size = version * 4 + 17;
    final int step = version == 32
        ? 26
        : (version * 4 + count * 2 + 1) ~/ (count * 2 - 2) * 2;
    final List<int> out = List<int>.filled(count, 6);
    int pos = size - 7;
    for (int i = count - 1; i >= 1; i--, pos -= step) {
      out[i] = pos;
    }
    return out;
  }

  /// The module is in one of the three 7 × 7 finder eyes.
  bool isFinder(int row, int col) => finderAt(row, col) != null;

  /// The top-left module of the finder eye holding (row, col), or null.
  (int, int)? finderAt(int row, int col) {
    for (final (int r0, int c0) in finderOrigins) {
      if (row >= r0 && row < r0 + 7 && col >= c0 && col < c0 + 7) {
        return (r0, c0);
      }
    }
    return null;
  }

  /// The top-left modules of the three finder eyes.
  List<(int, int)> get finderOrigins => <(int, int)>[
    (0, 0),
    (0, size - 7),
    (size - 7, 0),
  ];

  /// The module is in an alignment mark (5 × 5).
  bool isAlignment(int row, int col) {
    final List<int> centres = alignmentCentres;
    for (final int cr in centres) {
      for (final int cc in centres) {
        if (_overlapsFinder(cr, cc)) {
          continue;
        }
        if ((row - cr).abs() <= 2 && (col - cc).abs() <= 2) {
          return true;
        }
      }
    }
    return false;
  }

  /// The alignment marks that exist (those that would sit on a finder eye
  /// are left out by the standard).
  List<(int, int)> get alignmentMarks => <(int, int)>[
    for (final int cr in alignmentCentres)
      for (final int cc in alignmentCentres)
        if (!_overlapsFinder(cr, cc)) (cr, cc),
  ];

  bool _overlapsFinder(int row, int col) =>
      (row < 9 && col < 9) ||
      (row < 9 && col > size - 10) ||
      (row > size - 10 && col < 9);

  /// The module belongs to the code's own patterns, not to the data: the
  /// finder eyes with their light border, the timing lines, the alignment
  /// marks, the format areas next to the eyes, and from version 7 the two
  /// version areas.
  bool isFunction(int row, int col) {
    // The eyes and their separators (8 × 8 each), with the format areas.
    if ((row < 9 && col < 9) ||
        (row < 9 && col >= size - 8) ||
        (row >= size - 8 && col < 9)) {
      return true;
    }
    if (row == 6 || col == 6) {
      return true;
    }
    if (version >= 7 &&
        ((row < 6 && col >= size - 11 && col < size - 8) ||
            (col < 6 && row >= size - 11 && row < size - 8))) {
      return true;
    }
    return isAlignment(row, col);
  }

  /// Where a logo can go in the middle: a square of modules left empty,
  /// or null when this code cannot carry one — only with error correction
  /// H, never on a pattern (from version 7 an alignment mark sits right in
  /// the middle), and covering less than [maxLogoShare] of the code.
  late final QrHole? logoHole = _findHole();

  /// The largest share of the code's modules a logo may cover.
  static const double maxLogoShare = 0.09;

  QrHole? _findHole() {
    if (!robust) {
      return null;
    }
    int side = (size * 0.3).floor();
    if (side.isEven) {
      side -= 1;
    }
    for (; side >= 5; side -= 2) {
      if (side * side > size * size * maxLogoShare) {
        continue;
      }
      final int first = (size - side) ~/ 2;
      bool clear = true;
      for (int r = first - 1; r <= first + side && clear; r++) {
        for (int c = first - 1; c <= first + side; c++) {
          if (isFunction(r, c)) {
            clear = false;
            break;
          }
        }
      }
      if (clear) {
        return QrHole(first, side);
      }
    }
    return null;
  }

  /// The share of [hole] in all the modules.
  double shareOf(QrHole hole) => hole.side * hole.side / (size * size);

  /// The contrast ratio of [ink] on [paper] (WCAG): the
  /// stickers keep it at [minContrast] or more.
  static double contrast(int ink, int paper) {
    double channel(int v) {
      final double s = v / 255;
      return s <= 0.03928
          ? s / 12.92
          : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
    }

    double luminance(int argb) =>
        0.2126 * channel((argb >> 16) & 0xFF) +
        0.7152 * channel((argb >> 8) & 0xFF) +
        0.0722 * channel(argb & 0xFF);

    final double a = luminance(ink);
    final double b = luminance(paper);
    final double hi = math.max(a, b);
    final double lo = math.min(a, b);
    return (hi + 0.05) / (lo + 0.05);
  }

  /// The contrast every QR ink keeps on its paper.
  static const double minContrast = 7;
}

/// A square of [side] modules starting at module ([first], [first]).
@immutable
final class QrHole {
  const QrHole(this.first, this.side);

  final int first;
  final int side;

  bool contains(int row, int col) =>
      row >= first && row < first + side && col >= first && col < first + side;
}
