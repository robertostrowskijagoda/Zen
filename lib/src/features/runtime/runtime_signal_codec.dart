import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/features/runtime/zstd_frame_guard.dart';
import 'package:zstandard/zstandard.dart';

const String kRuntimeSignalEncodingKey = '_zenEncoding';
const String kRuntimeSignalPayloadKey = '_zenPayload';
const int kRuntimeSignalCompressionThresholdBytes = 8 * 1024;
const int kRuntimeSignalMaxBytes = 2 * 1024 * 1024;
const int kRuntimeSignalCompressionLevel = 3;

abstract interface class SignalPayloadCompressor {
  Future<Uint8List?> compress(Uint8List input, int level);

  Future<Uint8List?> decompress(Uint8List input);
}

final class ZstdSignalPayloadCompressor implements SignalPayloadCompressor {
  ZstdSignalPayloadCompressor([Zstandard? zstandard])
    : _zstandard = zstandard ?? Zstandard();

  final Zstandard _zstandard;

  @override
  Future<Uint8List?> compress(Uint8List input, int level) {
    return _zstandard.compress(input, level);
  }

  @override
  Future<Uint8List?> decompress(Uint8List input) {
    return _zstandard.decompress(input);
  }
}

bool shouldCompressRuntimeSignalPayload(Map<String, dynamic> payload) {
  return !payload.containsKey('attachmentData') &&
      !payload.containsKey('chunkData') &&
      !payload.containsKey(kRuntimeSignalEncodingKey) &&
      !payload.containsKey(kRuntimeSignalPayloadKey);
}

Future<String> encodeRuntimeSignalPayload(
  Map<String, dynamic> payload,
  SignalPayloadCompressor compressor,
) async {
  final String rawJson = jsonEncode(payload);
  final Uint8List rawBytes = Uint8List.fromList(utf8.encode(rawJson));
  if (rawBytes.length > kRuntimeSignalMaxBytes) {
    throw const FormatException('Signal payload exceeds 2MB limit.');
  }
  if (!shouldCompressRuntimeSignalPayload(payload) ||
      rawBytes.length < kRuntimeSignalCompressionThresholdBytes) {
    return rawJson;
  }

  final Uint8List? compressed = await compressor.compress(
    rawBytes,
    kRuntimeSignalCompressionLevel,
  );
  if (compressed != null &&
      compressed.isNotEmpty &&
      compressed.length + 64 < rawBytes.length) {
    return jsonEncode(<String, dynamic>{
      kRuntimeSignalEncodingKey: 'zstd',
      kRuntimeSignalPayloadKey: base64Encode(compressed),
    });
  }
  return rawJson;
}

Future<Map<String, dynamic>?> decodeRuntimeSignalPayload(
  String rawPayload,
  SignalPayloadCompressor compressor,
) async {
  final Object? parsed = jsonDecode(rawPayload);
  if (parsed is! Map<String, dynamic>) {
    return null;
  }
  final String? encoding = parsed[kRuntimeSignalEncodingKey] as String?;
  if (encoding == null || encoding.isEmpty) {
    return parsed;
  }
  final String encodedPayload =
      parsed[kRuntimeSignalPayloadKey] as String? ?? '';
  if (encodedPayload.isEmpty) {
    throw const FormatException('Missing compressed signal payload.');
  }
  if (encoding != 'zstd') {
    throw FormatException('Unsupported signal encoding: $encoding');
  }
  // Senders never compress more than [kRuntimeSignalMaxBytes] of JSON, so
  // anything claiming more is a decompression bomb, not a signal. (The Go
  // bridge compresses large signals itself and bounds its own decoder; this
  // Dart-level wrapper is still produced and accepted for older peers.)
  final Uint8List decodedBytes = await boundedZstdDecompress(
    Uint8List.fromList(base64Decode(encodedPayload)),
    maxBytes: kRuntimeSignalMaxBytes,
    decompress: compressor.decompress,
  );
  final Object? decoded = jsonDecode(utf8.decode(decodedBytes));
  return decoded is Map<String, dynamic> ? decoded : null;
}
