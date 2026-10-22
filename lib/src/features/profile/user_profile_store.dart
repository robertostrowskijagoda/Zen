import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';

abstract interface class UserProfileStore {
  Future<UserProfile?> load();
  Future<void> save(UserProfile profile);
}

final class MemoryUserProfileStore implements UserProfileStore {
  UserProfile? _profile;

  @override
  Future<UserProfile?> load() async => _profile;

  @override
  Future<void> save(UserProfile profile) async {
    _profile = profile;
  }
}

final class FileUserProfileStore implements UserProfileStore {
  FileUserProfileStore({required this.store, this.storageKey = 'user_profile'});

  final FileBinaryStore store;
  final String storageKey;

  @override
  Future<UserProfile?> load() async {
    try {
      final Uint8List? bytes = await store.read(storageKey);
      if (bytes == null || bytes.isEmpty) {
        return null;
      }
      final Object? json = jsonDecode(utf8.decode(bytes));
      if (store.heldAsNewer(storageKey, json, current: kFirstFormatVersion) ||
          json is! Map<String, dynamic>) {
        return null;
      }
      final UserProfile profile = UserProfile.fromJson(json);
      _carried = unknownFields(json, profile.toJson());
      return profile;
    } catch (_) {
      return null;
    }
  }

  /// Fields of the file this build does not know (a newer build's),
  /// written back as read.
  Map<String, Object?> _carried = const <String, Object?>{};

  @override
  Future<void> save(UserProfile profile) async {
    final String jsonStr = jsonEncode(
      withCarriedFields(withFormatVersion(profile.toJson()), _carried),
    );
    await store.write(storageKey, Uint8List.fromList(utf8.encode(jsonStr)));
  }
}

final Provider<UserProfileStore> userProfileStoreProvider =
    Provider<UserProfileStore>((Ref ref) {
      return MemoryUserProfileStore();
    });

final NotifierProvider<UserProfileController, UserProfile>
userProfileControllerProvider =
    NotifierProvider<UserProfileController, UserProfile>(
      UserProfileController.new,
    );

final class UserProfileController extends Notifier<UserProfile> {
  bool _hydrationScheduled = false;

  @override
  UserProfile build() {
    if (!_hydrationScheduled) {
      _hydrationScheduled = true;
      // Nothing awaits this, so an error would escape as an unhandled async
      // error instead of a log line.
      unawaitedLogged(
        Future<void>.microtask(_hydrate),
        context: 'Hydrating the user profile failed',
      );
    }
    return const UserProfile();
  }

  Future<void> _hydrate() async {
    // The microtask can be picked up after the container was torn down.
    if (!ref.mounted) {
      return;
    }
    final UserProfile? persisted = await ref
        .read(userProfileStoreProvider)
        .load();
    if (!ref.mounted) {
      return;
    }
    if (persisted != null) {
      state = persisted;
    }
  }

  /// The vault sealer, or `null` where there is none (it cannot be built).
  ProfileImageSealer? _sealer() {
    try {
      return ref.read(profileImageSealerProvider);
    } on Object catch (error, stackTrace) {
      logZenError('The media vault is not available', error, stackTrace);
      return null;
    }
  }

  Future<void> updateProfile({
    String? displayName,
    String? avatarPreset,
    String? avatarPath,
    bool clearAvatarPath = false,
    String? coverPath,
    bool clearCoverPath = false,
    String? customStatus,
    String? bio,
    Map<String, String>? visibility,
    List<String>? nationalities,
  }) async {
    UserProfile next = state.copyWith(
      displayName: displayName,
      avatarPreset: avatarPreset,
      avatarPath: avatarPath,
      clearAvatarPath: clearAvatarPath,
      coverPath: coverPath,
      clearCoverPath: clearCoverPath,
      customStatus: customStatus,
      bio: bio,
      visibility: visibility,
      nationalities: nationalities,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    // A new photo or cover is a plain file from the editor: into the vault.
    if (needsProfileImageSealing(next)) {
      final ProfileImageSealer? seal = _sealer();
      if (seal != null) {
        next = await sealOwnProfileImages(next, seal);
      }
      if (!ref.mounted) {
        return;
      }
    }
    state = next;
    await ref.read(userProfileStoreProvider).save(next);
  }
}
