import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late MemorySignalTransport transport;
  late LedgerNode node;

  setUp(() async {
    transport = MemorySignalTransport();
    await transport.start();
    node = LedgerNode(
      transport: transport,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      // One fixed minute, so per-minute budgets cannot roll over mid-test.
      clock: HlcClock(wallClock: () => 1700000000000),
    );
    await node.start();
  });

  tearDown(() => node.stop());

  Future<String> helloFromNewAccount(String from) async {
    final LedgerKeyPair account = await LedgerKeyPair.generate();
    final LedgerKeyPair device = await LedgerKeyPair.generate();
    final DeviceCertificate cert = await DeviceCertificate.issue(
      account: account,
      device: device.id,
      name: 'obcy',
      issued: 1,
    );
    await transport.injectIncoming(
      from: PeerShareCodec.normalizeAddress(from),
      payload: <String, dynamic>{
        'type': kLedgerHelloType,
        'cert': cert.toJson(),
      },
    );
    return account.id;
  }

  int repliesTo(bool Function(String address) match) => transport.sentSignals
      .where(
        (({String remoteAddress, Map<String, dynamic> payload}) s) =>
            s.payload['type'] == kLedgerHelloType && match(s.remoteAddress),
      )
      .length;

  test('accounts strangers make up are checked but never stored', () async {
    final List<String> minted = <String>[
      for (int i = 0; i < 20; i++) await helloFromNewAccount('200:${i + 1}::1'),
    ];
    await _settle();

    for (final String account in minted) {
      expect(node.store.directory.devicesOf(account), isEmpty);
    }
    // Still answered: a stranger's hello is how a follower learns our account.
    expect(repliesTo((String a) => true), 20);
  });

  test('one /64 network shares one stranger budget', () async {
    for (int i = 0; i < kStrangerFramesPerMinute + 10; i++) {
      await helloFromNewAccount('200:1:2:3::${i + 1}');
    }
    await helloFromNewAccount('200:9:9:9::1');
    await _settle();

    expect(
      repliesTo((String a) => a.startsWith('200:1:2:3:')),
      kStrangerFramesPerMinute,
    );
    expect(repliesTo((String a) => a.startsWith('200:9:9:9:')), 1);
  });
}
