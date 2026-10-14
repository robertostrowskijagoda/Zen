import 'dart:math' as math;
import 'dart:typed_data';

/// What a zstd input claims about its output, read from the frame headers
/// alone (RFC 8878), without decompressing anything.
final class ZstdOutputBounds {
  const ZstdOutputBounds({
    required this.declaredBytes,
    required this.worstCaseBytes,
    required this.frameCount,
  });

  /// Sum of every frame's Frame_Content_Size, or `null` when a frame does
  /// not declare one (encoders may leave it out; the block walk still bounds
  /// such a frame, see [worstCaseBytes]).
  final int? declaredBytes;

  /// Most the blocks could regenerate however the input is crafted: raw and
  /// RLE blocks count their own size, a compressed block its
  /// Block_Maximum_Size (window size, at most 128 KiB).
  final int worstCaseBytes;

  final int frameCount;
}

const int _zstdFrameMagic = 0xFD2FB528;
const int _zstdSkippableMagicMask = 0xFFFFFFF0;
const int _zstdSkippableMagic = 0x184D2A50;
const int _zstdBlockSizeMax = 128 * 1024;

/// Reads the frame and block headers of [input].
///
/// Returns `null` for anything that cannot be bounded up front: a malformed
/// or truncated frame, or a reserved block type.
ZstdOutputBounds? readZstdOutputBounds(Uint8List input) {
  final ByteData view = ByteData.sublistView(input);
  final int length = input.length;
  int offset = 0;
  int declared = 0;
  bool allDeclared = true;
  int worstCase = 0;
  int frames = 0;
  if (length == 0) {
    return null;
  }
  while (offset < length) {
    if (length - offset < 4) {
      return null;
    }
    final int magic = view.getUint32(offset, Endian.little);
    offset += 4;
    if ((magic & _zstdSkippableMagicMask) == _zstdSkippableMagic) {
      if (length - offset < 4) {
        return null;
      }
      final int skip = view.getUint32(offset, Endian.little);
      offset += 4;
      if (skip > length - offset) {
        return null;
      }
      offset += skip;
      continue;
    }
    if (magic != _zstdFrameMagic || offset >= length) {
      return null;
    }
    final int descriptor = input[offset];
    offset += 1;
    final int contentSizeFlag = descriptor >> 6;
    final bool singleSegment = (descriptor & 0x20) != 0;
    final bool reservedBit = (descriptor & 0x08) != 0;
    final bool hasChecksum = (descriptor & 0x04) != 0;
    final int dictionaryIdFlag = descriptor & 0x03;
    if (reservedBit) {
      return null;
    }
    int windowSize = 0;
    if (!singleSegment) {
      if (offset >= length) {
        return null;
      }
      final int windowDescriptor = input[offset];
      offset += 1;
      final int exponent = windowDescriptor >> 3;
      final int mantissa = windowDescriptor & 0x07;
      final int windowBase = 1 << (10 + exponent);
      windowSize = windowBase + (windowBase ~/ 8) * mantissa;
    }
    offset += const <int>[0, 1, 2, 4][dictionaryIdFlag];
    final int contentSizeBytes = switch (contentSizeFlag) {
      0 => singleSegment ? 1 : 0,
      1 => 2,
      2 => 4,
      _ => 8,
    };
    if (offset + contentSizeBytes > length) {
      return null;
    }
    // No size field: the frame does not say how big it is; only its blocks
    // bound it.
    final int? contentSize = switch (contentSizeBytes) {
      0 => null,
      1 => input[offset],
      2 => view.getUint16(offset, Endian.little) + 256,
      4 => view.getUint32(offset, Endian.little),
      _ => view.getUint64(offset, Endian.little),
    };
    offset += contentSizeBytes;
    if (contentSize != null && contentSize < 0) {
      // Top bit set in the 64-bit field: absurdly large.
      return null;
    }
    if (singleSegment) {
      // A single-segment frame always carries its size (see above).
      windowSize = contentSize ?? 0;
    }
    final int blockMaximum = math.min(windowSize, _zstdBlockSizeMax);
    bool lastBlock = false;
    while (!lastBlock) {
      if (offset + 3 > length) {
        return null;
      }
      final int header =
          input[offset] | (input[offset + 1] << 8) | (input[offset + 2] << 16);
      offset += 3;
      lastBlock = (header & 0x01) != 0;
      final int blockType = (header >> 1) & 0x03;
      final int blockSize = header >> 3;
      switch (blockType) {
        case 0: // Raw
          if (blockSize > length - offset) {
            return null;
          }
          offset += blockSize;
          worstCase += blockSize;
        case 1: // RLE: one byte, repeated blockSize times.
          if (offset + 1 > length) {
            return null;
          }
          offset += 1;
          worstCase += blockSize;
        case 2: // Compressed
          if (blockSize > length - offset) {
            return null;
          }
          offset += blockSize;
          worstCase += blockMaximum;
        default:
          return null;
      }
    }
    if (hasChecksum) {
      if (offset + 4 > length) {
        return null;
      }
      offset += 4;
    }
    if (contentSize == null) {
      allDeclared = false;
    } else {
      declared += contentSize;
    }
    frames += 1;
    if (declared < 0 || worstCase < 0) {
      return null;
    }
  }
  if (frames == 0) {
    return null;
  }
  return ZstdOutputBounds(
    declaredBytes: allDeclared ? declared : null,
    worstCaseBytes: worstCase,
    frameCount: frames,
  );
}

/// Decompresses [input] with [decompress] only once its headers prove the
/// output stays within [maxBytes], and checks the result again afterwards.
///
/// The zstd plugin cannot cap its output, so a few kilobytes from a peer
/// could otherwise expand to gigabytes (a decompression bomb). Throws a
/// [FormatException] for anything over the limit or unbounded.
Future<Uint8List> boundedZstdDecompress(
  Uint8List input, {
  required int maxBytes,
  required Future<Uint8List?> Function(Uint8List input) decompress,
}) async {
  final ZstdOutputBounds? bounds = readZstdOutputBounds(input);
  if (bounds == null) {
    throw const FormatException('Malformed compressed payload.');
  }
  final int? declared = bounds.declaredBytes;
  if (declared == null) {
    // Every encoder this app talks to writes the size (`ZSTD_compress`, and
    // a one-shot stream, always do); a frame without it can only be
    // crafted, and a decoder could size its buffer from it blindly.
    throw const FormatException(
      'Compressed payload does not declare its size.',
    );
  }
  // Real frames regenerate whole 128 KiB blocks except their last one, so
  // the worst case stays close to the declared size. The slack lets
  // compressors that cut smaller blocks through, while still capping what a
  // decoder that trusts the blocks over a lying size could be made to
  // produce.
  final int worstCaseLimit =
      maxBytes * 4 + bounds.frameCount * _zstdBlockSizeMax;
  if (declared > maxBytes || bounds.worstCaseBytes > worstCaseLimit) {
    throw const FormatException('Compressed payload is too large.');
  }
  final Uint8List? output = await decompress(input);
  if (output == null) {
    throw const FormatException('Could not decompress the payload.');
  }
  if (output.length > maxBytes) {
    throw const FormatException('Decompressed payload is too large.');
  }
  return output;
}
