import 'dart:typed_data';

import 'package:zen/src/features/media/media_guard.dart';

// GIFs picked from the gallery or the files, or inserted by the keyboard,
// stay animated GIFs: a photo is re-encoded as a fresh JPEG, which would
// flatten a GIF to its first frame. A GIF is rebuilt here block by block
// instead, keeping only what plays it (the pictures, their timing and the
// loop count) and dropping comments, XMP, colour profiles and anything
// after its end.

/// The largest GIF sent as an animated picture (in a chat, a post or the
/// gallery). A bigger one may still go to a chat as a plain file.
const int kMaxSentGifBytes = 8 * 1024 * 1024;

/// What a picked file turned out to be.
enum PickedGifStatus {
  /// Not a GIF at all: a photo (or anything else) goes its usual way.
  notGif,

  /// A GIF ready to send ([PickedGif.bytes], without metadata).
  ready,

  /// A whole GIF over the limits: [kMaxSentGifBytes], or the side, frame
  /// and pixel limits every phone checks before playing one
  /// ([isAcceptableGif]).
  tooLarge,

  /// Starts like a GIF, but its blocks do not add up (cut short, damaged).
  broken,
}

/// A picked GIF checked and stripped of metadata.
final class PickedGif {
  const PickedGif(this.status, [this.bytes]);

  final PickedGifStatus status;

  /// The GIF to send, when [status] is [PickedGifStatus.ready].
  final Uint8List? bytes;
}

/// Whether [bytes] start like a GIF (`GIF8`).
bool looksLikeGif(Uint8List bytes) =>
    bytes.length >= 6 &&
    bytes[0] == 0x47 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x38;

/// Checks a GIF someone picked to send (see [PickedGifStatus]).
PickedGif preparePickedGif(Uint8List bytes) {
  if (!looksLikeGif(bytes)) {
    return const PickedGif(PickedGifStatus.notGif);
  }
  if (bytes.length > kMaxSentGifBytes) {
    return const PickedGif(PickedGifStatus.tooLarge);
  }
  final Uint8List? clean = stripGifMetadata(bytes);
  if (clean == null) {
    return const PickedGif(PickedGifStatus.broken);
  }
  // The blocks add up (checked above): what is left are the limits the
  // recipient checks too, so a GIF that passes here plays there.
  if (!isAcceptableGif(clean)) {
    return const PickedGif(PickedGifStatus.tooLarge);
  }
  return PickedGif(PickedGifStatus.ready, clean);
}

/// The file name [name] with the `.gif` extension (`gif.gif` when empty).
String gifFileName(String name) {
  final String trimmed = name.trim();
  final int dot = trimmed.lastIndexOf('.');
  final String stem = dot > 0 ? trimmed.substring(0, dot) : trimmed;
  return '${stem.isEmpty ? 'gif' : stem}.gif';
}

/// [bytes] (a GIF) rebuilt with only the blocks that play it: the header,
/// the colour tables, the pictures with their Graphic Control Extensions
/// (timing, transparency) and the NETSCAPE / ANIMEXTS loop extension.
/// Comments, plain-text blocks, other application extensions (XMP, ICC
/// profiles, editor data) and anything after the trailer are dropped. A GIF
/// that ends right after a picture without its trailer gets one. Null when
/// the blocks do not add up or there is no picture.
Uint8List? stripGifMetadata(Uint8List bytes) {
  final int length = bytes.length;
  if (length < 13 ||
      !looksLikeGif(bytes) ||
      (bytes[4] != 0x37 && bytes[4] != 0x39) ||
      bytes[5] != 0x61) {
    return null;
  }
  final BytesBuilder out = BytesBuilder(copy: false);
  int offset = 13;
  final int packed = bytes[10];
  if ((packed & 0x80) != 0) {
    offset += 3 * (1 << ((packed & 0x07) + 1));
  }
  if (offset > length) {
    return null;
  }
  // Header, screen descriptor and global colour table.
  out.add(Uint8List.sublistView(bytes, 0, offset));

  // The end of the chain of data sub-blocks starting at [at] (just past
  // its zero terminator), or -1 when it is cut short.
  int subBlocksEnd(int at) {
    int i = at;
    while (i < length) {
      final int size = bytes[i];
      i += 1 + size;
      if (size == 0) {
        return i;
      }
    }
    return -1;
  }

  // A Graphic Control Extension belongs to the next picture: it is written
  // just before it, and dropped with a plain-text block it belonged to.
  Uint8List? pendingControl;
  int frames = 0;
  while (true) {
    if (offset >= length) {
      // No trailer: complete only if it ends right after a block.
      if (frames == 0) {
        return null;
      }
      break;
    }
    final int block = bytes[offset];
    if (block == 0x3B) {
      if (frames == 0) {
        return null;
      }
      break;
    }
    if (block == 0x21) {
      if (offset + 2 > length) {
        return null;
      }
      final int label = bytes[offset + 1];
      final int end = subBlocksEnd(offset + 2);
      if (end < 0) {
        return null;
      }
      if (label == 0xF9) {
        pendingControl = Uint8List.sublistView(bytes, offset, end);
      } else if (label == 0xFF && _isLoopExtension(bytes, offset + 2)) {
        out.add(Uint8List.sublistView(bytes, offset, end));
      } else if (label == 0x01) {
        // Plain text (never drawn by today's players): its control goes too.
        pendingControl = null;
      }
      // 0xFE comments and any other extension are left out.
      offset = end;
    } else if (block == 0x2C) {
      if (offset + 10 > length) {
        return null;
      }
      final int framePacked = bytes[offset + 9];
      int dataAt = offset + 10;
      if ((framePacked & 0x80) != 0) {
        dataAt += 3 * (1 << ((framePacked & 0x07) + 1));
      }
      // The LZW minimum code size, then the pixel data.
      if (dataAt >= length) {
        return null;
      }
      final int end = subBlocksEnd(dataAt + 1);
      if (end < 0) {
        return null;
      }
      if (pendingControl != null) {
        out.add(pendingControl);
        pendingControl = null;
      }
      out.add(Uint8List.sublistView(bytes, offset, end));
      frames++;
      offset = end;
    } else {
      return null;
    }
  }
  out.addByte(0x3B);
  return out.takeBytes();
}

/// Whether the application extension whose sub-blocks start at [at] is the
/// loop count (`NETSCAPE2.0` or `ANIMEXTS1.0`).
bool _isLoopExtension(Uint8List bytes, int at) {
  if (at + 12 > bytes.length || bytes[at] != 11) {
    return false;
  }
  final String id = String.fromCharCodes(bytes.sublist(at + 1, at + 12));
  return id == 'NETSCAPE2.0' || id == 'ANIMEXTS1.0';
}
