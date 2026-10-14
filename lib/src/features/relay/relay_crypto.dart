import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

/// Long-lived X25519 identity of this device for relayed (store-and-forward)
/// traffic.
///
/// Mesh addresses authenticate *who sent a datagram*, but a relayed message
/// passes through friends' devices on the way, so its content needs its own
/// end-to-end protection bound to the original sender and recipient.
@immutable
final class RelayIdentity {
  const RelayIdentity({required this.privateKey, required this.publicKey});

  final Uint8List privateKey;
  final Uint8List publicKey;

  String get publicKeyBase64 => base64Url.encode(publicKey);

  static Future<RelayIdentity> generate() async {
    final SimpleKeyPair pair = await X25519().newKeyPair();
    final SimpleKeyPairData data = await pair.extract();
    final SimplePublicKey publicKey = await pair.extractPublicKey();
    return RelayIdentity(
      privateKey: Uint8List.fromList(data.bytes),
      publicKey: Uint8List.fromList(publicKey.bytes),
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
    return RelayIdentity(privateKey: sk, publicKey: pk);
  }
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
final class RelayCipher {
  RelayCipher._();

  static const String _context = 'zen.relay.v1';
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

  static Uint8List _randomBytes(int length) {
    final Random random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
