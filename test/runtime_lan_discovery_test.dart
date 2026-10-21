import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_lan_discovery.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
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

  test('two devices pair over the sealed signals: the secret becomes '
      'post-quantum on both sides, a new install pairs again', () async {
    final LedgerKeyPair a = await LedgerKeyPair.fromSeed(_seed(7));
    final LedgerKeyPair b = await LedgerKeyPair.fromSeed(_seed(8));
    const String atA = '200:a::1';
    const String atB = '200:b::1';
    final Map<String, LocalPairKeys> byAddress = <String, LocalPairKeys>{};
    final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
    late LocalPairKeys pa;
    late LocalPairKeys pb;
    String? deviceAt(String address) => switch (address) {
      atA => b64(a.publicKey),
      atB => b64(b.publicKey),
      _ => null,
    };
    LocalPairKeys make(LedgerKeyPair key, String own, LedgerDisk disk) =>
        LocalPairKeys(
          disk: disk,
          ownDevice: b64(key.publicKey),
          send: (String to, Map<String, dynamic> payload) async {
            sent.add(payload);
            final LocalPairKeys? there = byAddress[to];
            await there?.onFrame(
              SignalTransportFrame(
                from: own,
                payload:
                    jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
                receivedAtMillis: 0,
              ),
              deviceAt: deviceAt,
            );
          },
        );
    final MemoryLedgerDisk diskA = MemoryLedgerDisk();
    pa = make(a, atA, diskA);
    pb = make(b, atB, MemoryLedgerDisk());
    byAddress[atA] = pa;
    byAddress[atB] = pb;
    int changes = 0;
    pa.onChanged = () => changes++;

    final String classical = (await LocalLinkSecrets(
      a,
    ).secretWith(b.publicKey))!;
    await pa.offer(b64(b.publicKey), atB);
    expect(sent, hasLength(3), reason: 'offer, answer, confirmation');
    expect(
      sent.every((Map<String, dynamic> m) => m['type'] == kLocalPairType),
      isTrue,
    );
    expect(pa.paired(b64(b.publicKey)), isTrue);
    expect(pb.paired(b64(a.publicKey)), isTrue);
    expect(changes, 1);
    final String? ab = await LocalLinkSecrets(
      a,
      pairs: pa,
    ).secretWith(b.publicKey);
    final String? ba = await LocalLinkSecrets(
      b,
      pairs: pb,
    ).secretWith(a.publicKey);
    expect(ab, ba);
    expect(ab, isNot(classical));
    // Paired: nothing more is offered.
    await pa.offer(b64(b.publicKey), atB);
    expect(sent, hasLength(3));

    // Kept across restarts.
    final LocalPairKeys again = make(a, atA, diskA);
    await again.offer(b64(b.publicKey), atB);
    expect(again.pairSecret(b64(b.publicKey)), pa.pairSecret(b64(b.publicKey)));

    // B is installed anew: its new contribution pairs again.
    pb = make(b, atB, MemoryLedgerDisk());
    byAddress[atB] = pb;
    await pb.offer(b64(a.publicKey), atA);
    expect(pa.paired(b64(b.publicKey)), isTrue);
    expect(pb.paired(b64(a.publicKey)), isTrue);
    expect(
      await LocalLinkSecrets(a, pairs: pa).secretWith(b.publicKey),
      await LocalLinkSecrets(b, pairs: pb).secretWith(a.publicKey),
    );

    // A contribution from an address that is not the device's is ignored.
    final LedgerKeyPair c = await LedgerKeyPair.fromSeed(_seed(9));
    await pa.onFrame(
      SignalTransportFrame(
        from: '200:c::1',
        payload: <String, dynamic>{
          'type': kLocalPairType,
          'd': b64(c.publicKey),
          'to': b64(a.publicKey),
          'c': b64(List<int>.filled(32, 1)),
          'h': '',
        },
        receivedAtMillis: 0,
      ),
      deviceAt: deviceAt,
    );
    expect(pa.paired(b64(c.publicKey)), isFalse);
  });
}
