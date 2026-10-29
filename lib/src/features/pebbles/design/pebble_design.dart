import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/pebbles/design/pebble_card_look.dart';
import 'package:zen/src/features/pebbles/design/pebble_faces.dart';
import 'package:zen/src/features/pebbles/design/pebble_fonts.dart';
import 'package:zen/src/features/pebbles/design/pebble_materials.dart';
import 'package:zen/src/features/pebbles/design/pebble_patterns.dart';
import 'package:zen/src/features/pebbles/design/pebble_shapes.dart';
import 'package:zen/src/features/pebbles/design/pebble_stamps.dart';

/// Face coordinates (s, t) are stored as 12-bit numbers over -2…2 (a
/// stroke may run onto a neighbouring face): 1/1024 of a face unit, well
/// under a texel.
abstract final class PebbleQ {
  static const int max = 4095;

  static int of(double v) => ((v + 2) * 1024).round().clamp(0, max);

  static double value(int q) => q / 1024 - 2;
}

/// What a stroke does.
enum PebbleStrokeTool { brush, spray, eraser }

/// One painting step, in the coordinates of a face. The fields hold the
/// stored (quantised) numbers, so a design read back equals the one
/// written.
@immutable
sealed class PebbleOp {
  const PebbleOp();

  int get face;
}

/// A brush, spray or eraser stroke: a polyline on [face] (its points may
/// run past the face's edge; they are drawn onto the neighbours too).
final class PebbleStroke extends PebbleOp {
  PebbleStroke({
    required this.tool,
    required this.colour,
    required this.size,
    required this.face,
    required this.points,
    this.mirror = false,
  }) : assert(points.length >= 2 && points.length.isEven);

  final PebbleStrokeTool tool;

  /// 0xAARRGGBB.
  final int colour;

  /// The radius in 1/256 of a face unit (1…255).
  final int size;

  @override
  final int face;

  /// Quantised (s, t) pairs ([PebbleQ]).
  final Uint16List points;

  /// Painted again mirrored across the stone's middle.
  final bool mirror;

  double get radius => size / 256;
  int get pointCount => points.length ~/ 2;
}

/// The whole face in one colour.
final class PebbleFaceFill extends PebbleOp {
  const PebbleFaceFill({required this.face, required this.colour});

  @override
  final int face;
  final int colour;
}

/// The region around (s, t) on [face], up to the strokes around it.
final class PebbleRegionFill extends PebbleOp {
  const PebbleRegionFill({
    required this.face,
    required this.s,
    required this.t,
    required this.colour,
  });

  @override
  final int face;
  final int s;
  final int t;
  final int colour;
}

/// A stamp put at (s, t) on [face].
final class PebbleStampOp extends PebbleOp {
  const PebbleStampOp({
    required this.stamp,
    required this.face,
    required this.s,
    required this.t,
    required this.size,
    this.angle = 0,
    this.colour = 0,
    this.ink = 0,
    this.mirror = false,
    this.flip = false,
  });

  final int stamp;
  @override
  final int face;
  final int s;
  final int t;

  /// Half the stamp's width in 1/200 of a face unit (1…255).
  final int size;

  /// The turn in 1/256 of a full turn.
  final int angle;

  /// 0xAARRGGBB, or 0 for the stamp's own colours.
  final int colour;
  final int ink;
  final bool mirror;

  /// Drawn flipped left-to-right.
  final bool flip;

  double get halfSize => size / 200;
}

/// Text on the surface, optionally curved along an arc.
final class PebbleTextOp extends PebbleOp {
  const PebbleTextOp({
    required this.face,
    required this.s,
    required this.t,
    required this.size,
    required this.text,
    required this.colour,
    this.angle = 0,
    this.curve = 0,
    this.font = 0,
  });

  static const int maxBytes = 80;

  /// How many typefaces a text may name ([PebbleFont]).
  static final int fontCount = PebbleFont.values.length;

  @override
  final int face;
  final int s;
  final int t;

  /// The letters' height in 1/200 of a face unit.
  final int size;
  final String text;
  final int colour;
  final int angle;

  /// -100…100: how much the line bends (positive arches upwards).
  final int curve;

  /// The typeface: a [PebbleFont]'s index.
  final int font;

  double get height => size / 200;
}

/// A pattern over the whole of [face].
final class PebblePatternOp extends PebbleOp {
  const PebblePatternOp({
    required this.face,
    required this.pattern,
    required this.colour,
    this.colour2 = 0,
    this.scale = 64,
    this.angle = 0,
  });

  @override
  final int face;
  final int pattern;
  final int colour;

  /// The second colour, or 0 for none.
  final int colour2;

  /// The repeat's size in 1/160 of a face unit.
  final int scale;
  final int angle;

  double get cell => 0.04 + scale / 160;
}

/// A painted pebble: the stone (shape, its seed and proportions, the
/// material and its colours) and the painting steps in order. It is stored
/// and sent as compact bytes ([encode]); the paint is kept as vector steps
/// in the faces' coordinates, never as pixels.
@immutable
final class PebbleDesign {
  const PebbleDesign({
    required this.shape,
    required this.seed,
    required this.material,
    required this.mainColour,
    required this.secondColour,
    this.width = 0,
    this.height = 0,
    this.length = 0,
    this.ops = const <PebbleOp>[],
  });

  /// A bare stone of [material]'s colours.
  factory PebbleDesign.stone({int shape = 0, int seed = 1, int material = 6}) {
    final PebbleMaterial m = PebbleMaterial.byId(material);
    return PebbleDesign(
      shape: shape,
      seed: seed,
      material: material,
      mainColour: m.main,
      secondColour: m.second,
    );
  }

  static const int version = 1;

  /// The hard cap of an encoded design.
  static const int maxBytes = 64 * 1024;
  static const int maxOps = 4000;
  static const int maxStrokePoints = 2000;
  static const int _headerBytes = 18;

  final int shape;

  /// u32.
  final int seed;
  final int material;

  /// 0xFFRRGGBB.
  final int mainColour;
  final int secondColour;

  /// Proportions, -100…100 (stretch across, up, along).
  final int width;
  final int height;
  final int length;

  final List<PebbleOp> ops;

  PebbleShapePreset get shapePreset => PebbleShapePreset.byId(shape);
  PebbleMaterial get materialPreset => PebbleMaterial.byId(material);
  PebbleFinish get finish => materialPreset.finish;

  PebbleCardLook get look => PebbleCardLook(
    shape: shape,
    seed: seed,
    material: material,
    mainColour: mainColour & 0xFFFFFF,
    secondColour: secondColour & 0xFFFFFF,
  );

  PebbleDesign copyWith({
    int? shape,
    int? seed,
    int? material,
    int? mainColour,
    int? secondColour,
    int? width,
    int? height,
    int? length,
    List<PebbleOp>? ops,
  }) => PebbleDesign(
    shape: shape ?? this.shape,
    seed: seed ?? this.seed,
    material: material ?? this.material,
    mainColour: mainColour ?? this.mainColour,
    secondColour: secondColour ?? this.secondColour,
    width: width ?? this.width,
    height: height ?? this.height,
    length: length ?? this.length,
    ops: ops ?? this.ops,
  );

  PebbleDesign withOp(PebbleOp op) =>
      copyWith(ops: List<PebbleOp>.unmodifiable(<PebbleOp>[...ops, op]));

  /// The size [encode] gives, without building the bytes.
  int get encodedLength {
    int n = _headerBytes;
    for (final PebbleOp op in ops) {
      n += _opLength(op);
    }
    return n;
  }

  /// Room left for [op] under [maxBytes] and [maxOps].
  bool canAdd(PebbleOp op) =>
      ops.length < maxOps && encodedLength + _opLength(op) <= maxBytes;

  /// The design's bytes. Throws [StateError] past [maxBytes].
  Uint8List encode() {
    final _Writer w = _Writer();
    w
      ..u8(version)
      ..u8(shape)
      ..u32(seed)
      ..u8(material)
      ..rgb(mainColour)
      ..rgb(secondColour)
      ..i8(width)
      ..i8(height)
      ..i8(length)
      ..u16(ops.length);
    for (final PebbleOp op in ops) {
      _writeOp(w, op);
    }
    final Uint8List bytes = w.take();
    if (bytes.length > maxBytes) {
      throw StateError('The design is ${bytes.length} bytes, over $maxBytes');
    }
    return bytes;
  }

  /// Reads [encode]'s bytes. Throws [FormatException] for anything else.
  static PebbleDesign decode(Uint8List bytes) {
    if (bytes.length > maxBytes) {
      throw const FormatException('The design is too large');
    }
    final _Reader r = _Reader(bytes);
    if (r.u8() != version) {
      throw const FormatException('Unknown design version');
    }
    final int shape = r.u8();
    final int seed = r.u32();
    final int material = r.u8();
    final int main = r.rgb();
    final int second = r.rgb();
    final int width = r.i8();
    final int height = r.i8();
    final int length = r.i8();
    final int count = r.u16();
    if (shape >= PebbleShapePreset.values.length ||
        material >= PebbleMaterial.values.length ||
        count > maxOps) {
      throw const FormatException('Bad design header');
    }
    final List<PebbleOp> ops = <PebbleOp>[
      for (int i = 0; i < count; i++) _readOp(r),
    ];
    if (!r.done) {
      throw const FormatException('Trailing bytes after the design');
    }
    return PebbleDesign(
      shape: shape,
      seed: seed,
      material: material,
      mainColour: main,
      secondColour: second,
      width: width,
      height: height,
      length: length,
      ops: List<PebbleOp>.unmodifiable(ops),
    );
  }

  /// Decodes [bytes], or null when they are not a design.
  static PebbleDesign? tryDecode(Uint8List? bytes) {
    if (bytes == null) {
      return null;
    }
    try {
      return decode(bytes);
    } on FormatException {
      return null;
    } on RangeError {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is PebbleDesign && listEquals(other.encode(), encode());

  @override
  int get hashCode => Object.hashAll(encode());
}

const int _opStroke = 1;
const int _opFaceFill = 2;
const int _opRegionFill = 3;
const int _opStamp = 4;
const int _opText = 5;
const int _opPattern = 6;

int _pointsLength(Uint16List p) {
  int n = 4;
  for (int i = 2; i < p.length; i += 2) {
    final int dx = p[i] - p[i - 2];
    final int dy = p[i + 1] - p[i - 1];
    n += dx.abs() <= 127 && dy.abs() <= 127 ? 2 : 5;
  }
  return n;
}

int _opLength(PebbleOp op) => switch (op) {
  PebbleStroke() => 10 + _pointsLength(op.points),
  PebbleFaceFill() => 6,
  PebbleRegionFill() => 10,
  PebbleStampOp() => 18,
  PebbleTextOp() => 16 + utf8.encode(op.text).length,
  PebblePatternOp() => 13,
};

void _writeOp(_Writer w, PebbleOp op) {
  switch (op) {
    case PebbleStroke():
      w
        ..u8(_opStroke)
        ..u8(op.tool.index | (op.mirror ? 4 : 0))
        ..u8(op.face)
        ..u8(op.size)
        ..u32(op.colour)
        ..u16(op.pointCount);
      final Uint16List p = op.points;
      w
        ..u16(p[0])
        ..u16(p[1]);
      for (int i = 2; i < p.length; i += 2) {
        final int dx = p[i] - p[i - 2];
        final int dy = p[i + 1] - p[i - 1];
        if (dx.abs() <= 127 && dy.abs() <= 127) {
          w
            ..i8(dx)
            ..i8(dy);
        } else {
          w
            ..u8(0x80)
            ..u16(p[i])
            ..u16(p[i + 1]);
        }
      }
    case PebbleFaceFill():
      w
        ..u8(_opFaceFill)
        ..u8(op.face)
        ..u32(op.colour);
    case PebbleRegionFill():
      w
        ..u8(_opRegionFill)
        ..u8(op.face)
        ..u16(op.s)
        ..u16(op.t)
        ..u32(op.colour);
    case PebbleStampOp():
      w
        ..u8(_opStamp)
        ..u8((op.mirror ? 1 : 0) | (op.flip ? 2 : 0))
        ..u16(op.stamp)
        ..u8(op.face)
        ..u16(op.s)
        ..u16(op.t)
        ..u8(op.size)
        ..u8(op.angle)
        ..u32(op.colour)
        ..u32(op.ink);
    case PebbleTextOp():
      final Uint8List text = utf8.encode(op.text);
      w
        ..u8(_opText)
        ..u8(op.face)
        ..u8(op.font)
        ..u16(op.s)
        ..u16(op.t)
        ..u8(op.size)
        ..u8(op.angle)
        ..i8(op.curve)
        ..u32(op.colour)
        ..u8(text.length)
        ..bytes(text);
    case PebblePatternOp():
      w
        ..u8(_opPattern)
        ..u8(op.face)
        ..u8(op.pattern)
        ..u8(op.scale)
        ..u8(op.angle)
        ..u32(op.colour)
        ..u32(op.colour2);
  }
}

int _face(_Reader r) {
  final int f = r.u8();
  if (f >= PebbleFace.count) {
    throw const FormatException('Bad face');
  }
  return f;
}

int _q(_Reader r) {
  final int q = r.u16();
  if (q > PebbleQ.max) {
    throw const FormatException('Bad coordinate');
  }
  return q;
}

PebbleOp _readOp(_Reader r) {
  final int type = r.u8();
  switch (type) {
    case _opStroke:
      final int flags = r.u8();
      final int tool = flags & 3;
      if (tool >= PebbleStrokeTool.values.length || flags & ~7 != 0) {
        throw const FormatException('Bad stroke');
      }
      final int face = _face(r);
      final int size = r.u8();
      final int colour = r.u32();
      final int n = r.u16();
      if (n < 1 || n > PebbleDesign.maxStrokePoints || size == 0) {
        throw const FormatException('Bad stroke');
      }
      final Uint16List p = Uint16List(n * 2);
      p[0] = _q(r);
      p[1] = _q(r);
      for (int i = 1; i < n; i++) {
        final int b = r.u8();
        if (b == 0x80) {
          p[i * 2] = _q(r);
          p[i * 2 + 1] = _q(r);
        } else {
          final int dx = b >= 128 ? b - 256 : b;
          final int dy = r.i8();
          final int x = p[i * 2 - 2] + dx;
          final int y = p[i * 2 - 1] + dy;
          if (x < 0 || x > PebbleQ.max || y < 0 || y > PebbleQ.max) {
            throw const FormatException('Bad coordinate');
          }
          p[i * 2] = x;
          p[i * 2 + 1] = y;
        }
      }
      return PebbleStroke(
        tool: PebbleStrokeTool.values[tool],
        colour: colour,
        size: size,
        face: face,
        points: p,
        mirror: flags & 4 != 0,
      );
    case _opFaceFill:
      return PebbleFaceFill(face: _face(r), colour: r.u32());
    case _opRegionFill:
      return PebbleRegionFill(
        face: _face(r),
        s: _q(r),
        t: _q(r),
        colour: r.u32(),
      );
    case _opStamp:
      final int flags = r.u8();
      final int stamp = r.u16();
      if (stamp >= PebbleStamps.count || flags & ~3 != 0) {
        throw const FormatException('Bad stamp');
      }
      final PebbleStampOp op = PebbleStampOp(
        mirror: flags & 1 != 0,
        flip: flags & 2 != 0,
        stamp: stamp,
        face: _face(r),
        s: _q(r),
        t: _q(r),
        size: r.u8(),
        angle: r.u8(),
        colour: r.u32(),
        ink: r.u32(),
      );
      if (op.size == 0) {
        throw const FormatException('Bad stamp');
      }
      return op;
    case _opText:
      final int face = _face(r);
      final int font = r.u8();
      final int s = _q(r);
      final int t = _q(r);
      final int size = r.u8();
      final int angle = r.u8();
      final int curve = r.i8();
      final int colour = r.u32();
      final int len = r.u8();
      if (font >= PebbleTextOp.fontCount ||
          len > PebbleTextOp.maxBytes ||
          size == 0 ||
          curve.abs() > 100) {
        throw const FormatException('Bad text');
      }
      return PebbleTextOp(
        face: face,
        font: font,
        s: s,
        t: t,
        size: size,
        angle: angle,
        curve: curve,
        colour: colour,
        text: utf8.decode(r.bytes(len)),
      );
    case _opPattern:
      final PebblePatternOp op = PebblePatternOp(
        face: _face(r),
        pattern: r.u8(),
        scale: r.u8(),
        angle: r.u8(),
        colour: r.u32(),
        colour2: r.u32(),
      );
      if (op.pattern >= PebblePattern.values.length) {
        throw const FormatException('Bad pattern');
      }
      return op;
    default:
      throw FormatException('Unknown design step $type');
  }
}

final class _Writer {
  final BytesBuilder _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v & 0xFF);

  void i8(int v) => _b.addByte(v.clamp(-128, 127) & 0xFF);

  void u16(int v) => _b
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);

  void u32(int v) => _b
    ..addByte((v >> 24) & 0xFF)
    ..addByte((v >> 16) & 0xFF)
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);

  void rgb(int v) => _b
    ..addByte((v >> 16) & 0xFF)
    ..addByte((v >> 8) & 0xFF)
    ..addByte(v & 0xFF);

  void bytes(List<int> v) => _b.add(v);

  Uint8List take() => _b.takeBytes();
}

final class _Reader {
  _Reader(this._b);

  final Uint8List _b;
  int _at = 0;

  bool get done => _at == _b.length;

  int u8() {
    if (_at >= _b.length) {
      throw const FormatException('The design ends too early');
    }
    return _b[_at++];
  }

  int i8() {
    final int v = u8();
    return v >= 128 ? v - 256 : v;
  }

  int u16() => (u8() << 8) | u8();

  int u32() => (u8() << 24) | (u8() << 16) | (u8() << 8) | u8();

  int rgb() => 0xFF000000 | (u8() << 16) | (u8() << 8) | u8();

  Uint8List bytes(int n) {
    if (_at + n > _b.length) {
      throw const FormatException('The design ends too early');
    }
    final Uint8List out = Uint8List.sublistView(_b, _at, _at + n);
    _at += n;
    return out;
  }
}
