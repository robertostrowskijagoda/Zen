import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_archive_collect.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/security/app_security_gate.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/launcher_disguise.dart';
import 'package:zen/src/features/settings/presentation/first_run_setup.dart';

/// A launcher that takes the disguised icon ([takes]) or not.
final class _Launcher extends LauncherDisguise {
  _Launcher({required this.takes})
    : super(channel: const MethodChannel('test/none'), supported: true);

  final bool takes;
  final List<bool> asked = <bool>[];

  @override
  Future<bool> set({required bool enabled}) async {
    asked.add(enabled);
    return takes;
  }
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

/// This device on its first start: terms accepted a moment ago, nothing
/// else gone through.
const AppSettings _device = AppSettings(
  legalAcceptedVersion: 'v2',
  legalAcceptedAtMillis: 200,
);

/// The settings of the account's old device, everything chosen.
AppSettings _old({int setupRevision = kSetupRevision}) =>
    const AppSettings().copyWith(
      setupRevision: setupRevision,
      permissionsSetupDone: true,
      accountSecureOffered: true,
      lockMode: AppLockMode.appClose,
      backgroundLockDelaySeconds: 300,
      allowNoAppPassword: true,
      disguiseIcon: true,
      bridgeEnabled: true,
      lanDiscovery: false,
      wifiDirect: true,
      bluetoothLinks: true,
      keepReceivingInBackground: true,
      palette: AppPalette.values.last,
      notificationPrivacy: NotificationPrivacy.generic,
      legalAcceptedVersion: 'v1',
      legalAcceptedAtMillis: 100,
    );

AccountArchive _archive(AppSettings settings, {bool lock = true}) =>
    AccountArchive(
      account: 'acc',
      createdAt: 1,
      scope: kAllAccountScopes,
      sections: <String, Object?>{
        CircleBackupSections.settings: settings.toJson(),
        if (lock) kAccountAppLock: const AppLockCopy().toJson(),
      },
    );

ProviderContainer _container(
  MemoryAppSettingsStore store, {
  LauncherDisguise? launcher,
}) {
  final ProviderContainer container = ProviderContainer(
    overrides: [
      appSettingsStoreProvider.overrideWithValue(store),
      appSettingsInitialStateProvider.overrideWithValue(_device),
      appSettingsHydrationEnabledProvider.overrideWithValue(false),
      if (launcher != null)
        launcherDisguiseProvider.overrideWithValue(launcher),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a backup of the whole app puts every setting back as it was, '
      'before the restart; only the latest terms acceptance and this '
      'phone\'s permissions step stay', () async {
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(_device);
    final _Launcher launcher = _Launcher(takes: true);
    final ProviderContainer container = _container(store, launcher: launcher);
    final AppSettingsController controller = container.read(
      appSettingsControllerProvider.notifier,
    );
    final AccountArchive archive = _archive(_old());
    expect(accountArchiveAppLock(archive), isNotNull);

    await takeAccountArchiveSettings(controller, archive, beforeRestart: true);
    final AppSettings now = container.read(appSettingsControllerProvider);
    expect(
      now.toJson(),
      _old()
          .copyWith(
            legalAcceptedVersion: 'v2',
            legalAcceptedAtMillis: 200,
            permissionsSetupDone: false,
          )
          .toJson(),
    );
    expect(now.setupPending, isFalse, reason: 'no setup after the restore');
    expect(launcher.asked, <bool>[true], reason: 'the launcher switched too');
    expect((await store.load())!.toJson(), now.toJson());

    // After the restart the rest is taken in: the settings stay as they are.
    await controller.setPalette(AppPalette.values.first);
    await takeAccountArchiveSettings(controller, archive, beforeRestart: false);
    expect(
      container.read(appSettingsControllerProvider).palette,
      AppPalette.values.first,
    );
  });

  test('terms accepted only in the backup count', () {
    final AppSettings taken = const AppSettings().restoringWhole(_old());
    expect(taken.legalAcceptedVersion, 'v1');
    expect(taken.legalAcceptedAtMillis, 100);
  });

  test(
    'a disguised icon the phone does not take stays as it is here',
    () async {
      final ProviderContainer container = _container(
        MemoryAppSettingsStore(_device),
        launcher: _Launcher(takes: false),
      );
      await container
          .read(appSettingsControllerProvider.notifier)
          .restoreWhole(_old());
      final AppSettings now = container.read(appSettingsControllerProvider);
      expect(now.disguiseIcon, isFalse);
      expect(now.lockMode, AppLockMode.appClose);
    },
  );

  test('a copy without the app\'s lock keeps this device\'s own settings, '
      'taken after the restart', () async {
    final ProviderContainer container = _container(
      MemoryAppSettingsStore(_device),
    );
    final AppSettingsController controller = container.read(
      appSettingsControllerProvider.notifier,
    );
    final AccountArchive archive = _archive(_old(), lock: false);
    expect(accountArchiveAppLock(archive), isNull);

    await takeAccountArchiveSettings(controller, archive, beforeRestart: true);
    expect(
      container.read(appSettingsControllerProvider).toJson(),
      _device.toJson(),
    );

    await takeAccountArchiveSettings(controller, archive, beforeRestart: false);
    final AppSettings now = container.read(appSettingsControllerProvider);
    expect(now.palette, AppPalette.values.last, reason: 'the account\'s');
    expect(now.lockMode, _device.lockMode, reason: 'this device\'s');
    expect(now.allowNoAppPassword, isFalse, reason: 'a password is asked');
    expect(now.permissionsSetupDone, isFalse);
  });

  testWidgets('a backup from an older setup shows the setup once', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(_device);
    final ProviderContainer container = ProviderContainer(
      overrides: [
        appSettingsStoreProvider.overrideWithValue(store),
        appSettingsInitialStateProvider.overrideWithValue(_device),
        appSettingsHydrationEnabledProvider.overrideWithValue(false),
        appSecurityServiceProvider.overrideWithValue(
          MemoryAppSecurityService(),
        ),
        firstRunSetupRequiredProvider.overrideWithValue(true),
        gateDefaultsProvider.overrideWithValue(_Gates()),
      ],
    );
    addTearDown(container.dispose);
    await container
        .read(appSettingsControllerProvider.notifier)
        .restoreWhole(_old(setupRevision: kSetupRevision - 1));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ZenTheme.dark(),
          builder: (BuildContext context, Widget? child) =>
              AppSecurityGate(child: child!),
          home: const Scaffold(body: Text('aplikacja')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-run-setup')), findsOneWidget);
    await tester.tap(find.byKey(const Key('first-run-skip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('first-run-setup')), findsNothing);
    expect(find.text('aplikacja'), findsOneWidget);
    expect((await store.load())!.setupPending, isFalse);
    // The rest of the old settings stayed through it.
    expect(
      container.read(appSettingsControllerProvider).lockMode,
      AppLockMode.appClose,
    );
  });
}
