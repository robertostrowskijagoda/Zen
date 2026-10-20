import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/settings/app_settings.dart';

String _hex(List<int> bytes) =>
    bytes.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List _seed(int start) =>
    Uint8List.fromList(List<int>.generate(32, (int i) => (start + i) & 0xff));

void main() {
  test('friends on the same Wi-Fi are on by default, Wi-Fi Direct off', () {
    const AppSettings defaults = AppSettings();
    expect(defaults.lanDiscovery, isNull);
    expect(defaults.lanDiscoveryOn, isTrue);
    expect(defaults.wifiDirect, isFalse);
    expect(defaults.toJson().containsKey('lanDiscovery'), isFalse);

    final AppSettings chosen = AppSettings.fromJson(
      defaults.copyWith(lanDiscovery: false, wifiDirect: true).toJson(),
    );
    expect(chosen.lanDiscoveryOn, isFalse);
    expect(chosen.wifiDirect, isTrue);
  });

  test('an Ed25519 key converts to the X25519 key of the same seed', () async {
    // Checked against an independent implementation.
    final LedgerKeyPair key = await LedgerKeyPair.fromSeed(_seed(0));
    expect(
      _hex(key.publicKey),
      '03a107bff3ce10be1d70dd18e74bc09967e4d6309ba50d5f1ddc8664125531b8',
    );
    expect(
      _hex(ed25519PublicKeyToX25519(key.publicKey)!),
      '4701d08488451f545a409fb58ae3e58581ca40ac3f7f114698cd71deac73ca01',
    );
    final SimplePublicKey x = await (await ed25519SeedToX25519(
      key.seed,
    )).extractPublicKey();
    expect(x.bytes, ed25519PublicKeyToX25519(key.publicKey));

    expect(ed25519PublicKeyToX25519(Uint8List(31)), isNull);
    // y = 1 is the neutral point: no X25519 key.
    expect(ed25519PublicKeyToX25519(Uint8List(32)..[0] = 1), isNull);
  });

  test('both devices of a pair make the same secret, others another', () async {
    final LedgerKeyPair a = await LedgerKeyPair.fromSeed(_seed(1));
    final LedgerKeyPair b = await LedgerKeyPair.fromSeed(_seed(2));
    final LedgerKeyPair c = await LedgerKeyPair.fromSeed(_seed(3));
    final String? ab = await LocalLinkSecrets(a).secretWith(b.publicKey);
    final String? ba = await LocalLinkSecrets(b).secretWith(a.publicKey);
    final String? ac = await LocalLinkSecrets(a).secretWith(c.publicKey);

    expect(ab, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(ba, ab);
    expect(ac, isNot(ab));
    expect(await LocalLinkSecrets(a).secretWith(a.publicKey), isNull);
  });

  test('peers: devices with an address, own ones marked', () async {
    final LedgerKeyPair me = await LedgerKeyPair.fromSeed(_seed(4));
    final LedgerKeyPair friend = await LedgerKeyPair.fromSeed(_seed(5));
    final LedgerKeyPair sibling = await LedgerKeyPair.fromSeed(_seed(6));
    final LocalLinkSecrets secrets = LocalLinkSecrets(me);

    final List<LocalLinkPeer> peers = await secrets.peersFor(<AccountDevice>[
      AccountDevice(
        account: 'friend-account',
        device: b64(friend.publicKey),
        name: 'Kasia',
        address: '200:1::1',
      ),
      AccountDevice(
        account: 'my-account',
        device: b64(sibling.publicKey),
        name: 'Laptop',
        address: '200:2::1',
      ),
      // No address yet: nothing to link with.
      AccountDevice(
        account: 'friend-account',
        device: b64(sibling.publicKey),
        name: 'Tablet',
      ),
      // Not a key.
      const AccountDevice(
        account: 'friend-account',
        device: 'nope',
        name: 'Broken',
        address: '200:3::1',
      ),
    ], account: 'my-account');

    expect(peers.map((LocalLinkPeer p) => p.address), <String>[
      '200:1::1',
      '200:2::1',
    ]);
    expect(peers.map((LocalLinkPeer p) => p.own), <bool>[false, true]);
    expect(peers.first.secretHex, await secrets.secretWith(friend.publicKey));
  });

  test('the bridge gets the setting and the devices', () {
    final Map<String, dynamic> json =
        jsonDecode(
              localLinksSettingsJson(
                lan: true,
                beaconSeconds: 10,
                peers: const <LocalLinkPeer>[
                  LocalLinkPeer(address: '200::1', secretHex: 'ab', own: true),
                ],
              ),
            )
            as Map<String, dynamic>;
    expect(json, <String, dynamic>{
      'Lan': true,
      'BeaconSeconds': 10,
      'Peers': <dynamic>[
        <String, dynamic>{'Address': '200::1', 'Secret': 'ab', 'Own': true},
      ],
    });
  });
}
