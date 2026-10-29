import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_fonts.dart';

// The typefaces for words on pebbles: each one registered, licensed under
// the SIL Open Font License next to its file and in the app's licences,
// credited, with every Polish letter, and stored in a design by index.

const String _polish = 'ąćęłńóśźżĄĆĘŁŃÓŚŹŻ';

/// The characters a TrueType font maps to glyphs ('cmap' formats 4 and 12).
Set<int> _characters(Uint8List font) {
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
Map<String, List<String>> _registered() {
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

void main() {
  test('10 to 14 new display faces next to the first four', () {
    final int added = PebbleFont.values.length - 4;
    expect(added, inInclusiveRange(10, 14));
    for (final PebbleFont f in PebbleFont.values) {
      expect(f.label, isNotEmpty);
    }
    expect(
      PebbleFont.values.map((PebbleFont f) => f.label).toSet(),
      hasLength(PebbleFont.values.length),
    );
  });

  test('every face is registered, licensed, credited and has the Polish '
      'letters', () {
    final Map<String, List<String>> registered = _registered();
    final String notices = File('THIRD_PARTY_NOTICES.md').readAsStringSync();
    final String inApp = File(
      'assets/licenses/fonts/OFL.txt',
    ).readAsStringSync();
    int bytes = 0;
    for (final PebbleFont f in PebbleFont.values) {
      final List<String>? files = registered[f.family];
      expect(files, isNotEmpty, reason: '${f.family} in pubspec.yaml');
      for (final String file in files!) {
        final Uint8List font = File(file).readAsBytesSync();
        final Set<int> chars = _characters(font);
        for (final int c in _polish.runes) {
          expect(
            chars,
            contains(c),
            reason: '${f.family} lacks ${String.fromCharCode(c)}',
          );
        }
        if (!file.startsWith('assets/fonts/pebbles/')) {
          continue;
        }
        bytes += font.length;
        // Its licence next to it, and its authors in the app's licences
        // and the notices.
        final String stem = file
            .split('/')
            .last
            .replaceFirst(RegExp(r'-\w+\.ttf$'), '');
        final File licence = File('assets/fonts/pebbles/$stem-OFL.txt');
        expect(licence.existsSync(), isTrue, reason: licence.path);
        final String text = licence.readAsStringSync();
        expect(text, contains('SIL OPEN FONT LICENSE Version 1.1'));
        expect(inApp, contains(text.split('\n').first.trim()));
        expect(notices, contains(f.family));
      }
    }
    // About 1.1 MB in all; none much over 150 KB.
    expect(bytes, lessThan(1300 * 1024));
  });

  test('a design stores the face by index; the first four still read', () {
    for (final PebbleFont f in PebbleFont.values) {
      final PebbleDesign d = PebbleDesign.stone(shape: 0, seed: 1).copyWith(
        ops: <PebbleOp>[
          PebbleTextOp(
            face: 0,
            s: 2048,
            t: 2048,
            size: 40,
            text: 'Zażółć',
            colour: 0xFF000000,
            font: f.index,
          ),
        ],
      );
      final PebbleDesign back = PebbleDesign.decode(d.encode());
      expect((back.ops.single as PebbleTextOp).font, f.index);
      expect(PebbleFont.byId(f.index), f);
    }
    // A face this build does not know is not taken.
    final PebbleDesign unknown = PebbleDesign.stone(shape: 0, seed: 1).copyWith(
      ops: const <PebbleOp>[
        PebbleTextOp(
          face: 0,
          s: 2048,
          t: 2048,
          size: 40,
          text: 'x',
          colour: 0xFF000000,
          font: 200,
        ),
      ],
    );
    expect(
      () => PebbleDesign.decode(unknown.encode()),
      throwsA(isA<FormatException>()),
    );
    expect(PebbleFont.byId(200), PebbleFont.rounded);
  });
}
