import 'dart:io';

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

  /// The app's own data folder (a sub-folder per profile).
  static Future<Directory> supportDirectory() async {
    final Directory base = await getApplicationSupportDirectory();
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
}
