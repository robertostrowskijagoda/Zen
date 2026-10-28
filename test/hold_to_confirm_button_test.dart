import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/security/hold_to_confirm_button.dart';

void main() {
  int confirmed = 0;

  setUp(() => confirmed = 0);

  Future<void> pumpButton(
    WidgetTester tester, {
    bool enabled = true,
    bool autofocus = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: Center(
            child: HoldToConfirmButton(
              idleLabel: 'Przytrzymaj',
              holdingLabel: (int seconds) => 'Jeszcze $seconds s',
              onConfirmed: () => confirmed++,
              enabled: enabled,
              autofocus: autofocus,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  double ring(WidgetTester tester) => tester
      .widget<CircularProgressIndicator>(
        find.byKey(const Key('hold-to-confirm-progress')),
      )
      .value!;

  testWidgets('holding for the whole ten seconds confirms once', (
    WidgetTester tester,
  ) async {
    await pumpButton(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 9900));
    expect(confirmed, 0);
    expect(ring(tester), closeTo(0.99, 0.001));
    expect(find.text('Jeszcze 1 s'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100));
    expect(confirmed, 1);
    expect(ring(tester), 1);
    await gesture.up();
    await tester.pump(const Duration(seconds: 20));
    expect(confirmed, 1);
  });

  testWidgets('letting go early cancels and the ring empties', (
    WidgetTester tester,
  ) async {
    await pumpButton(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(ring(tester), closeTo(0.9, 0.001));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(ring(tester), 0);
    expect(find.text('Przytrzymaj'), findsOneWidget);

    // Holding again starts from nothing: nine more seconds are not enough.
    final TestGesture again = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(confirmed, 0);
    await again.up();
    await tester.pump(const Duration(seconds: 20));
    expect(confirmed, 0);
  });

  testWidgets('a cancelled touch cancels too', (WidgetTester tester) async {
    await pumpButton(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    await gesture.cancel();
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(confirmed, 0);
    expect(ring(tester), 0);
  });

  testWidgets('a disabled button does not count', (WidgetTester tester) async {
    await pumpButton(tester, enabled: false);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));
    expect(confirmed, 0);
    expect(ring(tester), 0);
    await gesture.up();
  });

  testWidgets('holding Enter works like holding the button', (
    WidgetTester tester,
  ) async {
    await pumpButton(tester, autofocus: true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(confirmed, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(confirmed, 1);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
  });

  testWidgets('releasing Space early cancels', (WidgetTester tester) async {
    await pumpButton(tester, autofocus: true);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(ring(tester), closeTo(0.5, 0.001));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.space);
    await tester.pump();
    await tester.pump(const Duration(seconds: 20));
    expect(confirmed, 0);
    expect(ring(tester), 0);
  });

  testWidgets('animations turned off do not shorten the ten seconds', (
    WidgetTester tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await pumpButton(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(HoldToConfirmButton)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    expect(confirmed, 0);
    expect(ring(tester), closeTo(0.9, 0.001));
    await tester.pump(const Duration(seconds: 1));
    expect(confirmed, 1);
    await gesture.up();
  });
}
