import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/pyramid/pyramid_device_sync.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/pyramid_world.dart';

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

/// A pyramid host with no friends: only the account's own devices count.
final class _Host implements EventHost {
  _Host(this.address);

  final String address;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => const <String>[];

  @override
  bool isFriend(String address) => false;

  @override
  String ownAddress() => address;

  @override
  String ownName() => 'Ania';

  @override
  String nameOf(String address) => '';

  @override
  Future<void> notify(RuntimeSystemNotification notification) async {}
}

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<_Linked> _transport(String address) async {
  final _Linked t = _Linked(_a(address));
  _Linked.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(_Linked t, MemoryLedgerDisk disk) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk,
    friendAddresses: () => const <String>[],
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

void main() {
  setUp(_Linked.nodes.clear);

  test('a linked device takes over the pyramid; votes are added, never '
      'replaced', () async {
    final String a1 = _a('200::a1');
    final String a2 = _a('200::a2');
    final _Linked t1 = await _transport(a1);
    final _Linked t2 = await _transport(a2);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    final LedgerNode first = _node(t1, d1);
    await first.start();
    // Link the second device to the same account.
    final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
    await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
    final LedgerNode second = _node(t2, d2);
    await second.start();
    await second.rememberDeviceAddresses(<String>[a1]);
    await _settle(200);
    expect(first.ownDevices, hasLength(2));

    final PyramidService p1 = PyramidService(host: _Host(a1), disk: d1);
    final PyramidService p2 = PyramidService(host: _Host(a2), disk: d2);
    addTearDown(p1.dispose);
    addTearDown(p2.dispose);
    await p1.load();
    await p2.load();
    // One person, one pyramid key, whichever device.
    expect(p2.myKey, isNotNull);
    expect(p2.myKey, p1.myKey);
    await p1.found(myName: 'Ania', nat: 'PL', birthYear: 1990, gender: 'k');
    expect(p1.holdsPowerKey, isTrue);
    expect(p2.isMember, isFalse);

    final PyramidDeviceSync s1 = PyramidDeviceSync(
      node: first,
      pyramid: p1,
      delay: Duration.zero,
    );
    final PyramidDeviceSync s2 = PyramidDeviceSync(
      node: second,
      pyramid: p2,
      delay: Duration.zero,
    );
    addTearDown(s1.stop);
    addTearDown(s2.stop);
    await s1.start();
    await s2.start();
    await s1.flush();
    await _settle(200);
    await s2.idle;

    // The second device knows the membership, the data confirmed at
    // entry and the record this person signed: it can act as them.
    expect(p2.isMember, isTrue);
    expect(p2.myData, p1.myData);
    // The power key goes with the person, to every device.
    expect(p2.holdsPowerKey, isTrue);

    // Each device voted in its own referendum, and both in "r": the
    // first device keeps its own vote, the other one is added.
    p1.myVotes['r'] = 0;
    p2.myVotes['r'] = 1;
    p2.myVotes['r2'] = 2;
    await s2.flush();
    await _settle(200);
    await s1.idle;
    expect(p1.myVotes, <String, int>{'r': 0, 'r2': 2});
  });

  test('another person\'s state is not taken', () async {
    final PyramidWorld w = PyramidWorld();
    final SimPhone s = w.add('S');
    final SimPhone x = w.add('X');
    await w.pyr(s).load();
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm');
    await w.pyr(x).load();
    final Map<String, dynamic> theirs = w.pyr(s).sharedState()!;
    expect(await w.pyr(x).mergeFromOwnDevice(theirs), isFalse);
    expect(w.pyr(x).isMember, isFalse);
    expect(w.pyr(x).holdsPowerKey, isFalse);
    expect(w.pyr(x).myData, isEmpty);
  });

  test('records the linked device lacks come from friends', () async {
    final PyramidWorld w = PyramidWorld();
    final SimPhone s = w.add('S');
    final MemoryLedgerDisk diskA = MemoryLedgerDisk();
    final SimPhone a = w.add('A', disk: diskA);
    await w.pyr(s).load();
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm');
    await w.join(s, a);
    await w.sync();
    final PyramidService first = w.pyr(a);
    expect(first.isMember, isTrue);

    // A's second device: the same key, nothing else yet. Account routing
    // makes it A to A's friends.
    final MemoryLedgerDisk diskA2 = MemoryLedgerDisk();
    w.linkDevice(diskA, diskA2);
    final SimPhone a2 = w.add('A2', disk: diskA2);
    w.net.befriend(s, a2);
    final PyramidService second = w.pyr(a2);
    await second.load();
    expect(second.myKey, first.myKey);
    expect(second.isMember, isFalse);

    final Map<String, dynamic> shared = first.sharedState()!;
    expect(await second.mergeFromOwnDevice(shared), isTrue);
    // Kept here now: its records come from friends.
    await second.greet();
    await w.net.run();

    expect(second.current, first.current);
    expect(second.isMember, isTrue);
    expect(second.state?.members.keys, containsAll(first.state!.members.keys));
    // Taking the same state again changes nothing.
    expect(await second.mergeFromOwnDevice(shared), isFalse);
  });
}
