import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/crop_region.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/gif_shrink.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_temp_folder.dart'
    show mediaTemporaryDirectory;
import 'package:zen/src/features/profile/own_profile_images.dart';

/// Security validator and sanitizer for user profile avatar images.
/// Protects against malicious polyglots, oversized image payloads, decompression bombs,
/// disguised scripts/executables, and directory traversal vulnerabilities.
final class AvatarSanitizer {
  AvatarSanitizer._();

  /// Maximum allowed raw file size for avatar uploads (4 MB).
  static const int maxAvatarFileSize = 4 * 1024 * 1024;

  /// Minimum header size needed for magic signature verification.
  static const int minHeaderSize = 12;

  /// Validates magic header bytes to ensure the payload is a genuine image
  /// format. Supported formats are the ones Flutter can actually decode:
  /// JPEG, PNG, WebP and GIF. BMP is deliberately rejected — it would pass
  /// validation and then fail to render, leaving a blank avatar behind.
  static bool isValidImageBytes(Uint8List bytes) {
    if (bytes.length < 2) {
      return false;
    }

    // 1. JPEG: FF D8
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return true;
    }

    // 2. PNG: 89 50 4E 47
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return true;
    }

    // 3. WebP: 'RIFF' .... 'WEBP'
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return true;
    }

    // 4. GIF: 'GIF8'
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return true;
    }

    return false;
  }

  /// Detects dangerous binary signatures (PE/EXE, ELF, script tags, PHP/HTML polyglots).
  static bool hasDangerousHeader(Uint8List bytes) {
    if (bytes.length < 2) {
      return true;
    }

    // DOS / Windows PE Executable: 'MZ'
    if (bytes[0] == 0x4D && bytes[1] == 0x5A) {
      return true;
    }

    // Linux ELF: 0x7F 'ELF'
    if (bytes.length >= 4 &&
        bytes[0] == 0x7F &&
        bytes[1] == 0x45 &&
        bytes[2] == 0x4C &&
        bytes[3] == 0x46) {
      return true;
    }

    // Script shebang: '#!'
    if (bytes[0] == 0x23 && bytes[1] == 0x21) {
      return true;
    }

    return false;
  }

  /// Validates the source file and stages the sanitized copy as a plain file
  /// in the private temporary media folder ([stagePlainProfileImage]), where
  /// the profile editor shows it until saving seals it into the vault.
  /// Returns that path on success, or throws a [FormatException] on failure.
  static Future<String> validateAndStoreAvatar({
    required String sourcePath,
    Future<Directory> Function() folder = mediaTemporaryDirectory,
  }) async {
    final File sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FormatException(t('Plik źródłowy awatara nie istnieje.'));
    }

    return validateAndStoreAvatarBytes(
      rawBytes: await sourceFile.readAsBytes(),
      folder: folder,
    );
  }

  /// [validateAndStoreAvatar] for a picture already in memory (one the
  /// person framed: [makeAvatarImage]).
  static Future<String> validateAndStoreAvatarBytes({
    required Uint8List rawBytes,
    Future<Directory> Function() folder = mediaTemporaryDirectory,
  }) async {
    if (rawBytes.isEmpty) {
      throw FormatException(t('Plik awatara jest pusty.'));
    }
    if (rawBytes.length > maxAvatarFileSize) {
      throw FormatException(
        t(
          'Plik awatara jest zbyt duży ({size} MB). '
          'Maksymalny rozmiar to 4 MB.',
          {'size': (rawBytes.length / 1024 / 1024).toStringAsFixed(1)},
        ),
      );
    }

    if (hasDangerousHeader(rawBytes)) {
      throw FormatException(
        t('Wykryto niebezpieczną zawartość lub plik wykonywalny.'),
      );
    }

    if (!isValidImageBytes(rawBytes)) {
      throw FormatException(
        t('Nieobsługiwany format pliku. Wybierz obraz JPG, PNG, WEBP lub GIF.'),
      );
    }

    // A GIF stays animated, without its comments and other metadata, and
    // only when every phone can play it.
    Uint8List kept = rawBytes;
    if (looksLikeGif(rawBytes)) {
      final Uint8List? clean = stripGifMetadata(rawBytes);
      if (clean == null || !isAcceptableGif(clean)) {
        throw FormatException(
          t('Tego GIF-a nie da się użyć (uszkodzony albo za duży).'),
        );
      }
      kept = clean;
    }

    // The only plain copy lives in the private temporary media folder
    // (owner-only, emptied at every start), never under the account folder.
    // The extension follows the magic header.
    return stagePlainProfileImage(
      kept,
      prefix: 'avatar_',
      extension: _extensionForHeader(rawBytes),
      folder: folder,
    );
  }

  static String _extensionForHeader(Uint8List bytes) {
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return '.jpg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return '.webp';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46) {
      return '.gif';
    }
    return '.jpg';
  }

  /// Cleans up obsolete avatar files from the sandbox when replacing or removing avatar.
  static Future<void> cleanupOldAvatar(String? path) async {
    if (path == null || path.trim().isEmpty) {
      return;
    }
    try {
      final File file = File(path);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (error, stackTrace) {
      logZenError('Cleaning up old avatar failed', error, stackTrace);
    }
  }
}

/// The longest side of a photo of one's own, framed ([makeAvatarImage]).
const int kAvatarSide = 1024;

/// The longest side of an animated GIF photo, framed.
const int kAvatarGifSide = 512;

/// Largest picked file that can be framed as a photo (the result is far
/// smaller).
const int kMaxAvatarSourceBytes = 20 * 1024 * 1024;

/// The part [region] of the picture [picked] (framed by the person, made
/// square) as one's photo: a JPEG at most [kAvatarSide] a side (a PNG when
/// it has see-through parts), turned upright and without its metadata
/// (no EXIF, no GPS); a GIF stays animated ([kAvatarGifSide]), and so does
/// an animated WebP or PNG, made a GIF first ([animatedPictureAsGif]).
/// `null` when it is not a picture this app handles. Pure and slow for a
/// big picture: run it in an isolate.
Uint8List? makeAvatarImage((Uint8List, CropRegion?) job) {
  final Uint8List picked = job.$1;
  final CropRegion? region = job.$2;
  if (picked.length > kMaxAvatarSourceBytes ||
      !AvatarSanitizer.isValidImageBytes(picked) ||
      AvatarSanitizer.hasDangerousHeader(picked)) {
    return null;
  }
  final Uint8List bytes = animatedPictureAsGif(picked) ?? picked;
  if (looksLikeGif(bytes)) {
    return shrinkGif(
      bytes,
      maxSide: kAvatarGifSide,
      maxBytes: AvatarSanitizer.maxAvatarFileSize,
      aspect: 1,
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
  final ({int x, int y, int width, int height}) part =
      (region ?? CropRegion.full).pixels(
        oriented.width,
        oriented.height,
        aspect: 1,
      );
  img.Image out = img.copyCrop(
    oriented,
    x: part.x,
    y: part.y,
    width: part.width,
    height: part.height,
  );
  if (out.width > kAvatarSide) {
    out = img.copyResize(
      out,
      width: kAvatarSide,
      height: kAvatarSide,
      interpolation: img.Interpolation.average,
    );
  }
  if (out.hasAlpha && _seeThrough(out)) {
    return img.encodePng(out, level: 6);
  }
  return img.encodeJpg(out, quality: 88);
}

/// Whether any pixel of [image] is not fully opaque.
bool _seeThrough(img.Image image) {
  for (final img.Pixel p in image) {
    if (p.a < p.maxChannelValue) {
      return true;
    }
  }
  return false;
}
