import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_recovery.dart';

/// This installation's account and device keys.
///
/// Created on first use (this device becomes the account's first certified
/// device). Kept in the app's encrypted storage. Once the account password is set (§6.1) the
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

  /// Reads the saved identity, or creates and saves a new one.
  /// Whether an identity was saved on [disk] already.
  static Future<bool> exists(LedgerDisk disk) async =>
      await _load(disk) != null;

  /// The saved identity, or `null` when there is none yet. Never creates
  /// one (only the ledger node does), e.g. for signing with the device key
  /// outside the ledger (§24.1 introductions).
  static Future<LedgerIdentity?> read(LedgerDisk disk) => _load(disk);

  static Future<LedgerIdentity> loadOrCreate(
    LedgerDisk disk, {
    String deviceName = 'Urządzenie',
    int Function()? now,
  }) async {
    final LedgerIdentity? saved = await _load(disk);
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

  /// Makes this installation a new device of the account with [accountSeed]
  /// (after recovery, or when linking a device). Replaces whatever identity
  /// was there; the app must restart its ledger afterwards.
  static Future<LedgerIdentity> adoptAccount(
    LedgerDisk disk,
    Uint8List accountSeed, {
    String deviceName = 'Urządzenie',
    int Function()? now,
  }) async => _create(
    disk,
    await LedgerKeyPair.fromSeed(accountSeed),
    deviceName: deviceName,
    now: now,
  );

  static Future<LedgerIdentity> _create(
    LedgerDisk disk,
    LedgerKeyPair account, {
    required String deviceName,
    int Function()? now,
  }) async {
    final LedgerKeyPair device = await LedgerKeyPair.generate();
    final DeviceCertificate cert = await DeviceCertificate.issue(
      account: account,
      device: device.id,
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
            'cert': certificate.toJson(),
            'writer': writer,
          }),
        ),
      ),
    );
  }

  static Future<LedgerIdentity?> _load(LedgerDisk disk) async {
    final Uint8List? raw = await disk.read(storageKey);
    if (raw == null) {
      return null;
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return null;
    }
    if (json is! Map) {
      return null;
    }
    final Uint8List? deviceSeed = unb64(json['device'], length: 32);
    final DeviceCertificate? cert = DeviceCertificate.fromJson(json['cert']);
    final Object? writer = json['writer'];
    if (deviceSeed == null || cert == null || !isHex(writer, 32)) {
      return null;
    }
    final Uint8List? selfKey = unb64(json['self'], length: 32);
    final LedgerKeyPair device = await LedgerKeyPair.fromSeed(deviceSeed);
    if (cert.device != device.id) {
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
      );
    }
    if (json['v'] == _wrappedVersion) {
      final Object? acc = json['acc'];
      final PasswordWrappedSeed? w = PasswordWrappedSeed.fromJson(
        json['wrapped'],
      );
      if (acc is! String || w == null || cert.account != acc) {
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
      );
    }
    return null;
  }
}
