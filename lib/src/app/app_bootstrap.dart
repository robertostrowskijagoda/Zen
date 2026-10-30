import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AsyncSnapshot, ConnectionState;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/about/legal_documents.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/account/multi/desktop_background.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/groups/group_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/permissions/permissions_service.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/security/resume_session.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/presentation/first_run_setup.dart';
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

  /// The app's providers; [socialHubAutoHydrate] off and [socialHubSeed]
  /// let a caller read the social state itself.
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
        // Android: the permission is asked for on the permissions screen,
        // not when the first notification is set up.
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
        // Disappearing messages on top of the copy for the
        // account's other devices.
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
      // A computer is a bridge of the mesh without asking; not in
      // tests, which must not touch the real router.
      bridgeHostEnabledProvider.overrideWithValue(
        isDesktopPlatform && !Platform.environment.containsKey('FLUTTER_TEST'),
      ),
      // An app password is required by default — not for a debug
      // test profile (--zen-profile), which a script drives from outside.
      // Debug only: a profile build is a real install too.
      appPasswordRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
      // The first-start setup once after the password; skipped the same
      // way where a script drives the app.
      firstRunSetupRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
      // The permissions and Bluetooth step once after the password;
      // skipped the same way where a script drives the app.
      permissionsSetupRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
      // The terms, the privacy policy and the licence notice, accepted
      // before anything else; skipped the same way.
      legalConsentRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
      // The "Zabezpiecz konto" card once after that.
      accountSecureStepRequiredProvider.overrideWithValue(
        zenStartupGatesRequired(
          environment: Platform.environment,
          hasTestProfile: ZenInstance.profile != null,
        ),
      ),
    ];
  }
}

/// The bootstrap result whose app may be shown for [snapshot]: only one
/// that finished. While the next account's bootstrap runs, the snapshot
/// still carries the previous result; built again under the new account's
/// key, the account just left would come back to life with fresh providers
/// beside the next one — its node runtime, never stopped, started its node
/// again and kept calling on it, and the next account's node could not
/// start (the identity ran already).
ZenBootstrapResult? settledBootstrapResult(
  AsyncSnapshot<ZenBootstrapResult> snapshot,
) {
  if (snapshot.connectionState != ConnectionState.done) {
    return null;
  }
  return snapshot.data;
}

/// Ends what the app of an account that was left keeps running after its
/// providers are gone: its node runtime is overridden by value, so the
/// provider scope never disposes it.
void retireBootstrapResult(ZenBootstrapResult result) {
  result.runtime.dispose();
}

/// Whether the app password and the permissions step are
/// required at start. They are skipped only under `flutter test`
/// (`FLUTTER_TEST` in [environment]) or for a test profile (--zen-profile,
/// [hasTestProfile]) in a debug build — never in a release build, whatever
/// the environment says: `FLUTTER_TEST` is just a variable anyone starting
/// the process can set.
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
    this.opening,
    Future<void> Function()? prepareAccounts,
    Future<bool> Function()? receivesInBackground,
    this.maxCriticalStepRetries = 1,
    this.timeouts = const ZenStartTimeouts(),
  }) : assert(maxCriticalStepRetries >= 0),
       _prepareForegroundLaunch = prepareForegroundLaunch,
       _prepareAccounts =
           prepareAccounts ??
           // The accounts folder (salt, decoys) on every real install;
           // not where a test hands in its own folder.
           (supportDirectoryLoader == null
               ? () => ZenAccountRegistry().prepare()
               : null),
       _receivesInBackground =
           receivesInBackground ??
           (supportDirectoryLoader == null
               ? () => ZenBackgroundAccounts().isOn(ZenAccounts.current)
               : null),
       _supportDirectoryLoader =
           supportDirectoryLoader ?? ZenInstance.supportDirectory,
       _appSecurityServiceBuilder =
           appSecurityServiceBuilder ??
           // Biometric unlock goes through the device's security hardware
           // (shared by the accounts: an additional one never destroys
           // the hardware key).
           (() => LocalAppSecurityService(
             keyVault: ZenAccounts.current.isDefault
                 ? platformKeyVault()
                 : SharedKeyVault(platformKeyVault()),
             // Staying open after closing: the default account only (a
             // start always opens that one).
             resumeVault: ZenAccounts.current.isDefault
                 ? platformResumeSessionVault()
                 : null,
           )),
       _appSettingsStoreBuilder =
           appSettingsStoreBuilder ?? buildZenAppSettingsStoreForDirectory,
       _persistentStoresBuilder =
           persistentStoresBuilder ?? buildZenPersistentStoresForDirectory,
       _runtimeBuilder = runtimeBuilder ?? buildDefaultRuntimeNodeRuntime;

  final Future<void> Function()? _prepareForegroundLaunch;
  final Future<void> Function()? _prepareAccounts;

  /// Whether the account opening receives in the background ("Odbieraj
  /// w tle"); `null`: no (tests).
  final Future<bool> Function()? _receivesInBackground;

  /// The account to open (another one than at the last start, switched
  /// to in this process); `null`: the account open now (the default one
  /// at the app's start).
  final ZenAccountOpening? opening;

  /// The settings as soon as they are read (the first step of [bootstrap]),
  /// before the rest of the start-up is done: the splash shows the colours
  /// of the chosen theme from then on, not the default ones. `null` until
  /// then.
  final ValueNotifier<AppSettings?> loadedSettings =
      ValueNotifier<AppSettings?>(null);
  final SupportDirectoryLoader _supportDirectoryLoader;
  final AppSecurityServiceBuilder _appSecurityServiceBuilder;
  final AppSettingsStoreBuilder _appSettingsStoreBuilder;
  final PersistentStoresBuilder _persistentStoresBuilder;
  final RuntimeNodeRuntimeBuilder _runtimeBuilder;
  final int maxCriticalStepRetries;

  /// How long each step of [bootstrap] may take.
  final ZenStartTimeouts timeouts;

  /// The start up to the first screen. Every step has a time limit
  /// ([timeouts]); a step the app can start without (the accounts folder,
  /// the background service, the diagnostics log) gives way when it fails
  /// or takes too long, and nothing here waits on the Android background
  /// service: whether it runs the node is settled after the first screen
  /// (`AndroidBackgroundRuntimeBridge`).
  Future<ZenBootstrapResult> bootstrap() async {
    ZenStartTrace.begin();
    final ZenAccountOpening? opening = this.opening;
    if (opening != null) {
      // Before anything reads a folder or a secret: all of them are this
      // account's from here on.
      ZenAccounts.activate(opening.scope);
    }
    final Future<void> Function()? prepareAccounts = _prepareAccounts;
    if (prepareAccounts != null) {
      await ZenStartTrace.run<void>(
        ZenStartStep('accounts', label: t('folder kont'), optional: true),
        prepareAccounts,
        timeout: timeouts.optional,
        fallback: () {},
        fallbackOnError: true,
      );
    }
    final Future<void> Function()? prepareForegroundLaunch =
        _prepareForegroundLaunch;
    if (prepareForegroundLaunch != null) {
      await _runStep<void>(
        ZenStartStep(
          'background-service',
          label: t('usługa w tle'),
          optional: true,
        ),
        prepareForegroundLaunch,
        timeout: timeouts.optional,
        fallback: () {},
      );
    }
    final ZenBootstrapSettingsState settingsState =
        await _runStep<ZenBootstrapSettingsState>(
          ZenStartStep('settings', label: t('ustawienia')),
          initSettings,
          timeout: timeouts.settings,
        );
    // From here on both isolates record into the same on-device log.
    await ZenStartTrace.run<void>(
      ZenStartStep(
        'diagnostics-log',
        label: t('dziennik diagnostyczny'),
        optional: true,
      ),
      () => ZenDiagnosticsLog.attach(
        settingsState.supportDirectory,
        source: 'ui',
      ),
      timeout: timeouts.optional,
      fallback: () {},
      fallbackOnError: true,
    );
    logZenMessage('App bootstrap running.');
    unawaited(ZenTechLog.noteExits());
    unawaited(ZenTechLog.noteGoCrash());
    final AppSecurityService appSecurityService =
        await _runStep<AppSecurityService>(
          ZenStartStep('app-lock', label: t('blokada aplikacji')),
          () => initSecurity(settings: settingsState.settings),
          timeout: timeouts.security,
        );
    final ZenPersistentStores stores = await _runStep<ZenPersistentStores>(
      ZenStartStep('stores', label: t('magazyn danych')),
      () => initStorage(
        supportDirectory: settingsState.supportDirectory,
        appSettingsStore: settingsState.appSettingsStore,
        appSecurityService: appSecurityService,
      ),
      timeout: timeouts.storage,
    );
    // Plain copies a player left behind (a crash, a killed app).
    unawaited(wipeMediaTemporaryFiles());
    final ZenBootstrapRuntimeState runtimeState =
        await _runStep<ZenBootstrapRuntimeState>(
          ZenStartStep('network', label: t('sieć')),
          () => initRuntime(
            settings: settingsState.settings,
            appSecurityService: appSecurityService,
          ),
          timeout: timeouts.runtime,
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
    // The steps so far and every one from here are on disk at once.
    ZenStartTrace.attach(supportDirectory);
    final AppSettingsStore appSettingsStore = _appSettingsStoreBuilder(
      supportDirectory,
    );
    final AppSettings settings =
        await appSettingsStore.load() ?? const AppSettings();
    loadedSettings.value = settings;
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
    final AppSecurityService? opened = opening?.security;
    if (opened != null) {
      // Its password was checked before the switch: it opens unlocked.
      await opened.applySettings(settings);
      return opened;
    }
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
  }) async {
    final RuntimeSignalBootstrapConfig runtimeConfig =
        RuntimeSignalBootstrapConfig(
          waitTimeout: settings.signalWaitTimeout,
          nodeConfigProtector: appSecurityService == null
              ? null
              // Android: the background service runs the node while the
              // app is locked, without the master key.
              : Platform.isAndroid
              ? BackgroundKeyProtector(
                  appSecurityService.credentialsStore,
                  createKey: true,
                )
              // An iPhone: the locked receiver runs the node while Zen is
              // locked, in this process; the app's node waits until it let
              // go (one node per identity).
              : Platform.isIOS
              ? IosNodeGate.protector(
                  BackgroundKeyProtector(
                    appSecurityService.credentialsStore,
                    createKey: true,
                  ),
                )
              : Platform.isWindows || Platform.isLinux || Platform.isMacOS
              // A computer: under the background key only while
              // "Odbieraj w tle" is on (the tray then runs the node without
              // the password); either seal opens, in case a switch's
              // reseal was cut short.
              ? await _desktopNodeConfigProtector(appSecurityService)
              : EncryptedBinaryPayloadProtector(appSecurityService),
        );
    return ZenBootstrapRuntimeState(
      runtime: _runtimeBuilder(config: runtimeConfig),
      runtimeConfig: runtimeConfig,
    );
  }

  Future<KeyedBinaryPayloadProtector> _desktopNodeConfigProtector(
    AppSecurityService security,
  ) async {
    final KeyedBinaryPayloadProtector master = EncryptedBinaryPayloadProtector(
      security,
    );
    final KeyedBinaryPayloadProtector background = BackgroundKeyProtector(
      security.credentialsStore,
      createKey: true,
    );
    bool on = false;
    final Future<bool> Function()? receives = _receivesInBackground;
    if (receives != null) {
      on = await ZenStartTrace.run<bool>(
        ZenStartStep(
          'receive-in-background',
          label: t('odbieranie w tle'),
          optional: true,
        ),
        receives,
        timeout: timeouts.optional,
        fallback: () => false,
        fallbackOnError: true,
      );
    }
    return on
        ? FallbackKeyedProtector(background, master)
        : FallbackKeyedProtector(master, background);
  }

  /// [action] as [step], tried again up to [maxCriticalStepRetries]
  /// times when it fails (never when it ran out of time: it may still be
  /// running). With [fallback] the start goes on without it after the
  /// last failure or the time limit.
  Future<T> _runStep<T>(
    ZenStartStep step,
    Future<T> Function() action, {
    required Duration timeout,
    T Function()? fallback,
  }) async {
    final int maxAttempts = maxCriticalStepRetries + 1;
    for (int attempt = 1; ; attempt += 1) {
      try {
        return await ZenStartTrace.run<T>(
          step,
          action,
          timeout: timeout,
          fallback: fallback,
        );
      } on ZenStartStepTimeout {
        rethrow;
      } catch (error, stackTrace) {
        logZenError(
          'Bootstrap step "${step.id}" failed on attempt $attempt/$maxAttempts',
          error,
          stackTrace,
        );
        if (attempt < maxAttempts) {
          continue;
        }
        if (fallback != null) {
          return fallback();
        }
        rethrow;
      }
    }
  }
}

/// How long each step of [ZenBootstrapper.bootstrap] may take before the
/// start gives up on it (an optional step: goes on without it).
@immutable
final class ZenStartTimeouts {
  const ZenStartTimeouts({
    this.optional = const Duration(seconds: 6),
    this.settings = const Duration(seconds: 20),
    this.security = const Duration(seconds: 45),
    this.storage = const Duration(seconds: 20),
    this.runtime = const Duration(seconds: 20),
  });

  /// A step the app can start without.
  final Duration optional;

  /// The data folder and the settings file (with their protected copy).
  final Duration settings;

  /// The app lock: the secure storage (Android Keystore and the like).
  final Duration security;

  /// The encrypted stores.
  final Duration storage;

  /// The node runtime (built, not started: that comes after the first
  /// screen).
  final Duration runtime;
}
