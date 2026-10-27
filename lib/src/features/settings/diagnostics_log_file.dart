import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// The name a saved copy of the log gets: `zen-dziennik-<date>-<time>.txt`.
String diagnosticsLogFileName(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return 'zen-dziennik-${now.year}${two(now.month)}${two(now.day)}-'
      '${two(now.hour)}${two(now.minute)}.txt';
}

/// Saves the whole log ([ZenDiagnosticsLog.read], both isolates) as a
/// plain file: the system save dialog on a computer, the app's `Zen` folder
/// on a phone (on Android `Android/data/<app>/files/Zen`, which a cable or
/// `adb pull` reaches in every build). The path, or null when cancelled.
Future<String?> saveDiagnosticsLog() async {
  final String name = diagnosticsLogFileName(DateTime.now());
  String? target;
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    target = await FilePicker.platform.saveFile(
      dialogTitle: t('Zapisz dziennik techniczny'),
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
  // Remembered first: the panic password deletes it too.
  await rememberExportedFile(target);
  await ZenDiagnosticsLog.settled;
  await File(target).writeAsString(await ZenDiagnosticsLog.read(), flush: true);
  return target;
}
