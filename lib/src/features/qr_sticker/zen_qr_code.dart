import 'dart:convert';

import 'package:qr_flutter/qr_flutter.dart';

/// Where a QR code is shown: the error correction follows from it.
enum ZenQrMedium {
  /// Printed (stickers, posters): error correction M (about 15 % of the
  /// code may be scratched, stained or folded).
  print,

  /// Printed with a logo in the middle: H (about 30 %), the logo covers
  /// part of the code.
  printWithLogo,

  /// On a screen: L when that makes the code a version smaller than M
  /// (larger modules for the same space; a screen is never stained or
  /// creased, and the camera's trouble there is glare and moiré, which
  /// larger modules help with), otherwise M at no cost.
  screen,
}

/// [data] as a QR code at the lowest version it fits, in segments chosen
/// so it takes the fewest bits: digits in numeric mode (3.3 bits each),
/// runs of upper-case letters, digits and ` $%*+-./:` in alphanumeric mode
/// (5.5 bits), the rest in byte mode (8 bits). Every reader decodes the
/// segments back into the same text; a long run of digits (the pebble
/// links) is what gains the most.
QrCode zenQrCode(String data, {ZenQrMedium medium = ZenQrMedium.print}) {
  final int level = switch (medium) {
    ZenQrMedium.print => QrErrorCorrectLevel.M,
    ZenQrMedium.printWithLogo => QrErrorCorrectLevel.H,
    ZenQrMedium.screen =>
      zenQrVersion(data, QrErrorCorrectLevel.L) <
              zenQrVersion(data, QrErrorCorrectLevel.M)
          ? QrErrorCorrectLevel.L
          : QrErrorCorrectLevel.M,
  };
  final int version = zenQrVersion(data, level);
  final QrCode code = QrCode(version, level);
  for (final ZenQrSegment s in zenQrSegments(data, version)) {
    switch (s.mode) {
      case ZenQrMode.numeric:
        code.addNumeric(s.text);
      case ZenQrMode.alphanumeric:
        code.addAlphaNumeric(s.text);
      case ZenQrMode.byte:
        code.addData(s.text);
    }
  }
  return code;
}

/// The lowest QR version (1–40) [data] fits at error correction [level]
/// ([QrErrorCorrectLevel]); throws [ArgumentError] when it fits none.
int zenQrVersion(String data, int level) {
  final List<int> capacity = _dataCodewords[level]!;
  for (int version = 1; version <= 40; version++) {
    if (!zenQrVersionWorks(version, level)) {
      continue;
    }
    if (zenQrBits(data, version) <= capacity[version - 1] * 8) {
      return version;
    }
  }
  throw ArgumentError('Too long for a QR code.');
}

/// Whether the qr package writes a valid code of [version] at [level]: its
/// table lacks the second group of blocks of version 15 at H (7 blocks of
/// 13 data codewords), so a code it makes there cannot be read. The next
/// version up is taken instead.
bool zenQrVersionWorks(int version, int level) =>
    !(version == 15 && level == QrErrorCorrectLevel.H);

/// The bits [data] takes in a QR code of [version] with [zenQrSegments].
int zenQrBits(String data, int version) {
  int bits = 0;
  for (final ZenQrSegment s in zenQrSegments(data, version)) {
    bits += s.bits(version);
  }
  return bits;
}

/// How many data codewords (bytes) a QR code of [version] carries at
/// error correction [level] (ISO/IEC 18004, table 7).
int zenQrCapacity(int version, int level) =>
    _dataCodewords[level]![version - 1];

/// The three ways a QR code writes characters.
enum ZenQrMode { numeric, alphanumeric, byte }

/// A run of [text] written in one [mode].
final class ZenQrSegment {
  const ZenQrSegment(this.mode, this.text);

  final ZenQrMode mode;
  final String text;

  /// The bits of this segment (mode, length and data) in [version].
  int bits(int version) {
    final int group = version <= 9
        ? 0
        : version <= 26
        ? 1
        : 2;
    switch (mode) {
      case ZenQrMode.numeric:
        final int n = text.length;
        return 4 +
            const <int>[10, 12, 14][group] +
            n ~/ 3 * 10 +
            const <int>[0, 4, 7][n % 3];
      case ZenQrMode.alphanumeric:
        final int n = text.length;
        return 4 + const <int>[9, 11, 13][group] + n ~/ 2 * 11 + n % 2 * 6;
      case ZenQrMode.byte:
        return 4 + const <int>[8, 16, 16][group] + utf8.encode(text).length * 8;
    }
  }

  @override
  String toString() => '${mode.name}($text)';
}

const String _alphanumeric = r'0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:';

/// [data] cut into the segments that take the fewest bits in a code of
/// [version] (the length fields grow at versions 10 and 27): a shortest
/// path over the characters, each written in any mode that can hold it,
/// paying a segment's header whenever the mode changes.
List<ZenQrSegment> zenQrSegments(String data, int version) {
  final List<int> chars = data.runes.toList(growable: false);
  if (chars.isEmpty) {
    return const <ZenQrSegment>[];
  }
  final int group = version <= 9
      ? 0
      : version <= 26
      ? 1
      : 2;
  // Costs in sixths of a bit: a digit is 10/3 bits, an alphanumeric
  // character 11/2, a byte 8.
  final List<int> header = <int>[
    (4 + const <int>[10, 12, 14][group]) * 6,
    (4 + const <int>[9, 11, 13][group]) * 6,
    (4 + const <int>[8, 16, 16][group]) * 6,
  ];
  int charCost(int mode, int c) => switch (mode) {
    0 => c >= 0x30 && c <= 0x39 ? 20 : -1,
    1 => c < 128 && _alphanumeric.contains(String.fromCharCode(c)) ? 33 : -1,
    _ => utf8.encode(String.fromCharCode(c)).length * 48,
  };
  const int none = 1 << 50;
  final int n = chars.length;
  // cost[i][m]: the cheapest way to write the first i + 1 characters with
  // the last one in mode m; from[i][m]: the mode of the one before.
  final List<List<int>> cost = List<List<int>>.generate(
    n,
    (_) => List<int>.filled(3, none),
  );
  final List<List<int>> from = List<List<int>>.generate(
    n,
    (_) => List<int>.filled(3, -1),
  );
  for (int i = 0; i < n; i++) {
    for (int m = 0; m < 3; m++) {
      final int c = charCost(m, chars[i]);
      if (c < 0) {
        continue;
      }
      if (i == 0) {
        cost[i][m] = header[m] + c;
        continue;
      }
      for (int p = 0; p < 3; p++) {
        if (cost[i - 1][p] == none) {
          continue;
        }
        // A segment's last group rounds up to whole bits; a change of
        // mode pays for that and the new header.
        final int v = cost[i - 1][p] + c + (p == m ? 0 : header[m] + 5);
        if (v < cost[i][m]) {
          cost[i][m] = v;
          from[i][m] = p;
        }
      }
    }
  }
  int mode = 0;
  for (int m = 1; m < 3; m++) {
    if (cost[n - 1][m] < cost[n - 1][mode]) {
      mode = m;
    }
  }
  final List<int> modes = List<int>.filled(n, 0);
  for (int i = n - 1; i >= 0; i--) {
    modes[i] = mode;
    mode = from[i][mode];
  }
  final List<ZenQrSegment> out = <ZenQrSegment>[];
  int start = 0;
  for (int i = 1; i <= n; i++) {
    if (i == n || modes[i] != modes[start]) {
      out.add(
        ZenQrSegment(
          ZenQrMode.values[modes[start]],
          String.fromCharCodes(chars.sublist(start, i)),
        ),
      );
      start = i;
    }
  }
  return _merged(out, version);
}

/// [segments] with any short one folded into its neighbour when that is
/// fewer bits after all (the path above counts headers in fractions).
List<ZenQrSegment> _merged(List<ZenQrSegment> segments, int version) {
  final List<ZenQrSegment> out = List<ZenQrSegment>.of(segments);
  bool changed = true;
  while (changed && out.length > 1) {
    changed = false;
    for (int i = 0; i + 1 < out.length; i++) {
      final ZenQrSegment a = out[i];
      final ZenQrSegment b = out[i + 1];
      final ZenQrMode wider = a.mode.index > b.mode.index ? a.mode : b.mode;
      final ZenQrSegment joined = ZenQrSegment(wider, a.text + b.text);
      if (joined.bits(version) <= a.bits(version) + b.bits(version)) {
        out
          ..removeAt(i + 1)
          ..[i] = joined;
        changed = true;
        break;
      }
    }
  }
  return out;
}

/// Data codewords per version (1–40) and error correction level.
const Map<int, List<int>> _dataCodewords = <int, List<int>>{
  QrErrorCorrectLevel.L: <int>[
    19, 34, 55, 80, 108, 136, 156, 194, 232, 274, //
    324, 370, 428, 461, 523, 589, 647, 721, 795, 861,
    932, 1006, 1094, 1174, 1276, 1370, 1468, 1531, 1631, 1735,
    1843, 1955, 2071, 2191, 2306, 2434, 2566, 2702, 2812, 2956,
  ],
  QrErrorCorrectLevel.M: <int>[
    16, 28, 44, 64, 86, 108, 124, 154, 182, 216, //
    254, 290, 334, 365, 415, 453, 507, 563, 627, 669,
    714, 782, 860, 914, 1000, 1062, 1128, 1193, 1267, 1373,
    1455, 1541, 1631, 1725, 1812, 1914, 1992, 2102, 2216, 2334,
  ],
  QrErrorCorrectLevel.Q: <int>[
    13, 22, 34, 48, 62, 76, 88, 110, 132, 154, //
    180, 206, 244, 261, 295, 325, 367, 397, 445, 485,
    512, 568, 614, 664, 718, 754, 808, 871, 911, 985,
    1033, 1115, 1171, 1231, 1286, 1354, 1426, 1502, 1582, 1666,
  ],
  QrErrorCorrectLevel.H: <int>[
    9, 16, 26, 36, 46, 60, 66, 86, 100, 122, //
    140, 158, 180, 197, 223, 253, 283, 313, 341, 385,
    406, 442, 464, 514, 538, 596, 628, 661, 701, 745,
    793, 845, 901, 961, 986, 1054, 1096, 1142, 1222, 1276,
  ],
};
