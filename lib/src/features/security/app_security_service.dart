import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
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
/// (required by default). Off in tests and previews; the real app
/// turns it on.
final Provider<bool> appPasswordRequiredProvider = Provider<bool>(
  (Ref ref) => false,
);

/// Shortest app password accepted.
const int kMinAppPasswordLength = 8;

/// Why biometric unlock is weaker than the password (shown wherever it can
/// be turned on).
String get kBiometricRiskText => t(
  'Odcisk palca albo twarz da się wymusić — ktoś może przyłożyć Twój palec, '
  'gdy śpisz, albo skierować telefon na Twoją twarz — a Zen otworzy też '
  'każdy odcisk zapisany w tym telefonie, także cudzy. Jeśli chronisz się '
  'przed kimś bliskim albo przed przeszukaniem, zostań przy samym haśle.',
);

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

/// "Nigdy" with an app password: a plain copy of the master key (hex) in
/// the system's secret store (Android Keystore, the iOS / macOS keychain,
/// the Windows credential store — where the device master key lives
/// without a password), so a start from scratch opens without the
/// password. Written only when the person chooses it and proves it with
/// the password ([AppSecurityService.keepMasterKeyForNeverLock]); never by
/// setting a password or unlocking. Dropped as soon as another lock mode is
/// chosen or the app is locked by hand, and then kept again only by
/// choosing it once more.
const String appSecurityNeverLockMasterKeyStorageKey =
    'zen_rewrite_never_lock_master_key';

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

/// Failed lock-screen password attempts and when the last one happened
/// (`<count>:<epoch ms>`), see `UnlockThrottle`.
const String appSecurityUnlockFailuresStorageKey =
    'zen_rewrite_unlock_failures';

/// The background key (hex, see `background_keys.dart`).
///
/// Not the master key and nothing derived from it: the Android background
/// service reads it without the app password, and it opens only what the
/// service needs while the app is locked — the node config (this phone's
/// mesh identity) and the background capability (who counts as a contact,
/// the inbox's public key). Chats, the friend list, the ledger and every
/// other store stay under the master key; what arrives while the app is
/// locked goes into the sealed inbox, which only the master key opens.
const String appSecurityBackgroundKeyStorageKey = 'zen_rewrite_background_key';

const int appSecurityMasterKeyLengthBytes = 32;

/// Message when the main password would be the same as the panic password.
String get kAppPasswordEqualsPanicMessage =>
    t('Hasło aplikacji musi różnić się od hasła awaryjnego kasującego.');

/// Message when the panic password would be the same as the main password.
String get kPanicPasswordEqualsMainMessage =>
    t('Hasło awaryjne kasujące musi różnić się od hasła aplikacji.');

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

/// One password as a backup of the whole account carries it: the Argon2id
/// cost and salt its key is derived with, and the check of that key
/// ([securityVerifyDigest]) — never the password, the key or the master key
/// it wraps. Enough to know the same password again on another device.
@immutable
final class AppPasswordCheck {
  const AppPasswordCheck({
    required this.cost,
    required this.salt,
    required this.check,
  });

  final PasswordCost cost;
  final Uint8List salt;
  final Uint8List check;

  /// The key [password] derives when it is this password; `null` otherwise
  /// (one Argon2id run either way).
  Future<Uint8List?> keyFor(String password) async {
    final Uint8List key = await derivePasswordKey(password, salt, cost: cost);
    return securityConstantTimeEquals(securityVerifyDigest(key), check)
        ? key
        : null;
  }

  /// Whether [password] is this password.
  Future<bool> matches(String password) async => await keyFor(password) != null;

  /// The cost as the credentials store keeps it
  /// ([appSecurityPasswordKdfStorageKey]).
  String get kdfJson =>
      jsonEncode(<String, Object>{'a': 'argon2id', ...cost.toJson()});

  Map<String, Object> toJson() => <String, Object>{
    'a': 'argon2id',
    ...cost.toJson(),
    's': securityHexFromBytes(salt),
    'c': securityHexFromBytes(check),
  };

  static AppPasswordCheck? fromJson(Object? json) {
    if (json is! Map || json['a'] != 'argon2id') {
      return null;
    }
    final PasswordCost? cost = PasswordCost.fromJson(json);
    final Object? s = json['s'];
    final Object? c = json['c'];
    if (cost == null || s is! String || c is! String) {
      return null;
    }
    try {
      final Uint8List salt = securityBytesFromHex(s);
      final Uint8List check = securityBytesFromHex(c);
      if (salt.length < 16 || salt.length > 64 || check.length != 32) {
        return null;
      }
      return AppPasswordCheck(cost: cost, salt: salt, check: check);
    } on FormatException {
      return null;
    }
  }
}

/// The app's lock as a backup of the whole account carries it: the app
/// password ([password]; `null`: the app was used without one) and the
/// panic password. Biometric unlock and the key kept for "Nigdy" belong to
/// the device they were made on and are never in it.
@immutable
final class AppLockCopy {
  const AppLockCopy({this.password, this.panic});

  final AppPasswordCheck? password;
  final AppPasswordCheck? panic;

  Map<String, Object> toJson() => <String, Object>{
    'password': ?password?.toJson(),
    'panic': ?panic?.toJson(),
  };

  /// `null` for anything but a lock: a password that is there but cannot be
  /// read must never come back as "no password".
  static AppLockCopy? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final AppPasswordCheck? password = AppPasswordCheck.fromJson(
      json['password'],
    );
    final AppPasswordCheck? panic = AppPasswordCheck.fromJson(json['panic']);
    if ((json['password'] != null && password == null) ||
        (json['panic'] != null && panic == null)) {
      return null;
    }
    return AppLockCopy(password: password, panic: panic);
  }
}

abstract class AppSecurityCredentialsStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);
}

/// What [SecureStorageCredentialsStore] needs of the system's secret store
/// (a seam for tests).
abstract interface class SecureKeyValueBackend {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<Map<String, String>> readAll();
}

/// [SecureKeyValueBackend] over `flutter_secure_storage`.
final class FlutterSecureStorageBackend implements SecureKeyValueBackend {
  const FlutterSecureStorageBackend(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<Map<String, String>> readAll() => _storage.readAll();
}

/// iOS / macOS keychain items: readable once the device has been unlocked
/// after a restart (the background work needs them with the screen locked)
/// and never moved to another device — left out of iCloud Keychain and of
/// a backup restored elsewhere. The plugin's default
/// (`kSecAttrAccessibleWhenUnlocked`) travels with encrypted backups, and
/// without a password the master key itself is in the keychain.
const KeychainAccessibility kZenKeychainAccessibility =
    KeychainAccessibility.first_unlock_this_device;

/// The keychain as Zen opens it now.
const FlutterSecureStorage _zenKeychain = FlutterSecureStorage(
  iOptions: IOSOptions(accessibility: kZenKeychainAccessibility),
  // macOS: the login keychain. The data protection keychain (the plugin's
  // default) needs a team-signed app; Zen for Mac is signed ad hoc. The
  // login keychain is never synced to iCloud Keychain and takes no notice
  // of the accessibility; it is set anyway, in case that ever changes.
  mOptions: MacOsOptions(
    accessibility: kZenKeychainAccessibility,
    usesDataProtectionKeychain: false,
  ),
);

/// The keychain as Zen opened it before [kZenKeychainAccessibility]: the
/// plugin's default accessibility. Only to find, move and delete items
/// written then.
const FlutterSecureStorage _earlierZenKeychain = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);

/// Which entries a [SecureStorageCredentialsStore] reads and writes.
enum _SecretScope {
  /// The account open in this isolate ([SecureStorageCredentialsStore
  /// .activeNamespace]).
  active,

  /// The device's own entries, whatever account is open.
  device,

  /// One account's entries, named by the store.
  fixed,
}

/// The system's secret store, one account at a time: the default account
/// keeps the plain entry names; an additional account's entries are
/// named by a keyed hash of the name under the account's secret
/// ([scopedSecretName]), so nothing in the store tells which account an
/// entry belongs to, or that there is more than one.
final class SecureStorageCredentialsStore
    implements AppSecurityCredentialsStore {
  const SecureStorageCredentialsStore([
    this._keychain = const FlutterSecureStorageBackend(_zenKeychain),
    this._earlierKeychain = const FlutterSecureStorageBackend(
      _earlierZenKeychain,
    ),
  ]) : _scope = _SecretScope.active,
       _namespace = null;

  /// The device's own entries (the account registry), never an account's.
  const SecureStorageCredentialsStore.device([
    this._keychain = const FlutterSecureStorageBackend(_zenKeychain),
    this._earlierKeychain = const FlutterSecureStorageBackend(
      _earlierZenKeychain,
    ),
  ]) : _scope = _SecretScope.device,
       _namespace = null;

  /// The entries of the account whose secret is [namespace] (`null`: the
  /// default account), whatever account is open.
  const SecureStorageCredentialsStore.account(
    Uint8List? namespace, [
    this._keychain = const FlutterSecureStorageBackend(_zenKeychain),
    this._earlierKeychain = const FlutterSecureStorageBackend(
      _earlierZenKeychain,
    ),
  ]) : _scope = _SecretScope.fixed,
       _namespace = namespace;

  final SecureKeyValueBackend _keychain;
  final SecureKeyValueBackend _earlierKeychain;
  final _SecretScope _scope;
  final Uint8List? _namespace;

  /// The secret of the account open in this isolate; `null` for the
  /// default account. Set when an account is opened; the Android
  /// background service's isolate never sets it (it serves the default
  /// account only).
  static Uint8List? activeNamespace;

  /// The prefix of every entry Zen writes.
  static const String zenEntryPrefix = 'zen_';

  /// The prefix of an additional account's entries.
  static const String _scopedPrefix = 'zen_x_';

  /// The same backends, for the account with [namespace] (`null`: the
  /// default account).
  SecureStorageCredentialsStore forAccount(Uint8List? namespace) =>
      SecureStorageCredentialsStore.account(
        namespace,
        _keychain,
        _earlierKeychain,
      );

  /// The same backends, for the device's own entries.
  SecureStorageCredentialsStore forDevice() =>
      SecureStorageCredentialsStore.device(_keychain, _earlierKeychain);

  Uint8List? get _effectiveNamespace => switch (_scope) {
    _SecretScope.active => activeNamespace,
    _SecretScope.device => null,
    _SecretScope.fixed => _namespace,
  };

  /// The stored name of [key] for the account with [namespace]: the key
  /// itself for the default account, else `zen_x_` and 40 hex digits of
  /// HMAC-SHA256(namespace, key).
  static String scopedSecretName(Uint8List? namespace, String key) {
    if (namespace == null) {
      return key;
    }
    final String mac = crypto.Hmac(
      crypto.sha256,
      namespace,
    ).convert(utf8.encode(key)).toString();
    return '$_scopedPrefix${mac.substring(0, 40)}';
  }

  /// The entry that lists an additional account's key names (so the
  /// account can be wiped without a plain index anywhere else).
  static const String _keyListName = '\u0000keys';

  Future<void> _remember(Uint8List namespace, String key) async {
    final String listName = scopedSecretName(namespace, _keyListName);
    // Read every time (writes are rare): the background isolate may have
    // added to it meanwhile.
    final Set<String> known = await _readKeyList(listName);
    if (!known.add(key)) {
      return;
    }
    await _write(listName, jsonEncode(known.toList()..sort()));
  }

  Future<Set<String>> _readKeyList(String listName) async {
    final String? raw = await _keychain.read(listName);
    if (raw == null) {
      return <String>{};
    }
    try {
      final Object? json = jsonDecode(raw);
      return json is List ? json.whereType<String>().toSet() : <String>{};
    } on FormatException {
      return <String>{};
    }
  }

  /// Deletes every entry of this store's account (an additional account:
  /// all it ever wrote; the default account is reset by its own service).
  Future<void> deleteAccountEntries() async {
    await _moved();
    final Uint8List? namespace = _effectiveNamespace;
    if (namespace == null) {
      return;
    }
    final String listName = scopedSecretName(namespace, _keyListName);
    final Set<String> keys = await _readKeyList(listName);
    for (final String key in keys) {
      await _deleteRaw(scopedSecretName(namespace, key));
    }
    await _deleteRaw(listName);
  }

  /// Deletes every entry Zen ever wrote on this device, of every account
  /// (the device wipe).
  Future<void> deleteEverything() async {
    final Set<String> names = <String>{
      for (final SecureKeyValueBackend backend in <SecureKeyValueBackend>[
        _keychain,
        if (_onIos || _onMacOs) _earlierKeychain,
      ])
        ...(await backend.readAll()).keys,
    };
    for (final String name in names) {
      if (name.startsWith(zenEntryPrefix)) {
        await _deleteRaw(name);
      }
    }
  }

  Future<void> _deleteRaw(String name) async {
    await _keychain.delete(name);
    if (_onIos || _onMacOs) {
      await _earlierKeychain.delete(name);
    }
  }

  /// Set once every item of an iOS keychain has been rewritten with
  /// [kZenKeychainAccessibility].
  static const String keychainMovedMarkerKey =
      'zen_rewrite_keychain_this_device_only';

  /// The one move of the items written before (iOS), shared by every
  /// store of this isolate; the other calls wait for it.
  static Future<void>? _keychainMove;

  /// For tests: forget that the move ran in this isolate.
  @visibleForTesting
  static void debugForgetKeychainMove() {
    _keychainMove = null;
  }

  static bool get _onIos =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool get _onMacOs =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<String?> read(String rawKey) async {
    await _moved();
    final String key = scopedSecretName(_effectiveNamespace, rawKey);
    final String? value = await _keychain.read(key);
    if (value != null || !(_onIos || _onMacOs)) {
      return value;
    }
    // In case the plugin looks items up by their accessibility too: one
    // written before is found with the earlier one, and moved.
    final String? earlier = await _earlierKeychain.read(key);
    if (earlier != null) {
      try {
        await _write(key, earlier);
      } on PlatformException catch (error, stackTrace) {
        logZenError('Moving a keychain item failed', error, stackTrace);
      }
    }
    return earlier;
  }

  @override
  Future<void> write(String rawKey, String value) async {
    await _moved();
    final Uint8List? namespace = _effectiveNamespace;
    if (namespace != null) {
      await _remember(namespace, rawKey);
    }
    await _write(scopedSecretName(namespace, rawKey), value);
  }

  @override
  Future<void> delete(String rawKey) async {
    await _moved();
    // A copy with the earlier accessibility must not come back through
    // [read] (a wipe deletes the keys this way).
    await _deleteRaw(scopedSecretName(_effectiveNamespace, rawKey));
  }

  Future<void> _write(String key, String value) async {
    try {
      await _keychain.write(key, value);
    } on PlatformException catch (error) {
      if (_onMacOs) {
        // macOS: before updating, the plugin also looks in the data
        // protection keychain, which an app signed ad hoc may not open; it
        // then adds the entry again and fails on the duplicate. Replace it.
        await _replace(key, value);
        return;
      }
      if (_onIos && _isStaleKeychainItem(error)) {
        // iOS: an item written with the earlier accessibility the plugin
        // did not match by the new one (it then fails on the duplicate, or
        // on the update). Nothing else deletes before writing: a write
        // refused for another reason (a locked phone) keeps the old value.
        await _replace(key, value);
        return;
      }
      rethrow;
    }
  }

  /// Deletes [key] (of either accessibility) and writes it again. Should
  /// the new attributes be refused, the value goes in with the earlier
  /// ones rather than be lost: on macOS Zen keeps working whatever the
  /// keychain makes of them, on iOS the next write tries again.
  Future<void> _replace(String key, String value) async {
    await _keychain.delete(key);
    await _earlierKeychain.delete(key);
    try {
      await _keychain.write(key, value);
    } on PlatformException catch (error, stackTrace) {
      logZenError(
        'Writing a keychain item with the new attributes failed',
        error,
        stackTrace,
      );
      await _earlierKeychain.write(key, value);
    }
  }

  /// "The specified item already exists" (-25299) or "could not be found"
  /// (-25300): what the plugin answers for an item it did not match.
  static bool _isStaleKeychainItem(PlatformException error) {
    final String text = '${error.code} ${error.message} ${error.details}';
    return text.contains('-25299') || text.contains('-25300');
  }

  Future<void> _moved() {
    if (!_onIos) {
      return Future<void>.value();
    }
    return _keychainMove ??= _moveToThisDevice();
  }

  /// iOS, once: every item written before gets [kZenKeychainAccessibility]
  /// (written again with the same value), then the marker is set. A
  /// failure is tried again at the next start; the items stay readable
  /// meanwhile.
  Future<void> _moveToThisDevice() async {
    try {
      if (await _keychain.read(keychainMovedMarkerKey) == '1') {
        return;
      }
      await _restoreCutShortMove();
      final Map<String, String> items = await _earlierKeychain.readAll();
      for (final MapEntry<String, String> item in items.entries) {
        if (item.key == keychainMovedMarkerKey ||
            item.key.startsWith(_movingCopyPrefix)) {
          continue;
        }
        // Added anew, not updated (an update may keep the attributes), so
        // deleted first: a copy under another name holds the value until
        // it is back (the wrapped master key must never be lost).
        final String copy = '$_movingCopyPrefix${item.key}';
        await _keychain.write(copy, item.value);
        await _replace(item.key, item.value);
        await _keychain.delete(copy);
      }
      await _keychain.write(keychainMovedMarkerKey, '1');
    } on Object catch (error, stackTrace) {
      logZenError(
        'Moving keychain items to this device only failed',
        error,
        stackTrace,
      );
    }
  }

  /// The copies [_moveToThisDevice] keeps while it moves an item.
  static const String _movingCopyPrefix = 'zen_rewrite_keychain_moving:';

  /// After a move cut short (the app killed between deleting an item and
  /// adding it again): the item comes back from its copy.
  Future<void> _restoreCutShortMove() async {
    final Map<String, String> items = await _keychain.readAll();
    for (final MapEntry<String, String> item in items.entries) {
      if (!item.key.startsWith(_movingCopyPrefix)) {
        continue;
      }
      final String key = item.key.substring(_movingCopyPrefix.length);
      if (await _keychain.read(key) == null &&
          await _earlierKeychain.read(key) == null) {
        await _keychain.write(key, item.value);
      }
      await _keychain.delete(item.key);
    }
  }
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

  /// Re-confirms the person with the sealed key, without
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

  /// Whether the master key is kept for "Nigdy"
  /// ([appSecurityNeverLockMasterKeyStorageKey]): a start from scratch then
  /// opens without the password.
  bool get keepsNeverLockKey;

  /// Before "Nigdy" is chosen: [password] (the app password) unwraps the
  /// master key, which is then kept in the system's secret store. `false`,
  /// keeping nothing, for a wrong password or none set. The lock mode itself
  /// is the settings' (choosing another one drops the copy again).
  Future<bool> keepMasterKeyForNeverLock(String password);

  /// The app password and the panic password as a backup of the whole
  /// account carries them ([AppLockCopy]); `null` when they cannot be told
  /// (the backup then carries no lock, and the restored app asks for a new
  /// password).
  Future<AppLockCopy?> lockCopy();

  /// After a backup of the whole account was read: [password], when it is
  /// the app password of [copy], becomes this app's password again, with
  /// the cost and salt it had there. It wraps this device's own master key
  /// (the data here is sealed with that one, not with the other device's),
  /// and the copy's panic password comes with it. `false`, changing
  /// nothing, for another password or a copy without one. Needs the app
  /// unlocked. Biometric unlock and the key for "Nigdy" stay this device's
  /// own.
  Future<bool> takeLockCopy(AppLockCopy copy, String password);

  void lock();

  Future<void> reset();

  Future<Uint8List?> currentEncryptionKey();

  /// The secure storage this service keeps its credentials in (the lock
  /// screen keeps its failed-attempt counter there too).
  AppSecurityCredentialsStore get credentialsStore;
}

Future<bool> loadStoredAppSecurityHasPassword([
  AppSecurityCredentialsStore credentialsStore =
      const SecureStorageCredentialsStore(),
]) async {
  return await credentialsStore.read(appSecurityPasswordHashStorageKey) != null;
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

  /// Argon2id cost for new passwords (copied files must not be easy
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

  /// Whether the copy for "Nigdy" is (believed to be) in the secret store.
  bool _neverLockKeyKept = false;
  AppLockMode _lockMode = AppSettings.defaultLockMode;
  int _backgroundLockDelaySeconds =
      AppSettings.defaultBackgroundLockDelaySeconds;
  Uint8List? _encryptionKey;

  @override
  bool get isReady => _isReady;

  @override
  AppSecurityCredentialsStore get credentialsStore => _credentialsStore;

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
      // unlocking (password) or by the stored biometric token — or, with
      // "Nigdy", by the copy kept for it.
      final String? keptHex = await _readNeverLockKeyEntry();
      final Uint8List? kept = keptHex == null
          ? null
          : await _matchingMasterKey(_decodeMasterKeyHex(keptHex));
      if (kept != null && _lockMode == AppLockMode.never) {
        _neverLockKeyKept = true;
        _encryptionKey = kept;
        _isLocked = false;
      } else {
        if (keptHex != null) {
          // Another mode (leaving "Nigdy" was cut short), or a copy that
          // does not match: nothing opens without the password.
          await _dropNeverLockKey();
        }
        _isLocked = true;
        _encryptionKey = null;
      }
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
    final bool leavesNeverLock =
        settings.lockMode != AppLockMode.never &&
        (_neverLockKeyKept || _lockMode == AppLockMode.never);
    _applySettingsState(settings);
    if (leavesNeverLock) {
      // Any other mode: the copy goes at once.
      await _dropNeverLockKey();
    }
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
      throw AppPasswordConflictException(kAppPasswordEqualsPanicMessage);
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
    // sealed by the hardware vault. A copy kept for "Nigdy" stays as it is
    // (the master key does not change); none is made here: only the
    // person's own choice keeps one (keepMasterKeyForNeverLock).
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
    final Uint8List? masterKey = await _masterKeyFor(
      password,
      saltHex,
      hashHex,
    );
    if (masterKey == null) {
      return false;
    }
    await _finishUnlock(masterKey);
    return true;
  }

  /// The master key [password] unwraps; `null` for a wrong password.
  Future<Uint8List?> _masterKeyFor(
    String password,
    String saltHex,
    String hashHex,
  ) async {
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
      return null;
    }
    return _unwrapMasterKey(wrappedHex, derivedKey);
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
      throw AppPasswordConflictException(kPanicPasswordEqualsMainMessage);
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

  @override
  bool get keepsNeverLockKey => _neverLockKeyKept;

  @override
  Future<bool> keepMasterKeyForNeverLock(String password) async {
    final String? saltHex = await _credentialsStore.read(
      appSecuritySaltStorageKey,
    );
    final String? hashHex = await _credentialsStore.read(
      appSecurityPasswordHashStorageKey,
    );
    if (saltHex == null || hashHex == null) {
      return false;
    }
    final Uint8List? masterKey = await _matchingMasterKey(
      await _masterKeyFor(password, saltHex, hashHex),
    );
    if (masterKey == null) {
      return false;
    }
    await _storeNeverLockKey(masterKey);
    notifyListeners();
    return _neverLockKeyKept;
  }

  @override
  Future<AppLockCopy?> lockCopy() async {
    final _StoredCheck password = await _storedCheck(
      appSecurityPasswordKdfStorageKey,
      appSecuritySaltStorageKey,
      appSecurityPasswordHashStorageKey,
    );
    final _StoredCheck panic = await _storedCheck(
      appSecurityPanicKdfStorageKey,
      appSecurityPanicSaltStorageKey,
      appSecurityPanicPasswordHashStorageKey,
    );
    if (password.unreadable || panic.unreadable) {
      return null;
    }
    // A panic password means something only on a lock screen.
    return AppLockCopy(
      password: password.check,
      panic: password.check == null ? null : panic.check,
    );
  }

  /// The password whose verifier is under [hashKey], as a copy carries it.
  Future<_StoredCheck> _storedCheck(
    String kdfKey,
    String saltKey,
    String hashKey,
  ) async {
    final String? hash = await _credentialsStore.read(hashKey);
    if (hash == null) {
      return const _StoredCheck(null);
    }
    final String? salt = await _credentialsStore.read(saltKey);
    final String? kdf = await _credentialsStore.read(kdfKey);
    AppPasswordCheck? check;
    if (salt != null && kdf != null) {
      try {
        final Object? json = jsonDecode(kdf);
        check = json is Map
            ? AppPasswordCheck.fromJson(<Object?, Object?>{
                ...json,
                's': salt,
                'c': hash,
              })
            : null;
      } on FormatException {
        check = null;
      }
    }
    return check == null
        ? const _StoredCheck(null, unreadable: true)
        : _StoredCheck(check);
  }

  @override
  Future<bool> takeLockCopy(AppLockCopy copy, String password) async {
    final Uint8List? masterKey = _encryptionKey;
    if (masterKey == null) {
      throw StateError('Cannot take a password while the app is locked.');
    }
    final AppPasswordCheck? check = copy.password;
    final Uint8List? derivedKey = check == null
        ? null
        : await check.keyFor(password);
    if (check == null || derivedKey == null) {
      return false;
    }
    final Uint8List wrappedMasterKey = await encryptSecurityBytes(
      masterKey,
      derivedKey,
    );
    // The same entries as setPassword writes, with the copy's cost, salt
    // and verifier: the password opens this device's master key now.
    await _credentialsStore.write(
      appSecurityPasswordKdfStorageKey,
      check.kdfJson,
    );
    await _credentialsStore.write(
      appSecuritySaltStorageKey,
      securityHexFromBytes(check.salt),
    );
    await _credentialsStore.write(
      appSecurityPasswordHashStorageKey,
      securityHexFromBytes(check.check),
    );
    await _credentialsStore.write(
      appSecurityWrappedMasterKeyStorageKey,
      securityHexFromBytes(wrappedMasterKey),
    );
    await _credentialsStore.write(
      appSecurityMasterKeyFingerprintStorageKey,
      securityHexFromBytes(securityMasterFingerprint(masterKey)),
    );
    final AppPasswordCheck? panic = copy.panic;
    if (panic == null) {
      await _credentialsStore.delete(appSecurityPanicPasswordHashStorageKey);
      await _credentialsStore.delete(appSecurityPanicSaltStorageKey);
      await _credentialsStore.delete(appSecurityPanicKdfStorageKey);
    } else {
      await _credentialsStore.write(
        appSecurityPanicKdfStorageKey,
        panic.kdfJson,
      );
      await _credentialsStore.write(
        appSecurityPanicSaltStorageKey,
        securityHexFromBytes(panic.salt),
      );
      await _credentialsStore.write(
        appSecurityPanicPasswordHashStorageKey,
        securityHexFromBytes(panic.check),
      );
    }
    // As in setPassword: a biometric token only where this device's person
    // turned it on, and the device master key's plain copy goes.
    await _storeBiometricToken(masterKey);
    await _credentialsStore.delete(appSecurityDeviceMasterKeyStorageKey);
    _hasPassword = true;
    _hasPanicPassword = panic != null;
    _isLocked = false;
    notifyListeners();
    return true;
  }

  /// Keeps [masterKey] for "Nigdy" (see
  /// [appSecurityNeverLockMasterKeyStorageKey]).
  Future<void> _storeNeverLockKey(Uint8List masterKey) async {
    try {
      await _credentialsStore.write(
        appSecurityNeverLockMasterKeyStorageKey,
        securityHexFromBytes(masterKey),
      );
      _neverLockKeyKept = true;
    } on Object catch (error, stackTrace) {
      logZenError('Keeping the key for "Nigdy" failed', error, stackTrace);
      await _dropNeverLockKey();
    }
  }

  /// Drops the copy kept for "Nigdy": the password opens the data again.
  Future<void> _dropNeverLockKey() async {
    // Before the wait: a copy written meanwhile (an unlock) must count.
    _neverLockKeyKept = false;
    try {
      await _credentialsStore.delete(appSecurityNeverLockMasterKeyStorageKey);
    } on Object catch (error, stackTrace) {
      logZenError(
        'Dropping the key kept for "Nigdy" failed',
        error,
        stackTrace,
      );
    }
  }

  Future<String?> _readNeverLockKeyEntry() async {
    try {
      return await _credentialsStore.read(
        appSecurityNeverLockMasterKeyStorageKey,
      );
    } on Object catch (error, stackTrace) {
      logZenError('Reading the key kept for "Nigdy" failed', error, stackTrace);
      return null;
    }
  }

  /// [masterKey] when it is the one the stored fingerprint names; `null`
  /// otherwise, or without a fingerprint to check it against.
  Future<Uint8List?> _matchingMasterKey(Uint8List? masterKey) async {
    if (masterKey == null ||
        masterKey.length != appSecurityMasterKeyLengthBytes) {
      return null;
    }
    final String? fingerprintHex = await _credentialsStore.read(
      appSecurityMasterKeyFingerprintStorageKey,
    );
    if (fingerprintHex == null ||
        !securityConstantTimeEquals(
          securityMasterFingerprint(masterKey),
          securityBytesFromHex(fingerprintHex),
        )) {
      return null;
    }
    return masterKey;
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
    final Uint8List? masterKey = await _openSealedMasterKey(t('Odblokuj Zen'));
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
    if (_neverLockKeyKept) {
      // Locked by hand under "Nigdy": the lock holds across a restart too
      // (with the panic password there to type), and a start from scratch
      // asks for the password until "Nigdy" is chosen again. The lock
      // screen shows only once the copy is gone, so closing the app at
      // once cannot bring it back.
      unawaited(_dropNeverLockKey().whenComplete(notifyListeners));
      return;
    }
    notifyListeners();
  }

  /// Every credential [reset] destroys, the ones that open the data first
  /// (crypto-shredding: once they are gone, whatever is left on disk is
  /// noise, even if deleting the files is cut short).
  static const List<String> _keyMaterial = <String>[
    appSecurityWrappedMasterKeyStorageKey,
    appSecurityDeviceMasterKeyStorageKey,
    appSecurityNeverLockMasterKeyStorageKey,
    appSecuritySealedBiometricTokenStorageKey,
    appSecurityPasswordHashStorageKey,
    // The node identity and what the background service may read.
    appSecurityBackgroundKeyStorageKey,
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
    appSecurityUnlockFailuresStorageKey,
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
    _neverLockKeyKept = false;
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
    // No copy for "Nigdy" here, even on that mode (after a lock by hand,
    // or with settings brought back from elsewhere): only the person's own
    // choice keeps one (keepMasterKeyForNeverLock).
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

/// A stored password as a copy carries it: [check], or none set — or one
/// set that cannot be read ([unreadable]).
final class _StoredCheck {
  const _StoredCheck(this.check, {this.unreadable = false});

  final AppPasswordCheck? check;
  final bool unreadable;
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
