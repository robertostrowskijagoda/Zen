import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/account_import_layer.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/first_run_setup.dart';

/// The first start of a person who already has an account: the way back is
/// offered on the password step already and opens instead of it (a backup
/// of the whole app brings its own password; the setup and the permissions
/// wait for the account), and its screen comes up without the app flashing
/// up first.
void main() {
  late LocalAppSecurityService security;

  Future<MemoryAppSettingsStore> pumpFirstStart(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: MemoryKeyVault(available: false),
    );
    await security.initialize(settings: const AppSettings());
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(store),
          appSecurityServiceProvider.overrideWithValue(security),
          appPasswordRequiredProvider.overrideWithValue(true),
          firstRunSetupRequiredProvider.overrideWithValue(true),
          permissionsSetupRequiredProvider.overrideWithValue(true),
          permissionsPlatformProvider.overrideWithValue(_OnePermission()),
          accountSecureStepRequiredProvider.overrideWithValue(true),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          gateDefaultsProvider.overrideWithValue(_Gates()),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          // As in the app: the gate above the root Navigator, the layer
          // that opens the way back in the app.
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const AccountImportLayer(
            child: Scaffold(body: Text('aplikacja')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-password-setup')), findsOneWidget);
    return store;
  }

  Future<void> setPassword(WidgetTester tester) async {
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
  }

  testWidgets('"Mam już konto" on the password step: the ways back at once, '
      'no password asked yet; the backup screen without the app showing '
      'first; left, the first start starts over', (WidgetTester tester) async {
    final MemoryAppSettingsStore store = await pumpFirstStart(tester);
    await tester.tap(find.byKey(const Key('app-password-have-account')));
    await tester.pumpAndSettle();
    // No password, no setup, no permissions: the ways back, saying the
    // password comes with a backup of the whole app.
    expect(find.byKey(const Key('app-password-setup')), findsNothing);
    expect(find.byKey(const Key('first-run-setup')), findsNothing);
    expect(find.byKey(const Key('permissions-setup')), findsNothing);
    expect(find.byKey(const Key('account-start-stage')), findsOneWidget);
    expect(
      find.byKey(const Key('account-start-password-note')),
      findsOneWidget,
    );
    expect(security.hasPassword, isFalse);

    final Finder app = find.text('aplikacja', skipOffstage: false);
    final Finder cover = find.byKey(const Key('gate-start-cover'));
    final Finder restore = find.byKey(
      const Key('account-backup-restore-screen'),
    );
    await tester.tap(find.byKey(const Key('account-restore-backup-open')));
    // Frame by frame: the app is never what the person sees.
    for (int frame = 0; frame < 8; frame++) {
      await tester.pump();
      if (app.evaluate().isEmpty) {
        continue;
      }
      expect(
        cover.evaluate().isNotEmpty || restore.evaluate().isNotEmpty,
        isTrue,
        reason: 'frame $frame shows the app',
      );
    }
    await tester.pumpAndSettle();
    expect(restore, findsOneWidget);
    expect(cover, findsNothing);
    expect(find.byKey(const Key('app-password-setup')), findsNothing);
    expect(find.byKey(const Key('first-run-setup')), findsNothing);

    // Left without a copy: back to the first start, the password first.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(restore, findsNothing);
    expect(find.byKey(const Key('app-password-setup')), findsOneWidget);
    expect((await store.load())!.accountSecureOffered, isFalse);
    await setPassword(tester);
    expect(find.byKey(const Key('first-run-setup')), findsOneWidget);
  });

  testWidgets('"Nowe konto" after "Mam już konto": the password, the setup '
      'and the permissions come first', (WidgetTester tester) async {
    await pumpFirstStart(tester);
    await tester.tap(find.byKey(const Key('app-password-have-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-start-new')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-password-setup')), findsOneWidget);
    expect(find.byKey(const Key('app-password-have-account')), findsOneWidget);
    await setPassword(tester);
    expect(find.byKey(const Key('first-run-setup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('first-run-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('permissions-setup')), findsOneWidget);
  });

  testWidgets('the recovery circle (no password in it, a day or more of '
      'waiting): the password first, then the circle without the setup', (
    WidgetTester tester,
  ) async {
    await pumpFirstStart(tester);
    await tester.tap(find.byKey(const Key('app-password-have-account')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-restore-circle-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-password-setup')), findsOneWidget);
    expect(find.byKey(const Key('app-password-have-account')), findsNothing);
    await setPassword(tester);
    expect(security.hasPassword, isTrue);
    expect(find.byKey(const Key('app-password-setup')), findsNothing);
    expect(find.byKey(const Key('first-run-setup')), findsNothing);
    expect(find.byKey(const Key('permissions-setup')), findsNothing);
    expect(find.byKey(const Key('gate-start-cover')), findsNothing);
  });

  testWidgets('no "Mam już konto" once the first start is over', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 3200);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
      keyVault: MemoryKeyVault(available: false),
    );
    await security.initialize(settings: const AppSettings());
    const AppSettings answered = AppSettings(accountSecureOffered: true);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appSettingsStoreProvider.overrideWithValue(
            MemoryAppSettingsStore(answered),
          ),
          appSettingsInitialStateProvider.overrideWithValue(answered),
          appSettingsHydrationEnabledProvider.overrideWithValue(false),
          appSecurityServiceProvider.overrideWithValue(security),
          appPasswordRequiredProvider.overrideWithValue(true),
          accountSecureStepRequiredProvider.overrideWithValue(true),
          ledgerNodeEnabledProvider.overrideWithValue(true),
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
    expect(find.byKey(const Key('app-password-setup')), findsOneWidget);
    expect(find.byKey(const Key('app-password-have-account')), findsNothing);
  });
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

/// The gates as the setup sees them, without the introductions service.
final class _Gates extends ChangeNotifier implements GateDefaults {
  @override
  GateTerms? terms = GateTerms.standard;

  @override
  bool get member => false;

  @override
  GateDefault? get current => GateDefault.open;

  @override
  Future<void> set(GateDefault value) => setTerms(value.terms);

  @override
  Future<void> setTerms(GateTerms next) async {
    terms = next;
    notifyListeners();
  }

  @override
  Listenable get changes => this;
}
