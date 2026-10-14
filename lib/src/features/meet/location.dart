import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
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

/// Where the phone is now, asking for permission when needed. `null` when
/// location is off, refused or unavailable — the alarm then goes without
/// it. Used only while an alarm runs.
Future<GeoFix?> currentFix({
  Duration timeout = const Duration(seconds: 12),
}) async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return await _last();
    }
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      return null;
    }
    final Position p = await Geolocator.getCurrentPosition(
      locationSettings: LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: timeout,
      ),
    );
    return GeoFix(p.latitude, p.longitude, p.accuracy);
  } on Object catch (error) {
    logZenWarning('Położenie: $error');
    return _last();
  }
}

Future<GeoFix?> _last() async {
  try {
    final Position? p = await Geolocator.getLastKnownPosition();
    return p == null ? null : GeoFix(p.latitude, p.longitude, p.accuracy);
  } on Object {
    return null;
  }
}
