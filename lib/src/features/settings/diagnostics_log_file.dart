import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// The name a saved copy of the log gets: `zen-dziennik-<date>-<time>.txt`.
String diagnosticsLogFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'zen-dziennik-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.txt';
}

/// Saves the whole log ([ZenDiagnosticsLog.read], both isolates) as a
/// plain file and says where it went: the system save dialog on a computer;
/// on an Android phone Downloads (through the media store, the way account
/// backups go, since the app's own `Android/data` folder is hidden from
/// every file manager since Android 11), before Android 10 and on an iPhone
/// the app's folder. Null when cancelled; throws when the file did not
/// reach the folder.
Future<AccountBackupSaved?> saveDiagnosticsLog({
  AccountBackupPlaces? places,
  AccountBackupSystem? system,
  Future<String?> Function(String name)? pickTarget,
  DateTime? now,
}) async {
  final AccountBackupSystem kind = system ?? AccountBackupSystem.current;
  final String name = diagnosticsLogFileName(now ?? DateTime.now());
  if (kind == AccountBackupSystem.desktop) {
    final String? target = await (pickTarget ?? _askOnDesktop)(name);
    if (target == null || target.isEmpty) {
      return null;
    }
    // Remembered first: the panic password deletes it too.
    await rememberExportedFile(target);
    await _write(target);
    return AccountBackupSaved(
      folder: AccountBackupFolder.directory(File(target).parent.path),
      shown: <String>[target],
      canOpen: true,
    );
  }
  final AccountBackupPlaces where =
      places ?? PlatformAccountBackupPlaces(system: kind);
  final AccountBackupFolder folder = await where.defaultFolder();
  final String first = await where.workPath(folder, name);
  try {
    if (folder.isDirect) {
      await rememberExportedFile(first);
    }
    await _write(first);
    return await where.deliver(folder, first, <String>[first]);
  } finally {
    await where.release(folder, first);
  }
}

Future<String?> _askOnDesktop(String name) => FilePicker.platform.saveFile(
  dialogTitle: t('Zapisz dziennik techniczny'),
  fileName: name,
);

Future<void> _write(String path) async {
  await ZenDiagnosticsLog.settled;
  await File(path).writeAsString(await ZenDiagnosticsLog.read(), flush: true);
}
