import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

/// Long-lived X25519 identity of this device for relayed (store-and-forward)
/// traffic.
///
/// Mesh addresses authenticate *who sent a datagram*, but a relayed message
/// passes through friends' devices on the way, so its content needs its own
/// end-to-end protection bound to the original sender and recipient.
///
/// The mailbox identity ([generateHybrid]) also holds a hybrid
/// post-quantum key pair ([pqSeed], [pqPublicKey]; hybrid_kem.dart), so mail
/// recorded on its way can not be opened later with a quantum computer.
/// Other users of this class (dating keys, one-off keys) are X25519 only.
@immutable
final class RelayIdentity {
  const RelayIdentity({
    required this.privateKey,
    required this.publicKey,
    this.pqSeed,
    this.pqPublicKey,
  });

  final Uint8List privateKey;
  final Uint8List publicKey;

  /// The hybrid key pair's seed and public key (mailbox identities only).
  final Uint8List? pqSeed;
  final Uint8List? pqPublicKey;

  String get publicKeyBase64 => base64Url.encode(publicKey);

  bool get isHybrid => pqSeed != null && pqPublicKey != null;

  /// What a sender needs to seal mail for this identity ([isHybrid] only).
  RelayPublicKeys? get publicKeys {
    final Uint8List? pq = pqPublicKey;
    return pq == null ? null : RelayPublicKeys(x25519: publicKey, pq: pq);
  }

  static Future<RelayIdentity> generate() async {
    final SimpleKeyPair pair = await X25519().newKeyPair();
    final SimpleKeyPairData data = await pair.extract();
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    return RelayIdentity(
      privateKey: Uint8List.fromList(data.bytes),
      publicKey: Uint8List.fromList(publicKey.bytes),
    );
  }

  /// An X25519 identity with a hybrid key pair (the mailbox identity).
  static Future<RelayIdentity> generateHybrid() async {
    final RelayIdentity classical = await generate();
    final HybridKeyPair pq = await HybridKeyPair.generate();
    return RelayIdentity(
      privateKey: classical.privateKey,
      publicKey: classical.publicKey,
      pqSeed: pq.seed,
      pqPublicKey: pq.publicKey,
    );
  }

  SimpleKeyPairData get _keyPair => SimpleKeyPairData(
    privateKey,
    publicKey: SimplePublicKey(publicKey, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'sk': base64Url.encode(privateKey),
    'pk': base64Url.encode(publicKey),
    if (pqSeed != null && pqPublicKey != null) ...<String, dynamic>{
      'qs': base64Url.encode(pqSeed!),
      'qp': base64Url.encode(pqPublicKey!),
    },
  };

  static RelayIdentity? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Uint8List? sk = decodeRelayKey(json['sk']);
    final Uint8List? pk = decodeRelayKey(json['pk']);
    if (sk == null || pk == null) {
      return null;
    }
    if (json['qs'] == null && json['qp'] == null) {
      return RelayIdentity(privateKey: sk, publicKey: pk);
    }
    final Uint8List? qs = decodeRelayKey(json['qs']);
    final Uint8List? qp = decodeHybridPublicKey(json['qp']);
    if (qs == null || qp == null) {
      return null;
    }
    return RelayIdentity(
      privateKey: sk,
      publicKey: pk,
      pqSeed: qs,
      pqPublicKey: qp,
    );
  }
}

/// The keys a mailbox recipient announces (`rly_announce` `pk` and `pq`).
@immutable
final class RelayPublicKeys {
  const RelayPublicKeys({required this.x25519, required this.pq});

  final Uint8List x25519;

  /// The hybrid (ML-KEM-768 + X25519) public key.
  final Uint8List pq;
}

/// Decodes a base64url X25519 key, or `null` for anything that is not one.
Uint8List? decodeRelayKey(Object? value) {
  if (value is! String || value.isEmpty) {
    return null;
  }
  try {
    final Uint8List bytes = base64Url.decode(base64Url.normalize(value));
    return bytes.length == 32 ? bytes : null;
  } on FormatException {
    return null;
  }
}

/// Ciphertext of one relayed payload.
@immutable
final class RelaySealedBox {
  const RelaySealedBox({
    required this.ephemeralPublicKey,
    required this.nonce,
    required this.cipherText,
  });

  final Uint8List ephemeralPublicKey;
  final Uint8List nonce;

  /// Ciphertext followed by the 16-byte Poly1305 tag.
  final Uint8List cipherText;
}

/// Ciphertext of one mailbox envelope ([RelayCipher.sealHybrid]).
@immutable
final class RelayHybridBox {
  const RelayHybridBox({
    required this.pqCiphertext,
    required this.nonce,
    required this.cipherText,
  });

  /// The hybrid KEM ciphertext ([kHybridCiphertextBytes]).
  final Uint8List pqCiphertext;
  final Uint8List nonce;

  /// Ciphertext followed by the 16-byte Poly1305 tag.
  final Uint8List cipherText;
}

/// One hybrid secret a sender uses for a recipient's key a while.
final class _KemUse {
  _KemUse(this.ciphertext, this.secret, this.createdAt);

  final Uint8List ciphertext;
  final Uint8List secret;
  final DateTime createdAt;
  int uses = 0;
}

/// Sealing scheme for relayed payloads.
///
/// `key = HKDF-SHA256(DH(e, R) || DH(S, R), info = context)`, then
/// ChaCha20-Poly1305 with the envelope header as associated data, where `e` is
/// a fresh ephemeral key, `S` the sender's static key and `R` the recipient's.
///
/// * Relays only ever see ciphertext.
/// * The static-static term authenticates the sender: nobody without `S` (or
///   `R`) can produce a box that opens with the sender's known public key, so
///   a relay cannot forge or re-attribute a message.
/// * The ephemeral term keeps every box's key unique even for identical
///   plaintexts.
/// * The header (ids, addresses, timestamps) is bound as associated data, so a
///   relay cannot move a box to another sender, recipient or id.
///
/// [seal]/[open] are this X25519-only construction (dating boxes, door
/// knocks). Mailbox mail uses [sealHybrid]/[openHybrid], which add the
/// hybrid post-quantum KEM (hybrid_kem.dart):
///
/// `key = HKDF-SHA256(K || DH(S, R), salt = c || nonce, info = "zen.relay.v2")`,
/// then ChaCha20-Poly1305 with the envelope header as associated data, where
/// `(c, K)` is an encapsulation to the recipient's hybrid key (`info =
/// "zen.relay.kem.v2"`). The static term still authenticates the sender;
/// `K` keeps the mail secret even from someone who breaks X25519 later. A
/// sender encapsulates once per recipient key and reuses `(c, K)` for
/// [kemReuse] or [kemLifetime] (every envelope carries `c` and gets its own
/// key from its random nonce); a recipient decapsulates each `c` once. So the
/// KEM runs per key and day, not per message.
final class RelayCipher {
  RelayCipher._();

  static const String _context = 'zen.relay.v1';
  static const String _hybridContext = 'zen.relay.v2';
  static const String _kemContext = 'zen.relay.kem.v2';

  /// How long and for how many envelopes a sender reuses one encapsulation.
  static const Duration kemLifetime = Duration(hours: 24);
  static const int kemReuse = 1000;
  static const int _sendKemsKept = 256;
  static const int _openedKemsKept = 64;
  static final Map<String, _KemUse> _sendKems = <String, _KemUse>{};
  // Oldest first (map literals keep insertion order).
  static final Map<String, Uint8List> _openedKems = <String, Uint8List>{};
  static final X25519 _x25519 = X25519();
  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  static const int _macLength = 16;

  static Future<RelaySealedBox> seal({
    required RelayIdentity sender,
    required Uint8List recipientPublicKey,
    required Uint8List plaintext,
    required Uint8List associatedData,
  }) async {
    final SimpleKeyPair ephemeral = await _x25519.newKeyPair();
    final SimplePublicKey ephemeralPublic = await ephemeral.extractPublicKey();
    final SimplePublicKey recipient = SimplePublicKey(
      recipientPublicKey,
      type: KeyPairType.x25519,
    );
    final SecretKey key = await _deriveKey(
      ephemeralShared: await _x25519.sharedSecretKey(
        keyPair: ephemeral,
        remotePublicKey: recipient,
      ),
      staticShared: await _x25519.sharedSecretKey(
        keyPair: sender._keyPair,
        remotePublicKey: recipient,
      ),
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublic.bytes),
    );
    final Uint8List nonce = _randomBytes(12);
    final SecretBox box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: associatedData,
    );
    return RelaySealedBox(
      ephemeralPublicKey: Uint8List.fromList(ephemeralPublic.bytes),
      nonce: nonce,
      cipherText: Uint8List.fromList(<int>[
        ...box.cipherText,
        ...box.mac.bytes,
      ]),
    );
  }

  /// Opens [box]; throws [SecretBoxAuthenticationError] when the box was not
  /// made by [senderPublicKey] for [recipient], or was tampered with.
  static Future<Uint8List> open({
    required RelayIdentity recipient,
    required Uint8List senderPublicKey,
    required RelaySealedBox box,
    required Uint8List associatedData,
  }) async {
    if (box.cipherText.length < _macLength || box.nonce.length != 12) {
      throw const FormatException('Relay box is malformed.');
    }
    final SimpleKeyPairData own = recipient._keyPair;
    final SecretKey key = await _deriveKey(
      ephemeralShared: await _x25519.sharedSecretKey(
        keyPair: own,
        remotePublicKey: SimplePublicKey(
          box.ephemeralPublicKey,
          type: KeyPairType.x25519,
        ),
      ),
      staticShared: await _x25519.sharedSecretKey(
        keyPair: own,
        remotePublicKey: SimplePublicKey(
          senderPublicKey,
          type: KeyPairType.x25519,
        ),
      ),
      ephemeralPublicKey: box.ephemeralPublicKey,
    );
    final int macOffset = box.cipherText.length - _macLength;
    final List<int> plaintext = await _aead.decrypt(
      SecretBox(
        box.cipherText.sublist(0, macOffset),
        nonce: box.nonce,
        mac: Mac(box.cipherText.sublist(macOffset)),
      ),
      secretKey: key,
      aad: associatedData,
    );
    return Uint8List.fromList(plaintext);
  }

  static Future<SecretKey> _deriveKey({
    required SecretKey ephemeralShared,
    required SecretKey staticShared,
    required Uint8List ephemeralPublicKey,
  }) async {
    final List<int> material = <int>[
      ...await ephemeralShared.extractBytes(),
      ...await staticShared.extractBytes(),
    ];
    return _hkdf.deriveKey(
      secretKey: SecretKey(material),
      nonce: ephemeralPublicKey,
      info: utf8.encode(_context),
    );
  }

  /// Seals a mailbox envelope for [recipient] (see the class comment).
  static Future<RelayHybridBox> sealHybrid({
    required RelayIdentity sender,
    required RelayPublicKeys recipient,
    required Uint8List plaintext,
    required Uint8List associatedData,
  }) async {
    final _KemUse kem = await _kemFor(recipient.pq);
    final SecretKey staticShared = await _x25519.sharedSecretKey(
      keyPair: sender._keyPair,
      remotePublicKey: SimplePublicKey(
        recipient.x25519,
        type: KeyPairType.x25519,
      ),
    );
    final Uint8List nonce = _randomBytes(12);
    final SecretKey key = await hybridKey(
      pqSecret: kem.secret,
      staticShared: await staticShared.extractBytes(),
      pqCiphertext: kem.ciphertext,
      nonce: nonce,
    );
    final SecretBox box = await _aead.encrypt(
      plaintext,
      secretKey: key,
      nonce: nonce,
      aad: associatedData,
    );
    return RelayHybridBox(
      pqCiphertext: kem.ciphertext,
      nonce: nonce,
      cipherText: Uint8List.fromList(<int>[
        ...box.cipherText,
        ...box.mac.bytes,
      ]),
    );
  }

  /// Opens a mailbox envelope; throws when it was not sealed by
  /// [senderPublicKey] for [recipient] (a hybrid identity), or was tampered
  /// with.
  static Future<Uint8List> openHybrid({
    required RelayIdentity recipient,
    required Uint8List senderPublicKey,
    required RelayHybridBox box,
    required Uint8List associatedData,
  }) async {
    final Uint8List? seed = recipient.pqSeed;
    if (seed == null) {
      throw StateError('The relay identity has no hybrid key.');
    }
    if (box.cipherText.length < _macLength ||
        box.nonce.length != 12 ||
        box.pqCiphertext.length != kHybridCiphertextBytes) {
      throw const FormatException('Relay box is malformed.');
    }
    final Uint8List pqSecret = await _openedKem(seed, box.pqCiphertext);
    final SecretKey staticShared = await _x25519.sharedSecretKey(
      keyPair: recipient._keyPair,
      remotePublicKey: SimplePublicKey(
        senderPublicKey,
        type: KeyPairType.x25519,
      ),
    );
    final SecretKey key = await hybridKey(
      pqSecret: pqSecret,
      staticShared: await staticShared.extractBytes(),
      pqCiphertext: box.pqCiphertext,
      nonce: box.nonce,
    );
    final int macOffset = box.cipherText.length - _macLength;
    final List<int> plaintext = await _aead.decrypt(
      SecretBox(
        box.cipherText.sublist(0, macOffset),
        nonce: box.nonce,
        mac: Mac(box.cipherText.sublist(macOffset)),
      ),
      secretKey: key,
      aad: associatedData,
    );
    return Uint8List.fromList(plaintext);
  }

  /// The key of one mailbox envelope from its hybrid secret, the static
  /// X25519 term, the KEM ciphertext and the envelope's nonce.
  @visibleForTesting
  static Future<SecretKey> hybridKey({
    required List<int> pqSecret,
    required List<int> staticShared,
    required List<int> pqCiphertext,
    required List<int> nonce,
  }) {
    return _hkdf.deriveKey(
      secretKey: SecretKey(<int>[...pqSecret, ...staticShared]),
      nonce: <int>[...pqCiphertext, ...nonce],
      info: utf8.encode(_hybridContext),
    );
  }

  static Future<_KemUse> _kemFor(Uint8List recipientKey) async {
    final String id = base64Url.encode(recipientKey);
    final DateTime now = DateTime.now();
    final _KemUse? known = _sendKems[id];
    if (known != null &&
        known.uses < kemReuse &&
        now.difference(known.createdAt) < kemLifetime) {
      known.uses += 1;
      return known;
    }
    final HybridEncapsulation made = await hybridKem.encapsulate(
      recipientKey,
      info: utf8.encode(_kemContext),
    );
    final _KemUse fresh = _KemUse(made.ciphertext, made.secret, now)..uses = 1;
    _sendKems.remove(id);
    while (_sendKems.length >= _sendKemsKept) {
      _sendKems.remove(_sendKems.keys.first);
    }
    _sendKems[id] = fresh;
    return fresh;
  }

  static Future<Uint8List> _openedKem(
    Uint8List seed,
    Uint8List ciphertext,
  ) async {
    final String id =
        '${base64Url.encode(seed)}|${base64Url.encode(ciphertext)}';
    final Uint8List? known = _openedKems.remove(id);
    final Uint8List secret =
        known ??
        await hybridKem.decapsulate(
          seed,
          ciphertext,
          info: utf8.encode(_kemContext),
        );
    _openedKems[id] = secret;
    while (_openedKems.length > _openedKemsKept) {
      _openedKems.remove(_openedKems.keys.first);
    }
    return secret;
  }

  /// Forgets the reused and opened encapsulations (tests).
  @visibleForTesting
  static void debugForgetKems() {
    _sendKems.clear();
    _openedKems.clear();
  }

  static Uint8List _randomBytes(int length) {
    final Random random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}

/// Chunk sealing for blobs: attachments too large for one relayed envelope.
///
/// Each blob gets a fresh random 32-byte key. The key — with the blob's size,
/// chunk count and digest — travels to the recipient in a small *manifest*,
/// an ordinary reliable payload: sent directly, or sealed with [RelayCipher]
/// for the mailboxes. The chunks themselves are sealed once with
/// ChaCha20-Poly1305 under the blob key and can then be handed to any number
/// of mailboxes, which hold only ciphertext:
///
/// * a mailbox cannot read, forge or alter a chunk (no key);
/// * the nonce is the chunk index, unique under a key that is never reused;
/// * blob id, sender, recipient, index and count are bound as associated
///   data, so a chunk cannot be moved to another blob, position or person,
///   and a blob cannot be cut short.
final class RelayBlobCipher {
  RelayBlobCipher._();

  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static const int _macLength = 16;

  /// Bytes a sealed chunk adds to its plaintext.
  static const int overheadBytes = _macLength;

  static Uint8List newKey() => RelayCipher._randomBytes(32);

  static Uint8List associatedDataFor({
    required String blobId,
    required String sender,
    required String recipient,
    required int index,
    required int count,
  }) {
    return Uint8List.fromList(
      utf8.encode('zen.relay.blob.v1|$blobId|$sender|$recipient|$index|$count'),
    );
  }

  static Uint8List _nonceFor(int index) {
    final Uint8List nonce = Uint8List(12);
    for (int i = 0; i < 6; i++) {
      nonce[11 - i] = (index >> (8 * i)) & 0xff;
    }
    return nonce;
  }

  static Future<Uint8List> sealChunk({
    required Uint8List key,
    required int index,
    required Uint8List plaintext,
    required Uint8List associatedData,
  }) async {
    final SecretBox box = await _aead.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonceFor(index),
      aad: associatedData,
    );
    return Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]);
  }

  /// Opens a sealed chunk; throws when it was not sealed under [key] for
  /// exactly this [associatedData] and [index].
  static Future<Uint8List> openChunk({
    required Uint8List key,
    required int index,
    required Uint8List sealed,
    required Uint8List associatedData,
  }) async {
    if (sealed.length < _macLength) {
      throw const FormatException('Blob chunk is malformed.');
    }
    final int macOffset = sealed.length - _macLength;
    final List<int> plaintext = await _aead.decrypt(
      SecretBox(
        sealed.sublist(0, macOffset),
        nonce: _nonceFor(index),
        mac: Mac(sealed.sublist(macOffset)),
      ),
      secretKey: SecretKey(key),
      aad: associatedData,
    );
    return Uint8List.fromList(plaintext);
  }
}
