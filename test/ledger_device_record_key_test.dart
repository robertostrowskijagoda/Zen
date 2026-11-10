import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Transports wired by address.
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

Future<void> _settle([int rounds = 120]) async {
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

/// What the ledger hands the bridge: pins, and hints by account.
final class _Keys {
  final List<(Map<String, String>, bool)> pins =
      <(Map<String, String>, bool)>[];
  final Map<String, Map<String, String>> hints =
      <String, Map<String, String>>{};

  void pin(Map<String, String> keys, {bool force = false}) =>
      pins.add((Map<String, String>.of(keys), force));

  void hint(String account, Map<String, String> keys) =>
      hints[account] = Map<String, String>.of(keys);

  bool pinned(String address) =>
      pins.any(((Map<String, String>, bool) c) => c.$1.containsKey(address));
}

LedgerNode _node(
  _Linked t, {
  MemoryLedgerDisk? disk,
  List<String> friends = const <String>[],
  _Keys? keys,
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    syncInterval: Duration.zero,
  );
  if (keys != null) {
    n
      ..onSessionKeys = keys.pin
      ..onSessionKeyHints = keys.hint;
  }
  addTearDown(n.stop);
  return n;
}

void main() {
  setUp(_Linked.nodes.clear);

  test('a friend\'s device record names a key for an address only as a '
      'hint from that friend\'s account, never a pin, at every start '
      'too', () async {
    final String bob = _a('200::b');
    final String mal = _a('200::4d');
    final String ania = _a('200::a1'); // Bob's friend
    final String carol = _a('200::c'); // someone Bob will meet later
    final String fake = 'ee' * 32; // a key nobody at those addresses holds
    final _Linked tb = await _transport(bob);
    final _Linked tm = await _transport(mal);
    final MemoryLedgerDisk bobDisk = MemoryLedgerDisk();
    final _Keys keys = _Keys();
    final LedgerNode bobNode = _node(
      tb,
      disk: bobDisk,
      friends: <String>[mal, ania],
      keys: keys,
    );
    final LedgerNode malNode = _node(tm, friends: <String>[bob]);
    await bobNode.start();
    await malNode.start();
    await _settle();
    expect(bobNode.accountOf(mal), malNode.account);

    // Mal signs device records with her own device: one names Carol's
    // address, one Ania's, each with a key Mal picked.
    await malNode.publish(kDeviceRecordKind, <String, dynamic>{
      'address': carol,
      'name': 'Telefon',
      'pq': fake,
    }, spaceKind: 'acts');
    await malNode.publish(kDeviceRecordKind, <String, dynamic>{
      'address': ania,
      'name': 'Telefon',
      'pq': fake,
    }, spaceKind: 'acts');
    await _settle();

    expect(keys.pinned(carol), isFalse, reason: 'a record is no proof');
    expect(keys.pinned(ania), isFalse);
    // Only the newest record of Mal's device counts: one claim.
    expect(keys.hints[malNode.account], <String, String>{ania: fake});
    expect(bobNode.sessionKeyOf(ania), isNull);
    expect(bobNode.sessionKeyOf(carol), isNull);

    // Bob restarts: the record is read again, as a hint again.
    await bobNode.stop();
    final _Keys again = _Keys();
    _Linked.nodes.remove(bob);
    final _Linked tb2 = await _transport(bob);
    final LedgerNode bob2 = _node(
      tb2,
      disk: bobDisk,
      friends: <String>[mal, ania],
      keys: again,
    );
    await bob2.start();
    await _settle(40);
    expect(again.pinned(carol) || again.pinned(ania), isFalse);
    expect(again.hints[malNode.account], <String, String>{ania: fake});
  });
}
