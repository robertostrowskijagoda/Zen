import 'dart:typed_data';

// Removing the metadata of MP4 / MOV films before they leave the phone.
// (films without GPS, like photos without EXIF).
//
// Phones write where and when a film was recorded into "user data" boxes
// of the ISO base media file format: Android puts the location into
// `moov/udta/©xyz` (or `loci`), iPhones into `moov/meta` (QuickTime keys
// such as `com.apple.quicktime.location.ISO6709`) and `moov/udta`, and
// editing apps add XMP in a top-level `uuid` box. None of it is needed to
// play the film.
//
// The film is not re-encoded and no box moves: every metadata box keeps
// its size but becomes a `free` box full of zeros. So the chunk offsets
// (`stco` / `co64`) and fragment offsets stay valid without being
// rewritten, and players skip `free` boxes at any level. The recording
// times in `mvhd`, `tkhd` and `mdhd` are set to zero (0 = "unknown").
//
// Anything that is not an ISO media file (WebM, Matroska) is returned as
// it is.

/// Boxes whose children are looked into.
const Set<String> _containers = <String>{
  'moov',
  'trak',
  'mdia',
  'minf',
  'edts',
  'dinf',
  'stbl',
  'mvex',
  'moof',
  'traf',
};

/// Boxes that only carry metadata (titles, places, makers, dates).
const Set<String> _metadataBoxes = <String>{'udta', 'meta'};

/// Boxes with a creation and a modification time.
const Set<String> _timedBoxes = <String>{'mvhd', 'tkhd', 'mdhd'};

/// The XMP `uuid` box (BE7ACFCB-97A9-42E8-9C71-999491E3AFAC).
const List<int> _xmpUuid = <int>[
  0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8, //
  0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC,
];

/// Top-level boxes an ISO / QuickTime file may start with.
const Set<String> _firstBoxes = <String>{
  'ftyp',
  'moov',
  'mdat',
  'free',
  'skip',
  'wide',
  'pnot',
};

/// Deepest nesting walked (real files go 5 levels deep).
const int _maxDepth = 8;

/// Whether [bytes] look like an MP4 / MOV / M4A file.
bool isIsoMediaFile(Uint8List bytes) {
  if (bytes.length < 8) {
    return false;
  }
  return _firstBoxes.contains(String.fromCharCodes(bytes, 4, 8));
}

/// [bytes] without location, dates and other metadata (see the top of this
/// file). Returns [bytes] itself when there was nothing to remove or it is
/// not an ISO media file; otherwise a changed copy of the same length.
Uint8List stripVideoMetadata(Uint8List bytes) {
  if (!isIsoMediaFile(bytes)) {
    return bytes;
  }
  final _Stripper s = _Stripper(bytes)..walk(0, bytes.length, 0);
  return s.out ?? bytes;
}

final class _Stripper {
  _Stripper(this.input) : _data = ByteData.sublistView(input);

  final Uint8List input;
  final ByteData _data;

  /// The changed copy, made at the first change.
  Uint8List? out;

  Uint8List get _writable => out ??= Uint8List.fromList(input);

  int _u32(int at) => _data.getUint32(at);

  int _u64(int at) =>
      _data.getUint32(at) * 0x100000000 + _data.getUint32(at + 4);

  void walk(int start, int end, int depth) {
    int pos = start;
    while (pos + 8 <= end) {
      int size = _u32(pos);
      final String type = String.fromCharCodes(input, pos + 4, pos + 8);
      int header = 8;
      if (size == 1) {
        if (pos + 16 > end) {
          return;
        }
        size = _u64(pos + 8);
        header = 16;
      } else if (size == 0) {
        size = end - pos; // up to the end of the parent
      }
      if (size < header || size > end - pos) {
        return; // malformed: leave the rest as it is
      }
      final int payload = pos + header;
      final int boxEnd = pos + size;
      if (_metadataBoxes.contains(type) ||
          (type == 'uuid' && _startsWith(payload, boxEnd, _xmpUuid))) {
        _blank(pos, payload, boxEnd);
      } else if (_containers.contains(type) && depth < _maxDepth) {
        walk(payload, boxEnd, depth + 1);
      } else if (_timedBoxes.contains(type)) {
        _zeroTimes(payload, boxEnd);
      }
      pos = boxEnd;
    }
  }

  bool _startsWith(int at, int end, List<int> prefix) {
    if (end - at < prefix.length) {
      return false;
    }
    for (int i = 0; i < prefix.length; i++) {
      if (input[at + i] != prefix[i]) {
        return false;
      }
    }
    return true;
  }

  /// Turns the box at [pos] into a `free` box of zeros (same size).
  void _blank(int pos, int payload, int boxEnd) {
    final Uint8List w = _writable;
    w.setAll(pos + 4, 'free'.codeUnits);
    w.fillRange(payload, boxEnd, 0);
  }

  /// Version 0: 4-byte times, version 1: 8-byte times, after the version
  /// and flags.
  void _zeroTimes(int payload, int boxEnd) {
    if (payload >= boxEnd) {
      return;
    }
    final int version = input[payload];
    final int width = version == 1 ? 16 : 8;
    final int from = payload + 4;
    if (from + width > boxEnd) {
      return;
    }
    bool any = false;
    for (int i = from; i < from + width; i++) {
      if (input[i] != 0) {
        any = true;
        break;
      }
    }
    if (any) {
      _writable.fillRange(from, from + width, 0);
    }
  }
}
