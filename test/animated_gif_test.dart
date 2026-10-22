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
}
