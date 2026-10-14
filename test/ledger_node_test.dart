import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Transports wired to each other by address, delivering like the mesh does
/// (asynchronously, through JSON-like maps), with an on/off switch.
final class _Mesh {
  final Map<String, _LinkedTransport> nodes = <String, _LinkedTransport>{};

  _LinkedTransport add(String address) =>
      nodes[address] = _LinkedTransport(this, address);
}

final class _LinkedTransport extends MemorySignalTransport {
  _LinkedTransport(this.mesh, this.address);

  final _Mesh mesh;
  final String address;
  bool online = true;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _LinkedTransport? target =
        mesh.nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target == null || !online || !target.online) {
      return;
    }
    scheduleMicrotask(
      () => target.injectIncoming(from: address, payload: payload),
    );
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final String ada = PeerShareCodec.normalizeAddress('200::a');
final String bob = PeerShareCodec.normalizeAddress('200::b');
final String eve = PeerShareCodec.normalizeAddress('200::e');

void main() {
  late _Mesh mesh;

  setUp(() {
    mesh = _Mesh();
  });

  Future<LedgerNode> node(
    String address,
    List<String> friends, {
    LedgerDisk? disk,
  }) async {
    final _LinkedTransport transport = mesh.nodes[address] ?? mesh.add(address);
    await transport.start();
    final LedgerNode n = LedgerNode(
      transport: transport,
      disk: disk ?? MemoryLedgerDisk(),
      friendAddresses: () => friends,
    );
    addTearDown(n.stop);
    return n;
  }

  test('friends find each other\'s accounts and catch up on posts', () async {
    final LedgerNode a = await node(ada, <String>[bob]);
    final LedgerNode b = await node(bob, <String>[ada]);
    await a.start();
    await a.publish('post', <String, dynamic>{'text': 'Pierwszy'});
    await a.publish('post', <String, dynamic>{'text': 'Drugi'});
    await b.start();
    await _settle();

    expect(b.accountOf(ada), a.account);
    expect(a.accountOf(bob), b.account);
    expect(
      b.entriesOf(ofAccount: a.account).map((LogEntry e) => e.body['text']),
      <String>['Pierwszy', 'Drugi'],
    );

    // New posts arrive on their own.
    await b.publish('post', <String, dynamic>{'text': 'Odpowiedź'});
    await _settle();
    expect(a.entriesOf(ofAccount: b.account), hasLength(1));
  });

  test('strangers read only public spaces and cannot push anything', () async {
    final LedgerNode a = await node(ada, <String>[bob]);
    final LedgerNode e = await node(eve, <String>[ada]);
    await a.start();
    await e.start();
    await a.publish('post', <String, dynamic>{'text': 'Publiczny'});
    await a.publish('like', <String, dynamic>{'post': 'x'}, spaceKind: 'acts');
    await e.publish('post', <String, dynamic>{'text': 'Spam'});
    await _settle();

    expect(a.accountOf(eve), isNull);
    // A one-sided "friend" is just a follower: public posts only (§12).
    expect(e.entriesOf(ofAccount: a.account), hasLength(1));
    expect(e.entriesOf(spaceKind: 'acts', ofAccount: a.account), isEmpty);
    expect(a.store.spaces.where((String s) => s.contains(e.account)), isEmpty);
  });

  test('a restart keeps the account, the posts and the friends', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerNode first = await node(ada, <String>[bob], disk: disk);
    final LedgerNode b = await node(bob, <String>[ada]);
    await first.start();
    await b.start();
    await first.publish('post', <String, dynamic>{'text': 'Zostaję'});
    await _settle();
    final String account = first.account;
    await first.stop();

    mesh.nodes.remove(ada);
    final LedgerNode again = await node(ada, <String>[bob], disk: disk);
    await again.start();
    expect(again.account, account);
    expect(again.entriesOf(), hasLength(1));
    expect(again.accountOf(bob), b.account);

    // It keeps writing the same log after the restart.
    await again.publish('post', <String, dynamic>{'text': 'Dalej'});
    await _settle();
    expect(b.entriesOf(ofAccount: account), hasLength(2));
  });

  test('a friend offline at first catches up when it comes back', () async {
    final LedgerNode a = await node(ada, <String>[bob]);
    final LedgerNode b = await node(bob, <String>[ada]);
    await a.start();
    await b.start();
    await _settle();
    mesh.nodes[bob]!.online = false;
    await a.publish('post', <String, dynamic>{'text': 'Gdy cię nie było'});
    await _settle();
    expect(b.entriesOf(ofAccount: a.account), isEmpty);

    mesh.nodes[bob]!.online = true;
    // Any hello (e.g. on reconnect) triggers a full catch-up.
    await b.onFriendsChanged();
    b.replicator.syncWith(ada);
    await _settle();
    expect(b.entriesOf(ofAccount: a.account), hasLength(1));
  });

  test('removing a friend stops following their account', () async {
    final List<String> friends = <String>[bob];
    final LedgerNode a = await node(ada, friends);
    final LedgerNode b = await node(bob, <String>[ada]);
    await a.start();
    await b.start();
    await _settle();
    expect(a.accountOf(bob), isNotNull);

    friends.clear();
    await a.onFriendsChanged();
    await b.publish('post', <String, dynamic>{'text': 'Już nie widzisz'});
    await _settle();
    expect(a.accountOf(bob), isNull);
    expect(a.entriesOf(ofAccount: b.account), isEmpty);
  });
}
