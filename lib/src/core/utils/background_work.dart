import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

/// Payloads above this many bytes are worth a short-lived isolate: below it,
/// spawning one (and copying the data in) costs more than the work itself.
const int kBackgroundWorkThresholdBytes = 64 * 1024;

bool? _offloadOverride;

/// Whether big work may leave the calling isolate. Off under `flutter test`
/// (`FLUTTER_TEST`): a real isolate never finishes inside the fake-async
/// zone of `testWidgets`, so widget tests would hang. Tests of the offloaded
/// path switch it on with [debugSetBackgroundWorkEnabled].
bool get backgroundWorkEnabled {
  final bool? override = _offloadOverride;
  if (override != null) {
    return override;
  }
  if (kIsWeb) {
    return false;
  }
  return !Platform.environment.containsKey('FLUTTER_TEST');
}

/// Forces [backgroundWorkEnabled] on or off; `null` restores the default.
@visibleForTesting
void debugSetBackgroundWorkEnabled(bool? enabled) {
  _offloadOverride = enabled;
}

/// Runs [work] in a short-lived isolate when [sizeBytes] is above
/// [threshold] (and [backgroundWorkEnabled]), otherwise right here. The
/// result is the same either way, so callers do not care which one ran:
/// big payloads simply stop blocking the UI thread.
///
/// [work] must only capture sendable values (bytes, strings, numbers).
Future<R> runSizedWork<R>(
  int sizeBytes,
  FutureOr<R> Function() work, {
  int threshold = kBackgroundWorkThresholdBytes,
}) async {
  if (sizeBytes <= threshold || !backgroundWorkEnabled) {
    return work();
  }
  return Isolate.run<R>(work);
}
