import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_design.dart';
import 'package:zen/src/features/pebbles/render/pebble_mesh.dart';
import 'package:zen/src/features/pebbles/render/pebble_renderer.dart';
import 'package:zen/src/features/pebbles/render/pebble_texture.dart';

/// The card's 16×16, 16-colour top view of [design] ([PebbleThumbnail]):
/// the stone drawn from above (the back at the top), lit, shrunk 4×4 and
/// reduced to 15 colours plus transparent.
Future<Uint8List> pebbleThumbnail(PebbleDesign design) async {
  const int px = 64;
  const PebbleAtlas atlas = PebbleAtlas(128);
  final ui.Image texture = PebbleTextures.of(design, atlas);
  final PebbleRenderer renderer = PebbleRenderer(
    PebbleMesh.of(PebbleShapeKey.of(design)),
    design.finish,
    atlas,
    tint: design.mainColour,
  );
  final ui.PictureRecorder rec = ui.PictureRecorder();
  renderer.paint(
    ui.Canvas(rec),
    const ui.Rect.fromLTWH(0, 0, px + 0.0, px + 0.0),
    PebbleRotation.facing(0),
    texture,
    zoom: 1.15,
    shadow: false,
  );
  final ui.Image image = await rec.endRecording().toImage(px, px);
  final ByteData? data = await image.toByteData();
  image.dispose();
  texture.dispose();
  if (data == null) {
    throw StateError('The thumbnail could not be read');
  }
  return thumbnailFromRgba(data.buffer.asUint8List(), px);
}

/// Shrinks a square premultiplied RGBA picture [rgba] of side [px] (a
/// multiple of 16) into thumbnail bytes.
Uint8List thumbnailFromRgba(Uint8List rgba, int px) {
  const int side = PebbleThumbnail.side;
  final int block = px ~/ side;
  final List<int> colours = <int>[];
  final List<int> opaque = List<int>.filled(side * side, -1);
  for (int j = 0; j < side; j++) {
    for (int i = 0; i < side; i++) {
      int r = 0, g = 0, b = 0, a = 0;
      for (int y = 0; y < block; y++) {
        for (int x = 0; x < block; x++) {
          final int o = ((j * block + y) * px + i * block + x) * 4;
          r += rgba[o];
          g += rgba[o + 1];
          b += rgba[o + 2];
          a += rgba[o + 3];
        }
      }
      final int n = block * block;
      if (a < 128 * n) {
        continue;
      }
      // Premultiplied sums: divide by the alpha to get the colour back.
      final int cr = (r * 255 / a).round().clamp(0, 255);
      final int cg = (g * 255 / a).round().clamp(0, 255);
      final int cb = (b * 255 / a).round().clamp(0, 255);
      opaque[j * side + i] = colours.length;
      colours.add((cr << 16) | (cg << 8) | cb);
    }
  }
  final List<int> palette = _medianCut(colours, PebbleThumbnail.colours - 1);
  final List<int> pixels = List<int>.filled(side * side, 0);
  for (int p = 0; p < side * side; p++) {
    final int c = opaque[p];
    if (c < 0) {
      continue;
    }
    pixels[p] = 1 + _nearest(palette, colours[c]);
  }
  return PebbleThumbnail.encode(palette, pixels);
}

int _nearest(List<int> palette, int c) {
  int best = 0;
  int bestD = 1 << 30;
  for (int i = 0; i < palette.length; i++) {
    final int dr = ((palette[i] >> 16) & 0xFF) - ((c >> 16) & 0xFF);
    final int dg = ((palette[i] >> 8) & 0xFF) - ((c >> 8) & 0xFF);
    final int db = (palette[i] & 0xFF) - (c & 0xFF);
    final int d = dr * dr * 3 + dg * dg * 4 + db * db * 2;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/// Up to [count] colours representing [colours] (median cut, deterministic).
List<int> _medianCut(List<int> colours, int count) {
  if (colours.isEmpty) {
    return <int>[];
  }
  List<List<int>> boxes = <List<int>>[List<int>.of(colours)];
  while (boxes.length < count) {
    int widest = -1;
    int widestRange = 0;
    int widestChannel = 0;
    for (int b = 0; b < boxes.length; b++) {
      if (boxes[b].length < 2) {
        continue;
      }
      for (int ch = 0; ch < 3; ch++) {
        final int shift = 16 - ch * 8;
        int lo = 255, hi = 0;
        for (final int c in boxes[b]) {
          final int v = (c >> shift) & 0xFF;
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
        if (hi - lo > widestRange) {
          widestRange = hi - lo;
          widest = b;
          widestChannel = shift;
        }
      }
    }
    if (widest < 0) {
      break;
    }
    final List<int> box = boxes[widest]
      ..sort((int x, int y) {
        final int d =
            ((x >> widestChannel) & 0xFF) - ((y >> widestChannel) & 0xFF);
        return d != 0 ? d : x - y;
      });
    final int mid = box.length ~/ 2;
    boxes = <List<int>>[
      ...boxes.sublist(0, widest),
      box.sublist(0, mid),
      box.sublist(mid),
      ...boxes.sublist(widest + 1),
    ];
  }
  return <int>[
    for (final List<int> box in boxes)
      if (box.isNotEmpty) _average(box),
  ];
}

int _average(List<int> box) {
  int r = 0, g = 0, b = 0;
  for (final int c in box) {
    r += (c >> 16) & 0xFF;
    g += (c >> 8) & 0xFF;
    b += c & 0xFF;
  }
  final int n = box.length;
  return ((r / n).round() << 16) | ((g / n).round() << 8) | (b / n).round();
}

/// The card's two main colours from a thumbnail: the commonest colour and
/// the commonest one clearly different from it. Null without a thumbnail.
(int, int)? thumbnailColours(Uint8List thumbnail) {
  final Uint32List? px = PebbleThumbnail.decode(thumbnail);
  if (px == null) {
    return null;
  }
  final Map<int, int> counts = <int, int>{};
  for (final int c in px) {
    if (c != 0) {
      counts[c & 0xFFFFFF] = (counts[c & 0xFFFFFF] ?? 0) + 1;
    }
  }
  if (counts.isEmpty) {
    return null;
  }
  final List<MapEntry<int, int>> sorted = counts.entries.toList()
    ..sort(
      (MapEntry<int, int> a, MapEntry<int, int> b) =>
          b.value != a.value ? b.value - a.value : a.key - b.key,
    );
  final int first = sorted.first.key;
  int second = first;
  for (final MapEntry<int, int> e in sorted.skip(1)) {
    final int dr = ((e.key >> 16) & 0xFF) - ((first >> 16) & 0xFF);
    final int dg = ((e.key >> 8) & 0xFF) - ((first >> 8) & 0xFF);
    final int db = (e.key & 0xFF) - (first & 0xFF);
    if (dr * dr + dg * dg + db * db > 40 * 40) {
      second = e.key;
      break;
    }
  }
  return (first, second);
}
