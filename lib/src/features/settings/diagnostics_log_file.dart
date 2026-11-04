import 'dart:convert';
import 'dart:io';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/file_picking.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// The name a saved copy of the log gets:
/// `zen-dziennik-<date>-<time to the second>.txt` (a second copy saved
/// within the same minute no longer replaces the first).
String diagnosticsLogFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'zen-dziennik-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}.txt';
}

/// The saved file's bytes: UTF-8 with its byte order mark, without which
/// Windows' Notepad and PowerShell read the file as the local code page
/// and show "…", "—" and Polish letters as garbage.
List<int> diagnosticsLogFileBytes(String text) => <int>[
  0xEF,
  0xBB,
  0xBF,
  ...utf8.encode(text),
];

/// Saves the whole log ([ZenDiagnosticsLog.read], both isolates) as a
/// plain file and says where it went. The person always says where: the
/// system's save dialog on a computer, its file browser open at Downloads
/// on a phone ([saveAsWritten]). Null when cancelled; throws when the file
/// did not get there.
Future<AccountBackupSaved?> saveDiagnosticsLog({
  AccountBackupSystem? system,
  Future<String?> Function(String name)? pickTarget,
  Future<String?> Function(String name, Future<void> Function(File file) write)?
  saveAs,
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
  final String? saved = await (saveAs ?? _askOnPhone)(
    name,
    (File file) => _write(file.path),
  );
  if (saved == null || saved.isEmpty) {
    return null;
  }
  // A content address on a phone: the person is told the file's name.
  return AccountBackupSaved(
    folder: AccountBackupFolder.downloads(),
    shown: <String>[name],
  );
}

Future<String?> _askOnPhone(
  String name,
  Future<void> Function(File file) write,
) => saveAsWritten(
  fileName: name,
  dialogTitle: t('Zapisz dziennik techniczny'),
  mime: 'text/plain',
  write: write,
);

Future<String?> _askOnDesktop(String name) =>
    pickSavePath(dialogTitle: t('Zapisz dziennik techniczny'), fileName: name);

Future<void> _write(String path) async {
  await ZenDiagnosticsLog.settled;
  await File(path).writeAsBytes(
    diagnosticsLogFileBytes(await ZenDiagnosticsLog.read()),
    flush: true,
  );
}
