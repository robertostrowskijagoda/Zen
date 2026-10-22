import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/unlock_throttle.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

/// The lock screen's way out when the password is gone ("Nie pamiętam
/// hasła — zacznij od nowa": hold for ten seconds, then everything on this
/// device is erased) and its throttling of password attempts.
void main() {
  late MemorySecurityCredentialsStore store;
  late LocalAppSecurityService security;
  late DateTime now;
  late int wipes;
  late Completer<void> wipeGate;

  const Key field = Key('app-unlock-password-field');
  const Key submit = Key('app-unlock-submit-button');
  const Key forgot = Key('app-unlock-forgot-button');
  const Key hold = Key('app-reset-hold-button');

  /// The gate over the current security service and storage (pumping it
  /// again is a restart of the lock screen, not of the credentials).
  Future<void> pumpGate(WidgetTester tester) async {
    const AppSettings settings = AppSettings();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(settings),
          ),
          appSecurityServiceProvider.overrideWithValue(security),
          unlockThrottleProvider.overrideWithValue(
            UnlockThrottle(
              store,
              now: () => now,
              monotonic: () => now.difference(DateTime.utc(2026)),
            ),
          ),
          // The real wipe needs the whole runtime; this one only erases the
          // credentials like it does and then waits to be let go.
          zenLocalDataResetProvider.overrideWithValue((WidgetRef ref) async {
            wipes++;
            await security.reset();
            await wipeGate.future;
          }),
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
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(field), findsOneWidget);
  }

  Future<void> pumpLocked(WidgetTester tester, {bool withPanic = false}) async {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    wipes = 0;
    wipeGate = Completer<void>();
    now = DateTime.utc(2026, 10, 21, 12);
    store = MemorySecurityCredentialsStore();
    security = LocalAppSecurityService(
      credentialsStore: store,
      passwordIterations: 10,
    );
    const AppSettings settings = AppSettings();
    await security.initialize(settings: settings);
    await security.setPassword('sekret12');
    if (withPanic) {
      await security.setPanicPassword('panika99');
    }
    security.lock();
    await pumpGate(tester);
  }

  Future<void> attempt(WidgetTester tester, String password) async {
    await tester.enterText(find.byKey(field), password);
    await tester.tap(find.byKey(submit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  bool submitEnabled(WidgetTester tester) =>
      tester.widget<ButtonStyleButton>(find.byKey(submit)).onPressed != null;

  Future<void> openForgot(WidgetTester tester) async {
    await tester.tap(find.byKey(forgot));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('app-reset-panel')), findsOneWidget);
  }

  testWidgets('the way out is on the lock screen and explains the cost', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester, withPanic: true);
    expect(find.text('Nie pamiętam hasła — zacznij od nowa'), findsOneWidget);
    await openForgot(tester);

    expect(find.textContaining('klucz konta, rozmowy, pliki'), findsOneWidget);
    // Every way the account comes back, by the names used elsewhere.
    expect(find.textContaining('z drugiego urządzenia'), findsOneWidget);
    expect(find.textContaining('kopii całego konta'), findsOneWidget);
    expect(find.textContaining('z kopii klucza'), findsOneWidget);
    expect(find.textContaining('kręgu odzyskiwania'), findsOneWidget);
    expect(find.textContaining('nie da się cofnąć'), findsOneWidget);
    // Nothing here tells whether a panic password exists.
    expect(find.textContaining('panic', findRichText: true), findsNothing);
    expect(find.textContaining('Panic', findRichText: true), findsNothing);

    await tester.tap(find.byKey(const Key('app-reset-back-button')));
    await tester.pump();
    expect(find.byKey(field), findsOneWidget);
    expect(wipes, 0);
  });

  testWidgets('letting go before ten seconds erases nothing', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester);
    await openForgot(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(hold)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 9));
    await gesture.up();
    await tester.pump(const Duration(seconds: 15));
    expect(wipes, 0);
    expect(security.hasPassword, isTrue);
    expect(find.byKey(const Key('app-reset-panel')), findsOneWidget);
  });

  testWidgets('holding for ten seconds erases the device and starts over', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester);
    await openForgot(tester);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byKey(hold)),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    await gesture.up();
    await tester.pump();
    expect(wipes, 1);

    // The keys are gone, the wipe is still going: the lock screen stays,
    // showing the progress, and does not let the old app through.
    expect(security.hasPassword, isFalse);
    expect(find.text('Usuwam dane z tego urządzenia…'), findsOneWidget);
    expect(find.text('aplikacja'), findsNothing);

    wipeGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(field), findsNothing);
    expect(find.text('aplikacja'), findsOneWidget);
  });

  testWidgets('the real password still opens the app after a cancelled reset', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester);
    await openForgot(tester);
    await tester.tap(find.byKey(const Key('app-reset-back-button')));
    await tester.pump();
    await attempt(tester, 'sekret12');
    expect(find.text('aplikacja'), findsOneWidget);
    expect(wipes, 0);
  });

  testWidgets('five wrong passwords start a wait that grows', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester);
    for (int i = 0; i < 4; i++) {
      await attempt(tester, 'zle-haslo');
      expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
      expect(submitEnabled(tester), isTrue);
    }
    await attempt(tester, 'zle-haslo');
    expect(find.byKey(const Key('app-unlock-wait-message')), findsOneWidget);
    expect(find.textContaining('0:30'), findsOneWidget);
    expect(submitEnabled(tester), isFalse);

    // The button stays shut for the whole wait.
    await tester.pump(const Duration(seconds: 29));
    expect(submitEnabled(tester), isFalse);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 2));
    expect(find.byKey(const Key('app-unlock-wait-message')), findsNothing);
    expect(submitEnabled(tester), isTrue);

    await attempt(tester, 'zle-haslo');
    expect(find.textContaining('1:00'), findsOneWidget);
    expect(submitEnabled(tester), isFalse);
  });

  testWidgets('attempts started together count one by one', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester);
    await tester.enterText(find.byKey(field), 'zle-haslo');
    // A second submit (Enter, a double tap) while the first one runs is
    // not a free extra guess.
    await tester.tap(find.byKey(submit));
    await tester.tap(find.byKey(submit));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      await store.read(appSecurityUnlockFailuresStorageKey),
      startsWith('1:'),
    );
  });

  testWidgets('the wait survives leaving the screen and the right password '
      'ends it', (WidgetTester tester) async {
    await pumpLocked(tester);
    for (int i = 0; i < 5; i++) {
      await attempt(tester, 'zle-haslo');
    }
    expect(submitEnabled(tester), isFalse);

    // As after a restart: a fresh lock screen over the same storage.
    await tester.pumpWidget(const SizedBox());
    await pumpGate(tester);
    expect(find.byKey(const Key('app-unlock-wait-message')), findsOneWidget);
    expect(submitEnabled(tester), isFalse);

    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 31));
    expect(submitEnabled(tester), isTrue);
    await attempt(tester, 'sekret12');
    expect(find.text('aplikacja'), findsOneWidget);
    expect(await store.read(appSecurityUnlockFailuresStorageKey), isNull);
  });

  testWidgets('during a wait the way out is still there', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester);
    for (int i = 0; i < 5; i++) {
      await attempt(tester, 'zle-haslo');
    }
    expect(submitEnabled(tester), isFalse);
    await openForgot(tester);
    expect(find.byKey(hold), findsOneWidget);
  });

  testWidgets('the panic password still erases silently', (
    WidgetTester tester,
  ) async {
    await pumpLocked(tester, withPanic: true);
    await attempt(tester, 'panika99');
    expect(wipes, 1);
    // No sign on the screen that anything was erased.
    expect(find.text('Usuwam dane z tego urządzenia…'), findsNothing);
    expect(find.text('Nieprawidłowe hasło.'), findsNothing);
    wipeGate.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('aplikacja'), findsOneWidget);
    expect(security.hasPassword, isFalse);
  });
}
