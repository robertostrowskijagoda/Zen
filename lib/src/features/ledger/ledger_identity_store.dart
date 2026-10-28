import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/features/account/account_recovery.dart';

/// This installation's account and device keys.
///
/// Created on first use (this device becomes the account's first certified
/// device). Kept in the app's encrypted storage. Once the account password is set the
/// account key is stored only wrapped by it: daily work needs just the
/// device key, and a stolen phone without the password cannot take over
/// the account.
final class LedgerIdentity {
  LedgerIdentity._({
    required this.account,
    required LedgerKeyPair? accountKey,
    required this.deviceKey,
    required this.certificate,
    required this.writer,
    required this.pyramidSeed,
    PasswordWrappedSeed? wrapped,
    Uint8List? selfKey,
  }) : _accountKey = accountKey,
       _wrapped = wrapped,
       _selfKey = selfKey;

  static const String storageKey = 'ledger/identity';

  /// v1: plain account seed. v2: account seed wrapped by the password.
  static const int _plainVersion = 1;
  static const int _wrappedVersion = 2;

  /// Public key (id) of the account.
  final String account;
  LedgerKeyPair? _accountKey;
  final LedgerKeyPair deviceKey;
  final DeviceCertificate certificate;

  /// Log id of this installation (never reused, see [LedgerAuthor]).
  final String writer;

  /// The password-wrapped seed, once a password is set.
  PasswordWrappedSeed? get wrapped => _wrapped;
  PasswordWrappedSeed? _wrapped;

  bool get hasPassword => wrapped != null;

  /// Key only this account's own devices hold (derived from the account
  /// key): seals what goes into the private space — the backup of friends
  /// and groups — so friends can keep a copy without reading it.
  Uint8List? get selfKey => _selfKey;
  Uint8List? _selfKey;

  static Future<Uint8List> deriveSelfKey(Uint8List accountSeed) async {
    final SecretKey key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: SecretKey(accountSeed),
          info: utf8.encode('zen.self.v1'),
          nonce: const <int>[],
        );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Seed of the pyramid identity key, derived from the
  /// account key: every device of the account is the same person in the
  /// pyramid, and a recovered account gets its place and wallet back. Kept
  /// next to the device key, so it is at hand while the account key is
  /// locked by the password.
  final Uint8List pyramidSeed;

  static Future<Uint8List> derivePyramidSeed(Uint8List accountSeed) async {
    final SecretKey key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: SecretKey(accountSeed),
          info: utf8.encode('zen.pyramid.v1'),
          nonce: const <int>[],
        );
    return Uint8List.fromList(await key.extractBytes());
  }

  /// Derives and saves [selfKey] if it is missing and the account key is
  /// at hand (identities from before it existed, after [unlock]).
  Future<bool> rememberSelfKey(LedgerDisk disk) async {
    final LedgerKeyPair? key = _accountKey;
    if (_selfKey != null || key == null) {
      return false;
    }
    _selfKey = await deriveSelfKey(key.seed);
    await _save(disk);
    return true;
  }

  /// The account key while it is at hand (always before a password is
  /// set; after that only once [unlock]ed in this session).
  LedgerKeyPair? get accountKey => _accountKey;

  /// Whether an identity was saved on [disk] already (one that can no
  /// longer be read counts: it must not be replaced by a new account).
  static Future<bool> exists(LedgerDisk disk) async {
    try {
      return await _load(disk) != null;
    } on DamagedLedgerIdentityException {
      return true;
    }
  }

  /// The saved identity, or `null` when there is none yet or it cannot be
  /// read. Never creates one (only the ledger node does), e.g. for signing
  /// with the device key outside the ledger (introductions).
  static Future<LedgerIdentity?> read(LedgerDisk disk) async {
    try {
      return await _load(disk);
    } on DamagedLedgerIdentityException {
      return null;
    }
  }

  /// The saved identity, or `null` when there is none yet; throws
  /// [DamagedLedgerIdentityException] when one is there but cannot be read.
  static Future<LedgerIdentity?> load(LedgerDisk disk) => _load(disk);

  /// Reads the saved identity, or creates and saves a new one when there is
  /// none. One that cannot be read is never replaced
  /// ([DamagedLedgerIdentityException]): a new one would be another account.
  static Future<LedgerIdentity> loadOrCreate(
    LedgerDisk disk, {
    String deviceName = 'Urządzenie',
    int Function()? now,
  }) async {
    final LedgerIdentity? saved;
    try {
      saved = await _load(disk);
    } on DamagedLedgerIdentityException {
      // The account key may still read (only the device part is damaged):
      // this installation becomes a new device of the same account, as
      // after linking it.
      final Uint8List? seed = await _plainAccountSeed(disk);
      if (seed == null) {
        rethrow;
      }
      return adoptAccount(disk, seed, deviceName: deviceName, now: now);
    }
    if (saved != null) {
      return saved;
    }
    return _create(
      disk,
      await LedgerKeyPair.generate(),
      deviceName: deviceName,
      now: now,
    );
  }

  /// The account seed of a saved identity without a password whose other
  /// parts do not read; null when that cannot be read either.
  static Future<Uint8List?> _plainAccountSeed(LedgerDisk disk) async {
    try {
      final Uint8List? raw = await disk.read(storageKey);
      if (raw == null) {
        return null;
      }
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map || json['v'] != _plainVersion) {
        return null;
      }
      return unb64(json['account'], length: 32);
    } on FormatException {
      return null;
    }
  }

  /// Makes this installation a new device of the account with [accountSeed]
  /// (after recovery, or when linking a device). Replaces whatever identity
  /// was there; the app must restart its ledger afterwards.
  static Future<LedgerIdentity> adoptAccount(
    LedgerDisk disk,
    Uint8List accountSeed, {
    String deviceName = 'Urządzenie',
    int Function()? now,
  }) async {
    final LedgerIdentity identity = await _create(
      disk,
      await LedgerKeyPair.fromSeed(accountSeed),
      deviceName: deviceName,
      now: now,
    );
    DamagedIdentityNotice.instance.clear();
    return identity;
  }

  static Future<LedgerIdentity> _create(
    LedgerDisk disk,
    LedgerKeyPair account, {
    required String deviceName,
    int Function()? now,
  }) async {
    final LedgerKeyPair device = await LedgerKeyPair.generate();
    final DeviceCertificate cert = await DeviceCertificate.issue(
      account: account,
      device: device,
      name: deviceName,
      issued: (now ?? () => DateTime.now().millisecondsSinceEpoch)(),
    );
    final LedgerIdentity identity = LedgerIdentity._(
      account: account.id,
      accountKey: account,
      deviceKey: device,
      certificate: cert,
      writer: randomId(),
      selfKey: await deriveSelfKey(account.seed),
      pyramidSeed: await derivePyramidSeed(account.seed),
    );
    await identity._save(disk);
    return identity;
  }

  /// Sets (or changes) the account password: from now on the account key
  /// is kept only wrapped by it. Needs the key at hand ([unlock] first when
  /// changing).
  Future<void> setPassword(
    LedgerDisk disk,
    String password, {
    PasswordCost cost = const PasswordCost(),
  }) async {
    final LedgerKeyPair? key = _accountKey;
    if (key == null) {
      throw StateError(t('Najpierw odblokuj konto starym hasłem.'));
    }
    _wrapped = await PasswordWrappedSeed.wrap(key.seed, password, cost: cost);
    await _save(disk);
  }

  /// Unwraps the account key with [password]; false if it is wrong.
  Future<bool> unlock(String password) async {
    final PasswordWrappedSeed? w = wrapped;
    if (w == null) {
      return _accountKey != null;
    }
    final Uint8List? seed = await w.unwrap(password);
    if (seed == null) {
      return false;
    }
    final LedgerKeyPair key = await LedgerKeyPair.fromSeed(seed);
    if (key.id != account) {
      return false;
    }
    _accountKey = key;
    return true;
  }

  /// Forgets the unwrapped account key (when a password is set).
  void lock() {
    if (wrapped != null) {
      _accountKey = null;
    }
  }

  /// This identity with a fresh [writer], saved: for a device whose own
  /// log could not be read back whole. Writing on under the old writer
  /// would number new entries like the lost ones, and everyone who holds
  /// those would see two histories (a fork) and refuse the log for good.
  Future<LedgerIdentity> withNewWriter(LedgerDisk disk) async {
    final LedgerIdentity renewed = LedgerIdentity._(
      account: account,
      accountKey: _accountKey,
      deviceKey: deviceKey,
      certificate: certificate,
      writer: randomId(),
      pyramidSeed: pyramidSeed,
      wrapped: _wrapped,
      selfKey: _selfKey,
    );
    await renewed._save(disk);
    return renewed;
  }

  Future<void> _save(LedgerDisk disk) async {
    final PasswordWrappedSeed? w = wrapped;
    await disk.write(
      storageKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, dynamic>{
            'v': w == null ? _plainVersion : _wrappedVersion,
            if (w == null)
              'account': b64(_accountKey!.seed)
            else ...<String, dynamic>{'acc': account, 'wrapped': w.toJson()},
            'device': b64(deviceKey.seed),
            if (_selfKey != null) 'self': b64(_selfKey!),
            'pyr': b64(pyramidSeed),
            'cert': certificate.toJson(),
            'writer': writer,
          }),
        ),
      ),
    );
  }

  /// The saved identity; `null` only when none was ever saved. One that is
  /// there but cannot be read (neither the file nor its backup) throws
  /// [DamagedLedgerIdentityException] and is left as it is: the account key
  /// is in it and nowhere else on this device, so nothing may save a new
  /// one over it (a second account under the same name, the links of
  /// friends and own devices broken). The person links this device again
  /// from another of theirs, or recovers the account.
  static Future<LedgerIdentity?> _load(LedgerDisk disk) async {
    final Uint8List? raw;
    try {
      raw = await disk.read(storageKey);
    } on FormatException catch (error) {
      if (!isDamagedStoredFile(error)) {
        rethrow;
      }
      throw DamagedLedgerIdentityException(error.message);
    }
    if (raw == null) {
      return null;
    }
    final LedgerIdentity? identity = await _parse(disk, raw);
    if (identity == null) {
      throw const DamagedLedgerIdentityException('unreadable contents');
    }
    return identity;
  }

  static Future<LedgerIdentity?> _parse(LedgerDisk disk, Uint8List raw) async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return null;
    }
    if (json is! Map) {
      return null;
    }
    if (formatAgeOf(json['v'], current: _wrappedVersion) == FormatAge.newer) {
      // A newer build's identity: kept as it is and never replaced by a
      // fresh one (that would be a different account).
      holdNewerOn(disk, storageKey);
      throw NewerFormatException(
        storageKey,
        found: json['v'],
        supported: _wrappedVersion,
      );
    }
    final Uint8List? deviceSeed = unb64(json['device'], length: 32);
    final DeviceCertificate? cert = DeviceCertificate.fromJson(json['cert']);
    final Object? writer = json['writer'];
    if (deviceSeed == null || cert == null || !isHex(writer, 32)) {
      return null;
    }
    final Uint8List? selfKey = unb64(json['self'], length: 32);
    final LedgerKeyPair device = await LedgerKeyPair.fromSeed(deviceSeed);
    if (cert.device != device.id || cert.devicePq != device.pqId) {
      return null;
    }
    if (json['v'] == _plainVersion) {
      final Uint8List? accountSeed = unb64(json['account'], length: 32);
      if (accountSeed == null) {
        return null;
      }
      final LedgerKeyPair account = await LedgerKeyPair.fromSeed(accountSeed);
      if (cert.account != account.id) {
        return null;
      }
      return LedgerIdentity._(
        account: account.id,
        accountKey: account,
        deviceKey: device,
        certificate: cert,
        writer: writer as String,
        selfKey: selfKey ?? await deriveSelfKey(accountSeed),
        pyramidSeed: await derivePyramidSeed(accountSeed),
      );
    }
    if (json['v'] == _wrappedVersion) {
      final Object? acc = json['acc'];
      final PasswordWrappedSeed? w = PasswordWrappedSeed.fromJson(
        json['wrapped'],
      );
      final Uint8List? pyramidSeed = unb64(json['pyr'], length: 32);
      if (acc is! String ||
          w == null ||
          cert.account != acc ||
          pyramidSeed == null) {
        return null;
      }
      return LedgerIdentity._(
        account: acc,
        accountKey: null,
        deviceKey: device,
        certificate: cert,
        writer: writer as String,
        wrapped: w,
        selfKey: selfKey,
        pyramidSeed: pyramidSeed,
      );
    }
    return null;
  }
}

/// This device's account identity is on disk but cannot be read (both
/// copies damaged). The ledger stays off (posts, profiles, own devices)
/// until the device is linked again or the account recovered; the rest of
/// the app works. Never answered with a new identity: that would be another
/// account.
final class DamagedLedgerIdentityException implements Exception {
  const DamagedLedgerIdentityException(this.reason);

  /// What was wrong (never key material).
  final String reason;

  @override
  String toString() => 'DamagedLedgerIdentityException: $reason';
}

/// Tells the app that this device's account identity cannot be read
/// ([DamagedLedgerIdentityException]): the settings say so and lead to
/// linking the device again ("Urządzenia"). Cleared once an account is
/// adopted.
final class DamagedIdentityNotice extends ChangeNotifier {
  DamagedIdentityNotice();

  /// The one the ledger reports to.
  static final DamagedIdentityNotice instance = DamagedIdentityNotice();

  bool _damaged = false;

  bool get damaged => _damaged;

  void note() {
    if (_damaged) {
      return;
    }
    _damaged = true;
    logZenWarning(
      'The account identity on this device cannot be read; posts, profiles '
      'and own devices stay off until the device is linked again.',
    );
    notifyListeners();
  }

  void clear() {
    if (!_damaged) {
      return;
    }
    _damaged = false;
    notifyListeners();
  }
}
