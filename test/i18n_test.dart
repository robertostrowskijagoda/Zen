import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

import '../tool/i18n/scanner.dart';

/// The translation layer (lib/src/app/i18n/zen_i18n.dart), and the
/// translation files in assets/i18n checked against the texts of lib/ the
/// way `dart run tool/i18n.dart` checks them.
void main() {
  // Every test starts in Polish, the source language, with nothing loaded.
  tearDown(ZenI18n.debugReset);

  group('t()', () {
    test('returns the Polish text of the code when nothing is loaded', () {
      expect(ZenI18n.code, 'pl');
      expect(t('Dzień dobry'), 'Dzień dobry');
    });

    test('fills the {placeholders} from the values', () {
      expect(
        t('Wysłano do {name} ({count})', <String, Object?>{
          'name': 'Ala',
          'count': 3,
        }),
        'Wysłano do Ala (3)',
      );
    });

    test('leaves placeholders without a value as they are', () {
      expect(
        t('{name} i {other}', <String, Object?>{'name': 'Ala'}),
        'Ala i {other}',
      );
      // Not placeholders at all.
      expect(
        t('{1} { name } {}', <String, Object?>{'name': 'Ala'}),
        '{1} { name } {}',
      );
    });

    test('uses the loaded translation', () {
      ZenI18n.debugUse('en', const <String, Object?>{
        'Dzień dobry': 'Good morning',
        'Wysłano do {name}': 'Sent to {name}',
      });
      expect(ZenI18n.code, 'en');
      expect(ZenI18n.language.nativeName, 'English');
      expect(t('Dzień dobry'), 'Good morning');
      expect(
        t('Wysłano do {name}', <String, Object?>{'name': 'Ala'}),
        'Sent to Ala',
      );
    });

    test('falls back to the Polish text when a translation is missing', () {
      ZenI18n.debugUse('en', const <String, Object?>{
        'Dzień dobry': 'Good morning',
        'Pusty': '',
      });
      expect(t('Dobranoc'), 'Dobranoc');
      expect(t('Do {name}', <String, Object?>{'name': 'Ala'}), 'Do Ala');
      // An empty translation counts as missing.
      expect(t('Pusty'), 'Pusty');
    });

    test('plural forms under a text used with t() give their "other"', () {
      ZenI18n.debugUse('en', const <String, Object?>{
        '{n} osób': <String, String>{
          'one': '{n} person',
          'other': '{n} people',
        },
      });
      expect(t('{n} osób', <String, Object?>{'n': 5}), '5 people');
    });
  });

  group('tn()', () {
    String people(int n) =>
        tn(n, one: '{n} osoba', few: '{n} osoby', many: '{n} osób');

    test('picks the Polish form when nothing is loaded', () {
      expect(people(1), '1 osoba');
      expect(people(2), '2 osoby');
      expect(people(5), '5 osób');
      expect(people(12), '12 osób');
      expect(people(22), '22 osoby');
      expect(people(25), '25 osób');
      expect(people(0), '0 osób');
      expect(polishPluralForm(104, one: 'a', few: 'b', many: 'c'), 'b');
      expect(polishPluralForm(114, one: 'a', few: 'b', many: 'c'), 'c');
    });

    test('falls back to the Polish forms when the text is not translated', () {
      ZenI18n.debugUse('en', const <String, Object?>{});
      expect(people(1), '1 osoba');
      expect(people(3), '3 osoby');
    });

    test('uses the English one and other', () {
      ZenI18n.debugUse('en', const <String, Object?>{
        '{n} osób': <String, String>{
          'one': '{n} person',
          'other': '{n} people',
        },
      });
      expect(people(1), '1 person');
      expect(people(2), '2 people');
      expect(people(5), '5 people');
      expect(people(0), '0 people');
    });

    test('uses the Russian one, few and many', () {
      ZenI18n.debugUse('ru', const <String, Object?>{
        '{n} osób': <String, String>{
          'one': '{n} человек (one)',
          'few': '{n} человека (few)',
          'many': '{n} человек (many)',
          'other': '{n} человека (other)',
        },
      });
      expect(people(1), '1 человек (one)');
      expect(people(3), '3 человека (few)');
      expect(people(5), '5 человек (many)');
      expect(people(21), '21 человек (one)');
      expect(people(11), '11 человек (many)');
    });

    test('uses all six Arabic forms', () {
      ZenI18n.debugUse('ar', const <String, Object?>{
        '{n} osób': <String, String>{
          'zero': 'zero {n}',
          'one': 'one {n}',
          'two': 'two {n}',
          'few': 'few {n}',
          'many': 'many {n}',
          'other': 'other {n}',
        },
      });
      expect(people(0), 'zero 0');
      expect(people(1), 'one 1');
      expect(people(2), 'two 2');
      expect(people(3), 'few 3');
      expect(people(11), 'many 11');
      expect(people(100), 'other 100');
    });

    test('a language with one form uses "other" for every number', () {
      ZenI18n.debugUse('ja', const <String, Object?>{
        '{n} osób': <String, String>{'other': '{n}人'},
      });
      expect(people(1), '1人');
      expect(people(5), '5人');
    });

    test('fills other placeholders next to {n}', () {
      String files(int n) => tn(
        n,
        one: '{n} plik w {folder}',
        few: '{n} pliki w {folder}',
        many: '{n} plików w {folder}',
        args: <String, Object?>{'folder': 'Dokumenty'},
      );
      expect(files(1), '1 plik w Dokumenty');
      expect(files(3), '3 pliki w Dokumenty');
      expect(files(5), '5 plików w Dokumenty');
      ZenI18n.debugUse('en', const <String, Object?>{
        '{n} plików w {folder}': <String, String>{
          'one': '{n} file in {folder}',
          'other': '{n} files in {folder}',
        },
      });
      expect(files(1), '1 file in Dokumenty');
      expect(files(7), '7 files in Dokumenty');
    });
  });

  group('ZenI18n.resolve', () {
    test("the person's choice wins", () {
      expect(
        ZenI18n.resolve('de', const <Locale>[Locale('fr'), Locale('en')]),
        'de',
      );
    });

    test('without a choice: the first system language Zen speaks', () {
      expect(
        ZenI18n.resolve(null, const <Locale>[
          Locale('sv', 'SE'),
          Locale('ja', 'JP'),
          Locale('de'),
        ]),
        'ja',
      );
      expect(
        ZenI18n.resolve(null, const <Locale>[
          Locale.fromSubtags(
            languageCode: 'zh',
            scriptCode: 'Hans',
            countryCode: 'CN',
          ),
        ]),
        'zh',
      );
      // Indonesian under its old Java name.
      expect(ZenI18n.resolve(null, const <Locale>[Locale('in', 'ID')]), 'id');
      // A choice Zen does not speak counts as none.
      expect(ZenI18n.resolve('xx', const <Locale>[Locale('uk')]), 'uk');
    });

    test('English when Zen speaks none of the system languages', () {
      expect(
        ZenI18n.resolve(null, const <Locale>[Locale('sv'), Locale('fi')]),
        'en',
      );
      expect(ZenI18n.resolve(null, const <Locale>[]), 'en');
    });

    test('byCode finds only the languages Zen speaks', () {
      expect(ZenI18n.byCode('pl'), same(kZenSourceLanguage));
      expect(ZenI18n.byCode('de')?.nativeName, 'Deutsch');
      expect(ZenI18n.byCode('ar')?.rtl, isTrue);
      expect(ZenI18n.byCode('xx'), isNull);
      expect(ZenI18n.byCode(null), isNull);
    });
  });

  test('the languages: Polish first, unique codes, Arabic right to left', () {
    expect(kZenLanguages.first, same(kZenSourceLanguage));
    final List<String> codes = <String>[
      for (final ZenLanguage language in kZenLanguages) language.code,
    ];
    expect(codes.toSet(), hasLength(codes.length));
    expect(codes, everyElement(matches(RegExp(r'^[a-z]{2}$'))));
    expect(codes, contains(kZenFallbackLanguage));
    expect(
      <String>[
        for (final ZenLanguage language in kZenLanguages)
          if (language.rtl) language.code,
      ],
      <String>['ar'],
    );
  });

  group('ZenI18n.load', () {
    test('reads assets/i18n/<code>.json', () async {
      await ZenI18n.load(
        'de',
        bundle: _MemoryBundle(const <String, String>{
          'assets/i18n/de.json': '{"Język": "Sprache"}',
        }),
      );
      expect(ZenI18n.code, 'de');
      expect(t('Język'), 'Sprache');
    });

    test('a missing file keeps the text of the code', () async {
      await ZenI18n.load('fr', bundle: _MemoryBundle(const <String, String>{}));
      expect(ZenI18n.code, 'fr');
      expect(t('Język'), 'Język');
    });

    test('Polish, and a language Zen does not speak, need no file', () async {
      ZenI18n.debugUse('de', const <String, Object?>{'Język': 'Sprache'});
      await ZenI18n.load('xx', bundle: _MemoryBundle(const <String, String>{}));
      expect(ZenI18n.code, 'pl');
      expect(t('Język'), 'Język');
    });
  });

  group('the repository', () {
    // Scanned once, when a test first needs it (`flutter test` runs in the
    // package's folder).
    late final I18nScan scan = scanI18nDirectory(
      Directory('lib'),
      root: Directory.current,
    );

    test('lib/ passes t() and tn() only plain string literals', () {
      expect(scan.fileCount, greaterThan(0));
      expect(
        scan.errors,
        isEmpty,
        reason:
            'tool/i18n.dart cannot read these calls (the text must be one '
            r'string literal with {name} placeholders, not $ interpolation '
            'or a variable):\n${_capped(scan.errors)}',
      );
      // The scanner really finds the calls (the language screen's title).
      expect(scan.entries.keys, contains('Język'));
    });

    for (final ZenLanguage language in kZenLanguages) {
      if (language.code == kZenSourceLanguage.code) {
        continue;
      }
      final String path = 'assets/i18n/${language.code}.json';
      test('$path has exactly the texts of lib/', () {
        final File file = File(path);
        expect(file.existsSync(), isTrue, reason: '$path is missing');
        final Object? decoded = jsonDecode(file.readAsStringSync());
        if (decoded is! Map<String, Object?>) {
          fail('$path is not a JSON object');
        }
        final I18nFileReport report = checkI18nTranslations(scan, decoded);
        expect(
          report.isClean,
          isTrue,
          reason:
              '$path: ${report.missing.length} missing, '
              '${report.stale.length} stale, '
              '${report.mismatched.length} not matching '
              '(`dart run tool/i18n.dart --verbose` lists them all):\n'
              '${_capped(report.toString().split('\n'))}',
        );
      });
    }

    test('assets/i18n holds only the languages Zen speaks', () {
      final Set<String> expected = <String>{
        for (final ZenLanguage language in kZenLanguages)
          if (language.code != kZenSourceLanguage.code) '${language.code}.json',
      };
      final Set<String> found = <String>{
        for (final FileSystemEntity entity in Directory(
          'assets/i18n',
        ).listSync())
          if (entity is File && entity.path.endsWith('.json'))
            entity.uri.pathSegments.last,
      };
      expect(found, unorderedEquals(expected));
    });
  });
}

/// The first [limit] of [lines], one per line, and how many more there are.
String _capped(Iterable<Object> lines, {int limit = 30}) {
  final List<String> all = <String>[for (final Object line in lines) '$line'];
  if (all.length <= limit) {
    return all.join('\n');
  }
  return <String>[
    ...all.take(limit),
    '… and ${all.length - limit} more',
  ].join('\n');
}

/// Assets from memory: [files] maps a key to the file's text.
final class _MemoryBundle extends CachingAssetBundle {
  _MemoryBundle(this.files);

  final Map<String, String> files;

  @override
  Future<ByteData> load(String key) async {
    final String? text = files[key];
    if (text == null) {
      throw StateError('No asset $key');
    }
    return ByteData.sublistView(utf8.encode(text));
  }
}
