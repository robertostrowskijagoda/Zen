import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The court of the pyramid and appeals in the fold: a complaint goes to
/// the court of the accused's cell (its head), every appeal one level
/// higher with twice the time, up to the top whose refusal is final;
/// accepting overturns. Every decision is signed by the cards of its
/// matter's bench, never by a judge's own key. S on top, A and B, A1 and
/// A2 under A, B1 under B, X and Y under A1.
const int t0 = FoldWorld.t0;
const int day = FoldWorld.day;
const int h = FoldWorld.hour;

void main() {
  Future<PyramidRecord> suit(
    FoldWorld w,
    int at, {
    String by = 'B1',
    String against = 'X',
    String kind = 'fraud',
  }) => w.rec(
    PyrT.suit,
    at,
    <String>[by],
    <String, dynamic>{
      'k': w.id(against),
      'type': kind,
      'text': 'Nie oddał pożyczki',
    },
  );

  Future<PyramidRecord> verdict(
    FoldCourt k,
    PyramidRecord c,
    int at,
    List<String> judges, {
    String against = 'X',
    List<String>? addrs,
    List<String>? ring,
  }) => k.rule(
    PyrT.verdict,
    c.id,
    c.at,
    at,
    judges,
    ring: ring,
    fields: <String, dynamic>{
      'case': c.id,
      'guilty': true,
      'k': k.w.id(against),
      'type': 'noloan',
      'text': 'Nie pożyczajcie mu pieniędzy',
      'addrs': addrs ?? <String>[FoldWorld.addrOf(against)],
    },
  );

  Future<PyramidRecord> appeal(
    FoldWorld w,
    String of,
    int at, {
    String by = 'X',
  }) => w.rec(
    PyrT.appeal,
    at,
    <String>[by],
    <String, dynamic>{'of': of, 'why': 'To nieprawda'},
  );

  /// The top judges [a] (S, A and B, none of them a party here), 2 of 3.
  const List<String> top = <String>['S', 'A', 'B'];

  Future<PyramidRecord> answer(
    FoldCourt k,
    PyramidRecord a,
    int at,
    List<String> judges, {
    required bool ok,
    List<String>? ring,
    Map<String, dynamic> more = const <String, dynamic>{},
  }) => k.rule(
    PyrT.appealAnswer,
    a.id,
    a.at,
    at,
    judges,
    ring: ring,
    q: (ring ?? judges).length > 1 ? 2 : 1,
    fields: <String, dynamic>{
      'appeal': a.id,
      'ok': ok,
      'why': ok ? 'Racja' : 'Nie',
      ...more,
    },
  );

  group('the court', () {
    test('a complaint goes to the court of the accused\'s cell, which has 3 '
        'days; a verdict shows at the accused\'s addresses', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      final PyramidRecord c = await suit(w, t0 + day);
      // A is not that court: its cards make no bench, and its own key is
      // no card.
      final PyramidRecord otherBench = await k.bench(
        c.id,
        t0 + day + 2,
        <String>['A'],
      );
      final PyramidRecord byOther = await w.rec(
        PyrT.verdict,
        t0 + day + h,
        <String>['A'],
        <String, dynamic>{
          'case': c.id,
          'guilty': true,
          'k': w.id('X'),
          'type': 'noloan',
          'text': 'Nie pożyczajcie mu pieniędzy',
          'addrs': <String>[FoldWorld.addrOf('X')],
          'q': 1,
        },
      );
      final PyramidRecord wrongPlace = await verdict(
        k,
        c,
        t0 + day + 2 * h,
        <String>['A1'],
        addrs: <String>[FoldWorld.addrOf('S')],
      );
      final PyramidRecord ok = await verdict(k, c, t0 + 2 * day, <String>[
        'A1',
      ]);
      final PyramidState st = w.fold(<PyramidRecord>[
        c,
        ...k.benches,
        byOther,
        wrongPlace,
        ok,
      ]);
      final PyrCase kase = st.cases[c.id]!;
      expect(kase.judge, '00');
      expect(kase.deadline, t0 + day + pyrStepTimeMs(0));
      expect(pyrStepTimeMs(0), 3 * day);
      expect(st.rejected[otherBench.id], contains('jego skład'));
      expect(st.rejected[byOther.id], contains('karty spoza'));
      expect(st.rejected[wrongPlace.id], contains('adresy'));
      expect(kase.status, PyrCaseStatus.guilty);
      final PyrVerdict v = st.verdictsAgainst(w.id('X'), t0 + 3 * day).single;
      expect(v.kind, 'noloan');
      expect(v.judge, '00');
      expect(st.membersAt(FoldWorld.addrOf('X'), (String a) => a), <String>[
        w.id('X'),
      ]);
    });

    test('nobody judges in their own case; no verdict after the time; '
        'nobody sues themself', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      // A1 sues X: A1 heads X's cell, so the level above judges.
      final PyramidRecord byHead = await suit(w, t0 + day, by: 'A1');
      final PyramidRecord self = await suit(w, t0 + day + 1, by: 'X');
      final PyramidRecord c = await suit(w, t0 + day + 2);
      final PyramidRecord late = await verdict(k, c, t0 + 4 * day + 2, <String>[
        'A1',
      ]);
      final PyramidState st = w.fold(<PyramidRecord>[
        byHead,
        self,
        c,
        ...k.benches,
        late,
      ]);
      expect(st.cases[byHead.id]!.judge, '0');
      expect(st.rejected[self.id], contains('innego członka'));
      expect(st.rejected[late.id], contains('poza czasem'));
      expect(st.cases[c.id]!.expiredAt(t0 + 4 * day + 2), isTrue);
    });

    test('at most 3 open complaints at a time', () async {
      final FoldWorld w = await FoldWorld.make();
      final List<String> accused = <String>['X', 'Y', 'A2', 'A1'];
      final List<PyramidRecord> four = <PyramidRecord>[
        for (int i = 0; i < accused.length; i++)
          await suit(w, t0 + day + i, against: accused[i]),
      ];
      final PyramidState st = w.fold(four);
      expect(st.cases, hasLength(kPyrOpenSuits));
      expect(st.rejected[four.last.id], contains('za dużo'));
    });
  });

  group('appeals', () {
    test('one level up each time, twice as long each time; the top\'s '
        'refusal is final', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      final PyramidRecord c = await suit(w, t0 + day);
      final PyramidRecord v = await verdict(k, c, t0 + 2 * day, <String>['A1']);
      final PyramidRecord a1 = await appeal(w, v.id, t0 + 3 * day);
      final PyramidRecord notTheirs = await appeal(
        w,
        v.id,
        t0 + 3 * day + 1,
        by: 'Y',
      );
      final PyramidRecord twice = await appeal(w, v.id, t0 + 3 * day + 2);
      final PyramidRecord wrongJudge = await answer(
        k,
        a1,
        t0 + 3 * day + 3,
        <String>['B'],
        ok: true,
      );
      final PyramidRecord refuse1 = await answer(k, a1, t0 + 4 * day, <String>[
        'A',
      ], ok: false);
      final PyramidRecord a2 = await appeal(w, v.id, t0 + 5 * day);
      final PyramidRecord oneOfTop = await answer(
        k,
        a2,
        t0 + 6 * day,
        <String>['S'],
        ring: top,
        ok: false,
      );
      final PyramidRecord refuse2 = await answer(
        k,
        a2,
        t0 + 6 * day + 1,
        <String>['S', 'B'],
        ring: top,
        ok: false,
      );
      final PyramidRecord a3 = await appeal(w, v.id, t0 + 7 * day);
      final PyramidState st = w.fold(<PyramidRecord>[
        c,
        v,
        a1,
        notTheirs,
        twice,
        wrongJudge,
        refuse1,
        a2,
        oneOfTop,
        refuse2,
        a3,
        ...k.benches,
      ]);
      final PyrAppeal first = st.appeals[a1.id]!;
      // A verdict of the first instance (step 0): its appeal is step 1.
      expect(first.judge, '0');
      expect(first.deadline, t0 + 3 * day + 6 * day);
      expect(st.rejected[notTheirs.id], contains('tylko osoba'));
      expect(st.rejected[twice.id], contains('jeszcze czeka'));
      // B's cards are no bench of this appeal: A judges it.
      expect(st.rejected[wrongJudge.id], contains('karty spoza'));
      expect(first.ok, isFalse);
      final PyrAppeal second = st.appeals[a2.id]!;
      expect(second.judge, '', reason: 'the top');
      expect(second.deadline, t0 + 5 * day + 12 * day);
      expect(st.rejected[oneOfTop.id], contains('za mało kart'));
      expect(second.ok, isFalse);
      expect(st.rejected[a3.id], contains('ostateczna'));
      expect(st.verdictsAgainst(w.id('X'), t0 + 8 * day), hasLength(1));
      expect(st.nextJudge(st.matters[v.id]!), isNull);
    });

    test('no answer in time: one level higher; a late answer does not '
        'count; accepted, the verdict is overturned', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      final PyramidRecord c = await suit(w, t0 + day);
      final PyramidRecord v = await verdict(k, c, t0 + 2 * day, <String>['A1']);
      const int at = t0 + 3 * day;
      final PyramidRecord a1 = await appeal(w, v.id, at);
      final PyramidRecord tooEarly = await appeal(w, v.id, at + 6 * day - 1);
      final PyramidRecord lateAnswer = await answer(
        k,
        a1,
        at + 6 * day,
        <String>['A'],
        ok: true,
      );
      final PyramidRecord a2 = await appeal(w, v.id, at + 6 * day + 1);
      final PyramidRecord accept = await answer(
        k,
        a2,
        at + 7 * day,
        <String>['S', 'A'],
        ring: top,
        ok: true,
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        c,
        v,
        a1,
        tooEarly,
        lateAnswer,
        a2,
        accept,
        ...k.benches,
      ]);
      expect(st.rejected[tooEarly.id], contains('jeszcze czeka'));
      expect(st.rejected[lateAnswer.id], contains('poza czasem'));
      expect(st.appeals[a1.id]!.expiredAt(at + 6 * day), isTrue);
      expect(st.appeals[a2.id]!.judge, '');
      expect(st.appeals[a2.id]!.ok, isTrue);
      expect(st.verdicts[v.id]!.overturned, isTrue);
      expect(st.verdictsAgainst(w.id('X'), at + 8 * day), isEmpty);
      expect(st.matters[v.id]!.overturned, isTrue);
    });

    test(
      'a dismissed complaint: the plaintiff appeals; accepted above, the '
      'verdict comes from there and the accused appeals it further',
      () async {
        final FoldWorld w = await FoldWorld.make();
        final FoldCourt k = FoldCourt(w);
        final PyramidRecord c = await suit(w, t0 + day);
        final PyramidRecord dismiss = await k.rule(
          PyrT.verdict,
          c.id,
          c.at,
          t0 + 2 * day,
          <String>['A1'],
          fields: <String, dynamic>{
            'case': c.id,
            'guilty': false,
            'why': 'Brak dowodów',
          },
        );
        final PyramidRecord byAccused = await appeal(w, c.id, t0 + 3 * day);
        final PyramidRecord byPlaintiff = await appeal(
          w,
          c.id,
          t0 + 3 * day + 1,
          by: 'B1',
        );
        final PyramidRecord accept = await answer(
          k,
          byPlaintiff,
          t0 + 4 * day,
          <String>['A'],
          ok: true,
          more: <String, dynamic>{
            'k': w.id('X'),
            'type': 'beware',
            'text': 'Uważajcie',
            'addrs': <String>[FoldWorld.addrOf('X')],
          },
        );
        final PyramidRecord further = await appeal(w, accept.id, t0 + 5 * day);
        final PyramidState st = w.fold(<PyramidRecord>[
          c,
          dismiss,
          byAccused,
          byPlaintiff,
          accept,
          further,
          ...k.benches,
        ]);
        expect(st.rejected[byAccused.id], contains('tylko osoba'));
        expect(st.cases[c.id]!.status, PyrCaseStatus.guilty);
        final PyrVerdict v = st.verdicts[accept.id]!;
        expect(v.kind, 'beware');
        expect(v.judge, '0');
        expect(st.appeals[further.id]!.judge, '', reason: 'above A: the top');
        // Step 1 was the plaintiff's appeal: the accused's is step 2.
        expect(st.appeals[further.id]!.deadline, t0 + 5 * day + 12 * day);
      },
    );

    test('a complaint not answered in time: the plaintiff goes one level '
        'up', () async {
      final FoldWorld w = await FoldWorld.make();
      final PyramidRecord c = await suit(w, t0 + day);
      final PyramidRecord early = await appeal(
        w,
        c.id,
        t0 + 4 * day - 1,
        by: 'B1',
      );
      final PyramidRecord inTime = await appeal(
        w,
        c.id,
        t0 + 4 * day,
        by: 'B1',
      );
      final PyramidState st = w.fold(<PyramidRecord>[c, early, inTime]);
      expect(st.rejected[early.id], contains('czeka'));
      expect(st.appeals[inTime.id]!.judge, '0');
    });

    test('a ban of the top: the top reconsiders it once', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      Future<PyramidRecord> ban(int at) => w.rec(
        PyrT.ban,
        at,
        <String>['S', 'A'],
        <String, dynamic>{
          'target': w.id('Y'),
          'kind': 'pause',
          'until': at + 30 * day,
          'reason': 'spam',
        },
      );
      final PyramidRecord b1 = await ban(t0 + day);
      final PyramidRecord ap1 = await appeal(w, b1.id, t0 + 2 * day, by: 'Y');
      final PyramidRecord lift = await answer(
        k,
        ap1,
        t0 + 3 * day,
        <String>['S', 'B'],
        ring: top,
        ok: true,
      );
      final PyramidRecord b2 = await ban(t0 + 4 * day);
      final PyramidRecord ap2 = await appeal(w, b2.id, t0 + 5 * day, by: 'Y');
      final PyramidRecord refuse = await answer(
        k,
        ap2,
        t0 + 6 * day,
        <String>['S', 'A'],
        ring: top,
        ok: false,
      );
      final PyramidRecord again = await appeal(w, b2.id, t0 + 7 * day, by: 'Y');
      final PyramidState st = w.fold(<PyramidRecord>[
        b1,
        ap1,
        lift,
        b2,
        ap2,
        refuse,
        again,
        ...k.benches,
      ]);
      expect(st.appeals[ap1.id]!.judge, '');
      expect(st.appeals[ap1.id]!.deadline, t0 + 2 * day + 3 * day);
      expect(st.bans[b1.id]!.lifted, isTrue);
      expect(st.bans[b2.id]!.lifted, isFalse);
      expect(st.rejected[again.id], contains('ostateczna'));
    });

    test('appealing a ban of a report decision overturns the decision: every '
        'ban it gave is lifted', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      Future<PyramidRecord> ban(int at, String kind) => w.rec(
        PyrT.ban,
        at,
        <String>['S', 'A'],
        <String, dynamic>{
          'target': w.id('Y'),
          'kind': kind,
          'dk': 'dk-y',
          'rep': 'r1',
        },
      );
      final PyramidRecord dating = await ban(t0 + day, 'dating');
      final PyramidRecord pause = await ban(t0 + day + 1, 'pause');
      final PyramidRecord ap = await appeal(w, pause.id, t0 + 2 * day, by: 'Y');
      final PyramidRecord ok = await answer(
        k,
        ap,
        t0 + 3 * day,
        <String>['S', 'B'],
        ring: top,
        ok: true,
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        dating,
        pause,
        ap,
        ok,
        ...k.benches,
      ]);
      expect(st.bans[dating.id]!.lifted, isTrue);
      expect(st.bans[pause.id]!.lifted, isTrue);
      expect(st.overturnedReports, contains('r1'));
    });

    test('a removal overturned: back on the old place, or the nearest free '
        'one in the old branch — never higher', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      // Y's own cell: A1 above and X beside.
      final PyramidRecord remove = await w.rec(
        PyrT.remove,
        t0 + day,
        <String>['A1', 'X'],
        <String, dynamic>{'k': w.id('Y')},
      );
      final PyramidRecord ap = await appeal(
        w,
        remove.id,
        t0 + 2 * day,
        by: 'Y',
      );
      final PyramidRecord ok = await answer(k, ap, t0 + 3 * day, <String>[
        'A',
      ], ok: true);
      PyramidState st = w.fold(<PyramidRecord>[remove, ap, ok, ...k.benches]);
      expect(st.appeals[ap.id]!.judge, '0', reason: 'above A1, who removed');
      expect(st.pathOf(w.id('Y')), '001');
      expect(st.members[w.id('Y')]!.active, isTrue);

      // Meanwhile somebody else took the place: the nearest free one below.
      final FoldWorld w2 = await FoldWorld.make(
        tree: <(String, String?, String)>[...kFoldTree, ('Z', 'X', '0000')],
      );
      final FoldCourt k2 = FoldCourt(w2);
      final PyramidRecord remove2 = await w2.rec(
        PyrT.remove,
        t0 + day,
        <String>['A1', 'X'],
        <String, dynamic>{'k': w2.id('Y')},
      );
      final PyramidRecord moveIn = await w2.rec(
        PyrT.migrate,
        t0 + day + 1,
        <String>['B1', 'A1'],
        <String, dynamic>{'k': w2.id('B1'), 'to': w2.id('A1')},
      );
      final PyramidRecord ap2 = await appeal(
        w2,
        remove2.id,
        t0 + 2 * day,
        by: 'Y',
      );
      final PyramidRecord ok2 = await answer(k2, ap2, t0 + 3 * day, <String>[
        'A',
      ], ok: true);
      st = w2.fold(<PyramidRecord>[remove2, moveIn, ap2, ok2, ...k2.benches]);
      expect(st.pathOf(w2.id('B1')), '001');
      final String back = st.pathOf(w2.id('Y'))!;
      expect(back.length, greaterThanOrEqualTo(3));
      expect(back.startsWith('00'), isTrue);
    });
  });
}
