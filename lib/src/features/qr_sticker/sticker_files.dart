import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/windows_system_paths.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// Where a finished sticker goes: a file (Downloads on Android and on a
/// computer, the Files app on an iPhone), the share sheet and the system's
/// printing (Android). Replaced in tests.
abstract interface class StickerOutlet {
  /// The share sheet is there.
  bool get canShare;

  /// The system's printing is there.
  bool get canPrint;

  /// Saving opens the saved file afterwards on request ([open]).
  bool get canOpen;

  /// Saves [bytes] as [name]; where it went as the person is told of it,
  /// or null when they cancelled.
  Future<String?> save(String name, Uint8List bytes, String mime);

  /// Opens the share sheet with [bytes] as [name]; false when it could not.
  Future<bool> share(String name, Uint8List bytes, String mime);

  /// Hands the PDF [pdf] to the system's printing; false when it could not.
  Future<bool> printPdf(String name, Uint8List pdf);

  /// Opens the file [saved] (what [save] answered) in the system's viewer,
  /// where it can be printed.
  Future<bool> open(String saved);
}

/// The real [StickerOutlet] (the Android side is ZenSystemBridge.kt).
final class PlatformStickerOutlet implements StickerOutlet {
  const PlatformStickerOutlet([
    this._channel = const MethodChannel('zen/system'),
  ]);

  final MethodChannel _channel;

  static bool get _desktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  @override
  bool get canShare => Platform.isAndroid;

  @override
  bool get canPrint => Platform.isAndroid;

  @override
  bool get canOpen => _desktop;

  @override
  Future<String?> save(String name, Uint8List bytes, String mime) async {
    if (_desktop) {
      final String? target = await FilePicker.platform.saveFile(
        dialogTitle: t('Zapisz naklejkę'),
        fileName: name,
      );
      if (target == null || target.isEmpty) {
        return null;
      }
      return _write(target, bytes);
    }
    if (Platform.isAndroid) {
      final int sdk = await _channel.invokeMethod<int>('sdkInt') ?? 0;
      if (sdk >= kAndroidDownloadsWithoutPermissionSdk) {
        final File staged = await _stage('zen_sticker_out', name, bytes);
        try {
          final Map<Object?, Object?>? out = await _channel
              .invokeMapMethod<Object?, Object?>(
                'exportToDownloads',
                <String, Object>{
                  'paths': <String>[staged.path],
                  'name': name,
                  'mime': mime,
                },
              );
          final Object? names = out?['names'];
          final Object? uris = out?['uris'];
          if (names is! List || names.isEmpty) {
            throw StateError('The sticker did not reach Downloads');
          }
          if (uris is List) {
            for (final Object? uri in uris) {
              if (uri is String) {
                // The panic password deletes it with the other exports.
                await rememberExportedFile(uri);
              }
            }
          }
          return '${t('Pobrane')}/${names.first}';
        } finally {
          await _remove(staged.parent);
        }
      }
      // Before Android 10 Downloads needs the storage permission: the
      // app's own folder.
      final Directory? dir = await getExternalStorageDirectory();
      if (dir == null) {
        return null;
      }
      return _write('${dir.path}/Zen/$name', bytes);
    }
    // iPhone: the app's Documents are in the Files app.
    final Directory dir = await getApplicationDocumentsDirectory();
    return _write('${dir.path}/$name', bytes);
  }

  Future<String> _write(String target, Uint8List bytes) async {
    final File file = File(target);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
    // Outside Zen's folders: the panic password deletes it too.
    await rememberExportedFile(target);
    return target;
  }

  /// [bytes] as [name] alone in the cache folder [folder] (the one before
  /// goes).
  Future<File> _stage(String folder, String name, Uint8List bytes) async {
    final Directory dir = Directory(
      '${(await getTemporaryDirectory()).path}/$folder',
    );
    await _remove(dir);
    await dir.create(recursive: true);
    final File file = File('${dir.path}/$name');
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  static Future<void> _remove(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Not there.
    }
  }

  @override
  Future<bool> share(String name, Uint8List bytes, String mime) async {
    if (!canShare) {
      return false;
    }
    final File file = await _stage('shared_sticker', name, bytes);
    return await _channel.invokeMethod<bool>('shareFile', <String, Object>{
          'path': file.path,
          'mime': mime,
        }) ??
        false;
  }

  @override
  Future<bool> printPdf(String name, Uint8List pdf) async {
    if (!canPrint) {
      return false;
    }
    final File file = await _stage('shared_sticker', name, pdf);
    return await _channel.invokeMethod<bool>('printPdf', <String, Object>{
          'path': file.path,
          'name': name,
        }) ??
        false;
  }

  @override
  Future<bool> open(String saved) async {
    if (!_desktop || !File(saved).existsSync()) {
      return false;
    }
    try {
      if (Platform.isWindows) {
        await Process.run(windowsExplorerPath(), <String>[saved]);
      } else if (Platform.isMacOS) {
        await Process.run('/usr/bin/open', <String>[saved]);
      } else {
        await Process.run('xdg-open', <String>[saved]);
      }
      return true;
    } on Object catch (error) {
      logZenWarning('Opening the sticker failed: $error');
      return false;
    }
  }
}

final Provider<StickerOutlet> stickerOutletProvider = Provider<StickerOutlet>(
  (Ref ref) => const PlatformStickerOutlet(),
);
