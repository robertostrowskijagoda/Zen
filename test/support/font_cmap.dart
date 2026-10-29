import 'dart:io';
import 'dart:typed_data';

/// The characters a TrueType font maps to glyphs ('cmap' formats 4 and 12).
Set<int> fontCharacters(Uint8List font) {
  final ByteData d = ByteData.sublistView(font);
  final int tables = d.getUint16(4);
  int? cmap;
  for (int i = 0; i < tables; i++) {
    final int at = 12 + 16 * i;
    if (String.fromCharCodes(font.sublist(at, at + 4)) == 'cmap') {
      cmap = d.getUint32(at + 8);
    }
  }
  final Set<int> out = <int>{};
  if (cmap == null) {
    return out;
  }
  final int count = d.getUint16(cmap + 2);
  for (int i = 0; i < count; i++) {
    final int s = cmap + d.getUint32(cmap + 4 + 8 * i + 4);
    final int format = d.getUint16(s);
    if (format == 4) {
      final int segments = d.getUint16(s + 6) ~/ 2;
      for (int g = 0; g < segments; g++) {
        final int end = d.getUint16(s + 14 + 2 * g);
        final int start = d.getUint16(s + 16 + 2 * segments + 2 * g);
        for (int c = start; c <= end && c != 0xFFFF; c++) {
          out.add(c);
        }
      }
    } else if (format == 12) {
      final int groups = d.getUint32(s + 12);
      for (int g = 0; g < groups; g++) {
        final int start = d.getUint32(s + 16 + 12 * g);
        final int end = d.getUint32(s + 20 + 12 * g);
        for (int c = start; c <= end; c++) {
          out.add(c);
        }
      }
    }
  }
  return out;
}

/// Every family pubspec.yaml registers, with its asset files.
Map<String, List<String>> registeredFonts() {
  final Map<String, List<String>> out = <String, List<String>>{};
  String? family;
  for (final String line in File('pubspec.yaml').readAsLinesSync()) {
    final RegExpMatch? f = RegExp(r'^\s+- family: (.+)$').firstMatch(line);
    if (f != null) {
      family = f[1]!.trim();
      out[family] = <String>[];
      continue;
    }
    final RegExpMatch? a = RegExp(r'^\s+- asset: (.+\.ttf)$').firstMatch(line);
    if (a != null && family != null) {
      out[family]!.add(a[1]!.trim());
    }
  }
  return out;
}
