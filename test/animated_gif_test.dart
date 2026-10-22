import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/chat/presentation/animated_gif.dart';

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

Uint8List _bigGif({required int frames}) {
  final img.Image first = img.Image(width: 200, height: 200, numChannels: 4)
    ..frameDuration = 40;
  img.fill(first, color: img.ColorRgba8(255, 0, 0, 255));
  for (int i = 1; i < frames; i++) {
    final img.Image next = img.Image(width: 200, height: 200, numChannels: 4)
      ..frameDuration = 40;
    img.fill(next, color: img.ColorRgba8(0, 0, 255, 255));
    first.addFrame(next);
  }
  return img.encodeGif(first);
}

/// Lets the first frame decode and show.
Future<void> _firstFrame(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump();
    if (find.byType(RawImage).evaluate().isNotEmpty) {
      return;
    }
  }
}

/// Frames decoded while time goes on for about 0.7 s.
Future<int> _framesDecodedMeanwhile(WidgetTester tester) async {
  final int before = debugGifFramesDecoded;
  for (int i = 0; i < 12; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    await tester.pump(const Duration(milliseconds: 60));
  }
  return debugGifFramesDecoded - before;
}

void main() {
  final Uint8List twoFrames = _twoFrameGif();

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

  Future<Set<int>> watchFrames(WidgetTester tester) async {
    final Set<int> seen = <int>{};
    for (int i = 0; i < 12; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)),
      );
      await tester.pump(const Duration(milliseconds: 60));
      final Finder raw = find.byType(RawImage);
      if (raw.evaluate().isNotEmpty) {
        final ui.Image? frame = tester.widget<RawImage>(raw).image;
        if (frame != null) {
          seen.add(identityHashCode(frame));
        }
      }
    }
    return seen;
  }

  testWidgets('without autoplay a GIF waits on its first frame for a tap', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ZenAnimatedImage(
          bytes: _twoFrameGif(),
          width: 80,
          height: 80,
          autoplay: false,
        ),
      ),
    );
    expect((await watchFrames(tester)).length, 1);
    expect(find.byKey(const Key('gif-play')), findsOneWidget);

    await tester.tap(find.byKey(const Key('gif-play')));
    await tester.pump();
    expect(find.byKey(const Key('gif-play')), findsNothing);
    expect((await watchFrames(tester)).length, greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reduced motion keeps a GIF still until it is tapped', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: ZenAnimatedImage(bytes: _twoFrameGif(), width: 80, height: 80),
        ),
      ),
    );
    expect((await watchFrames(tester)).length, 1);
    expect(find.byKey(const Key('gif-play')), findsOneWidget);
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

  testWidgets('a GIF in a hidden tab decodes no frames until it is shown', (
    WidgetTester tester,
  ) async {
    Widget app({required bool shown}) => MaterialApp(
      home: TickerMode(
        enabled: shown,
        child: ZenAnimatedImage(
          key: const Key('gif'),
          bytes: twoFrames,
          width: 80,
          height: 80,
        ),
      ),
    );
    await tester.pumpWidget(app(shown: false));
    await _firstFrame(tester);
    expect(find.byType(RawImage), findsOneWidget, reason: 'first frame shown');
    expect(await _framesDecodedMeanwhile(tester), 0);

    await tester.pumpWidget(app(shown: true));
    expect(await _framesDecodedMeanwhile(tester), greaterThan(1));

    await tester.pumpWidget(app(shown: false));
    // At most the frame already being decoded.
    expect(await _framesDecodedMeanwhile(tester), lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a GIF stops while the app is not in front and goes on after', (
    WidgetTester tester,
  ) async {
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ZenAnimatedImage(bytes: twoFrames, width: 80, height: 80),
      ),
    );
    await _firstFrame(tester);
    expect(await _framesDecodedMeanwhile(tester), greaterThan(1));

    // In the background, behind other windows or hidden in the tray.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(await _framesDecodedMeanwhile(tester), lessThanOrEqualTo(1));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(await _framesDecodedMeanwhile(tester), greaterThan(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a GIF under another page decodes no frames', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: ZenAnimatedImage(bytes: twoFrames, width: 80, height: 80),
      ),
    );
    await _firstFrame(tester);
    unawaited(
      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('nad')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(await _framesDecodedMeanwhile(tester), lessThanOrEqualTo(1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a still GIF in a small box is decoded at the box size, and '
      'any GIF keeps its natural size on screen', (WidgetTester tester) async {
    Future<RawImage> shown(Uint8List gif) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ZenAnimatedImage(bytes: gif, width: 20, height: 20),
          ),
        ),
      );
      await _firstFrame(tester);
      return tester.widget<RawImage>(find.byType(RawImage));
    }

    final double ratio = tester.view.devicePixelRatio;
    final RawImage still = await shown(_bigGif(frames: 1));
    expect(still.image!.width, (20 * ratio).round());
    expect(still.image!.width / still.scale, closeTo(200, 1));
    await tester.pumpWidget(const SizedBox());

    // The engine decodes an animated image's frames at full size: then it
    // is shown at its natural size too, not blown up.
    final RawImage moving = await shown(_bigGif(frames: 2));
    expect(moving.image!.width, lessThanOrEqualTo(200));
    expect(moving.image!.width / moving.scale, closeTo(200, 1));
    await tester.pumpWidget(const SizedBox());
  });

  group('gifDecodeSize', () {
    test('never larger than the image', () {
      final ui.TargetImageSize size = gifDecodeSize(
        100,
        50,
        box: const Size(400, 400),
      );
      expect(size.width, isNull);
      expect(size.height, isNull);
    });

    test('covers the box (the shorter side fills it)', () {
      final ui.TargetImageSize size = gifDecodeSize(
        1000,
        500,
        box: const Size(100, 100),
      );
      expect(size.width, 200);
      expect(size.height, 100);
    });

    test('fits into the box with contain', () {
      final ui.TargetImageSize size = gifDecodeSize(
        1000,
        500,
        box: const Size(100, 100),
        fit: BoxFit.contain,
      );
      expect(size.width, 100);
      expect(size.height, 50);
    });

    test('an unknown box only caps the longest side at 1024', () {
      final ui.TargetImageSize size = gifDecodeSize(4000, 2000);
      expect(size.width, 1024);
      expect(size.height, 512);
      final ui.TargetImageSize tall = gifDecodeSize(
        800,
        1600,
        box: const Size(400, double.infinity),
      );
      expect(tall.width, 400);
      expect(tall.height, 800);
    });
  });
}
