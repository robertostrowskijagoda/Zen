import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/profile/avatar_sanitizer.dart';

/// Longest side of a photo in an event's shared album (§17.1).
const int kEventPhotoSide = 1024;

/// Longest side of a flat's profile photo (§18.1).
const int kFlatPhotoSide = 320;

/// Largest compressed flat photo (it travels in every copy of the profile).
const int kMaxFlatPhotoBytes = 60 * 1024;

/// Largest compressed photo that travels between phones, in bytes.
const int kMaxSharedPhotoBytes = 240 * 1024;

/// Largest picture accepted for compressing (a photo straight from the
/// camera fits easily).
const int kMaxPhotoInputBytes = 25 * 1024 * 1024;

/// This person's own pictures: anything bigger is a decompression bomb, not
/// a photo (a 108 MP camera picture still fits).
const int _maxDimension = 12000;
const int _maxPixels = 110 * 1000 * 1000;

/// A picture from another phone was already made small there (at most
/// [kEventPhotoSide] px a side), so anything much bigger is not a photo of
/// this app: it is refused from its header, before it is decoded.
const int kMaxRemotePhotoSide = 4096;
const int kMaxRemotePhotoPixels = 16 * 1000 * 1000;

/// The same for another flat's photo (made at most [kFlatPhotoSide] px a
/// side there), which strangers send and every list shows.
const int kMaxRemoteFlatPhotoSide = 1024;
const int kMaxRemoteFlatPhotoPixels = 1024 * 1024;

/// Largest picture from another phone taken for cleaning, in bytes.
const int kMaxRemotePhotoInputBytes = 2 * kMaxSharedPhotoBytes;

bool _isJpeg(Uint8List b) => b.length > 3 && b[0] == 0xFF && b[1] == 0xD8;

bool _isPng(Uint8List b) =>
    b.length > 24 &&
    b[0] == 0x89 &&
    b[1] == 0x50 &&
    b[2] == 0x4E &&
    b[3] == 0x47;

int _be16(Uint8List b, int i) => (b[i] << 8) | b[i + 1];

int _be32(Uint8List b, int i) =>
    (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];

/// The size (width, height) the header of a JPEG or PNG claims, read
/// straight from the bytes — the image library's own header reading of a
/// JPEG already sets memory aside for the size it claims. `null` for other
/// formats and for headers that cannot be read.
(int, int)? _claimedSize(Uint8List b) {
  if (_isPng(b)) {
    // The first chunk is IHDR: width, height.
    if (b[12] != 0x49 || b[13] != 0x48 || b[14] != 0x44 || b[15] != 0x52) {
      return null;
    }
    return (_be32(b, 16), _be32(b, 20));
  }
  if (!_isJpeg(b)) {
    return null;
  }
  int i = 2;
  while (i + 3 < b.length) {
    if (b[i] != 0xFF) {
      return null;
    }
    final int marker = b[i + 1];
    if (marker == 0xFF) {
      i++; // fill byte
      continue;
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      i += 2; // a marker without a segment
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) {
      return null; // the end, or the image data, before any frame header
    }
    final int length = _be16(b, i + 2);
    if (length < 2) {
      return null;
    }
    // SOF0–SOF15, but DHT (C4), JPG (C8) and DAC (CC).
    if (marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC) {
      if (i + 8 >= b.length) {
        return null;
      }
      return (_be16(b, i + 7), _be16(b, i + 5));
    }
    i += 2 + length;
  }
  return null;
}

bool _fitsSize(int width, int height, int maxSide, int maxPixels) =>
    width > 0 &&
    height > 0 &&
    width <= maxSide &&
    height <= maxSide &&
    width * height <= maxPixels;

/// Whether the header of [bytes] (read without decoding the picture)
/// describes a picture of at most [maxSide] px a side and [maxPixels] in
/// all. `false` for anything that is not a picture.
bool photoSizeAllowed(
  Uint8List bytes, {
  int maxSide = kMaxRemotePhotoSide,
  int maxPixels = kMaxRemotePhotoPixels,
}) {
  final (int, int)? claimed = _claimedSize(bytes);
  if (claimed != null) {
    return _fitsSize(claimed.$1, claimed.$2, maxSide, maxPixels);
  }
  if (_isJpeg(bytes) || _isPng(bytes)) {
    return false;
  }
  try {
    final img.DecodeInfo? info = img
        .findDecoderForData(bytes)
        ?.startDecode(bytes);
    return info != null &&
        _fitsSize(info.width, info.height, maxSide, maxPixels);
  } on Object {
    return false;
  }
}

/// Re-encodes [bytes] as a small JPEG: turned upright, scaled down to
/// [maxSide], without EXIF/GPS. `null` for anything that is not a picture
/// this app is willing to handle. The same function cleans photos that come
/// from other phones (with the stricter [kMaxRemotePhotoSide] /
/// [kMaxRemotePhotoPixels] / [kMaxRemotePhotoInputBytes] limits, and
/// [jpegOnly]: phones of this app only ever send JPEGs), so odd bytes never
/// reach the disk or the UI's decoder. Pure: run it with `compute`.
Uint8List? compressSharedPhoto(
  Uint8List bytes, {
  int maxSide = kEventPhotoSide,
  int quality = 72,
  int maxBytes = kMaxSharedPhotoBytes,
  int maxInputBytes = kMaxPhotoInputBytes,
  int maxInputSide = _maxDimension,
  int maxInputPixels = _maxPixels,
  bool jpegOnly = false,
}) {
  if (bytes.isEmpty || bytes.length > maxInputBytes) {
    return null;
  }
  if (!AvatarSanitizer.isValidImageBytes(bytes) ||
      AvatarSanitizer.hasDangerousHeader(bytes) ||
      (jpegOnly && !_isJpeg(bytes))) {
    return null;
  }
  // The size the header claims, read before anything is decoded: a picture
  // too big to decode safely is refused before memory is set aside for it.
  final (int, int)? claimed = _claimedSize(bytes);
  if (claimed != null
      ? !_fitsSize(claimed.$1, claimed.$2, maxInputSide, maxInputPixels)
      : jpegOnly) {
    return null;
  }
  try {
    final img.Decoder? decoder = img.findDecoderForData(bytes);
    final img.DecodeInfo? info = decoder?.startDecode(bytes);
    if (decoder == null ||
        info == null ||
        (jpegOnly && decoder is! img.JpegDecoder) ||
        !_fitsSize(info.width, info.height, maxInputSide, maxInputPixels)) {
      return null;
    }
    final img.Image? decoded = decoder.decode(bytes, frame: 0);
    if (decoded == null) {
      return null;
    }
    img.Image image = img.bakeOrientation(decoded);
    final int longest = math.max(image.width, image.height);
    if (longest > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(image, width: maxSide)
          : img.copyResize(image, height: maxSide);
    }
    image.exif = img.ExifData();
    Uint8List out = img.encodeJpg(image, quality: quality);
    // A very detailed picture: try once more, smaller.
    if (out.length > maxBytes) {
      out = img.encodeJpg(
        img.copyResize(
          image,
          width: image.width >= image.height ? (maxSide * 3) ~/ 4 : null,
          height: image.width >= image.height ? null : (maxSide * 3) ~/ 4,
        ),
        quality: 60,
      );
    }
    return out.length > maxBytes ? null : out;
  } on Object {
    return null;
  }
}

/// [compressSharedPhoto] for an event album photo (for `compute`).
Uint8List? compressEventPhoto(Uint8List bytes) => compressSharedPhoto(bytes);

/// [compressSharedPhoto] for a flat's profile photo (for `compute`).
Uint8List? compressFlatPhoto(Uint8List bytes) => compressSharedPhoto(
  bytes,
  maxSide: kFlatPhotoSide,
  quality: 70,
  maxBytes: kMaxFlatPhotoBytes,
);

/// [compressEventPhoto] for an album photo from another phone, with the
/// stricter limits of pictures that come over the network (for `compute`).
Uint8List? compressRemoteEventPhoto(Uint8List bytes) => compressSharedPhoto(
  bytes,
  maxInputBytes: kMaxRemotePhotoInputBytes,
  maxInputSide: kMaxRemotePhotoSide,
  maxInputPixels: kMaxRemotePhotoPixels,
  jpegOnly: true,
);

/// [compressFlatPhoto] for another flat's photo (for `compute`).
Uint8List? compressRemoteFlatPhoto(Uint8List bytes) => compressSharedPhoto(
  bytes,
  maxSide: kFlatPhotoSide,
  quality: 70,
  maxBytes: kMaxFlatPhotoBytes,
  maxInputBytes: kMaxRemotePhotoInputBytes,
  maxInputSide: kMaxRemoteFlatPhotoSide,
  maxInputPixels: kMaxRemoteFlatPhotoPixels,
  jpegOnly: true,
);
