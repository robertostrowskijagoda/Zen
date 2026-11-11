import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_court_view.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_decisions.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The court decides without names: a verdict, a dismissal or an answer to
/// an appeal is signed by one-time cards of the judges of its matter (the
/// bench), never by a judge's own key, and carries only as many signatures
/// as the court needs. Nobody outside the bench learns which judges
/// agreed, the screens name the court of a level, never a person, and
/// nothing of the court's way passes through the people it judges.
const int t0 = FoldWorld.t0;
const int day = FoldWorld.day;
const int h = FoldWorld.hour;

void main() {
  group('the fold', () {
    /// X's verdict (by A1) appealed to A, refused, appealed to the top:
    /// parties X and B1, so S, A and B judge it, 2 of 3.
    Future<({FoldWorld w, FoldCourt k, List<PyramidRecord> before, String of})>
    atTheTop() async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      final PyramidRecord c = await w.rec(
        PyrT.suit,
        t0 + day,
        <String>['B1'],
        <String, dynamic>{
          'k': w.id('X'),
          'type': 'noloan',
          'text': 'Nie oddał',
        },
      );
      final PyramidRecord v = await k.rule(
        PyrT.verdict,
        c.id,
        c.at,
        t0 + 2 * day,
        <String>['A1'],
        fields: <String, dynamic>{
          'case': c.id,
          'guilty': true,
          'k': w.id('X'),
          'type': 'noloan',
          'text': 'Nie pożyczajcie',
          'addrs': <String>[FoldWorld.addrOf('X')],
        },
      );
      Future<PyramidRecord> appeal(int at) => w.rec(
        PyrT.appeal,
        at,
        <String>['X'],
        <String, dynamic>{'of': v.id, 'why': 'Nieprawda'},
      );
      final PyramidRecord a1 = await appeal(t0 + 3 * day);
      final PyramidRecord no = await k.rule(
        PyrT.appealAnswer,
        a1.id,
        a1.at,
        t0 + 4 * day,
        <String>['A'],
        fields: <String, dynamic>{'appeal': a1.id, 'ok': false, 'why': 'Nie'},
      );
      final PyramidRecord a2 = await appeal(t0 + 5 * day);
      return (w: w, k: k, before: <PyramidRecord>[c, v, a1, no, a2], of: a2.id);
    }

    Future<PyramidRecord> answer(
      FoldCourt k,
      String of,
      int at,
      List<LedgerKeyPair> cards, {
      List<LedgerKeyPair>? listed,
      int q = 2,
      String appeal = '',
    }) async {
      PyramidRecord r = PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.appealAnswer,
          'py': k.w.py,
          'at': at,
          'by': <String>[for (final LedgerKeyPair c in listed ?? cards) c.id]
            ..sort(),
          'q': q,
          'appeal': appeal.isEmpty ? of : appeal,
          'ok': true,
          'why': 'Racja',
        },
      );
      for (final LedgerKeyPair c in cards) {
        r = await r.signedBy(c);
      }
      return r;
    }

    test('two distinct cards of the bench decide at the top, and the record '
        'names no judge', () async {
      final x = await atTheTop();
      final FoldWorld w = x.w;
      final PyramidRecord bench = await x.k.bench(
        x.of,
        t0 + 5 * day + 1,
        <String>['S', 'A', 'B'],
      );
      final List<LedgerKeyPair> cards = <LedgerKeyPair>[
        for (final String n in <String>['S', 'A', 'B']) await x.k.card(x.of, n),
      ];
      final PyramidRecord ok = await answer(
        x.k,
        x.of,
        t0 + 6 * day,
        <LedgerKeyPair>[cards[0], cards[2]],
        listed: cards,
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        ...x.before,
        ...x.k.benches,
        ok,
      ]);
      expect(st.rejected[bench.id], isNull);
      expect(st.benches[x.of]!.tokens, hasLength(3));
      expect(st.benches[x.of]!.need, 2);
      expect(st.applied, contains(ok.id));
      expect(st.appeals[x.of]!.ok, isTrue);
      // Nobody's key, nobody's address: only cards.
      final String json = jsonEncode(ok.toJson());
      for (final String n in <String>['S', 'A', 'B', 'X', 'B1']) {
        expect(json, isNot(contains(w.id(n))), reason: n);
        expect(json, isNot(contains(FoldWorld.addrOf(n))), reason: n);
      }
      expect(ok.signers.toSet().intersection(st.members.keys.toSet()), isEmpty);
    });

    test('one judge counts once: the same card twice is one, and a bench '
        'with more cards than judges who signed it does not count', () async {
      final x = await atTheTop();
      await x.k.bench(x.of, t0 + 5 * day + 1, <String>['S', 'A', 'B']);
      final LedgerKeyPair s = await x.k.card(x.of, 'S');
      final LedgerKeyPair a = await x.k.card(x.of, 'A');
      final LedgerKeyPair b = await x.k.card(x.of, 'B');
      final PyramidRecord once = await answer(
        x.k,
        x.of,
        t0 + 6 * day,
        <LedgerKeyPair>[s, s],
        listed: <LedgerKeyPair>[s, a, b],
      );
      expect(once.sigs, hasLength(1));
      // S holds two cards on a bench only S and A signed: no bench.
      final LedgerKeyPair second = await LedgerKeyPair.generate();
      final PyramidRecord stuffed = PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.bench,
          'py': x.w.py,
          'at': t0 + 5 * day + 2,
          'by': <String>[x.w.id('S'), x.w.id('A'), x.w.id('B')]..sort(),
          'of': x.of,
          'toks': <String>[s.hybridId, a.hybridId, second.hybridId]..sort(),
        },
      );
      final PyramidRecord stuffedSigned = await (await stuffed.signedBy(
        x.w['S'],
      )).signedBy(x.w['A']);
      final FoldWorld w = x.w;
      final PyramidState st = w.fold(<PyramidRecord>[
        ...x.before,
        ...x.k.benches,
        once,
        stuffedSigned,
      ]);
      expect(st.rejected[once.id], contains('za mało kart'));
      expect(st.rejected[stuffedSigned.id], contains('za mało podpisów'));
      expect(st.appeals[x.of]!.ok, isNull);
    });

    test('a card of one matter does not count in another', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      Future<PyramidRecord> suit(String against, int at) => w.rec(
        PyrT.suit,
        at,
        <String>['B1'],
        <String, dynamic>{
          'k': w.id(against),
          'type': 'beware',
          'text': 'Uwaga',
        },
      );
      final PyramidRecord onX = await suit('X', t0 + day);
      final PyramidRecord onY = await suit('Y', t0 + day + 1);
      Map<String, dynamic> guilty(PyramidRecord c, String who) =>
          <String, dynamic>{
            'case': c.id,
            'guilty': true,
            'k': w.id(who),
            'type': 'beware',
            'text': 'Uważajcie',
            'addrs': <String>[FoldWorld.addrOf(who)],
          };
      // A1 judges both; its card for X signs a verdict in Y.
      await k.bench(onY.id, onY.at + 1, <String>['A1']);
      final LedgerKeyPair forX = await k.card(onX.id, 'A1');
      await k.bench(onX.id, onX.at + 1, <String>['A1']);
      PyramidRecord moved = PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.verdict,
          'py': w.py,
          'at': t0 + 2 * day,
          'by': <String>[forX.id],
          'q': 1,
          ...guilty(onY, 'Y'),
        },
      );
      moved = await moved.signedBy(forX);
      final PyramidRecord right = await k.rule(
        PyrT.verdict,
        onX.id,
        onX.at,
        t0 + 2 * day + 1,
        <String>['A1'],
        fields: guilty(onX, 'X'),
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        onX,
        onY,
        ...k.benches,
        moved,
        right,
      ]);
      expect(st.rejected[moved.id], contains('karty spoza'));
      expect(st.cases[onY.id]!.status, PyrCaseStatus.open);
      expect(st.cases[onX.id]!.status, PyrCaseStatus.guilty);
    });

    test('nobody outside the court holds a card: a bench signed by a '
        'stranger, a decision by a card no bench lists', () async {
      final FoldWorld w = await FoldWorld.make();
      final FoldCourt k = FoldCourt(w);
      final PyramidRecord c = await w.rec(
        PyrT.suit,
        t0 + day,
        <String>['B1'],
        <String, dynamic>{'k': w.id('X'), 'type': 'other', 'text': 'Coś'},
      );
      // B (not X's court) signs a bench for it, and the real one lists
      // A1's card only.
      final PyramidRecord stranger = await k.bench(c.id, c.at + 1, <String>[
        'A1',
        'B',
      ]);
      await k.bench(c.id, c.at + 2, <String>['A1']);
      final LedgerKeyPair outsider = await LedgerKeyPair.generate();
      final PyramidRecord forged = await PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.verdict,
          'py': w.py,
          'at': t0 + 2 * day,
          'by': <String>[outsider.id],
          'q': 1,
          'case': c.id,
          'guilty': false,
          'why': 'Oddalam',
        },
      ).signedBy(outsider);
      final PyramidState st = w.fold(<PyramidRecord>[c, ...k.benches, forged]);
      expect(st.rejected[stranger.id], contains('jego skład'));
      expect(st.rejected[forged.id], contains('karty spoza'));
      expect(st.cases[c.id]!.status, PyrCaseStatus.open);
    });

    test('a judge who left the court before the decision no longer counts: '
        'the bench of the old court is spent, a new one decides', () async {
      final x = await atTheTop();
      final FoldWorld w = x.w;
      await x.k.bench(x.of, t0 + 5 * day + 1, <String>['S', 'A', 'B']);
      final List<LedgerKeyPair> old = <LedgerKeyPair>[
        for (final String n in <String>['S', 'A', 'B']) await x.k.card(x.of, n),
      ];
      // B leaves the pyramid: the top is S and A now.
      final PyramidRecord leave = await w.rec(
        PyrT.leave,
        t0 + 5 * day + h,
        <String>['B'],
        <String, dynamic>{'k': w.id('B')},
      );
      final PyramidRecord withB = await answer(
        x.k,
        x.of,
        t0 + 5 * day + 2 * h,
        <LedgerKeyPair>[old[0], old[2]],
        listed: old,
      );
      final PyramidRecord again = await x.k.bench(
        x.of,
        t0 + 5 * day + 3 * h,
        <String>['S', 'A'],
      );
      final LedgerKeyPair s2 = await x.k.card(x.of, 'S');
      final LedgerKeyPair a2 = await x.k.card(x.of, 'A');
      final PyramidRecord byNew = await answer(
        x.k,
        x.of,
        t0 + 5 * day + 4 * h,
        <LedgerKeyPair>[s2, a2],
      );
      final PyramidState st = w.fold(<PyramidRecord>[
        ...x.before,
        ...x.k.benches,
        leave,
        withB,
        byNew,
      ]);
      expect(st.rejected[withB.id], contains('skład sądu się zmienił'));
      expect(st.benches[x.of]!.id, again.id);
      expect(st.applied, contains(byNew.id));
      expect(st.appeals[x.of]!.ok, isTrue);
    });
  });

  group('on the phones', () {
    /// Szczepan on top; Agata and Bogdan under him; Adam and Alicja under
    /// Agata; Beata under Bogdan. Adam sues Beata, Bogdan (her head)
    /// judges; Beata appeals to the top, where Szczepan, Agata and Bogdan
    /// judge, 2 of 3.
    Future<PyramidWorld> world() async {
      final PyramidWorld w = PyramidWorld();
      final SimPhone s = w.add('Szczepan');
      final SimPhone a = w.add('Agata');
      final SimPhone b = w.add('Bogdan');
      final SimPhone a1 = w.add('Adam');
      final SimPhone a2 = w.add('Alicja');
      final SimPhone b1 = w.add('Beata');
      await w.pyr(s).load();
      await w
          .pyr(s)
          .found(myName: 'Szczepan', nat: 'PL', birthYear: 1980, gender: 'm');
      await w.join(s, a);
      await w.join(s, b);
      await w.join(a, a1);
      await w.join(a, a2);
      await w.join(b, b1);
      w.net
        ..befriend(a2, b1)
        ..befriend(a1, b);
      await w.sync();
      return w;
    }

    const List<String> judges = <String>['Szczepan', 'Agata', 'Bogdan'];

    /// Every court decision ([PyrT.ruled]) inside [json], however deep.
    List<Map<String, dynamic>> rulingsIn(
      Object? json,
    ) => <Map<String, dynamic>>[
      if (json is Map) ...<Map<String, dynamic>>[
        if (json['b'] is Map && PyrT.ruled.contains((json['b'] as Map)['t']))
          Map<String, dynamic>.from(json),
        for (final Object? v in json.values) ...rulingsIn(v),
      ] else if (json is List)
        for (final Object? v in json) ...rulingsIn(v),
    ];

    testWidgets(
      'a verdict and an appeal at the top: no record, frame or screen names '
      'a judge, and every phone keeps only the signatures the court needs',
      (WidgetTester tester) async {
        late PyramidWorld w;
        late PyramidRecord verdict;
        late PyramidRecord answer;
        await tester.runAsync(() async {
          w = await world();
          final String beata = w['Beata'].myKey!;
          final PyramidRecord? suit = await w['Adam'].sue(
            beata,
            'fraud',
            'Nie oddała 200 zł',
          );
          await w.net.run();
          expect(w['Bogdan'].casesToDecide().single.id, suit!.id);
          expect(
            await w['Bogdan'].decideCase(
              suit.id,
              guilty: true,
              kind: 'noloan',
              text: 'Nie pożyczajcie jej pieniędzy',
            ),
            isTrue,
          );
          await w.net.run();
          final PyrVerdict v = w['Szczepan'].state!.verdicts.values.single;
          verdict = w['Szczepan'].recordOf(v.id)!;
          final PyrMatter m = w['Beata'].myMatters().single;
          expect(await w['Beata'].appealDecision(m.id, 'Oddałam'), isNotNull);
          await w.net.run();
          await w.duties();
          final PyrAppeal a = w['Szczepan'].appealsToAnswer().single;
          expect(w['Szczepan'].state!.benches[a.id]!.ring, hasLength(3));
          expect(
            await w['Szczepan'].answerAppeal(a.id, ok: true, why: 'Oddała'),
            isTrue,
          );
          await w.net.run();
          await w.approve('Agata', PyrT.appealAnswer);
          await w.sync();
          answer = w['Beata'].recordOf(
            w['Beata'].state!.appeals[a.id]!.answer!,
          )!;
        });

        final PyramidState st = w['Beata'].state!;
        final Set<String> judgeKeys = <String>{
          for (final String n in judges) w[n].myKey!,
        };
        final Set<String> judgeAddrs = <String>{
          for (final String n in judges) w.net[n].address,
        };
        expect(st.verdicts[verdict.id]!.overturned, isTrue);
        // The records: cards only, as many as the court needs.
        for (final PyramidRecord r in <PyramidRecord>[verdict, answer]) {
          expect(r.candidates.toSet().intersection(judgeKeys), isEmpty);
          expect(
            r.signers.toSet().intersection(st.members.keys.toSet()),
            isEmpty,
          );
          expect(r.sigs, hasLength(r.integer('q')));
          final String json = jsonEncode(r.toJson());
          for (final String x in <String>{...judgeKeys, ...judgeAddrs}) {
            expect(json, isNot(contains(x)));
          }
        }
        expect(answer.integer('q'), 2);
        for (final SimPhone p in w.net.phones) {
          final PyramidRecord? kept = w.pyr(p).recordOf(answer.id);
          expect(
            kept?.sigs.keys.toList(),
            answer.sigs.keys.toList(),
            reason: p.name,
          );
        }
        // Every frame that carried a decision of the court: no judge's
        // key or address in the decision, nor in a frame of the court's
        // own way between judges (but the list of whom a friend should
        // pass it on to: the court itself, never only the signers).
        int carried = 0;
        for (final SimPhone p in w.net.phones) {
          for (final Map<String, dynamic> frame in p.outbox) {
            final bool between =
                (frame['type'] == PyramidTypes.proposal ||
                    frame['type'] == PyramidTypes.anon) &&
                rulingsIn(frame).isNotEmpty;
            for (final Map<String, dynamic> x in <Map<String, dynamic>>[
              ...rulingsIn(frame),
              if (between) <String, dynamic>{...frame}..remove('to'),
            ]) {
              carried++;
              final String json = jsonEncode(x);
              for (final String k in <String>{...judgeKeys, ...judgeAddrs}) {
                expect(
                  json,
                  isNot(contains(k)),
                  reason: '${p.name} ${frame['type']}',
                );
              }
            }
          }
        }
        expect(carried, greaterThan(0));
        // Nothing of the court's way passes through the accused or the
        // plaintiff: neither cards nor decisions on their way.
        for (final String n in <String>['Beata', 'Adam']) {
          for (final Map<String, dynamic> frame in w.net[n].outbox) {
            expect(
              (frame['type'] == PyramidTypes.proposal ||
                      frame['type'] == PyramidTypes.card) &&
                  frame['of'] != null,
              isFalse,
              reason: n,
            );
          }
        }
        // The court's part of the history names no judge.
        final Set<String> court = <String>{
          for (final String id in w['Beata'].recordIds)
            if (<String>{
              PyrT.suit,
              PyrT.appeal,
              PyrT.bench,
              ...PyrT.ruled,
            }.contains(w['Beata'].recordOf(id)!.type))
              id,
        };
        for (final PyrHistory e in st.history) {
          if (!court.contains(e.recordId)) {
            continue;
          }
          for (final String n in judges) {
            expect(e.text, isNot(contains(n)), reason: e.text);
          }
        }
        for (final String id in w['Beata'].recordIds) {
          final PyramidRecord r = w['Beata'].recordOf(id)!;
          if (PyrT.ruled.contains(r.type) || r.type == PyrT.bench) {
            for (final String n in judges) {
              expect(w['Beata'].describeRecord(r), isNot(contains(n)));
            }
          }
        }

        // The screens: Beata's decisions, the verdict on her profile.
        Widget app(Widget child) => MaterialApp(
          theme: ZenTheme.dark(),
          home: Scaffold(body: ListView(children: <Widget>[child])),
        );
        void noJudge() {
          for (final Widget t in tester.allWidgets) {
            final String? text = t is Text
                ? t.data ?? t.textSpan?.toPlainText()
                : t is SelectableText
                ? t.data ?? t.textSpan?.toPlainText()
                : null;
            for (final String n in judges) {
              expect(text ?? '', isNot(contains(n)), reason: text);
            }
          }
        }

        await tester.pumpWidget(
          app(
            DecisionsAgainstMe(pyr: w['Beata'], s: st, me: w['Beata'].myKey!),
          ),
        );
        expect(find.byKey(const Key('decisions-against-me')), findsOneWidget);
        expect(find.textContaining(pyrJudgeName(st, '')), findsWidgets);
        noJudge();
      },
    );

    testWidgets('while a case waits: the judges\' list, the complaint and the '
        'verdict on a profile name the court of a level, not its judge', (
      WidgetTester tester,
    ) async {
      late PyramidWorld w;
      await tester.runAsync(() async {
        w = await world();
        await w['Adam'].sue(w['Beata'].myKey!, 'fraud', 'Nie oddała');
        await w.net.run();
      });
      final PyramidState st = w['Bogdan'].state!;
      Widget app(Widget child) => MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(body: ListView(children: <Widget>[child])),
      );
      void noJudge() {
        for (final Widget t in tester.allWidgets) {
          final String text = switch (t) {
            Text(:final String? data, :final InlineSpan? textSpan) =>
              data ?? textSpan?.toPlainText() ?? '',
            SelectableText(:final String? data, :final TextSpan? textSpan) =>
              data ?? textSpan?.toPlainText() ?? '',
            _ => '',
          };
          expect(text, isNot(contains('Bogdan')), reason: text);
        }
      }

      await tester.pumpWidget(app(CourtDuties(pyr: w['Bogdan'], s: st)));
      expect(find.byKey(const Key('court-duties')), findsOneWidget);
      noJudge();
      // Adam's complaint form: "Rozpatrzy: sąd poziomu 2".
      expect(pyrJudgeName(st, '1'), isNot(contains('Bogdan')));
      expect(w['Adam'].firstJudgeOf(w['Beata'].myKey!), '1');
      // The verdict, once given, on Beata's profile.
      await tester.runAsync(() async {
        await w['Bogdan'].decideCase(
          w['Bogdan'].casesToDecide().single.id,
          guilty: true,
          kind: 'beware',
          text: 'Uważajcie',
        );
        await w.net.run();
      });
      await tester.pumpWidget(
        app(PyrVerdictList(pyr: w['Adam'], address: w.net['Beata'].address)),
      );
      expect(find.byKey(const Key('pyr-verdict-badge')), findsOneWidget);
      noJudge();
    });
  });
}
