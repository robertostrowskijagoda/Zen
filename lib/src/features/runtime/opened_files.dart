import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/single_instance_guard.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/key_file.dart';
import 'package:zen/src/features/update/release.dart';

/// What a file opened in Zen from outside is.
enum ZenOpenedFileKind {
  /// The whole account (`.zenbackup`): "Mam kopię".
  accountBackup,

  /// The account key alone (`.zenkey`): "Przywróć klucz".
  keyFile,

  /// A release with its files (`.zenupdate`): "Aktualizacje".
  update,

  /// Not one of Zen's files, or it could not be read.
  other,
}

/// A file the system handed to Zen: a tap in Files, a mail or a chat,
/// "Otwórz za pomocą" on a computer.
@immutable
final class ZenOpenedFile {
  const ZenOpenedFile({required this.kind, required this.path});

  final ZenOpenedFileKind kind;

  /// The file to read: a copy in the app's cache on a phone, the file
  /// itself on a computer. `null` when it could not be read.
  final String? path;
}

/// Extension of an update file (release.dart, [ReleaseBundle]).
const String kUpdateFileExtension = 'zenupdate';

/// key_file.dart's magic (private there).
const String _keyFileMagic = 'ZENKEY';

/// What [name] with first bytes [head] is: by its magic, else by its
/// name (a damaged copy still opens its screen, which tells what is
/// wrong; a backup's later parts have no magic of their own).
ZenOpenedFileKind zenOpenedFileKindOf(String name, List<int> head) {
  bool startsWith(List<int> magic) {
    if (head.length < magic.length) {
      return false;
    }
    for (int i = 0; i < magic.length; i++) {
      if (head[i] != magic[i]) {
        return false;
      }
    }
    return true;
  }

  // ZENACCT and its version digit: a newer backup is still a backup (its
  // screen says it needs a newer Zen).
  if (startsWith(ascii.encode(kAccountBackupMagic.substring(0, 7)))) {
    return ZenOpenedFileKind.accountBackup;
  }
  if (startsWith(ascii.encode(_keyFileMagic))) {
    return ZenOpenedFileKind.keyFile;
  }
  if (startsWith(ReleaseBundle.magic)) {
    return ZenOpenedFileKind.update;
  }
  final String lower = name.toLowerCase();
  if (RegExp(
    '\\.${RegExp.escape(kAccountBackupExtension)}(\\.\\d+)?\$',
  ).hasMatch(lower)) {
    return ZenOpenedFileKind.accountBackup;
  }
  if (lower.endsWith('.$kKeyFileExtension')) {
    return ZenOpenedFileKind.keyFile;
  }
  if (lower.endsWith('.$kUpdateFileExtension')) {
    return ZenOpenedFileKind.update;
  }
  return ZenOpenedFileKind.other;
}

/// The file a link from app_links stands for: a content address as it is
/// (Android), a file address or a bare absolute path as a path (Linux
/// passes what the file manager gave). `null` for a real link (zen://,
/// https).
String? zenOpenedFileOfLink(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme == 'content') {
    return uri.toString();
  }
  if (scheme == 'file' || (scheme.isEmpty && uri.path.startsWith('/'))) {
    try {
      return uri.toFilePath(windows: false);
    } on UnsupportedError {
      return null;
    }
  }
  return null;
}

/// Whether [uri] from app_links is a file, not a link to follow.
bool isZenOpenedFileLink(Uri uri) => zenOpenedFileOfLink(uri) != null;

/// The file a computer started Zen with ("Otwórz za pomocą", a double
/// click once Zen is the program for the file): the first argument that is
/// an absolute path. The options (`--zen-profile=…`) are not files.
String? zenOpenedFileArgument(List<String> args) {
  for (final String arg in args) {
    if (arg.startsWith('-')) {
      continue;
    }
    final bool absolute =
        arg.startsWith('/') ||
        arg.startsWith(r'\\') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(arg);
    if (absolute) {
      return arg;
    }
  }
  return null;
}

/// Makes a local, readable file of what was opened.
abstract interface class OpenedFileReader {
  /// The path to read for [file] (a content address or a path); `null`
  /// when it cannot be read.
  Future<String?> localPath(String file);
}

/// The real [OpenedFileReader]: a content address is copied into the
/// cache by `zen/system` (ZenSystemBridge.kt); a path is read where it is
/// (a backup's other parts lie next to it).
final class PlatformOpenedFileReader implements OpenedFileReader {
  const PlatformOpenedFileReader();

  static const MethodChannel _system = MethodChannel('zen/system');

  @override
  Future<String?> localPath(String file) async {
    if (file.toLowerCase().startsWith('content:')) {
      final Map<String, Object?>? copied = await _system
          .invokeMapMethod<String, Object?>('copyOpenedFile', <String, Object?>{
            'uri': file,
          });
      return copied?['path'] as String?;
    }
    return await File(file).exists() ? file : null;
  }
}

/// The files opened in Zen while it runs, from the system's hand-over to
/// the screen that takes them (`OpenedFileBridge`).
///
/// One per process, started in `main` before anything else listens to
/// app_links: it gets the file Zen was started with as well, and keeps
/// listening while Zen is locked (the screens below the lock are gone
/// then; the file waits here until it is unlocked). Only the newest file
/// waits.
final class ZenOpenedFiles extends ChangeNotifier {
  ZenOpenedFiles({
    OpenedFileReader reader = const PlatformOpenedFileReader(),
    DateTime Function()? now,
  }) : _reader = reader,
       _now = now ?? DateTime.now;

  static final ZenOpenedFiles instance = ZenOpenedFiles();

  /// The same file handed over twice in a row this soon is one opening
  /// (app_links may give the launch file both as the first link and on
  /// request).
  static const Duration repeatWindow = Duration(seconds: 3);

  /// iPhone and Mac: the files the app delegate took (AppDelegate.swift,
  /// SceneDelegate.swift), as local paths.
  static const MethodChannel _darwin = MethodChannel('zen/opened_files');

  final OpenedFileReader _reader;
  final DateTime Function() _now;

  ZenOpenedFile? _pending;
  String? _last;
  DateTime? _lastAt;
  bool _started = false;
  StreamSubscription<Uri>? _links;

  /// The file waiting for its screen.
  ZenOpenedFile? get pending => _pending;

  /// Takes the waiting file (once).
  ZenOpenedFile? take() {
    final ZenOpenedFile? file = _pending;
    _pending = null;
    return file;
  }

  /// Starts listening (once per process). [args]: `main`'s arguments.
  void start(List<String> args) {
    if (_started || kIsWeb) {
      return;
    }
    _started = true;
    if (Platform.isAndroid || Platform.isLinux) {
      // Android: content addresses (ZenOpenFileActivity.kt). Linux: the
      // file manager's argument, also from a second launch (GApplication
      // passes it to the running one). The same stream as
      // runtime_deep_link_bridge.dart: AppLinks shares one platform
      // listener among its listeners.
      _links = AppLinks().uriLinkStream.listen(
        (Uri uri) {
          final String? file = zenOpenedFileOfLink(uri);
          if (file != null) {
            unawaitedLogged(offer(file), context: 'Opening a file failed');
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          logZenError('Opened-file link stream error', error, stackTrace);
        },
      );
    } else if (Platform.isIOS || Platform.isMacOS) {
      _darwin.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'opened') {
          await _takeDarwin();
        }
        return null;
      });
      unawaitedLogged(_takeDarwin(), context: 'Taking opened files failed');
    } else if (Platform.isWindows) {
      // A file opened while Zen runs starts a second launch, which hands
      // it over before it quits (single_instance_guard.dart).
      ZenSingleInstance.setOpenHandler(offer);
      final String? file = zenOpenedFileArgument(args);
      if (file != null) {
        unawaitedLogged(offer(file), context: 'Opening a file failed');
      }
    }
  }

  Future<void> _takeDarwin() async {
    final List<String>? paths = await _darwin.invokeListMethod<String>('take');
    for (final String path in paths ?? const <String>[]) {
      await offer(path);
    }
  }

  /// Reads [file] (a content address or a path) and lets it wait for its
  /// screen.
  Future<void> offer(String file) async {
    final DateTime now = _now();
    final DateTime? lastAt = _lastAt;
    if (file == _last &&
        lastAt != null &&
        now.difference(lastAt) < repeatWindow) {
      return;
    }
    _last = file;
    _lastAt = now;
    String? path;
    try {
      path = await _reader.localPath(file);
    } on Object catch (error, stackTrace) {
      logZenError('Reading an opened file failed', error, stackTrace);
    }
    ZenOpenedFileKind kind = ZenOpenedFileKind.other;
    if (path != null) {
      try {
        kind = zenOpenedFileKindOf(path, await _head(path));
      } on FileSystemException catch (error, stackTrace) {
        logZenError('Reading an opened file failed', error, stackTrace);
        path = null;
      }
    }
    // The kind only: the name may say whose file it is.
    logZenMessage('A file was opened in Zen: ${kind.name}');
    _pending = ZenOpenedFile(kind: kind, path: path);
    notifyListeners();
  }

  static Future<List<int>> _head(String path) async {
    final RandomAccessFile file = await File(path).open();
    try {
      return await file.read(16);
    } finally {
      await file.close();
    }
  }

  @override
  void dispose() {
    unawaitedLogged(
      _links?.cancel(),
      context: 'Opened-file subscription cancellation failed',
    );
    _links = null;
    super.dispose();
  }
}

/// The process's [ZenOpenedFiles] (replaced in tests).
final Provider<ZenOpenedFiles> zenOpenedFilesProvider =
    Provider<ZenOpenedFiles>((Ref ref) => ZenOpenedFiles.instance);
