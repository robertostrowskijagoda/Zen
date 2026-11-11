import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/resume_session.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/lock_mode_choice.dart';

/// "Automatyczna blokada": a choice that locks Zen later than now asks for
/// the app password first; one that locks it sooner does not.
void main() {
  const AppSettings fiveMinutes = AppSettings(
    lockMode: AppLockMode.background,
    backgroundLockDelaySeconds: 300,
  );

  test('what locks later', () {
    AppSettings mode(AppLockMode m) => fiveMinutes.copyWith(lockMode: m);
    final List<AppLockMode> order = <AppLockMode>[
      AppLockMode.background,
      AppLockMode.appClose,
      AppLockMode.systemRestart,
      AppLockMode.never,
    ];
    for (int i = 0; i < order.length; i++) {
      for (int j = 0; j < order.length; j++) {
        expect(
          locksLater(mode(order[i]), mode(order[j])),
          j > i,
          reason: '${order[i]} -> ${order[j]}',
        );
      }
    }
    expect(
      locksLater(
        fiveMinutes,
        fiveMinutes.copyWith(backgroundLockDelaySeconds: 900),
      ),
      isTrue,
    );
    expect(
      locksLater(
        fiveMinutes,
        fiveMinutes.copyWith(backgroundLockDelaySeconds: 60),
      ),
      isFalse,
    );
    final AppSettings kept = fiveMinutes.copyWith(keepUnlockedAfterClose: true);
    expect(locksLater(fiveMinutes, kept), isTrue);
    expect(locksLater(kept, fiveMinutes), isFalse);
    // Back from "Przy zamknięciu aplikacji" to a delay with the key kept
    // after closing: closing no longer locks at once.
    expect(
      locksLater(kept.copyWith(lockMode: AppLockMode.appClose), kept),
      isTrue,
    );
    expect(
      locksLater(
        fiveMinutes.copyWith(lockMode: AppLockMode.appClose),
        fiveMinutes,
      ),
      isFalse,
    );
  });

  group('the lock choice', () {
    late MemoryAppSecurityService security;
    late ProviderContainer container;

    Future<void> pump(
      WidgetTester tester, {
      AppSettings settings = fiveMinutes,
      bool password = true,
      bool confirmsLaterLock = true,
      ZenAccountScope? account,
    }) async {
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      int sinceBoot = 3 * 60 * 60 * 1000;
      security = MemoryAppSecurityService(
        settings: settings,
        passwordIterations: 10,
        resumeVault: ClockResumeSessionVault(
          sinceBootMillis: () => sinceBoot++,
          screenLock: () async => true,
        ),
      );
      if (password) {
        await security.setPassword('sekret12');
      }
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...buildAppSettingsProviderOverrides(
              store: MemoryAppSettingsStore(),
              initialState: settings,
              hydrationEnabled: false,
            ),
            appSecurityServiceProvider.overrideWithValue(security),
            if (account != null) zenAccountProvider.overrideWithValue(account),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LockModeSettingChoice(
                  confirmsLaterLock: confirmsLaterLock,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      container = ProviderScope.containerOf(
        tester.element(find.byType(LockModeSettingChoice)),
      );
    }

    AppSettings now() => container.read(appSettingsControllerProvider);
    final Finder dialog = find.byKey(const Key('sensitive-access-dialog'));

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(Key(key)));
      await tester.pumpAndSettle();
    }

    Future<void> confirmWith(WidgetTester tester, String password) async {
      await tester.enterText(
        find.byKey(const Key('sensitive-access-password')),
        password,
      );
      await tester.tap(find.byKey(const Key('sensitive-access-confirm')));
      await tester.pumpAndSettle();
    }

    testWidgets('a later lock asks for the app password first; cancelled or '
        'wrong, nothing changes', (WidgetTester tester) async {
      await pump(tester);
      await tap(tester, 'settings-lock-mode-systemRestart');
      expect(dialog, findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(now().lockMode, AppLockMode.background);

      await tap(tester, 'settings-lock-mode-appClose');
      await confirmWith(tester, 'zle-haslo');
      expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(now().lockMode, AppLockMode.background);

      await tap(tester, 'settings-lock-mode-appClose');
      await confirmWith(tester, 'sekret12');
      expect(dialog, findsNothing);
      expect(now().lockMode, AppLockMode.appClose);
    });

    testWidgets('a longer delay asks, a shorter one does not', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      await tap(tester, 'settings-lock-delay-60');
      expect(dialog, findsNothing);
      expect(now().backgroundLockDelaySeconds, 60);
      await tap(tester, 'settings-lock-delay-3600');
      expect(dialog, findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(now().backgroundLockDelaySeconds, 60);
    });

    testWidgets('where the question is off (the setup of a first start) a '
        'later lock and a longer delay apply at once; "Nigdy" still takes '
        'the password', (WidgetTester tester) async {
      await pump(tester, confirmsLaterLock: false);
      await tap(tester, 'settings-lock-delay-3600');
      expect(dialog, findsNothing);
      expect(now().backgroundLockDelaySeconds, 3600);
      await tap(tester, 'settings-lock-mode-systemRestart');
      expect(dialog, findsNothing);
      expect(now().lockMode, AppLockMode.systemRestart);

      await tap(tester, 'settings-lock-mode-never');
      expect(
        find.byKey(const Key('settings-never-lock-dialog')),
        findsOneWidget,
      );
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(now().lockMode, AppLockMode.systemRestart);
    });

    testWidgets('a sooner lock needs no password', (WidgetTester tester) async {
      await pump(
        tester,
        settings: fiveMinutes.copyWith(lockMode: AppLockMode.systemRestart),
      );
      await tap(tester, 'settings-lock-mode-appClose');
      expect(dialog, findsNothing);
      expect(now().lockMode, AppLockMode.appClose);
      await tap(tester, 'settings-lock-mode-background');
      expect(dialog, findsNothing);
      expect(now().lockMode, AppLockMode.background);
    });

    testWidgets('keeping the key after closing asks; letting it go does not', (
      WidgetTester tester,
    ) async {
      await pump(tester);
      final Finder toggle = find.byKey(
        const Key('settings-lock-keep-after-close'),
      );
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      await confirmWith(tester, 'sekret12');
      expect(now().keepUnlockedAfterClose, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(dialog, findsNothing);
      expect(now().keepUnlockedAfterClose, isFalse);
    });

    testWidgets('"Nigdy" on an additional account asks for the password', (
      WidgetTester tester,
    ) async {
      await pump(
        tester,
        account: ZenAccountScope.derive('TEST-ACCOUNT', Uint8List(32)),
      );
      await tap(tester, 'settings-lock-mode-never');
      expect(dialog, findsOneWidget);
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(now().lockMode, AppLockMode.background);
    });

    testWidgets('without an app password there is nothing to ask', (
      WidgetTester tester,
    ) async {
      await pump(tester, password: false);
      await tap(tester, 'settings-lock-mode-systemRestart');
      expect(dialog, findsNothing);
      expect(now().lockMode, AppLockMode.systemRestart);
    });
  });
}
