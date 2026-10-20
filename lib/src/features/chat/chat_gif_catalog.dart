import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Shared application key for the Klipy catalog, embedded in the app and used
/// unless the user sets their own key in the settings. GIF browsing works out
/// of the box without any user configuration. Client-side catalog keys are
/// public by nature (they ship in every GUI client), so embedding one is a
/// deliberate product decision.
///
/// GIF search is the one feature that talks to a third party: the search
/// text, the app language and this device's IP address reach api.klipy.com
/// (the picker says so), and the GIFs themselves come from klipy.com.
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

/// A catalog that returns no GIFs, for wiring in where GIF search should be
/// off (tests, a build without it). Not the default: the app embeds a Klipy
/// key ([kZenSharedKlipyApiKey]) and uses [KlipyGifCatalog] unless
/// [gifCatalogProvider] is overridden.
final class EmptyGifCatalog implements GifCatalog {
  const EmptyGifCatalog();

  @override
  Future<List<GifCatalogEntry>> loadFeatured() async =>
      const <GifCatalogEntry>[];

  @override
  Future<List<GifCatalogEntry>> search(String query) async =>
      const <GifCatalogEntry>[];
}

/// The catalog locale (`xx_YY`) for a Zen language code such as
/// [ZenI18n.code]; English (`en_US`) for a code Zen does not speak.
String klipyLocaleFor(String languageCode) =>
    _klipyLocales[languageCode] ?? 'en_US';

/// Every language in `kZenLanguages`, with the region it is most used in.
const Map<String, String> _klipyLocales = <String, String>{
  'pl': 'pl_PL',
  'id': 'id_ID',
  'cs': 'cs_CZ',
  'de': 'de_DE',
  'en': 'en_US',
  'es': 'es_ES',
  'fr': 'fr_FR',
  'it': 'it_IT',
  'hu': 'hu_HU',
  'nl': 'nl_NL',
  'pt': 'pt_BR',
  'ro': 'ro_RO',
  'vi': 'vi_VN',
  'tr': 'tr_TR',
  'ru': 'ru_RU',
  'uk': 'uk_UA',
  'ar': 'ar_SA',
  'hi': 'hi_IN',
  'zh': 'zh_CN',
  'ja': 'ja_JP',
  'ko': 'ko_KR',
};

final class KlipyGifCatalog implements GifCatalog {
  const KlipyGifCatalog({
    required this.apiKey,
    HttpClient Function()? clientFactory,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final String apiKey;
  static const String _clientKey = 'zen_messenger';

  final HttpClient Function() _clientFactory;

  /// The app's current language, read per request so switching it takes
  /// effect at once.
  String get _locale => klipyLocaleFor(ZenI18n.code);

  /// The request for the featured GIFs.
  Uri featuredUri() => Uri.parse(
    'https://api.klipy.com/v2/featured'
    '?key=$apiKey&client_key=$_clientKey'
    '&limit=30&media_filter=tinygif,gif&locale=$_locale',
  );

  /// The request for GIFs matching [query] (already trimmed, non-empty).
  Uri searchUri(String query) => Uri.parse(
    'https://api.klipy.com/v2/search'
    '?q=${Uri.encodeComponent(query)}'
    '&key=$apiKey&client_key=$_clientKey'
    '&limit=30&media_filter=tinygif,gif&locale=$_locale',
  );

  @override
  Future<List<GifCatalogEntry>> loadFeatured() => _fetch(featuredUri());

  @override
  Future<List<GifCatalogEntry>> search(String query) {
    final String normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty) {
      return loadFeatured();
    }
    return _fetch(searchUri(normalizedQuery));
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
