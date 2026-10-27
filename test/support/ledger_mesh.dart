import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Ledger nodes of several phones on one simulated mesh: each phone has
/// its own friend list, can go offline (nothing reaches it, nothing leaves
/// it), and single frames can be dropped on the way ([drop]). Every frame
/// a phone sends is counted by type ([sent]).
final class LedgerMesh {
  final Map<String, LedgerMeshLink> _links = <String, LedgerMeshLink>{};
  final Map<String, String> _addresses = <String, String>{};
  final Map<String, Set<String>> _friends = <String, Set<String>>{};
  final Set<String> _offline = <String>{};
  final Map<String, LedgerNode> nodes = <String, LedgerNode>{};

  /// Frames for which this says true are lost (from, to: phone names).
  bool Function(String from, String to, Map<String, dynamic> payload)? drop;

  /// Phone name → frame type → how many it sent.
  final Map<String, Map<String, int>> sent = <String, Map<String, int>>{};

  /// The mesh address of phone [name].
  String address(String name) => _addresses.putIfAbsent(
    name,
    () => PeerShareCodec.normalizeAddress(
      '200::${(0x100 + _addresses.length).toRadixString(16)}',
    ),
  );

  String? _nameOf(String address) {
    final String n = PeerShareCodec.normalizeAddress(address);
    for (final MapEntry<String, String> e in _addresses.entries) {
      if (e.value == n) {
        return e.key;
      }
    }
    return null;
  }

  LedgerNode operator [](String name) => nodes[name]!;

  void befriend(String a, String b) {
    (_friends[a] ??= <String>{}).add(b);
    (_friends[b] ??= <String>{}).add(a);
  }

  /// Friendships along [names]: a–b–c–…
  void chain(List<String> names) {
    for (int i = 0; i + 1 < names.length; i++) {
      befriend(names[i], names[i + 1]);
    }
  }

  bool isOnline(String name) => !_offline.contains(name);

  void setOnline(String name, bool on) {
    if (on) {
      _offline.remove(name);
    } else {
      _offline.add(name);
    }
  }

  /// Starts the ledger of phone [name] (friends as set so far, and any
  /// set later).
  Future<LedgerNode> add(String name, {bool autoDownload = true}) async {
    final String me = address(name);
    final LedgerMeshLink link = _links[me] = LedgerMeshLink._(this, name, me);
    await link.start();
    final LedgerNode node = LedgerNode(
      transport: link,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[
        for (final String f in _friends[name] ?? const <String>{}) address(f),
      ],
      bridges: BridgeBook(probe: (String _) async => null),
      autoDownloadMedia: () => autoDownload,
      helloInterval: Duration.zero,
      syncInterval: Duration.zero,
    );
    addTearDown(node.stop);
    await node.start();
    return nodes[name] = node;
  }

  /// Phone [name] comes back online and greets its friends (who catch up
  /// both ways). Hellos go at most once a second.
  Future<void> comeBack(String name) async {
    setOnline(name, true);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    await nodes[name]!.greetFriends();
    await settle();
  }

  /// Lets everything in flight arrive.
  Future<void> settle([int rounds = 80]) async {
    for (int i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  void _deliver(String from, String to, Map<String, dynamic> payload) {
    final String type = '${payload['type']}';
    final Map<String, int> counts = sent[from] ??= <String, int>{};
    counts[type] = (counts[type] ?? 0) + 1;
    final String? target = _nameOf(to);
    if (target == null ||
        _offline.contains(from) ||
        _offline.contains(target) ||
        (drop?.call(from, target, payload) ?? false)) {
      return;
    }
    final LedgerMeshLink? link = _links[address(target)];
    if (link != null) {
      // Like the wire: JSON in, JSON out.
      final Map<String, dynamic> copy =
          jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(
        () => link.injectIncoming(from: address(from), payload: copy),
      );
    }
  }
}

/// One phone's link to the [LedgerMesh].
final class LedgerMeshLink extends MemorySignalTransport {
  LedgerMeshLink._(this._mesh, this.name, this.address);

  final LedgerMesh _mesh;
  final String name;
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async => _mesh._deliver(name, remoteAddress, payload);
}
