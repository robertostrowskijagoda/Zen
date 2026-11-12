import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/presentation/password_form_screen.dart';

import 'support/text_fit.dart';

// The strength word under the password ("Very strong" for what the
// generator makes) is never cut on the narrowest phone at the normal font
// size: it has a line of its own, not one shared with "Generate".
void main() {
  setUpAll(loadAppFonts);
  tearDown(ZenI18n.debugReset);

  for (final String code in <String>['en', 'pl', 'de', 'hu', 'fr', 'ru']) {
    testWidgets('the strength word fits at 320 dp ($code)', (
      WidgetTester tester,
    ) async {
      ZenI18n.debugUse(code, textFitStrings(code));
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            passwordVaultServiceProvider.overrideWithValue(
              PasswordVaultService(disk: MemoryLedgerDisk()),
            ),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: const PasswordFormScreen(),
          ),
        ),
      );
      await tester.pump();
      await tester.enterText(
        find.byKey(const Key('password-field-password')),
        'xK9#mQ2\$vL7!pR4&zT8wcN5@',
      );
      await tester.pump();
      expect(find.byKey(const Key('password-strength')), findsOneWidget);
      expect(find.byKey(const Key('password-generate')), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(truncatedTexts(tester), isEmpty, reason: 'texts cut at 320 dp');
    });
  }
}
