import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Making a film small enough to travel between friends: the phone's own
// hardware encoder (Android MediaCodec, Apple AVFoundation, Windows Media
// Foundation) turns it into H.264 / AAC in an MP4, at most 720p and about
// 2.5 Mb/s, cut to the chosen start and end. The native side
// (ZenVideoBridge.kt, ZenVideoBridge.swift, video_bridge.cpp) answers on the
// channel `zen/video`:
//
//  - `isAvailable`: whether this device can compress at all;
//  - `compress` {input, output, startMs, endMs, maxShortSide, videoBitrate,
//    audioBitrate}: writes `output` and answers {durationMs, width, height,
//    bytes}; while it works it calls `progress` {fraction} back;
//  - `cancel`: stops the running compression (it then fails "cancelled");
//  - `thumbnail` {input, atMs, maxSide}: one frame as JPEG bytes, or null.
//
// Where there is no encoder (Linux), films go as they are, within the
// limits ([VideoCompressor.available] is false).

/// The short side of a compressed film's picture (720p).
const int kVideoTargetShortSide = 720;

/// The bit rate of a compressed film's picture when its length allows it.
const int kVideoTargetBitrate = 2500000;

/// The bit rate of its sound.
const int kVideoAudioBitrate = 128000;

/// The lowest picture bit rate worth sending (below it the size limit
/// cannot be met at this length).
const int kVideoMinBitrate = 400000;

/// A compressed film's size limit: what a friend's mailbox holds for one
/// sender, so a short film can wait there while its author is offline.
const int kCompressedVideoMaxBytes = 20 * 1024 * 1024;

/// Share of the size limit the picture and sound may take (the rest is the
/// MP4 index and the encoder's overshoot).
const double _payloadShare = 0.95;

/// How a film is compressed: picture size limit and bit rates.
@immutable
final class VideoCompressionPlan {
  const VideoCompressionPlan({
    required this.maxShortSide,
    required this.videoBitrate,
    required this.audioBitrate,
  });

  final int maxShortSide;
  final int videoBitrate;
  final int audioBitrate;

  /// About how many bytes a film of [durationMs] comes out at.
  int estimatedBytes(int durationMs) =>
      ((videoBitrate + audioBitrate) * durationMs / 8000).ceil();
}

/// The plan for a film of [durationMs] (after trimming): 720p at 2.5 Mb/s
/// while that fits in [maxBytes], a lower bit rate for a longer film.
/// Throws [ArgumentError] when even [kVideoMinBitrate] would not fit.
VideoCompressionPlan planVideoCompression({
  required int durationMs,
  int maxBytes = kCompressedVideoMaxBytes,
}) {
  if (durationMs <= 0) {
    throw ArgumentError.value(durationMs, 'durationMs');
  }
  final double budgetBits = maxBytes * 8 * _payloadShare;
  final int perSecond = (budgetBits * 1000 / durationMs).floor();
  final int video = math.min(
    kVideoTargetBitrate,
    perSecond - kVideoAudioBitrate,
  );
  if (video < kVideoMinBitrate) {
    throw ArgumentError.value(durationMs, 'durationMs', 'too long');
  }
  return VideoCompressionPlan(
    maxShortSide: kVideoTargetShortSide,
    videoBitrate: video,
    audioBitrate: kVideoAudioBitrate,
  );
}

/// The picture size a [width] × [height] film is compressed to: the short
/// side at most [maxShortSide] (never enlarged), the proportions kept and
/// both sides even (what encoders take). The native bridges work it out
/// the same way.
({int width, int height}) scaledVideoSize(
  int width,
  int height, {
  int maxShortSide = kVideoTargetShortSide,
}) {
  if (width <= 0 || height <= 0) {
    return (width: 0, height: 0);
  }
  final int short = math.min(width, height);
  if (short <= maxShortSide) {
    return (width: width & ~1, height: height & ~1);
  }
  final double scale = maxShortSide / short;
  int even(double v) => math.max(2, v.round() & ~1);
  return (width: even(width * scale), height: even(height * scale));
}

/// A compressed film on disk.
@immutable
final class CompressedVideo {
  const CompressedVideo({
    required this.path,
    required this.durationMs,
    required this.bytes,
    this.width = 0,
    this.height = 0,
  });

  final String path;
  final int durationMs;
  final int bytes;
  final int width;
  final int height;
}

/// Why a compression did not finish.
final class VideoCompressionException implements Exception {
  const VideoCompressionException(this.code, [this.message = '']);

  /// `unsupported`, `cancelled` or `failed`.
  final String code;
  final String message;

  bool get cancelled => code == 'cancelled';

  @override
  String toString() => message.isEmpty ? code : '$code: $message';
}

/// The phone's video encoder (see the top of this file).
abstract interface class VideoCompressor {
  /// Whether films can be compressed (and trimmed) on this device.
  Future<bool> available();

  /// Writes [input] from [startMs] to [endMs] (`null`: to its end) as a
  /// compressed MP4 at [output], following [plan]. [onProgress] gets 0..1.
  Future<CompressedVideo> compress({
    required String input,
    required String output,
    required VideoCompressionPlan plan,
    int startMs = 0,
    int? endMs,
    void Function(double fraction)? onProgress,
  });

  /// Stops a running [compress].
  Future<void> cancel();

  /// One frame of [input] at [atMs] as JPEG, its long side at most
  /// [maxSide]; `null` where that is not possible.
  Future<Uint8List?> thumbnail(String input, {int atMs = 0, int maxSide = 480});
}

/// [VideoCompressor] over the `zen/video` channel.
final class PlatformVideoCompressor implements VideoCompressor {
  PlatformVideoCompressor({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('zen/video') {
    _channel.setMethodCallHandler(_onCall);
  }

  /// The one the app uses.
  static final PlatformVideoCompressor instance = PlatformVideoCompressor();

  final MethodChannel _channel;
  void Function(double fraction)? _progress;
  bool? _available;

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'progress') {
      final Object? args = call.arguments;
      final Object? f = args is Map ? args['fraction'] : null;
      if (f is num) {
        _progress?.call(f.toDouble().clamp(0.0, 1.0).toDouble());
      }
    }
    return null;
  }

  @override
  Future<bool> available() async {
    if (_available != null) {
      return _available!;
    }
    if (kIsWeb || Platform.isLinux) {
      return _available = false;
    }
    try {
      return _available =
          await _channel.invokeMethod<bool>('isAvailable') ?? false;
    } on MissingPluginException {
      return _available = false;
    } on PlatformException {
      return _available = false;
    }
  }

  @override
  Future<CompressedVideo> compress({
    required String input,
    required String output,
    required VideoCompressionPlan plan,
    int startMs = 0,
    int? endMs,
    void Function(double fraction)? onProgress,
  }) async {
    if (!await available()) {
      throw const VideoCompressionException('unsupported');
    }
    _progress = onProgress;
    try {
      final Map<Object?, Object?>? out = await _channel
          .invokeMapMethod<Object?, Object?>('compress', <String, Object?>{
            'input': input,
            'output': output,
            'startMs': math.max(0, startMs),
            'endMs': endMs ?? -1,
            'maxShortSide': plan.maxShortSide,
            'videoBitrate': plan.videoBitrate,
            'audioBitrate': plan.audioBitrate,
          });
      if (out == null) {
        throw const VideoCompressionException('failed');
      }
      final File file = File(output);
      return CompressedVideo(
        path: output,
        durationMs: (out['durationMs'] as num?)?.toInt() ?? 0,
        bytes: (out['bytes'] as num?)?.toInt() ?? await file.length(),
        width: (out['width'] as num?)?.toInt() ?? 0,
        height: (out['height'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (e) {
      throw VideoCompressionException(e.code, e.message ?? '');
    } on MissingPluginException {
      throw const VideoCompressionException('unsupported');
    } finally {
      _progress = null;
    }
  }

  @override
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } on MissingPluginException {
      // Nothing runs.
    } on PlatformException {
      // Nothing runs.
    }
  }

  @override
  Future<Uint8List?> thumbnail(
    String input, {
    int atMs = 0,
    int maxSide = 480,
  }) async {
    if (!await available()) {
      return null;
    }
    try {
      return await _channel.invokeMethod<Uint8List>(
        'thumbnail',
        <String, Object?>{'input': input, 'atMs': atMs, 'maxSide': maxSide},
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
