import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/media/media_temp_folder.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/profile/avatar_sanitizer.dart';
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

  test(
    'a photo from another device or a backup leaves no plain copy',
    () async {
      final Uint8List photo = _bytes(70000, 4);
      final String path = await sealIncomingProfileImage(
        vault,
        Stream<List<int>>.fromIterable(<List<int>>[
          photo.sublist(0, 1000),
          photo.sublist(1000),
        ]),
        cover: false,
        folder: () async => temporary,
      );
      expect(isMediaVaultPath(path), isTrue);
      expect(path, startsWith(support.path));
      expect(await readOwnProfileImage(path), photo);
      // The plain file in the temporary media folder went at once.
      expect(temporary.listSync(), isEmpty);

      // Cut off halfway: nothing plain stays either.
      await expectLater(
        sealIncomingProfileImage(
          vault,
          Stream<List<int>>.error(StateError('cut')),
          cover: true,
          folder: () async => temporary,
        ),
        throwsA(anything),
      );
      expect(temporary.listSync(), isEmpty);

      // A locked vault: the same.
      final MediaVault locked = MediaVault(
        masterKey: () async => null,
        supportDirectory: () async => support,
        temporaryDirectory: () async => temporary,
      );
      await expectLater(
        sealIncomingProfileImage(
          locked,
          Stream<List<int>>.value(photo),
          cover: true,
          folder: () async => temporary,
        ),
        throwsStateError,
      );
      expect(temporary.listSync(), isEmpty);
    },
  );

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

  test(
    'a new photo from the editor is sealed when the profile is saved',
    () async {
      final MemoryUserProfileStore store = MemoryUserProfileStore();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          userProfileStoreProvider.overrideWithValue(store),
          profileImageSealerProvider.overrideWithValue(
            (String path) => sealProfileImageFile(vault, path),
          ),
        ],
      );
      addTearDown(container.dispose);
      final Uint8List photo = _bytes(1500, 6);
      final File next = plain('avatar_4.jpg', photo);
      await container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(avatarPath: next.path);
      final UserProfile now = container.read(userProfileControllerProvider);
      expect(isMediaVaultPath(now.avatarPath), isTrue);
      expect(next.existsSync(), isFalse);
      expect(isMediaVaultPath((await store.load())!.avatarPath), isTrue);
      expect(await readOwnProfileImage(now.avatarPath), photo);
    },
  );

  group('no plain photo or cover under the account folder', () {
    late Directory staging;

    setUp(() {
      // The private temporary media folder, as the app names it.
      staging = Directory(
        '${temporary.path}${Platform.pathSeparator}'
        '${mediaTemporaryFolderName()}',
      )..createSync();
    });

    Future<Directory> stagingFolder() async => staging;

    List<String> filesUnder(Directory dir) => !dir.existsSync()
        ? <String>[]
        : <String>[
            for (final FileSystemEntity e in dir.listSync(
              recursive: true,
              followLinks: false,
            ))
              if (e is File) e.path,
          ];

    final Uint8List jpeg = Uint8List.fromList(<int>[
      0xFF,
      0xD8,
      0xFF,
      0xE0,
      ...List<int>.generate(400, (int i) => (i * 7 + 3) % 251),
    ]);
    final Uint8List png = img.encodePng(img.Image(width: 90, height: 30));

    ProviderContainer containerWith(MediaVault v, MemoryUserProfileStore s) {
      final ProviderContainer c = ProviderContainer(
        overrides: [
          userProfileStoreProvider.overrideWithValue(s),
          profileImageSealerProvider.overrideWithValue(
            (String path) => sealProfileImageFile(v, path),
          ),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    MediaVault lockedVault() => MediaVault(
      masterKey: () async => null,
      supportDirectory: () async => support,
      temporaryDirectory: () async => temporary,
    );

    test('staging and sealing write nothing plain under it', () async {
      final String avatar = await AvatarSanitizer.validateAndStoreAvatarBytes(
        rawBytes: jpeg,
        folder: stagingFolder,
      );
      final String cover = await storeCoverBytes(
        bytes: png,
        folder: stagingFolder,
      );
      // Staged: in the private temporary folder, and nothing else anywhere.
      expect(avatar, startsWith(staging.path));
      expect(cover, startsWith(staging.path));
      expect(isStagedProfileImage(avatar), isTrue);
      expect(isStagedProfileImage(cover), isTrue);
      expect(File(avatar).readAsBytesSync(), jpeg);
      expect(support.listSync(recursive: true), isEmpty);

      final MemoryUserProfileStore store = MemoryUserProfileStore();
      final ProviderContainer container = containerWith(vault, store);
      await container
          .read(userProfileControllerProvider.notifier)
          .updateProfile(avatarPath: avatar, coverPath: cover);

      final UserProfile now = container.read(userProfileControllerProvider);
      expect(isMediaVaultPath(now.avatarPath), isTrue);
      expect(isMediaVaultPath(now.coverPath), isTrue);
      expect(await readOwnProfileImage(now.avatarPath), jpeg);
      expect(staging.listSync(), isEmpty);
      for (final String path in filesUnder(support)) {
        expect(isMediaVaultPath(path), isTrue, reason: path);
      }
      for (final String name in kLegacyProfileImageFolders) {
        expect(
          Directory(
            '${support.path}${Platform.pathSeparator}$name',
          ).existsSync(),
          isFalse,
        );
      }
    });

    test('a picture that is refused leaves nothing behind', () async {
      final Uint8List exe = Uint8List.fromList(<int>[
        0x4D,
        0x5A,
        ...List<int>.filled(30, 1),
      ]);
      final Uint8List undecodable = Uint8List.fromList(<int>[
        0xFF,
        0xD8,
        ...List<int>.filled(30, 0),
      ]);
      for (final Uint8List bytes in <Uint8List>[
        Uint8List(0),
        exe,
        Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
      ]) {
        await expectLater(
          AvatarSanitizer.validateAndStoreAvatarBytes(
            rawBytes: bytes,
            folder: stagingFolder,
          ),
          throwsA(isA<FormatException>()),
        );
      }
      await expectLater(
        AvatarSanitizer.validateAndStoreAvatarBytes(
          rawBytes: Uint8List.fromList(<int>[
            ...'GIF89a'.codeUnits,
            ...List<int>.filled(10, 0),
          ]),
          folder: stagingFolder,
        ),
        throwsA(isA<FormatException>()),
      );
      for (final Uint8List bytes in <Uint8List>[exe, undecodable]) {
        await expectLater(
          storeCoverBytes(bytes: bytes, folder: stagingFolder),
          throwsA(isA<FormatException>()),
        );
      }
      // The folder cannot be had, or cannot be written into.
      await expectLater(
        AvatarSanitizer.validateAndStoreAvatarBytes(
          rawBytes: jpeg,
          folder: () async => throw StateError('no private folder'),
        ),
        throwsStateError,
      );
      final File notAFolder = plain('not_a_folder', _bytes(10, 1));
      await expectLater(
        storeCoverBytes(
          bytes: png,
          folder: () async => Directory(notAFolder.path),
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(support.listSync(recursive: true).whereType<File>().length, 1);
      expect(staging.listSync(), isEmpty);
    });

    test(
      'killed between staging and sealing: the next start clears it',
      () async {
        final String avatar = await AvatarSanitizer.validateAndStoreAvatarBytes(
          rawBytes: jpeg,
          folder: stagingFolder,
        );
        final String cover = await storeCoverBytes(
          bytes: png,
          folder: stagingFolder,
        );
        expect(File(avatar).existsSync(), isTrue);
        expect(File(cover).existsSync(), isTrue);
        expect(support.listSync(recursive: true), isEmpty);

        // What every start does.
        await deleteMediaTemporaryFolders(
          temporary,
          mediaTemporaryFolderName(),
        );
        expect(File(avatar).existsSync(), isFalse);
        expect(File(cover).existsSync(), isFalse);
        expect(support.listSync(recursive: true), isEmpty);
      },
    );

    test(
      'a vault that is locked refuses the save, the file stays for a retry',
      () async {
        final String avatar = await AvatarSanitizer.validateAndStoreAvatarBytes(
          rawBytes: jpeg,
          folder: stagingFolder,
        );
        final MemoryUserProfileStore store = MemoryUserProfileStore();
        final ProviderContainer container = containerWith(lockedVault(), store);
        await expectLater(
          container
              .read(userProfileControllerProvider.notifier)
              .updateProfile(avatarPath: avatar),
          throwsStateError,
        );
        // No profile points at a file the next start would clear.
        expect(
          container.read(userProfileControllerProvider).avatarPath,
          isNull,
        );
        expect((await store.load()), isNull);
        expect(File(avatar).existsSync(), isTrue);
        expect(support.listSync(recursive: true), isEmpty);

        final String? sealed = await sealProfileImageFile(vault, avatar);
        expect(isMediaVaultPath(sealed), isTrue);
        expect(File(avatar).existsSync(), isFalse);
      },
    );

    group('what older versions left', () {
      final Uint8List photo = _bytes(3000, 11);
      final Uint8List other = _bytes(2000, 12);

      File legacy(String folder, String name, Uint8List bytes) {
        final Directory dir = Directory(
          '${support.path}${Platform.pathSeparator}$folder',
        )..createSync(recursive: true);
        return File('${dir.path}${Platform.pathSeparator}$name')
          ..writeAsBytesSync(bytes);
      }

      Directory folder(String name) =>
          Directory('${support.path}${Platform.pathSeparator}$name');

      test(
        'the one in use is sealed first, the rest and the folders go',
        () async {
          final File mine = legacy('avatars', 'avatar_2.jpg', photo);
          final File old = legacy('avatars', 'avatar_1.jpg', other);
          final File oldCover = legacy('profile', 'cover_1.jpg', other);
          UserProfile? saved;
          await removeLegacyPlainProfileImages(
            support: support,
            profile: UserProfile(displayName: 'Ada', avatarPath: mine.path),
            vault: vault,
            persist: (UserProfile p) async {
              saved = p;
              return true;
            },
          );
          expect(saved!.displayName, 'Ada');
          expect(isMediaVaultPath(saved!.avatarPath), isTrue);
          expect(await readOwnProfileImage(saved!.avatarPath), photo);
          expect(mine.existsSync(), isFalse);
          expect(old.existsSync(), isFalse);
          expect(oldCover.existsSync(), isFalse);
          expect(folder('avatars').existsSync(), isFalse);
          expect(folder('profile').existsSync(), isFalse);
        },
      );

      test('nothing in use is lost while the vault is locked', () async {
        final File mine = legacy('profile', 'cover_2.jpg', photo);
        final File old = legacy('avatars', 'avatar_1.jpg', other);
        await removeLegacyPlainProfileImages(
          support: support,
          profile: UserProfile(coverPath: mine.path),
          vault: lockedVault(),
          persist: (UserProfile p) async => fail('nothing was sealed'),
        );
        expect(mine.existsSync(), isTrue);
        expect(old.existsSync(), isFalse);
        expect(folder('avatars').existsSync(), isFalse);
        expect(folder('profile').existsSync(), isTrue);
      });

      test('a profile that cannot be saved keeps every plain file', () async {
        final File mine = legacy('avatars', 'avatar_2.jpg', photo);
        final File old = legacy('avatars', 'avatar_1.jpg', other);
        await removeLegacyPlainProfileImages(
          support: support,
          profile: UserProfile(avatarPath: mine.path),
          vault: vault,
          persist: (UserProfile p) async => false,
        );
        expect(mine.existsSync(), isTrue);
        expect(old.existsSync(), isTrue);
        // The copy made for the refused profile is not left behind.
        expect(filesUnder(folder(kMediaVaultFolder)), isEmpty);

        await expectLater(
          removeLegacyPlainProfileImages(
            support: support,
            profile: UserProfile(avatarPath: mine.path),
            vault: vault,
            persist: (UserProfile p) async => throw StateError('locked'),
          ),
          throwsStateError,
        );
        expect(mine.existsSync(), isTrue);
        expect(old.existsSync(), isTrue);
        expect(filesUnder(folder(kMediaVaultFolder)), isEmpty);
      });

      test('what the app did not write is left alone', () async {
        final File notes = legacy('avatars', 'notes.txt', other);
        legacy('avatars', 'avatar_1.jpg', other);
        await removeLegacyPlainProfileImages(
          support: support,
          profile: const UserProfile(),
          vault: vault,
          persist: (UserProfile p) async => fail('nothing to save'),
        );
        expect(notes.existsSync(), isTrue);
        expect(filesUnder(folder('avatars')), <String>[notes.path]);
      });

      test('the start clears them for the saved profile', () async {
        final File mine = legacy('profile', 'cover_2.jpg', photo);
        legacy('avatars', 'avatar_1.jpg', other);
        final MemoryUserProfileStore store = MemoryUserProfileStore();
        await store.save(UserProfile(displayName: 'Ada', coverPath: mine.path));
        final ProviderContainer container = ProviderContainer(
          overrides: [
            userProfileStoreProvider.overrideWithValue(store),
            legacyProfileImageTidierProvider.overrideWithValue(
              (
                UserProfile loaded,
                Future<bool> Function(UserProfile) persist,
              ) => removeLegacyPlainProfileImages(
                support: support,
                profile: loaded,
                vault: vault,
                persist: persist,
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.read(userProfileControllerProvider);
        for (int i = 0; i < 100 && folder('profile').existsSync(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(folder('profile').existsSync(), isFalse);
        expect(folder('avatars').existsSync(), isFalse);
        final UserProfile now = container.read(userProfileControllerProvider);
        expect(now.displayName, 'Ada');
        expect(isMediaVaultPath(now.coverPath), isTrue);
        expect(isMediaVaultPath((await store.load())!.coverPath), isTrue);
        expect(await readOwnProfileImage(now.coverPath), photo);
      });
    });
  });
}
