import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What the release's `SHA256SUMS` says about a file (§14.3 point 5).
enum Sha256SumsVerdict {
  /// The file's sum is listed in the release's `SHA256SUMS`.
  match,

  /// `SHA256SUMS` lists this file name with another sum.
  mismatch,

  /// `SHA256SUMS` lists neither this sum nor this file name.
  notListed,
}

/// Where the `SHA256SUMS` of release [version] lives (the tag is
/// `v<version>`, RELEASES.md §2 point 6).
Uri sha256SumsUri(String version) => Uri.parse(
  '${PeerShareCodec.repositoryUrl}/releases/download/'
  'v${Uri.encodeComponent(version)}/SHA256SUMS',
);

/// The sums of a `sha256sum`-format file: file name → lower-case hex. Lines
/// that are not `<64 hex> <name>` (a `*` before the name marks binary mode)
/// are skipped.
Map<String, String> parseSha256Sums(String text) {
  final RegExp line = RegExp(r'^([0-9a-fA-F]{64}) [ *]?(.+)$');
  final Map<String, String> sums = <String, String>{};
  for (final String raw in const LineSplitter().convert(text)) {
    final RegExpMatch? m = line.firstMatch(raw.trim());
    if (m != null) {
      sums[m.group(2)!.trim()] = m.group(1)!.toLowerCase();
    }
  }
  return sums;
}

/// Compares the file [fileName] whose SHA-256 is [sha256Hex] with the text
/// of a `SHA256SUMS` file. The sum counts wherever it is listed (a release
/// file may carry a different name than the one it was saved under).
Sha256SumsVerdict compareWithSha256Sums({
  required String fileName,
  required String sha256Hex,
  required String sumsText,
}) {
  final Map<String, String> sums = parseSha256Sums(sumsText);
  final String hex = sha256Hex.toLowerCase();
  if (sums.containsValue(hex)) {
    return Sha256SumsVerdict.match;
  }
  return sums.containsKey(fileName)
      ? Sha256SumsVerdict.mismatch
      : Sha256SumsVerdict.notListed;
}

/// Downloads the text at [uri]; swapped out in tests. Called only when the
/// person asks: Zen never reaches GitHub on its own.
typedef Sha256SumsFetcher = Future<String> Function(Uri uri);

final Provider<Sha256SumsFetcher> sha256SumsFetcherProvider =
    Provider<Sha256SumsFetcher>((Ref ref) => fetchSha256Sums);

/// The most a `SHA256SUMS` file may be (a few lines in reality).
const int kMaxSha256SumsBytes = 64 * 1024;

/// Fetches [uri] over HTTPS (GitHub redirects to its CDN, which is followed),
/// refusing anything larger than [kMaxSha256SumsBytes]. Throws on any error.
Future<String> fetchSha256Sums(Uri uri) async {
  if (uri.scheme != 'https') {
    throw ArgumentError.value(uri, 'uri', 'HTTPS only');
  }
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);
  try {
    final HttpClientRequest request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: uri);
    }
    final BytesBuilder body = BytesBuilder(copy: false);
    await for (final List<int> chunk in response.timeout(
      const Duration(seconds: 15),
    )) {
      body.add(chunk);
      if (body.length > kMaxSha256SumsBytes) {
        throw HttpException('SHA256SUMS is too large', uri: uri);
      }
    }
    return utf8.decode(body.takeBytes(), allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}
