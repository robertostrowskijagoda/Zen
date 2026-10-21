/// Private payments of the pyramid.
///
/// Nobody but the payer, the one paid and the treasurers learns that a
/// payment happened — not even its existence. An order ([PyrT.transfer])
/// or a settlement of a conditional payment ([PyrT.settle]) is signed by
/// the payer like a record, sealed to each treasurer and never enters the
/// public log. A treasurer signs it only against its own copy of the
/// private ledger (the next number of the account, the money there, the
/// daily limit, fresh) and never two operations for one slot (the
/// account's number, or one settlement per payment). An operation counts
/// once most of the treasurers of its time signed it ([PyrLedger.isFinal]):
/// two majorities share an honest treasurer, so as long as most of them
/// are honest nothing is spent twice.
///
/// Every treasurer keeps the whole ledger and syncs it with the others
/// (also to a new set of treasurers); everybody else keeps only what
/// concerns them, and the treasurers' signed statements of their balance.
/// Emissions stay public in amount (the hard limit is everybody's to
/// check), with the one who gets the money only as a commitment
/// ([pyrEmitCommit]); its note ([PyrEmitNote]) goes sealed to the
/// treasurers and the one paid.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// How old an order (or a settlement) a treasurer still signs: it may
/// wait for treasurers who are offline, but not for ever.
const int kPyrMaxOrderAgeMs = 7 * 24 * 3600 * 1000;

/// The longest a conditional payment may wait for its word.
const int kPyrMaxHoldMs = 30 * 24 * 3600 * 1000;

/// At most this many intermediaries pass one announcement on.
const int kMaxAdHops = 5;

/// The commitment to who gets emission [to], with [salt]: public in the
/// emission record, opened by its note ([PyrEmitNote]).
String pyrEmitCommit(String to, String salt) =>
    sha256Hex(utf8.encode('zen-pyr-emit|$to|$salt'));

/// Who gets an emission and why: sealed to the treasurers and to the one
/// paid; it opens the emission's commitment.
@immutable
final class PyrEmitNote {
  const PyrEmitNote({
    required this.rc,
    required this.to,
    required this.salt,
    this.why = '',
  });

  final String rc;
  final String to;
  final String salt;
  final String why;

  bool get holds => pyrEmitCommit(to, salt) == rc;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'rc': rc,
    'to': to,
    'salt': salt,
    if (why.isNotEmpty) 'why': why,
  };

  static PyrEmitNote? fromJson(Object? json) {
    if (json is! Map ||
        json['rc'] is! String ||
        json['to'] is! String ||
        json['salt'] is! String) {
      return null;
    }
    final Object? why = json['why'];
    final PyrEmitNote n = PyrEmitNote(
      rc: json['rc'] as String,
      to: json['to'] as String,
      salt: json['salt'] as String,
      why: why is String && why.length <= 500 ? why : '',
    );
    return n.holds && (json['salt'] as String).length <= 64 ? n : null;
  }
}

/// A conditional payment: put aside by its order, kept or returned by its
/// settlement.
final class PyrEscrow {
  PyrEscrow({
    required this.id,
    required this.from,
    required this.to,
    required this.amount,
    required this.condBy,
    required this.until,
    this.memo = '',
    this.share = 0,
    this.hops = 0,
    this.hash,
    this.parent,
    this.at = 0,
  });

  final String id;

  /// When the money was put aside (no settlement may be dated before).
  final int at;

  /// Who paid (also for every later hop of an announcement: the money is
  /// still theirs until somebody keeps it, and comes back to them).
  final String from;
  final String to;
  final int amount;
  final String condBy;
  final int until;
  final String memo;

  /// An announcement passed on through intermediaries: each one who
  /// accepts keeps [share] and may pass the rest on to one next person
  /// while [hops] > 0; 0 = an ordinary conditional payment.
  final int share;
  final int hops;

  /// Hash of the announcement's text, so nobody on the way can change it.
  final String? hash;

  /// The escrow of the hop before (announcements).
  final String? parent;
  bool? settled;

  /// What happened to the rest at settling (announcements): the escrow of
  /// the next hop, or null when it went back to the payer.
  String? next;

  bool get isChain => share > 0;
}

/// One line of an account's history.
enum PyrEntryKind { payment, hold, kept, returned, emission }

@immutable
final class PyrLedgerEntry {
  const PyrLedgerEntry({
    required this.id,
    required this.kind,
    required this.from,
    required this.to,
    required this.amount,
    required this.at,
    this.memo = '',
  });

  final String id;
  final PyrEntryKind kind;
  final String from;
  final String to;
  final int amount;
  final int at;
  final String memo;
}

/// What the operations a phone knows give: balances, numbers, the
/// conditional payments and the history.
final class PyrLedgerView {
  final Map<String, int> balances = <String, int>{};
  final Map<String, int> seqs = <String, int>{};
  final Map<String, PyrEscrow> escrows = <String, PyrEscrow>{};
  final List<PyrLedgerEntry> entries = <PyrLedgerEntry>[];

  /// Slot (account and number, or a payment settled) → the operation that
  /// took it.
  final Map<String, String> slots = <String, String>{};

  /// Times of the counted orders of each payer (the daily limit).
  final Map<String, List<int>> orderTimes = <String, List<int>>{};

  /// The operations that counted (and the emissions credited, 'e:' + id).
  final Set<String> counted = <String>{};

  /// Treasurers caught signing two operations for one slot.
  final Map<String, List<String>> cheaters = <String, List<String>>{};

  int balanceOf(String key) => balances[key] ?? 0;
  int seqOf(String key) => seqs[key] ?? 0;

  /// Orders [key] placed in the day up to [at].
  int ordersInDay(String key, int at) => (orderTimes[key] ?? const <int>[])
      .where((int t) => t <= at && t > at - kPyrDayMs)
      .length;

  void _add(String key, int amount, Set<String> skip, String id) {
    if (!skip.contains(id)) {
      balances[key] = (balances[key] ?? 0) + amount;
    }
  }
}

/// The private ledger a phone keeps: operations with the treasurer
/// signatures that checked (merged, never replaced), and emission notes.
/// A treasurer's holds them all; anybody else's what concerns them.
final class PyrLedger {
  final Map<String, PyramidRecord> ops = <String, PyramidRecord>{};
  final Map<String, PyrEmitNote> notes = <String, PyrEmitNote>{};

  /// The slot an operation takes: one per account number, one settlement
  /// per payment.
  static String slotOf(PyramidRecord op) => op.type == PyrT.settle
      ? 'x|${op.str('x')}'
      : '${op.str('from')}|${op.integer('seq')}';

  /// Whether [op] counts: signed by most of the treasurers of its time.
  static bool isFinal(PyramidRecord op, PyramidState s) {
    final List<String> t = s.treasurersAt(op.at);
    return t.isNotEmpty &&
        op.tsigs.keys.where(t.contains).length >= t.length ~/ 2 + 1;
  }

  /// Takes [op] (its signatures already checked): new, or more treasurer
  /// signatures for one here. Whether anything changed.
  bool merge(PyramidRecord op) {
    if (!PyrT.treasured.contains(op.type)) {
      return false;
    }
    final PyramidRecord? had = ops[op.id];
    if (had == null) {
      ops[op.id] = op;
      return true;
    }
    final Map<String, String> more = <String, String>{
      for (final MapEntry<String, String> e in op.tsigs.entries)
        if (!had.tsigs.containsKey(e.key)) e.key: e.value,
    };
    if (more.isEmpty) {
      return false;
    }
    ops[op.id] = PyramidRecord(
      body: had.body,
      sigs: had.sigs.isEmpty ? op.sigs : had.sigs,
      tsigs: <String, String>{...had.tsigs, ...more},
    );
    return true;
  }

  /// Takes emission note [n] when it opens its commitment.
  bool mergeNote(PyrEmitNote n) {
    if (!n.holds || notes.containsKey(n.rc)) {
      return false;
    }
    notes[n.rc] = n;
    return true;
  }

  /// The operations (and notes) that concern [key]: as its payer, the one
  /// paid, the one whose word a payment waits for, the next one of an
  /// announcement — and the orders of the conditional payments they
  /// settle, so the settlement can be read.
  List<PyramidRecord> concerning(String key) {
    final Set<String> mine = <String>{};
    for (final PyramidRecord op in ops.values) {
      if (partiesOf(op).contains(key)) {
        mine.add(op.id);
      }
    }
    // The orders (and hops) the settlements in it refer to.
    bool grew = true;
    while (grew) {
      grew = false;
      for (final PyramidRecord op in ops.values) {
        if (op.type == PyrT.settle && mine.contains(op.id)) {
          final String x = op.str('x');
          if (ops.containsKey(x) && mine.add(x)) {
            grew = true;
          }
        }
        if (op.type == PyrT.settle && mine.contains(op.str('x'))) {
          if (mine.add(op.id)) {
            grew = true;
          }
        }
      }
    }
    return <PyramidRecord>[for (final String id in mine) ops[id]!]
      ..sort((PyramidRecord a, PyramidRecord b) => a.at.compareTo(b.at));
  }

  /// Who [op] concerns: its payer, the one paid, the one whose word it
  /// waits for (a settlement: its signers and the next one).
  static Set<String> partiesOf(PyramidRecord op) {
    if (op.type == PyrT.settle) {
      return <String>{
        ...op.signers,
        if (op.str('next').isNotEmpty) op.str('next'),
      };
    }
    final Object? cond = op.body['cond'];
    return <String>{
      op.str('from'),
      op.str('to'),
      if (cond is Map && cond['by'] is String) cond['by'] as String,
    };
  }

  /// The ledger as it stands in [s]: the operations that count, oldest
  /// first, and the emissions done whose note is here. Operations in
  /// [skip] change no balance (a statement already counted them) but
  /// still make the conditional payments readable.
  PyrLedgerView compute(PyramidState s, {Set<String> skip = const <String>{}}) {
    final PyrLedgerView v = PyrLedgerView();
    // Two operations for one slot, both signed by one treasurer: evidence,
    // whether they counted or not.
    final Map<String, List<PyramidRecord>> bySlot =
        <String, List<PyramidRecord>>{};
    for (final PyramidRecord op in ops.values) {
      (bySlot[slotOf(op)] ??= <PyramidRecord>[]).add(op);
    }
    for (final List<PyramidRecord> same in bySlot.values) {
      for (int i = 0; i < same.length; i++) {
        for (int j = i + 1; j < same.length; j++) {
          for (final String t in same[i].tsigs.keys) {
            if (same[j].tsigs.containsKey(t)) {
              (v.cheaters[t] ??= <String>[]).addAll(<String>[
                same[i].id,
                same[j].id,
              ]);
            }
          }
        }
      }
    }
    final List<PyramidRecord> finals =
        <PyramidRecord>[
          for (final PyramidRecord op in ops.values)
            if (isFinal(op, s)) op,
        ]..sort((PyramidRecord a, PyramidRecord b) {
          final int c = a.at.compareTo(b.at);
          if (c != 0) {
            return c;
          }
          final int t = (a.type == PyrT.settle ? 1 : 0).compareTo(
            b.type == PyrT.settle ? 1 : 0,
          );
          return t != 0 ? t : a.id.compareTo(b.id);
        });
    for (final PyramidRecord op in finals) {
      final String slot = slotOf(op);
      if (v.slots.containsKey(slot)) {
        // Only a dishonest majority gets a second one through: the first
        // stands.
        continue;
      }
      if (op.type == PyrT.transfer) {
        _order(v, op, skip);
      } else {
        _settle(v, op, s, skip);
      }
    }
    for (final PyrEmission e in s.emissions.values) {
      final PyrEmitNote? n = notes[e.rc];
      if (!e.done || e.vetoed || n == null) {
        continue;
      }
      final String id = 'e:${e.id}';
      v
        .._add(n.to, e.amount, skip, id)
        ..counted.add(id)
        ..entries.add(
          PyrLedgerEntry(
            id: id,
            kind: PyrEntryKind.emission,
            from: '',
            to: n.to,
            amount: e.amount,
            at: e.effectiveAt,
            memo: n.why,
          ),
        );
    }
    v.entries.sort(
      (PyrLedgerEntry a, PyrLedgerEntry b) => a.at.compareTo(b.at),
    );
    return v;
  }

  void _order(PyrLedgerView v, PyramidRecord op, Set<String> skip) {
    final String from = op.str('from');
    final String to = op.str('to');
    final int amount = op.integer('amount');
    final int seq = op.integer('seq');
    v
      ..slots[slotOf(op)] = op.id
      ..counted.add(op.id)
      ..seqs[from] = max(v.seqOf(from), seq);
    (v.orderTimes[from] ??= <int>[]).add(op.at);
    v._add(from, -amount, skip, op.id);
    final Object? cond = op.body['cond'];
    if (cond is Map && cond['by'] is String) {
      final int share = cond['share'] is int
          ? (cond['share'] as int).clamp(0, amount)
          : 0;
      v.escrows[op.id] = PyrEscrow(
        id: op.id,
        at: op.at,
        from: from,
        to: to,
        amount: amount,
        condBy: cond['by'] as String,
        until: cond['until'] is int
            ? cond['until'] as int
            : op.at + 7 * 24 * 3600 * 1000,
        memo: op.str('memo'),
        share: share,
        hops: share > 0 && cond['hops'] is int
            ? (cond['hops'] as int).clamp(0, kMaxAdHops - 1)
            : 0,
        hash: cond['h'] is String ? cond['h'] as String : null,
      );
      v.entries.add(
        PyrLedgerEntry(
          id: op.id,
          kind: PyrEntryKind.hold,
          from: from,
          to: to,
          amount: amount,
          at: op.at,
          memo: op.str('memo'),
        ),
      );
      return;
    }
    v
      .._add(to, amount, skip, op.id)
      ..entries.add(
        PyrLedgerEntry(
          id: op.id,
          kind: PyrEntryKind.payment,
          from: from,
          to: to,
          amount: amount,
          at: op.at,
          memo: op.str('memo'),
        ),
      );
  }

  void _settle(
    PyrLedgerView v,
    PyramidRecord op,
    PyramidState s,
    Set<String> skip,
  ) {
    final PyrEscrow? e = v.escrows[op.str('x')];
    if (e == null || e.settled != null || op.at < e.at) {
      return;
    }
    v
      ..slots[slotOf(op)] = op.id
      ..counted.add(op.id);
    final bool ok = op.body['ok'] == true;
    e.settled = ok;
    if (!ok) {
      v
        .._add(e.from, e.amount, skip, op.id)
        ..entries.add(
          PyrLedgerEntry(
            id: op.id,
            kind: PyrEntryKind.returned,
            from: e.to,
            to: e.from,
            amount: e.amount,
            at: op.at,
            memo: e.memo,
          ),
        );
      return;
    }
    final int keep = e.isChain ? min(e.share, e.amount) : e.amount;
    v
      .._add(e.to, keep, skip, op.id)
      ..entries.add(
        PyrLedgerEntry(
          id: op.id,
          kind: PyrEntryKind.kept,
          from: e.from,
          to: e.to,
          amount: keep,
          at: op.at,
          memo: e.memo,
        ),
      );
    final int rest = e.amount - keep;
    if (rest <= 0) {
      return;
    }
    final String next = op.str('next');
    // Never back to anybody already on the way (no loops collecting a
    // share twice).
    if (e.hops > 0 &&
        next.isNotEmpty &&
        s.isMember(next) &&
        !_onChain(v, e, next) &&
        !v.escrows.containsKey(op.id)) {
      v.escrows[op.id] = PyrEscrow(
        id: op.id,
        at: op.at,
        from: e.from,
        to: next,
        amount: rest,
        condBy: next,
        until: op.at + 7 * 24 * 3600 * 1000,
        memo: e.memo,
        share: e.share,
        hops: e.hops - 1,
        hash: e.hash,
        parent: e.id,
      );
      e.next = op.id;
      return;
    }
    v._add(e.from, rest, skip, op.id);
  }

  static bool _onChain(PyrLedgerView v, PyrEscrow e, String key) {
    PyrEscrow? x = e;
    int guard = 0;
    while (x != null && guard++ < kMaxAdHops + 2) {
      if (x.to == key || x.from == key) {
        return true;
      }
      x = x.parent == null ? null : v.escrows[x.parent];
    }
    return false;
  }

  /// Why a treasurer with this ledger ([v], computed in [s]) may not sign
  /// [op] at [now], or null: fresh; signed by its payer (or the one whose
  /// word a payment waits for, or the payer refunding after the time);
  /// within the treasurers' era it was made in; the next number of the
  /// account, the money there and the day's payments under
  /// [PyrParams.xferLimit] — by the orders' own times and by the
  /// [signedToday] orders of the payer this treasurer signed in the last
  /// day by its own clock (an order dated back does not escape it); both
  /// sides members.
  static String? problem(
    PyramidRecord op,
    PyramidState s,
    PyrLedgerView v,
    int now, {
    int signedToday = 0,
  }) {
    if (op.at > now + kPyrMaxSkewMs || now - op.at > kPyrMaxOrderAgeMs) {
      return 'zlecenie stare albo z przyszłości';
    }
    if (op.at < s.treasurerEraStart) {
      return 'zlecenie sprzed zmiany skarbników';
    }
    if (op.pyramid != s.id) {
      return 'inna piramida';
    }
    if (op.type == PyrT.transfer) {
      final String from = op.str('from');
      final String to = op.str('to');
      final int amount = op.integer('amount');
      if (!op.signers.contains(from) ||
          !s.pqHolds(op, from) ||
          !s.isMember(from) ||
          !s.isMember(to) ||
          from == to ||
          amount <= 0 ||
          amount > kPyrMaxAmount) {
        return 'zły przelew';
      }
      if (op.integer('seq') != v.seqOf(from) + 1) {
        return 'zły numer kolejny';
      }
      if (v.balanceOf(from) < amount) {
        return 'za mało środków';
      }
      if (max(v.ordersInDay(from, op.at), signedToday) >= s.params.xferLimit) {
        return 'limit przelewów na dzień';
      }
      final Object? cond = op.body['cond'];
      if (cond != null) {
        final Object? until = cond is Map ? cond['until'] : null;
        if (cond is! Map ||
            cond['by'] is! String ||
            !s.isMember(cond['by'] as String) ||
            (until != null &&
                (until is! int ||
                    until <= op.at ||
                    until > op.at + kPyrMaxHoldMs))) {
          return 'zły warunek';
        }
      }
      return null;
    }
    if (op.type != PyrT.settle) {
      return 'nie przelew';
    }
    final PyrEscrow? e = v.escrows[op.str('x')];
    if (e == null || e.settled != null || op.at < e.at) {
      return 'nie ma czego rozliczyć';
    }
    final bool ok = op.body['ok'] == true;
    final bool byCond =
        op.signers.contains(e.condBy) && s.pqHolds(op, e.condBy);
    final bool refund =
        !ok &&
        op.signers.contains(e.from) &&
        s.pqHolds(op, e.from) &&
        op.at >= e.until;
    if (!byCond && !refund) {
      return 'rozlicza odbiorca warunku albo płacący po terminie';
    }
    if (ok && now > e.until + kPyrMaxSkewMs) {
      return 'za późno na przyjęcie';
    }
    final String next = op.str('next');
    if (next.isNotEmpty && !s.isMember(next)) {
      return 'dalej tylko do członka';
    }
    return null;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ops': <Map<String, dynamic>>[
      for (final PyramidRecord op in ops.values) op.toJson(),
    ],
    'notes': <Map<String, dynamic>>[
      for (final PyrEmitNote n in notes.values) n.toJson(),
    ],
  };

  /// What was stored (checked when it came: taken as it is).
  static PyrLedger fromJson(Object? json) {
    final PyrLedger l = PyrLedger();
    if (json is! Map) {
      return l;
    }
    final Object? ops = json['ops'];
    if (ops is List) {
      for (final Object? o in ops) {
        final PyramidRecord? r = PyramidRecord.fromJson(o);
        if (r != null && PyrT.treasured.contains(r.type)) {
          l.ops[r.id] = r;
        }
      }
    }
    final Object? notes = json['notes'];
    if (notes is List) {
      for (final Object? n in notes) {
        final PyrEmitNote? x = PyrEmitNote.fromJson(n);
        if (x != null) {
          l.notes[x.rc] = x;
        }
      }
    }
    return l;
  }
}

/// A treasurer's signed statement of one account: its balance and number
/// as that treasurer's ledger has them, and which operations it counted.
@immutable
final class PyrStatement {
  const PyrStatement({
    required this.pyramid,
    required this.account,
    required this.balance,
    required this.seq,
    required this.at,
    required this.ids,
    required this.by,
    required this.sig,
  });

  final String pyramid;
  final String account;
  final int balance;
  final int seq;
  final int at;

  /// The operations it counted (and 'e:' + emission id).
  final List<String> ids;

  /// The treasurer, and their signature of [signedBytes].
  final String by;
  final String sig;

  /// What agreeing treasurers share.
  String get agreement =>
      '$balance|$seq|${sha256Hex(utf8.encode((List<String>.of(ids)..sort()).join(',')))}';

  Map<String, dynamic> get body => <String, dynamic>{
    'py': pyramid,
    'a': account,
    'bal': balance,
    'seq': seq,
    'at': at,
    'ids': List<String>.of(ids)..sort(),
  };

  Uint8List get signedBytes => Uint8List.fromList(<int>[
    ...utf8.encode('zen-pyr-statement|'),
    ...canonicalJsonBytes(body),
  ]);

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...body,
    'by': by,
    'sig': sig,
  };

  static PyrStatement? fromJson(Object? json) {
    if (json is! Map ||
        json['py'] is! String ||
        json['a'] is! String ||
        json['bal'] is! int ||
        json['seq'] is! int ||
        json['at'] is! int ||
        json['ids'] is! List ||
        json['by'] is! String ||
        json['sig'] is! String) {
      return null;
    }
    return PyrStatement(
      pyramid: json['py'] as String,
      account: json['a'] as String,
      balance: json['bal'] as int,
      seq: json['seq'] as int,
      at: json['at'] as int,
      ids: (json['ids'] as List).whereType<String>().toList(),
      by: json['by'] as String,
      sig: json['sig'] as String,
    );
  }
}

/// The statements most of the treasurers agree on (the newest agreement
/// among [all], each treasurer's latest), when most of [treasurers] signed
/// the same balance, number and operations; null otherwise.
PyrStatement? pyrAgreedStatement(
  Map<String, PyrStatement> all,
  List<String> treasurers,
) {
  if (treasurers.isEmpty) {
    return null;
  }
  final Map<String, List<PyrStatement>> by = <String, List<PyrStatement>>{};
  for (final PyrStatement st in all.values) {
    if (treasurers.contains(st.by)) {
      (by[st.agreement] ??= <PyrStatement>[]).add(st);
    }
  }
  PyrStatement? best;
  for (final List<PyrStatement> same in by.values) {
    if (same.length >= treasurers.length ~/ 2 + 1) {
      final PyrStatement newest = same.reduce(
        (PyrStatement a, PyrStatement b) => b.at > a.at ? b : a,
      );
      if (best == null || newest.at > best.at) {
        best = newest;
      }
    }
  }
  return best;
}
