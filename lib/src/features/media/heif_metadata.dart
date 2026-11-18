import 'dart:typed_data';

// The place, time and device data of a HEIC/HEIF or AVIF picture, taken out
// without decoding it.
//
// Such a picture is an ISO box file: `ftyp`, then a `meta` box that lists
// its items (`iinf`: the coded picture, its tiles and thumbnail, and the
// metadata) and where each item's bytes are (`iloc`: offsets into the file,
// or into the `idat` box inside `meta`), then `mdat` with those bytes. The
// EXIF (GPS, camera, dates) is an item of type `Exif`; the XMP an item of
// type `mime`. Their bytes are overwritten where they are, so no offset or
// length anywhere in the file changes and every reader still finds the
// picture where it was. What it finds where the metadata was is an EXIF
// with no entries and an empty XMP packet, padded with zeros and spaces:
// zeros alone are no EXIF at all, and some readers (Pillow's `getexif`)
// refuse a picture's EXIF that is not one rather than see no tags. XML kept
// in the `meta` box itself (`xml `, `bxml`) becomes zeros (an empty text).
//
// Where the boxes are not what this understands (a picture sequence with a
// `moov`, a box this does not know at the top, metadata whose bytes are in
// another item or another file), the answer is null and the picture is not
// cleaned: the caller then says it goes with its metadata. Everything read
// is checked against the bounds of its box, and the counts of boxes, items
// and blanked ranges are bounded, so a hostile file can neither hang this
// nor make it throw.

/// Boxes at one level (the top, the `meta` box, the `iinf` box): a tiled
/// picture of a phone has a few hundred items, a huge panorama thousands.
const int _maxBoxes = 1 << 16;

/// Items one `iloc` box may list.
const int _maxItems = 1 << 16;

/// Ranges of metadata blanked in one picture; a real one has two or three.
const int _maxRanges = 1024;

/// Boxes that may stand at the top of a still picture beside `ftyp` and
/// `meta`: the picture's bytes and filler.
const Set<String> _topKept = <String>{'mdat', 'free', 'skip', 'wide'};

/// What an item of metadata becomes.
enum _Fill {
  /// An EXIF item: [_emptyExif], then zeros.
  exif,

  /// An XMP packet (`mime`, `application/rdf+xml`, not compressed):
  /// [_emptyXmp], then spaces.
  xmp,

  /// Anything else that may hold the same (another `mime` item, XML in the
  /// `meta` box): zeros.
  zeros,
}

/// An EXIF item with no entries: the offset of its TIFF header (past
/// `Exif\0\0`), a big-endian header and an empty IFD0 with no next one.
final Uint8List _emptyExif = Uint8List.fromList(<int>[
  0, 0, 0, 6, //
  ...'Exif'.codeUnits, 0, 0,
  ...'MM'.codeUnits, 0, 42, 0, 0, 0, 8,
  0, 0, // no entries
  0, 0, 0, 0, // no next IFD
]);

/// An XMP packet that says nothing.
final Uint8List _emptyXmp = Uint8List.fromList(
  '<x:xmpmeta xmlns:x="adobe:ns:meta/"/>'.codeUnits,
);

/// A range of the file to overwrite and with what; [first] is the first
/// extent of its item, where the empty EXIF or XMP goes.
typedef _Range = ({int from, int to, _Fill fill, bool first});

/// [bytes], a HEIC/HEIF or AVIF picture, with its EXIF and XMP overwritten
/// in place (see the top of this file). Returns [bytes] itself when there
/// is nothing left to overwrite, and null when its boxes are not what this
/// understands: then nothing is cleaned.
Uint8List? stripHeifMetadata(Uint8List bytes) {
  try {
    final List<_Range>? ranges = _metadataRanges(bytes);
    if (ranges == null) {
      return null;
    }
    if (ranges.every((_Range r) => _holds(bytes, r))) {
      return bytes;
    }
    final Uint8List out = Uint8List.fromList(bytes);
    for (final _Range r in ranges) {
      for (int i = r.from; i < r.to; i++) {
        out[i] = _byteAt(r, i);
      }
    }
    return out;
  } on RangeError {
    // A read past what was checked: not understood.
    return null;
  }
}

/// The byte [i] of [r] once overwritten.
int _byteAt(_Range r, int i) {
  final Uint8List? head = !r.first
      ? null
      : switch (r.fill) {
          _Fill.exif => _emptyExif,
          _Fill.xmp => _emptyXmp,
          _Fill.zeros => null,
        };
  final int at = i - r.from;
  if (head != null && r.to - r.from >= head.length && at < head.length) {
    return head[at];
  }
  return r.fill == _Fill.xmp ? 0x20 : 0;
}

/// Whether [r] of [b] is already what it is overwritten with.
bool _holds(Uint8List b, _Range r) {
  for (int i = r.from; i < r.to; i++) {
    if (b[i] != _byteAt(r, i)) {
      return false;
    }
  }
  return true;
}

final class _Box {
  const _Box(this.type, this.start, this.body, this.end);

  final String type;

  /// Where its header starts.
  final int start;

  /// Where what it holds starts, past the header.
  final int body;

  /// Just past its last byte.
  final int end;
}

int _u16(Uint8List b, int at) => (b[at] << 8) | b[at + 1];

int _u32(Uint8List b, int at) =>
    (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3];

/// An unsigned number of [size] bytes (0, 4 or 8) at [at], or null when it
/// is beyond any file this handles (4 GiB and more).
int? _sized(Uint8List b, int at, int size) => switch (size) {
  0 => 0,
  4 => _u32(b, at),
  8 => _u32(b, at) == 0 ? _u32(b, at + 4) : null,
  _ => null,
};

/// The boxes from [from] to [to], one after another, filling it exactly;
/// null when one does not fit or there are too many.
List<_Box>? _boxes(Uint8List b, int from, int to) {
  final List<_Box> boxes = <_Box>[];
  int at = from;
  while (at < to) {
    if (boxes.length >= _maxBoxes || to - at < 8) {
      return null;
    }
    int size = _u32(b, at);
    final String type = String.fromCharCodes(b, at + 4, at + 8);
    int header = 8;
    if (size == 1) {
      if (to - at < 16) {
        return null;
      }
      final int? large = _sized(b, at + 8, 8);
      if (large == null) {
        return null;
      }
      size = large;
      header = 16;
    } else if (size == 0) {
      size = to - at; // to the end of what holds it
    }
    if (type == 'uuid') {
      header += 16;
    }
    if (size < header || size > to - at) {
      return null;
    }
    boxes.add(_Box(type, at, at + header, at + size));
    at += size;
  }
  return boxes;
}

/// The one box of [type] among [boxes]; null when there is none, and
/// [_twice] when there are more.
_Box? _single(List<_Box> boxes, String type) {
  _Box? found;
  for (final _Box box in boxes) {
    if (box.type == type) {
      if (found != null) {
        return _twice;
      }
      found = box;
    }
  }
  return found;
}

const _Box _twice = _Box('', -1, -1, -1);

/// The ranges of [b] that hold metadata, or null when the picture is not
/// one this understands.
List<_Range>? _metadataRanges(Uint8List b) {
  final List<_Box>? top = _boxes(b, 0, b.length);
  if (top == null || top.isEmpty || top.first.type != 'ftyp') {
    return null;
  }
  _Box? meta;
  for (final _Box box in top.skip(1)) {
    if (box.type == 'meta' && meta == null) {
      meta = box;
    } else if (!_topKept.contains(box.type)) {
      // A second `meta`, a `moov` (a sequence, a live photo), a `uuid`
      // that may hold XMP, anything else: not a picture this knows.
      return null;
    }
  }
  if (meta == null || meta.end - meta.body < 4 || b[meta.body] != 0) {
    return null;
  }
  final List<_Box>? inMeta = _boxes(b, meta.body + 4, meta.end);
  if (inMeta == null) {
    return null;
  }
  final _Box? handler = _single(inMeta, 'hdlr');
  final _Box? info = _single(inMeta, 'iinf');
  final _Box? location = _single(inMeta, 'iloc');
  final _Box? data = _single(inMeta, 'idat');
  if (handler == null ||
      info == null ||
      location == null ||
      identical(handler, _twice) ||
      identical(info, _twice) ||
      identical(location, _twice) ||
      identical(data, _twice) ||
      handler.end - handler.body < 12 ||
      String.fromCharCodes(b, handler.body + 8, handler.body + 12) != 'pict') {
    return null;
  }
  final Map<int, _Fill>? metadata = _metadataItems(b, info);
  if (metadata == null) {
    return null;
  }
  // What a range in the file must never reach: the boxes that say where
  // everything is, and the header of every box at the top.
  final List<(int, int)> structure = <(int, int)>[
    (top.first.start, top.first.end),
    (meta.start, meta.end),
    for (final _Box box in top) (box.start, box.body),
  ];
  final List<_Range>? ranges = _itemRanges(
    b,
    location,
    metadata,
    data,
    structure,
  );
  if (ranges == null) {
    return null;
  }
  for (final _Box box in inMeta) {
    if ((box.type == 'xml ' || box.type == 'bxml') && box.end - box.body > 4) {
      ranges.add((
        from: box.body + 4,
        to: box.end,
        fill: _Fill.zeros,
        first: true,
      ));
    }
  }
  if (ranges.length > _maxRanges) {
    return null;
  }
  return ranges;
}

/// The items of [info] (`iinf`) whose bytes are metadata, by ID, with
/// what they become; null when an item entry does not read.
Map<int, _Fill>? _metadataItems(Uint8List b, _Box info) {
  if (info.end - info.body < 4) {
    return null;
  }
  final int version = b[info.body];
  final int countSize = version == 0 ? 2 : 4;
  if (info.end - info.body < 4 + countSize) {
    return null;
  }
  final List<_Box>? entries = _boxes(b, info.body + 4 + countSize, info.end);
  if (entries == null) {
    return null;
  }
  final Map<int, _Fill> items = <int, _Fill>{};
  for (final _Box entry in entries) {
    if (entry.type != 'infe') {
      continue;
    }
    if (entry.end - entry.body < 4) {
      return null;
    }
    final int entryVersion = b[entry.body];
    // Versions 0 and 1 carry no item type (the older form, not HEIF's);
    // version 2 has 16-bit item IDs, 3 has 32-bit ones.
    if (entryVersion != 2 && entryVersion != 3) {
      return null;
    }
    final int idSize = entryVersion == 2 ? 2 : 4;
    final int at = entry.body + 4;
    if (entry.end - at < idSize + 2 + 4) {
      return null;
    }
    final int id = idSize == 2 ? _u16(b, at) : _u32(b, at);
    final String type = String.fromCharCodes(
      b,
      at + idSize + 2,
      at + idSize + 6,
    );
    if (type == 'Exif') {
      items[id] = _Fill.exif;
    } else if (type == 'mime') {
      // After the type: the item's name, its content type and, when it is
      // compressed, its content encoding, each ended by a zero.
      final int name = _textEnd(b, at + idSize + 6, entry.end);
      final int content = _textEnd(b, name + 1, entry.end);
      final bool xmp =
          content < entry.end &&
          String.fromCharCodes(b, name + 1, content) == 'application/rdf+xml' &&
          (content + 1 >= entry.end || b[content + 1] == 0);
      items[id] = xmp ? _Fill.xmp : _Fill.zeros;
    }
  }
  return items;
}

/// Where the text that starts at [from] ends (its zero), or [to] when it
/// has none before it.
int _textEnd(Uint8List b, int from, int to) {
  for (int i = from; i < to; i++) {
    if (b[i] == 0) {
      return i;
    }
  }
  return to;
}

/// Where the bytes of the [items] are, by [location] (`iloc`): ranges of
/// the file, either directly or inside [data] (`idat`). Null when they are
/// anywhere else (another item, another file), reach past where they can
/// be, run to an unknown end or overlap [structure].
List<_Range>? _itemRanges(
  Uint8List b,
  _Box location,
  Map<int, _Fill> items,
  _Box? data,
  List<(int, int)> structure,
) {
  int at = location.body;
  final int end = location.end;
  if (end - at < 6) {
    return null;
  }
  final int version = b[at];
  if (version > 2) {
    return null;
  }
  at += 4;
  final int offsetSize = b[at] >> 4;
  final int lengthSize = b[at] & 0x0F;
  final int baseSize = b[at + 1] >> 4;
  final int indexSize = version == 0 ? 0 : b[at + 1] & 0x0F;
  at += 2;
  for (final int size in <int>[offsetSize, lengthSize, baseSize, indexSize]) {
    if (size != 0 && size != 4 && size != 8) {
      return null;
    }
  }
  final int idSize = version < 2 ? 2 : 4;
  if (end - at < idSize) {
    return null;
  }
  final int count = version < 2 ? _u16(b, at) : _u32(b, at);
  at += idSize;
  if (count > _maxItems) {
    return null;
  }
  final int extentSize = indexSize + offsetSize + lengthSize;
  final List<_Range> ranges = <_Range>[];
  int blanked = 0;
  for (int i = 0; i < count; i++) {
    final int fixed = idSize + (version == 0 ? 0 : 2) + 2 + baseSize + 2;
    if (end - at < fixed) {
      return null;
    }
    final int id = idSize == 2 ? _u16(b, at) : _u32(b, at);
    at += idSize;
    int method = 0;
    if (version != 0) {
      method = _u16(b, at) & 0x0F;
      at += 2;
    }
    final int reference = _u16(b, at);
    at += 2;
    final int? base = _sized(b, at, baseSize);
    at += baseSize;
    final int extents = _u16(b, at);
    at += 2;
    if (base == null || end - at < extents * extentSize) {
      return null;
    }
    final _Fill? fill = items[id];
    if (fill == null) {
      at += extents * extentSize; // the picture's own bytes: left alone
      continue;
    }
    // The bytes in this file (reference 0), straight (method 0) or in the
    // `idat` box (method 1); method 2 takes them from another item.
    if (reference != 0 || method > 1 || (method == 1 && data == null)) {
      return null;
    }
    final int origin = method == 0 ? 0 : data!.body;
    final int limit = method == 0 ? b.length : data!.end;
    for (int e = 0; e < extents; e++) {
      at += indexSize;
      final int? offset = _sized(b, at, offsetSize);
      at += offsetSize;
      final int? length = _sized(b, at, lengthSize);
      at += lengthSize;
      // A length of 0 means "to the end", which is no place to blank.
      if (offset == null || length == null || length == 0) {
        return null;
      }
      final int from = origin + base + offset;
      if (from < origin || from > limit || length > limit - from) {
        return null;
      }
      final int to = from + length;
      if (method == 0 &&
          structure.any(((int, int) s) => from < s.$2 && to > s.$1)) {
        return null;
      }
      blanked += length;
      ranges.add((from: from, to: to, fill: fill, first: e == 0));
      if (ranges.length > _maxRanges || blanked > b.length) {
        return null;
      }
    }
  }
  return ranges;
}
