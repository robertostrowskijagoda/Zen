import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/platform_key_vault.dart';
import 'package:zen/src/features/settings/app_settings.dart';

final Provider<AppSecurityService> appSecurityServiceProvider =
    Provider<AppSecurityService>((Ref ref) {
      return MemoryAppSecurityService();
    });

/// Whether the app insists on an app password before anything else
/// (§14.1: required by default). Off in tests and previews; the real app
/// turns it on.
final Provider<bool> appPasswordRequiredProvider = Provider<bool>(
  (Ref ref) => false,
);

/// Shortest app password accepted.
const int kMinAppPasswordLength = 8;

List buildAppSecurityProviderOverrides({required AppSecurityService service}) {
  return [appSecurityServiceProvider.overrideWithValue(service)];
}

const String appSecurityPasswordHashStorageKey = 'zen_rewrite_password_hash';
const String appSecuritySaltStorageKey = 'zen_rewrite_password_salt';
const String appSecurityPanicPasswordHashStorageKey =
    'zen_rewrite_panic_password_hash';
const String appSecurityPanicSaltStorageKey = 'zen_rewrite_panic_salt';

/// The master key sealed by [PlatformKeyVault] (base64), for biometric
/// unlock.
const String appSecuritySealedBiometricTokenStorageKey =
    'zen_rewrite_biometric_sealed_token';

/// How the password key is derived (JSON `{a: argon2id, m, t, p}`).
const String appSecurityPasswordKdfStorageKey = 'zen_rewrite_password_kdf';
const String appSecurityPanicKdfStorageKey = 'zen_rewrite_panic_kdf';
// Envelope-encryption entries. The master data key seals all local storage;
// the user password only wraps/unwraps it, so the raw password is never
// persisted anywhere.
const String appSecurityWrappedMasterKeyStorageKey =
    'zen_rewrite_wrapped_master_key';
const String appSecurityDeviceMasterKeyStorageKey =
    'zen_rewrite_device_master_key';
const String appSecurityMasterKeyFingerprintStorageKey =
    'zen_rewrite_master_key_fingerprint';

/// Whether the person wants biometric unlock: `1` on, `0` off. Absent: on
/// where the hardware itself asks for the person before it unwraps
/// (Android Keystore), off where only the app asks (Windows Hello in front
/// of the TPM) — there it must be turned on explicitly.
const String appSecurityBiometricUnlockChoiceStorageKey =
    'zen_rewrite_biometric_unlock_choice';

/// The security-relevant settings (lock mode, secure screens, …) kept out
/// of reach of whoever can write the settings file (see
/// `GuardedAppSettingsStore`).
const String appSecurityGuardedSettingsStorageKey =
    'zen_rewrite_guarded_settings';

/// The user's own GIF API key, kept in secure storage instead of the plain
/// settings file.
const String appSecurityGifApiKeyStorageKey = 'zen_rewrite_gif_api_key';

const int appSecurityMasterKeyLengthBytes = 32;

/// Message when the main password would be the same as the panic password.
const String kAppPasswordEqualsPanicMessage =
    'Hasło aplikacji musi różnić się od hasła panic.';

/// Message when the panic password would be the same as the main password.
const String kPanicPasswordEqualsMainMessage =
    'Hasło panic musi różnić się od głównego hasła.';

/// The main and the panic password must never be the same: the panic one
/// wipes everything when typed on the lock screen.
final class AppPasswordConflictException implements Exception {
  const AppPasswordConflictException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Biometric unlock, as the settings show it.
@immutable
final class BiometricUnlockStatus {
  const BiometricUnlockStatus({
    required this.available,
    required this.enabled,
    required this.hardwareEnforced,
    required this.protection,
    this.deviceSupported = false,
  });

  /// A password is set and the vault (and Windows Hello / enrolled
  /// biometrics) is there.
  final bool available;

  /// The person turned it on (off until they do).
  final bool enabled;

  /// The vault (and Windows Hello / enrolled biometrics) is there, password
  /// or not: whether first setup should ask about biometric unlock.
  final bool deviceSupported;

  /// The hardware itself asks for the person before releasing the key
  /// (Android). `false`: only the app asks (Windows Hello before the TPM),
  /// so a program already running as this Windows user could unwrap it.
  final bool hardwareEnforced;

  /// What protects the key ("TPM", "Android Keystore (TEE)", "brak").
  final String protection;
}

abstract class AppSecurityCredentialsStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

final class SecureStorageCredentialsStore
    implements AppSecurityCredentialsStore {
  const SecureStorageCredentialsStore([
    this._storage = const FlutterSecureStorage(),
  ]);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) {
    return _storage.write(key: key, value: value);
  }

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

final class MemorySecurityCredentialsStore
    implements AppSecurityCredentialsStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async {
    _values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

abstract class AppSecurityService extends ChangeNotifier {
  bool get isReady;

  bool get hasPassword;

  bool get isLocked;

  bool get isUnlocked;

  /// Local encryption is always enabled; data at rest is sealed with the
  /// master data key (password-wrapped when a password is set).
  bool get encryptionEnabled;

  AppLockMode get lockMode;

  int get backgroundLockDelaySeconds;

  bool get canQuickLock;

  bool get hasPanicPassword;

  Future<void> initialize({required AppSettings settings});

  Future<void> applySettings(AppSettings settings);

  Future<void> setPassword(String password);

  Future<bool> unlock(String password);

  /// Pure verification of the main password without changing lock state.
  Future<bool> verifyPassword(String password);

  /// Sets the panic (duress) password. Entering it on the lock screen wipes
  /// all local data instead of unlocking.
  Future<void> setPanicPassword(String password);

  Future<void> clearPanicPassword();

  Future<bool> matchesPanicPassword(String password);

  /// Whether biometric unlock can be offered (hardware vault present and a
  /// sealed key stored).
  Future<bool> canUnlockWithBiometrics();

  /// Unlocks with the master key sealed in the hardware vault; the vault
  /// asks for the fingerprint / face / Windows Hello itself.
  Future<bool> unlockWithBiometrics();

  /// Re-confirms the person (§14.1 point 4) with the sealed key, without
  /// changing the lock state. `false` when refused or unavailable.
  Future<bool> confirmWithBiometrics({required String reason});

  /// What protects the key for biometric unlock (for the settings).
  Future<String> keyProtection();

  /// Biometric unlock for the settings: can it be offered, is it on.
  Future<BiometricUnlockStatus> biometricUnlockStatus();

  /// Turns biometric unlock on (seals the master key in the vault; needs a
  /// password and the app unlocked) or off (drops the sealed key and
  /// destroys the hardware key). Returns whether it is now in the asked
  /// state.
  Future<bool> setBiometricUnlockEnabled(bool enabled);

  void lock();

  Future<void> reset();

  Future<Uint8List?> currentEncryptionKey();
}

Future<bool> loadStoredAppSecurityHasPassword([
  AppSecurityCredentialsStore credentialsStore =
      const SecureStorageCredentialsStore(),
]) async {
  return await credentialsStore.read(appSecurityPasswordHashStorageKey) != null;
}

/// Device-mode master key (present only when no password is set). Read by the
/// Android background runtime so it can decrypt stores without user input.
Future<Uint8List?> loadStoredDeviceMasterKey([
  AppSecurityCredentialsStore credentialsStore =
      const SecureStorageCredentialsStore(),
]) async {
  final String? encoded = await credentialsStore.read(
    appSecurityDeviceMasterKeyStorageKey,
  );
  return _decodeMasterKeyHex(encoded);
}

Uint8List? _decodeMasterKeyHex(String? encoded) {
  final String? trimmed = encoded?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return null;
  }
  if (trimmed.length != appSecurityMasterKeyLengthBytes * 2) {
    return null;
  }
  try {
    return securityBytesFromHex(trimmed);
  } on FormatException {
    return null;
  }
}

sealed class _BaseAppSecurityService extends AppSecurityService {
  _BaseAppSecurityService(
    this._credentialsStore,
    int passwordIterations, {
    PasswordCost? passwordCost,
    PlatformKeyVault? keyVault,
  }) : _cost =
           passwordCost ??
           // Tests pass a token iteration count: keep Argon2id cheap too.
           (passwordIterations < 1000
               ? const PasswordCost(memoryKiB: 64, iterations: 1)
               : const PasswordCost()),
       _vault = keyVault ?? const NoKeyVault();

  final AppSecurityCredentialsStore _credentialsStore;

  /// Argon2id cost for new passwords (§14.1: copied files must not be easy
  /// to crack offline).
  final PasswordCost _cost;
  final PlatformKeyVault _vault;

  String get _kdfJson =>
      jsonEncode(<String, Object>{'a': 'argon2id', ..._cost.toJson()});

  /// The key for [password] with the Argon2id cost [kdfKey] records;
  /// `null` when none is recorded.
  Future<Uint8List?> _derive(
    String password,
    Uint8List salt,
    String kdfKey,
  ) async {
    final String? kdf = await _credentialsStore.read(kdfKey);
    if (kdf == null) {
      return null;
    }
    try {
      final Object? json = jsonDecode(kdf);
      final PasswordCost? cost = json is Map && json['a'] == 'argon2id'
          ? PasswordCost.fromJson(json)
          : null;
      return cost == null
          ? null
          : await derivePasswordKey(password, salt, cost: cost);
    } on FormatException {
      return null;
    }
  }

  /// The person's choice, or the vault's default (see
  /// [appSecurityBiometricUnlockChoiceStorageKey]).
  Future<bool> _biometricUnlockWanted() async {
    final String? choice = await _credentialsStore.read(
      appSecurityBiometricUnlockChoiceStorageKey,
    );
    if (choice == '1') {
      return true;
    }
    if (choice == '0') {
      return false;
    }
    // Off until the person turns it on (in settings or at first setup):
    // unlocking with a fingerprint or face is a convenience, not a default.
    return false;
  }

  /// Drops the stored copy of the master key meant for biometric unlock.
  Future<void> _dropBiometricToken() async {
    await _credentialsStore.delete(appSecuritySealedBiometricTokenStorageKey);
  }

  /// Seals [masterKey] for biometric unlock (no prompt) — only when the
  /// person wants it and the vault (with Windows Hello / enrolled
  /// biometrics) is there; otherwise no sealed copy is left.
  Future<void> _storeBiometricToken(Uint8List masterKey) async {
    try {
      final Uint8List? sealed =
          await _biometricUnlockWanted() && await _vault.isAvailable()
          ? await _vault.seal(masterKey)
          : null;
      if (sealed == null) {
        await _credentialsStore.delete(
          appSecuritySealedBiometricTokenStorageKey,
        );
        return;
      }
      await _credentialsStore.write(
        appSecuritySealedBiometricTokenStorageKey,
        base64Encode(sealed),
      );
    } on Object catch (error, stackTrace) {
      logZenError('Sealing the biometric token failed', error, stackTrace);
    }
  }

  bool _isReady = false;
  bool _hasPassword = false;
  bool _hasPanicPassword = false;
  bool _isLocked = false;
  AppLockMode _lockMode = AppSettings.defaultLockMode;
  int _backgroundLockDelaySeconds =
      AppSettings.defaultBackgroundLockDelaySeconds;
  Uint8List? _encryptionKey;

  @override
  bool get isReady => _isReady;

  @override
  bool get hasPassword => _hasPassword;

  @override
  bool get isLocked => _isLocked;

  @override
  bool get isUnlocked => !_isLocked;

  @override
  bool get encryptionEnabled => true;

  @override
  AppLockMode get lockMode => _lockMode;

  @override
  int get backgroundLockDelaySeconds => _backgroundLockDelaySeconds;

  @override
  bool get canQuickLock => _hasPassword;

  @override
  bool get hasPanicPassword => _hasPanicPassword;

  @override
  Future<void> initialize({required AppSettings settings}) async {
    _applySettingsState(settings);
    _hasPassword =
        await _credentialsStore.read(appSecurityPasswordHashStorageKey) != null;
    _hasPanicPassword =
        await _credentialsStore.read(appSecurityPanicPasswordHashStorageKey) !=
        null;
    if (_hasPassword) {
      // Password mode starts locked; the master key is only recovered by
      // unlocking (password) or by the stored biometric token.
      _isLocked = true;
      _encryptionKey = null;
    } else {
      final Uint8List? storedMasterKey = await _readDeviceMasterKey();
      final Uint8List masterKey = storedMasterKey ?? randomSecurityBytes(32);
      if (storedMasterKey == null) {
        await _credentialsStore.write(
          appSecurityDeviceMasterKeyStorageKey,
          securityHexFromBytes(masterKey),
        );
      }
      await _ensureMasterFingerprint(masterKey);
      _encryptionKey = masterKey;
      _isLocked = false;
    }
    _isReady = true;
    notifyListeners();
  }

  @override
  Future<void> applySettings(AppSettings settings) async {
    _applySettingsState(settings);
    notifyListeners();
  }

  @override
  Future<void> setPassword(String password) async {
    final Uint8List? currentMasterKey = _encryptionKey;
    if (currentMasterKey == null) {
      throw StateError('Cannot set a password while the app is locked.');
    }
    // The same password as the panic one would wipe everything on the next
    // unlock.
    if (await matchesPanicPassword(password)) {
      throw const AppPasswordConflictException(kAppPasswordEqualsPanicMessage);
    }
    final Uint8List salt = randomSecurityBytes(32);
    final Uint8List derivedKey = await derivePasswordKey(
      password,
      salt,
      cost: _cost,
    );
    final Uint8List wrappedMasterKey = await encryptSecurityBytes(
      currentMasterKey,
      derivedKey,
    );
    await _credentialsStore.write(appSecurityPasswordKdfStorageKey, _kdfJson);
    await _credentialsStore.write(
      appSecuritySaltStorageKey,
      securityHexFromBytes(salt),
    );
    await _credentialsStore.write(
      appSecurityPasswordHashStorageKey,
      securityHexFromBytes(securityVerifyDigest(derivedKey)),
    );
    await _credentialsStore.write(
      appSecurityWrappedMasterKeyStorageKey,
      securityHexFromBytes(wrappedMasterKey),
    );
    await _credentialsStore.write(
      appSecurityMasterKeyFingerprintStorageKey,
      securityHexFromBytes(securityMasterFingerprint(currentMasterKey)),
    );
    // The biometric token holds the master key (never the raw password),
    // sealed by the hardware vault.
    await _storeBiometricToken(currentMasterKey);
    await _credentialsStore.delete(appSecurityDeviceMasterKeyStorageKey);
    _hasPassword = true;
    _isLocked = false;
    notifyListeners();
  }

  @override
  Future<bool> unlock(String password) async {
    final String? saltHex = await _credentialsStore.read(
      appSecuritySaltStorageKey,
    );
    final String? hashHex = await _credentialsStore.read(
      appSecurityPasswordHashStorageKey,
    );
    if (saltHex == null || hashHex == null) {
      _hasPassword = false;
      _isLocked = false;
      await _dropBiometricToken();
      notifyListeners();
      return false;
    }
    final Uint8List? derivedKey = await _derive(
      password,
      securityBytesFromHex(saltHex),
      appSecurityPasswordKdfStorageKey,
    );
    final String? wrappedHex = await _credentialsStore.read(
      appSecurityWrappedMasterKeyStorageKey,
    );
    if (derivedKey == null ||
        wrappedHex == null ||
        !securityConstantTimeEquals(
          securityVerifyDigest(derivedKey),
          securityBytesFromHex(hashHex),
        )) {
      return false;
    }
    final Uint8List? masterKey = await _unwrapMasterKey(wrappedHex, derivedKey);
    if (masterKey == null) {
      return false;
    }
    await _finishUnlock(masterKey);
    return true;
  }

  @override
  Future<bool> verifyPassword(String password) async {
    final String? saltHex = await _credentialsStore.read(
      appSecuritySaltStorageKey,
    );
    final String? hashHex = await _credentialsStore.read(
      appSecurityPasswordHashStorageKey,
    );
    if (saltHex == null || hashHex == null) {
      return false;
    }
    final Uint8List? derivedKey = await _derive(
      password,
      securityBytesFromHex(saltHex),
      appSecurityPasswordKdfStorageKey,
    );
    return derivedKey != null &&
        securityConstantTimeEquals(
          securityVerifyDigest(derivedKey),
          securityBytesFromHex(hashHex),
        );
  }

  @override
  Future<void> setPanicPassword(String password) async {
    if (password.isEmpty) {
      throw ArgumentError.value(password, 'password', 'Must not be empty.');
    }
    if (await verifyPassword(password)) {
      throw const AppPasswordConflictException(kPanicPasswordEqualsMainMessage);
    }
    final Uint8List salt = randomSecurityBytes(32);
    final Uint8List derivedKey = await derivePasswordKey(
      password,
      salt,
      cost: _cost,
    );
    await _credentialsStore.write(appSecurityPanicKdfStorageKey, _kdfJson);
    await _credentialsStore.write(
      appSecurityPanicSaltStorageKey,
      securityHexFromBytes(salt),
    );
    await _credentialsStore.write(
      appSecurityPanicPasswordHashStorageKey,
      securityHexFromBytes(securityVerifyDigest(derivedKey)),
    );
    _hasPanicPassword = true;
    notifyListeners();
  }

  @override
  Future<void> clearPanicPassword() async {
    await _credentialsStore.delete(appSecurityPanicPasswordHashStorageKey);
    await _credentialsStore.delete(appSecurityPanicSaltStorageKey);
    await _credentialsStore.delete(appSecurityPanicKdfStorageKey);
    _hasPanicPassword = false;
    notifyListeners();
  }

  @override
  Future<bool> matchesPanicPassword(String password) async {
    final String? saltHex = await _credentialsStore.read(
      appSecurityPanicSaltStorageKey,
    );
    final String? hashHex = await _credentialsStore.read(
      appSecurityPanicPasswordHashStorageKey,
    );
    if (saltHex == null || hashHex == null) {
      return false;
    }
    final Uint8List? derivedKey = await _derive(
      password,
      securityBytesFromHex(saltHex),
      appSecurityPanicKdfStorageKey,
    );
    return derivedKey != null &&
        securityConstantTimeEquals(
          securityVerifyDigest(derivedKey),
          securityBytesFromHex(hashHex),
        );
  }

  @override
  Future<bool> canUnlockWithBiometrics() async =>
      _hasPassword &&
      await _biometricUnlockWanted() &&
      await _credentialsStore.read(appSecuritySealedBiometricTokenStorageKey) !=
          null &&
      await _vault.isAvailable();

  @override
  Future<String> keyProtection() => _vault.describe();

  @override
  Future<BiometricUnlockStatus> biometricUnlockStatus() async {
    final bool vaultAvailable = await _vault.isAvailable();
    return BiometricUnlockStatus(
      available: _hasPassword && vaultAvailable,
      deviceSupported: vaultAvailable,
      enabled: await _biometricUnlockWanted(),
      hardwareEnforced: _vault.enforcesUserPresence,
      protection: await _vault.describe(),
    );
  }

  @override
  Future<bool> setBiometricUnlockEnabled(bool enabled) async {
    if (!enabled) {
      await _credentialsStore.write(
        appSecurityBiometricUnlockChoiceStorageKey,
        '0',
      );
      await _dropBiometricToken();
      try {
        // Sealed copies anywhere (backups) become useless too.
        await _vault.wipe();
      } on Object catch (error, stackTrace) {
        logZenError('Wiping the hardware key failed', error, stackTrace);
      }
      notifyListeners();
      return true;
    }
    final Uint8List? masterKey = _encryptionKey;
    if (!_hasPassword || masterKey == null) {
      throw StateError(
        'Biometric unlock needs an app password and the app unlocked.',
      );
    }
    if (!await _vault.isAvailable()) {
      return false;
    }
    final String? previous = await _credentialsStore.read(
      appSecurityBiometricUnlockChoiceStorageKey,
    );
    await _credentialsStore.write(
      appSecurityBiometricUnlockChoiceStorageKey,
      '1',
    );
    await _storeBiometricToken(masterKey);
    final bool sealed =
        await _credentialsStore.read(
          appSecuritySealedBiometricTokenStorageKey,
        ) !=
        null;
    if (!sealed) {
      // Nothing could be sealed: the choice stays what it was.
      if (previous == null) {
        await _credentialsStore.delete(
          appSecurityBiometricUnlockChoiceStorageKey,
        );
      } else {
        await _credentialsStore.write(
          appSecurityBiometricUnlockChoiceStorageKey,
          previous,
        );
      }
    }
    notifyListeners();
    return sealed;
  }

  /// Opens the sealed master key (the vault asks for biometrics) and checks
  /// it against the stored fingerprint.
  Future<Uint8List?> _openSealedMasterKey(String reason) async {
    final String? sealed = await _credentialsStore.read(
      appSecuritySealedBiometricTokenStorageKey,
    );
    if (sealed == null) {
      return null;
    }
    Uint8List? masterKey;
    try {
      masterKey = await _vault.open(base64Decode(sealed), reason: reason);
    } on Object catch (error, stackTrace) {
      logZenError('Opening the sealed key failed', error, stackTrace);
    }
    if (masterKey == null ||
        masterKey.length != appSecurityMasterKeyLengthBytes) {
      return null;
    }
    final String? fingerprintHex = await _credentialsStore.read(
      appSecurityMasterKeyFingerprintStorageKey,
    );
    if (fingerprintHex != null) {
      final bool matches = securityConstantTimeEquals(
        securityMasterFingerprint(masterKey),
        securityBytesFromHex(fingerprintHex),
      );
      if (!matches) {
        return null;
      }
    } else if (_hasPassword) {
      // Password mode must never trust a token without a fingerprint to
      // verify it against.
      return null;
    }
    return masterKey;
  }

  @override
  Future<bool> unlockWithBiometrics() async {
    final Uint8List? masterKey = await _openSealedMasterKey('Odblokuj Zen');
    if (masterKey == null) {
      return false;
    }
    await _finishUnlock(masterKey, reseal: false);
    return true;
  }

  @override
  Future<bool> confirmWithBiometrics({required String reason}) async {
    if (!await canUnlockWithBiometrics()) {
      return false;
    }
    return await _openSealedMasterKey(reason) != null;
  }

  @override
  void lock() {
    if (!_hasPassword) {
      return;
    }
    _isLocked = true;
    _encryptionKey = null;
    notifyListeners();
  }

  /// Every credential [reset] destroys, the ones that open the data first
  /// (crypto-shredding: once they are gone, whatever is left on disk is
  /// noise, even if deleting the files is cut short).
  static const List<String> _keyMaterial = <String>[
    appSecurityWrappedMasterKeyStorageKey,
    appSecurityDeviceMasterKeyStorageKey,
    appSecuritySealedBiometricTokenStorageKey,
    appSecurityPasswordHashStorageKey,
  ];

  static const List<String> _otherCredentials = <String>[
    appSecuritySaltStorageKey,
    appSecurityPasswordKdfStorageKey,
    appSecurityPanicPasswordHashStorageKey,
    appSecurityPanicSaltStorageKey,
    appSecurityPanicKdfStorageKey,
    appSecurityMasterKeyFingerprintStorageKey,
    appSecurityBiometricUnlockChoiceStorageKey,
    appSecurityGuardedSettingsStorageKey,
    appSecurityGifApiKeyStorageKey,
  ];

  Future<void> _deleteCredential(String key) async {
    try {
      await _credentialsStore.delete(key);
    } on Object catch (error, stackTrace) {
      // Keep destroying the rest.
      logZenError('Deleting $key failed', error, stackTrace);
    }
  }

  @override
  Future<void> reset() async {
    _encryptionKey = null;
    for (final String key in _keyMaterial) {
      await _deleteCredential(key);
    }
    try {
      // Sealed copies anywhere become useless.
      await _vault.wipe();
    } on Object catch (error, stackTrace) {
      logZenError('Wiping the hardware key failed', error, stackTrace);
    }
    for (final String key in _otherCredentials) {
      await _deleteCredential(key);
    }
    final Uint8List masterKey = randomSecurityBytes(32);
    await _credentialsStore.write(
      appSecurityDeviceMasterKeyStorageKey,
      securityHexFromBytes(masterKey),
    );
    await _ensureMasterFingerprint(masterKey);
    _hasPassword = false;
    _hasPanicPassword = false;
    _isLocked = false;
    _encryptionKey = masterKey;
    notifyListeners();
  }

  @override
  Future<Uint8List?> currentEncryptionKey() async {
    if (!_isReady) {
      return null;
    }
    return _encryptionKey;
  }

  Future<Uint8List?> _readDeviceMasterKey() async {
    try {
      return _decodeMasterKeyHex(
        await _credentialsStore.read(appSecurityDeviceMasterKeyStorageKey),
      );
    } catch (error, stackTrace) {
      logZenError('Reading the device master key failed', error, stackTrace);
      return null;
    }
  }

  Future<Uint8List?> _unwrapMasterKey(
    String wrappedHex,
    Uint8List derivedKey,
  ) async {
    try {
      final Uint8List masterKey = await decryptSecurityBytes(
        securityBytesFromHex(wrappedHex),
        derivedKey,
      );
      return masterKey.length == appSecurityMasterKeyLengthBytes
          ? masterKey
          : null;
    } catch (error, stackTrace) {
      logZenError('Unwrapping the master key failed', error, stackTrace);
      return null;
    }
  }

  Future<void> _finishUnlock(Uint8List masterKey, {bool reseal = true}) async {
    if (reseal) {
      await _storeBiometricToken(masterKey);
    }
    await _ensureMasterFingerprint(masterKey);
    _hasPassword = true;
    _encryptionKey = masterKey;
    _isLocked = false;
    notifyListeners();
  }

  Future<void> _ensureMasterFingerprint(Uint8List masterKey) async {
    final String? existing = await _credentialsStore.read(
      appSecurityMasterKeyFingerprintStorageKey,
    );
    if (existing != null) {
      return;
    }
    await _credentialsStore.write(
      appSecurityMasterKeyFingerprintStorageKey,
      securityHexFromBytes(securityMasterFingerprint(masterKey)),
    );
  }

  @protected
  void prime({
    AppSettings settings = const AppSettings(),
    bool hasPassword = false,
    bool hasPanicPassword = false,
    bool locked = false,
    Uint8List? encryptionKey,
  }) {
    _applySettingsState(settings);
    _hasPassword = hasPassword;
    _hasPanicPassword = hasPanicPassword;
    _isReady = true;
    if (hasPassword) {
      _isLocked = locked;
      _encryptionKey = locked ? null : encryptionKey;
    } else {
      _isLocked = false;
      _encryptionKey = encryptionKey;
    }
    notifyListeners();
  }

  void _applySettingsState(AppSettings settings) {
    _lockMode = settings.lockMode;
    _backgroundLockDelaySeconds = settings.backgroundLockDelaySeconds;
  }
}

final class LocalAppSecurityService extends _BaseAppSecurityService {
  LocalAppSecurityService({
    AppSecurityCredentialsStore? credentialsStore,
    int passwordIterations = 100000,
    super.passwordCost,
    super.keyVault,
  }) : super(
         credentialsStore ?? const SecureStorageCredentialsStore(),
         passwordIterations,
       );
}

final class MemoryAppSecurityService extends _BaseAppSecurityService {
  MemoryAppSecurityService({
    AppSettings settings = const AppSettings(),
    AppSecurityCredentialsStore? credentialsStore,
    bool hasPassword = false,
    bool hasPanicPassword = false,
    bool locked = false,
    Uint8List? encryptionKey,
    int passwordIterations = 100000,
    super.keyVault,
  }) : super(
         credentialsStore ?? MemorySecurityCredentialsStore(),
         passwordIterations,
       ) {
    prime(
      settings: settings,
      hasPassword: hasPassword,
      hasPanicPassword: hasPanicPassword,
      locked: locked,
      encryptionKey:
          encryptionKey ??
          Uint8List.fromList(List<int>.generate(32, (int index) => index + 1)),
    );
  }
}

final class HeadlessAppSecurityService extends _BaseAppSecurityService {
  HeadlessAppSecurityService({
    required AppSettings settings,
    required bool hasPassword,
    Uint8List? encryptionKey,
    int passwordIterations = 100000,
  }) : super(MemorySecurityCredentialsStore(), passwordIterations) {
    prime(
      settings: settings,
      hasPassword: hasPassword,
      locked: hasPassword && encryptionKey == null,
      encryptionKey: encryptionKey,
    );
  }
}
