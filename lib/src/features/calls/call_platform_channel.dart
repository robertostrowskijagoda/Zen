import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Android-only hooks the call UI needs but Flutter does not expose.
///
/// Lives on the activity engine, so every call is a no-op off Android and in
/// the foreground-service isolate (which has no activity attached).
const MethodChannel zenCallPlatformChannel = MethodChannel('zen/calls');

/// Whether Android still lets a ringing call use its full-screen intent.
///
/// Android 14 revokes `USE_FULL_SCREEN_INTENT` for apps that the Play Store
/// does not classify as calling apps. Without it an incoming call is reduced
/// to a heads-up notification and never takes over a locked screen, so the UI
/// has to be able to tell the user why calls look "silent".
Future<bool> canUseCallFullScreenIntent() async {
  if (!Platform.isAndroid) {
    return true;
  }
  try {
    final bool? granted = await zenCallPlatformChannel.invokeMethod<bool>(
      'canUseFullScreenIntent',
    );
    return granted ?? false;
  } catch (error, stackTrace) {
    logZenError(
      'Reading the full-screen intent permission failed',
      error,
      stackTrace,
    );
    return false;
  }
}

/// Opens the system page where the user grants the full-screen intent, then
/// reports the state it was left in.
Future<bool> requestCallFullScreenIntentPermission() async {
  if (!Platform.isAndroid) {
    return true;
  }
  try {
    // The settings screen is driven by flutter_local_notifications, which
    // already owns the activity result plumbing for it.
    await FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestFullScreenIntentPermission();
  } catch (error, stackTrace) {
    logZenError(
      'Requesting the full-screen intent permission failed',
      error,
      stackTrace,
    );
  }
  return canUseCallFullScreenIntent();
}

/// Marks the window as "a call is ringing", so Android wakes the screen and
/// draws the app over the keyguard.
///
/// Must be cleared when the call stops ringing — otherwise the whole
/// messenger stays visible on the lock screen.
Future<void> setRingingCallWindowActive(bool active) async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>(
      'setRingingCallActive',
      active,
    );
  } catch (error, stackTrace) {
    logZenError(
      'Updating the ringing call window flags failed',
      error,
      stackTrace,
    );
  }
}

/// Brings the main activity / app window to the front.
Future<void> bringAppToFront() async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>('bringToFront');
  } catch (error, stackTrace) {
    logZenError('bringAppToFront failed', error, stackTrace);
  }
}

/// Shows the native incoming-call card over other apps / the lock screen.
///
/// This is a separate activity, not [MainActivity], so the messenger itself
/// stays in the background.
Future<bool> showIncomingCallPopup({
  required String displayName,
  required bool isVideo,
  required String peerAddress,
  required String acceptRouteKey,
}) async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    final bool? shown = await zenCallPlatformChannel
        .invokeMethod<bool>('showIncomingCallPopup', <String, Object>{
          'displayName': displayName,
          'isVideo': isVideo,
          'peerAddress': peerAddress,
          'acceptRouteKey': acceptRouteKey,
        });
    return shown ?? false;
  } catch (error, stackTrace) {
    logZenError('Showing the incoming-call popup failed', error, stackTrace);
    return false;
  }
}

/// Dismisses the native incoming-call card if it is on screen.
Future<void> hideIncomingCallPopup() async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>('hideIncomingCallPopup');
  } catch (error, stackTrace) {
    logZenError('Hiding the incoming-call popup failed', error, stackTrace);
  }
}

/// Asks Android to dismiss the keyguard so the in-call UI can be used.
///
/// Only after the user has already answered — doing this while the call is
/// still ringing puts the PIN pad on top of the accept/decline buttons.
Future<void> unlockForCall() async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>('unlockForCall');
  } catch (error, stackTrace) {
    logZenError(
      'Unlocking the screen for an accepted call failed',
      error,
      stackTrace,
    );
  }
}

typedef IncomingCallPlatformActionHandler =
    Future<void> Function(String action, String peerAddress);

/// Listens for accept/decline from the native incoming-call card.
void bindIncomingCallPlatformHandler(
  IncomingCallPlatformActionHandler onAction,
) {
  if (!Platform.isAndroid) {
    return;
  }
  zenCallPlatformChannel.setMethodCallHandler((MethodCall call) async {
    switch (call.method) {
      case 'onPipChanged':
        pictureInPictureChanged?.call(call.arguments == true);
        return;
      case 'onPipAction':
        if (call.arguments == 'hangup') {
          await pictureInPictureHangUp?.call();
        }
        return;
    }
    if (call.method != 'onIncomingCallAction') {
      return;
    }
    final Object? raw = call.arguments;
    if (raw is! Map) {
      return;
    }
    final String action = '${raw['action'] ?? ''}'.trim();
    final String peerAddress = '${raw['peerAddress'] ?? ''}'.trim();
    if (action.isEmpty || peerAddress.isEmpty) {
      return;
    }
    await onAction(action, peerAddress);
  });
}

/// Picture-in-picture entered (true) or left (false); set by the call UI.
void Function(bool inPip)? pictureInPictureChanged;

/// "Rozłącz" pressed in the picture-in-picture window; set by the call UI.
Future<void> Function()? pictureInPictureHangUp;

/// Arms picture-in-picture for a running call (or disarms it): leaving the
/// app then shrinks it into a small window over other apps.
Future<void> setPictureInPictureCall({
  required bool active,
  required bool video,
}) async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>(
      'setPipCall',
      <String, Object>{'active': active, 'video': video},
    );
  } catch (error, stackTrace) {
    logZenError('Setting up picture-in-picture failed', error, stackTrace);
  }
}

/// Whether the app has permission to draw floating overlays above other apps.
Future<bool> canDrawOverlays() async {
  if (!Platform.isAndroid) {
    return true;
  }
  try {
    final bool? granted = await zenCallPlatformChannel.invokeMethod<bool>(
      'canDrawOverlays',
    );
    return granted ?? false;
  } catch (error, stackTrace) {
    logZenError('Checking canDrawOverlays failed', error, stackTrace);
    return false;
  }
}

/// Opens the Android system settings screen for floating overlay permission.
Future<void> openOverlaySettings() async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>('openOverlaySettings');
  } catch (error, stackTrace) {
    logZenError('Opening overlay settings failed', error, stackTrace);
  }
}

/// Requests Camera, Microphone, and Notification runtime permissions.
Future<void> requestAllAppPermissions() async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>('requestAllAppPermissions');
  } catch (error, stackTrace) {
    logZenError('Requesting runtime app permissions failed', error, stackTrace);
  }
}

/// Checks the state of all required permissions on Android.
Future<Map<String, bool>> checkAllPermissions() async {
  if (!Platform.isAndroid) {
    return <String, bool>{
      'audio': true,
      'camera': true,
      'notifications': true,
      'overlay': true,
      'batteryExempt': true,
    };
  }
  try {
    final Map<Object?, Object?>? result = await zenCallPlatformChannel
        .invokeMethod<Map<Object?, Object?>>('checkPermissions');
    if (result == null) {
      return <String, bool>{};
    }
    return result.map(
      (Object? key, Object? value) => MapEntry(key.toString(), value == true),
    );
  } catch (error, stackTrace) {
    logZenError('Checking all permissions failed', error, stackTrace);
    return <String, bool>{};
  }
}
