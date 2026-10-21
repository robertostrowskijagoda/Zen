import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';

const String _kOuterInfo = 'zen.date.v2.outer';
const String _kInnerInfo = 'zen.date.v2.inner';
const String _kKemInfo = 'zen.date.kem.v2';

final Chacha20 _aead = Chacha20.poly1305Aead();
final Hkdf _hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
const int _macLength = 16;

Uint8List _randomBytes(int length) {
  final Random random = Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
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

Future<SecretKey> _key(List<int> material, List<int> salt, String info) =>
    _hkdf.deriveKey(
      secretKey: SecretKey(material),
      nonce: salt,
      info: utf8.encode(info),
    );

Future<Uint8List> _encrypt(
  SecretKey key,
  List<int> nonce,
  List<int> plain,
) async {
  final SecretBox box = await _aead.encrypt(
    plain,
    secretKey: key,
    nonce: nonce,
  );
  return Uint8List.fromList(<int>[...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> _decrypt(
  SecretKey key,
  List<int> nonce,
  Uint8List sealed,
) async {
  if (sealed.length < _macLength) {
    throw const FormatException('Dating box is malformed.');
  }
  final int at = sealed.length - _macLength;
  return Uint8List.fromList(
    await _aead.decrypt(
      SecretBox(
        sealed.sublist(0, at),
        nonce: nonce,
        mac: Mac(sealed.sublist(at)),
      ),
      secretKey: key,
    ),
  );
}

/// A sealed message between two dating keys: it travels through
/// friends' phones, which can neither read it nor tell who sent it.
///
/// Two layers under one ephemeral key `e`: the outer one carries the
/// sender's dating key (so the phones in between do not see it), the inner
/// one the payload under a key only the sender's static key (or the
/// recipient's) gives (so the recipient knows who wrote). When the
/// recipient has a hybrid key ([seal] `recipientPq`), both keys also take a
/// fresh ML-KEM-768 + X25519 secret (a new encapsulation for every box, so
/// boxes to one person cannot be told apart): what is recorded on the way
/// stays closed even to a quantum computer later.
///
/// Wire: `{e, c?, n, x}` — the ephemeral key, the KEM ciphertext (hybrid
/// boxes only), the nonce and the outer ciphertext.
abstract final class DatingBox {
  static Future<Map<String, String>> seal({
    required RelayIdentity me,
    required Uint8List recipient,
    required Map<String, dynamic> payload,
    Uint8List? recipientPq,
  }) async {
    final RelayIdentity e = await RelayIdentity.generate();
    final List<int> pqSecret;
    final Uint8List? ciphertext;
    if (recipientPq != null) {
      final HybridEncapsulation made = await hybridKem.encapsulate(
        recipientPq,
        info: utf8.encode(_kKemInfo),
      );
      pqSecret = made.secret;
      ciphertext = made.ciphertext;
    } else {
      pqSecret = const <int>[];
      ciphertext = null;
    }
    final List<int> salt = <int>[...e.publicKey, ...?ciphertext];
    final SecretKey inner = await _key(
      <int>[...pqSecret, ...await _x25519(me, recipient)],
      salt,
      _kInnerInfo,
    );
    final Uint8List innerNonce = _randomBytes(12);
    final Uint8List innerBox = await _encrypt(
      inner,
      innerNonce,
      utf8.encode(jsonEncode(payload)),
    );
    final SecretKey outer = await _key(
      <int>[...pqSecret, ...await _x25519(e, recipient)],
      salt,
      _kOuterInfo,
    );
    final Uint8List nonce = _randomBytes(12);
    final Uint8List outerBox = await _encrypt(outer, nonce, <int>[
      ...me.publicKey,
      ...innerNonce,
      ...innerBox,
    ]);
    return <String, String>{
      'e': base64Url.encode(e.publicKey),
      if (ciphertext != null) 'c': base64Url.encode(ciphertext),
      'n': base64Url.encode(nonce),
      'x': base64Url.encode(outerBox),
    };
  }

  /// Opens a box addressed to [me]: the sender's dating key and the
  /// payload, or `null` for anything else (a hybrid box needs [me]'s hybrid
  /// key).
  static Future<(Uint8List, Map<String, dynamic>)?> open({
    required RelayIdentity me,
    required Object? box,
  }) async {
    try {
      if (box is! Map) {
        return null;
      }
      final Uint8List? e = decodeRelayKey(box['e']);
      final Uint8List? nonce = unb64(box['n'], length: 12);
      final Uint8List? sealed = unb64(box['x']);
      final Object? c = box['c'];
      if (e == null || nonce == null || sealed == null) {
        return null;
      }
      List<int> pqSecret = const <int>[];
      Uint8List? ciphertext;
      if (c != null) {
        ciphertext = unb64(c, length: kHybridCiphertextBytes);
        final Uint8List? seed = me.pqSeed;
        if (ciphertext == null || seed == null) {
          return null;
        }
        pqSecret = await hybridKem.decapsulate(
          seed,
          ciphertext,
          info: utf8.encode(_kKemInfo),
        );
      }
      final List<int> salt = <int>[...e, ...?ciphertext];
      final Uint8List middle = await _decrypt(
        await _key(
          <int>[...pqSecret, ...await _x25519(me, e)],
          salt,
          _kOuterInfo,
        ),
        nonce,
        sealed,
      );
      if (middle.length < 32 + 12 + _macLength) {
        return null;
      }
      final Uint8List sender = middle.sublist(0, 32);
      final Uint8List plain = await _decrypt(
        await _key(
          <int>[...pqSecret, ...await _x25519(me, sender)],
          salt,
          _kInnerInfo,
        ),
        middle.sublist(32, 44),
        middle.sublist(44),
      );
      final Object? json = jsonDecode(utf8.decode(plain));
      if (json is! Map) {
        return null;
      }
      return (sender, Map<String, dynamic>.from(json));
    } on Object {
      return null;
    }
  }

  /// Whether [box] is sealed with the hybrid KEM.
  static bool isHybrid(Object? box) => box is Map && box['c'] is String;
}

/// What a "Tak" signs: this like, from [from] to [to], with the KEM
/// ciphertext [ciphertext] that starts the pair's own secret.
Uint8List datingLikeBytes({
  required String from,
  required String to,
  required String ciphertext,
}) => canonicalJsonBytes(<String, dynamic>{
  't': 'zen_date_like',
  'from': from,
  'to': to,
  'c': ciphertext,
});

/// A fresh hybrid secret for the dating key with hybrid half [theirPq]: the
/// ciphertext (base64url) to send in a "Tak" and the secret kept here.
Future<(String, Uint8List)> datingPairEncapsulate(Uint8List theirPq) async {
  final HybridEncapsulation made = await hybridKem.encapsulate(
    theirPq,
    info: utf8.encode('zen.date.pair.v1'),
  );
  return (base64Url.encode(made.ciphertext), made.secret);
}

/// The secret in a "Tak" that came ([ciphertext]), for this phone's hybrid
/// dating key [me]; `null` for anything malformed.
Future<Uint8List?> datingPairDecapsulate(
  RelayIdentity me,
  Object? ciphertext,
) async {
  final Uint8List? c = unb64(ciphertext, length: kHybridCiphertextBytes);
  final Uint8List? seed = me.pqSeed;
  if (c == null || seed == null) {
    return null;
  }
  try {
    return await hybridKem.decapsulate(
      seed,
      c,
      info: utf8.encode('zen.date.pair.v1'),
    );
  } on Object {
    return null;
  }
}

/// The pair's own key: from the two secrets of their "Tak"s (each side
/// started one with a hybrid encapsulation), ordered by dating key so both
/// sides get the same. Messages carry a MAC with it, so a message stays
/// authentic even to someone who breaks X25519 later.
Uint8List datingPairKey({
  required String myKey,
  required String theirKey,
  required List<int> mine,
  required List<int> theirs,
}) {
  final bool first = myKey.compareTo(theirKey) < 0;
  return Uint8List.fromList(
    crypto.sha256.convert(<int>[
      ...utf8.encode('zen-date-pair|'),
      ...(first ? mine : theirs),
      ...(first ? theirs : mine),
    ]).bytes,
  );
}

/// The MAC of a message [id] with [text] under the pair key [key].
String datingMessageMac(List<int> key, String id, String text) => b64(
  crypto.Hmac(
    crypto.sha256,
    key,
  ).convert(utf8.encode('zen-date-msg|$id|$text')).bytes,
);

/// The same secret for one friend's address on both sides of a pair (for
/// "Wspólni znajomi", shown only when both agreed): a MAC under the pair
/// key, cut short.
String datingFriendMark(List<int> key, String address) => b64(
  crypto.Hmac(
    crypto.sha256,
    key,
  ).convert(utf8.encode('zen-date-friend|$address')).bytes.sublist(0, 16),
);

/// Bytes of the core of a profile (or a cover) sent on request: always
/// exactly this many, so a real profile and a cover look alike.
const int kDatingCoreBytes = 24 * 1024;

/// Bytes of one part of a profile (a photo, or a few vouches) sent on
/// request, real or cover.
const int kDatingPartBytes = 64 * 1024;

/// [content] with a filler field `z`, so that its JSON is exactly [size]
/// bytes long (or a whole number of [size]s, should it ever not fit one). A
/// real profile and a cover (what a phone with dating off answers a request
/// with) then look alike to the phones the sealed answer passes through:
/// one fixed size, nothing else.
Map<String, dynamic> datingPadded(
  Map<String, dynamic> content, {
  int size = kDatingCoreBytes,
}) {
  // `,"z":""` is 7 bytes; the filler is plain ASCII.
  final int plain = utf8.encode(jsonEncode(content)).length + 7;
  final int buckets = max(1, (plain / size).ceil());
  return <String, dynamic>{
    ...content,
    'z': ''.padRight(buckets * size - plain, ' '),
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
/// The test itself is classical (there is no post-quantum private set
/// intersection in use); its answers and everything after them travel in
/// hybrid boxes ([DatingBox]).
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
