import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/meet/meet_service.dart';

/// How long a shortcut may wait for the network (the background service
/// taking it over) before it is dropped: an old press must not start an
/// alarm much later.
const Duration kAlarmShortcutMaxDelay = Duration(minutes: 2);

/// What the power-button shortcut did (§16.3).
enum ShortcutAlarmResult {
  /// The alarm went out.
  raised,

  /// This person's alarm already runs: nothing new.
  alreadyRunning,

  /// The shortcut is off.
  off,

  /// No alarm PINs yet, so an alarm could not be ended safely.
  noPin,
}

/// Raises the alarm for the power-button shortcut: exactly the alarm of
/// the 3-second button (the same friends, the same Bluetooth wave when that
/// is on, it ends only with the PIN, and the panic PIN works as always).
/// Reads the newest settings first: the app and the Android background
/// service share them.
Future<ShortcutAlarmResult> raiseAlarmFromShortcut(MeetService meet) async {
  await meet.reload();
  if (!meet.book.alarmPowerButton) {
    return ShortcutAlarmResult.off;
  }
  if (!meet.hasAlarmPin) {
    return ShortcutAlarmResult.noPin;
  }
  if (meet.book.ownActiveAlarm != null) {
    return ShortcutAlarmResult.alreadyRunning;
  }
  await meet.raiseAlarm();
  return ShortcutAlarmResult.raised;
}

/// The power-button shortcut on Android (`zen/alarm_shortcut`). The phone
/// itself counts screen on/off changes (5 within about 4 seconds), vibrates
/// and tells exactly one part of the app: the background service while it
/// runs the network, otherwise the app.
final class AlarmShortcutChannel {
  const AlarmShortcutChannel();

  static const MethodChannel _channel = MethodChannel('zen/alarm_shortcut');
  static const EventChannel _events = EventChannel('zen/alarm_shortcut/events');

  /// One subscription per isolate, shared by every listener in it.
  static final Stream<void> _presses = _events
      .receiveBroadcastStream()
      .where((Object? e) => e is Map && e['type'] == 'power')
      .map<void>((Object? _) {})
      .handleError((Object error) => logZenWarning('Skrót alarmu: $error'));

  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// One event per completed shortcut.
  Stream<void> get presses => supported ? _presses : const Stream<void>.empty();

  /// Starts (or stops) counting presses.
  Future<void> setEnabled(bool on) => _call('setEnabled', on);

  /// Whether this isolate (the background service) runs the network now:
  /// the shortcut then comes here.
  Future<void> setNodeOwner(bool on) => _call('setNodeOwner', on);

  Future<void> _call(String method, Object? args) async {
    if (!supported) {
      return;
    }
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // An engine without the bridge: nothing to tell.
    } on PlatformException catch (error) {
      logZenWarning('Skrót alarmu ($method): ${error.message}');
    }
  }
}
