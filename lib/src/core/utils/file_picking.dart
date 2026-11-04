import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Where the person wants [fileName] saved on a computer, or `null` when
/// they closed the dialog. The picker puts an empty file there; the caller
/// writes the content (streamed or encrypted on the way, as it needs).
Future<String?> pickSavePath({
  required String fileName,
  String? dialogTitle,
}) async {
  final Uri? saved = await FilePicker.saveFile(
    fileName: fileName,
    bytes: Uint8List(0),
    dialogTitle: dialogTitle,
  );
  if (saved == null || saved.scheme != 'file') {
    return null;
  }
  final String path = saved.toFilePath();
  return path.isEmpty ? null : path;
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

/// The size of [file] as the picker reported it, read from the file when
/// it did not; 0 when it cannot be told.
Future<int> pickedLength(PlatformFile file) async =>
    file.lengthSync() ?? await file.length() ?? 0;
