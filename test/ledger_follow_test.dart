import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_replicator.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;
  final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    sent.add(payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
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
  final String cel = PeerShareCodec.normalizeAddress('200::c');

  late Map<String, _Linked> nodes;
  late LedgerNode a;
  late LedgerNode c;
  late MemoryLedgerDisk cDisk;

  LedgerNode make(String address, {MemoryLedgerDisk? disk}) {
    final _Linked t = nodes[address] ??= _Linked(address, nodes);
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: disk ?? MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      helloInterval: Duration.zero,
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(n.stop);
    return n;
  }

  setUp(() async {
    nodes = <String, _Linked>{};
    cDisk = MemoryLedgerDisk();
    a = make(ada);
    c = make(cel, disk: cDisk);
    await nodes[ada]!.start();
    await nodes[cel]!.start();
    await a.start();
    await c.start();
  });

  test('anyone can follow a public wall without being a friend', () async {
    await a.publish(kPostKind, newPostBody('Dla wszystkich'));
    await a.publish('like', likeBody('x'), spaceKind: 'acts');
    await c.follow(ada);
    await _settle();

    expect(c.followedAccounts, <String, String>{ada: a.account});
    final List<FeedPost> wall = buildFeed(c, nameOf: (String x) => 'Ada');
    expect(wall.single.text, 'Dla wszystkich');
    expect(wall.single.authorLabel, 'Ada');
    // Only public spaces travel to a follower.
    expect(c.entriesOf(spaceKind: 'acts', ofAccount: a.account), isEmpty);

    // New posts arrive at the next greeting.
    await a.publish(kPostKind, newPostBody('Drugi'));
    await c.greetFriends();
    await _settle();
    expect(buildFeed(c, nameOf: (_) => 'Ada'), hasLength(2));
  });

  test('a stranger cannot push entries or read private spaces', () async {
    await c.publish(kPostKind, newPostBody('Nikt mnie nie obserwuje'));
    await a.publish('note', <String, dynamic>{'x': 1}, spaceKind: 'private');
    // C (a stranger) asks for A's private space and offers its own feed.
    await nodes[cel]!.send(
      remoteAddress: ada,
      payload: <String, dynamic>{
        'type': LedgerMessages.heads,
        'spaces': <String, dynamic>{
          accountSpace('private', a.account): <String, int>{},
          accountSpace('feed', c.account): <String, int>{c.account: 1},
        },
      },
    );
    await nodes[cel]!.send(
      remoteAddress: ada,
      payload: <String, dynamic>{
        'type': LedgerMessages.entries,
        'entries': <Map<String, dynamic>>[
          for (final LogEntry e in c.entriesOf()) e.toJson(),
        ],
      },
    );
    await c.follow(ada);
    await _settle();
    expect(a.entriesOf(ofAccount: c.account), isEmpty);
    expect(c.entriesOf(spaceKind: 'private', ofAccount: a.account), isEmpty);
    // A never sent anything from its private space.
    expect(
      nodes[ada]!.sent.any(
        (Map<String, dynamic> m) =>
            m['type'] == LedgerMessages.entries &&
            (m['entries'] as List<dynamic>).any(
              (dynamic e) =>
                  (e as Map<dynamic, dynamic>)['space'] ==
                  accountSpace('private', a.account),
            ),
      ),
      isFalse,
    );
  });

  test('following survives a restart and can be undone', () async {
    await a.publish(kPostKind, newPostBody('Raz'));
    await c.follow(ada);
    await _settle();
    await c.stop();

    final LedgerNode again = LedgerNode(
      transport: nodes[cel]!,
      disk: cDisk,
      friendAddresses: () => const <String>[],
      helloInterval: Duration.zero,
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(again.stop);
    await again.start();
    expect(again.isFollowing(ada), isTrue);
    expect(buildFeed(again, nameOf: (_) => 'Ada'), hasLength(1));

    await again.unfollow(ada);
    expect(again.isFollowing(ada), isFalse);
    expect(buildFeed(again, nameOf: (_) => 'Ada'), isEmpty);
  });

  test('a flood from a stranger is cut off', () async {
    int answers = 0;
    final StreamSubscription<SignalTransportFrame> sub = nodes[cel]!.frames
        .listen((SignalTransportFrame f) {
          if (f.payload['type'] == LedgerMessages.entries) {
            answers++;
          }
        });
    addTearDown(sub.cancel);
    await a.publish(kPostKind, newPostBody('Treść'));
    for (int i = 0; i < kStrangerFramesPerMinute + 20; i++) {
      await nodes[cel]!.send(
        remoteAddress: ada,
        payload: <String, dynamic>{
          'type': LedgerMessages.heads,
          'spaces': <String, dynamic>{
            accountSpace('feed', a.account): <String, int>{},
          },
        },
      );
    }
    await _settle();
    expect(answers, kStrangerFramesPerMinute);
  });
}
