import 'dart:io';
import 'dart:math';

/// Replaces [file]'s contents with [bytes] so that a reader — in this
/// isolate, in another one (the Android app and its background service
/// share one process) or after a crash — finds either the old or the new
/// contents, never part of them.
///
/// The bytes go to a temporary file with a name of its own (two writers at
/// once never write into the same temporary file: with one fixed name, as
/// before, their bytes mixed in it and the mix was moved into place),
/// flushed to the disk, then moved over [file] in one rename. Should the
/// rename keep failing (Windows, while a scanner holds the file), the bytes
/// are written to [file] directly. A failed write leaves nothing behind.
Future<void> writeFileAtomically(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final File temporary = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.'
    '${_random.nextInt(1 << 32)}.tmp',
  );
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    for (int attempt = 0; ; attempt++) {
      try {
        await temporary.rename(file.path);
        return;
      } on FileSystemException {
        if (attempt >= 4) {
          break;
        }
        await Future<void>.delayed(Duration(milliseconds: 25 * (attempt + 1)));
      }
    }
    await file.writeAsBytes(bytes, flush: true);
  } finally {
    try {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    } on FileSystemException {
      // Left for the next sweep.
    }
  }
}

final Random _random = Random();
