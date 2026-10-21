import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_mail_push.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Ledger nodes linked in memory; frames to an address in [offline] are
/// lost, like datagrams to a phone that is off.
final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes, this.offline);

  final String address;
  final Map<String, _Linked> nodes;
  final Set<String> offline;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String to = PeerShareCodec.normalizeAddress(remoteAddress);
    final _Linked? target = nodes[to];
    if (target != null && !offline.contains(to)) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  final String ada = PeerShareCodec.normalizeAddress('200::a');
  final String bob = PeerShareCodec.normalizeAddress('200::b');
  final String cel = PeerShareCodec.normalizeAddress('200::c');
  late Map<String, _Linked> nodes;
  late Set<String> offline;

  Future<LedgerNode> make(String address, List<String> friends) async {
    final _Linked t = nodes[address] = _Linked(address, nodes, offline);
    await t.start();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => friends,
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(n.stop);
    await n.start();
    return n;
  }

  setUp(() {
    nodes = <String, _Linked>{};
    offline = <String>{};
  });

  test('a post reaches a friend who was offline through the queue, and not '
      'twice to one who is online', () async {
    final LedgerNode a = await make(ada, <String>[bob, cel]);
    final LedgerNode b = await make(bob, <String>[ada]);
    await make(cel, <String>[ada]);
    await _settle(); // hellos: everyone knows everyone's account
    expect(a.friendAccounts.keys.toSet(), <String>{bob, cel});

    final List<({String to, Map<String, dynamic> payload})> pushed =
        <({String to, Map<String, dynamic> payload})>[];
    final LedgerMailPush push = LedgerMailPush(
      node: a,
      isOnline: (String address) => !offline.contains(address),
      send: (String to, Map<String, dynamic> payload) async =>
          pushed.add((to: to, payload: payload)),
      delay: const Duration(hours: 1), // flushed by hand
    )..start();
    addTearDown(push.stop);

    offline.add(bob);
    final LogEntry post = await a.publish(
      kPostKind,
      newPostBody('Dla nieobecnych'),
    );
    // A reaction bundle never goes this way (the sync carries it).
    await a.publish(kReactionsKind, <String, dynamic>{
      'post': post.id,
      'likes': <Object>[],
      'comments': <Object>[],
    }, spaceKind: 'acts');
    await _settle();
    expect(
      b.entriesOf(ofAccount: a.account).map((LogEntry e) => e.id),
      isNot(contains(post.id)),
    );

    expect(await push.flush(), 1);
    expect(pushed.single.to, bob, reason: 'cel is online: the sync has it');
    expect(pushed.single.payload['type'], kLedgerPushType);
    expect(pushed.single.payload['entries'], hasLength(1));

    // Bob is back while ada is away: only the queued push can bring it.
    offline
      ..remove(bob)
      ..add(ada);
    await nodes[bob]!.injectIncoming(from: ada, payload: pushed.single.payload);
    await _settle();
    expect(
      b.entriesOf(ofAccount: a.account).map((LogEntry e) => e.id),
      contains(post.id),
    );
    expect(await push.flush(), 0, reason: 'nothing new');
  });

  test('pushes to one friend are limited, so a busy writer cannot flood '
      'a friend\'s mailboxes', () async {
    final LedgerNode a = await make(ada, <String>[bob]);
    await make(bob, <String>[ada]);
    await _settle();
    offline.add(bob);
    int sent = 0;
    final LedgerMailPush push = LedgerMailPush(
      node: a,
      isOnline: (String _) => false,
      send: (String to, Map<String, dynamic> payload) async => sent++,
      delay: const Duration(hours: 1),
      maxPushesPerHour: 3,
    )..start();
    addTearDown(push.stop);
    for (int i = 0; i < 5; i++) {
      await a.publish(kPostKind, newPostBody('Wpis $i'));
      await _settle();
      await push.flush();
    }
    expect(sent, 3);
  });
}
