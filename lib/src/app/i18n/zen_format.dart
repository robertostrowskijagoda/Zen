import 'package:intl/intl.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// Dates, times, numbers and money in the language the app speaks
/// ([ZenI18n.code]).
///
/// Polish, the source language, is written by hand exactly as Zen always
/// wrote it ("15.10.2026", "18:05", "1 234,50"), so it needs no locale data
/// and reads the same in tests. The other languages use `package:intl`
/// with their own order, names and separators ("Oct 15", "10月15日",
/// "6:05 PM"). Their date names come from the data [ZenI18n.load] sets up
/// (`initializeDateFormatting`); until it is there (tests, a failed load)
/// the American English forms stand in, which `intl` always has.
abstract final class ZenFormat {
  static const List<String> _plMonthsShort = <String>[
    'sty',
    'lut',
    'mar',
    'kwi',
    'maj',
    'cze',
    'lip',
    'sie',
    'wrz',
    'paź',
    'lis',
    'gru',
  ];

  static const List<String> _plWeekdaysShort = <String>[
    'pon.',
    'wt.',
    'śr.',
    'czw.',
    'pt.',
    'sob.',
    'niedz.',
  ];

  static const List<String> _plWeekdaysCompact = <String>[
    'pn',
    'wt',
    'śr',
    'cz',
    'pt',
    'sb',
    'nd',
  ];

  static const List<String> _plWeekdaysLong = <String>[
    'poniedziałek',
    'wtorek',
    'środa',
    'czwartek',
    'piątek',
    'sobota',
    'niedziela',
  ];

  /// The `intl` locale American English stands in with: its date data is
  /// built into `intl`, so it never needs initialising.
  static const String _fallbackLocale = 'en_US';

  static final Map<String, DateFormat> _dateFormats = <String, DateFormat>{};

  static bool get _polish => ZenI18n.code == kZenSourceLanguage.code;

  static String _two(int v) => v.toString().padLeft(2, '0');

  /// The locale to format dates with: the app's language when `intl` has
  /// its date data, else [_fallbackLocale].
  static String _dateLocale() {
    final String code = ZenI18n.code;
    try {
      if (DateFormat.localeExists(code)) {
        return code;
      }
    } on Object {
      // Not initialised: intl throws instead of answering.
    }
    return _fallbackLocale;
  }

  /// [d] through the `intl` format [make] builds for a locale (cached per
  /// [key] and locale).
  static String _intl(
    String key,
    DateFormat Function(String locale) make,
    DateTime d,
  ) {
    final String locale = _dateLocale();
    try {
      final DateFormat format = _dateFormats.putIfAbsent(
        '$key|$locale',
        () => make(locale),
      );
      return format.format(d);
    } on Object {
      return make(_fallbackLocale).format(d);
    }
  }

  /// "18:05" (Polish); "6:05 PM", "18:05", "下午6:05" in other languages.
  static String time(DateTime d) => _polish
      ? '${_two(d.hour)}:${_two(d.minute)}'
      : _intl('jm', DateFormat.jm, d);

  /// "15.10.2026" (Polish); "10/15/2026", "15.10.2026", "2026/10/15".
  static String date(DateTime d) => _polish
      ? '${_two(d.day)}.${_two(d.month)}.${d.year}'
      : _intl('yMd', DateFormat.yMd, d);

  /// The day and the month in numbers: "15.10" (Polish, "5.10" without
  /// [padDay]); "10/15", "15.10.", "10/15" in other languages.
  static String dayMonth(DateTime d, {bool padDay = true}) => _polish
      ? '${padDay ? _two(d.day) : d.day}.${_two(d.month)}'
      : _intl('Md', DateFormat.Md, d);

  /// The day and the short name of the month: "15 paź" (Polish); "Oct 15",
  /// "10月15日" in other languages.
  static String dayMonthName(DateTime d) => _polish
      ? '${d.day} ${_plMonthsShort[d.month - 1]}'
      : _intl('MMMd', DateFormat.MMMd, d);

  /// The short name of the month on its own (a calendar tile): "paź",
  /// "Oct", "10月".
  static String monthShort(DateTime d) =>
      _polish ? _plMonthsShort[d.month - 1] : _intl('LLL', DateFormat.LLL, d);

  /// "15.10.2026 18:05" (Polish); "10/15/2026 6:05 PM" in English.
  static String dateTime(DateTime d) => _polish
      ? '${date(d)} ${time(d)}'
      : _intl('yMd jm', (String l) => DateFormat.yMd(l).add_jm(), d);

  /// "15.10 18:05" (Polish); "10/15 6:05 PM" in English.
  static String dayMonthTime(DateTime d) => _polish
      ? '${dayMonth(d)} ${time(d)}'
      : _intl('Md jm', (String l) => DateFormat.Md(l).add_jm(), d);

  /// The short name of the weekday of [d]: "pon." (Polish, "pn" when
  /// [compact]); "Mon", "周一" in other languages. [capitalized] starts it
  /// with a capital letter (the start of a label).
  static String weekdayShort(
    DateTime d, {
    bool compact = false,
    bool capitalized = false,
  }) {
    final String name = _polish
        ? (compact ? _plWeekdaysCompact : _plWeekdaysShort)[d.weekday - 1]
        : _intl('ccc', (String l) => DateFormat('ccc', l), d);
    return capitalized ? _capitalize(name) : name;
  }

  /// The short name of [weekday] (1 = Monday … 7 = Sunday, as
  /// [DateTime.weekday]), see [weekdayShort].
  static String weekdayShortOf(
    int weekday, {
    bool compact = false,
    bool capitalized = false,
  }) => weekdayShort(
    _dayOfWeek(weekday),
    compact: compact,
    capitalized: capitalized,
  );

  /// The full name of the weekday of [d]: "sobota" (Polish), "Saturday",
  /// "星期六"; [capitalized] starts it with a capital letter.
  static String weekdayLong(DateTime d, {bool capitalized = false}) {
    final String name = _polish
        ? _plWeekdaysLong[d.weekday - 1]
        : _intl('cccc', (String l) => DateFormat('cccc', l), d);
    return capitalized ? _capitalize(name) : name;
  }

  /// A day that is [weekday] (1 = Monday): 5–11 January 2026 is a Monday to
  /// a Sunday.
  static DateTime _dayOfWeek(int weekday) =>
      DateTime(2026, 1, 4 + weekday.clamp(1, 7));

  static String _capitalize(String s) {
    if (s.isEmpty) {
      return s;
    }
    final String first = String.fromCharCode(s.runes.first);
    final String rest = s.substring(first.length);
    final bool dottedI = ZenI18n.code == 'tr' || ZenI18n.code == 'az';
    return '${dottedI && first == 'i' ? 'İ' : first.toUpperCase()}$rest';
  }

  /// [value] with the digits grouped the way the language groups them:
  /// "1 234" (Polish), "1,234" (English); [decimals] digits after the
  /// separator when given.
  static String number(num value, {int? decimals}) {
    try {
      final NumberFormat format = NumberFormat.decimalPattern(ZenI18n.code);
      if (decimals != null) {
        format
          ..minimumFractionDigits = decimals
          ..maximumFractionDigits = decimals;
      }
      return format.format(value);
    } on Object {
      return decimals == null
          ? value.toString()
          : value.toStringAsFixed(decimals);
    }
  }

  /// An amount in hundredths for people: 123450 → "1 234,50" (Polish,
  /// thousands grouped with a non-breaking space, or "1234,50" without
  /// [grouped]); "1,234.50" in English, "1.234,50" in German. Exact for any
  /// 64-bit amount (no floating point on the way).
  static String money(int hundredths, {bool grouped = true}) {
    final bool neg = hundredths < 0;
    final int v = hundredths.abs();
    final int whole = v ~/ 100;
    final String cents = _two(v % 100);
    if (_polish) {
      final String w = grouped
          ? whole.toString().replaceAllMapped(
              RegExp(r'\B(?=(\d{3})+(?!\d))'),
              (Match m) => '\u00a0',
            )
          : whole.toString();
      final String s = '$w,$cents';
      return neg ? '-$s' : s;
    }
    try {
      final NumberFormat format = NumberFormat.decimalPattern(ZenI18n.code);
      final String zero = format.symbols.ZERO_DIGIT;
      final String w = grouped
          ? format.format(whole)
          : _nativeDigits(whole.toString(), zero);
      final String s =
          '$w${format.symbols.DECIMAL_SEP}${_nativeDigits(cents, zero)}';
      return neg ? '${format.symbols.MINUS_SIGN}$s' : s;
    } on Object {
      final String s = '$whole.$cents';
      return neg ? '-$s' : s;
    }
  }

  static String _nativeDigits(String ascii, String zero) {
    if (zero.length != 1 || zero == '0') {
      return ascii;
    }
    final int zeroUnit = zero.codeUnitAt(0);
    return String.fromCharCodes(<int>[
      for (final int unit in ascii.codeUnits)
        unit >= 0x30 && unit <= 0x39 ? zeroUnit + unit - 0x30 : unit,
    ]);
  }

  /// A decimal number as a person typed it, made plain for parsing: ASCII
  /// digits, an optional leading "-", "." before the fraction and nothing
  /// between the digits. Reads back what [money] and [number] write in
  /// any language ("1 234,50", "1,234.50", "1.234,50", "١٢٣٫٤٥").
  ///
  /// Spaces and direction marks are dropped. When both "," and "." occur,
  /// the last one is the decimal separator and the other groups thousands.
  /// When only one of them occurs and it is the language's group separator
  /// (not Polish: there it is a space), it groups thousands if it occurs
  /// more than once or is followed by exactly three digits; otherwise it is
  /// the decimal separator (so "12.5" and "12,50" read in every language).
  /// Anything else is left as it is for the caller to reject.
  static String normalizeDecimal(String text) {
    final StringBuffer plain = StringBuffer();
    for (final int rune in text.runes) {
      if (rune >= 0x0660 && rune <= 0x0669) {
        plain.writeCharCode(0x30 + rune - 0x0660); // Arabic-Indic digits
      } else if (rune >= 0x06F0 && rune <= 0x06F9) {
        plain.writeCharCode(0x30 + rune - 0x06F0); // Persian digits
      } else if (rune == 0x066B) {
        plain.write(','); // Arabic decimal separator
      } else if (rune == 0x066C || rune == 0x2019 || rune == 0x27) {
        // Arabic thousands separator, apostrophes (Swiss style): grouping.
      } else if (rune == 0x2212) {
        plain.write('-'); // the minus sign
      } else if (rune == 0x200E || rune == 0x200F || rune == 0x061C) {
        // Direction marks around signs (Arabic, Hebrew).
      } else if (String.fromCharCode(rune).trim().isEmpty) {
        // Spaces of any kind (non-breaking, narrow) group thousands.
      } else {
        plain.writeCharCode(rune);
      }
    }
    final String s = plain.toString();
    final int lastComma = s.lastIndexOf(',');
    final int lastDot = s.lastIndexOf('.');
    if (lastComma >= 0 && lastDot >= 0) {
      final String decimal = lastComma > lastDot ? ',' : '.';
      final String group = decimal == ',' ? '.' : ',';
      return s.replaceAll(group, '').replaceAll(decimal, '.');
    }
    if (lastComma < 0 && lastDot < 0) {
      return s;
    }
    final String sep = lastComma >= 0 ? ',' : '.';
    final int last = lastComma >= 0 ? lastComma : lastDot;
    if (!_polish && sep == _groupSeparator()) {
      final int count = sep.allMatches(s).length;
      final int digitsAfter = s.length - last - 1;
      if (count > 1 || digitsAfter == 3) {
        return s.replaceAll(sep, '');
      }
    }
    return s.replaceAll(sep, '.');
  }

  static String _groupSeparator() {
    try {
      return NumberFormat.decimalPattern(ZenI18n.code).symbols.GROUP_SEP;
    } on Object {
      return ',';
    }
  }

  /// Forgets the cached formats (tests switch languages and locale data).
  static void debugReset() => _dateFormats.clear();
}
