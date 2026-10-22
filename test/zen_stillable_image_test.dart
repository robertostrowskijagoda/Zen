import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_ui.dart';

/// A stream whose frames the test hands in, telling whether anyone listens
/// (an animated image decodes frames only for listeners).
class _Frames extends ImageStreamCompleter {
  bool get listening => hasListeners;

  void show(ui.Image image) => setImage(ImageInfo(image: image));
}

class _Picture extends ImageProvider<_Picture> {
  _Picture(this.frames);

  final _Frames frames;

  @override
  Future<_Picture> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_Picture>(this);

  @override
  ImageStreamCompleter loadImage(_Picture key, ImageDecoderCallback decode) =>
      frames;
}

void main() {
  Widget avatar(_Picture picture, {bool shown = true, bool reduced = false}) =>
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: TickerMode(
            enabled: shown,
            child: Center(
              child: ZenBlobAvatar(name: 'Ada', image: picture),
            ),
          ),
        ),
      );

  testWidgets('a GIF avatar in a hidden tab rests on its first frame', (
    WidgetTester tester,
  ) async {
    final _Frames frames = _Frames();
    final _Picture picture = _Picture(frames);
    final ui.Image image = (await tester.runAsync(
      () => createTestImage(width: 4, height: 4),
    ))!;

    await tester.pumpWidget(avatar(picture, shown: false));
    expect(frames.listening, isTrue, reason: 'waits for something to show');

    frames.show(image);
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(frames.listening, isFalse, reason: 'no more frames decoded');

    await tester.pumpWidget(avatar(picture));
    expect(frames.listening, isTrue, reason: 'moves when seen');

    await tester.pumpWidget(avatar(picture, shown: false));
    expect(frames.listening, isFalse);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('"remove animations" keeps a GIF avatar on its first frame', (
    WidgetTester tester,
  ) async {
    final _Frames frames = _Frames();
    final _Picture picture = _Picture(frames);
    final ui.Image image = (await tester.runAsync(
      () => createTestImage(width: 4, height: 4),
    ))!;

    await tester.pumpWidget(avatar(picture, reduced: true));
    frames.show(image);
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(frames.listening, isFalse);

    await tester.pumpWidget(avatar(picture));
    expect(frames.listening, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('an avatar without a photo shows the initial', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: ZenBlobAvatar(name: 'ada')),
      ),
    );
    expect(find.text('A'), findsOneWidget);
    expect(find.byType(ZenStillableImage), findsNothing);
  });
}
