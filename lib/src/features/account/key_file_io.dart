import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/file_picking.dart';
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
    String? target;
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      target = await pickSavePath(
        dialogTitle: t('Zapisz plik kopii klucza'),
        fileName: name,
      );
    } else {
      final Directory? dir = Platform.isAndroid
          ? await getExternalStorageDirectory()
          : await getApplicationDocumentsDirectory();
      if (dir != null) {
        final Directory zen = Directory('${dir.path}/Zen');
        await zen.create(recursive: true);
        target = '${zen.path}/$name';
      }
    }
    if (target == null || target.isEmpty) {
      return null;
    }
    await File(target).writeAsBytes(bytes, flush: true);
    // Outside Zen's folders: the panic password deletes it too.
    await rememberExportedFile(target);
    return target;
  }

  @override
  Future<Uint8List?> pick() async {
    final String? path = await pickOnePath();
    if (path == null) {
      return null;
    }
    return File(path).readAsBytes();
  }
}

final Provider<KeyFileIo> keyFileIoProvider = Provider<KeyFileIo>(
  (Ref ref) => const PlatformKeyFileIo(),
);
