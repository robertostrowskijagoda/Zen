import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// Wipes every piece of local state (conversations, invites, settings,
/// lock credentials, node identity) and restarts the runtime from a clean
/// slate. Used by the settings "reset data" panel and by the panic
/// password flow, so both paths must stay perfectly in sync.
Future<void> performZenLocalDataReset(WidgetRef ref) async {
  // The background service holds the master key and writes the same files:
  // it stops first, or it could write some of them back after the wipe.
  try {
    await ref.read(androidBackgroundServiceControllerProvider).stop();
  } on Object catch (error, stackTrace) {
    logZenError(
      'Stopping the background service before a wipe failed',
      error,
      stackTrace,
    );
  }
  final RuntimeNodeRuntime runtime = ref.read(runtimeNodeRuntimeProvider);
  await runtime.stop();
  final Directory supportDirectory = await ref.read(
    supportDirectoryResolverProvider,
  )();
  await shredKeysThenDeleteLocalData(
    destroyKeys: ref.read(appSecurityServiceProvider).reset,
    supportDirectory: supportDirectory,
    scratch: await findZenScratchPlaces(),
    deleteExports: () => const ExportedFilesIndex().deleteAll(),
  );
  await ref.read(appSettingsControllerProvider.notifier).reset();
  await ref.read(socialHubControllerProvider.notifier).resetLocalState();
  await ref.read(runtimeNotificationCenterProvider).clear();
  await ref.read(runtimeSystemNotificationServiceProvider).clear();
  await runtime.start();
}

/// Places outside the support folder where Zen leaves files.
@immutable
final class ZenScratchPlaces {
  const ZenScratchPlaces({
    this.ownFolders = const <Directory>[],
    this.sharedFolders = const <Directory>[],
    this.namedFolders = const <Directory>[],
  });

  /// Folders only Zen uses (a phone's cache and temporary folder,
  /// `Android/data/<package>/files`): emptied.
  final List<Directory> ownFolders;

  /// A computer's temporary folder, shared with other programs: only what
  /// Zen named (`zen-…`, `zen_…`) goes.
  final List<Directory> sharedFolders;

  /// Documents and Downloads: only a `Zen` folder in them goes.
  final List<Directory> namedFolders;
}

/// Where this platform keeps Zen's caches, temporary files and saved
/// copies (see [ZenScratchPlaces]). A folder the platform does not have
/// is left out.
Future<ZenScratchPlaces> findZenScratchPlaces() async {
  final List<Directory> own = <Directory>[];
  final List<Directory> shared = <Directory>[];
  final List<Directory> named = <Directory>[];
  final bool phone = Platform.isAndroid || Platform.isIOS;
  final Directory? temporary = await _tryFolder(getTemporaryDirectory);
  if (temporary != null) {
    (phone ? own : shared).add(temporary);
  }
  if (phone) {
    final Directory? cache = await _tryFolder(getApplicationCacheDirectory);
    if (cache != null) {
      own.add(cache);
    }
  }
  if (Platform.isAndroid) {
    // `Android/data/<package>/files`: where "Zapisz kopię" puts files.
    final Directory? external = await _tryFolder(getExternalStorageDirectory);
    if (external != null) {
      own.add(external);
    }
    try {
      own.addAll(await getExternalCacheDirectories() ?? const <Directory>[]);
    } on Object catch (error) {
      logZenWarning('No external cache folders: $error');
    }
  }
  final Directory? documents = await _tryFolder(
    getApplicationDocumentsDirectory,
  );
  if (documents != null) {
    named.add(documents);
  }
  if (!phone) {
    final Directory? downloads = await _tryFolder(getDownloadsDirectory);
    if (downloads != null) {
      named.add(downloads);
    }
  }
  return ZenScratchPlaces(
    ownFolders: own,
    sharedFolders: shared,
    namedFolders: named,
  );
}

Future<Directory?> _tryFolder(Future<Directory?> Function() find) async {
  try {
    return await find();
  } on Object catch (error) {
    logZenWarning('A folder to wipe is not available: $error');
    return null;
  }
}

/// The order of a wipe (crypto-shredding): the keys go first — the wrapped
/// master key, the device key, the sealed biometric copies and the
/// hardware key ([destroyKeys]) — and only then the files, as far as they
/// can be deleted: the support folder, then Zen's caches, temporary files
/// and saved copies ([scratch]), then the files Zen exported on purpose
/// ([deleteExports]). A crash, a killed process or a locked file halfway
/// through the deletion then leaves only ciphertext nobody can open, never
/// a readable copy next to the key that opens it.
Future<void> shredKeysThenDeleteLocalData({
  required Future<void> Function() destroyKeys,
  required Directory supportDirectory,
  ZenScratchPlaces scratch = const ZenScratchPlaces(),
  Future<void> Function()? deleteExports,
}) async {
  bool shredded = false;
  try {
    await destroyKeys();
    shredded = true;
  } on Object catch (error, stackTrace) {
    logZenError('Destroying the data keys failed', error, stackTrace);
  }
  await _deleteContentsBestEffort(supportDirectory);
  for (final Directory folder in scratch.ownFolders) {
    if (_isSafeToEmpty(folder, supportDirectory)) {
      await _deleteContentsBestEffort(folder);
    }
  }
  for (final Directory folder in scratch.sharedFolders) {
    await _deleteMatching(folder, _isZenScratchName);
  }
  for (final Directory folder in scratch.namedFolders) {
    await _deleteMatching(folder, (String name) => name.toLowerCase() == 'zen');
  }
  if (deleteExports != null) {
    try {
      await deleteExports();
    } on Object catch (error, stackTrace) {
      logZenError('Deleting exported files failed', error, stackTrace);
    }
  }
  if (!shredded) {
    // Once more after the files: whatever failed the first time.
    try {
      await destroyKeys();
    } on Object catch (error, stackTrace) {
      logZenError('Destroying the data keys failed again', error, stackTrace);
    }
  }
}

/// What Zen names in a shared temporary folder: `zen-media`, `zen-audio-…`,
/// `zen_rec_…` and the like.
bool _isZenScratchName(String name) {
  final String lower = name.toLowerCase();
  return lower == 'zen' || lower.startsWith('zen-') || lower.startsWith('zen_');
}

/// Never a root, the support folder itself or a folder that holds it.
bool _isSafeToEmpty(Directory folder, Directory supportDirectory) {
  final String separator = Platform.pathSeparator;
  String clean(String path) {
    final String absolute = Directory(path).absolute.path;
    final String trimmed = absolute.endsWith(separator)
        ? absolute.substring(0, absolute.length - 1)
        : absolute;
    return Platform.isWindows ? trimmed.toLowerCase() : trimmed;
  }

  final String path = clean(folder.path);
  final String support = clean(supportDirectory.path);
  if (path.split(separator).where((String part) => part.isNotEmpty).length <
      2) {
    return false;
  }
  return path != support && !support.startsWith('$path$separator');
}

/// Deletes the entries of [folder] whose name [matches]; what cannot be
/// deleted is skipped.
Future<void> _deleteMatching(
  Directory folder,
  bool Function(String name) matches,
) async {
  final List<FileSystemEntity> entries;
  try {
    if (!await folder.exists()) {
      return;
    }
    entries = await folder.list(followLinks: false).toList();
  } on FileSystemException {
    return;
  }
  final String separator = Platform.pathSeparator;
  for (final FileSystemEntity entry in entries) {
    final String name = entry.path.substring(
      entry.path.lastIndexOf(separator) + 1,
    );
    if (!matches(name)) {
      continue;
    }
    try {
      await entry.delete(recursive: true);
    } on FileSystemException catch (error) {
      logZenWarning('Could not delete ${entry.path}: $error');
    }
  }
}

/// Deletes [directory] with everything in it; what cannot be deleted (a
/// file another process holds open on Windows) is skipped instead of
/// stopping the rest. The directory itself is there again afterwards.
Future<void> _deleteContentsBestEffort(Directory directory) async {
  try {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  } on FileSystemException catch (error) {
    logZenWarning('Wiping ${directory.path} at once failed: $error');
    await _deleteEachEntry(directory);
  }
  try {
    await directory.create(recursive: true);
  } on FileSystemException catch (error) {
    logZenWarning('Recreating ${directory.path} failed: $error');
  }
}

Future<void> _deleteEachEntry(Directory directory) async {
  final List<FileSystemEntity> entries;
  try {
    entries = await directory.list(followLinks: false).toList();
  } on FileSystemException {
    return;
  }
  for (final FileSystemEntity entry in entries) {
    try {
      if (entry is Directory) {
        await _deleteEachEntry(entry);
        await entry.delete();
      } else {
        await entry.delete();
      }
    } on FileSystemException catch (error) {
      logZenWarning('Could not delete ${entry.path}: $error');
    }
  }
}
