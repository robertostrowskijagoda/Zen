import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/groups/group_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

typedef SupportDirectoryLoader = Future<Directory> Function();
typedef AppSecurityServiceBuilder = AppSecurityService Function();
typedef AppSettingsStoreBuilder =
    AppSettingsStore Function(Directory supportDirectory);
typedef PersistentStoresBuilder =
    ZenPersistentStores Function(
      Directory supportDirectory, {
      AppSettingsStore? appSettingsStore,
      BinaryPayloadProtector? dataProtector,
    });
typedef RuntimeNodeRuntimeBuilder =
    RuntimeNodeRuntime Function({required RuntimeSignalBootstrapConfig config});
typedef RuntimeSystemNotificationServiceFactory =
    RuntimeSystemNotificationService Function();

final class ZenBootstrapException implements Exception {
  const ZenBootstrapException({
    required this.userMessage,
    required this.details,
  });

  final String userMessage;
  final String details;

  @override
  String toString() => details;
}

@immutable
final class ZenBootstrapSettingsState {
  const ZenBootstrapSettingsState({
    required this.supportDirectory,
    required this.appSettingsStore,
    required this.settings,
  });

  final Directory supportDirectory;
  final AppSettingsStore appSettingsStore;
  final AppSettings settings;
}

@immutable
final class ZenBootstrapRuntimeState {
  const ZenBootstrapRuntimeState({
    required this.runtime,
    required this.runtimeConfig,
  });

  final RuntimeNodeRuntime runtime;
  final RuntimeSignalBootstrapConfig runtimeConfig;
}

@immutable
final class ZenBootstrapResult {
  const ZenBootstrapResult({
    required this.runtime,
    required this.runtimeConfig,
    required this.appSecurityService,
    required this.initialSettings,
    required this.stores,
  });

  final RuntimeNodeRuntime runtime;
  final RuntimeSignalBootstrapConfig runtimeConfig;
  final AppSecurityService appSecurityService;
  final AppSettings initialSettings;
  final ZenPersistentStores stores;

  /// The app's providers. The Android background service builds the same
  /// ones (`ZenHost.backgroundService`), reading the social state itself
  /// ([socialHubAutoHydrate] off) from [socialHubSeed].
  List buildProviderOverrides({
    RuntimeSystemNotificationServiceFactory? systemNotificationServiceFactory,
    bool socialHubAutoHydrate = true,
    SocialHubState? socialHubSeed,
  }) {
    return [
      ...buildRuntimeTransportProviderOverrides(
        runtime: runtime,
        runtimeConfig: runtimeConfig,
        relayStateStore: stores.relayStateStore,
      ),
      ...buildRuntimeSystemNotificationProviderOverrides(
        // Android: the permission is asked for on the permissions screen
        // (§25.2), not when the first notification is set up.
        serviceFactory:
            systemNotificationServiceFactory ??
            (() => FlutterLocalRuntimeSystemNotificationService(
              canRequestPermission: false,
            )),
      ),
      ...buildAppSecurityProviderOverrides(service: appSecurityService),
      ...buildAppSettingsProviderOverrides(
        store: stores.appSettingsStore,
        initialState: initialSettings,
        hydrationEnabled: false,
      ),
      ...buildSocialHubProviderOverrides(
        signalQueueStore: stores.signalQueueStore,
        socialSnapshotStore: stores.socialSnapshotStore,
        // Disappearing messages (§14.1) on top of the copy for the
        // account's other devices (§6).
        messageTimelineStore: DisappearingTimelineStore(
          SyncingMessageTimelineStore(stores.messageTimelineStore),
        ),
        attachmentTransferStore: stores.attachmentTransferStore,
        autoHydrate: socialHubAutoHydrate,
        seedState: socialHubSeed,
      ),
      userProfileStoreProvider.overrideWithValue(stores.userProfileStore),
      groupStoreProvider.overrideWithValue(stores.groupStore),
      ledgerDiskProvider.overrideWithValue(stores.ledgerDisk),
      ledgerNodeEnabledProvider.overrideWithValue(true),
      // A computer is a bridge of the mesh without asking (§5.1); not in
      // tests, which must not touch the real router.
      bridgeHostEnabledProvider.overrideWithValue(
        isDesktopPlatform && !Platform.environment.containsKey('FLUTTER_TEST'),
      ),
      // §14.1: an app password is required by default — not for a debug
      // test profile (--zen-profile), which a script drives from outside.
      // Debug only: a profile build is a real install too.
      appPasswordRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
      // §25.2: the permissions and Bluetooth step once after the password;
      // skipped the same way where a script drives the app.
      permissionsSetupRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
      // §6.1, §6.3: the "Zabezpiecz konto" card once after that.
      accountSecureStepRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
    ];
  }
}

/// Whether the app password (§14.1) and the permissions step (§25.2) are
/// required at start. They are skipped only under `flutter test`
/// (`FLUTTER_TEST` in [environment]) or for a test profile (--zen-profile,
/// [hasTestProfile]) in a debug build — never in a release build, whatever
/// the environment says: `FLUTTER_TEST` is just a variable anyone starting
/// the process can set (S-20).
@visibleForTesting
bool zenStartupGatesRequired({
  required Map<String, String> environment,
  required bool hasTestProfile,
  bool releaseMode = kReleaseMode,
  bool debugMode = kDebugMode,
}) {
  if (releaseMode) {
    return true;
  }
  if (environment.containsKey('FLUTTER_TEST')) {
    return false;
  }
  return !(hasTestProfile && debugMode);
}

final class ZenBootstrapper {
  ZenBootstrapper({
    Future<void> Function()? prepareForegroundLaunch,
    SupportDirectoryLoader? supportDirectoryLoader,
    AppSecurityServiceBuilder? appSecurityServiceBuilder,
    AppSettingsStoreBuilder? appSettingsStoreBuilder,
    PersistentStoresBuilder? persistentStoresBuilder,
    RuntimeNodeRuntimeBuilder? runtimeBuilder,
    this.maxCriticalStepRetries = 1,
  }) : assert(maxCriticalStepRetries >= 0),
       _prepareForegroundLaunch = prepareForegroundLaunch,
       _supportDirectoryLoader =
           supportDirectoryLoader ?? ZenInstance.supportDirectory,
       _appSecurityServiceBuilder =
           appSecurityServiceBuilder ??
           // Biometric unlock goes through the device's security hardware
           // (§14.1).
           (() => LocalAppSecurityService(keyVault: platformKeyVault())),
       _appSettingsStoreBuilder =
           appSettingsStoreBuilder ?? buildZenAppSettingsStoreForDirectory,
       _persistentStoresBuilder =
           persistentStoresBuilder ?? buildZenPersistentStoresForDirectory,
       _runtimeBuilder = runtimeBuilder ?? buildDefaultRuntimeNodeRuntime;

  final Future<void> Function()? _prepareForegroundLaunch;
  final SupportDirectoryLoader _supportDirectoryLoader;
  final AppSecurityServiceBuilder _appSecurityServiceBuilder;
  final AppSettingsStoreBuilder _appSettingsStoreBuilder;
  final PersistentStoresBuilder _persistentStoresBuilder;
  final RuntimeNodeRuntimeBuilder _runtimeBuilder;
  final int maxCriticalStepRetries;

  Future<ZenBootstrapResult> bootstrap() async {
    await _runCriticalStep<void>('prepare foreground runtime', () async {
      final Future<void> Function()? prepareForegroundLaunch =
          _prepareForegroundLaunch;
      if (prepareForegroundLaunch == null) {
        return;
      }
      await prepareForegroundLaunch();
    });
    final ZenBootstrapSettingsState settingsState =
        await _runCriticalStep<ZenBootstrapSettingsState>(
          'init settings',
          initSettings,
        );
    // From here on both isolates record into the same on-device log.
    await ZenDiagnosticsLog.attach(
      settingsState.supportDirectory,
      source: 'ui',
    );
    logZenMessage('App bootstrap running.');
    final AppSecurityService appSecurityService =
        await _runCriticalStep<AppSecurityService>(
          'init security',
          () => initSecurity(settings: settingsState.settings),
        );
    final ZenPersistentStores stores =
        await _runCriticalStep<ZenPersistentStores>(
          'init storage',
          () => initStorage(
            supportDirectory: settingsState.supportDirectory,
            appSettingsStore: settingsState.appSettingsStore,
            appSecurityService: appSecurityService,
          ),
        );
    // Plain copies a player left behind (a crash, a killed app).
    unawaited(wipeMediaTemporaryFiles());
    final ZenBootstrapRuntimeState runtimeState =
        await _runCriticalStep<ZenBootstrapRuntimeState>(
          'init runtime',
          () => initRuntime(
            settings: settingsState.settings,
            appSecurityService: appSecurityService,
            lanDiscovery: lanDiscoveryResolver(
              loadSettings: settingsState.appSettingsStore.load,
              ledgerDisk: stores.ledgerDisk,
            ),
          ),
        );
    return ZenBootstrapResult(
      runtime: runtimeState.runtime,
      runtimeConfig: runtimeState.runtimeConfig,
      appSecurityService: appSecurityService,
      initialSettings: settingsState.settings,
      stores: stores,
    );
  }

  @visibleForTesting
  Future<ZenBootstrapSettingsState> initSettings() async {
    final Directory supportDirectory = await _supportDirectoryLoader();
    final AppSettingsStore appSettingsStore = _appSettingsStoreBuilder(
      supportDirectory,
    );
    final AppSettings settings =
        await appSettingsStore.load() ?? const AppSettings();
    return ZenBootstrapSettingsState(
      supportDirectory: supportDirectory,
      appSettingsStore: appSettingsStore,
      settings: settings,
    );
  }

  @visibleForTesting
  Future<AppSecurityService> initSecurity({
    required AppSettings settings,
  }) async {
    final AppSecurityService appSecurityService = _appSecurityServiceBuilder();
    await appSecurityService.initialize(settings: settings);
    return appSecurityService;
  }

  @visibleForTesting
  Future<ZenPersistentStores> initStorage({
    required Directory supportDirectory,
    required AppSettingsStore appSettingsStore,
    required AppSecurityService appSecurityService,
  }) async {
    return _persistentStoresBuilder(
      supportDirectory,
      appSettingsStore: appSettingsStore,
      dataProtector: EncryptedBinaryPayloadProtector(appSecurityService),
    );
  }

  @visibleForTesting
  Future<ZenBootstrapRuntimeState> initRuntime({
    required AppSettings settings,
    AppSecurityService? appSecurityService,
    RuntimeLanDiscoveryResolver? lanDiscovery,
  }) async {
    final RuntimeSignalBootstrapConfig runtimeConfig =
        RuntimeSignalBootstrapConfig(
          waitTimeout: settings.signalWaitTimeout,
          nodeConfigProtector: appSecurityService == null
              ? null
              : EncryptedBinaryPayloadProtector(appSecurityService),
          lanDiscovery: lanDiscovery,
        );
    return ZenBootstrapRuntimeState(
      runtime: _runtimeBuilder(config: runtimeConfig),
      runtimeConfig: runtimeConfig,
    );
  }

  Future<T> _runCriticalStep<T>(
    String label,
    Future<T> Function() action,
  ) async {
    final int maxAttempts = maxCriticalStepRetries + 1;
    Object? lastError;
    StackTrace? lastStackTrace;
    for (int attempt = 1; attempt <= maxAttempts; attempt += 1) {
      try {
        return await action();
      } catch (error, stackTrace) {
        lastError = error;
        lastStackTrace = stackTrace;
        logZenError(
          'Bootstrap step "$label" failed on attempt $attempt/$maxAttempts',
          error,
          stackTrace,
        );
        if (attempt >= maxAttempts) {
          rethrow;
        }
      }
    }
    Error.throwWithStackTrace(lastError!, lastStackTrace!);
  }
}
