import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_data_reset.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  late Directory support;
  late File thread;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('zen-wipe-');
    final String sep = Platform.pathSeparator;
    thread = File('${support.path}${sep}data${sep}hidden${sep}abc.zenbin')
      ..createSync(recursive: true)
      ..writeAsStringSync('szyfrogram');
  });

  tearDown(() async {
    if (await support.exists()) {
      await support.delete(recursive: true);
    }
  });

  test('a wipe destroys the keys before it touches the files', () async {
    final MemorySecurityCredentialsStore credentials =
        MemorySecurityCredentialsStore();
    final MemoryKeyVault vault = MemoryKeyVault();
    final LocalAppSecurityService security = LocalAppSecurityService(
      credentialsStore: credentials,
      passwordIterations: 10,
      keyVault: vault,
    );
    await security.initialize(settings: const AppSettings());
    await security.setPassword('sekret12');
    await security.setBiometricUnlockEnabled(true);
    await security.setPanicPassword('panika123');
    expect(
      await credentials.read(appSecurityWrappedMasterKeyStorageKey),
      isNotNull,
    );
    expect(
      await credentials.read(appSecuritySealedBiometricTokenStorageKey),
      isNotNull,
    );

    bool filesStillThereWhileShredding = false;
    await shredKeysThenDeleteLocalData(
      destroyKeys: () async {
        filesStillThereWhileShredding = thread.existsSync();
        await security.reset();
      },
      supportDirectory: support,
    );

    expect(
      filesStillThereWhileShredding,
      isTrue,
      reason: 'a crash during the deletion must find the keys gone already',
    );
    for (final String key in <String>[
      appSecurityWrappedMasterKeyStorageKey,
      appSecurityPasswordHashStorageKey,
      appSecuritySealedBiometricTokenStorageKey,
      appSecurityPanicPasswordHashStorageKey,
    ]) {
      expect(await credentials.read(key), isNull, reason: key);
    }
    expect(vault.wipes, 1, reason: 'the hardware key is destroyed too');
    expect(thread.existsSync(), isFalse);
    expect(support.existsSync(), isTrue);
    expect(security.hasPassword, isFalse);
    expect(await security.verifyPassword('sekret12'), isFalse);
  });

  test('when destroying the keys fails the files still go, and the keys are '
      'tried again', () async {
    int attempts = 0;
    await shredKeysThenDeleteLocalData(
      destroyKeys: () async {
        attempts++;
        if (attempts == 1) {
          throw StateError('secure storage busy');
        }
      },
      supportDirectory: support,
    );
    expect(attempts, 2);
    expect(thread.existsSync(), isFalse);
    expect(support.existsSync(), isTrue);
  });

  test('a wipe also empties the caches and removes what Zen left in '
      'shared folders and exported on purpose', () async {
    final String sep = Platform.pathSeparator;
    final Directory cache = Directory('${support.path}-cache')
      ..createSync(recursive: true);
    final Directory sharedTemp = Directory('${support.path}-tmp')
      ..createSync(recursive: true);
    final Directory documents = Directory('${support.path}-docs')
      ..createSync(recursive: true);
    addTearDown(() async {
      for (final Directory dir in <Directory>[cache, sharedTemp, documents]) {
        if (dir.existsSync()) {
          await dir.delete(recursive: true);
        }
      }
    });
    final File cached = File('${cache.path}${sep}shared_apk${sep}zen.apk')
      ..createSync(recursive: true);
    final File media = File(
      '${sharedTemp.path}$sep${mediaTemporaryFolderName()}${sep}a.m4a',
    )..createSync(recursive: true);
    final File otherZen = File('${sharedTemp.path}${sep}zen_rec_1.webm')
      ..createSync();
    final File otherProfile = File(
      '${sharedTemp.path}${sep}zen-media-other-profile${sep}b.m4a',
    )..createSync(recursive: true);
    final File foreign = File('${sharedTemp.path}${sep}inny-program.tmp')
      ..createSync();
    final File saved = File('${documents.path}${sep}Zen${sep}raport.pdf')
      ..createSync(recursive: true);
    final File notes = File('${documents.path}${sep}notatki.txt')..createSync();
    final File exported = File('${documents.path}${sep}rozmowa.webm')
      ..createSync();
    final ExportedFilesIndex exports = ExportedFilesIndex(
      MemorySecurityCredentialsStore(),
    );
    await exports.remember(exported.path);

    await shredKeysThenDeleteLocalData(
      destroyKeys: () async {},
      supportDirectory: support,
      scratch: ZenScratchPlaces(
        ownFolders: <Directory>[cache],
        sharedFolders: <Directory>[sharedTemp],
        namedFolders: <Directory>[documents],
      ),
      deleteExports: exports.deleteAll,
    );

    expect(cached.existsSync(), isFalse);
    expect(cache.existsSync(), isTrue);
    expect(media.existsSync(), isFalse);
    expect(otherZen.existsSync(), isTrue, reason: 'not this instance\'s');
    expect(otherProfile.existsSync(), isTrue, reason: 'another profile');
    expect(foreign.existsSync(), isTrue, reason: 'not from Zen');
    expect(saved.existsSync(), isFalse);
    expect(notes.existsSync(), isTrue, reason: 'not from Zen');
    expect(exported.existsSync(), isFalse);
    expect(await exports.paths(), isEmpty);
  });

  test('the default profile\'s wipe leaves the test profiles alone', () async {
    final String sep = Platform.pathSeparator;
    final File other = File(
      '${support.path}${sep}profiles${sep}anna${sep}k.bin',
    )..createSync(recursive: true);
    await shredKeysThenDeleteLocalData(
      destroyKeys: () async {},
      supportDirectory: support,
      keepInSupport: const <String>{'profiles'},
    );
    expect(thread.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);

    // A profile's own wipe (nothing to keep) takes its whole folder.
    await shredKeysThenDeleteLocalData(
      destroyKeys: () async {},
      supportDirectory: Directory('${support.path}${sep}profiles${sep}anna'),
    );
    expect(other.existsSync(), isFalse);
  });

  test('a folder that holds the support folder is never emptied', () async {
    final File inside = File(
      '${support.path}${Platform.pathSeparator}keep-out.txt',
    )..createSync();
    final File sibling = File(
      '${support.parent.path}${Platform.pathSeparator}'
      'zen-wipe-sibling-${DateTime.now().microsecondsSinceEpoch}.txt',
    )..createSync();
    addTearDown(() {
      if (sibling.existsSync()) {
        sibling.deleteSync();
      }
    });
    await shredKeysThenDeleteLocalData(
      destroyKeys: () async {},
      supportDirectory: support,
      scratch: ZenScratchPlaces(ownFolders: <Directory>[support.parent]),
    );
    expect(inside.existsSync(), isFalse);
    expect(sibling.existsSync(), isTrue);
  });
}
