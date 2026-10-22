import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

/// A signing key (account, device, pyramid, alarm, maintainer… key): a
/// 32-byte seed with both public halves of Zen's hybrid signature
/// (Ed25519 + ML-DSA-65, hybrid_signature.dart). [id] is the Ed25519 half,
/// [pqId] the fingerprint of the ML-DSA half.
final class LedgerKeyPair {
  LedgerKeyPair._(this.seed, this.publicKey, this.pqPublicKey, this.pqId);

  final Uint8List seed;

  /// The Ed25519 public key.
  final Uint8List publicKey;

  /// The ML-DSA-65 public key.
  final Uint8List pqPublicKey;

  /// SHA-256 of [pqPublicKey], base64url.
  final String pqId;

  String get id => b64(publicKey);

  /// Both halves in one text ([hybridKeyId]).
  String get hybridId => hybridKeyId(id, pqId);

  static Future<LedgerKeyPair> generate() => fromSeed(randomBytes(32));

  static Future<LedgerKeyPair> fromSeed(Uint8List seed) async {
    if (seed.length != 32) {
      throw ArgumentError('Ziarno klucza musi mieć 32 bajty.');
    }
    final HybridPublicKey key = await hybridSigner.publicKeyOf(
      Uint8List.fromList(seed),
    );
    // Own keys are always at hand to check what this device signed.
    HybridKeyBook.add(key.pq);
    return LedgerKeyPair._(
      Uint8List.fromList(seed),
      key.ed,
      key.pq,
      b64(key.fingerprint),
    );
  }

  /// The hybrid signature of [message] (3405 bytes): it names the ML-DSA
  /// key by fingerprint, so whoever checks it needs the key from the
  /// record that published it ([DeviceCertificate], a pyramid admission).
  Future<Uint8List> sign(List<int> message) =>
      hybridSigner.signDigest(seed, hybridDigest(message));

  /// The keyed hybrid signature of [message] (5325 bytes): it carries the
  /// ML-DSA key, for records checked where no record of the key can be at
  /// hand yet — the record that introduces the key, what strangers check
  /// (releases, bridge announcements, neighbours' frames, alarms).
  Future<Uint8List> signWithKey(List<int> message) =>
      hybridSigner.signDigest(seed, hybridDigest(message), withKey: true);

  /// A classical Ed25519 signature (64 bytes) — only for what must fit a
  /// QR code and is checked on the spot (an event ticket at the door,
  /// docs/PROTOCOL.md §4.1). Everything kept or passed on is signed with
  /// [sign].
  Future<Uint8List> signClassical(List<int> message) async {
    final Ed25519 ed = Ed25519();
    final Signature signature = await ed.sign(
      message,
      keyPair: await ed.newKeyPairFromSeed(seed),
    );
    return Uint8List.fromList(signature.bytes);
  }
}

/// Checks a classical Ed25519 signature ([LedgerKeyPair.signClassical]);
/// false for anything malformed. Never for what is kept or passed on.
Future<bool> verifyClassicalSignature({
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
    return await Ed25519().verify(
      message,
      signature: Signature(
        sig,
        publicKey: SimplePublicKey(pk, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

/// Checks a hybrid signature (hybrid_signature.dart) by the key [publicKey]
/// (its Ed25519 id): both halves must hold, and the ML-DSA key it names or
/// carries must be [pqId] when a record anchors the key (device
/// certificates, maintainers, alarm keys), otherwise the one pinned for
/// [publicKey] ([HybridKeyPins]) if any.
///
/// A signature that names its ML-DSA key is checked with [pqKey] (from the
/// record that publishes it) or the key [HybridKeyBook] holds. Without the
/// key it is **not** taken: false, like anything malformed (an
/// Ed25519-only signature included); callers that can wait fetch the
/// record ([hybridSignatureLacksKey]) and check again.
Future<bool> verifyLedgerSignature({
  required String publicKey,
  required List<int> message,
  required String signature,
  String? pqId,
  Uint8List? pqKey,
}) async {
  final Uint8List? pk = unb64(publicKey, length: 32);
  final Uint8List? sig = decodeHybridSignature(signature);
  if (pk == null || sig == null) {
    return false;
  }
  final String ed = b64(pk);
  final Uint8List? fingerprint = hybridSignatureFingerprint(sig);
  if (fingerprint == null) {
    return false;
  }
  final String named = b64(fingerprint);
  if (pqId != null ? named != pqId : !HybridKeyPins.admits(ed, named)) {
    return false;
  }
  final bool keyed = hybridSignaturePqKey(sig) != null;
  final Uint8List? key = keyed ? pqKey : pqKey ?? HybridKeyBook.lookup(named);
  if (!keyed && key == null) {
    return false;
  }
  try {
    if (!await hybridSigner.verifyDigest(
      pk,
      hybridDigest(message),
      sig,
      pqKey: key,
    )) {
      return false;
    }
  } on Object {
    return false;
  }
  HybridKeyPins.pin(ed, named);
  return true;
}

bool _isKey(Object? value) => unb64(value, length: 32) != null;

/// The ML-DSA public key in [value] (base64url, its one canonical
/// spelling), or `null`.
Uint8List? _pqKeyOf(Object? value) {
  final Uint8List? key = unb64(value, length: kMlDsaPublicKeyBytes);
  return key != null && b64(key) == value ? key : null;
}

/// "Device [device] belongs to account [account]", signed by the account
/// key: the **device record**. It publishes the device key's ML-DSA half
/// ([devicePqKey]) once, so what the device signs (every ledger entry, its
/// hello) names that key by fingerprint only and is checked against
/// exactly that key ([verifyByDevice]). The account's signature carries
/// the account's ML-DSA key (keyed form), so a certificate can be checked
/// by anyone on its own.
///
/// Entries do not carry it: a store keeps the certificates of the devices
/// whose entries it holds ([AccountDirectory]) and asks the peer that sent
/// an entry for the certificate it lacks (`lg_cert_want`). An entry passed
/// on outside the ledger (a reshare, a report) goes with it
/// ([LogEntry.toCertifiedJson]).
@immutable
final class DeviceCertificate {
  const DeviceCertificate({
    required this.account,
    required this.device,
    required this.devicePqKey,
    required this.name,
    required this.issued,
    required this.signature,
  });

  final String account;
  final String device;

  /// The device key's ML-DSA public key (base64url,
  /// [LedgerKeyPair.pqPublicKey]).
  final String devicePqKey;
  final String name;
  final int issued;
  final String signature;

  static const int maxNameLength = 60;

  static final Expando<Uint8List> _pqKeys = Expando<Uint8List>('devicePq');
  static final Expando<String> _pqIds = Expando<String>('devicePqId');

  /// [devicePqKey] decoded (once: every entry of the device is checked
  /// with it).
  Uint8List get _pqKey => _pqKeys[this] ??=
      unb64(devicePqKey, length: kMlDsaPublicKeyBytes) ?? Uint8List(0);

  /// The fingerprint of [devicePqKey] ([LedgerKeyPair.pqId]).
  String get devicePq => _pqIds[this] ??= pqFingerprintOf(_pqKey);

  static Map<String, dynamic> _payload(
    String account,
    String device,
    String devicePqKey,
    String name,
    int issued,
  ) => <String, dynamic>{
    't': 'dev_cert',
    'account': account,
    'device': device,
    'dpk': devicePqKey,
    'name': name,
    'issued': issued,
  };

  static Future<DeviceCertificate> issue({
    required LedgerKeyPair account,
    required LedgerKeyPair device,
    required String name,
    required int issued,
  }) async {
    final String clipped = name.length > maxNameLength
        ? name.substring(0, maxNameLength)
        : name;
    final String devicePqKey = b64(device.pqPublicKey);
    final Uint8List sig = await account.signWithKey(
      canonicalJsonBytes(
        _payload(account.id, device.id, devicePqKey, clipped, issued),
      ),
    );
    return DeviceCertificate(
      account: account.id,
      device: device.id,
      devicePqKey: devicePqKey,
      name: clipped,
      issued: issued,
      signature: b64(sig),
    );
  }

  Future<bool> verify() => verifyLedgerSignature(
    publicKey: account,
    message: canonicalJsonBytes(
      _payload(account, device, devicePqKey, name, issued),
    ),
    signature: signature,
  );

  /// Whether [signature] over [message] is the device's: its Ed25519 half
  /// and exactly the ML-DSA key this certificate publishes.
  Future<bool> verifyByDevice(List<int> message, String signature) =>
      verifyLedgerSignature(
        publicKey: device,
        message: message,
        signature: signature,
        pqId: devicePq,
        pqKey: _pqKey,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._payload(account, device, devicePqKey, name, issued),
    'sig': signature,
  };

  static DeviceCertificate? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'dev_cert' ||
        !_isKey(json['account']) ||
        !_isKey(json['device']) ||
        _pqKeyOf(json['dpk']) == null ||
        json['name'] is! String ||
        (json['name'] as String).length > maxNameLength ||
        json['issued'] is! int ||
        !isKeyedHybridSignatureText(json['sig'])) {
      return null;
    }
    return DeviceCertificate(
      account: json['account'] as String,
      device: json['device'] as String,
      devicePqKey: json['dpk'] as String,
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
    // Keyed: a revocation travels to everyone, also to phones that never
    // met the account (a cut-off must reach them before the device's
    // entries do).
    final Uint8List sig = await account.signWithKey(
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
        !isKeyedHybridSignatureText(json['sig'])) {
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

  /// Grows whenever a certificate is added (what the archive saves).
  int get revision => _revision;
  int _revision = 0;

  /// Grows whenever a certificate of [account] is added (what the archive
  /// saves, one file per account).
  int revisionOf(String account) => _accountRevisions[account] ?? 0;
  final Map<String, int> _accountRevisions = <String, int>{};

  /// Every account with a certificate known.
  Iterable<String> get accounts => _certs.keys;

  bool knowsCertificate(DeviceCertificate cert) =>
      _certs[cert.account]?[cert.device]?.signature == cert.signature;

  /// The certificate of [device] of [account], if known: what its entries
  /// are checked with.
  DeviceCertificate? certificateOf(String account, String device) =>
      _certs[account]?[device];

  /// Every certificate known.
  Iterable<DeviceCertificate> get certificates =>
      _certs.values.expand((Map<String, DeviceCertificate> m) => m.values);

  void _put(DeviceCertificate cert) {
    (_certs[cert.account] ??= <String, DeviceCertificate>{})[cert.device] =
        cert;
    _revision++;
    _accountRevisions[cert.account] = revisionOf(cert.account) + 1;
  }

  /// Records a certificate read back from our own storage (checked when it
  /// first arrived); it pins the account's ML-DSA key again
  /// ([HybridKeyPins]).
  void trustCertificate(DeviceCertificate cert) {
    if (HybridKeyPins.pinnedFor(cert.account) == null) {
      HybridKeyPins.pinSignature(cert.account, cert.signature);
    }
    if (!knowsCertificate(cert)) {
      _put(cert);
    }
  }

  /// Records a certificate after checking its signature.
  Future<bool> addCertificate(DeviceCertificate cert) async {
    if (knowsCertificate(cert)) {
      return true;
    }
    if (!await cert.verify()) {
      return false;
    }
    _put(cert);
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
