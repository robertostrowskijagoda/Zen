import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Knocks while nobody is home. The flat's door runs on a resident's
// phone, so it answers only while that phone is online. Next to it the door
// sticker lists up to [kDoorSlots] "mailbox doors": addresses of door nodes
// whose keys are derived from the phone's door key, one per slot, and run by
// the friends who keep this phone's offline mailboxes. Nothing in the
// code says who runs them; a slot keeps its address when another friend
// takes it over, so the sticker stays valid while the mailboxes change (as
// long as there are not fewer of them).
//
// A knock for a mailbox door is sealed for the household (X25519,
// [FlatSeal]) with a key derived from the household's own key and the door
// token ([flatSealSeed]), which never leave the residents' phones: the
// friend keeps ciphertext only, does not learn who knocked or what flat it
// is, and passes it on to the resident (`flat_held`, through the relay
// layer, direct to the resident as soon as it shows up). The same path
// carries the answer after "Wpuść" when the knocker is offline by then: the
// knock names the knocker's own mailbox doors ([FlatMailDoor]).
//
// Against a quantum computer the box has a second, inner layer: a knock is
// also keyed with the door token from the sticker (a secret only those who
// saw the sticker hold; door traffic itself travels inside the doors'
// post-quantum session layer, door_node.go), and an answer is keyed with a
// hybrid ML-KEM-768 + X25519 key of the knocker's household, which the knock
// carries ([FlatMailDoor.kem]; too big for the sticker). So a friend who
// keeps the ciphertext cannot read it later either — for a knock, unless
// they also saw the sticker.
//
// The other residents' doors go into the same list on the sticker, mixed
// with the mailbox doors and sorted, so nothing tells them apart: every
// resident's phone takes the sealed copy at its own door and opens it with
// the household's key. A knock so reaches every phone of the household that
// is on, also when the phone that printed the sticker is off.

/// Mailbox doors on one door sticker: as many as a phone has mailboxes.
const int kDoorSlots = 6;

/// Other residents' doors on one door sticker at most (beside the mailbox
/// doors).
const int kStickerResidentDoors = 8;

/// Addresses in a sticker's sealed-knock list at most.
const int kStickerSealDoors = kDoorSlots + kStickerResidentDoors;

/// Mailbox doors one phone runs for friends at most (door_node.go has the
/// same cap); later requests are ignored.
const int kMaxHostedDoors = 8;

/// How long a knock held by friends waits for the resident (and how long a
/// knock waits at all, `kKnockLife`).
const Duration kHeldKnockLife = Duration(days: 7);

/// Knocks one mailbox door takes per [kHeldKnockLife]; more are dropped.
const int kHeldPerDoor = 10;

/// Knocks one mailbox door takes per day: fresh keys cost nothing, so a
/// burst of them cannot take the whole week's [kHeldPerDoor] at once.
const int kHeldPerDoorPerDay = 4;

/// Knocks one knocker (a mesh node, or a /64 for subnet addresses) leaves at
/// one mailbox door per [kHeldKnockLife].
const int kHeldPerKnocker = 2;

/// Longest sealed knock (base64 characters): a flat's card without its
/// photo fits; it stays well under the bridge's limit for mailbox doors.
const int kMaxSealedChars = 40000;

/// How long a knocker's phone keeps retrying the flat's door (a door never
/// answers, so retries end only here).
const Duration kDoorRetryLife = Duration(days: 1);

/// How long a sealed knock is retried at the mailbox doors: their friends
/// are mostly online, and six of them get it.
const Duration kSealRetryLife = Duration(hours: 1);

/// The Yggdrasil address of an ed25519 [publicKey] (yggdrasil-go's
/// `address.AddrForKey`): the mailbox doors' addresses go on the sticker
/// before any of them runs.
String yggAddressForKey(List<int> publicKey) {
  final List<int> inverted = <int>[for (final int b in publicKey) ~b & 0xff];
  final List<int> rest = <int>[];
  int ones = 0;
  bool done = false;
  int bits = 0;
  int count = 0;
  for (int i = 0; i < 8 * inverted.length; i++) {
    final int bit = (inverted[i ~/ 8] >> (7 - i % 8)) & 1;
    if (!done) {
      if (bit != 0) {
        ones++;
      } else {
        done = true;
      }
      continue;
    }
    bits = ((bits << 1) | bit) & 0xff;
    count++;
    if (count == 8) {
      count = 0;
      rest.add(bits);
    }
  }
  final Uint8List address = Uint8List(16)
    ..[0] = 0x02
    ..[1] = ones & 0xff;
  for (int i = 0; i < 14 && i < rest.length; i++) {
    address[2 + i] = rest[i];
  }
  return addressFromBytes(address);
}

/// An IPv6 address from its 16 bytes, normalized as the app keeps them.
String addressFromBytes(List<int> bytes) => PeerShareCodec.normalizeAddress(
  <String>[
    for (int i = 0; i < 16; i += 2)
      ((bytes[i] << 8) | bytes[i + 1]).toRadixString(16),
  ].join(':'),
);

/// The 16 bytes of an IPv6 address, or `null`.
Uint8List? addressBytes(String address) {
  try {
    return Uint8List.fromList(Uri.parseIPv6Address(address.trim()));
  } on FormatException {
    return null;
  }
}

Uint8List _hmac(List<int> key, String label) => Uint8List.fromList(
  crypto.Hmac(crypto.sha256, key).convert(utf8.encode(label)).bytes,
);

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List? _unhex(String hex) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(hex)) {
    return null;
  }
  return Uint8List.fromList(<int>[
    for (int i = 0; i < 64; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// The address of the door node a key (hex seed) runs as, or `null` for a
/// key that is not one.
Future<String?> doorAddressForSeed(String seedHex) async {
  final Uint8List? seed = _unhex(seedHex);
  if (seed == null) {
    return null;
  }
  return yggAddressForKey((await LedgerKeyPair.fromSeed(seed)).publicKey);
}

/// The seed of the household's sealing key: from the household's own key
/// ([flatSeed], which every resident holds) and the door token, so every
/// resident opens what knockers sealed, and a new door code (or a new
/// household key) makes old sealed knocks unreadable.
Uint8List flatSealSeed(List<int> flatSeed, String doorToken) =>
    _hmac(flatSeed, 'zen.flat.door-seal.v2|$doorToken');

/// The seed of the household's hybrid post-quantum key for sealed
/// answers, from its sealing seed ([flatSealSeed]).
Uint8List flatSealKemSeed(List<int> sealSeed) =>
    _hmac(sealSeed, 'zen.flat.seal.kem.v1');

/// The household's sealing key from its [seed] ([flatSealSeed]); `null`
/// for a seed that is not 32 bytes.
Future<RelayIdentity?> flatSealIdentity(List<int> seed) async {
  if (seed.length != 32) {
    return null;
  }
  final SimpleKeyPair pair = await X25519().newKeyPairFromSeed(seed);
  final SimpleKeyPairData data = await pair.extract();
  final SimplePublicKey sealPublic = await pair.extractPublicKey();
  return RelayIdentity(
    privateKey: Uint8List.fromList(data.bytes),
    publicKey: Uint8List.fromList(sealPublic.bytes),
  );
}

/// [bytes] as lowercase hex.
String flatHex(List<int> bytes) => _hex(bytes);

/// The 32 bytes of a hex seed, or `null`.
Uint8List? flatUnhex(String hex) => _unhex(hex);

/// What a phone's door key (hex seed of the flat's door node) gives: the
/// keys and addresses of its mailbox doors; with the household's sealing
/// key ([flatSealSeed]) knocks for them are sealed to. Derived each time,
/// never stored.
@immutable
final class FlatDoorKeys {
  const FlatDoorKeys({
    required this.doorKey,
    required this.sealSeed,
    required this.slotSeeds,
    required this.slots,
    required this.seal,
    required this.kemSeed,
    required this.kemPublic,
  });

  final String doorKey;

  /// The household's sealing seed (hex) [seal] was made from.
  final String sealSeed;

  /// The mailbox doors' keys (hex), handed to the friends who run them.
  final List<String> slotSeeds;

  /// Their addresses, printed on the sticker.
  final List<String> slots;

  /// Opens what knockers sealed for this door; stays on this phone.
  final RelayIdentity seal;

  /// The household's hybrid post-quantum key for sealed answers
  /// ([flatSealKemSeed]): the seed stays on this phone, the public key goes
  /// in knocks.
  final Uint8List kemSeed;
  final Uint8List kemPublic;

  /// The keys of the door key [doorKey] with the household's sealing seed
  /// [sealSeed] ([flatSealSeed]).
  static Future<FlatDoorKeys?> derive(
    String doorKey, {
    required List<int> sealSeed,
  }) async {
    final Uint8List? key = _unhex(doorKey);
    final RelayIdentity? seal = await flatSealIdentity(sealSeed);
    if (key == null || seal == null) {
      return null;
    }
    final List<String> seeds = <String>[
      for (int i = 0; i < kDoorSlots; i++)
        _hex(_hmac(key, 'zen.flat.door-slot.v1|$i')),
    ];
    final List<String> slots = <String>[
      for (final String s in seeds) (await doorAddressForSeed(s))!,
    ];
    final Uint8List kemSeed = flatSealKemSeed(sealSeed);
    return FlatDoorKeys(
      doorKey: doorKey,
      sealSeed: _hex(sealSeed),
      slotSeeds: seeds,
      slots: slots,
      seal: seal,
      kemSeed: kemSeed,
      kemPublic: await hybridKem.publicKeyOf(kemSeed),
    );
  }

  /// Where sealed knocks may be left: the mailbox doors of the slots
  /// [taken] (the ones friends run) and the other residents' [doors] (at
  /// most [kStickerResidentDoors]), sorted together so the list does not
  /// tell which is which; `null` with none. [withKem]: with the hybrid key
  /// for answers (in a knock; a sticker has no room for it).
  FlatMailDoor? mailDoor(
    Iterable<int> taken, {
    Iterable<String> doors = const <String>[],
    bool withKem = false,
  }) {
    final List<int> picked =
        taken.where((int i) => i >= 0 && i < slots.length).toSet().toList()
          ..sort();
    final Set<String> all = <String>{
      for (final int i in picked) slots[i],
      ...doors
          .where((String d) => addressBytes(d)?.first == 0x02)
          .map(PeerShareCodec.normalizeAddress)
          .take(kStickerResidentDoors),
    };
    if (all.isEmpty) {
      return null;
    }
    final List<String> sorted = all.toList()
      ..sort((String a, String b) => _compareBytes(a, b));
    return FlatMailDoor(
      slots: sorted,
      seal: seal.publicKeyBase64,
      kem: withKem ? kemPublic : null,
    );
  }

  static int _compareBytes(String a, String b) {
    final Uint8List x = addressBytes(a) ?? Uint8List(16);
    final Uint8List y = addressBytes(b) ?? Uint8List(16);
    for (int i = 0; i < 16; i++) {
      if (x[i] != y[i]) {
        return x[i] - y[i];
      }
    }
    return 0;
  }
}

/// Where sealed mail for a flat can be left while its phones are offline:
/// its mailbox doors and the key to seal for. On the door sticker, and in a
/// knock (so the answer can wait for the knocker the same way).
@immutable
final class FlatMailDoor {
  const FlatMailDoor({required this.slots, required this.seal, this.kem});

  final List<String> slots;

  /// X25519 public key, base64url.
  final String seal;

  /// The household's hybrid post-quantum public key
  /// ([FlatDoorKeys.kemPublic]), in a knock only.
  final Uint8List? kem;

  /// The slots as one base64url string of their 16-byte addresses.
  String get slotsCode => base64Url
      .encode(<int>[for (final String s in slots) ...?addressBytes(s)])
      .replaceAll('=', '');

  Map<String, dynamic> toJson() => <String, dynamic>{
    's': slotsCode,
    'x': seal,
    if (kem != null) 'q': base64Url.encode(kem!),
  };

  /// Reads the slots, the sealing key and the hybrid key when there is one
  /// ([kem]); `null` when one of them is not valid.
  static FlatMailDoor? read(Object? slotsCode, Object? seal, [Object? kem]) {
    final Uint8List? kemKey = kem == null ? null : decodeHybridPublicKey(kem);
    if (kem != null && kemKey == null) {
      return null;
    }
    if (slotsCode is! String ||
        slotsCode.isEmpty ||
        slotsCode.length > 400 ||
        decodeRelayKey(seal) == null) {
      return null;
    }
    try {
      final Uint8List bytes = base64Url.decode(base64Url.normalize(slotsCode));
      if (bytes.isEmpty || bytes.length % 16 != 0) {
        return null;
      }
      final List<String> slots = <String>[];
      for (
        int i = 0;
        i < bytes.length && slots.length < kStickerSealDoors;
        i += 16
      ) {
        // Node addresses only (200::/8): a door is one key.
        if (bytes[i] != 0x02) {
          return null;
        }
        slots.add(addressFromBytes(bytes.sublist(i, i + 16)));
      }
      return FlatMailDoor(slots: slots, seal: seal as String, kem: kemKey);
    } on FormatException {
      return null;
    }
  }

  static FlatMailDoor? fromJson(Object? json) =>
      json is Map ? read(json['s'], json['x'], json['q']) : null;
}

/// Sealing for the mailbox doors: [RelayCipher] with a fresh sender key per
/// box, so the box says nothing about who made it; what is inside is signed
/// with the flat's key anyway. Inside it, a second layer (ChaCha20-Poly1305)
/// keyed with what a quantum computer cannot get at: the door token from the
/// sticker (`p`), a secret encapsulated to the recipient's hybrid
/// ML-KEM-768 + X25519 key (`q`, the ciphertext), or both.
abstract final class FlatSeal {
  static final Uint8List _context = Uint8List.fromList(
    utf8.encode('zen.flat.seal.v1'),
  );
  static final List<int> _kemInfo = utf8.encode('zen.flat.seal.kem.v2');
  static final Chacha20 _aead = Chacha20.poly1305Aead();

  /// The key of the inner layer, from the door token and the KEM secret.
  static Uint8List _innerKey({
    String? doorToken,
    List<int>? kemSecret,
    List<int>? ciphertext,
  }) => Uint8List.fromList(
    crypto.Hmac(crypto.sha256, <int>[
      ...?(doorToken == null
          ? null
          : _hmac(utf8.encode(doorToken), 'zen.flat.seal.psk.v2')),
      ...?kemSecret,
    ]).convert(<int>[
      ...utf8.encode('zen.flat.seal.inner.v2|'),
      ...?(ciphertext == null ? null : crypto.sha256.convert(ciphertext).bytes),
    ]).bytes,
  );

  /// [message] sealed for [seal] (base64url X25519): `{x, n, c, k}`, plus
  /// `p` when keyed with the [doorToken] of the sticker it is for, and `q`
  /// when keyed with a secret for the household's hybrid key [kem].
  static Future<Map<String, dynamic>?> seal(
    Map<String, dynamic> message,
    String seal, {
    String? doorToken,
    Uint8List? kem,
  }) async {
    final Uint8List? to = decodeRelayKey(seal);
    if (to == null) {
      return null;
    }
    Uint8List plaintext = Uint8List.fromList(utf8.encode(jsonEncode(message)));
    HybridEncapsulation? encapsulated;
    if (kem != null) {
      encapsulated = await hybridKem.encapsulate(kem, info: _kemInfo);
    }
    if (doorToken != null || encapsulated != null) {
      final Uint8List key = _innerKey(
        doorToken: doorToken,
        kemSecret: encapsulated?.secret,
        ciphertext: encapsulated?.ciphertext,
      );
      final Uint8List nonce = randomBytes(12);
      final SecretBox inner = await _aead.encrypt(
        plaintext,
        secretKey: SecretKey(key),
        nonce: nonce,
        aad: _context,
      );
      key.fillRange(0, key.length, 0);
      if (encapsulated != null) {
        encapsulated.secret.fillRange(0, encapsulated.secret.length, 0);
      }
      plaintext = Uint8List.fromList(<int>[
        ...nonce,
        ...inner.cipherText,
        ...inner.mac.bytes,
      ]);
    }
    final RelayIdentity sender = await RelayIdentity.generate();
    final RelaySealedBox box = await RelayCipher.seal(
      sender: sender,
      recipientPublicKey: to,
      plaintext: plaintext,
      associatedData: _context,
    );
    return <String, dynamic>{
      'x': base64Url.encode(box.ephemeralPublicKey),
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'k': sender.publicKeyBase64,
      if (doorToken != null) 'p': 1,
      if (encapsulated != null) 'q': base64Url.encode(encapsulated.ciphertext),
    };
  }

  /// Whether [json] has the shape of a box within [kMaxSealedChars].
  static bool looksSealed(Map<dynamic, dynamic> json) {
    final Object? c = json['c'];
    final Object? n = json['n'];
    final Object? p = json['p'];
    final Object? q = json['q'];
    return c is String &&
        c.isNotEmpty &&
        c.length <= kMaxSealedChars &&
        n is String &&
        n.length <= 24 &&
        (p == null || p == 1) &&
        (q == null || (q is String && q.length <= 2000)) &&
        decodeRelayKey(json['x']) != null &&
        decodeRelayKey(json['k']) != null;
  }

  /// Opens a box made by [seal]; `null` when it is not one for [own] (with
  /// the [doorToken] of the household's current sticker, and the seed of
  /// its hybrid key [kemSeed], when the box needs them).
  static Future<Map<String, dynamic>?> open(
    Map<dynamic, dynamic> json,
    RelayIdentity own, {
    String? doorToken,
    Uint8List? kemSeed,
  }) async {
    if (!looksSealed(json)) {
      return null;
    }
    try {
      Uint8List plain = await RelayCipher.open(
        recipient: own,
        senderPublicKey: decodeRelayKey(json['k'])!,
        box: RelaySealedBox(
          ephemeralPublicKey: decodeRelayKey(json['x'])!,
          nonce: base64Url.decode(base64Url.normalize(json['n'] as String)),
          cipherText: base64Url.decode(
            base64Url.normalize(json['c'] as String),
          ),
        ),
        associatedData: _context,
      );
      final bool keyed = json['p'] == 1;
      final Object? q = json['q'];
      if (keyed || q != null) {
        if ((keyed && doorToken == null) ||
            (q != null && kemSeed == null) ||
            plain.length < 12 + 16) {
          return null;
        }
        Uint8List? secret;
        Uint8List? ciphertext;
        if (q is String) {
          ciphertext = base64Url.decode(base64Url.normalize(q));
          if (ciphertext.length != kHybridCiphertextBytes) {
            return null;
          }
          secret = await hybridKem.decapsulate(
            kemSeed!,
            ciphertext,
            info: _kemInfo,
          );
        }
        final Uint8List key = _innerKey(
          doorToken: keyed ? doorToken : null,
          kemSecret: secret,
          ciphertext: ciphertext,
        );
        secret?.fillRange(0, secret.length, 0);
        try {
          plain = Uint8List.fromList(
            await _aead.decrypt(
              SecretBox(
                plain.sublist(12, plain.length - 16),
                nonce: plain.sublist(0, 12),
                mac: Mac(plain.sublist(plain.length - 16)),
              ),
              secretKey: SecretKey(key),
              aad: _context,
            ),
          );
        } finally {
          key.fillRange(0, key.length, 0);
        }
      }
      final Object? message = jsonDecode(utf8.decode(plain));
      return message is Map ? Map<String, dynamic>.from(message) : null;
    } on Object {
      return null;
    }
  }
}

/// A mailbox door this phone runs for a friend ([owner]), with the knocks
/// it took lately (for the caps), as hashes only.
final class HostedDoor {
  HostedDoor({
    required this.owner,
    required this.seed,
    required this.address,
    required this.at,
    List<HeldKnock>? knocks,
  }) : knocks = knocks ?? <HeldKnock>[];

  /// The friend whose door it is.
  final String owner;

  /// The door's key (hex), as the friend handed it over.
  final String seed;
  final String address;

  /// When the friend handed it over (the newest hand-over wins).
  final int at;
  final List<HeldKnock> knocks;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'o': owner,
    's': seed,
    'a': address,
    'at': at,
    'k': <Map<String, dynamic>>[for (final HeldKnock k in knocks) k.toJson()],
  };

  static HostedDoor? fromJson(Object? json) {
    if (json is! Map ||
        json['o'] is! String ||
        json['s'] is! String ||
        _unhex(json['s'] as String) == null ||
        json['a'] is! String ||
        json['at'] is! int) {
      return null;
    }
    final Object? knocks = json['k'];
    return HostedDoor(
      owner: PeerShareCodec.normalizeAddress(json['o'] as String),
      seed: json['s'] as String,
      address: PeerShareCodec.normalizeAddress(json['a'] as String),
      at: json['at'] as int,
      knocks: <HeldKnock>[
        if (knocks is List)
          for (final Object? k in knocks.take(kHeldPerDoor))
            if (HeldKnock.fromJson(k) != null) HeldKnock.fromJson(k)!,
      ],
    );
  }
}

/// One knock a mailbox door took: when, and a hash of who knocked (only to
/// count them, [kHeldPerKnocker]).
@immutable
final class HeldKnock {
  const HeldKnock({required this.at, required this.who});

  final int at;
  final String who;

  /// The hash kept for a knocker [identity] at the door [door].
  static String hashOf(String door, String identity) => _hex(
    crypto.sha256.convert(utf8.encode('$door|$identity')).bytes.sublist(0, 12),
  );

  Map<String, dynamic> toJson() => <String, dynamic>{'at': at, 'w': who};

  static HeldKnock? fromJson(Object? json) =>
      json is Map && json['at'] is int && json['w'] is String
      ? HeldKnock(at: json['at'] as int, who: json['w'] as String)
      : null;
}

/// A short hash of [text]: what a mailbox door keeps of a knocker's retry
/// ids, instead of the knocker's address.
String flatMailHash(String text) =>
    _hex(crypto.sha256.convert(utf8.encode(text)).bytes.sublist(0, 12));
