import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

Uint8List _twoFrameGif() {
  final img.Image first = img.Image(width: 8, height: 8, numChannels: 4)
    ..frameDuration = 40;
  img.fill(first, color: img.ColorRgba8(255, 0, 0, 255));
  final img.Image second = img.Image(width: 8, height: 8, numChannels: 4)
    ..frameDuration = 40;
  img.fill(second, color: img.ColorRgba8(0, 0, 255, 255));
  first.addFrame(second);
  return img.encodeGif(first);
}

const String _peerGifUrl = 'https://static.klipy.com/ii/abc/peer.gif';

/// A [ZenRemoteGif] in a minimal app, with the app settings [settings].
Widget _remoteGifApp({
  required GifFetcher fetcher,
  bool chosenByUser = false,
  AppSettings settings = const AppSettings(),
}) {
  return ProviderScope(
    overrides: [
      appSettingsHydrationEnabledProvider.overrideWithValue(false),
      appSettingsInitialStateProvider.overrideWithValue(settings),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: ZenRemoteGif(
          url: _peerGifUrl,
          chosenByUser: chosenByUser,
          width: 200,
          height: 220,
          fetcher: fetcher,
          errorBuilder: (BuildContext context, Object error, StackTrace? st) =>
              const Text('zepsuty'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a GIF keeps moving: the frame on screen changes over time', (
    WidgetTester tester,
  ) async {
    final Uint8List gif = _twoFrameGif();
    await tester.pumpWidget(
      MaterialApp(home: ZenAnimatedImage(bytes: gif, width: 80, height: 80)),
    );
    final Set<int> seen = <int>{};
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      // Advances the frame timer (fake time in widget tests).
      await tester.pump(const Duration(milliseconds: 60));
      final Finder raw = find.byType(RawImage);
      if (raw.evaluate().isEmpty) {
        continue;
      }
      final ui.Image? frame = tester.widget<RawImage>(raw).image;
      if (frame != null) {
        seen.add(identityHashCode(frame));
      }
    }
    expect(seen.length, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('something that is not an image shows the error view', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ZenAnimatedImage(
          bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          errorBuilder: (BuildContext context, Object error, StackTrace? st) =>
              const Text('zepsuty'),
        ),
      ),
    );
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('zepsuty'), findsOneWidget);
  });

  testWidgets('a GIF from a peer is not fetched until it is tapped', (
    WidgetTester tester,
  ) async {
    final List<String> fetched = <String>[];
    await tester.pumpWidget(
      _remoteGifApp(
        fetcher: (String url) {
          fetched.add(url);
          return Future<Uint8List?>.value();
        },
      ),
    );
    await tester.pump();

    expect(fetched, isEmpty);
    expect(find.text('GIF — dotknij, aby wczytać'), findsOneWidget);
    expect(find.text('static.klipy.com'), findsOneWidget);
    expect(find.byType(ZenAnimatedImage), findsNothing);

    // Rebuilding (scrolling, a new message) still fetches nothing.
    await tester.pump(const Duration(seconds: 5));
    expect(fetched, isEmpty);

    await tester.tap(find.byKey(const Key('remote-gif-tap-to-load')));
    await tester.pump();
    await tester.pump();

    expect(fetched, <String>[_peerGifUrl]);
    expect(find.text('GIF — dotknij, aby wczytać'), findsNothing);
    expect(find.byType(ZenAnimatedImage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a GIF the user picked themselves previews at once', (
    WidgetTester tester,
  ) async {
    final List<String> fetched = <String>[];
    await tester.pumpWidget(
      _remoteGifApp(
        chosenByUser: true,
        fetcher: (String url) {
          fetched.add(url);
          return Future<Uint8List?>.value();
        },
      ),
    );
    await tester.pump();

    expect(fetched, <String>[_peerGifUrl]);
    expect(find.text('GIF — dotknij, aby wczytać'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'with media downloads set to tap-only even an own GIF waits for a tap',
    (WidgetTester tester) async {
      final List<String> fetched = <String>[];
      await tester.pumpWidget(
        _remoteGifApp(
          chosenByUser: true,
          settings: const AppSettings(autoDownloadMedia: false),
          fetcher: (String url) {
            fetched.add(url);
            return Future<Uint8List?>.value();
          },
        ),
      );
      await tester.pump();

      expect(fetched, isEmpty);
      expect(find.text('GIF — dotknij, aby wczytać'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('fetched bytes that are not a GIF never reach the decoder', (
    WidgetTester tester,
  ) async {
    final Uint8List png = img.encodePng(img.Image(width: 4, height: 4));
    await tester.pumpWidget(
      MaterialApp(
        home: ZenAnimatedImage(
          url: _peerGifUrl,
          fetcher: (String url) => Future<Uint8List?>.value(png),
          errorBuilder: (BuildContext context, Object error, StackTrace? st) =>
              const Text('zepsuty'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('zepsuty'), findsOneWidget);
  });

  group('isAcceptableRemoteGif', () {
    test('accepts a small GIF', () {
      expect(isAcceptableRemoteGif(_twoFrameGif()), isTrue);
    });

    test('rejects other formats and truncated data', () {
      expect(
        isAcceptableRemoteGif(img.encodePng(img.Image(width: 4, height: 4))),
        isFalse,
      );
      expect(
        isAcceptableRemoteGif(Uint8List.fromList('GIF89a'.codeUnits)),
        isFalse,
      );
    });

    test('rejects a GIF declaring a huge or empty canvas', () {
      final Uint8List huge = Uint8List.fromList(_twoFrameGif());
      huge[6] = 0x88; // width 5000, little-endian
      huge[7] = 0x13;
      expect(isAcceptableRemoteGif(huge), isFalse);

      final Uint8List empty = Uint8List.fromList(_twoFrameGif());
      empty[8] = 0;
      empty[9] = 0;
      expect(isAcceptableRemoteGif(empty), isFalse);
    });
  });
}
