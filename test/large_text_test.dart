import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/about/presentation/about_screen.dart';

import 'support/text_fit.dart';

/// Large text (the system font size at 200 %): the shell, the settings, the
/// chats list, the Tablica and "O aplikacji" lay out without a row or a
/// column overflowing. Texts may wrap or, for one-line titles, shorten.

/// The text size checked: twice the normal.
const double kLargeTextScale = 2;

/// A common phone width.
const double kLargeTextWidth = 360;

final List<TextFitScreen> largeTextScreens = <TextFitScreen>[
  TextFitScreen(
    'shell and the chats list',
    height: 800,
    open: (WidgetTester tester) => pumpShellForFit(tester),
  ),
  TextFitScreen(
    'the Tablica',
    height: 1600,
    open: (WidgetTester tester) async {
      await pumpShellForFit(tester);
      await tester.tap(find.byKey(const Key('side-tab-feed')));
      await pumpFrames(tester);
    },
  ),
  TextFitScreen(
    'settings',
    height: 6000,
    open: (WidgetTester tester) async {
      await pumpShellForFit(tester);
      await tester.tap(find.byKey(const Key('chats-status-chip')));
      await pumpFrames(tester);
    },
  ),
  TextFitScreen(
    'about',
    height: 3000,
    open: (WidgetTester tester) => pumpAboutForFit(tester),
  ),
  for (final AboutSection section in AboutSection.values)
    TextFitScreen(
      'about: ${section.name}',
      height: 6000,
      open: (WidgetTester tester) async {
        await pumpAboutForFit(tester);
        await tester.tap(find.byKey(Key('about-section-${section.name}')));
        await pumpFrames(tester);
      },
    ),
];

void main() {
  setUpAll(loadAppFonts);
  tearDown(ZenI18n.debugReset);

  // Polish (the texts of the code) and German (among the longest).
  for (final String code in <String>['pl', 'de']) {
    group('in "$code"', () {
      setUpAll(() async {
        if (code != 'pl') {
          await initializeDateFormatting(code);
        }
      });

      for (final TextFitScreen screen in largeTextScreens) {
        testWidgets('${screen.name}: no overflow with text at '
            '${(kLargeTextScale * 100).round()} %', (
          WidgetTester tester,
        ) async {
          ZenI18n.debugUse(code, textFitStrings(code));
          tester.view.physicalSize = Size(kLargeTextWidth, screen.height);
          tester.view.devicePixelRatio = 1;
          tester.platformDispatcher.textScaleFactorTestValue = kLargeTextScale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

          await screen.open(tester);

          final Object? overflow = tester.takeException();
          expect(overflow, isNull, reason: '${screen.name} ($code): $overflow');
          // The text really is large here.
          expect(
            MediaQuery.textScalerOf(
              tester.element(find.byType(Scaffold).first),
            ).scale(10),
            closeTo(10 * kLargeTextScale, 0.01),
          );

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(settleAsync);
        });
      }
    });
  }
}
