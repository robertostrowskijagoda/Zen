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

/// Size steps of a profile sent on request, in bytes (§19.7).
const int kDatingBucket = 4096;

/// [content] with a filler field `z`, so that its JSON is a whole number of
/// [kDatingBucket]s long, at least [minBuckets]. A real profile and a cover
/// (what a phone with dating off answers a request with) then look alike to
/// the phones the sealed answer passes through: they see a size, nothing
/// else, and a cover is drawn from the range of real profiles (§19.1).
Map<String, dynamic> datingPadded(
  Map<String, dynamic> content, {
  int minBuckets = 1,
}) {
  // `,"z":""` is 7 bytes; the filler is plain ASCII.
  final int plain = utf8.encode(jsonEncode(content)).length + 7;
  final int buckets = max(minBuckets, (plain / kDatingBucket).ceil());
  return <String, dynamic>{
    ...content,
    'z': ''.padRight(buckets * kDatingBucket - plain, ' '),
  };
}
