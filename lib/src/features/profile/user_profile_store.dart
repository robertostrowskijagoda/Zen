import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/profile/user_profile.dart';

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
      final Map<String, dynamic> map =
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return UserProfile.fromJson(map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(UserProfile profile) async {
    final String jsonStr = jsonEncode(profile.toJson());
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

  Future<void> updateProfile({
    String? displayName,
    String? avatarPreset,
    String? avatarPath,
    bool clearAvatarPath = false,
    String? coverPath,
    bool clearCoverPath = false,
    String? customStatus,
    String? bio,
  }) async {
    final UserProfile next = state.copyWith(
      displayName: displayName,
      avatarPreset: avatarPreset,
      avatarPath: avatarPath,
      clearAvatarPath: clearAvatarPath,
      coverPath: coverPath,
      clearCoverPath: clearCoverPath,
      customStatus: customStatus,
      bio: bio,
      updatedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );
    state = next;
    await ref.read(userProfileStoreProvider).save(next);
  }
}
