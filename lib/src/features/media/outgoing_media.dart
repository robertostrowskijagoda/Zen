import 'dart:typed_data';

import 'package:zen/src/core/utils/background_work.dart';
import 'package:zen/src/features/feed/video_metadata.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_guard.dart';

// What leaves this device keeps the picture, the film or the sound, never
// where, when and on what it was made.
//
// Pictures are re-encoded where they are picked (`media_transfer.dart`,
// `prepareOutgoing`): only pixels go on. Everything that is sent goes past
// [stripOutgoingMetadata] once more right before it leaves (the chat's and
// the group's send, the post's `storeMedia`), which removes the metadata
// of every kind it knows without re-encoding anything:
//  - films and recordings in MP4 / MOV / 3GP / M4A: `video_metadata.dart`
//    (the place, the dates, the maker and model, XMP);
//  - JPEG: EXIF (GPS, camera, dates), XMP, IPTC, comments, maker data and
//    whatever follows the picture (the second pictures and trailers phones
//    add, with an EXIF of their own); the turn of the picture is kept;
//  - PNG: text, time and EXIF chunks; WebP: its EXIF and XMP chunks;
//  - GIF: comments and application data (`gif_files.dart`);
//  - MP3: ID3 and APE tags; WAV: everything but the sound's own chunks;
//    FLAC: tags, pictures and application blocks.
// A kind this does not know (an Ogg recording, a WebM film, a HEIC photo
// the phone could not decode, a document) is left as it is:
// [canStripMetadata] says which ones Zen cannot clean, and the attach flow
// says so to the person.

/// The largest film, recording or file read whole to take its metadata
/// out before it is sent; a bigger one goes as it is.
const int kMaxCleanedTransferBytes = 64 * 1024 * 1024;

/// Whether [head] (the first bytes of a file) is a kind whose location,
/// device and time data [stripOutgoingMetadata] removes, or that carries
/// none (BMP, AMR).
bool canStripMetadata(Uint8List head) {
  if (_isJpeg(head) || _isPng(head) || _isWebp(head) || looksLikeGif(head)) {
    return true;
  }
  if (head.length >= 2 && head[0] == 0x42 && head[1] == 0x4D) {
    return true; // BMP: no metadata
  }
  if (isIsoMedia(head)) {
    // A HEIC picture's metadata sits beside the picture in its `meta` box:
    // only decoding it leaves the picture alone.
    return !isIsoPicture(head);
  }
  return _startsWithText(head, '#!AMR') ||
      _isMp3(head) ||
      _isWav(head) ||
      _startsWithText(head, 'fLaC');
}

/// [bytes] without their location, device and time metadata (see the top
/// of this file). Returns [bytes] itself when there was nothing to remove
/// or it is a kind this does not know; anything it cannot walk is left as
/// it is too.
Uint8List stripOutgoingMetadata(Uint8List bytes) {
  try {
    final Uint8List? clean;
    if (_isJpeg(bytes)) {
      clean = _stripJpeg(bytes);
    } else if (_isPng(bytes)) {
      clean = _stripPng(bytes);
    } else if (_isWebp(bytes)) {
      clean = _stripRiff(bytes, _webpDropped);
    } else if (looksLikeGif(bytes)) {
      clean = stripGifMetadata(bytes);
    } else if (isIsoMedia(bytes)) {
      clean = isIsoPicture(bytes) ? null : stripVideoMetadata(bytes);
    } else if (_isWav(bytes)) {
      clean = _stripRiff(bytes, (String id) => !_wavKept.contains(id));
    } else if (_startsWithText(bytes, 'fLaC')) {
      clean = _stripFlac(bytes);
    } else if (_isMp3(bytes)) {
      clean = _stripMp3(bytes);
    } else {
      clean = null;
    }
    if (clean == null || _same(clean, bytes)) {
      return bytes;
    }
    return clean;
  } on Object {
    // Malformed beyond what the walkers check: left as it is.
    return bytes;
  }
}

/// The size, in pixels, the picture [bytes] (its start is enough) is
/// shown at, read from its header without decoding it: a GIF's canvas, a
/// PNG, JPEG, WebP or BMP picture's size, with width and height swapped for
/// a JPEG whose kept EXIF turns it a quarter (orientations 5 to 8: the
/// friend's phone shows it turned). Null when [bytes] are no such picture
/// or its header does not read.
({int width, int height})? pictureDisplaySize(Uint8List bytes) {
  if (looksLikeGif(bytes)) {
    if (bytes.length < 10) {
      return null;
    }
    final int width = bytes[6] | (bytes[7] << 8);
    final int height = bytes[8] | (bytes[9] << 8);
    return width > 0 && height > 0 ? (width: width, height: height) : null;
  }
  final ImageCost? cost = incomingImageCost(bytes);
  if (cost == null) {
    return null;
  }
  final int? orientation = _isJpeg(bytes) ? _jpegOrientation(bytes) : null;
  return orientation != null && orientation >= 5 && orientation <= 8
      ? (width: cost.height, height: cost.width)
      : (width: cost.width, height: cost.height);
}

/// [stripOutgoingMetadata] off the UI thread when [bytes] are big.
// Not async on purpose: a closure made in an async function may drag its
// suspended frame along, which cannot be sent to another isolate.
Future<Uint8List> stripOutgoingMetadataSized(Uint8List bytes) =>
    runSizedWork<Uint8List>(bytes.length, () => stripOutgoingMetadata(bytes));

bool _same(Uint8List a, Uint8List b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

bool _startsWithText(Uint8List b, String text) {
  if (b.length < text.length) {
    return false;
  }
  for (int i = 0; i < text.length; i++) {
    if (b[i] != text.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}

bool _textAt(Uint8List b, int at, String text) {
  if (at < 0 || at + text.length > b.length) {
    return false;
  }
  for (int i = 0; i < text.length; i++) {
    if (b[at + i] != text.codeUnitAt(i)) {
      return false;
    }
  }
  return true;
}

bool _isJpeg(Uint8List b) =>
    b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;

bool _isPng(Uint8List b) =>
    b.length >= 8 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47 &&
    b[4] == 0x0D &&
    b[5] == 0x0A &&
    b[6] == 0x1A &&
    b[7] == 0x0A;

bool _isWebp(Uint8List b) =>
    _startsWithText(b, 'RIFF') && _textAt(b, 8, 'WEBP');

bool _isWav(Uint8List b) => _startsWithText(b, 'RIFF') && _textAt(b, 8, 'WAVE');

bool _isMp3(Uint8List b) => sniffMimeType(b) == 'audio/mpeg';

// ---------------------------------------------------------------------------
// JPEG
// ---------------------------------------------------------------------------

/// Whether the segment [marker] with payload [from]..[to] goes: every APPn
/// but APP0 (JFIF), the ICC profile in APP2 and APP14 (Adobe colour
/// transform), which the picture needs to look right, and comments.
bool _dropJpegSegment(Uint8List b, int marker, int from, int to) {
  if (marker == 0xFE) {
    return true;
  }
  if (marker < 0xE0 || marker > 0xEF) {
    return false;
  }
  if (marker == 0xE0 || marker == 0xEE) {
    return false;
  }
  if (marker == 0xE2) {
    return !_textAt(b, from, 'ICC_PROFILE\u0000');
  }
  return true;
}

Uint8List? _stripJpeg(Uint8List b) {
  final List<Uint8List> kept = <Uint8List>[];
  int at = 2;
  int? orientation;
  bool changed = false;
  int afterApp0 = 0;
  while (at + 1 < b.length) {
    if (b[at] != 0xFF) {
      return null;
    }
    final int marker = b[at + 1];
    if (marker == 0xFF) {
      at++; // fill byte
      continue;
    }
    if (marker == 0xD9) {
      kept.add(Uint8List.sublistView(b, at, at + 2));
      changed = changed || at + 2 < b.length;
      break;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      kept.add(Uint8List.sublistView(b, at, at + 2));
      at += 2;
      continue;
    }
    if (at + 4 > b.length) {
      return null;
    }
    final int length = (b[at + 2] << 8) | b[at + 3];
    final int end = at + 2 + length;
    if (length < 2 || end > b.length) {
      return null;
    }
    if (marker == 0xDA) {
      // The picture itself, up to the end marker; anything after it (a
      // second picture with its own EXIF, a phone's trailer) goes.
      final int last = _jpegEnd(b, end);
      kept.add(Uint8List.sublistView(b, at, last));
      changed = changed || last < b.length;
      break;
    }
    if (_dropJpegSegment(b, marker, at + 4, end)) {
      if (marker == 0xE1) {
        orientation ??= _exifOrientation(b, at + 4, end);
      }
      changed = true;
    } else {
      kept.add(Uint8List.sublistView(b, at, end));
      if (marker == 0xE0 && afterApp0 == kept.length - 1) {
        afterApp0 = kept.length;
      }
    }
    at = end;
  }
  if (!changed) {
    return b;
  }
  if (orientation != null && orientation > 1 && orientation <= 8) {
    // The turn of the picture is all that stays of its EXIF.
    kept.insert(afterApp0, _orientationSegment(orientation));
  }
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(const <int>[0xFF, 0xD8]);
  kept.forEach(out.add);
  return out.takeBytes();
}

/// The EXIF orientation of the JPEG [b]: of the first APP1 segment with
/// one, before the picture data; null when there is none or the segments
/// do not add up.
int? _jpegOrientation(Uint8List b) {
  int at = 2;
  while (at + 4 <= b.length) {
    if (b[at] != 0xFF) {
      return null;
    }
    final int marker = b[at + 1];
    if (marker == 0xFF) {
      at++; // fill byte
      continue;
    }
    if (marker == 0xDA || marker == 0xD9) {
      return null;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD7)) {
      at += 2;
      continue;
    }
    final int end = at + 2 + ((b[at + 2] << 8) | b[at + 3]);
    if (end > b.length) {
      return null;
    }
    if (marker == 0xE1) {
      final int? orientation = _exifOrientation(b, at + 4, end);
      if (orientation != null) {
        return orientation;
      }
    }
    at = end;
  }
  return null;
}

/// Where the entropy-coded data that starts at [from] ends: just past the
/// end marker (FF D9), or the end of the file. In the data a 0xFF is
/// always followed by 0x00 or a restart marker, so the first FF D9 is it.
int _jpegEnd(Uint8List b, int from) {
  for (int i = from; i + 1 < b.length; i++) {
    if (b[i] == 0xFF && b[i + 1] == 0xD9) {
      return i + 2;
    }
  }
  return b.length;
}

/// The Orientation (tag 0x0112) of IFD0 of the EXIF in [from]..[to], or
/// null.
int? _exifOrientation(Uint8List b, int from, int to) {
  if (!_textAt(b, from, 'Exif\u0000\u0000')) {
    return null;
  }
  final int tiff = from + 6;
  if (tiff + 8 > to) {
    return null;
  }
  final Endian endian;
  if (b[tiff] == 0x49 && b[tiff + 1] == 0x49) {
    endian = Endian.little;
  } else if (b[tiff] == 0x4D && b[tiff + 1] == 0x4D) {
    endian = Endian.big;
  } else {
    return null;
  }
  final ByteData data = ByteData.sublistView(b, tiff, to);
  final int ifd = data.getUint32(4, endian);
  if (ifd + 2 > data.lengthInBytes) {
    return null;
  }
  final int count = data.getUint16(ifd, endian);
  for (int i = 0; i < count; i++) {
    final int entry = ifd + 2 + 12 * i;
    if (entry + 12 > data.lengthInBytes) {
      return null;
    }
    if (data.getUint16(entry, endian) == 0x0112) {
      return data.getUint16(entry + 8, endian);
    }
  }
  return null;
}

/// An APP1 segment with an EXIF that holds only [orientation].
Uint8List _orientationSegment(int orientation) => Uint8List.fromList(<int>[
  0xFF, 0xE1, 0x00, 34, //
  ...'Exif'.codeUnits, 0, 0,
  ...'MM'.codeUnits, 0x00, 0x2A, 0, 0, 0, 8, // TIFF header, IFD0 at 8
  0x00, 0x01, // one entry
  0x01, 0x12, 0x00, 0x03, 0, 0, 0, 1, 0x00, orientation, 0, 0,
  0, 0, 0, 0, // no next IFD
]);

// ---------------------------------------------------------------------------
// PNG
// ---------------------------------------------------------------------------

/// Text (which cameras and editors fill with dates, authors and software),
/// the time of the last change, EXIF and content credentials.
const Set<String> _pngDropped = <String>{
  'tEXt',
  'zTXt',
  'iTXt',
  'tIME',
  'eXIf',
  'caBX',
};

Uint8List? _stripPng(Uint8List b) {
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(b, 0, 8));
  final ByteData data = ByteData.sublistView(b);
  int at = 8;
  bool changed = false;
  while (at + 12 <= b.length) {
    final int length = data.getUint32(at);
    final int end = at + 12 + length;
    if (end > b.length) {
      return null;
    }
    final String type = String.fromCharCodes(b, at + 4, at + 8);
    if (_pngDropped.contains(type)) {
      changed = true;
    } else {
      out.add(Uint8List.sublistView(b, at, end));
    }
    at = end;
    if (type == 'IEND') {
      break;
    }
  }
  if (at < b.length) {
    changed = true; // anything after the end
  }
  return changed ? out.takeBytes() : b;
}

// ---------------------------------------------------------------------------
// WebP and WAV (RIFF)
// ---------------------------------------------------------------------------

bool _webpDropped(String id) => id == 'EXIF' || id == 'XMP ';

/// The chunks of a WAV recording kept: the format, the sound and what
/// plays it (cue points, loops); lists (INFO with names and dates), ID3,
/// broadcast data (`bext`: the device, the date and time) and XML go.
const Set<String> _wavKept = <String>{
  'fmt ',
  'fact',
  'data',
  'cue ',
  'smpl',
  'inst',
};

/// A RIFF file without the chunks [drop] says go; the size in its header
/// is set again. In a WebP the extended header's EXIF and XMP flags are
/// cleared with them.
Uint8List? _stripRiff(Uint8List b, bool Function(String id) drop) {
  if (b.length < 12) {
    return null;
  }
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(b, 0, 12));
  final ByteData data = ByteData.sublistView(b);
  int at = 12;
  bool changed = false;
  while (at + 8 <= b.length) {
    final String id = String.fromCharCodes(b, at, at + 4);
    final int size = data.getUint32(at + 4, Endian.little);
    final int padded = size + (size & 1);
    if (at + 8 + size > b.length) {
      // A recording whose size was never written (still being recorded
      // when it was copied): the rest is kept as it is.
      out.add(Uint8List.sublistView(b, at));
      at = b.length;
      break;
    }
    final int end = (at + 8 + padded).clamp(0, b.length);
    if (drop(id)) {
      changed = true;
    } else if (id == 'VP8X' && size >= 1 && (b[at + 8] & 0x0C) != 0) {
      final Uint8List chunk = Uint8List.fromList(
        Uint8List.sublistView(b, at, end),
      );
      chunk[8] &= ~0x0C;
      out.add(chunk);
      changed = true;
    } else {
      out.add(Uint8List.sublistView(b, at, end));
    }
    at = end;
  }
  if (!changed) {
    return b;
  }
  final Uint8List result = out.takeBytes();
  ByteData.sublistView(result).setUint32(4, result.length - 8, Endian.little);
  return result;
}

// ---------------------------------------------------------------------------
// FLAC
// ---------------------------------------------------------------------------

/// Kept metadata blocks: STREAMINFO, PADDING, SEEKTABLE and CUESHEET. The
/// APPLICATION, VORBIS_COMMENT (tags) and PICTURE blocks go.
const Set<int> _flacKept = <int>{0, 1, 3, 5};

Uint8List? _stripFlac(Uint8List b) {
  final List<Uint8List> kept = <Uint8List>[];
  int at = 4;
  bool changed = false;
  while (true) {
    if (at + 4 > b.length) {
      return null;
    }
    final bool last = (b[at] & 0x80) != 0;
    final int type = b[at] & 0x7F;
    final int length = (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];
    final int end = at + 4 + length;
    if (end > b.length) {
      return null;
    }
    if (_flacKept.contains(type)) {
      kept.add(Uint8List.fromList(Uint8List.sublistView(b, at, end)));
    } else {
      changed = true;
    }
    at = end;
    if (last) {
      break;
    }
  }
  if (!changed) {
    return b;
  }
  if (kept.isEmpty) {
    return null; // no STREAMINFO: not a FLAC this can rebuild
  }
  for (final Uint8List block in kept) {
    block[0] &= 0x7F;
  }
  kept.last[0] |= 0x80;
  final BytesBuilder out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(b, 0, 4));
  kept.forEach(out.add);
  out.add(Uint8List.sublistView(b, at));
  return out.takeBytes();
}

// ---------------------------------------------------------------------------
// MP3
// ---------------------------------------------------------------------------

Uint8List? _stripMp3(Uint8List b) {
  int start = 0;
  // ID3v2 tags at the start (there may be more than one).
  while (_textAt(b, start, 'ID3') && start + 10 <= b.length) {
    final int size =
        ((b[start + 6] & 0x7F) << 21) |
        ((b[start + 7] & 0x7F) << 14) |
        ((b[start + 8] & 0x7F) << 7) |
        (b[start + 9] & 0x7F);
    final int footer = (b[start + 5] & 0x10) != 0 ? 10 : 0;
    final int next = start + 10 + size + footer;
    if (next > b.length) {
      return null;
    }
    start = next;
  }
  int end = b.length;
  // ID3v1 (and its extended form) at the end.
  if (end - 128 >= start && _textAt(b, end - 128, 'TAG')) {
    end -= 128;
    if (end - 227 >= start && _textAt(b, end - 227, 'TAG+')) {
      end -= 227;
    }
  }
  // An APEv2 tag before it.
  if (end - 32 >= start && _textAt(b, end - 32, 'APETAGEX')) {
    final ByteData footer = ByteData.sublistView(b, end - 32, end);
    final int size = footer.getUint32(12, Endian.little);
    final bool header = (footer.getUint32(20, Endian.little) & 0x80000000) != 0;
    final int cut = size + (header ? 32 : 0);
    if (cut >= 32 && end - cut >= start) {
      end -= cut;
    }
  }
  if (start == 0 && end == b.length) {
    return b;
  }
  return Uint8List.fromList(Uint8List.sublistView(b, start, end));
}
