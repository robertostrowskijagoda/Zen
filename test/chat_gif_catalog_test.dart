import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

void main() {
  test('GIFs use the shared key until the user sets their own', () async {
    final ProviderContainer container = ProviderContainer(
      overrides: [appSettingsHydrationEnabledProvider.overrideWithValue(false)],
    );
    addTearDown(container.dispose);

    String keyInUse() =>
        (container.read(gifCatalogProvider) as KlipyGifCatalog).apiKey;

    expect(container.read(gifCatalogProvider), isA<KlipyGifCatalog>());
    expect(keyInUse(), kZenSharedKlipyApiKey);

    await container
        .read(appSettingsControllerProvider.notifier)
        .setGifApiKey('  moj-klucz_123  ');
    expect(keyInUse(), 'moj-klucz_123');

    // Clearing it goes back to the default.
    await container
        .read(appSettingsControllerProvider.notifier)
        .setGifApiKey('');
    expect(keyInUse(), kZenSharedKlipyApiKey);
  });

  test('Klipy GIF catalog maps preview and send URLs from API results', () {
    final List<GifCatalogEntry> entries = KlipyGifCatalog.parseResults(
      <String, dynamic>{
        'results': <Object>[
          <String, dynamic>{
            'content_description': 'Kot macha lapa',
            'media_formats': <String, dynamic>{
              'tinygif': <String, dynamic>{
                'url': 'https://example.com/cat-preview.gif',
              },
              'gif': <String, dynamic>{'url': 'https://example.com/cat.gif'},
            },
          },
          <String, dynamic>{
            'media_formats': <String, dynamic>{
              'tinygif': <String, dynamic>{'url': ''},
            },
          },
        ],
      },
    );

    expect(entries, hasLength(1));
    expect(entries.single.previewUrl, 'https://example.com/cat-preview.gif');
    expect(entries.single.sendUrl, 'https://example.com/cat.gif');
    expect(entries.single.label, 'Kot macha lapa');
  });
}
