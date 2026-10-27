import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';

/// The release file with the short note about what is new in a version
/// (docs/RELEASES.md, "What's new"): made by `tool/release.dart whats-new`
/// from the "### What's new" part of CHANGELOG.md and listed in
/// `SHA256SUMS`, so `SHA256SUMS.sig` signs it with everything else.
const String kWhatsNewAssetName = 'whats-new.json';

/// Most lines of the note in one language.
const int kMaxWhatsNewLines = 3;

/// Most characters of one line.
const int kMaxWhatsNewLineLength = 160;

/// The most the file may be (well under a kilobyte in reality).
const int kMaxWhatsNewBytes = 16 * 1024;

/// The language whose lines are shown when the note has none in the app's
/// language (every note has them).
const String kWhatsNewFallbackLanguage = 'en';

/// A language code of the note: two lower-case letters, as Zen's own.
final RegExp _languageCode = RegExp(r'^[a-z]{2}$');

/// What a line of the note must not hold: control characters, links and
/// the marks of Markdown or HTML (it is shown as plain text).
final RegExp _notPlain = RegExp(
  r'[\u0000-\u001f\u007f*`<>\[\]]|://|www\.|https?:',
  caseSensitive: false,
);

/// Whether [line] may be shown as a line of the note: plain text of 1 to
/// [kMaxWhatsNewLineLength] characters, no links and no markup.
bool isPlainWhatsNewLine(String line) =>
    line.trim() == line &&
    line.isNotEmpty &&
    line.length <= kMaxWhatsNewLineLength &&
    !_notPlain.hasMatch(line);

/// The short note about what is new in a release: up to
/// [kMaxWhatsNewLines] plain lines per language, always in English.
///
/// `{"t": "zen_whats_new", "app": "zen", "version": "1.13.0",
/// "lines": {"en": ["…"], "pl": ["…"]}}`.
@immutable
final class WhatsNew {
  const WhatsNew({required this.version, required this.lines});

  final String version;

  /// Language code → its lines, in order.
  final Map<String, List<String>> lines;

  /// The lines in [language], else in English.
  List<String> linesFor(String language) =>
      lines[language] ?? lines[kWhatsNewFallbackLanguage] ?? const <String>[];

  /// Reads the note; null for anything that is not exactly one (a line
  /// that is not plain, too many lines, no English).
  static WhatsNew? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'zen_whats_new' ||
        json['app'] != kReleaseApp) {
      return null;
    }
    final Object? version = json['version'];
    final Object? lines = json['lines'];
    if (version is! String ||
        !isValidAppVersion(version) ||
        lines is! Map ||
        lines.isEmpty ||
        lines.length > 30) {
      return null;
    }
    final Map<String, List<String>> parsed = <String, List<String>>{};
    for (final MapEntry<Object?, Object?> e in lines.entries) {
      final Object? language = e.key;
      final Object? list = e.value;
      if (language is! String ||
          !_languageCode.hasMatch(language) ||
          list is! List ||
          list.isEmpty ||
          list.length > kMaxWhatsNewLines ||
          !list.every((Object? l) => l is String && isPlainWhatsNewLine(l))) {
        return null;
      }
      parsed[language] = List<String>.unmodifiable(list.cast<String>());
    }
    if (!parsed.containsKey(kWhatsNewFallbackLanguage)) {
      return null;
    }
    return WhatsNew(
      version: version,
      lines: Map<String, List<String>>.unmodifiable(parsed),
    );
  }

  /// Reads the text of a [kWhatsNewAssetName] file; null when it is not
  /// one.
  static WhatsNew? decode(String text) {
    if (text.length > kMaxWhatsNewBytes) {
      return null;
    }
    try {
      return fromJson(jsonDecode(text));
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    't': 'zen_whats_new',
    'app': kReleaseApp,
    'version': version,
    'lines': lines,
  };
}

/// The note of [release] from its [kWhatsNewAssetName], fetched with
/// [fetchText] (as `SHA256SUMS`, from github.com, not the API, so it costs
/// nothing of GitHub's rate limit), or null when the release has none.
///
/// Taken only when it is this very version's note and the release vouches
/// for it like for an installer: signed by one of [maintainers] in
/// `SHA256SUMS.sig` (while [maintainers] is empty: listed in the release's
/// `SHA256SUMS`). A note that does not hold up is left out (and logged by
/// the caller): it never stops the notice about the version itself.
Future<WhatsNew?> fetchWhatsNew(
  GithubRelease release, {
  required Sha256SumsFetcher fetchText,
  List<String> maintainers = kReleaseMaintainers,
}) async {
  if (!release.assets.containsKey(kWhatsNewAssetName)) {
    return null;
  }
  final String text = await fetchText(release.assetUri(kWhatsNewAssetName));
  final WhatsNew? note = WhatsNew.decode(text);
  if (note == null || note.version != release.version) {
    throw const FormatException('whats-new.json is not this release\'s note');
  }
  final String hex = sha256Hex(utf8.encode(text));
  final bool vouched;
  if (maintainers.isEmpty) {
    vouched = sha256SumsConfirm(
      sumsText: await fetchText(sha256SumsUri(release.version)),
      name: kWhatsNewAssetName,
      sha256Hex: hex,
    );
  } else {
    final SignedSums? signed = SignedSums.decode(
      await fetchText(release.assetUri(kSignedSumsAssetName)),
    );
    vouched =
        signed != null &&
        await signed.confirms(
          version: release.version,
          name: kWhatsNewAssetName,
          sha256Hex: hex,
          maintainers: maintainers,
        );
  }
  if (!vouched) {
    throw const FormatException(
      'whats-new.json is not signed with the release',
    );
  }
  return note;
}
