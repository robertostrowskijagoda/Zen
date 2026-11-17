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

  /// Its device's certificate (which publishes the key the entry is
  /// checked with) is not known here yet: kept aside **unchecked** until
  /// the certificate comes ([LedgerStore.addCertificate]; the replicator
  /// asks the peer that sent the entry). Never part of a log before.
  awaitingCertificate,

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

  /// Entries `base + 1` … [head], in order.
  final List<LogEntry> entries = <LogEntry>[];
  final Map<int, LogEntry> pending = <int, LogEntry>{};
  bool forked = false;

  /// The last entry not held: the log is held from its writer's checkpoint
  /// `base + 1` on (0: from the first entry).
  int base = 0;

  /// Id of entry [base] (what entry `base + 1` names in `prev`).
  String baseId = '';

  /// Bytes of [entries] and [pending].
  int bytes = 0;

  /// Held checkpoints that say how many entries after them carry the state
  /// from before them ([rebaseCountOf]), oldest first: `(seq, count)`.
  final List<(int, int)> rebases = <(int, int)>[];

  /// The sender of a checkpoint waiting past a gap holds the log only from
  /// there, but the entries it says carry the state have not all come:
  /// the log moves to it once they have ([LedgerStore.adoptCheckpoint]).
  bool adoptWanted = false;

  /// Entries of this log that held carriers carry ([carriedIn]), by
  /// sequence number. Those up to [base] are what still counts of the part
  /// of the log not held ([carriedBefore]); the others are held anyway.
  final Map<int, LogEntry> carried = <int, LogEntry>{};

  int get head => base + entries.length;
  String get lastId => entries.isEmpty ? baseId : entries.last.id;

  /// What still counts of the log before [base], by its writer's folds.
  Iterable<LogEntry> get carriedBefore =>
      carried.values.where((LogEntry e) => e.seq <= base);

  /// Entry [seq], when held.
  LogEntry? at(int seq) =>
      seq > base && seq <= head ? entries[seq - base - 1] : null;

  /// Reads again what the held carriers carry.
  void recarry() {
    carried.clear();
    for (final LogEntry entry in entries) {
      _carry(entry);
    }
  }

  /// The entries [entry] carries that were not carried before.
  List<LogEntry> _carry(LogEntry entry) {
    if (entry.kind != kLedgerCarryKind) {
      return const <LogEntry>[];
    }
    final List<LogEntry> fresh = <LogEntry>[];
    for (final LogEntry e in carriedIn(entry)) {
      if (carried[e.seq]?.id != e.id) {
        fresh.add(e);
      }
      carried[e.seq] = e;
    }
    return fresh;
  }

  /// Starts the log after entry [newBase] (id [newBaseId]): every held
  /// entry and every pending one up to it goes.
  void startAfter(int newBase, String newBaseId) {
    for (final LogEntry entry in entries) {
      bytes -= entry.encodedLength;
    }
    entries.clear();
    rebases.clear();
    carried.clear();
    for (final int seq in pending.keys.toList()) {
      if (seq <= newBase) {
        bytes -= pending.remove(seq)!.encodedLength;
      }
    }
    base = newBase;
    baseId = newBaseId;
  }

  /// Drops the held entries before [seq] (a checkpoint held here).
  void dropBefore(int seq) {
    final LogEntry? first = at(seq);
    if (first == null) {
      return;
    }
    final int cut = seq - base - 1;
    for (int i = 0; i < cut; i++) {
      bytes -= entries[i].encodedLength;
    }
    entries.removeRange(0, cut);
    base = seq - 1;
    baseId = first.prev;
    rebases.removeWhere(((int, int) r) => r.$1 <= base);
    recarry();
  }

  /// Appends [entry]; returns the entries from before [base] it carries
  /// that were not carried before (a fold's carrier, [kLedgerCarryKind]).
  List<LogEntry> add(LogEntry entry) {
    entries.add(entry);
    bytes += entry.encodedLength;
    final int? count = startCountOf(entry);
    if (count != null) {
      rebases.add((entry.seq, count));
    }
    return <LogEntry>[
      for (final LogEntry e in _carry(entry))
        if (e.seq <= base) e,
    ];
  }

  /// The newest held checkpoint whose entries carrying the state are all
  /// held too, with something before it still held; `null` when none.
  int? readyRebase() {
    for (final (int seq, int count) in rebases.reversed) {
      if (seq + count <= head) {
        return seq > base + 1 ? seq : null;
      }
    }
    return null;
  }

  void addPending(LogEntry entry) {
    pending[entry.seq] = entry;
    bytes += entry.encodedLength;
  }

  LogEntry? takePending(int seq) {
    final LogEntry? entry = pending.remove(seq);
    if (entry != null) {
      bytes -= entry.encodedLength;
    }
    return entry;
  }

  void clearPending() {
    for (final LogEntry entry in pending.values) {
      bytes -= entry.encodedLength;
    }
    pending.clear();
  }

  /// Keeps the entries up to [keep] (a sequence number).
  void truncate(int keep) {
    final int from = keep <= base ? 0 : keep - base;
    for (int i = from; i < entries.length; i++) {
      bytes -= entries[i].encodedLength;
    }
    if (from < entries.length) {
      entries.removeRange(from, entries.length);
    }
    rebases.removeWhere(((int, int) r) => r.$1 > head);
    recarry();
  }

  /// Marks the log as keeping two histories: nothing more is taken.
  void fork() {
    forked = true;
    clearPending();
  }
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
    this.maxAwaitingCertificate = 1024,
    this.maxBoundedOwnerBytes = kMaxUnknownOwnerBytes,
    this.maxBoundedBytes = kMaxUnknownBytes,
  }) : directory = directory ?? AccountDirectory(),
       clock = clock ?? HlcClock(),
       _policies = policies ?? defaultSpacePolicy {
    // Whether a device waited its day is judged on this store's clock.
    this.directory.now = this.clock.wallMillis;
  }

  final AccountDirectory directory;
  final HlcClock clock;
  final SpacePolicyResolver _policies;
  final int maxPendingPerLog;

  /// Most entries kept aside, in all, for certificates not known yet.
  final int maxAwaitingCertificate;

  /// `account|device` → entries (by id) waiting for that device's
  /// certificate; unchecked.
  final Map<String, Map<String, LogEntry>> _awaiting =
      <String, Map<String, LogEntry>>{};
  int _awaitingCount = 0;

  /// Most bytes held in [BoundedSpacePolicy] spaces of one owner.
  final int maxBoundedOwnerBytes;

  /// Most bytes held in all [BoundedSpacePolicy] spaces together.
  final int maxBoundedBytes;

  /// space → writer → log
  final Map<String, Map<String, _WriterLog>> _logs =
      <String, Map<String, _WriterLog>>{};

  /// Spaces held under a [BoundedSpacePolicy] → their owner.
  final Map<String, String> _boundedOwners = <String, String>{};

  /// Accounts whose entries this user refuses (their own block list).
  final Set<String> blockedAccounts = <String>{};

  /// This device's own account: its spaces are kept whole, whatever
  /// [AccountSpacePolicy.maxBytes] says.
  String? ownAccount;

  /// Spaces of other accounts that reached their bound
  /// ([AccountSpacePolicy.maxBytes]) and refuse what comes next.
  final Set<String> _full = <String>{};

  /// Spaces that refuse new entries for want of room ([_overQuota]).
  Set<String> get fullSpaces => Set<String>.unmodifiable(_full);

  /// Called when [fullSpaces] changes.
  void Function()? onFullChanged;

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

  /// Where the held part of a log starts: entries after `base` are held,
  /// `baseId` is the id of entry `base` ((0, '') for a log held whole).
  ({int base, String baseId}) baseOf(String space, String writer) {
    final _WriterLog? log = _logs[space]?[writer];
    return log == null
        ? (base: 0, baseId: '')
        : (base: log.base, baseId: log.baseId);
  }

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
    // Entries before the log's start are not held: it goes on from there.
    final int start = afterSeq < log.base ? log.base : afterSeq;
    final int end = (start + limit) < log.head ? start + limit : log.head;
    return log.entries.sublist(start - log.base, end - log.base);
  }

  /// All entries of [space] (every device), oldest first by HLC: those
  /// held, and those its writers' folds carried from before where a log is
  /// held from ([kLedgerFoldKind]), as they were written.
  List<LogEntry> entries(String space) {
    final List<LogEntry> all = <LogEntry>[
      for (final _WriterLog log
          in (_logs[space] ?? const <String, _WriterLog>{})
              .values) ...<LogEntry>[...log.carriedBefore, ...log.entries],
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
      for (final LogEntry e in log.carriedBefore) {
        if (e.id == id) {
          return e;
        }
      }
    }
    return null;
  }

  /// The entries of [writer] in [space] as its readers see them: what its
  /// folds carried from before where the log is held from, then what is
  /// held, in log order.
  List<LogEntry> logView(String space, String writer) {
    final _WriterLog? log = _logs[space]?[writer];
    if (log == null) {
      return const <LogEntry>[];
    }
    return <LogEntry>[
      ...log.carriedBefore.toList()
        ..sort((LogEntry a, LogEntry b) => a.seq.compareTo(b.seq)),
      ...log.entries,
    ];
  }

  /// Takes one entry from anywhere (JSON as received).
  Future<IngestResult> ingestJson(Object? json) async {
    final LogEntry? entry = LogEntry.fromJson(json);
    if (entry == null) {
      return const IngestResult(IngestStatus.rejected, 'nieprawidłowy wpis');
    }
    return ingest(entry);
  }

  Future<IngestResult> ingest(LogEntry received) async {
    final IngestResult? early = _precheck(received);
    if (early != null) {
      return early;
    }
    final DeviceCertificate? carried = received.certificate;
    if (carried != null && !await directory.addCertificate(carried)) {
      return const IngestResult(IngestStatus.rejected, 'zły certyfikat');
    }
    // The certificate kept here (a device keeps its first one, with what
    // co-signed it since), not the one the entry carried.
    final DeviceCertificate? cert =
        directory.certificateOf(received.account, received.device) ?? carried;
    if (cert == null) {
      return _awaitCertificate(received);
    }
    final LogEntry entry = identical(cert, carried)
        ? received
        : received.withCertificate(cert);
    if (!await entry.verifySignature()) {
      return const IngestResult(IngestStatus.rejected, 'zły podpis');
    }
    // State may have moved while verifying; decide on the current one.
    final IngestResult? late = _precheck(entry);
    if (late != null) {
      return late;
    }
    final Map<String, _WriterLog> space = _space(entry.space);
    final _WriterLog log = space[entry.writer] ??= _WriterLog(
      entry.account,
      entry.device,
    );
    clock.observe(entry.hlc);

    if (log.head == 0 && entry.seq > 1 && startsLog(entry)) {
      // Nothing held yet and the writer's checkpoint (or fold) arrives: the
      // log may start here (those who hand it on may have cut what came
      // before).
      log.startAfter(entry.seq - 1, entry.prev);
    }
    if (entry.seq <= log.head) {
      // Only reachable for a different id at a taken position (duplicates
      // were caught in the precheck).
      log.fork();
      _changed.add(null);
      return const IngestResult(IngestStatus.forked, 'dwa wpisy o tym numerze');
    }
    final LogEntry? waiting = log.pending[entry.seq];
    if (waiting != null) {
      if (waiting.id == entry.id) {
        return const IngestResult(IngestStatus.duplicate);
      }
      log.fork();
      _changed.add(null);
      return const IngestResult(IngestStatus.forked, 'dwa wpisy o tym numerze');
    }
    if (entry.seq > log.head + 1) {
      if (log.pending.length >= maxPendingPerLog) {
        return const IngestResult(IngestStatus.rejected, 'za dużo zaległych');
      }
      log.addPending(entry);
      // A full space refuses what comes next until its writer folds: the
      // fold waits past the refused entries, so the log moves to it.
      if (log.adoptWanted || _full.contains(entry.space)) {
        adoptCheckpoint(entry.space, entry.writer);
      }
      return const IngestResult(IngestStatus.pending);
    }
    if (!_append(log, entry)) {
      return const IngestResult(IngestStatus.forked, 'zerwany łańcuch');
    }
    _drain(log);
    return const IngestResult(IngestStatus.added);
  }

  static String _deviceKey(String account, String device) => '$account|$device';

  IngestResult _awaitCertificate(LogEntry entry) {
    final String key = _deviceKey(entry.account, entry.device);
    final Map<String, LogEntry>? had = _awaiting[key];
    if (had != null && had.containsKey(entry.id)) {
      return const IngestResult(IngestStatus.awaitingCertificate);
    }
    if ((had?.length ?? 0) >= maxPendingPerLog) {
      return const IngestResult(
        IngestStatus.rejected,
        'za dużo wpisów bez certyfikatu',
      );
    }
    // Full: the device that has waited longest goes (its entries come
    // again with the next sync).
    while (_awaitingCount >= maxAwaitingCertificate && _awaiting.isNotEmpty) {
      final String oldest = _awaiting.keys.first;
      _awaitingCount -= _awaiting.remove(oldest)!.length;
    }
    (_awaiting[key] ??= <String, LogEntry>{})[entry.id] = entry;
    _awaitingCount++;
    return const IngestResult(
      IngestStatus.awaitingCertificate,
      'brak certyfikatu urządzenia',
    );
  }

  /// Whether entries of [device] of [account] wait for its certificate.
  bool awaitsCertificate(String account, String device) =>
      _awaiting.containsKey(_deviceKey(account, device));

  /// Takes the certificate of a device whose entries wait for it: checks
  /// it, keeps it, then checks and takes the entries. Returns how many
  /// became new (added or pending), or -1 for a certificate that does not
  /// hold.
  Future<int> addCertificate(DeviceCertificate cert) async {
    if (!await directory.addCertificate(cert)) {
      return -1;
    }
    final Map<String, LogEntry>? waiting = _awaiting.remove(
      _deviceKey(cert.account, cert.device),
    );
    if (waiting == null) {
      return 0;
    }
    _awaitingCount -= waiting.length;
    final List<LogEntry> entries = waiting.values.toList()
      ..sort((LogEntry a, LogEntry b) {
        final int byLog = '${a.space}|${a.writer}'.compareTo(
          '${b.space}|${b.writer}',
        );
        return byLog != 0 ? byLog : a.seq.compareTo(b.seq);
      });
    int taken = 0;
    for (final LogEntry entry in entries) {
      if ((await ingest(entry)).isNew) {
        taken++;
      }
    }
    return taken;
  }

  /// Whether entries of any device of [account] wait for a certificate.
  bool awaitsAccount(String account) =>
      _awaiting.keys.any((String key) => key.startsWith('$account|'));

  /// Every account with a log held here in a space [inSpace] admits.
  Set<String> accountsIn({bool Function(String space)? inSpace}) {
    final Set<String> out = <String>{};
    for (final MapEntry<String, Map<String, _WriterLog>> space
        in _logs.entries) {
      if (inSpace != null && !inSpace(space.key)) {
        continue;
      }
      for (final _WriterLog log in space.value.values) {
        out.add(log.account);
      }
    }
    return out;
  }

  /// Whether this store holds a log of [device] of [account] in a space
  /// [inSpace] admits (whose certificate it may then hand out).
  bool holdsLogOf(
    String account,
    String device, {
    bool Function(String space)? inSpace,
  }) {
    for (final MapEntry<String, Map<String, _WriterLog>> space
        in _logs.entries) {
      if (inSpace != null && !inSpace(space.key)) {
        continue;
      }
      for (final _WriterLog log in space.value.values) {
        if (log.account == account && log.device == device) {
          return true;
        }
      }
    }
    return false;
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
      if (entry.seq <= log.base) {
        // Before the checkpoint the log is held from: not kept here.
        return const IngestResult(IngestStatus.duplicate, 'przed początkiem');
      }
      if (entry.seq <= log.head && log.at(entry.seq)?.id == entry.id) {
        return const IngestResult(IngestStatus.duplicate);
      }
    }
    // Only what would be stored counts (a second entry at a taken position
    // is a fork, not more data).
    if (policy is BoundedSpacePolicy &&
        (log == null || entry.seq > log.head) &&
        log?.pending[entry.seq]?.id != entry.id) {
      return _overBound(entry, policy, log);
    }
    if (policy is AccountSpacePolicy &&
        entry.account != ownAccount &&
        (log == null || entry.seq > log.head) &&
        log?.pending[entry.seq]?.id != entry.id) {
      if (policy.maxBytes case final int quota) {
        return _overQuota(entry, quota);
      }
    }
    return null;
  }

  /// Why [entry] would take its space past [quota] bytes; `null` when it
  /// fits. What its writers' folds said no longer counts goes first, oldest
  /// first ([pruneBefore]); then new entries are refused, and the space is
  /// listed in [fullSpaces]: never anything still current. A fold's own
  /// entries may take up to twice the bound for the while before what
  /// they replace goes.
  IngestResult? _overQuota(LogEntry entry, int quota) {
    final String space = entry.space;
    final int size = entry.encodedLength;
    final int limit =
        entry.kind == kLedgerFoldKind || entry.kind == kLedgerCarryKind
        ? 2 * quota
        : quota;
    if (_bytesOf(space) + size <= limit) {
      return null;
    }
    for (final MapEntry<String, _WriterLog> e
        in (_logs[space] ?? const <String, _WriterLog>{}).entries.toList()) {
      final int? ready = e.value.forked ? null : e.value.readyRebase();
      if (ready != null) {
        pruneBefore(space, e.key, ready);
      }
    }
    if (_bytesOf(space) + size <= limit) {
      return null;
    }
    if (_full.add(space)) {
      onFullChanged?.call();
    }
    return const IngestResult(IngestStatus.rejected, 'limit miejsca');
  }

  /// Takes [space] off [fullSpaces] once it has room again.
  void _recheckFull(String space) {
    if (!_full.contains(space)) {
      return;
    }
    final SpacePolicy? policy = _policies(space);
    final int? quota = policy is AccountSpacePolicy ? policy.maxBytes : null;
    if (quota == null || _bytesOf(space) < quota) {
      _full.remove(space);
      onFullChanged?.call();
    }
  }

  /// The logs of [space], created on first use.
  Map<String, _WriterLog> _space(String space) {
    final Map<String, _WriterLog>? held = _logs[space];
    if (held != null) {
      return held;
    }
    if (_policies(space) case final BoundedSpacePolicy bounded) {
      _boundedOwners[space] = bounded.owner;
    }
    return _logs[space] = <String, _WriterLog>{};
  }

  int _bytesOf(String space) {
    int bytes = 0;
    for (final _WriterLog log
        in (_logs[space] ?? const <String, _WriterLog>{}).values) {
      bytes += log.bytes;
    }
    return bytes;
  }

  /// Why [entry] would take [policy]'s space (or its owner's, or all
  /// bounded spaces) past its limits; `null` when it fits.
  IngestResult? _overBound(
    LogEntry entry,
    BoundedSpacePolicy policy,
    _WriterLog? log,
  ) {
    if (log == null && (_logs[entry.space]?.length ?? 0) >= policy.maxWriters) {
      return const IngestResult(IngestStatus.rejected, 'za dużo urządzeń');
    }
    final int size = entry.encodedLength;
    if (_bytesOf(entry.space) + size > policy.maxBytes) {
      return const IngestResult(IngestStatus.rejected, 'przestrzeń pełna');
    }
    int owner = 0;
    int total = 0;
    for (final MapEntry<String, String> held in _boundedOwners.entries) {
      final int bytes = _bytesOf(held.key);
      total += bytes;
      if (held.value == policy.owner) {
        owner += bytes;
      }
    }
    if (owner + size > maxBoundedOwnerBytes || total + size > maxBoundedBytes) {
      return const IngestResult(IngestStatus.rejected, 'brak miejsca');
    }
    return null;
  }

  bool _append(_WriterLog log, LogEntry entry) {
    if (entry.prev != log.lastId) {
      // Signed by the device but chained to something else: it keeps two
      // histories.
      log.fork();
      _changed.add(null);
      return false;
    }
    final List<LogEntry> carried = log.add(entry);
    _added.add(entry);
    // What a fold carried from before where this log is held from is new
    // here too (a log taken from its writer's fold on).
    for (final LogEntry e in carried) {
      _added.add(e);
    }
    _changed.add(null);
    return true;
  }

  void _drain(_WriterLog log) {
    while (!log.forked) {
      final LogEntry? next = log.takePending(log.head + 1);
      if (next == null || !_append(log, next)) {
        return;
      }
    }
  }

  /// Moves a log of [writer] in [space] to start at the writer's
  /// checkpoint waiting past a gap: for when the peer that sent it holds
  /// the log only from that checkpoint on (it was cut there), so the gap
  /// will never be filled. Everything held before it goes. Returns whether
  /// the log moved.
  ///
  /// A checkpoint that says which entries after it carry the state from
  /// before it ([rebaseCountOf]) is moved to only once all of them wait
  /// here as well: a peer handing on the checkpoint alone (cut short, or
  /// holding the rest back) cannot make this store give up the last whole
  /// state it holds. The log then moves when they come.
  bool adoptCheckpoint(String space, String writer) {
    final _WriterLog? log = _logs[space]?[writer];
    if (log == null || log.forked) {
      return false;
    }
    final List<int> waiting =
        log.pending.keys.where((int seq) => seq > log.head + 1).toList()
          ..sort();
    // Nothing to wait for once no checkpoint waits past a gap.
    log.adoptWanted = false;
    for (final int seq in waiting) {
      final LogEntry checkpoint = log.pending[seq]!;
      if (!startsLog(checkpoint)) {
        continue;
      }
      final int? count = startCountOf(checkpoint);
      if (count != null) {
        bool whole = true;
        for (int next = seq + 1; next <= seq + count; next++) {
          if (!log.pending.containsKey(next)) {
            whole = false;
            break;
          }
        }
        if (!whole) {
          log.adoptWanted = true;
          continue;
        }
      }
      log.adoptWanted = false;
      log.startAfter(seq - 1, checkpoint.prev);
      _drain(log);
      _recheckFull(space);
      _changed.add(null);
      return true;
    }
    return false;
  }

  /// The newest held checkpoint of [writer] in [space] whose entries
  /// carrying the state from before it ([rebaseCountOf]) are all held,
  /// with something before it still held: what may be dropped up to by
  /// [pruneBefore]. `null` when there is none.
  int? readyRebase(String space, String writer) {
    final _WriterLog? log = _logs[space]?[writer];
    return log == null || log.forked ? null : log.readyRebase();
  }

  /// Bytes of the entries of [writer] in [space] held here (those waiting
  /// past a gap not counted).
  int heldBytes(String space, String writer) {
    final _WriterLog? log = _logs[space]?[writer];
    if (log == null) {
      return 0;
    }
    int bytes = 0;
    for (final LogEntry entry in log.entries) {
      bytes += entry.encodedLength;
    }
    return bytes;
  }

  /// Takes [run], new entries of one log of this device, each following
  /// the one before and the first following what is held: all are checked
  /// first, then all join the log in one go, so nothing listening (a save,
  /// a peer's sync) ever sees only some of them. Returns false, taking
  /// none, when any does not hold.
  Future<bool> ingestRun(List<LogEntry> run) async {
    if (run.isEmpty) {
      return true;
    }
    final List<LogEntry> checked = <LogEntry>[];
    for (final LogEntry received in run) {
      if (received.space != run.first.space ||
          received.writer != run.first.writer ||
          _precheck(received) != null) {
        return false;
      }
      final DeviceCertificate? carried = received.certificate;
      if (carried != null && !await directory.addCertificate(carried)) {
        return false;
      }
      final DeviceCertificate? cert =
          directory.certificateOf(received.account, received.device) ?? carried;
      if (cert == null) {
        return false;
      }
      final LogEntry entry = identical(cert, carried)
          ? received
          : received.withCertificate(cert);
      if (!await entry.verifySignature()) {
        return false;
      }
      checked.add(entry);
    }
    // Decided on the state as it is now, with nothing awaited in between.
    final LogEntry first = checked.first;
    final _WriterLog? had = _logs[first.space]?[first.writer];
    String last = had?.lastId ?? '';
    int seq = had?.head ?? 0;
    for (final LogEntry entry in checked) {
      if (_precheck(entry) != null ||
          entry.seq != seq + 1 ||
          entry.prev != last ||
          (had?.pending.containsKey(entry.seq) ?? false)) {
        return false;
      }
      seq = entry.seq;
      last = entry.id;
    }
    final _WriterLog log = _space(first.space)[first.writer] ??= _WriterLog(
      first.account,
      first.device,
    );
    for (final LogEntry entry in checked) {
      clock.observe(entry.hlc);
      log.add(entry);
      _added.add(entry);
    }
    _changed.add(null);
    return true;
  }

  /// Drops the entries of a log before its writer's checkpoint [seq] (held
  /// here): the log is then held, and handed on, from that checkpoint.
  /// Returns how many entries went (0 when [seq] is no checkpoint held).
  int pruneBefore(String space, String writer, int seq) {
    final _WriterLog? log = _logs[space]?[writer];
    final LogEntry? checkpoint = log?.at(seq);
    if (log == null || checkpoint == null || !startsLog(checkpoint)) {
      return 0;
    }
    final int before = log.entries.length;
    log.dropBefore(seq);
    final int removed = before - log.entries.length;
    if (removed > 0) {
      _recheckFull(space);
      _changed.add(null);
    }
    return removed;
  }

  /// Puts back where a log read from our own storage starts (before its
  /// entries, [restore]): after entry [base] whose id is [baseId].
  void restoreBase(String space, String writer, int base, String baseId) {
    if (base <= 0 || _policies(space) == null) {
      return;
    }
    final _WriterLog? log = _logs[space]?[writer];
    if (log != null && log.head > 0) {
      return;
    }
    _pendingBases['$space|$writer'] = (base: base, baseId: baseId);
  }

  /// Bases read back ([restoreBase]) for logs whose first entry is not
  /// restored yet.
  final Map<String, ({int base, String baseId})> _pendingBases =
      <String, ({int base, String baseId})>{};

  /// Puts back an entry read from our own storage: it was fully checked
  /// when it first arrived, so only the chain is checked again (a damaged
  /// file must not produce a broken log) and its device's certificate must
  /// be known (restored first). Returns false when it does not fit.
  bool restore(LogEntry stored) {
    final DeviceCertificate? cert =
        stored.certificate ??
        directory.certificateOf(stored.account, stored.device);
    if (_policies(stored.space) == null || cert == null) {
      return false;
    }
    final LogEntry entry = stored.certificate == null
        ? stored.withCertificate(cert)
        : stored;
    final _WriterLog log = _space(entry.space)[entry.writer] ??= _WriterLog(
      entry.account,
      entry.device,
    );
    if (log.head == 0) {
      final ({int base, String baseId})? start = _pendingBases.remove(
        '${entry.space}|${entry.writer}',
      );
      if (start != null) {
        log.startAfter(start.base, start.baseId);
      }
    }
    if (log.account != entry.account ||
        log.device != entry.device ||
        entry.seq != log.head + 1 ||
        entry.prev != log.lastId) {
      return false;
    }
    directory.trustCertificate(cert);
    log.add(entry);
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
    // Every device of the account, not only the one named: in an account
    // that co-signs, a cut-off also leaves out what its signer does not
    // keep, and one cut-off may undo another.
    for (final MapEntry<String, Map<String, _WriterLog>> space
        in _logs.entries) {
      for (final MapEntry<String, _WriterLog> e in space.value.entries) {
        final _WriterLog log = e.value;
        bool allows(int seq) => directory.allowsEntry(
          account: log.account,
          device: log.device,
          writer: e.key,
          seq: seq,
          space: space.key,
        );
        if (log.account != revocation.account || allows(log.head + 1)) {
          continue;
        }
        log.clearPending();
        if (log.head == log.base || allows(log.head)) {
          continue;
        }
        // What a cut-off allows is a start of the log: the last entry
        // allowed is found by halves.
        int low = log.base;
        int high = log.head - 1;
        while (low < high) {
          final int mid = (low + high + 1) ~/ 2;
          if (allows(mid)) {
            low = mid;
          } else {
            high = mid - 1;
          }
        }
        final int before = log.entries.length;
        log.truncate(low);
        removed += before - log.entries.length;
      }
    }
    _full.toList().forEach(_recheckFull);
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
    _awaiting.removeWhere((String key, Map<String, LogEntry> waiting) {
      if (!key.startsWith('$account|')) {
        return false;
      }
      _awaitingCount -= waiting.length;
      return true;
    });
    _full.toList().forEach(_recheckFull);
    _changed.add(null);
  }

  Future<void> dispose() async {
    await _added.close();
    await _changed.close();
  }
}
