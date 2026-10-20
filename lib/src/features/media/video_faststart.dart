import 'dart:typed_data';

// A film that plays while it downloads (§10) needs its index first: the
// `moov` box of an MP4 / MOV file says where every frame is, and phones
// usually write it at the very end, after the frames (`mdat`). A player
// that gets the file from the start would then wait for the whole file.
//
// [moveMoovToFront] puts `moov` before the first `mdat` ("fast start"),
// without re-encoding anything: the frames move by the size of `moov`, so
// every chunk offset in `stco` / `co64` that points into them is moved by
// as much. Fragmented files (`moof`) and anything that does not add up are
// left as they are.

/// Boxes inside `moov` that lead to the chunk offset tables.
const Set<String> _path = <String>{'moov', 'trak', 'mdia', 'minf', 'stbl'};

/// A real file nests these boxes four levels deep; more is a crafted file.
const int _maxDepth = 8;

typedef _Box = ({String type, int start, int size, int header});

/// The boxes from [start] to [end] of [bytes], or `null` when they do not
/// add up.
List<_Box>? _boxes(Uint8List bytes, int start, int end) {
  final ByteData data = ByteData.sublistView(bytes);
  final List<_Box> out = <_Box>[];
  int pos = start;
  while (pos < end) {
    if (pos + 8 > end || out.length > 4096) {
      return null;
    }
    int size = data.getUint32(pos);
    int header = 8;
    if (size == 1) {
      if (pos + 16 > end) {
        return null;
      }
      size = data.getUint32(pos + 8) * 0x100000000 + data.getUint32(pos + 12);
      header = 16;
    } else if (size == 0) {
      size = end - pos;
    }
    if (size < header || size > end - pos) {
      return null;
    }
    out.add((
      type: String.fromCharCodes(bytes, pos + 4, pos + 8),
      start: pos,
      size: size,
      header: header,
    ));
    pos += size;
  }
  return out;
}

/// [bytes] with `moov` before the frames (see the top of this file), or
/// [bytes] itself when it already is, or cannot be changed safely.
Uint8List moveMoovToFront(Uint8List bytes) {
  final List<_Box>? top = _boxes(bytes, 0, bytes.length);
  if (top == null || top.isEmpty || top.first.type != 'ftyp') {
    return bytes;
  }
  final int moovAt = top.indexWhere((_Box b) => b.type == 'moov');
  final int mdatAt = top.indexWhere((_Box b) => b.type == 'mdat');
  if (moovAt < 0 ||
      mdatAt < 0 ||
      moovAt < mdatAt ||
      top.any((_Box b) => b.type == 'moof') ||
      top.where((_Box b) => b.type == 'moov').length != 1) {
    return bytes;
  }
  final _Box moov = top[moovAt];
  final int from = top[mdatAt].start;
  final Uint8List index = Uint8List.fromList(
    Uint8List.sublistView(bytes, moov.start, moov.start + moov.size),
  );
  if (!_shiftOffsets(index, 0, index.length, from, moov.start, moov.size)) {
    return bytes;
  }
  final BytesBuilder out = BytesBuilder(copy: false);
  for (int i = 0; i < top.length; i++) {
    if (i == mdatAt) {
      out.add(index);
    }
    if (i != moovAt) {
      final _Box b = top[i];
      out.add(Uint8List.sublistView(bytes, b.start, b.start + b.size));
    }
  }
  return out.takeBytes();
}

/// Adds [shift] to every chunk offset in [moov] (from [start] to [end])
/// that points between [from] and [until] (the frames that move). False
/// when the tables do not add up or a 32-bit offset would overflow.
bool _shiftOffsets(
  Uint8List moov,
  int start,
  int end,
  int from,
  int until,
  int shift, [
  int depth = 0,
]) {
  if (depth > _maxDepth) {
    return false;
  }
  final List<_Box>? boxes = _boxes(moov, start, end);
  if (boxes == null) {
    return false;
  }
  final ByteData data = ByteData.sublistView(moov);
  for (final _Box b in boxes) {
    final int payload = b.start + b.header;
    final int boxEnd = b.start + b.size;
    if (_path.contains(b.type)) {
      if (!_shiftOffsets(
        moov,
        payload,
        boxEnd,
        from,
        until,
        shift,
        depth + 1,
      )) {
        return false;
      }
    } else if (b.type == 'stco' || b.type == 'co64') {
      final bool wide = b.type == 'co64';
      final int width = wide ? 8 : 4;
      if (payload + 8 > boxEnd) {
        return false;
      }
      final int count = data.getUint32(payload + 4);
      if (payload + 8 + count * width > boxEnd) {
        return false;
      }
      for (int i = 0; i < count; i++) {
        final int at = payload + 8 + i * width;
        final int offset = wide
            ? data.getUint32(at) * 0x100000000 + data.getUint32(at + 4)
            : data.getUint32(at);
        if (offset < from || offset >= until) {
          continue;
        }
        final int moved = offset + shift;
        if (wide) {
          data
            ..setUint32(at, moved ~/ 0x100000000)
            ..setUint32(at + 4, moved % 0x100000000);
        } else if (moved > 0xFFFFFFFF) {
          return false;
        } else {
          data.setUint32(at, moved);
        }
      }
    }
  }
  return true;
}
