import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/call_screen_share.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/alarm_kit.dart';
import 'package:zen/src/features/meet/alarm_shortcut.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/location.dart';
import 'package:zen/src/features/meet/locked_alarm.dart';
import 'package:zen/src/features/meet/locked_nearby.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/alarm_audio.dart';
import 'package:zen/src/features/neighbors/neighbors_providers.dart';
import 'package:zen/src/features/neighbors/neighbors_service.dart';
import 'package:zen/src/features/relay/locked_outbox.dart';
import 'package:zen/src/features/relay/locked_outbox_writer.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/update/background_update_check.dart';

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
  // Screen sharing: Android 14+ captures only under a service of
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
/// trigger a second node while the first one is still up. It is counted on a
/// monotonic clock that stands still while the phone sleeps (both isolates'
/// timers do too): after a long sleep the service never mistakes the app's
/// silence for its end. The end itself comes as a signal (ZenPower
/// "appGone", when the app's engine goes).
const Duration kAndroidBackgroundHeartbeatTimeout = Duration(seconds: 20);

/// How often the parked service wakes the phone to look at the heartbeats.
const Duration kAndroidStandbyWatchdogEvery = Duration(minutes: 1);

/// After this long in the background, unlocked or not, the app hands the
/// node to the service's receive-only mode, whatever the lock setting: no
/// presence, no account scans, no Wi-Fi Direct or Bluetooth links, no
/// ledger sync — only what friends send is kept (and calls and alarms ring).
const Duration kAndroidReceiveOnlyAfter = Duration(minutes: 5);

/// The receive-only threshold (tests make it shorter).
final Provider<Duration> androidReceiveOnlyAfterProvider = Provider<Duration>(
  (Ref ref) => kAndroidReceiveOnlyAfter,
);

/// Whether the app, in the background since [backgroundSince], should drop
/// to the service's receive-only mode at [now].
bool shouldDropToReceiveOnly({
  required DateTime? backgroundSince,
  required DateTime now,
  Duration after = kAndroidReceiveOnlyAfter,
}) {
  if (backgroundSince == null) {
    return false;
  }
  return !now.difference(backgroundSince).isNegative &&
      now.difference(backgroundSince) >= after;
}

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

/// Heads-up for a service parked because the app has not yet published what
/// it may receive with (not unlocked since it was installed or wiped).
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

/// The payload the service falls back to when no app is around to send one
/// (a boot, a self-restart): the settings, and "own the node".
///
/// No key of any kind: the service never holds the master key. It
/// receives with the background capability the app published, which it
/// reads itself.
Future<AndroidBackgroundBootstrapPayload>
loadStoredAndroidBackgroundBootstrapPayload({
  AppSettingsStore? settingsStore,
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
    return AndroidBackgroundBootstrapPayload(settings: settings);
  } catch (error, stackTrace) {
    logZenError(
      'Loading stored Android background bootstrap payload failed',
      error,
      stackTrace,
    );
    return const AndroidBackgroundBootstrapPayload(settings: AppSettings());
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

/// What the app tells the service: the settings it needs and the mode to
/// reach. Never a key.
@immutable
final class AndroidBackgroundBootstrapPayload {
  const AndroidBackgroundBootstrapPayload({
    required this.settings,
    this.mode = AndroidBackgroundRuntimeMode.active,
  });

  final AppSettings settings;

  /// Mode the task isolate should converge to once it applies this payload.
  final AndroidBackgroundRuntimeMode mode;

  AndroidBackgroundBootstrapPayload withMode(
    AndroidBackgroundRuntimeMode mode,
  ) {
    return AndroidBackgroundBootstrapPayload(settings: settings, mode: mode);
  }

  Map<String, dynamic> toData() {
    return <String, dynamic>{
      'type': 'bootstrap',
      'inboxLimitMb': settings.inboxLimitMb,
      'autoCleanupDays': settings.autoCleanupDays,
      'lockMode': settings.lockMode.index,
      'backgroundLockDelaySeconds': settings.backgroundLockDelaySeconds,
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
    return AndroidBackgroundBootstrapPayload(
      settings: AppSettings(
        inboxLimitMb:
            (data['inboxLimitMb'] as num?)?.toInt() ??
            AppSettings.defaultInboxLimitMb,
        autoCleanupDays:
            (data['autoCleanupDays'] as num?)?.toInt() ??
            AppSettings.defaultAutoCleanupDays,
        lockMode: AppSettings.lockModeFromStorage(
          (data['lockMode'] as num?)?.toInt() ?? AppLockMode.background.index,
        ),
        backgroundLockDelaySeconds:
            (data['backgroundLockDelaySeconds'] as num?)?.toInt() ??
            AppSettings.defaultBackgroundLockDelaySeconds,
      ),
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
        // No lock for the whole life of the service: with the screen off the
        // phone sleeps. Alarms wake it for the work that comes back and a
        // signal wakes it by itself; each holds it awake briefly
        // (zen_wake.dart, ZenPower.kt). Only a call holds it longer.
        allowWakeLock: false,
        allowWifiLock: false,
      ),
    );
    // Notifications and the rest are asked for on the permissions screen
    // (first start and Ustawienia), never on their own at startup.
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

/// Where the app publishes the background capability and finds what the
/// service kept while the app was locked.
final Provider<BackgroundVault> backgroundVaultProvider =
    Provider<BackgroundVault>((Ref ref) {
      return FileBackgroundVault(
        supportDirectory: ref.read(supportDirectoryResolverProvider),
        credentials: ref.read(appSecurityServiceProvider).credentialsStore,
        createKey: true,
      );
    });

/// Keeps the node where the master key is.
///
/// * On screen, and in the background while unlocked, this isolate runs the
///   node and the app's `ZenCore`; the foreground service stays parked
///   (started from the foreground, see `_ensureServiceStandby`) and only
///   listens for the heartbeat.
/// * Once the app locks — or its engine is gone, which the parked service
///   notices by the missing heartbeat — the service takes the node over in
///   its receive-only mode ([LockedReceiver]): no master key, only the
///   background capability this widget publishes while the app is unlocked.
/// * Back on screen and unlocked, this isolate takes the node back and
///   drains the sealed inbox into the app.
/// * While unlocked it keeps the alarm kit up to date: what the
///   locked service raises this person's alarm with; and the nearby kit
///   and the door kit: what it shows and recognises nearby with, and the
///   doors it runs.
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

  /// How long to wait before draining again when the node was not up yet.
  static const Duration _drainRetryDelay = Duration(seconds: 10);

  bool _initialized = false;
  bool _syncScheduled = false;
  bool _syncInFlight = false;
  bool _syncQueued = false;

  /// The service runs the node (receive-only) since this app locked.
  bool _handoffActive = false;
  bool _handoffInFlight = false;

  /// The app's `ZenCore` was stopped for the handoff: it starts again once
  /// this isolate has the node back.
  bool _coreHandedOff = false;
  AndroidBackgroundRuntimeMode? _lastConfirmedMode;
  String? _lastParkedCallSignature;
  DateTime? _lastStandbyFailureAt;

  bool _isObserving = false;
  Timer? _heartbeatTimer;

  /// Since when the app is in the background (wall clock: the time that
  /// counts here passes while the phone sleeps too); `null` on screen.
  DateTime? _backgroundSince;

  /// The phone (and Wi-Fi) is held awake for a call.
  bool _callHeld = false;

  AppSecurityService? _security;

  /// The public part of the inbox key (not a secret): kept, so the
  /// capability can still be published once a lock erased the master key.
  Uint8List? _inboxPublicKey;

  /// Fingerprint of the master key [_inboxPublicKey] belongs to.
  String? _inboxKeyOwner;
  String? _publishedSignature;
  Future<void> _publishing = Future<void>.value();

  bool _draining = false;

  /// Keeps the alarm kit in step with the alarm setup; made once
  /// the app is unlocked and its core runs.
  AlarmKitKeeper? _alarmKitKeeper;
  MeetService? _kitMeet;
  Future<void> _alarmKitWriting = Future<void>.value();

  /// A refresh waits behind the one running: more changes meanwhile ride
  /// on it.
  bool _alarmKitQueued = false;

  /// This widget emptied the inbox since the service last ran the node.
  bool _inboxDrained = false;
  Timer? _drainRetry;

  /// Keeps the nearby kit in step; made once the app is unlocked and its
  /// core runs, like the alarm kit's keeper.
  NearbyKitKeeper? _nearbyKitKeeper;

  /// Whose changes write the door kit again.
  NeighborsService? _kitNeighbors;
  String? _doorKitWritten;
  Future<void> _lockedKitsWriting = Future<void>.value();
  bool _lockedKitsQueued = false;

  /// Looks at the kits now and then: a new day moves the nearby kit's
  /// tokens on, also when nothing else changed.
  Timer? _lockedKitsTimer;

  /// Keeps the outbox kit (this device's queue, sealed for its recipients)
  /// in step for the locked service.
  LockedOutboxKitWriter? _outboxKitWriter;

  @override
  void initState() {
    super.initState();
    if (!ref.read(androidBackgroundRuntimeBridgeEnabledProvider)) {
      return;
    }
    // The sync must not depend on a widget rebuild. Flutter disables frames
    // before it dispatches `hidden`/`paused` to observers, so `scheduleFrame`
    // (and with it every rebuild and post-frame callback) is a no-op from the
    // moment the app leaves the screen - and the lock timer fires exactly
    // then, in the background.
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
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    _security = security;
    security.addListener(_onSecurityChanged);
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

  /// A lock (or an unlock) reaches the handoff straight away, frame or not.
  void _onSecurityChanged() {
    if (_initialized && mounted) {
      _scheduleSync();
    }
  }

  @override
  void dispose() {
    androidScreenCaptureActive.removeListener(_onScreenCaptureChanged);
    androidPrepareScreenCapture = null;
    _security?.removeListener(_onSecurityChanged);
    _security = null;
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _drainRetry?.cancel();
    _drainRetry = null;
    _lockedKitsTimer?.cancel();
    _lockedKitsTimer = null;
    _outboxKitWriter?.detach();
    _outboxKitWriter = null;
    _kitMeet?.removeListener(_onMeetChanged);
    _kitMeet = null;
    _kitNeighbors?.removeListener(_onKitSourceChanged);
    _kitNeighbors = null;
    if (_callHeld) {
      _callHeld = false;
      unawaited(ZenWake.holdForCall(false));
    }
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

  /// Holds the phone and Wi-Fi awake exactly while a call runs (the only
  /// long hold Zen takes).
  void _syncCallHold() {
    final CallSession? call = ref.read(socialHubControllerProvider).activeCall;
    final bool inCall =
        call != null &&
        !(call.isIncoming && call.status == CallSessionStatus.ringing);
    if (inCall == _callHeld) {
      return;
    }
    _callHeld = inCall;
    unawaited(ZenWake.holdForCall(inCall));
  }

  /// Whether the WebRTC session in *this* isolate is on a live call.
  ///
  /// The relay a call runs over belongs to this isolate's Yggdrasil node, so
  /// handing the node to the service mid-call cuts the media. The foreground
  /// service is already holding the microphone/camera types for the call, so
  /// the process survives without the handoff.
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
    // Whether the node runs, not every refresh of its numbers: a sync
    // writes kits and hashes them.
    ref.watch(
      runtimeNodeSnapshotProvider.select(
        (RuntimeTransportSnapshot snapshot) => snapshot.serviceRunning,
      ),
    );
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
    // Friends and groups as the service will recognise them while locked.
    ref.listen<String>(
      socialHubControllerProvider.select(backgroundContactsSignature),
      (String? previous, String next) {
        if (_initialized) {
          unawaitedLogged(
            _publishCapability(),
            context: 'Publishing the background capability failed',
          );
          unawaitedLogged(
            _publishAlarmKit(),
            context: 'Writing the alarm kit failed',
          );
        }
      },
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
    _attachOutboxKitWriter();
    _lockedKitsTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      if (mounted) {
        unawaitedLogged(
          _publishLockedKits(),
          context: 'Writing the locked kits failed',
        );
      }
    });
    // Permissions are asked for on the permissions screen, not
    // here: several system dialogs at once at every start got in the way.
  }

  /// The locked service keeps delivering this device's queue from the
  /// outbox kit: written whenever the queue changes, and before handoff.
  void _attachOutboxKitWriter() {
    final RelayEngine? relay = ref.read(relayEngineProvider);
    if (relay == null || _outboxKitWriter != null) {
      return;
    }
    final SupportDirectoryResolver support = ref.read(
      supportDirectoryResolverProvider,
    );
    final AppSecurityCredentialsStore credentials = ref
        .read(appSecurityServiceProvider)
        .credentialsStore;
    _outboxKitWriter = LockedOutboxKitWriter(
      engine: relay,
      write: (Object? json) => lockedOutboxKitFile(
        supportDirectory: support,
        credentials: credentials,
        createKey: true,
      ).write(json),
    )..attach();
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
    _syncCallHold();
    if (isSecurityBlockingUi(ref.read(appSecurityServiceProvider))) {
      await _handoffToReceiver();
      return;
    }
    final LifecycleSnapshot lifecycle = ref
        .read(socialHubControllerProvider)
        .lifecycle;
    if (lifecycle.isBackgroundLike) {
      final DateTime now = DateTime.now();
      final DateTime since = _backgroundSince ??= now;
      // Unlocked in the background: this isolate keeps the node and the
      // core for a while, so the master key never leaves it. After
      // kAndroidReceiveOnlyAfter it hands the node to the service's
      // receive-only mode anyway, whatever the lock setting ("Nigdy" and
      // long delays too): everything else the core does costs battery.
      if (shouldDropToReceiveOnly(
        backgroundSince: since,
        now: now,
        after: ref.read(androidReceiveOnlyAfterProvider),
      )) {
        logZenMessage('Long in the background: the service only receives.');
        await _handoffToReceiver();
      }
      return;
    }
    _backgroundSince = null;
    await _restoreForegroundRuntime();
  }

  AndroidBackgroundBootstrapPayload _payload(
    AndroidBackgroundRuntimeMode mode,
  ) {
    return AndroidBackgroundBootstrapPayload(
      settings: ref.read(appSettingsControllerProvider),
      mode: mode,
    );
  }

  /// The app locked: the node goes to the service, which receives without
  /// the master key.
  ///
  /// Everything is read before the first wait. A lock on screen replaces
  /// the app with the lock screen on the next frame, which removes this
  /// widget; the handoff must finish without it.
  Future<void> _handoffToReceiver() async {
    if (_handoffActive || _handoffInFlight) {
      return;
    }
    if (_localMediaOwnsActiveCall()) {
      // Keep the node here until the call is over; a later sync retries.
      _syncHeartbeat(ownsNode: true);
      return;
    }
    _handoffInFlight = true;
    _inboxDrained = false;
    // The phone may be asleep but for the alarm that woke it: it stays
    // awake until the service runs the node.
    unawaited(ZenWake.hold(const Duration(seconds: 45), tag: 'handoff'));
    final AndroidBackgroundServiceController controller = ref.read(
      androidBackgroundServiceControllerProvider,
    );
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    final ZenCore core = ref.read(zenCoreProvider);
    final LedgerNode? ledger = ref.read(ledgerNodeProvider);
    final CallSession? activeCall = ref
        .read(socialHubControllerProvider)
        .activeCall;
    final AndroidBackgroundBootstrapPayload payload = _payload(
      AndroidBackgroundRuntimeMode.active,
    );
    // Who counts as a contact, as of now (the key's public part is kept).
    final Future<void> published = _publishCapability();
    // The kits were written while the app was unlocked; one still being
    // written finishes before the service reads it.
    final Future<void> kitWritten = _alarmKitWriting;
    final Future<void> lockedKitsWritten = _lockedKitsWriting;
    // This device's queue, sealed for its recipients, for the service to
    // keep delivering.
    final Future<void> outboxKitWritten =
        _outboxKitWriter?.flush() ?? Future<void>.value();
    // The service is about to own the node; a heartbeat from here on would
    // only keep it parked.
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _lastConfirmedMode = null;
    _lastParkedCallSignature = null;
    logZenMessage('The app is locked: the service receives without the key.');
    try {
      await published;
      await kitWritten;
      await lockedKitsWritten;
      await outboxKitWritten;
      // Saved and closed: nothing writes the ledger while the app is locked.
      await ledger?.suspend();
      final bool coreWasRunning = core.isStarted;
      await core.stop();
      // Down first: the identity key is shared, so a second Yggdrasil node
      // must never be up while this one still holds the mesh session.
      await runtime.stop();
      final bool started = await controller.start(
        payload,
        activeCall: activeCall,
      );
      if (!started) {
        // With the heartbeat gone the parked service takes the node over by
        // itself (kAndroidBackgroundHeartbeatTimeout).
        logZenWarning('Handoff failed: the service did not confirm the node.');
      }
      if (mounted) {
        _handoffActive = started;
        _lastConfirmedMode = started
            ? AndroidBackgroundRuntimeMode.active
            : null;
        _coreHandedOff = _coreHandedOff || coreWasRunning;
      }
    } on Object catch (error, stackTrace) {
      logZenError('Handing the node to the service failed', error, stackTrace);
    } finally {
      _handoffInFlight = false;
      unawaited(ZenWake.release(tag: 'handoff'));
    }
  }

  Future<void> _restoreForegroundRuntime() async {
    final AndroidBackgroundServiceController controller = ref.read(
      androidBackgroundServiceControllerProvider,
    );
    // A null `_lastConfirmedMode` means this widget has not parked the
    // service yet: a fresh launch, an unlock (the lock screen replaced this
    // widget), or a launch on top of a service still running the node.
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
    // The node is free (or never was taken): the ledger comes back.
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
    if (!mounted) {
      return;
    }
    unawaitedLogged(
      _publishCapability(),
      context: 'Publishing the background capability failed',
    );
    await _drainInbox();
    // After the drain: an alarm the locked service raised is taken over
    // first, then the kit gets a new one.
    unawaitedLogged(
      _publishAlarmKit(),
      context: 'Writing the alarm kit failed',
    );
    unawaitedLogged(
      _publishLockedKits(),
      context: 'Writing the locked kits failed',
    );
  }

  void _onMeetChanged() {
    if (_initialized && mounted) {
      unawaitedLogged(
        _publishAlarmKit(),
        context: 'Writing the alarm kit failed',
      );
      unawaitedLogged(
        _publishLockedKits(),
        context: 'Writing the locked kits failed',
      );
    }
  }

  void _onKitSourceChanged() {
    if (_initialized && mounted) {
      unawaitedLogged(
        _publishLockedKits(),
        context: 'Writing the locked kits failed',
      );
    }
  }

  /// Writes the nearby kit and the door kit again when what they hold
  /// changed: this phone's tokens for the coming days, friends' keys to
  /// recognise them and the settings; the flat's door key and the mailbox
  /// doors run for friends. Only while unlocked with the core running (all
  /// of it is under the master key); everything is read before the first
  /// wait.
  Future<void> _publishLockedKits() {
    if (!mounted ||
        isSecurityBlockingUi(ref.read(appSecurityServiceProvider)) ||
        !ref.read(zenCoreProvider).isStarted) {
      return _lockedKitsWriting;
    }
    // Only once the friends were read: a kit without them must not replace
    // the one stored.
    if (!ref.read(socialHubControllerProvider.notifier).isHydrated ||
        ref.read(socialHubControllerProvider).snapshotUnreadable) {
      return _lockedKitsWriting;
    }
    final SupportDirectoryResolver support = ref.read(
      supportDirectoryResolverProvider,
    );
    final AppSecurityCredentialsStore credentials = ref
        .read(appSecurityServiceProvider)
        .credentialsStore;
    final NearbyKitKeeper keeper = _nearbyKitKeeper ??= NearbyKitKeeper(
      meet: ref.read(meetServiceProvider),
      write: (NearbyKit kit) => nearbyKitFile(
        supportDirectory: support,
        credentials: credentials,
        createKey: true,
      ).write(kit.toJson()),
      // Circles' dinners: reminded of while locked too.
      reminders: () => ref.read(circleServiceProvider).lockedReminders(),
    );
    final EncounterLog encounters = ref.read(encounterLogProvider);
    final NeighborsService neighbors = ref.read(neighborsServiceProvider);
    if (!identical(_kitNeighbors, neighbors)) {
      _kitNeighbors?.removeListener(_onKitSourceChanged);
      _kitNeighbors = neighbors..addListener(_onKitSourceChanged);
    }
    if (_lockedKitsQueued) {
      return _lockedKitsWriting;
    }
    _lockedKitsQueued = true;
    final BackgroundKitFile doorFile = lockedDoorKitFile(
      supportDirectory: support,
      credentials: credentials,
      createKey: true,
    );
    _lockedKitsWriting = _lockedKitsWriting
        .then((_) async {
          _lockedKitsQueued = false;
          await keeper.refresh(recording: encounters.recording);
          if (!neighbors.isLoaded) {
            return;
          }
          final LockedDoorKit door = LockedDoorKit(
            doorKey: neighbors.doorKey,
            mailboxDoorKeys: neighbors.hostedDoorKeys,
            // What tells a knock while locked (never the household's key).
            flatKey: neighbors.doorKey == null ? null : neighbors.profile?.key,
            doorToken: neighbors.doorKey == null ? null : neighbors.door,
            sealSeed: neighbors.doorKey == null ? null : neighbors.sealSeed,
            tempTokens: neighbors.tempDoorTokens,
          );
          final String signature = jsonEncode(door.toJson());
          if (signature != _doorKitWritten) {
            await doorFile.write(door.toJson());
            _doorKitWritten = signature;
          }
        })
        .catchError((Object error, StackTrace stackTrace) {
          _lockedKitsQueued = false;
          logZenError('Writing the locked kits failed', error, stackTrace);
        });
    return _lockedKitsWriting;
  }

  /// Writes the alarm kit again when the alarm setup changed: the
  /// friends it goes to (and their devices), the settings, the alarm going
  /// on. Only while unlocked with the core running (the setup is under the
  /// master key); everything is read before the first wait.
  Future<void> _publishAlarmKit() {
    if (!mounted ||
        isSecurityBlockingUi(ref.read(appSecurityServiceProvider)) ||
        !ref.read(zenCoreProvider).isStarted) {
      return _alarmKitWriting;
    }
    // Only once the friends were read: a kit without them must not replace
    // the one stored.
    if (!ref.read(socialHubControllerProvider.notifier).isHydrated ||
        ref.read(socialHubControllerProvider).snapshotUnreadable) {
      return _alarmKitWriting;
    }
    AlarmKitKeeper? keeper = _alarmKitKeeper;
    if (keeper == null) {
      final MeetService meet = ref.read(meetServiceProvider);
      keeper = _alarmKitKeeper = AlarmKitKeeper(
        meet: meet,
        store: FileAlarmKitStore(
          supportDirectory: ref.read(supportDirectoryResolverProvider),
          credentials: ref.read(appSecurityServiceProvider).credentialsStore,
          createKey: true,
        ),
      );
      _kitMeet = meet..addListener(_onMeetChanged);
    }
    if (_alarmKitQueued) {
      return _alarmKitWriting;
    }
    _alarmKitQueued = true;
    final AccountDirectoryHolder directories = ref.read(
      accountDirectoryHolderProvider,
    );
    final RelayEngine? relay = ref.read(relayEngineProvider);
    final AlarmKitKeeper current = keeper;
    _alarmKitWriting = _alarmKitWriting.then((_) async {
      _alarmKitQueued = false;
      await current.refresh(
        devicesOf: (String friend) {
          final AccountDeviceDirectory? directory = directories.directory;
          final String? account = directory?.accountOf(friend);
          return directory == null || account == null
              ? const <String>[]
              : directory.addressesOf(account);
        },
        preseal: relay?.presealDeposits,
      );
    });
    return _alarmKitWriting;
  }

  /// Starts the app's `ZenCore` again after the service let go. A locked app
  /// leaves it to the security gate, which starts the core once the app is
  /// unlocked.
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

  /// Tells the service who counts as a contact while the app is locked, and
  /// the public part of the inbox key. Only once the friends were
  /// read: an empty list then must not replace the one stored.
  Future<void> _publishCapability() {
    if (!mounted) {
      return _publishing;
    }
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final AccountDirectoryHolder directories = ref.read(
      accountDirectoryHolderProvider,
    );
    final List<String> mailboxes =
        ref.read(relayEngineProvider)?.overview.value.relays ??
        const <String>[];
    final BackgroundVault vault = ref.read(backgroundVaultProvider);
    SocialHubState state = ref.read(socialHubControllerProvider);
    _publishing = _publishing
        .then((_) async {
          if (!hub.isHydrated) {
            await hub.whenHydrated;
            if (!mounted) {
              return;
            }
            state = ref.read(socialHubControllerProvider);
          }
          if (!hub.isHydrated || state.snapshotUnreadable) {
            return;
          }
          // Derived again whenever the master key is another one (a wipe
          // makes a new one): an inbox sealed for the old key would never
          // open.
          final Uint8List? masterKey = await security.currentEncryptionKey();
          Uint8List? publicKey = _inboxPublicKey;
          if (masterKey != null) {
            final String owner = securityHexFromBytes(
              securityMasterFingerprint(masterKey),
            );
            if (publicKey == null || owner != _inboxKeyOwner) {
              publicKey = await inboxPublicKeyFor(masterKey);
              _inboxPublicKey = publicKey;
              _inboxKeyOwner = owner;
            }
          }
          if (publicKey == null) {
            return;
          }
          final BackgroundCapabilityDraft draft = backgroundCapabilityDraftOf(
            state,
            inboxPublicKey: publicKey,
            directory: directories.directory,
            mailboxes: mailboxes,
          );
          String sorted(Iterable<String> values) =>
              (values.toList()..sort()).join(',');
          final String signature = <String>[
            base64Url.encode(publicKey),
            sorted(draft.friends),
            sorted(draft.groupMembers),
            sorted(draft.blocked),
            draft.mailboxes.join(','),
          ].join('|');
          if (signature == _publishedSignature) {
            return;
          }
          await vault.publish(draft);
          _publishedSignature = signature;
        })
        .catchError((Object error, StackTrace stackTrace) {
          logZenError(
            'Publishing the background capability failed',
            error,
            stackTrace,
          );
        });
    return _publishing;
  }

  /// Opens what the service kept while the app was locked and hands it to
  /// the app as if it had just arrived. Only while the service is
  /// parked (it is the only writer), the app unlocked, its services
  /// listening and the node up — otherwise the inbox waits.
  Future<void> _drainInbox() async {
    if (_draining || _inboxDrained || !mounted) {
      return;
    }
    final AndroidBackgroundServiceController controller = ref.read(
      androidBackgroundServiceControllerProvider,
    );
    final AppSecurityService security = ref.read(appSecurityServiceProvider);
    final BackgroundVault vault = ref.read(backgroundVaultProvider);
    final ZenCore core = ref.read(zenCoreProvider);
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
    final RuntimeSystemNotificationService notices = ref.read(
      runtimeSystemNotificationServiceProvider,
    );
    _draining = true;
    try {
      if (_lastConfirmedMode != AndroidBackgroundRuntimeMode.standby &&
          await controller.isRunning()) {
        return;
      }
      if (isSecurityBlockingUi(security)) {
        return;
      }
      final Uint8List? masterKey = await security.currentEncryptionKey();
      if (masterKey == null) {
        return;
      }
      if (!await vault.hasInbox()) {
        _inboxDrained = true;
        return;
      }
      // The app's services have to be listening before anything is handed
      // to them.
      await core.start();
      await hub.whenHydrated;
      if (!mounted) {
        return;
      }
      if (ref.read(socialHubControllerProvider).snapshotUnreadable) {
        logZenWarning('The inbox waits: the stored friends are unreadable.');
        return;
      }
      if (!runtime.snapshot.serviceRunning) {
        _drainRetry?.cancel();
        _drainRetry = Timer(_drainRetryDelay, () {
          if (mounted) {
            _scheduleSync();
          }
        });
        return;
      }
      // "Mijani" seen by the locked service goes to the log, not to the
      // frame handlers; only this device's own records count.
      final EncounterLog encounters = ref.read(encounterLogProvider);
      final String self = runtime.snapshot.localAddress;
      final int delivered = await vault.drain(
        masterKey: masterKey,
        deliver: (Uint8List record) async {
          final SignalTransportFrame? frame = decodeInboxFrame(record);
          if (frame == null) {
            return;
          }
          if (frame.payload['type'] == kKeptEncountersType) {
            if (!frame.door &&
                self.isNotEmpty &&
                PeerShareCodec.addressesEqual(frame.from, self)) {
              await encounters.takeKept(frame.payload);
            }
            return;
          }
          runtime.replayReceived(frame);
        },
      );
      _inboxDrained = true;
      for (final String slot in kLockedReceiverSlots) {
        await notices.dismissSlot(slot);
      }
      logZenMessage(
        'Drained $delivered frame(s) kept while the app was locked.',
      );
    } on Object catch (error, stackTrace) {
      logZenError('Draining the inbox failed', error, stackTrace);
    } finally {
      _draining = false;
    }
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
    final bool parked = await controller.start(
      _payload(AndroidBackgroundRuntimeMode.standby),
      activeCall: activeCall,
    );
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

/// The service's node while the app is locked or gone: the mesh
/// node with its identity under the background key, and the
/// [LockedReceiver] on it. Nothing here can open the master key's stores.
final class _LockedReceiverSession {
  _LockedReceiverSession._(
    RuntimeNodeRuntime this._runtime,
    LockedReceiver this._receiver,
    this._nearby, {
    LockedOutbox? outbox,
  }) : _outbox = outbox;

  /// No node of the default account ("Odbieraj w tle" off for it): only
  /// the other accounts' ([_also]), if any.
  _LockedReceiverSession._without()
    : _runtime = null,
      _receiver = null,
      _nearby = null,
      _outbox = null;

  final RuntimeNodeRuntime? _runtime;
  final LockedReceiver? _receiver;

  /// The additional accounts with "Odbieraj w tle" on: a receive-only node
  /// each, with generic notifications (background_accounts.dart).
  final List<BackgroundAccountNode> _also = <BackgroundAccountNode>[];

  /// This device's queue from the outbox kit, still going out while locked
  /// (`null`: nothing was queued).
  final LockedOutbox? _outbox;

  /// People nearby from the nearby kit (`null`: the app never wrote one).
  final LockedNearby? _nearby;

  /// The default account's node (when "Odbieraj w tle" is on for it) and
  /// those of the additional accounts that have it on. `null` when the
  /// default account should receive but the app never published a
  /// capability (not unlocked since it was installed or wiped).
  static Future<_LockedReceiverSession?> open(
    AndroidBackgroundBootstrapPayload payload, {
    required RuntimeSystemNotificationService notices,
  }) async {
    ZenBackgroundAccountList accounts = const ZenBackgroundAccountList();
    try {
      accounts = await ZenBackgroundAccounts().load();
    } on Object catch (error, stackTrace) {
      logZenError('Reading the background accounts failed', error, stackTrace);
    }
    final _LockedReceiverSession? session = accounts.defaultOn
        ? await _openDefault(payload, notices: notices)
        : _LockedReceiverSession._without();
    if (session == null || accounts.additional.isEmpty) {
      return session;
    }
    final Directory instance = await ZenInstance.instanceDirectory();
    session._also.addAll(
      await BackgroundAccountNode.openAll(
        accounts,
        accounts: Directory(
          '${instance.path}${Platform.pathSeparator}'
          '${ZenInstance.accountsFolder}',
        ),
        notices: notices,
        waitTimeout: payload.settings.signalWaitTimeout,
      ),
    );
    return session;
  }

  /// The default account's node, as before there were other accounts.
  static Future<_LockedReceiverSession?> _openDefault(
    AndroidBackgroundBootstrapPayload payload, {
    required RuntimeSystemNotificationService notices,
  }) async {
    final Directory support = await ZenInstance.supportDirectory();
    const AppSecurityCredentialsStore credentials =
        SecureStorageCredentialsStore();
    final FileBackgroundVault vault = FileBackgroundVault(
      supportDirectory: () async => support,
      credentials: credentials,
    );
    final BackgroundCapability? capability = await vault.load();
    if (capability == null) {
      return null;
    }
    // What this person's alarm goes out with while the app is locked;
    // `null` when the app never wrote one.
    final AlarmKit? kit = await FileAlarmKitStore(
      supportDirectory: () async => support,
      credentials: credentials,
    ).read();
    // What this phone shows and recognises nearby, and the doors it runs.
    final NearbyKit? nearbyKit = NearbyKit.fromJson(
      await nearbyKitFile(
        supportDirectory: () async => support,
        credentials: credentials,
      ).read(),
    );
    final LockedDoorKit? doorKit = LockedDoorKit.fromJson(
      await lockedDoorKitFile(
        supportDirectory: () async => support,
        credentials: credentials,
      ).read(),
    );
    // What this device still had to send, sealed for each recipient.
    final LockedOutboxKit? outboxKit = LockedOutboxKit.fromJson(
      await lockedOutboxKitFile(
        supportDirectory: () async => support,
        credentials: credentials,
      ).read(),
    );
    final RuntimeNodeRuntime runtime = buildDefaultRuntimeNodeRuntime(
      config: RuntimeSignalBootstrapConfig(
        waitTimeout: payload.settings.signalWaitTimeout,
        nodeConfigProtector: BackgroundKeyProtector(credentials),
        // Signals wake the service as they arrive (a blocking wait in an
        // isolate of its own); this slow poll runs only if that wait fails.
        fallbackPollInterval: const Duration(seconds: 2),
      ),
    );
    if (doorKit != null && !doorKit.isEmpty) {
      // Safe before the node is up: the doors come up with it. Knocks wait
      // in the inbox; only the door key is here, never the flat's keys.
      runtime
        ..setDoorKey(doorKit.doorKey)
        ..setMailboxDoorKeys(doorKit.mailboxDoorKeys);
    }
    final SealedInboxWriter inbox = SealedInboxWriter(
      file: await vault.inboxFile(),
      recipientPublicKey: capability.inboxPublicKey,
    );
    Future<bool> keep(SignalTransportFrame record) =>
        inbox.append(encodeInboxFrame(record));
    final ChannelNearbyRadio radio = ChannelNearbyRadio();
    final LockedNearby? nearby = nearbyKit == null
        ? null
        : LockedNearby(
            kit: nearbyKit,
            radio: radio,
            keep: keep,
            notices: notices,
            claimAlarms: radio.setAlarmReceiver,
            alarmKeys: radio.setAlarmKeys,
            place: lastKnownEncounterPlace,
          );
    return _LockedReceiverSession._(
      runtime,
      LockedReceiver(
        transport: runtime,
        capability: capability,
        inbox: inbox,
        notices: notices,
        doorFrames: runtime.doorFrames,
        knocks: doorKit?.knockWatch(),
        alarm: kit == null
            ? null
            : LockedAlarm(
                kit: kit,
                transport: runtime,
                keep: keep,
                locate: currentFixInBackground,
                record: AlarmAudioPump.recordClip,
                wave: (String id, int at, bool ended) {
                  Future<int> wave() =>
                      waveLockedAlarm(radio, kit, id: id, at: at, ended: ended);
                  // A look around going on must not end its scan midway.
                  return nearby == null ? wave() : nearby.holdingRadio(wave);
                },
              ),
      ),
      nearby,
      outbox: outboxKit == null || outboxKit.items.isEmpty
          ? null
          : LockedOutbox(transport: runtime, kit: outboxKit),
    );
  }

  Future<void> start() async {
    final LockedReceiver? receiver = _receiver;
    if (receiver != null) {
      await _setShortcutOwner(true);
      await receiver.start();
      await _outbox?.start();
      await _nearby?.start();
    }
    for (final BackgroundAccountNode node in _also) {
      try {
        await node.start();
      } on Object catch (error, stackTrace) {
        logZenError('Starting a background account failed', error, stackTrace);
      }
    }
  }

  /// The power-button shortcut while this service runs the node.
  Future<void> onPowerShortcut() async => _receiver?.onPowerShortcut();

  Future<void> dispose() async {
    final LockedReceiver? receiver = _receiver;
    if (receiver != null) {
      await _setShortcutOwner(false);
      // First: what it saw goes to the inbox, and alarm waves go back to
      // the app before it drains the inbox.
      await _nearby?.stop();
      await _outbox?.stop();
      await receiver.stop();
      _runtime?.dispose();
    }
    for (final BackgroundAccountNode node in _also) {
      try {
        await node.stop();
      } on Object catch (error, stackTrace) {
        logZenError('Stopping a background account failed', error, stackTrace);
      }
    }
  }

  /// The shortcut comes here while this service runs the network (the
  /// alarm goes out from the alarm kit), to the app otherwise.
  static Future<void> _setShortcutOwner(bool owner) async {
    if (!AlarmShortcutChannel.supported) {
      return;
    }
    try {
      await const AlarmShortcutChannel().setNodeOwner(owner);
    } on Object catch (error, stackTrace) {
      logZenError('Handing the alarm shortcut over failed', error, stackTrace);
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

  /// The receive-only node while the app is locked or gone.
  _LockedReceiverSession? _session;

  /// Latest state the app asked for. Every queued reconcile converges to this,
  /// so out-of-order or duplicated messages cannot leave the node half-owned.
  AndroidBackgroundBootstrapPayload? _desired;
  Future<void> _transitions = Future<void>.value();
  bool _destroyed = false;

  /// Since the app last proved it is alive (monotonic: it stands still
  /// while the phone sleeps). Only meaningful while parked.
  Stopwatch? _sinceAppHeartbeat;

  /// Wakes the phone now and then while parked, to look at the heartbeats.
  WakeTimer? _watchdog;

  /// The app's engine went away (ZenPower "appGone").
  StreamSubscription<void>? _appGone;

  /// Where the service's own notices go (tests); `null`: the system's.
  final RuntimeSystemNotificationService Function()? _noticeServiceFactory;

  /// Lazily created: the service's own notices (parked without a background
  /// capability, stopped by Android) and the locked receiver's.
  RuntimeSystemNotificationService? _notices;
  bool _noticesInitialized = false;

  /// One notice per parked-locked stretch; re-armed once the node actually
  /// comes up again.
  bool _lockedParkNoticeShown = false;

  /// The app said it is stopping the service itself (see
  /// [kAndroidBackgroundStopRequestType]).
  bool _stopRequestedByApp = false;

  /// The power-button shortcut. It comes here while this service
  /// runs the network, or when the app is not listening at all.
  StreamSubscription<void>? _powerShortcut;

  /// A shortcut that came while no node ran here: answered once one does
  /// (within [kAlarmShortcutMaxDelay]).
  DateTime? _pendingPowerAlarmAt;

  /// The look at GitHub for a new version while the app is closed.
  BackgroundUpdateCheck? _updateCheck;

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
    _appGone = ZenWake.appGone.listen((_) => _onAppGone());
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
    if (!_destroyed) {
      _updateCheck ??= startBackgroundUpdateCheck(notices: _readyNotices);
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {
    _checkStandbyWatchdog();
  }

  /// The app's engine is gone: no heartbeat will come, take the node now.
  void _onAppGone() {
    logZenMessage('The app\'s engine is gone.');
    _checkStandbyWatchdog(appGone: true);
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map<Object?, Object?> &&
        data['type'] == _kRuntimeHeartbeatType) {
      _noteAppAlive();
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
  void _checkStandbyWatchdog({bool appGone = false}) {
    if (_destroyed) {
      return;
    }
    final AndroidBackgroundBootstrapPayload? desired = _desired;
    if (desired == null ||
        desired.mode != AndroidBackgroundRuntimeMode.standby) {
      return;
    }
    final Stopwatch? since = _sinceAppHeartbeat;
    if (!appGone &&
        since != null &&
        since.elapsed < kAndroidBackgroundHeartbeatTimeout) {
      return;
    }
    logZenWarning(
      appGone
          ? 'The app is gone while parked — the service is taking the '
                'runtime node over.'
          : 'No app heartbeat for '
                '${kAndroidBackgroundHeartbeatTimeout.inSeconds}s while parked '
                '— the service is taking the runtime node over.',
    );
    _noteAppAlive();
    _request(desired.withMode(AndroidBackgroundRuntimeMode.active));
  }

  void _noteAppAlive() {
    (_sinceAppHeartbeat ??= Stopwatch())
      ..reset()
      ..start();
  }

  /// While parked, an alarm now and then wakes the phone to look at the
  /// heartbeats (and lets the app's own timers run); none while this
  /// service runs the node.
  void _syncWatchdog(AndroidBackgroundRuntimeMode mode) {
    if (mode == AndroidBackgroundRuntimeMode.standby && !_destroyed) {
      _watchdog ??= ZenWake.every(
        'watchdog',
        kAndroidStandbyWatchdogEvery,
        _checkStandbyWatchdog,
        hold: const Duration(seconds: 5),
      );
    } else {
      _watchdog?.cancel();
      _watchdog = null;
    }
  }

  @override
  void onNotificationPressed() {
    FlutterForegroundTask.launchApp();
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _destroyed = true;
    _updateCheck?.stop();
    _updateCheck = null;
    _syncWatchdog(AndroidBackgroundRuntimeMode.active);
    await _appGone?.cancel();
    _appGone = null;
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
    await _session?.dispose();
    _session = null;
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

  /// 5× the power button while this service runs the node: the app is
  /// locked or gone, so the alarm goes out from the alarm kit the app left,
  /// without the master key.
  void _onPowerShortcut() {
    logZenMessage('Power-button alarm shortcut reached the service.');
    _pendingPowerAlarmAt = DateTime.now();
    if (_session == null) {
      // Nobody runs the network: take it over now if the app is gone.
      _checkStandbyWatchdog();
    }
    _transitions = _transitions.then((_) => _servePowerShortcut()).catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      logZenError('Power-button alarm failed', error, stackTrace);
    });
  }

  /// Answers a pending shortcut once a node runs here; otherwise it waits
  /// for the next activation.
  Future<void> _servePowerShortcut() async {
    final DateTime? at = _pendingPowerAlarmAt;
    final _LockedReceiverSession? session = _session;
    if (at == null || session == null || _destroyed) {
      return;
    }
    _pendingPowerAlarmAt = null;
    if (DateTime.now().difference(at) > kAlarmShortcutMaxDelay) {
      logZenWarning('A power-button alarm waited too long and was dropped.');
      return;
    }
    try {
      await session.onPowerShortcut();
    } catch (error, stackTrace) {
      logZenError('Power-button alarm failed', error, stackTrace);
    }
  }

  void _request(AndroidBackgroundBootstrapPayload payload) {
    if (payload.mode == AndroidBackgroundRuntimeMode.standby) {
      // A park request is itself proof the app is on screen and alive.
      _noteAppAlive();
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
      '(node ${_session == null ? 'down' : 'up'}).',
    );
    if (mode == AndroidBackgroundRuntimeMode.active && _session == null) {
      _LockedReceiverSession? session;
      try {
        final RuntimeSystemNotificationService notices =
            await _readyNotices() ?? MemoryRuntimeSystemNotificationService();
        session = await _LockedReceiverSession.open(payload, notices: notices);
        if (session == null) {
          // The app never told what it may receive with (not unlocked since
          // it was installed or wiped): stand by rather than run a node
          // that could keep nothing.
          logZenWarning(
            'Background runtime stayed parked: no background capability yet.',
          );
          mode = AndroidBackgroundRuntimeMode.standby;
          await _notifyLockedPark();
        } else if (_destroyed) {
          await session.dispose();
          return;
        } else {
          _session = session;
          await session.start();
          _lockedParkNoticeShown = false;
          await _updateServiceNotification(AndroidBackgroundRuntimeMode.active);
        }
      } catch (error, stackTrace) {
        // Leaving a half-built session in place would wedge the task
        // forever: every later reconcile would see a non-null `_session`,
        // skip the start, and report "active" for a node that does not
        // exist. Tear it down and report the mode actually reached, so the
        // app keeps serving from its own isolate instead of waiting on an
        // acknowledgement that never comes.
        logZenError('Background runtime activation failed', error, stackTrace);
        _session = null;
        if (session != null) {
          try {
            await session.dispose();
          } catch (disposeError, disposeStackTrace) {
            logZenError(
              'Disposing a failed background runtime failed',
              disposeError,
              disposeStackTrace,
            );
          }
        }
        mode = AndroidBackgroundRuntimeMode.standby;
      }
    }
    if (mode == AndroidBackgroundRuntimeMode.standby) {
      final _LockedReceiverSession? session = _session;
      _session = null;
      if (session != null) {
        await session.dispose();
      }
      await _updateServiceNotification(AndroidBackgroundRuntimeMode.standby);
    }
    logZenMessage('Service reached "${mode.name}".');
    _syncWatchdog(mode);
    _acknowledge(mode);
    if (mode == AndroidBackgroundRuntimeMode.active) {
      await _servePowerShortcut();
    }
  }

  /// Tells the user the parked service cannot take calls until they unlock.
  ///
  /// Without it, a service with no background capability fails silently: it
  /// stays parked with no node, and nobody can tell why the phone never
  /// rings. Shown once per
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

  Future<void> _updateServiceNotification(
    AndroidBackgroundRuntimeMode mode,
  ) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await FlutterForegroundTask.updateService(
        notificationTitle: 'Zen',
        notificationText: _backgroundServiceNotificationText(null, mode: mode),
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.roj.zen.service.NOTIFICATION_ICON',
        ),
      );
    } catch (error, stackTrace) {
      logZenError('Service notification update failed', error, stackTrace);
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
