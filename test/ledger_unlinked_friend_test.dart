import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Transports wired to each other by address (like the mesh: the sender's
/// address cannot be forged).
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

  /// How many frames went to [to].
  int sentTo(String to) => sentSignals
      .where(
        (({String remoteAddress, Map<String, dynamic> payload}) s) =>
            PeerShareCodec.normalizeAddress(s.remoteAddress) == to,
      )
      .length;
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
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

/// Where a message the app sends to [to] goes through the account routing.
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

void main() {
  setUp(_Linked.nodes.clear);

  test('a friend\'s phone its owner unlinked gets nothing more, is not taken '
      'as that friend, and the friend is warned about', () async {
    final String a1 = _a('200::a1');
    final String a2 = _a('200::a2');
    final String b = _a('200::b');
    final _Linked ta1 = await _transport(a1);
    final _Linked ta2 = await _transport(a2);
    final _Linked tb = await _transport(b);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    // Bob added Ania by scanning the code on her phone (a1).
    final LedgerNode phone = _node(ta1, disk: d1, friends: <String>[b]);
    final LedgerNode bob = _node(tb, friends: <String>[a1]);
    final List<String> warned = <String>[];
    bob.onDeviceUnlinked = warned.add;
    await phone.start();
    await bob.start();
    await _settle();
    // Her laptop joins the account (and has Bob among its friends).
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    final LedgerIdentity first = await LedgerIdentity.loadOrCreate(d1);
    await LedgerIdentity.adoptAccount(d2, first.accountKey!.seed);
    final LedgerNode laptop = _node(ta2, disk: d2, friends: <String>[b]);
    await laptop.start();
    await laptop.rememberDeviceAddresses(<String>[a1]);
    await _settle(200);
    expect(bob.accountOfAddress(a1), phone.account);
    expect(bob.accountOfAddress(a2), phone.account);
    final String keyBefore = bob.keyring.current(Audience.all).id;

    // The phone is stolen: Ania cuts it off from the laptop.
    await laptop.unlinkDevice(phone.identity.deviceKey.id);
    await _settle(200);

    expect(bob.isUnlinkedAddress(a1), isTrue);
    expect(warned, <String>[a1]);
    expect(bob.isFriendAddress(a1), isFalse);
    expect(bob.accountOfAddress(a1), isNull);
    expect(bob.addressesOfAccount(phone.account), <String>[a2]);
    expect(
      bob.keyring.current(Audience.all).id,
      isNot(keyBefore),
      reason: 'what the phone could read gets new keys',
    );
    // What Bob writes to Ania goes to her laptop only.
    expect(await _routedTo(bob, <String>[a1], a1), <String>{a2});

    // The thief's phone keeps greeting Bob: no answer, no keys, no sync,
    // and the address stays cut off.
    final int before = tb.sentTo(a1);
    phone.greet(b);
    await bob.greetFriends();
    await _settle(120);
    expect(tb.sentTo(a1), before);
    expect(bob.accountOfAddress(a1), isNull);
    expect(warned, <String>[a1], reason: 'warned once');
  });
}
