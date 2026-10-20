import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/calls/call_platform_channel.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';

/// Something Zen asks the system for (§25.2), in the order it asks.
enum ZenPermission {
  notifications,

  /// Bluetooth scan / advertise / connect (Android 12+), the location
  /// permission on Android 11 and older.
  bluetooth,

  /// Bluetooth itself switched on.
  bluetoothOn,

  /// Where this phone is while Zen is open: the place sent with an alarm,
  /// neighbours nearby (§16.3, §17).
  location,

  /// The same, also with the screen off ("Always" in the system dialog):
  /// an alarm raised from the lock screen or the background service.
  backgroundLocation,

  /// A friend's alarm over the locked screen (Android 14+ may refuse it).
  fullScreen,

  /// Alarms and reminders at the exact minute (Android 12+: a special
  /// access the person gives on a system page).
  exactAlarms,

  /// Android does not put Zen to sleep (battery optimisation off).
  battery,
  microphone,
  camera;

  /// Not needed for messages, alarms and Bluetooth: asked again on first
  /// use anyway.
  bool get optional =>
      this == ZenPermission.microphone ||
      this == ZenPermission.camera ||
      this == ZenPermission.location ||
      this == ZenPermission.backgroundLocation ||
      this == ZenPermission.exactAlarms;
}

/// What the permissions screen shows.
@immutable
final class PermissionsSnapshot {
  const PermissionsSnapshot({
    this.applicable = const <ZenPermission>[],
    this.granted = const <ZenPermission, bool>{},
    this.bluetoothNeedsLocation = false,
    this.manufacturer = '',
  });

  /// What applies on this device, in the order it is asked.
  final List<ZenPermission> applicable;

  /// What the system says; a permission missing here cannot be checked on
  /// this device (the system's own settings tell).
  final Map<ZenPermission, bool> granted;

  /// Android 11 and older: Bluetooth needs the location permission.
  final bool bluetoothNeedsLocation;

  /// The phone maker (`Build.MANUFACTURER`, lower case; empty when unknown):
  /// picks the battery instructions of the vendor.
  final String manufacturer;

  bool? operator [](ZenPermission permission) => granted[permission];

  /// Bluetooth may be used and is on.
  bool get bluetoothReady =>
      granted[ZenPermission.bluetooth] == true &&
      granted[ZenPermission.bluetoothOn] == true;
}

/// The system side of the permissions screen (a fake in tests).
abstract interface class PermissionsPlatform {
  /// Whether there is anything to ask for here (if not, the first-start
  /// step is skipped).
  bool get hasAnything;

  /// Whether people nearby (Bluetooth, §15) exist on this platform.
  bool get hasBluetooth;

  Future<PermissionsSnapshot> check();

  /// Asks the system (a dialog or a system page); the answer shows in the
  /// next [check].
  Future<void> request(ZenPermission permission);

  /// Opens the system page where [permission] is changed by hand (after
  /// the system stopped asking).
  Future<void> openSettings(ZenPermission permission);

  /// Bluetooth switched on (`true`) or off.
  Stream<bool> get bluetoothChanges;
}

/// Android: notifications, Bluetooth, the full-screen alarm, battery,
/// microphone and camera.
final class AndroidPermissionsPlatform implements PermissionsPlatform {
  AndroidPermissionsPlatform({ChannelNearbyRadio? radio})
    : _radio = radio ?? ChannelNearbyRadio();

  static const MethodChannel _channel = MethodChannel('zen/permissions');

  /// The Android version (14) that may refuse full-screen notifications.
  static const int _fullScreenSdk = 34;

  /// Android 10: "allow all the time" is a separate step.
  static const int _backgroundLocationSdk = 29;

  /// Android 12: SCHEDULE_EXACT_ALARM.
  static const int _exactAlarmSdk = 31;

  final ChannelNearbyRadio _radio;

  @override
  bool get hasAnything => true;

  @override
  bool get hasBluetooth => true;

  Future<Map<Object?, Object?>> _state() async {
    try {
      return await _channel.invokeMethod<Map<Object?, Object?>>('state') ??
          const <Object?, Object?>{};
    } on MissingPluginException {
      return const <Object?, Object?>{};
    } on PlatformException catch (error) {
      logZenWarning('Uprawnienia: ${error.message}');
      return const <Object?, Object?>{};
    }
  }

  @override
  Future<PermissionsSnapshot> check() async {
    final Map<Object?, Object?> own = await _state();
    final Map<Object?, Object?> radio = await _radio.state();
    final bool battery = await isAndroidBackgroundDeliveryUnrestricted();
    final bool fullScreen = await canUseCallFullScreenIntent();
    final Object? sdk = own['sdk'];
    final bool bluetooth = radio['supported'] == true;
    final LocationPermission? place = await _locationPermission();
    return PermissionsSnapshot(
      applicable: <ZenPermission>[
        ZenPermission.notifications,
        if (bluetooth) ...<ZenPermission>[
          ZenPermission.bluetooth,
          ZenPermission.bluetoothOn,
        ],
        ZenPermission.location,
        // Android 10 split "also in the background" from the rest.
        if (sdk is int && sdk >= _backgroundLocationSdk)
          ZenPermission.backgroundLocation,
        if (sdk is int && sdk >= _fullScreenSdk) ZenPermission.fullScreen,
        // Android 12: exact alarms became a special access.
        if (sdk is int && sdk >= _exactAlarmSdk) ZenPermission.exactAlarms,
        ZenPermission.battery,
        ZenPermission.microphone,
        ZenPermission.camera,
      ],
      granted: <ZenPermission, bool>{
        ZenPermission.notifications: own['notifications'] == true,
        ZenPermission.bluetooth: radio['permitted'] == true,
        ZenPermission.bluetoothOn: radio['enabled'] == true,
        ZenPermission.location:
            place == LocationPermission.whileInUse ||
            place == LocationPermission.always,
        ZenPermission.backgroundLocation: place == LocationPermission.always,
        ZenPermission.fullScreen: fullScreen,
        // Missing in the answer of an older app part: nothing to ask.
        ZenPermission.exactAlarms: own['exactAlarms'] != false,
        ZenPermission.battery: battery,
        ZenPermission.microphone: own['microphone'] == true,
        ZenPermission.camera: own['camera'] == true,
      },
      bluetoothNeedsLocation: radio['needsLocation'] == true,
      manufacturer: own['manufacturer'] is String
          ? (own['manufacturer']! as String).toLowerCase()
          : '',
    );
  }

  Future<LocationPermission?> _locationPermission() async {
    try {
      return await Geolocator.checkPermission();
    } on Object catch (error) {
      logZenWarning('Uprawnienia (położenie): $error');
      return null;
    }
  }

  @override
  Future<void> request(ZenPermission permission) async {
    switch (permission) {
      case ZenPermission.notifications ||
          ZenPermission.microphone ||
          ZenPermission.camera ||
          ZenPermission.exactAlarms:
        try {
          await _channel.invokeMethod<bool>('request', permission.name);
        } on MissingPluginException {
          // An engine without the bridge: nothing to ask.
        } on PlatformException catch (error) {
          logZenWarning('Uprawnienia (${permission.name}): ${error.message}');
        }
      case ZenPermission.bluetooth:
        await _radio.requestPermissions();
      case ZenPermission.bluetoothOn:
        await _radio.requestEnable();
      case ZenPermission.location:
        try {
          await Geolocator.requestPermission();
        } on Object catch (error) {
          logZenWarning('Uprawnienia (położenie): $error');
        }
      case ZenPermission.backgroundLocation:
        try {
          LocationPermission now = await Geolocator.checkPermission();
          if (now == LocationPermission.denied) {
            now = await Geolocator.requestPermission();
          }
          // Android 11+ takes "all the time" only from the settings page.
          if (now != LocationPermission.always) {
            await openAndroidAppSettings();
          }
        } on Object catch (error) {
          logZenWarning('Uprawnienia (położenie w tle): $error');
        }
      case ZenPermission.fullScreen:
        await requestCallFullScreenIntentPermission();
      case ZenPermission.battery:
        await requestAndroidBackgroundDeliveryExemption();
    }
  }

  @override
  Future<void> openSettings(ZenPermission permission) async {
    await openAndroidAppSettings();
  }

  @override
  Stream<bool> get bluetoothChanges => _radio.events
      .where((Map<Object?, Object?> e) => e['type'] == 'bluetooth')
      .map((Map<Object?, Object?> e) => e['on'] == true);
}

/// Windows: no Bluetooth here; notifications, microphone and camera are
/// set in the system's own settings (it asks on first use).
final class WindowsPermissionsPlatform implements PermissionsPlatform {
  const WindowsPermissionsPlatform();

  @override
  bool get hasAnything => true;

  @override
  bool get hasBluetooth => false;

  @override
  Future<PermissionsSnapshot> check() async => const PermissionsSnapshot(
    applicable: <ZenPermission>[
      ZenPermission.notifications,
      ZenPermission.microphone,
      ZenPermission.camera,
    ],
  );

  @override
  Future<void> request(ZenPermission permission) => openSettings(permission);

  @override
  Future<void> openSettings(ZenPermission permission) async {
    final String page = switch (permission) {
      ZenPermission.notifications => 'ms-settings:notifications',
      ZenPermission.microphone => 'ms-settings:privacy-microphone',
      ZenPermission.camera => 'ms-settings:privacy-webcam',
      _ => 'ms-settings:',
    };
    try {
      await Process.run('explorer', <String>[page]);
    } on Object catch (error) {
      logZenWarning('Ustawienia Windows: $error');
    }
  }

  @override
  Stream<bool> get bluetoothChanges => const Stream<bool>.empty();
}

/// Everywhere else (and in tests): nothing to ask.
final class NoPermissionsPlatform implements PermissionsPlatform {
  const NoPermissionsPlatform();

  @override
  bool get hasAnything => false;

  @override
  bool get hasBluetooth => false;

  @override
  Future<PermissionsSnapshot> check() async => const PermissionsSnapshot();

  @override
  Future<void> request(ZenPermission permission) async {}

  @override
  Future<void> openSettings(ZenPermission permission) async {}

  @override
  Stream<bool> get bluetoothChanges => const Stream<bool>.empty();
}

final Provider<PermissionsPlatform> permissionsPlatformProvider =
    Provider<PermissionsPlatform>((Ref ref) {
      if (kIsWeb) {
        return const NoPermissionsPlatform();
      }
      if (Platform.isAndroid) {
        return AndroidPermissionsPlatform();
      }
      if (Platform.isWindows) {
        return const WindowsPermissionsPlatform();
      }
      return const NoPermissionsPlatform();
    });

/// Whether the first start shows "Uprawnienia i Bluetooth" (§25.2) until
/// it is done. Off in tests and previews; the real app turns it on (like
/// the app password).
final Provider<bool> permissionsSetupRequiredProvider = Provider<bool>(
  (Ref ref) => false,
);
