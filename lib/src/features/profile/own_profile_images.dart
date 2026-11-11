import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/media/media_temp_folder.dart'
    show
        createPrivateTemporaryFile,
        isMediaTemporaryFolderEntry,
        mediaTemporaryFolderName;
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/social/social_hub_controller.dart'
    show supportDirectoryResolverProvider;

// Your own photo and cover live in the media vault, encrypted like
// everything else of yours, not as plain files. The profile editor
// prepares a plain file first (checked, re-encoded); saving the profile
// moves it into the vault. That plain file is only ever written to the
// private temporary media folder ([stagePlainProfileImage]), which is
// emptied at every start and exit: nothing plain is written under the
// account's own folder, not even for a moment.

/// Folders under the account folder in which versions up to 1.16.4 staged
/// the plain photo (`avatars`) and cover (`profile`). Nothing writes there
/// any more; [removeLegacyPlainProfileImages] clears them.
const List<String> kLegacyProfileImageFolders = <String>['avatars', 'profile'];

final RegExp _separator = RegExp(r'[\\/]');

/// Largest own picture read back (the cover and the photo are far smaller).
const int kMaxOwnProfileImageBytes = 20 * 1024 * 1024;

/// Encrypts the plain file at a path into the vault and returns the new
/// path (or `null` when it could not: the plain file then stays).
typedef ProfileImageSealer = Future<String?> Function(String path);

/// The sealer of the app: the media vault of this container.
final Provider<ProfileImageSealer> profileImageSealerProvider =
    Provider<ProfileImageSealer>((Ref ref) {
      final MediaVault vault = ref.watch(mediaVaultProvider);
      return (String path) => sealProfileImageFile(vault, path);
    });

/// Writes the checked, re-encoded picture [bytes] as a plain file for the
/// profile editor to show and to seal on save, and returns its path.
///
/// The file is made in [folder] (the private temporary media folder), named
/// [prefix] (`avatar_` or `cover_`) + a random name + [extension] (with its
/// dot), owner-only before any byte goes in. When writing fails nothing is
/// left behind; when the app is killed in between, the next start empties
/// the folder.
Future<String> stagePlainProfileImage(
  Uint8List bytes, {
  required String prefix,
  required String extension,
  Future<Directory> Function() folder = mediaTemporaryDirectory,
}) async {
  final Directory dir = await folder();
  final File file = await createPrivateTemporaryFile(
    '${dir.path}${Platform.pathSeparator}$prefix'
    '${securityHexFromBytes(randomSecurityBytes(16))}$extension',
  );
  try {
    await file.writeAsBytes(bytes, flush: true);
  } on Object {
    try {
      if (file.existsSync()) {
        await file.delete();
      }
    } on FileSystemException catch (error) {
      logZenWarning('Deleting a plain profile picture failed: $error');
    }
    rethrow;
  }
  return file.path;
}

/// Whether [path] is a plain picture staged by [stagePlainProfileImage]: it
/// lies in a temporary media folder, which the next start empties.
bool isStagedProfileImage(String? path) {
  if (path == null || path.isEmpty || isMediaVaultPath(path)) {
    return false;
  }
  final List<String> parts = path.split(_separator);
  return parts.length >= 2 &&
      isOwnPlainProfileImage(path) &&
      isMediaTemporaryFolderEntry(
        parts[parts.length - 2],
        mediaTemporaryFolderName(),
      );
}

/// Whether [path] is a plain file this app wrote for the profile (and so
/// may delete once it is in the vault).
bool isOwnPlainProfileImage(String? path) {
  if (path == null || path.isEmpty || isMediaVaultPath(path)) {
    return false;
  }
  final String name = path.split(_separator).last;
  return name.startsWith('avatar_') || name.startsWith('cover_');
}

/// Moves the plain picture at [path] into [vault]. A file this app wrote
/// ([isOwnPlainProfileImage]) is deleted afterwards; anything else is only
/// copied.
Future<String?> sealProfileImageFile(MediaVault vault, String path) async {
  if (isMediaVaultPath(path)) {
    return path;
  }
  final File file = File(path);
  if (!file.existsSync() || file.lengthSync() > kMaxOwnProfileImageBytes) {
    return null;
  }
  try {
    return await vault.putFile(
      file,
      deleteSource: isOwnPlainProfileImage(path),
    );
  } on Object catch (error, stackTrace) {
    // Locked or no data key yet: the next save or start tries again.
    logZenError('Sealing a profile picture failed', error, stackTrace);
    return null;
  }
}

/// Puts a picture of your own profile arriving as [bytes] (from your other
/// device or from a backup) into [vault]; returns its vault path.
///
/// The bytes pass through a short-lived plain file in the temporary media
/// folder ([folder]; private to this user, emptied at start, at exit and by
/// every wipe), deleted as soon as the vault holds the picture or the
/// attempt fails. Throws when the picture is too big or cannot be stored.
Future<String> sealIncomingProfileImage(
  MediaVault vault,
  Stream<List<int>> bytes, {
  required bool cover,
  Future<Directory> Function() folder = mediaTemporaryDirectory,
}) async {
  final Directory dir = await folder();
  final File plain = await createPrivateTemporaryFile(
    '${dir.path}${Platform.pathSeparator}${cover ? 'cover_' : 'avatar_'}'
    '${securityHexFromBytes(randomSecurityBytes(16))}.jpg',
  );
  try {
    final IOSink sink = plain.openWrite();
    try {
      await sink.addStream(bytes);
    } finally {
      await sink.close();
    }
    if (await plain.length() > kMaxOwnProfileImageBytes) {
      throw const FormatException('The profile picture is too big.');
    }
    return await vault.putFile(plain);
  } finally {
    try {
      if (plain.existsSync()) {
        await plain.delete();
      }
    } on FileSystemException catch (error) {
      logZenWarning('Deleting a plain profile picture failed: $error');
    }
  }
}

/// Whether [profile] still points at a plain photo or cover file.
bool needsProfileImageSealing(UserProfile profile) => <String?>[
  profile.avatarPath,
  profile.coverPath,
].any((String? p) => p != null && p.isNotEmpty && !isMediaVaultPath(p));

/// [profile] with its photo and cover in the vault, or [profile] itself
/// when nothing had to move (or could not move yet).
///
/// A picture staged in the temporary media folder ([isStagedProfileImage])
/// that cannot be sealed makes this throw: the folder is emptied at the
/// next start, so a profile pointing at it would lose the picture silently.
/// The editor then still holds the file and the person can save again.
Future<UserProfile> sealOwnProfileImages(
  UserProfile profile,
  ProfileImageSealer seal,
) async {
  String? avatar = profile.avatarPath;
  String? cover = profile.coverPath;
  bool changed = false;
  if (avatar != null && avatar.isNotEmpty && !isMediaVaultPath(avatar)) {
    final String? sealed = await _sealStaged(seal, avatar);
    if (sealed != null && sealed != avatar) {
      avatar = sealed;
      changed = true;
    }
  }
  if (cover != null && cover.isNotEmpty && !isMediaVaultPath(cover)) {
    final String? sealed = await _sealStaged(seal, cover);
    if (sealed != null && sealed != cover) {
      cover = sealed;
      changed = true;
    }
  }
  return changed
      ? profile.copyWith(avatarPath: avatar, coverPath: cover)
      : profile;
}

Future<String?> _sealStaged(ProfileImageSealer seal, String path) async {
  final String? sealed = await seal(path);
  if (sealed == null && isStagedProfileImage(path)) {
    throw StateError('The new profile picture could not be stored encrypted.');
  }
  return sealed;
}

/// Plain pictures that versions up to 1.16.4 left under [support]
/// (`avatars` and `profile`).
///
/// The ones the saved [profile] still points at are first copied into
/// [vault] and the profile with the new paths is handed to [persist] (which
/// saves it and says whether it did); only then are the plain files
/// deleted. A picture that cannot be sealed yet (the vault being locked), or
/// a profile that cannot be saved, leaves every plain file in place for the
/// next start. Every other picture this app wrote there is deleted, and a
/// folder that ends up empty is removed; anything else in those folders is
/// left alone.
Future<void> removeLegacyPlainProfileImages({
  required Directory support,
  required UserProfile profile,
  required MediaVault vault,
  required Future<bool> Function(UserProfile sealed) persist,
}) async {
  final List<Directory> present = <Directory>[];
  for (final String name in kLegacyProfileImageFolders) {
    final Directory folder = Directory(
      '${support.path}${Platform.pathSeparator}$name',
    );
    if (await FileSystemEntity.type(folder.path, followLinks: false) ==
        FileSystemEntityType.directory) {
      present.add(folder);
    }
  }
  if (present.isEmpty) {
    return;
  }
  bool inLegacyFolder(String? path) {
    if (path == null || path.isEmpty) {
      return false;
    }
    final List<String> parts = path.split(_separator);
    return parts.length >= 2 &&
        kLegacyProfileImageFolders.contains(parts[parts.length - 2]);
  }

  final List<String> created = <String>[];
  Future<String?> sealed(String? path) async {
    final File? file = inLegacyFolder(path) ? File(path!) : null;
    if (file == null ||
        !file.existsSync() ||
        file.lengthSync() > kMaxOwnProfileImageBytes) {
      return null;
    }
    try {
      final String copy = await vault.putFile(file, deleteSource: false);
      created.add(copy);
      return copy;
    } on Object catch (error, stackTrace) {
      // Locked or no data key yet: the plain file stays, the next start tries
      // again.
      logZenError('Sealing an older profile picture failed', error, stackTrace);
      return null;
    }
  }

  UserProfile result = profile;
  final String? avatar = await sealed(profile.avatarPath);
  final String? cover = await sealed(profile.coverPath);
  if (avatar != null || cover != null) {
    result = profile.copyWith(
      avatarPath: avatar ?? profile.avatarPath,
      coverPath: cover ?? profile.coverPath,
    );
    bool saved = false;
    try {
      saved = await persist(result);
    } finally {
      if (!saved) {
        for (final String copy in created) {
          await deleteOwnProfileImage(copy);
        }
      }
    }
    if (!saved) {
      return;
    }
  }
  final Set<String> inUse = <String>{
    for (final String? path in <String?>[result.avatarPath, result.coverPath])
      if (inLegacyFolder(path)) path!.split(_separator).last,
  };
  for (final Directory folder in present) {
    try {
      await for (final FileSystemEntity entry in folder.list(
        followLinks: false,
      )) {
        final String name = entry.path.split(_separator).last;
        if (entry is File &&
            isOwnPlainProfileImage(name) &&
            !inUse.contains(name)) {
          await entry.delete();
        }
      }
      if (await folder.list(followLinks: false).isEmpty) {
        await folder.delete();
      }
    } on FileSystemException catch (error) {
      logZenWarning('Clearing an older profile picture folder failed: $error');
    }
  }
}

/// Clears what older versions left in the account folder (see
/// [removeLegacyPlainProfileImages]) for the saved profile [loaded]; [persist]
/// saves a profile whose paths moved into the vault and says whether it did.
typedef LegacyProfileImageTidier =
    Future<void> Function(
      UserProfile loaded,
      Future<bool> Function(UserProfile sealed) persist,
    );

/// The tidier of the app: this account's folder, this container's vault.
final Provider<LegacyProfileImageTidier> legacyProfileImageTidierProvider =
    Provider<LegacyProfileImageTidier>((Ref ref) {
      return (
        UserProfile loaded,
        Future<bool> Function(UserProfile) persist,
      ) async {
        final Directory support = await ref.read(
          supportDirectoryResolverProvider,
        )();
        await removeLegacyPlainProfileImages(
          support: support,
          profile: loaded,
          vault: ref.read(mediaVaultProvider),
          persist: persist,
        );
      };
    });

/// The plain bytes of your own photo or cover at [path] (vault or plain
/// file), or `null` when there is none or it cannot be read.
Future<Uint8List?> readOwnProfileImage(
  String? path, {
  int maxBytes = kMaxOwnProfileImageBytes,
}) async {
  if (path == null || path.isEmpty) {
    return null;
  }
  try {
    final File file = File(path);
    if (!file.existsSync()) {
      return null;
    }
    if (!isMediaVaultPath(path) && file.lengthSync() > maxBytes) {
      return null;
    }
    final Uint8List bytes = await readMediaFile(path);
    return bytes.length > maxBytes ? null : bytes;
  } on Object catch (error, stackTrace) {
    logZenError('Reading a profile picture failed', error, stackTrace);
    return null;
  }
}

/// Removes your old photo or cover: a vault file, or a plain file this app
/// wrote. Anything else is left alone.
Future<void> deleteOwnProfileImage(String? path) async {
  if (path == null || path.isEmpty) {
    return;
  }
  if (!isMediaVaultPath(path) && !isOwnPlainProfileImage(path)) {
    return;
  }
  try {
    final File file = File(path);
    if (file.existsSync()) {
      await file.delete();
    }
  } on Object catch (error, stackTrace) {
    logZenError('Removing an old profile picture failed', error, stackTrace);
  }
}
