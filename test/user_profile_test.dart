import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

void main() {
  group('UserProfile & UserProfileStore', () {
    test('default UserProfile has expected initial properties', () {
      const UserProfile profile = UserProfile();
      expect(profile.displayName, 'Ja');
      // No jargon by default: the status and the bio start empty.
      expect(profile.customStatus, isEmpty);
      expect(profile.bio, isEmpty);
      expect(profile.avatarPreset, 'zen_avatar_1');
    });

    test('UserProfile JSON serialization round-trips correctly', () {
      final UserProfile profile = const UserProfile(
        displayName: 'Robert',
        avatarPreset: 'zen_avatar_3',
        customStatus: 'Koduję w Zen',
        bio: 'Mesh network fan',
        updatedAtMillis: 123456789,
      );

      final Map<String, dynamic> json = profile.toJson();
      final UserProfile restored = UserProfile.fromJson(json);

      expect(restored.displayName, 'Robert');
      expect(restored.avatarPreset, 'zen_avatar_3');
      expect(restored.customStatus, 'Koduję w Zen');
      expect(restored.bio, 'Mesh network fan');
      expect(restored.updatedAtMillis, 123456789);
    });

    test('MemoryUserProfileStore saves and loads profile', () async {
      final MemoryUserProfileStore store = MemoryUserProfileStore();
      expect(await store.load(), isNull);

      final UserProfile profile = const UserProfile(displayName: 'Ada');
      await store.save(profile);

      final UserProfile? loaded = await store.load();
      expect(loaded?.displayName, 'Ada');
    });
  });
}
