import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';

/// Zen's signature: **Ed25519 and ML-DSA-65 (FIPS 204) together**, valid
/// only when both halves are, so a signature holds while either scheme
/// does — also against a quantum computer, which breaks Ed25519
/// (docs/PROTOCOL.md §4.1). From Go's ML-DSA in the bridge
/// (`native/yggdrasil_bridge/internal/zensig`), on every platform; there is
/// no Dart ML-DSA.
///
/// A key is the 32-byte seed the app keeps anyway: the Ed25519 key is that
/// seed (its public key stays the key's id everywhere) and the ML-DSA-65
/// key is expanded from `HKDF-SHA256(seed, info "zen.sig.mldsa65.v1")`, so
/// a backup or a recovery of the seed restores both.
///
/// Both halves sign
/// `"zen.sig.v1" 0x00 | Ed25519 key | SHA-256(ML-DSA key) | SHA-512(message)`:
/// each half certifies the other key, so neither half can be stripped or
/// moved to another key. The SHA-256 of the ML-DSA key is the key's
/// **fingerprint** (`pq` id). A signature (3405 bytes) is the Ed25519
/// signature, the fingerprint and the ML-DSA signature: the ML-DSA key
/// itself (1952 bytes) is published once, in the record that introduces
/// it (a device certificate, a pyramid admission), and the verifier looks
/// it up ([HybridKeyBook]) or is handed it. Where no such record can exist
/// yet (that very record, a release, whatever strangers check) the
/// **keyed** form (5325 bytes) carries the key instead of the fingerprint;
/// both forms have the same two halves.
const int kSigSeedBytes = 32;
const int kEd25519PublicKeyBytes = 32;
const int kEd25519SignatureBytes = 64;
const int kMlDsaPublicKeyBytes = 1952;
const int kMlDsaSignatureBytes = 3309;
const int kSigFingerprintBytes = 32;
const int kSigDigestBytes = 64;

/// A signature that names its ML-DSA key by fingerprint.
const int kHybridSignatureBytes =
    kEd25519SignatureBytes + kSigFingerprintBytes + kMlDsaSignatureBytes;

/// A signature that carries its ML-DSA key (the keyed form).
const int kKeyedHybridSignatureBytes =
    kEd25519SignatureBytes + kMlDsaPublicKeyBytes + kMlDsaSignatureBytes;

/// The length of a signature as the app writes it (base64url, padded).
const int kHybridSignatureChars = (kHybridSignatureBytes + 2) ~/ 3 * 4;

/// The length of a keyed signature as the app writes it.
const int kKeyedHybridSignatureChars =
    (kKeyedHybridSignatureBytes + 2) ~/ 3 * 4;

/// The length of an ML-DSA public key as the app writes it (base64url).
const int kMlDsaPublicKeyChars = (kMlDsaPublicKeyBytes + 2) ~/ 3 * 4;

/// Domain of every hybrid signature (also ML-DSA's context string).
const String kHybridSignatureContext = 'zen.sig.v1';

/// Both public halves of a key.
final class HybridPublicKey {
  const HybridPublicKey({
    required this.ed,
    required this.pq,
    required this.fingerprint,
  });

  /// The Ed25519 public key (32 bytes): the key's id.
  final Uint8List ed;

  /// The ML-DSA-65 public key (1952 bytes).
  final Uint8List pq;

  /// SHA-256 of [pq].
  final Uint8List fingerprint;
}

/// The signing backend: the bridge, or the stand-in in tests.
abstract interface class HybridSigner {
  /// Both public halves of [seed].
  Future<HybridPublicKey> publicKeyOf(Uint8List seed);

  /// The hybrid signature of the message whose [hybridDigest] is [digest]:
  /// naming the ML-DSA key by fingerprint, or carrying it [withKey].
  Future<Uint8List> signDigest(
    Uint8List seed,
    Uint8List digest, {
    bool withKey = false,
  });

  /// Whether [signature] by the Ed25519 key [ed] holds over the message
  /// whose [hybridDigest] is [digest] — both halves. [pqKey] is the
  /// signer's ML-DSA key: needed when the signature names it by
  /// fingerprint (and it must be that key), optional for a keyed
  /// signature (then it must be the key carried).
  Future<bool> verifyDigest(
    Uint8List ed,
    Uint8List digest,
    Uint8List signature, {
    Uint8List? pqKey,
  });
}

/// What is signed of a message: its SHA-512 (the bridge never needs the
/// message itself, so a two-megabyte record costs as much as a short one).
Uint8List hybridDigest(List<int> message) =>
    Uint8List.fromList(crypto.sha512.convert(message).bytes);

/// A signature as the app writes it (base64url), in either form, or
/// `null` for anything that is not one — an Ed25519-only signature
/// included.
Uint8List? decodeHybridSignature(Object? value) {
  if (value is! String) {
    return null;
  }
  return switch (value.length) {
    kHybridSignatureChars => unb64(value, length: kHybridSignatureBytes),
    kKeyedHybridSignatureChars => unb64(
      value,
      length: kKeyedHybridSignatureBytes,
    ),
    _ => null,
  };
}

/// Whether [value] has the length of a hybrid signature (either form) as
/// the app writes it — a cheap check for parsers (an Ed25519-only
/// signature is far shorter); the signature itself is decoded and checked
/// when verified.
bool isHybridSignatureText(Object? value) =>
    value is String &&
    (value.length == kHybridSignatureChars ||
        value.length == kKeyedHybridSignatureChars);

/// Whether [value] has the length of a keyed signature (one that carries
/// its ML-DSA key): what a record checked by anyone, with no earlier
/// record of the key at hand, must carry.
bool isKeyedHybridSignatureText(Object? value) =>
    value is String && value.length == kKeyedHybridSignatureChars;

/// The ML-DSA public key a keyed signature carries; `null` for one that
/// names its key by fingerprint.
Uint8List? hybridSignaturePqKey(Uint8List signature) =>
    signature.length == kKeyedHybridSignatureBytes
    ? Uint8List.sublistView(
        signature,
        kEd25519SignatureBytes,
        kEd25519SignatureBytes + kMlDsaPublicKeyBytes,
      )
    : null;

/// The fingerprint of the ML-DSA key [signature] names or carries
/// (unchecked), or `null` when it is not a hybrid signature.
Uint8List? hybridSignatureFingerprint(Uint8List signature) {
  if (signature.length == kHybridSignatureBytes) {
    return Uint8List.sublistView(
      signature,
      kEd25519SignatureBytes,
      kEd25519SignatureBytes + kSigFingerprintBytes,
    );
  }
  final Uint8List? key = hybridSignaturePqKey(signature);
  return key == null
      ? null
      : Uint8List.fromList(crypto.sha256.convert(key).bytes);
}

/// The ML-DSA half of [signature] (its last bytes, in both forms).
Uint8List hybridSignatureMlDsaHalf(Uint8List signature) =>
    Uint8List.sublistView(signature, signature.length - kMlDsaSignatureBytes);

/// The fingerprint (base64url) of an ML-DSA public key.
String pqFingerprintOf(List<int> pqPublicKey) =>
    b64(crypto.sha256.convert(pqPublicKey).bytes);

/// The fingerprint of the ML-DSA key [signature] names or carries
/// (unchecked), or `null` when it is not a hybrid signature. Decodes only
/// the part that holds it (the pyramid's fold asks once per signature).
String? hybridSignaturePqId(Object? signature) {
  if (signature is! String) {
    return null;
  }
  // The key's part starts at byte 64, in the base64 group of bytes
  // [63, 66): characters from 84 on.
  const int firstByte = kEd25519SignatureBytes ~/ 3 * 3;
  const int skip = kEd25519SignatureBytes - firstByte;
  const int fingerprintEnd = kEd25519SignatureBytes + kSigFingerprintBytes;
  const int keyEnd = kEd25519SignatureBytes + kMlDsaPublicKeyBytes;
  try {
    if (signature.length == kHybridSignatureChars) {
      final Uint8List part = base64Url.decode(
        signature.substring(firstByte ~/ 3 * 4, (fingerprintEnd + 2) ~/ 3 * 4),
      );
      return b64(
        Uint8List.sublistView(part, skip, skip + kSigFingerprintBytes),
      );
    }
    if (signature.length == kKeyedHybridSignatureChars) {
      final Uint8List part = base64Url.decode(
        signature.substring(firstByte ~/ 3 * 4, (keyEnd + 2) ~/ 3 * 4),
      );
      return pqFingerprintOf(
        Uint8List.sublistView(part, skip, skip + kMlDsaPublicKeyBytes),
      );
    }
  } on FormatException {
    return null;
  }
  return null;
}

/// The ML-DSA key to check [signature] with: the one a keyed signature
/// carries (which [pqKey], when given, must be), or [pqKey] when it is the
/// key the signature names by fingerprint; `null` otherwise.
Uint8List? hybridVerificationKey(Uint8List signature, Uint8List? pqKey) {
  final Uint8List? carried = hybridSignaturePqKey(signature);
  if (carried != null) {
    return pqKey == null || _sameBytes(pqKey, carried) ? carried : null;
  }
  final Uint8List? named = hybridSignatureFingerprint(signature);
  if (named == null ||
      pqKey == null ||
      pqKey.length != kMlDsaPublicKeyBytes ||
      !_sameBytes(crypto.sha256.convert(pqKey).bytes, named)) {
    return null;
  }
  return pqKey;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

/// Whether [signature] (base64url) names its ML-DSA key by a fingerprint
/// [HybridKeyBook] does not hold: it cannot be checked — and so is never
/// taken — until the record that publishes the key has come.
bool hybridSignatureLacksKey(Object? signature) =>
    signature is String &&
    signature.length == kHybridSignatureChars &&
    !HybridKeyBook.holds(hybridSignaturePqId(signature) ?? '');

/// A key's **hybrid id**: its Ed25519 id and its fingerprint, joined by a
/// dot (`<44 chars>.<44 chars>`). Pinned lists (release maintainers) and
/// records that name a key for good use it, so the ML-DSA half is fixed
/// together with the Ed25519 half.
String hybridKeyId(String ed, String pqId) => '$ed.$pqId';

/// The two halves of a hybrid id, or `null` for anything else.
({String ed, String pq})? parseHybridKeyId(Object? value) {
  if (value is! String || value.length != 89 || value[44] != '.') {
    return null;
  }
  final String ed = value.substring(0, 44);
  final String pq = value.substring(45);
  final Uint8List? edBytes = unb64(ed, length: kEd25519PublicKeyBytes);
  final Uint8List? pqBytes = unb64(pq, length: kSigFingerprintBytes);
  if (edBytes == null ||
      pqBytes == null ||
      b64(edBytes) != ed ||
      b64(pqBytes) != pq) {
    return null;
  }
  return (ed: ed, pq: pq);
}

/// Which ML-DSA key belongs to which Ed25519 key, as this process first
/// saw it.
///
/// A future quantum computer could forge the Ed25519 half of any key and
/// pair it with an ML-DSA key of its own; only the first ML-DSA key seen
/// for an Ed25519 key is therefore taken (the genuine key is derived from
/// the seed and never changes). The pins come from every signature that
/// checked out and from what is read back from the app's own storage
/// ([pinSignature]), so data kept before such a computer exists keeps
/// anchoring the keys. Records that name a key for good (device
/// certificates, release maintainers, the pyramid's power key) carry the
/// fingerprint itself.
abstract final class HybridKeyPins {
  static final Map<String, String> _pins = <String, String>{};

  /// Whether [pqId] may be the ML-DSA key of [ed] (no other is pinned).
  static bool admits(String ed, String pqId) {
    final String? pinned = _pins[ed];
    return pinned == null || pinned == pqId;
  }

  /// The fingerprint pinned for [ed], if any.
  static String? pinnedFor(String ed) => _pins[ed];

  /// Pins [pqId] for [ed] (the first pin stays).
  static void pin(String ed, String pqId) {
    _pins.putIfAbsent(ed, () => pqId);
  }

  /// Pins the key a stored, already checked [signature] of [ed] names or
  /// carries.
  static void pinSignature(String ed, String signature) {
    final Uint8List? key = unb64(ed, length: kEd25519PublicKeyBytes);
    final String? pq = hybridSignaturePqId(signature);
    if (key != null && pq != null) {
      pin(b64(key), pq);
    }
  }

  /// Forgets every pin (tests only).
  static void clear() => _pins.clear();
}

/// ML-DSA public keys this process knows, by fingerprint: published once,
/// in the records that introduce them (device certificates, pyramid
/// admissions, keyed signatures), and looked up for the signatures that
/// name a key by fingerprint.
///
/// Content-addressed: a key is filed only under its own SHA-256, so
/// whoever hands one over can add a key but never replace one, and a key
/// found here is exactly the one a signature names. Which ML-DSA key
/// belongs to which Ed25519 key is not decided here ([HybridKeyPins] and
/// the records do that). The app files its own keys and those of the
/// records it keeps, so the book grows with what is kept, not with what
/// strangers send.
abstract final class HybridKeyBook {
  static final Map<String, Uint8List> _keys = <String, Uint8List>{};

  /// Files [pqKey]; its fingerprint, or `null` for anything that is not an
  /// ML-DSA-65 public key.
  static String? add(List<int> pqKey) {
    if (pqKey.length != kMlDsaPublicKeyBytes) {
      return null;
    }
    final String id = pqFingerprintOf(pqKey);
    _keys.putIfAbsent(id, () => Uint8List.fromList(pqKey));
    return id;
  }

  /// Files a key written as the app writes keys (base64url).
  static String? addText(Object? pqKey) {
    final Uint8List? bytes = unb64(pqKey, length: kMlDsaPublicKeyBytes);
    return bytes == null ? null : add(bytes);
  }

  /// Files the key a keyed signature (base64url) carries; nothing for a
  /// signature that names its key.
  static void addFromSignature(Object? signature) {
    if (!isKeyedHybridSignatureText(signature)) {
      return;
    }
    final Uint8List? sig = decodeHybridSignature(signature);
    final Uint8List? key = sig == null ? null : hybridSignaturePqKey(sig);
    if (key != null) {
      add(key);
    }
  }

  /// The key with fingerprint [pqId] (base64url), if known.
  static Uint8List? lookup(String pqId) => _keys[pqId];

  static bool holds(String pqId) => _keys.containsKey(pqId);

  /// Forgets every key (tests only).
  static void clear() => _keys.clear();
}

/// A signer with the sizes and layout of the hybrid one, whose "ML-DSA"
/// half is a hash anyone can compute: for tests without the bridge. The
/// Ed25519 half is real (and composed as the bridge composes it, see
/// [hybridToBeSigned]), so a signature still belongs to its key; it is
/// **not** post-quantum and never used outside tests.
const HybridSigner kStandInHybridSigner = _StandInSigner();

/// What both halves of a hybrid signature sign:
/// `"zen.sig.v1" 0x00 | Ed25519 key | fingerprint | digest`.
Uint8List hybridToBeSigned(
  List<int> ed,
  List<int> fingerprint,
  List<int> digest,
) => Uint8List.fromList(<int>[
  ...utf8.encode(kHybridSignatureContext),
  0,
  ...ed,
  ...fingerprint,
  ...digest,
]);

/// Whether the Ed25519 half of [signature] (either form) by [ed] holds
/// over the message whose [hybridDigest] is [digest] (the ML-DSA half is
/// not checked: only the bridge can). For tests that compare this
/// composition with the bridge's.
Future<bool> verifyHybridEd25519Half(
  Uint8List ed,
  Uint8List digest,
  Uint8List signature,
) async {
  final Uint8List? fingerprint = hybridSignatureFingerprint(signature);
  if (ed.length != kEd25519PublicKeyBytes ||
      digest.length != kSigDigestBytes ||
      fingerprint == null) {
    return false;
  }
  try {
    return await Ed25519().verify(
      hybridToBeSigned(ed, fingerprint, digest),
      signature: Signature(
        signature.sublist(0, kEd25519SignatureBytes),
        publicKey: SimplePublicKey(ed, type: KeyPairType.ed25519),
      ),
    );
  } on Object {
    return false;
  }
}

/// The "ML-DSA" half [kStandInHybridSigner] makes for [pqKey] over
/// [toBeSigned] — public so tests can play a forger who pairs a valid
/// Ed25519 half with an ML-DSA key of its own.
Uint8List standInMlDsaSignature(List<int> pqKey, List<int> toBeSigned) =>
    _StandInSigner._expand('zen.standin.mldsa.sig', <int>[
      ...crypto.sha256.convert(pqKey).bytes,
      ...toBeSigned,
    ], kMlDsaSignatureBytes);

final class _StandInSigner implements HybridSigner {
  const _StandInSigner();

  static Uint8List _expand(String label, List<int> input, int length) {
    final List<int> block = crypto.sha256.convert(<int>[
      ...utf8.encode(label),
      ...input,
    ]).bytes;
    final Uint8List out = Uint8List(length);
    for (int i = 0; i < length; i++) {
      out[i] = block[i % block.length] ^ (i ~/ block.length & 0xff);
    }
    return out;
  }

  static Uint8List _pqSignature(List<int> pqKey, List<int> toBeSigned) =>
      standInMlDsaSignature(pqKey, toBeSigned);

  /// Key pairs already expanded (tests sign with a few keys many times;
  /// pure-Dart Ed25519 is slow).
  static final Map<String, (SimpleKeyPair, HybridPublicKey)> _keys =
      <String, (SimpleKeyPair, HybridPublicKey)>{};

  static Future<(SimpleKeyPair, HybridPublicKey)> _key(Uint8List seed) async {
    if (seed.length != kSigSeedBytes) {
      throw FormatException('seed of ${seed.length} bytes');
    }
    final String id = b64(seed);
    final (SimpleKeyPair, HybridPublicKey)? had = _keys[id];
    if (had != null) {
      return had;
    }
    final SimpleKeyPair pair = await Ed25519().newKeyPairFromSeed(seed);
    final Uint8List ed = Uint8List.fromList(
      (await pair.extractPublicKey()).bytes,
    );
    final Uint8List pq = _expand(
      'zen.standin.mldsa.key',
      seed,
      kMlDsaPublicKeyBytes,
    );
    final (SimpleKeyPair, HybridPublicKey) key = (
      pair,
      HybridPublicKey(
        ed: ed,
        pq: pq,
        fingerprint: Uint8List.fromList(crypto.sha256.convert(pq).bytes),
      ),
    );
    if (_keys.length >= 512) {
      _keys.clear();
    }
    return _keys[id] = key;
  }

  @override
  Future<HybridPublicKey> publicKeyOf(Uint8List seed) async =>
      (await _key(seed)).$2;

  @override
  Future<Uint8List> signDigest(
    Uint8List seed,
    Uint8List digest, {
    bool withKey = false,
  }) async {
    if (digest.length != kSigDigestBytes) {
      throw FormatException('digest of ${digest.length} bytes');
    }
    final (SimpleKeyPair pair, HybridPublicKey key) = await _key(seed);
    final Uint8List t = hybridToBeSigned(key.ed, key.fingerprint, digest);
    final Signature ed = await Ed25519().sign(t, keyPair: pair);
    return Uint8List.fromList(<int>[
      ...ed.bytes,
      ...(withKey ? key.pq : key.fingerprint),
      ..._pqSignature(key.pq, t),
    ]);
  }

  @override
  Future<bool> verifyDigest(
    Uint8List ed,
    Uint8List digest,
    Uint8List signature, {
    Uint8List? pqKey,
  }) async {
    final Uint8List? pq = hybridVerificationKey(signature, pqKey);
    if (pq == null || !await verifyHybridEd25519Half(ed, digest, signature)) {
      return false;
    }
    final Uint8List expected = _pqSignature(
      pq,
      hybridToBeSigned(ed, crypto.sha256.convert(pq).bytes, digest),
    );
    return _sameBytes(hybridSignatureMlDsaHalf(signature), expected);
  }
}
