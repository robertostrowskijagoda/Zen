import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:record/record.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';

typedef VoiceMessageRecorderFactory = VoiceMessageRecorder Function();

/// Voice messages of the chat: recorded into the temporary media folder,
/// then encrypted into the [MediaVault].
final Provider<VoiceMessageRecorderFactory>
voiceMessageRecorderFactoryProvider = Provider<VoiceMessageRecorderFactory>((
  Ref ref,
) {
  final MediaVault vault = ref.watch(mediaVaultProvider);
  return () => PlatformVoiceMessageRecorder(vault: vault);
});

final class RecordedVoiceClip {
  const RecordedVoiceClip({
    required this.path,
    required this.durationMs,
    this.fileName = 'voice.m4a',
    this.mimeType = 'audio/mp4',
  });

  /// Where the recording is: a vault file, or (without a vault) the plain
  /// temporary file, which the caller deletes.
  final String path;
  final int durationMs;
  final String fileName;
  final String mimeType;
}

abstract interface class VoiceMessageRecorder {
  Future<bool> start();

  Future<RecordedVoiceClip?> stop();

  Future<void> cancel();
}

final class PlatformVoiceMessageRecorder implements VoiceMessageRecorder {
  /// With a [vault] the finished recording is encrypted into it and the
  /// plain file is deleted; without one [stop] gives the plain temporary
  /// file.
  PlatformVoiceMessageRecorder({
    MediaVault? vault,
    Future<Directory> Function()? temporaryDirectory,
    AudioRecorder? recorder,
    DateTime Function()? now,
  }) : _vault = vault,
       _temporaryDirectory = temporaryDirectory ?? mediaTemporaryDirectory,
       _recorder = recorder ?? AudioRecorder(),
       _now = now ?? DateTime.now;

  final MediaVault? _vault;
  final Future<Directory> Function() _temporaryDirectory;
  final AudioRecorder _recorder;
  final DateTime Function() _now;

  String? _recordingPath;
  DateTime? _recordingStartedAt;
  bool _started = false;

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) {
      await _disposeRecorder();
      return false;
    }
    final Directory folder = await _temporaryDirectory();
    // A random name: the temporary folder says nothing about the chat.
    final String filePath =
        '${folder.path}${Platform.pathSeparator}'
        '${securityHexFromBytes(randomSecurityBytes(12))}.m4a';
    _recordingPath = filePath;
    _recordingStartedAt = _now();
    await _recorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000),
      path: filePath,
    );
    _started = true;
    return true;
  }

  @override
  Future<RecordedVoiceClip?> stop() async {
    final String? fallbackPath = _recordingPath;
    try {
      final String? path = _started ? await _recorder.stop() : fallbackPath;
      final int durationMs = _recordingStartedAt == null
          ? 0
          : _now().difference(_recordingStartedAt!).inMilliseconds;
      if (path == null) {
        return null;
      }
      final File file = File(path);
      if (!await file.exists()) {
        return null;
      }
      final MediaVault? vault = _vault;
      if (vault == null) {
        return RecordedVoiceClip(path: path, durationMs: durationMs);
      }
      try {
        final String sealed = await vault.putFile(file);
        return RecordedVoiceClip(path: sealed, durationMs: durationMs);
      } catch (_) {
        // Never left behind in plain form.
        await _deleteQuietly(file);
        rethrow;
      }
    } finally {
      await _disposeRecorder();
    }
  }

  @override
  Future<void> cancel() async {
    final String? fallbackPath = _recordingPath;
    try {
      if (_started) {
        await _recorder.stop();
      }
    } finally {
      await _disposeRecorder();
    }
    if (fallbackPath == null) {
      return;
    }
    await _deleteQuietly(File(fallbackPath));
  }

  Future<void> _disposeRecorder() async {
    _started = false;
    _recordingStartedAt = null;
    _recordingPath = null;
    await _recorder.dispose();
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } on FileSystemException {
      // Removed with the temporary media folder at the next start.
    }
  }
}
