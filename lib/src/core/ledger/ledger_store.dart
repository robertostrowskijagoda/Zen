import 'dart:async';

import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';

enum IngestStatus {
  /// New, verified and appended (possibly together with earlier-arrived
  /// successors that were waiting for it).
  added,

  /// Already had it.
  duplicate,

  /// Verified, but an earlier entry of its log is still missing; kept aside
  /// until the gap is filled.
  pending,

  /// Malformed, bad signature, not allowed in this space, from the future,
  /// revoked, blocked, or its log is known to be forked.
  rejected,

  /// A second, different entry for a position that is already taken: the
  /// device signed two histories. The log is frozen from here on.
  forked,
}

final class IngestResult {
  const IngestResult(this.status, [this.reason = '']);

  final IngestStatus status;
  final String reason;

  bool get isNew =>
      status == IngestStatus.added || status == IngestStatus.pending;

  @override
  String toString() => reason.isEmpty ? status.name : '${status.name}: $reason';
}

final class _WriterLog {
  _WriterLog(this.account, this.device);

  final String account;
  final String device;
  final List<LogEntry> entries = <LogEntry>[];
  final Map<int, LogEntry> pending = <int, LogEntry>{};
  bool forked = false;

  int get head => entries.length;
  String get lastId => entries.isEmpty ? '' : entries.last.id;
}

typedef SpacePolicyResolver = SpacePolicy? Function(String space);

/// Every log this device holds, checked on the way in.
///
/// Order-independent: entries may arrive in any order, from anyone, any
/// number of times; the result is the same.
final class LedgerStore {
  LedgerStore({
    AccountDirectory? directory,
    HlcClock? clock,
    SpacePolicyResolver? policies,
    this.maxPendingPerLog = 512,
  }) : directory = directory ?? AccountDirectory(),
       clock = clock ?? HlcClock(),
       _policies = policies ?? defaultSpacePolicy;

  final AccountDirectory directory;
  final HlcClock clock;
  final SpacePolicyResolver _policies;
  final int maxPendingPerLog;

  /// space → writer → log
  final Map<String, Map<String, _WriterLog>> _logs =
      <String, Map<String, _WriterLog>>{};

  /// Accounts whose entries this user refuses (their own block list).
  final Set<String> blockedAccounts = <String>{};

  final StreamController<LogEntry> _added =
      StreamController<LogEntry>.broadcast(sync: true);

  /// Every entry that became part of a log, in log order.
  Stream<LogEntry> get added => _added.stream;

  final StreamController<void> _changed = StreamController<void>.broadcast(
    sync: true,
  );

  /// Anything worth saving changed (entries added or removed, blocks).
  Stream<void> get changed => _changed.stream;

  Iterable<String> get spaces => _logs.keys;

  bool holdsSpace(String space) => _logs.containsKey(space);

  /// `writer → last contiguous seq` for [space].
  Map<String, int> heads(String space) => <String, int>{
    for (final MapEntry<String, _WriterLog> e
        in (_logs[space] ?? const <String, _WriterLog>{}).entries)
      if (e.value.head > 0) e.key: e.value.head,
  };

  int headOf(String space, String writer) => _logs[space]?[writer]?.head ?? 0;

  String lastIdOf(String space, String writer) =>
      _logs[space]?[writer]?.lastId ?? '';

  bool isForked(String space, String writer) =>
      _logs[space]?[writer]?.forked ?? false;

  /// Entries of [writer] in [space] after [afterSeq], in order.
  List<LogEntry> entriesAfter(
    String space,
    String writer,
    int afterSeq, {
    int limit = 1 << 30,
  }) {
    final _WriterLog? log = _logs[space]?[writer];
    if (log == null || afterSeq >= log.head) {
      return const <LogEntry>[];
    }
    final int start = afterSeq < 0 ? 0 : afterSeq;
    final int end = (start + limit) < log.head ? start + limit : log.head;
    return log.entries.sublist(start, end);
  }

  /// All entries of [space] (every device), oldest first by HLC.
  List<LogEntry> entries(String space) {
    final List<LogEntry> all = <LogEntry>[
      for (final _WriterLog log
          in (_logs[space] ?? const <String, _WriterLog>{}).values)
        ...log.entries,
    ];
    all.sort((LogEntry a, LogEntry b) {
      final int byTime = a.hlc.compareTo(b.hlc);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    return all;
  }

  LogEntry? entryById(String space, String id) {
    for (final _WriterLog log
        in (_logs[space] ?? const <String, _WriterLog>{}).values) {
      for (final LogEntry e in log.entries) {
        if (e.id == id) {
          return e;
        }
      }
    }
    return null;
  }

  /// Takes one entry from anywhere (JSON as received).
  Future<IngestResult> ingestJson(Object? json) async {
    final LogEntry? entry = LogEntry.fromJson(json);
    if (entry == null) {
      return const IngestResult(IngestStatus.rejected, 'nieprawidłowy wpis');
    }
    return ingest(entry);
  }

  Future<IngestResult> ingest(LogEntry entry) async {
    final IngestResult? early = _precheck(entry);
    if (early != null) {
      return early;
    }
    if (!await directory.addCertificate(entry.certificate)) {
      return const IngestResult(IngestStatus.rejected, 'zły certyfikat');
    }
    if (!await entry.verifySignature()) {
      return const IngestResult(IngestStatus.rejected, 'zły podpis');
    }
    // State may have moved while verifying; decide on the current one.
    final IngestResult? late = _precheck(entry);
    if (late != null) {
      return late;
    }
    final Map<String, _WriterLog> space = _logs[entry.space] ??=
        <String, _WriterLog>{};
    final _WriterLog log = space[entry.writer] ??= _WriterLog(
      entry.account,
      entry.device,
    );
    clock.observe(entry.hlc);

    if (entry.seq <= log.head) {
      // Only reachable for a different id at a taken position (duplicates
      // were caught in the precheck).
      log
        ..forked = true
        ..pending.clear();
      _changed.add(null);
      return const IngestResult(IngestStatus.forked, 'dwa wpisy o tym numerze');
    }
    final LogEntry? waiting = log.pending[entry.seq];
    if (waiting != null) {
      if (waiting.id == entry.id) {
        return const IngestResult(IngestStatus.duplicate);
      }
      log
        ..forked = true
        ..pending.clear();
      _changed.add(null);
      return const IngestResult(IngestStatus.forked, 'dwa wpisy o tym numerze');
    }
    if (entry.seq > log.head + 1) {
      if (log.pending.length >= maxPendingPerLog) {
        return const IngestResult(IngestStatus.rejected, 'za dużo zaległych');
      }
      log.pending[entry.seq] = entry;
      return const IngestResult(IngestStatus.pending);
    }
    if (!_append(log, entry)) {
      return const IngestResult(IngestStatus.forked, 'zerwany łańcuch');
    }
    _drain(log);
    return const IngestResult(IngestStatus.added);
  }

  IngestResult? _precheck(LogEntry entry) {
    final SpacePolicy? policy = _policies(entry.space);
    if (policy == null) {
      return const IngestResult(IngestStatus.rejected, 'nieznana przestrzeń');
    }
    if (!policy.allows(entry)) {
      return const IngestResult(IngestStatus.rejected, 'brak prawa zapisu');
    }
    if (blockedAccounts.contains(entry.account)) {
      return const IngestResult(IngestStatus.rejected, 'zablokowany');
    }
    if (!clock.isAcceptable(entry.hlc)) {
      return const IngestResult(IngestStatus.rejected, 'czas z przyszłości');
    }
    if (!directory.allowsEntry(
      account: entry.account,
      device: entry.device,
      writer: entry.writer,
      seq: entry.seq,
      space: entry.space,
    )) {
      return const IngestResult(IngestStatus.rejected, 'urządzenie odłączone');
    }
    final _WriterLog? log = _logs[entry.space]?[entry.writer];
    if (log != null) {
      if (log.account != entry.account || log.device != entry.device) {
        // A log belongs to one device for good.
        return const IngestResult(IngestStatus.rejected, 'cudzy dziennik');
      }
      if (log.forked) {
        return const IngestResult(IngestStatus.rejected, 'dziennik rozwidlony');
      }
      if (entry.seq <= log.head && log.entries[entry.seq - 1].id == entry.id) {
        return const IngestResult(IngestStatus.duplicate);
      }
    }
    return null;
  }

  bool _append(_WriterLog log, LogEntry entry) {
    if (entry.prev != log.lastId) {
      // Signed by the device but chained to something else: it keeps two
      // histories.
      log
        ..forked = true
        ..pending.clear();
      _changed.add(null);
      return false;
    }
    log.entries.add(entry);
    _added.add(entry);
    _changed.add(null);
    return true;
  }

  void _drain(_WriterLog log) {
    while (!log.forked) {
      final LogEntry? next = log.pending.remove(log.head + 1);
      if (next == null || !_append(log, next)) {
        return;
      }
    }
  }

  /// Puts back an entry read from our own storage: it was fully checked
  /// when it first arrived, so only the chain is checked again (a damaged
  /// file must not produce a broken log). Returns false when it does not
  /// fit.
  bool restore(LogEntry entry) {
    if (_policies(entry.space) == null) {
      return false;
    }
    final _WriterLog log =
        (_logs[entry.space] ??= <String, _WriterLog>{})[entry.writer] ??=
            _WriterLog(entry.account, entry.device);
    if (log.account != entry.account ||
        log.device != entry.device ||
        entry.seq != log.head + 1 ||
        entry.prev != log.lastId) {
      return false;
    }
    directory.trustCertificate(entry.certificate);
    log.entries.add(entry);
    clock.observe(entry.hlc);
    return true;
  }

  /// Marks a log as forked (restored from storage).
  void restoreForked(String space, String writer) {
    _logs[space]?[writer]?.forked = true;
  }

  /// Every log held: `(space, writer, count, forked)`.
  Iterable<(String, String, int, bool)> get logs sync* {
    for (final MapEntry<String, Map<String, _WriterLog>> space
        in _logs.entries) {
      for (final MapEntry<String, _WriterLog> log in space.value.entries) {
        yield (space.key, log.key, log.value.head, log.value.forked);
      }
    }
  }

  /// Drops everything a revocation no longer allows. Returns how many
  /// entries went.
  /// How far every log [device] of [account] wrote is held here
  /// (`writer@space` → entries held): the cut-offs of a revocation that
  /// keeps everything seen so far.
  Map<String, int> headsOfDevice({
    required String account,
    required String device,
  }) {
    return <String, int>{
      for (final MapEntry<String, Map<String, _WriterLog>> space
          in _logs.entries)
        for (final MapEntry<String, _WriterLog> e in space.value.entries)
          if (e.value.account == account && e.value.device == device)
            cutoffKey(e.key, space.key): e.value.head,
    };
  }

  Future<int> applyRevocation(DeviceRevocation revocation) async {
    if (!await directory.addRevocation(revocation)) {
      return -1;
    }
    int removed = 0;
    for (final MapEntry<String, Map<String, _WriterLog>> space
        in _logs.entries) {
      for (final MapEntry<String, _WriterLog> e in space.value.entries) {
        final _WriterLog log = e.value;
        if (log.account != revocation.account ||
            log.device != revocation.device) {
          continue;
        }
        final int keep =
            revocation.cutoffs[cutoffKey(e.key, space.key)] ??
            revocation.cutoffs[e.key] ??
            0;
        if (log.entries.length > keep) {
          removed += log.entries.length - keep;
          log.entries.removeRange(keep, log.entries.length);
        }
        log.pending.clear();
      }
    }
    _changed.add(null);
    return removed;
  }

  /// Blocks [account]: nothing more is accepted from it and what is held
  /// goes.
  void blockAccount(String account) {
    blockedAccounts.add(account);
    for (final Map<String, _WriterLog> space in _logs.values) {
      space.removeWhere((_, _WriterLog log) => log.account == account);
    }
    _changed.add(null);
  }

  Future<void> dispose() async {
    await _added.close();
    await _changed.close();
  }
}
