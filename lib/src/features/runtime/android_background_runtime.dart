import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/app/zen_host.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/calls/noop_call_media_session.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/nearby_keeper.dart';
import 'package:zen/src/features/meet/presentation/alarm_audio.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The quiet channel of the background service (minimum importance).
const String kAndroidBackgroundChannelId = 'zen_background_quiet';

/// The Android API level (14) that brought the `specialUse` service type.
const int kAndroidSpecialUseServiceSdk = 34;

const MethodChannel _systemChannel = MethodChannel('zen/system');

/// This device's Android API level once [loadAndroidSdkInt] read it; `null`
/// before that and on other platforms.
int? _androidSdkInt;

/// The Android API level, read once from the platform (`null` when unknown).
Future<int?> loadAndroidSdkInt() async {
  if (_androidSdkInt != null || !Platform.isAndroid) {
    return _androidSdkInt;
  }
  try {
    _androidSdkInt = await _systemChannel.invokeMethod<int>('sdkInt');
  } catch (error, stackTrace) {
    logZenError('Reading the Android version failed', error, stackTrace);
  }
  return _androidSdkInt;
}

/// Opens Zen's page in the system settings, where phone makers keep their
/// own battery limits ("Autostart", "Uśpione aplikacje"...).
Future<bool> openAndroidAppSettings() async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await _systemChannel.invokeMethod<bool>('openAppSettings') ?? false;
  } catch (error, stackTrace) {
    logZenError('Opening the app settings failed', error, stackTrace);
    return false;
  }
}

/// The type the always-on service (the node that receives messages, calls
/// and alarms) runs under.
///
/// `specialUse` from Android 14 on: it has no time limit, while Android 15
/// stops a `dataSync` service after 6 hours in 24. Older versions have no
/// `specialUse` (the plugin drops it there, which would leave the service
/// with a stale or no type) and no time limits either, so they keep
/// `dataSync`. An unknown version counts as a current one.
ForegroundServiceTypes foregroundServiceKeepAliveType(int? androidSdkInt) {
  if (androidSdkInt != null && androidSdkInt < kAndroidSpecialUseServiceSdk) {
    return ForegroundServiceTypes.dataSync;
  }
  return ForegroundServiceTypes.specialUse;
}

List<ForegroundServiceTypes> foregroundServiceTypesForCallSession(
  CallSession? session, {
  int? androidSdkInt,
}) {
  final List<ForegroundServiceTypes> base = _baseServiceTypes(
    session,
    foregroundServiceKeepAliveType(androidSdkInt ?? _androidSdkInt),
  );
  // Screen sharing (§13.1): Android 14+ captures only under a service of
  // the mediaProjection type.
  if (session != null && androidScreenCaptureActive.value) {
    return <ForegroundServiceTypes>[
      ...base,
      ForegroundServiceTypes.mediaProjection,
    ];
  }
  return base;
}

List<ForegroundServiceTypes> _baseServiceTypes(
  CallSession? session,
  ForegroundServiceTypes keepAlive,
) {
  if (session == null) {
    return <ForegroundServiceTypes>[keepAlive];
  }
  if (session.isIncoming && session.status == CallSessionStatus.ringing) {
    return <ForegroundServiceTypes>[keepAlive];
  }
  return session.kind == CallInviteKind.video
      ? <ForegroundServiceTypes>[
          keepAlive,
          ForegroundServiceTypes.microphone,
          ForegroundServiceTypes.camera,
        ]
      : <ForegroundServiceTypes>[keepAlive, ForegroundServiceTypes.microphone];
}

/// What the foreground service isolate is expected to be doing.
///
/// The service is started while the app is still on screen (Android 12+ refuses
/// a foreground-service start from the background) and then parked in
/// [standby]: alive, holding its notification, but without a Yggdrasil node.
/// Only the handoff flips it to [active], where it owns the node.
enum AndroidBackgroundRuntimeMode { standby, active }

/// Message type the task isolate sends back once it reached a requested mode.
const String _kRuntimeModeAckType = 'zen.runtime.mode';

/// Message the app sends while it is on screen and owns the node itself.
const String _kRuntimeHeartbeatType = 'zen.runtime.heartbeat';

/// Message the app sends right before it stops the service on purpose (a
/// restart with other service types). Any other end of the service means
/// Android ended it.
const String kAndroidBackgroundStopRequestType = 'zen.runtime.stop';

/// Slot of the "Zen nie odbiera w tle" notice.
const String kBackgroundRuntimeStoppedSlot = 'background-runtime-stopped';

/// How often the app proves it is still alive while the service is parked.
const Duration kAndroidBackgroundHeartbeatInterval = Duration(seconds: 5);

/// How long the parked service waits for a heartbeat before taking the node
/// over on its own.
///
/// Swiping the app away destroys the Flutter engine but not the process — the
/// foreground service keeps it alive — so nothing was left to hand the node
/// over, and the service sat parked and silent until the next launch. That is
/// exactly the "no notification for an incoming call once the app is closed"
/// case. The window is generous enough that a briefly janky UI isolate cannot
/// trigger a second node while the first one is still up.
const Duration kAndroidBackgroundHeartbeatTimeout = Duration(seconds: 20);

String _backgroundServiceNotificationText(
  CallSession? session, {
  AndroidBackgroundRuntimeMode mode = AndroidBackgroundRuntimeMode.active,
}) {
  if (mode == AndroidBackgroundRuntimeMode.standby) {
    return t('Zen jest gotowy');
  }
  if (session == null) {
    return t('Zen działa w tle');
  }
  if (session.status == CallSessionStatus.ringing) {
    // An incoming ring already has its own full-screen call notification with
    // the accept/decline buttons; repeating it here put two entries for one
    // call in the shade.
    return session.isIncoming
        ? t('Zen działa w tle')
        : t('Wywoływanie {name}', {'name': session.displayName});
  }
  return session.kind == CallInviteKind.video
      ? t('Aktywna rozmowa wideo z {name}', {'name': session.displayName})
      : t('Aktywna rozmowa audio z {name}', {'name': session.displayName});
}

/// Heads-up for a service parked without an unlocked key (password mode).
///
/// In that state the background runtime cannot start the node at all, so
/// incoming calls silently go nowhere. The suppression key keeps repeat park
/// events from spamming the shade; the slot gives the notice a stable
/// identity.
@visibleForTesting
Future<bool> showLockedBackgroundRuntimeNotice(
  RuntimeSystemNotificationService service, {
  required int createdAtMillis,
}) {
  return service.show(
    RuntimeSystemNotification(
      id: 'background-runtime-locked',
      title: t('Zen czeka na odblokowanie'),
      body: t(
        'Połączenia przychodzące nie będą odbierane, dopóki nie odblokujesz '
        'aplikacji.',
      ),
      createdAtMillis: createdAtMillis,
      routeKey: buildInboxRouteKey(),
      slotKey: 'background-runtime-locked',
      suppressionKey: 'background-runtime-locked',
      category: RuntimeSystemNotificationCategory.call,
    ),
  );
}

/// Whether the end of the service leaves the person without messages,
/// calls and alarms in the background, unknowingly: Android ended it (the
/// time limit of a service type, or any stop the app did not ask for).
bool backgroundStopNeedsNotice({
  required bool isTimeout,
  required bool stopRequestedByApp,
}) {
  return isTimeout || !stopRequestedByApp;
}

/// Heads-up that Android stopped the background service.
///
/// Nothing receives for the person after that, and Android does not let the
/// app restart the service on its own (Android 12+ refuses a start from the
/// background; after a type's time limit only opening the app resets it).
/// Tapping opens Zen, which starts the service again.
@visibleForTesting
Future<bool> showBackgroundRuntimeStoppedNotice(
  RuntimeSystemNotificationService service, {
  required int createdAtMillis,
}) {
  return service.show(
    RuntimeSystemNotification(
      id: kBackgroundRuntimeStoppedSlot,
      title: t('Zen nie odbiera w tle'),
      body: t('Android zatrzymał działanie w tle. Dotknij, żeby wznowić.'),
      createdAtMillis: createdAtMillis,
      routeKey: buildInboxRouteKey(),
      slotKey: kBackgroundRuntimeStoppedSlot,
      suppressionKey: kBackgroundRuntimeStoppedSlot,
      category: RuntimeSystemNotificationCategory.call,
    ),
  );
}

Future<AndroidBackgroundBootstrapPayload>
loadStoredAndroidBackgroundBootstrapPayload({
  AppSettingsStore? settingsStore,
  AppSecurityCredentialsStore? credentialsStore,
}) async {
  try {
    final AppSettingsStore resolvedSettingsStore;
    if (settingsStore != null) {
      resolvedSettingsStore = settingsStore;
    } else {
      final Directory supportDirectory = await ZenInstance.supportDirectory();
      resolvedSettingsStore = buildZenAppSettingsStoreForDirectory(
        supportDirectory,
      );
    }
    final AppSettings settings =
        await resolvedSettingsStore.load() ?? const AppSettings();
    final AppSecurityCredentialsStore resolvedCredentialsStore =
        credentialsStore ?? const SecureStorageCredentialsStore();
    final bool hasPassword = await loadStoredAppSecurityHasPassword(
      resolvedCredentialsStore,
    );
    // Encryption is always on. Without a password the device master key from
    // secure storage lets the background isolate decrypt stores on its own;
    // password mode requires a key handed over from the unlocked foreground.
    final Uint8List? deviceMasterKey = hasPassword
        ? null
        : await loadStoredDeviceMasterKey(resolvedCredentialsStore);
    return AndroidBackgroundBootstrapPayload(
      settings: settings,
      hasPassword: hasPassword,
      encryptionKey: deviceMasterKey,
    );
  } catch (error, stackTrace) {
    logZenError(
      'Loading stored Android background bootstrap payload failed',
      error,
      stackTrace,
    );
    return const AndroidBackgroundBootstrapPayload(
      settings: AppSettings(),
      hasPassword: false,
    );
  }
}

final Provider<bool> androidBackgroundRuntimeBridgeEnabledProvider =
    Provider<bool>((Ref ref) {
      return Platform.isAndroid;
    });

final Provider<AndroidBackgroundServiceController>
androidBackgroundServiceControllerProvider =
    Provider<AndroidBackgroundServiceController>((Ref ref) {
      return defaultAndroidBackgroundServiceController;
    });

final FlutterForegroundAndroidBackgroundServiceController
defaultAndroidBackgroundServiceController =
    FlutterForegroundAndroidBackgroundServiceController();

Future<void> prepareAndroidBackgroundRuntimeForForegroundLaunch() async {
  if (!Platform.isAndroid) {
    return;
  }
  await defaultAndroidBackgroundServiceController.initialize();
}

/// Whether Android lets the app keep its foreground service alive indefinitely.
///
/// Without the exemption OEM battery managers kill the service after a while,
/// and the plugin's own restart alarm cannot bring it back: starting a
/// foreground service from a background broadcast is refused on Android 12+.
Future<bool> isAndroidBackgroundDeliveryUnrestricted() async {
  if (!Platform.isAndroid) {
    return true;
  }
  try {
    return await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  } catch (error, stackTrace) {
    logZenError(
      'Reading the battery optimization state failed',
      error,
      stackTrace,
    );
    return false;
  }
}

/// Asks the user to exempt Zen from battery optimization. Returns the state
/// after the prompt, so the caller can reflect it without a second round trip.
Future<bool> requestAndroidBackgroundDeliveryExemption() async {
  if (!Platform.isAndroid) {
    return true;
  }
  try {
    await FlutterForegroundTask.requestIgnoreBatteryOptimization();
  } catch (error, stackTrace) {
    logZenError(
      'Requesting the battery optimization exemption failed',
      error,
      stackTrace,
    );
  }
  return isAndroidBackgroundDeliveryUnrestricted();
}

@immutable
final class AndroidBackgroundBootstrapPayload {
  const AndroidBackgroundBootstrapPayload({
    required this.settings,
    required this.hasPassword,
    this.encryptionKey,
    this.mode = AndroidBackgroundRuntimeMode.active,
  });

  final AppSettings settings;
  final bool hasPassword;
  final Uint8List? encryptionKey;

  /// Mode the task isolate should converge to once it applies this payload.
  final AndroidBackgroundRuntimeMode mode;

  AndroidBackgroundBootstrapPayload withMode(
    AndroidBackgroundRuntimeMode mode,
  ) {
    return AndroidBackgroundBootstrapPayload(
      settings: settings,
      hasPassword: hasPassword,
      encryptionKey: encryptionKey,
      mode: mode,
    );
  }

  /// Local encryption is always on; password mode or an uninitialized device
  /// master key cannot access sealed storage without the key handed over.
  bool get requiresUnlockedDataAccess => hasPassword || encryptionKey == null;

  Map<String, dynamic> toData() {
    return <String, dynamic>{
      'type': 'bootstrap',
      'inboxLimitMb': settings.inboxLimitMb,
      'autoCleanupDays': settings.autoCleanupDays,
      'notificationDelaySeconds': settings.notificationDelaySeconds,
      'lockMode': settings.lockMode.index,
      'backgroundLockDelaySeconds': settings.backgroundLockDelaySeconds,
      'hasPassword': hasPassword,
      'encryptionKey': encryptionKey == null
          ? null
          : base64Encode(encryptionKey!),
      'mode': mode.name,
    };
  }

  static AndroidBackgroundBootstrapPayload? fromData(Object data) {
    if (data is! Map<Object?, Object?>) {
      return null;
    }
    if ((data['type'] as String?) != 'bootstrap') {
      return null;
    }
    final String? encodedKey = (data['encryptionKey'] as String?)?.trim();
    return AndroidBackgroundBootstrapPayload(
      settings: AppSettings(
        inboxLimitMb:
            (data['inboxLimitMb'] as num?)?.toInt() ??
            AppSettings.defaultInboxLimitMb,
        autoCleanupDays:
            (data['autoCleanupDays'] as num?)?.toInt() ??
            AppSettings.defaultAutoCleanupDays,
        notificationDelaySeconds:
            (data['notificationDelaySeconds'] as num?)?.toInt() ??
            AppSettings.defaultNotificationDelaySeconds,
        lockMode: AppSettings.lockModeFromStorage(
          (data['lockMode'] as num?)?.toInt() ?? AppLockMode.background.index,
        ),
        backgroundLockDelaySeconds:
            (data['backgroundLockDelaySeconds'] as num?)?.toInt() ??
            AppSettings.defaultBackgroundLockDelaySeconds,
      ),
      hasPassword: (data['hasPassword'] as bool?) ?? false,
      encryptionKey: encodedKey == null || encodedKey.isEmpty
          ? null
          : Uint8List.fromList(base64Decode(encodedKey)),
      // A payload without a mode (the on-disk fallback used when the
      // service restarts itself with no app around) means "own the node".
      mode:
          (data['mode'] as String?) == AndroidBackgroundRuntimeMode.standby.name
          ? AndroidBackgroundRuntimeMode.standby
          : AndroidBackgroundRuntimeMode.active,
    );
  }
}

abstract interface class AndroidBackgroundServiceController {
  Future<void> initialize();

  Future<bool> isRunning();

  /// Signals the parked task isolate that the app is still running.
  void sendHeartbeat();

  /// Makes sure the foreground service exists and drives it to
  /// [AndroidBackgroundBootstrapPayload.mode].
  ///
  /// Resolves to `true` only once the task isolate confirmed it reached the
  /// requested mode, so the caller can rely on the background node being up
  /// (active) or fully torn down (standby) before touching its own node.
  Future<bool> start(
    AndroidBackgroundBootstrapPayload payload, {
    CallSession? activeCall,
  });

  Future<void> stop();
}

final class NoopAndroidBackgroundServiceController
    implements AndroidBackgroundServiceController {
  const NoopAndroidBackgroundServiceController();

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isRunning() async => false;

  @override
  void sendHeartbeat() {}

  @override
  Future<bool> start(
    AndroidBackgroundBootstrapPayload payload, {
    CallSession? activeCall,
  }) async => false;

  @override
  Future<void> stop() async {}
}

final class FlutterForegroundAndroidBackgroundServiceController
    implements AndroidBackgroundServiceController {
  /// How long to wait for the task isolate to confirm a mode change. Bringing
  /// a Yggdrasil node up or down is the slow part; past this the caller falls
  /// back to its own recovery instead of blocking the UI.
  static const Duration _modeAckTimeout = Duration(seconds: 10);

  /// How often an unacknowledged mode request is repeated.
  static const Duration _modeResendInterval = Duration(milliseconds: 1200);

  bool _initialized = false;
  Completer<void>? _pendingModeAck;
  AndroidBackgroundRuntimeMode? _pendingMode;
  List<ForegroundServiceTypes>? _runningServiceTypes;

  /// Tells the parked service the app is still here. Silence is the signal
  /// that the UI isolate is gone and the service has to own the node again.
  @override
  void sendHeartbeat() {
    if (!Platform.isAndroid || !_initialized) {
      return;
    }
    try {
      FlutterForegroundTask.sendDataToTask(<String, Object?>{
        'type': _kRuntimeHeartbeatType,
      });
    } catch (error, stackTrace) {
      logZenError(
        'Sending the background runtime heartbeat failed',
        error,
        stackTrace,
      );
    }
  }

  @override
  Future<void> initialize() async {
    if (_initialized || !Platform.isAndroid) {
      return;
    }
    // Task -> main channel. Without it the handoff is blind: the app cannot
    // tell whether the service isolate already released the node.
    FlutterForegroundTask.initCommunicationPort();
    FlutterForegroundTask.addTaskDataCallback(_handleTaskData);
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: kAndroidBackgroundChannelId,
        channelName: t('Zen — działanie w tle'),
        channelDescription: t(
          'Ciche powiadomienie, którego Android wymaga, żeby Zen odbierał '
          'wiadomości i połączenia w tle. Bez ikony na pasku stanu; '
          'można je przesunąć albo całkiem wyłączyć — Zen działa dalej.',
        ),
        // Minimum: no icon in the status bar, folded at the bottom of the
        // shade, nothing on the lock screen.
        channelImportance: NotificationChannelImportance.MIN,
        priority: NotificationPriority.MIN,
        visibility: NotificationVisibility.VISIBILITY_SECRET,
        playSound: false,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // Drives the standby watchdog in the task isolate.
        eventAction: ForegroundTaskEventAction.repeat(
          kAndroidBackgroundHeartbeatInterval.inMilliseconds,
        ),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    // Notifications and the rest are asked for on the permissions screen
    // (§25.2: first start and Ustawienia), never on their own at startup.
    // Which service type fits this Android; [start] waits for it.
    unawaited(loadAndroidSdkInt());
    _initialized = true;
  }

  @override
  Future<bool> isRunning() async {
    if (!Platform.isAndroid) {
      return false;
    }
    try {
      return await FlutterForegroundTask.isRunningService;
    } catch (error, stackTrace) {
      logZenError(
        'Checking Android background service state failed',
        error,
        stackTrace,
      );
      return false;
    }
  }

  @override
  Future<bool> start(
    AndroidBackgroundBootstrapPayload payload, {
    CallSession? activeCall,
  }) async {
    if (!Platform.isAndroid) {
      return false;
    }
    await initialize();
    final List<ForegroundServiceTypes> serviceTypes =
        foregroundServiceTypesForCallSession(
          activeCall,
          androidSdkInt: await loadAndroidSdkInt(),
        );
    // A live service keeps the foregroundServiceType it was started with, and
    // background microphone/camera capture needs the matching type. Recycling
    // is only safe while the app is on screen, which a standby request always
    // is - a handoff runs from the background, where Android would refuse the
    // restart and leave the app with no service at all.
    final bool mayRecycle =
        payload.mode == AndroidBackgroundRuntimeMode.standby;
    if (mayRecycle &&
        await isRunning() &&
        !_sameServiceTypes(_runningServiceTypes, serviceTypes)) {
      await stop();
      _runningServiceTypes = null;
    }
    if (!await isRunning()) {
      final ServiceRequestResult result =
          await FlutterForegroundTask.startService(
            serviceTypes: serviceTypes,
            notificationTitle: 'Zen',
            notificationText: _backgroundServiceNotificationText(
              activeCall,
              mode: payload.mode,
            ),
            notificationIcon: const NotificationIcon(
              metaDataName: 'com.roj.zen.service.NOTIFICATION_ICON',
            ),
            callback: _androidBackgroundRuntimeTaskEntryPoint,
          );
      if (result is! ServiceRequestSuccess) {
        // Android 12+ rejects a foreground-service start once the app is in
        // the background, which is why the service is started from the
        // foreground and only parked afterwards.
        logZenError(
          'Starting the Android background service failed',
          result is ServiceRequestFailure ? result.error : result,
          StackTrace.current,
        );
        return false;
      }
      _runningServiceTypes = serviceTypes;
    }
    return _requestMode(payload);
  }

  static bool _sameServiceTypes(
    List<ForegroundServiceTypes>? current,
    List<ForegroundServiceTypes> wanted,
  ) {
    if (current == null || current.length != wanted.length) {
      return false;
    }
    for (int index = 0; index < wanted.length; index += 1) {
      if (current[index] != wanted[index]) {
        return false;
      }
    }
    return true;
  }

  /// Sends the payload and waits for the task isolate's acknowledgement.
  Future<bool> _requestMode(AndroidBackgroundBootstrapPayload payload) async {
    final Completer<void> completer = Completer<void>();
    _pendingModeAck = completer;
    _pendingMode = payload.mode;
    // The very first message can race the task isolate's engine coming up and
    // be dropped; applying the payload is idempotent, so keep resending until
    // it is acknowledged rather than letting the task fall back to its
    // on-disk default.
    final Timer resendTimer = Timer.periodic(_modeResendInterval, (
      Timer timer,
    ) {
      if (completer.isCompleted) {
        timer.cancel();
        return;
      }
      FlutterForegroundTask.sendDataToTask(payload.toData());
    });
    try {
      FlutterForegroundTask.sendDataToTask(payload.toData());
      await completer.future.timeout(_modeAckTimeout);
      return true;
    } on TimeoutException {
      logZenWarning(
        'Background runtime did not confirm "${payload.mode.name}" mode within '
        '${_modeAckTimeout.inSeconds}s',
      );
      return false;
    } catch (error, stackTrace) {
      logZenError(
        'Requesting background runtime mode failed',
        error,
        stackTrace,
      );
      return false;
    } finally {
      resendTimer.cancel();
      if (identical(_pendingModeAck, completer)) {
        _pendingModeAck = null;
        _pendingMode = null;
      }
    }
  }

  void _handleTaskData(Object data) {
    if (data is! Map<Object?, Object?>) {
      return;
    }
    if (data['type'] != _kRuntimeModeAckType) {
      return;
    }
    final Completer<void>? completer = _pendingModeAck;
    final AndroidBackgroundRuntimeMode? expected = _pendingMode;
    if (completer == null || completer.isCompleted || expected == null) {
      return;
    }
    if (data['mode'] != expected.name) {
      return;
    }
    completer.complete();
  }

  @override
  Future<void> stop() async {
    if (!Platform.isAndroid) {
      return;
    }
    if (!await isRunning()) {
      return;
    }
    // First the word that this stop is the app's own doing (a restart with
    // other types): otherwise the service would tell the person that
    // Android shut Zen down. Both go down the same channel, in order.
    try {
      FlutterForegroundTask.sendDataToTask(<String, Object?>{
        'type': kAndroidBackgroundStopRequestType,
      });
    } catch (error, stackTrace) {
      logZenError(
        'Announcing the background service stop failed',
        error,
        stackTrace,
      );
    }
    await FlutterForegroundTask.stopService();
  }
}

class AndroidBackgroundRuntimeBridge extends ConsumerStatefulWidget {
  const AndroidBackgroundRuntimeBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<AndroidBackgroundRuntimeBridge> createState() =>
      _AndroidBackgroundRuntimeBridgeState();
}

final class _AndroidBackgroundRuntimeBridgeState
    extends ConsumerState<AndroidBackgroundRuntimeBridge>
    with WidgetsBindingObserver {
  /// How long to wait before retrying a foreground service start that the
  /// system refused, so a rebuild storm cannot turn into a retry storm.
  static const Duration _standbyRetryBackoff = Duration(seconds: 30);

  bool _initialized = false;
  bool _syncScheduled = false;
  bool _syncInFlight = false;
  bool _syncQueued = false;
  bool _handoffActive = false;

  /// The app's `ZenCore` was stopped for the handoff: the service runs the
  /// same modules meanwhile, and only one of them may do the duties.
  bool _coreHandedOff = false;
  int? _lastBackgroundHandoffGeneration;
  AndroidBackgroundRuntimeMode? _lastConfirmedMode;
  String? _lastParkedCallSignature;
  DateTime? _lastStandbyFailureAt;

  bool _isObserving = false;
  Timer? _heartbeatTimer;

  @override
  void initState() {
    super.initState();
    if (!ref.read(androidBackgroundRuntimeBridgeEnabledProvider)) {
      return;
    }
    // The sync must not depend on a widget rebuild. Flutter disables frames
    // before it dispatches `hidden`/`paused` to observers, so `scheduleFrame`
    // (and with it every rebuild and post-frame callback) is a no-op from the
    // moment the app leaves the screen - which is exactly when the handoff to
    // the foreground service has to happen.
    _isObserving = true;
    WidgetsBinding.instance.addObserver(this);
    androidScreenCaptureActive.addListener(_onScreenCaptureChanged);
    androidPrepareScreenCapture = () async {
      if (!mounted) {
        return;
      }
      await _ensureServiceStandby(
        ref.read(androidBackgroundServiceControllerProvider),
      );
    };
    unawaitedLogged(
      _initialize(),
      context: 'Android background runtime bridge initialization failed',
    );
  }

  void _onScreenCaptureChanged() {
    if (_initialized && mounted) {
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    androidScreenCaptureActive.removeListener(_onScreenCaptureChanged);
    androidPrepareScreenCapture = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_isObserving) {
      WidgetsBinding.instance.removeObserver(this);
    }
    super.dispose();
  }

  /// Keeps the heartbeat running exactly while this isolate owns the node.
  ///
  /// Stopping it is what lets the parked service notice the app is gone, so it
  /// must never outlive local ownership of the node.
  void _syncHeartbeat({required bool ownsNode}) {
    if (!ownsNode) {
      _heartbeatTimer?.cancel();
      _heartbeatTimer = null;
      return;
    }
    ref.read(androidBackgroundServiceControllerProvider).sendHeartbeat();
    if (_heartbeatTimer != null) {
      return;
    }
    _heartbeatTimer = Timer.periodic(kAndroidBackgroundHeartbeatInterval, (_) {
      if (!mounted) {
        return;
      }
      ref.read(androidBackgroundServiceControllerProvider).sendHeartbeat();
      // Frames stop while the app is off screen, so a deferred handoff has no
      // rebuild to ride on; this tick is what eventually runs it.
      if (ref.read(socialHubControllerProvider).lifecycle.isBackgroundLike) {
        _scheduleSync();
      }
    });
  }

  /// Whether the WebRTC session in *this* isolate is on a live call.
  ///
  /// The relay a call runs over belongs to this isolate's Yggdrasil node, so
  /// handing the node to the service mid-call cuts the media: the call simply
  /// went dead the moment the app left the screen. The foreground service is
  /// already holding the microphone/camera types for the call, so the process
  /// survives without the handoff.
  bool _localMediaOwnsActiveCall() {
    final CallSession? activeCall = ref
        .read(socialHubControllerProvider)
        .activeCall;
    if (activeCall == null) {
      return false;
    }
    return ref.read(callMediaSessionControllerProvider).activeCallId ==
            activeCall.id ||
        ref.read(groupCallMediaProvider).activeCallId == activeCall.id;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_initialized) {
      return;
    }
    // `RuntimeLifecycleBridge` is an ancestor, so it has already published the
    // new lifecycle snapshot by the time this runs.
    _scheduleSync();
  }

  @override
  Widget build(BuildContext context) {
    final bool enabled = ref.watch(
      androidBackgroundRuntimeBridgeEnabledProvider,
    );
    if (!enabled) {
      return widget.child;
    }
    ref.watch(appSettingsControllerProvider);
    ref.watch(runtimeNodeSnapshotProvider);
    ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.lifecycle,
      ),
    );
    // A call starting or ending changes which foreground service types the
    // service needs, and that can only be fixed while the app is on screen.
    ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.activeCall?.status,
      ),
    );
    ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.activeCall?.kind,
      ),
    );
    if (_initialized) {
      _scheduleSync();
    }
    return widget.child;
  }

  Future<void> _initialize() async {
    await ref.read(androidBackgroundServiceControllerProvider).initialize();
    if (!mounted) {
      return;
    }
    _initialized = true;
    _scheduleSync();
    // Permissions are asked for on the permissions screen (§25.2), not
    // here: several system dialogs at once at every start got in the way.
  }

  void _scheduleSync() {
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    // A microtask, not a post-frame callback: frames stop the instant the app
    // is backgrounded, and this work has to run precisely then.
    scheduleMicrotask(() {
      _syncScheduled = false;
      if (!mounted) {
        return;
      }
      unawaitedLogged(
        _runSyncLoop(),
        context: 'Android background runtime sync loop failed',
      );
    });
  }

  Future<void> _runSyncLoop() async {
    if (_syncInFlight) {
      _syncQueued = true;
      return;
    }
    _syncInFlight = true;
    try {
      do {
        _syncQueued = false;
        await _syncRuntimeState();
      } while (_syncQueued && mounted);
    } finally {
      _syncInFlight = false;
    }
  }

  Future<void> _syncRuntimeState() async {
    if (!mounted) {
      return;
    }
    final LifecycleSnapshot lifecycle = ref
        .read(socialHubControllerProvider)
        .lifecycle;
    if (lifecycle.isBackgroundLike) {
      await _handoffToBackgroundService(lifecycle);
      return;
    }
    _lastBackgroundHandoffGeneration = null;
    await _restoreForegroundRuntime();
  }

  /// Snapshot of everything the service isolate needs, or `null` when the app
  /// is locked and cannot hand over a usable key.
  Future<AndroidBackgroundBootstrapPayload?> _buildPayload(
    AndroidBackgroundRuntimeMode mode,
  ) async {
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final AppSettings settings = ref.read(appSettingsControllerProvider);
    final Uint8List? encryptionKey = await security.currentEncryptionKey();
    final AndroidBackgroundBootstrapPayload payload =
        AndroidBackgroundBootstrapPayload(
          settings: settings,
          hasPassword: security.hasPassword,
          encryptionKey: encryptionKey,
          mode: mode,
        );
    if (mode == AndroidBackgroundRuntimeMode.active &&
        payload.requiresUnlockedDataAccess &&
        encryptionKey == null) {
      return null;
    }
    return payload;
  }

  Future<void> _handoffToBackgroundService(LifecycleSnapshot lifecycle) async {
    if (_handoffActive) {
      return;
    }
    if (_localMediaOwnsActiveCall()) {
      // Keep the node here until the call is over. Left unset so the next
      // sync of this same lifecycle generation retries once it ends.
      _lastBackgroundHandoffGeneration = null;
      _syncHeartbeat(ownsNode: true);
      return;
    }
    if (_lastBackgroundHandoffGeneration == lifecycle.generation) {
      return;
    }
    _lastBackgroundHandoffGeneration = lifecycle.generation;
    logZenMessage(
      'Handing the runtime to the background service '
      '(${lifecycle.visibility.name})',
    );
    final AndroidBackgroundBootstrapPayload? payload = await _buildPayload(
      AndroidBackgroundRuntimeMode.active,
    );
    if (payload == null) {
      logZenWarning(
        'Handoff skipped: the app is locked, so no key can be handed over.',
      );
      return;
    }
    if (!mounted) {
      return;
    }
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    final CallSession? activeCall = ref
        .read(socialHubControllerProvider)
        .activeCall;
    // The service serves posts, photos and videos to friends while the app
    // is away; only one process may write the ledger on disk at a time.
    await ref.read(ledgerNodeProvider)?.suspend();
    if (!mounted) {
      return;
    }
    // Park this isolate node first: the identity key is shared, so a second
    // Yggdrasil node must never be up while this one still holds the mesh
    // session.
    await runtime.stop();
    if (!mounted) {
      return;
    }
    // The service runs the app's own modules (one `ZenCore`, one code
    // path): the app's duties pause meanwhile, so the minute work and the
    // writes of the shared state happen in one isolate only.
    final ZenCore core = ref.read(zenCoreProvider);
    final bool coreWasRunning = core.isStarted;
    if (coreWasRunning) {
      await core.stop();
      if (!mounted) {
        return;
      }
    }
    _lastConfirmedMode = null;
    _lastParkedCallSignature = null;
    // The service is about to own the node; a heartbeat from here on would
    // only be noise.
    _syncHeartbeat(ownsNode: false);
    final bool started = await ref
        .read(androidBackgroundServiceControllerProvider)
        .start(payload, activeCall: activeCall);
    if (!mounted) {
      return;
    }
    if (!started) {
      // Nothing took the node over, so keep serving from the UI isolate for as
      // long as the process survives instead of going silently offline.
      logZenWarning(
        'Handoff failed: the service never confirmed it owns the node.',
      );
      await ref.read(ledgerNodeProvider)?.resume();
      await runtime.start();
      if (coreWasRunning) {
        _restartCore();
      }
      return;
    }
    _lastConfirmedMode = AndroidBackgroundRuntimeMode.active;
    _handoffActive = true;
    _coreHandedOff = coreWasRunning;
    logZenMessage('Background service owns the runtime node.');
  }

  Future<void> _restoreForegroundRuntime() async {
    final AndroidBackgroundServiceController controller = ref.read(
      androidBackgroundServiceControllerProvider,
    );
    // A null `_lastConfirmedMode` means this process has not parked the
    // service yet: either a fresh launch, or a launch on top of a service that
    // is still running the node from a previous session.
    final bool serviceOwnsNode =
        _handoffActive ||
        (_lastConfirmedMode == null && await controller.isRunning());
    if (!mounted) {
      return;
    }
    final bool parked = await _ensureServiceStandby(controller);
    if (!mounted) {
      return;
    }
    if (serviceOwnsNode && parked) {
      final LifecycleSnapshot currentLifecycle = ref
          .read(socialHubControllerProvider)
          .lifecycle;
      final SocialHubController socialHub = ref.read(
        socialHubControllerProvider.notifier,
      );
      await socialHub.hydrateFromStore();
      if (!mounted) {
        return;
      }
      await socialHub.setLifecycle(currentLifecycle);
      if (!mounted) {
        return;
      }
      _handoffActive = false;
    }
    // The service has let go of the ledger (or never had it): take it back,
    // with whatever it received meanwhile.
    if (!serviceOwnsNode || parked) {
      await ref.read(ledgerNodeProvider)?.resume();
      if (!mounted) {
        return;
      }
    }
    final RuntimeTransportSnapshot runtimeSnapshot = ref.read(
      runtimeNodeSnapshotProvider,
    );
    if (!runtimeSnapshot.serviceRunning) {
      await ref.read(runtimeNodeRuntimeProvider).start();
    }
    if (_coreHandedOff && (!serviceOwnsNode || parked) && mounted) {
      _coreHandedOff = false;
      _restartCore();
    }
  }

  /// Starts the app's `ZenCore` again after the service let go, and reloads
  /// what the service changed meanwhile. A locked app leaves it to the
  /// security gate, which starts the core once the app is unlocked.
  void _restartCore() {
    if (isSecurityBlockingUi(ref.read(appSecurityServiceProvider))) {
      return;
    }
    final ZenCore core = ref.read(zenCoreProvider);
    unawaitedLogged(
      core.start().then((_) => core.resumed()),
      context: 'Restarting ZenCore after the background service failed',
    );
  }

  /// Starts the foreground service while the app is still on screen and parks
  /// it without a node.
  ///
  /// Doing this here, rather than at the moment the app is backgrounded, is
  /// what makes the app survive being swiped out of recents: Android 12+
  /// refuses a foreground-service start from the background, and a process
  /// with no running service is killed outright on task removal.
  Future<bool> _ensureServiceStandby(
    AndroidBackgroundServiceController controller,
  ) async {
    final CallSession? activeCall = ref
        .read(socialHubControllerProvider)
        .activeCall;
    if (_lastConfirmedMode == AndroidBackgroundRuntimeMode.standby &&
        _lastParkedCallSignature == _callServiceSignature(activeCall)) {
      _syncHeartbeat(ownsNode: true);
      return true;
    }
    final DateTime? lastFailure = _lastStandbyFailureAt;
    if (lastFailure != null &&
        DateTime.now().difference(lastFailure) < _standbyRetryBackoff) {
      return false;
    }
    final AndroidBackgroundBootstrapPayload? payload = await _buildPayload(
      AndroidBackgroundRuntimeMode.standby,
    );
    if (payload == null || !mounted) {
      return false;
    }
    final bool parked = await controller.start(payload, activeCall: activeCall);
    if (!mounted) {
      return false;
    }
    if (parked) {
      _lastConfirmedMode = AndroidBackgroundRuntimeMode.standby;
      _lastParkedCallSignature = _callServiceSignature(activeCall);
      _lastStandbyFailureAt = null;
    } else {
      _lastConfirmedMode = null;
      _lastParkedCallSignature = null;
      _lastStandbyFailureAt = DateTime.now();
    }
    _syncHeartbeat(ownsNode: parked);
    return parked;
  }

  /// Everything about a call that changes the required service types.
  static String _callServiceSignature(CallSession? session) {
    // The raw values: the plugin's type class has no toString of its own, so
    // every type used to read the same and only the count told them apart.
    return foregroundServiceTypesForCallSession(
      session,
    ).map((ForegroundServiceTypes type) => '${type.rawValue}').join(',');
  }
}

final class BackgroundRuntimeEnvironment {
  const BackgroundRuntimeEnvironment({
    required this.container,
    required this.transport,
    required this.callMediaController,
    this.runtime,
  });

  /// The app's providers, built as the app builds them, with
  /// [zenHostProvider] set to [ZenHost.backgroundService].
  final ProviderContainer container;
  final SignalTransport transport;
  final CallMediaSessionController callMediaController;
  final RuntimeNodeRuntime? runtime;
}

/// The service's providers: the app's own ([ZenBootstrapResult]), over the
/// same stores, with the key the app handed over, and no call media (calls
/// are answered in the app).
Future<BackgroundRuntimeEnvironment> buildHeadlessBackgroundRuntimeEnvironment(
  AndroidBackgroundBootstrapPayload payload,
) async {
  final Directory supportDirectory = await ZenInstance.supportDirectory();
  final HeadlessAppSecurityService security = HeadlessAppSecurityService(
    settings: payload.settings,
    hasPassword: payload.hasPassword,
    encryptionKey: payload.encryptionKey,
  );
  final MemoryAppSettingsStore appSettingsStore = MemoryAppSettingsStore(
    payload.settings,
  );
  final ZenPersistentStores stores = buildZenPersistentStoresForDirectory(
    supportDirectory,
    appSettingsStore: appSettingsStore,
    dataProtector: EncryptedBinaryPayloadProtector(security),
  );
  final RuntimeSignalBootstrapConfig runtimeConfig =
      RuntimeSignalBootstrapConfig(
        waitTimeout: payload.settings.signalWaitTimeout,
        nodeConfigProtector: EncryptedBinaryPayloadProtector(security),
        // Signals wake the service as they arrive (a blocking wait in an
        // isolate of its own); this slow poll runs only if that wait fails.
        fallbackPollInterval: const Duration(seconds: 2),
        // The same setting and account secret as the app (§5.1 item 6).
        lanDiscovery: lanDiscoveryResolver(
          loadSettings: appSettingsStore.load,
          ledgerDisk: stores.ledgerDisk,
        ),
      );
  final RuntimeNodeRuntime runtime = buildDefaultRuntimeNodeRuntime(
    config: runtimeConfig,
  );
  final NoopCallMediaSessionController callMedia =
      NoopCallMediaSessionController();
  final ZenBootstrapResult app = ZenBootstrapResult(
    runtime: runtime,
    runtimeConfig: runtimeConfig,
    appSecurityService: security,
    initialSettings: payload.settings,
    stores: stores,
  );
  final ProviderContainer container = ProviderContainer(
    overrides: [
      ...app.buildProviderOverrides(
        // Read by the coordinator itself, which must not run on an empty
        // stand-in (see [HeadlessBackgroundRuntimeCoordinator.start]).
        socialHubAutoHydrate: false,
        socialHubSeed: SocialHubState.empty(
          lifecycle: _backgroundLifecycleSnapshot(),
        ),
      ),
      zenHostProvider.overrideWithValue(ZenHost.backgroundService),
      ...buildCallMediaSessionProviderOverrides(controller: callMedia),
    ],
  );
  return BackgroundRuntimeEnvironment(
    container: container,
    // The relay-aware transport, not the raw runtime: frames must pass the
    // relay layer (acks, de-duplication, relayed mail) here as well.
    transport: container.read(signalTransportProvider),
    callMediaController: callMedia,
    runtime: runtime,
  );
}

/// Runs Zen in the Android background service while the app is away: the
/// same `ZenCore` as the app (`zenAppModules`, one code path), started on
/// the app's state, plus what only the service does — the power-button
/// alarm, alarm waves from phones around and its own notification.
final class HeadlessBackgroundRuntimeCoordinator {
  HeadlessBackgroundRuntimeCoordinator({required this.environment});

  final BackgroundRuntimeEnvironment environment;

  /// The app's modules, running here.
  ZenCore? _core;

  /// Stops following calls (they change the service notification's text).
  void Function()? _stopCallText;

  /// People nearby while the app is away (§15, §16.3): alarm waves from
  /// phones around and, when allowed, a short look around now and then.
  NearbyKeeper? _nearbyKeeper;

  /// Set once [dispose] began: late work (an alarm's position) stops.
  bool _disposed = false;

  /// Last text pushed onto the service notification.
  ///
  /// A ringing call re-sends its invite once per second, and every frame
  /// could post the notification again: re-posting the unchanged
  /// notification makes the shade entry flash as if a new call notification
  /// kept arriving.
  String? _lastServiceNotificationText;

  ProviderContainer get _container => environment.container;

  Future<void> start() async {
    final SocialHubController controller = _container.read(
      socialHubControllerProvider.notifier,
    );
    await _container
        .read(runtimeSystemNotificationServiceProvider)
        .initialize(
          onOpenRoute: controller.requestLaunchFromRouteKey,
          onAction: _handleNotificationAction,
        );
    bindIncomingCallPlatformHandler((String action, String peerAddress) async {
      await _handleNotificationAction(
        action == 'accept'
            ? 'accept_call'
            : action == 'decline'
            ? 'decline_call'
            : action,
        peerAddress,
      );
    });
    // Hydration has to succeed before anything else runs. On the empty seed
    // state every incoming signal is dropped (no peer is a known friend) and
    // the first lifecycle write would overwrite the real snapshot with
    // nothing - so let a failure propagate instead of running degraded.
    await controller.hydrateFromStore();
    logZenMessage(
      'Background runtime hydrated '
      '(${_container.read(socialHubControllerProvider).friends.length} peers).',
    );
    await controller.setLifecycle(_backgroundLifecycleSnapshot());
    final callText = _container.listen<String>(
      socialHubControllerProvider.select(
        (SocialHubState s) => _backgroundServiceNotificationText(s.activeCall),
      ),
      (String? previous, String next) => unawaitedLogged(
        _syncForegroundServiceState(),
        context: 'Background service notification',
      ),
    );
    _stopCallText = callText.close;
    final ZenCore core = _container.read(zenCoreProvider);
    _core = core;
    await core.start();
    logZenMessage(
      'Background runtime started: ${core.runningModules.join(', ')}.',
    );
    await _startAlarmDuties();
    await _syncForegroundServiceState();
  }

  /// What this service does for alarms while it runs the network (§16.3):
  /// the power-button shortcut comes here, this person's running alarm is
  /// sent once more, and phones nearby are heard.
  Future<void> _startAlarmDuties() async {
    final MeetService meet = _container.read(meetServiceProvider);
    try {
      const AlarmShortcutChannel shortcut = AlarmShortcutChannel();
      if (Platform.isAndroid) {
        // First: a shortcut from now on comes here, not to the app that
        // just let the network go.
        await shortcut.setNodeOwner(true);
      }
      await meet.reload();
      if (Platform.isAndroid &&
          meet.book.alarmPowerButton &&
          meet.hasAlarmPin) {
        await shortcut.setEnabled(true);
      }
      // The shortcut fires as the screen goes off, while the app is
      // handing the network over: an alarm the app raised just then may
      // not have gone out.
      await meet.resendOwnAlarm();
    } catch (error, stackTrace) {
      logZenError('Background alarm duties did not start', error, stackTrace);
    }
    if (!Platform.isAndroid) {
      return;
    }
    try {
      // The app's "people nearby", kept working with nobody looking.
      final NearbyService nearby = _container.read(nearbyServiceProvider);
      final NearbyRadio radio = nearby.radio;
      final NearbyKeeper keeper = NearbyKeeper(
        nearby: nearby,
        inService: true,
        announceAlarmReceiver: radio is ChannelNearbyRadio
            ? radio.setAlarmReceiver
            : null,
      );
      _nearbyKeeper = keeper;
      await keeper.start();
      logZenMessage(
        'Background nearby started '
        '(alarm waves: ${keeper.receivesAlarms ? 'on' : 'off'}).',
      );
    } catch (error, stackTrace) {
      logZenError('Background nearby did not start', error, stackTrace);
    }
  }

  Future<void> _stopAlarmDuties() async {
    final NearbyKeeper? keeper = _nearbyKeeper;
    _nearbyKeeper = null;
    try {
      if (Platform.isAndroid) {
        // From now on the shortcut goes to the app again.
        await const AlarmShortcutChannel().setNodeOwner(false);
      }
      await keeper?.close();
    } catch (error, stackTrace) {
      logZenError('Stopping background nearby failed', error, stackTrace);
    }
  }

  /// The power-button shortcut while this service runs the network
  /// (§16.3): the same alarm as the button in the app.
  Future<void> onPowerShortcut() async {
    final MeetService meet = _container.read(meetServiceProvider);
    final ShortcutAlarmResult result = await raiseAlarmFromShortcut(meet);
    logZenMessage('Power-button alarm in the background: ${result.name}.');
    if (result != ShortcutAlarmResult.raised) {
      return;
    }
    // Sound too, when the person chose it for alarms (§16.3): the same
    // pieces as after the button. Android lets the service record only if
    // the microphone permission is there; without it nothing is recorded.
    if (meet.book.alarmRecordAudio) {
      AlarmAudioPump.start(meet);
    }
    // The position, if Android lets the service have it (often only the
    // last known one); the app sends fresh ones once it is opened.
    unawaitedLogged(() async {
      // Fresh when the permission is there (read under a `location`
      // foreground service); never asks: nobody is looking at the screen.
      final GeoFix? fix = await currentFixInBackground(
        timeout: const Duration(seconds: 15),
      );
      if (fix != null && !_disposed) {
        await meet.updateAlarmLocation(
          fix.lat,
          fix.lon,
          accuracy: fix.accuracy,
        );
      }
    }(), context: 'Alarm position in the background');
  }

  Future<void> dispose() async {
    _disposed = true;
    AlarmAudioPump.stop();
    await _stopAlarmDuties();
    _stopCallText?.call();
    _stopCallText = null;
    final ZenCore? core = _core;
    _core = null;
    await core?.stop();
    // Saved and closed before the app takes the ledger back.
    if (_container.exists(ledgerNodeProvider)) {
      try {
        await _container.read(ledgerNodeProvider)?.stop();
      } catch (error, stackTrace) {
        logZenError('Stopping the background ledger failed', error, stackTrace);
      }
    }
    await environment.transport.stop();
    await environment.callMediaController.close();
    environment.callMediaController.dispose();
    environment.runtime?.dispose();
    _container.dispose();
  }

  /// Handles the accept/decline buttons of a ringing-call notification.
  ///
  /// This isolate owns the notification whenever the app is not on screen, so
  /// without this the buttons of an incoming call were simply inert.
  Future<void> _handleNotificationAction(
    String actionId,
    String? payload,
  ) async {
    final SocialHubController controller = _container.read(
      socialHubControllerProvider.notifier,
    );
    final CallSession? session = _container
        .read(socialHubControllerProvider)
        .activeCall;
    if (session == null || session.status != CallSessionStatus.ringing) {
      return;
    }
    switch (actionId) {
      case 'decline_call':
        // Fully serviceable from here: declining is one signal plus a local
        // teardown, and needs no media capture.
        await controller.declineIncomingCall(peerAddress: session.peerAddress);
        await _syncForegroundServiceState();
        return;
      case 'accept_call':
        try {
          await _container
              .read(runtimeSystemNotificationServiceProvider)
              .dismissSlot(callNotificationSlotKey(session.peerAddress));
        } catch (_) {}
        // Answering needs the microphone and a renderer, which only the UI
        // isolate has. Bring the app up on the call route with the accept flag
        // set, so it performs the answer itself instead of showing the
        // accept/decline overlay again; the ringing state is already
        // persisted. The notification payload carries the plain ringing route
        // and must not be used here - it would drop that flag.
        await controller.requestLaunchFromRouteKey(
          buildCallRouteKey(
            peerAddress: session.peerAddress,
            title: session.displayName,
            autoAccept: true,
            callId: session.id,
          ),
        );
        try {
          FlutterForegroundTask.launchApp();
        } catch (error, stackTrace) {
          logZenError(
            'Launching the app for an accepted call failed',
            error,
            stackTrace,
          );
        }
        return;
      default:
        return;
    }
  }

  Future<void> _syncForegroundServiceState() async {
    if (!Platform.isAndroid) {
      return;
    }
    final CallSession? activeCall = _container
        .read(socialHubControllerProvider)
        .activeCall;
    final String notificationText = _backgroundServiceNotificationText(
      activeCall,
    );
    if (notificationText == _lastServiceNotificationText) {
      return;
    }
    _lastServiceNotificationText = notificationText;
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Zen',
        notificationText: notificationText,
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.roj.zen.service.NOTIFICATION_ICON',
        ),
      );
    } catch (error, stackTrace) {
      logZenError('Background service sync error', error, stackTrace);
    }
  }
}

/// The person's language, loading in the service isolate (started by its
/// entry point; [TaskHandler.onStart] waits for it before any notice).
Future<void>? _serviceLanguageLoad;

@pragma('vm:entry-point')
void _androidBackgroundRuntimeTaskEntryPoint() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();
      // The service's own notices (and the channels it registers) speak the
      // person's language, not the source Polish.
      unawaitedLogged(
        _serviceLanguageLoad = loadZenLanguage(),
        context: 'Loading the language in the background service failed',
      );
      FlutterForegroundTask.setTaskHandler(
        _ZenRewriteAndroidBackgroundTaskHandler(),
      );
    },
    (Object error, StackTrace stackTrace) {
      logZenError(
        'Android background runtime entrypoint failed',
        error,
        stackTrace,
      );
    },
  );
}

/// The service's task handler with [notices] instead of the system
/// notifications, so tests can see what the service tells the person.
@visibleForTesting
TaskHandler buildAndroidBackgroundTaskHandlerForTesting({
  required RuntimeSystemNotificationService notices,
}) {
  return _ZenRewriteAndroidBackgroundTaskHandler(noticeService: () => notices);
}

final class _ZenRewriteAndroidBackgroundTaskHandler extends TaskHandler {
  _ZenRewriteAndroidBackgroundTaskHandler({
    RuntimeSystemNotificationService Function()? noticeService,
  }) : _noticeServiceFactory = noticeService;

  final Completer<AndroidBackgroundBootstrapPayload> _bootstrapCompleter =
      Completer<AndroidBackgroundBootstrapPayload>();

  HeadlessBackgroundRuntimeCoordinator? _coordinator;

  /// Latest state the app asked for. Every queued reconcile converges to this,
  /// so out-of-order or duplicated messages cannot leave the node half-owned.
  AndroidBackgroundBootstrapPayload? _desired;
  Future<void> _transitions = Future<void>.value();
  bool _destroyed = false;

  /// When the app last proved it is alive. Only meaningful while parked.
  DateTime? _lastAppHeartbeat;

  /// Where the service's own notices go (tests); `null`: the system's.
  final RuntimeSystemNotificationService Function()? _noticeServiceFactory;

  /// Lazily created: only the service's own notices need it (parked without
  /// a key, stopped by Android), and those paths have no provider container
  /// to borrow one from.
  RuntimeSystemNotificationService? _notices;
  bool _noticesInitialized = false;

  /// One notice per parked-locked stretch; re-armed once the node actually
  /// comes up again.
  bool _lockedParkNoticeShown = false;

  /// The app said it is stopping the service itself (see
  /// [kAndroidBackgroundStopRequestType]).
  bool _stopRequestedByApp = false;

  /// The power-button shortcut (§16.3). It comes here while this service
  /// runs the network, or when the app is not listening at all.
  StreamSubscription<void>? _powerShortcut;

  /// A shortcut that came while no node ran here: raised once one does
  /// (within [kAlarmShortcutMaxDelay]).
  DateTime? _pendingPowerAlarmAt;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await (_serviceLanguageLoad ?? Future<void>.value());
    try {
      await ZenDiagnosticsLog.attach(
        await ZenInstance.supportDirectory(),
        source: 'svc',
      );
    } catch (error, stackTrace) {
      logZenError('Attaching the service log failed', error, stackTrace);
    }
    logZenMessage('Foreground service task started (${starter.name}).');
    _powerShortcut = const AlarmShortcutChannel().presses.listen(
      (_) => _onPowerShortcut(),
    );
    // Running again: a "Zen nie odbiera w tle" notice from an earlier end
    // of the service is no longer true. Before the node comes up, so the
    // node's own notification handlers are the last ones set up.
    await _withdrawStoppedNotice();
    // No app around (boot, package replace, or a self-restart after the
    // process was killed) means nobody will send a payload: fall back to the
    // stored one, which always asks for the node.
    final AndroidBackgroundBootstrapPayload payload = await _bootstrapCompleter
        .future
        .timeout(
          const Duration(seconds: 5),
          onTimeout: loadStoredAndroidBackgroundBootstrapPayload,
        );
    _request(payload);
    await _transitions;
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _checkStandbyWatchdog(timestamp);
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<Object?, Object?> &&
        data['type'] == _kRuntimeHeartbeatType) {
      _lastAppHeartbeat = DateTime.now();
      return;
    }
    if (data is Map<Object?, Object?> &&
        data['type'] == kAndroidBackgroundStopRequestType) {
      _stopRequestedByApp = true;
      return;
    }
    final AndroidBackgroundBootstrapPayload? payload =
        AndroidBackgroundBootstrapPayload.fromData(data);
    if (payload == null) {
      return;
    }
    if (!_bootstrapCompleter.isCompleted) {
      _bootstrapCompleter.complete(payload);
      return;
    }
    _request(payload);
  }

  /// Takes the node over when the app stops reporting in while parked.
  ///
  /// Without it, an app whose engine is destroyed (swiped from recents) leaves
  /// the service parked with no node at all: no mesh, no incoming calls, no
  /// notifications — until the app is opened again.
  void _checkStandbyWatchdog(DateTime now) {
    if (_destroyed) {
      return;
    }
    final AndroidBackgroundBootstrapPayload? desired = _desired;
    if (desired == null ||
        desired.mode != AndroidBackgroundRuntimeMode.standby) {
      return;
    }
    final DateTime? lastHeartbeat = _lastAppHeartbeat;
    if (lastHeartbeat != null &&
        now.difference(lastHeartbeat) < kAndroidBackgroundHeartbeatTimeout) {
      return;
    }
    logZenWarning(
      'No app heartbeat for '
      '${kAndroidBackgroundHeartbeatTimeout.inSeconds}s while parked — the '
      'service is taking the runtime node over.',
    );
    _lastAppHeartbeat = now;
    _request(desired.withMode(AndroidBackgroundRuntimeMode.active));
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    if (isTimeout) {
      logZenWarning(
        'Android ended the background service: its type ran out of time.',
      );
    }
    // The notice first: with the service gone, Android may end the whole
    // process at any moment, and the teardown below can take a while.
    if (backgroundStopNeedsNotice(
      isTimeout: isTimeout,
      stopRequestedByApp: _stopRequestedByApp,
    )) {
      await _notifyStoppedByAndroid(timestamp);
    }
    await _powerShortcut?.cancel();
    _powerShortcut = null;
    await _transitions;
    await _coordinator?.dispose();
    _coordinator = null;
  }

  /// The service's own notification service, ready to post; `null` where
  /// there is none (not Android, outside tests).
  Future<RuntimeSystemNotificationService?> _readyNotices() async {
    final RuntimeSystemNotificationService? service = _notices ??=
        _createNotices();
    if (service == null) {
      return null;
    }
    if (!_noticesInitialized) {
      _noticesInitialized = true;
      await service.initialize(
        onOpenRoute: (String routeKey) async {
          FlutterForegroundTask.launchApp();
        },
      );
    }
    return service;
  }

  RuntimeSystemNotificationService? _createNotices() {
    final RuntimeSystemNotificationService Function()? factory =
        _noticeServiceFactory;
    if (factory != null) {
      return factory();
    }
    if (!Platform.isAndroid) {
      return null;
    }
    return FlutterLocalRuntimeSystemNotificationService(
      // No Activity is attached to the service engine.
      canRequestPermission: false,
    );
  }

  /// "Zen nie odbiera w tle": the person learns the phone stopped receiving,
  /// and one tap on it opens Zen, which starts the service again.
  Future<void> _notifyStoppedByAndroid(DateTime at) async {
    logZenWarning(
      'The background service ended without the app asking for it.',
    );
    try {
      final RuntimeSystemNotificationService? service = await _readyNotices();
      if (service == null) {
        return;
      }
      await showBackgroundRuntimeStoppedNotice(
        service,
        createdAtMillis: at.millisecondsSinceEpoch,
      );
    } catch (error, stackTrace) {
      logZenError(
        'Showing the background stop notice failed',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _withdrawStoppedNotice() async {
    try {
      final RuntimeSystemNotificationService? service = await _readyNotices();
      await service?.dismissSlot(kBackgroundRuntimeStoppedSlot);
    } catch (error, stackTrace) {
      logZenError(
        'Withdrawing the background stop notice failed',
        error,
        stackTrace,
      );
    }
  }

  /// 5× the power button: the alarm goes out from here once the node runs
  /// (right away when it already does).
  void _onPowerShortcut() {
    logZenMessage('Power-button alarm shortcut reached the service.');
    _pendingPowerAlarmAt = DateTime.now();
    if (_coordinator == null) {
      // Nobody runs the network: take it over now if the app is gone.
      _checkStandbyWatchdog(DateTime.now());
    }
    _transitions = _transitions.then((_) => _servePowerShortcut()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logZenError('Power-button alarm failed', error, stackTrace);
    });
  }

  /// Raises a pending shortcut alarm when a node runs here; otherwise it
  /// waits for the next activation.
  Future<void> _servePowerShortcut() async {
    final DateTime? at = _pendingPowerAlarmAt;
    final HeadlessBackgroundRuntimeCoordinator? coordinator = _coordinator;
    if (at == null || coordinator == null || _destroyed) {
      return;
    }
    _pendingPowerAlarmAt = null;
    if (DateTime.now().difference(at) > kAlarmShortcutMaxDelay) {
      logZenWarning('A power-button alarm waited too long and was dropped.');
      return;
    }
    try {
      await coordinator.onPowerShortcut();
    } catch (error, stackTrace) {
      logZenError('Power-button alarm failed', error, stackTrace);
    }
  }

  void _request(AndroidBackgroundBootstrapPayload payload) {
    if (payload.mode == AndroidBackgroundRuntimeMode.standby) {
      // A park request is itself proof the app is on screen and alive.
      _lastAppHeartbeat = DateTime.now();
    }
    _desired = payload;
    _transitions = _transitions.then((_) => _reconcile()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logZenError(
        'Background runtime mode transition failed',
        error,
        stackTrace,
      );
    });
  }

  Future<void> _reconcile() async {
    final AndroidBackgroundBootstrapPayload? payload = _desired;
    if (payload == null || _destroyed) {
      return;
    }
    AndroidBackgroundRuntimeMode mode = payload.mode;
    logZenMessage(
      'Service reconciling to "${mode.name}" '
      '(node ${_coordinator == null ? 'down' : 'up'}).',
    );
    if (mode == AndroidBackgroundRuntimeMode.active &&
        payload.requiresUnlockedDataAccess &&
        payload.encryptionKey == null) {
      // Password mode with no key handed over: the stores stay sealed, so
      // stand by rather than run a node that cannot read anything.
      logZenWarning(
        'Background runtime stayed parked: no unlocked key was handed over.',
      );
      mode = AndroidBackgroundRuntimeMode.standby;
      await _notifyLockedPark();
    }
    if (mode == AndroidBackgroundRuntimeMode.active) {
      if (_coordinator == null) {
        HeadlessBackgroundRuntimeCoordinator? coordinator;
        try {
          final BackgroundRuntimeEnvironment environment =
              await buildHeadlessBackgroundRuntimeEnvironment(payload);
          coordinator = HeadlessBackgroundRuntimeCoordinator(
            environment: environment,
          );
          if (_destroyed) {
            await coordinator.dispose();
            return;
          }
          _coordinator = coordinator;
          await coordinator.start();
          _lockedParkNoticeShown = false;
        } catch (error, stackTrace) {
          // Leaving a half-built coordinator in place would wedge the task
          // forever: every later reconcile sees a non-null `_coordinator`,
          // skips the start, and reports "active" for a node that does not
          // exist. Tear it down and report the mode actually reached, so the
          // app keeps serving from its own isolate instead of waiting on an
          // acknowledgement that never comes.
          logZenError(
            'Background runtime activation failed',
            error,
            stackTrace,
          );
          _coordinator = null;
          if (coordinator != null) {
            try {
              await coordinator.dispose();
            } catch (disposeError, disposeStackTrace) {
              logZenError(
                'Disposing a failed background runtime failed',
                disposeError,
                disposeStackTrace,
              );
            }
          }
          await _updateStandbyNotification();
          _acknowledge(AndroidBackgroundRuntimeMode.standby);
          return;
        }
      }
    } else {
      final HeadlessBackgroundRuntimeCoordinator? coordinator = _coordinator;
      _coordinator = null;
      if (coordinator != null) {
        await coordinator.dispose();
      }
      await _updateStandbyNotification();
    }
    logZenMessage('Service reached "${mode.name}".');
    _acknowledge(mode);
    if (mode == AndroidBackgroundRuntimeMode.active) {
      await _servePowerShortcut();
    }
  }

  /// Tells the user the parked service cannot take calls until they unlock.
  ///
  /// Without it, password mode fails silently: the service stays parked with
  /// no node, and nobody can tell why the phone never rings. Shown once per
  /// parked-locked stretch; the suppression key throttles any repeats.
  Future<void> _notifyLockedPark() async {
    if (_lockedParkNoticeShown) {
      return;
    }
    _lockedParkNoticeShown = true;
    try {
      final RuntimeSystemNotificationService? service = await _readyNotices();
      if (service == null) {
        return;
      }
      await showLockedBackgroundRuntimeNotice(
        service,
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (error, stackTrace) {
      logZenError(
        'Showing the locked background runtime notice failed',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _updateStandbyNotification() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Zen',
        notificationText: _backgroundServiceNotificationText(
          null,
          mode: AndroidBackgroundRuntimeMode.standby,
        ),
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.roj.zen.service.NOTIFICATION_ICON',
        ),
      );
    } catch (error, stackTrace) {
      logZenError('Standby notification update failed', error, stackTrace);
    }
  }

  /// Tells the app which mode was actually reached. A missing main isolate
  /// (the app was killed) simply drops the message.
  void _acknowledge(AndroidBackgroundRuntimeMode mode) {
    try {
      FlutterForegroundTask.sendDataToMain(<String, Object?>{
        'type': _kRuntimeModeAckType,
        'mode': mode.name,
      });
    } catch (error, stackTrace) {
      logZenError(
        'Acknowledging background runtime mode failed',
        error,
        stackTrace,
      );
    }
  }
}

LifecycleSnapshot _backgroundLifecycleSnapshot() {
  return LifecycleSnapshot(
    visibility: AppVisibilityState.background,
    generation: 1,
    capturedAtMillis: DateTime.now().millisecondsSinceEpoch,
  );
}
