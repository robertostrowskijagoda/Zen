import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The "Łączenie…" dots of a call keep moving on a phone whose window is
/// on screen without the focus (Flutter on Android says "inactive" then: a
/// system dialog or the notification shade over it, split screen, an
/// overlay window), and stand still on a computer whose window is behind
/// others, as before.
void main() {
  late bool motionWas;

  setUp(() {
    motionWas = ZenMotion.enabled;
    ZenMotion.enabled = true;
  });

  tearDown(() => ZenMotion.enabled = motionWas);

  Widget dots() => const MaterialApp(
    home: ZenMotionScope(
      mode: AppAnimations.always,
      child: Scaffold(body: Center(child: ZenAnimatedDots())),
    ),
  );

  List<double> opacities(WidgetTester tester) => tester
      .widgetList<Opacity>(
        find.descendant(
          of: find.byType(ZenAnimatedDots),
          matching: find.byType(Opacity),
        ),
      )
      .map((Opacity o) => o.opacity)
      .toList();

  /// Some real time for the clock's stopwatch, then the clock's ticks.
  Future<void> wait(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 350)),
    );
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('on a phone the dots move while the window has no focus', (
    WidgetTester tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(dots());
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(ZenMotion.clockRunning, isTrue);
    final List<double> before = opacities(tester);
    await wait(tester);
    final List<double> after = opacities(tester);
    expect(after, hasLength(3));
    expect(after, isNot(equals(before)));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    expect(ZenMotion.clockRunning, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(ZenMotion.clockRunning, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('a computer window behind others still rests', (
    WidgetTester tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(dots());
    await tester.pump();
    expect(ZenMotion.clockRunning, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(ZenMotion.clockRunning, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox.shrink());
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
