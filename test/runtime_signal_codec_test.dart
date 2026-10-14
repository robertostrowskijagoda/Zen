import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/runtime/runtime_signal_codec.dart';

void main() {
  test('compresses large payloads with the shared Zen envelope', () async {
    final _RecordingSignalCompressor compressor = _RecordingSignalCompressor();
    final Map<String, dynamic> payload = <String, dynamic>{
      'type': 'message',
      'content': 'a' * 9000,
    };

    final String encoded = await encodeRuntimeSignalPayload(
      payload,
      compressor,
    );
    final Map<String, dynamic>? decoded = await decodeRuntimeSignalPayload(
      encoded,
      compressor,
    );

    expect(compressor.lastLevel, kRuntimeSignalCompressionLevel);
    expect(
      (jsonDecode(encoded) as Map<String, dynamic>)[kRuntimeSignalEncodingKey],
      'zstd',
    );
    expect(decoded, payload);
  });

  test('keeps small payloads as raw JSON', () async {
    final _RecordingSignalCompressor compressor = _RecordingSignalCompressor();
    final Map<String, dynamic> payload = const <String, dynamic>{
      'type': 'ping',
    };

    final String encoded = await encodeRuntimeSignalPayload(
      payload,
      compressor,
    );

    expect(encoded, jsonEncode(payload));
    expect(compressor.lastLevel, isNull);
  });

  test('refuses a compressed envelope that would expand past the signal '
      'limit, without decompressing it', () async {
    final _RecordingSignalCompressor compressor = _RecordingSignalCompressor();
    // A few bytes on the wire, declaring a gigabyte of "JSON".
    final String bomb = jsonEncode(<String, dynamic>{
      kRuntimeSignalEncodingKey: 'zstd',
      kRuntimeSignalPayloadKey: base64Encode(
        _frameHeader(declaredBytes: 1 << 30, rleBlockBytes: 64 * 1024),
      ),
    });

    await expectLater(
      decodeRuntimeSignalPayload(bomb, compressor),
      throwsFormatException,
    );
    expect(compressor.decompressCalls, 0);
  });

  test('refuses a compressed envelope that is not a zstd frame', () async {
    final _RecordingSignalCompressor compressor = _RecordingSignalCompressor();
    final String garbage = jsonEncode(<String, dynamic>{
      kRuntimeSignalEncodingKey: 'zstd',
      kRuntimeSignalPayloadKey: base64Encode(<int>[1, 2, 3, 4]),
    });

    await expectLater(
      decodeRuntimeSignalPayload(garbage, compressor),
      throwsFormatException,
    );
    expect(compressor.decompressCalls, 0);
  });
}

/// A zstd frame header declaring [declaredBytes] (single segment, 4-byte
/// size field) and one RLE block regenerating [rleBlockBytes] - what a real
/// compressor writes for a long run of one byte.
Uint8List _frameHeader({
  required int declaredBytes,
  required int rleBlockBytes,
}) {
  final int blockHeader = 1 | (1 << 1) | (rleBlockBytes << 3);
  return Uint8List.fromList(<int>[
    0x28, 0xB5, 0x2F, 0xFD, // magic
    0xA0, // 4-byte content size, single segment
    declaredBytes & 0xFF,
    (declaredBytes >> 8) & 0xFF,
    (declaredBytes >> 16) & 0xFF,
    (declaredBytes >> 24) & 0xFF,
    blockHeader & 0xFF,
    (blockHeader >> 8) & 0xFF,
    (blockHeader >> 16) & 0xFF,
    0x61,
  ]);
}

/// Pretends to compress: emits a well-formed frame that declares the input's
/// size (as any real zstd encoder does) and hands the input back on
/// decompression.
final class _RecordingSignalCompressor implements SignalPayloadCompressor {
  Uint8List? _lastInput;
  int? lastLevel;
  int decompressCalls = 0;

  @override
  Future<Uint8List?> compress(Uint8List input, int level) async {
    _lastInput = Uint8List.fromList(input);
    lastLevel = level;
    return _frameHeader(
      declaredBytes: input.length,
      rleBlockBytes: input.length < 128 * 1024 ? input.length : 128 * 1024,
    );
  }

  @override
  Future<Uint8List?> decompress(Uint8List input) async {
    decompressCalls += 1;
    return _lastInput;
  }
}
