import 'dart:convert';
import 'dart:math';

import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_replicator.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';

/// One simulated device.
final class SimNode {
  SimNode(this.name, this.net) {
    store = LedgerStore(clock: HlcClock(wallClock: () => net.nowMillis));
    replicator = LedgerReplicator(
      store: store,
      blobs: blobs,
      send: (String to, Map<String, dynamic> message) =>
          net._enqueue(name, to, message),
      peers: () => neighbors.where((String n) => net.nodes[n]!.online),
      acceptsFrom: (String peer, String space) =>
          acceptsFrom?.call(peer, space) ??
          replicator.subscriptions.contains(space),
      servesTo: (String peer, String space) =>
          servesTo?.call(peer, space) ?? true,
      forwardsFrom: (String peer, String space) =>
          forwardsFrom?.call(peer, space) ?? false,
    );
  }

  final String name;
  final SimNet net;
  late final LedgerStore store;
  final BlobStore blobs = BlobStore();
  late final LedgerReplicator replicator;
  LedgerAuthor? author;
  final Set<String> neighbors = <String>{};
  bool online = true;

  /// Optional narrowing of who may push what (see [LedgerReplicator]).
  bool Function(String peer, String space)? acceptsFrom;

  /// Optional limit on what a peer may get (default: everything).
  bool Function(String peer, String space)? servesTo;

  /// Optional: spaces taken from a peer only to pass on.
  bool Function(String peer, String space)? forwardsFrom;

  Future<void> becomeAuthor() async {
    final LedgerAccountSetup setup = await LedgerAccountSetup.create(
      deviceName: name,
    );
    author = LedgerAuthor(
      deviceKey: setup.deviceKey,
      certificate: setup.certificate,
      store: store,
    );
    accountSetup = setup;
  }

  LedgerAccountSetup? accountSetup;

  String get account => author!.account;
}

/// A deterministic network: messages queue up and are delivered one by one
/// (as JSON, like on the wire), with optional loss and offline nodes.
final class SimNet {
  SimNet({int seed = 1, this.dropRate = 0}) : _random = Random(seed);

  final Random _random;
  double dropRate;
  int nowMillis = 1790000000000;
  final Map<String, SimNode> nodes = <String, SimNode>{};
  final List<(String, String, String)> _queue = <(String, String, String)>[];
  int delivered = 0;
  int dropped = 0;

  SimNode add(String name) => nodes[name] = SimNode(name, this);

  void link(String a, String b) {
    nodes[a]!.neighbors.add(b);
    nodes[b]!.neighbors.add(a);
  }

  void _enqueue(String from, String to, Map<String, dynamic> message) {
    _queue.add((from, to, jsonEncode(message)));
  }

  /// Delivers until nothing is left in flight.
  Future<void> pump({int maxMessages = 200000}) async {
    int steps = 0;
    await Future<void>.delayed(Duration.zero);
    while (_queue.isNotEmpty) {
      if (++steps > maxMessages) {
        throw StateError('Sieć się nie uspokaja (pętla wiadomości?)');
      }
      final (String from, String to, String json) = _queue.removeAt(0);
      final SimNode? target = nodes[to];
      final SimNode? source = nodes[from];
      if (target == null ||
          source == null ||
          !target.online ||
          !source.online ||
          (dropRate > 0 && _random.nextDouble() < dropRate)) {
        dropped++;
        continue;
      }
      delivered++;
      await target.replicator.handle(
        from,
        jsonDecode(json) as Map<String, dynamic>,
      );
      // Let announcements scheduled as microtasks go out.
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Every online node syncs with every online neighbour, then the network
  /// settles; repeated [rounds] times (what reconnects do in the app).
  Future<void> syncRounds(int rounds) async {
    for (int r = 0; r < rounds; r++) {
      for (final SimNode node in nodes.values) {
        if (!node.online) {
          continue;
        }
        for (final String n in node.neighbors) {
          if (nodes[n]!.online) {
            node.replicator.syncWith(n);
          }
        }
      }
      await pump();
      for (final SimNode node in nodes.values) {
        if (node.online) {
          node.replicator.retryBlobs();
        }
      }
      await pump();
    }
  }

  void randomlyToggle(double offlineShare) {
    for (final SimNode node in nodes.values) {
      node.online = _random.nextDouble() >= offlineShare;
    }
  }

  void allOnline() {
    for (final SimNode node in nodes.values) {
      node.online = true;
    }
  }

  Random get random => _random;
}

/// Makes [bytes] of deterministic pseudo-random content.
List<int> simBytes(int length, {int seed = 7}) {
  final Random r = Random(seed);
  return List<int>.generate(length, (_) => r.nextInt(256));
}
