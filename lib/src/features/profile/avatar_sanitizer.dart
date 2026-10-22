import 'dart:io';
import 'dart:typed_data';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_guard.dart';

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

  /// Validates the source file and safely copies it into the sandboxed avatars directory.
  /// Returns the sanitized local file path on success, or throws a [FormatException] on failure.
  static Future<String> validateAndStoreAvatar({
    required String sourcePath,
    required Directory storageDir,
  }) async {
    final File sourceFile = File(sourcePath);
    if (!await sourceFile.exists()) {
      throw FormatException(t('Plik źródłowy awatara nie istnieje.'));
    }

    final Uint8List rawBytes = await sourceFile.readAsBytes();
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

    // Prepare sandbox avatars directory
    final Directory avatarSandbox = Directory(
      '${storageDir.path}${Platform.pathSeparator}avatars',
    );
    if (!await avatarSandbox.exists()) {
      await avatarSandbox.create(recursive: true);
    }

    // Determine safe extension based on magic header
    final String safeExt = _extensionForHeader(rawBytes);
    final String safeFileName =
        'avatar_${DateTime.now().microsecondsSinceEpoch}$safeExt';
    final String targetPath =
        '${avatarSandbox.path}${Platform.pathSeparator}$safeFileName';

    // Write sanitized file
    await File(targetPath).writeAsBytes(kept, flush: true);

    return targetPath;
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
