import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/calls/presentation/call_floating_overlay.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
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

  testWidgets('Android: the whole window stays protected while the setting '
      'is on, the lock screen and the chat list included', (
    WidgetTester tester,
  ) async {
    SecureWindow.lastApplied = false;
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(home: SecureAppWindow(child: Text('lista'))),
      ),
    );
    await tester.pump();
    expect(SecureWindow.lastApplied, isTrue);

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.text('lista')),
    );
    await container
        .read(appSettingsControllerProvider.notifier)
        .setSecureScreens(false);
    await tester.pump();
    expect(SecureWindow.lastApplied, isFalse);

    await container
        .read(appSettingsControllerProvider.notifier)
        .setSecureScreens(true);
    await tester.pump();
    expect(SecureWindow.lastApplied, isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(SecureWindow.lastApplied, isFalse);
  });

  testWidgets(
    'computers: only the protected screens are kept out of captures',
    (WidgetTester tester) async {
      SecureWindow.lastApplied = false;
      final ValueNotifier<bool> open = ValueNotifier<bool>(false);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: SecureAppWindow(
              child: ValueListenableBuilder<bool>(
                valueListenable: open,
                builder: (BuildContext context, bool on, Widget? _) => on
                    ? const SecureScreen(child: Text('rozmowa'))
                    : const Text('lista'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(SecureWindow.lastApplied, isFalse);
      open.value = true;
      await tester.pump();
      expect(SecureWindow.lastApplied, isTrue);
      open.value = false;
      await tester.pump();
      expect(SecureWindow.lastApplied, isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
