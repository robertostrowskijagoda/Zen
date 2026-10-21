import 'dart:convert';
import 'dart:io';

import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_service.dart';

/// Where [ExportedFilesIndex] keeps its list (secure storage).
const String kExportedFilesStorageKey = 'zen_rewrite_exported_files';

/// Most files remembered; the oldest are forgotten first (secure storage
/// keeps small values only).
const int kMaxRememberedExports = 64;

/// Where the device's own list of every account's exports is kept: what
/// the device wipe deletes without knowing the accounts.
const String kExportedFilesDeviceStorageKey = 'zen_rewrite_exported_files_all';

/// Most paths in the device's list.
const int kMaxRememberedDeviceExports = 256;

/// Files Zen wrote outside its own folders on purpose: a saved copy of an
/// attachment, an exported recording, a door sticker, a downloaded update.
/// They are plain files by design, so the panic password deletes them as
/// well. The list lives in the system's secure storage: the lock screen can
/// read it, a look at the disk cannot.
///
/// Two lists: the account's own (in its entries of the secret store — for
/// an additional account under a keyed name, so it says nothing about the
/// account), which wiping the account deletes; and the device's, with the
/// paths only, which the device wipe deletes whatever accounts there are
/// (the files themselves are plain on the disk anyway).
final class ExportedFilesIndex {
  const ExportedFilesIndex([
    this._store = const SecureStorageCredentialsStore(),
    this._device = const SecureStorageCredentialsStore.device(),
  ]);

  final AppSecurityCredentialsStore _store;
  final AppSecurityCredentialsStore? _device;

  /// The remembered paths, oldest first.
  Future<List<String>> paths() => _read(_store, kExportedFilesStorageKey);

  static Future<List<String>> _read(
    AppSecurityCredentialsStore store,
    String key,
  ) async {
    final String? raw = await store.read(key);
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

  static Future<void> _add(
    AppSecurityCredentialsStore store,
    String key,
    String path,
    int max,
  ) async {
    final List<String> all = <String>[
      for (final String known in await _read(store, key))
        if (known != path) known,
      path,
    ];
    final List<String> kept = all.length > max
        ? all.sublist(all.length - max)
        : all;
    await store.write(key, jsonEncode(kept));
  }

  Future<void> remember(String path) async {
    final String clean = path.trim();
    if (clean.isEmpty) {
      return;
    }
    await _add(_store, kExportedFilesStorageKey, clean, kMaxRememberedExports);
    final AppSecurityCredentialsStore? device = _device;
    if (device == null) {
      return;
    }
    try {
      await _add(
        device,
        kExportedFilesDeviceStorageKey,
        clean,
        kMaxRememberedDeviceExports,
      );
    } on Object catch (error) {
      logZenWarning('Remembering an export for the device failed: $error');
    }
  }

  /// Deletes every remembered file of this account still there, then its
  /// list (and its paths from the device's list). Returns how many files
  /// went.
  Future<int> deleteAll() async {
    final List<String> mine = await paths();
    final int deleted = await _deleteFiles(mine);
    await _store.delete(kExportedFilesStorageKey);
    final AppSecurityCredentialsStore? device = _device;
    if (device != null && mine.isNotEmpty) {
      try {
        final Set<String> gone = mine.toSet();
        final List<String> rest = <String>[
          for (final String p in await _read(
            device,
            kExportedFilesDeviceStorageKey,
          ))
            if (!gone.contains(p)) p,
        ];
        if (rest.isEmpty) {
          await device.delete(kExportedFilesDeviceStorageKey);
        } else {
          await device.write(kExportedFilesDeviceStorageKey, jsonEncode(rest));
        }
      } on Object catch (error) {
        logZenWarning('Updating the device exports failed: $error');
      }
    }
    return deleted;
  }

  /// The device wipe: every file any account on this device exported,
  /// then the device's list. Returns how many files went.
  static Future<int> deleteEveryAccount([
    AppSecurityCredentialsStore device =
        const SecureStorageCredentialsStore.device(),
  ]) async {
    final int deleted = await _deleteFiles(
      await _read(device, kExportedFilesDeviceStorageKey),
    );
    await device.delete(kExportedFilesDeviceStorageKey);
    return deleted;
  }

  static Future<int> _deleteFiles(Iterable<String> paths) async {
    int deleted = 0;
    for (final String path in paths) {
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
