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

/// About how much of the ledger one sealed frame carries.
const int kPyrLedgerFrameBytes = 900 * 1024;

/// Operations a statement carries in full (the newest; the others only by
/// id).
const int kPyrStatementOps = 50;

/// Kinds of the sealed messages ([PyramidTypes.priv]).
abstract final class _Priv {
  /// An order or a settlement for a treasurer to sign.
  static const String order = 'ord';

  /// A treasurer's signature back to whoever ordered.
  static const String sig = 'tsig';

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
    _recoverAsk = false;
    _rev++;
    final List<int>? raw;
    try {
      raw = await pyr.disk.read(_key);
    } on Object catch (error, stack) {
      _unreadable = true;
      logZenError('Piramida: prywatna księga', error, stack);
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
      }
    } on Object catch (error, stack) {
      // Damaged: it comes back from the treasurers.
      logZenError('Piramida: prywatna księga', error, stack);
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
  /// handled here at once.
  Future<void> sendTo(String to, Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return;
    }
    if (to == pyr.myKey) {
      await _handle(json);
      return;
    }
    final String addr = s.members[to]?.addr ?? '';
    if (addr.isEmpty) {
      return;
    }
    final Map<String, dynamic>? frame = await seal(json, s, to);
    if (frame != null) {
      await pyr._send(addr, frame);
    }
  }

  // ---- reading ----

  bool get isTreasurer {
    final String? me = pyr.myKey;
    final PyramidState? s = pyr.state;
    return me != null && s != null && s.treasurers.contains(me);
  }

  /// The ledger as this phone has it (computed again only when the ledger,
  /// the statements or the pyramid changed).
  PyrLedgerView view(PyramidState s) {
    final Object key = (s, s.revision, _rev);
    final PyrLedgerView? had = _view;
    if (had != null && _viewKey == key) {
      return had;
    }
    _viewKey = key;
    return _view = ledger.compute(s);
  }

  /// The statement most treasurers agree on, if any.
  PyrStatement? agreed(PyramidState s) =>
      pyrAgreedStatement(statements, s.treasurers);

  /// This person's balance: from the ledger here when it counted all the
  /// statement most treasurers signed did (always so for a treasurer in
  /// sync); otherwise that statement, with what came since.
  int balanceOf(String me) {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return 0;
    }
    final PyrLedgerView v = view(s);
    final PyrStatement? st = agreed(s);
    if (st == null || v.counted.containsAll(st.ids)) {
      return v.balanceOf(me);
    }
    final Object key = (s, s.revision, _rev, st.by, st.at);
    PyrLedgerView? since = _since;
    if (since == null || _sinceKey != key) {
      _sinceKey = key;
      since = _since = ledger.compute(s, skip: st.ids.toSet());
    }
    return st.balance + since.balanceOf(me);
  }

  /// The number this person's next order takes.
  int nextSeq(String me) {
    final PyramidState? s = pyr.state;
    if (s == null) {
      return 1;
    }
    return max(agreed(s)?.seq ?? 0, view(s).seqOf(me)) + 1;
  }

  // ---- ordering ----

  /// Sends [order] (or a settlement) to every treasurer of its time; kept
  /// until most of them signed — also across a restart — and sent again
  /// as it is.
  Future<void> toTreasurers(PyramidRecord order) async {
    final PyramidState? s = order.pyramid == pyr.current ? pyr.state : null;
    if (s == null || pyr.myKey == null) {
      return;
    }
    pyr._payments[order.id] ??= order;
    pyr._resentAt[order.id] = pyr._now();
    await pyr._save();
    for (final String t in s.treasurersAt(order.at)) {
      await sendTo(t, <String, dynamic>{'k': _Priv.order, 'r': order.toJson()});
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

  /// A treasurer checks an order against its own ledger and signs it (once
  /// per slot), keeping its signature as evidence; the signature goes back
  /// to whoever signed the order.
  Future<void> _onOrder(Map<String, dynamic> json) async {
    final LedgerKeyPair? me = pyr._identity;
    final PyramidState? s = pyr.state;
    final PyramidRecord? raw = PyramidRecord.fromJson(json['r']);
    if (me == null || s == null || raw == null) {
      return;
    }
    if (!s.treasurersAt(raw.at).contains(me.id) ||
        !s.treasurers.contains(me.id)) {
      return;
    }
    final PyramidRecord? op = await checked(raw, s);
    if (op == null) {
      return;
    }
    final int now = pyr._now();
    final String payer = op.type == PyrT.transfer ? op.str('from') : '';
    final List<int> times = <int>[
      for (final int x in _signedAt[payer] ?? const <int>[])
        if (x > now - kPyrDayMs) x,
    ];
    final String slot = PyrLedger.slotOf(op);
    final String? already = pyr._signedOrders[slot];
    if (already != null && already != op.id) {
      return;
    }
    // The same order again (its signature lost on the way) is signed
    // again, not counted twice.
    if (already == null &&
        PyrLedger.problem(op, s, view(s), now, signedToday: times.length) !=
            null) {
      return;
    }
    if (already == null && payer.isNotEmpty) {
      _signedAt[payer] = <int>[...times, now];
    }
    pyr._signedOrders[slot] = op.id;
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
  /// it concerns.
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
        !s.treasurersAt(order.at).contains(k)) {
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
    if (PyrLedger.isFinal(more, s)) {
      pyr._payments.remove(order.id);
      pyr._resentAt.remove(order.id);
      ledger.merge(more);
      await save();
      await _spreadDone(more, s);
    }
    await pyr._save();
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

  /// An operation that counts goes to every treasurer (of its time and of
  /// now) and to those it concerns: the payer, the one paid, the one whose
  /// word a payment waits for, the next one of an announcement.
  Future<void> _spreadDone(PyramidRecord op, PyramidState s) async {
    final List<PyramidRecord> chain = _withChain(op);
    final Set<String> to = <String>{
      ...s.treasurersAt(op.at),
      ...s.treasurers,
      for (final PyramidRecord x in chain) ...PyrLedger.partiesOf(x),
    }..remove(pyr.myKey);
    final Map<String, dynamic> msg = <String, dynamic>{
      'k': _Priv.done,
      'ops': <Map<String, dynamic>>[
        for (final PyramidRecord x in chain) x.toJson(),
      ],
    };
    for (final String k in to.toList()..sort()) {
      if (s.members.containsKey(k)) {
        await sendTo(k, msg);
      }
    }
  }

  /// Operations that count, or evidence: a treasurer keeps them all, anybody
  /// else only a set that concerns them. A payment to this person is told.
  Future<void> _onDone(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final Object? list = json['ops'];
    if (s == null || me == null || list is! List) {
      return;
    }
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
    if (ops.isEmpty ||
        (!keeper &&
            !ops.any(
              (PyramidRecord op) => PyrLedger.partiesOf(op).contains(me),
            ))) {
      return;
    }
    bool changed = false;
    for (final PyramidRecord op in ops) {
      // Evidence (not counting yet) only for a treasurer.
      if (keeper || PyrLedger.isFinal(op, s)) {
        changed = ledger.merge(op) || changed;
      }
    }
    if (!changed) {
      return;
    }
    await save();
    pyr._changed();
    await _tellPaid(s, me, <String>{for (final PyramidRecord op in ops) op.id});
    // Market messages waiting for their payment.
    await pyr._retryHeld();
  }

  /// Notifications of what came in for this person with operations
  /// [fresh] (each told once).
  Future<void> _tellPaid(PyramidState s, String me, Set<String> fresh) async {
    final PyrLedgerView v = view(s);
    for (final PyrLedgerEntry e in v.entries) {
      if (!fresh.contains(e.id) ||
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

  /// A treasurer's statement of [account] as its ledger has it, signed:
  /// the balance, the number, the operations counted (the newest of them
  /// in full) and the emission notes for it. Sealed to [account] alone.
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
    final PyrLedgerView v = view(s);
    final List<PyramidRecord> mine = ledger.concerning(a);
    final List<PyrEmitNote> notes = <PyrEmitNote>[
      for (final PyrEmitNote n in ledger.notes.values)
        if (n.to == a) n,
    ];
    final Set<String> emitted = <String>{
      for (final PyrEmission e in s.emissions.values)
        if (notes.any((PyrEmitNote n) => n.rc == e.rc)) 'e:${e.id}',
    };
    final List<String> ids = <String>[
      for (final PyramidRecord op in mine)
        if (v.counted.contains(op.id)) op.id,
      ...emitted.where(v.counted.contains),
    ];
    final PyrStatement unsigned = PyrStatement(
      pyramid: s.id,
      account: a,
      balance: v.balanceOf(a),
      seq: v.seqOf(a),
      at: pyr._now(),
      ids: ids,
      by: me.id,
      sig: '',
    );
    final String sig = b64(await me.sign(unsigned.signedBytes));
    final List<PyramidRecord> newest = mine.reversed
        .take(kPyrStatementOps)
        .toList();
    await sendTo(a, <String, dynamic>{
      'k': _Priv.statement,
      'st': <String, dynamic>{...unsigned.toJson(), 'sig': sig},
      'ops': <Map<String, dynamic>>[
        for (final PyramidRecord op in newest)
          if (v.counted.contains(op.id)) op.toJson(),
      ],
      'notes': <Map<String, dynamic>>[
        for (final PyrEmitNote n in notes) n.toJson(),
      ],
    });
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
    final PyrStatement? had = statements[st.by];
    if (had == null || had.at < st.at) {
      statements[st.by] = st;
    }
    final Object? ops = json['ops'];
    if (ops is List) {
      for (final Object? x in ops.take(kPyrStatementOps)) {
        final PyramidRecord? raw = PyramidRecord.fromJson(x);
        final PyramidRecord? op = raw == null ? null : await checked(raw, s);
        if (op != null && PyrLedger.isFinal(op, s)) {
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
    pyr._changed();
  }

  // ---- the treasurers' sync ----

  /// The ledger by buckets (the first character of the ids) with who
  /// signed each, and the notes: what treasurers compare.
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
  }

  /// The buckets of [d] (another's digest) that differ from this ledger's.
  List<String> _differing(Map<dynamic, dynamic> d) {
    final Map<String, String> mine = digest();
    return <String>{
      ...mine.keys,
      ...d.keys.whereType<String>(),
    }.where((String b) => mine[b] != d[b] && b.length <= 2).toList()..sort();
  }

  /// Another treasurer's digest: a current treasurer gets what differs
  /// from here, and is asked for theirs; anybody else (a former treasurer
  /// handing over) is only asked.
  Future<void> _onDigest(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final Object? f = json['f'];
    final Object? d = json['d'];
    if (s == null ||
        me == null ||
        f is! String ||
        d is! Map ||
        f == me ||
        !s.treasurers.contains(me)) {
      return;
    }
    final List<String> differ = _differing(d);
    if (differ.isEmpty) {
      return;
    }
    await sendTo(f, <String, dynamic>{'k': _Priv.want, 'f': me, 'b': differ});
    if (s.treasurers.contains(f)) {
      await _sendBuckets(f, differ);
    }
  }

  /// Asked for buckets: sent only to a treasurer now (or, by one who
  /// stopped being one, to the new ones — that is the handover).
  Future<void> _onWant(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    final Object? f = json['f'];
    final Object? b = json['b'];
    if (s == null ||
        me == null ||
        f is! String ||
        b is! List ||
        !s.treasurers.contains(f)) {
      return;
    }
    final bool keeper =
        s.treasurers.contains(me) || pyr._now() < treasurerUntil;
    if (!keeper) {
      return;
    }
    await _sendBuckets(f, b.whereType<String>().take(17).toList());
  }

  /// The operations of [buckets] (and the notes, 'n') to treasurer [to],
  /// in frames of about [kPyrLedgerFrameBytes].
  Future<void> _sendBuckets(String to, List<String> buckets) async {
    final Set<String> want = buckets.toSet();
    List<Map<String, dynamic>> frame = <Map<String, dynamic>>[];
    int bytes = 0;
    Future<void> flush({List<Map<String, dynamic>>? notes}) async {
      if (frame.isEmpty && notes == null) {
        return;
      }
      await sendTo(to, <String, dynamic>{
        'k': _Priv.ops,
        'ops': frame,
        'notes': ?notes,
      });
      frame = <Map<String, dynamic>>[];
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
    await flush(
      notes: want.contains('n')
          ? <Map<String, dynamic>>[
              for (final PyrEmitNote n in ledger.notes.values) n.toJson(),
            ]
          : null,
    );
  }

  /// Part of another treasurer's ledger: operations whose payer's
  /// signature holds, with the treasurer signatures that hold (evidence
  /// counts too), and notes that open their commitment.
  Future<void> _onOps(Map<String, dynamic> json) async {
    final PyramidState? s = pyr.state;
    final String? me = pyr.myKey;
    if (s == null ||
        me == null ||
        !(s.treasurers.contains(me) || pyr._now() < treasurerUntil)) {
      return;
    }
    bool changed = false;
    final Object? ops = json['ops'];
    if (ops is List) {
      for (final Object? x in ops) {
        final PyramidRecord? raw = PyramidRecord.fromJson(x);
        final PyramidRecord? op = raw == null ? null : await checked(raw, s);
        if (op != null && op.tsigs.keys.any(s.treasurersAt(op.at).contains)) {
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
      pyr._changed();
    }
  }

  // ---- receiving ----

  Future<void> onFrame(Map<String, dynamic> p) async {
    final Map<String, dynamic>? json = await open(p);
    if (json != null) {
      await _handle(json);
    }
  }

  Future<void> _handle(Map<String, dynamic> json) async {
    switch (json['k']) {
      case _Priv.order:
        await _onOrder(json);
      case _Priv.sig:
        await _onSig(json);
      case _Priv.done:
        await _onDone(json);
      case _Priv.note:
        await _onNote(json);
      case _Priv.ask:
        await _onAsk(json);
      case _Priv.statement:
        await _onStatement(json);
      case _Priv.digest:
        await _onDigest(json);
      case _Priv.want:
        await _onWant(json);
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
    // half hour), until they count, are a week old, or the treasurers
    // changed since (the new ones sign none from before).
    for (final PyramidRecord r in pyr._payments.values.toList()) {
      final PyramidRecord? kept = ledger.ops[r.id];
      if ((kept != null && PyrLedger.isFinal(kept, s)) ||
          now - r.at > kPyrMaxOrderAgeMs ||
          r.at < s.treasurerEraStart) {
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
    await _askIfHere();
    if (!s.treasurers.contains(me)) {
      await askStatements();
    }
    await syncDuty();
  }
}
