import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/calls/call_safety_cues.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

final Provider<RuntimeSystemNotificationService>
runtimeSystemNotificationServiceProvider =
    Provider<RuntimeSystemNotificationService>((Ref ref) {
      return MemoryRuntimeSystemNotificationService();
    });

List buildRuntimeSystemNotificationProviderOverrides({
  RuntimeSystemNotificationServiceFactory? serviceFactory,
}) {
  return [
    runtimeSystemNotificationServiceProvider.overrideWith(
      (Ref ref) => PrivacyRedactingNotificationService(
        serviceFactory?.call() ??
            FlutterLocalRuntimeSystemNotificationService(
              soundEffects: ref.read(zenSoundEffectsProvider),
            ),
        // Read on every post, so flipping the setting applies at once.
        // Also while this device shares its screen in a call.
        hideContent: () =>
            ref.read(appSettingsControllerProvider).hideNotificationContent ||
            screenShareHidesNotifications.value,
      ),
    ),
  ];
}

typedef RuntimeSystemNotificationServiceFactory =
    RuntimeSystemNotificationService Function();

enum RuntimeSystemNotificationCategory {
  social,
  message,
  call,
  transfer,

  /// A friend's alarm: loudest, full screen, cannot be missed.
  alarm,
}

/// Whether [notification] comes from the neighbours section (its posts'
/// ids start with `flat-`, see NeighborsService).
bool isNeighboursNotification(RuntimeSystemNotification notification) =>
    notification.id.startsWith('flat-');

/// The sound [notification] makes: also which Android channel it goes to.
/// A call that is not ringing (missed, declined, ended) is told like a
/// message, never with the ringtone.
ZenSound? zenSoundFor(RuntimeSystemNotification notification) {
  return switch (notification.category) {
    RuntimeSystemNotificationCategory.alarm => ZenSound.alarm,
    RuntimeSystemNotificationCategory.call =>
      notification.isRingingCall ? ZenSound.ringtone : ZenSound.message,
    RuntimeSystemNotificationCategory.message => ZenSound.message,
    RuntimeSystemNotificationCategory.social =>
      isNeighboursNotification(notification) ? ZenSound.knock : ZenSound.social,
    RuntimeSystemNotificationCategory.transfer => null,
  };
}

@immutable
final class RuntimeSystemNotification {
  const RuntimeSystemNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.createdAtMillis,
    required this.category,
    this.routeKey,
    this.slotKey,
    this.suppressionKey,
    this.isRingingCall = false,
    this.lines = const <String>[],
    this.stackCount = 1,
    this.contentRedacted = false,
  });

  final String id;
  final String title;
  final String body;
  final int createdAtMillis;
  final String? routeKey;
  final RuntimeSystemNotificationCategory category;
  final String? slotKey;
  final String? suppressionKey;

  /// True only while a call is actually ringing. Those get the full-screen
  /// intent and the ringtone; the follow-up states (declined, busy, ended)
  /// share the call channel but must stay ordinary, dismissible notifications.
  final bool isRingingCall;

  /// Earlier bodies still folded into this notification (oldest first,
  /// newest last). Several messages from one chat become one entry.
  final List<String> lines;

  /// How many events this notification stands for.
  final int stackCount;

  /// True when the poster already applied the "no content" setting itself
  /// (and kept what it deliberately shows, such as who wrote).
  final bool contentRedacted;

  /// This notification with its text replaced by [body] (and no stacked
  /// lines), and its title by [title] when given, see
  /// [PrivacyRedactingNotificationService].
  RuntimeSystemNotification withRedactedBody(String body, {String? title}) {
    return RuntimeSystemNotification(
      id: id,
      title: title ?? this.title,
      body: body,
      createdAtMillis: createdAtMillis,
      category: category,
      routeKey: routeKey,
      slotKey: slotKey,
      suppressionKey: suppressionKey,
      isRingingCall: isRingingCall,
      stackCount: stackCount,
      contentRedacted: true,
    );
  }

  RuntimeSystemNotification _stacked({
    required List<String> lines,
    required int stackCount,
  }) {
    return RuntimeSystemNotification(
      id: id,
      title: title,
      body: body,
      createdAtMillis: createdAtMillis,
      category: category,
      routeKey: routeKey,
      slotKey: slotKey,
      suppressionKey: suppressionKey,
      isRingingCall: isRingingCall,
      lines: lines,
      stackCount: stackCount,
      contentRedacted: contentRedacted,
    );
  }
}

/// Folds [next] into the message notification [previous] of the same slot.
///
/// A burst of messages from one chat used to replace the notification body
/// each time — only the last message was visible, and each replacement
/// buzzed again. Now the entry keeps the recent lines and a count.
RuntimeSystemNotification stackRuntimeNotification(
  RuntimeSystemNotification? previous,
  RuntimeSystemNotification next,
) {
  if (previous == null ||
      next.isRingingCall ||
      previous.category != RuntimeSystemNotificationCategory.message ||
      next.category != RuntimeSystemNotificationCategory.message) {
    return next;
  }
  final List<String> lines = <String>[
    ...(previous.lines.isEmpty ? <String>[previous.body] : previous.lines),
    next.body,
  ];
  return next._stacked(
    lines: lines.length > _maxStackedLines
        ? lines.sublist(lines.length - _maxStackedLines)
        : lines,
    stackCount: previous.stackCount + 1,
  );
}

const int _maxStackedLines = 6;

/// Updates of a still-visible notification within this window stay silent.
const Duration kNotificationRealertWindow = Duration(seconds: 30);

typedef NotificationActionCallback =
    Future<void> Function(String actionId, String? payload);

abstract interface class RuntimeSystemNotificationService {
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  });

  Future<bool> show(RuntimeSystemNotification notification);

  Future<void> dismiss(String id);

  /// Drops whatever notification currently occupies [slotKey].
  ///
  /// [dismiss] needs the exact notification id, which the caller rarely has:
  /// a ringing call is posted from one signal and cancelled from another.
  /// The slot is the stable identity across a call's whole lifetime.
  Future<void> dismissSlot(String slotKey);

  Future<void> clear();
}

/// Applies the "Powiadomienia bez treści" setting to every notification the
/// app posts, whoever posts it.
///
/// Features post straight to the notification service (dating, the meet
/// services, the pyramid...), and only the chat used to honour the setting,
/// so their text still reached the shade and the lock screen. Here, with
/// the setting on (the default), the body of every message, social and
/// transfer notification is replaced by a generic line; the title (who or
/// what it is about) stays, as it always did for chat messages — except
/// where the title itself tells too much ("X idzie na randkę", "Odpowiedź:
/// {pytanie}", "Zaproszenie: {wydarzenie}"): dating, questions, events,
/// introductions and the pyramid get a generic title too. Calls and
/// alarms are left alone: the ringing UI must say who calls, and an alarm
/// has to be readable at a glance.
final class PrivacyRedactingNotificationService
    implements RuntimeSystemNotificationService {
  PrivacyRedactingNotificationService(
    this.delegate, {
    required bool Function() hideContent,
  }) : _hideContent = hideContent;

  final RuntimeSystemNotificationService delegate;
  final bool Function() _hideContent;

  /// Ids (see the features' `notify` calls) of the posts whose title alone
  /// gives away what they are about: dating (`date-`), questions (`ask-`),
  /// events and the meet-ups like them (`event-`, `plan-`, `circle-`),
  /// introductions (`intro-`), the pyramid (`pyr-`) and reactions to your
  /// posts (`react-`: the title names who liked or commented).
  static const List<String> _revealingTitleIdPrefixes = <String>[
    'react-',
    'date-',
    'ask-',
    'event-',
    'plan-',
    'circle-',
    'intro-',
    'pyr-',
  ];

  /// Of those, what stays readable: a safe-date check-in ("Wszystko OK?")
  /// turns into an alarm when it is missed.
  static const List<String> _explicitIdPrefixes = <String>['date-safe-rem-'];

  /// Body shown instead of the content, per category.
  static String genericBodyFor(RuntimeSystemNotificationCategory category) {
    return switch (category) {
      RuntimeSystemNotificationCategory.message => t('Nowa wiadomość'),
      _ => t('Otwórz Zen, aby zobaczyć szczegóły.'),
    };
  }

  /// Title shown instead of one that tells too much (see [hidesTitle]).
  static String get genericTitle => t('Nowe powiadomienie');

  /// Whether, with the setting on, [notification] loses its title too.
  static bool hidesTitle(RuntimeSystemNotification notification) {
    final String id = notification.id;
    return _revealingTitleIdPrefixes.any(
          (String prefix) => id.startsWith(prefix),
        ) &&
        !_explicitIdPrefixes.any((String prefix) => id.startsWith(prefix));
  }

  /// [notification] as the shade may show it right now.
  RuntimeSystemNotification redact(RuntimeSystemNotification notification) {
    if (notification.category == RuntimeSystemNotificationCategory.call ||
        notification.category == RuntimeSystemNotificationCategory.alarm ||
        !_shouldHide()) {
      return notification;
    }
    final bool hideTitle = hidesTitle(notification);
    if (notification.contentRedacted && !hideTitle) {
      return notification;
    }
    return notification.withRedactedBody(
      genericBodyFor(notification.category),
      title: hideTitle ? genericTitle : null,
    );
  }

  bool _shouldHide() {
    try {
      return _hideContent();
    } catch (_) {
      // Settings not readable (yet): err on the private side.
      return true;
    }
  }

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) {
    return delegate.initialize(onOpenRoute: onOpenRoute, onAction: onAction);
  }

  @override
  Future<bool> show(RuntimeSystemNotification notification) {
    return delegate.show(redact(notification));
  }

  @override
  Future<void> dismiss(String id) => delegate.dismiss(id);

  @override
  Future<void> dismissSlot(String slotKey) => delegate.dismissSlot(slotKey);

  @override
  Future<void> clear() => delegate.clear();
}

final class MemoryRuntimeSystemNotificationService
    implements RuntimeSystemNotificationService {
  final Map<String, RuntimeSystemNotification> _activeNotificationsBySlot =
      <String, RuntimeSystemNotification>{};
  final Map<String, String> _slotKeyByNotificationId = <String, String>{};
  final _NotificationSuppressionWindow _suppressionWindow =
      _NotificationSuppressionWindow();
  Future<void> Function(String routeKey) _onOpenRoute = _noopOpenRoute;
  NotificationActionCallback? _onAction;

  bool _initialized = false;

  bool get isInitialized => _initialized;

  List<RuntimeSystemNotification> get activeNotifications =>
      List<RuntimeSystemNotification>.unmodifiable(
        _activeNotificationsBySlot.values.toList(growable: false),
      );

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) async {
    _initialized = true;
    _onOpenRoute = onOpenRoute;
    _onAction = onAction;
  }

  Future<void> simulateAction(String actionId, String? payload) async {
    await _onAction?.call(actionId, payload);
  }

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    if (notification.suppressionKey != null &&
        !_suppressionWindow.shouldNotify(
          notification.suppressionKey!,
          notification.createdAtMillis,
        )) {
      return false;
    }
    final String slotKey = notification.slotKey ?? notification.id;
    final RuntimeSystemNotification? previous =
        _activeNotificationsBySlot[slotKey];
    if (_isRedundantRingingRepost(previous, notification)) {
      return true;
    }
    final RuntimeSystemNotification stacked = stackRuntimeNotification(
      previous,
      notification,
    );
    _slotKeyByNotificationId.removeWhere(
      (_, String mappedSlotKey) => mappedSlotKey == slotKey,
    );
    _slotKeyByNotificationId[notification.id] = slotKey;
    _activeNotificationsBySlot[slotKey] = stacked;
    final int? lastAlert = _lastAlertAtBySlot[slotKey];
    final bool audible =
        previous == null ||
        lastAlert == null ||
        notification.createdAtMillis - lastAlert >=
            kNotificationRealertWindow.inMilliseconds;
    if (audible) {
      _lastAlertAtBySlot[slotKey] = notification.createdAtMillis;
      audibleAlertCount += 1;
    }
    return true;
  }

  /// How many posts would have made a sound (tests assert on this).
  int audibleAlertCount = 0;
  final Map<String, int> _lastAlertAtBySlot = <String, int>{};

  @override
  Future<void> dismiss(String id) async {
    final String slotKey = _slotKeyByNotificationId.remove(id) ?? id;
    final RuntimeSystemNotification? active =
        _activeNotificationsBySlot[slotKey];
    if (active == null || active.id != id) {
      return;
    }
    _slotKeyByNotificationId.removeWhere(
      (_, String mappedSlotKey) => mappedSlotKey == slotKey,
    );
    _activeNotificationsBySlot.remove(slotKey);
  }

  @override
  Future<void> dismissSlot(String slotKey) async {
    _slotKeyByNotificationId.removeWhere(
      (_, String mappedSlotKey) => mappedSlotKey == slotKey,
    );
    _activeNotificationsBySlot.remove(slotKey);
    _suppressionWindow.forget(slotKey);
  }

  @override
  Future<void> clear() async {
    _slotKeyByNotificationId.clear();
    _activeNotificationsBySlot.clear();
    _suppressionWindow.clear();
  }

  Future<void> simulateTap(String id) async {
    final String slotKey = _slotKeyByNotificationId[id] ?? id;
    final String? routeKey = _activeNotificationsBySlot[slotKey]?.routeKey
        ?.trim();
    if (routeKey == null || routeKey.isEmpty) {
      return;
    }
    await _onOpenRoute(routeKey);
  }
}

final class FlutterLocalRuntimeSystemNotificationService
    implements RuntimeSystemNotificationService {
  FlutterLocalRuntimeSystemNotificationService({
    FlutterLocalNotificationsPlugin? plugin,
    this.canRequestPermission = true,
    this.soundEffects,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  /// Plays the notification sounds on Windows and Linux, where the toast
  /// itself stays silent (see [ZenSoundEffects.playsNotificationSounds]).
  /// `null` in the background isolate.
  final ZenSoundEffects? soundEffects;

  /// Whether this isolate may ask for POST_NOTIFICATIONS.
  ///
  /// Only the UI isolate can: the plugin resolves the request against the
  /// attached Activity, and dereferences it without a null check, so asking
  /// from the foreground-service isolate throws. The permission is the
  /// foreground app's job anyway.
  final bool canRequestPermission;

  // A channel keeps the sound it was created with: a new sound needs a new
  // channel id.
  static const String _socialChannelId = 'zen_social_v2';
  static const String _neighboursChannelId = 'zen_neighbours_v1';
  static const String _messageChannelId = 'zen_messages_v2';
  static const String _callChannelId = 'zen_calls_v4';
  static const String _alarmChannelId = 'zen_alarm_v2';
  static const String _transferChannelId = 'zen_transfers';

  /// Android's FLAG_INSISTENT: the sound repeats until the notification is
  /// opened or cancelled (a friend's alarm).
  static const int _flagInsistent = 4;

  /// Every Android channel Zen posts to, each with its own sound.
  @visibleForTesting
  static List<AndroidNotificationChannel> androidChannels() {
    AndroidNotificationChannel sounding(
      String id,
      String name,
      String description,
      ZenSound sound, {
      Importance importance = Importance.high,
      AudioAttributesUsage usage = AudioAttributesUsage.notification,
      bool bypassDnd = false,
    }) {
      return AndroidNotificationChannel(
        id,
        name,
        description: description,
        importance: importance,
        bypassDnd: bypassDnd,
        playSound: true,
        sound: RawResourceAndroidNotificationSound(sound.fileName),
        enableVibration: true,
        showBadge: true,
        audioAttributesUsage: usage,
      );
    }

    return <AndroidNotificationChannel>[
      sounding(
        _messageChannelId,
        t('Wiadomości'),
        t('Nowe wiadomości od znajomych.'),
        ZenSound.message,
      ),
      sounding(
        _callChannelId,
        t('Połączenia'),
        t('Dzwoniący znajomi.'),
        ZenSound.ringtone,
        importance: Importance.max,
        usage: AudioAttributesUsage.notificationRingtone,
      ),
      sounding(
        _alarmChannelId,
        t('Alarmy'),
        t('Alarm przyjaciela, który potrzebuje pomocy.'),
        ZenSound.alarm,
        importance: Importance.max,
        usage: AudioAttributesUsage.alarm,
        bypassDnd: true,
      ),
      sounding(
        _socialChannelId,
        t('Relacje'),
        t('Zaproszenia, akceptacje i zmiany stanu relacji.'),
        ZenSound.social,
      ),
      sounding(
        _neighboursChannelId,
        t('Sąsiedzi'),
        t('Pukanie do drzwi i sprawy domowników.'),
        ZenSound.knock,
      ),
      AndroidNotificationChannel(
        _transferChannelId,
        t('Transfery'),
        description: t('Statusy anulowania i problemów transferu.'),
        importance: Importance.defaultImportance,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      ),
    ];
  }

  /// The channel [notification] goes to: the one with its sound.
  @visibleForTesting
  static AndroidNotificationChannel androidChannelFor(
    RuntimeSystemNotification notification,
  ) {
    final String id = switch (zenSoundFor(notification)) {
      ZenSound.alarm => _alarmChannelId,
      ZenSound.ringtone => _callChannelId,
      ZenSound.knock => _neighboursChannelId,
      ZenSound.social => _socialChannelId,
      null => _transferChannelId,
      _ => _messageChannelId,
    };
    return androidChannels().firstWhere(
      (AndroidNotificationChannel channel) => channel.id == id,
    );
  }

  final FlutterLocalNotificationsPlugin _plugin;
  final Map<String, RuntimeSystemNotification> _activeNotificationsBySlot =
      <String, RuntimeSystemNotification>{};
  final Map<String, String> _slotKeyByNotificationId = <String, String>{};
  final _NotificationSuppressionWindow _suppressionWindow =
      _NotificationSuppressionWindow();
  final Map<String, int> _lastAlertAtBySlot = <String, int>{};

  /// Windows and Linux: a ringing alarm's sound, repeating per slot.
  final Map<String, ZenSoundLoop> _alarmLoops = <String, ZenSoundLoop>{};
  final Set<String> _alarmLoopsStarting = <String>{};

  Future<void> Function(String routeKey) _onOpenRoute = _noopOpenRoute;
  NotificationActionCallback? _onAction;
  bool _initialized = false;
  bool _notificationsPermissionDenied = false;

  /// True when the user (or OEM) denied POST_NOTIFICATIONS — the UI can use
  /// this to show an in-app fallback instead of staying silent.
  bool get notificationsPermissionDenied => _notificationsPermissionDenied;

  @override
  Future<void> initialize({
    required Future<void> Function(String routeKey) onOpenRoute,
    NotificationActionCallback? onAction,
  }) async {
    _onOpenRoute = onOpenRoute;
    _onAction = onAction;
    // Never propagate: this runs first thing in the background runtime, and a
    // notification-channel problem must not stop the mesh node from starting.
    try {
      await _ensureInitialized();
    } catch (error, stackTrace) {
      logZenError(
        'Initializing system notifications failed',
        error,
        stackTrace,
      );
    }
  }

  @override
  Future<bool> show(RuntimeSystemNotification notification) async {
    if (notification.suppressionKey != null &&
        !_suppressionWindow.shouldNotify(
          notification.suppressionKey!,
          notification.createdAtMillis,
        )) {
      return false;
    }
    final String slotKey = notification.slotKey ?? notification.id;
    final RuntimeSystemNotification? previous =
        _activeNotificationsBySlot[slotKey];
    if (_isRedundantRingingRepost(previous, notification)) {
      // Already on screen and unchanged: re-posting it would only re-fire the
      // ringtone and the full-screen intent.
      return true;
    }
    notification = stackRuntimeNotification(previous, notification);
    // Updating an entry that is still on screen stays quiet for a while: a
    // chatty conversation must not buzz the phone once per message.
    final int? lastAlert = _lastAlertAtBySlot[slotKey];
    final bool onlyAlertOnce =
        previous != null &&
        lastAlert != null &&
        notification.createdAtMillis - lastAlert <
            kNotificationRealertWindow.inMilliseconds;
    if (!onlyAlertOnce) {
      _lastAlertAtBySlot[slotKey] = notification.createdAtMillis;
    }
    _slotKeyByNotificationId.removeWhere(
      (_, String mappedSlotKey) => mappedSlotKey == slotKey,
    );
    _slotKeyByNotificationId[notification.id] = slotKey;
    _activeNotificationsBySlot[slotKey] = notification;
    // A failing notification channel must never abort the signal handling that
    // triggered it — an unhandled error here used to swallow the rest of the
    // incoming call/message pipeline.
    try {
      await _ensureInitialized();
      await _plugin.show(
        id: slotKey.hashCode & 0x7fffffff,
        title: notification.title,
        body: notification.body,
        notificationDetails: _detailsFor(
          notification,
          onlyAlertOnce: onlyAlertOnce,
        ),
        payload: notification.routeKey,
      );
      _playOwnSound(notification, slotKey, onlyAlertOnce: onlyAlertOnce);
      return true;
    } catch (error, stackTrace) {
      // Not the title: the diagnostics log must not collect who wrote.
      logZenError(
        'Showing a ${notification.category.name} system notification failed',
        error,
        stackTrace,
      );
      try {
        await _plugin.show(
          id: slotKey.hashCode & 0x7fffffff,
          title: notification.title,
          body: notification.body,
          notificationDetails: _detailsFor(
            notification,
            fallback: true,
            onlyAlertOnce: onlyAlertOnce,
          ),
          payload: notification.routeKey,
        );
        _playOwnSound(notification, slotKey, onlyAlertOnce: onlyAlertOnce);
        return true;
      } catch (fallbackError, fallbackStackTrace) {
        logZenError(
          'Showing a fallback ${notification.category.name} system '
          'notification failed',
          fallbackError,
          fallbackStackTrace,
        );
        return false;
      }
    }
  }

  @override
  Future<void> dismiss(String id) async {
    final String slotKey = _slotKeyByNotificationId.remove(id) ?? id;
    final RuntimeSystemNotification? active =
        _activeNotificationsBySlot[slotKey];
    if (active == null || active.id != id) {
      return;
    }
    _slotKeyByNotificationId.removeWhere(
      (_, String mappedSlotKey) => mappedSlotKey == slotKey,
    );
    _activeNotificationsBySlot.remove(slotKey);
    _stopAlarmLoop(slotKey);
    try {
      await _ensureInitialized();
      await _plugin.cancel(id: slotKey.hashCode & 0x7fffffff);
    } catch (error, stackTrace) {
      logZenError('Dismissing system notification failed', error, stackTrace);
    }
  }

  @override
  Future<void> dismissSlot(String slotKey) async {
    _slotKeyByNotificationId.removeWhere(
      (_, String mappedSlotKey) => mappedSlotKey == slotKey,
    );
    _activeNotificationsBySlot.remove(slotKey);
    _suppressionWindow.forget(slotKey);
    _stopAlarmLoop(slotKey);
    try {
      await _ensureInitialized();
      await _plugin.cancel(id: slotKey.hashCode & 0x7fffffff);
    } catch (error, stackTrace) {
      logZenError(
        'Dismissing the "$slotKey" notification slot failed',
        error,
        stackTrace,
      );
    }
  }

  @override
  Future<void> clear() async {
    _activeNotificationsBySlot.clear();
    _slotKeyByNotificationId.clear();
    _suppressionWindow.clear();
    _alarmLoopsStarting.clear();
    for (final String slotKey in _alarmLoops.keys.toList()) {
      _stopAlarmLoop(slotKey);
    }
    try {
      await _ensureInitialized();
      await _plugin.cancelAll();
    } catch (error, stackTrace) {
      logZenError('Clearing system notifications failed', error, stackTrace);
    }
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }
    final DarwinInitializationSettings darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          'zen_incoming_call',
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(
              'accept_call',
              t('Odbierz'),
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.foreground,
              },
            ),
            DarwinNotificationAction.plain(
              'decline_call',
              t('Odrzuć'),
              options: <DarwinNotificationActionOption>{
                DarwinNotificationActionOption.destructive,
              },
            ),
          ],
          options: <DarwinNotificationCategoryOption>{
            DarwinNotificationCategoryOption.customDismissAction,
            DarwinNotificationCategoryOption.allowInCarPlay,
          },
        ),
      ],
    );
    await _plugin.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('tiny_notification'),
        iOS: darwin,
        macOS: darwin,
        // Linux: clicking the notification is its default action.
        linux: LinuxInitializationSettings(defaultActionName: t('Otwórz')),
        windows: WindowsInitializationSettings(
          appName: 'Zen',
          appUserModelId: 'HuraganKodu.Zen.Rewrite.1',
          guid: 'b1d56d65-0f30-4b14-bf33-7a33b6dc7c6a',
        ),
      ),
      onDidReceiveNotificationResponse: _handleNotificationResponse,
    );
    final AndroidFlutterLocalNotificationsPlugin? android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      // A denied permission prompt (or an OEM that refuses it) must not stop
      // the channels from being registered.
      if (canRequestPermission) {
        try {
          final bool? granted = await android.requestNotificationsPermission();
          _notificationsPermissionDenied = granted == false;
          if (_notificationsPermissionDenied) {
            logZenWarning(
              'Android notification permission denied — incoming calls and '
              'messages will only appear inside the app.',
            );
          }
        } catch (error, stackTrace) {
          logZenError(
            'Requesting Android notification permission failed',
            error,
            stackTrace,
          );
        }
        try {
          await android.requestFullScreenIntentPermission();
        } catch (error, stackTrace) {
          logZenError(
            'Requesting full-screen intent permission failed',
            error,
            stackTrace,
          );
        }
      }
      for (final AndroidNotificationChannel channel in androidChannels()) {
        await _createChannel(android, channel);
      }
    }
    _initialized = true;
    try {
      final NotificationAppLaunchDetails? launchDetails = await _plugin
          .getNotificationAppLaunchDetails();
      final String? launchPayload =
          launchDetails?.didNotificationLaunchApp == true
          ? launchDetails?.notificationResponse?.payload?.trim()
          : null;
      if (launchPayload != null && launchPayload.isNotEmpty) {
        unawaitedLogged(
          _onOpenRoute(launchPayload),
          context: 'Handling notification launch route failed',
        );
      }
    } catch (error, stackTrace) {
      logZenError(
        'Reading notification launch details failed',
        error,
        stackTrace,
      );
    }
  }

  /// Registers one channel. A single failing channel must not take the
  /// others - or the caller - down with it.
  Future<void> _createChannel(
    AndroidFlutterLocalNotificationsPlugin android,
    AndroidNotificationChannel channel,
  ) async {
    try {
      await android.createNotificationChannel(channel);
    } catch (error, stackTrace) {
      logZenError(
        'Registering the "${channel.id}" notification channel failed',
        error,
        stackTrace,
      );
    }
  }

  NotificationDetails _detailsFor(
    RuntimeSystemNotification notification, {
    bool fallback = false,
    bool onlyAlertOnce = false,
  }) {
    final AndroidNotificationChannel channel = androidChannelFor(notification);
    final ZenSound? sound = zenSoundFor(notification);
    final bool isAlarm =
        notification.category == RuntimeSystemNotificationCategory.alarm;
    final bool isCall =
        isAlarm ||
        notification.category == RuntimeSystemNotificationCategory.call;
    final bool isRinging = notification.isRingingCall;
    final DarwinNotificationDetails darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBanner: true,
      presentSound: true,
      presentBadge: true,
      sound: sound?.appleFileName,
      categoryIdentifier: isRinging && !isAlarm ? 'zen_incoming_call' : null,
      interruptionLevel: isRinging
          ? InterruptionLevel.timeSensitive
          : InterruptionLevel.active,
    );
    return NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.name,
        channelDescription: channel.description,
        icon: isRinging ? 'ic_stat_call' : 'tiny_notification',
        largeIcon: fallback
            ? null
            : const DrawableResourceAndroidBitmap('ic_launcher'),
        importance: isCall ? Importance.max : Importance.high,
        priority: isCall ? Priority.max : Priority.high,
        category: isAlarm
            ? AndroidNotificationCategory.alarm
            : isCall
            ? AndroidNotificationCategory.call
            : AndroidNotificationCategory.message,
        channelShowBadge: true,
        // Private: on a secure lock screen Android shows only that there is
        // something, unless the user allows sensitive content there. Public
        // overrode that choice and put names and texts on the lock screen.
        // A ringing call and a friend's alarm stay public - they have to be
        // seen (and answered) without unlocking.
        visibility: isRinging
            ? NotificationVisibility.public
            : NotificationVisibility.private,
        ticker: notification.title,
        groupKey:
            notification.category == RuntimeSystemNotificationCategory.message
            ? 'com.roj.zen.MESSAGES'
            : null,
        // The native IncomingCallActivity is the lock-screen / overlay UI.
        // A full-screen intent would launch MainActivity and pop the whole
        // messenger in front of whatever the user was doing.
        // A friend's alarm is the exception: it must take the screen.
        fullScreenIntent: isAlarm && isRinging,
        // Only a ringing call is sticky; "declined"/"ended" must stay
        // dismissible or they pile up as notifications the user cannot swipe.
        ongoing: isRinging,
        autoCancel: !isRinging,
        playSound: sound != null,
        sound: sound == null
            ? null
            : RawResourceAndroidNotificationSound(sound.fileName),
        enableVibration: true,
        vibrationPattern: isRinging
            ? Int64List.fromList(<int>[0, 500, 200, 500, 200, 800])
            : null,
        audioAttributesUsage: isAlarm
            ? AudioAttributesUsage.alarm
            : isRinging
            ? AudioAttributesUsage.notificationRingtone
            : AudioAttributesUsage.notification,
        additionalFlags: isAlarm && isRinging
            ? Int32List.fromList(<int>[_flagInsistent])
            : null,
        onlyAlertOnce: onlyAlertOnce && !isRinging,
        number: notification.stackCount > 1 ? notification.stackCount : null,
        styleInformation: notification.lines.length > 1
            ? InboxStyleInformation(
                notification.lines,
                contentTitle: notification.title,
                summaryText: tn(
                  notification.stackCount,
                  one: '{n} nowa wiadomość',
                  few: '{n} nowe wiadomości',
                  many: '{n} nowych wiadomości',
                ),
              )
            : BigTextStyleInformation(
                notification.body,
                contentTitle: notification.title,
              ),
        actions: isRinging && !isAlarm
            ? <AndroidNotificationAction>[
                AndroidNotificationAction(
                  'accept_call',
                  t('Odbierz'),
                  showsUserInterface: true,
                  cancelNotification: true,
                ),
                AndroidNotificationAction(
                  'decline_call',
                  t('Odrzuć'),
                  showsUserInterface: false,
                  cancelNotification: true,
                ),
              ]
            : null,
      ),
      windows: WindowsNotificationDetails(
        duration: isCall
            ? WindowsNotificationDuration.long
            : WindowsNotificationDuration.short,
        scenario: isAlarm && isRinging
            ? WindowsNotificationScenario.alarm
            : isRinging
            ? WindowsNotificationScenario.incomingCall
            : null,
        subtitle: channel.name,
        // Zen plays its own sound instead (see [_playOwnSound]).
        audio: _playsOwnSounds ? WindowsNotificationAudio.silent() : null,
      ),
      iOS: darwin,
      macOS: darwin,
      linux: LinuxNotificationDetails(
        urgency: isCall
            ? LinuxNotificationUrgency.critical
            : LinuxNotificationUrgency.normal,
        suppressSound: _playsOwnSounds,
      ),
    );
  }

  bool get _playsOwnSounds => soundEffects?.playsNotificationSounds ?? false;

  /// Windows and Linux: the sound of a notification just posted. A ringing
  /// call rings from [RuntimeSystemNotificationsBridge] (for as long as it
  /// rings); a ringing alarm repeats until its notification goes.
  void _playOwnSound(
    RuntimeSystemNotification notification,
    String slotKey, {
    required bool onlyAlertOnce,
  }) {
    final ZenSoundEffects? effects = soundEffects;
    final ZenSound? sound = zenSoundFor(notification);
    if (!notification.isRingingCall) {
      _stopAlarmLoop(slotKey);
    }
    if (effects == null ||
        !_playsOwnSounds ||
        sound == null ||
        sound == ZenSound.ringtone ||
        onlyAlertOnce) {
      return;
    }
    if (sound == ZenSound.alarm && notification.isRingingCall) {
      unawaitedLogged(
        _startAlarmLoop(effects, slotKey),
        context: 'Starting the alarm sound failed',
      );
      return;
    }
    unawaitedLogged(
      effects.play(sound),
      context: 'Playing a notification sound failed',
    );
  }

  Future<void> _startAlarmLoop(ZenSoundEffects effects, String slotKey) async {
    if (_alarmLoops[slotKey]?.isStopped == false ||
        !_alarmLoopsStarting.add(slotKey)) {
      return;
    }
    try {
      final ZenSoundLoop? loop = await effects.loop(ZenSound.alarm);
      if (loop == null) {
        return;
      }
      if (!_alarmLoopsStarting.contains(slotKey) ||
          _activeNotificationsBySlot[slotKey]?.isRingingCall != true) {
        // The alarm went while the sound was starting.
        await loop.stop();
        return;
      }
      _alarmLoops[slotKey] = loop;
    } finally {
      _alarmLoopsStarting.remove(slotKey);
    }
  }

  void _stopAlarmLoop(String slotKey) {
    _alarmLoopsStarting.remove(slotKey);
    final ZenSoundLoop? loop = _alarmLoops.remove(slotKey);
    if (loop != null) {
      unawaitedLogged(loop.stop(), context: 'Stopping the alarm sound failed');
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final String? actionId = response.actionId?.trim();
    final String? payload = response.payload?.trim();
    if (actionId != null && actionId.isNotEmpty) {
      final NotificationActionCallback? onAction = _onAction;
      if (onAction != null) {
        unawaitedLogged(
          onAction(actionId, payload),
          context: 'Handling notification action failed',
        );
      }
      // Routing an action is the action handler's own job: opening the payload
      // route from here as well would race it, and the plain ringing route
      // would overwrite the accept route the handler just queued.
      return;
    }
    if (payload == null || payload.isEmpty) {
      return;
    }
    unawaitedLogged(
      _onOpenRoute(payload),
      context: 'Handling notification tap route failed',
    );
  }
}

class RuntimeSystemNotificationsBridge extends ConsumerStatefulWidget {
  const RuntimeSystemNotificationsBridge({required this.child, super.key});

  final Widget child;

  @override
  ConsumerState<RuntimeSystemNotificationsBridge> createState() =>
      _RuntimeSystemNotificationsBridgeState();
}

/// What the call sounds follow: which call, in which state, which way.
typedef _CallSoundState = ({
  String? id,
  CallSessionStatus? status,
  bool incoming,
});

_CallSoundState _callSoundStateOf(SocialHubState state) {
  final CallSession? call = state.activeCall;
  return (
    id: call?.id,
    status: call?.status,
    incoming: call?.isIncoming ?? false,
  );
}

final class _RuntimeSystemNotificationsBridgeState
    extends ConsumerState<RuntimeSystemNotificationsBridge> {
  bool _initialized = false;
  bool _lastFocused = false;

  /// Windows and Linux: the ringtone while a call rings here.
  ZenSoundLoop? _ringtone;
  bool _ringtoneStarting = false;
  bool _wantsRingtone = false;

  @override
  void initState() {
    super.initState();
    unawaitedLogged(
      _initialize(),
      context: 'Runtime system notifications bridge initialization failed',
    );
  }

  @override
  void dispose() {
    _wantsRingtone = false;
    _stopRingtone();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<_CallSoundState>(
      socialHubControllerProvider.select(_callSoundStateOf),
      _onCallSoundState,
    );
    final bool isFocused = ref.watch(
      socialHubControllerProvider.select((state) => state.lifecycle.isFocused),
    );
    if (_initialized && isFocused && !_lastFocused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaitedLogged(
          ref.read(runtimeSystemNotificationServiceProvider).clear(),
          context: 'Clearing focused system notifications failed',
        );
      });
    }
    _lastFocused = isFocused;
    return widget.child;
  }

  /// A call that connects or ends gets its short sound; on Windows and
  /// Linux an incoming call rings here for as long as it rings.
  void _onCallSoundState(_CallSoundState? previous, _CallSoundState next) {
    final ZenSoundEffects effects = ref.read(zenSoundEffectsProvider);
    final bool wasOn = previous?.status == CallSessionStatus.active;
    final bool isOn = next.status == CallSessionStatus.active;
    final bool sameCall = previous?.id == next.id;
    if (isOn && !(wasOn && sameCall)) {
      unawaitedLogged(
        effects.play(ZenSound.callConnected),
        context: 'Playing the call sound failed',
      );
    } else if (wasOn && !(isOn && sameCall)) {
      unawaitedLogged(
        effects.play(ZenSound.callEnded),
        context: 'Playing the call sound failed',
      );
    }
    if (!effects.playsNotificationSounds) {
      // Elsewhere the system rings (the notification, Android's call card).
      return;
    }
    _wantsRingtone = next.incoming && next.status == CallSessionStatus.ringing;
    if (!_wantsRingtone) {
      _stopRingtone();
    } else if ((_ringtone == null || _ringtone!.isStopped) &&
        !_ringtoneStarting) {
      unawaitedLogged(
        _startRingtone(effects),
        context: 'Starting the ringtone failed',
      );
    }
  }

  Future<void> _startRingtone(ZenSoundEffects effects) async {
    _ringtoneStarting = true;
    try {
      final ZenSoundLoop? loop = await effects.loop(
        ZenSound.ringtone,
        maxDuration: const Duration(minutes: 2),
      );
      if (loop == null) {
        return;
      }
      if (!_wantsRingtone || !mounted) {
        await loop.stop();
        return;
      }
      _ringtone = loop;
    } finally {
      _ringtoneStarting = false;
    }
  }

  void _stopRingtone() {
    final ZenSoundLoop? ringtone = _ringtone;
    _ringtone = null;
    if (ringtone != null) {
      unawaitedLogged(ringtone.stop(), context: 'Stopping the ringtone failed');
    }
  }

  Future<void> _initialize() async {
    await ref
        .read(runtimeSystemNotificationServiceProvider)
        .initialize(
          onOpenRoute: (String routeKey) {
            return ref
                .read(socialHubControllerProvider.notifier)
                .requestLaunchFromRouteKey(routeKey);
          },
          onAction: (String actionId, String? payload) async {
            final SocialHubState state = ref.read(socialHubControllerProvider);
            final CallSession? activeCall = state.activeCall;
            if (activeCall == null) {
              return;
            }
            final String peerAddress = activeCall.peerAddress;
            final SocialHubController controller = ref.read(
              socialHubControllerProvider.notifier,
            );
            if (actionId == 'accept_call') {
              await controller.acceptIncomingCall(peerAddress: peerAddress);
              // The notification is cancelled the moment it is answered, so
              // without this the accepted call would have no surface at all.
              await controller.requestLaunchFromRouteKey(
                buildCallRouteKey(
                  peerAddress: peerAddress,
                  title: activeCall.displayName,
                ),
              );
            } else if (actionId == 'decline_call') {
              await controller.declineIncomingCall(peerAddress: peerAddress);
            }
          },
        );
    bindIncomingCallPlatformHandler((String action, String peerAddress) async {
      final SocialHubController controller = ref.read(
        socialHubControllerProvider.notifier,
      );
      if (action == 'decline' || action == 'decline_call') {
        await controller.declineIncomingCall(peerAddress: peerAddress);
        return;
      }
      if (action == 'accept' || action == 'accept_call') {
        final CallSession? activeCall = ref
            .read(socialHubControllerProvider)
            .activeCall;
        await controller.acceptIncomingCall(peerAddress: peerAddress);
        await controller.requestLaunchFromRouteKey(
          buildCallRouteKey(
            peerAddress: peerAddress,
            title: activeCall?.displayName,
            autoAccept: true,
            callId: activeCall?.id,
          ),
        );
      }
    });
    if (!mounted) {
      return;
    }
    _initialized = true;
    if (_lastFocused) {
      unawaitedLogged(
        ref.read(runtimeSystemNotificationServiceProvider).clear(),
        context: 'Clearing startup system notifications failed',
      );
    }
  }
}

Future<void> _noopOpenRoute(String _) async {}

/// True when [candidate] would only re-post the ringing notification [active]
/// already holds in the same slot.
///
/// An outgoing call re-sends its invite once per second, so without this the
/// callee re-posts the very same ringing notification every second: it
/// re-fires the ringtone and the full-screen intent, and keeps swapping out
/// the buttons the user is trying to press.
bool _isRedundantRingingRepost(
  RuntimeSystemNotification? active,
  RuntimeSystemNotification candidate,
) {
  return candidate.isRingingCall &&
      active != null &&
      active.isRingingCall &&
      active.title == candidate.title &&
      active.body == candidate.body &&
      active.routeKey == candidate.routeKey;
}

final class _NotificationSuppressionWindow {
  _NotificationSuppressionWindow();

  static const Duration _window = Duration(seconds: 60);

  final Map<String, int> _seenAtMillis = <String, int>{};

  bool shouldNotify(String key, int observedAtMillis) {
    _prune(observedAtMillis);
    final int? previousMillis = _seenAtMillis[key];
    if (previousMillis != null &&
        observedAtMillis - previousMillis < _window.inMilliseconds) {
      return false;
    }
    _seenAtMillis[key] = observedAtMillis;
    return true;
  }

  void clear() {
    _seenAtMillis.clear();
  }

  void forget(String key) {
    _seenAtMillis.remove(key);
  }

  void _prune(int observedAtMillis) {
    _seenAtMillis.removeWhere(
      (_, int previousMillis) =>
          observedAtMillis - previousMillis >= _window.inMilliseconds,
    );
  }
}
