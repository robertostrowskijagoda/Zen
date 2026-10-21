import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// True while this device shares its screen in a call. Notification
/// posting reads it as "notifications without content" so nothing private
/// pops up on the shared picture.
final ValueNotifier<bool> screenShareHidesNotifications = ValueNotifier<bool>(
  false,
);

/// Android major version below which the system cannot share "one app" only
/// (Android 14 = API 34).
const int kAndroidSingleAppShareApi = 34;

/// Whether starting a share must first warn that the WHOLE screen goes out:
/// Android before 14 has no "share one app" choice.
bool screenShareNeedsWholeScreenWarning({
  required bool isAndroid,
  required int? androidSdkInt,
}) =>
    isAndroid &&
    androidSdkInt != null &&
    androidSdkInt < kAndroidSingleAppShareApi;

/// Plays the tone announcing that a recording started. Replaceable
/// in tests.
Future<void> Function() callRecordingTonePlayer = _playRecordingTone;

/// Two short beeps as a 16-bit mono PCM WAV file.
Uint8List buildRecordingToneWav({
  int sampleRate = 22050,
  double frequency = 880,
  int beepMs = 180,
  int gapMs = 120,
  int beeps = 2,
}) {
  final int beepSamples = sampleRate * beepMs ~/ 1000;
  final int gapSamples = sampleRate * gapMs ~/ 1000;
  final int total = beeps * beepSamples + (beeps - 1) * gapSamples;
  final ByteData data = ByteData(44 + total * 2);
  void ascii(int offset, String text) {
    for (int i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + total * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, total * 2, Endian.little);
  int index = 0;
  for (int b = 0; b < beeps; b++) {
    for (int i = 0; i < beepSamples; i++) {
      // Short fade in/out so the beep does not click.
      final double edge = math.min(1.0, math.min(i, beepSamples - i) / 200);
      final double v =
          math.sin(2 * math.pi * frequency * i / sampleRate) * 0.6 * edge;
      data.setInt16(44 + index * 2, (v * 32767).round(), Endian.little);
      index++;
    }
    if (b < beeps - 1) {
      index += gapSamples;
    }
  }
  return data.buffer.asUint8List();
}

Future<void> _playRecordingTone() async {
  try {
    unawaited(SystemSound.play(SystemSoundType.alert));
    unawaited(HapticFeedback.heavyImpact());
    final File file = await writeTemporaryMedia(
      buildRecordingToneWav(),
      extension: '.wav',
    );
    final VideoPlayerController player = VideoPlayerController.file(file);
    try {
      await player.initialize();
      await player.play();
      await Future<void>.delayed(
        player.value.duration + const Duration(milliseconds: 200),
      );
    } finally {
      await player.dispose();
      if (file.existsSync()) {
        await file.delete();
      }
    }
  } catch (error) {
    logZenWarning('Playing the recording tone failed: $error');
  }
}

/// Fire-and-forget wrapper used by the call sessions.
void announceRecordingStartedWithTone() {
  unawaited(callRecordingTonePlayer());
}
