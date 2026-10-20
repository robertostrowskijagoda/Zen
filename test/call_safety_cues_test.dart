import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/call_safety_cues.dart';
import 'package:zen/src/features/calls/presentation/screen_share_guard.dart';

void main() {
  group('whole-screen warning', () {
    test('only Android before 14 warns', () {
      expect(
        screenShareNeedsWholeScreenWarning(isAndroid: true, androidSdkInt: 33),
        isTrue,
      );
      expect(
        screenShareNeedsWholeScreenWarning(isAndroid: true, androidSdkInt: 34),
        isFalse,
      );
      expect(
        screenShareNeedsWholeScreenWarning(
          isAndroid: true,
          androidSdkInt: null,
        ),
        isFalse,
      );
      expect(
        screenShareNeedsWholeScreenWarning(isAndroid: false, androidSdkInt: 30),
        isFalse,
      );
    });

    testWidgets('dialog on Android 13 can be confirmed or cancelled', (
      WidgetTester tester,
    ) async {
      screenShareIsAndroid = () => true;
      screenShareAndroidSdkReader = () async => 33;
      addTearDown(() {
        screenShareIsAndroid = () => false;
      });
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      final Future<bool> pending = confirmScreenShareStart(ctx);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('screen-share-whole-screen-warning')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('screen-share-warning-cancel')));
      await tester.pumpAndSettle();
      expect(await pending, isFalse);

      final Future<bool> again = confirmScreenShareStart(ctx);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('screen-share-warning-continue')));
      await tester.pumpAndSettle();
      expect(await again, isTrue);
    });

    testWidgets('no dialog on other platforms', (WidgetTester tester) async {
      screenShareIsAndroid = () => false;
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              ctx = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(await confirmScreenShareStart(ctx), isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });

  testWidgets('reminder banner states that everything is visible', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: ScreenShareReminderBanner(zen: ZenColors.of(context)),
          ),
        ),
      ),
    );
    expect(
      find.text(
        'Udostępniasz cały ekran — widać wszystko, także powiadomienia',
      ),
      findsOneWidget,
    );
  });

  test('recording tone is a valid two-beep WAV', () {
    final Uint8List wav = buildRecordingToneWav();
    expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
    final ByteData data = ByteData.sublistView(wav);
    expect(data.getUint32(4, Endian.little), wav.length - 8);
    expect(data.getUint32(40, Endian.little), wav.length - 44);
    // Silence in the gap, signal in the beeps.
    final int beep = 22050 * 180 ~/ 1000;
    final int gap = 22050 * 120 ~/ 1000;
    expect(data.getInt16(44 + (beep + gap ~/ 2) * 2, Endian.little), 0);
    expect(
      List<int>.generate(
        beep,
        (int i) => data.getInt16(44 + i * 2, Endian.little).abs(),
      ).reduce((int a, int b) => a > b ? a : b),
      greaterThan(10000),
    );
  });

  test('announceRecordingStartedWithTone calls the player', () {
    int played = 0;
    final Future<void> Function() original = callRecordingTonePlayer;
    callRecordingTonePlayer = () async => played++;
    addTearDown(() => callRecordingTonePlayer = original);
    announceRecordingStartedWithTone();
    expect(played, 1);
  });
}
