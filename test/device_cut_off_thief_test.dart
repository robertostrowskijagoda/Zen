// "Odłącz" against whoever holds the account key and password (a thief of
// one unlocked device), with real nodes: a device the owner links counts
// with friends at once by its co-signature; one the thief makes waits a
// day, the owner hears of it from friends and vetoes it; the thief cannot
// cut the owner's devices off with the account key alone; what the stolen
// device co-signed goes with it; a settled cut-off is not undone.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/device_trust.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

const int _h = 3600 * 1000;

/// The wall clock of every node here.
int _now = 1800000000000;

final String _a1 = _a('200::a1');
final String _a2 = _a('200::a2');
final String _a3 = _a('200::a3');
final String _b = _a('200::b');

Future<LedgerNode> _node(
  String address, {
  required MemoryLedgerDisk disk,
  required List<String> friends,
  String name = 'Urządzenie',
}) async {
  final _Linked t = _Linked(address);
  _Linked.nodes[address] = t;
  await t.start();
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk,
    clock: HlcClock(wallClock: () => _now),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    deviceName: name,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  await n.start();
  return n;
}

/// The owner's first device, a friend, and (two hours after they met) a
/// second device the owner links from the first: the one to be stolen.
Future<(LedgerNode, LedgerNode, LedgerNode)> _owner() async {
  final MemoryLedgerDisk d1 = MemoryLedgerDisk();
  await LedgerIdentity.loadOrCreate(d1, now: () => _now);
  final LedgerNode first = await _node(_a1, disk: d1, friends: <String>[_b]);
  final LedgerNode bob = await _node(
    _b,
    disk: MemoryLedgerDisk(),
    friends: <String>[_a1, _a2, _a3],
  );
  await _settle();
  _now += 2 * _h;

  await first.expectOwnDevice(_a2);
  final MemoryLedgerDisk d2 = MemoryLedgerDisk();
  await LedgerIdentity.adoptAccount(
    d2,
    first.identity.accountKey!.seed,
    now: () => _now,
  );
  final LedgerNode second = await _node(
    _a2,
    disk: d2,
    friends: <String>[_b],
    name: 'Telefon',
  );
  await second.expectOwnDevice(_a1);
  await second.rememberDeviceAddresses(<String>[_a1]);
  await _settle(160);
  return (first, bob, second);
}

void main() {
  setUp(() {
    _Linked.nodes.clear();
    _now = 1800000000000;
  });

  test('a device the owner links counts with friends at once; one the '
      'thief makes with the account key waits, the owner hears of it from '
      'a friend, vetoes it, and it never counts', () async {
    final (LedgerNode first, LedgerNode bob, LedgerNode second) =
        await _owner();
    final String account = first.account;
    final String s = second.identity.deviceKey.id;
    expect(second.identity.certificate.co?.by, first.identity.deviceKey.id);
    expect(
      bob.store.directory.certificateOf(account, s)!.coSignedByOther,
      isTrue,
    );
    expect(bob.store.directory.isRevoked(account, s), isFalse);

    // The thief, with the account key from the stolen phone, makes a device
    // of his own and greets the friend.
    final MemoryLedgerDisk d3 = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      d3,
      second.identity.accountKey!.seed,
      now: () => _now,
    );
    final LedgerNode third = await _node(
      _a3,
      disk: d3,
      friends: <String>[_b],
      name: 'Nowe urządzenie',
    );
    final String t = third.identity.deviceKey.id;
    await _settle(160);
    final LogEntry post = await third.publish('post', <String, dynamic>{
      'text': 'od złodzieja',
    });
    await _settle(160);
    expect(bob.store.directory.pendingUntil(account, t), isNotNull);
    expect(bob.store.directory.isRevoked(account, t), isTrue);
    expect(bob.store.entryById(post.space, post.id), isNull);

    // The friend told the owner's devices; the owner vetoes it.
    expect(
      first.pendingOwnDevices.map((AccountDevice d) => d.device),
      contains(t),
    );
    await first.unlinkDevice(t);
    await _settle(160);
    expect(bob.store.directory.isCutOff(account, t), isTrue);

    // A day later it still does not count, and cuts nothing.
    _now += kNewDeviceWait.inMilliseconds + _h;
    final DeviceRevocation answer = await DeviceRevocation.issue(
      account: third.identity.accountKey!,
      device: first.identity.deviceKey.id,
      cutoffs: const <String, int>{},
      issued: _now,
      by: third.identity.deviceKey,
      byCertificate: third.identity.certificate,
    );
    await bob.store.applyRevocation(answer);
    expect(bob.store.directory.isCutOff(account, t), isTrue);
    expect(
      bob.store.directory.isRevoked(account, first.identity.deviceKey.id),
      isFalse,
    );
  });

  test('the account key alone does not cut the owner off; the stolen '
      'device\'s cut-off of the owner, a day after the owner cut it off, '
      'does nothing; what the stolen device co-signed goes with it', () async {
    final (LedgerNode first, LedgerNode bob, LedgerNode second) =
        await _owner();
    final String account = first.account;
    final String owner = first.identity.deviceKey.id;
    final LedgerKeyPair accountKey = second.identity.accountKey!;

    final DeviceRevocation alone = await DeviceRevocation.issue(
      account: accountKey,
      device: owner,
      cutoffs: const <String, int>{},
      issued: _now,
    );
    expect(await bob.store.applyRevocation(alone), -1);
    expect(bob.store.directory.isRevoked(account, owner), isFalse);

    // While it still counts, the stolen device co-signs one of the
    // thief's.
    final (LedgerKeyPair tk, DeviceCertificate certT) = await (() async {
      final LedgerKeyPair k = await LedgerKeyPair.generate();
      return (
        k,
        await DeviceCertificate.issue(
          account: accountKey,
          device: k,
          name: 'Tablet',
          issued: _now,
        ),
      );
    })();
    final DeviceCertificate coT = await certT.coSignedBy(
      second.identity.deviceKey,
    );
    await bob.store.directory.addCertificate(coT);
    expect(bob.store.directory.isRevoked(account, tk.id), isFalse);

    await first.unlinkDevice(second.identity.deviceKey.id);
    await _settle(160);
    expect(
      bob.store.directory.isCutOff(account, second.identity.deviceKey.id),
      isTrue,
    );
    expect(bob.store.directory.isCutOff(account, tk.id), isTrue);
    expect(bob.store.directory.isRevoked(account, owner), isFalse);

    _now += kNewDeviceWait.inMilliseconds + _h;
    await bob.store.applyRevocation(
      await DeviceRevocation.issue(
        account: accountKey,
        device: owner,
        cutoffs: const <String, int>{},
        issued: _now,
        by: second.identity.deviceKey,
        byCertificate: second.identity.certificate,
      ),
    );
    expect(bob.store.directory.isRevoked(account, owner), isFalse);
  });
}
