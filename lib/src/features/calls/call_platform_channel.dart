import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/calls/call_video_quality.dart';

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

/// Rings for an incoming call ([on]) as a phone call rings (Android: the
/// phone's ringtone over and over at the ringer's volume and a repeating
/// vibration, as the ringer mode allows, ZenRinger.kt), or stops it.
Future<void> setCallRinging(bool on) async {
  if (!Platform.isAndroid) {
    return;
  }
  try {
    await zenCallPlatformChannel.invokeMethod<void>('setCallRinging', on);
  } catch (error, stackTrace) {
    logZenError('Ringing for a call failed', error, stackTrace);
  }
}

/// Whether the phone is locked or its screen is off: nobody sees the app
/// then, even while a ringing call drew it over the keyguard (a missed call
/// still needs its notification). False off Android.
Future<bool> isDeviceLocked() async {
  if (!Platform.isAndroid) {
    return false;
  }
  try {
    return await zenCallPlatformChannel.invokeMethod<bool>('isDeviceLocked') ??
        false;
  } catch (error, stackTrace) {
    logZenError('Asking whether the phone is locked failed', error, stackTrace);
    return false;
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

/// Keeps the screen on ([on]) for a running call, or lets it go
/// (CallScreenKeepOn.kt, apart from the ringing's flag). Whether the app's
/// window took it now (false: no window at the moment, it is set when one
/// shows); null off Android.
Future<bool?> setCallKeepScreenOn(bool on) async {
  if (!Platform.isAndroid) {
    return null;
  }
  try {
    return await zenCallPlatformChannel.invokeMethod<bool>(
          'setCallKeepScreenOn',
          on,
        ) ??
        false;
  } catch (error, stackTrace) {
    logZenError('Keeping the screen on for the call failed', error, stackTrace);
    return false;
  }
}

/// Pins the auto-exposure of the call camera behind the video track
/// [trackId] to the steadiest frame-rate range the camera offers
/// ([chooseCameraFrameRateRange]; ZenCallCamera.kt): in poor light the
/// camera no longer slows to a few frames a second. Android only (the
/// caller checks); never throws. Returns one line for the technical log:
/// what was offered, what the camera ran at, what was pinned or why not.
Future<String> steadyCallCameraFrameRate(
  String trackId, {
  MethodChannel channel = zenCallPlatformChannel,
}) async {
  try {
    final Map<Object?, Object?>? found = await channel
        .invokeMethod<Map<Object?, Object?>>(
          'callCameraFrameRates',
          <String, Object?>{'trackId': trackId},
        );
    final Object? error = found?['error'];
    if (found == null || error != null) {
      return 'not read (${error ?? 'no answer'})';
    }
    final List<CameraFrameRateRange> offered = cameraFrameRateRanges(
      found['ranges'],
    );
    final List<CameraFrameRateRange> current = cameraFrameRateRanges(<Object?>[
      found['current'],
    ]);
    final String was = current.isEmpty
        ? '?'
        : describeCameraFrameRateRange(current.first);
    final String offers = offered.isEmpty
        ? 'nothing'
        : offered.map(describeCameraFrameRateRange).join(' ');
    final CameraFrameRateRange? chosen = chooseCameraFrameRateRange(offered);
    if (chosen == null) {
      return 'kept at $was fps: no steady range among $offers';
    }
    if (current.isNotEmpty && current.first == chosen) {
      return 'already at $was fps (offers $offers)';
    }
    final String? outcome = await channel.invokeMethod<String>(
      'pinCallCameraFrameRate',
      <String, Object?>{
        'trackId': trackId,
        'min': chosen.min,
        'max': chosen.max,
      },
    );
    return '${outcome == 'pinned' ? 'pinned to' : 'not pinned (${outcome ?? 'no answer'}) to'} '
        '${describeCameraFrameRateRange(chosen)} fps, was $was (offers $offers)';
  } on Object catch (error) {
    return 'not pinned: $error';
  }
}
