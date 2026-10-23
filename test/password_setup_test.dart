import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

/// First start: the app password screen, with the one question about
/// biometric unlock (off unless the person says yes).
void main() {
  Future<LocalAppSecurityService> pumpSetup(
    WidgetTester tester, {
    required MemoryKeyVault vault,
  }) async {
    _tallScreen(tester);
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: vault,
    );
    await security.initialize(settings: const AppSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(const AppSettings()),
          ),
          appSecurityServiceProvider.overrideWithValue(security),
          appPasswordRequiredProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          // Same place as in the app: above the root Navigator.
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-password-setup')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('app-password-new')),
      'sekret123',
    );
    await tester.enterText(
      find.byKey(const Key('app-password-repeat')),
      'sekret123',
    );
    await tester.tap(find.byKey(const Key('app-password-set')));
    await tester.pumpAndSettle();
    return security;
  }

  testWidgets('saying yes turns biometric unlock on', (
    WidgetTester tester,
  ) async {
    final MemoryKeyVault vault = MemoryKeyVault();
    final LocalAppSecurityService security = await pumpSetup(
      tester,
      vault: vault,
    );
    expect(
      find.byKey(const Key('app-password-biometric-question')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('app-password-biometric-yes')));
    await tester.pumpAndSettle();

    expect(find.text('aplikacja'), findsOneWidget);
    expect(security.hasPassword, isTrue);
    expect((await security.biometricUnlockStatus()).enabled, isTrue);
    expect(await security.canUnlockWithBiometrics(), isTrue);

    // Locked again: the biometric prompt comes at once and unlocks.
    security.lock();
    await tester.pumpAndSettle();
    expect(security.isLocked, isFalse);
  });

  testWidgets('"not now" keeps it off', (WidgetTester tester) async {
    final LocalAppSecurityService security = await pumpSetup(
      tester,
      vault: MemoryKeyVault(),
    );
    await tester.tap(find.byKey(const Key('app-password-biometric-no')));
    await tester.pumpAndSettle();

    expect(find.text('aplikacja'), findsOneWidget);
    expect(security.hasPassword, isTrue);
    expect((await security.biometricUnlockStatus()).enabled, isFalse);
    expect(await security.canUnlockWithBiometrics(), isFalse);

    // Locked: the unlock screen has no biometric button then.
    security.lock();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-unlock-password-field')), findsOneWidget);
    expect(find.byKey(const Key('app-unlock-biometric-button')), findsNothing);
  });

  testWidgets('no question on a device without biometrics', (
    WidgetTester tester,
  ) async {
    final LocalAppSecurityService security = await pumpSetup(
      tester,
      vault: MemoryKeyVault(available: false),
    );
    expect(
      find.byKey(const Key('app-password-biometric-question')),
      findsNothing,
    );
    expect(find.text('aplikacja'), findsOneWidget);
    expect(security.hasPassword, isTrue);
  });

  testWidgets('after the password the permissions step really shows '
      '(the two steps do not share one Navigator)', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: MemoryKeyVault(available: false),
    );
    await security.initialize(settings: const AppSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(const AppSettings()),
          ),
          appSecurityServiceProvider.overrideWithValue(security),
          appPasswordRequiredProvider.overrideWithValue(true),
          permissionsSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(_OnePermission()),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('app-password-new')),
      'sekret123',
    );
    await tester.enterText(
      find.byKey(const Key('app-password-repeat')),
      'sekret123',
    );
    await tester.tap(find.byKey(const Key('app-password-set')));
    await tester.pumpAndSettle();

    expect(security.hasPassword, isTrue);
    expect(find.byKey(const Key('app-password-setup')), findsNothing);
    expect(find.byKey(const Key('permissions-setup')), findsOneWidget);
  });

  testWidgets('skipping the password asks first and then lets the app in', (
    WidgetTester tester,
  ) async {
    _tallScreen(tester);
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: MemoryKeyVault(),
    );
    await security.initialize(settings: const AppSettings());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(const AppSettings()),
          ),
          appSecurityServiceProvider.overrideWithValue(security),
          appPasswordRequiredProvider.overrideWithValue(true),
        ],
        child: MaterialApp(
          theme: ZenTheme.light(),
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('app-password-skip')));
    await tester.pumpAndSettle();
    expect(find.text('Bez hasła?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('app-password-skip-confirm')));
    await tester.pumpAndSettle();
    expect(find.text('aplikacja'), findsOneWidget);
    expect(security.hasPassword, isFalse);
  });
}

/// The whole setup form on screen, buttons included.
void _tallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 2.0;
  addTearDown(tester.view.reset);
}

/// A device with one thing to ask for (notifications).
final class _OnePermission implements PermissionsPlatform {
  @override
  bool get hasAnything => true;

  @override
  bool get hasBluetooth => false;

  @override
  Future<PermissionsSnapshot> check() async => const PermissionsSnapshot(
    applicable: <ZenPermission>[ZenPermission.notifications],
  );

  @override
  Future<void> request(ZenPermission permission) async {}

  @override
  Future<void> openSettings(ZenPermission permission) async {}

  @override
  Stream<bool> get bluetoothChanges => const Stream<bool>.empty();
}
