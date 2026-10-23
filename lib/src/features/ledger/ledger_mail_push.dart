import 'dart:async';

import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Posts, comments and likes this device writes, handed to friends who are
/// offline through the reliable queue (`lg_push`, [kLedgerPushType]): they
/// wait in those friends' mailboxes and arrive even if this phone is off by
/// the time the friend comes back. Friends who are online get them from
/// the usual sync, so nothing goes twice to them.
///
/// Kept small on purpose: only `feed` and `acts` entries of this device,
/// never reaction bundles (rewritten at every like; their friends get them
/// from the sync); several entries go together after [delay]; at most
/// [maxPushesPerHour] pushes to one friend; an entry larger than one
/// envelope ([maxBytes]) waits for the sync.
final class LedgerMailPush {
  LedgerMailPush({
    required this.node,
    required this.isOnline,
    required this.send,
    this.delay = const Duration(seconds: 30),
    this.maxBytes = 30 * 1024,
    this.maxQueued = 200,
    this.maxPushesPerHour = 10,
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerNode node;

  /// Whether a friend (by address) is online right now.
  final bool Function(String address) isOnline;

  /// Hands a payload to the reliable transport.
  final Future<void> Function(String address, Map<String, dynamic> payload)
  send;
  final Duration delay;
  final int maxBytes;
  final int maxQueued;
  final int maxPushesPerHour;
  final int Function() _now;

  StreamSubscription<LogEntry>? _subscription;
  Timer? _timer;
  int _since = 0;
  final List<LogEntry> _queued = <LogEntry>[];
  final Map<String, List<int>> _pushedAt = <String, List<int>>{};

  /// Entry kinds that never go this way.
  static const Set<String> _skippedKinds = <String>{
    kReactionsKind,
    kReactionsPageKind,
  };

  void start() {
    if (_subscription != null) {
      return;
    }
    // Entries read back from the disk at start are old news.
    _since = _now() - 5000;
    _subscription = node.store.added.listen(_onAdded);
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  void _onAdded(LogEntry entry) {
    if (!node.isReady ||
        entry.account != node.account ||
        entry.writer != node.author.writer ||
        entry.hlc.millis < _since ||
        _skippedKinds.contains(entry.kind) ||
        !(entry.space.startsWith('feed/') || entry.space.startsWith('acts/')) ||
        entry.encodedLength > maxBytes) {
      return;
    }
    if (_queued.length >= maxQueued) {
      _queued.removeAt(0);
    }
    _queued.add(entry);
    _timer ??= Timer(delay, () {
      _timer = null;
      unawaitedLogged(flush(), context: 'Pushing entries to friends failed');
    });
  }

  /// Hands what was written lately to every friend who is offline; returns
  /// how many pushes were queued.
  Future<int> flush() async {
    _timer?.cancel();
    _timer = null;
    if (_queued.isEmpty) {
      return 0;
    }
    final List<LogEntry> entries = List<LogEntry>.of(_queued);
    _queued.clear();
    final List<List<Map<String, dynamic>>> batches = _batches(entries);
    final int now = _now();
    int pushed = 0;
    for (final String friend in node.friendAccounts.keys) {
      final String address = PeerShareCodec.normalizeAddress(friend);
      if (isOnline(address) || node.isUnlinkedAddress(address)) {
        continue; // the sync brings it; an unlinked device gets nothing
      }
      final List<int> recent = (_pushedAt[address] ??= <int>[])
        ..removeWhere(
          (int at) => now - at >= const Duration(hours: 1).inMilliseconds,
        );
      for (final List<Map<String, dynamic>> batch in batches) {
        if (recent.length >= maxPushesPerHour) {
          break; // the sync catches up later
        }
        recent.add(now);
        try {
          await send(address, <String, dynamic>{
            'type': kLedgerPushType,
            'entries': batch,
          });
          pushed++;
        } on Object catch (error) {
          logZenWarning('Pushing entries to $address failed: $error');
        }
      }
    }
    return pushed;
  }

  List<List<Map<String, dynamic>>> _batches(List<LogEntry> entries) {
    final List<List<Map<String, dynamic>>> batches =
        <List<Map<String, dynamic>>>[];
    List<Map<String, dynamic>> batch = <Map<String, dynamic>>[];
    int bytes = 0;
    for (final LogEntry entry in entries) {
      if (batch.isNotEmpty && bytes + entry.encodedLength > maxBytes) {
        batches.add(batch);
        batch = <Map<String, dynamic>>[];
        bytes = 0;
      }
      batch.add(entry.toJson());
      bytes += entry.encodedLength;
    }
    if (batch.isNotEmpty) {
      batches.add(batch);
    }
    return batches;
  }
}
