part of 'pyramid_service.dart';

/// What sealed pyramid messages are bound to.
const String _kPrivContext = 'zen.pyr.priv.v1';

/// How often a member asks the treasurers for their balance statement,
/// and a treasurer syncs the private ledger with the others.
const int kPyrStatementEveryMs = 12 * 3600 * 1000;
const int kPyrLedgerSyncEveryMs = 30 * 60 * 1000;

/// How long somebody who stopped being a treasurer keeps passing their
/// copy of the ledger on (to the new treasurers) before they forget what
/// does not concern them.
const int kPyrHandoverMs = 30 * 24 * 3600 * 1000;

/// About how much of the ledger one sealed frame carries (sealed, it grows
/// by a third: well within [kPyrMaxFrameBytes]).
const int kPyrLedgerFrameBytes = 900 * 1024;

/// The biggest sealed frame sent: a signal's limit, less room for what
/// the transport adds around it.
const int kPyrMaxFrameBytes = kRuntimeSignalMaxBytes - 64 * 1024;

/// Operations a statement carries in full (the newest; the others only by
/// id), each with a majority of signatures, within [kPyrLedgerFrameBytes].
const int kPyrStatementOps = 50;

/// How long after a payment to this person came in its wallet keeps
/// asking the treasurers for a statement that lists it, and how often.
const int kPyrConfirmForMs = 24 * 3600 * 1000;
const int kPyrConfirmEveryMs = 10 * 60 * 1000;

/// How long after offering its ledger to the other treasurers a treasurer
/// waits before it proposes a seal: what it missed (back from being away)
/// comes first.
const int kPyrSealSyncedMs = 10 * 60 * 1000;

/// For how long after an operation's time a treasurer who signed it
/// signs no seal that leaves it out: once most of them signed it, it
/// reaches every treasurer meanwhile (at once, or with the next ledger
/// sync), and a seal without it needs a majority, so the signature of at
/// least one who signed it. Past this, one that never counted is left
/// out; one that counts never is by an honest treasurer.
const int kPyrSealGraceMs = kPyrLedgerSyncEveryMs + kPyrSealSyncedMs;

/// How long a treasurer sees a span of a number split ([PyrLedger.isSplit])
/// before it votes to release it: an operation of it that is final through
/// a signature kept from the treasurers reaches them first from whoever
/// holds it (a payee's phone passes what it gets on at once), and counts.
const int kPyrReleaseWaitMs = 3600 * 1000;

/// Kinds of the sealed messages ([PyramidTypes.priv]).
abstract final class _Priv {
  /// An order or a settlement for a treasurer to sign.
  static const String order = 'ord';

  /// A treasurer's signature back to whoever ordered.
  static const String sig = 'tsig';

  /// A treasurer's refusal back to whoever ordered: why, and the time of
  /// the newest change it counted on the payer's account.
  static const String refuse = 'tno';

  /// Operations that count (or evidence), to treasurers and to those they
  /// concern.
  static const String done = 'fin';

  /// A member asks for their statement; a treasurer's answer.
  static const String ask = 'stq';
  static const String statement = 'st';

  /// Who gets an emission ([PyrEmitNote]).
  static const String note = 'note';

  /// Treasurers' sync: what I have, what I want, here it is.
  static const String digest = 'ldig';
  static const String want = 'lwant';
  static const String ops = 'lops';
}

/// The private side of the pyramid's money on this phone: the ledger (all
/// of it for a treasurer, what concerns this person otherwise), the
/// treasurers' statements of this person's balance, and the sealed
/// messages between payers, the paid and the treasurers. See
/// `pyramid_ledger.dart` for the rules.
final class _Treasury {
  _Treasury(this.pyr);

  final PyramidService pyr;

  static const String _key = 'pyramid/ledger';

  PyrLedger ledger = PyrLedger();

  /// Each treasurer's latest statement of this person's account.
  final Map<String, PyrStatement> statements = <String, PyrStatement>{};

  /// When statements were last asked for, the ledger last synced, and
  /// until when this person was a treasurer.
  int askedAt = 0;
  int syncedAt = 0;
  int treasurerUntil = 0;

  /// After a recovery: the statements (and the operations behind them)
  /// are asked for once the pyramid has this device's address.
  bool _recoverAsk = false;

  /// When this treasurer signed orders of each payer (its own clock, the
  /// last day): the daily limit, whatever time the orders carry.
  final Map<String, List<int>> _signedAt = <String, List<int>>{};

  /// Since when this treasurer sees each span split (slot and the release
  /// it follows): its vote waits [kPyrReleaseWaitMs].
  final Map<String, int> _splitSeen = <String, int>{};

  /// Refusals of this person's orders waiting: order → treasurer → why
  /// ([PyrLedger.refusalCode]) and the time of the newest change it
  /// counted on the account. Kept while the order waits (the orders go
  /// out again, so do the refusals).
  final Map<String, Map<String, (String, int)>> _refusals =
      <String, Map<String, (String, int)>>{};

  /// When a statement was last asked for to confirm payments that came in.
  int _confirmAskedAt = 0;

  /// Bumped on every change of [ledger] or [statements].
  int _rev = 0;
  PyrLedgerView? _view;
  Object? _viewKey;
  PyrLedgerView? _since;
  Object? _sinceKey;

  HybridKeyPair? _kem;
  int _kemSentAt = 0;

  /// The stored ledger could not be read (the disk still locked): nothing
  /// is written over it until a read succeeds.
  bool _unreadable = false;

  // ---- storage ----

  Future<void> load() async {
    ledger = PyrLedger();
    statements.clear();
    _signedAt.clear();
    _splitSeen.clear();
    _refusals.clear();
    _confirmAskedAt = 0;
    _recoverAsk = false;
    _rev++;
    final List<int>? raw;
    try {
      raw = await pyr.disk.read(_key);
    } on Object catch (error, stack) {
      _unreadable = true;
      logZenError('Pyramid: private ledger', error, stack);
      return;
    }
    _unreadable = false;
    try {
      final Object? json = raw == null ? null : jsonDecode(utf8.decode(raw));
      if (json is Map) {
        ledger = PyrLedger.fromJson(json['l']);
        final Object? st = json['st'];
        if (st is List) {
          for (final Object? x in st) {
            final PyrStatement? s = PyrStatement.fromJson(x);
            if (s != null) {
              statements[s.by] = s;
            }
          }
        }
        askedAt = json['ask'] is int ? json['ask'] as int : 0;
        _recoverAsk = json['rcv'] == true;
        treasurerUntil = json['tu'] is int ? json['tu'] as int : 0;
        _signedAt.clear();
        final Object? rl = json['rl'];
        if (rl is Map) {
          for (final MapEntry<dynamic, dynamic> e in rl.entries) {
            if (e.key is String && e.value is List) {
              _signedAt[e.key as String] = (e.value as List)
                  .whereType<int>()
                  .toList();
            }
          }
        }
        _splitSeen.clear();
        final Object? rs = json['rs'];
        if (rs is Map) {
          for (final MapEntry<dynamic, dynamic> e in rs.entries) {
            if (e.key is String && e.value is int) {
              _splitSeen[e.key as String] = e.value as int;
            }
          }
        }
      }
    } on Object catch (error, stack) {
      // Damaged: it comes back from the treasurers.
      logZenError('Pyramid: private ledger', error, stack);
    }
    _rev++;
  }

  Future<void> save() async {
    _rev++;
    if (pyr._diskUnreadable || _unreadable) {
      return;
    }
    await pyr.disk.write(
      _key,
      utf8.encode(
        jsonEncode(<String, dynamic>{
          'l': ledger.toJson(),
          'st': <Map<String, dynamic>>[
            for (final PyrStatement s in statements.values) s.toJson(),
          ],
          'ask': askedAt,
          'tu': treasurerUntil,
          if (_recoverAsk) 'rcv': true,
          if (_signedAt.isNotEmpty) 'rl': _signedAt,
          if (_splitSeen.isNotEmpty) 'rs': _splitSeen,
        }),
      ),
    );
  }

  // ---- keys and seals ----

  /// This person's hybrid KEM key pair, from the pyramid identity's seed
  /// (the same on every device of the account and after recovery).
  Future<HybridKeyPair?> keys() async {
    final HybridKeyPair? had = _kem;
    if (had != null) {
      return had;
    }
    final Uint8List? seed = pyr._seed;
    if (seed == null) {
      return null;
    }
    return _kem = await HybridKeyPair.fromSeed(
      securitySubkey(seed, 'pyramid.kem'),
    );
  }

  /// This person's public KEM key, as the record publishes it.
  Future<String?> publicKey() async {
    final HybridKeyPair? k = await keys();
    return k == null ? null : base64Url.encode(k.publicKey);
  }

  static List<int> _info(String py, String to) =>
      utf8.encode('$_kPrivContext|$py|$to');

  static Uint8List _boxKey(Uint8List secret, Uint8List ciphertext) =>
      securitySubkey(
        Uint8List.fromList(<int>[...secret, ...ciphertext]),
        'pyramid.priv',
      );

  /// [json] sealed to member [to] (their published KEM key) as a frame;
  /// null when they published none.
  static Future<Map<String, dynamic>?> seal(
    Map<String, dynamic> json,
    PyramidState s,
    String to,
  ) async {
    final Uint8List? pk = decodeHybridPublicKey(s.members[to]?.kem);
    if (pk == null) {
      return null;
    }
    final List<int> info = _info(s.id, to);
    final HybridEncapsulation kem = await hybridKem.encapsulate(pk, info: info);
    final Uint8List box = await encryptSecurityBytes(
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
      _boxKey(kem.secret, kem.ciphertext),
      aad: info,
    );
    return <String, dynamic>{
      'type': PyramidTypes.priv,
      'c': base64Url.encode(kem.ciphertext),
      'b': base64Url.encode(box),
    };
  }

  /// A sealed frame opened with this person's key; null when it is not
  /// for them (or damaged).
  Future<Map<String, dynamic>?> open(Map<String, dynamic> p) async {
    final String? me = pyr.myKey;
    final String? py = pyr.current;
    final HybridKeyPair? k = await keys();
    final Object? c = p['c'];
    final Object? b = p['b'];
    if (me == null ||
        py == null ||
        k == null ||
        c is! String ||
        b is! String ||
        b.length > 8 * 1024 * 1024) {
      return null;
    }
    try {
      final Uint8List ct = base64Url.decode(base64Url.normalize(c));
      final List<int> info = _info(py, me);
      final Uint8List secret = await hybridKem.decapsulate(
        k.seed,
        ct,
        info: info,
      );
      final Object? json = jsonDecode(
        utf8.decode(
          await decryptSecurityBytes(
            base64Url.decode(base64Url.normalize(b)),
            _boxKey(secret, ct),
            aad: info,
          ),
        ),
      );
      return json is Map ? Map<String, dynamic>.from(json) : null;
    } on Object {
      return null;
    }
  }

  /// Sends [json] sealed to member [to]; this person's own messages are
  /// handled here at once. False when it could not go: no address or key,
  /// or a frame bigger than a signal may be ([kPyrMaxFrameBytes]) — then
  /// the one who built it sends less.
  Future<bool> sendTo(String to, Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return false;
    }
    if (to == pyr.myKey) {
      await _handle(json);
      return true;
    }
    final String addr = s.members[to]?.addr ?? '';
    if (addr.isEmpty) {
      return false;
    }
    final Map<String, dynamic>? frame = await seal(json, s, to);
    if (frame == null) {
      return false;
    }
    final int size = utf8.encode(jsonEncode(frame)).length;
    if (size > kPyrMaxFrameBytes) {
      logZenError(
        'Pyramid: ${json['k']} frame of $size bytes',
        StateError('over the signal limit of $kPyrMaxFrameBytes bytes'),
        StackTrace.current,
      );
      return false;
    }
    await pyr._send(addr, frame);
    return true;
  }

  /// Sends [ops] (with [rel], the releases they follow) to [to] as
  /// [_Priv.done] frames of about [kPyrLedgerFrameBytes] each: a chain of
  /// operations, each with a majority of signatures, fits in a signal
  /// whatever the number of treasurers.
  /// [ask] goes with the last frame: whose short statement the treasurer
  /// sends back once it took the operations ('a', [_onAsk]).
  Future<void> _sendDone(
    String to,
    List<Map<String, dynamic>> ops,
    List<Map<String, dynamic>> rel, {
    String? ask,
  }) async {
    final List<Map<String, dynamic>> frames = _frames(ops, rel);
    for (int i = 0; i < frames.length; i++) {
      await sendTo(to, <String, dynamic>{
        'k': _Priv.done,
        ...frames[i],
        if (ask != null && i == frames.length - 1) ...<String, dynamic>{
          'a': ask,
          'l': true,
        },
      });
    }
  }

  /// [ops] and [rel] packed into frames ('ops', 'rel') of about
  /// [kPyrLedgerFrameBytes]; one frame (maybe empty) at least.
  static List<Map<String, dynamic>> _frames(
    List<Map<String, dynamic>> ops,
    List<Map<String, dynamic>> rel,
  ) {
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> o = <Map<String, dynamic>>[];
    List<Map<String, dynamic>> r = <Map<String, dynamic>>[];
    int bytes = 0;
    void flush() {
      out.add(<String, dynamic>{'ops': o, if (r.isNotEmpty) 'rel': r});
      o = <Map<String, dynamic>>[];
      r = <Map<String, dynamic>>[];
      bytes = 0;
    }

    // The operations before the releases: a phone that keeps only its own
    // takes the releases of the slots it has operations of.
    for (final (List<Map<String, dynamic>>, bool) part
        in <(List<Map<String, dynamic>>, bool)>[(ops, true), (rel, false)]) {
      for (final Map<String, dynamic> j in part.$1) {
        final int size = jsonEncode(j).length;
        if ((o.isNotEmpty || r.isNotEmpty) &&
            bytes + size > kPyrLedgerFrameBytes) {
          flush();
        }
        (part.$2 ? o : r).add(j);
        bytes += size;
      }
    }
    if (o.isNotEmpty || r.isNotEmpty || out.isEmpty) {
      flush();
    }
    return out;
  }

  // ---- reading ----

  bool get isTreasurer {
    final String? me = pyr.myKey;
    final PyramidState? s = pyr.state;
    return me != null && s != null && s.treasurers.contains(me);
  }

  /// Whether this phone keeps the whole ledger: a treasurer's, or one's
  /// who was until lately ([kPyrHandoverMs]).
  bool _keeps(PyramidState s) {
    final String? me = pyr.myKey;
    return me != null &&
        (s.treasurers.contains(me) || pyr._now() < treasurerUntil);
  }

  /// The ledger as this phone has it (computed again only when the ledger,
  /// the statements or the pyramid changed). A whole ledger is also
  /// checked for the numbers and the money ([PyrLedger.compute]).
  PyrLedgerView view(PyramidState s) {
    final bool whole = _keeps(s);
    final Object key = (s, s.revision, _rev, whole);
    final PyrLedgerView? had = _view;
    if (had != null && _viewKey == key) {
      return had;
    }
    _viewKey = key;
    return _view = ledger.compute(s, whole: whole);
  }

  /// The statement most treasurers agree on, if any.
  PyrStatement? agreed(PyramidState s) =>
      pyrAgreedStatement(statements, s.treasurers);

  /// What came on this phone since statement [st] (none: everything): the
  /// operations it lists, and those dated before what it lists, change no
  /// balance. On a phone that keeps only its own operations, what would
  /// credit [me] waits ([PyrLedgerView.held]) until a statement most
  /// treasurers signed lists it: only the treasurers know whether the
  /// payer had the money and the number at the payment's time.
  PyrLedgerView _sinceView(PyramidState s, String me, PyrStatement? st) {
    final bool whole = _keeps(s);
    final Object key = (s, s.revision, _rev, me, whole, st?.by, st?.at);
    final PyrLedgerView? had = _since;
    if (had != null && _sinceKey == key) {
      return had;
    }
    _sinceKey = key;
    return _since = ledger.compute(
      s,
      skip: st?.ids.toSet() ?? const <String>{},
      skipBefore: st?.from ?? 0,
      hold: whole ? null : me,
    );
  }

  /// This person's balance: from the ledger here when this phone keeps the
  /// whole ledger and counted all the statement most treasurers signed did
  /// (always so for a treasurer in sync); otherwise that statement, with
  /// what came since — money that came in only once a statement lists it.
  int balanceOf(String me) {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return 0;
    }
    final PyrLedgerView v = view(s);
    final PyrStatement? st = agreed(s);
    if (_keeps(s) && (st == null || v.counted.containsAll(st.ids))) {
      return v.balanceOf(me);
    }
    return (st?.balance ?? 0) + _sinceView(s, me, st).balanceOf(me);
  }

  /// Operations that would pay [me] (or wait for [me]'s word) which no
  /// statement most treasurers signed lists yet: shown as waiting for
  /// confirmation, never as money. Always empty for a whole ledger.
  Set<String> awaiting(String me) {
    final PyramidState? s = pyr.state;
    if (s == null || _keeps(s)) {
      return const <String>{};
    }
    return _sinceView(s, me, agreed(s)).held;
  }

  /// Whether operation [id] counts for the treasurers: on a whole ledger,
  /// when it counts here; otherwise when the statement most treasurers
  /// signed lists it.
  bool confirmed(String id) {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return false;
    }
    if (_keeps(s)) {
      return view(s).counted.contains(id);
    }
    return agreed(s)?.ids.contains(id) ?? false;
  }

  /// The number this person's next order takes.
  int nextSeq(String me) {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return 1;
    }
    return max(agreed(s)?.seq ?? 0, view(s).seqOf(me)) + 1;
  }

  /// The time this person's next order carries: now, but after every
  /// change this phone counted on the account — a clock a little behind
  /// (within [kPyrMaxSkewMs]) never dates an order before the money it
  /// spends, which the treasurers would not count. At most [after] + 1
  /// when given (a treasurer's refusal named a later change), never past
  /// the skew a treasurer accepts.
  int orderAt(String me, {int after = 0}) {
    final int now = pyr._now();
    final PyramidState? s = pyr.state;
    final int last = max(
      after,
      s == null || pyr.orderTimeFromClock ? 0 : (view(s).lastAt[me] ?? 0),
    );
    return min(max(now, last + 1), now + kPyrMaxSkewMs);
  }

  /// The release an operation for [slot] follows now (null for the first
  /// span): what a new order or settlement names.
  String? relFor(String slot) {
    final PyramidState? s = pyr.state;
    final String? rel = s == null ? null : view(s).releases[slot];
    return rel == null || rel.isEmpty ? null : rel;
  }

  /// The releases that count of the slots of [ops], to go with them: a
  /// phone that counts an operation of a later span needs them. Each with
  /// the votes of a majority only: a release counts with those.
  List<Map<String, dynamic>> _chainsOf(
    Iterable<PyramidRecord> ops,
    PyramidState s,
  ) => _chainsIn(ledger, ops, s);

  static List<Map<String, dynamic>> _chainsIn(
    PyrLedger ledger,
    Iterable<PyramidRecord> ops,
    PyramidState s,
  ) => <Map<String, dynamic>>[
    for (final String slot in <String>{
      for (final PyramidRecord op in ops) PyrLedger.slotOf(op),
    })
      for (final PyramidRecord r in ledger.chainOf(slot, s))
        PyrLedger.majorityOnly(r, s).toJson(),
  ];

  // ---- ordering ----

  /// Sends [order] (or a settlement) to every treasurer of its era, with
  /// the releases of its number it follows; kept until most of them
  /// signed — also across a restart — and sent again as it is.
  Future<void> toTreasurers(PyramidRecord order) async {
    final PyramidState? s = order.pyramid == pyr.current ? pyr.state : null;
    if (s == null || pyr.myKey == null) {
      return;
    }
    pyr._payments[order.id] ??= order;
    pyr._resentAt[order.id] = pyr._now();
    await pyr._save();
    final List<Map<String, dynamic>> rel = _chainsOf(<PyramidRecord>[order], s);
    for (final String t in PyrLedger.treasurersOf(order, s)) {
      await sendTo(t, <String, dynamic>{
        'k': _Priv.order,
        'r': order.toJson(),
        if (rel.isNotEmpty) 'rel': rel,
      });
    }
  }

  /// [op] with its signatures checked one by one: the payer's (all must
  /// hold) and the treasurers' that hold, with the ML-DSA keys they were
  /// admitted with. Null when the payer's does not.
  static Future<PyramidRecord?> checked(
    PyramidRecord op,
    PyramidState s,
  ) async {
    if (!PyrT.treasured.contains(op.type) ||
        op.pyramid != s.id ||
        !await op.verifySigners() ||
        op.signers.any((String k) => !s.pqHolds(op, k))) {
      return null;
    }
    final Map<String, String> t = await op.validTreasurerSigMap();
    return PyramidRecord(
      body: op.body,
      sigs: op.sigs,
      tsigs: <String, String>{
        for (final MapEntry<String, String> e in t.entries)
          if (s.pqHolds(op, e.key, treasurer: true)) e.key: e.value,
      },
    );
  }

  /// Release [r] with the votes that check: by treasurers of its era, the
  /// ML-DSA halves by the keys they were admitted with. Null when it is
  /// not shaped like a release of this pyramid, or no vote holds.
  static Future<PyramidRecord?> checkedRelease(
    PyramidRecord r,
    PyramidState s,
  ) async {
    if (!PyrLedger.isRelease(r) || r.pyramid != s.id) {
      return null;
    }
    final List<String> t = s.treasurersAt(r.at);
    final Map<String, String> votes = <String, String>{
      for (final MapEntry<String, String> e
          in (await r.validTreasurerSigMap()).entries)
        if (t.contains(e.key) && s.pqHolds(r, e.key, treasurer: true))
          e.key: e.value,
    };
    return votes.isEmpty ? null : PyramidRecord(body: r.body, tsigs: votes);
  }

  /// The releases that count here.
  Set<String> _finalReleases(PyramidState s) => <String>{
    for (final PyramidRecord r in ledger.releases.values)
      if (PyrLedger.releaseFinal(r, s)) r.id,
  };

  /// Releases in [list]: those that count; with [votes] (a treasurer's
  /// ledger) also those still gathering votes, for a slot this ledger
  /// has operations of. A phone that keeps only its own takes those of
  /// its slots. Whether anything changed (saved).
  Future<bool> _takeReleases(
    Object? list,
    PyramidState s, {
    bool votes = false,
    int limit = kPyrMaxEvidencePerPayer,
  }) async {
    if (list is! List) {
      return false;
    }
    final String? me = pyr.myKey;
    final bool keeper = _keeps(s);
    final Set<String> slots = <String>{
      for (final PyramidRecord op in ledger.ops.values) PyrLedger.slotOf(op),
      for (final PyramidRecord op in pyr._payments.values) PyrLedger.slotOf(op),
    };
    bool changed = false;
    for (final Object? x in list.take(limit)) {
      final PyramidRecord? raw = PyramidRecord.fromJson(x);
      final PyramidRecord? r = raw == null
          ? null
          : await checkedRelease(raw, s);
      if (r == null ||
          s.treasurerEras.isEmpty ||
          r.at < s.treasurerEras.first.$1 ||
          r.at > pyr._now() + kPyrMaxSkewMs) {
        continue;
      }
      final String slot = r.str('slot');
      final bool counts = PyrLedger.releaseFinal(r, s);
      final bool mine =
          slots.contains(slot) || (me != null && slot.startsWith('$me|'));
      if ((counts && (keeper || mine)) || (votes && keeper && mine)) {
        changed = ledger.mergeRelease(r) || changed;
      }
    }
    if (changed) {
      await save();
    }
    return changed;
  }

  /// After releases came: one that came to count here is told to everyone
  /// whose operations of its slot this treasurer knows (once, by those
  /// who voted for it), and this person's own orders it left behind go
  /// out again in the span it starts ([_reissue]).
  Future<void> _afterReleases(PyramidState s, Set<String> before) async {
    final String? me = pyr.myKey;
    final bool treasurer = me != null && s.treasurers.contains(me);
    for (final PyramidRecord r in ledger.releases.values.toList()) {
      if (!treasurer ||
          before.contains(r.id) ||
          !r.tsigs.containsKey(me) ||
          !PyrLedger.releaseFinal(r, s)) {
        continue;
      }
      final String slot = r.str('slot');
      final List<PyramidRecord> of = ledger.inSlot(slot);
      final Set<String> to = <String>{
        for (final PyramidRecord op in of) ...PyrLedger.partiesOf(op),
        if (slot.startsWith('x|'))
          if (ledger.ops[slot.substring(2)] case final PyramidRecord paid)
            ...PyrLedger.partiesOf(paid),
      }..remove(me);
      final List<Map<String, dynamic>> chain = <Map<String, dynamic>>[
        for (final PyramidRecord x in ledger.chainOf(slot, s))
          PyrLedger.majorityOnly(x, s).toJson(),
      ];
      for (final String k in to.toList()..sort()) {
        if (s.members.containsKey(k)) {
          await _sendDone(k, const <Map<String, dynamic>>[], chain);
        }
      }
    }
    await _reissue(s);
  }

  /// This person's orders and settlements still waiting that a release
  /// left behind, or whose era was sealed without them, go out again,
  /// signed afresh in the span the release starts and the era open now:
  /// the same number (or payment), the same payee and amount, a new time.
  /// One its era's seal lists counted: it waits no more. An acceptance
  /// past its time is dropped instead (no honest treasurer signs it any
  /// more); so is anything when the app may not sign now.
  Future<void> _reissue(PyramidState s) async {
    final LedgerKeyPair? me = pyr._signer;
    if (me == null) {
      return;
    }
    final PyrLedgerView v = view(s);
    final List<PyramidRecord> stale = <PyramidRecord>[];
    for (final PyramidRecord r in pyr._payments.values.toList()) {
      if (r.pyramid != s.id || !r.signers.contains(me.id)) {
        continue;
      }
      final PyrSeal? sealed = s.sealOfEra(PyrLedger.eraOf(r));
      if (sealed != null && sealed.ops.contains(r.id)) {
        pyr._payments.remove(r.id);
        pyr._resentAt.remove(r.id);
      } else if (sealed != null ||
          PyrLedger.eraOf(r) < 1 ||
          (v.leftBehind(r, s) &&
              (PyrLedger.relOf(r).isEmpty ||
                  ledger.releases.containsKey(PyrLedger.relOf(r))))) {
        stale.add(r);
      }
    }
    // One that counted until its era's seal left it out (signed by most of
    // the era's treasurers, its number still free): once, again.
    final Set<String> waiting = <String>{
      for (final PyramidRecord r in pyr._payments.values) PyrLedger.slotOf(r),
      for (final PyramidRecord r in stale) PyrLedger.slotOf(r),
    };
    for (final PyramidRecord op in ledger.ops.values.toList()) {
      final String slot = PyrLedger.slotOf(op);
      if (op.pyramid == s.id &&
          PyrLedger.payerOf(op) == me.id &&
          op.signers.contains(me.id) &&
          v.broken[op.id] == kPyrLeftOutOfSeal &&
          !v.slots.containsKey(slot) &&
          !waiting.contains(slot) &&
          pyr._announced.add('again-${op.id}')) {
        waiting.add(slot);
        stale.add(op);
      }
    }
    if (stale.isEmpty || !await TamperGuard.allowsSensitive()) {
      return;
    }
    final int now = pyr._now();
    for (final PyramidRecord r in stale) {
      pyr._payments.remove(r.id);
      pyr._resentAt.remove(r.id);
      final PyrEscrow? e = r.type == PyrT.settle ? v.escrows[r.str('x')] : null;
      if (r.type == PyrT.settle &&
          r.body['ok'] == true &&
          (e == null || now > e.until + kPyrMaxSkewMs)) {
        continue;
      }
      final String rel = v.releases[PyrLedger.slotOf(r)] ?? '';
      final Map<String, dynamic> body = <String, dynamic>{
        ...r.body,
        'at': orderAt(me.id),
        'after': s.seals.length,
        'nc': pyr._newId(24),
      };
      if (rel.isEmpty) {
        body.remove('rel');
      } else {
        body['rel'] = rel;
      }
      final PyramidRecord again = await PyramidRecord(body: body).signedBy(me);
      await toTreasurers(again);
    }
    await pyr._save();
    pyr._changed();
  }

  /// A treasurer checks an order against its own ledger and signs it (once
  /// per span, [_consider]), keeping its signature as evidence; the
  /// signature goes back to whoever signed the order. The releases that
  /// come with it are taken first.
  Future<void> _onOrder(Map<String, dynamic> json) async {
    final LedgerKeyPair? me = pyr._identity;
    final PyramidState? s = pyr.state;
    final PyramidRecord? raw = PyramidRecord.fromJson(json['r']);
    if (me == null || s == null || raw == null || !PyrLedger.fits(raw)) {
      return;
    }
    // A treasurer of the era open here; one of another era is refused
    // with that reason ([PyrLedger.problem]), so its payer orders again.
    if (!s.treasurers.contains(me.id)) {
      return;
    }
    final PyramidRecord? op = await checked(raw, s);
    if (op == null) {
      return;
    }
    final Set<String> before = _finalReleases(s);
    if (await _takeReleases(json['rel'], s)) {
      await _afterReleases(s, before);
    }
    await _consider(op, s, me, answer: true);
  }

  /// Signs [op] when an honest treasurer may: one operation per span of a
  /// slot, whatever it sees of the others — a second one only when the
  /// era of the first was sealed without it ([PyrLedger.passed]). An
  /// operation of a span left behind by a release (or following one not
  /// known here) is never signed: its payer gets the releases, to order
  /// again in the span that counts. A number split so that no operation
  /// can reach a majority is freed by a release most treasurers vote for
  /// ([_tidy]), never by one treasurer moving on alone. An operation
  /// refused for its span is kept as evidence when a treasurer of its time
  /// signed it. One this treasurer would not count ([PyrLedger.problem])
  /// is refused; with [answer] (it came from its payer) the payer hears
  /// why, and the time of the newest change counted on the account: an
  /// order dated before it can go out again dated after.
  Future<void> _consider(
    PyramidRecord op,
    PyramidState s,
    LedgerKeyPair me, {
    bool answer = false,
  }) async {
    final int now = pyr._now();
    final String payer = op.type == PyrT.transfer ? op.str('from') : '';
    final List<int> times = <int>[
      for (final int x in _signedAt[payer] ?? const <int>[])
        if (x > now - kPyrDayMs) x,
    ];
    final String span = PyrLedger.spanOf(op);
    final String? already = pyr._signedOrders[span];
    final PyrLedgerView v = view(s);
    if (v.leftBehind(op, s)) {
      if (_evidence(op, s) && ledger.merge(op)) {
        await save();
      }
      final String slot = PyrLedger.slotOf(op);
      if (v.releases.containsKey(slot) && op.signers.isNotEmpty) {
        await _sendDone(
          op.signers.first,
          const <Map<String, dynamic>>[],
          _chainsIn(ledger, <PyramidRecord>[op], s),
        );
      }
      return;
    }
    if (already != null && already != op.id) {
      final PyramidRecord? had = ledger.ops[already];
      if (had == null ||
          !PyrLedger.isLater(op, had) ||
          !PyrLedger.passed(had, s)) {
        if (_evidence(op, s) && ledger.merge(op)) {
          await save();
        }
        return;
      }
    }
    // The same order again (its signature lost on the way) is signed
    // again, not counted twice.
    if (already != op.id) {
      // Once this treasurer signed a seal of the open era, nothing more of
      // it: what is signed now would be left out, its payer orders again
      // in the next era.
      final String? why = pyr._signedOrders['seal|${s.openEra}'] != null
          ? kPyrOtherEra
          : ledger.problem(
              op,
              s,
              now,
              signedToday: times.length,
              current: v,
            );
      if (why != null) {
        if (answer && op.signers.isNotEmpty) {
          await sendTo(op.signers.first, <String, dynamic>{
            'k': _Priv.refuse,
            'id': op.id,
            'by': me.id,
            'why': PyrLedger.refusalCode(why),
            'after': v.lastAt[PyrLedger.payerOf(op)] ?? 0,
          });
        }
        return;
      }
    }
    // An order after its number's release is the same payment again: one
    // against the day's limit.
    if (already == null &&
        payer.isNotEmpty &&
        !ledger
            .inSlot(PyrLedger.slotOf(op))
            .any((PyramidRecord o) => o.tsigs.containsKey(me.id))) {
      _signedAt[payer] = <int>[...times, now];
    }
    pyr._markSigned(span, op.id, op.at);
    final String sig = b64(await me.sign(PyramidRecord.treasurerBytes(op.id)));
    ledger.merge(op.withTreasurerSig(me.id, sig));
    await save();
    await pyr._save();
    await sendTo(op.signers.first, <String, dynamic>{
      'k': _Priv.sig,
      'id': op.id,
      'by': me.id,
      's': sig,
    });
  }

  /// A treasurer's signature for an order waiting here: only a valid one
  /// is added, never replacing one kept. Once most treasurers of its time
  /// signed, it counts: into the ledger, and to the treasurers and those
  /// it concerns — unless a release left its span behind meanwhile: then
  /// it goes out again in the next one ([_reissue]).
  Future<void> _onSig(Map<String, dynamic> json) async {
    final Object? id = json['id'];
    final Object? k = json['by'];
    final Object? sig = json['s'];
    final PyramidRecord? order = id is String ? pyr._payments[id] : null;
    final PyramidState? s = pyr.state;
    if (order == null ||
        s == null ||
        k is! String ||
        sig is! String ||
        order.tsigs.containsKey(k) ||
        !PyrLedger.treasurersOf(order, s).contains(k)) {
      return;
    }
    final PyramidRecord one = PyramidRecord(
      body: order.body,
      sigs: order.sigs,
      tsigs: <String, String>{k: sig},
    );
    if ((await one.validTreasurerSigMap()).isEmpty ||
        !s.pqHolds(one, k, treasurer: true)) {
      return;
    }
    final PyramidRecord? now = pyr._payments[order.id];
    if (now == null || now.tsigs.containsKey(k)) {
      return;
    }
    final PyramidRecord more = now.withTreasurerSig(k, sig);
    pyr._payments[order.id] = more;
    if (PyrLedger.isFinal(more, s) && !view(s).leftBehind(more, s)) {
      pyr._payments.remove(order.id);
      pyr._resentAt.remove(order.id);
      _refusals.remove(order.id);
      ledger.merge(more);
      await save();
      await _spreadDone(more, s);
    }
    await pyr._save();
    pyr._changed();
  }

  /// A treasurer's refusal of an order waiting here (from that treasurer's
  /// own device, or this phone's own when this person is the treasurer).
  /// Once so many treasurers of its time refused it that it can never
  /// count, and none signed it, an order dated before a change they
  /// counted on the account goes out again dated after it ([_redate]): a
  /// clock behind, or money that came with a later time, does not leave
  /// the number stuck. Otherwise the wallet shows why
  /// ([refusalOf]).
  Future<void> _onRefuse(Map<String, dynamic> json, String? from) async {
    final Object? id = json['id'];
    final Object? k = json['by'];
    final Object? why = json['why'];
    final Object? after = json['after'];
    final PyramidRecord? order = id is String ? pyr._payments[id] : null;
    final PyramidState? s = pyr.state;
    if (order == null ||
        s == null ||
        k is! String ||
        why is! String ||
        why.length > 16 ||
        after is! int ||
        !PyrLedger.treasurersOf(order, s).contains(k) ||
        !(from == null ? k == pyr.myKey : _sentBy(s, k, from))) {
      return;
    }
    if (why == PyrLedger.refusalCode(kPyrOtherEra)) {
      // Another era on that treasurer's phone: once a seal closes the
      // order's era here, it goes out again in the next ([_reissue]);
      // until then it is sent again as it is.
      return;
    }
    // A time ahead of any clock a treasurer accepts names nothing real.
    final int when = min(after, pyr._now() + kPyrMaxSkewMs);
    (_refusals[order.id] ??= <String, (String, int)>{})[k] = (why, when);
    pyr._changed();
    final List<String> t = PyrLedger.treasurersOf(order, s);
    final Map<String, (String, int)> no = _refusals[order.id]!;
    final int later = no.values.fold(
      0,
      (int a, (String, int) b) => max(a, b.$2),
    );
    if (order.tsigs.isEmpty &&
        no.keys.where(t.contains).length > t.length - (t.length ~/ 2 + 1) &&
        later >= order.at) {
      await _redate(order, s, later);
    }
  }

  /// Why most treasurers refused order [id] waiting here ([PyrLedger.
  /// refusalCode]), once so many did that it cannot count; null otherwise.
  String? refusalOf(String id) {
    final PyramidRecord? order = pyr._payments[id];
    final PyramidState? s = pyr.state;
    final Map<String, (String, int)>? no = _refusals[id];
    if (order == null || s == null || no == null) {
      return null;
    }
    final List<String> t = PyrLedger.treasurersOf(order, s);
    final Map<String, int> by = <String, int>{};
    for (final MapEntry<String, (String, int)> e in no.entries) {
      if (t.contains(e.key)) {
        by[e.value.$1] = (by[e.value.$1] ?? 0) + 1;
      }
    }
    if (by.values.fold(0, (int a, int b) => a + b) <=
        t.length - (t.length ~/ 2 + 1)) {
      return null;
    }
    return (by.entries.toList()..sort(
          (MapEntry<String, int> a, MapEntry<String, int> b) =>
              b.value.compareTo(a.value),
        ))
        .first
        .key;
  }

  /// Order [old] (none signed it, it cannot count) goes out again as it
  /// was, dated after [after] — the same number, payee, amount and release.
  Future<void> _redate(PyramidRecord old, PyramidState s, int after) async {
    final LedgerKeyPair? me = pyr._signer;
    if (me == null ||
        !old.signers.contains(me.id) ||
        !await TamperGuard.allowsSensitive()) {
      return;
    }
    pyr._payments.remove(old.id);
    pyr._resentAt.remove(old.id);
    _refusals.remove(old.id);
    final PyramidRecord again = await PyramidRecord(
      body: <String, dynamic>{
        ...old.body,
        'at': orderAt(me.id, after: after),
        'after': s.seals.length,
        'nc': pyr._newId(24),
      },
    ).signedBy(me);
    await toTreasurers(again);
    pyr._changed();
  }

  /// [op] and the operations it rests on (the payment a settlement
  /// settles, and the hops before it).
  List<PyramidRecord> _withChain(PyramidRecord op) {
    final List<PyramidRecord> out = <PyramidRecord>[op];
    PyramidRecord? x = op;
    int guard = 0;
    while (x != null && x.type == PyrT.settle && guard++ < kMaxAdHops + 2) {
      x = ledger.ops[x.str('x')];
      if (x != null) {
        out.add(x);
      }
    }
    return out;
  }

  /// An operation that counts goes to every treasurer (of its era and of
  /// now) and to those it concerns: the payer, the one paid, the one whose
  /// word a payment waits for, the next one of an announcement — with the
  /// releases of its number it follows.
  Future<void> _spreadDone(PyramidRecord op, PyramidState s) async {
    final List<PyramidRecord> chain = _withChain(op);
    final Set<String> to = <String>{
      ...PyrLedger.treasurersOf(op, s),
      ...s.treasurers,
      for (final PyramidRecord x in chain) ...PyrLedger.partiesOf(x),
    }..remove(pyr.myKey);
    final List<Map<String, dynamic>> rel = _chainsOf(chain, s);
    // Every signature goes along (a treasurer who signed two is shown so):
    // the frames are packed instead.
    final List<Map<String, dynamic>> ops = <Map<String, dynamic>>[
      for (final PyramidRecord x in chain) x.toJson(),
    ];
    for (final String k in to.toList()..sort()) {
      if (s.members.containsKey(k)) {
        await _sendDone(k, ops, rel);
      }
    }
  }

  /// Operations that count, and releases of numbers: a treasurer keeps
  /// them all, anybody else only a set that concerns them. A payment to
  /// this person is told, and passed on to the treasurers at once: a
  /// payment counts for good only once they hold it — a release leaves
  /// behind what they never saw ([kPyrReleaseWaitMs]).
  Future<void> _onDone(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final Object? list = json['ops'];
    if (s == null || me == null || list is! List) {
      return;
    }
    final Set<String> before = _finalReleases(s);
    final List<PyramidRecord> ops = <PyramidRecord>[];
    for (final Object? x in list.take(kMaxAdHops + 2)) {
      final PyramidRecord? raw = PyramidRecord.fromJson(x);
      final PyramidRecord? op = raw == null ? null : await checked(raw, s);
      if (op != null) {
        ops.add(op);
      }
    }
    final bool keeper =
        s.treasurers.contains(me) || pyr._now() < treasurerUntil;
    bool changed = false;
    if (keeper ||
        ops.any((PyramidRecord op) => PyrLedger.partiesOf(op).contains(me))) {
      for (final PyramidRecord op in ops) {
        // What counts by the rules every phone counts by (signed by most
        // treasurers of its time, dated within their time, nothing an
        // honest treasurer refuses whoever signed it), on a treasurer's
        // phone too: anybody can send this, and evidence comes only from
        // the treasurers themselves ([_onOps], [_consider]).
        if (PyrLedger.isFinal(op, s) && PyrLedger.breaks(op, s) == null) {
          changed = ledger.merge(op) || changed;
        }
      }
    }
    if (changed) {
      await save();
    }
    // After the operations: a phone that keeps only its own takes the
    // releases of the slots it has operations of.
    final bool freed = await _takeReleases(json['rel'], s);
    if (freed) {
      await _afterReleases(s, before);
    }
    if (!changed && !freed) {
      return;
    }
    pyr._changed();
    if (!changed) {
      return;
    }
    if (!keeper) {
      // What came in for this person waits until the treasurers' agreed
      // statement lists it: asked for with the payment itself (a treasurer
      // answers once it took it), and again while it waits ([duties]).
      final bool waits = awaiting(me).isNotEmpty;
      if (!await _publish(s, me, ops, ask: waits) && waits) {
        await _askToConfirm(s, me);
      }
    }
    await _tellPaid(s, me, <String>{for (final PyramidRecord op in ops) op.id});
    // Market messages waiting for their payment.
    await pyr._retryHeld();
  }

  /// Payments to [me] among [ops] (new here) go on to the treasurers of
  /// their time and of now, once each: an order final through a signature
  /// a treasurer kept from the others reaches them before its number can
  /// be released, so it counts and that treasurer is shown signing two.
  /// With [ask], each treasurer is asked for this person's short
  /// statement with them. Whether anything went.
  Future<bool> _publish(
    PyramidState s,
    String me,
    List<PyramidRecord> ops, {
    bool ask = false,
  }) async {
    final List<PyramidRecord> paid = <PyramidRecord>[
      for (final PyramidRecord op in ops)
        if (PyrLedger.payerOf(op) != me &&
            PyrLedger.partiesOf(op).contains(me) &&
            ledger.ops.containsKey(op.id) &&
            pyr._announced.add('pub-${op.id}'))
          op,
    ];
    if (paid.isEmpty) {
      return false;
    }
    if (ask) {
      _confirmAskedAt = pyr._now();
    }
    final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[
      for (final PyramidRecord op in paid) op.toJson(),
    ];
    final List<Map<String, dynamic>> rel = _chainsOf(paid, s);
    for (final String k in <String>{
      for (final PyramidRecord op in paid) ...PyrLedger.treasurersOf(op, s),
      ...s.treasurers,
    }.toList()..sort()) {
      if (k != me) {
        await _sendDone(k, sent, rel, ask: ask ? me : null);
      }
    }
    return true;
  }

  /// Notifications of what came in for this person with operations
  /// [fresh] (each told once): only once it counts for the treasurers
  /// ([awaiting]: until then it is no money).
  Future<void> _tellPaid(PyramidState s, String me, Set<String> fresh) async {
    final PyrLedgerView v = view(s);
    final Set<String> waits = awaiting(me);
    for (final PyrLedgerEntry e in v.entries) {
      if (!fresh.contains(e.id) ||
          waits.contains(e.id) ||
          e.to != me ||
          e.from == me ||
          (e.kind != PyrEntryKind.payment &&
              e.kind != PyrEntryKind.kept &&
              e.kind != PyrEntryKind.hold)) {
        continue;
      }
      if (!pyr._announced.add('pay-${e.id}')) {
        continue;
      }
      final String name = s.members[e.from]?.name ?? '?';
      await pyr.host.notify(
        RuntimeSystemNotification(
          id: 'pyr-pay-${e.id}',
          title: e.kind == PyrEntryKind.hold
              ? t('Płatność czeka na Twoją decyzję')
              : t('Wpłata'),
          body: e.memo.isEmpty
              ? t('{amount} od {name}', <String, Object?>{
                  'amount': formatMoney(e.amount),
                  'name': name,
                })
              : t('{amount} od {name} — {memo}', <String, Object?>{
                  'amount': formatMoney(e.amount),
                  'name': name,
                  'memo': e.memo,
                }),
          createdAtMillis: pyr._now(),
          category: RuntimeSystemNotificationCategory.social,
          slotKey: 'pyr-pay-${e.id}',
        ),
      );
    }
  }

  // ---- emission notes ----

  /// Sends emission note [n] to the treasurers and to the one paid (and
  /// keeps it here when this person is one of them).
  Future<void> sendNote(PyrEmitNote n) async {
    final PyramidState? s = pyr.state;
    if (s == null || !n.holds) {
      return;
    }
    for (final String k in <String>{...s.treasurers, n.to}.toList()..sort()) {
      await sendTo(k, <String, dynamic>{'k': _Priv.note, 'n': n.toJson()});
    }
  }

  Future<void> _onNote(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final PyrEmitNote? n = PyrEmitNote.fromJson(json['n']);
    if (s == null || me == null || n == null || !s.members.containsKey(n.to)) {
      return;
    }
    final bool keeper =
        s.treasurers.contains(me) || pyr._now() < treasurerUntil;
    if ((keeper || n.to == me) && ledger.mergeNote(n)) {
      await save();
      pyr._changed();
    }
  }

  // ---- statements ----

  /// The account was recovered on this device: its wallet comes back from
  /// the treasurers' statements.
  Future<void> recovered() async {
    _recoverAsk = true;
    await save();
    await _askIfHere();
  }

  /// After a recovery, once the pyramid sends to this device: asks for the
  /// statements (every few minutes, until most treasurers agreed on one),
  /// and a treasurer offers its ledger for sync at once.
  Future<void> _askIfHere() async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final PyrMember? m = me == null ? null : s?.members[me];
    if (!_recoverAsk ||
        s == null ||
        m == null ||
        pyr._n(m.addr) != pyr._n(pyr.host.ownAddress())) {
      return;
    }
    if (agreed(s) != null) {
      _recoverAsk = false;
      await save();
      return;
    }
    if (pyr._now() - askedAt < 5 * 60 * 1000) {
      return;
    }
    syncedAt = 0;
    await askStatements(force: true);
  }

  /// Asks the treasurers for this person's statement (every
  /// [kPyrStatementEveryMs], or now with [force]: after a recovery).
  Future<void> askStatements({bool force = false}) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final int now = pyr._now();
    if (s == null || me == null || !s.isMember(me)) {
      return;
    }
    if (!force && now - askedAt < kPyrStatementEveryMs) {
      return;
    }
    askedAt = now;
    await save();
    for (final String k in s.treasurers) {
      if (k != me) {
        await sendTo(k, <String, dynamic>{'k': _Priv.ask, 'a': me});
      }
    }
  }

  /// Asks the treasurers for a short statement (no operations in full):
  /// whether they count what came in for this person ([awaiting]).
  Future<void> _askToConfirm(PyramidState s, String me) async {
    if (!s.isMember(me)) {
      return;
    }
    _confirmAskedAt = pyr._now();
    for (final String k in s.treasurers) {
      if (k != me) {
        await sendTo(k, <String, dynamic>{'k': _Priv.ask, 'a': me, 'l': true});
      }
    }
  }

  /// A treasurer's statement of [account] as its ledger has it, signed
  /// ([statementFrame]). Sealed to [account] alone; should the frame still
  /// not go (bigger than counted), half the operations go, down to none.
  Future<void> _onAsk(Map<String, dynamic> json) async {
    final LedgerKeyPair? me = pyr._identity;
    final PyramidState? s = pyr.state;
    final Object? a = json['a'];
    if (me == null ||
        s == null ||
        a is! String ||
        !s.isMember(a) ||
        !s.treasurers.contains(me.id)) {
      return;
    }
    final Map<String, dynamic> frame = await statementFrame(
      ledger,
      view(s),
      s,
      a,
      me,
      pyr._now(),
      short: json['l'] == true,
    );
    final List<Map<String, dynamic>> ops =
        (frame['ops'] as List<Map<String, dynamic>>?) ??
        const <Map<String, dynamic>>[];
    int take = ops.length;
    while (true) {
      final Map<String, dynamic> part = take == ops.length
          ? frame
          : <String, dynamic>{
              'k': _Priv.statement,
              'st': frame['st'],
              'ops': ops.take(take).toList(),
              'rel': _chainsIn(ledger, <PyramidRecord>[
                for (final Map<String, dynamic> j in ops.take(take))
                  ?PyramidRecord.fromJson(j),
              ], s),
              'notes': take == 0
                  ? const <Map<String, dynamic>>[]
                  : frame['notes'],
            };
      if (await sendTo(a, part) || take == 0) {
        return;
      }
      take ~/= 2;
    }
  }

  /// The statement of [account] by treasurer [me] whose (whole) [ledger]
  /// counts [v], at [now], as the frame that carries it: the balance, the
  /// number, the operations counted ([PyrStatement.window]: the newest by
  /// id), the newest of them in full ([kPyrStatementOps] at most) with a
  /// majority of signatures each and the releases they follow, and the
  /// emission notes for it — within [kPyrLedgerFrameBytes], whatever the
  /// number of treasurers or the account's history. A [short] one carries
  /// no operations nor notes.
  static Future<Map<String, dynamic>> statementFrame(
    PyrLedger ledger,
    PyrLedgerView v,
    PyramidState s,
    String account,
    LedgerKeyPair me,
    int now, {
    bool short = false,
  }) async {
    final List<PyramidRecord> mine = ledger.concerning(account);
    final List<PyrEmitNote> notes = <PyrEmitNote>[
      for (final PyrEmitNote n in ledger.notes.values)
        if (n.to == account) n,
    ];
    final Map<String, int> noteAt = <String, int>{
      for (final PyrEmission e in s.emissions.values) e.rc: e.effectiveAt,
    };
    final Map<String, int> emitted = <String, int>{
      for (final PyrEmission e in s.emissions.values)
        if (notes.any((PyrEmitNote n) => n.rc == e.rc))
          'e:${e.id}': e.effectiveAt,
    };
    final (List<String> ids, int from) = PyrStatement.window(<String, int>{
      for (final PyramidRecord op in mine)
        if (v.counted.contains(op.id)) op.id: op.at,
      for (final MapEntry<String, int> e in emitted.entries)
        if (v.counted.contains(e.key)) e.key: e.value,
    });
    final PyrStatement unsigned = PyrStatement(
      pyramid: s.id,
      account: account,
      balance: v.balanceOf(account),
      seq: v.seqOf(account),
      at: now,
      ids: ids,
      from: from,
      by: me.id,
      sig: '',
    );
    final Map<String, dynamic> st = <String, dynamic>{
      ...unsigned.toJson(),
      'sig': b64(await me.sign(unsigned.signedBytes)),
    };
    if (short) {
      return <String, dynamic>{'k': _Priv.statement, 'st': st};
    }
    int bytes = jsonEncode(st).length;
    // The notes of the emissions it lists (or not counted yet), newest
    // first, in a quarter of the frame at most.
    final List<Map<String, dynamic>> noteJson = <Map<String, dynamic>>[];
    notes.sort(
      (PyrEmitNote x, PyrEmitNote y) =>
          (noteAt[y.rc] ?? 0).compareTo(noteAt[x.rc] ?? 0),
    );
    for (final PyrEmitNote n in notes) {
      final Map<String, dynamic> j = n.toJson();
      final int size = jsonEncode(j).length;
      if ((noteAt[n.rc] ?? from) < from ||
          bytes + size > kPyrLedgerFrameBytes ~/ 4) {
        continue;
      }
      noteJson.add(j);
      bytes += size;
    }
    // The newest operations in full while they fit.
    final List<PyramidRecord> newest = <PyramidRecord>[];
    List<Map<String, dynamic>> rel = <Map<String, dynamic>>[];
    int relBytes = 2;
    for (final PyramidRecord op in mine.reversed) {
      if (newest.length >= kPyrStatementOps) {
        break;
      }
      if (!v.counted.contains(op.id)) {
        continue;
      }
      final PyramidRecord slim = PyrLedger.majorityOnly(op, s);
      final List<Map<String, dynamic>> moreRel = _chainsIn(
        ledger,
        <PyramidRecord>[...newest, slim],
        s,
      );
      final int moreRelBytes = jsonEncode(moreRel).length;
      final int size =
          jsonEncode(slim.toJson()).length + moreRelBytes - relBytes;
      if (bytes + size > kPyrLedgerFrameBytes) {
        break;
      }
      newest.add(slim);
      rel = moreRel;
      relBytes = moreRelBytes;
      bytes += size;
    }
    return <String, dynamic>{
      'k': _Priv.statement,
      'st': st,
      'ops': <Map<String, dynamic>>[
        for (final PyramidRecord op in newest) op.toJson(),
      ],
      if (rel.isNotEmpty) 'rel': rel,
      'notes': noteJson,
    };
  }

  /// A treasurer's statement of this person's account: kept when its
  /// signature holds; the operations and notes it brings fill the history.
  Future<void> _onStatement(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final PyrStatement? st = PyrStatement.fromJson(json['st']);
    if (s == null ||
        me == null ||
        st == null ||
        st.account != me ||
        st.pyramid != s.id ||
        !s.isMember(st.by) ||
        // The ML-DSA half by the key the treasurer was admitted with.
        !s.pqHolds(
          PyramidRecord(body: st.body, tsigs: <String, String>{st.by: st.sig}),
          st.by,
          treasurer: true,
        ) ||
        !await verifyLedgerSignature(
          publicKey: st.by,
          message: st.signedBytes,
          signature: st.sig,
        )) {
      return;
    }
    // What waited here for the treasurers before: told once a statement
    // most of them signed lists it.
    final Set<String> waited = Set<String>.of(awaiting(me));
    final PyrStatement? had = statements[st.by];
    if (had == null || had.at < st.at) {
      statements[st.by] = st;
    }
    final Object? ops = json['ops'];
    if (ops is List) {
      for (final Object? x in ops.take(kPyrStatementOps)) {
        final PyramidRecord? raw = PyramidRecord.fromJson(x);
        final PyramidRecord? op = raw == null ? null : await checked(raw, s);
        if (op != null &&
            PyrLedger.isFinal(op, s) &&
            PyrLedger.breaks(op, s) == null) {
          ledger.merge(op);
        }
      }
    }
    final Object? notes = json['notes'];
    if (notes is List) {
      for (final Object? x in notes) {
        final PyrEmitNote? n = PyrEmitNote.fromJson(x);
        if (n != null && n.to == me) {
          ledger.mergeNote(n);
        }
      }
    }
    await save();
    final Set<String> before = _finalReleases(s);
    if (await _takeReleases(json['rel'], s)) {
      await _afterReleases(s, before);
    }
    pyr._changed();
    final Set<String> now = awaiting(me);
    final Set<String> come = <String>{
      for (final String id in waited)
        if (!now.contains(id) && confirmed(id)) id,
    };
    if (come.isNotEmpty) {
      await _tellPaid(s, me, come);
      await pyr._retryHeld();
    }
  }

  // ---- the treasurers' sync ----

  /// The ledger by buckets (the first character of the ids) with who
  /// signed each, the notes ('n') and the releases with who voted ('r'):
  /// what treasurers compare.
  Map<String, String> digest() {
    final Map<String, List<String>> by = <String, List<String>>{};
    for (final PyramidRecord op in ledger.ops.values) {
      (by[op.id.substring(0, 1)] ??= <String>[]).add(
        '${op.id}:${(op.tsigs.keys.toList()..sort()).join(',')}',
      );
    }
    return <String, String>{
      for (final MapEntry<String, List<String>> e in by.entries)
        e.key: sha256Hex(utf8.encode((e.value..sort()).join('|'))),
      if (ledger.notes.isNotEmpty)
        'n': sha256Hex(
          utf8.encode((ledger.notes.keys.toList()..sort()).join()),
        ),
      if (ledger.releases.isNotEmpty)
        'r': sha256Hex(
          utf8.encode(
            (<String>[
              for (final PyramidRecord r in ledger.releases.values)
                '${r.id}:${(r.tsigs.keys.toList()..sort()).join(',')}',
            ]..sort()).join('|'),
          ),
        ),
    };
  }

  /// Every [kPyrLedgerSyncEveryMs]: a treasurer offers its digest to the
  /// other treasurers; one who stopped being a treasurer, for
  /// [kPyrHandoverMs], to the new ones (it gets nothing back but requests);
  /// after that it forgets what does not concern it.
  Future<void> syncDuty() async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final int now = pyr._now();
    if (s == null || me == null) {
      return;
    }
    final bool treasurer = s.treasurers.contains(me);
    if (treasurer) {
      treasurerUntil = now + kPyrHandoverMs;
    } else if (now >= treasurerUntil && treasurerUntil > 0) {
      _forgetOthers(me);
      treasurerUntil = 0;
      await save();
      return;
    }
    if ((!treasurer && treasurerUntil == 0) ||
        now - syncedAt < kPyrLedgerSyncEveryMs) {
      return;
    }
    syncedAt = now;
    await _tidy(s);
    final Map<String, String> d = digest();
    for (final String k in s.treasurers) {
      if (k != me) {
        await sendTo(k, <String, dynamic>{'k': _Priv.digest, 'f': me, 'd': d});
      }
    }
  }

  /// Keeps only what concerns [me] (no longer a treasurer).
  void _forgetOthers(String me) {
    final Set<String> keep = <String>{
      for (final PyramidRecord op in ledger.concerning(me)) op.id,
    };
    ledger.ops.removeWhere((String id, PyramidRecord _) => !keep.contains(id));
    ledger.notes.removeWhere((String _, PyrEmitNote n) => n.to != me);
    final Set<String> slots = <String>{
      for (final PyramidRecord op in ledger.ops.values) PyrLedger.slotOf(op),
    };
    ledger.releases.removeWhere(
      (String _, PyramidRecord r) => !slots.contains(r.str('slot')),
    );
  }

  /// The buckets of [d] (another's digest) that differ from this ledger's.
  List<String> _differing(Map<dynamic, dynamic> d) {
    final Map<String, String> mine = digest();
    return <String>{
      ...mine.keys,
      ...d.keys.whereType<String>(),
    }.where((String b) => mine[b] != d[b] && b.length <= 2).toList()..sort();
  }

  /// Whether [f], named in a sync request as the one who asks, is the
  /// member whose device sent it ([from]): the ledger goes only to who
  /// asked for it, never where somebody else points it.
  bool _sentBy(PyramidState s, String f, String? from) =>
      from != null &&
      pyr._n(s.members[f]?.addr ?? '') == from &&
      from.isNotEmpty;

  /// Another treasurer's digest: a current treasurer gets what differs
  /// from here, and is asked for theirs; anybody else (a former treasurer
  /// handing over) is only asked.
  Future<void> _onDigest(Map<String, dynamic> json, String? from) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final Object? f = json['f'];
    final Object? d = json['d'];
    if (s == null ||
        me == null ||
        f is! String ||
        d is! Map ||
        f == me ||
        !s.treasurers.contains(me) ||
        !_sentBy(s, f, from)) {
      return;
    }
    await _tidy(s);
    final List<String> differ = _differing(d);
    if (differ.isEmpty) {
      return;
    }
    await sendTo(f, <String, dynamic>{'k': _Priv.want, 'f': me, 'b': differ});
    if (s.treasurers.contains(f)) {
      await _sendBuckets(f, differ);
    }
  }

  /// Asked for buckets: sent only to a treasurer now who asked itself (or,
  /// by one who stopped being one, to the new ones — that is the
  /// handover).
  Future<void> _onWant(Map<String, dynamic> json, String? from) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final Object? f = json['f'];
    final Object? b = json['b'];
    if (s == null ||
        me == null ||
        f is! String ||
        b is! List ||
        !s.treasurers.contains(f) ||
        !_sentBy(s, f, from)) {
      return;
    }
    final bool keeper =
        s.treasurers.contains(me) || pyr._now() < treasurerUntil;
    if (!keeper) {
      return;
    }
    await _sendBuckets(f, b.whereType<String>().take(18).toList());
  }

  /// The operations of [buckets] (and the notes, 'n', and the releases,
  /// 'r') to treasurer [to], in frames of about [kPyrLedgerFrameBytes].
  Future<void> _sendBuckets(String to, List<String> buckets) async {
    final Set<String> want = buckets.toSet();
    List<Map<String, dynamic>> frame = <Map<String, dynamic>>[];
    int bytes = 0;
    List<Map<String, dynamic>> rel = <Map<String, dynamic>>[];
    Future<void> flush({List<Map<String, dynamic>>? notes}) async {
      if (frame.isEmpty && rel.isEmpty && notes == null) {
        return;
      }
      await sendTo(to, <String, dynamic>{
        'k': _Priv.ops,
        'ops': frame,
        'notes': ?notes,
        if (rel.isNotEmpty) 'rel': rel,
      });
      frame = <Map<String, dynamic>>[];
      rel = <Map<String, dynamic>>[];
      bytes = 0;
    }

    for (final PyramidRecord op in ledger.ops.values) {
      if (!want.contains(op.id.substring(0, 1))) {
        continue;
      }
      final Map<String, dynamic> j = op.toJson();
      final int size = jsonEncode(j).length;
      if (frame.isNotEmpty && bytes + size > kPyrLedgerFrameBytes) {
        await flush();
      }
      frame.add(j);
      bytes += size;
    }
    if (want.contains('r')) {
      for (final PyramidRecord r in ledger.releases.values) {
        final Map<String, dynamic> j = r.toJson();
        final int size = jsonEncode(j).length;
        if ((frame.isNotEmpty || rel.isNotEmpty) &&
            bytes + size > kPyrLedgerFrameBytes) {
          await flush();
        }
        rel.add(j);
        bytes += size;
      }
    }
    await flush(
      notes: want.contains('n')
          ? <Map<String, dynamic>>[
              for (final PyrEmitNote n in ledger.notes.values) n.toJson(),
            ]
          : null,
    );
  }

  /// Whether [op] (its signatures checked) is worth a place in a whole
  /// ledger as evidence, whether it counts or not: within
  /// [kPyrMaxOpBytes], dated within the treasurers' time (not before the
  /// first era, not ahead of this clock), and signed by a treasurer of its
  /// era — what only treasurers make. How many of one payer's that do
  /// not count are kept is bounded by [_tidy].
  bool _evidence(PyramidRecord op, PyramidState s) =>
      PyrLedger.fits(op) &&
      s.treasurerEras.isNotEmpty &&
      op.at >= s.treasurerEras.first.$1 &&
      op.at <= pyr._now() + kPyrMaxSkewMs &&
      op.tsigs.keys.any(PyrLedger.treasurersOf(op, s).contains);

  /// The ledger's last tidy: the ledger's revision and the pyramid's.
  Object? _tidied;

  /// Keeps a whole ledger to what [_evidence] admits, and of each payer's
  /// operations that do not count only the newest
  /// [kPyrMaxEvidencePerPayer] — the same rules on every treasurer's
  /// phone, so their ledgers meet; what came in before them (or another
  /// way) goes. Releases are kept for the slots it has operations of (one
  /// that counts, always: the spans after it rest on it). Then votes for
  /// the release of each span split ([_vote]) and signs the operation
  /// waiting in a span a release started.
  Future<void> _tidy(PyramidState s) async {
    if (!_keeps(s)) {
      return;
    }
    final Object key = (s, s.revision, _rev);
    if (_tidied != key) {
      await _prune(s);
      _tidied = (s, s.revision, _rev);
    }
    final LedgerKeyPair? me = pyr._identity;
    if (me == null || !s.treasurers.contains(me.id)) {
      return;
    }
    await _vote(s, me);
    final PyrLedgerView v = view(s);
    // The latest operation of each span a release started that this
    // treasurer signed nothing of yet (refused before the release came).
    final Map<String, PyramidRecord> latest = <String, PyramidRecord>{};
    for (final PyramidRecord op in ledger.ops.values) {
      final String span = PyrLedger.spanOf(op);
      final PyramidRecord? had = latest[span];
      if (PyrLedger.relOf(op).isNotEmpty &&
          PyrLedger.eraOf(op) == s.openEra &&
          !v.leftBehind(op, s) &&
          !v.counted.contains(op.id) &&
          !v.slots.containsKey(PyrLedger.slotOf(op)) &&
          pyr._signedOrders[span] == null &&
          (had == null || PyrLedger.isLater(op, had))) {
        latest[span] = op;
      }
    }
    for (final PyramidRecord op in latest.values) {
      await _consider(op, s, me);
    }
  }

  /// This treasurer's vote for the release of each span of a slot that is
  /// split ([PyrLedger.isSplit]): nothing of the slot counts here, every
  /// operation of the span is of this era, and it has looked split here
  /// for [kPyrReleaseWaitMs]. One vote per span, on every device of the
  /// account; the vote goes to the other treasurers at once, and the
  /// release, once most voted, to everyone the slot's operations concern.
  Future<void> _vote(PyramidState s, LedgerKeyPair me) async {
    final PyrLedgerView v = view(s);
    final int now = pyr._now();
    final Map<String, List<PyramidRecord>> spans =
        <String, List<PyramidRecord>>{};
    for (final PyramidRecord op in ledger.ops.values) {
      if (!v.leftBehind(op, s) &&
          s.sealOfEra(PyrLedger.eraOf(op)) == null) {
        (spans[PyrLedger.slotOf(op)] ??= <PyramidRecord>[]).add(op);
      }
    }
    final Set<String> split = <String>{};
    final List<PyramidRecord> voted = <PyramidRecord>[];
    bool changed = false;
    for (final MapEntry<String, List<PyramidRecord>> e in spans.entries) {
      final String slot = e.key;
      if (v.slots.containsKey(slot) ||
          e.value.any(
            (PyramidRecord op) => PyrLedger.eraOf(op) != s.openEra,
          ) ||
          !PyrLedger.isSplit(e.value, s.treasurers)) {
        continue;
      }
      final String prev = v.releases[slot] ?? '';
      final String seenKey = '$slot|$prev';
      split.add(seenKey);
      final int? seen = _splitSeen[seenKey];
      if (seen == null) {
        _splitSeen[seenKey] = now;
        changed = true;
        continue;
      }
      if (now - seen < kPyrReleaseWaitMs) {
        continue;
      }
      final PyramidRecord bare = PyrLedger.releaseOf(
        pyramid: s.id,
        slot: slot,
        prev: prev,
        at: s.sealedTo,
      );
      final String once = 'rel|$seenKey';
      final String? done = pyr._signedOrders[once];
      if ((done != null && done != bare.id) ||
          (ledger.releases[bare.id]?.tsigs.containsKey(me.id) ?? false)) {
        continue;
      }
      pyr._markSigned(once, bare.id, bare.at);
      ledger.mergeRelease(
        bare.withTreasurerSig(
          me.id,
          b64(await me.sign(PyramidRecord.treasurerBytes(bare.id))),
        ),
      );
      voted.add(bare);
      changed = true;
    }
    final int had = _splitSeen.length;
    _splitSeen.removeWhere((String k, int _) => !split.contains(k));
    if (!changed && had == _splitSeen.length) {
      return;
    }
    final Set<String> before = _finalReleases(s);
    await save();
    await pyr._save();
    if (voted.isEmpty) {
      return;
    }
    // In frames of [kPyrLedgerFrameBytes]: many spans may be split at once.
    final List<Map<String, dynamic>> frames = _frames(
      const <Map<String, dynamic>>[],
      <Map<String, dynamic>>[
        for (final PyramidRecord r in voted) ledger.releases[r.id]!.toJson(),
      ],
    );
    for (final String k in s.treasurers) {
      if (k != me.id) {
        for (final Map<String, dynamic> f in frames) {
          await sendTo(k, <String, dynamic>{'k': _Priv.ops, ...f});
        }
      }
    }
    // [before] already has this vote: what came to count with it is told
    // by [_afterReleases] when the others' votes come back, or here.
    before.removeAll(<String>{for (final PyramidRecord r in voted) r.id});
    await _afterReleases(s, before);
  }

  /// [_tidy]'s keeping (see there).
  Future<void> _prune(PyramidState s) async {
    final PyrLedgerView v = view(s);
    final Map<String, List<PyramidRecord>> waiting =
        <String, List<PyramidRecord>>{};
    final Set<String> drop = <String>{};
    for (final PyramidRecord op in ledger.ops.values) {
      if (v.counted.contains(op.id)) {
        continue;
      }
      if (!_evidence(op, s)) {
        drop.add(op.id);
        continue;
      }
      (waiting[PyrLedger.payerOf(op)] ??= <PyramidRecord>[]).add(op);
    }
    for (final List<PyramidRecord> l in waiting.values) {
      if (l.length > kPyrMaxEvidencePerPayer) {
        l.sort(
          (PyramidRecord a, PyramidRecord b) =>
              PyrLedger.isLater(a, b) ? -1 : 1,
        );
        drop.addAll(<String>[
          for (final PyramidRecord op in l.skip(kPyrMaxEvidencePerPayer)) op.id,
        ]);
      }
    }
    ledger.ops.removeWhere((String id, PyramidRecord _) => drop.contains(id));
    // Releases: those that count always; the others only for a slot with
    // operations here, the newest few of each.
    final Set<String> slots = <String>{
      for (final PyramidRecord op in ledger.ops.values) PyrLedger.slotOf(op),
    };
    final Map<String, List<PyramidRecord>> open =
        <String, List<PyramidRecord>>{};
    for (final PyramidRecord r in ledger.releases.values) {
      if (PyrLedger.releaseFinal(r, s)) {
        continue;
      }
      if (!slots.contains(r.str('slot'))) {
        drop.add(r.id);
        continue;
      }
      (open[r.str('slot')] ??= <PyramidRecord>[]).add(r);
    }
    for (final List<PyramidRecord> l in open.values) {
      l.sort((PyramidRecord a, PyramidRecord b) {
        final int c = b.at.compareTo(a.at);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      drop.addAll(<String>[for (final PyramidRecord r in l.skip(4)) r.id]);
    }
    final int had = ledger.releases.length;
    ledger.releases.removeWhere(
      (String id, PyramidRecord _) => drop.contains(id),
    );
    if (drop.isNotEmpty || had != ledger.releases.length) {
      await save();
      pyr._changed();
    }
  }

  /// Part of another treasurer's ledger: operations whose payer's
  /// signature holds, with the treasurer signatures that hold, that
  /// [_evidence] admits (evidence counts too), notes that open their
  /// commitment, and releases with the votes that hold (one still
  /// gathering votes for a slot with operations here).
  Future<void> _onOps(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    if (s == null ||
        me == null ||
        !(s.treasurers.contains(me) || pyr._now() < treasurerUntil)) {
      return;
    }
    bool changed = false;
    final Set<String> before = _finalReleases(s);
    final Object? ops = json['ops'];
    if (ops is List) {
      for (final Object? x in ops) {
        final PyramidRecord? raw = PyramidRecord.fromJson(x);
        final PyramidRecord? op = raw == null || !PyrLedger.fits(raw)
            ? null
            : await checked(raw, s);
        if (op != null && _evidence(op, s)) {
          changed = ledger.merge(op) || changed;
        }
      }
    }
    final Object? notes = json['notes'];
    if (notes is List) {
      for (final Object? x in notes) {
        final PyrEmitNote? n = PyrEmitNote.fromJson(x);
        if (n != null && s.members.containsKey(n.to)) {
          changed = ledger.mergeNote(n) || changed;
        }
      }
    }
    if (changed) {
      await save();
    }
    final bool freed = await _takeReleases(
      json['rel'],
      s,
      votes: true,
      limit: 256,
    );
    if (freed) {
      await _afterReleases(s, before);
    }
    if (changed || freed) {
      pyr._changed();
      await _tidy(s);
    }
  }

  // ---- receiving ----

  /// A sealed frame from the device at [from] (a normalized address).
  Future<void> onFrame(Map<String, dynamic> p, {required String from}) async {
    final Map<String, dynamic>? json = await open(p);
    if (json != null) {
      await _handle(json, from: from);
    }
  }

  /// [json] from the device at [from]; null: from this phone itself.
  Future<void> _handle(Map<String, dynamic> json, {String? from}) async {
    switch (json['k']) {
      case _Priv.order:
        await _onOrder(json);
      case _Priv.sig:
        await _onSig(json);
      case _Priv.refuse:
        await _onRefuse(json, from);
      case _Priv.done:
        await _onDone(json);
        // A member asks for its short statement with what it passed on.
        if (json['a'] is String && json['l'] == true) {
          await _onAsk(<String, dynamic>{'a': json['a'], 'l': true});
        }
      case _Priv.note:
        await _onNote(json);
      case _Priv.ask:
        await _onAsk(json);
      case _Priv.statement:
        await _onStatement(json);
      case _Priv.digest:
        await _onDigest(json, from);
      case _Priv.want:
        await _onWant(json, from);
      case _Priv.ops:
        await _onOps(json);
    }
  }

  // ---- duties ----

  /// Periodic: publish this person's KEM key, resend orders still waiting,
  /// ask for a statement, sync the ledger.
  Future<void> duties() async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    if (s == null || me == null) {
      return;
    }
    final int now = pyr._now();
    final String? kem = await publicKey();
    final PyrMember? m = s.members[me];
    if (kem != null &&
        m != null &&
        s.isMember(me) &&
        m.kem != kem &&
        now - _kemSentAt > 30 * 60 * 1000) {
      _kemSentAt = now;
      await pyr.propose(
        <String, dynamic>{'t': PyrT.sealKey, 'k': me, 'kem': kem},
        candidates: <String>[me],
        need: 1,
      );
    }
    // Orders and settlements still waiting go out again as they are (every
    // half hour), until they count, are a week old, or their number or
    // payment went to another one (sent from another device of the
    // account); signed afresh in the next span when a release left theirs
    // behind, and in the era open now when a seal closed theirs without
    // them.
    await _reissue(s);
    final PyrLedgerView v = view(s);
    for (final PyramidRecord r in pyr._payments.values.toList()) {
      final PyramidRecord? kept = ledger.ops[r.id];
      final String? took = v.slots[PyrLedger.slotOf(r)];
      if ((kept != null && PyrLedger.isFinal(kept, s)) ||
          (took != null && took != r.id) ||
          (r.type == PyrT.transfer && r.integer('seq') < nextSeq(me)) ||
          now - r.at > kPyrMaxOrderAgeMs) {
        pyr._payments.remove(r.id);
        pyr._resentAt.remove(r.id);
        await pyr._save();
      } else if (now - (pyr._resentAt[r.id] ?? 0) > 30 * 60 * 1000) {
        await toTreasurers(r);
      }
    }
    _signedAt.removeWhere(
      (String _, List<int> at) => at.every((int x) => x <= now - kPyrDayMs),
    );
    _refusals.removeWhere(
      (String id, Map<String, (String, int)> _) =>
          !pyr._payments.containsKey(id),
    );
    await _askIfHere();
    if (!s.treasurers.contains(me)) {
      await askStatements();
      // Payments that came in and still wait for the treasurers: asked
      // again for a day after the newest of them.
      final Set<String> waits = awaiting(me);
      final int newest = <int>[
        for (final PyrLedgerEntry e in view(s).entries)
          if (waits.contains(e.id)) e.at,
      ].fold(0, max);
      if (waits.isNotEmpty &&
          now - newest < kPyrConfirmForMs &&
          now - _confirmAskedAt >= kPyrConfirmEveryMs) {
        await _askToConfirm(s, me);
      }
    }
    if (pyr._pruneSigned(s, _keeps(s) ? view(s) : null)) {
      await pyr._save();
    }
    await syncDuty();
    await _sealDuty();
  }

  // ---- seals of the eras ----

  /// Seals the open era of the treasurers ([PyrT.seal]) with the others
  /// of its treasurers, when this person is one of them and keeps the
  /// whole ledger. The app signs by itself:
  /// - every seal of the era it can check ([_sealHolds]) that dominates
  ///   the one it signed before ([PyrSeal.dominates]: more operations, or
  ///   the same with the lower id), the best of them — never one that does
  ///   not, so two seals of an era an honest app signed always dominate
  ///   one another, and the treasurers meet in the best one;
  /// - its own, ending [kPyrMaxSkewMs] before now (what was dated before
  ///   had time to come), once the era is due by it and [kPyrSealSyncedMs]
  ///   after this phone offered its ledger to the others, unless a seal
  ///   it can check already lists everything it counts.
  /// From its first seal of the era on, it signs no more operations of it
  /// ([kPyrOtherEra]); their payers order again in the next era.
  Future<void> _sealDuty() async {
    final PyramidState? s = pyr.state;
    final LedgerKeyPair? me = pyr._signer;
    if (s == null ||
        me == null ||
        !_keeps(s) ||
        !s.treasurers.contains(me.id)) {
      return;
    }
    final int n = s.openEra;
    final int now = pyr._now();
    final PyrLedgerView v = view(s);
    final String key = 'seal|$n';
    final PyramidRecord? signed = pyr._records[pyr._signedOrders[key] ?? ''];
    final PyrSeal? mine = signed == null ? null : PyrSeal.read(signed);
    bool may(PyrSeal x) => mine == null || x.id == mine.id || x.dominates(mine);
    final Set<String> counted = ledger.countedIn(v, n).toSet();
    final List<(PyrSeal, PyramidRecord)> held = <(PyrSeal, PyramidRecord)>[
      for (final PyramidRecord r in pyr._records.values)
        if (r.type == PyrT.seal && r.body['n'] == n)
          if (PyrSeal.read(r) case final PyrSeal x
              when may(x) && _sealHolds(x, r, s, v, now))
            (x, r),
    ];
    final int to = now - kPyrMaxSkewMs;
    final PyrEraToSeal? era = s.eraToSeal(to);
    if (era != null &&
        syncedAt > era.from &&
        now - syncedAt >= kPyrSealSyncedMs &&
        _sealDue(era.from, to, counted.length, era.next, era.set) &&
        _leavesOutNothingOwn(counted, n, v, now) &&
        !held.any(
          ((PyrSeal, PyramidRecord) h) => h.$1.ops.containsAll(counted),
        )) {
      final PyramidRecord own = PyramidRecord(
        body: PyrSeal.body(
          pyramid: s.id,
          n: era.n,
          prev: era.prev,
          from: era.from,
          to: era.to,
          set: era.set,
          next: era.next,
          ops: counted,
          changes: era.changes,
        ),
      );
      final PyrSeal? x = PyrSeal.read(own);
      // A seal that would not fit a record (or a signal) is never taken by
      // anybody: said so, and nothing is signed.
      if (x == null ||
          own.signedBytes.length > kPyrMaxRecordBytes ||
          utf8.encode(jsonEncode(own.toJson())).length > kPyrMaxFrameBytes) {
        logZenError(
          'Pyramid: seal of era $n',
          StateError('${counted.length} operations do not fit'),
          StackTrace.current,
        );
      } else if (may(x)) {
        held.add((x, pyr._records[own.id] ?? own));
      }
    }
    (PyrSeal, PyramidRecord)? best;
    for (final (PyrSeal, PyramidRecord) h in held) {
      // More operations first, then the lower id: what dominates comes
      // first, and every app picks the same among the rest.
      if (best == null ||
          h.$1.ops.length > best.$1.ops.length ||
          (h.$1.ops.length == best.$1.ops.length &&
              h.$1.id.compareTo(best.$1.id) < 0)) {
        best = h;
      }
    }
    if (best == null || best.$2.sigs.containsKey(me.id)) {
      return;
    }
    pyr._markSigned(key, best.$1.id, best.$1.to);
    await pyr._save();
    await pyr.ingest(await best.$2.signedBy(me));
  }

  /// Whether an era from [from] to [to] with [ops] operations that count
  /// may be sealed: it ran [kPyrEraMs], it has [kPyrEraOps] operations, or
  /// the tree's treasurers are no longer its own ([next] against [set])
  /// and it ran [kPyrEraChangeMs]. Judged by the time a seal names, which
  /// its co-signers accept up to [kPyrMaxSkewMs] ahead of their clocks.
  static bool _sealDue(
    int from,
    int to,
    int ops,
    List<String> next,
    List<String> set,
  ) =>
      to - from >= kPyrEraMs ||
      ops >= kPyrEraOps ||
      (!listEquals(next, set) && to - from >= kPyrEraChangeMs);

  /// Whether this treasurer can co-sign [x] (record [r]) for the open era
  /// of [s]: it follows the last seal, names the era's treasurers, ends no
  /// later than [kPyrMaxSkewMs] after [now] and when the era was due; the
  /// tree here gives its next treasurers at its end, with no change of
  /// them (or departure) it does not name; and every operation it lists
  /// is of the era and counts on this whole ledger ([v]). It need not list
  /// everything this ledger counts: what it leaves out is ordered again in
  /// the next era.
  bool _sealHolds(
    PyrSeal x,
    PyramidRecord r,
    PyramidState s,
    PyrLedgerView v,
    int now,
  ) {
    if (x.prev != (s.seals.lastOrNull?.id ?? '') ||
        x.from != s.sealedTo ||
        r.at != x.to ||
        x.to <= x.from ||
        x.to > now + kPyrMaxSkewMs ||
        !listEquals(x.set, s.treasurers) ||
        !_sealDue(x.from, x.to, x.ops.length, x.next, x.set)) {
      return false;
    }
    final PyrEraToSeal? era = s.eraToSeal(x.to);
    if (era == null ||
        !listEquals(era.next, x.next) ||
        !x.changes.containsAll(era.changes)) {
      return false;
    }
    for (final String id in x.ops) {
      final PyramidRecord? op = ledger.ops[id];
      if (op == null ||
          PyrLedger.eraOf(op) != x.n ||
          !v.counted.contains(id)) {
        return false;
      }
    }
    return _leavesOutNothingOwn(x.ops, x.n, v, now);
  }

  /// Whether a seal of era [n] listing [ops] leaves out no operation of
  /// the era this treasurer signed: none that counts here, and none dated
  /// less than [kPyrSealGraceMs] before [now] (it may count yet).
  bool _leavesOutNothingOwn(
    Set<String> ops,
    int n,
    PyrLedgerView v,
    int now,
  ) {
    final String? me = pyr.myKey;
    for (final PyramidRecord op in ledger.ops.values) {
      if (op.tsigs.containsKey(me) &&
          PyrLedger.eraOf(op) == n &&
          !ops.contains(op.id) &&
          (v.counted.contains(op.id) || now - op.at < kPyrSealGraceMs)) {
        return false;
      }
    }
    return true;
  }
}
