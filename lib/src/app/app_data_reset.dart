import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/multi/account_registry.dart';
import 'package:zen/src/features/account/multi/account_scope.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/account/multi/background_accounts.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_notification_center.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// Wipes every piece of local state of the account open now
/// (conversations, invites, settings, lock credentials, node identity).
/// The default account restarts from a clean slate in place; an
/// additional account is wiped whole ([ZenAccountRegistry.wipeAccount])
/// and the app goes back to the default account. The other accounts on
/// the device stay as they are (see [performZenDeviceWipe]).
Future<void> performZenLocalDataReset(WidgetRef ref) async {
  final ZenAccountScope account = ref.read(zenAccountProvider);
  if (!account.isDefault) {
    await _wipeAdditionalAccount(ref, account);
    return;
  }
  await _resetDefaultAccountInPlace(
    ref,
    destroyKeys: ref.read(appSecurityServiceProvider).reset,
    keepAccounts: true,
  );
}

/// The default account starts over in place: its node stops, its keys
/// go ([destroyKeys]), then its files (the other accounts' folders too
/// unless [keepAccounts]), and the app carries on from a clean slate.
Future<void> _resetDefaultAccountInPlace(
  WidgetRef ref, {
  required Future<void> Function() destroyKeys,
  required bool keepAccounts,
}) async {
  // The background service runs the node and writes the sealed inbox: it
  // stops first, or it could write some of it back after the wipe.
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
  try {
    // While the index of them is still there (a device wipe takes every
    // entry of the secret store with the keys).
    await const ExportedFilesIndex().deleteAll();
  } on Object catch (error, stackTrace) {
    logZenError('Deleting exported files failed', error, stackTrace);
  }
  await shredKeysThenDeleteLocalData(
    destroyKeys: destroyKeys,
    supportDirectory: supportDirectory,
    // The other accounts (and decoys) stay unless the whole device goes.
    // The default profile's folder also holds the test profiles'.
    keepInSupport: <String>{
      if (ZenInstance.profile == null) ZenInstance.profilesFolder,
      if (keepAccounts) ZenInstance.accountsFolder,
    },
    scratch: await findZenScratchPlaces(),
  );
  // The diagnostics log is plain text: it goes with the support
  // folder, and again here in case a line written during the wipe brought
  // it back.
  await ZenDiagnosticsLog.clear();
  await ref.read(appSettingsControllerProvider.notifier).reset();
  await ref.read(socialHubControllerProvider.notifier).resetLocalState();
  // What the person hid after reports is gone from the disk with the rest;
  // the list in memory must not write it back.
  ref.invalidate(hiddenByMeProvider);
  await ref.read(runtimeNotificationCenterProvider).clear();
  await ref.read(runtimeSystemNotificationServiceProvider).clear();
  await runtime.start();
}

/// Wipes the additional account [account]: its node stops, its keys
/// and folder go, and the default account opens (locked).
Future<void> _wipeAdditionalAccount(
  WidgetRef ref,
  ZenAccountScope account,
) async {
  final ZenAccountRegistry registry = ref.read(zenAccountRegistryProvider);
  final ZenAccountHost host = ref.read(zenAccountHostProvider);
  final ZenBackgroundAccounts background = ref.read(
    zenBackgroundAccountsProvider,
  );
  await leaveZenAccount(ref);
  try {
    // Off the background list while its key still marks it as real.
    await background.forget(account);
  } on Object catch (error, stackTrace) {
    logZenError('Leaving the background list failed', error, stackTrace);
  }
  try {
    // Its own copies first, while its index still names them.
    await const ExportedFilesIndex().deleteAll();
  } on Object catch (error, stackTrace) {
    logZenError('Deleting exported files failed', error, stackTrace);
  }
  await registry.wipeAccount(account);
  host.request(const ZenAccountOpening(scope: ZenAccountScope.defaultAccount));
}

/// Wipes the whole device: every account on it — the default one, the
/// listed and the hidden ones — every entry Zen has in the system's secret
/// store, the hardware key, the files and caches; then the app starts as
/// newly installed. What the lock screen's "start over" and the panic
/// password do.
Future<void> performZenDeviceWipe(WidgetRef ref) async {
  final ZenAccountScope account = ref.read(zenAccountProvider);
  final AppSecurityService security = ref.read(appSecurityServiceProvider);
  final ZenAccountRegistry registry = ref.read(zenAccountRegistryProvider);
  Future<void> destroyAllKeys() async {
    // The open account's own reset first (for the default account it also
    // destroys the hardware key; an additional one only drops its copy).
    await security.reset();
    try {
      await const SecureStorageCredentialsStore.device().deleteEverything();
    } on Object catch (error, stackTrace) {
      logZenError(
        'Deleting the secret store entries failed',
        error,
        stackTrace,
      );
    }
    try {
      await platformKeyVault().wipe();
    } on Object catch (error, stackTrace) {
      logZenError('Wiping the hardware key failed', error, stackTrace);
    }
  }

  if (account.isDefault) {
    // On the default account (the lock screen's case) the app starts over
    // in place, every other account's folder gone with the rest.
    await _resetDefaultAccountInPlace(
      ref,
      destroyKeys: destroyAllKeys,
      keepAccounts: false,
    );
    registry.forget();
    return;
  }
  final AndroidBackgroundServiceController service = ref.read(
    androidBackgroundServiceControllerProvider,
  );
  final ZenAccountHost host = ref.read(zenAccountHostProvider);
  // Started before the first wait: everything is read from [ref] at once.
  final Future<void> leaving = leaveZenAccount(ref);
  try {
    await service.stop();
  } on Object catch (error, stackTrace) {
    logZenError(
      'Stopping the background service before a wipe failed',
      error,
      stackTrace,
    );
  }
  await leaving;
  try {
    await const ExportedFilesIndex().deleteAll();
  } on Object catch (error, stackTrace) {
    logZenError('Deleting exported files failed', error, stackTrace);
  }
  await shredKeysThenDeleteLocalData(
    destroyKeys: destroyAllKeys,
    supportDirectory: await ZenInstance.instanceDirectory(),
    // The default profile's folder also holds the test profiles'.
    keepInSupport: ZenInstance.profile == null
        ? const <String>{ZenInstance.profilesFolder}
        : const <String>{},
    scratch: await findZenScratchPlaces(),
  );
  registry.forget();
  await ZenDiagnosticsLog.clear();
  // The default account opens, as on a new install.
  host.request(const ZenAccountOpening(scope: ZenAccountScope.defaultAccount));
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

  /// A computer's temporary folder, shared with other programs: only this
  /// instance's own Zen folder in it (`mediaTemporaryFolderName`) goes.
  final List<Directory> sharedFolders;

  /// A phone app's Documents: only a `Zen` folder in it goes.
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
  if (phone) {
    // The app's own Documents, where "Zapisz kopię" makes its `Zen` folder
    // on a phone. A computer's Documents and Downloads belong to the person:
    // a `Zen` folder there may be theirs, and what Zen saves there (by
    // choice, through a dialog) is on the export list.
    final Directory? documents = await _tryFolder(
      getApplicationDocumentsDirectory,
    );
    if (documents != null) {
      named.add(documents);
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
  Set<String> keepInSupport = const <String>{},
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
  if (keepInSupport.isEmpty) {
    await _deleteContentsBestEffort(supportDirectory);
  } else {
    await _deleteEntriesExcept(supportDirectory, keepInSupport);
  }
  for (final Directory folder in scratch.ownFolders) {
    if (_isSafeToEmpty(folder, supportDirectory)) {
      await _deleteContentsBestEffort(folder);
    }
  }
  for (final Directory folder in scratch.sharedFolders) {
    final String own = mediaTemporaryFolderName();
    await _deleteMatching(folder, (String name) => name == own);
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

/// Deletes the entries of [directory] except those named in [keep].
Future<void> _deleteEntriesExcept(Directory directory, Set<String> keep) async {
  final List<FileSystemEntity> entries;
  try {
    if (!await directory.exists()) {
      return;
    }
    entries = await directory.list(followLinks: false).toList();
  } on FileSystemException {
    return;
  }
  for (final FileSystemEntity entry in entries) {
    final String name = entry.path.substring(
      entry.path.lastIndexOf(Platform.pathSeparator) + 1,
    );
    if (keep.contains(name)) {
      continue;
    }
    try {
      await entry.delete(recursive: true);
    } on FileSystemException catch (error) {
      logZenWarning('Could not delete ${entry.path}: $error');
      if (entry is Directory) {
        await _deleteEachEntry(entry);
      }
    }
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
