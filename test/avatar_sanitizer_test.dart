import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';

void main() {
  group('AvatarSanitizer Security Validation', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('avatar_sanitizer_test_');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('validates JPEG, PNG, WebP, and GIF magic headers correctly', () {
      // JPEG
      final Uint8List jpegBytes = Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        0xFF,
        0xE0,
        0x00,
        0x10,
        0x4A,
        0x46,
        0x49,
        0x46,
        0x00,
        0x01,
      ]);
      expect(AvatarSanitizer.isValidImageBytes(jpegBytes), isTrue);

      // PNG
      final Uint8List pngBytes = Uint8List.fromList(<int>[
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
        0x00,
        0x00,
        0x00,
        0x0D,
      ]);
      expect(AvatarSanitizer.isValidImageBytes(pngBytes), isTrue);

      // WebP
      final Uint8List webpBytes = Uint8List.fromList(<int>[
        0x52,
        0x49,
        0x46,
        0x46,
        0x24,
        0x00,
        0x00,
        0x00,
        0x57,
        0x45,
        0x42,
        0x50,
      ]);
      expect(AvatarSanitizer.isValidImageBytes(webpBytes), isTrue);

      // GIF
      final Uint8List gifBytes = Uint8List.fromList(<int>[
        0x47,
        0x49,
        0x46,
        0x38,
        0x39,
        0x61,
        0x01,
        0x00,
        0x01,
        0x00,
        0x80,
        0x00,
      ]);
      expect(AvatarSanitizer.isValidImageBytes(gifBytes), isTrue);
    });

    test('rejects malicious executables, scripts, and non-image payloads', () {
      // Windows PE EXE (MZ header)
      final Uint8List exeBytes = Uint8List.fromList(<int>[
        0x4D,
        0x5A,
        0x90,
        0x00,
        0x03,
        0x00,
        0x00,
        0x00,
        0x04,
        0x00,
        0x00,
        0x00,
      ]);
      expect(AvatarSanitizer.hasDangerousHeader(exeBytes), isTrue);
      expect(AvatarSanitizer.isValidImageBytes(exeBytes), isFalse);

      // Linux ELF binary
      final Uint8List elfBytes = Uint8List.fromList(<int>[
        0x7F,
        0x45,
        0x4C,
        0x46,
        0x02,
        0x01,
        0x01,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
      ]);
      expect(AvatarSanitizer.hasDangerousHeader(elfBytes), isTrue);
      expect(AvatarSanitizer.isValidImageBytes(elfBytes), isFalse);

      // Shell Script
      final Uint8List scriptBytes = Uint8List.fromList(<int>[
        0x23,
        0x21,
        0x2F,
        0x62,
        0x69,
        0x6E,
        0x2F,
        0x73,
        0x68,
        0x0A,
        0x65,
        0x63,
      ]);
      expect(AvatarSanitizer.hasDangerousHeader(scriptBytes), isTrue);
      expect(AvatarSanitizer.isValidImageBytes(scriptBytes), isFalse);

      // Random text
      final Uint8List textBytes = Uint8List.fromList(
        'hello world fake image'.codeUnits,
      );
      expect(AvatarSanitizer.isValidImageBytes(textBytes), isFalse);
    });

    test('rejects BMP because Flutter cannot render it', () {
      final Uint8List bmpBytes = Uint8List.fromList(<int>[
        0x42,
        0x4D,
        0x36,
        0x00,
        0x0C,
        0x00,
        0x00,
        0x00,
        0x00,
        0x00,
        0x36,
        0x00,
      ]);
      // Accepting it would store an avatar that silently fails to display.
      expect(AvatarSanitizer.isValidImageBytes(bmpBytes), isFalse);
    });

    test(
      'validateAndStoreAvatar stores valid image and returns sanitized path',
      () async {
        final File testSource = File('${tempDir.path}/test_source.png');
        final Uint8List pngBytes = Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
          0x00,
          0x00,
          0x00,
          0x0D,
          0x49,
          0x48,
          0x44,
          0x52,
          0x00,
          0x00,
          0x00,
          0x01,
          0x00,
          0x00,
          0x00,
          0x01,
        ]);
        await testSource.writeAsBytes(pngBytes);

        final String storedPath = await AvatarSanitizer.validateAndStoreAvatar(
          sourcePath: testSource.path,
          storageDir: tempDir,
        );

        expect(storedPath, isNotEmpty);
        expect(storedPath.endsWith('.png'), isTrue);
        expect(File(storedPath).existsSync(), isTrue);
        expect(await File(storedPath).length(), equals(pngBytes.length));
      },
    );

    test(
      'validateAndStoreAvatar throws on dangerous executable file disguised as png',
      () async {
        final File fakeImage = File('${tempDir.path}/fake_image.png');
        final Uint8List exeBytes = Uint8List.fromList(<int>[
          0x4D,
          0x5A,
          0x90,
          0x00,
          0x03,
          0x00,
          0x00,
          0x00,
          0x04,
          0x00,
          0x00,
          0x00,
        ]);
        await fakeImage.writeAsBytes(exeBytes);

        expect(
          () => AvatarSanitizer.validateAndStoreAvatar(
            sourcePath: fakeImage.path,
            storageDir: tempDir,
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('validateAndStoreAvatar throws on oversized files > 4MB', () async {
      final File oversizedFile = File('${tempDir.path}/huge.jpg');
      // Create a sparse/large dummy file (> 4MB)
      final Uint8List header = Uint8List(
        AvatarSanitizer.maxAvatarFileSize + 1024,
      );
      header[0] = 0xFF;
      header[1] = 0xD8;
      header[2] = 0xFF;
      await oversizedFile.writeAsBytes(header);

      expect(
        () => AvatarSanitizer.validateAndStoreAvatar(
          sourcePath: oversizedFile.path,
          storageDir: tempDir,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('cleanupOldAvatar safely deletes old avatar file', () async {
      final File oldAvatar = File('${tempDir.path}/old_avatar.jpg');
      await oldAvatar.writeAsString('test');
      expect(oldAvatar.existsSync(), isTrue);

      await AvatarSanitizer.cleanupOldAvatar(oldAvatar.path);
      expect(oldAvatar.existsSync(), isFalse);
    });
  });
}
