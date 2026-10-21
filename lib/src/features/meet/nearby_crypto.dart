import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// [bytes] as lowercase hex.
String nearbyHex(List<int> bytes) =>
    bytes.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Bluetooth wave version of an alarm told to phones nearby.
///
/// Built unsigned for everyone, and signed with the key of one pair of
/// friends ([FriendNearbyKey.pair]) for a friend: only that friend can
/// check it, and no other friend can make it. `t` is the pair's id
/// for the wave's slot ([nearbyPairId]).
const int kAlarmWaveVersion = 6;

/// A wave dated further than this from the receiver's clock (either way)
/// is dropped: a recorded wave cannot be played back later.
const Duration kAlarmWaveFreshFor = Duration(minutes: 10);

/// What an alarm id may look like (the app makes base36 ids).
final RegExp kAlarmIdPattern = RegExp(r'^[0-9A-Za-z_-]{1,40}$');

final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

/// An alarm wave heard over Bluetooth.
///
/// `{v, id, at, end?, t?, m?}`: `t` is the pair's id — friends look up who
/// it is — and `m` the MAC over all of it. Without `t` and `m` the wave is
/// unsigned (told to everyone nearby): nobody can tell whose it is.
@immutable
final class AlarmWave {
  const AlarmWave({
    required this.id,
    required this.at,
    required this.ended,
    this.token = '',
    this.mac = '',
  });

  final String id;

  /// When the sender made it (the sender's clock).
  final int at;
  final bool ended;
  final String token;
  final String mac;

  bool get signed => token.isNotEmpty && mac.isNotEmpty;

  /// The unsigned wave for alarm [id], made at [at].
  static Map<String, dynamic> build({
    required String id,
    required int at,
    required bool ended,
  }) => <String, dynamic>{
    'v': kAlarmWaveVersion,
    'id': id,
    'at': at,
    if (ended) 'end': true,
  };

  /// The wave for alarm [id] signed for one friend with [pairKey] (the key
  /// this phone gave that friend, [NearbyOwnKeys.pairKey]).
  static Map<String, dynamic> buildPair({
    required String id,
    required int at,
    required bool ended,
    required List<int> pairKey,
  }) {
    final String token = nearbyPairId(pairKey, nearbySlot(at));
    return <String, dynamic>{
      'v': kAlarmWaveVersion,
      'id': id,
      'at': at,
      if (ended) 'end': true,
      't': token,
      'm': _pairMac(pairKey, id: id, at: at, ended: ended, token: token),
    };
  }

  /// [json] when it is a well-formed wave of a version read here, else
  /// `null`.
  static AlarmWave? parse(Map<dynamic, dynamic> json) {
    final Object? v = json['v'];
    final Object? id = json['id'];
    final Object? at = json['at'];
    final Object? end = json['end'];
    final Object? t = json['t'];
    final Object? m = json['m'];
    if (v != kAlarmWaveVersion ||
        (t == null) != (m == null) ||
        id is! String ||
        !kAlarmIdPattern.hasMatch(id) ||
        at is! int ||
        (end != null && end is! bool) ||
        (t != null && (t is! String || !_hex32.hasMatch(t))) ||
        (m != null && (m is! String || !_hex32.hasMatch(m)))) {
      return null;
    }
    return AlarmWave(
      id: id,
      at: at,
      ended: end == true,
      token: t is String ? t : '',
      mac: m is String ? m : '',
    );
  }

  /// Dated close enough to [now] (the receiver's clock).
  bool isFreshAt(int now) =>
      (now - at).abs() <= kAlarmWaveFreshFor.inMilliseconds;

  /// Whether the friend who gave this phone [stored] (their per-friend
  /// keys, [FriendNearbyKey]) made this very wave.
  bool verify(String stored) {
    if (!signed) {
      return false;
    }
    final FriendNearbyKey? key = FriendNearbyKey.parse(stored);
    if (key == null) {
      return false;
    }
    if (token != nearbyPairId(key.pair, nearbySlot(at))) {
      return false;
    }
    final String expected = _pairMac(
      key.pair,
      id: id,
      at: at,
      ended: ended,
      token: token,
    );
    // Same length (both 32 hex): compare every character.
    int diff = 0;
    for (int i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ mac.codeUnitAt(i);
    }
    return diff == 0;
  }
}

String _pairMac(
  List<int> pairKey, {
  required String id,
  required int at,
  required bool ended,
  required String token,
}) => nearbyHex(
  _hmac(
    pairKey,
    'zen-nearby-alarm|$kAlarmWaveVersion|$id|$at|${ended ? 1 : 0}|$token',
  ).sublist(0, 16),
);

// ---- per-friend keys ----
//
// Each person keeps a private nearby key ([NearbyOwnKeys]) that never
// leaves the phone. From it come:
//  - a mask key, given to every friend: it only unmasks the token shown in
//    a slot (and its short hint), so friends can link the slots, strangers
//    cannot;
//  - a one-way hash chain per 30 days: the token of a slot is the chain
//    value of that slot, masked. A friend checks it by hashing it forward to
//    the anchor this person gave them, but cannot make the value of a slot
//    that has not been shown yet (each value is the hash of the next one) —
//    so a friend can no longer show "this person is here" to others;
//  - a pair key per friend, which signs alarm waves only that friend can
//    check and nobody else can make ([kAlarmWaveVersion]).
// The token changes every [kNearbySlot], shorter than Android's 15-minute
// address rotation: advertising restarts with each new token (and a new
// address), so the address does not change in the middle of a token and
// two addresses are never linked by one token.

/// How long one token lives (and one Bluetooth address with it).
const Duration kNearbySlot = Duration(minutes: 10);

int nearbySlot(int millis) => millis ~/ kNearbySlot.inMilliseconds;

/// Slots per hash chain (30 days); a friend holds the anchors of the
/// current and the next chain, renewed through the hello digest.
const int kNearbyChainSlots = 4320;

int nearbyChainOf(int slot) => slot ~/ kNearbyChainSlots;

/// What a stored friend's key starts with.
const String kNearbyKeyPrefix = 'z2.';

/// Longest stored per-friend key taken from a friend.
const int kNearbyKeyMaxLength = 1024;

/// Prefix of a pair key handed to the native alarm-wave check.
const String kNearbyPairKeyPrefix = 'p:';

/// Bytes of the hint shown after the token (a quick filter for friends).
const int kNearbyHintLength = 4;

/// Bytes the radio shows in one slot: the token, then the hint.
const int kNearbyAdvertBytes = 16 + kNearbyHintLength;

List<int> _hmac(List<int> key, String text) =>
    crypto.Hmac(crypto.sha256, key).convert(utf8.encode(text)).bytes;

const List<int> _chainTag = <int>[0x7a, 0x6e, 0x63]; // "znc"

List<int> _chainStep(List<int> x) =>
    crypto.sha256.convert(<int>[..._chainTag, ...x]).bytes.sublist(0, 16);

List<int> _chainHash(List<int> x, int times) {
  List<int> v = x;
  for (int i = 0; i < times; i++) {
    v = _chainStep(v);
  }
  return v;
}

List<int> _unhex(String hex) => <int>[
  for (int i = 0; i + 1 < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

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

/// The mask over a token in [slot] (from a person's mask key).
List<int> nearbyMask(List<int> maskKey, int slot) =>
    _hmac(maskKey, 'zen-nearby-mask|$slot').sublist(0, 16);

/// The short hint shown after the token in [slot].
List<int> nearbyHint(List<int> maskKey, int slot) =>
    _hmac(maskKey, 'zen-nearby-hint|$slot').sublist(0, kNearbyHintLength);

/// The id (hex) of a pair of friends in [slot]: carried by their alarm
/// waves, so the receiver knows which pair key to check.
String nearbyPairId(List<int> pairKey, int slot) =>
    nearbyHex(_hmac(pairKey, 'zen-nearby-pair-id|$slot').sublist(0, 16));

/// A new private nearby key (base64url), never given to anyone.
String newNearbyPrivateKey(Random random) =>
    base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));

/// This person's keys, from the private nearby key.
final class NearbyOwnKeys {
  /// Throws [FormatException] for a damaged key.
  NearbyOwnKeys(String private)
    : _key = base64Url.decode(base64Url.normalize(private)) {
    if (_key.length < 16) {
      throw const FormatException('nearby key too short');
    }
  }

  final List<int> _key;

  /// Given to every friend: it unmasks tokens, it cannot make them.
  late final List<int> maskKey = _hmac(_key, 'zen-nearby-mask-key');

  /// Anchors already worked out (4321 hashes each), per private key.
  static final Map<String, List<int>> _anchors = <String, List<int>>{};

  /// The key this phone signs alarm waves with for [friend] (a normalised
  /// address); only that friend gets it.
  List<int> pairKey(String friend) => _hmac(_key, 'zen-nearby-pair|$friend');

  List<int> _seed(int chain) =>
      _hmac(_key, 'zen-nearby-chain|$chain').sublist(0, 16);

  /// The end of [chain] that friends check tokens against.
  List<int> anchor(int chain) {
    final String cacheKey = '${nearbyHex(_key)}|$chain';
    final List<int>? had = _anchors[cacheKey];
    if (had != null) {
      return had;
    }
    final List<int> made = _chainHash(_seed(chain), kNearbyChainSlots + 1);
    if (_anchors.length >= 32) {
      _anchors.remove(_anchors.keys.first);
    }
    return _anchors[cacheKey] = made;
  }

  /// The chain value of [slot] (unmasked token): [anchor] after
  /// `slot % kNearbyChainSlots + 1` more hashes.
  List<int> chainValue(int slot) => _chainHash(
    _seed(nearbyChainOf(slot)),
    kNearbyChainSlots - slot % kNearbyChainSlots,
  );

  /// The token shown in [slot] (16 bytes).
  Uint8List token(int slot) {
    final List<int> c = chainValue(slot);
    final List<int> m = nearbyMask(maskKey, slot);
    return Uint8List.fromList(<int>[for (int i = 0; i < 16; i++) c[i] ^ m[i]]);
  }

  /// What the radio shows in [slot]: the token, then the hint.
  Uint8List advert(int slot) =>
      Uint8List.fromList(<int>[...token(slot), ...nearbyHint(maskKey, slot)]);

  /// [advert] of each of [count] slots from [firstSlot] on, one after
  /// another ([kNearbyAdvertBytes] each). Each chain is hashed once from its
  /// seed to the last slot needed and then walked back one hash per slot
  /// (the value of a slot is the hash of the next one's), so a week costs a
  /// few thousand hashes, not a few million.
  Uint8List adverts(int firstSlot, int count) {
    final Uint8List out = Uint8List(max(0, count) * kNearbyAdvertBytes);
    int slot = firstSlot + count - 1;
    while (count > 0 && slot >= firstSlot) {
      final int chain = nearbyChainOf(slot);
      final int from = max(firstSlot, chain * kNearbyChainSlots);
      List<int> value = chainValue(slot);
      for (int s = slot; s >= from; s--) {
        if (s != slot) {
          value = _chainStep(value);
        }
        final List<int> mask = nearbyMask(maskKey, s);
        final int at = (s - firstSlot) * kNearbyAdvertBytes;
        for (int i = 0; i < 16; i++) {
          out[at + i] = value[i] ^ mask[i];
        }
        out.setRange(at + 16, at + kNearbyAdvertBytes, nearbyHint(maskKey, s));
      }
      slot = from - 1;
    }
    return out;
  }

  /// What [friend] (a normalised address) gets at [now]: the mask key, their
  /// pair key and the anchors of the current and the next chain. Stored as
  /// is by the friend ([FriendNearbyKey.parse]); it changes when a chain
  /// does, and the hello digest then asks for it again.
  String materialFor(String friend, int now) {
    final int chain = nearbyChainOf(nearbySlot(now));
    final String json = jsonEncode(<String, dynamic>{
      'v': 2,
      'h': base64Url.encode(maskKey),
      'p': base64Url.encode(pairKey(friend)),
      'a': <String, String>{
        '$chain': nearbyHex(anchor(chain)),
        '${chain + 1}': nearbyHex(anchor(chain + 1)),
      },
    });
    return '$kNearbyKeyPrefix${base64Url.encode(utf8.encode(json))}';
  }
}

/// What a friend gave this phone: per-friend keys
/// ([NearbyOwnKeys.materialFor]).
@immutable
final class FriendNearbyKey {
  const FriendNearbyKey._({
    required this.mask,
    required this.pair,
    required this.anchors,
  });

  final List<int> mask;

  /// The key the friend signs alarm waves to this phone with.
  final List<int> pair;

  /// Chain → anchor.
  final Map<int, List<int>> anchors;

  /// The key handed to the native alarm-wave check.
  String get radioKey => '$kNearbyPairKeyPrefix${base64Url.encode(pair)}';

  /// [stored] read, or `null` when it is not a friend's keys.
  static FriendNearbyKey? parse(String? stored) {
    if (stored == null ||
        stored.isEmpty ||
        !stored.startsWith(kNearbyKeyPrefix) ||
        stored.length > kNearbyKeyMaxLength) {
      return null;
    }
    try {
      final Object? json = jsonDecode(
        utf8.decode(
          base64Url.decode(
            base64Url.normalize(stored.substring(kNearbyKeyPrefix.length)),
          ),
        ),
      );
      if (json is! Map || json['v'] != 2) {
        return null;
      }
      final Object? h = json['h'];
      final Object? p = json['p'];
      final Object? a = json['a'];
      if (h is! String || p is! String || a is! Map || a.length > 4) {
        return null;
      }
      final List<int> mask = base64Url.decode(base64Url.normalize(h));
      final List<int> pair = base64Url.decode(base64Url.normalize(p));
      if (mask.length != 32 || pair.length != 32) {
        return null;
      }
      final Map<int, List<int>> anchors = <int, List<int>>{};
      for (final MapEntry<dynamic, dynamic> e in a.entries) {
        final Object? k = e.key;
        final Object? v = e.value;
        final int? chain = k is String ? int.tryParse(k) : null;
        if (chain == null || v is! String || !_hex32.hasMatch(v)) {
          return null;
        }
        anchors[chain] = _unhex(v);
      }
      return FriendNearbyKey._(mask: mask, pair: pair, anchors: anchors);
    } on FormatException {
      return null;
    }
  }

  /// The chain value behind [token] (16 bytes) shown in [slot], when it is
  /// really this friend's; else `null`. [last]: a value of this friend
  /// checked before (its slot and value), which makes the check short.
  List<int>? open(List<int> token, int slot, {(int, List<int>)? last}) {
    if (token.length != 16 || slot < 0) {
      return null;
    }
    final List<int> mk = nearbyMask(mask, slot);
    final List<int> c = <int>[for (int i = 0; i < 16; i++) token[i] ^ mk[i]];
    final int chain = nearbyChainOf(slot);
    if (last != null &&
        nearbyChainOf(last.$1) == chain &&
        last.$1 <= slot &&
        _sameBytes(_chainHash(c, slot - last.$1), last.$2)) {
      return c;
    }
    final List<int>? anchor = anchors[chain];
    if (anchor == null) {
      return null;
    }
    final int steps = slot % kNearbyChainSlots + 1;
    return _sameBytes(_chainHash(c, steps), anchor) ? c : null;
  }
}

// ---- longer waves in parts ----
//
// A hello and its answer carry a hybrid post-quantum key exchange
// (ML-KEM-768 + X25519, hybrid_kem.dart): the hello's one-time public key
// (1216 bytes) and the answer's ciphertext (1120 bytes) do not fit one
// Bluetooth write, so each goes as a few parts before the message that
// names it by hash. Parts are JSON like every wave, each well under one
// write.

/// Version of a part of a longer piece.
const int kNearbyPartVersion = 11;

/// Base64 characters of data in one part: with the frame around it a part
/// stays under 500 bytes.
const int kNearbyPartChars = 400;

/// Parts of one piece at most (a hybrid key takes 5).
const int kNearbyMaxParts = 6;

/// Pieces being put together, and finished ones not yet taken, at most.
const int kNearbyMaxPieces = 16;

/// How long parts wait for the rest.
const Duration kNearbyPieceLife = Duration(minutes: 2);

/// The id of a piece (base64url of 16 bytes of its SHA-256): the message
/// that uses it names it, so parts of another piece cannot take its place.
String nearbyPieceId(List<int> bytes) =>
    base64Url.encode(crypto.sha256.convert(bytes).bytes.sublist(0, 16));

/// [bytes] as parts of conversation [sid]; [what] says which piece it is
/// (`h`: the hello's key, `r`: the answer's ciphertext).
List<Map<String, dynamic>> nearbyParts(
  String sid,
  String what,
  List<int> bytes,
) {
  final String data = base64Url.encode(bytes);
  final String id = nearbyPieceId(bytes);
  final int count = (data.length + kNearbyPartChars - 1) ~/ kNearbyPartChars;
  return <Map<String, dynamic>>[
    for (int i = 0; i < count; i++)
      <String, dynamic>{
        'v': kNearbyPartVersion,
        'sid': sid,
        'w': what,
        'h': id,
        'i': i,
        'k': count,
        'd': data.substring(
          i * kNearbyPartChars,
          min((i + 1) * kNearbyPartChars, data.length),
        ),
      },
  ];
}

final RegExp _pieceChars = RegExp(r'^[A-Za-z0-9_=-]+$');

/// Parts heard over Bluetooth, put together into pieces. Bounded: a phone
/// nearby can fill it, but only up to [kNearbyMaxPieces] small pieces that
/// go after [kNearbyPieceLife].
final class NearbyPieces {
  final Map<String, ({int at, int count, Map<int, String> parts})> _open =
      <String, ({int at, int count, Map<int, String> parts})>{};
  final Map<String, ({int at, Uint8List bytes})> _done =
      <String, ({int at, Uint8List bytes})>{};

  static String _key(String sid, String what, String id) => '$sid|$what|$id';

  void _expire(int now) {
    _open.removeWhere(
      (String _, ({int at, int count, Map<int, String> parts}) p) =>
          now - p.at > kNearbyPieceLife.inMilliseconds,
    );
    _done.removeWhere(
      (String _, ({int at, Uint8List bytes}) p) =>
          now - p.at > kNearbyPieceLife.inMilliseconds,
    );
  }

  /// Takes part [json] heard at [now]. Returns `(sid, what)` when it
  /// finished a piece (whose bytes hash to its id), else `null`.
  (String, String)? add(Map<dynamic, dynamic> json, int now) {
    final Object? sid = json['sid'];
    final Object? what = json['w'];
    final Object? id = json['h'];
    final Object? i = json['i'];
    final Object? k = json['k'];
    final Object? d = json['d'];
    if (json['v'] != kNearbyPartVersion ||
        sid is! String ||
        !kAlarmIdPattern.hasMatch(sid) ||
        (what != 'h' && what != 'r') ||
        id is! String ||
        id.length != 24 ||
        k is! int ||
        k < 1 ||
        k > kNearbyMaxParts ||
        i is! int ||
        i < 0 ||
        i >= k ||
        d is! String ||
        d.isEmpty ||
        d.length > kNearbyPartChars ||
        !_pieceChars.hasMatch(d)) {
      return null;
    }
    _expire(now);
    final String key = _key(sid, what as String, id);
    if (_done.containsKey(key)) {
      return null;
    }
    ({int at, int count, Map<int, String> parts})? piece = _open[key];
    if (piece == null) {
      while (_open.length >= kNearbyMaxPieces) {
        _open.remove(_open.keys.first);
      }
      piece = _open[key] = (at: now, count: k, parts: <int, String>{});
    }
    if (piece.count != k) {
      return null;
    }
    piece.parts.putIfAbsent(i, () => d);
    if (piece.parts.length < k) {
      return null;
    }
    _open.remove(key);
    final Uint8List bytes;
    try {
      bytes = base64Url.decode(
        <String>[for (int x = 0; x < k; x++) piece.parts[x]!].join(),
      );
    } on FormatException {
      return null;
    }
    if (nearbyPieceId(bytes) != id) {
      return null;
    }
    while (_done.length >= kNearbyMaxPieces) {
      _done.remove(_done.keys.first);
    }
    _done[key] = (at: now, bytes: bytes);
    return (sid, what);
  }

  /// The finished piece [id] of conversation [sid] (taken once), or `null`.
  Uint8List? take(String sid, String what, String id, int now) {
    _expire(now);
    return _done.remove(_key(sid, what, id))?.bytes;
  }
}
