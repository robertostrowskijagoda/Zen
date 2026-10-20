import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_memo.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
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
  test('the wall is built again only when what it reads changes', () async {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    await ta.start();
    await tb.start();
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();

    // What the screen does: every ledger change bumps the revision.
    int revision = 0;
    final StreamSubscription<void> changes = a.store.changed.listen(
      (_) => revision++,
    );
    addTearDown(changes.cancel);

    await a.publish(kPostKind, newPostBody('Od Ady'));
    await b.publish(kPostKind, newPostBody('Od Boba'));
    await _settle();

    String name = 'Bob';
    final FeedMemo memo = FeedMemo();
    List<FeedPost> wall() =>
        memo.wallOf(a, revision: revision, nameOf: (String _) => name);

    final List<FeedPost> first = wall();
    // Own posts are on the profile, not on the wall.
    expect(first.map((FeedPost p) => p.text), <String>['Od Boba']);
    expect(first.single.authorLabel, 'Bob');
    expect(identical(wall(), first), isTrue, reason: 'nothing changed');

    name = 'Robert';
    final List<FeedPost> renamed = wall();
    expect(identical(renamed, first), isFalse);
    expect(renamed.single.authorLabel, 'Robert');
    expect(identical(wall(), renamed), isTrue);

    await b.publish(kPostKind, newPostBody('Znowu Bob'));
    await _settle();
    final List<FeedPost> updated = wall();
    expect(updated.map((FeedPost p) => p.text), <String>[
      'Znowu Bob',
      'Od Boba',
    ]);
    // The same as building it from scratch.
    expect(
      updated.map((FeedPost p) => p.id),
      buildFeed(
        a,
        nameOf: (String _) => name,
      ).where((FeedPost p) => !p.isOwn).map((FeedPost p) => p.id),
    );
  });
}
