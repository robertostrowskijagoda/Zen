import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// A place on Earth, for the alarm (§16.3).
@immutable
final class GeoFix {
  const GeoFix(this.lat, this.lon, this.accuracy);

  final double lat;
  final double lon;

  /// Metres.
  final double accuracy;
}

/// Where positions come from (the phone's location service); tests give
/// their own.
abstract interface class GeoSource {
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<bool> serviceEnabled();

  /// One fresh, accurate position (foreground).
  Future<GeoFix> current(Duration timeout);

  /// One fresh position asked for under a notification of its own: on
  /// Android that runs a foreground service of the `location` type, which is
  /// what lets a background service (the alarm shortcut with Zen closed)
  /// read the position at all.
  Future<GeoFix> currentUnderService(Duration timeout);

  Future<GeoFix?> lastKnown();
}

GeoFix _fix(Position p) => GeoFix(p.latitude, p.longitude, p.accuracy);

final class _GeolocatorSource implements GeoSource {
  const _GeolocatorSource();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<GeoFix> current(Duration timeout) async => _fix(
    await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: timeout,
      ),
    ),
  );

  @override
  Future<GeoFix> currentUnderService(Duration timeout) async {
    final LocationSettings settings =
        defaultTargetPlatform == TargetPlatform.android
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            intervalDuration: const Duration(seconds: 2),
            foregroundNotificationConfig: ForegroundNotificationConfig(
              notificationTitle: 'Zen',
              notificationText: t('Ustalam położenie dla alarmu'),
              notificationChannelName: t('Położenie alarmu'),
            ),
          )
        : LocationSettings(accuracy: LocationAccuracy.high);
    // The first position is enough; leaving the stream ends the service.
    return _fix(
      await Geolocator.getPositionStream(
        locationSettings: settings,
      ).first.timeout(timeout),
    );
  }

  @override
  Future<GeoFix?> lastKnown() async {
    final Position? p = await Geolocator.getLastKnownPosition();
    return p == null ? null : _fix(p);
  }
}

/// The source the app uses; replaced in tests.
@visibleForTesting
GeoSource geoSource = const _GeolocatorSource();

bool _allowed(LocationPermission p) =>
    p == LocationPermission.whileInUse || p == LocationPermission.always;

/// Where the phone is now, asking for permission when needed (and when
/// [ask] is true: a background service cannot show the question). `null`
/// when location is off, refused or unavailable — the alarm then goes
/// without it. Used only while an alarm runs.
Future<GeoFix?> currentFix({
  Duration timeout = const Duration(seconds: 12),
  bool ask = true,
}) async {
  final GeoSource source = geoSource;
  try {
    if (!await source.serviceEnabled()) {
      return await _last(source);
    }
    LocationPermission permission = await source.checkPermission();
    if (permission == LocationPermission.denied && ask) {
      permission = await source.requestPermission();
    }
    if (!_allowed(permission)) {
      return null;
    }
    return await source.current(timeout);
  } on Object catch (error) {
    logZenWarning('Położenie: $error');
    return _last(source);
  }
}

/// A fresh position for an alarm raised while Zen is not on screen (the
/// power-button shortcut, handled by the background service). Never asks
/// for permission (nobody is looking at the screen): without the
/// permission there is no position at all; with it the position is read
/// under a `location` foreground service (Android), and when that fails
/// the last known one is the fallback.
Future<GeoFix?> currentFixInBackground({
  Duration timeout = const Duration(seconds: 15),
}) async {
  final GeoSource source = geoSource;
  try {
    if (!_allowed(await source.checkPermission())) {
      return null;
    }
    if (!await source.serviceEnabled()) {
      return await _last(source);
    }
    return await source.currentUnderService(timeout);
  } on Object catch (error) {
    logZenWarning('Położenie w tle: $error');
    return _last(source);
  }
}

Future<GeoFix?> _last(GeoSource source) async {
  try {
    return await source.lastKnown();
  } on Object {
    return null;
  }
}
