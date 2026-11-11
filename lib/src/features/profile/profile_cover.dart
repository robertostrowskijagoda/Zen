import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/media/crop_region.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/media/media_temp_folder.dart'
    show mediaTemporaryDirectory;
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';

/// The cover photo behind the profile header: a 3:1 JPEG, at most
/// [kCoverWidth] wide. Re-encoded, so nothing but pixels leaves the device
/// (no EXIF, no GPS).
const int kCoverWidth = 1500;
const int kCoverHeight = 500;

/// Largest picked file accepted for a cover (the result is far smaller).
const int kMaxCoverSourceBytes = 20 * 1024 * 1024;

/// A GIF cover stays animated: 3:1, at most this wide and [kMaxCoverGifBytes]
/// (it travels like a post's photo).
const int kCoverGifWidth = 600;
const int kMaxCoverGifBytes = 3 * 1024 * 1024;

/// A cropped, scaled JPEG of [picked] (a GIF: a cropped, scaled GIF that
/// still plays; an animated WebP or PNG is made a GIF first), or `null`
/// when it is not an image this app is willing to handle: the part
/// [region] names (framed by the person, made 3:1), or the middle band.
/// Runs in an isolate.
Uint8List? makeCoverImage(Uint8List picked, {CropRegion? region}) {
  if (picked.length > kMaxCoverSourceBytes ||
      !AvatarSanitizer.isValidImageBytes(picked) ||
      AvatarSanitizer.hasDangerousHeader(picked)) {
    return null;
  }
  final Uint8List bytes = animatedPictureAsGif(picked) ?? picked;
  if (looksLikeGif(bytes)) {
    return shrinkGif(
      bytes,
      maxSide: kCoverGifWidth,
      maxBytes: kMaxCoverGifBytes,
      aspect: kCoverWidth / kCoverHeight,
      region: region,
    );
  }
  final img.Decoder? decoder = img.findDecoderForData(bytes);
  final img.DecodeInfo? info = decoder?.startDecode(bytes);
  if (decoder == null ||
      info == null ||
      info.width <= 0 ||
      info.height <= 0 ||
      info.width > 12000 ||
      info.height > 12000) {
    return null;
  }
  final img.Image? decoded = decoder.decode(bytes, frame: 0);
  if (decoded == null) {
    return null;
  }
  final img.Image oriented = img.bakeOrientation(decoded);
  // Crop the framed part (or the middle band) at 3:1, then scale down.
  final int w = oriented.width;
  final int h = oriented.height;
  final ({int x, int y, int width, int height}) part;
  if (region != null && !region.isFull) {
    part = region.pixels(w, h, aspect: kCoverWidth / kCoverHeight);
  } else {
    int cw = w;
    int ch = (w / 3).round();
    if (ch > h) {
      ch = h;
      cw = h * 3;
    }
    part = (x: (w - cw) ~/ 2, y: (h - ch) ~/ 2, width: cw, height: ch);
  }
  final int cw = part.width;
  final img.Image band = img.copyCrop(
    oriented,
    x: part.x,
    y: part.y,
    width: part.width,
    height: part.height,
  );
  final img.Image scaled = cw > kCoverWidth
      ? img.copyResize(
          band,
          width: kCoverWidth,
          height: (kCoverWidth * band.height / band.width).round(),
        )
      : band;
  return img.encodeJpg(scaled, quality: 82);
}

/// Prepares the picked file at [sourcePath] and stages it as a plain file in
/// the private temporary media folder ([stagePlainProfileImage]); returns the
/// new path. Throws [FormatException] with a message for the
/// user when the file is not a usable picture.
Future<String> storeCoverImage({
  required String sourcePath,
  Future<Directory> Function() folder = mediaTemporaryDirectory,
  CropRegion? region,
}) async {
  final File source = File(sourcePath);
  if (!source.existsSync() || source.lengthSync() > kMaxCoverSourceBytes) {
    throw FormatException(
      t(
        'To zdjęcie jest za duże albo nie da się go otworzyć (najwyżej 20 MB).',
      ),
    );
  }
  return storeCoverBytes(
    bytes: await source.readAsBytes(),
    folder: folder,
    region: region,
  );
}

/// [storeCoverImage] for a picture already in memory (a GIF from the search
/// or the keyboard).
Future<String> storeCoverBytes({
  required Uint8List bytes,
  Future<Directory> Function() folder = mediaTemporaryDirectory,
  CropRegion? region,
}) async {
  if (bytes.length > kMaxCoverSourceBytes) {
    throw FormatException(
      t(
        'To zdjęcie jest za duże albo nie da się go otworzyć (najwyżej 20 MB).',
      ),
    );
  }
  final Uint8List? cover = await compute(_makeCover, (bytes, region));
  if (cover == null) {
    throw FormatException(
      t('To nie wygląda na zdjęcie (obsługiwane: JPEG, PNG, WebP, GIF).'),
    );
  }
  // Never under the account folder: the only plain copy is in the private
  // temporary media folder, which every start empties.
  return stagePlainProfileImage(
    cover,
    prefix: 'cover_',
    extension: looksLikeGif(cover) ? '.gif' : '.jpg',
    folder: folder,
  );
}

Uint8List? _makeCover((Uint8List, CropRegion?) job) =>
    makeCoverImage(job.$1, region: job.$2);

/// Removes a cover written by [storeCoverImage], or the vault copy it was
/// moved into. Ignores anything else.
Future<void> deleteCoverImage(String? path) => deleteOwnProfileImage(path);
