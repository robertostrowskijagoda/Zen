import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/own_profile_images.dart';
import 'package:zen/src/features/profile/profile_cover.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';

Uint8List _bytes(int length, int seed) => Uint8List.fromList(
  List<int>.generate(length, (int i) => (i * 31 + seed) % 251),
);

void main() {
  late Directory support;
  late Directory temporary;
  late MediaVault vault;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('zen-own-');
    temporary = await Directory.systemTemp.createTemp('zen-own-tmp-');
    final Uint8List key = Uint8List.fromList(
      List<int>.generate(32, (int i) => i + 3),
    );
    vault = MediaVault(
      masterKey: () async => key,
      supportDirectory: () async => support,
      temporaryDirectory: () async => temporary,
    );
    MediaVault.current = vault;
  });

  tearDown(() async {
    MediaVault.current = null;
    for (final Directory dir in <Directory>[support, temporary]) {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    }
  });

  File plain(String name, Uint8List bytes) =>
      File('${support.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync(bytes);

  test('the photo and cover move into the vault, plain files go', () async {
    final Uint8List photo = _bytes(5000, 1);
    final Uint8List cover = _bytes(9000, 2);
    final File avatarFile = plain('avatar_1.jpg', photo);
    final File coverFile = plain('cover_1.jpg', cover);
    final UserProfile before = UserProfile(
      displayName: 'Ada',
      avatarPath: avatarFile.path,
      coverPath: coverFile.path,
      updatedAtMillis: 7,
    );
    expect(needsProfileImageSealing(before), isTrue);

    final UserProfile after = await sealOwnProfileImages(
      before,
      (String path) => sealProfileImageFile(vault, path),
    );
    expect(isMediaVaultPath(after.avatarPath), isTrue);
    expect(isMediaVaultPath(after.coverPath), isTrue);
    expect(needsProfileImageSealing(after), isFalse);
    expect(after.updatedAtMillis, 7);
    expect(after.displayName, 'Ada');
    // The plain copies are gone; what is on disk is not the picture.
    expect(avatarFile.existsSync(), isFalse);
    expect(coverFile.existsSync(), isFalse);
    expect(File(after.avatarPath!).readAsBytesSync(), isNot(photo));
    // Read back through the vault.
    expect(await readOwnProfileImage(after.avatarPath), photo);
    expect(await readOwnProfileImage(after.coverPath), cover);

    // Already sealed: nothing to do.
    expect(
      identical(
        await sealOwnProfileImages(
          after,
          (String path) => sealProfileImageFile(vault, path),
        ),
        after,
      ),
      isTrue,
    );

    // Old pictures are removed from the vault too.
    await deleteCoverImage(after.coverPath);
    await deleteOwnProfileImage(after.avatarPath);
    expect(File(after.coverPath!).existsSync(), isFalse);
    expect(File(after.avatarPath!).existsSync(), isFalse);
  });

  test('a file the app did not write is copied, not deleted', () async {
    final File mine = plain('holiday.jpg', _bytes(3000, 3));
    final String? sealed = await sealProfileImageFile(vault, mine.path);
    expect(isMediaVaultPath(sealed), isTrue);
    expect(mine.existsSync(), isTrue);
    await deleteOwnProfileImage(mine.path);
    expect(mine.existsSync(), isTrue);
  });

  test('a locked vault keeps the plain file for later', () async {
    final MediaVault locked = MediaVault(
      masterKey: () async => null,
      supportDirectory: () async => support,
      temporaryDirectory: () async => temporary,
    );
    final File avatar = plain('avatar_2.png', _bytes(100, 4));
    final UserProfile p = UserProfile(avatarPath: avatar.path);
    final UserProfile same = await sealOwnProfileImages(
      p,
      (String path) => sealProfileImageFile(locked, path),
    );
    expect(identical(same, p), isTrue);
    expect(avatar.existsSync(), isTrue);
    expect(await readOwnProfileImage(avatar.path), _bytes(100, 4));
    expect(await readOwnProfileImage(null), isNull);
    expect(await readOwnProfileImage('${support.path}/missing.jpg'), isNull);
  });

  test('a profile saved by an older version is moved at start', () async {
    final Uint8List photo = _bytes(2000, 5);
    final File avatar = plain('avatar_3.jpg', photo);
    final MemoryUserProfileStore store = MemoryUserProfileStore();
    await store.save(UserProfile(displayName: 'Ada', avatarPath: avatar.path));
    final ProviderContainer container = ProviderContainer(
      overrides: [
        userProfileStoreProvider.overrideWithValue(store),
        profileImageSealerProvider.overrideWithValue(
          (String path) => sealProfileImageFile(vault, path),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(userProfileControllerProvider);
    for (
      int i = 0;
      i < 100 &&
          !isMediaVaultPath(
            container.read(userProfileControllerProvider).avatarPath,
          );
      i++
    ) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final UserProfile now = container.read(userProfileControllerProvider);
    expect(isMediaVaultPath(now.avatarPath), isTrue);
    expect(avatar.existsSync(), isFalse);
    expect(isMediaVaultPath((await store.load())!.avatarPath), isTrue);
    expect(await readOwnProfileImage(now.avatarPath), photo);

    // A new photo from the editor is sealed when the profile is saved.
    final File next = plain('avatar_4.jpg', _bytes(1500, 6));
    await container
        .read(userProfileControllerProvider.notifier)
        .updateProfile(avatarPath: next.path);
    expect(
      isMediaVaultPath(
        container.read(userProfileControllerProvider).avatarPath,
      ),
      isTrue,
    );
    expect(next.existsSync(), isFalse);
  });
}
