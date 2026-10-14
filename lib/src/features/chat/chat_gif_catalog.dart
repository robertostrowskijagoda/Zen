import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Shared application key for the Klipy catalog. GIF browsing works out of
/// the box without any user configuration. Client-side catalog keys are
/// public by nature (they ship in every GUI client), so embedding one is a
/// deliberate product decision.
const String kZenSharedKlipyApiKey =
    'yvzMn6WP9oU5ZUKnlbVIyIzSJHUxU4bznsvFA0cJJQ0uJFGiFuzYBh9z0jiiW3Bj';

/// Builds the catalog for [apiKey]; swapped out in tests.
final Provider<GifCatalog Function(String apiKey)> gifCatalogFactoryProvider =
    Provider<GifCatalog Function(String apiKey)>(
      (Ref ref) =>
          (String apiKey) => KlipyGifCatalog(apiKey: apiKey),
    );

/// The user's own key when they set one, otherwise the shared app key.
final Provider<GifCatalog> gifCatalogProvider = Provider<GifCatalog>((Ref ref) {
  final String ownKey = ref.watch(
    appSettingsControllerProvider.select((settings) => settings.gifApiKey),
  );
  return ref.read(gifCatalogFactoryProvider)(
    ownKey.isEmpty ? kZenSharedKlipyApiKey : ownKey,
  );
});

final class GifCatalogEntry {
  const GifCatalogEntry({
    required this.previewUrl,
    required this.sendUrl,
    this.label,
  });

  final String previewUrl;
  final String sendUrl;
  final String? label;
}

abstract interface class GifCatalog {
  Future<List<GifCatalogEntry>> loadFeatured();

  Future<List<GifCatalogEntry>> search(String query);
}

/// Placeholder used until the user provides their own Klipy API key in the
/// settings. The app ships without any embedded third-party credentials.
final class EmptyGifCatalog implements GifCatalog {
  const EmptyGifCatalog();

  @override
  Future<List<GifCatalogEntry>> loadFeatured() async =>
      const <GifCatalogEntry>[];

  @override
  Future<List<GifCatalogEntry>> search(String query) async =>
      const <GifCatalogEntry>[];
}

final class KlipyGifCatalog implements GifCatalog {
  const KlipyGifCatalog({
    required this.apiKey,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final String apiKey;
  static const String _clientKey = 'zen_messenger';

  final HttpClient Function() _clientFactory;

  @override
  Future<List<GifCatalogEntry>> loadFeatured() {
    final Uri uri = Uri.parse(
      'https://api.klipy.com/v2/featured'
      '?key=$apiKey&client_key=$_clientKey'
      '&limit=30&media_filter=tinygif,gif&locale=pl_PL',
    );
    return _fetch(uri);
  }

  @override
  Future<List<GifCatalogEntry>> search(String query) {
    final String normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return loadFeatured();
    }
    final Uri uri = Uri.parse(
      'https://api.klipy.com/v2/search'
      '?q=${Uri.encodeComponent(normalizedQuery)}'
      '&key=$apiKey&client_key=$_clientKey'
      '&limit=30&media_filter=tinygif,gif&locale=pl_PL',
    );
    return _fetch(uri);
  }

  Future<List<GifCatalogEntry>> _fetch(Uri uri) async {
    final HttpClient client = _clientFactory();
    try {
      final HttpClientRequest request = await client.getUrl(uri);
      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GIF catalog request failed with ${response.statusCode}.',
          uri: uri,
        );
      }
      final Object decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('GIF catalog payload is invalid.');
      }
      return parseResults(decoded);
    } finally {
      client.close(force: true);
    }
  }

  static List<GifCatalogEntry> parseResults(Map<String, dynamic> payload) {
    final List<dynamic> results =
        payload['results'] as List<dynamic>? ?? <dynamic>[];
    return results
        .map(_entryFromRaw)
        .whereType<GifCatalogEntry>()
        .toList(growable: false);
  }

  static GifCatalogEntry? _entryFromRaw(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> data = raw.cast<String, dynamic>();
    final Map<String, dynamic>? mediaFormats =
        data['media_formats'] as Map<String, dynamic>?;
    if (mediaFormats == null) {
      return null;
    }
    final String? previewUrl = _readMediaUrl(mediaFormats, const <String>[
      'tinygif',
      'gif',
    ]);
    final String? sendUrl = _readMediaUrl(mediaFormats, const <String>[
      'gif',
      'mediumgif',
      'tinygif',
    ]);
    if (previewUrl == null || sendUrl == null) {
      return null;
    }
    final String? label = (data['content_description'] as String?)
        ?.trim()
        .replaceAll(RegExp(r'\s+'), ' ');
    return GifCatalogEntry(
      previewUrl: previewUrl,
      sendUrl: sendUrl,
      label: label == null || label.isEmpty ? null : label,
    );
  }

  static String? _readMediaUrl(
    Map<String, dynamic> mediaFormats,
    List<String> priorities,
  ) {
    for (final String key in priorities) {
      final Map<String, dynamic>? format =
          mediaFormats[key] as Map<String, dynamic>?;
      final String? url = (format?['url'] as String?)?.trim();
      if (url != null && url.isNotEmpty) {
        return url;
      }
    }
    return null;
  }
}
