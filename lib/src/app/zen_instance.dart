import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// Which instance of the app this is (testing on many clients): with
/// `--zen-profile=NAME` (or `ZEN_PROFILE=NAME`) a desktop app keeps its data
/// in its own folder, skips the single-instance lock and runs side by side
/// with others — each a separate person with its own keys and mesh node.
/// Without it, the app behaves as always.
abstract final class ZenInstance {
  /// The folder, inside the default instance's data folder, that holds the
  /// data of the test profiles.
  static const String profilesFolder = 'profiles';

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

  /// The folder, inside an instance's data folder, that holds the data of
  /// its additional accounts (and the decoys among them).
  static const String accountsFolder = 'accounts';

  static Future<Directory>? _base;

  /// The folder of the additional account open in this isolate (inside
  /// [accountsFolder]); `null` for the default account.
  static String? _account;

  /// The open account's folder name; `null` for the default account.
  static String? get accountFolder => _account;

  /// Opens the account kept in [folder] (inside [accountsFolder]) for
  /// everything that asks for [supportDirectory] in this isolate; `null`
  /// opens the default account.
  static void useAccountFolder(String? folder) {
    _account = folder == null || folder.isEmpty ? null : folder;
  }

  /// For tests: the base folder instead of the platform's.
  @visibleForTesting
  static void debugSetBaseDirectory(Directory? directory) {
    _base = directory == null ? null : Future<Directory>.value(directory);
  }

  /// The open account's data folder: the instance's folder
  /// ([instanceDirectory]) for the default account, a folder in its
  /// [accountsFolder] for an additional one.
  ///
  /// On Windows this is under `%LOCALAPPDATA%`, not the roaming profile:
  /// a roaming profile (or a profile backup restored on another computer)
  /// would copy the keys and the posting log to a second machine and fork
  /// the log without a word.
  static Future<Directory> supportDirectory() async {
    final Directory instance = await instanceDirectory();
    final String? account = _account;
    if (account == null) {
      return instance;
    }
    final Directory dir = Directory(
      '${instance.path}${Platform.pathSeparator}$accountsFolder'
      '${Platform.pathSeparator}$account',
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// The app's own data folder (a sub-folder per profile): the default
  /// account's data, and the [accountsFolder] of the others.
  static Future<Directory> instanceDirectory() async {
    final Directory base = await _cachedBase();
    final String? p = _profile;
    if (p == null) {
      return base;
    }
    final Directory dir = Directory(
      '${base.path}${Platform.pathSeparator}$profilesFolder'
      '${Platform.pathSeparator}$p',
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
    // `%LOCALAPPDATA%\<company>\<app>`: the plugin's path re-rooted. The
    // `flutter_secure_storage` plugin keeps its own file in the roaming
    // folder regardless; that is left alone.
    final String? local = windowsLocalPathFor(
      base.path,
      roamingRoot: Platform.environment['APPDATA'],
      localRoot: Platform.environment['LOCALAPPDATA'],
    );
    if (local == null) {
      return base;
    }
    final Directory dir = Directory(local);
    await dir.create(recursive: true);
    return dir;
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
}
