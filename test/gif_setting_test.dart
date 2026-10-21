import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

final class _CountingCatalog implements GifCatalog {
  int calls = 0;

  @override
  Future<List<GifCatalogEntry>> loadFeatured() async {
    calls++;
    return const <GifCatalogEntry>[];
  }

  @override
  Future<List<GifCatalogEntry>> search(String query) async {
    calls++;
    return const <GifCatalogEntry>[];
  }
}

void main() {
  ProviderContainer container({
    required bool gifSearch,
    required List<String> keys,
  }) {
    final ProviderContainer c = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: AppSettings(gifSearch: gifSearch),
          hydrationEnabled: false,
        ),
        gifCatalogFactoryProvider.overrideWithValue((String key) {
          keys.add(key);
          return _CountingCatalog();
        }),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('GIF search is on by default and the choice is kept', () {
    expect(const AppSettings().gifSearch, isTrue);
    expect(AppSettings.fromJson(<String, dynamic>{}).gifSearch, isTrue);
    expect(
      AppSettings.fromJson(
        const AppSettings(gifSearch: false).toJson(),
      ).gifSearch,
      isFalse,
    );
  });

  test('on: the catalog of klipy.com is used', () {
    final List<String> keys = <String>[];
    final ProviderContainer c = container(gifSearch: true, keys: keys);
    expect(c.read(gifSearchEnabledProvider), isTrue);
    expect(c.read(gifCatalogProvider), isA<_CountingCatalog>());
    expect(keys, <String>[kZenSharedKlipyApiKey]);
    expect(c.read(gifDownloaderProvider), isA<HttpGifDownloader>());
  });

  test('off: no catalog is made and nothing is downloaded', () async {
    final List<String> keys = <String>[];
    final ProviderContainer c = container(gifSearch: false, keys: keys);
    expect(c.read(gifSearchEnabledProvider), isFalse);
    final GifCatalog catalog = c.read(gifCatalogProvider);
    expect(catalog, isA<EmptyGifCatalog>());
    expect(await catalog.search('kot'), isEmpty);
    expect(await catalog.loadFeatured(), isEmpty);
    expect(keys, isEmpty, reason: 'no request to klipy.com');
    final GifDownloader downloader = c.read(gifDownloaderProvider);
    expect(downloader, isA<DisabledGifDownloader>());
    await expectLater(
      downloader.download('https://static.klipy.com/a.gif'),
      throwsStateError,
    );
  });

  test('turned off while running: the catalog follows at once', () async {
    final List<String> keys = <String>[];
    final ProviderContainer c = container(gifSearch: true, keys: keys);
    expect(c.read(gifCatalogProvider), isA<_CountingCatalog>());
    await c.read(appSettingsControllerProvider.notifier).setGifSearch(false);
    expect(c.read(gifCatalogProvider), isA<EmptyGifCatalog>());
    expect(c.read(gifDownloaderProvider), isA<DisabledGifDownloader>());
  });
}
