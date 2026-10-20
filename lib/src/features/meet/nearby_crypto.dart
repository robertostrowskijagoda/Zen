import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

/// [bytes] as lowercase hex.
String nearbyHex(List<int> bytes) =>
    bytes.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Bluetooth wave version of an alarm told to phones nearby (§16.3).
///
/// Built unsigned for everyone, and signed with the key of one pair of
/// friends ([FriendNearbyKey.pair]) for a friend: only that friend can
/// check it, and no other friend can make it (S6). `t` is the pair's id
/// for the wave's slot ([nearbyPairId]).
const int kAlarmWaveVersion = 6;

/// A wave dated further than this from the receiver's clock (either way)
/// is dropped: a recorded wave cannot be played back later.
const Duration kAlarmWaveFreshFor = Duration(minutes: 10);

/// What an alarm id may look like (the app makes base36 ids).
final RegExp kAlarmIdPattern = RegExp(r'^[0-9A-Za-z_-]{1,40}$');

final RegExp _hex32 = RegExp(r'^[0-9a-f]{32}$');

/// An alarm wave heard over Bluetooth (§16.3).
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

// ---- per-friend keys (S6) ----
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
