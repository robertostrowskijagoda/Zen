import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// What the person allows Zen to know about where the device is.
enum LocationPermission {
  /// Not allowed (yet); asking may still show the system question.
  denied,

  /// Refused for good: only the system settings can change it.
  deniedForever,

  /// While Zen is open.
  whileInUse,

  /// Also with Zen closed (the alarm from the lock screen).
  always,

  /// This system has no location service Zen can use.
  unableToDetermine,
}

/// A place on Earth, for the alarm.
@immutable
final class GeoFix {
  const GeoFix(this.lat, this.lon, this.accuracy, {this.at});

  final double lat;
  final double lon;

  /// Metres.
  final double accuracy;

  /// When it was measured; `null` when the system does not say.
  final DateTime? at;
}

/// Where positions come from (the device's location service); tests give
/// their own.
abstract interface class GeoSource {
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<bool> serviceEnabled();

  /// One fresh, accurate position (foreground).
  Future<GeoFix> current(Duration timeout);

  /// One fresh position asked for under a notification of its own: on
  /// Android, without the background permission, that runs a foreground
  /// service of the `location` type, which is what lets a background
  /// service (the alarm shortcut with Zen closed) read the position at all.
  Future<GeoFix> currentUnderService(Duration timeout);

  Future<GeoFix?> lastKnown();
}

/// The system's own location service over `zen/location`: Android's
/// LocationManager (ZenLocationBridge.kt, no Google Play services), Core
/// Location on iOS and macOS (ZenLocationBridge.swift) and
/// Windows.Devices.Geolocation (location_bridge.cpp).
final class ChannelGeoSource implements GeoSource {
  const ChannelGeoSource({
    MethodChannel channel = const MethodChannel('zen/location'),
  }) : _channel = channel;

  final MethodChannel _channel;

  /// Extra wait over the platform's own time limit before giving up here.
  static const Duration _grace = Duration(seconds: 3);

  static LocationPermission _permission(Object? raw) =>
      LocationPermission.values.asNameMap()[raw] ??
      LocationPermission.unableToDetermine;

  /// A position from the platform, `null` when it is not a usable one.
  static GeoFix? _fixOf(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Object? lat = raw['lat'];
    final Object? lon = raw['lon'];
    final Object? accuracy = raw['accuracy'];
    final Object? at = raw['at'];
    if (lat is! num ||
        lon is! num ||
        !lat.isFinite ||
        !lon.isFinite ||
        lat.abs() > 90 ||
        lon.abs() > 180) {
      return null;
    }
    return GeoFix(
      lat.toDouble(),
      lon.toDouble(),
      accuracy is num && accuracy.isFinite && accuracy >= 0
          ? accuracy.toDouble()
          : 0.0,
      at: at is int && at > 0 ? DateTime.fromMillisecondsSinceEpoch(at) : null,
    );
  }

  @override
  Future<LocationPermission> checkPermission() async =>
      _permission(await _channel.invokeMethod<Object?>('check'));

  @override
  Future<LocationPermission> requestPermission() async =>
      _permission(await _channel.invokeMethod<Object?>('request'));

  @override
  Future<bool> serviceEnabled() async =>
      await _channel.invokeMethod<bool>('serviceEnabled') ?? false;

  @override
  Future<GeoFix> current(Duration timeout) =>
      _read(timeout, <String, Object?>{});

  @override
  Future<GeoFix> currentUnderService(Duration timeout) =>
      _read(timeout, <String, Object?>{
        'background': true,
        'title': 'Zen',
        'text': t('Ustalam położenie dla alarmu'),
        'channel': t('Położenie alarmu'),
      });

  Future<GeoFix> _read(Duration timeout, Map<String, Object?> extra) async {
    final Object? raw = await _channel
        .invokeMethod<Object?>('current', <String, Object?>{
          'timeoutMs': timeout.inMilliseconds,
          ...extra,
        })
        .timeout(timeout + _grace);
    final GeoFix? fix = _fixOf(raw);
    if (fix == null) {
      throw StateError('no position');
    }
    return fix;
  }

  @override
  Future<GeoFix?> lastKnown() async =>
      _fixOf(await _channel.invokeMethod<Object?>('lastKnown'));
}

/// A system without a location service Zen uses: Linux (GeoClue gives no
/// permission answer, so an alarm there goes without a place) and the web.
final class _NoGeoSource implements GeoSource {
  const _NoGeoSource();

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.unableToDetermine;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.unableToDetermine;

  @override
  Future<bool> serviceEnabled() async => false;

  @override
  Future<GeoFix> current(Duration timeout) =>
      Future<GeoFix>.error(UnsupportedError('no location service'));

  @override
  Future<GeoFix> currentUnderService(Duration timeout) => current(timeout);

  @override
  Future<GeoFix?> lastKnown() async => null;
}

GeoSource _platformSource() {
  if (kIsWeb) {
    return const _NoGeoSource();
  }
  return switch (defaultTargetPlatform) {
    TargetPlatform.android ||
    TargetPlatform.iOS ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => const ChannelGeoSource(),
    TargetPlatform.linux || TargetPlatform.fuchsia => const _NoGeoSource(),
  };
}

/// The source the app uses; replaced in tests.
@visibleForTesting
GeoSource geoSource = _platformSource();

bool _allowed(LocationPermission p) =>
    p == LocationPermission.whileInUse || p == LocationPermission.always;

/// What the person allows now (never asks).
Future<LocationPermission> checkLocationPermission() =>
    geoSource.checkPermission();

/// Shows the system question when it may still be asked; what the person
/// allows afterwards.
Future<LocationPermission> requestLocationPermission() =>
    geoSource.requestPermission();

/// The last position the system still keeps (the GPS is not switched on),
/// only with the permission already given; `null` otherwise.
Future<GeoFix?> lastKnownFix() async {
  final GeoSource source = geoSource;
  try {
    if (!_allowed(await source.checkPermission())) {
      return null;
    }
  } on Object catch (error) {
    logZenWarning('Położenie: $error');
    return null;
  }
  return _last(source);
}

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
