import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/features/profile/avatar_sanitizer.dart';

/// The cover photo behind the profile header (§9): a 3:1 JPEG, at most
/// [kCoverWidth] wide. Re-encoded, so nothing but pixels leaves the device
/// (no EXIF, no GPS).
const int kCoverWidth = 1500;
const int kCoverHeight = 500;

/// Largest picked file accepted for a cover (the result is far smaller).
const int kMaxCoverSourceBytes = 20 * 1024 * 1024;

/// A cropped, scaled JPEG of [bytes], or `null` when it is not an image this
/// app is willing to handle. Runs in an isolate.
Uint8List? makeCoverImage(Uint8List bytes) {
  if (bytes.length > kMaxCoverSourceBytes ||
      !AvatarSanitizer.isValidImageBytes(bytes) ||
      AvatarSanitizer.hasDangerousHeader(bytes)) {
    return null;
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
  // Crop the middle band at 3:1, then scale down.
  final int w = oriented.width;
  final int h = oriented.height;
  int cw = w;
  int ch = (w / 3).round();
  if (ch > h) {
    ch = h;
    cw = h * 3;
  }
  final img.Image band = img.copyCrop(
    oriented,
    x: (w - cw) ~/ 2,
    y: (h - ch) ~/ 2,
    width: cw,
    height: ch,
  );
  final img.Image scaled = cw > kCoverWidth
      ? img.copyResize(band, width: kCoverWidth, height: kCoverHeight)
      : band;
  return img.encodeJpg(scaled, quality: 82);
}

/// Prepares the picked file at [sourcePath] and stores it in [storageDir];
/// returns the new path. Throws [FormatException] with a message for the
/// user when the file is not a usable picture.
Future<String> storeCoverImage({
  required String sourcePath,
  required Directory storageDir,
}) async {
  final File source = File(sourcePath);
  if (!source.existsSync() || source.lengthSync() > kMaxCoverSourceBytes) {
    throw const FormatException(
      'To zdjęcie jest za duże albo nie da się go otworzyć (najwyżej 20 MB).',
    );
  }
  final Uint8List? cover = await compute(
    makeCoverImage,
    await source.readAsBytes(),
  );
  if (cover == null) {
    throw const FormatException(
      'To nie wygląda na zdjęcie (obsługiwane: JPEG, PNG, WebP, GIF).',
    );
  }
  final Directory dir = Directory(
    '${storageDir.path}${Platform.pathSeparator}profile',
  )..createSync(recursive: true);
  final File out = File(
    '${dir.path}${Platform.pathSeparator}'
    'cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
  );
  await out.writeAsBytes(cover, flush: true);
  return out.path;
}

/// Removes a cover written by [storeCoverImage] (ignores anything else).
Future<void> deleteCoverImage(String? path) async {
  if (path == null || !path.contains('cover_')) {
    return;
  }
  final File f = File(path);
  if (f.existsSync()) {
    await f.delete();
  }
}
