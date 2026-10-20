import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/meet/presentation/circle_screen.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// Dates, times and money in the app's language (lib/src/app/i18n/
/// zen_format.dart): Polish exactly as Zen always wrote it, the other
/// languages through `intl`.
void main() {
  // Thursday, 15 October 2026, 18:05; Monday, 5 January 2026, 09:07.
  final DateTime evening = DateTime(2026, 10, 15, 18, 5);
  final DateTime morning = DateTime(2026, 1, 5, 9, 7);

  tearDown(ZenI18n.debugReset);

  // Runs before any date data is loaded (the groups below load it).
  group('without date data', () {
    test('Polish needs none', () {
      expect(ZenFormat.time(evening), '18:05');
      expect(ZenFormat.dayMonthName(evening), '15 paź');
    });

    test('another language falls back to American English', () {
      ZenI18n.debugUse('ja', const <String, Object?>{});
      expect(ZenFormat.dayMonthName(evening), 'Oct 15');
      expect(ZenFormat.weekdayLong(evening), 'Thursday');
    });
  });

  group('Polish (the source language, nothing loaded)', () {
    test('dates and times keep their old shape', () {
      expect(ZenFormat.time(morning), '09:07');
      expect(ZenFormat.date(morning), '05.01.2026');
      expect(ZenFormat.dayMonth(morning), '05.01');
      expect(ZenFormat.dayMonth(morning, padDay: false), '5.01');
      expect(ZenFormat.dayMonthName(evening), '15 paź');
      expect(ZenFormat.monthShort(evening), 'paź');
      expect(ZenFormat.dateTime(evening), '15.10.2026 18:05');
      expect(ZenFormat.dayMonthTime(evening), '15.10 18:05');
    });

    test('weekdays: short, compact, full, capitalised', () {
      expect(ZenFormat.weekdayShort(morning), 'pon.');
      expect(ZenFormat.weekdayShort(evening, capitalized: true), 'Czw.');
      expect(ZenFormat.weekdayShortOf(3, capitalized: true), 'Śr.');
      expect(ZenFormat.weekdayShortOf(1, compact: true), 'pn');
      expect(ZenFormat.weekdayShortOf(7, compact: true), 'nd');
      expect(ZenFormat.weekdayLong(evening), 'czwartek');
      expect(
        ZenFormat.weekdayLong(DateTime(2026, 10, 17), capitalized: true),
        'Sobota',
      );
    });

    test('money: comma, non-breaking spaces, minus', () {
      expect(ZenFormat.money(123456789), '1 234 567,89');
      expect(ZenFormat.money(5), '0,05');
      expect(ZenFormat.money(-2550), '-25,50');
      expect(ZenFormat.money(123456, grouped: false), '1234,56');
      expect(formatMoney(123456789), '1 234 567,89');
      expect(formatKitty(2550), '25,50');
    });

    test('typed amounts read as before', () {
      expect(parseMoney('12,50'), 1250);
      expect(parseMoney('12.5'), 1250);
      expect(parseMoney('1 000,00'), 100000);
      expect(parseMoney(formatMoney(123456789)), 123456789);
      expect(parseMoney('-3'), isNull);
      expect(parseMoney('1,2,3'), isNull);
      expect(parseKittyCents('1,234'), isNull);
      expect(parseKittyCents(' 12,50 '), 1250);
    });
  });

  group('other languages', () {
    setUpAll(initializeDateFormatting);

    test('English: month first, 12-hour clock, dot for decimals', () {
      ZenI18n.debugUse('en', const <String, Object?>{});
      expect(ZenFormat.date(evening), '10/15/2026');
      expect(ZenFormat.dayMonth(evening), '10/15');
      expect(ZenFormat.dayMonthName(evening), 'Oct 15');
      expect(ZenFormat.monthShort(evening), 'Oct');
      expect(ZenFormat.time(evening), allOf(contains('6:05'), contains('PM')));
      expect(ZenFormat.dateTime(evening), startsWith('10/15/2026'));
      expect(ZenFormat.weekdayShort(evening), 'Thu');
      expect(ZenFormat.weekdayLong(evening), 'Thursday');
      expect(ZenFormat.money(123456789), '1,234,567.89');
      expect(ZenFormat.money(-2550), '-25.50');
      expect(parseMoney(formatMoney(123456789)), 123456789);
      expect(parseMoney('1,000'), 100000);
      expect(parseMoney('12,50'), 1250);
      expect(parseKittyCents('12.50'), 1250);
    });

    test('German: day first, dot groups thousands', () {
      ZenI18n.debugUse('de', const <String, Object?>{});
      expect(ZenFormat.date(evening), '15.10.2026');
      expect(ZenFormat.time(evening), '18:05');
      expect(ZenFormat.money(123456789), '1.234.567,89');
      expect(parseMoney(formatMoney(123456789)), 123456789);
      expect(parseMoney('12,50'), 1250);
    });

    test('Chinese: year-month-day and its own month names', () {
      ZenI18n.debugUse('zh', const <String, Object?>{});
      expect(ZenFormat.dayMonthName(evening), '10月15日');
      expect(ZenFormat.monthShort(evening), '10月');
      expect(ZenFormat.date(evening), startsWith('2026'));
      expect(ZenFormat.weekdayLong(evening), '星期四');
      expect(parseMoney(formatMoney(123456789)), 123456789);
    });

    test('Arabic: its month names; amounts read back', () {
      ZenI18n.debugUse('ar', const <String, Object?>{});
      expect(ZenFormat.dayMonthName(evening), contains('أكتوبر'));
      expect(ZenFormat.date(evening), isNot(contains('.10.')));
      expect(parseMoney(formatMoney(123456789)), 123456789);
      expect(parseMoney('١٢٫٥٠'), 1250);
    });

    test('Polish stays hand-written with the date data loaded', () {
      expect(ZenFormat.dayMonthName(evening), '15 paź');
      expect(ZenFormat.dateTime(evening), '15.10.2026 18:05');
    });

    test('ZenI18n.load sets up the date data of the language', () async {
      await ZenI18n.load('fr', bundle: _NoFiles());
      expect(ZenI18n.code, 'fr');
      expect(ZenFormat.weekdayLong(evening), 'jeudi');
    });
  });
}

/// A bundle without the translation files (the strings do not matter here).
final class _NoFiles extends CachingAssetBundle {
  @override
  Future<ByteData> load(String key) async => throw StateError('No asset $key');
}
