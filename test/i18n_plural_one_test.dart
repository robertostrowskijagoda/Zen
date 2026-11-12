import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

import '../tool/i18n/scanner.dart';

/// In Russian and Ukrainian the plural category "one" is also used for 21, 31,
/// 101 …, in French, Portuguese and Hindi for 0 as well. A "one" form that
/// leaves the number out then reads "A verdict" under 21 verdicts and
/// "once" after 0 times. These tests render the real texts of lib/ with the
/// real translation files for such numbers.
void main() {
  tearDown(ZenI18n.debugReset);

  group('the numbers that reach the "one" form', () {
    // Guards the table the translation check relies on.
    for (final MapEntry<String, List<int>> language
        in kI18nWideOneForms.entries) {
      test('${language.key} sends ${language.value} to "one"', () {
        ZenI18n.debugUse(language.key, <String, Object?>{
          'many': <String, Object?>{
            'one': 'ONE',
            'few': 'FEW',
            'many': 'MANY',
            'other': 'OTHER',
          },
        });
        for (final int n in language.value) {
          expect(
            tn(n, one: 'one', few: 'few', many: 'many'),
            'ONE',
            reason: '${language.key}: $n',
          );
        }
      });
    }
  });

  group('every plural text of lib/ with a number', () {
    late final I18nScan scan = scanI18nDirectory(
      Directory('lib'),
      root: Directory.current,
    );

    for (final MapEntry<String, List<int>> language
        in kI18nWideOneForms.entries) {
      test('${language.key} shows the number under ${language.value}', () {
        final Map<String, Object?> strings =
            jsonDecode(
                  File('assets/i18n/${language.key}.json').readAsStringSync(),
                )
                as Map<String, Object?>;
        ZenI18n.debugUse(language.key, strings);
        final List<String> bare = <String>[];
        for (final I18nEntry entry in scan.entries.values) {
          final I18nPlural? plural = entry.plural;
          if (plural == null || !i18nPlaceholders(plural.many).contains('n')) {
            continue;
          }
          final Map<String, Object?> args = <String, Object?>{
            for (final String name in plural.placeholders)
              if (name != 'n') name: 'X',
          };
          for (final int n in language.value) {
            if (n == 0 && kI18nNeverZero.contains(entry.key)) {
              continue;
            }
            final String shown = tn(
              n,
              one: plural.one,
              few: plural.few,
              many: plural.many,
              args: args,
            );
            if (!shown.contains('$n')) {
              bare.add('$n => "$shown"');
            }
          }
        }
        expect(bare, isEmpty);
      });
    }

    test('the examples of the report read right', () {
      Map<String, Object?> load(String code) =>
          jsonDecode(File('assets/i18n/$code.json').readAsStringSync())
              as Map<String, Object?>;
      ZenI18n.debugUse('ru', load('ru'));
      expect(
        tn(
          21,
          one: 'Wyrok sądu piramidy',
          few: '{n} wyroki sądu piramidy',
          many: '{n} wyroków sądu piramidy',
        ),
        contains('21'),
      );
      ZenI18n.debugUse('uk', load('uk'));
      expect(
        tn(
          31,
          one: 'Wspólne wydarzenie: {names}',
          few: 'Wspólne wydarzenia ({n}): {names}',
          many: 'Wspólne wydarzenia ({n}): {names}',
          args: <String, Object?>{'names': 'X'},
        ),
        contains('31'),
      );
      ZenI18n.debugUse('fr', load('fr'));
      expect(
        tn(0, one: '{n} raz', few: '{n} razy', many: '{n} razy'),
        '0 fois',
      );
    });
  });
}
