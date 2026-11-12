import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/file_picking.dart';
import 'package:zen/src/features/account/key_file.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// Where the backup file is saved and read from (replaced in tests).
abstract interface class KeyFileIo {
  /// Saves [bytes] as [name]: the system save dialog on a computer, the
  /// app's `Zen` folder on a phone. Returns the path, or `null` when the
  /// person cancelled.
  Future<String?> save(String name, Uint8List bytes);

  /// Lets the person pick a backup file; `null` when they cancelled.
  Future<Uint8List?> pick();
}

/// The real [KeyFileIo].
final class PlatformKeyFileIo implements KeyFileIo {
  const PlatformKeyFileIo();

  @override
  Future<String?> save(String name, Uint8List bytes) async {
    // "Zapisz jako", open at Downloads, on every system; outside Zen's
    // folders, so the panic password deletes it too.
    final String? target = await saveAsWritten(
      fileName: name,
      dialogTitle: t('Zapisz plik kopii klucza'),
      write: (File file) => file.writeAsBytes(bytes, flush: true),
    );
    return target == null || target.isEmpty ? null : target;
  }

  @override
  Future<Uint8List?> pick() async {
    final String? path = await pickOnePath();
    if (path == null) {
      return null;
    }
    return readPickedFile(path, maxBytes: kMaxKeyFileReadBytes);
  }
}

final Provider<KeyFileIo> keyFileIoProvider = Provider<KeyFileIo>(
  (Ref ref) => const PlatformKeyFileIo(),
);
