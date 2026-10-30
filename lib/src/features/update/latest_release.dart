import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/update/github_release.dart';

/// Where an answer about the newest release came from.
enum LatestReleaseSource {
  /// The project's `release.json` on GitHub Pages ([kZenReleaseInfoUri]).
  pages,

  /// GitHub's API ([kGithubLatestReleaseUri]).
  api,

  /// GitHub's redirect from the newest release's page
  /// ([kGithubLatestReleasePageUri]): the version alone.
  redirect,
}

/// What a look for the newest release found: [release] (null: none is
/// published, or the answer named none that this build understands) and
/// where it came from.
@immutable
final class LatestReleaseAnswer {
  const LatestReleaseAnswer(this.release, this.source);

  final GithubRelease? release;
  final LatestReleaseSource source;
}

/// The tag GitHub's redirect from [uri] leads to ([fetchLatestReleaseTag]);
/// swapped out in tests.
typedef GithubTagFetcher = Future<String?> Function(Uri uri);

/// Looks up the newest published release, from the repository first:
///
/// 1. GitHub's redirect from the newest release's page
///    ([kGithubLatestReleasePageUri], [fetchTag]): no request limit, the
///    newest version the moment it is published;
/// 2. GitHub's API ([kGithubLatestReleaseUri]) through [fetchJson] (with
///    `If-None-Match`), for the release's files and sizes: 60 requests an
///    hour per IP address, which a mobile operator's shared address often
///    has used up (403 or 429);
/// 3. only when the API refused: the project's `release.json` on GitHub
///    Pages ([kZenReleaseInfoUri]), if it already names that version (the
///    pages are rebuilt minutes after a release);
/// 4. otherwise the redirect's version alone ([GithubRelease.detailed]
///    false).
///
/// None of them is trusted for more than which version is the newest: what
/// is installed is still checked against the release's `SHA256SUMS` (and
/// its signature, and on Android the signing certificate), downloaded from
/// github.com for that very tag. When nothing answers, the API's error is
/// thrown, so the caller can tell a rate limit, an error answer, "no
/// release" (404) and "not reached" apart. [fetchTag] null: no redirect.
final class LatestReleaseFinder {
  LatestReleaseFinder({required GithubJsonFetcher fetchJson, this.fetchTag})
    : _fetchJson = fetchJson;

  /// The finder of the app and the Android background service: every step
  /// over the network, the JSON answers remembered with their `ETag`.
  factory LatestReleaseFinder.standard() => LatestReleaseFinder(
    fetchJson: GithubJsonCache().call,
    fetchTag: fetchLatestReleaseTag,
  );

  final GithubJsonFetcher _fetchJson;
  final GithubTagFetcher? fetchTag;

  Future<LatestReleaseAnswer> call() async {
    // Which version is the newest comes from the repository itself, at
    // once: GitHub's redirect from the newest release's page has no
    // request limit and knows a release the moment it is published (the
    // pages are rebuilt after it, minutes later).
    String? tag;
    final GithubTagFetcher? tagOf = fetchTag;
    if (tagOf != null) {
      try {
        tag = await tagOf(kGithubLatestReleasePageUri);
      } on Object catch (error) {
        logZenWarning('Update check: release page not read: $error');
      }
    }
    final GithubRelease? tagged = tag == null
        ? null
        : GithubRelease.fromTag(tag);
    // The release's files and sizes: GitHub's API (an unchanged answer is
    // not counted against its limit, `If-None-Match`).
    Object? apiError;
    StackTrace? apiStack;
    try {
      final GithubRelease? release = GithubRelease.fromJson(
        await _fetchJson(kGithubLatestReleaseUri),
      );
      if (tagged == null || release?.version == tagged.version) {
        return LatestReleaseAnswer(release, LatestReleaseSource.api);
      }
    } on GithubStatusException catch (error, stack) {
      if (error.statusCode == HttpStatus.notFound && tagged == null) {
        rethrow;
      }
      apiError = error;
      apiStack = stack;
    } on Object catch (error, stack) {
      apiError = error;
      apiStack = stack;
    }
    // The API refused (a mobile operator's shared address used its limit
    // up): the pages' copy of the same release, when they have it already.
    try {
      final GithubRelease? release = GithubRelease.fromJson(
        await _fetchJson(kZenReleaseInfoUri),
      );
      if (release != null &&
          (tagged == null || release.version == tagged.version)) {
        return LatestReleaseAnswer(release, LatestReleaseSource.pages);
      }
    } on Object catch (error) {
      logZenWarning('Update check: release.json not read: $error');
    }
    if (tagged != null) {
      logZenWarning(
        'Update check: GitHub API answered ${apiError ?? 'another version'}; '
        'the version came from the release page.',
      );
      return LatestReleaseAnswer(tagged, LatestReleaseSource.redirect);
    }
    if (apiError != null) {
      Error.throwWithStackTrace(apiError, apiStack!);
    }
    return const LatestReleaseAnswer(null, LatestReleaseSource.api);
  }
}
