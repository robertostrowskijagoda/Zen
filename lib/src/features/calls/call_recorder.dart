import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';

/// What records calls on this device, for 1:1 and group calls:
/// - Android: flutter_webrtc's recorder — what you hear, plus the other
///   side's video in a 1:1 video call (`.mp4`);
/// - iPhone, iPad and Mac: the runner (ios/Runner/ZenCallRecorder.swift,
///   shared by both apps) taps flutter_webrtc's own audio processing: what
///   the call plays (everyone else, already mixed) and the microphone, as
///   AAC (`.m4a`); other sounds of the device are never in it;
/// - Windows: only what this app plays (the other side, through WASAPI
///   process loopback — never other apps or system sounds) mixed with the
///   microphone, in the app's runner (`.wav`);
/// - Linux: the same through PulseAudio (also PipeWire's): only this app's
///   own playback streams, followed as they come and go, mixed with the
///   default microphone (linux/runner/zen_call_recorder.cc, `.wav`); without
///   libpulse it is not available;
/// - elsewhere (the web): no.
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
  return callRecorderForPlatform(Platform.operatingSystem);
}

/// The recorder for [operatingSystem] (`Platform.operatingSystem`).
CallRecorder callRecorderForPlatform(
  String operatingSystem, {
  MethodChannel? channel,
}) {
  switch (operatingSystem) {
    case 'android':
      return AndroidCallRecorder();
    case 'ios':
    case 'macos':
      return RunnerCallRecorder.aac(channel: channel);
    case 'windows':
    case 'linux':
      return RunnerCallRecorder.wav(channel: channel);
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
        t('Nagrywanie rozmów nie jest jeszcze dostępne na tym urządzeniu.'),
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

/// The recorder in the app's own runner (method channel `zen/recorder`):
/// Windows (windows/runner/call_recorder.cpp), Linux
/// (linux/runner/zen_call_recorder.cc), iPhone, iPad and Mac
/// (ios/Runner/ZenCallRecorder.swift). Sound only; [video] is ignored.
///
///  - `available` → bool: whether this device can record at all;
///  - `start` {path} → true, or the error `unavailable` (nothing to record
///    with here) or `start_failed` with the reason;
///  - `stop` → the path, or null when nothing ran.
final class RunnerCallRecorder implements CallRecorder {
  RunnerCallRecorder({
    required this.extension,
    required this.mime,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel(channelName);

  /// AAC in an MP4 file (iPhone, iPad, Mac).
  factory RunnerCallRecorder.aac({MethodChannel? channel}) =>
      RunnerCallRecorder(extension: 'm4a', mime: 'audio/mp4', channel: channel);

  /// Plain PCM in a WAV file (Windows, Linux).
  factory RunnerCallRecorder.wav({MethodChannel? channel}) =>
      RunnerCallRecorder(extension: 'wav', mime: 'audio/wav', channel: channel);

  static const String channelName = 'zen/recorder';

  @override
  final String extension;

  @override
  final String mime;

  final MethodChannel _channel;
  bool _recording = false;
  bool? _runnerAvailable;
  Future<bool>? _asking;

  /// The runner is asked once, the first time this is read; until it
  /// answers, recording is offered (a refusal then says why).
  @override
  bool get available {
    if (_asking == null) {
      unawaited(checkAvailable());
    }
    return _runnerAvailable ?? true;
  }

  /// Asks the runner (once) whether this device can record.
  Future<bool> checkAvailable() => _asking ??= _ask();

  Future<bool> _ask() async {
    try {
      _runnerAvailable =
          await _channel.invokeMethod<bool>('available') ?? false;
    } catch (_) {
      // No runner recorder (or no answer): nothing to record with.
      _runnerAvailable = false;
    }
    return _runnerAvailable ?? false;
  }

  void _markUnavailable() {
    _runnerAvailable = false;
    _asking ??= Future<bool>.value(false);
  }

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
      if (e.code == 'unavailable') {
        _markUnavailable();
        throw UnsupportedError(
          t('Nagrywanie rozmów nie jest jeszcze dostępne na tym urządzeniu.'),
        );
      }
      throw StateError(
        t('Nie udało się zacząć nagrywania: {error}', {'error': e.message}),
      );
    } on MissingPluginException {
      _markUnavailable();
      throw UnsupportedError(
        t('Ta wersja aplikacji nie umie nagrywać — zaktualizuj ją.'),
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
