import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

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
  /// the log without a word.
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
