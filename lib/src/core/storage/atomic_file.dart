import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Replaces [file]'s contents with [bytes] so that a reader — in this
/// isolate, in another one (the Android app and its background service
/// share one process) or after a crash — finds either the old or the new
/// contents, never part of them.
///
/// The bytes go to a temporary file with a name of its own (two writers at
/// once never write into the same temporary file: with one fixed name, as
/// before, their bytes mixed in it and the mix was moved into place),
/// flushed to the disk, then moved over [file] in one rename.
///
/// On Windows that rename fails while anyone has [file] open: another
/// isolate reading it, another writer's rename, a scanner. It is tried
/// again, at growing and slightly random intervals so two writers do not
/// keep meeting, for up to [atomicRenameBudget] (it used to give up after a
/// quarter of a second, and a busy machine then wrote over [file] in place:
/// a reader at that moment found it empty). Only a file held for longer than
/// that gets the bytes written straight into it, with a warning in the log.
/// A failed write leaves nothing behind.
Future<void> writeFileAtomically(File file, List<int> bytes) async {
  await file.parent.create(recursive: true);
  final File temporary = File(
    '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$pid.'
    '${_random.nextInt(1 << 32)}.tmp',
  );
  try {
    await temporary.writeAsBytes(bytes, flush: true);
    final Stopwatch waited = Stopwatch()..start();
    FileSystemException? last;
    for (int attempt = 0; ; attempt++) {
      try {
        await atomicRename(temporary, file.path);
        return;
      } on FileSystemException catch (error) {
        last = error;
      }
      if (waited.elapsed >= atomicRenameBudget) {
        break;
      }
      await Future<void>.delayed(_retryDelay(attempt));
    }
    logZenWarning(
      'Saving ${file.uri.pathSegments.last} in one move failed for '
      '${waited.elapsedMilliseconds} ms (${last.osError?.message ?? last.message}); '
      'writing it in place.',
    );
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

/// How long a save keeps trying to move its bytes over a file someone
/// holds open before it writes into the file in place.
@visibleForTesting
Duration atomicRenameBudget = const Duration(seconds: 3);

/// The move of the temporary file over the saved one (tests make it fail).
@visibleForTesting
Future<void> Function(File temporary, String path) atomicRename = _renameOver;

/// Puts [atomicRenameBudget] and [atomicRename] back.
@visibleForTesting
void resetAtomicFileForTest() {
  atomicRenameBudget = const Duration(seconds: 3);
  atomicRename = _renameOver;
}

Future<void> _renameOver(File temporary, String path) async {
  await temporary.rename(path);
}

/// 5, 10, 20, 40, 80, 160 ms, then 250 ms, each plus up to half again at
/// random.
Duration _retryDelay(int attempt) {
  final int base = min(250, 5 << min(attempt, 6));
  return Duration(milliseconds: base + _random.nextInt(base ~/ 2 + 1));
}

final Random _random = Random();
