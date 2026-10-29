import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';

import 'support/font_cmap.dart';

// The title face of the app is Baloo 2. It has a glyph for every Latin
// letter of every language Zen speaks (ą, ć, ę, ń, ś, ź, ż, č, ř, ů, ő, ű,
// ș, ț, ğ, ş and the Vietnamese letters among them), so a title is never
// finished by another font, or by the phone's own, in the middle of a word.
// This checks, from the font file itself and with no fallback to lean on,
// that every such letter has a glyph in Baloo 2.
//
// There is no pl.json: Polish is the language of the code, so its texts are
// the keys of the translation files.

/// The bundled files of a family, in the order pubspec.yaml lists them.
List<String> _filesOf(String family) {
  final List<String>? files = registeredFonts()[family];
  if (files == null) {
    throw StateError('$family is not registered in pubspec.yaml');
  }
  return files;
}

/// The characters of a family: every one of its files together.
Set<int> _familyCharacters(String family) => <int>{
  for (final String path in _filesOf(family))
    ...fontCharacters(File(path).readAsBytesSync()),
};

/// The letters of a text that a Latin-script font is expected to draw:
/// Latin letters (basic, Latin-1 to Latin Extended-B, IPA-free, and the
/// Latin Extended Additional block of Vietnamese).
bool _isLatinLetter(int c) =>
    (c >= 0x41 && c <= 0x5A) ||
    (c >= 0x61 && c <= 0x7A) ||
    (c >= 0xC0 && c <= 0x24F && c != 0xD7 && c != 0xF7) ||
    (c >= 0x1E00 && c <= 0x1EFF);

void _collect(Object? node, Set<int> out) {
  if (node is String) {
    for (final int c in node.runes) {
      if (_isLatinLetter(c)) {
        out.add(c);
      }
    }
  } else if (node is Map) {
    for (final Object? v in node.values) {
      _collect(v, out);
    }
  } else if (node is List) {
    for (final Object? v in node) {
      _collect(v, out);
    }
  }
}

String _show(Iterable<int> chars) => chars
    .map((int c) => '${String.fromCharCode(c)} U+${c.toRadixString(16)}')
    .join(', ');

void main() {
  final Set<int> title = _familyCharacters(ZenTypefaces.zen.display);

  test('the title font is Baloo 2, bundled and registered', () {
    expect(ZenTypefaces.zen.display, 'Baloo 2');
    final List<String> files = _filesOf(ZenTypefaces.zen.display);
    expect(files, isNotEmpty);
    for (final String path in files) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  test('Baloo 2 draws every letter of the Polish texts on its own', () {
    final Map<String, dynamic> en =
        jsonDecode(File('assets/i18n/en.json').readAsStringSync())
            as Map<String, dynamic>;
    final Set<int> polish = <int>{};
    for (final String key in en.keys) {
      for (final int c in key.runes) {
        if (RegExp(r'\p{L}', unicode: true).hasMatch(String.fromCharCode(c))) {
          polish.add(c);
        }
      }
    }
    // The texts do use the Polish letters (not every capital, though), and
    // the whole Polish alphabet has a glyph, used or not.
    for (final int c in 'ąćęłńóśźż'.runes) {
      expect(polish, contains(c), reason: String.fromCharCode(c));
    }
    polish.addAll('ąćęłńóśźżĄĆĘŁŃÓŚŹŻ'.runes);
    final List<int> missing =
        polish.where((int c) => !title.contains(c)).toList()..sort();
    expect(missing, isEmpty, reason: 'no glyph for ${_show(missing)}');
  });

  test('Baloo 2 draws the Latin letters of every language on its own', () {
    final List<File> files =
        Directory('assets/i18n')
            .listSync()
            .whereType<File>()
            .where((File f) => f.path.endsWith('.json'))
            .toList()
          ..sort((File a, File b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty);
    for (final File file in files) {
      final Set<int> letters = <int>{};
      _collect(jsonDecode(file.readAsStringSync()), letters);
      final List<int> missing =
          letters.where((int c) => !title.contains(c)).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: '${file.uri.pathSegments.last}: no glyph for ${_show(missing)}',
      );
    }
  });

  test('no title font is left over from before Baloo 2', () {
    expect(registeredFonts().keys, isNot(contains('Fredoka')));
    expect(
      File('assets/fonts/Fredoka-Variable.ttf').existsSync(),
      isFalse,
    );
  });
}
