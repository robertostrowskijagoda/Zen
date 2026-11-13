import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/i18n/label_exceptions.dart';
import '../tool/i18n/scanner.dart';

/// A translated text that quotes a control must name it the way the app shows
/// it (tool/i18n.dart checks every file in assets/i18n; these tests check the
/// check).
void main() {
  I18nScan scanOf(String source) => I18nScan()..addSource('a.dart', source);

  const String source = '''
String a() => t('Dotknij „Zapisz”.');
String b() => t('Zapisz');
String c() => t('Wybierz „Ustawienia → Zapisz”.');
String d() => t('Ustawienia');
String e() => t('Dotknij „{name}”.');
''';

  test('a text that names the label differently is refused', () {
    final I18nFileReport report =
        checkI18nTranslations(scanOf(source), <String, Object?>{
          'Dotknij „Zapisz”.': 'Tap "Store".',
          'Zapisz': 'Save',
          'Wybierz „Ustawienia → Zapisz”.': 'Choose "Settings → Save".',
          'Ustawienia': 'Settings',
          'Dotknij „{name}”.': 'Tap "{name}".',
        }, languageCode: 'en');
    expect(report.mismatched, hasLength(1));
    expect(report.mismatched.single, contains('names "Zapisz"'));
  });

  test('a path of two labels is checked step by step', () {
    final I18nFileReport report =
        checkI18nTranslations(scanOf(source), <String, Object?>{
          'Dotknij „Zapisz”.': 'Tap "Save".',
          'Zapisz': 'Save',
          'Wybierz „Ustawienia → Zapisz”.': 'Choose "Options → Save".',
          'Ustawienia': 'Settings',
          'Dotknij „{name}”.': 'Tap "{name}".',
        }, languageCode: 'en');
    expect(report.mismatched, hasLength(1));
    expect(report.mismatched.single, contains('names "Ustawienia"'));
  });

  test('case and a curly apostrophe do not matter', () {
    final I18nFileReport report = checkI18nTranslations(
      scanOf("String a() => t('Dotknij „Ja”.'); String b() => t('Ja');"),
      <String, Object?>{'Dotknij „Ja”.': 'Tap “i’m in”.', 'Ja': "I'm in"},
      languageCode: 'en',
    );
    expect(report.isClean, isTrue, reason: '$report');
  });

  test('without a language code the labels are not compared', () {
    final I18nFileReport report =
        checkI18nTranslations(scanOf(source), <String, Object?>{
          'Dotknij „Zapisz”.': 'Tap "Store".',
          'Zapisz': 'Save',
          'Wybierz „Ustawienia → Zapisz”.': 'Choose "Settings → Save".',
          'Ustawienia': 'Settings',
          'Dotknij „{name}”.': 'Tap "{name}".',
        });
    expect(report.isClean, isTrue);
  });

  test('a name that exists in one language only is kept as it is', () {
    final I18nScan scan = scanOf(
      "String a() => t('Wyszukaj „Sprawdź wiadomości Zen”.');",
    );
    I18nFileReport check(String translated) => checkI18nTranslations(
      scan,
      <String, Object?>{'Wyszukaj „Sprawdź wiadomości Zen”.': translated},
      languageCode: 'en',
    );
    expect(check('Search for “Check Zen messages”.').mismatched, hasLength(1));
    expect(check('Search for “Sprawdź wiadomości Zen”.').isClean, isTrue);
  });

  test('every exception still points at a text and a label of lib/', () {
    final I18nScan scan = scanI18nDirectory(
      Directory('lib'),
      root: Directory.current,
    );
    for (final I18nLabelException exception in kI18nLabelExceptions) {
      expect(
        scan.entries.keys.where((String key) => key.startsWith(exception.text)),
        isNotEmpty,
        reason: 'no text starts with "${exception.text}"',
      );
      expect(
        scan.entries.keys,
        contains(exception.label),
        reason: 'no label "${exception.label}"',
      );
      expect(exception.languages, isNotEmpty);
      expect(exception.reason, isNotEmpty);
    }
  });
}
