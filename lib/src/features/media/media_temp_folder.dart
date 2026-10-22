import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';

/// Folder of the short-lived plain copies a player or recorder needs (in a
/// per-user folder, see [mediaTemporaryBase]). Emptied at every start and
/// at exit.
const String kMediaTemporaryFolder = 'zen-media';

/// `0700`: only the owner may list, enter or change the folder.
const int kOwnerOnlyFolderMode = 0x1C0;

/// `0600`: only the owner may read or write the file.
const int kOwnerOnlyFileMode = 0x180;

/// `0777`.
const int _permissionBits = 0x1FF;

/// `0077`: any right for the group or the others.
const int _groupOtherBits = 0x3F;

/// `0022`: the group or the others may add, rename or remove entries.
const int _groupOtherWriteBits = 0x12;

/// The file-system operations a private folder needs; a fake in tests.
abstract interface class PosixFolderAccess {
  /// Type of [path] itself (a link is a link, not its target).
  Future<FileSystemEntityType> typeOf(String path);

  /// Permission bits (the `0777` part of the mode) of [path].
  Future<int> permissionsOf(String path);

  /// `chmod`; false when refused. Only the owner (or root) may change the
  /// mode, so success also says the entry is this user's.
  bool setPermissions(String path, int mode);
}

/// [PosixFolderAccess] of the running system (Linux and macOS).
final class SystemFolderAccess implements PosixFolderAccess {
  const SystemFolderAccess();

  @override
  Future<FileSystemEntityType> typeOf(String path) =>
      FileSystemEntity.type(path, followLinks: false);

  @override
  Future<int> permissionsOf(String path) async =>
      (await FileStat.stat(path)).mode & _permissionBits;

  @override
  bool setPermissions(String path, int mode) => posixChmod(path, mode);
}

typedef _ChmodNative = Int32 Function(Pointer<Utf8> path, Uint32 mode);
typedef _ChmodDart = int Function(Pointer<Utf8> path, int mode);

_ChmodDart? _chmod;

/// libc `chmod` (Linux, macOS, Android); false when it fails or there is
/// no libc here.
bool posixChmod(String path, int mode) {
  if (Platform.isWindows) {
    return false;
  }
  final _ChmodDart chmod;
  try {
    chmod = _chmod ??= DynamicLibrary.process()
        .lookupFunction<_ChmodNative, _ChmodDart>('chmod');
  } on Object catch (error) {
    logZenWarning('No chmod here: $error');
    return false;
  }
  final Pointer<Utf8> native = path.toNativeUtf8();
  try {
    return chmod(native, mode) == 0;
  } finally {
    malloc.free(native);
  }
}

/// Whether plain media needs a folder checked here: a computer with
/// POSIX permissions. A phone's temporary folder is the app's own, and a
/// Windows one is the user's own.
bool get _checksPermissions => Platform.isLinux || Platform.isMacOS;

/// The name of this instance's temporary media folder: one per test
/// profile on a computer. A wipe removes exactly this (and its
/// replacements, see [isMediaTemporaryFolderEntry]) and nothing another
/// program or profile made.
String mediaTemporaryFolderName() {
  final String? profile = ZenInstance.profile;
  return '$kMediaTemporaryFolder${profile == null ? '' : '-$profile'}';
}

/// Whether the entry [name] is the temporary media folder [own] or one
/// made in its place ([own] + `.` + random, see [preparePrivateFolder]).
/// A profile name has no dot, so another profile's folder never matches.
bool isMediaTemporaryFolderEntry(String name, String own) =>
    name == own || name.startsWith('$own.');

/// The first of [candidates] that is a folder nobody else may write into
/// (no group or other write bit); null when none is.
Future<Directory?> pickPrivateBase(
  List<Directory> candidates, {
  PosixFolderAccess access = const SystemFolderAccess(),
}) async {
  for (final Directory candidate in candidates) {
    try {
      if (!await candidate.exists()) {
        continue;
      }
      final int bits = await access.permissionsOf(candidate.path);
      if ((bits & _groupOtherWriteBits) == 0) {
        return candidate;
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// Where the temporary media folder lives.
///
/// Linux: `/tmp` is shared by every user of the computer, so the app's own
/// cache folder (`~/.cache/<app>`) instead, else `$XDG_RUNTIME_DIR`
/// (memory, but capped at a fraction of RAM, too small for a film or an
/// hour of call recording). Elsewhere the system's temporary folder, which
/// is per user (macOS, Windows) or per app (phones).
Future<Directory> mediaTemporaryBase() async {
  if (Platform.isLinux) {
    final List<Directory> candidates = <Directory>[];
    try {
      final Directory cache = await getApplicationCacheDirectory();
      await cache.create(recursive: true);
      candidates.add(cache);
    } on Object catch (error) {
      logZenWarning('No app cache folder: $error');
    }
    final String runtime = Platform.environment['XDG_RUNTIME_DIR'] ?? '';
    if (runtime.startsWith('/')) {
      candidates.add(Directory(runtime));
    }
    final Directory? base = await pickPrivateBase(candidates);
    if (base != null) {
      return base;
    }
    logZenWarning('No per-user folder for temporary media; using /tmp.');
  }
  return getTemporaryDirectory();
}

/// Whether [path] is a real folder (not a link), with no rights for the
/// group or others, that belongs to this user (proved by `chmod`, which
/// only the owner may do).
Future<bool> isPrivateOwnFolder(
  String path, {
  PosixFolderAccess access = const SystemFolderAccess(),
}) async {
  try {
    if (await access.typeOf(path) != FileSystemEntityType.directory) {
      return false;
    }
    if ((await access.permissionsOf(path) & _groupOtherBits) != 0) {
      return false;
    }
    return access.setPermissions(path, kOwnerOnlyFolderMode);
  } on FileSystemException {
    return false;
  }
}

/// The folder [name] in [base], private to this user (`0700`).
///
/// A folder Zen makes is set to `0700` at once. A folder that already
/// exists is used only when it is a real folder of this user with no
/// rights for anyone else: a link, a file, a folder of someone else or one
/// others could already open is never used (whoever made it could read or
/// swap what Zen writes there). A new folder with a random name
/// (`<name>.XXXXXX`) is made instead; [replacement], one made earlier,
/// is reused while it is still private. Throws when no private folder can
/// be had: plain media is then not written at all.
Future<Directory> preparePrivateFolder(
  Directory base,
  String name, {
  PosixFolderAccess access = const SystemFolderAccess(),
  Directory? replacement,
}) async {
  final Directory folder = Directory(
    '${base.path}${Platform.pathSeparator}$name',
  );
  final FileSystemEntityType before = await access.typeOf(folder.path);
  if (before == FileSystemEntityType.notFound) {
    try {
      await folder.create();
    } on FileSystemException catch (error) {
      logZenWarning('Creating the temporary media folder failed: $error');
    }
    // Made a moment ago: the umask may have left it open, so close it
    // first. Someone who made it in between is not its owner, so the
    // chmod (and with it the check) fails for them.
    if (await access.typeOf(folder.path) == FileSystemEntityType.directory &&
        access.setPermissions(folder.path, kOwnerOnlyFolderMode) &&
        await isPrivateOwnFolder(folder.path, access: access)) {
      return folder;
    }
  } else if (await isPrivateOwnFolder(folder.path, access: access)) {
    return folder;
  }
  logZenWarning(
    'The temporary media folder is not private to this user; '
    'using a new one.',
  );
  if (replacement != null &&
      await isPrivateOwnFolder(replacement.path, access: access)) {
    return replacement;
  }
  final Directory fresh = await base.createTemp('$name.');
  if (access.setPermissions(fresh.path, kOwnerOnlyFolderMode) &&
      await isPrivateOwnFolder(fresh.path, access: access)) {
    return fresh;
  }
  try {
    await fresh.delete(recursive: true);
  } on FileSystemException {
    // Nothing was written into it.
  }
  throw StateError('No private folder for temporary media.');
}

Directory? _replacementFolder;

/// The temporary media folder (one per test profile on a computer),
/// private to this user on Linux and macOS.
Future<Directory> mediaTemporaryDirectory() async {
  final Directory base = await mediaTemporaryBase();
  final String name = mediaTemporaryFolderName();
  if (!_checksPermissions) {
    final Directory folder = Directory(
      '${base.path}${Platform.pathSeparator}$name',
    );
    await folder.create(recursive: true);
    return folder;
  }
  final Directory folder = await preparePrivateFolder(
    base,
    name,
    replacement: _replacementFolder,
  );
  if (!folder.path.endsWith('${Platform.pathSeparator}$name')) {
    _replacementFolder = folder;
  }
  return folder;
}

/// A new path in the temporary media folder: [prefix] + a random name +
/// [extension] (with its dot), so nobody can guess it and put a link
/// there first.
Future<String> newTemporaryMediaPath({
  String prefix = '',
  String extension = '',
}) async {
  final Directory folder = await mediaTemporaryDirectory();
  final String id = securityHexFromBytes(randomSecurityBytes(16));
  return '${folder.path}${Platform.pathSeparator}$prefix$id$extension';
}

/// Creates the empty file [path], readable only by its owner (`0600` on
/// Linux and macOS), before any plain byte goes into it. Writing into it
/// afterwards keeps the mode.
Future<File> createPrivateTemporaryFile(String path) async {
  final File file = File(path);
  await file.writeAsBytes(const <int>[], flush: true);
  if (_checksPermissions && !posixChmod(path, kOwnerOnlyFileMode)) {
    await file.delete();
    throw StateError('A temporary media file could not be made private.');
  }
  return file;
}

/// Deletes the temporary media folder [name] in [base] and the folders
/// made in its place; a link is removed itself, never what it points to.
Future<void> deleteMediaTemporaryFolders(Directory base, String name) async {
  final List<FileSystemEntity> entries;
  try {
    if (!await base.exists()) {
      return;
    }
    entries = await base.list(followLinks: false).toList();
  } on FileSystemException {
    return;
  }
  for (final FileSystemEntity entry in entries) {
    final String entryName = entry.path.substring(
      entry.path.lastIndexOf(Platform.pathSeparator) + 1,
    );
    if (!isMediaTemporaryFolderEntry(entryName, name)) {
      continue;
    }
    try {
      await entry.delete(recursive: true);
    } on FileSystemException catch (error) {
      logZenWarning('Clearing temporary media failed: $error');
    }
  }
}

/// Removes the plain copies players and recorders left behind (a crash, a
/// killed app): at start and at exit.
Future<void> wipeMediaTemporaryFiles() async {
  try {
    final Directory base = await mediaTemporaryBase();
    await deleteMediaTemporaryFolders(base, mediaTemporaryFolderName());
    _replacementFolder = null;
  } on Object catch (error) {
    logZenWarning('Clearing temporary media failed: $error');
  }
}
