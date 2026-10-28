import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';

/// The app's lock in a backup of the whole account: the restored device
/// opens with the same password, over its own master key.
void main() {
  Future<LocalAppSecurityService> device(
    MemorySecurityCredentialsStore store, {
    PlatformKeyVault? vault,
  }) async {
    final LocalAppSecurityService service = LocalAppSecurityService(
      credentialsStore: store,
      passwordIterations: 10,
      keyVault: vault ?? MemoryKeyVault(available: false),
    );
    await service.initialize(settings: const AppSettings());
    return service;
  }

  /// [copy] as it travels in the backup file.
  AppLockCopy travelled(AppLockCopy copy) =>
      AppLockCopy.fromJson(jsonDecode(jsonEncode(copy.toJson())))!;

  test('the old password opens the restored device, over this device\'s own '
      'master key; the panic password comes along', () async {
    final LocalAppSecurityService old = await device(
      MemorySecurityCredentialsStore(),
      vault: MemoryKeyVault(),
    );
    await old.setPassword('stare hasło 1');
    await old.setPanicPassword('panika 123');
    expect(await old.setBiometricUnlockEnabled(true), isTrue);
    final AppLockCopy copy = travelled((await old.lockCopy())!);
    expect(copy.password, isNotNull);
    expect(copy.panic, isNotNull);
    // What it carries tells the password, never what it opens.
    final String carried = jsonEncode(copy.toJson());
    final Uint8List oldKey = (await old.currentEncryptionKey())!;
    expect(carried, isNot(contains('stare hasło 1')));
    expect(
      await old.credentialsStore.read(appSecurityWrappedMasterKeyStorageKey),
      isNot(predicate<String?>((String? w) => carried.contains(w!))),
    );

    final MemorySecurityCredentialsStore store =
        MemorySecurityCredentialsStore();
    final LocalAppSecurityService restored = await device(
      store,
      vault: MemoryKeyVault(),
    );
    final Uint8List here = (await restored.currentEncryptionKey())!;
    expect(here, isNot(oldKey));

    // A wrong password changes nothing.
    expect(await restored.takeLockCopy(copy, 'złe hasło 1'), isFalse);
    expect(restored.hasPassword, isFalse);
    expect(await store.read(appSecurityDeviceMasterKeyStorageKey), isNotNull);

    expect(await restored.takeLockCopy(copy, 'stare hasło 1'), isTrue);
    expect(restored.hasPassword, isTrue);
    expect(restored.hasPanicPassword, isTrue);
    expect(restored.isLocked, isFalse);
    expect(await restored.currentEncryptionKey(), here);
    // No plain copy of the master key left, and nothing device-bound came
    // with it: biometric unlock is off until turned on here.
    expect(await store.read(appSecurityDeviceMasterKeyStorageKey), isNull);
    expect(await store.read(appSecuritySealedBiometricTokenStorageKey), isNull);
    expect(await store.read(appSecurityNeverLockMasterKeyStorageKey), isNull);
    expect(await restored.canUnlockWithBiometrics(), isFalse);

    restored.lock();
    expect(await restored.unlock('złe hasło 1'), isFalse);
    expect(await restored.unlock('stare hasło 1'), isTrue);
    expect(await restored.currentEncryptionKey(), here);

    // A start from scratch: locked, the old password opens it, the panic
    // password is the old one.
    final LocalAppSecurityService again = await device(store);
    expect(again.hasPassword, isTrue);
    expect(again.isLocked, isTrue);
    expect(await again.matchesPanicPassword('panika 123'), isTrue);
    expect(await again.unlock('panika 123'), isFalse);
    expect(await again.unlock('stare hasło 1'), isTrue);
    expect(await again.currentEncryptionKey(), here);
  });

  test(
    'a password set on this device already is replaced by the old one',
    () async {
      final LocalAppSecurityService old = await device(
        MemorySecurityCredentialsStore(),
      );
      await old.setPassword('stare hasło 1');
      final AppLockCopy copy = travelled((await old.lockCopy())!);

      final LocalAppSecurityService restored = await device(
        MemorySecurityCredentialsStore(),
      );
      await restored.setPassword('nowe hasło 1');
      await restored.setPanicPassword('panika tutaj');
      expect(await restored.takeLockCopy(copy, 'stare hasło 1'), isTrue);
      expect(restored.hasPanicPassword, isFalse);
      restored.lock();
      expect(await restored.unlock('nowe hasło 1'), isFalse);
      expect(await restored.unlock('stare hasło 1'), isTrue);
    },
  );

  test('an app used without a password: the copy says so', () async {
    final LocalAppSecurityService old = await device(
      MemorySecurityCredentialsStore(),
    );
    final AppLockCopy copy = (await old.lockCopy())!;
    expect(copy.password, isNull);
    expect(copy.panic, isNull);
    expect(copy.toJson(), isEmpty);
    expect(travelled(copy).password, isNull);

    final LocalAppSecurityService restored = await device(
      MemorySecurityCredentialsStore(),
    );
    expect(await restored.takeLockCopy(copy, 'cokolwiek 1'), isFalse);
    expect(restored.hasPassword, isFalse);
  });

  test(
    'a password that cannot be read never comes back as "no password"',
    () async {
      expect(AppLockCopy.fromJson(null), isNull);
      expect(AppLockCopy.fromJson('x'), isNull);
      expect(
        AppLockCopy.fromJson(<String, Object>{
          'password': <String, Object>{'a': 'argon2id'},
        }),
        isNull,
      );
      expect(
        AppLockCopy.fromJson(<String, Object>{
          'password': <String, Object>{
            'a': 'argon2id',
            'm': 64,
            't': 1,
            'p': 1,
            's': 'zz',
            'c': 'zz',
          },
        }),
        isNull,
      );
      // An absurd cost is refused rather than run.
      final MemorySecurityCredentialsStore store =
          MemorySecurityCredentialsStore();
      final LocalAppSecurityService old = await device(store);
      await old.setPassword('stare hasło 1');
      final Map<String, Object> json = (await old.lockCopy())!.toJson();
      final Map<String, Object?> password = Map<String, Object?>.from(
        json['password']! as Map,
      )..['m'] = 1 << 30;
      expect(
        AppLockCopy.fromJson(<String, Object?>{'password': password}),
        isNull,
      );

      // A stored cost this build cannot read: no lock in the backup at all.
      await store.write(appSecurityPasswordKdfStorageKey, 'nie json');
      expect(await old.lockCopy(), isNull);
    },
  );

  test('taking the password needs the app unlocked', () async {
    final LocalAppSecurityService old = await device(
      MemorySecurityCredentialsStore(),
    );
    await old.setPassword('stare hasło 1');
    final AppLockCopy copy = (await old.lockCopy())!;
    old.lock();
    await expectLater(
      old.takeLockCopy(copy, 'stare hasło 1'),
      throwsStateError,
    );
  });
}
