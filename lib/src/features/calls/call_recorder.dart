import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// What records calls on this device (§13.2), for 1:1 and group calls:
/// - Android: flutter_webrtc's recorder — what you hear, plus the other
///   side's video in a 1:1 video call (`.mp4`);
/// - Windows: only what this app plays (the other side, through WASAPI
///   process loopback — never other apps or system sounds) mixed with the
///   microphone, in the app's runner (`.wav`);
/// - elsewhere: not yet.
///
/// Recording is always announced to everyone in the call first; this only
/// writes the file.
abstract class CallRecorder {
  bool get available;

  /// File type of the recording, for its name when exported.
  String get extension;
  String get mime;

  /// Starts writing [path]. [video] (Android, 1:1) goes into the file too.
  Future<void> start(String path, {MediaStreamTrack? video});

  Future<void> stop();

  bool get isRecording;
}

/// The recorder for this platform.
CallRecorder platformCallRecorder() {
  if (kIsWeb) {
    return const UnavailableCallRecorder();
  }
  if (Platform.isAndroid) {
    return AndroidCallRecorder();
  }
  if (Platform.isWindows) {
    return WindowsCallRecorder();
  }
  return const UnavailableCallRecorder();
}

final class UnavailableCallRecorder implements CallRecorder {
  const UnavailableCallRecorder();

  @override
  bool get available => false;

  @override
  String get extension => 'mp4';

  @override
  String get mime => 'video/mp4';

  @override
  bool get isRecording => false;

  @override
  Future<void> start(String path, {MediaStreamTrack? video}) =>
      throw UnsupportedError(
        'Nagrywanie rozmów nie jest jeszcze dostępne na tym urządzeniu.',
      );

  @override
  Future<void> stop() async {}
}

final class AndroidCallRecorder implements CallRecorder {
  MediaRecorder? _recorder;

  @override
  bool get available => true;

  @override
  String get extension => 'mp4';

  @override
  String get mime => 'video/mp4';

  @override
  bool get isRecording => _recorder != null;

  @override
  Future<void> start(String path, {MediaStreamTrack? video}) async {
    if (_recorder != null) {
      return;
    }
    final MediaRecorder recorder = MediaRecorder();
    await recorder.start(
      path,
      videoTrack: video,
      audioChannel: RecorderAudioChannel.OUTPUT,
    );
    _recorder = recorder;
  }

  @override
  Future<void> stop() async {
    final MediaRecorder? recorder = _recorder;
    _recorder = null;
    await recorder?.stop();
  }
}

/// The runner's WASAPI recorder (windows/runner/call_recorder.cpp).
final class WindowsCallRecorder implements CallRecorder {
  WindowsCallRecorder({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('zen/recorder');

  final MethodChannel _channel;
  bool _recording = false;

  @override
  bool get available => true;

  @override
  String get extension => 'wav';

  @override
  String get mime => 'audio/wav';

  @override
  bool get isRecording => _recording;

  @override
  Future<void> start(String path, {MediaStreamTrack? video}) async {
    if (_recording) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('start', <String, Object>{
        'path': path,
      });
    } on PlatformException catch (e) {
      throw StateError('Nie udało się zacząć nagrywania: ${e.message}');
    } on MissingPluginException {
      throw UnsupportedError(
        'Ta wersja aplikacji nie umie nagrywać — zaktualizuj ją.',
      );
    }
    _recording = true;
  }

  @override
  Future<void> stop() async {
    if (!_recording) {
      return;
    }
    _recording = false;
    await _channel.invokeMethod<String>('stop');
  }
}
