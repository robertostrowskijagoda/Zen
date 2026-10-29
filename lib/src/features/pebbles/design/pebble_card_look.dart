import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// What a stone view needs from a pebble's public card: the look and the
/// optional 16×16 top-view thumbnail. The card (pebble_card.dart) provides
/// these, so a stone can be drawn from the card alone while the full
/// design is still on its way.
abstract interface class PebbleLookSource {
  PebbleCardLook get look;

  /// [PebbleThumbnail.bytes] bytes, or null.
  Uint8List? get thumbnail;
}

/// The part of a pebble's card that draws a recognisable stone: shape
/// preset, seed, material and two main colours. Its bytes are the card
/// format's "u8 shape preset id, u32 shape seed, u8 material preset id,
/// 3 bytes main colour RGB, 3 bytes second colour RGB" (12 bytes).
@immutable
final class PebbleCardLook implements PebbleLookSource {
  const PebbleCardLook({
    required this.shape,
    required this.seed,
    required this.material,
    required this.mainColour,
    required this.secondColour,
    this.thumbnail,
  });

  static const int byteLength = 12;

  final int shape;

  /// u32.
  final int seed;
  final int material;

  /// 0xRRGGBB.
  final int mainColour;
  final int secondColour;

  @override
  final Uint8List? thumbnail;

  @override
  PebbleCardLook get look => this;

  PebbleCardLook withThumbnail(Uint8List? thumbnail) => PebbleCardLook(
    shape: shape,
    seed: seed,
    material: material,
    mainColour: mainColour,
    secondColour: secondColour,
    thumbnail: thumbnail,
  );

  Uint8List toBytes() => Uint8List.fromList(<int>[
    shape & 0xFF,
    (seed >> 24) & 0xFF,
    (seed >> 16) & 0xFF,
    (seed >> 8) & 0xFF,
    seed & 0xFF,
    material & 0xFF,
    (mainColour >> 16) & 0xFF,
    (mainColour >> 8) & 0xFF,
    mainColour & 0xFF,
    (secondColour >> 16) & 0xFF,
    (secondColour >> 8) & 0xFF,
    secondColour & 0xFF,
  ]);

  /// Reads [byteLength] bytes of [bytes] from [offset].
  static PebbleCardLook fromBytes(Uint8List bytes, [int offset = 0]) {
    if (bytes.length < offset + byteLength) {
      throw const FormatException('The pebble look is too short');
    }
    int at(int i) => bytes[offset + i];
    return PebbleCardLook(
      shape: at(0),
      seed: (at(1) << 24) | (at(2) << 16) | (at(3) << 8) | at(4),
      material: at(5),
      mainColour: (at(6) << 16) | (at(7) << 8) | at(8),
      secondColour: (at(9) << 16) | (at(10) << 8) | at(11),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PebbleCardLook &&
      other.shape == shape &&
      other.seed == seed &&
      other.material == material &&
      other.mainColour == mainColour &&
      other.secondColour == secondColour;

  @override
  int get hashCode =>
      Object.hash(shape, seed, material, mainColour, secondColour);
}

/// The card's thumbnail: a 16×16 top view of the painted stone in 16
/// colours. 16 × 3 bytes of palette (RGB; entry 0 means transparent and is
/// stored as 0, 0, 0), then 256 pixels of 4 bits, row by row from the top
/// (the back of the stone), two pixels per byte, the left one in the high
/// nibble: 176 bytes.
abstract final class PebbleThumbnail {
  static const int side = 16;
  static const int colours = 16;
  static const int bytes = colours * 3 + side * side ~/ 2;

  /// Builds the bytes from [palette] (up to 15 opaque colours, 0xRRGGBB, for
  /// indices 1…) and [pixels] (256 indices, 0 = transparent).
  static Uint8List encode(List<int> palette, List<int> pixels) {
    assert(palette.length < colours && pixels.length == side * side);
    final Uint8List out = Uint8List(bytes);
    for (int i = 0; i < palette.length; i++) {
      out[(i + 1) * 3] = (palette[i] >> 16) & 0xFF;
      out[(i + 1) * 3 + 1] = (palette[i] >> 8) & 0xFF;
      out[(i + 1) * 3 + 2] = palette[i] & 0xFF;
    }
    for (int i = 0; i < side * side; i += 2) {
      out[colours * 3 + i ~/ 2] =
          ((pixels[i] & 15) << 4) | (pixels[i + 1] & 15);
    }
    return out;
  }

  /// The 256 pixels as 0xAARRGGBB (0 for transparent), or null when [data]
  /// is not a thumbnail.
  static Uint32List? decode(Uint8List? data) {
    if (data == null || data.length != bytes) {
      return null;
    }
    final Uint32List out = Uint32List(side * side);
    for (int i = 0; i < side * side; i++) {
      final int b = data[colours * 3 + i ~/ 2];
      final int index = i.isEven ? b >> 4 : b & 15;
      if (index != 0) {
        out[i] =
            0xFF000000 |
            (data[index * 3] << 16) |
            (data[index * 3 + 1] << 8) |
            data[index * 3 + 2];
      }
    }
    return out;
  }
}
