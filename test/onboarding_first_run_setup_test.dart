import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/first_run_setup.dart';
import 'package:zen/src/features/shell/presentation/app_shell_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The gates as the setup sees them, without the introductions service.
final class _Gates extends ChangeNotifier implements GateDefaults {
  GateDefault? value = GateDefault.of(GateSettings());

  @override
  GateDefault? get current => value;

  @override
  Future<void> set(GateDefault next) async {
    value = next;
    notifyListeners();
  }

  @override
  Listenable get changes => this;
}

/// Nothing to ask on this "device": the permissions step is left out.
final class _NoPermissions implements PermissionsPlatform {
  @override
  bool get hasAnything => false;

  @override
  bool get hasBluetooth => false;

  @override
  Future<PermissionsSnapshot> check() async => const PermissionsSnapshot();

  @override
  Future<void> request(ZenPermission permission) async {}

  @override
  Future<void> openSettings(ZenPermission permission) async {}

  @override
  Stream<bool> get bluetoothChanges => const Stream<bool>.empty();
}

void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 4000);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

Widget _gatedApp({required List overrides}) => ProviderScope(
  overrides: [...overrides],
  child: MaterialApp(
    theme: ZenTheme.dark(),
    builder: (BuildContext context, Widget? child) =>
        AppSecurityGate(child: child!),
    home: const Scaffold(body: Text('aplikacja')),
  ),
);

void main() {
  test('gates are open for free for a new person', () {
    expect(GateTerms.standard.free, isTrue);
    expect(GateTerms.standard.consent, isFalse);
    final GateSettings fresh = GateSettings();
    for (final GateTier tier in GateTier.values) {
      expect(fresh.of(tier), GateTerms.standard, reason: tier.name);
    }
    expect(GateDefault.of(fresh), GateDefault.open);
    expect(GateDefault.of(GateSettings.fromJson(null)), GateDefault.open);
    fresh.tiers[GateTier.far] = const GateTerms(price: 500);
    expect(GateDefault.of(fresh), isNull, reason: 'terms of one\'s own');
  });

  test('the setup is remembered in the settings', () {
    expect(const AppSettings().firstRunSetupDone, isFalse);
    final AppSettings done = const AppSettings().copyWith(
      firstRunSetupDone: true,
    );
    expect(AppSettings.fromJson(done.toJson()).firstRunSetupDone, isTrue);
  });

  testWidgets('first start: shown once after the password, every answer '
      'saved, never shown again', (WidgetTester tester) async {
    _tallScreen(tester);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    final _Gates gates = _Gates();
    List overrides(AppSettings? initial) => [
      appSettingsStoreProvider.overrideWithValue(store),
      if (initial != null) ...[
        appSettingsInitialStateProvider.overrideWithValue(initial),
        appSettingsHydrationEnabledProvider.overrideWithValue(false),
      ],
      firstRunSetupRequiredProvider.overrideWithValue(true),
      permissionsPlatformProvider.overrideWithValue(_NoPermissions()),
      gateDefaultsProvider.overrideWithValue(gates),
    ];
    await tester.pumpWidget(_gatedApp(overrides: overrides(null)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-run-setup')), findsOneWidget);
    expect(find.text('aplikacja'), findsNothing);
    expect(find.byKey(const Key('first-run-welcome')), findsOneWidget);
    expect(find.text('Krok 1 z 4'), findsOneWidget);

    // 1) The lock: the honest note about "Nigdy".
    await tester.tap(find.byKey(const Key('settings-lock-mode-never')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-lock-never-note')), findsOneWidget);
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pumpAndSettle();

    // 2) Notifications: "Nadawca i treść" chosen by default.
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('notification-privacy-senderAndContent')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('notification-privacy-senderOnly')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pumpAndSettle();

    // 3) Gates: open for free by default.
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const Key('first-run-gates-open')))
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('first-run-gates-consent')));
    await tester.pumpAndSettle();
    expect(gates.value, GateDefault.consent);
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pumpAndSettle();

    // 4) Animations: on by default.
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('settings-animations-always')),
          )
          .selected,
      isTrue,
    );
    await tester.tap(find.byKey(const Key('settings-animations-off')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pumpAndSettle();

    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('first-run-setup')), findsNothing);
    final AppSettings saved = (await store.load())!;
    expect(saved.firstRunSetupDone, isTrue);
    expect(saved.lockMode, AppLockMode.never);
    expect(saved.notificationPrivacy, NotificationPrivacy.senderOnly);
    expect(saved.animations, AppAnimations.off);

    // The next start goes straight to the app.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_gatedApp(overrides: overrides(saved)));
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('first-run-setup')), findsNothing);
  });

  testWidgets('"Nigdy" in the setup takes the password just set once more '
      'and keeps the key: the next cold start opens without it', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    final MemorySecurityCredentialsStore secrets =
        MemorySecurityCredentialsStore();
    LocalAppSecurityService securityOn() => LocalAppSecurityService(
      credentialsStore: secrets,
      passwordIterations: 10,
    );
    // The password step is behind: the setup comes right after it.
    final LocalAppSecurityService security = securityOn();
    await tester.runAsync(() async {
      await security.initialize(settings: const AppSettings());
      await security.setPassword('haslo-do-testu');
    });
    List overrides(AppSecurityService security, AppSettings? initial) => [
      appSettingsStoreProvider.overrideWithValue(store),
      appSecurityServiceProvider.overrideWithValue(security),
      if (initial != null) ...[
        appSettingsInitialStateProvider.overrideWithValue(initial),
        appSettingsHydrationEnabledProvider.overrideWithValue(false),
      ],
      firstRunSetupRequiredProvider.overrideWithValue(true),
      permissionsPlatformProvider.overrideWithValue(_NoPermissions()),
      gateDefaultsProvider.overrideWithValue(_Gates()),
    ];
    Future<void> tapAndWait(Finder finder) async {
      await tester.tap(finder);
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(_gatedApp(overrides: overrides(security, null)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-run-step-lock')), findsOneWidget);

    final Finder dialog = find.byKey(const Key('settings-never-lock-dialog'));
    final Finder field = find.byKey(
      const Key('settings-never-lock-password-field'),
    );
    final Finder note = find.byKey(const Key('settings-lock-never-note'));

    // The warning first; cancelled, nothing changes.
    await tapAndWait(find.byKey(const Key('settings-lock-mode-never')));
    expect(dialog, findsOneWidget);
    await tester.tap(find.text('Anuluj'));
    await tester.pumpAndSettle();
    expect(dialog, findsNothing);
    expect(note, findsNothing);
    expect(security.lockMode, isNot(AppLockMode.never));
    expect(security.keepsNeverLockKey, isFalse);

    // A wrong password keeps nothing.
    await tapAndWait(find.byKey(const Key('settings-lock-mode-never')));
    await tester.enterText(field, 'zle-haslo');
    await tapAndWait(find.byKey(const Key('settings-never-lock-confirm')));
    expect(find.text('Nieprawidłowe hasło.'), findsOneWidget);
    expect(security.keepsNeverLockKey, isFalse);

    await tester.enterText(field, 'haslo-do-testu');
    await tapAndWait(find.byKey(const Key('settings-never-lock-confirm')));
    expect(dialog, findsNothing);
    expect(security.lockMode, AppLockMode.never);
    expect(security.keepsNeverLockKey, isTrue);
    expect(
      tester.widget<Text>(note).data,
      contains('otwiera się bez hasła, także po restarcie'),
    );

    await tester.tap(find.byKey(const Key('first-run-skip')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    final AppSettings saved = (await store.load())!;
    expect(saved.lockMode, AppLockMode.never);
    expect(saved.firstRunSetupDone, isTrue);

    // A start from scratch: no password asked.
    await tester.pumpWidget(const SizedBox.shrink());
    final LocalAppSecurityService restarted = securityOn();
    await tester.runAsync(() => restarted.initialize(settings: saved));
    expect(restarted.isLocked, isFalse);
    await tester.pumpWidget(_gatedApp(overrides: overrides(restarted, saved)));
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(find.byKey(const Key('app-unlock-password-field')), findsNothing);
  });

  testWidgets('it can be skipped: the defaults stay', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    await tester.pumpWidget(
      _gatedApp(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(store),
          firstRunSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(_NoPermissions()),
          gateDefaultsProvider.overrideWithValue(_Gates()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('first-run-skip')));
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    final AppSettings saved = (await store.load())!;
    expect(saved.firstRunSetupDone, isTrue);
    expect(saved.notificationPrivacy, NotificationPrivacy.senderAndContent);
    expect(saved.animations, AppAnimations.always);
    expect(saved.lockMode, AppSettings.defaultLockMode);
  });

  testWidgets('not required (tests, a script): straight to the app', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _gatedApp(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(MemoryAppSettingsStore()),
          permissionsPlatformProvider.overrideWithValue(_NoPermissions()),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
  });

  testWidgets('"Ponownie przeprowadź konfigurację" in Settings runs the '
      'setup again with what is set now', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          permissionsPlatformProvider.overrideWithValue(_NoPermissions()),
          gateDefaultsProvider.overrideWithValue(_Gates()),
          appSettingsInitialStateProvider.overrideWithValue(
            const AppSettings(notificationPrivacy: NotificationPrivacy.generic),
          ),
          appSettingsHydrationEnabledProvider.overrideWithValue(false),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const AppShellScreen(),
        ),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('chats-status-chip')));
    // Not pumpAndSettle: the status bar keeps pulsing.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.scrollUntilVisible(
      find.byKey(const Key('settings-rerun-setup')),
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('settings-tab-body')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.pump();
    expect(find.text('Ponownie przeprowadź konfigurację'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-rerun-setup')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('first-run-setup-screen')), findsOneWidget);
    expect(find.byKey(const Key('first-run-step-lock')), findsOneWidget);
    expect(find.byKey(const Key('first-run-welcome')), findsNothing);

    // Prefilled: the notifications step shows what is set now.
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const Key('notification-privacy-generic')),
          )
          .selected,
      isTrue,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  });

  testWidgets('an iPhone: a step with the ways to wake Zen, each to choose', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    int shortcuts = 0;
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appSettingsInitialStateProvider.overrideWithValue(const AppSettings()),
        appSettingsHydrationEnabledProvider.overrideWithValue(false),
        permissionsPlatformProvider.overrideWithValue(_NoPermissions()),
        gateDefaultsProvider.overrideWithValue(_Gates()),
        iosBackgroundBridgeEnabledProvider.overrideWithValue(true),
        iosBackgroundStatusReaderProvider.overrideWithValue(
          () async => const IosBackgroundStatus(
            refresh: IosBackgroundRefresh.available,
            notifications: IosNotifications.allowed,
          ),
        ),
        iosOpenShortcutsProvider.overrideWithValue(() async => shortcuts++),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ZenTheme.dark(),
          home: const FirstRunSetupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Krok 1 z 5'), findsOneWidget);
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('first-run-next')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-run-step-iphone')), findsOneWidget);
    expect(find.text('Krok 3 z 5'), findsOneWidget);
    for (final String option in <String>[
      'ios-wake-refresh',
      'ios-wake-shortcut',
      'ios-wake-keep-alive',
      'ios-settings-checklist',
    ]) {
      expect(find.byKey(Key(option)), findsOneWidget, reason: option);
    }

    // Shortcuts: the steps on request, and the app one tap away.
    await tester.tap(find.byKey(const Key('ios-wake-shortcut-how')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ios-wake-shortcut-steps')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ios-wake-open-shortcuts')));
    await tester.pump();
    expect(shortcuts, 1);

    // The silent sound only after the battery warning.
    await tester.tap(find.byKey(const Key('settings-ios-keep-alive-switch')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('ios-keep-alive-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('ios-keep-alive-confirm-ok')));
    await tester.pumpAndSettle();
    expect(
      container.read(appSettingsControllerProvider).keepReceivingInBackground,
      isTrue,
    );
  });
}
