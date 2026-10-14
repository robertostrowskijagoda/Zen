import 'package:flutter/foundation.dart';

/// A screen or a single window/app that can be shared in a call (§13.1).
@immutable
final class ScreenShareSource {
  const ScreenShareSource({
    required this.id,
    required this.name,
    required this.isWindow,
    this.thumbnail,
  });

  final String id;
  final String name;

  /// One window (or app) rather than the whole screen.
  final bool isWindow;
  final Uint8List? thumbnail;
}

/// Message telling the other side that screen sharing started or stopped:
/// `{type, callId, on}`. Everyone in the call sees who shares.
const String kCallScreenSignal = 'call_screen';

/// Group calls: `{type, callId, on}` to every participant.
const String kGroupScreenSignal = 'gc_screen';

/// Message telling the other side that recording started or stopped:
/// `{type, callId, on}`. Recording is never silent (§13.2).
const String kCallRecordingSignal = 'call_rec';

/// Group calls: `{type, callId, on}` to every participant (also to whoever
/// joins while it runs).
const String kGroupRecordingSignal = 'gc_rec';

/// Android: true while the screen is captured. The foreground service then
/// needs the `mediaProjection` type (Android 14+ refuses capture otherwise).
final ValueNotifier<bool> androidScreenCaptureActive = ValueNotifier<bool>(
  false,
);

/// Set by the Android background bridge: (re)starts the foreground service
/// with the `mediaProjection` type before capture begins.
Future<void> Function()? androidPrepareScreenCapture;
