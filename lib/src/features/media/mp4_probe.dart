import 'dart:io';

import 'package:flutter/foundation.dart';

// What an MP4 / MOV file says about itself: how long it is and how big its
// picture is, read from the index (`moov`) without decoding anything. Used to
// check a film before it is compressed and after (the limits of the "Filmy"
// section) and to show the trimming slider at the right length.
//
// Only the boxes on the way are read: `moov/mvhd` (time scale, duration) and
// for every track `tkhd` (picture size, rotation matrix) and `mdia/hdlr`
// (what kind of track). Anything that does not add up gives `null`.

/// A film's length and picture, as its index states them.
@immutable
final class Mp4Info {
  const Mp4Info({
    required this.durationMs,
    this.width = 0,
    this.height = 0,
    this.rotation = 0,
    this.hasVideo = false,
    this.hasAudio = false,
  });

  final int durationMs;

  /// The picture as stored (before [rotation]); 0 when there is no video.
  final int width;
  final int height;

  /// Clockwise degrees the picture is turned when shown: 0, 90, 180, 270.
  final int rotation;
  final bool hasVideo;
  final bool hasAudio;

  /// The picture as shown (turned by [rotation]).
  int get displayWidth => rotation == 90 || rotation == 270 ? height : width;
  int get displayHeight => rotation == 90 || rotation == 270 ? width : height;
}

/// Deepest nesting walked; real files nest the boxes read here 4 levels.
const int _maxDepth = 6;

/// The index of [bytes] (a whole file, or at least everything up to the end
/// of its `moov`), or `null` when it is not an MP4 / MOV file.
Mp4Info? probeMp4(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  int pos = 0;
  while (pos + 8 <= bytes.length) {
    final _Head? head = _head(data, pos, bytes.length);
    if (head == null) {
      return null;
    }
    if (head.type == 'moov') {
      if (pos + head.size > bytes.length) {
        return null;
      }
      return _moov(data, pos + head.header, pos + head.size);
    }
    pos += head.size;
  }
  return null;
}

/// [probeMp4] for a file on disk: only the box headers and the `moov` box
/// are read, so a long film does not have to fit in memory.
Future<Mp4Info?> probeMp4File(File file, {int maxIndexBytes = 32 << 20}) async {
  final RandomAccessFile raf = await file.open();
  try {
    final int length = await raf.length();
    int pos = 0;
    while (pos + 8 <= length) {
      await raf.setPosition(pos);
      final Uint8List header = await raf.read(16);
      final _Head? head = _head(
        ByteData.sublistView(header),
        0,
        header.length,
        parentEnd: length - pos,
      );
      if (head == null) {
        return null;
      }
      if (head.type == 'moov') {
        if (head.size > maxIndexBytes) {
          return null;
        }
        await raf.setPosition(pos);
        final Uint8List moov = await raf.read(head.size);
        if (moov.length != head.size) {
          return null;
        }
        return _moov(ByteData.sublistView(moov), head.header, head.size);
      }
      pos += head.size;
    }
    return null;
  } on FileSystemException {
    return null;
  } finally {
    await raf.close();
  }
}

typedef _Head = ({String type, int size, int header});

/// The box header at [pos] (size and type), checked against [end] (or
/// [parentEnd], the room left in the file, when only the header was read).
_Head? _head(ByteData data, int pos, int end, {int? parentEnd}) {
  if (pos + 8 > end) {
    return null;
  }
  int size = data.getUint32(pos);
  final String type = String.fromCharCodes(<int>[
    for (int i = 4; i < 8; i++) data.getUint8(pos + i),
  ]);
  int header = 8;
  final int room = parentEnd ?? end - pos;
  if (size == 1) {
    if (pos + 16 > end) {
      return null;
    }
    size = data.getUint32(pos + 8) * 0x100000000 + data.getUint32(pos + 12);
    header = 16;
  } else if (size == 0) {
    size = room;
  }
  if (size < header || size > room) {
    return null;
  }
  return (type: type, size: size, header: header);
}

Mp4Info? _moov(ByteData data, int start, int end) {
  int? timescale;
  int? duration;
  int width = 0;
  int height = 0;
  int rotation = 0;
  bool video = false;
  bool audio = false;
  int pos = start;
  while (pos + 8 <= end) {
    final _Head? h = _head(data, pos, end);
    if (h == null) {
      return null;
    }
    final int payload = pos + h.header;
    final int boxEnd = pos + h.size;
    if (h.type == 'mvhd' && payload + 4 <= boxEnd) {
      final int version = data.getUint8(payload);
      if (version == 1 && payload + 32 <= boxEnd) {
        timescale = data.getUint32(payload + 20);
        duration =
            data.getUint32(payload + 24) * 0x100000000 +
            data.getUint32(payload + 28);
      } else if (version == 0 && payload + 20 <= boxEnd) {
        timescale = data.getUint32(payload + 12);
        duration = data.getUint32(payload + 16);
      }
    } else if (h.type == 'trak') {
      final _Track? track = _track(data, payload, boxEnd, 1);
      if (track != null) {
        if (track.handler == 'vide' && !video && track.width > 0) {
          video = true;
          width = track.width;
          height = track.height;
          rotation = track.rotation;
        } else if (track.handler == 'soun') {
          audio = true;
        }
      }
    }
    pos = boxEnd;
  }
  if (timescale == null || timescale == 0 || duration == null) {
    return null;
  }
  return Mp4Info(
    durationMs: duration * 1000 ~/ timescale,
    width: width,
    height: height,
    rotation: rotation,
    hasVideo: video,
    hasAudio: audio,
  );
}

typedef _Track = ({String handler, int width, int height, int rotation});

_Track? _track(ByteData data, int start, int end, int depth) {
  if (depth > _maxDepth) {
    return null;
  }
  String handler = '';
  int width = 0;
  int height = 0;
  int rotation = 0;
  int pos = start;
  while (pos + 8 <= end) {
    final _Head? h = _head(data, pos, end);
    if (h == null) {
      return null;
    }
    final int payload = pos + h.header;
    final int boxEnd = pos + h.size;
    if (h.type == 'tkhd' && payload + 4 <= boxEnd) {
      final int version = data.getUint8(payload);
      // version/flags, times, track id, reserved, duration, reserved (8),
      // layer, group, volume, reserved: then the matrix and the size.
      final int matrixAt = payload + (version == 1 ? 52 : 40);
      if (matrixAt + 44 <= boxEnd) {
        rotation = _rotation(data, matrixAt);
        width = data.getUint32(matrixAt + 36) >> 16;
        height = data.getUint32(matrixAt + 40) >> 16;
      }
    } else if (h.type == 'mdia') {
      final _Track? inner = _track(data, payload, boxEnd, depth + 1);
      if (inner != null && inner.handler.isNotEmpty) {
        handler = inner.handler;
      }
    } else if (h.type == 'hdlr' && payload + 12 <= boxEnd) {
      handler = String.fromCharCodes(<int>[
        for (int i = 8; i < 12; i++) data.getUint8(payload + i),
      ]);
    }
    pos = boxEnd;
  }
  return (handler: handler, width: width, height: height, rotation: rotation);
}

/// Degrees of the 16.16 matrix at [at] (a, b, u, c, d, v, x, y, w).
int _rotation(ByteData data, int at) {
  final int a = data.getInt32(at);
  final int b = data.getInt32(at + 4);
  final int c = data.getInt32(at + 12);
  final int d = data.getInt32(at + 16);
  const int one = 0x10000;
  if (a == 0 && b == one && c == -one && d == 0) {
    return 90;
  }
  if (a == -one && b == 0 && c == 0 && d == -one) {
    return 180;
  }
  if (a == 0 && b == -one && c == one && d == 0) {
    return 270;
  }
  return 0;
}
