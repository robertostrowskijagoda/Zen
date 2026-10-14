import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

final Ed25519 _ed25519 = Ed25519();

/// An Ed25519 key pair (account or device key).
final class LedgerKeyPair {
  LedgerKeyPair._(this.seed, this.publicKey, this._pair);

  final Uint8List seed;
  final Uint8List publicKey;
  final SimpleKeyPair _pair;

  String get id => b64(publicKey);

  static Future<LedgerKeyPair> generate() => fromSeed(randomBytes(32));

  static Future<LedgerKeyPair> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ziarno klucza musi mieć 32 bajty.');
    }
    final SimpleKeyPair pair = await _ed25519.newKeyPairFromSeed(seed);
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    return LedgerKeyPair._(
      Uint8List.fromList(seed),
      Uint8List.fromList(publicKey.bytes),
      pair,
    );
  }

  Future<Uint8List> sign(List<int> message) async {
    final Signature signature = await _ed25519.sign(message, keyPair: _pair);
    return Uint8List.fromList(signature.bytes);
  }
}

/// Checks an Ed25519 signature; false for anything malformed.
Future<bool> verifyLedgerSignature({
  required String publicKey,
  required List<int> message,
  required String signature,
}) async {
  final Uint8List? pk = unb64(publicKey, length: 32);
  final Uint8List? sig = unb64(signature, length: 64);
  if (pk == null || sig == null) {
    return false;
  }
  try {
    return await _ed25519.verify(
      message,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}

bool _isKey(Object? value) => unb64(value, length: 32) != null;

/// "Device [device] belongs to account [account]", signed by the account
/// key. Travels inside every entry the device writes, so any entry can be
/// checked by anyone, even a stranger who got it through a reshare.
@immutable
final class DeviceCertificate {
  const DeviceCertificate({
    required this.account,
    required this.device,
    required this.name,
    required this.issued,
    required this.signature,
  });

  final String account;
  final String device;
  final String name;
  final int issued;
  final String signature;

  static const int maxNameLength = 60;

  static Map<String, dynamic> _payload(
    String account,
    String device,
    String name,
    int issued,
  ) => <String, dynamic>{
    't': 'dev_cert',
    'account': account,
    'device': device,
    'name': name,
    'issued': issued,
  };

  static Future<DeviceCertificate> issue({
    required LedgerKeyPair account,
    required String device,
    required String name,
    required int issued,
  }) async {
    final String clipped = name.length > maxNameLength
        ? name.substring(0, maxNameLength)
        : name;
    final Uint8List sig = await account.sign(
      canonicalJsonBytes(_payload(account.id, device, clipped, issued)),
    );
    return DeviceCertificate(
      account: account.id,
      device: device,
      name: clipped,
      issued: issued,
      signature: b64(sig),
    );
  }

  Future<bool> verify() => verifyLedgerSignature(
    publicKey: account,
    message: canonicalJsonBytes(_payload(account, device, name, issued)),
    signature: signature,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._payload(account, device, name, issued),
    'sig': signature,
  };

  static DeviceCertificate? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'dev_cert' ||
        !_isKey(json['account']) ||
        !_isKey(json['device']) ||
        json['name'] is! String ||
        (json['name'] as String).length > maxNameLength ||
        json['issued'] is! int ||
        json['sig'] is! String) {
      return null;
    }
    return DeviceCertificate(
      account: json['account'] as String,
      device: json['device'] as String,
      name: json['name'] as String,
      issued: json['issued'] as int,
      signature: json['sig'] as String,
    );
  }
}

/// "Stop trusting [device]", signed by the account key.
///
/// [cutoffs] lists, per log the device wrote, the last entry that stays
/// valid (what the owner had already seen). A log is named
/// `writer@space` (see [cutoffKey]); a bare `writer` applies to every
/// space. Every later entry, and every
/// entry of a log not listed, is refused, so a stolen phone cannot slip in
/// back-dated posts after it was cut off.
@immutable
final class DeviceRevocation {
  const DeviceRevocation({
    required this.account,
    required this.device,
    required this.cutoffs,
    required this.issued,
    required this.signature,
  });

  final String account;
  final String device;
  final Map<String, int> cutoffs;
  final int issued;
  final String signature;

  static Map<String, dynamic> _payload(
    String account,
    String device,
    Map<String, int> cutoffs,
    int issued,
  ) => <String, dynamic>{
    't': 'dev_revoke',
    'account': account,
    'device': device,
    'cutoffs': cutoffs,
    'issued': issued,
  };

  static Future<DeviceRevocation> issue({
    required LedgerKeyPair account,
    required String device,
    required Map<String, int> cutoffs,
    required int issued,
  }) async {
    final Uint8List sig = await account.sign(
      canonicalJsonBytes(_payload(account.id, device, cutoffs, issued)),
    );
    return DeviceRevocation(
      account: account.id,
      device: device,
      cutoffs: Map<String, int>.unmodifiable(cutoffs),
      issued: issued,
      signature: b64(sig),
    );
  }

  Future<bool> verify() => verifyLedgerSignature(
    publicKey: account,
    message: canonicalJsonBytes(_payload(account, device, cutoffs, issued)),
    signature: signature,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._payload(account, device, cutoffs, issued),
    'sig': signature,
  };

  static DeviceRevocation? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'dev_revoke' ||
        !_isKey(json['account']) ||
        !_isKey(json['device']) ||
        json['cutoffs'] is! Map ||
        json['issued'] is! int ||
        json['sig'] is! String) {
      return null;
    }
    final Map<String, int> cutoffs = <String, int>{};
    for (final MapEntry<dynamic, dynamic> e
        in (json['cutoffs'] as Map).entries) {
      if (!_isCutoffKey(e.key) || e.value is! int || (e.value as int) < 0) {
        return null;
      }
      cutoffs[e.key as String] = e.value as int;
    }
    return DeviceRevocation(
      account: json['account'] as String,
      device: json['device'] as String,
      cutoffs: Map<String, int>.unmodifiable(cutoffs),
      issued: json['issued'] as int,
      signature: json['sig'] as String,
    );
  }
}

/// Name of one log in [DeviceRevocation.cutoffs]: a device's writer
/// writes one log per space, each with its own numbering.
String cutoffKey(String writer, String space) => '$writer@$space';

bool _isCutoffKey(Object? key) {
  if (key is! String) {
    return false;
  }
  final int at = key.indexOf('@');
  if (at < 0) {
    return isHex(key, 32);
  }
  return isHex(key.substring(0, at), 32) &&
      key.length - at - 1 > 0 &&
      key.length - at - 1 <= 200;
}

/// Which devices belong to which account, and which were cut off.
final class AccountDirectory {
  final Map<String, Map<String, DeviceCertificate>> _certs =
      <String, Map<String, DeviceCertificate>>{};
  final Map<String, List<DeviceRevocation>> _revocations =
      <String, List<DeviceRevocation>>{};

  static String _key(String account, String device) => '$account|$device';

  bool knowsCertificate(DeviceCertificate cert) =>
      _certs[cert.account]?[cert.device]?.signature == cert.signature;

  /// Records a certificate read back from our own storage (checked when it
  /// first arrived).
  void trustCertificate(DeviceCertificate cert) {
    (_certs[cert.account] ??= <String, DeviceCertificate>{})[cert.device] =
        cert;
  }

  /// Records a certificate after checking its signature.
  Future<bool> addCertificate(DeviceCertificate cert) async {
    if (knowsCertificate(cert)) {
      return true;
    }
    if (!await cert.verify()) {
      return false;
    }
    (_certs[cert.account] ??= <String, DeviceCertificate>{})[cert.device] =
        cert;
    return true;
  }

  /// Records a revocation after checking its signature. Returns false for
  /// a bad signature; true (and nothing changes) for one already known.
  Future<bool> addRevocation(DeviceRevocation revocation) async {
    final List<DeviceRevocation> list =
        _revocations[_key(revocation.account, revocation.device)] ??=
            <DeviceRevocation>[];
    if (list.any((DeviceRevocation r) => r.signature == revocation.signature)) {
      return true;
    }
    if (!await revocation.verify()) {
      if (list.isEmpty) {
        _revocations.remove(_key(revocation.account, revocation.device));
      }
      return false;
    }
    list.add(revocation);
    return true;
  }

  bool isRevoked(String account, String device) =>
      _revocations[_key(account, device)]?.isNotEmpty ?? false;

  /// Every signed revocation known, as issued (for passing on).
  Iterable<DeviceRevocation> get revocations =>
      _revocations.values.expand((List<DeviceRevocation> l) => l);

  Iterable<DeviceCertificate> devicesOf(String account) =>
      _certs[account]?.values ?? const <DeviceCertificate>[];

  /// Whether entry [seq] of log [writer], written by [device] of [account],
  /// is still trusted. Several revocations combine to the strictest one.
  bool allowsEntry({
    required String account,
    required String device,
    required String writer,
    required int seq,
    String? space,
  }) {
    final List<DeviceRevocation>? list = _revocations[_key(account, device)];
    if (list == null || list.isEmpty) {
      return true;
    }
    for (final DeviceRevocation revocation in list) {
      final int keep =
          (space == null
              ? null
              : revocation.cutoffs[cutoffKey(writer, space)]) ??
          revocation.cutoffs[writer] ??
          0;
      if (seq > keep) {
        return false;
      }
    }
    return true;
  }
}
