import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Where the documents are published (the same files the app carries).
const String kRepositoryFilesUrl =
    'https://github.com/robertostrowskijagoda/Zen/blob/main/';

/// The languages the documents are translated into (besides English, the
/// source): `docs/TERMS.<code>.md`, `docs/PRIVACY.<code>.md` and
/// `docs/NOTICE.<code>.md`. A translation is the same version as its
/// English source.
const Set<String> kLegalTranslations = <String>{'pl'};

/// The documents a person accepts before using Zen. The app carries them
/// (pubspec assets), so they are read in the app, also offline.
enum LegalDocument {
  terms('docs/TERMS.md', 'docs/TERMS'),
  privacy('docs/PRIVACY.md', 'docs/PRIVACY'),
  licence('NOTICE', 'docs/NOTICE');

  const LegalDocument(this.path, this._translationStem);

  /// The path in the repository of the English source, also the asset's
  /// key.
  final String path;

  final String _translationStem;

  /// The path of the translation into [code], or `null` when there is none.
  String? translationPath(String code) =>
      kLegalTranslations.contains(code) ? '$_translationStem.$code.md' : null;

  /// The path of what is shown in [code]: the translation, else English.
  String pathFor(String code) => translationPath(code) ?? path;

  String get title => switch (this) {
    LegalDocument.terms => t('Regulamin'),
    LegalDocument.privacy => t('Polityka prywatności'),
    LegalDocument.licence => t('Licencja'),
  };

  String get subtitle => switch (this) {
    LegalDocument.terms => t('Zasady korzystania z Zen'),
    LegalDocument.privacy => t('Co dzieje się z Twoimi danymi'),
    LegalDocument.licence => t('GPL-3.0 z dodatkowymi warunkami (NOTICE)'),
  };

  /// The same document on GitHub (the English source).
  String get url => '$kRepositoryFilesUrl$path';

  /// The document on GitHub in [code] (its translation, else English).
  String urlFor(String code) => '$kRepositoryFilesUrl${pathFor(code)}';

  /// The document a link in one of them points at, by its repository path
  /// (the source or a translation); `null` for anything else.
  static LegalDocument? ofPath(String path) {
    for (final LegalDocument d in values) {
      if (d.path == path ||
          kLegalTranslations.any((String c) => d.translationPath(c) == path)) {
        return d;
      }
    }
    return null;
  }
}

/// What a link in the document [from] leads to: another of the documents
/// ([LegalLinkTarget.document]) or a web address ([LegalLinkTarget.url]).
/// Relative links ("PRIVACY.md", "../NOTICE") are read the way GitHub reads
/// them, from the document's place in the repository. Returns `null` for a
/// link that is neither (a `mailto:`, a page anchor).
LegalLinkTarget? resolveLegalLink(LegalDocument from, String href) {
  final String link = href.trim();
  if (link.isEmpty || link.startsWith('#')) {
    return null;
  }
  final Uri? uri = Uri.tryParse(link);
  if (uri == null) {
    return null;
  }
  if (uri.hasScheme) {
    return uri.scheme == 'https' || uri.scheme == 'http'
        ? LegalLinkTarget.url(link)
        : null;
  }
  final Uri resolved = Uri.parse(
    '$kRepositoryFilesUrl${from.path}',
  ).resolveUri(uri.removeFragment());
  final String base = Uri.parse(kRepositoryFilesUrl).path;
  if (resolved.path.startsWith(base)) {
    final LegalDocument? doc = LegalDocument.ofPath(
      resolved.path.substring(base.length),
    );
    if (doc != null) {
      return LegalLinkTarget.document(doc);
    }
  }
  return LegalLinkTarget.url(resolved.toString());
}

/// See [resolveLegalLink].
@immutable
final class LegalLinkTarget {
  const LegalLinkTarget.document(LegalDocument this.document) : url = null;

  const LegalLinkTarget.url(String this.url) : document = null;

  final LegalDocument? document;
  final String? url;

  @override
  bool operator ==(Object other) =>
      other is LegalLinkTarget &&
      other.document == document &&
      other.url == url;

  @override
  int get hashCode => Object.hash(document, url);

  @override
  String toString() => document?.name ?? url ?? '';
}

/// The texts of the documents, as the app carries them: the English
/// sources ([texts], which set the version) and their translations.
@immutable
final class LegalTexts {
  const LegalTexts(
    this.texts, [
    this.translations = const <String, Map<LegalDocument, String>>{},
  ]);

  final Map<LegalDocument, String> texts;

  /// By language code, the translated documents.
  final Map<String, Map<LegalDocument, String>> translations;

  /// The English source of [doc].
  String of(LegalDocument doc) => texts[doc] ?? '';

  /// Whether [doc] is translated into [code].
  bool isTranslated(LegalDocument doc, String code) =>
      (translations[code]?[doc] ?? '').isNotEmpty;

  /// [doc] in the language [code] when it is translated, else English.
  String inLanguage(LegalDocument doc, String code) =>
      isTranslated(doc, code) ? translations[code]![doc]! : of(doc);

  /// The version the person accepts: see [legalDocumentsVersion].
  String get version => legalDocumentsVersion(texts);
}

/// The version of the set of documents: for each the date of its "last
/// updated" line (the terms and the policy), otherwise a short digest of its
/// text (the licence notice). A new date or a changed notice is a new
/// version, which is asked for again.
String legalDocumentsVersion(Map<LegalDocument, String> texts) {
  final RegExp updated = RegExp(
    r'last updated ([^.*\n]+)',
    caseSensitive: false,
  );
  String versionOf(LegalDocument doc) {
    final String text = texts[doc] ?? '';
    final RegExpMatch? date = updated.firstMatch(text);
    if (date != null) {
      return date.group(1)!.trim();
    }
    return sha256.convert(utf8.encode(text)).toString().substring(0, 12);
  }

  return <String>[
    for (final LegalDocument doc in LegalDocument.values)
      '${doc.name}:${versionOf(doc)}',
  ].join(';');
}

/// Recorded when the documents could not be read from the app (a broken
/// install): the person accepted the versions published online.
const String kLegalVersionUnavailable = 'unavailable';

/// The documents from the app's assets, with their translations (a
/// missing translation is simply not there: the English one is shown).
final FutureProvider<LegalTexts> legalTextsProvider =
    FutureProvider<LegalTexts>((Ref ref) async {
      final Map<String, Map<LegalDocument, String>> translations =
          <String, Map<LegalDocument, String>>{};
      for (final String code in kLegalTranslations) {
        for (final LegalDocument doc in LegalDocument.values) {
          try {
            final String text = await rootBundle.loadString(
              doc.translationPath(code)!,
            );
            (translations[code] ??= <LegalDocument, String>{})[doc] = text;
          } on Object {
            // Not carried: English is shown.
          }
        }
      }
      return LegalTexts(<LegalDocument, String>{
        for (final LegalDocument doc in LegalDocument.values)
          doc: await rootBundle.loadString(doc.path),
      }, translations);
    });

/// The version to accept now: the documents' own, [kLegalVersionUnavailable]
/// when they cannot be read, `null` while they are being read.
String? legalVersionNow(AsyncValue<LegalTexts> texts) => switch (texts) {
  AsyncData<LegalTexts>(:final LegalTexts value) => value.version,
  AsyncError<LegalTexts>() => kLegalVersionUnavailable,
  _ => null,
};

/// Whether the first start asks to accept the documents. Off in tests and
/// previews; the real app turns it on (like the app password).
final Provider<bool> legalConsentRequiredProvider = Provider<bool>(
  (Ref ref) => false,
);

/// Whether the documents still have to be accepted: never accepted, or
/// accepted in another version than the app carries now (also while the
/// documents are being read, so nothing starts before the answer).
final Provider<bool> legalConsentPendingProvider = Provider<bool>((Ref ref) {
  if (!ref.watch(legalConsentRequiredProvider)) {
    return false;
  }
  final String accepted = ref.watch(
    appSettingsControllerProvider.select(
      (AppSettings s) => s.legalAcceptedVersion,
    ),
  );
  final String? now = legalVersionNow(ref.watch(legalTextsProvider));
  return now == null || now != accepted;
});
