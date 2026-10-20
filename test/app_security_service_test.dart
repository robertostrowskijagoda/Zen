import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  test(
    'security service locks and unlocks encrypted state with a password',
    () async {
      final LocalAppSecurityService service = LocalAppSecurityService(
        credentialsStore: MemorySecurityCredentialsStore(),
        passwordIterations: 10,
      );
      await service.initialize(settings: const AppSettings());
      expect(service.isReady, isTrue);
      expect(service.hasPassword, isFalse);
      expect(service.isLocked, isFalse);

      await service.setPassword('sekret12');
      await service.applySettings(
        const AppSettings(
          lockMode: AppLockMode.background,
          backgroundLockDelaySeconds: 7,
        ),
      );

      expect(service.hasPassword, isTrue);
      expect(service.encryptionEnabled, isTrue);
      expect(service.isLocked, isFalse);
      expect(await service.currentEncryptionKey(), isNotNull);

      service.lock();
      expect(service.isLocked, isTrue);
      expect(await service.currentEncryptionKey(), isNull);
      expect(await service.unlock('zle-haslo'), isFalse);
      expect(service.isLocked, isTrue);
      expect(await service.unlock('sekret12'), isTrue);
      expect(service.isLocked, isFalse);
      expect(await service.currentEncryptionKey(), isNotNull);
    },
  );

  test(
    'encryption stays enabled and the master key survives password changes',
    () async {
      final LocalAppSecurityService service = LocalAppSecurityService(
        credentialsStore: MemorySecurityCredentialsStore(),
        passwordIterations: 10,
      );
      await service.initialize(settings: const AppSettings());
      final Uint8List deviceKey = (await service.currentEncryptionKey())!;

      await service.setPassword('sekret12');
      expect(service.encryptionEnabled, isTrue);
      expect(await service.currentEncryptionKey(), deviceKey);

      await service.applySettings(
        const AppSettings(lockMode: AppLockMode.never),
      );
      // Encryption can no longer be toggled off.
      expect(service.encryptionEnabled, isTrue);
      expect(service.isLocked, isFalse);
      expect(await service.currentEncryptionKey(), deviceKey);

      // Changing the password keeps the same master key and invalidates the
      // old password.
      await service.setPassword('nowe-haslo');
      expect(await service.currentEncryptionKey(), deviceKey);
      service.lock();
      expect(await service.unlock('sekret12'), isFalse);
      expect(await service.unlock('nowe-haslo'), isTrue);
      expect(await service.currentEncryptionKey(), deviceKey);
    },
  );

  test(
    'biometric unlock opens the master key sealed by the hardware vault',
    () async {
      final MemorySecurityCredentialsStore credentials =
          MemorySecurityCredentialsStore();
      final MemoryKeyVault vault = MemoryKeyVault();
      final LocalAppSecurityService service = LocalAppSecurityService(
        credentialsStore: credentials,
        passwordIterations: 10,
        keyVault: vault,
      );
      await service.initialize(settings: const AppSettings());
      final Uint8List deviceKey = (await service.currentEncryptionKey())!;

      await service.setPassword('sekret12');
      // Biometric unlock is off by default; the person turns it on.
      expect(await service.setBiometricUnlockEnabled(true), isTrue);
      service.lock();

      // Nothing usable lies around in plain storage.
      final String? sealed = await credentials.read(
        appSecuritySealedBiometricTokenStorageKey,
      );
      expect(sealed, isNotNull);
      expect(sealed, isNot(contains(securityHexFromBytes(deviceKey))));
      expect(await service.canUnlockWithBiometrics(), isTrue);

      // The person says no: still locked.
      vault.approve = false;
      expect(await service.unlockWithBiometrics(), isFalse);
      expect(service.isLocked, isTrue);

      vault.approve = true;
      expect(await service.unlockWithBiometrics(), isTrue);
      expect(service.isLocked, isFalse);
      expect(await service.currentEncryptionKey(), deviceKey);

      // Re-confirming does not change the lock state.
      expect(await service.confirmWithBiometrics(reason: 'test'), isTrue);
      vault.approve = false;
      expect(await service.confirmWithBiometrics(reason: 'test'), isFalse);
      expect(service.isLocked, isFalse);
      expect(vault.prompts, 4);
    },
  );

  test('without a hardware vault there is no biometric unlock', () async {
    final MemorySecurityCredentialsStore credentials =
        MemorySecurityCredentialsStore();
    final LocalAppSecurityService service = LocalAppSecurityService(
      credentialsStore: credentials,
      passwordIterations: 10,
    );
    await service.initialize(settings: const AppSettings());
    await service.setPassword('sekret12');
    service.lock();
    expect(await service.canUnlockWithBiometrics(), isFalse);
    expect(await service.unlockWithBiometrics(), isFalse);
    expect(
      await credentials.read(appSecuritySealedBiometricTokenStorageKey),
      isNull,
    );
    expect(await service.keyProtection(), 'brak');
  });

  test(
    'a new password uses Argon2id and the panic wipe kills the vault key',
    () async {
      final MemorySecurityCredentialsStore credentials =
          MemorySecurityCredentialsStore();
      final MemoryKeyVault vault = MemoryKeyVault();
      final LocalAppSecurityService service = LocalAppSecurityService(
        credentialsStore: credentials,
        passwordIterations: 10,
        keyVault: vault,
      );
      await service.initialize(settings: const AppSettings());
      await service.setPassword('sekret12');
      final String? kdf = await credentials.read(
        appSecurityPasswordKdfStorageKey,
      );
      expect(kdf, contains('argon2id'));
      service.lock();
      expect(await service.unlock('sekret12'), isTrue);

      await service.reset();
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNull,
      );
      expect(await credentials.read(appSecurityPasswordKdfStorageKey), isNull);
    },
  );

  test(
    'device mode encrypts without a password using the device master key',
    () async {
      final MemorySecurityCredentialsStore credentials =
          MemorySecurityCredentialsStore();
      final LocalAppSecurityService service = LocalAppSecurityService(
        credentialsStore: credentials,
        passwordIterations: 10,
      );
      await service.initialize(settings: const AppSettings());

      expect(service.encryptionEnabled, isTrue);
      expect(service.hasPassword, isFalse);
      expect(service.isLocked, isFalse);
      final Uint8List? key = await service.currentEncryptionKey();
      expect(key, isNotNull);
      expect(key!.length, appSecurityMasterKeyLengthBytes);
      expect(
        await credentials.read(appSecurityDeviceMasterKeyStorageKey),
        securityHexFromBytes(key),
      );
      // Without a password there is nothing to lock against.
      service.lock();
      expect(service.isLocked, isFalse);
      expect(service.canQuickLock, isFalse);
    },
  );

  test('panic password is stored separately and cleared on demand', () async {
    final LocalAppSecurityService service = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
    );
    await service.initialize(settings: const AppSettings());
    await service.setPassword('sekret12');

    expect(service.hasPanicPassword, isFalse);
    expect(await service.matchesPanicPassword('panika123'), isFalse);

    await service.setPanicPassword('panika123');
    expect(service.hasPanicPassword, isTrue);
    expect(await service.matchesPanicPassword('panika123'), isTrue);
    expect(await service.matchesPanicPassword('sekret12'), isFalse);
    expect(await service.matchesPanicPassword('inne-haslo'), isFalse);

    // The panic password never unlocks the app.
    service.lock();
    expect(await service.unlock('panika123'), isFalse);
    expect(service.isLocked, isTrue);

    await service.clearPanicPassword();
    expect(service.hasPanicPassword, isFalse);
    expect(await service.matchesPanicPassword('panika123'), isFalse);
  });

  test(
    'reset clears the panic password together with the main password',
    () async {
      final LocalAppSecurityService service = LocalAppSecurityService(
        credentialsStore: MemorySecurityCredentialsStore(),
        passwordIterations: 10,
      );
      await service.initialize(settings: const AppSettings());
      await service.setPassword('sekret12');
      await service.setPanicPassword('panika123');
      service.lock();

      await service.reset();

      expect(service.hasPassword, isFalse);
      expect(service.hasPanicPassword, isFalse);
      expect(service.isLocked, isFalse);
      expect(await service.verifyPassword('sekret12'), isFalse);
      expect(await service.matchesPanicPassword('panika123'), isFalse);
    },
  );

  test('verifyPassword checks the main password without unlocking', () async {
    final LocalAppSecurityService service = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
    );
    await service.initialize(settings: const AppSettings());

    // Without any password there is nothing to verify against.
    expect(await service.verifyPassword('sekret12'), isFalse);

    await service.setPassword('sekret12');
    expect(await service.verifyPassword('sekret12'), isTrue);
    expect(await service.verifyPassword('zle-haslo'), isFalse);

    service.lock();
    expect(await service.verifyPassword('zle-haslo'), isFalse);
    expect(await service.verifyPassword('sekret12'), isTrue);
    // Pure check: the lock state must not change.
    expect(service.isLocked, isTrue);
  });

  test('the main and the panic password can never be the same', () async {
    final LocalAppSecurityService service = LocalAppSecurityService(
      credentialsStore: MemorySecurityCredentialsStore(),
      passwordIterations: 10,
    );
    await service.initialize(settings: const AppSettings());
    await service.setPassword('sekret12');

    // The panic password may not be the main one: the next unlock would
    // wipe everything.
    await expectLater(
      service.setPanicPassword('sekret12'),
      throwsA(isA<AppPasswordConflictException>()),
    );
    expect(service.hasPanicPassword, isFalse);

    await service.setPanicPassword('panika123');
    // …and the main password may not become the panic one.
    await expectLater(
      service.setPassword('panika123'),
      throwsA(
        isA<AppPasswordConflictException>().having(
          (AppPasswordConflictException e) => e.message,
          'message',
          kAppPasswordEqualsPanicMessage,
        ),
      ),
    );
    expect(await service.verifyPassword('sekret12'), isTrue);
    expect(await service.verifyPassword('panika123'), isFalse);
    expect(await service.matchesPanicPassword('panika123'), isTrue);

    // Different passwords keep working.
    await service.setPassword('nowe-haslo');
    expect(await service.verifyPassword('nowe-haslo'), isTrue);
  });

  group('biometric unlock on a vault where only the app asks (Windows)', () {
    late MemorySecurityCredentialsStore credentials;
    late MemoryKeyVault vault;
    late LocalAppSecurityService service;

    setUp(() async {
      credentials = MemorySecurityCredentialsStore();
      vault = MemoryKeyVault(enforcesUserPresence: false);
      service = LocalAppSecurityService(
        credentialsStore: credentials,
        passwordIterations: 10,
        keyVault: vault,
      );
      await service.initialize(settings: const AppSettings());
      await service.setPassword('sekret12');
    });

    test('nothing is sealed until the person turns it on', () async {
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNull,
      );
      expect(await service.canUnlockWithBiometrics(), isFalse);
      final BiometricUnlockStatus status = await service
          .biometricUnlockStatus();
      expect(status.available, isTrue);
      expect(status.enabled, isFalse);
      expect(status.hardwareEnforced, isFalse);

      // A password unlock does not seal it either.
      service.lock();
      expect(await service.unlock('sekret12'), isTrue);
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNull,
      );
    });

    test('turned on it unlocks; turned off the sealed key and the hardware '
        'key are gone', () async {
      expect(await service.setBiometricUnlockEnabled(true), isTrue);
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNotNull,
      );
      expect((await service.biometricUnlockStatus()).enabled, isTrue);
      service.lock();
      expect(await service.unlockWithBiometrics(), isTrue);
      expect(service.isLocked, isFalse);

      expect(await service.setBiometricUnlockEnabled(false), isTrue);
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNull,
      );
      expect(vault.wipes, 1);
      expect(await service.canUnlockWithBiometrics(), isFalse);
      // And it stays off across unlocks.
      service.lock();
      expect(await service.unlock('sekret12'), isTrue);
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNull,
      );
    });

    test('turning it on needs the app unlocked, and Windows Hello', () async {
      service.lock();
      await expectLater(
        service.setBiometricUnlockEnabled(true),
        throwsStateError,
      );
      expect(await service.unlock('sekret12'), isTrue);
      vault.available = false;
      expect(await service.setBiometricUnlockEnabled(true), isFalse);
      expect((await service.biometricUnlockStatus()).enabled, isFalse);
      expect(
        await credentials.read(appSecuritySealedBiometricTokenStorageKey),
        isNull,
      );
    });
  });

  test('biometric unlock is off by default and, once turned on, survives '
      'an update and can be turned off again', () async {
    final MemorySecurityCredentialsStore credentials =
        MemorySecurityCredentialsStore();
    final MemoryKeyVault android = MemoryKeyVault();
    final LocalAppSecurityService before = LocalAppSecurityService(
      credentialsStore: credentials,
      passwordIterations: 10,
      keyVault: android,
    );
    await before.initialize(settings: const AppSettings());
    await before.setPassword('sekret12');
    // Off by default: nothing is sealed until the person asks.
    expect(
      await credentials.read(appSecuritySealedBiometricTokenStorageKey),
      isNull,
    );
    expect(await before.canUnlockWithBiometrics(), isFalse);
    expect(await before.setBiometricUnlockEnabled(true), isTrue);
    expect(
      await credentials.read(appSecuritySealedBiometricTokenStorageKey),
      isNotNull,
    );

    final LocalAppSecurityService after = LocalAppSecurityService(
      credentialsStore: credentials,
      passwordIterations: 10,
      keyVault: android,
    );
    await after.initialize(settings: const AppSettings());
    expect(android.wipes, 0);
    expect(await after.canUnlockWithBiometrics(), isTrue);
    expect(await after.unlockWithBiometrics(), isTrue);

    await after.setBiometricUnlockEnabled(false);
    after.lock();
    expect(await after.unlock('sekret12'), isTrue);
    expect(
      await credentials.read(appSecuritySealedBiometricTokenStorageKey),
      isNull,
      reason: 'the person said no: nothing is sealed again',
    );
  });

  test('reset destroys the key material first, even when the hardware '
      'wipe fails', () async {
    final _RecordingCredentials credentials = _RecordingCredentials();
    final LocalAppSecurityService service = LocalAppSecurityService(
      credentialsStore: credentials,
      passwordIterations: 10,
      keyVault: _BrokenWipeVault(),
    );
    await service.initialize(settings: const AppSettings());
    await service.setPassword('sekret12');
    await service.setBiometricUnlockEnabled(true);
    await service.setPanicPassword('panika123');
    await credentials.write(appSecurityGifApiKeyStorageKey, 'klucz');
    expect(
      await credentials.read(appSecuritySealedBiometricTokenStorageKey),
      isNotNull,
    );
    credentials.deleted.clear();

    await service.reset();

    expect(credentials.deleted.first, appSecurityWrappedMasterKeyStorageKey);
    expect(
      credentials.deleted.indexOf(appSecurityDeviceMasterKeyStorageKey),
      lessThan(credentials.deleted.indexOf(appSecuritySaltStorageKey)),
    );
    for (final String key in <String>[
      appSecurityWrappedMasterKeyStorageKey,
      appSecurityPasswordHashStorageKey,
      appSecuritySealedBiometricTokenStorageKey,
      appSecurityPanicPasswordHashStorageKey,
      appSecurityGifApiKeyStorageKey,
    ]) {
      expect(await credentials.read(key), isNull, reason: key);
    }
    expect(service.hasPassword, isFalse);
    expect(await service.currentEncryptionKey(), isNotNull);
  });
}

/// Records the order of deletions.
final class _RecordingCredentials implements AppSecurityCredentialsStore {
  final Map<String, String> _values = <String, String>{};
  final List<String> deleted = <String>[];

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    _values.remove(key);
  }
}

/// A vault whose hardware key cannot be destroyed.
final class _BrokenWipeVault implements PlatformKeyVault {
  final MemoryKeyVault _inner = MemoryKeyVault();

  @override
  bool get enforcesUserPresence => true;

  @override
  Future<bool> isAvailable() => _inner.isAvailable();

  @override
  Future<String> describe() => _inner.describe();

  @override
  Future<Uint8List?> seal(Uint8List secret) => _inner.seal(secret);

  @override
  Future<Uint8List?> open(Uint8List sealed, {required String reason}) =>
      _inner.open(sealed, reason: reason);

  @override
  Future<void> wipe() async {
    throw StateError('TPM busy');
  }
}
