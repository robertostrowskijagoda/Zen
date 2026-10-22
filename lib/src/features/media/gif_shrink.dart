import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_guard.dart';

// Small animated GIFs for the places that keep a picture inline, under a
// strict size limit (an event's album, a flat's or a food offer's photo,
// the avatar sent to friends, the profile cover): a photo becomes a small
// JPEG there, a GIF becomes a small GIF that still plays. It is decoded in
// pure Dart, every frame scaled down (and cropped when the place has a
// fixed shape), frames thinned out when there are too many, and encoded
// again — smaller and with fewer frames until it fits. It never falls back
// to a still first frame.
//
// A GIF that comes from another phone is not re-encoded (that would let
// anyone make this phone work hard): it is taken only when it is already
// within the limits its sender had to meet ([acceptSmallGif]).

/// The most frames a made-small GIF keeps; more are thinned out (their
/// time goes to the frames that stay).
const int kMaxShrunkGifFrames = 48;

/// Below this side a GIF is not made any smaller: fewer frames instead.
const int _minShrunkSide = 48;

/// Tries at most this many sizes before giving up.
const int _maxAttempts = 12;

/// Canvas size and number of pictures of a GIF, read from its blocks (no
/// pixel is decoded). Null when the blocks do not add up.
({int width, int height, int frames})? gifShape(Uint8List bytes) {
  final int length = bytes.length;
  if (length < 14 || !looksLikeGif(bytes)) {
    return null;
  }
  final int width = bytes[6] | (bytes[7] << 8);
  final int height = bytes[8] | (bytes[9] << 8);
  int offset = 13;
  final int packed = bytes[10];
  if ((packed & 0x80) != 0) {
    offset += 3 * (1 << ((packed & 0x07) + 1));
  }
  int skipSubBlocks(int at) {
    int i = at;
    while (i < length) {
      final int size = bytes[i];
      i += 1 + size;
      if (size == 0) {
        return i <= length ? i : -1;
      }
    }
    return -1;
  }

  int frames = 0;
  while (offset >= 0 && offset < length) {
    final int block = bytes[offset];
    if (block == 0x3B) {
      break;
    }
    if (block == 0x21) {
      offset = offset + 2 > length ? -1 : skipSubBlocks(offset + 2);
    } else if (block == 0x2C) {
      if (offset + 10 > length) {
        return null;
      }
      final int framePacked = bytes[offset + 9];
      int dataAt = offset + 10;
      if ((framePacked & 0x80) != 0) {
        dataAt += 3 * (1 << ((framePacked & 0x07) + 1));
      }
      offset = dataAt >= length ? -1 : skipSubBlocks(dataAt + 1);
      frames++;
    } else {
      return null;
    }
  }
  if (offset < 0 || frames == 0 || width <= 0 || height <= 0) {
    return null;
  }
  return (width: width, height: height, frames: frames);
}

/// [gif] made fit for a place with a size limit: at most [maxSide] px a
/// side, [maxBytes] and [maxFrames] frames, still animated. With [aspect]
/// (width / height) the middle of the canvas is cropped to that shape
/// first. A GIF already within the limits (and of that shape) is only
/// stripped of its metadata. Null for anything that is not a complete GIF
/// within [isAcceptableGif], or one that cannot be made small enough. Pure
/// and slow for a big GIF: run it in an isolate.
Uint8List? shrinkGif(
  Uint8List gif, {
  required int maxSide,
  required int maxBytes,
  int maxFrames = kMaxShrunkGifFrames,
  double? aspect,
}) {
  final Uint8List? clean = stripGifMetadata(gif);
  if (clean == null || !isAcceptableGif(clean)) {
    return null;
  }
  final ({int width, int height, int frames})? shape = gifShape(clean);
  if (shape == null) {
    return null;
  }
  final int w = shape.width;
  final int h = shape.height;
  // The part of the canvas that is kept.
  int cw = w;
  int ch = h;
  if (aspect != null && aspect > 0) {
    ch = math.min(h, math.max(1, (w / aspect).round()));
    cw = math.min(w, math.max(1, (ch * aspect).round()));
  }
  final bool cropped = cw < w - 1 || ch < h - 1;
  if (!cropped &&
      clean.length <= maxBytes &&
      math.max(w, h) <= maxSide &&
      shape.frames <= maxFrames) {
    return clean;
  }
  final img.Image? decoded;
  try {
    decoded = img.decodeGif(clean);
  } on Object {
    return null;
  }
  if (decoded == null) {
    return null;
  }
  final List<img.Image> frames = List<img.Image>.of(decoded.frames);
  if (frames.isEmpty) {
    return null;
  }
  final _Crop crop = _Crop(
    x: cropped ? (w - cw) ~/ 2 : 0,
    y: cropped ? (h - ch) ~/ 2 : 0,
    width: cropped ? cw : w,
    height: cropped ? ch : h,
    canvasWidth: w,
    canvasHeight: h,
  );
  final int n = frames.length;
  // At least two frames stay of an animation.
  final int maxStep = n >= 2 ? (n + 1) ~/ 2 : 1;
  int step = math.min(maxStep, math.max(1, (n + maxFrames - 1) ~/ maxFrames));
  final int longest = math.max(crop.width, crop.height);
  int side = math.min(maxSide, longest);
  // A first guess from the size of the file: a picture of a quarter of the
  // pixels takes about a quarter of the bytes.
  final double share =
      clean.length * (crop.width * crop.height) / (w * h) / step;
  if (share > maxBytes) {
    final double scale = math.sqrt(maxBytes * 0.85 / share);
    side = math.max(_minShrunkSide, math.min(side, (longest * scale).floor()));
  }
  side = math.min(side, longest);
  for (int attempt = 0; attempt < _maxAttempts; attempt++) {
    final Uint8List out;
    try {
      out = _encode(frames, crop, side, step, decoded.loopCount);
    } on Object {
      return null;
    }
    if (out.length <= maxBytes) {
      return out;
    }
    final double over = out.length / maxBytes;
    final int kept = (n + step - 1) ~/ step;
    final bool canThin = step < maxStep && kept > 2;
    if (canThin && ((kept > 12 && over > 1.6) || side <= _minShrunkSide)) {
      step = math.min(maxStep, step * 2);
      continue;
    }
    final int next = math.min(
      side - 1,
      (side / math.sqrt(over) * 0.95).floor(),
    );
    if (next >= _minShrunkSide) {
      side = next;
    } else if (side > _minShrunkSide) {
      side = math.min(_minShrunkSide, longest);
    } else if (canThin) {
      step = math.min(maxStep, step * 2);
    } else {
      return null;
    }
  }
  return null;
}

/// [gif] from another phone when it is a complete GIF already within the
/// limits its sender had to meet; stripped of its metadata. Null otherwise
/// (it is never re-encoded here).
Uint8List? acceptSmallGif(
  Uint8List gif, {
  required int maxSide,
  required int maxBytes,
  int maxFrames = kMaxShrunkGifFrames,
}) {
  if (gif.length > maxBytes) {
    return null;
  }
  final Uint8List? clean = stripGifMetadata(gif);
  if (clean == null || !isAcceptableGif(clean)) {
    return null;
  }
  final ({int width, int height, int frames})? shape = gifShape(clean);
  if (shape == null ||
      shape.width > maxSide ||
      shape.height > maxSide ||
      shape.frames > maxFrames) {
    return null;
  }
  return clean;
}

final class _Crop {
  const _Crop({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final int canvasWidth;
  final int canvasHeight;
}

/// Every [step]-th of [frames] scaled so the longer side of [crop] is
/// [side], as one GIF; a frame keeps the time of those left out after it.
Uint8List _encode(
  List<img.Image> frames,
  _Crop crop,
  int side,
  int step,
  int loopCount,
) {
  final double scale = side / math.max(crop.width, crop.height);
  final int tw = math.max(1, (crop.width * scale).round());
  final int th = math.max(1, (crop.height * scale).round());
  img.Image? first;
  for (int i = 0; i < frames.length; i += step) {
    int duration = 0;
    for (int j = i; j < math.min(i + step, frames.length); j++) {
      duration += math.max(0, frames[j].frameDuration);
    }
    final img.Image frame = _scaled(frames[i], crop, tw, th)
      ..frameDuration = duration;
    if (first == null) {
      first = frame;
    } else {
      first.addFrame(frame);
    }
  }
  first!.loopCount = loopCount;
  return img.encodeGif(first);
}

/// The [crop] of one decoded frame [src] at [tw] x [th]: each pixel the
/// average of up to four samples of the source (transparent when most of
/// them are). Reads the frame's own pixels only, never its animation.
img.Image _scaled(img.Image src, _Crop crop, int tw, int th) {
  final img.Image out = img.Image(width: tw, height: th, numChannels: 4);
  // A frame smaller than the canvas is mapped by its own size.
  final double kx = src.width / crop.canvasWidth;
  final double ky = src.height / crop.canvasHeight;
  final double fx = crop.width / tw;
  final double fy = crop.height / th;
  final List<double> offsets = fx >= 2 || fy >= 2
      ? const <double>[0.25, 0.75]
      : const <double>[0.5];
  final int maxX = src.width - 1;
  final int maxY = src.height - 1;
  for (int y = 0; y < th; y++) {
    for (int x = 0; x < tw; x++) {
      num r = 0;
      num g = 0;
      num b = 0;
      int opaque = 0;
      int samples = 0;
      for (final double oy in offsets) {
        final int sy = math.min(
          maxY,
          math.max(0, ((crop.y + (y + oy) * fy) * ky).floor()),
        );
        for (final double ox in offsets) {
          final int sx = math.min(
            maxX,
            math.max(0, ((crop.x + (x + ox) * fx) * kx).floor()),
          );
          final img.Pixel p = src.getPixel(sx, sy);
          final num max = p.maxChannelValue;
          samples++;
          if (max > 0 && p.a * 2 >= max) {
            r += p.r * 255 / max;
            g += p.g * 255 / max;
            b += p.b * 255 / max;
            opaque++;
          }
        }
      }
      if (opaque * 2 >= samples && opaque > 0) {
        out.setPixelRgba(x, y, r / opaque, g / opaque, b / opaque, 255);
      } else {
        out.setPixelRgba(x, y, 255, 255, 255, 0);
      }
    }
  }
  return out;
}
