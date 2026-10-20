import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/core/logging/zen_log.dart';

/// Which instance of the app this is (testing on many clients): with
/// `--zen-profile=NAME` (or `ZEN_PROFILE=NAME`) a desktop app keeps its data
/// in its own folder, skips the single-instance lock and runs side by side
/// with others — each a separate person with its own keys and mesh node.
/// Without it, the app behaves as always.
abstract final class ZenInstance {
  static String? _profile;

  /// The profile name, or null for the normal app.
  static String? get profile => _profile;

  static void init(List<String> args) {
    String? name;
    for (final String a in args) {
      if (a.startsWith('--zen-profile=')) {
        name = a.substring('--zen-profile='.length);
      }
    }
    if (name == null || name.isEmpty) {
      try {
        name = Platform.environment['ZEN_PROFILE'];
      } on Object {
        name = null;
      }
    }
    final String clean = (name ?? '').replaceAll(RegExp('[^A-Za-z0-9_-]'), '');
    _profile = clean.isEmpty ? null : clean;
  }

  static Future<Directory>? _base;

  /// The app's own data folder (a sub-folder per profile).
  ///
  /// On Windows this is under `%LOCALAPPDATA%`, not the roaming profile:
  /// a roaming profile (or a profile backup restored on another computer)
  /// would copy the keys and the posting log to a second machine and fork
  /// the log without a word. Data from an older install in the roaming
  /// folder is moved over once ([migrateSupportDirectory]).
  static Future<Directory> supportDirectory() async {
    final Directory base = await _cachedBase();
    final String? p = _profile;
    if (p == null) {
      return base;
    }
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}profiles${Platform.pathSeparator}$p',
    );
    await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _cachedBase() async {
    final Future<Directory> pending = _base ??= _resolveBase();
    try {
      return await pending;
    } on Object {
      _base = null;
      rethrow;
    }
  }

  static Future<Directory> _resolveBase() async {
    final Directory base = await getApplicationSupportDirectory();
    if (!Platform.isWindows) {
      return base;
    }
    try {
      final String? local = windowsLocalPathFor(
        base.path,
        roamingRoot: Platform.environment['APPDATA'],
        localRoot: Platform.environment['LOCALAPPDATA'],
      );
      if (local == null) {
        return base;
      }
      final Directory chosen = await migrateSupportDirectory(
        roaming: base,
        local: Directory(local),
      );
      await keepSecureStorageInRoaming(roaming: base, local: Directory(local));
      return chosen;
    } on Object catch (error) {
      logZenWarning('Folder danych: zostaję przy starym miejscu ($error).');
      return base;
    }
  }

  /// Name of the file flutter_secure_storage keeps on Windows. The plugin
  /// always reads it from the roaming folder (`%APPDATA%\<company>\<app>`),
  /// whatever folder Zen uses for its data.
  static const String windowsSecureStorageFile = 'flutter_secure_storage.dat';

  /// Moving the roaming folder takes the plugin's file along; without it
  /// the app would start as a new install (no password, no keys). Puts it
  /// back in [roaming] when only [local] has it.
  @visibleForTesting
  static Future<void> keepSecureStorageInRoaming({
    required Directory roaming,
    required Directory local,
  }) async {
    final String sep = Platform.pathSeparator;
    final File inRoaming = File('${roaming.path}$sep$windowsSecureStorageFile');
    final File inLocal = File('${local.path}$sep$windowsSecureStorageFile');
    try {
      if (await inRoaming.exists() || !await inLocal.exists()) {
        return;
      }
      await roaming.create(recursive: true);
      await inLocal.copy(inRoaming.path);
    } on Object catch (error) {
      logZenWarning('Nie udało się przywrócić magazynu kluczy ($error).');
    }
  }

  /// [roamingPath] (under [roamingRoot], the roaming AppData folder)
  /// re-rooted under [localRoot] (the local AppData folder); `null` when
  /// either root is unknown or the path is not under the roaming root.
  @visibleForTesting
  static String? windowsLocalPathFor(
    String roamingPath, {
    required String? roamingRoot,
    required String? localRoot,
  }) {
    if (roamingRoot == null ||
        roamingRoot.isEmpty ||
        localRoot == null ||
        localRoot.isEmpty) {
      return null;
    }
    String trim(String path) {
      String out = path.replaceAll('/', '\\');
      while (out.length > 3 && out.endsWith('\\')) {
        out = out.substring(0, out.length - 1);
      }
      return out;
    }

    final String roaming = trim(roamingPath);
    final String root = trim(roamingRoot);
    if (roaming.length <= root.length ||
        roaming.substring(0, root.length).toLowerCase() != root.toLowerCase() ||
        roaming[root.length] != '\\') {
      return null;
    }
    return '${trim(localRoot)}${roaming.substring(root.length)}';
  }

  /// The folder to use for data that may still sit in [roaming]: [local]
  /// once it holds data; otherwise the roaming data is moved there (a
  /// rename, or a copy into a side folder that is renamed into place and
  /// only then removed from [roaming]). If moving fails, [roaming] stays
  /// in use and nothing is lost.
  @visibleForTesting
  static Future<Directory> migrateSupportDirectory({
    required Directory roaming,
    required Directory local,
  }) async {
    if (await _hasContent(local)) {
      return local;
    }
    if (!await _hasContent(roaming)) {
      await local.create(recursive: true);
      return local;
    }
    final Directory side = Directory('${local.path}.migrating');
    try {
      await local.parent.create(recursive: true);
      if (await local.exists()) {
        await local.delete();
      }
      try {
        await roaming.rename(local.path);
        return local;
      } on FileSystemException {
        // Another drive, or a file still open: copy instead.
      }
      if (await side.exists()) {
        await side.delete(recursive: true);
      }
      await _copyTree(roaming, side);
      await side.rename(local.path);
    } on Object catch (error) {
      logZenWarning(
        'Przenoszenie danych do %LOCALAPPDATA% nie udało się '
        '($error); używam starego folderu.',
      );
      try {
        if (await side.exists()) {
          await side.delete(recursive: true);
        }
      } on Object {
        // Best effort.
      }
      return roaming;
    }
    try {
      await roaming.delete(recursive: true);
    } on Object {
      // The copy in use is the local one; a leftover roaming folder (a
      // locked file) is harmless and not read again.
    }
    return local;
  }

  static Future<bool> _hasContent(Directory dir) async {
    if (!await dir.exists()) {
      return false;
    }
    await for (final FileSystemEntity _ in dir.list()) {
      return true;
    }
    return false;
  }

  static Future<void> _copyTree(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final FileSystemEntity entity in from.list(followLinks: false)) {
      final String name = entity.uri.pathSegments
          .where((String s) => s.isNotEmpty)
          .last;
      final String target = '${to.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyTree(entity, Directory(target));
      } else if (entity is File) {
        await entity.copy(target);
      }
    }
  }
}
