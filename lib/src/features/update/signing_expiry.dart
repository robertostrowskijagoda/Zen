import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// How long before the signature runs out the app starts to warn.
const Duration kSigningWarnBefore = Duration(days: 2);

const MethodChannel _integrity = MethodChannel('zen/integrity');

/// When the signature of this iPhone build runs out (a sideloaded build:
/// the provisioning profile's `ExpirationDate`, about 7 days with a free
/// Apple ID). `null` elsewhere, for a store build, or when it cannot be
/// read.
Future<DateTime?> readSigningExpiry() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS) {
    return null;
  }
  try {
    final int? millis = await _integrity.invokeMethod<int>('signingExpiry');
    return millis == null || millis <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis);
  } on Object catch (error) {
    logZenWarning('The signing expiry could not be read: $error');
    return null;
  }
}

/// The expiry of this build's signature (see [readSigningExpiry]).
final FutureProvider<DateTime?> signingExpiryProvider =
    FutureProvider<DateTime?>((Ref ref) => readSigningExpiry());

/// Whole days left until [expiry] (rounded up, at least 0), or `null` when
/// no warning is due yet at [now] (more than [kSigningWarnBefore] left).
int? signingDaysLeftToWarn(DateTime expiry, DateTime now) {
  final Duration left = expiry.difference(now);
  if (left > kSigningWarnBefore) {
    return null;
  }
  if (left <= Duration.zero) {
    return 0;
  }
  return (left.inMinutes / Duration.minutesPerDay).ceil();
}

/// The id in `AppSettings.seenTips` of a dismissed warning for [expiry]: a
/// refreshed build has a new expiry, so the next warning shows again.
String signingTipId(DateTime expiry) =>
    'signing-${expiry.millisecondsSinceEpoch}';
