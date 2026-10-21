import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

// Secrets for direct links nearby: friends' devices and the
// account's own devices on the same Wi-Fi, in a Wi-Fi Direct group or over
// Bluetooth connect directly, also without internet
// (native/yggdrasil_bridge/local_link.go).
//
// Every pair of devices shares one secret. The bridge only uses it to make
// adverts that the other device alone can recognise and to prove the pair
// in the link handshake: strangers on the network learn nothing about who
// is there, and cannot link. The link's own keys mix in a one-time
// ML-KEM-768 exchange (local_link_handshake.go), so a recorded link stays
// unreadable to a quantum computer.
//
// The secret is post-quantum once the two devices have paired
// ([LocalPairKeys]): each sends the other a random contribution in a
// `local_pair` signal, which the session layer seals with ML-KEM-768 +
// X25519 and authenticates by the sender's device key (pq_session.go), and
// the secret mixes both contributions in. Until then (two devices that never
// reached each other over the network, e.g. met only offline) it comes from
// the devices' static keys alone (X25519 of their Ed25519 ledger keys, HKDF
// with both public keys): with both public keys a quantum computer could
// recognise such a pair's adverts or sit in the middle of a new link.

/// HKDF label of a pair's secret from the static keys.
const String kLocalLinkHkdfInfo = 'zen.local.v1';

/// HKDF label of a pair's secret with both pairing contributions.
const String kLocalLinkPqHkdfInfo = 'zen.local.pq.v1';

/// Signal of the post-quantum pairing of two devices' local links.
const String kLocalPairType = 'local_pair';

/// Beacon intervals the bridge uses on local networks: often while the app
/// is used, rarely otherwise (battery).
const int kLocalLinkActiveBeaconSeconds = 10;
const int kLocalLinkIdleBeaconSeconds = 30;

final BigInt _fieldPrime = (BigInt.one << 255) - BigInt.from(19);

/// The X25519 (Montgomery) form of an Ed25519 public key, or `null` for
/// one that is not a valid point encoding.
Uint8List? ed25519PublicKeyToX25519(List<int> edPublic) {
  if (edPublic.length != 32) {
    return null;
  }
  BigInt y = BigInt.zero;
  for (int i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(i == 31 ? edPublic[i] & 0x7f : edPublic[i]);
  }
  if (y >= _fieldPrime) {
    return null;
  }
  final BigInt denominator = (BigInt.one - y) % _fieldPrime;
  if (denominator == BigInt.zero) {
    return null;
  }
  BigInt u =
      ((BigInt.one + y) * denominator.modInverse(_fieldPrime)) % _fieldPrime;
  final Uint8List out = Uint8List(32);
  final BigInt byteMask = BigInt.from(0xff);
  for (int i = 0; i < 32; i++) {
    out[i] = (u & byteMask).toInt();
    u = u >> 8;
  }
  return out;
}

/// The X25519 key pair of an Ed25519 seed (the scalar Ed25519 signs with).
Future<SimpleKeyPair> ed25519SeedToX25519(List<int> seed) async {
  final Hash digest = await Sha512().hash(seed);
  return X25519().newKeyPairFromSeed(digest.bytes.sublist(0, 32));
}

/// A device this one may link with directly, with their pair's secret.
@immutable
final class LocalLinkPeer {
  const LocalLinkPeer({
    required this.address,
    required this.secretHex,
    required this.own,
  });

  /// Its mesh address (its Yggdrasil key must match it).
  final String address;
  final String secretHex;

  /// One of this account's own devices (else a friend's).
  final bool own;

  Map<String, Object> toJson() => <String, Object>{
    'Address': address,
    'Secret': secretHex,
    'Own': own,
  };
}

/// The settings the bridge reads (YggSetLocalLinksJson).
String localLinksSettingsJson({
  required bool lan,
  required int beaconSeconds,
  required List<LocalLinkPeer> peers,
}) => jsonEncode(<String, Object>{
  'Lan': lan,
  'BeaconSeconds': beaconSeconds,
  'Peers': <Map<String, Object>>[
    for (final LocalLinkPeer peer in peers) peer.toJson(),
  ],
});

String _hex(List<int> bytes) =>
    bytes.map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();

/// Makes (and remembers) the pair secrets of this device with others.
final class LocalLinkSecrets {
  LocalLinkSecrets(this.deviceKey, {this.pairs});

  /// This device's ledger key.
  final LedgerKeyPair deviceKey;

  /// The post-quantum pairings with other devices ([LocalPairKeys]); none:
  /// the static keys only.
  final LocalPairKeys? pairs;
  Future<SimpleKeyPair>? _x25519;
  final Map<String, String?> _byDevice = <String, String?>{};

  /// The secret with the device whose ledger key is [devicePublicKey], or
  /// `null` for a key no secret can be made with: post-quantum once the two
  /// devices paired ([LocalPairKeys.pairSecret]).
  Future<String?> secretWith(Uint8List devicePublicKey) async {
    final String id = b64(devicePublicKey);
    final String? base = _byDevice.containsKey(id)
        ? _byDevice[id]
        : (_byDevice[id] = await _derive(devicePublicKey));
    final Uint8List? paired = pairs?.pairSecret(id);
    if (base == null || paired == null) {
      return base;
    }
    final SecretKey secret = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: SecretKey(<int>[..._unhex(base), ...paired]),
          nonce: utf8.encode(
            id.compareTo(b64(deviceKey.publicKey)) < 0
                ? '$id|${b64(deviceKey.publicKey)}'
                : '${b64(deviceKey.publicKey)}|$id',
          ),
          info: utf8.encode(kLocalLinkPqHkdfInfo),
        );
    return _hex(await secret.extractBytes());
  }

  static List<int> _unhex(String hex) => <int>[
    for (int i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];

  Future<String?> _derive(Uint8List theirs) async {
    final Uint8List? theirX = ed25519PublicKeyToX25519(theirs);
    if (theirX == null || listEquals(theirs, deviceKey.publicKey)) {
      return null;
    }
    final SimpleKeyPair mine = await (_x25519 ??= ed25519SeedToX25519(
      deviceKey.seed,
    ));
    final SecretKey shared = await X25519().sharedSecretKey(
      keyPair: mine,
      remotePublicKey: SimplePublicKey(theirX, type: KeyPairType.x25519),
    );
    final List<int> sharedBytes = await shared.extractBytes();
    if (sharedBytes.every((int b) => b == 0)) {
      return null;
    }
    // Both public keys, in the same order on both sides.
    final Uint8List ours = deviceKey.publicKey;
    final bool oursFirst = _compare(ours, theirs) < 0;
    final SecretKey secret = await Hkdf(hmac: Hmac.sha256(), outputLength: 32)
        .deriveKey(
          secretKey: SecretKey(sharedBytes),
          nonce: <int>[
            ...(oursFirst ? ours : theirs),
            ...(oursFirst ? theirs : ours),
          ],
          info: utf8.encode(kLocalLinkHkdfInfo),
        );
    return _hex(await secret.extractBytes());
  }

  static int _compare(List<int> a, List<int> b) {
    for (int i = 0; i < a.length && i < b.length; i++) {
      if (a[i] != b[i]) {
        return a[i] - b[i];
      }
    }
    return a.length - b.length;
  }

  /// The peers for [devices] (own devices of [account] and friends'
  /// devices) that have a mesh address and a usable key.
  Future<List<LocalLinkPeer>> peersFor(
    Iterable<AccountDevice> devices, {
    required String account,
  }) async {
    final List<LocalLinkPeer> out = <LocalLinkPeer>[];
    final Set<String> seen = <String>{};
    for (final AccountDevice device in devices) {
      final String? address = device.address;
      final Uint8List? key = unb64(device.device, length: 32);
      if (address == null || address.isEmpty || key == null) {
        continue;
      }
      if (!seen.add(address)) {
        continue;
      }
      await pairs?.offer(b64(key), address);
      final String? secret = await secretWith(key);
      if (secret != null) {
        out.add(
          LocalLinkPeer(
            address: address,
            secretHex: secret,
            own: device.account == account,
          ),
        );
      }
    }
    return out;
  }
}

/// One device's pairing with another: the random contribution this
/// device gave it, the one it gave this device, and whether the other one
/// confirmed holding this one's ([LocalPairKeys]).
final class _Pair {
  _Pair({required this.mine, this.theirs, this.confirmed = false});

  final Uint8List mine;
  Uint8List? theirs;
  bool confirmed;

  Map<String, Object> toJson() => <String, Object>{
    'm': b64(mine),
    if (theirs != null) 't': b64(theirs!),
    'c': confirmed,
  };

  static _Pair? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Uint8List? mine = unb64(json['m'], length: 32);
    if (mine == null) {
      return null;
    }
    final Uint8List? theirs = unb64(json['t'], length: 32);
    return _Pair(
      mine: mine,
      theirs: theirs,
      confirmed: theirs != null && json['c'] == true,
    );
  }
}

/// The post-quantum pairing of this device's local links with other
/// devices (its own and friends').
///
/// Each device gives the other a random 32-byte contribution in a
/// [kLocalPairType] signal, `{d: sender's device key, to: receiver's,
/// c: contribution, h: hash of the receiver's contribution as the sender
/// holds it}`. Signals are sealed by the session layer with ML-KEM-768 +
/// X25519 and authenticated by the sender's device key, and a contribution
/// is taken only from the address the ledger has for that device. A device
/// answers when the other does not hold its current contribution yet, or
/// when it learnt a new one; the pair counts once each side saw the other
/// hold its contribution (a new install starts again with a new one). The
/// pair's secret then mixes both in ([pairSecret], [LocalLinkSecrets]).
final class LocalPairKeys {
  LocalPairKeys({
    required this.disk,
    required this.ownDevice,
    required this.send,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  /// Where the pairings are kept (the ledger's encrypted store).
  final LedgerDisk disk;

  /// This device's ledger key (id).
  final String ownDevice;

  /// Sends a signal to a mesh address.
  final Future<void> Function(String to, Map<String, dynamic> payload) send;

  final int Function() _now;
  final Random _random;

  /// Called when a pair's secret changed (the bridge gets the peers again).
  void Function()? onChanged;

  static const String diskKey = 'runtime/local-pairs';

  /// How often an unconfirmed pairing is offered again to one device.
  static const int resendMs = 10 * 60 * 1000;

  final Map<String, _Pair> _pairs = <String, _Pair>{};
  final Map<String, int> _offeredAt = <String, int>{};
  bool _loaded = false;

  Future<void> _load() async {
    if (_loaded) {
      return;
    }
    _loaded = true;
    try {
      final Uint8List? raw = await disk.read(diskKey);
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        for (final MapEntry<dynamic, dynamic> e in json.entries) {
          final _Pair? pair = _Pair.fromJson(e.value);
          if (e.key is String && pair != null) {
            _pairs[e.key as String] = pair;
          }
        }
      }
    } on Object catch (error) {
      logZenWarning('Local link pairings unreadable: $error');
    }
  }

  Future<void> _save() async {
    await disk.write(
      diskKey,
      Uint8List.fromList(
        utf8.encode(
          jsonEncode(<String, Object>{
            for (final MapEntry<String, _Pair> e in _pairs.entries)
              e.key: e.value.toJson(),
          }),
        ),
      ),
    );
  }

  static String _hash(List<int> contribution) => b64(
    crypto.sha256
        .convert(<int>[...utf8.encode('zen.local.pair|'), ...contribution])
        .bytes
        .sublist(0, 16),
  );

  Uint8List _fresh() =>
      Uint8List.fromList(List<int>.generate(32, (_) => _random.nextInt(256)));

  /// The secret both contributions make with [device] (its key id), once
  /// the pair counts; `null` before.
  Uint8List? pairSecret(String device) {
    final _Pair? pair = _pairs[device];
    final Uint8List? theirs = pair?.theirs;
    if (pair == null || theirs == null || !pair.confirmed) {
      return null;
    }
    final bool mineFirst = ownDevice.compareTo(device) < 0;
    return Uint8List.fromList(
      crypto.sha256.convert(<int>[
        ...utf8.encode('zen.local.pair.secret|'),
        ...(mineFirst ? pair.mine : theirs),
        ...(mineFirst ? theirs : pair.mine),
      ]).bytes,
    );
  }

  /// Whether the pair with [device] counts (tests, the settings page).
  bool paired(String device) => pairSecret(device) != null;

  Future<void> _sendTo(String device, String address) async {
    final _Pair pair = _pairs[device]!;
    final Uint8List? theirs = pair.theirs;
    _offeredAt[device] = _now();
    try {
      await send(address, <String, dynamic>{
        'type': kLocalPairType,
        'd': ownDevice,
        'to': device,
        'c': b64(pair.mine),
        'h': theirs == null ? '' : _hash(theirs),
      });
    } on Object catch (error) {
      logZenWarning('Local link pairing to $address: $error');
    }
  }

  /// Offers the pairing to [device] at [address] while it does not count
  /// yet (at most every [resendMs]).
  Future<void> offer(String device, String address) async {
    await _load();
    if (device == ownDevice || paired(device)) {
      return;
    }
    if (_now() - (_offeredAt[device] ?? -resendMs) < resendMs) {
      return;
    }
    if (!_pairs.containsKey(device)) {
      _pairs[device] = _Pair(mine: _fresh());
      await _save();
    }
    await _sendTo(device, address);
  }

  /// A [kLocalPairType] signal; [deviceAt] names the device the ledger has
  /// at an address (`null`: none this device links with).
  Future<void> onFrame(
    SignalTransportFrame frame, {
    required String? Function(String address) deviceAt,
  }) async {
    final Map<String, dynamic> p = frame.payload;
    final Object? from = p['d'];
    final Object? to = p['to'];
    final Uint8List? contribution = unb64(p['c'], length: 32);
    final Object? hash = p['h'];
    if (p['type'] != kLocalPairType ||
        frame.door ||
        from is! String ||
        to != ownDevice ||
        from == ownDevice ||
        contribution == null ||
        hash is! String ||
        deviceAt(frame.from) != from) {
      return;
    }
    await _load();
    final bool wasPaired = paired(from);
    final _Pair pair = _pairs[from] ??= _Pair(mine: _fresh());
    final bool learnt =
        pair.theirs == null || !listEquals(pair.theirs, contribution);
    if (learnt) {
      pair
        ..theirs = contribution
        ..confirmed = false;
    }
    final bool holdsMine = hash == _hash(pair.mine);
    if (holdsMine && !pair.confirmed) {
      pair.confirmed = true;
    }
    await _save();
    if (!holdsMine || learnt) {
      await _sendTo(from, frame.from);
    }
    if (paired(from) != wasPaired) {
      onChanged?.call();
    }
  }
}

/// Android delivers broadcasts and multicast on Wi-Fi reliably only to apps
/// holding a `WifiManager.MulticastLock` (ZenMulticastLock.kt). It costs
/// battery, so it is held only while the LAN is on and the app is used.
abstract final class AndroidMulticastLock {
  static const MethodChannel _channel = MethodChannel('zen/multicast');

  static Future<void> setHeld(bool held) async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<bool>('setHeld', <String, Object>{
        'held': held,
      });
    } on Object catch (error) {
      logZenWarning('Multicast lock (held: $held) failed: $error');
    }
  }
}
