import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
import 'package:zen/src/core/ledger/device_trust.dart';
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
///
/// [co] is a device's word on top of the account's (docs/SECURITY_MODEL.md,
/// "Cutting a device off"): another device of the account that counts
/// co-signs a device it linked or the person confirmed there, and such a
/// device counts with friends at once; one without it waits a day. A
/// device's co-signature of its own certificate only says that the account
/// uses co-signatures. It lies outside what the account key signs, so
/// versions before it pass the certificate on without it and check it as
/// before.
@immutable
final class DeviceCertificate {
  const DeviceCertificate({
    required this.account,
    required this.device,
    required this.devicePqKey,
    required this.name,
    required this.issued,
    required this.signature,
    this.co,
  });

  final String account;
  final String device;

  /// The device key's ML-DSA public key (base64url,
  /// [LedgerKeyPair.pqPublicKey]).
  final String devicePqKey;
  final String name;
  final int issued;
  final String signature;

  /// The co-signature, if any (unchecked as it comes: [verifyCo]).
  final CoSignature? co;

  /// Whether another device co-signed it ([co] by a device not this one).
  bool get coSignedByOther => co != null && co!.by != device;

  /// This certificate with [co] (or none) in place of its own.
  DeviceCertificate withCo(CoSignature? co) => DeviceCertificate(
    account: account,
    device: device,
    devicePqKey: devicePqKey,
    name: name,
    issued: issued,
    signature: signature,
    co: co,
  );

  Map<String, dynamic> _coPayload(String by) => <String, dynamic>{
    ..._payload(account, device, devicePqKey, name, issued),
    't': 'dev_co',
    'by': by,
  };

  /// This certificate co-signed by [signer], the device key of [by] (this
  /// very device, or another device of the account).
  Future<DeviceCertificate> coSignedBy(LedgerKeyPair signer) async {
    final Uint8List sig = await signer.sign(
      canonicalJsonBytes(_coPayload(signer.id)),
    );
    return withCo(CoSignature(by: signer.id, signature: b64(sig)));
  }

  /// Whether [co] holds: signed by this device itself, or by the device
  /// whose certificate is [signer] (of the same account, checked by the
  /// caller).
  Future<bool> verifyCo([DeviceCertificate? signer]) async {
    final CoSignature? c = co;
    if (c == null) {
      return false;
    }
    final DeviceCertificate? by = c.by == device ? this : signer;
    if (by == null || by.device != c.by || by.account != account) {
      return false;
    }
    return by.verifyByDevice(canonicalJsonBytes(_coPayload(c.by)), c.signature);
  }

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
    if (co != null) 'co': co!.toJson(),
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
      // A damaged co-signature costs only itself: the certificate is the
      // account's word and holds without it.
      co: CoSignature.fromJson(json['co']),
    );
  }
}

/// A device's co-signature of a [DeviceCertificate] (`co`).
@immutable
final class CoSignature {
  const CoSignature({required this.by, required this.signature});

  /// The device key (id) that signed.
  final String by;

  /// Its signature (naming its ML-DSA key by fingerprint).
  final String signature;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'by': by,
    'sig': signature,
  };

  static CoSignature? fromJson(Object? json) {
    if (json is! Map ||
        !_isKey(json['by']) ||
        !isHybridSignatureText(json['sig'])) {
      return null;
    }
    return CoSignature(
      by: json['by'] as String,
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
///
/// The cutting device's word goes on top of the account's (a device part:
/// [by], [keep], [deviceSignature] and [byCertificate], outside what the
/// account key signs, so versions before it pass it on without and take
/// the account's part as before): it names the devices its signer keeps.
/// Once an account co-signs its devices, a cut-off without a device part
/// is refused (docs/SECURITY_MODEL.md, "Cutting a device off").
@immutable
final class DeviceRevocation {
  const DeviceRevocation({
    required this.account,
    required this.device,
    required this.cutoffs,
    required this.issued,
    required this.signature,
    this.by,
    this.keep,
    this.deviceSignature,
    this.byCertificate,
  });

  final String account;
  final String device;
  final Map<String, int> cutoffs;
  final int issued;
  final String signature;

  /// The device that cut [device] off; null for a cut-off with the account
  /// key alone (or one passed on by a version that drops the device part).
  final String? by;

  /// The devices [by] keeps (itself not listed), sorted.
  final List<String>? keep;

  /// [by]'s signature over the account's part with [by] and [keep].
  final String? deviceSignature;

  /// [by]'s certificate, so the cut-off can be checked on its own.
  final DeviceCertificate? byCertificate;

  /// Whether it carries a device part (checked: [verifyDevicePart]).
  bool get hasDevicePart => by != null;

  /// Most logs one revocation names (a device writes one log per space);
  /// what a revocation would list beyond that is left out, so cut off
  /// whole. Bounds what one revocation costs to keep and pass on.
  static const int maxCutoffs = 1024;

  /// Most devices one cut-off keeps.
  static const int maxKeep = 64;

  static final Expando<String> _ids = Expando<String>('revocationId');
  static final Expando<int> _sizes = Expando<int>('revocationSize');

  /// A short id of this very revocation (from its signature).
  String get id =>
      _ids[this] ??= sha256Hex(utf8.encode(signature)).substring(0, 32);

  /// Its size as it travels (bytes of its JSON).
  int get encodedLength =>
      _sizes[this] ??= utf8.encode(jsonEncode(toJson())).length;

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

  static Map<String, dynamic> _devicePayload(
    String account,
    String device,
    Map<String, int> cutoffs,
    int issued,
    String by,
    List<String> keep,
  ) => <String, dynamic>{
    ..._payload(account, device, cutoffs, issued),
    't': 'dev_revoke_by',
    'by': by,
    'keep': keep,
  };

  /// A cut-off of [device] signed by [account]; with [by] (this device's
  /// key) and [byCertificate] (its certificate) also by this device, which
  /// keeps [keep].
  static Future<DeviceRevocation> issue({
    required LedgerKeyPair account,
    required String device,
    required Map<String, int> cutoffs,
    required int issued,
    LedgerKeyPair? by,
    DeviceCertificate? byCertificate,
    Iterable<String> keep = const <String>[],
  }) async {
    final Map<String, int> kept = cutoffs.length <= maxCutoffs
        ? cutoffs
        : Map<String, int>.fromEntries(cutoffs.entries.take(maxCutoffs));
    // Keyed: a revocation travels with the certificates it concerns, also
    // to phones that never met the account (a cut-off must reach them
    // before the device's entries do).
    final Uint8List sig = await account.signWithKey(
      canonicalJsonBytes(_payload(account.id, device, kept, issued)),
    );
    if (by == null || byCertificate == null) {
      return DeviceRevocation(
        account: account.id,
        device: device,
        cutoffs: Map<String, int>.unmodifiable(kept),
        issued: issued,
        signature: b64(sig),
      );
    }
    final List<String> keeps =
        (<String>{...keep}
              ..remove(by.id)
              ..remove(device))
            .take(maxKeep)
            .toList()
          ..sort();
    final Uint8List deviceSig = await by.sign(
      canonicalJsonBytes(
        _devicePayload(account.id, device, kept, issued, by.id, keeps),
      ),
    );
    return DeviceRevocation(
      account: account.id,
      device: device,
      cutoffs: Map<String, int>.unmodifiable(kept),
      issued: issued,
      signature: b64(sig),
      by: by.id,
      keep: List<String>.unmodifiable(keeps),
      deviceSignature: b64(deviceSig),
      byCertificate: byCertificate.withCo(null),
    );
  }

  Future<bool> verify() => verifyLedgerSignature(
    publicKey: account,
    message: canonicalJsonBytes(_payload(account, device, cutoffs, issued)),
    signature: signature,
  );

  /// Whether the device part holds: [byCertificate] is [by]'s, of this
  /// account, signed by the account key, and [by] signed this cut-off.
  Future<bool> verifyDevicePart() async {
    final String? b = by;
    final List<String>? k = keep;
    final String? s = deviceSignature;
    final DeviceCertificate? cert = byCertificate;
    if (b == null || k == null || s == null || cert == null) {
      return false;
    }
    if (cert.account != account || cert.device != b || b == device) {
      return false;
    }
    if (!await cert.verify()) {
      return false;
    }
    return cert.verifyByDevice(
      canonicalJsonBytes(
        _devicePayload(account, device, cutoffs, issued, b, k),
      ),
      s,
    );
  }

  /// This cut-off as the account key alone signed it.
  DeviceRevocation withoutDevicePart() => DeviceRevocation(
    account: account,
    device: device,
    cutoffs: cutoffs,
    issued: issued,
    signature: signature,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    ..._payload(account, device, cutoffs, issued),
    'sig': signature,
    if (by != null) ...<String, dynamic>{
      'by': by,
      'keep': keep,
      'dsig': deviceSignature,
      'bc': byCertificate!.toJson(),
    },
  };

  static DeviceRevocation? fromJson(Object? json) {
    if (json is! Map ||
        json['t'] != 'dev_revoke' ||
        !_isKey(json['account']) ||
        !_isKey(json['device']) ||
        json['cutoffs'] is! Map ||
        (json['cutoffs'] as Map).length > maxCutoffs ||
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
    // The device part comes whole or not at all: a damaged one leaves the
    // account's cut-off, which an account that co-signs refuses.
    final Object? by = json['by'];
    final Object? keep = json['keep'];
    final Object? dsig = json['dsig'];
    final DeviceCertificate? bc = DeviceCertificate.fromJson(json['bc']);
    final bool whole =
        _isKey(by) &&
        keep is List &&
        keep.length <= maxKeep &&
        keep.every(_isKey) &&
        isHybridSignatureText(dsig) &&
        bc != null;
    return DeviceRevocation(
      account: json['account'] as String,
      device: json['device'] as String,
      cutoffs: Map<String, int>.unmodifiable(cutoffs),
      issued: json['issued'] as int,
      signature: json['sig'] as String,
      by: whole ? by as String : null,
      keep: whole ? List<String>.unmodifiable(keep.cast<String>()) : null,
      deviceSignature: whole ? dsig as String : null,
      byCertificate: whole ? bc.withCo(null) : null,
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

/// When this phone first saw a device, and whether that was with the first
/// contact with its account ([kFirstContactWindow]).
@immutable
final class DeviceSeen {
  const DeviceSeen(this.at, {this.firstContact = false});

  /// When (ms).
  final int at;

  /// Seen with the first contact: it counted at once.
  final bool firstContact;
}

/// Which devices belong to which account, and which were cut off.
///
/// Which of them count is judged by [judgeDevices] from the certificates,
/// their co-signatures, the cut-offs and when this phone first saw each
/// device and got each cut-off (docs/SECURITY_MODEL.md, "Cutting a device
/// off"). An account none of whose certificates carries a co-signature
/// keeps the rule from before: what the account key cut off is out.
///
/// Revocations are bounded: anyone can make an account and sign
/// revocations with it, and each is about 8 KB (kept in the ledger, checked
/// at start, passed on). Per account at most one per device certified here
/// plus [spareRevocationsPerAccount] (never more than
/// [maxRevocationsPerAccount]), [maxRevocationsPerDevice] per device, and
/// [maxRevocations] in all. When everything is full, a revocation of an
/// account [isCoreAccount] names (this account, friends, followed ones)
/// makes room by dropping the oldest of another account; anything else is
/// refused. An account that co-signs takes only cut-offs its devices sign:
/// at most [maxRevocationsPerSigner] per signing device and
/// [maxSignedRevocationsPerAccount] in all, where one by a device closer to
/// the account's first devices (fewer co-signatures away) pushes out one by
/// a device further away, so devices a stolen one co-signed cannot crowd
/// out the owner's cut-off of it.
final class AccountDirectory {
  final Map<String, Map<String, DeviceCertificate>> _certs =
      <String, Map<String, DeviceCertificate>>{};
  final Map<String, List<DeviceRevocation>> _revocations =
      <String, List<DeviceRevocation>>{};

  /// Signatures of every revocation kept.
  final Set<String> _revocationSignatures = <String>{};

  /// Revocations kept per account.
  final Map<String, int> _revocationsPerAccount = <String, int>{};
  int _revocationCount = 0;

  static const int spareRevocationsPerAccount = 4;
  static const int maxRevocationsPerAccount = 32;
  static const int maxRevocationsPerDevice = 2;
  static const int maxRevocations = 512;
  static const int maxRevocationsPerSigner = 8;
  static const int maxSignedRevocationsPerAccount = 64;

  /// Certificates waiting for the certificate of the device that
  /// co-signed them (`account|co-signer` → certificates), at most
  /// [_maxWaitingCo] in all.
  final Map<String, List<DeviceCertificate>> _waitingCo =
      <String, List<DeviceCertificate>>{};
  int _waitingCoCount = 0;
  static const int _maxWaitingCo = 256;

  /// The time (ms) the judgements use; the store sets its clock.
  int Function() now = () => DateTime.now().millisecondsSinceEpoch;

  /// This device: it never waits for itself.
  String? get selfDevice => _selfDevice;
  String? _selfDevice;
  set selfDevice(String? device) {
    _selfDevice = device;
    _verdicts.clear();
  }

  /// account → device → when first seen here.
  final Map<String, Map<String, DeviceSeen>> _seen =
      <String, Map<String, DeviceSeen>>{};

  /// account → when its first device was seen here.
  final Map<String, int> _firstContact = <String, int>{};

  /// Revocation signature → when it was taken here (ms).
  final Map<String, int> _received = <String, int>{};

  /// The last judgement of each account, good until the next device
  /// stops waiting.
  final Map<String, ({TrustVerdict verdict, bool strict, int until})>
  _verdicts = <String, ({TrustVerdict verdict, bool strict, int until})>{};

  /// Accounts whose revocations are never dropped to make room (set by
  /// the app: this account, friends, followed accounts).
  bool Function(String account)? isCoreAccount;

  static String _key(String account, String device) => '$account|$device';

  /// Grows whenever a certificate is added (what the archive saves).
  int get revision => _revision;
  int _revision = 0;

  /// Grows whenever a revocation is added or dropped (what the archive
  /// saves).
  int get revocationRevision => _revocationRevision;
  int _revocationRevision = 0;

  /// Grows whenever a certificate of [account] is added (what the archive
  /// saves, one file per account).
  int revisionOf(String account) => _accountRevisions[account] ?? 0;
  final Map<String, int> _accountRevisions = <String, int>{};

  /// Every account with a certificate known.
  Iterable<String> get accounts => _certs.keys;

  bool knowsCertificate(DeviceCertificate cert) {
    final DeviceCertificate? held = _certs[cert.account]?[cert.device];
    return held != null &&
        held.signature == cert.signature &&
        held.co?.signature == cert.co?.signature;
  }

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
    _noteSeen(cert.account, cert.device);
    _changedAccount(cert.account);
  }

  void _changedAccount(String account) {
    _revision++;
    _accountRevisions[account] = revisionOf(account) + 1;
    _verdicts.remove(account);
  }

  void _noteSeen(String account, String device) {
    final Map<String, DeviceSeen> seen = _seen[account] ??=
        <String, DeviceSeen>{};
    if (seen.containsKey(device)) {
      return;
    }
    final int at = now();
    final int first = _firstContact.putIfAbsent(account, () => at);
    seen[device] = DeviceSeen(
      at,
      firstContact: at - first <= kFirstContactWindow.inMilliseconds,
    );
  }

  /// When this phone first saw each device of [account], and its first
  /// contact with it (what the archive saves).
  Map<String, DeviceSeen> seenOf(String account) =>
      _seen[account] ?? const <String, DeviceSeen>{};
  int? firstContactOf(String account) => _firstContact[account];

  /// Puts back what [seenOf] and [firstContactOf] said (read from our own
  /// storage, before the certificates).
  void restoreSeen(
    String account, {
    required int? firstContact,
    required Map<String, DeviceSeen> seen,
  }) {
    if (firstContact != null) {
      _firstContact[account] = firstContact;
    }
    (_seen[account] ??= <String, DeviceSeen>{}).addAll(seen);
    _verdicts.remove(account);
  }

  /// Records a certificate read back from our own storage (checked when it
  /// first arrived, its co-signature too); it pins the account's ML-DSA key
  /// again ([HybridKeyPins]). One seen before this phone kept when it saw
  /// devices counts as seen with the first contact.
  void trustCertificate(DeviceCertificate cert) {
    if (HybridKeyPins.pinnedFor(cert.account) == null) {
      HybridKeyPins.pinSignature(cert.account, cert.signature);
    }
    if (knowsCertificate(cert)) {
      return;
    }
    final Map<String, DeviceSeen> seen = _seen[cert.account] ??=
        <String, DeviceSeen>{};
    seen.putIfAbsent(
      cert.device,
      () => const DeviceSeen(0, firstContact: true),
    );
    _firstContact.putIfAbsent(cert.account, () => 0);
    _put(cert);
  }

  /// Records a certificate after checking its signature. Returns false for
  /// one that does not hold. A device keeps the first certificate known
  /// here: another one for it (the account key can sign any number) is
  /// not taken, only a co-signature on the same one ([_takesCo]).
  Future<bool> addCertificate(DeviceCertificate cert) async {
    final DeviceCertificate? held = _certs[cert.account]?[cert.device];
    if (held != null) {
      if (held.signature != cert.signature) {
        return true;
      }
      if (cert.co == null ||
          cert.co!.signature == held.co?.signature ||
          !_takesCo(held, cert)) {
        return true;
      }
      final DeviceCertificate checked = await _checkedCo(cert);
      if (checked.co != null && _takesCo(held, checked)) {
        _put(checked);
        await _retryWaitingCo(checked);
      }
      return true;
    }
    if (!await cert.verify()) {
      return false;
    }
    final DeviceCertificate checked = await _checkedCo(cert);
    if (_certs[cert.account]?[cert.device] == null) {
      _put(checked);
    }
    await _retryWaitingCo(checked);
    return true;
  }

  /// Takes this device's own certificate with a co-signature another
  /// device of the account gave it (checked), whatever the rule for
  /// others' ([_takesCo]). Returns whether it was taken.
  Future<bool> adoptOwnCertificate(DeviceCertificate cert) async {
    final DeviceCertificate? held = _certs[cert.account]?[cert.device];
    if (held == null ||
        held.signature != cert.signature ||
        cert.co == null ||
        cert.co!.signature == held.co?.signature) {
      return false;
    }
    final DeviceCertificate checked = await _checkedCo(cert);
    if (checked.co == null ||
        (held.coSignedByOther && !checked.coSignedByOther)) {
      return false;
    }
    _put(checked);
    return true;
  }

  /// Whether [incoming]'s co-signature replaces [held]'s: one that only
  /// marks the account as co-signing where there was none; another
  /// device's where there was none or only the mark — and only while the
  /// device does not count here on its own yet. A device that counts gains
  /// nothing from a co-signature, while a thief who co-signed the owner's
  /// devices with the stolen one would take them down with it.
  bool _takesCo(DeviceCertificate held, DeviceCertificate incoming) {
    if (held.coSignedByOther) {
      return false;
    }
    if (!incoming.coSignedByOther) {
      return held.co == null;
    }
    return now() < _readyAt(held.account, held.device);
  }

  /// [cert] with its co-signature when that holds, without it otherwise.
  /// One by a device whose certificate is not known yet waits for it
  /// ([_retryWaitingCo]).
  Future<DeviceCertificate> _checkedCo(DeviceCertificate cert) async {
    final CoSignature? co = cert.co;
    if (co == null) {
      return cert;
    }
    if (co.by == cert.device) {
      return await cert.verifyCo() ? cert : cert.withCo(null);
    }
    final DeviceCertificate? signer = _certs[cert.account]?[co.by];
    if (signer == null) {
      if (_waitingCoCount < _maxWaitingCo) {
        (_waitingCo[_key(cert.account, co.by)] ??= <DeviceCertificate>[]).add(
          cert,
        );
        _waitingCoCount++;
      }
      return cert.withCo(null);
    }
    return await cert.verifyCo(signer) ? cert : cert.withCo(null);
  }

  /// [signer] is known now: the co-signatures that waited for it are
  /// checked.
  Future<void> _retryWaitingCo(DeviceCertificate signer) async {
    final List<DeviceCertificate>? waiting = _waitingCo.remove(
      _key(signer.account, signer.device),
    );
    if (waiting == null) {
      return;
    }
    _waitingCoCount -= waiting.length;
    for (final DeviceCertificate cert in waiting) {
      await addCertificate(cert);
    }
  }

  /// Whether this very revocation is kept here.
  bool knowsRevocation(DeviceRevocation revocation) =>
      _revocationSignatures.contains(revocation.signature);

  /// Whether [revocation] would be kept (the limits above), not counting
  /// its signature.
  bool hasRoomFor(DeviceRevocation revocation) {
    final String account = revocation.account;
    if ((_revocations[_key(account, revocation.device)]?.length ?? 0) >=
        maxRevocationsPerDevice) {
      return false;
    }
    if (revocation.hasDevicePart) {
      if (_signedBy(account, revocation.by!) >= maxRevocationsPerSigner) {
        return false;
      }
      if ((_revocationsPerAccount[account] ?? 0) >=
              maxSignedRevocationsPerAccount &&
          _furthestSigned(account, revocation.by!) == null) {
        return false;
      }
    } else {
      final int perAccount = min(
        devicesOf(account).length + spareRevocationsPerAccount,
        maxRevocationsPerAccount,
      );
      if ((_revocationsPerAccount[account] ?? 0) >= perAccount) {
        return false;
      }
    }
    return _revocationCount < maxRevocations ||
        ((isCoreAccount?.call(account) ?? false) && _droppableKey() != null);
  }

  /// How many cut-offs [by] signed among those kept of [account].
  int _signedBy(String account, String by) => <DeviceRevocation>[
    for (final DeviceRevocation r in _revocationsOfAccount(account))
      if (r.by == by) r,
  ].length;

  /// How many co-signatures [device] is away from a device without one.
  int _depth(String account, String device) {
    final Set<String> seen = <String>{device};
    String? at = device;
    int depth = 0;
    while (true) {
      final DeviceCertificate? cert = at == null
          ? null
          : certificateOf(account, at);
      final String? next = cert != null && cert.coSignedByOther
          ? cert.co!.by
          : null;
      if (next == null || !seen.add(next) || depth >= 64) {
        return depth;
      }
      depth++;
      at = next;
    }
  }

  /// The signed cut-off of [account] to push out for one by [by]: one by
  /// the device furthest from the account's first devices, when that is
  /// further than [by] (the newest of them).
  DeviceRevocation? _furthestSigned(String account, String by) {
    final int mine = _depth(account, by);
    DeviceRevocation? out;
    int outDepth = mine;
    for (final DeviceRevocation r in _revocationsOfAccount(account)) {
      if (!r.hasDevicePart) {
        continue;
      }
      final int d = _depth(account, r.by!);
      if (d > outDepth ||
          (out != null &&
              d == outDepth &&
              (_received[r.signature] ?? 0) >
                  (_received[out.signature] ?? 0))) {
        out = r;
        outDepth = d;
      }
    }
    return out;
  }

  Iterable<DeviceRevocation> _revocationsOfAccount(String account) =>
      _revocations.values
          .where(
            (List<DeviceRevocation> l) =>
                l.isNotEmpty && l.first.account == account,
          )
          .expand((List<DeviceRevocation> l) => l);

  /// The oldest revocations of an account that is not core, if any.
  String? _droppableKey() {
    for (final MapEntry<String, List<DeviceRevocation>> e
        in _revocations.entries) {
      if (e.value.isNotEmpty &&
          !(isCoreAccount?.call(e.value.first.account) ?? false)) {
        return e.key;
      }
    }
    return null;
  }

  void _drop(String key) {
    final List<DeviceRevocation>? list = _revocations.remove(key);
    if (list == null || list.isEmpty) {
      return;
    }
    final String account = list.first.account;
    _revocationCount -= list.length;
    final int left = (_revocationsPerAccount[account] ?? 0) - list.length;
    if (left > 0) {
      _revocationsPerAccount[account] = left;
    } else {
      _revocationsPerAccount.remove(account);
    }
    for (final DeviceRevocation r in list) {
      _revocationSignatures.remove(r.signature);
      _received.remove(r.signature);
    }
    _revocationRevision++;
    _verdicts.remove(account);
  }

  /// Drops the one revocation [r].
  void _dropOne(DeviceRevocation r) {
    final String key = _key(r.account, r.device);
    final List<DeviceRevocation>? list = _revocations[key];
    if (list == null || !list.remove(r)) {
      return;
    }
    if (list.isEmpty) {
      _revocations.remove(key);
    }
    _revocationCount--;
    _revocationsPerAccount[r.account] =
        (_revocationsPerAccount[r.account] ?? 1) - 1;
    _revocationSignatures.remove(r.signature);
    _received.remove(r.signature);
    _revocationRevision++;
    _verdicts.remove(r.account);
  }

  bool _keep(DeviceRevocation revocation, {int? receivedAt}) {
    if (knowsRevocation(revocation)) {
      return true;
    }
    if (!hasRoomFor(revocation)) {
      return false;
    }
    if (revocation.hasDevicePart &&
        (_revocationsPerAccount[revocation.account] ?? 0) >=
            maxSignedRevocationsPerAccount) {
      final DeviceRevocation? out = _furthestSigned(
        revocation.account,
        revocation.by!,
      );
      if (out == null) {
        return false;
      }
      _dropOne(out);
    }
    if (_revocationCount >= maxRevocations) {
      final String? drop = _droppableKey();
      if (drop == null) {
        return false;
      }
      _drop(drop);
    }
    (_revocations[_key(revocation.account, revocation.device)] ??=
            <DeviceRevocation>[])
        .add(revocation);
    _revocationSignatures.add(revocation.signature);
    _received[revocation.signature] = receivedAt ?? now();
    _revocationsPerAccount[revocation.account] =
        (_revocationsPerAccount[revocation.account] ?? 0) + 1;
    _revocationCount++;
    _revocationRevision++;
    _verdicts.remove(revocation.account);
    return true;
  }

  /// Records a revocation after checking its signature. Returns false for
  /// a bad signature or one over the limits; true (and nothing changes)
  /// for one already known (the first version taken stays). One whose
  /// device part does not hold counts as the account's alone. An account
  /// that co-signs takes only one its device part names a signer that
  /// could count here; the signer's certificate it carries is taken too.
  Future<bool> addRevocation(DeviceRevocation revocation) async {
    if (knowsRevocation(revocation)) {
      return true;
    }
    DeviceRevocation r = revocation;
    // The limits first: a revocation that would not be kept costs no
    // signature check.
    if (!hasRoomFor(r) || !await r.verify()) {
      return false;
    }
    if (r.hasDevicePart && !await r.verifyDevicePart()) {
      r = r.withoutDevicePart();
      if (!hasRoomFor(r)) {
        return false;
      }
    }
    if (r.hasDevicePart) {
      if (!await addCertificate(r.byCertificate!) ||
          !_verdict(r.account).verdict.signers.contains(r.by)) {
        return false;
      }
    } else if (isStrict(r.account)) {
      return false;
    }
    return _keep(r);
  }

  /// Records a revocation read back from our own storage (checked when it
  /// first arrived), within the limits, taken here at [receivedAt].
  bool trustRevocation(DeviceRevocation revocation, {int receivedAt = 0}) =>
      _keep(revocation, receivedAt: receivedAt);

  /// When this phone took [revocation] (ms), if it keeps it.
  int? receivedAtOf(DeviceRevocation revocation) =>
      _received[revocation.signature];

  /// How many revocations are kept.
  int get revocationCount => _revocationCount;

  /// Whether [account] co-signs its devices: a certificate known here
  /// carries a checked co-signature (its own device's too), or a cut-off a
  /// device part. Then cut-offs by the account key alone are refused and
  /// devices without a co-signature wait ([judgeDevices]).
  bool isStrict(String account) => _verdict(account).strict;

  bool _computeStrict(String account) {
    for (final DeviceCertificate c
        in _certs[account]?.values ?? const <DeviceCertificate>[]) {
      if (c.co != null) {
        return true;
      }
    }
    return _revocationsOfAccount(
      account,
    ).any((DeviceRevocation r) => r.hasDevicePart);
  }

  int _readyAt(String account, String device) {
    if (device == _selfDevice) {
      return _always;
    }
    final DeviceSeen? seen = _seen[account]?[device];
    if (seen == null) {
      return _always;
    }
    return seen.firstContact
        ? seen.at
        : seen.at + kNewDeviceWait.inMilliseconds;
  }

  static const int _always = -(1 << 52);

  ({TrustVerdict verdict, bool strict, int until}) _verdict(String account) {
    final int t = now();
    final ({TrustVerdict verdict, bool strict, int until})? had =
        _verdicts[account];
    if (had != null && t < had.until) {
      return had;
    }
    final Map<String, TrustDevice> devices = <String, TrustDevice>{};
    int until = 1 << 52;
    for (final DeviceCertificate c
        in _certs[account]?.values ?? const <DeviceCertificate>[]) {
      final int ready = _readyAt(account, c.device);
      if (ready > t && ready < until) {
        until = ready;
      }
      devices[c.device] = TrustDevice(
        id: c.device,
        issued: c.issued,
        readyAt: ready,
        coBy: c.coSignedByOther ? c.co!.by : null,
      );
    }
    final bool strict = _computeStrict(account);
    final TrustVerdict verdict = judgeDevices(
      strict: strict,
      devices: devices,
      cuts: <TrustCut>[
        for (final DeviceRevocation r in _revocationsOfAccount(account))
          TrustCut(
            id: r.signature,
            target: r.device,
            by: r.by,
            keep: r.keep?.toSet(),
            issued: r.issued,
            receivedAt: _received[r.signature] ?? 0,
          ),
      ],
      now: t,
    );
    final ({TrustVerdict verdict, bool strict, int until}) out = (
      verdict: verdict,
      strict: strict,
      until: until,
    );
    _verdicts[account] = out;
    return out;
  }

  /// Whether [device] of [account] does not count: cut off, left out by a
  /// cut-off, or (in an account that co-signs) still waiting. A device
  /// whose certificate is not known here counts as long as no cut-off
  /// that counts names it (its entries wait for the certificate).
  bool isRevoked(String account, String device) {
    final List<DeviceRevocation>? own = _revocations[_key(account, device)];
    if (_certs[account] == null) {
      return own?.isNotEmpty ?? false;
    }
    final TrustVerdict v = _verdict(account).verdict;
    if (certificateOf(account, device) == null) {
      return v.cuts.containsKey(device);
    }
    return !v.counting.contains(device);
  }

  /// Whether [device] of [account] waits to count (no co-signature, not
  /// seen long enough here): until when (ms), or null.
  int? pendingUntil(String account, String device) => _certs[account] == null
      ? null
      : _verdict(account).verdict.pendingUntil[device];

  /// Whether [device] of [account] is out for good: cut off or left out
  /// by a cut-off that counts (not merely waiting).
  bool isCutOff(String account, String device) =>
      isRevoked(account, device) && pendingUntil(account, device) == null;

  /// The devices of [account] waiting to count, with until when (ms).
  Map<String, int> pendingDevicesOf(String account) => _certs[account] == null
      ? const <String, int>{}
      : _verdict(account).verdict.pendingUntil;

  /// The cut-offs of [account] that count.
  List<DeviceRevocation> countingRevocationsOf(String account) {
    final Map<String, List<TrustCut>> cuts = _verdict(account).verdict.cuts;
    return <DeviceRevocation>[
      for (final DeviceRevocation r in _revocationsOfAccount(account))
        if (cuts[r.device]?.any((TrustCut c) => c.id == r.signature) ?? false)
          r,
    ];
  }

  /// Every signed revocation known, as issued (for passing on).
  Iterable<DeviceRevocation> get revocations =>
      _revocations.values.expand((List<DeviceRevocation> l) => l);

  /// The revocations of [device] of [account] kept here.
  List<DeviceRevocation> revocationsOf(String account, String device) =>
      _revocations[_key(account, device)] ?? const <DeviceRevocation>[];

  Iterable<DeviceCertificate> devicesOf(String account) =>
      _certs[account]?.values ?? const <DeviceCertificate>[];

  /// Whether entry [seq] of log [writer], written by [device] of [account],
  /// is still trusted. Several revocations combine to the strictest one.
  /// In an account that co-signs, a device that waits or was left out
  /// writes nothing that is taken; one cut off keeps what its cut-offs
  /// that count keep.
  bool allowsEntry({
    required String account,
    required String device,
    required String writer,
    required int seq,
    String? space,
  }) {
    final List<DeviceRevocation>? list;
    if (_certs[account] != null && isStrict(account)) {
      final TrustVerdict v = _verdict(account).verdict;
      if (v.counting.contains(device)) {
        return true;
      }
      final Set<String> counting = <String>{
        for (final TrustCut c in v.cuts[device] ?? const <TrustCut>[]) c.id,
      };
      if (counting.isEmpty) {
        // Waiting, left out, or (certificate unknown) not cut off.
        return certificateOf(account, device) == null;
      }
      list = <DeviceRevocation>[
        for (final DeviceRevocation r in revocationsOf(account, device))
          if (counting.contains(r.signature)) r,
      ];
    } else {
      list = _revocations[_key(account, device)];
    }
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
