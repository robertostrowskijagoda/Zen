import 'dart:convert';
import 'dart:io';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Where [ExportedFilesIndex] keeps its list (secure storage).
const String kExportedFilesStorageKey = 'zen_rewrite_exported_files';

/// Most files remembered; the oldest are forgotten first (secure storage
/// keeps small values only).
const int kMaxRememberedExports = 64;

/// Files Zen wrote outside its own folders on purpose: a saved copy of an
/// attachment, an exported recording, a door sticker, a downloaded update.
/// They are plain files by design, so the panic password deletes them as
/// well. The list lives in the system's secure storage: the lock screen can
/// read it, a look at the disk cannot.
final class ExportedFilesIndex {
  const ExportedFilesIndex([
    this._store = const SecureStorageCredentialsStore(),
  ]);

  final AppSecurityCredentialsStore _store;

  /// The remembered paths, oldest first.
  Future<List<String>> paths() async {
    final String? raw = await _store.read(kExportedFilesStorageKey);
    if (raw == null || raw.isEmpty) {
      return const <String>[];
    }
    try {
      final Object? json = jsonDecode(raw);
      return json is List
          ? json.whereType<String>().toList(growable: false)
          : const <String>[];
    } on FormatException {
      return const <String>[];
    }
  }

  Future<void> remember(String path) async {
    final String clean = path.trim();
    if (clean.isEmpty) {
      return;
    }
    final List<String> all = <String>[
      for (final String known in await paths())
        if (known != clean) known,
      clean,
    ];
    final List<String> kept = all.length > kMaxRememberedExports
        ? all.sublist(all.length - kMaxRememberedExports)
        : all;
    await _store.write(kExportedFilesStorageKey, jsonEncode(kept));
  }

  /// Deletes every remembered file still there, then the list. Returns how
  /// many files went.
  Future<int> deleteAll() async {
    int deleted = 0;
    for (final String path in await paths()) {
      try {
        final File file = File(path);
        if (await file.exists()) {
          await file.delete();
          deleted++;
        }
      } on FileSystemException catch (error) {
        logZenWarning('Deleting an exported file failed: $error');
      }
    }
    await _store.delete(kExportedFilesStorageKey);
    return deleted;
  }
}

/// Remembers [path] for the panic wipe. Never throws: without secure
/// storage the file is only not found by the wipe.
Future<void> rememberExportedFile(
  String path, {
  ExportedFilesIndex index = const ExportedFilesIndex(),
}) async {
  try {
    await index.remember(path);
  } on Object catch (error) {
    logZenWarning('Remembering an exported file failed: $error');
  }
}
