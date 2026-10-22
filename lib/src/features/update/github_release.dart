import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/github_redirects.dart';
import 'package:zen/src/features/update/sha256_sums.dart';

/// The newest published release of the project on GitHub (drafts and
/// pre-releases are never "latest").
final Uri kGithubLatestReleaseUri = Uri.parse(
  'https://api.github.com/repos/robertostrowskijagoda/Zen/releases/latest',
);

/// The only header Zen adds to its GitHub requests (GitHub's API refuses a
/// request without one). No tokens, ids or anything else about the device.
const String kGithubUserAgent = 'Zen';

/// How long one request may take before GitHub counts as unreachable.
const Duration kGithubTimeout = Duration(seconds: 20);

/// The most the release JSON may be (a few dozen KB in reality).
const int kMaxGithubJsonBytes = 1024 * 1024;

/// The most a downloaded release file may be.
const int kMaxGithubAssetBytes = 600 * 1024 * 1024;

/// GitHub could not be reached at all: no connection, DNS failure, a
/// broken TLS handshake or a timeout. Not "GitHub answered with an error".
final class GithubUnreachableException implements Exception {
  const GithubUnreachableException(this.cause);

  final Object cause;

  @override
  String toString() => 'GitHub unreachable: $cause';
}

/// GitHub answered, but not with what was asked for.
final class GithubStatusException implements Exception {
  const GithubStatusException(this.statusCode, {this.retryAfter});

  final int statusCode;

  /// How long GitHub asked to wait (`Retry-After`, or the reset time of
  /// an exhausted rate limit); null when it said nothing.
  final Duration? retryAfter;

  /// GitHub's rate limit (60 requests an hour per IP address without an
  /// account, shared by everyone behind the same mobile operator's
  /// address): 429, or 403 with a time to wait.
  bool get rateLimited =>
      statusCode == HttpStatus.tooManyRequests ||
      (statusCode == HttpStatus.forbidden && retryAfter != null);

  @override
  String toString() => 'HTTP $statusCode';
}

/// How long GitHub asks a client to wait before the next request, read
/// from its answer's headers: `Retry-After` (seconds), else, when
/// `x-ratelimit-remaining` is 0, until `x-ratelimit-reset` (Unix seconds).
/// Null when the answer says nothing about it.
Duration? githubRetryAfter({
  String? retryAfter,
  String? rateLimitRemaining,
  String? rateLimitReset,
  required DateTime now,
}) {
  final int? seconds = int.tryParse(retryAfter?.trim() ?? '');
  if (seconds != null && seconds >= 0) {
    return Duration(seconds: seconds);
  }
  final int? reset = int.tryParse(rateLimitReset?.trim() ?? '');
  if (rateLimitRemaining?.trim() == '0' && reset != null) {
    final Duration wait = DateTime.fromMillisecondsSinceEpoch(
      reset * 1000,
      isUtc: true,
    ).difference(now.toUtc());
    return wait.isNegative ? Duration.zero : wait;
  }
  return null;
}

/// Whether [error] means the server could not be reached (as opposed to an
/// answer that was an error).
bool isUnreachableError(Object error) =>
    error is GithubUnreachableException ||
    error is SocketException ||
    error is TimeoutException ||
    error is TlsException ||
    error is HttpException;

/// One release as GitHub's API describes it.
@immutable
final class GithubRelease {
  const GithubRelease({
    required this.tag,
    required this.version,
    required this.assets,
    this.minVersion,
  });

  /// `v1.12.0`.
  final String tag;

  /// `1.12.0`.
  final String version;

  /// File name → size in bytes.
  final Map<String, int> assets;

  /// The oldest Zen still supported, from a line `zen-min: 1.12.0` in the
  /// release notes ([kZenMinLine]); `null` when there is none. A build
  /// older than this tells the person it must be updated.
  final String? minVersion;

  /// Reads the `releases/latest` answer; null for a draft, a pre-release, a
  /// tag that is not `v<major.minor.patch>` or anything malformed.
  static GithubRelease? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? tag = json['tag_name'];
    if (tag is! String ||
        !tag.startsWith('v') ||
        json['draft'] == true ||
        json['prerelease'] == true) {
      return null;
    }
    // Release tags are `v<version>` (docs/RELEASES.md), as the SHA256SUMS
    // address assumes.
    final String version = tag.substring(1);
    if (!isValidAppVersion(version)) {
      return null;
    }
    final Map<String, int> assets = <String, int>{};
    final Object? list = json['assets'];
    if (list is List) {
      for (final Object? a in list) {
        if (a is! Map) {
          continue;
        }
        final Object? name = a['name'];
        final Object? size = a['size'];
        if (name is String &&
            _safeAssetName.hasMatch(name) &&
            size is int &&
            size > 0 &&
            size <= kMaxGithubAssetBytes) {
          assets[name] = size;
        }
      }
    }
    final Object? body = json['body'];
    final String? min = body is String
        ? kZenMinLine.firstMatch(body)?.group(1)
        : null;
    return GithubRelease(
      tag: tag,
      version: version,
      assets: assets,
      minVersion: min != null && compareAppVersions(min, version) <= 0
          ? min
          : null,
    );
  }

  /// Whether this release is newer than [ours].
  bool isNewerThan(String ours) => compareAppVersions(version, ours) > 0;

  /// Where the file [name] of this release is downloaded from.
  Uri assetUri(String name) => Uri.parse(
    '${PeerShareCodec.repositoryUrl}/releases/download/'
    '${Uri.encodeComponent(tag)}/${Uri.encodeComponent(name)}',
  );

  /// The release page (for people who prefer to download by hand).
  Uri get pageUri => Uri.parse(
    '${PeerShareCodec.repositoryUrl}/releases/tag/${Uri.encodeComponent(tag)}',
  );
}

final RegExp _safeAssetName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$');

/// The line of a release's notes that names the oldest supported Zen:
/// `zen-min: 1.12.0` (on a line of its own).
final RegExp kZenMinLine = RegExp(
  r'^\s*zen-min:\s*(\d{1,4}\.\d{1,4}\.\d{1,4})\s*$',
  multiLine: true,
);

/// How Zen is installed on a Linux computer (which release file updates it).
enum LinuxInstall {
  /// Unpacked from `Zen-Linux-*.tar.gz` somewhere.
  tarball,

  /// The `.deb` package (`/opt/zen`).
  deb,

  /// The Flatpak bundle.
  flatpak,
}

/// The release file that updates this platform ([releasePlatform] as
/// [currentReleasePlatform] names it), or null where Zen cannot update
/// itself (iOS: only the prompt is shown).
String? githubAssetName({
  required String releasePlatform,
  required Abi abi,
  LinuxInstall linux = LinuxInstall.tarball,
}) {
  switch (releasePlatform) {
    case 'android':
      return 'Zen.apk';
    case 'windows':
      return abi == Abi.windowsArm64
          ? 'Zen-Windows-arm64.zip'
          : 'Zen-Windows.zip';
    case 'macos':
      return 'Zen-macOS.zip';
    case 'linux':
      final String arch = abi == Abi.linuxArm64 ? 'arm64' : 'x64';
      return switch (linux) {
        LinuxInstall.deb => 'Zen-Linux-$arch.deb',
        // The Flatpak bundle is built for x64 only.
        LinuxInstall.flatpak when arch == 'x64' => 'Zen-Linux-x64.flatpak',
        _ => 'Zen-Linux-$arch.tar.gz',
      };
  }
  return null;
}

/// Whether the release's `SHA256SUMS` ([sumsText]) lists the file [name]
/// with exactly [sha256Hex]. Stricter than [compareWithSha256Sums]: the
/// name must match too.
bool sha256SumsConfirm({
  required String sumsText,
  required String name,
  required String sha256Hex,
}) => parseSha256Sums(sumsText)[name] == sha256Hex.toLowerCase();

/// Fetches JSON from [uri]; swapped out in tests.
typedef GithubJsonFetcher = Future<Object?> Function(Uri uri);

/// Downloads [uri] into [target], refusing more than [maxBytes];
/// [onProgress] gets the bytes received so far. Swapped out in tests.
typedef GithubDownloader =
    Future<void> Function(
      Uri uri,
      File target, {
      required int maxBytes,
      void Function(int received)? onProgress,
    });

HttpClient _client() => HttpClient()
  ..connectionTimeout = kGithubTimeout
  ..userAgent = kGithubUserAgent;

/// Redirects are followed only to GitHub's own hosts ([kGithubHosts]).
Future<HttpClientResponse> _get(
  HttpClient client,
  Uri uri, {
  Map<String, String> headers = const <String, String>{},
}) async {
  try {
    return await getFromGithub(
      client,
      uri,
      timeout: kGithubTimeout,
      headers: headers,
    );
  } on Object catch (error) {
    if (isUnreachableError(error)) {
      throw GithubUnreachableException(error);
    }
    rethrow;
  }
}

/// One answer of GitHub's API: the decoded JSON, or [notModified] when
/// the `If-None-Match` sent matched (GitHub does not count such an answer
/// against the rate limit), and the `ETag` to send next time.
@immutable
final class GithubJsonAnswer {
  const GithubJsonAnswer({this.json, this.etag, this.notModified = false});

  final Object? json;
  final String? etag;
  final bool notModified;
}

/// GETs [uri] and decodes its JSON. With [etag] it asks
/// `If-None-Match` and a 304 comes back as [GithubJsonAnswer.notModified].
/// Throws [GithubUnreachableException] when the server cannot be reached
/// and [GithubStatusException] (with GitHub's time to wait, if it gave
/// one) for any other answer but 200.
Future<GithubJsonAnswer> fetchGithubJsonAnswer(Uri uri, {String? etag}) async {
  final HttpClient client = _client();
  try {
    final HttpClientResponse response = await _get(
      client,
      uri,
      headers: <String, String>{
        if (etag != null && etag.isNotEmpty) 'If-None-Match': etag,
      },
    );
    final String? newEtag = response.headers.value('etag');
    if (response.statusCode == HttpStatus.notModified && etag != null) {
      await _drainQuietly(response);
      return GithubJsonAnswer(etag: newEtag ?? etag, notModified: true);
    }
    if (response.statusCode != HttpStatus.ok) {
      await _drainQuietly(response);
      throw GithubStatusException(
        response.statusCode,
        retryAfter: githubRetryAfter(
          retryAfter: response.headers.value('retry-after'),
          rateLimitRemaining: response.headers.value('x-ratelimit-remaining'),
          rateLimitReset: response.headers.value('x-ratelimit-reset'),
          now: DateTime.now(),
        ),
      );
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    try {
      await for (final List<int> chunk in response.timeout(kGithubTimeout)) {
        body.add(chunk);
        if (body.length > kMaxGithubJsonBytes) {
          throw const GithubStatusException(HttpStatus.requestEntityTooLarge);
        }
      }
    } on Object catch (error) {
      if (isUnreachableError(error)) {
        throw GithubUnreachableException(error);
      }
      rethrow;
    }
    return GithubJsonAnswer(
      json: jsonDecode(utf8.decode(body.takeBytes())),
      etag: newEtag,
    );
  } finally {
    client.close(force: true);
  }
}

/// GETs [uri] and decodes its JSON ([fetchGithubJsonAnswer] without a
/// cache).
Future<Object?> fetchGithubJson(Uri uri) async =>
    (await fetchGithubJsonAnswer(uri)).json;

/// A [GithubJsonFetcher] that remembers the last answer and its `ETag`
/// for each address and asks with `If-None-Match`: an unchanged release
/// costs GitHub's rate limit nothing and comes back from here.
final class GithubJsonCache {
  GithubJsonCache({
    Future<GithubJsonAnswer> Function(Uri uri, {String? etag})? fetch,
  }) : _fetch = fetch ?? fetchGithubJsonAnswer;

  final Future<GithubJsonAnswer> Function(Uri uri, {String? etag}) _fetch;
  final Map<Uri, GithubJsonAnswer> _last = <Uri, GithubJsonAnswer>{};

  Future<Object?> call(Uri uri) async {
    final GithubJsonAnswer? last = _last[uri];
    final GithubJsonAnswer answer = await _fetch(uri, etag: last?.etag);
    if (answer.notModified && last != null) {
      return last.json;
    }
    final String? etag = answer.etag;
    if (etag != null && etag.isNotEmpty) {
      _last[uri] = answer;
    } else {
      _last.remove(uri);
    }
    return answer.json;
  }
}

Future<void> _drainQuietly(HttpClientResponse response) async {
  try {
    await response.drain<void>().timeout(kGithubTimeout);
  } on Object {
    // Only the status and the headers matter.
  }
}

/// Downloads [uri] (GitHub redirects to its file servers, which is
/// followed, but nowhere else) into [target].
Future<void> downloadGithubAsset(
  Uri uri,
  File target, {
  required int maxBytes,
  void Function(int received)? onProgress,
}) async {
  final HttpClient client = _client();
  IOSink? sink;
  try {
    final HttpClientResponse response = await _get(client, uri);
    if (response.statusCode != HttpStatus.ok) {
      throw GithubStatusException(response.statusCode);
    }
    sink = target.openWrite();
    int received = 0;
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 60),
    )) {
      received += chunk.length;
      if (received > maxBytes) {
        throw const GithubStatusException(HttpStatus.requestEntityTooLarge);
      }
      sink.add(chunk);
      onProgress?.call(received);
    }
    await sink.flush();
  } finally {
    await sink?.close();
    client.close(force: true);
  }
}
