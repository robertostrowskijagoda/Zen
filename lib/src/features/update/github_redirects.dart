import 'dart:async';
import 'dart:io';

import 'package:zen/src/app/zen_web.dart';

/// The only hosts Zen's GitHub requests go to, redirects included: the API,
/// the release pages and GitHub's file servers.
const Set<String> kGithubHosts = <String>{
  'api.github.com',
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com',
};

/// How many redirects one request may follow.
const int kMaxGithubRedirects = 5;

/// Whether [uri] is HTTPS on the default port to one of [kGithubHosts].
bool isGithubUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    kGithubHosts.contains(uri.host.toLowerCase());

/// Whether [uri] is HTTPS on the default port to the project's pages
/// ([kZenPageBases]), where the Pages workflow publishes `release.json`.
bool isZenPagesUri(Uri uri) =>
    uri.scheme == 'https' &&
    uri.userInfo.isEmpty &&
    uri.port == 443 &&
    kZenPageBases.any(
      (String base) => Uri.parse(base).host == uri.host.toLowerCase(),
    );

/// Where the newest release is looked up: GitHub ([isGithubUri]) and the
/// project's pages ([isZenPagesUri]).
bool isReleaseInfoUri(Uri uri) => isGithubUri(uri) || isZenPagesUri(uri);

/// A redirect that leads away from GitHub (or one too many).
final class GithubRedirectException implements Exception {
  const GithubRedirectException(this.uri);

  final Uri uri;

  @override
  String toString() => 'Redirect refused: $uri';
}

/// GETs [uri] and follows redirects by hand, only to [allowed] addresses
/// ([isGithubUri] unless said otherwise) and at most [kMaxGithubRedirects]
/// times, each step within [timeout]. [headers] go with the first request
/// only (e.g. `If-None-Match`). Throws [ArgumentError] when [uri] itself is
/// not such an address and [GithubRedirectException] for a redirect
/// anywhere else.
Future<HttpClientResponse> getFromGithub(
  HttpClient client,
  Uri uri, {
  required Duration timeout,
  Map<String, String> headers = const <String, String>{},
  bool Function(Uri uri) allowed = isGithubUri,
}) async {
  if (!allowed(uri)) {
    throw ArgumentError.value(uri, 'uri', 'HTTPS to GitHub only');
  }
  Uri at = uri;
  for (int hop = 0; ; hop++) {
    final HttpClientRequest request = await client.getUrl(at).timeout(timeout);
    request.followRedirects = false;
    if (hop == 0) {
      headers.forEach(request.headers.set);
    }
    final HttpClientResponse response = await request.close().timeout(timeout);
    if (!response.isRedirect) {
      return response;
    }
    final String? location = response.headers.value(HttpHeaders.locationHeader);
    try {
      await response.drain<void>().timeout(timeout);
    } on Object {
      // Only the Location header matters.
    }
    final Uri? next = location == null ? null : Uri.tryParse(location);
    final Uri target = next == null ? at : at.resolveUri(next);
    if (next == null || hop >= kMaxGithubRedirects || !allowed(target)) {
      throw GithubRedirectException(target);
    }
    at = target;
  }
}
