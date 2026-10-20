import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Transports wired to each other by address (like the mesh: the sender's
/// address cannot be forged), with links that can be cut.
final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};

  /// `from>to` pairs whose frames are lost.
  static final Set<String> cut = <String>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final String to = PeerShareCodec.normalizeAddress(remoteAddress);
    final _Linked? target = nodes[to];
    if (target != null && !cut.contains('$address>$to')) {
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

Future<_Linked> _transport(String address) async {
  final _Linked t = _Linked(_a(address));
  _Linked.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(
  _Linked t, {
  MemoryLedgerDisk? disk,
  List<String> friends = const <String>[],
  List<String> greet = const <String>[],
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    greetAlso: () => greet,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

/// Where a message the app sends to [to] goes, through the account routing
/// (as in the app), with [node] as the directory.
Future<Set<String>> _routedTo(
  LedgerNode node,
  List<String> friends,
  String to,
) async {
  final MemorySignalTransport wire = MemorySignalTransport();
  await wire.start();
  addTearDown(wire.stop);
  final AccountRoutingTransport routed = AccountRoutingTransport(
    delegate: wire,
    directory: () => LedgerAccountDirectory(node, () => friends),
  );
  await routed.send(
    remoteAddress: to,
    payload: <String, dynamic>{'type': 'message', 'msgId': 'm1', 'text': 'hej'},
  );
  return <String>{
    for (final s in wire.sentSignals)
      if (s.payload['type'] == 'message') _a(s.remoteAddress),
  };
}

/// Links a second device at [t] to the account on [firstDisk] (whose
/// device is at [firstAddress]).
Future<LedgerNode> _linkSecond(
  MemoryLedgerDisk firstDisk,
  String firstAddress,
  _Linked t, {
  List<String> greet = const <String>[],
}) async {
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final LedgerIdentity first = await LedgerIdentity.loadOrCreate(firstDisk);
  await LedgerIdentity.adoptAccount(disk, first.accountKey!.seed);
  final LedgerNode second = _node(t, disk: disk, greet: greet);
  await second.start();
  await second.rememberDeviceAddresses(<String>[firstAddress]);
  return second;
}

void main() {
  setUp(() {
    _Linked.nodes.clear();
    _Linked.cut.clear();
  });

  test('a forged device record never routes to its address', () async {
    final String a1 = _a('200::a1');
    final String a2 = _a('200::a2');
    final String b = _a('200::b');
    final String m = _a('200::4d');
    final String c = _a('200::c');
    final _Linked ta1 = await _transport(a1);
    final _Linked ta2 = await _transport(a2);
    final _Linked tb = await _transport(b);
    final _Linked tm = await _transport(m);
    final _Linked tc = await _transport(c);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final LedgerNode ania = _node(ta1, disk: d1, friends: <String>[b]);
    final LedgerNode bob = _node(tb, friends: <String>[a1, m]);
    final LedgerNode mal = _node(tm, friends: <String>[b]);
    // Someone neither of them knows.
    final LedgerNode carol = _node(tc);
    await ania.start();
    await bob.start();
    await mal.start();
    await carol.start();
    await _settle();
    // Ania's second device, proven to Bob by its own hello.
    await _linkSecond(d1, a1, ta2);
    await _settle(200);
    expect(bob.accountOfAddress(a2), ania.account);
    await bob.setLevel(a1, FriendLevel.close);
    await bob.setLevel(m, FriendLevel.weak);

    // Mal (a friend) signs a record saying her device is at Carol's
    // address.
    await mal.publish(kDeviceRecordKind, <String, dynamic>{
      'address': c,
      'name': 'Telefon',
    }, spaceKind: 'acts');
    await _settle(120);
    expect(
      bob
          .entriesOf(spaceKind: 'acts', ofAccount: mal.account)
          .any(
            (LogEntry e) =>
                e.kind == kDeviceRecordKind && e.body['address'] == c,
          ),
      isTrue,
      reason: 'Bob has the record',
    );
    expect(bob.accountOfAddress(c), isNull);
    expect(bob.isFriendAddress(c), isFalse);
    expect(bob.levelOf(c), FriendLevel.friend, reason: 'not Mal\'s level');
    // Carol answered Bob's hello with her own certificate.
    expect(bob.accountOfAnyAddress(c), carol.account);
    expect(bob.addressesOfAccount(mal.account), <String>[m]);
    expect(await _routedTo(bob, <String>[a1, m], m), <String>{m});

    // Then at the address of Ania's second device: Ania's stays Ania's.
    await mal.publish(kDeviceRecordKind, <String, dynamic>{
      'address': a2,
      'name': 'Telefon',
    }, spaceKind: 'acts');
    await _settle(120);
    expect(bob.accountOfAddress(a2), ania.account);
    expect(bob.accountOfAnyAddress(a2), ania.account);
    expect(bob.levelOf(a2), FriendLevel.close);
    expect(bob.addressesOfAccount(mal.account), <String>[m]);
    expect(bob.addressesOfAccount(ania.account), containsAll(<String>[a1, a2]));
    expect(await _routedTo(bob, <String>[a1, m], m), <String>{m});
    expect(await _routedTo(bob, <String>[a1, m], a1), <String>{a1, a2});
  });

  test('a genuine device is routed to after its proven hello', () async {
    final String a1 = _a('200::a1');
    final String a2 = _a('200::a2');
    final String b = _a('200::b');
    final _Linked ta1 = await _transport(a1);
    final _Linked ta2 = await _transport(a2);
    final _Linked tb = await _transport(b);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final LedgerNode ania = _node(ta1, disk: d1, friends: <String>[b]);
    final LedgerNode bob = _node(tb, friends: <String>[a1]);
    await ania.start();
    await bob.start();
    await _settle();

    // Bob's greetings do not reach the new device for now.
    _Linked.cut.add('$b>$a2');
    final List<String> greet = <String>[];
    final LedgerNode second = await _linkSecond(d1, a1, ta2, greet: greet);
    await _settle(200);
    expect(ania.siblingAddresses, <String>[a2]);
    expect(
      bob
          .entriesOf(spaceKind: 'acts', ofAccount: ania.account)
          .any(
            (LogEntry e) =>
                e.kind == kDeviceRecordKind && e.body['address'] == a2,
          ),
      isTrue,
      reason: 'Bob has its record',
    );
    expect(
      tb.sentSignals.any(
        (s) =>
            _a(s.remoteAddress) == a2 && s.payload['type'] == kLedgerHelloType,
      ),
      isTrue,
      reason: 'the record makes Bob greet that address',
    );
    expect(bob.accountOfAddress(a2), isNull, reason: 'nothing proven yet');
    expect(bob.addressesOfAccount(ania.account), <String>[a1]);
    expect(await _routedTo(bob, <String>[a1], a1), <String>{a1});

    // The device itself says hello: signed by its key, from its address.
    _Linked.cut.clear();
    greet.add(b);
    await second.greetFriends();
    await _settle(120);
    expect(bob.accountOfAddress(a2), ania.account);
    expect(bob.isFriendAddress(a2), isTrue);
    expect(bob.addressesOfAccount(ania.account), containsAll(<String>[a1, a2]));
    expect(await _routedTo(bob, <String>[a1], a1), <String>{a1, a2});
  });
}
