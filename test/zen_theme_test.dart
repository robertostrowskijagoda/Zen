import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_concept.dart';
import 'package:zen/src/app/theme/zen_motion.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  group('ZenTheme & ZenColors', () {
    test('all presets resolve in dark and light modes with valid colors', () {
      for (final AppAccentTheme accent in AppAccentTheme.values) {
        final ZenColors darkColors = ZenColors.resolve(accent, Brightness.dark);
        expect(darkColors.background, isNotNull);
        expect(darkColors.surface, isNotNull);
        expect(darkColors.surfaceRaised, isNotNull);
        expect(darkColors.textPrimary, isNotNull);
        expect(darkColors.outline, isNotNull);

        final ZenColors lightColors = ZenColors.resolve(
          accent,
          Brightness.light,
        );
        expect(lightColors.background, isNotNull);
        expect(lightColors.surface, isNotNull);
        expect(lightColors.surfaceRaised, isNotNull);
        expect(lightColors.textPrimary, isNotNull);
        expect(lightColors.outline, isNotNull);

        final ThemeData darkTheme = ZenTheme.dark(accent);
        expect(darkTheme.brightness, Brightness.dark);

        final ThemeData lightTheme = ZenTheme.light(accent);
        expect(lightTheme.brightness, Brightness.light);
      }
    });

    test('accent foreground stays readable on every accent', () {
      double contrast(Color a, Color b) {
        final double la = a.computeLuminance();
        final double lb = b.computeLuminance();
        final double lighter = la > lb ? la : lb;
        final double darker = la > lb ? lb : la;
        return (lighter + 0.05) / (darker + 0.05);
      }

      for (final AppAccentTheme accent in AppAccentTheme.values) {
        for (final Brightness brightness in Brightness.values) {
          final ZenColors colors = ZenColors.resolve(accent, brightness);
          // Filled buttons paint onAccent on top of accent; anything under
          // 4.5:1 is the "invisible label" bug.
          expect(
            contrast(colors.accent, colors.onAccent),
            greaterThanOrEqualTo(4.5),
            reason: '$accent / $brightness accent vs onAccent',
          );
          // Accent-tinted text and icons sit on the card surface.
          expect(
            contrast(colors.accent, colors.surface),
            greaterThanOrEqualTo(2.0),
            reason: '$accent / $brightness accent vs surface',
          );
          expect(
            contrast(colors.textPrimary, colors.background),
            greaterThanOrEqualTo(4.5),
            reason: '$accent / $brightness text vs background',
          );
          expect(
            contrast(colors.textSecondary, colors.surface),
            greaterThanOrEqualTo(3.0),
            reason: '$accent / $brightness secondary text vs surface',
          );
        }
      }
    });

    test('every palette keeps its contrast in both modes', () {
      double contrast(Color a, Color b) {
        final double la = a.computeLuminance();
        final double lb = b.computeLuminance();
        final double lighter = la > lb ? la : lb;
        final double darker = la > lb ? lb : la;
        return (lighter + 0.05) / (darker + 0.05);
      }

      for (final AppPalette palette in AppPalette.values) {
        for (final Brightness brightness in Brightness.values) {
          final ZenColors colors = ZenColors.forPalette(
            palette,
            AppSettings.defaultAccentTheme,
            brightness,
          );
          final String where = '$palette / $brightness';
          expect(
            ThemeData.estimateBrightnessForColor(colors.background),
            brightness,
            reason: '$where background',
          );
          expect(
            contrast(colors.accent, colors.onAccent),
            greaterThanOrEqualTo(4.5),
            reason: '$where accent vs onAccent',
          );
          expect(
            contrast(colors.accent, colors.surface),
            greaterThanOrEqualTo(2.0),
            reason: '$where accent vs surface',
          );
          expect(
            contrast(colors.textPrimary, colors.background),
            greaterThanOrEqualTo(4.5),
            reason: '$where text vs background',
          );
          expect(
            contrast(colors.textSecondary, colors.surface),
            greaterThanOrEqualTo(3.0),
            reason: '$where secondary text vs surface',
          );
          expect(colors.concept, palette != AppPalette.classic);
          expect(
            ZenTheme.dark(AppSettings.defaultAccentTheme, palette),
            isA<ThemeData>(),
          );
          expect(
            ZenTheme.light(AppSettings.defaultAccentTheme, palette),
            isA<ThemeData>(),
          );
        }
      }
    });

    test('Klasyczny stays the accent theme it was', () {
      for (final Brightness brightness in Brightness.values) {
        final ZenColors classic = ZenColors.forPalette(
          AppPalette.classic,
          AppAccentTheme.aurora,
          brightness,
        );
        final ZenColors accent = ZenColors.resolve(
          AppAccentTheme.aurora,
          brightness,
        );
        expect(classic.accent, accent.accent);
        expect(classic.background, accent.background);
        expect(classic.concept, isFalse);
        expect(classic.glow, 0);
        expect(classic.gradient, 1);
      }
      final ThemeData theme = ZenTheme.dark();
      expect(theme.splashFactory, InkRipple.splashFactory);
      expect(theme.tabBarTheme.indicator, isNull);
    });

    testWidgets('only neon glows, and the pulse stands still in tests', (
      WidgetTester tester,
    ) async {
      final ZenColors neon = ZenColors.forPalette(
        AppPalette.neon,
        AppSettings.defaultAccentTheme,
        Brightness.dark,
      );
      expect(neon.neonGlow(neon.accent), isNotEmpty);
      expect(
        ZenColors.forPalette(
          AppPalette.calm,
          AppSettings.defaultAccentTheme,
          Brightness.dark,
        ).neonGlow(neon.accent),
        isNull,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ZenTheme.dark(AppSettings.defaultAccentTheme, AppPalette.neon),
          home: const Scaffold(
            body: DefaultTabController(
              length: 2,
              child: Column(
                children: <Widget>[
                  TabBar(
                    tabs: <Widget>[
                      Tab(text: 'A'),
                      Tab(text: 'B'),
                    ],
                  ),
                  ZenSoftPulse(color: Colors.cyan, child: Text('3')),
                  TextField(autofocus: true),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ZenMotion widgets build without error', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                ZenAnimatedDots(size: 4),
                ZenPulsingDot(color: Colors.green),
                ZenPulseRings(color: Colors.blue, child: Icon(Icons.phone)),
                ZenFadeSlide(child: Text('Motion')),
                ZenNeonFlicker(color: Colors.amber, child: Text('Neon')),
                ZenPressable(child: Text('Pressable')),
                ZenNeonGlitchText(text: 'Glitch'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Motion'), findsOneWidget);
      expect(find.text('Neon'), findsOneWidget);
      expect(find.text('Pressable'), findsOneWidget);
      expect(find.text('Glitch'), findsOneWidget);
    });

    testWidgets('motion widgets run their live waveforms without error', (
      WidgetTester tester,
    ) async {
      // The rest of the suite runs with motion off, which means the perpetual
      // animations never execute. Flip it on for one test so the waveform
      // maths (randomised speeds, echo beats, flicker bursts) is covered.
      final bool previous = ZenMotion.enabled;
      ZenMotion.enabled = true;
      addTearDown(() => ZenMotion.enabled = previous);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                ZenAnimatedDots(size: 4, dotCount: 4),
                ZenPulsingDot(color: Colors.green),
                ZenPulseRings(
                  ringCount: 3,
                  color: Colors.blue,
                  child: Icon(Icons.phone),
                ),
                ZenNeonFlicker(color: Colors.amber, child: Text('Neon')),
                ZenNeonGlitchText(
                  text: 'GLITCH',
                  minQuietSeconds: 0,
                  maxQuietSeconds: 1,
                ),
              ],
            ),
          ),
        ),
      );

      // Walk a few seconds of animation frame by frame; anything that produced
      // a NaN or an out-of-range opacity would throw here.
      for (int frame = 0; frame < 240; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('Neon'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Unmount so no perpetual ticker or flicker timer outlives the test.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('CallFloatingOverlay renders child when no active call', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: CallFloatingOverlay(child: Text('Main Screen Content')),
            ),
          ),
        ),
      );

      expect(find.text('Main Screen Content'), findsOneWidget);
    });
  });
}
