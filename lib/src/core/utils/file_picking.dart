import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Where the person wants [fileName] saved on a computer, or `null` when
/// they closed the dialog. The dialog opens at Downloads (the person may go
/// anywhere). The picker puts an empty file there; the caller writes the
/// content (streamed or encrypted on the way, as it needs).
Future<String?> pickSavePath({
  required String fileName,
  String? dialogTitle,
}) async {
  final Uri? saved = await FilePicker.saveFile(
    fileName: fileName,
    bytes: Uint8List(0),
    dialogTitle: dialogTitle,
    initialDirectory: await _downloadsFolder(),
  );
  if (saved == null || saved.scheme != 'file') {
    return null;
  }
  final String path = saved.toFilePath();
  return path.isEmpty ? null : path;
}

/// "Zapisz jako" for a file that is ready at [sourcePath], on every
/// system: the system's own file browser, open at Downloads, asks where
/// [fileName] goes, and the file is copied there. Returns where it went (a
/// path, or a content address on Android and iOS), `null` when the person
/// closed the browser. [sourcePath] stays; the caller deletes a temporary
/// one.
Future<String?> saveFileAs({
  required String sourcePath,
  required String fileName,
  String mime = 'application/octet-stream',
  String? dialogTitle,
}) async {
  if (Platform.isAndroid) {
    final Map<String, dynamic>? saved = await const MethodChannel('zen/system')
        .invokeMapMethod<String, dynamic>('saveAs', <String, Object>{
          'path': sourcePath,
          'name': fileName,
          'mime': mime,
        });
    return saved?['uri'] as String?;
  }
  if (Platform.isIOS) {
    final Uri? saved = await FilePicker.saveFile(
      fileName: fileName,
      bytes: await File(sourcePath).readAsBytes(),
      mimeType: mime,
      dialogTitle: dialogTitle,
    );
    return saved?.toString();
  }
  final String? target = await pickSavePath(
    fileName: fileName,
    dialogTitle: dialogTitle,
  );
  if (target == null) {
    return null;
  }
  await File(sourcePath).copy(target);
  return target;
}

/// A file in the app's temporary folder for content that is written first
/// and then saved where the person says ([saveFileAs]).
Future<File> temporaryFileFor(String fileName) async {
  final Directory dir = Directory(
    '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}'
    'save-as',
  );
  await dir.create(recursive: true);
  return File('${dir.path}${Platform.pathSeparator}$fileName');
}

/// The Downloads folder where the system names one, else `null` (the
/// dialog then opens where it likes).
Future<String?> _downloadsFolder() async {
  try {
    return (await getDownloadsDirectory())?.path;
  } on Object catch (error) {
    logZenWarning('The Downloads folder is not known: $error');
    return null;
  }
}

/// The path of one file the person picks, or `null` (closed, or a file
/// with no path on this device).
Future<String?> pickOnePath({
  FileType type = FileType.any,
  String? dialogTitle,
}) async {
  final PlatformFile? picked = await FilePicker.pickFile(
    type: type,
    dialogTitle: dialogTitle,
  );
  final String? path = picked?.path?.trim();
  return path == null || path.isEmpty ? null : path;
}

/// At most [maxBytes] + 1 bytes from the start of [path], for a file Zen
/// reads whole because it was opened or picked from outside (a key
/// backup, an update). A larger file comes back cut one byte past
/// [maxBytes], which the reader that takes it refuses as damaged, and the
/// rest is never read into memory.
Future<Uint8List> readPickedFile(String path, {required int maxBytes}) async {
  final RandomAccessFile file = await File(path).open();
  try {
    final int length = await file.length();
    return await file.read(length > maxBytes ? maxBytes + 1 : length);
  } finally {
    await file.close();
  }
}

/// The size of [file] as the picker reported it, read from the file when
/// it did not; 0 when it cannot be told.
Future<int> pickedLength(PlatformFile file) async =>
    file.lengthSync() ?? await file.length() ?? 0;
