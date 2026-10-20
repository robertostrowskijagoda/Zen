import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' show Intl;
import 'package:zen/src/core/logging/zen_log.dart';

/// A language Zen speaks.
@immutable
final class ZenLanguage {
  const ZenLanguage(this.code, this.nativeName, {this.rtl = false});

  /// ISO 639-1 code, also the name of the file in `assets/i18n/`.
  final String code;

  /// The language's own name for itself ("Deutsch", "日本語").
  final String nativeName;

  /// Written right to left.
  final bool rtl;
}

/// Polish is the source language: every string in the code is Polish and
/// the other languages are looked up by that text in
/// `assets/i18n/<code>.json` (`dart run tool/i18n.dart` keeps them in step).
const ZenLanguage kZenSourceLanguage = ZenLanguage('pl', 'Polski');

/// The language used when the system's language is not one of [kZenLanguages].
const String kZenFallbackLanguage = 'en';

/// Every language Zen speaks, Polish first, then by native name.
const List<ZenLanguage> kZenLanguages = <ZenLanguage>[
  kZenSourceLanguage,
  ZenLanguage('id', 'Bahasa Indonesia'),
  ZenLanguage('cs', 'Čeština'),
  ZenLanguage('de', 'Deutsch'),
  ZenLanguage('en', 'English'),
  ZenLanguage('es', 'Español'),
  ZenLanguage('fr', 'Français'),
  ZenLanguage('it', 'Italiano'),
  ZenLanguage('hu', 'Magyar'),
  ZenLanguage('nl', 'Nederlands'),
  ZenLanguage('pt', 'Português'),
  ZenLanguage('ro', 'Română'),
  ZenLanguage('vi', 'Tiếng Việt'),
  ZenLanguage('tr', 'Türkçe'),
  ZenLanguage('ru', 'Русский'),
  ZenLanguage('uk', 'Українська'),
  ZenLanguage('ar', 'العربية', rtl: true),
  ZenLanguage('hi', 'हिन्दी'),
  ZenLanguage('zh', '中文（简体）'),
  ZenLanguage('ja', '日本語'),
  ZenLanguage('ko', '한국어'),
];

/// The language the app speaks right now and its strings.
///
/// Until [load] runs (and in tests) Zen speaks Polish, the source language,
/// so [t] returns the text from the code unchanged.
abstract final class ZenI18n {
  static String _code = kZenSourceLanguage.code;
  static Map<String, Object?> _strings = const <String, Object?>{};

  /// Code of the current language.
  static String get code => _code;

  /// The current language.
  static ZenLanguage get language => byCode(_code) ?? kZenSourceLanguage;

  /// The language with [code], or null when Zen does not speak it.
  static ZenLanguage? byCode(String? code) {
    for (final ZenLanguage language in kZenLanguages) {
      if (language.code == code) {
        return language;
      }
    }
    return null;
  }

  /// The language to speak: [preferred] when Zen speaks it, otherwise the
  /// first of [systemLocales] Zen speaks, otherwise English.
  static String resolve(String? preferred, List<Locale> systemLocales) {
    if (byCode(preferred) != null) {
      return preferred!;
    }
    for (final Locale locale in systemLocales) {
      final String language = locale.languageCode.toLowerCase();
      // Older Java locales still call Indonesian "in".
      final String code = language == 'in' ? 'id' : language;
      if (byCode(code) != null) {
        return code;
      }
    }
    return kZenFallbackLanguage;
  }

  /// Loads the strings of [code] (Polish needs none). A missing or broken
  /// file leaves the text from the code, so the app always has something to
  /// show.
  static Future<void> load(String code, {AssetBundle? bundle}) async {
    final ZenLanguage language = byCode(code) ?? kZenSourceLanguage;
    if (language == kZenSourceLanguage) {
      _use(language.code, const <String, Object?>{});
      return;
    }
    try {
      // Not cached by the bundle: the decoded map below is what stays, the
      // text of the file (hundreds of kilobytes) is not needed again.
      final String json = await (bundle ?? rootBundle).loadString(
        'assets/i18n/${language.code}.json',
        cache: false,
      );
      final Object? decoded = jsonDecode(json);
      _use(
        language.code,
        decoded is Map<String, Object?> ? decoded : const <String, Object?>{},
      );
    } on Object catch (error) {
      logZenWarning('Cannot load the strings of ${language.code}: $error');
      _use(language.code, const <String, Object?>{});
    }
  }

  /// Uses [strings] for [code] directly (tests, tools).
  @visibleForTesting
  static void debugUse(String code, Map<String, Object?> strings) =>
      _use(code, strings);

  /// Back to the state before any [load]: Polish, the text from the code,
  /// and no default locale for `intl` (tests reset to this in tearDown).
  @visibleForTesting
  static void debugReset() {
    _code = kZenSourceLanguage.code;
    _strings = const <String, Object?>{};
    Intl.defaultLocale = null;
  }

  static void _use(String code, Map<String, Object?> strings) {
    _code = code;
    _strings = strings;
    Intl.defaultLocale = code;
  }
}

/// Translates [source], a Polish text written in the code, into the current
/// language and fills its `{name}` placeholders from [args].
///
/// [source] must be a string literal (with `{name}` placeholders instead of
/// `$name` interpolation) so `tool/i18n.dart` can find it:
///
/// ```dart
/// Text(t('Wysłano do {name}', {'name': friend.displayName}))
/// ```
String t(
  String source, [
  Map<String, Object?> args = const <String, Object?>{},
]) {
  final String text = switch (ZenI18n._strings[source]) {
    final String s when s.isNotEmpty => s,
    // Plural forms (a tn() text) used as a plain text: the general form.
    {'other': final String other} when other.isNotEmpty => other,
    _ => source,
  };
  return args.isEmpty ? text : _fill(text, args);
}

/// Translates a text that depends on the number [n], given by its three
/// Polish forms (`{n}` is [n]; [args] fill other placeholders):
///
/// ```dart
/// tn(count, one: '{n} osoba', few: '{n} osoby', many: '{n} osób')
/// ```
///
/// [one] is for 1, [few] for 2–4, 22–24, … and [many] for the rest. Other
/// languages keep their forms under the [many] text, picked by their own
/// plural rules (zero, one, two, few, many, other).
String tn(
  int n, {
  required String one,
  required String few,
  required String many,
  Map<String, Object?> args = const <String, Object?>{},
}) {
  final Map<String, Object?> all = <String, Object?>{'n': n, ...args};
  final Object? entry = ZenI18n._strings[many];
  if (entry is Map<String, Object?>) {
    String? form(String key) => switch (entry[key]) {
      final String s when s.isNotEmpty => s,
      _ => null,
    };
    final String? other = form('other');
    if (other != null) {
      final String chosen = Intl.pluralLogic<String>(
        n,
        locale: ZenI18n._code,
        zero: form('zero'),
        one: form('one'),
        two: form('two'),
        few: form('few'),
        many: form('many'),
        other: other,
      );
      return _fill(chosen, all);
    }
  }
  if (entry is String && entry.isNotEmpty) {
    return _fill(entry, all);
  }
  return _fill(polishPluralForm(n, one: one, few: few, many: many), all);
}

/// The Polish form for [n]: 1 osoba, 2 osoby, 5 osób, 22 osoby, 25 osób.
String polishPluralForm(
  int n, {
  required String one,
  required String few,
  required String many,
}) {
  if (n == 1) {
    return one;
  }
  final int mod10 = n.abs() % 10;
  final int mod100 = n.abs() % 100;
  if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
    return few;
  }
  return many;
}

final RegExp _placeholder = RegExp(r'\{([A-Za-z][A-Za-z0-9_]*)\}');

String _fill(String text, Map<String, Object?> args) {
  if (args.isEmpty || !text.contains('{')) {
    return text;
  }
  return text.replaceAllMapped(_placeholder, (Match match) {
    final String name = match.group(1)!;
    return args.containsKey(name) ? '${args[name]}' : match.group(0)!;
  });
}
