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

/// Looks up the newest published release, in this order, until one answers:
///
/// 1. the project's `release.json` on GitHub Pages ([kZenReleaseInfoUri]):
///    no rate limit, the release's files and sizes, `zen-min`;
/// 2. GitHub's API ([kGithubLatestReleaseUri]), through [fetchJson] (with
///    `If-None-Match`): 60 requests an hour per IP address, which a mobile
///    operator's shared address often has used up (403 or 429);
/// 3. only when the API answered with an error or did not answer (not for
///    its 404, which says no release is published): GitHub's redirect from
///    the newest release's page ([kGithubLatestReleasePageUri], [fetchTag]),
///    which names the version alone ([GithubRelease.detailed] false).
///
/// None of them is trusted for more than which version is the newest: what
/// is installed is still checked against the release's `SHA256SUMS` (and
/// its signature, and on Android the signing certificate), downloaded from
/// github.com for that very tag. When nothing answers, the API's error is
/// thrown (or the pages' error, without an API answer), so the caller can
/// tell a rate limit, an error answer, "no release" (404) and "not
/// reached" apart. [fetchTag] null: no third step.
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
    try {
      final GithubRelease? release = GithubRelease.fromJson(
        await _fetchJson(kZenReleaseInfoUri),
      );
      if (release != null) {
        return LatestReleaseAnswer(release, LatestReleaseSource.pages);
      }
      // No release on the pages (before the first one): GitHub says.
    } on Object catch (error) {
      logZenWarning('Update check: release.json not read: $error');
    }
    final Object apiError;
    final StackTrace apiStack;
    try {
      return LatestReleaseAnswer(
        GithubRelease.fromJson(await _fetchJson(kGithubLatestReleaseUri)),
        LatestReleaseSource.api,
      );
    } on GithubStatusException catch (error, stack) {
      if (error.statusCode == HttpStatus.notFound) {
        rethrow;
      }
      apiError = error;
      apiStack = stack;
    } on Object catch (error, stack) {
      apiError = error;
      apiStack = stack;
    }
    final GithubTagFetcher? tagOf = fetchTag;
    if (tagOf != null) {
      try {
        final String? tag = await tagOf(kGithubLatestReleasePageUri);
        final GithubRelease? release = tag == null
            ? null
            : GithubRelease.fromTag(tag);
        if (release != null) {
          logZenWarning(
            'Update check: GitHub API answered $apiError; the version came '
            'from the release page.',
          );
          return LatestReleaseAnswer(release, LatestReleaseSource.redirect);
        }
      } on Object catch (error) {
        logZenWarning('Update check: release page not read: $error');
      }
    }
    Error.throwWithStackTrace(apiError, apiStack);
  }
}
