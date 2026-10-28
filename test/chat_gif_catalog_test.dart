import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/chat/chat_gif_catalog.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The catalog host: each copy by its URL, and what was fetched.
final class _Host implements GifDownloader {
  _Host(this.files);

  final Map<String, Uint8List> files;
  final List<String> fetched = <String>[];

  @override
  Future<Uint8List> download(String url) async {
    fetched.add(url);
    final Uint8List? bytes = files[url];
    if (bytes == null) {
      throw StateError('no such GIF');
    }
    return bytes;
  }
}

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
    // No sizes given: the small copy the picker shows goes.
    expect(entries.single.sendUrl, 'https://example.com/cat-preview.gif');
    expect(entries.single.smallerSendUrls, isEmpty);
    expect(entries.single.label, 'Kot macha lapa');
  });

  test('the copy sent is the largest one that fits a chat message', () {
    GifCatalogEntry entryWith(Map<String, int> sizes) =>
        KlipyGifCatalog.parseResults(<String, dynamic>{
          'results': <Object>[
            <String, dynamic>{
              'media_formats': <String, dynamic>{
                for (final MapEntry<String, int> size in sizes.entries)
                  size.key: <String, dynamic>{
                    'url': 'https://static.klipy.com/${size.key}.gif',
                    'size': size.value,
                  },
              },
            },
          ],
        }).single;

    // The full copy is several megabytes: the medium one fits.
    final GifCatalogEntry medium = entryWith(<String, int>{
      'gif': 4 * 1024 * 1024,
      'mediumgif': 150 * 1024,
      'tinygif': 60 * 1024,
    });
    expect(medium.previewUrl, 'https://static.klipy.com/tinygif.gif');
    expect(medium.sendUrl, 'https://static.klipy.com/mediumgif.gif');
    expect(medium.smallerSendUrls, <String>[
      'https://static.klipy.com/tinygif.gif',
    ]);

    // A small GIF goes whole.
    expect(
      entryWith(<String, int>{'gif': 90 * 1024, 'tinygif': 30 * 1024}).sendUrl,
      'https://static.klipy.com/gif.gif',
    );

    // None fits: the smallest.
    final GifCatalogEntry none = entryWith(<String, int>{
      'gif': 9 * 1024 * 1024,
      'mediumgif': 2 * 1024 * 1024,
      'tinygif': 400 * 1024,
    });
    expect(none.sendUrl, 'https://static.klipy.com/tinygif.gif');
    expect(none.smallerSendUrls, isEmpty);
  });

  test('a catalog GIF fits a message that a locked phone keeps at once', () {
    // The GIF goes in the message as base64, with the message's own fields.
    expect(
      base64Encode(Uint8List(kMaxCatalogGifSendBytes)).length + 8 * 1024,
      lessThanOrEqualTo(kSealedInboxMaxRecordBytes),
    );
  });

  group('downloadGifToSend', () {
    final Uint8List gif = Uint8List.fromList(const <int>[
      0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, //
      0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x2C, 0x00, 0x00, 0x00, 0x00,
      0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00, 0x3B,
    ]);
    // The same GIF with a comment and junk after its end, as some hosts
    // serve them.
    final Uint8List withMetadata = Uint8List.fromList(<int>[
      ...gif.sublist(0, 19),
      0x21, 0xFE, 3, 0x41, 0x42, 0x43, 0, //
      ...gif.sublist(19),
      0x00, 0x00,
    ]);

    test('sends the GIF without its metadata', () async {
      final _Host host = _Host(<String, Uint8List>{
        'https://static.klipy.com/a.gif': withMetadata,
      });
      final Uint8List sent = await downloadGifToSend(
        host,
        const GifCatalogEntry(
          previewUrl: 'https://static.klipy.com/a.gif',
          sendUrl: 'https://static.klipy.com/a.gif',
        ),
      );
      expect(sent, gif);
    });

    test('falls back to a smaller copy when one cannot be fetched or is '
        'too large', () async {
      final Uint8List large = Uint8List.fromList(<int>[
        ...gif.sublist(0, 19),
        // A long comment: over the limit for a catalog GIF, yet a valid GIF.
        for (int i = 0; i < (kMaxCatalogGifSendBytes ~/ 255) + 2; i++) ...<int>[
          0x21,
          0xFE,
          255,
          ...List<int>.filled(255, 0x41),
          0,
        ],
        ...gif.sublist(19),
      ]);
      // Too large even without metadata: a picture block of its own.
      final Uint8List heavy = Uint8List.fromList(<int>[
        ...gif.sublist(0, 19),
        0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, //
        for (int i = 0; i < (kMaxCatalogGifSendBytes ~/ 255) + 2; i++) ...<int>[
          255,
          ...List<int>.filled(255, 0x00),
        ],
        0x00,
        ...gif.sublist(19),
      ]);
      final _Host host = _Host(<String, Uint8List>{
        'https://static.klipy.com/heavy.gif': heavy,
        'https://static.klipy.com/large.gif': large,
      });
      final Uint8List sent = await downloadGifToSend(
        host,
        const GifCatalogEntry(
          previewUrl: 'https://static.klipy.com/large.gif',
          sendUrl: 'https://static.klipy.com/heavy.gif',
          smallerSendUrls: <String>[
            'https://static.klipy.com/missing.gif',
            'https://static.klipy.com/large.gif',
          ],
        ),
      );
      // The comment went with the metadata: the last copy fits.
      expect(sent, gif);
      expect(host.fetched, <String>[
        'https://static.klipy.com/heavy.gif',
        'https://static.klipy.com/missing.gif',
        'https://static.klipy.com/large.gif',
      ]);

      // Only the heavy one there: it still goes.
      expect(
        await downloadGifToSend(
          _Host(<String, Uint8List>{
            'https://static.klipy.com/heavy.gif': heavy,
          }),
          const GifCatalogEntry(
            previewUrl: 'https://static.klipy.com/heavy.gif',
            sendUrl: 'https://static.klipy.com/heavy.gif',
            smallerSendUrls: <String>['https://static.klipy.com/missing.gif'],
          ),
        ),
        heavy,
      );
    });

    test('fails when no copy is a GIF that can be sent', () async {
      await expectLater(
        downloadGifToSend(
          _Host(<String, Uint8List>{
            'https://static.klipy.com/a.gif': Uint8List.fromList(
              'not a gif'.codeUnits,
            ),
          }),
          const GifCatalogEntry(
            previewUrl: 'https://static.klipy.com/a.gif',
            sendUrl: 'https://static.klipy.com/a.gif',
            smallerSendUrls: <String>['https://static.klipy.com/b.gif'],
          ),
        ),
        throwsA(anything),
      );
    });
  });

  group('Klipy requests use the app language', () {
    tearDown(ZenI18n.debugReset);

    test('Polish by default (the source language)', () {
      const KlipyGifCatalog catalog = KlipyGifCatalog(apiKey: 'k');
      expect(catalog.featuredUri().queryParameters['locale'], 'pl_PL');
      expect(catalog.searchUri('kot').queryParameters['locale'], 'pl_PL');
      // Every copy a GIF may be sent in is asked for.
      for (final Uri uri in <Uri>[
        catalog.featuredUri(),
        catalog.searchUri('kot'),
      ]) {
        expect(
          uri.queryParameters['media_filter']!.split(','),
          containsAll(<String>['tinygif', 'mediumgif', 'gif']),
        );
      }
    });

    test('follows the language the app speaks', () {
      const KlipyGifCatalog catalog = KlipyGifCatalog(apiKey: 'k');
      ZenI18n.debugUse('en', const <String, Object?>{});
      expect(catalog.featuredUri().queryParameters['locale'], 'en_US');
      ZenI18n.debugUse('de', const <String, Object?>{});
      final Uri search = catalog.searchUri('katze');
      expect(search.queryParameters['locale'], 'de_DE');
      expect(search.queryParameters['q'], 'katze');
    });

    test('every language Zen speaks maps to a locale', () {
      for (final ZenLanguage language in kZenLanguages) {
        expect(
          klipyLocaleFor(language.code),
          matches(RegExp('^${language.code}_[A-Z]{2}\$')),
          reason: language.code,
        );
      }
      expect(klipyLocaleFor('xx'), 'en_US');
    });
  });

  test('the GIF downloader only fetches from the catalog host', () async {
    final HttpGifDownloader downloader = HttpGifDownloader(
      clientFactory: () => throw StateError('no request may be made'),
    );
    for (final String url in <String>[
      'http://cdn.klipy.com/cat.gif',
      'https://evil.com/cat.gif',
      'https://192.168.0.10/cat.gif',
      '',
    ]) {
      await expectLater(downloader.download(url), throwsFormatException);
    }
  });
}
