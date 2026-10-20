import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Knocks while nobody is home (§18.2). The flat's door runs on a resident's
// phone, so it answers only while that phone is online. Next to it the door
// sticker lists up to [kDoorSlots] "mailbox doors": addresses of door nodes
// whose keys are derived from the phone's door key, one per slot, and run by
// the friends who keep this phone's offline mailboxes (§7). Nothing in the
// code says who runs them; a slot keeps its address when another friend
// takes it over, so the sticker stays valid while the mailboxes change (as
// long as there are not fewer of them).
//
// A knock for a mailbox door is sealed for the flat (X25519, [FlatSeal]) with
// a key derived from the same door key, which never leaves the residents'
// phones: the friend keeps ciphertext only, does not learn who knocked or
// what flat it is, and passes it on to the resident (`flat_held`, through
// the relay layer, direct to the resident as soon as it shows up). The same
// path carries the answer after "Wpuść" when the knocker is offline by then:
// the knock names the knocker's own mailbox doors ([FlatMailDoor]).

/// Mailbox doors on one door sticker: as many as a phone has mailboxes (§7).
const int kDoorSlots = 6;

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

/// What a phone's door key (hex seed of the flat's door node) gives: the
/// keys and addresses of its mailbox doors, and the key knocks for them are
/// sealed to. Derived each time, never stored.
@immutable
final class FlatDoorKeys {
  const FlatDoorKeys({
    required this.doorKey,
    required this.slotSeeds,
    required this.slots,
    required this.seal,
  });

  final String doorKey;

  /// The mailbox doors' keys (hex), handed to the friends who run them.
  final List<String> slotSeeds;

  /// Their addresses, printed on the sticker.
  final List<String> slots;

  /// Opens what knockers sealed for this door; stays on this phone.
  final RelayIdentity seal;

  static Future<FlatDoorKeys?> derive(String doorKey) async {
    final Uint8List? key = _unhex(doorKey);
    if (key == null) {
      return null;
    }
    final List<String> seeds = <String>[
      for (int i = 0; i < kDoorSlots; i++)
        _hex(_hmac(key, 'zen.flat.door-slot.v1|$i')),
    ];
    final List<String> slots = <String>[
      for (final String s in seeds) (await doorAddressForSeed(s))!,
    ];
    final SimpleKeyPair pair = await X25519().newKeyPairFromSeed(
      _hmac(key, 'zen.flat.door-seal.v1'),
    );
    final SimpleKeyPairData data = await pair.extract();
    final SimplePublicKey sealPublic = await pair.extractPublicKey();
    return FlatDoorKeys(
      doorKey: doorKey,
      slotSeeds: seeds,
      slots: slots,
      seal: RelayIdentity(
        privateKey: Uint8List.fromList(data.bytes),
        publicKey: Uint8List.fromList(sealPublic.bytes),
      ),
    );
  }

  /// The mailbox doors of the slots [taken] (the ones friends run), or
  /// `null` with none.
  FlatMailDoor? mailDoor(Iterable<int> taken) {
    final List<int> sorted =
        taken.where((int i) => i >= 0 && i < slots.length).toSet().toList()
          ..sort();
    return sorted.isEmpty
        ? null
        : FlatMailDoor(
            slots: <String>[for (final int i in sorted) slots[i]],
            seal: seal.publicKeyBase64,
          );
  }
}

/// Where sealed mail for a flat can be left while its phones are offline:
/// its mailbox doors and the key to seal for. On the door sticker, and in a
/// knock (so the answer can wait for the knocker the same way).
@immutable
final class FlatMailDoor {
  const FlatMailDoor({required this.slots, required this.seal});

  final List<String> slots;

  /// X25519 public key, base64url.
  final String seal;

  /// The slots as one base64url string of their 16-byte addresses.
  String get slotsCode => base64Url
      .encode(<int>[for (final String s in slots) ...?addressBytes(s)])
      .replaceAll('=', '');

  Map<String, dynamic> toJson() => <String, dynamic>{'s': slotsCode, 'x': seal};

  /// Reads the slots and the sealing key; `null` when either is not valid.
  static FlatMailDoor? read(Object? slotsCode, Object? seal) {
    if (slotsCode is! String ||
        slotsCode.isEmpty ||
        slotsCode.length > 200 ||
        decodeRelayKey(seal) == null) {
      return null;
    }
    try {
      final Uint8List bytes = base64Url.decode(base64Url.normalize(slotsCode));
      if (bytes.isEmpty || bytes.length % 16 != 0) {
        return null;
      }
      final List<String> slots = <String>[];
      for (int i = 0; i < bytes.length && slots.length < kDoorSlots; i += 16) {
        // Node addresses only (200::/8): a door is one key.
        if (bytes[i] != 0x02) {
          return null;
        }
        slots.add(addressFromBytes(bytes.sublist(i, i + 16)));
      }
      return FlatMailDoor(slots: slots, seal: seal as String);
    } on FormatException {
      return null;
    }
  }

  static FlatMailDoor? fromJson(Object? json) =>
      json is Map ? read(json['s'], json['x']) : null;
}

/// Sealing for the mailbox doors: [RelayCipher] with a fresh sender key per
/// box, so the box says nothing about who made it; what is inside is signed
/// with the flat's key anyway.
abstract final class FlatSeal {
  static final Uint8List _context = Uint8List.fromList(
    utf8.encode('zen.flat.seal.v1'),
  );

  /// [message] sealed for [seal] (base64url X25519): `{x, n, c, k}`.
  static Future<Map<String, dynamic>?> seal(
    Map<String, dynamic> message,
    String seal,
  ) async {
    final Uint8List? to = decodeRelayKey(seal);
    if (to == null) {
      return null;
    }
    final RelayIdentity sender = await RelayIdentity.generate();
    final RelaySealedBox box = await RelayCipher.seal(
      sender: sender,
      recipientPublicKey: to,
      plaintext: Uint8List.fromList(utf8.encode(jsonEncode(message))),
      associatedData: _context,
    );
    return <String, dynamic>{
      'x': base64Url.encode(box.ephemeralPublicKey),
      'n': base64Url.encode(box.nonce),
      'c': base64Url.encode(box.cipherText),
      'k': sender.publicKeyBase64,
    };
  }

  /// Whether [json] has the shape of a box within [kMaxSealedChars].
  static bool looksSealed(Map<dynamic, dynamic> json) {
    final Object? c = json['c'];
    final Object? n = json['n'];
    return c is String &&
        c.isNotEmpty &&
        c.length <= kMaxSealedChars &&
        n is String &&
        n.length <= 24 &&
        decodeRelayKey(json['x']) != null &&
        decodeRelayKey(json['k']) != null;
  }

  /// Opens a box made by [seal]; `null` when it is not one for [own].
  static Future<Map<String, dynamic>?> open(
    Map<dynamic, dynamic> json,
    RelayIdentity own,
  ) async {
    if (!looksSealed(json)) {
      return null;
    }
    try {
      final Uint8List plain = await RelayCipher.open(
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
