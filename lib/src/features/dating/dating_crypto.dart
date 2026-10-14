import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';

const String _kDatingAad = 'zen.date.v1';

/// A sealed message between two dating keys (§19): it travels through
/// friends' phones, which can neither read it nor tell who sent it.
///
/// Two layers: the inner box is sealed by the sender's dating key (so the
/// recipient knows who wrote), the outer one by a one-off key (so the
/// phones in between do not even see the sender's dating key).
abstract final class DatingBox {
  static Uint8List get _aad => Uint8List.fromList(utf8.encode(_kDatingAad));

  static Map<String, String> _boxJson(Uint8List sender, RelaySealedBox box) =>
      <String, String>{
        's': base64Url.encode(sender),
        'e': base64Url.encode(box.ephemeralPublicKey),
        'n': base64Url.encode(box.nonce),
        'c': base64Url.encode(box.cipherText),
      };

  static Future<Map<String, String>> seal({
    required RelayIdentity me,
    required Uint8List recipient,
    required Map<String, dynamic> payload,
  }) async {
    final RelaySealedBox inner = await RelayCipher.seal(
      sender: me,
      recipientPublicKey: recipient,
      plaintext: Uint8List.fromList(utf8.encode(jsonEncode(payload))),
      associatedData: _aad,
    );
    final RelayIdentity oneOff = await RelayIdentity.generate();
    final RelaySealedBox outer = await RelayCipher.seal(
      sender: oneOff,
      recipientPublicKey: recipient,
      plaintext: Uint8List.fromList(
        utf8.encode(jsonEncode(_boxJson(me.publicKey, inner))),
      ),
      associatedData: _aad,
    );
    return _boxJson(oneOff.publicKey, outer);
  }

  /// Opens a box addressed to [me]: the sender's dating key and the
  /// payload, or `null` for anything else.
  static Future<(Uint8List, Map<String, dynamic>)?> open({
    required RelayIdentity me,
    required Object? box,
  }) async {
    try {
      final (Uint8List, RelaySealedBox)? outer = _parse(box);
      if (outer == null) {
        return null;
      }
      final Uint8List middle = await RelayCipher.open(
        recipient: me,
        senderPublicKey: outer.$1,
        box: outer.$2,
        associatedData: _aad,
      );
      final (Uint8List, RelaySealedBox)? inner = _parse(
        jsonDecode(utf8.decode(middle)),
      );
      if (inner == null) {
        return null;
      }
      final Uint8List plain = await RelayCipher.open(
        recipient: me,
        senderPublicKey: inner.$1,
        box: inner.$2,
        associatedData: _aad,
      );
      final Object? json = jsonDecode(utf8.decode(plain));
      if (json is! Map) {
        return null;
      }
      return (inner.$1, Map<String, dynamic>.from(json));
    } on Object {
      return null;
    }
  }

  static (Uint8List, RelaySealedBox)? _parse(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Uint8List? s = decodeRelayKey(json['s']);
    final Uint8List? e = decodeRelayKey(json['e']);
    final Object? n = json['n'];
    final Object? c = json['c'];
    if (s == null || e == null || n is! String || c is! String) {
      return null;
    }
    return (
      s,
      RelaySealedBox(
        ephemeralPublicKey: e,
        nonce: base64Url.decode(base64Url.normalize(n)),
        cipherText: base64Url.decode(base64Url.normalize(c)),
      ),
    );
  }
}

/// The "Tak" token for the pair ([me], [them]) (§19.2): both sides compute
/// the same value from their dating keys, nobody else can. It is sent only
/// for "Tak"; "Nie" sends nothing, so it looks exactly like no decision.
Future<String> datingLikeToken(RelayIdentity me, Uint8List them) async {
  final SecretKey shared = await X25519().sharedSecretKey(
    keyPair: SimpleKeyPairData(
      me.privateKey,
      publicKey: SimplePublicKey(me.publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    ),
    remotePublicKey: SimplePublicKey(them, type: KeyPairType.x25519),
  );
  final String a = base64Url.encode(me.publicKey);
  final String b = base64Url.encode(them);
  final List<String> pair = <String>[a, b]..sort();
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode('zen-date-like|${pair[0]}|${pair[1]}'),
    secretKey: shared,
  );
  return base64Url.encode(mac.bytes);
}

/// The weekly package sealed for the phones it passes through (§19.1,
/// "nikt nie wie, kto randkuje").
///
/// The profile (or the cover of a phone with dating off) is encrypted with
/// a fresh random key for every package (ChaCha20-Poly1305). The package
/// shows only the sender's dating key — every app has one, dating or not —
/// and a ciphertext padded to a multiple of [bucket] bytes, so a real
/// profile and a cover look alike to the phones passing it on.
///
/// The key is never in the package. Every phone that gets a package, with
/// dating on or off, asks for the key back along the way it came (sealed
/// to the sender's dating key, see [DatingBox]); every phone answers with
/// the key of its package, real or cover. So the traffic is the same for
/// everybody, and only the phone that asked can read the answer.
///
/// **Limits (honestly):** a phone that only passes packages on can no
/// longer read them, nor keep them to read later. But anyone in range who
/// asks gets the key — a modified app pretending to date still sees the
/// profiles in range, as in any dating app. What the owner controls on top
/// is who gets an answer: blocked dating keys get none. The size buckets
/// hide only the exact size; covers are drawn from the range of real
/// profiles (1–4 photos), not from a perfect match of them.
abstract final class DatingPackageSeal {
  static const int bucket = 4096;
  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static const int _macLength = 16;

  static Uint8List _aad(String sender, String packageId) =>
      Uint8List.fromList(utf8.encode('zen.date.pkg.v2|$sender|$packageId'));

  /// Largest sealed package (ciphertext with its tag) passed on: a profile
  /// with four photos (each under 48 KB of base64) and the longest texts
  /// and lists stays well under half of it.
  static const int maxBytes = 128 * bucket;

  /// Whether [body] is a sealed (v2) package.
  static bool isSealed(Object? body) =>
      body is Map &&
      body['v'] == 2 &&
      body['k'] is String &&
      body['n'] is String &&
      body['c'] is String;

  /// [body] as this app makes packages — a dating key, a 12-byte nonce and
  /// a ciphertext of whole [bucket]s, at most [maxBytes] — rebuilt with
  /// only those fields (nothing else rides along when it is passed on);
  /// `null` for anything else.
  static Map<String, dynamic>? wellFormed(Object? body) {
    if (!isSealed(body)) {
      return null;
    }
    final Map<dynamic, dynamic> b = body as Map<dynamic, dynamic>;
    final String k = b['k'] as String;
    final String n = b['n'] as String;
    final String c = b['c'] as String;
    if (k.length > 64 ||
        n.length > 24 ||
        c.length > (maxBytes ~/ 3 + 1) * 4 ||
        decodeRelayKey(k) == null) {
      return null;
    }
    try {
      final int nonce = base64Url.decode(base64Url.normalize(n)).length;
      final int sealed = base64Url.decode(base64Url.normalize(c)).length;
      if (nonce != 12 ||
          sealed < bucket ||
          sealed > maxBytes ||
          sealed % bucket != 0) {
        return null;
      }
    } on FormatException {
      return null;
    }
    return <String, dynamic>{'v': 2, 'k': k, 'n': n, 'c': c};
  }

  /// The sender's dating key in a sealed package.
  static String? senderOf(Object? body) =>
      isSealed(body) ? (body as Map<dynamic, dynamic>)['k'] as String : null;

  /// Seals [content] (a profile or a cover) as package [packageId] of the
  /// dating key [sender]. [minBuckets] pads a cover to a chosen size.
  /// Returns the key (to hand out on request) and the package body.
  static Future<(Uint8List, Map<String, dynamic>)> seal({
    required String sender,
    required String packageId,
    required Map<String, dynamic> content,
    int minBuckets = 1,
  }) async {
    final Uint8List key = _random(32);
    final Uint8List nonce = _random(12);
    final List<int> json = utf8.encode(jsonEncode(content));
    final int size =
        max(
          minBuckets * bucket,
          ((json.length + _macLength) / bucket).ceil() * bucket,
        ) -
        _macLength;
    // JSON allows trailing white space: the padding needs no framing.
    final Uint8List plain = Uint8List(size)
      ..fillRange(0, size, 0x20)
      ..setRange(0, json.length, json);
    final SecretBox box = await _aead.encrypt(
      plain,
      secretKey: SecretKey(key),
      nonce: nonce,
      aad: _aad(sender, packageId),
    );
    return (
      key,
      <String, dynamic>{
        'v': 2,
        'k': sender,
        'n': base64Url.encode(nonce),
        'c': base64Url.encode(<int>[...box.cipherText, ...box.mac.bytes]),
      },
    );
  }

  /// Opens package [packageId] with [key]; `null` when it does not open.
  static Future<Map<String, dynamic>?> open({
    required Object? body,
    required String packageId,
    required Uint8List key,
  }) async {
    try {
      if (!isSealed(body) || key.length != 32) {
        return null;
      }
      final Map<dynamic, dynamic> b = body as Map<dynamic, dynamic>;
      final Uint8List nonce = base64Url.decode(
        base64Url.normalize(b['n'] as String),
      );
      final Uint8List c = base64Url.decode(
        base64Url.normalize(b['c'] as String),
      );
      if (nonce.length != 12 || c.length < _macLength) {
        return null;
      }
      final List<int> plain = await _aead.decrypt(
        SecretBox(
          c.sublist(0, c.length - _macLength),
          nonce: nonce,
          mac: Mac(c.sublist(c.length - _macLength)),
        ),
        secretKey: SecretKey(key),
        aad: _aad(b['k'] as String, packageId),
      );
      final Object? json = jsonDecode(utf8.decode(plain));
      return json is Map ? Map<String, dynamic>.from(json) : null;
    } on Object {
      return null;
    }
  }

  static Uint8List _random(int length) {
    final Random random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
