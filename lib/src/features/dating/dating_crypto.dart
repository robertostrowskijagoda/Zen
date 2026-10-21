import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';

const String _kDatingAad = 'zen.date.v1';

/// A sealed message between two dating keys: it travels through
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

/// X25519 of the secret of [me] with [point] (a public key, or any point
/// of the curve).
Future<Uint8List> _x25519(RelayIdentity me, Uint8List point) async {
  final SecretKey shared = await X25519().sharedSecretKey(
    keyPair: SimpleKeyPairData(
      me.privateKey,
      publicKey: SimplePublicKey(me.publicKey, type: KeyPairType.x25519),
      type: KeyPairType.x25519,
    ),
    remotePublicKey: SimplePublicKey(point, type: KeyPairType.x25519),
  );
  return Uint8List.fromList(await shared.extractBytes());
}

/// The "Tak" token for the pair ([me], [them]): both sides compute
/// the same value from their dating keys, nobody else can. It is sent only
/// for "Tak"; "Nie" sends nothing, so it looks exactly like no decision.
Future<String> datingLikeToken(RelayIdentity me, Uint8List them) async {
  final SecretKey shared = SecretKey(await _x25519(me, them));
  final String a = base64Url.encode(me.publicKey);
  final String b = base64Url.encode(them);
  final List<String> pair = <String>[a, b]..sort();
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode('zen-date-like|${pair[0]}|${pair[1]}'),
    secretKey: shared,
  );
  return base64Url.encode(mac.bytes);
}

/// Size steps of a profile sent on request, in bytes.
const int kDatingBucket = 4096;

/// [content] with a filler field `z`, so that its JSON is a whole number of
/// [kDatingBucket]s long, at least [minBuckets]. A real profile and a cover
/// (what a phone with dating off answers a request with) then look alike to
/// the phones the sealed answer passes through: they see a size, nothing
/// else, and a cover is drawn from the range of real profiles.
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

/// Proof that the answer to a profile request for the lantern [lanternId]
/// comes from the one who sent that lantern and names the dating key
/// [datingKey]. The owner computes it with the lantern's one-off
/// key ([me]) and the asker's dating key ([them]); the asker with its dating
/// key and the lantern's key — both get the same value, nobody else can.
Future<String> datingLanternProof(
  RelayIdentity me,
  Uint8List them,
  String lanternId,
  String datingKey,
) async {
  final Mac mac = await Hmac.sha256().calculateMac(
    utf8.encode('zen-date-lantern|$lanternId|$datingKey'),
    secretKey: SecretKey(await _x25519(me, them)),
  );
  return base64Url.encode(mac.bytes);
}

/// The private match test behind a lantern: whether two people fit
/// (intention — dates or new friends — and wanted genders, both ways), and
/// nothing else.
///
/// Every wish is a tag ([DatingMatch.slots] at most, see `DatingWants`
/// `offerTags` / `seekTags`); two people fit when they share a tag. Each
/// tag is hashed to a point of Curve25519. The asker blinds its points with
/// a one-off secret b; the lantern's owner raises them with a secret a, new
/// for every answer, returns them shuffled, and sends its own points raised
/// with a as well; the asker raises those with b and compares: H(t)^ab is the
/// same on both sides only for a common tag (a Diffie–Hellman private set
/// intersection). So:
/// * the owner learns nothing about the asker's wishes from the question;
/// * the asker learns whether (and in how many tags) they fit;
/// * the phones in between see sealed boxes of always the same size.
/// Unused slots are filled with random points, which look the same as the
/// real ones. A phone with dating off (or a person it is hidden from) fills
/// every slot, so it never fits, exactly like a person who does not fit.
/// The profile itself goes out only after a proof of fit ([proves]): the
/// asker reveals b, and the owner checks that a question point is one of its
/// own tags blinded with b.
///
/// Limits: a modified app can put any points in a question, so every answer
/// tells it how many of up to [slots] chosen tags the owner offers. Keys cost
/// nothing; what bounds this is the number of answers per lantern and per
/// friend the question came through (`kDatingMatchNearPerFriend`,
/// `kDatingMatchFarPerFriend` in the service), not the asker's key.
abstract final class DatingMatch {
  /// Points on each side: one per way of meeting (dates, new friends) and
  /// gender. Every question and answer carries all of them, real or filler.
  static const int slots = 6;

  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final Map<String, Uint8List> _points = <String, Uint8List>{};

  /// The point for [tag]: on the curve (not the twist), with no known
  /// discrete logarithm.
  static Future<Uint8List> point(String tag) async {
    final Uint8List? known = _points[tag];
    if (known != null) {
      return known;
    }
    for (int i = 0; ; i++) {
      final Hash h = await Sha256().hash(utf8.encode('zen-date-match|$i|$tag'));
      final Uint8List u = Uint8List.fromList(h.bytes);
      u[31] &= 0x7f;
      BigInt x = BigInt.zero;
      for (int j = 31; j >= 0; j--) {
        x = (x << 8) | BigInt.from(u[j]);
      }
      if (x == BigInt.zero || x >= _p) {
        continue;
      }
      // On the curve when x³ + 486662x² + x is a square mod p.
      final BigInt v = (x * x * x + BigInt.from(486662) * x * x + x) % _p;
      if (v != BigInt.zero &&
          v.modPow((_p - BigInt.one) >> 1, _p) == BigInt.one) {
        return _points[tag] = u;
      }
    }
  }

  /// A random point of the same kind as a raised one (fills a slot).
  static Future<String> _filler() async =>
      base64Url.encode((await RelayIdentity.generate()).publicKey);

  static Future<List<String>> _raised(
    RelayIdentity secret,
    Set<String> tags,
    Random random,
  ) async {
    final List<String> out = <String>[
      for (final String tag in tags.take(slots))
        base64Url.encode(await _x25519(secret, await point(tag))),
    ];
    while (out.length < slots) {
      out.add(await _filler());
    }
    return out..shuffle(random);
  }

  static List<Uint8List>? _points3(Object? json) {
    if (json is! List || json.length != slots) {
      return null;
    }
    final List<Uint8List> out = <Uint8List>[];
    for (final Object? p in json) {
      final Uint8List? key = decodeRelayKey(p);
      if (key == null) {
        return null;
      }
      out.add(key);
    }
    return out;
  }

  /// The asker's side: a one-off blinding secret and its blinded [tags]
  /// (empty: only fillers).
  static Future<(RelayIdentity, List<String>)> ask(
    Set<String> tags,
    Random random,
  ) async {
    final RelayIdentity blind = await RelayIdentity.generate();
    return (blind, await _raised(blind, tags, random));
  }

  /// The owner's side, with a new secret: the asker's points raised with it
  /// (shuffled) and the owner's own [tags] raised with it (empty: only
  /// fillers). `null` when [asked] is not what [ask] makes.
  static Future<(List<String>, List<String>)?> answer(
    Object? asked,
    Set<String> tags,
    Random random,
  ) async {
    final List<Uint8List>? points = _points3(asked);
    if (points == null) {
      return null;
    }
    final RelayIdentity secret = await RelayIdentity.generate();
    final List<String> raised = <String>[
      for (final Uint8List p in points)
        base64Url.encode(await _x25519(secret, p)),
    ]..shuffle(random);
    return (raised, await _raised(secret, tags, random));
  }

  /// The owner's check of a proof of fit: whether one of the points the
  /// asker sent ([asked]) is one of the owner's [tags] blinded with the
  /// asker's revealed secret [blind].
  static Future<bool> proves(
    RelayIdentity blind,
    Object? asked,
    Set<String> tags,
  ) async {
    final List<Uint8List>? points = _points3(asked);
    if (points == null) {
      return false;
    }
    final Set<String> sent = <String>{
      for (final Uint8List p in points) base64Url.encode(p),
    };
    for (final String tag in tags.take(slots)) {
      if (sent.contains(
        base64Url.encode(await _x25519(blind, await point(tag))),
      )) {
        return true;
      }
    }
    return false;
  }

  /// The asker's verdict: whether the owner's answer ([raised], [offered])
  /// shows a common tag.
  static Future<bool> fits(
    RelayIdentity blind,
    Object? raised,
    Object? offered,
  ) async {
    final List<Uint8List>? mine = _points3(raised);
    final List<Uint8List>? theirs = _points3(offered);
    if (mine == null || theirs == null) {
      return false;
    }
    final Set<String> mineSet = <String>{
      for (final Uint8List p in mine) base64Url.encode(p),
    };
    for (final Uint8List p in theirs) {
      if (mineSet.contains(base64Url.encode(await _x25519(blind, p)))) {
        return true;
      }
    }
    return false;
  }
}
