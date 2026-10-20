import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/chat/remote_media_guard.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Shared application key for the Klipy catalog, embedded in the app and used
/// unless the user sets their own key in the settings. GIF browsing works out
/// of the box without any user configuration. Client-side catalog keys are
/// public by nature (they ship in every GUI client), so embedding one is a
/// deliberate product decision.
///
/// GIF search is the one feature that talks to a third party, and only from
/// the sender's device: the search text, the app language and this device's IP
/// address reach api.klipy.com, and the previews and the chosen GIF are
/// downloaded from klipy.com (the picker says so). The chosen GIF is then sent
/// as an ordinary image attachment, so the recipient never contacts klipy.com.
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

/// Downloads the bytes of a catalog GIF; swapped out in tests.
final Provider<GifDownloader> gifDownloaderProvider = Provider<GifDownloader>(
  (Ref ref) => HttpGifDownloader(),
);

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

/// Fetches a GIF from the catalog host as bytes.
abstract interface class GifDownloader {
  /// The bytes of the GIF at [url]. Throws when the URL is not an allowed
  /// catalog URL, the download fails or is too large, or the bytes are not a
  /// well-formed GIF within the limits of `media_guard` ([isAcceptableGif]).
  Future<Uint8List> download(String url);
}

/// Downloads over HTTPS from the allow-listed catalog host only
/// ([isAllowedRemoteMediaUrl]). Redirects are followed by hand and each hop
/// is checked against the allow-list. Recent GIFs are kept in memory so the
/// picker does not fetch a preview again when scrolling back.
final class HttpGifDownloader implements GifDownloader {
  HttpGifDownloader({HttpClient Function()? clientFactory})
    : _clientFactory = clientFactory ?? HttpClient.new;

  static const int _maxRedirects = 3;
  static const int _maxCached = 40;

  final HttpClient Function() _clientFactory;
  final LinkedHashMap<String, Uint8List> _cache =
      LinkedHashMap<String, Uint8List>();
  final Map<String, Future<Uint8List>> _inFlight =
      <String, Future<Uint8List>>{};

  @override
  Future<Uint8List> download(String url) async {
    if (!isAllowedRemoteMediaUrl(url)) {
      throw const FormatException('GIF URL is not allowed.');
    }
    final Uint8List? cached = _cache.remove(url);
    if (cached != null) {
      _cache[url] = cached; // most recently used last
      return cached;
    }
    final Future<Uint8List>? running = _inFlight[url];
    if (running != null) {
      return running;
    }
    final Future<Uint8List> pending = _fetch(url);
    _inFlight[url] = pending;
    try {
      final Uint8List bytes = await pending;
      _cache[url] = bytes;
      while (_cache.length > _maxCached) {
        _cache.remove(_cache.keys.first);
      }
      return bytes;
    } finally {
      _inFlight.remove(url);
    }
  }

  Future<Uint8List> _fetch(String url) async {
    final HttpClient client = _clientFactory()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      Uri target = Uri.parse(url);
      HttpClientResponse? response;
      for (int hop = 0; hop <= _maxRedirects; hop++) {
        final HttpClientRequest request = await client.getUrl(target);
        request.followRedirects = false;
        final HttpClientResponse candidate = await request.close();
        if (!candidate.isRedirect) {
          response = candidate;
          break;
        }
        final String? location = candidate.headers.value(
          HttpHeaders.locationHeader,
        );
        await candidate.drain<void>();
        if (location == null) {
          throw const HttpException('GIF redirect without a location.');
        }
        final Uri next = target.resolve(location);
        if (!isAllowedRemoteMediaUrl(next.toString())) {
          throw const FormatException('GIF redirect is not allowed.');
        }
        target = next;
      }
      if (response == null || response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'GIF download failed with ${response?.statusCode}.',
          uri: target,
        );
      }
      if (response.contentLength > kMaxGifBytes) {
        throw const FormatException('GIF is too large.');
      }
      final BytesBuilder builder = BytesBuilder(copy: false);
      await for (final List<int> chunk in response) {
        builder.add(chunk);
        if (builder.length > kMaxGifBytes) {
          throw const FormatException('GIF is too large.');
        }
      }
      final Uint8List bytes = builder.takeBytes();
      if (!isAcceptableGif(bytes)) {
        throw const FormatException(
          'Downloaded file is not an acceptable GIF.',
        );
      }
      return bytes;
    } finally {
      client.close(force: true);
    }
  }
}
