import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// The fold refuses what the security review found it accepted (§20–24):
/// broken rings, a second spelling of one vote, a constitution by two
/// people, emission limits dodged, delegations stretched, records dated
/// back to rewrite history, money moving without treasurers.
const int t0 = 1700000000000;
const int h = 3600 * 1000;
const int day = 24 * h;

Future<PyramidRecord> rec(
  String type,
  String py,
  int at,
  List<LedgerKeyPair> signers,
  Map<String, dynamic> fields,
) async {
  PyramidRecord r = PyramidRecord(
    body: <String, dynamic>{
      't': type,
      'py': py,
      'at': at,
      'by': <String>[for (final LedgerKeyPair k in signers) k.id],
      ...fields,
    },
  );
  for (final LedgerKeyPair k in signers) {
    r = await r.signedBy(k);
  }
  return r;
}

Map<String, dynamic> member(
  LedgerKeyPair k,
  String name, {
  String nat = 'PL',
}) => <String, dynamic>{
  'k': k.id,
  'n': name,
  'nat': nat,
  'yr': 1990,
  'dc': 'x',
};

/// Each member met in person by the two after them (§6.2), so all six may
/// vote in referenda (§20.6).
Future<List<PyramidRecord>> metRecords(
  String py,
  List<LedgerKeyPair> k,
  int at,
) async => <PyramidRecord>[
  for (int i = 0; i < k.length; i++)
    for (int j = 1; j <= 2; j++)
      await rec(
        PyrT.met,
        py,
        at + i * 2 + j,
        <LedgerKeyPair>[k[(i + j) % k.length]],
        <String, dynamic>{'k': k[i].id},
      ),
];

/// S on top, A and B under S, A1 and A2 under A, B1 under B.
final class Six {
  Six._(this.s, this.a, this.b, this.a1, this.a2, this.b1, this.records);

  final LedgerKeyPair s;
  final LedgerKeyPair a;
  final LedgerKeyPair b;
  final LedgerKeyPair a1;
  final LedgerKeyPair a2;
  final LedgerKeyPair b1;
  final List<PyramidRecord> records;

  String get py => records.first.id;

  List<LedgerKeyPair> get all => <LedgerKeyPair>[s, a, b, a1, a2, b1];

  static Future<Six> make() async {
    final List<LedgerKeyPair> k = <LedgerKeyPair>[
      for (int i = 0; i < 6; i++) await LedgerKeyPair.generate(),
    ];
    final PyramidRecord g = await rec(
      PyrT.genesis,
      '',
      t0,
      <LedgerKeyPair>[k[0]],
      <String, dynamic>{'name': 'Test', 'founder': member(k[0], 'S')},
    );
    final String py = g.id;
    return Six._(k[0], k[1], k[2], k[3], k[4], k[5], <PyramidRecord>[
      g,
      await rec(
        PyrT.admit,
        py,
        t0 + 1,
        <LedgerKeyPair>[k[0], k[1]],
        <String, dynamic>{'head': k[0].id, 'm': member(k[1], 'A')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 2,
        <LedgerKeyPair>[k[0], k[2]],
        <String, dynamic>{'head': k[0].id, 'm': member(k[2], 'B')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 3,
        <LedgerKeyPair>[k[1], k[3]],
        <String, dynamic>{'head': k[1].id, 'm': member(k[3], 'A1')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 4,
        <LedgerKeyPair>[k[1], k[4]],
        <String, dynamic>{'head': k[1].id, 'm': member(k[4], 'A2')},
      ),
      await rec(
        PyrT.admit,
        py,
        t0 + 5,
        <LedgerKeyPair>[k[2], k[5]],
        <String, dynamic>{'head': k[2].id, 'm': member(k[5], 'B1')},
      ),
      ...await metRecords(py, k, t0 + 10),
    ]);
  }

  /// Every treasurer (all six are) signed each of [rs].
  Map<String, Set<String>> treasurersSigned(Iterable<PyramidRecord> rs) =>
      <String, Set<String>>{
        for (final PyramidRecord r in rs)
          r.id: <String>{for (final LedgerKeyPair k in all) k.id},
      };

  PyramidState fold(
    Iterable<PyramidRecord> more, {
    int now = t0 + 400 * day,
    Map<String, Set<String>> tsigs = const <String, Set<String>>{},
  }) => PyramidState.fold(
    py,
    <PyramidRecord>[...records, ...more],
    now: now,
    treasurerSigs: tsigs,
  );

  Future<PyramidRecord> emit(
    int at,
    LedgerKeyPair to,
    int amount, {
    List<LedgerKeyPair>? by,
  }) => rec(PyrT.emit, py, at, by ?? <LedgerKeyPair>[s, a], <String, dynamic>{
    'to': to.id,
    'amount': amount,
    'why': 'x',
  });

  Future<PyramidRecord> pay(
    int at,
    LedgerKeyPair from,
    LedgerKeyPair to,
    int amount,
    int seq, {
    Map<String, dynamic>? cond,
  }) => rec(
    PyrT.transfer,
    py,
    at,
    <LedgerKeyPair>[from],
    <String, dynamic>{
      'from': from.id,
      'to': to.id,
      'amount': amount,
      'seq': seq,
      'memo': '',
      'cond': ?cond,
    },
  );

  Future<PyramidRecord> settle(
    int at,
    LedgerKeyPair by,
    String escrow,
    bool ok, {
    String? next,
  }) => rec(
    PyrT.settle,
    py,
    at,
    <LedgerKeyPair>[by],
    <String, dynamic>{'x': escrow, 'ok': ok, 'next': ?next},
  );
}

const Map<String, String> allScope = <String, String>{
  'k': 'all',
  'p': '',
  'nat': '',
};

void main() {
  late Six w;

  setUp(() async {
    w = await Six.make();
  });

  group('anonymous records (C1, H1)', () {
    Future<(Map<String, dynamic>, RingSignature)> request(
      LedgerKeyPair signer,
      int at,
    ) async {
      final List<String> ring = <String>[w.a.id, w.a1.id, w.a2.id]..sort();
      final Map<String, dynamic> body = <String, dynamic>{
        't': PyrT.voteRequest,
        'py': w.py,
        'at': at,
        'by': const <String>[],
        'cell': '0',
        'head': w.a.id,
        'ring': ring,
        'n': 'n1',
      };
      final RingSignature sig = RingSignature.sign(
        seed: signer.seed,
        ring: ring.map((String k) => unb64(k, length: 32)!).toList(),
        context: PyramidState.voteRequestContext(w.py, '0', w.a.id),
        message: PyramidRecord(body: body).signedBytes,
      );
      return (body, sig);
    }

    test(
      'a ring with a key image that is not base64 is skipped, the pyramid stays',
      () async {
        final (Map<String, dynamic> body, RingSignature good) = await request(
          w.a1,
          t0 + day,
        );
        final PyramidRecord junk = PyramidRecord(
          body: body,
          ring: RingSignature(
            c0: good.c0,
            s: good.s,
            keyImage: '%%% not base64 %%%',
          ),
        );
        // This threw a FormatException out of the fold on every phone.
        final PyramidState st = w.fold(<PyramidRecord>[junk]);
        expect(st.members, hasLength(6));
        expect(st.rejected[junk.id], isNotNull);
        expect(st.elections, isEmpty);
        // The genuine one counts.
        expect(
          w.fold(<PyramidRecord>[
            PyramidRecord(body: body, ring: good),
          ]).elections,
          hasLength(1),
        );
        // And a malformed one does not even parse.
        expect(
          PyramidRecord.fromJson(<String, dynamic>{
            'b': body,
            'r': <String, dynamic>{
              'c': '1',
              's': <String>['1', '1', '1'],
              'i': '!!!',
            },
          }),
          isNull,
        );
      },
    );

    test(
      'one person cannot vote twice under another spelling of the key image',
      () async {
        final (Map<String, dynamic> reqBody, RingSignature reqSig) =
            await request(w.a1, t0 + day);
        final PyramidRecord req = PyramidRecord(body: reqBody, ring: reqSig);
        final List<String> ring = reqBody['ring'] as List<String>;
        Future<PyramidRecord> vote(String n, int at) async {
          final Map<String, dynamic> body = <String, dynamic>{
            't': PyrT.vote,
            'py': w.py,
            'at': at,
            'by': const <String>[],
            'elect': req.id,
            'choice': w.a1.id,
            'n': n,
          };
          return PyramidRecord(
            body: body,
            ring: RingSignature.sign(
              seed: w.a1.seed,
              ring: ring.map((String k) => unb64(k, length: 32)!).toList(),
              context: PyramidState.voteContext(req.id),
              message: PyramidRecord(body: body).signedBytes,
            ),
          );
        }

        final PyramidRecord first = await vote('v1', t0 + day + 1000);
        final PyramidRecord again = await vote('v2', t0 + day + 2000);
        final String image = again.ring!.keyImage;
        final String alias = image.contains('-') || image.contains('_')
            ? image.replaceAll('-', '+').replaceAll('_', '/')
            : image.replaceAll('=', '');
        final PyramidRecord aliased = PyramidRecord(
          body: again.body,
          ring: RingSignature(
            c0: again.ring!.c0,
            s: again.ring!.s,
            keyImage: alias,
          ),
        );
        final PyramidState st = w.fold(<PyramidRecord>[
          req,
          first,
          aliased,
        ], now: t0 + day + 3000);
        expect(st.elections[req.id]!.votes, hasLength(1));
        expect(st.rejected[aliased.id], isNotNull);
        // The same image in its own spelling is a repeat, refused as before.
        final PyramidState st2 = w.fold(<PyramidRecord>[
          req,
          first,
          again,
        ], now: t0 + day + 3000);
        expect(st2.elections[req.id]!.votes, hasLength(1));
        expect(st2.rejected[again.id], 'już głosował(a)');
      },
    );
  });

  group('constitution (H2)', () {
    Future<PyramidRecord> constitutionRef(int at, int end) => rec(
      PyrT.referendum,
      w.py,
      at,
      <LedgerKeyPair>[w.s, w.a],
      <String, dynamic>{
        'q': 'Nowe zasady?',
        'opts': <String>['Tak', 'Nie'],
        'end': end,
        'scope': allScope,
        'kind': 'constitution',
        'params': <String, dynamic>{'version': 2, 'emitLimit': 5},
      },
    );

    Future<PyramidRecord> tally(
      LedgerKeyPair by,
      int at,
      String ref,
      List<int> counts, {
      List<String> kids = const <String>[],
      bool extra = false,
    }) => rec(
      PyrT.tally,
      w.py,
      at,
      <LedgerKeyPair>[by],
      <String, dynamic>{
        'ref': ref,
        'counts': counts,
        'kids': kids,
        'extra': extra,
      },
    );

    Future<PyramidRecord> apply(int at, String ref) => rec(
      PyrT.constitution,
      w.py,
      at,
      <LedgerKeyPair>[w.s, w.a],
      <String, dynamic>{'ref': ref},
    );

    test('a constitutional vote shorter than 72 h is refused', () async {
      const int at = t0 + day;
      final PyramidRecord short = await constitutionRef(at, at + 71 * h);
      final PyramidRecord ok = await constitutionRef(at, at + 72 * h);
      final PyramidState st = w.fold(<PyramidRecord>[short, ok]);
      expect(st.referenda.keys, <String>[ok.id]);
      expect(st.rejected[short.id], contains('za krótkie'));
    });

    test('two of the top cannot pass new rules alone', () async {
      const int at = t0 + day;
      const int end = at + 72 * h;
      final PyramidRecord ref = await constitutionRef(at, end);
      // Right after the end the top claims its own count, the branches
      // left out: refused while their sums may still come.
      final PyramidRecord early = await tally(w.s, end + 60000, ref.id, <int>[
        2,
        0,
      ]);
      // A sum before the end: refused.
      final PyramidRecord beforeEnd = await tally(
        w.a,
        end - 60000,
        ref.id,
        <int>[3, 0],
        extra: true,
      );
      // More than its own people can give: refused.
      final PyramidRecord inflated = await tally(
        w.s,
        end + 7 * h,
        ref.id,
        <int>[3, 0],
      );
      // Numbers that would wrap around: refused.
      final PyramidRecord huge = await tally(
        w.s,
        end + 7 * h + 1,
        ref.id,
        <int>[1 << 62, 1 << 62],
      );
      // Only the top's own two votes, after the wait: counted, but far from
      // a quorum — the rules stay.
      final PyramidRecord alone = await tally(
        w.s,
        end + 7 * h + 2,
        ref.id,
        <int>[2, 0],
      );
      final PyramidRecord change = await apply(end + 8 * h, ref.id);
      final PyramidState st = w.fold(<PyramidRecord>[
        ref,
        early,
        beforeEnd,
        inflated,
        huge,
        alone,
        change,
      ]);
      expect(st.rejected[early.id], 'czeka na sumę gałęzi niżej');
      expect(st.rejected[beforeEnd.id], 'suma poza czasem liczenia');
      expect(st.rejected[inflated.id], 'zawyżona suma');
      expect(st.rejected[huge.id], 'zła suma');
      expect(st.resultOf(ref.id), <int>[2, 0]);
      expect(st.constitutionPasses(ref.id), isFalse);
      expect(st.rejected[change.id], 'referendum nie przeszło');
      expect(st.params.version, 1);
      expect(st.params.emitLimit, PyrParams().emitLimit);
    });

    test(
      'a full count passes, but not before the sums had time; the top must include every branch',
      () async {
        const int at = t0 + day;
        const int end = at + 72 * h;
        final PyramidRecord ref = await constitutionRef(at, end);
        // A: A1, A2 and S's own vote (passed to the first child).
        final PyramidRecord tA = await tally(w.a, end + 60000, ref.id, <int>[
          3,
          0,
        ], extra: true);
        final PyramidRecord tB = await tally(w.b, end + 60000, ref.id, <int>[
          1,
          0,
        ]);
        // The top leaving B's branch out once B's sum exists: refused.
        final PyramidRecord partial = await tally(
          w.s,
          end + 120000,
          ref.id,
          <int>[5, 0],
          kids: <String>[tA.id],
        );
        final PyramidRecord twice = await tally(
          w.s,
          end + 120001,
          ref.id,
          <int>[8, 0],
          kids: <String>[tA.id, tA.id],
        );
        final PyramidRecord full = await tally(
          w.s,
          end + 180000,
          ref.id,
          <int>[6, 0],
          kids: <String>[tA.id, tB.id],
        );
        final PyramidRecord tooEarly = await apply(end + h, ref.id);
        final PyramidRecord change = await apply(
          end + kPyrTallyGraceMs + 60000,
          ref.id,
        );
        final PyramidState st = w.fold(<PyramidRecord>[
          ref,
          tA,
          tB,
          partial,
          twice,
          full,
          tooEarly,
          change,
        ]);
        expect(st.rejected[partial.id], 'brak najnowszej sumy gałęzi niżej');
        expect(st.rejected[twice.id], 'powtórzona suma gałęzi');
        expect(st.resultOf(ref.id, strict: true), <int>[6, 0]);
        expect(st.rejected[tooEarly.id], contains('za wcześnie'));
        expect(st.applied, contains(change.id));
        expect(st.params.version, 2);
        expect(st.params.emitLimit, 5);
      },
    );
  });

  group('emission (H3)', () {
    test(
      'a new head does not bring a fresh limit: it is per 30 days',
      () async {
        const int at = t0 + day;
        final PyramidRecord e1 = await w.emit(at, w.a1, PyrParams().emitLimit);
        // A and B put A at the head: a new term.
        final PyramidRecord swap = await rec(
          PyrT.swap,
          w.py,
          at + h,
          <LedgerKeyPair>[w.a, w.b],
          <String, dynamic>{'cell': '', 'head': w.s.id, 'up': w.a.id},
        );
        final PyramidRecord e2 = await w.emit(
          at + 2 * h,
          w.a1,
          1,
          by: <LedgerKeyPair>[w.a, w.b],
        );
        final PyramidRecord e3 = await w.emit(
          at + 31 * day,
          w.a1,
          1,
          by: <LedgerKeyPair>[w.a, w.b],
        );
        final PyramidState st = w.fold(<PyramidRecord>[e1, swap, e2, e3]);
        expect(st.term, 2);
        expect(st.rejected[e2.id], contains('limit'));
        expect(st.applied, contains(e3.id));
      },
    );

    test(
      'a veto counts once; the signers cannot veto; a vetoer moved away keeps the right',
      () async {
        const int at = t0 + day;
        final PyramidRecord e = await w.emit(at, w.a1, 5000);
        final PyramidRecord bySigner = await rec(
          PyrT.veto,
          w.py,
          at + 1000,
          <LedgerKeyPair>[w.s],
          <String, dynamic>{'emit': e.id},
        );
        // S and A remove B from the top (B's own cell), then B vetoes.
        final PyramidRecord removeB = await rec(
          PyrT.remove,
          w.py,
          at + h,
          <LedgerKeyPair>[w.s, w.a],
          <String, dynamic>{'k': w.b.id},
        );
        final PyramidRecord v1 = await rec(
          PyrT.veto,
          w.py,
          at + 2 * h,
          <LedgerKeyPair>[w.b],
          <String, dynamic>{'emit': e.id},
        );
        final PyramidRecord v2 = await rec(
          PyrT.veto,
          w.py,
          at + 3 * h,
          <LedgerKeyPair>[w.b],
          <String, dynamic>{'emit': e.id},
        );
        final PyramidState st = w.fold(<PyramidRecord>[
          e,
          bySigner,
          removeB,
          v1,
          v2,
        ]);
        expect(st.emissions[e.id]!.vetoers, <String>[w.b.id]);
        expect(st.rejected[bySigner.id], 'weto: trzeci członek szczytu');
        expect(st.isMember(w.b.id), isFalse);
        expect(st.emissions[e.id]!.vetoed, isTrue);
        expect(st.rejected[v2.id], 'nie ma czego zawetować');
        expect(st.emittedInTerm[1], 0, reason: 'lowered once, not twice');
        expect(st.balanceOf(w.a1.id), 0);
      },
    );

    test('a veto must be dated inside the wait', () async {
      const int at = t0 + day;
      final PyramidRecord e = await w.emit(at, w.a1, 5000);
      final PyramidRecord before = await rec(
        PyrT.veto,
        w.py,
        at - 1000,
        <LedgerKeyPair>[w.b],
        <String, dynamic>{'emit': e.id},
      );
      final PyramidRecord late = await rec(
        PyrT.veto,
        w.py,
        at + 25 * h,
        <LedgerKeyPair>[w.b],
        <String, dynamic>{'emit': e.id},
      );
      final PyramidState st = w.fold(<PyramidRecord>[e, before, late]);
      expect(st.emissions[e.id]!.vetoed, isFalse);
      expect(st.balanceOf(w.a1.id), 5000);
    });

    test('a fresh copy of the same proposal counts once', () async {
      const int at = t0 + day;
      final Map<String, dynamic> fields = <String, dynamic>{
        'to': w.a1.id,
        'amount': 700,
        'why': 'x',
        'pn': 'propozycja-1',
      };
      final PyramidRecord first = await rec(
        PyrT.emit,
        w.py,
        at,
        <LedgerKeyPair>[w.s, w.a],
        fields,
      );
      final PyramidRecord copy = await rec(
        PyrT.emit,
        w.py,
        at + 20 * 60000,
        <LedgerKeyPair>[w.s, w.a],
        fields,
      );
      final PyramidRecord other = await rec(
        PyrT.emit,
        w.py,
        at + 30 * 60000,
        <LedgerKeyPair>[w.s, w.a],
        <String, dynamic>{...fields, 'pn': 'propozycja-2'},
      );
      final PyramidState st = w.fold(<PyramidRecord>[first, copy, other]);
      expect(st.rejected[copy.id], contains('już weszła'));
      expect(st.balanceOf(w.a1.id), 1400);
    });
  });

  group('money (T7, T3, ad chains)', () {
    test(
      'an order most treasurers signed uses its number even when the money went away',
      () async {
        const int at = t0 + day;
        final PyramidRecord e1 = await w.emit(at, w.a1, 1000);
        final PyramidRecord e2 = await w.emit(at + 60000, w.a1, 500);
        final PyramidRecord x1 = await w.pay(at + 25 * h, w.a1, w.b1, 1200, 1);
        // A veto of e2, inside its wait: x1 is no longer covered.
        final PyramidRecord v = await rec(
          PyrT.veto,
          w.py,
          at + h,
          <LedgerKeyPair>[w.b],
          <String, dynamic>{'emit': e2.id},
        );
        final PyramidRecord x2 = await w.pay(at + 26 * h, w.a1, w.b1, 300, 2);
        final PyramidState st = w.fold(<PyramidRecord>[
          e1,
          e2,
          x1,
          v,
          x2,
        ], tsigs: w.treasurersSigned(<PyramidRecord>[x1, x2]));
        expect(st.rejected[x1.id], 'za mało środków');
        expect(
          st.accounts[w.a1.id]!.seq,
          2,
          reason: 'the account is not stuck at number 1',
        );
        expect(st.applied, contains(x2.id));
        expect(st.balanceOf(w.a1.id), 700);
        expect(st.balanceOf(w.b1.id), 300);
      },
    );

    test(
      'a settlement counts only with most treasurers; a refund only after the time',
      () async {
        const int at = t0 + day;
        final PyramidRecord e = await w.emit(at, w.a1, 2000);
        final PyramidRecord x = await w.pay(
          at + 25 * h,
          w.a1,
          w.b1,
          1000,
          1,
          cond: <String, dynamic>{'by': w.b1.id, 'until': at + 30 * h},
        );
        // B1 accepts late, dated before the payer's refund, with no treasurer
        // signatures (honest treasurers signed the refund already).
        final PyramidRecord lateOk = await w.settle(
          at + 28 * h,
          w.b1,
          x.id,
          true,
        );
        final PyramidRecord earlyRefund = await w.settle(
          at + 29 * h,
          w.a1,
          x.id,
          false,
        );
        final PyramidRecord refund = await w.settle(
          at + 31 * h,
          w.a1,
          x.id,
          false,
        );
        final PyramidState st = w.fold(<PyramidRecord>[
          e,
          x,
          lateOk,
          earlyRefund,
          refund,
        ], tsigs: w.treasurersSigned(<PyramidRecord>[x, earlyRefund, refund]));
        expect(st.rejected[lateOk.id], contains('skarbników'));
        expect(st.rejected[earlyRefund.id], contains('po terminie'));
        expect(st.escrows[x.id]!.settled, isFalse);
        expect(st.balanceOf(w.a1.id), 2000);
        expect(st.balanceOf(w.b1.id), 0);
      },
    );

    test(
      'an announcement never goes back to someone already on its way',
      () async {
        const int at = t0 + day;
        final PyramidRecord e = await w.emit(at, w.a1, 1000);
        final PyramidRecord x = await w.pay(
          at + 25 * h,
          w.a1,
          w.a,
          300,
          1,
          cond: <String, dynamic>{
            'by': w.a.id,
            'until': at + 30 * day,
            'share': 100,
            'hops': 2,
            'h': 'tekst',
          },
        );
        final PyramidRecord s1 = await w.settle(
          at + 26 * h,
          w.a,
          x.id,
          true,
          next: w.s.id,
        );
        // S passes it back to A, who would keep a second share.
        final PyramidRecord s2 = await w.settle(
          at + 27 * h,
          w.s,
          s1.id,
          true,
          next: w.a.id,
        );
        final PyramidState st = w.fold(<PyramidRecord>[
          e,
          x,
          s1,
          s2,
        ], tsigs: w.treasurersSigned(<PyramidRecord>[x, s1, s2]));
        expect(st.escrows[s2.id], isNull);
        expect(st.balanceOf(w.a.id), 100);
        expect(st.balanceOf(w.s.id), 100);
        expect(st.balanceOf(w.a1.id), 800);
      },
    );
  });

  group('delegations (M2, M3, T4)', () {
    Future<PyramidRecord> delegate(
      int at,
      LedgerKeyPair to,
      String power, {
      String scope = '',
      Object limit = 0,
      String? parent,
      bool sub = false,
      List<LedgerKeyPair>? by,
    }) => rec(
      PyrT.delegate,
      w.py,
      at,
      by ?? <LedgerKeyPair>[w.s, w.a],
      <String, dynamic>{
        'to': to.id,
        'power': power,
        'scope': scope,
        'limit': limit,
        // One end for all, so a passed-on delegation is never "longer".
        'until': t0 + 31 * day,
        'sub': sub,
        'parent': ?parent,
      },
    );

    Future<PyramidRecord> contentBan(
      int at,
      LedgerKeyPair by,
      String via,
      String eid,
    ) => rec(
      PyrT.ban,
      w.py,
      at,
      <LedgerKeyPair>[by],
      <String, dynamic>{
        'target': '',
        'kind': 'content',
        'eid': eid,
        'reason': '',
        'via': via,
      },
    );

    test('limits are real counts and hold along the whole chain', () async {
      const int at = t0 + day;
      final PyramidRecord negative = await delegate(
        at,
        w.b,
        'content',
        limit: -1,
      );
      final PyramidRecord text = await delegate(at, w.b, 'content', limit: '5');
      final PyramidRecord d1 = await delegate(
        at + 1,
        w.b,
        'content',
        limit: 1,
        sub: true,
      );
      final PyramidRecord unlimitedSub = await delegate(
        at + 2,
        w.b1,
        'content',
        parent: d1.id,
        by: <LedgerKeyPair>[w.b],
      );
      final PyramidRecord d2 = await delegate(
        at + 3,
        w.b1,
        'content',
        limit: 1,
        parent: d1.id,
        by: <LedgerKeyPair>[w.b],
      );
      final PyramidRecord ban1 = await contentBan(at + h, w.b1, d2.id, 'h1');
      // B's own use would be the second under d1's limit of 1.
      final PyramidRecord ban2 = await contentBan(at + 2 * h, w.b, d1.id, 'h2');
      final PyramidState st = w.fold(<PyramidRecord>[
        negative,
        text,
        d1,
        unlimitedSub,
        d2,
        ban1,
        ban2,
      ]);
      expect(st.delegations.keys.toSet(), <String>{d1.id, d2.id});
      expect(st.rejected[unlimitedSub.id], 'szerzej niż własna delegacja');
      expect(st.bannedEntries(at + 3 * h), <String>{'h1'});
      expect(st.rejected[ban2.id], isNotNull);
    });

    test('a delegate who left the pyramid can no longer use it', () async {
      const int at = t0 + day;
      final PyramidRecord d = await delegate(at, w.b1, 'content');
      final PyramidRecord leave = await rec(
        PyrT.leave,
        w.py,
        at + h,
        <LedgerKeyPair>[w.b1],
        <String, dynamic>{'k': w.b1.id},
      );
      final PyramidRecord ban = await contentBan(at + 2 * h, w.b1, d.id, 'h1');
      final PyramidState st = w.fold(<PyramidRecord>[d, leave, ban]);
      expect(st.rejected[ban.id], isNotNull);
      expect(st.bannedEntries(at + 3 * h), isEmpty);
    });

    test('a branch delegate reaches only its branch', () async {
      const int at = t0 + day;
      final PyramidRecord d = await delegate(at, w.b, 'alarm', scope: '1');
      Future<PyramidRecord> alarm(int dt, Map<String, String> scope) => rec(
        PyrT.alarm,
        w.py,
        at + dt,
        <LedgerKeyPair>[w.b],
        <String, dynamic>{
          'text': 'Uwaga',
          'scope': scope,
          'until': at + day,
          'via': d.id,
        },
      );
      final PyramidRecord all = await alarm(1000, allScope);
      final PyramidRecord nat = await alarm(2000, const <String, String>{
        'k': 'nat',
        'p': '',
        'nat': 'PL',
      });
      final PyramidRecord other = await alarm(3000, const <String, String>{
        'k': 'branch',
        'p': '0',
        'nat': '',
      });
      final PyramidRecord own = await alarm(4000, const <String, String>{
        'k': 'branch',
        'p': '1',
        'nat': '',
      });
      final PyramidState st = w.fold(<PyramidRecord>[d, all, nat, other, own]);
      expect(st.alarms.map((PyrAlarm a) => a.id), <String>[own.id]);
    });

    test(
      'a revocation invalidates everything that resulted from the delegation, '
      'earlier acts too (§21.2)',
      () async {
        const int at = t0 + day;
        final PyramidRecord d = await delegate(at, w.b, 'content');
        final PyramidRecord ban1 = await contentBan(at + h, w.b, d.id, 'h1');
        final PyramidRecord ban2 = await contentBan(
          at + 90 * 60000,
          w.b,
          d.id,
          'h2',
        );
        final PyramidRecord revoke = await rec(
          PyrT.revoke,
          w.py,
          at + 2 * h,
          <LedgerKeyPair>[w.s, w.a],
          <String, dynamic>{'d': d.id},
        );
        final PyramidRecord after = await contentBan(
          at + 3 * h,
          w.b,
          d.id,
          'h3',
        );
        // Before the revocation both bans count.
        final PyramidState before = w.fold(<PyramidRecord>[d, ban1, ban2]);
        expect(before.bannedEntries(at + 4 * h), <String>{'h1', 'h2'});
        expect(before.actsOf(d.id), <String>{ban1.id, ban2.id});
        final PyramidState st = w.fold(<PyramidRecord>[
          d,
          ban1,
          ban2,
          revoke,
          after,
        ]);
        expect(st.applied, contains(revoke.id));
        expect(st.bannedEntries(at + 4 * h), isEmpty);
        expect(st.rejected[ban1.id], contains('cofniętej delegacji'));
        expect(st.rejected[ban2.id], contains('cofniętej delegacji'));
        expect(st.rejected[after.id], isNotNull);
        expect(st.actsOf(d.id), isEmpty);
      },
    );
  });

  group('history and identities (T5, M4, LOW)', () {
    test(
      'a top already replaced cannot close the pyramid by dating the closing back',
      () async {
        const int at = t0 + day;
        // A1 and A2 put A1 at the head of A's cell: A leaves the top.
        final PyramidRecord swap = await rec(
          PyrT.swap,
          w.py,
          at + h,
          <LedgerKeyPair>[w.a1, w.a2],
          <String, dynamic>{'cell': '0', 'head': w.a.id, 'up': w.a1.id},
        );
        final PyramidRecord post = await rec(
          PyrT.post,
          w.py,
          at + 2 * h,
          <LedgerKeyPair>[w.b],
          <String, dynamic>{'text': 'dalej', 'lvl': 1},
        );
        final PyramidRecord backdated = await rec(
          PyrT.merged,
          w.py,
          at,
          <LedgerKeyPair>[w.s, w.a],
          <String, dynamic>{'into': 'inna'},
        );
        PyramidState st = w.fold(<PyramidRecord>[swap, post, backdated]);
        expect(st.mergedInto, isNull);
        expect(st.rejected[backdated.id], 'zamknąć może tylko obecny szczyt');
        expect(st.applied, containsAll(<String>[swap.id, post.id]));
        // The top of today can close it.
        final PyramidRecord closing = await rec(
          PyrT.merged,
          w.py,
          at + 3 * h,
          <LedgerKeyPair>[w.s, w.b],
          <String, dynamic>{'into': 'inna'},
        );
        st = w.fold(<PyramidRecord>[swap, post, backdated, closing]);
        expect(st.mergedInto, 'inna');
      },
    );

    test(
      'a merge snapshot is checked: one entry per person, real keys, no banned',
      () async {
        const int at = t0 + day;
        final LedgerKeyPair t = await LedgerKeyPair.generate();
        final LedgerKeyPair t1 = await LedgerKeyPair.generate();
        final LedgerKeyPair t2 = await LedgerKeyPair.generate();
        Map<String, dynamic> entry(String p, String k) => <String, dynamic>{
          'p': p,
          'k': k,
          'n': 'X',
          'nat': 'PL',
          'yr': 1990,
          'dc': '',
          'addr': '',
        };
        Future<PyramidRecord> merge(int dt, List<Map<String, dynamic>> snap) =>
            rec(
              PyrT.merge,
              w.py,
              at + dt,
              <LedgerKeyPair>[w.a1, t, t1],
              <String, dynamic>{'from': 'mala', 'under': w.a1.id, 'snap': snap},
            );
        final PyramidRecord twice = await merge(1, <Map<String, dynamic>>[
          entry('', t.id),
          entry('0', t1.id),
          entry('1', t.id),
        ]);
        final PyramidRecord alias = await merge(2, <Map<String, dynamic>>[
          entry('', t.id),
          entry('0', t1.id.replaceAll('=', '')),
        ]);
        final PyramidRecord badPath = await merge(3, <Map<String, dynamic>>[
          entry('', t.id),
          entry('x', t1.id),
        ]);
        final PyramidRecord ban = await rec(
          PyrT.ban,
          w.py,
          at + 10,
          <LedgerKeyPair>[w.s, w.a],
          <String, dynamic>{'target': t2.id, 'kind': 'perm', 'reason': ''},
        );
        final PyramidRecord banned = await merge(20, <Map<String, dynamic>>[
          entry('', t.id),
          entry('0', t1.id),
          entry('1', t2.id),
        ]);
        final PyramidRecord good = await merge(30, <Map<String, dynamic>>[
          entry('', t.id),
          entry('0', t1.id),
        ]);
        final PyramidState st = w.fold(<PyramidRecord>[
          twice,
          alias,
          badPath,
          ban,
          banned,
          good,
        ]);
        expect(st.rejected[twice.id], 'powtórzony wpis połączenia');
        expect(st.rejected[alias.id], 'zły wpis połączenia');
        expect(st.rejected[badPath.id], 'zły wpis połączenia');
        expect(st.rejected[banned.id], 'ban stały');
        expect(st.applied, contains(good.id));
        expect(st.pathOf(t.id), '000');
        expect(st.isMember(t2.id), isFalse);
      },
    );

    test(
      'a banned person cannot come back under another spelling of the key',
      () async {
        const int at = t0 + day;
        final LedgerKeyPair x = await LedgerKeyPair.generate();
        final PyramidRecord ban = await rec(
          PyrT.ban,
          w.py,
          at,
          <LedgerKeyPair>[w.s, w.a],
          <String, dynamic>{'target': x.id, 'kind': 'perm', 'reason': ''},
        );
        final String alias = x.id.replaceAll('=', '');
        // Signatures are not the fold's business: the alias is refused anyway.
        final PyramidRecord admit = PyramidRecord(
          body: <String, dynamic>{
            't': PyrT.admit,
            'py': w.py,
            'at': at + h,
            'by': <String>[w.a1.id, alias],
            'head': w.a1.id,
            'm': <String, dynamic>{
              'k': alias,
              'n': 'X',
              'nat': 'PL',
              'yr': 1990,
              'dc': 'x',
            },
          },
          sigs: <String, String>{w.a1.id: 'sig', alias: 'sig'},
        );
        final PyramidState st = w.fold(<PyramidRecord>[ban, admit]);
        expect(st.rejected[admit.id], isNotNull);
        expect(st.isMember(alias), isFalse);
        // And such a signature never verifies on arrival.
        expect(PyramidRecord.isCanonicalKey(x.id), isTrue);
        expect(PyramidRecord.isCanonicalKey(alias), isFalse);
        final PyramidRecord signed = await PyramidRecord(
          body: <String, dynamic>{
            't': PyrT.post,
            'py': w.py,
            'at': at,
            'by': <String>[alias],
            'text': 'x',
            'lvl': 0,
          },
        ).signedBy(x);
        final PyramidRecord renamed = PyramidRecord(
          body: signed.body,
          sigs: <String, String>{alias: signed.sigs.values.single},
        );
        expect(await renamed.verifySigners(), isFalse);
      },
    );

    test('records that could hash the same for two texts do not parse', () {
      Map<String, dynamic> wrap(Map<String, dynamic> b) => <String, dynamic>{
        'b': <String, dynamic>{'t': PyrT.post, 'at': 1, ...b},
      };
      expect(
        PyramidRecord.fromJson(
          wrap(<String, dynamic>{'text': 'zwykły tekst 😀'}),
        ),
        isNotNull,
      );
      expect(
        PyramidRecord.fromJson(
          wrap(<String, dynamic>{'text': 'samotny \uD800 surogat'}),
        ),
        isNull,
      );
      expect(
        PyramidRecord.fromJson(
          wrap(<String, dynamic>{'text': 'odwrotny \uDC00'}),
        ),
        isNull,
      );
      expect(
        PyramidRecord.fromJson(wrap(<String, dynamic>{'amount': 1.5})),
        isNull,
      );
      expect(
        PyramidRecord.fromJson(
          wrap(<String, dynamic>{
            'm': <String, dynamic>{
              'nested': <Object?>[1.0],
            },
          }),
        ),
        isNull,
      );
      expect(
        PyramidRecord.fromJson(<String, dynamic>{
          ...wrap(const <String, dynamic>{}),
          'r': <String, dynamic>{'c': 'zz'},
        }),
        isNull,
      );
    });

    test('a vote dated before its request does not count', () async {
      final List<String> ring = <String>[w.a.id, w.a1.id, w.a2.id]..sort();
      final List<Uint8List> points = ring
          .map((String k) => unb64(k, length: 32)!)
          .toList();
      final Map<String, dynamic> reqBody = <String, dynamic>{
        't': PyrT.voteRequest,
        'py': w.py,
        'at': t0 + day,
        'by': const <String>[],
        'cell': '0',
        'head': w.a.id,
        'ring': ring,
        'n': 'n1',
      };
      final PyramidRecord req = PyramidRecord(
        body: reqBody,
        ring: RingSignature.sign(
          seed: w.a2.seed,
          ring: points,
          context: PyramidState.voteRequestContext(w.py, '0', w.a.id),
          message: PyramidRecord(body: reqBody).signedBytes,
        ),
      );
      final Map<String, dynamic> voteBody = <String, dynamic>{
        't': PyrT.vote,
        'py': w.py,
        'at': t0 + day - 1000,
        'by': const <String>[],
        'elect': req.id,
        'choice': w.a2.id,
        'n': 'v',
      };
      final PyramidRecord vote = PyramidRecord(
        body: voteBody,
        ring: RingSignature.sign(
          seed: w.a2.seed,
          ring: points,
          context: PyramidState.voteContext(req.id),
          message: PyramidRecord(body: voteBody).signedBytes,
        ),
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        req,
        vote,
      ], now: t0 + day + 1000);
      expect(st.elections[req.id]!.votes, isEmpty);
    });
  });

  group('money stays inside 64 bits', () {
    test('a giant emission or transfer is refused and nothing wraps', () async {
      const int at = t0 + day;
      final PyramidRecord huge = await w.emit(at, w.a1, 1 << 62);
      final PyramidRecord fine = await w.emit(at + 60000, w.a1, 5000);
      final PyramidRecord giant = await w.pay(
        at + 25 * h,
        w.a1,
        w.b1,
        1 << 62,
        1,
      );
      final PyramidRecord minus = await w.pay(at + 26 * h, w.a1, w.b1, -9, 1);
      final PyramidRecord ok = await w.pay(at + 27 * h, w.a1, w.b1, 1000, 1);
      final PyramidState st = w.fold(<PyramidRecord>[
        huge,
        fine,
        giant,
        minus,
        ok,
      ], tsigs: w.treasurersSigned(<PyramidRecord>[giant, minus, ok]));
      expect(st.rejected[huge.id], isNotNull);
      expect(st.rejected[giant.id], 'zły przelew');
      expect(st.rejected[minus.id], 'zły przelew');
      expect(st.applied, contains(ok.id));
      expect(st.balanceOf(w.a1.id), 4000);
      expect(st.balanceOf(w.b1.id), 1000);
    });

    test('sums stop at the ceiling instead of wrapping around', () {
      expect(pyrAdd(kPyrMaxBalance, kPyrMaxBalance), kPyrMaxBalance);
      expect(pyrAdd(1 << 62, 1 << 62), kPyrMaxBalance);
      expect(pyrAdd(-5, 7), 7);
      expect(kPyrMaxAmount * 100, greaterThan(0), reason: 'fits in 64 bits');
    });

    test('typed amounts that would not fit are refused', () {
      expect(parseMoney('12,50'), 1250);
      expect(parseMoney('10000000000000'), kPyrMaxAmount);
      expect(parseMoney('10000000000001'), isNull);
      expect(parseMoney('99999999999999999999'), isNull);
      expect(parseMoney('-3'), isNull);
    });
  });
}
