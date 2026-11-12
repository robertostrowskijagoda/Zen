/// Private payments of the pyramid.
///
/// Nobody but the payer, the one paid and the treasurers learns that a
/// payment happened — not even its existence. An order ([PyrT.transfer])
/// or a settlement of a conditional payment ([PyrT.settle]) is signed by
/// the payer like a record, sealed to each treasurer and never enters the
/// public log. A treasurer signs it only when its own copy of the private
/// ledger would count it ([PyrLedger.problem]: by the same rules, at the
/// time the operation carries — the next number of the account, the money
/// there then, the daily limit; and fresh) and never two operations for
/// one span of a slot
/// (the account's number, or one settlement per payment). An operation
/// counts once most of the treasurers of its time signed it
/// ([PyrLedger.isFinal]): two majorities of n share 2m − n treasurers (m
/// the majority: two of an even number, one of an odd one), so nothing is
/// spent twice unless that many sign two operations for one span, which
/// is proof against them ([PyrLedgerView.cheaters]).
///
/// A number split between operations none of which can reach a majority
/// any more ([PyrLedger.isSplit]: cancelled orders, two devices at once,
/// an acceptance and a refund around a payment's time) is freed by a
/// release ([PyrT.release]) most treasurers of the era sign — never by a
/// treasurer signing a second operation on what it alone sees. The release
/// leaves every operation of the span behind (one final only through a
/// signature its treasurer kept from the others too: its holder had to
/// show it to the treasurers before), and the next span of the number
/// starts: an operation names the release it follows (`rel`). A treasurer
/// signs one release per span, so two releases of one span need 2m − n
/// treasurers signing both, like two operations.
///
/// A time is never a source of power by itself: once an era of the
/// treasurers ended, most of the next era's treasurers seal it
/// ([PyrT.seal], [PyrSeal]) with the operations dated in it that counted
/// for them. From then on the era's treasurers are the sealed ones, and an
/// operation dated in it that the seal does not list counts nowhere — the
/// treasurers of back then, or the founder alone in the first era, can
/// sign whatever they like dated back then, it changes nothing. Every
/// phone also checks, when it counts, what an honest treasurer checks
/// before signing ([PyrLedger.breaks]; on a treasurer's whole ledger the
/// numbers and the money too), so no majority makes money from nothing.
///
/// Every treasurer keeps the whole ledger and syncs it with the others
/// (also to a new set of treasurers); everybody else keeps only what
/// concerns them, and the treasurers' signed statements of their balance:
/// a payment to them is money there only once a statement most treasurers
/// signed lists it (only the treasurers know the payer's money and number
/// at its time). Emissions stay public in amount (the hard limit is everybody's to
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

/// The largest body of a private operation (an order's memo is cut far
/// below it): anything bigger is nobody's payment, only weight.
const int kPyrMaxOpBytes = 4 * 1024;

/// The highest number an account's order may take: far more orders than
/// a lifetime makes, and far below where the next number would wrap.
const int kPyrMaxSeq = 1 << 40;

/// How many operations of one payer that do not count (evidence: orders
/// still waiting, or split) a treasurer keeps: the newest.
const int kPyrMaxEvidencePerPayer = 32;

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
  PyrLedgerView({this.holdFor, this.skipBefore = 0});

  /// The account whose credits from operations ([PyrLedger.compute]'s
  /// `hold`) change no balance here but wait in [held]: on a phone that
  /// keeps only its own operations, money comes in once the treasurers'
  /// agreed statement lists it.
  final String? holdFor;

  /// Changes dated before it change no balance (a statement counted them
  /// without listing them: [PyrStatement.from]).
  final int skipBefore;

  final Map<String, int> balances = <String, int>{};
  final Map<String, int> seqs = <String, int>{};
  final Map<String, PyrEscrow> escrows = <String, PyrEscrow>{};
  final List<PyrLedgerEntry> entries = <PyrLedgerEntry>[];

  /// Slot (account and number, or a payment settled) → the operation that
  /// took it.
  final Map<String, String> slots = <String, String>{};

  /// Slot → the last release of it that counts: only operations that name
  /// it (`rel`) can count, those of the spans before it nowhere.
  final Map<String, String> releases = <String, String>{};

  /// Times of the counted orders of each payer (the daily limit).
  final Map<String, List<int>> orderTimes = <String, List<int>>{};

  /// The operations that counted (and the emissions credited, 'e:' + id).
  final Set<String> counted = <String>{};

  /// Treasurers caught signing two operations for one span of a slot, or
  /// two releases of one span.
  final Map<String, List<String>> cheaters = <String, List<String>>{};

  /// Operations most treasurers signed although no honest treasurer would
  /// ([PyrLedger.breaks]: a negative amount, an order its payer did not
  /// sign, a settlement by somebody else...) → why: they count nowhere.
  final Map<String, String> broken = <String, String>{};

  /// Operations that would credit [holdFor] and wait for a statement.
  final Set<String> held = <String>{};

  /// The time of the newest change counted on each account: an order
  /// dated after it is judged on the account as it stands.
  final Map<String, int> lastAt = <String, int>{};

  int balanceOf(String key) => balances[key] ?? 0;
  int seqOf(String key) => seqs[key] ?? 0;

  /// Whether [op] is of a span its slot's release left behind (or names a
  /// release not known here): it counts nowhere and no honest treasurer
  /// signs it. An operation dated in a sealed era goes by its seal.
  bool leftBehind(PyramidRecord op, PyramidState s) =>
      s.sealAt(op.at) == null &&
      PyrLedger.relOf(op) != (releases[PyrLedger.slotOf(op)] ?? '');

  /// Orders [key] placed in the day up to [at].
  int ordersInDay(String key, int at) => (orderTimes[key] ?? const <int>[])
      .where((int t) => t <= at && t > at - kPyrDayMs)
      .length;

  void _add(String key, int amount, Set<String> skip, String id, int at) {
    lastAt[key] = max(lastAt[key] ?? at, at);
    if (skip.contains(id) || at < skipBefore) {
      return;
    }
    // Emissions are public and counted alike on every phone; a payment
    // waits for the treasurers who counted the payer's money.
    if (amount > 0 && key == holdFor && !id.startsWith('e:')) {
      held.add(id);
      return;
    }
    balances[key] = (balances[key] ?? 0) + amount;
  }

  /// Whether adding [amount] to [key] keeps the balance within
  /// ±[kPyrMaxBalance] (so no sum of balances wraps around).
  bool _fits(String key, int amount) {
    final int b = balanceOf(key) + amount;
    return b <= kPyrMaxBalance && b >= -kPyrMaxBalance;
  }
}

/// The private ledger a phone keeps: operations with the treasurer
/// signatures that checked (merged, never replaced), and emission notes.
/// A treasurer's holds them all; anybody else's what concerns them.
final class PyrLedger {
  final Map<String, PyramidRecord> ops = <String, PyramidRecord>{};
  final Map<String, PyrEmitNote> notes = <String, PyrEmitNote>{};

  /// Releases of split spans ([PyrT.release]) with the treasurers' votes
  /// that checked (merged, never replaced).
  final Map<String, PyramidRecord> releases = <String, PyramidRecord>{};

  /// The slot an operation takes: one per account number, one settlement
  /// per payment.
  static String slotOf(PyramidRecord op) => op.type == PyrT.settle
      ? 'x|${op.str('x')}'
      : '${op.str('from')}|${op.integer('seq')}';

  /// The release [op] follows ('' for the first span of its slot).
  static String relOf(PyramidRecord op) => op.str('rel');

  /// The span of a slot [op] belongs to: what an honest treasurer signs
  /// one operation of.
  static String spanOf(PyramidRecord op) {
    final String rel = relOf(op);
    return rel.isEmpty ? slotOf(op) : '${slotOf(op)}|$rel';
  }

  /// The release of span [prev] ('' for the first) of [slot]: the same
  /// record on every treasurer's phone of the era starting at [at], so
  /// their votes meet in it.
  static PyramidRecord releaseOf({
    required String pyramid,
    required String slot,
    required String prev,
    required int at,
  }) => PyramidRecord(
    body: <String, dynamic>{
      't': PyrT.release,
      'py': pyramid,
      'at': at,
      'slot': slot,
      if (prev.isNotEmpty) 'prev': prev,
    },
  );

  /// Whether [r] is shaped like a release.
  static bool isRelease(PyramidRecord r) =>
      r.type == PyrT.release &&
      r.str('slot').isNotEmpty &&
      (r.body['prev'] == null || r.body['prev'] is String) &&
      fits(r);

  /// Whether release [r] counts: most treasurers of its era voted for it.
  static bool releaseFinal(PyramidRecord r, PyramidState s) {
    final List<String> t = s.treasurersAt(r.at);
    return isRelease(r) &&
        t.isNotEmpty &&
        r.tsigs.keys.where(t.contains).length >= t.length ~/ 2 + 1;
  }

  /// The releases of [slot] that count, one after the other from its
  /// first span (of two for one span, which only a dishonest majority
  /// signs, the lower id).
  List<PyramidRecord> chainOf(String slot, PyramidState s) {
    final List<PyramidRecord> all = <PyramidRecord>[
      for (final PyramidRecord r in releases.values)
        if (r.str('slot') == slot && releaseFinal(r, s)) r,
    ];
    final List<PyramidRecord> out = <PyramidRecord>[];
    String prev = '';
    while (out.length < all.length) {
      PyramidRecord? next;
      for (final PyramidRecord r in all) {
        if (r.str('prev') == prev &&
            (next == null || r.id.compareTo(next.id) < 0)) {
          next = r;
        }
      }
      if (next == null) {
        break;
      }
      out.add(next);
      prev = next.id;
    }
    return out;
  }

  /// The release that starts the span of [slot] where its operations count
  /// now ('' for the first).
  String currentOf(String slot, PyramidState s) =>
      chainOf(slot, s).lastOrNull?.id ?? '';

  /// Takes release [r] (its votes already checked): new, or more votes
  /// for one here. Whether anything changed.
  bool mergeRelease(PyramidRecord r) {
    if (!isRelease(r)) {
      return false;
    }
    final PyramidRecord? had = releases[r.id];
    if (had == null) {
      releases[r.id] = r;
      return true;
    }
    final Map<String, String> more = <String, String>{
      for (final MapEntry<String, String> e in r.tsigs.entries)
        if (!had.tsigs.containsKey(e.key)) e.key: e.value,
    };
    if (more.isEmpty) {
      return false;
    }
    releases[r.id] = PyramidRecord(
      body: had.body,
      tsigs: <String, String>{...had.tsigs, ...more},
    );
    return true;
  }

  /// Whether no operation of [span] (the operations of one span of a slot
  /// known here) can reach a majority of [treasurers] any more: each has
  /// fewer signatures of theirs than a majority less those who signed none
  /// of them. An honest treasurer signs one operation per span, so then
  /// none of them is final by honest signatures; one can be final only
  /// through a signature its treasurer kept from the others, which the
  /// span's release leaves behind with the rest. One operation alone is
  /// never split (it can still reach every treasurer).
  static bool isSplit(Iterable<PyramidRecord> span, List<String> treasurers) {
    if (span.isEmpty || treasurers.isEmpty) {
      return false;
    }
    final int m = treasurers.length ~/ 2 + 1;
    final Set<String> signed = <String>{
      for (final PyramidRecord o in span)
        ...o.tsigs.keys.where(treasurers.contains),
    };
    final int free = treasurers.length - signed.length;
    return span.every(
      (PyramidRecord o) =>
          o.tsigs.keys.where(treasurers.contains).length + free < m,
    );
  }

  /// Whose money [op] moves: the payer of an order, the one who signed a
  /// settlement.
  static String payerOf(PyramidRecord op) => op.type == PyrT.transfer
      ? op.str('from')
      : (op.signers.isEmpty ? '' : op.signers.first);

  /// Whether [op]'s body stays within [kPyrMaxOpBytes].
  static bool fits(PyramidRecord op) {
    try {
      return op.signedBytes.length <= kPyrMaxOpBytes;
    } on Object {
      return false;
    }
  }

  /// Whether [b] comes after [a] among the operations for one slot: by
  /// time, then by id (the same order on every phone).
  static bool isLater(PyramidRecord b, PyramidRecord a) {
    final int c = b.at.compareTo(a.at);
    return c != 0 ? c > 0 : b.id.compareTo(a.id) > 0;
  }

  /// Whether [x] can no longer count because its era was sealed without
  /// it: then a later operation of its span may be signed by those who
  /// signed [x] (the next era's, the number taken again). Within an era
  /// only a release frees a span ([isSplit]). With [strict] (judging who
  /// signed two), the seal leaves [x] behind only when it had fewer than
  /// most of its era's signatures: a treasurer of back then who signs an
  /// operation dated into a sealed era is still caught.
  static bool passed(PyramidRecord x, PyramidState s, {bool strict = false}) {
    final PyrSeal? seal = s.sealAt(x.at);
    return seal != null &&
        !seal.ops.contains(x.id) &&
        (!strict ||
            x.tsigs.keys.where(seal.set.contains).length <
                seal.set.length ~/ 2 + 1);
  }

  /// The operations here for [slot].
  List<PyramidRecord> inSlot(String slot) => <PyramidRecord>[
    for (final PyramidRecord op in ops.values)
      if (slotOf(op) == slot) op,
  ];

  /// Whether [op] counts: dated in a sealed era, the era's seal lists it
  /// (an operation it does not list was signed after the era ended, by
  /// treasurers of back then, and counts nowhere) and most of the era's
  /// treasurers signed it; otherwise signed by most of the treasurers of
  /// its time. With [signed], as if most of them had signed it (what a
  /// treasurer asks before it signs).
  static bool isFinal(PyramidRecord op, PyramidState s, {bool signed = false}) {
    final PyrSeal? seal = s.sealAt(op.at);
    if (seal != null && !seal.ops.contains(op.id)) {
      return false;
    }
    final List<String> t = s.treasurersAt(op.at);
    return t.isNotEmpty &&
        (signed || op.tsigs.keys.where(t.contains).length >= t.length ~/ 2 + 1);
  }

  /// [op] with only as many treasurer signatures as make it final (those
  /// of the treasurers of its time, in the order of their keys): what a
  /// phone that does not keep the whole ledger needs, so a message with it
  /// does not grow with the number of treasurers.
  static PyramidRecord majorityOnly(PyramidRecord op, PyramidState s) {
    final List<String> t = s.treasurersAt(op.at);
    final List<String> keep = (op.tsigs.keys.where(t.contains).toList()..sort())
        .take(t.length ~/ 2 + 1)
        .toList();
    if (keep.length == op.tsigs.length) {
      return op;
    }
    return PyramidRecord(
      body: op.body,
      sigs: op.sigs,
      tsigs: <String, String>{for (final String k in keep) k: op.tsigs[k]!},
    );
  }

  /// Why [op] breaks a rule of [problem] that holds however many treasurers
  /// signed it and whoever checks it, or null: of this pyramid, dated within
  /// the treasurers' time; an order signed by its payer (both halves, the
  /// ML-DSA one by the key the payer was admitted with), between two
  /// members of that time, of a positive amount up to [kPyrMaxAmount],
  /// with a number and a well-formed condition waiting for a member. Every
  /// phone applies it when it counts the operations ([compute]), the same
  /// way, so a dishonest majority of treasurers gets nothing through that
  /// an honest one would refuse. (What a settlement must meet depends on
  /// its payment, and the money and numbers on the whole ledger: [compute].)
  static String? breaks(PyramidRecord op, PyramidState s) {
    if (op.pyramid != s.id) {
      return 'inna piramida';
    }
    if (s.treasurerEras.isEmpty || op.at < s.treasurerEras.first.$1) {
      return 'zlecenie sprzed skarbników';
    }
    // The release it follows names one by its id, or none.
    if (op.body['rel'] != null && op.body['rel'] is! String) {
      return 'zły przelew';
    }
    if (op.type != PyrT.transfer) {
      if (op.type != PyrT.settle) {
        return 'nie przelew';
      }
      return fits(op) ? null : 'zły przelew';
    }
    final String from = op.str('from');
    final String to = op.str('to');
    final int amount = op.integer('amount');
    if (from.isEmpty ||
        to.isEmpty ||
        from == to ||
        !op.signers.contains(from) ||
        !s.pqHolds(op, from) ||
        !s.memberAt(from, op.at) ||
        !s.memberAt(to, op.at) ||
        amount <= 0 ||
        amount > kPyrMaxAmount ||
        op.integer('seq') < 1 ||
        op.integer('seq') > kPyrMaxSeq ||
        !fits(op)) {
      return 'zły przelew';
    }
    final Object? cond = op.body['cond'];
    if (cond != null) {
      final Object? until = cond is Map ? cond['until'] : null;
      if (cond is! Map ||
          cond['by'] is! String ||
          !s.memberAt(cond['by'] as String, op.at) ||
          (until != null &&
              (until is! int ||
                  until <= op.at ||
                  until > op.at + kPyrMaxHoldMs))) {
        return 'zły warunek';
      }
    }
    return null;
  }

  /// Why settlement [op] of [e] breaks a rule of [problem] that holds
  /// whoever checks it, or null: settled by whom the payment waits for, or
  /// taken back by the payer after its time (both halves of the
  /// signature, the ML-DSA one by the key they were admitted with);
  /// accepted no later than an honest treasurer would sign (its time,
  /// give or take the clocks); passed on only to a member of its time.
  static String? _settleBreaks(PyramidRecord op, PyrEscrow e, PyramidState s) {
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
    if (ok && op.at > e.until + 2 * kPyrMaxSkewMs) {
      return 'za późno na przyjęcie';
    }
    final String next = op.str('next');
    if (next.isNotEmpty && !s.memberAt(next, op.at)) {
      return 'dalej tylko do członka';
    }
    return null;
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

  /// The operations dated from [from] (inclusive) to [to] (exclusive)
  /// that count in [v]: what the seal of that era lists.
  List<String> countedBetween(PyrLedgerView v, int from, int to) => <String>[
    for (final PyramidRecord op in ops.values)
      if (op.at >= from && op.at < to && v.counted.contains(op.id)) op.id,
  ]..sort();

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
  ///
  /// Every phone refuses what [breaks] a rule and an order over the day's
  /// limit of its time. A [whole] ledger (a treasurer's: every operation
  /// of every account) also refuses an order that is not the account's
  /// next number or not covered by the money there at its time — so a
  /// majority of treasurers, now or of any era, makes no money from
  /// nothing on the phones of the honest ones, whose statements the
  /// others go by. A phone that keeps only its own operations cannot
  /// know another account's money, and goes by those statements.
  ///
  /// With [assume], that operation counts as if most treasurers of its
  /// time had signed it: whether it would count then is what a treasurer
  /// asks before signing it ([problem]), by these same rules. Changes
  /// dated before [skipBefore] change no balance either; credits to
  /// [hold] from operations (not emissions) wait in [PyrLedgerView.held].
  PyrLedgerView compute(
    PyramidState s, {
    Set<String> skip = const <String>{},
    bool whole = false,
    PyramidRecord? assume,
    String? hold,
    int skipBefore = 0,
  }) {
    final PyrLedgerView v = PyrLedgerView(
      holdFor: hold,
      skipBefore: skipBefore,
    );
    final Map<String, PyramidRecord> ops = assume == null
        ? this.ops
        : <String, PyramidRecord>{...this.ops, assume.id: assume};
    for (final String slot in <String>{
      for (final PyramidRecord r in releases.values) r.str('slot'),
    }) {
      final String current = currentOf(slot, s);
      if (current.isNotEmpty) {
        v.releases[slot] = current;
      }
    }
    // Two operations for one span of a slot, both signed by one treasurer:
    // evidence, whether they counted or not — unless the earlier one's era
    // was sealed without it ([passed]): then signing the later one was
    // what an honest treasurer does to take the number again. Operations of
    // different spans are not two for one: the release between them freed
    // the number.
    final Map<String, List<PyramidRecord>> bySpan =
        <String, List<PyramidRecord>>{};
    for (final PyramidRecord op in ops.values) {
      (bySpan[spanOf(op)] ??= <PyramidRecord>[]).add(op);
    }
    for (final List<PyramidRecord> same in bySpan.values) {
      if (same.length < 2) {
        continue;
      }
      same.sort(
        (PyramidRecord a, PyramidRecord b) =>
            isLater(a, b) ? 1 : (isLater(b, a) ? -1 : 0),
      );
      for (int i = 0; i < same.length; i++) {
        final bool left = passed(same[i], s, strict: true);
        for (int j = i + 1; j < same.length; j++) {
          for (final String t in same[i].tsigs.keys) {
            if (same[j].tsigs.containsKey(t) && !left) {
              (v.cheaters[t] ??= <String>[]).addAll(<String>[
                same[i].id,
                same[j].id,
              ]);
            }
          }
        }
      }
    }
    // Two releases of one span, both voted for by one treasurer.
    final Map<String, List<PyramidRecord>> byPrev =
        <String, List<PyramidRecord>>{};
    for (final PyramidRecord r in releases.values) {
      (byPrev['${r.str('slot')}|${r.str('prev')}'] ??= <PyramidRecord>[]).add(
        r,
      );
    }
    for (final List<PyramidRecord> same in byPrev.values) {
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
            if (isFinal(op, s, signed: op.id == assume?.id) &&
                !v.leftBehind(op, s))
              op,
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
    // Emissions are credited in time with the operations: an order spends
    // only money there at its time. All the money there is never passes
    // [kPyrMaxBalance] (counted from the public emissions, the same on
    // every phone): no balance, and no sum of them, can wrap around.
    int supply = 0;
    final Set<String> within = <String>{};
    for (final PyrEmission e
        in s.emissions.values.toList()..sort((PyrEmission a, PyrEmission b) {
          final int c = a.effectiveAt.compareTo(b.effectiveAt);
          return c != 0 ? c : a.id.compareTo(b.id);
        })) {
      if (e.done &&
          !e.vetoed &&
          e.amount > 0 &&
          supply + e.amount <= kPyrMaxBalance) {
        supply += e.amount;
        within.add(e.id);
      }
    }
    final List<(PyrEmission, PyrEmitNote)> emitted =
        <(PyrEmission, PyrEmitNote)>[
          for (final PyrEmission e in s.emissions.values)
            if (notes[e.rc] case final PyrEmitNote n when within.contains(e.id))
              (e, n),
        ]..sort(((PyrEmission, PyrEmitNote) a, (PyrEmission, PyrEmitNote) b) {
          final int c = a.$1.effectiveAt.compareTo(b.$1.effectiveAt);
          return c != 0 ? c : a.$1.id.compareTo(b.$1.id);
        });
    int credited = 0;
    void creditUpTo(int at) {
      while (credited < emitted.length &&
          emitted[credited].$1.effectiveAt <= at) {
        final (PyrEmission e, PyrEmitNote n) = emitted[credited++];
        final String id = 'e:${e.id}';
        v
          .._add(n.to, e.amount, skip, id, e.effectiveAt)
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
    }

    for (final PyramidRecord op in finals) {
      creditUpTo(op.at);
      final String slot = slotOf(op);
      if (v.slots.containsKey(slot)) {
        // Only a dishonest majority gets a second one through: the first
        // stands.
        continue;
      }
      final String? why =
          breaks(op, s) ?? _covered(v, op, s, whole) ?? _inRange(v, op);
      if (why != null) {
        // Only a dishonest majority gets it this far: it takes no slot.
        v.broken[op.id] = why;
        continue;
      }
      if (op.type == PyrT.transfer) {
        _order(v, op, skip);
      } else {
        _settle(v, op, s, skip);
      }
    }
    creditUpTo(1 << 62);
    // Signed by a majority of an era's treasurers, but its seal does not
    // list it: made after the era ended.
    for (final PyramidRecord op in ops.values) {
      final PyrSeal? seal = s.sealAt(op.at);
      if (seal != null &&
          !seal.ops.contains(op.id) &&
          op.tsigs.keys.where(seal.set.contains).length >=
              seal.set.length ~/ 2 + 1) {
        v.broken[op.id] = 'poza pieczęcią swojej ery';
      }
    }
    v.entries.sort(
      (PyrLedgerEntry a, PyrLedgerEntry b) => a.at.compareTo(b.at),
    );
    return v;
  }

  /// Why order [op] is not covered where [compute] counts it, or null: the
  /// day's limit of its time (on every phone), and on a [whole] ledger the
  /// account's next number and the money there at its time.
  static String? _covered(
    PyrLedgerView v,
    PyramidRecord op,
    PyramidState s,
    bool whole,
  ) {
    if (op.type != PyrT.transfer) {
      return null;
    }
    final String from = op.str('from');
    if (v.ordersInDay(from, op.at) >= s.xferLimitAt(op.at)) {
      return 'limit przelewów na dzień';
    }
    if (!whole) {
      return null;
    }
    if (op.integer('seq') != v.seqOf(from) + 1) {
      return 'zły numer kolejny';
    }
    if (v.balanceOf(from) < op.integer('amount')) {
      return 'za mało środków';
    }
    return null;
  }

  /// Why order [op] would take a balance in [v] past ±[kPyrMaxBalance],
  /// or null. Only a dishonest majority gets that far (all the money there
  /// is stays below it): it counts nowhere rather than wrap a balance
  /// around.
  static String? _inRange(PyrLedgerView v, PyramidRecord op) {
    if (op.type != PyrT.transfer) {
      return null;
    }
    final int amount = op.integer('amount');
    return v._fits(op.str('from'), -amount) &&
            (op.body['cond'] != null || v._fits(op.str('to'), amount))
        ? null
        : 'saldo poza zakresem';
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
    v._add(from, -amount, skip, op.id, op.at);
    final Object? cond = op.body['cond'];
    if (cond is Map && cond['by'] is String) {
      // A payment waiting for [PyrLedgerView.holdFor]'s word waits for the
      // treasurers first, like money.
      if ((to == v.holdFor || cond['by'] == v.holdFor) &&
          from != v.holdFor &&
          !skip.contains(op.id) &&
          op.at >= v.skipBefore) {
        v.held.add(op.id);
      }
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
      .._add(to, amount, skip, op.id, op.at)
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
    final bool ok = op.body['ok'] == true;
    final int keep = ok ? (e.isChain ? min(e.share, e.amount) : e.amount) : 0;
    final String? why =
        _settleBreaks(op, e, s) ??
        (v._fits(e.from, e.amount - keep) && v._fits(e.to, keep)
            ? null
            : 'saldo poza zakresem');
    if (why != null) {
      v.broken[op.id] = why;
      return;
    }
    v
      ..slots[slotOf(op)] = op.id
      ..counted.add(op.id);
    e.settled = ok;
    if (!ok) {
      v
        .._add(e.from, e.amount, skip, op.id, op.at)
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
    v
      .._add(e.to, keep, skip, op.id, op.at)
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
        s.memberAt(next, op.at) &&
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
    v._add(e.from, rest, skip, op.id, op.at);
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

  /// Why a treasurer keeping this (whole) ledger may not sign [op] at
  /// [now], or null. It signs only what it would count: [compute], the
  /// rules every phone counts by, run with [op] as if most treasurers had
  /// signed it, must count [op] and still count everything it counts
  /// without it ([current], computed here when not given) — whatever time
  /// [op] carries, the money and the number at that time decide, as they
  /// do when it is counted. On top of that, what only the moment of
  /// signing can tell: fresh; within the treasurers' era it was made in;
  /// the parties members now; at most [PyrParams.xferLimit] orders of the
  /// payer this treasurer signed in the last day by its own clock
  /// ([signedToday]: an order dated back does not escape it); an
  /// acceptance only until its time, and a payer takes a conditional
  /// payment back only once this treasurer no longer signs an acceptance.
  String? problem(
    PyramidRecord op,
    PyramidState s,
    int now, {
    int signedToday = 0,
    PyrLedgerView? current,
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
    if (!fits(op)) {
      return 'za duża operacja';
    }
    final PyrLedgerView v = current ?? compute(s, whole: true);
    if (op.type == PyrT.transfer) {
      final Object? cond = op.body['cond'];
      if (!s.isMember(op.str('from')) || !s.isMember(op.str('to'))) {
        return 'zły przelew';
      }
      if (cond is Map &&
          cond['by'] is String &&
          !s.isMember(cond['by'] as String)) {
        return 'zły warunek';
      }
      if (v.slots.containsKey(slotOf(op))) {
        return 'zły numer kolejny';
      }
      if (signedToday >= s.params.xferLimit) {
        return 'limit przelewów na dzień';
      }
    } else if (op.type == PyrT.settle) {
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
      // The payer takes it back only once this treasurer no longer signs
      // an acceptance: the two never race for its signature.
      if (!byCond && now <= e.until + kPyrMaxSkewMs) {
        return 'za wcześnie na zwrot';
      }
      final String next = op.str('next');
      if (next.isNotEmpty && !s.isMember(next)) {
        return 'dalej tylko do członka';
      }
    } else {
      return 'nie przelew';
    }
    return wouldCount(op, s, v);
  }

  /// Why [op] would not count on this whole ledger once most treasurers
  /// signed it, or null: [compute] with it must count it and everything
  /// it counts in [v] (the ledger without it) — an operation dated before
  /// another that counts may not change what that one did.
  String? wouldCount(PyramidRecord op, PyramidState s, PyrLedgerView v) {
    final PyrLedgerView w = compute(s, whole: true, assume: op);
    if (!w.counted.contains(op.id)) {
      return w.broken[op.id] ??
          (op.type == PyrT.transfer
              ? 'zły numer kolejny'
              : 'nie ma czego rozliczyć');
    }
    if (!w.counted.containsAll(v.counted)) {
      return 'zmienia to, co już się liczy';
    }
    return null;
  }

  /// The reasons of [problem] a payer's wallet tells apart: no money, not
  /// the next number, over the day's limit; any other rule.
  static String refusalCode(String why) => switch (why) {
    'za mało środków' => 'funds',
    'zły numer kolejny' => 'seq',
    'limit przelewów na dzień' => 'limit',
    _ => 'rule',
  };

  Map<String, dynamic> toJson() => <String, dynamic>{
    'ops': <Map<String, dynamic>>[
      for (final PyramidRecord op in ops.values) op.toJson(),
    ],
    'notes': <Map<String, dynamic>>[
      for (final PyrEmitNote n in notes.values) n.toJson(),
    ],
    if (releases.isNotEmpty)
      'rel': <Map<String, dynamic>>[
        for (final PyramidRecord r in releases.values) r.toJson(),
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
    final Object? rel = json['rel'];
    if (rel is List) {
      for (final Object? o in rel) {
        final PyramidRecord? r = PyramidRecord.fromJson(o);
        if (r != null && isRelease(r)) {
          l.releases[r.id] = r;
        }
      }
    }
    return l;
  }
}

/// How many operations a statement lists by id at most: the newest. What
/// counted before them is in its balance, but not listed
/// ([PyrStatement.from]), so a statement does not grow with an account's
/// history.
const int kPyrStatementIds = 1000;

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
    this.from = 0,
  });

  final String pyramid;
  final String account;
  final int balance;
  final int seq;
  final int at;

  /// The operations it counted (and 'e:' + emission id) dated from [from]
  /// on: every one of them. Those dated before are in [balance] without
  /// being listed.
  final List<String> ids;
  final int from;

  /// Of [counted] (an account's operations that count, id → time), the
  /// newest [kPyrStatementIds] or fewer, and the time from which every one
  /// of them is listed (0: all are).
  static (List<String>, int) window(Map<String, int> counted) {
    if (counted.length <= kPyrStatementIds) {
      return (counted.keys.toList(), 0);
    }
    final List<int> times = counted.values.toList()
      ..sort((int a, int b) => b.compareTo(a));
    // Everything at or after [from] is listed: when the boundary time is
    // shared past the limit, it moves up past it.
    int from = times[kPyrStatementIds - 1];
    if (times.length > kPyrStatementIds && times[kPyrStatementIds] == from) {
      from++;
    }
    return (
      <String>[
        for (final MapEntry<String, int> e in counted.entries)
          if (e.value >= from) e.key,
      ],
      from,
    );
  }

  /// The treasurer, and their signature of [signedBytes].
  final String by;
  final String sig;

  /// What agreeing treasurers share.
  String get agreement =>
      '$balance|$seq|$from|${sha256Hex(utf8.encode((List<String>.of(ids)..sort()).join(',')))}';

  Map<String, dynamic> get body => <String, dynamic>{
    'py': pyramid,
    'a': account,
    'bal': balance,
    'seq': seq,
    'at': at,
    'ids': List<String>.of(ids)..sort(),
    if (from > 0) 'from': from,
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
    // A treasurer's whole ledger never holds more than all the money there
    // is, nor a number past the highest: anything else would only wrap a
    // sum around.
    final int bal = json['bal'] as int;
    final int seq = json['seq'] as int;
    final Object? from = json['from'] ?? 0;
    if (bal < 0 ||
        bal > kPyrMaxBalance ||
        seq < 0 ||
        seq > kPyrMaxSeq ||
        from is! int ||
        from < 0 ||
        (json['ids'] as List).length > kPyrStatementIds) {
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
      from: from,
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
