import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

// Secrets for direct links nearby: friends' devices and the
// account's own devices on the same Wi-Fi, in a Wi-Fi Direct group or over
// Bluetooth connect directly, also without internet
// (native/yggdrasil_bridge/local_link.go).
//
// Every pair of devices shares one secret, made on both sides from the two
// devices' static keys (the ledger device keys: X25519 of their Ed25519
// keys, then HKDF with both public keys). The bridge only uses it to make
// adverts that the other device alone can recognise and to prove the pair
// in the link handshake: strangers on the network learn nothing about who
// is there, and cannot link. The link's own keys mix in a one-time
// ML-KEM-768 exchange (local_link_handshake.go), so a recorded link stays
// unreadable to a quantum computer; the pair secret itself stays classical
// (X25519): with both devices' public keys and a quantum computer one could
// recognise their adverts or sit in the middle of a new link.

/// HKDF label of a pair's secret.
const String kLocalLinkHkdfInfo = 'zen.local.v1';

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
  LocalLinkSecrets(this.deviceKey);

  /// This device's ledger key.
  final LedgerKeyPair deviceKey;
  Future<SimpleKeyPair>? _x25519;
  final Map<String, String?> _byDevice = <String, String?>{};

  /// The secret with the device whose ledger key is [devicePublicKey], or
  /// `null` for a key no secret can be made with.
  Future<String?> secretWith(Uint8List devicePublicKey) async {
    final String id = b64(devicePublicKey);
    if (_byDevice.containsKey(id)) {
      return _byDevice[id];
    }
    final String? secret = await _derive(devicePublicKey);
    _byDevice[id] = secret;
    return secret;
  }

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
