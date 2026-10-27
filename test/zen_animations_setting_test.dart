import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_backdrop.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/animations_choice.dart';

void main() {
  late bool motionWas;

  setUp(() {
    motionWas = ZenMotion.enabled;
    ZenMotion.enabled = true;
  });

  tearDown(() => ZenMotion.enabled = motionWas);

  void systemAsksForLessMotion(WidgetTester tester, {required bool on}) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        FakeAccessibilityFeatures(disableAnimations: on);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }

  Widget app(AppAnimations mode, {bool shown = true}) => MaterialApp(
    theme: ZenTheme.forPalette(
      AppPalette.neon,
      AppSettings.defaultAccentTheme,
      Brightness.dark,
    ),
    builder: (BuildContext context, Widget? child) =>
        ZenMotionScope(mode: mode, child: child!),
    home: Scaffold(
      body: TickerMode(
        enabled: shown,
        child: Builder(
          builder: (BuildContext context) => ZenBackdropLayer(
            kind: ZenBackdrop.rain,
            colors: ZenColors.of(context),
          ),
        ),
      ),
    ),
  );

  group('the animations setting', () {
    test('is on by default, whatever the system says', () {
      expect(const AppSettings().animations, AppAnimations.always);
      expect(AppSettings.defaultAnimations, AppAnimations.always);
    });

    test('survives the json round trip, and a bad name falls back', () {
      for (final AppAnimations mode in AppAnimations.values) {
        expect(
          AppSettings.fromJson(
            AppSettings(animations: mode).toJson(),
          ).animations,
          mode,
        );
      }
      expect(
        AppSettings.fromJson(<String, dynamic>{
          'animations': 'noSuchMode',
        }).animations,
        AppAnimations.always,
      );
    });
  });

  group('the backdrop under the animations setting', () {
    testWidgets('"Włączone" ticks although the system asks for less motion', (
      WidgetTester tester,
    ) async {
      systemAsksForLessMotion(tester, on: true);
      await tester.pumpWidget(app(AppAnimations.always));
      await tester.pump();
      expect(ZenBackdropLayer.running, 1);
      expect(find.byKey(const Key('zen-backdrop-live')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(ZenBackdropLayer.running, 0);
    });

    testWidgets('"Włączone" still rests while the screen is hidden', (
      WidgetTester tester,
    ) async {
      systemAsksForLessMotion(tester, on: true);
      await tester.pumpWidget(app(AppAnimations.always, shown: false));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);
      expect(find.byKey(const Key('zen-backdrop-still')), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('"Zgodnie z systemem" stops with the system flag on and ticks '
        'with it off', (WidgetTester tester) async {
      systemAsksForLessMotion(tester, on: true);
      await tester.pumpWidget(app(AppAnimations.system));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);
      expect(find.byKey(const Key('zen-backdrop-still')), findsOneWidget);

      systemAsksForLessMotion(tester, on: false);
      await tester.pump();
      expect(ZenBackdropLayer.running, 1);

      await tester.pumpWidget(const SizedBox.shrink());
      expect(ZenBackdropLayer.running, 0);
    });

    testWidgets('"Wyłączone" never ticks', (WidgetTester tester) async {
      systemAsksForLessMotion(tester, on: false);
      await tester.pumpWidget(app(AppAnimations.off));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);
      expect(find.byKey(const Key('zen-backdrop-still')), findsOneWidget);

      systemAsksForLessMotion(tester, on: true);
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('changing the setting starts and stops it in place', (
      WidgetTester tester,
    ) async {
      systemAsksForLessMotion(tester, on: true);
      await tester.pumpWidget(app(AppAnimations.system));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);

      await tester.pumpWidget(app(AppAnimations.always));
      await tester.pump();
      expect(ZenBackdropLayer.running, 1);

      await tester.pumpWidget(app(AppAnimations.off));
      await tester.pump();
      expect(ZenBackdropLayer.running, 0);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('the setting as a question', () {
    testWidgets('shows the three choices and reports the picked one', (
      WidgetTester tester,
    ) async {
      AppAnimations shown = AppAnimations.always;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) =>
                  AnimationsChoice(
                    value: shown,
                    onChanged: (AppAnimations v) => setState(() => shown = v),
                  ),
            ),
          ),
        ),
      );
      for (final AppAnimations mode in AppAnimations.values) {
        expect(
          find.byKey(Key('settings-animations-${mode.name}')),
          findsOneWidget,
        );
      }
      expect(find.text(AppAnimations.always.description), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings-animations-off')));
      await tester.pump();
      expect(shown, AppAnimations.off);
      expect(find.text(AppAnimations.off.description), findsOneWidget);
    });

    testWidgets('the bound one saves the choice', (WidgetTester tester) async {
      final MemoryAppSettingsStore store = MemoryAppSettingsStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [appSettingsStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            home: Scaffold(body: AnimationsSettingChoice()),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('settings-animations-system')));
      await tester.pump();
      expect(
        container.read(appSettingsControllerProvider).animations,
        AppAnimations.system,
      );
      expect((await store.load())!.animations, AppAnimations.system);
    });
  });
}
