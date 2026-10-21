import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

import 'support/text_fit.dart';

/// Every text of a screen fits a 320 dp wide phone in every language Zen
/// speaks: no text ends cut ("…" or clipped after its last line) and no row
/// or column overflows. The screens are listed in [textFitScreens]
/// (test/support/text_fit.dart).
void main() {
  setUpAll(loadAppFonts);
  tearDown(ZenI18n.debugReset);

  for (final String code in textFitLanguages()) {
    group('in "$code"', () {
      setUpAll(() async {
        if (code != 'pl') {
          await initializeDateFormatting(code);
        }
      });

      for (final TextFitScreen screen in textFitScreens) {
        testWidgets('${screen.name}: nothing cut at $kNarrowestPhoneWidth dp', (
          WidgetTester tester,
        ) async {
          ZenI18n.debugUse(code, textFitStrings(code));
          tester.view.physicalSize = Size(kNarrowestPhoneWidth, screen.height);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);

          await screen.open(tester);

          final Object? overflow = tester.takeException();
          expect(overflow, isNull, reason: '${screen.name} ($code): $overflow');
          expect(
            truncatedTexts(tester),
            isEmpty,
            reason: '${screen.name} ($code): texts cut',
          );
          screen.check?.call(tester);

          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(settleAsync);
        });
      }
    });
  }
}
