import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

/// A store still locked for its first [lockedReads] reads, as before the
/// app password is given.
final class _LockedAtFirst implements UserProfileStore {
  _LockedAtFirst(this.saved, {this.lockedReads = 1});

  UserProfile? saved;
  int lockedReads;
  final List<UserProfile> writes = <UserProfile>[];

  @override
  Future<UserProfile?> load() async {
    if (lockedReads > 0) {
      lockedReads--;
      throw StateError('Encrypted storage is locked.');
    }
    return saved;
  }

  @override
  Future<void> save(UserProfile profile) async {
    writes.add(profile);
    saved = profile;
  }
}

void main() {
  test('a profile read while the store is still locked is read again, '
      'not left at the default (it looked reset after a restart)', () async {
    final _LockedAtFirst store = _LockedAtFirst(
      const UserProfile(displayName: 'Ada'),
    );
    final ProviderContainer container = ProviderContainer(
      overrides: [userProfileStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    expect(
      container.read(userProfileControllerProvider).displayName,
      isNot('Ada'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 1300));
    expect(container.read(userProfileControllerProvider).displayName, 'Ada');
  });

  test(
    'a change made before the profile was read keeps the saved fields',
    () async {
      final _LockedAtFirst store = _LockedAtFirst(
        const UserProfile(displayName: 'Ada', bio: 'Lubię góry'),
        lockedReads: 0,
      );
      final ProviderContainer container = ProviderContainer(
        overrides: [userProfileStoreProvider.overrideWithValue(store)],
      );
      addTearDown(container.dispose);
      await container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(customStatus: 'W drodze');
      expect(store.writes.single.displayName, 'Ada');
      expect(store.writes.single.bio, 'Lubię góry');
      expect(store.writes.single.customStatus, 'W drodze');
    },
  );
}
