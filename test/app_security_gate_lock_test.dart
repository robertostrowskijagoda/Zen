import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/resume_session.dart';
import 'package:zen/src/features/security/secure_screen.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

/// The background lock comes by itself, and a computer locks when
/// nobody touches it. On Android the whole window stays protected.
void main() {
  Future<MemoryAppSecurityService> pumpGate(
    WidgetTester tester, {
    AppLockMode mode = AppLockMode.background,
    int delay = 30,
  }) async {
    final AppSettings settings = AppSettings(
      lockMode: mode,
      backgroundLockDelaySeconds: delay,
    );
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      settings: settings,
      hasPassword: true,
      passwordIterations: 10,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(settings),
          ),
          appSecurityServiceProvider.overrideWithValue(security),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(security.isLocked, isFalse);
    return security;
  }

  void leave(WidgetTester tester) {
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.paused);
  }

  Future<void> comeBack(WidgetTester tester) async {
    tester.binding
      ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
      ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
      ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
  }

  testWidgets('the app locks in the background once the delay is over, '
      'without coming back first', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await pumpGate(tester);
    leave(tester);
    await tester.pump(const Duration(seconds: 29));
    expect(security.isLocked, isFalse);
    await tester.pump(const Duration(seconds: 2));
    expect(security.isLocked, isTrue);

    await comeBack(tester);
    expect(find.byKey(const Key('app-unlock-password-field')), findsOneWidget);
    expect(find.text('aplikacja'), findsNothing);
  });

  testWidgets("the small buttons under the password keep the app's font (a "
      "button's own text style would put the phone's font there)", (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await pumpGate(tester);
    security.lock();
    await tester.pump();
    final String? family = tester
        .widget<RichText>(
          find
              .descendant(
                of: find.byKey(const Key('app-unlock-password-field')),
                matching: find.byType(RichText),
              )
              .first,
        )
        .text
        .style
        ?.fontFamily;
    expect(family, isNotNull);
    for (final String key in <String>[
      'app-unlock-forgot-button',
      'app-unlock-other-account',
    ]) {
      final RichText text = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(RichText),
        ),
      );
      expect(text.text.style?.fontFamily, family, reason: key);
      expect(text.text.style?.fontSize, 12.5, reason: key);
    }
  });

  testWidgets('coming back in time stops the countdown', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await pumpGate(tester);
    leave(tester);
    await tester.pump(const Duration(seconds: 20));
    await comeBack(tester);
    await tester.pump(const Duration(minutes: 5));
    expect(security.isLocked, isFalse);
    expect(find.text('aplikacja'), findsOneWidget);
  });

  testWidgets('"Nie blokuj od razu po zamknięciu aplikacji": the key waits '
      'sealed while Zen is away, and goes when it is back or locked', (
    WidgetTester tester,
  ) async {
    const AppSettings settings = AppSettings(
      lockMode: AppLockMode.background,
      backgroundLockDelaySeconds: 30,
      keepUnlockedAfterClose: true,
    );
    final MemorySecurityCredentialsStore credentials =
        MemorySecurityCredentialsStore();
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      settings: settings,
      credentialsStore: credentials,
      hasPassword: true,
      passwordIterations: 10,
      resumeVault: ClockResumeSessionVault(
        sinceBootMillis: () => 60 * 60 * 1000,
        now: () => DateTime.utc(2026, 10, 28, 12),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(settings),
          ),
          appSecurityServiceProvider.overrideWithValue(security),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pump();
    Future<String?> kept() =>
        credentials.read(appSecurityResumeSessionStorageKey);

    expect(await kept(), isNull);
    leave(tester);
    await tester.pump();
    expect(await kept(), isNotNull);
    await comeBack(tester);
    await tester.pump();
    expect(await kept(), isNull);
    expect(security.isLocked, isFalse);

    leave(tester);
    await tester.pump();
    expect(await kept(), isNotNull);
    await tester.pump(const Duration(seconds: 31));
    expect(security.isLocked, isTrue);
    await tester.pump();
    expect(await kept(), isNull);
  });

  testWidgets('other lock modes do not lock in the background', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await pumpGate(
      tester,
      mode: AppLockMode.appClose,
    );
    leave(tester);
    await tester.pump(const Duration(hours: 2));
    expect(security.isLocked, isFalse);
    await comeBack(tester);
  });

  testWidgets('"Nigdy": leaving the app, coming back or closing it never '
      'locks', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await pumpGate(
      tester,
      mode: AppLockMode.never,
    );
    leave(tester);
    await tester.pump(const Duration(hours: 5));
    expect(security.isLocked, isFalse);
    await comeBack(tester);
    expect(security.isLocked, isFalse);
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.detached);
    await tester.pump();
    expect(security.isLocked, isFalse);
    expect(find.text('aplikacja'), findsOneWidget);
  });

  group('a cold start with a password', () {
    const AppSettings never = AppSettings(lockMode: AppLockMode.never);

    Future<void> pumpStarted(
      WidgetTester tester,
      AppSecurityService security,
      AppSettings settings,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(settings),
            ),
            appSecurityServiceProvider.overrideWithValue(security),
          ],
          child: MaterialApp(
            theme: ZenTheme.dark(),
            builder: (BuildContext context, Widget? child) =>
                AppSecurityGate(child: child!),
            home: const Scaffold(body: Text('aplikacja')),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('"Nigdy" with the key kept opens without the password', (
      WidgetTester tester,
    ) async {
      final MemorySecurityCredentialsStore store =
          MemorySecurityCredentialsStore();
      final LocalAppSecurityService first = LocalAppSecurityService(
        credentialsStore: store,
        passwordIterations: 10,
      );
      await tester.runAsync(() async {
        await first.initialize(settings: const AppSettings());
        await first.setPassword('haslo-do-testu');
        await first.applySettings(never);
        expect(await first.keepMasterKeyForNeverLock('haslo-do-testu'), isTrue);
      });

      final LocalAppSecurityService restarted = LocalAppSecurityService(
        credentialsStore: store,
        passwordIterations: 10,
      );
      await tester.runAsync(() => restarted.initialize(settings: never));
      expect(restarted.isLocked, isFalse);

      await pumpStarted(tester, restarted, never);
      expect(find.text('aplikacja'), findsOneWidget);
      expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);

      // Locked by hand: the lock screen, with the panic password there,
      // once the kept copy is gone.
      restarted.lock();
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('app-unlock-password-field')),
        findsOneWidget,
      );
    });

    testWidgets('another mode, or "Nigdy" without the key kept, asks for '
        'it: the password is what opens the data key', (
      WidgetTester tester,
    ) async {
      final MemorySecurityCredentialsStore store =
          MemorySecurityCredentialsStore();
      final LocalAppSecurityService first = LocalAppSecurityService(
        credentialsStore: store,
        passwordIterations: 10,
      );
      await tester.runAsync(() async {
        await first.initialize(settings: const AppSettings());
        await first.setPassword('haslo-do-testu');
        await first.applySettings(never);
        expect(await first.keepMasterKeyForNeverLock('haslo-do-testu'), isTrue);
        // Leaving "Nigdy" drops the copy.
        await first.applySettings(const AppSettings());
      });

      for (final AppSettings settings in <AppSettings>[
        never,
        const AppSettings(),
      ]) {
        final LocalAppSecurityService restarted = LocalAppSecurityService(
          credentialsStore: store,
          passwordIterations: 10,
        );
        await tester.runAsync(() => restarted.initialize(settings: settings));
        // The master key exists on disk only wrapped by the password:
        // without it (or the hardware-sealed copy) there is nothing to open
        // the data with.
        expect(restarted.isLocked, isTrue);
        expect(await restarted.currentEncryptionKey(), isNull);

        await pumpStarted(tester, restarted, settings);
        expect(
          find.byKey(const Key('app-unlock-password-field')),
          findsOneWidget,
        );
        expect(find.text('aplikacja'), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    });
  });

  testWidgets(
    'a computer locks after the delay without a key press or the mouse',
    (WidgetTester tester) async {
      final MemoryAppSecurityService security = await pumpGate(tester);
      await tester.pump(const Duration(seconds: 20));
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(seconds: 20));
      expect(security.isLocked, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump(const Duration(seconds: 29));
      expect(security.isLocked, isFalse);
      await tester.pump(const Duration(seconds: 2));
      expect(security.isLocked, isTrue);
      await tester.pump();
      expect(
        find.byKey(const Key('app-unlock-password-field')),
        findsOneWidget,
      );
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets('no idle lock without the "after leaving the app" mode', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await pumpGate(
      tester,
      mode: AppLockMode.never,
    );
    await tester.pump(const Duration(hours: 2));
    expect(security.isLocked, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('a call on screen holds the idle lock off', (
    WidgetTester tester,
  ) async {
    final MemoryAppSecurityService security = await pumpGate(tester);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.text('aplikacja')),
    );
    container.read(callSurfaceActiveProvider.notifier).setActive(true);
    await tester.pump(const Duration(minutes: 5));
    expect(security.isLocked, isFalse);
    container.read(callSurfaceActiveProvider.notifier).setActive(false);
    await tester.pump(const Duration(seconds: 31));
    expect(security.isLocked, isTrue);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  testWidgets('no idle lock on a phone', (WidgetTester tester) async {
    final MemoryAppSecurityService security = await pumpGate(tester);
    await tester.pump(const Duration(hours: 2));
    expect(security.isLocked, isFalse);
  });

  testWidgets('the window allows captures: a start lifts any protection an '
      'older version left, and no screen puts it back', (
    WidgetTester tester,
  ) async {
    SecureWindow.lastApplied = true;
    await tester.pumpWidget(
      const MaterialApp(
        home: SecureAppWindow(child: SecureScreen(child: Text('rozmowa'))),
      ),
    );
    await tester.pump();
    expect(SecureWindow.lastApplied, isFalse);
    expect(find.text('rozmowa'), findsOneWidget);
  });
}
