import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/media/media_vault.dart';

// Your own photo and cover live in the media vault, encrypted like
// everything else of yours, not as plain files. The profile editor
// prepares a plain file first (checked, re-encoded); saving the profile
// moves it into the vault.

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

/// Whether [path] is a plain file this app wrote for the profile (and so
/// may delete once it is in the vault).
bool isOwnPlainProfileImage(String? path) {
  if (path == null || path.isEmpty || isMediaVaultPath(path)) {
    return false;
  }
  final String name = path.split(RegExp(r'[\\/]')).last;
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

/// Whether [profile] still points at a plain photo or cover file.
bool needsProfileImageSealing(UserProfile profile) => <String?>[
  profile.avatarPath,
  profile.coverPath,
].any((String? p) => p != null && p.isNotEmpty && !isMediaVaultPath(p));

/// [profile] with its photo and cover in the vault, or [profile] itself
/// when nothing had to move (or could not move yet).
Future<UserProfile> sealOwnProfileImages(
  UserProfile profile,
  ProfileImageSealer seal,
) async {
  String? avatar = profile.avatarPath;
  String? cover = profile.coverPath;
  bool changed = false;
  if (avatar != null && avatar.isNotEmpty && !isMediaVaultPath(avatar)) {
    final String? sealed = await seal(avatar);
    if (sealed != null && sealed != avatar) {
      avatar = sealed;
      changed = true;
    }
  }
  if (cover != null && cover.isNotEmpty && !isMediaVaultPath(cover)) {
    final String? sealed = await seal(cover);
    if (sealed != null && sealed != cover) {
      cover = sealed;
      changed = true;
    }
  }
  return changed
      ? profile.copyWith(avatarPath: avatar, coverPath: cover)
      : profile;
}

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
