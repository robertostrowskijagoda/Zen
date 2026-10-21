import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_palettes.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_theme_picker.dart';
import 'package:zen/src/features/settings/app_settings.dart';

Future<List<AppPalette>> _pumpPicker(
  WidgetTester tester, {
  required AppPalette current,
  required Brightness brightness,
}) async {
  tester.view.physicalSize = const Size(412 * 3, 1800 * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  final List<AppPalette> picked = <AppPalette>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: ZenTheme.forPalette(
        current,
        AppSettings.defaultAccentTheme,
        brightness,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ZenThemePicker(
            selected: current,
            accent: AppSettings.defaultAccentTheme,
            brightness: brightness,
            onSelect: picked.add,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return picked;
}

void main() {
  for (final Brightness brightness in Brightness.values) {
    testWidgets(
      'the picker shows every palette by group (${brightness.name})',
      (WidgetTester tester) async {
        await _pumpPicker(
          tester,
          current: AppPalette.classic,
          brightness: brightness,
        );
        for (final ZenThemeCategory category in ZenThemeCategory.values) {
          expect(
            find.byKey(Key('settings-palette-category-${category.name}')),
            findsOneWidget,
          );
          expect(find.text(category.label), findsOneWidget);
          for (final AppPalette p in category.palettes) {
            // The card sits inside its group.
            expect(
              find.descendant(
                of: find.byKey(
                  Key('settings-palette-category-${category.name}'),
                ),
                matching: find.byKey(Key('settings-palette-${p.name}')),
              ),
              findsOneWidget,
              reason: '$p',
            );
          }
        }
        // A live miniature for each palette, with still backdrops.
        expect(
          find.byType(ZenThemePreview),
          findsNWidgets(AppPalette.values.length),
        );
        expect(find.byKey(const Key('zen-backdrop-live')), findsNothing);
        expect(
          find.byKey(const Key('zen-backdrop-still')),
          findsNWidgets(
            AppPalette.values
                .where(
                  (AppPalette p) =>
                      ZenLook.forPalette(p).backdrop != ZenBackdrop.none,
                )
                .length,
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('one tap picks a palette', (WidgetTester tester) async {
    final List<AppPalette> picked = await _pumpPicker(
      tester,
      current: AppPalette.classic,
      brightness: Brightness.dark,
    );
    for (final AppPalette p in <AppPalette>[
      AppPalette.rain,
      AppPalette.onyx,
      AppPalette.player,
    ]) {
      final Finder card = find.byKey(Key('settings-palette-${p.name}'));
      await tester.ensureVisible(card);
      await tester.pump();
      await tester.tap(card);
      await tester.pump();
    }
    expect(picked, <AppPalette>[
      AppPalette.rain,
      AppPalette.onyx,
      AppPalette.player,
    ]);
  });

  testWidgets('the picker builds inside every look', (
    WidgetTester tester,
  ) async {
    for (final AppPalette p in AppPalette.values) {
      await _pumpPicker(tester, current: p, brightness: Brightness.light);
      // Exactly the current palette is marked.
      expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
      expect(tester.takeException(), isNull, reason: '$p');
    }
  });
}
