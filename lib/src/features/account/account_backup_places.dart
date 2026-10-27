import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/windows_system_paths.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_backup_io.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/security/exported_files.dart';

/// The first Android version (10) whose Downloads folder takes a file from
/// any app with no storage permission (through the media store).
const int kAndroidDownloadsWithoutPermissionSdk = 29;

/// The kinds of system that keep backups in different places.
enum AccountBackupSystem {
  android,
  ios,
  desktop;

  static AccountBackupSystem get current => Platform.isAndroid
      ? android
      : Platform.isIOS
      ? ios
      : desktop;
}

/// How a [AccountBackupFolder] is written to.
enum AccountBackupFolderKind {
  /// A plain folder of the file system, written to directly.
  directory,

  /// Android: the Downloads folder, through the media store.
  downloads,

  /// Android: a folder the person picked in the system's file chooser.
  picked,
}

/// A place for a new backup file.
final class AccountBackupFolder {
  const AccountBackupFolder._(this.kind, this.label, {this.path, this.tree});

  /// A folder of the file system at [path], shown as [label] (its path by
  /// default).
  factory AccountBackupFolder.directory(String path, {String? label}) =>
      AccountBackupFolder._(
        AccountBackupFolderKind.directory,
        label ?? path,
        path: path,
      );

  /// Android: Downloads.
  factory AccountBackupFolder.downloads() =>
      AccountBackupFolder._(AccountBackupFolderKind.downloads, t('Pobrane'));

  /// Android: the folder behind the system's [tree] address.
  factory AccountBackupFolder.picked({
    required String tree,
    required String label,
  }) =>
      AccountBackupFolder._(AccountBackupFolderKind.picked, label, tree: tree);

  final AccountBackupFolderKind kind;

  /// What the person sees as the folder.
  final String label;

  /// [AccountBackupFolderKind.directory]: where it is.
  final String? path;

  /// [AccountBackupFolderKind.picked]: the system's address of the folder.
  final String? tree;

  /// Written to as a normal folder, with no staging.
  bool get isDirect => kind == AccountBackupFolderKind.directory;

  @override
  bool operator ==(Object other) =>
      other is AccountBackupFolder &&
      other.kind == kind &&
      other.label == label &&
      other.path == path &&
      other.tree == tree;

  @override
  int get hashCode => Object.hash(kind, label, path, tree);
}

/// Where a finished backup is: [shown] holds each file as the person is
/// told of it (a path, or `Pobrane/name`).
final class AccountBackupSaved {
  const AccountBackupSaved({
    required this.folder,
    required this.shown,
    this.canOpen = false,
  });

  final AccountBackupFolder folder;
  final List<String> shown;

  /// The system can show [folder] to the person.
  final bool canOpen;
}

/// Where backup files are written and found (replaced in tests).
abstract interface class AccountBackupPlaces {
  /// Where a new backup goes unless the person chooses: Downloads on a
  /// computer and an Android phone, the app's folder in the Files app on an
  /// iPhone.
  Future<AccountBackupFolder> defaultFolder();

  /// Lets the person choose another folder; null when they cancelled.
  Future<AccountBackupFolder?> chooseFolder();

  /// Where [writeAccountBackup] writes the first part of [name] for
  /// [folder]: the folder itself when it can be written to directly,
  /// otherwise a private working folder ([release] removes it).
  Future<String> workPath(AccountBackupFolder folder, String name);

  /// Takes the parts [written] (the first one at [first]) to [folder].
  Future<AccountBackupSaved> deliver(
    AccountBackupFolder folder,
    String first,
    List<String> written,
  );

  /// Removes what [workPath] made once [deliver] is done or the writing
  /// failed.
  Future<void> release(AccountBackupFolder folder, String first);

  /// Shows [saved]'s folder (the Files app, Explorer…); false when it
  /// could not be shown.
  Future<bool> open(AccountBackupSaved saved);

  /// A backup file the person picks (any of its parts), from anywhere; null
  /// when cancelled.
  Future<String?> pick();
}

/// Writes the backup [build] for [password] as [name] into [folder] and
/// returns where it ended up.
Future<AccountBackupSaved> saveAccountBackup({
  required AccountBackupPlaces places,
  required AccountBackupFolder folder,
  required String name,
  required AccountArchiveBuild build,
  required String password,
  required PasswordCost cost,
  void Function(int done, int total)? progress,
}) async {
  final String first = await places.workPath(folder, name);
  try {
    final List<String> written = await writeAccountBackup(
      build: build,
      password: password,
      first: first,
      cost: cost,
      progress: progress,
      // A staged copy is deleted at once; the panic password only needs to
      // know the files that stay (remembered when they are delivered).
      remember: folder.isDirect,
    );
    return await places.deliver(folder, first, written);
  } finally {
    await places.release(folder, first);
  }
}

/// The real [AccountBackupPlaces]. The system, the folders and the Android
/// bridge (`zen/system`) are parameters for tests.
final class PlatformAccountBackupPlaces implements AccountBackupPlaces {
  PlatformAccountBackupPlaces({
    AccountBackupSystem? system,
    MethodChannel channel = const MethodChannel('zen/system'),
    Future<int?> Function()? androidSdk,
    Future<Directory?> Function()? downloads,
    Future<Directory> Function()? documents,
    Future<Directory?> Function()? appExternal,
    Future<Directory> Function()? temporary,
    Future<String?> Function()? directoryPicker,
    Future<void> Function(String path)? reveal,
    Future<void> Function(String path)? remember,
  }) : _system = system ?? AccountBackupSystem.current,
       _channel = channel,
       _androidSdk = androidSdk,
       _downloads = downloads ?? getDownloadsDirectory,
       _documents = documents ?? getApplicationDocumentsDirectory,
       _appExternal = appExternal ?? getExternalStorageDirectory,
       _temporary = temporary ?? getTemporaryDirectory,
       _directoryPicker =
           directoryPicker ??
           (() => FilePicker.platform.getDirectoryPath(
             dialogTitle: t('Wybierz folder na kopię'),
           )),
       _reveal = reveal ?? _revealOnDesktop,
       _remember = remember ?? rememberExportedFile;

  final AccountBackupSystem _system;
  final MethodChannel _channel;
  final Future<int?> Function()? _androidSdk;
  final Future<Directory?> Function() _downloads;
  final Future<Directory> Function() _documents;
  final Future<Directory?> Function() _appExternal;
  final Future<Directory> Function() _temporary;
  final Future<String?> Function() _directoryPicker;
  final Future<void> Function(String path) _reveal;
  final Future<void> Function(String path) _remember;

  static String _name(String path) =>
      path.split(RegExp(r'[\\/]')).where((String s) => s.isNotEmpty).last;

  Future<int?> _sdk() =>
      _androidSdk?.call() ?? _channel.invokeMethod<int>('sdkInt');

  @override
  Future<AccountBackupFolder> defaultFolder() async {
    final String sep = Platform.pathSeparator;
    switch (_system) {
      case AccountBackupSystem.android:
        final int? sdk = await _sdk();
        if (sdk != null && sdk >= kAndroidDownloadsWithoutPermissionSdk) {
          return AccountBackupFolder.downloads();
        }
        // Before Android 10 Downloads needs the storage permission: the
        // app's own folder instead.
        final Directory dir = await _appExternal() ?? await _documents();
        return AccountBackupFolder.directory('${dir.path}${sep}Zen');
      case AccountBackupSystem.ios:
        // There is no Downloads: the app's Documents are in the Files app.
        return AccountBackupFolder.directory(
          (await _documents()).path,
          label: t('Pliki (folder Zen)'),
        );
      case AccountBackupSystem.desktop:
        final Directory dir = await _downloads() ?? await _documents();
        return AccountBackupFolder.directory(dir.path);
    }
  }

  @override
  Future<AccountBackupFolder?> chooseFolder() async {
    if (_system == AccountBackupSystem.android) {
      final Map<Object?, Object?>? picked = await _channel
          .invokeMapMethod<Object?, Object?>('pickFolder');
      final Object? tree = picked?['tree'];
      if (tree is! String || tree.isEmpty) {
        return null;
      }
      final Object? label = picked?['label'];
      return AccountBackupFolder.picked(
        tree: tree,
        label: label is String && label.isNotEmpty
            ? label
            : t('Wybrany folder'),
      );
    }
    final String? path = await _directoryPicker();
    return path == null || path.isEmpty
        ? null
        : AccountBackupFolder.directory(path);
  }

  @override
  Future<String> workPath(AccountBackupFolder folder, String name) async {
    final String sep = Platform.pathSeparator;
    if (folder.isDirect) {
      final Directory dir = Directory(folder.path!);
      await dir.create(recursive: true);
      return '${dir.path}$sep$name';
    }
    final Directory work = await (await _temporary()).createTemp(
      'zen_backup_out_',
    );
    return '${work.path}$sep$name';
  }

  @override
  Future<AccountBackupSaved> deliver(
    AccountBackupFolder folder,
    String first,
    List<String> written,
  ) async {
    switch (folder.kind) {
      case AccountBackupFolderKind.directory:
        return AccountBackupSaved(
          folder: folder,
          shown: written,
          canOpen: _system == AccountBackupSystem.desktop,
        );
      case AccountBackupFolderKind.downloads:
        final Map<Object?, Object?>? out = await _channel
            .invokeMapMethod<Object?, Object?>(
              'exportToDownloads',
              <String, Object>{'paths': written, 'name': _name(first)},
            );
        final List<String> names = _strings(out?['names']);
        if (names.isEmpty) {
          throw StateError('The backup did not reach Downloads');
        }
        // The panic password deletes what it still finds at these paths.
        for (final String path in _strings(out?['paths'])) {
          await _remember(path);
        }
        return AccountBackupSaved(
          folder: folder,
          shown: <String>[for (final String n in names) '${folder.label}/$n'],
          canOpen: true,
        );
      case AccountBackupFolderKind.picked:
        final Map<Object?, Object?>? out = await _channel
            .invokeMapMethod<Object?, Object?>(
              'exportToFolder',
              <String, Object>{
                'tree': folder.tree!,
                'paths': written,
                'name': _name(first),
              },
            );
        final List<String> names = _strings(out?['names']);
        if (names.isEmpty) {
          throw StateError('The backup did not reach the chosen folder');
        }
        return AccountBackupSaved(
          folder: folder,
          shown: <String>[for (final String n in names) '${folder.label}/$n'],
          canOpen: true,
        );
    }
  }

  static List<String> _strings(Object? raw) => raw is List
      ? <String>[
          for (final Object? s in raw)
            if (s is String) s,
        ]
      : const <String>[];

  @override
  Future<void> release(AccountBackupFolder folder, String first) async {
    if (folder.isDirect) {
      return;
    }
    try {
      await File(first).parent.delete(recursive: true);
    } on FileSystemException {
      // Gone already.
    }
  }

  @override
  Future<bool> open(AccountBackupSaved saved) async {
    try {
      switch (saved.folder.kind) {
        case AccountBackupFolderKind.directory:
          if (_system != AccountBackupSystem.desktop || saved.shown.isEmpty) {
            return false;
          }
          await _reveal(saved.shown.first);
          return true;
        case AccountBackupFolderKind.downloads:
          return await _channel.invokeMethod<bool>('openDownloads') ?? false;
        case AccountBackupFolderKind.picked:
          return await _channel.invokeMethod<bool>(
                'openFolder',
                <String, Object>{'tree': saved.folder.tree!},
              ) ??
              false;
      }
    } on Object catch (error) {
      logZenWarning('Showing the backup folder failed: $error');
      return false;
    }
  }

  /// Windows: Explorer with the file selected; macOS: Finder likewise;
  /// Linux: the file manager on the folder.
  static Future<void> _revealOnDesktop(String path) async {
    if (Platform.isWindows) {
      await Process.run(windowsExplorerPath(), <String>['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.run('/usr/bin/open', <String>['-R', path]);
    } else {
      await Process.run('xdg-open', <String>[File(path).parent.path]);
    }
  }

  @override
  Future<String?> pick() async {
    final FilePickerResult? picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      withData: false,
    );
    return picked?.files.firstOrNull?.path;
  }
}

final Provider<AccountBackupPlaces> accountBackupPlacesProvider =
    Provider<AccountBackupPlaces>((Ref ref) => PlatformAccountBackupPlaces());
