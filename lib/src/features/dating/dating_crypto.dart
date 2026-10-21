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

/// The commitment a lantern carries: SHA-256 of its one-off hybrid key (the
/// X25519 key and the ML-KEM-768 + X25519 key, as they are sent on request).
/// Small enough to flood three steps every week; whoever asks gets the keys
/// themselves and checks them against it, so a phone on the way cannot slip
/// its own keys in (a hash, safe against a quantum computer).
String datingLanternHash(List<int> x25519, List<int> pq) =>
    b64(crypto.sha256.convert(<int>[...x25519, ...pq]).bytes);

/// Proof that the answer to a profile request for the lantern [lanternId]
/// comes from the one who holds that lantern and names the dating key
/// [datingKey]: a MAC with the secret [nonce] the lantern's holder put in
/// its answer to the match test. That answer is sealed (hybrid) for the
/// asker, and the asker's keys came sealed (hybrid) to the lantern's key,
/// so only the two of them know the nonce — now and later.
String datingLanternProof(
  List<int> nonce,
  String lanternId,
  String datingKey,
) => b64(
  crypto.Hmac(
    crypto.sha256,
    nonce,
  ).convert(utf8.encode('zen-date-lantern|$lanternId|$datingKey')).bytes,
);

/// What the first phone on the way back says about who asked: a MAC of the
/// question's ephemeral key [ephemeral] with the dating key the asker's own
/// phone told it ([datingKey]). The lantern's holder checks it against the
/// key inside the question: an app that asks with another key than the one
/// it told its friends is noticed (and a hidden friend recognised). It
/// names nobody to the phones on the way.
String datingOriginTag(String datingKey, String ephemeral) => b64(
  crypto.Hmac(
    crypto.sha256,
    utf8.encode(datingKey),
  ).convert(utf8.encode('zen-date-origin|$ephemeral')).bytes.sublist(0, 16),
);

/// The private match test behind a lantern: whether two people fit
/// (intention — dates or new friends — and wanted genders, both ways).
///
/// Every wish is a tag of a small, fixed universe ([universe]: 2 ways of
/// meeting × 3 genders × 3 genders = 18; see `DatingWants` `offerTags` /
/// `seekTags`); two people fit when they share a tag. The test is a
/// **sealed offer**: the lantern's holder answers with its offered tags as
/// a fixed-length bit string, sealed (ML-KEM-768 + X25519) for the asker,
/// and the asker compares them with its own wishes on its own phone. The
/// question carries no wishes at all, so the holder learns nothing from it;
/// the asker reveals its wishes only in the profile request that proves the
/// fit, and only when they fit (as before, with a new private set
/// intersection). Nothing in it rests on a discrete logarithm: a recording
/// stays closed to a quantum computer.
///
/// What it gives an asker who is not honest: the holder's offered tags for
/// this answer. That is no more than the earlier Diffie–Hellman test gave:
/// there a modified app chose 6 of the 18 tags per answer and learnt all of
/// them in three answers, within the same limits per lantern and friend
/// (`kDatingMatchNearPerFriend`, `kDatingMatchFarPerFriend` in the service).
/// A phone with dating off, or that this person hides from, offers nothing
/// — exactly like a person who does not fit.
abstract final class DatingMatch {
  /// Every tag, in a fixed order: the bit strings follow it.
  static final List<String> universe = <String>[
    for (final String m in <String>['d', 'f'])
      for (final String o in <String>['k', 'm', 'i'])
        for (final String g in <String>['k', 'm', 'i']) '$m:$o>$g',
  ];

  /// [tags] as a bit string over [universe] ('1' for a tag in it).
  static String bits(Set<String> tags) => <String>[
    for (final String t in universe) tags.contains(t) ? '1' : '0',
  ].join();

  /// Nothing offered or asked: what a phone with dating off sends.
  static String get none => '0' * universe.length;

  /// Whether [json] is a bit string of the right length.
  static bool valid(Object? json) =>
      json is String &&
      json.length == universe.length &&
      json.split('').every((String c) => c == '0' || c == '1');

  /// The tags of a bit string (empty for anything malformed).
  static Set<String> tagsOf(Object? json) => !valid(json)
      ? const <String>{}
      : <String>{
          for (int i = 0; i < universe.length; i++)
            if ((json as String)[i] == '1') universe[i],
        };

  /// Whether the asked tags [seek] and the offered [offer] share one.
  static bool fits(Object? seek, Object? offer) {
    if (!valid(seek) || !valid(offer)) {
      return false;
    }
    final String a = seek as String;
    final String b = offer as String;
    for (int i = 0; i < a.length; i++) {
      if (a[i] == '1' && b[i] == '1') {
        return true;
      }
    }
    return false;
  }
}
