import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/design/pebble_fonts.dart';

import 'support/font_cmap.dart';

// The typefaces for words on pebbles: each one registered, licensed under
// the SIL Open Font License next to its file and in the app's licences,
// credited, with every Polish letter, and stored in a design by index.

const String _polish = 'ąćęłńóśźżĄĆĘŁŃÓŚŹŻ';

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
    final Map<String, List<String>> registered = registeredFonts();
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
        final Set<int> chars = fontCharacters(font);
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
