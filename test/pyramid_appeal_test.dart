import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_court_view.dart';
import 'package:zen/src/features/pyramid/pyramid_court.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_root.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The court and appeals on the phones: a complaint, its verdict on the
/// accused's profile — for members and for friends outside the pyramid,
/// whom member friends pass it on to — an appeal one level up, and an
/// appeal refused by the top, which is final.
void main() {
  test('a complaint, a verdict on the profile of the accused (members and '
      'friends outside the pyramid), an appeal that overturns it', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final SimPhone o = w.add('O');
    await w['O'].load();
    w.net.befriend(w.net['A2'], o);
    await w.sync();
    final String b1 = w['B1'].myKey!;
    final String b1Address = w.net['B1'].address;

    // A1 complains about B1: B heads B1's cell.
    expect(w['A1'].firstJudgeOf(b1), '1');
    final PyramidRecord? suit = await w['A1'].sue(
      b1,
      'fraud',
      'Nie oddał 200 zł',
    );
    await w.net.run();
    expect(suit, isNotNull);
    expect(w['B'].casesToDecide().single.id, suit!.id);
    expect(w['A'].casesToDecide(), isEmpty);
    await w['B'].decideCase(
      suit.id,
      guilty: true,
      kind: 'noloan',
      text: 'Nie pożyczajcie mu pieniędzy',
    );
    await w.net.run();
    final PyrVerdict v = w['S'].state!.verdicts.values.single;
    expect(v.addrs, isNotEmpty);
    expect(w['S'].verdictsAt(b1Address).single.kind, 'noloan');
    expect(w['B1'].verdictsAt(null).single.kind, 'noloan', reason: 'own');
    // Outside the pyramid: A2 passed it on to O.
    expect(w['O'].isMember, isFalse);
    expect(w['O'].verdictsAt(b1Address).single.kind, 'noloan');
    expect(w['O'].verdictsAt(w.net['A1'].address), isEmpty);

    // B1 appeals: above B is the top (2 of 3, the parties left out).
    final PyrMatter m = w['B1'].myMatters().single;
    expect(w['B1'].state!.nextJudge(m), '');
    expect(await w['B1'].appealDecision(m.id, ''), isNull, reason: 'why?');
    expect(await w['B1'].appealDecision(m.id, 'Oddałem w gotówce'), isNotNull);
    await w.net.run();
    final PyrAppeal a = w['S'].appealsToAnswer().single;
    expect(a.judge, '');
    expect(a.deadline - a.at, pyrStepTimeMs(1));
    expect(w['A1'].appealsToAnswer(), isEmpty, reason: 'a party');
    await w['S'].answerAppeal(a.id, ok: true, why: 'Pokwitowanie jest');
    await w.net.run();
    await w.approve('A', PyrT.appealAnswer);
    await w.sync();
    expect(w['A1'].state!.verdicts[v.id]!.overturned, isTrue);
    expect(w['S'].verdictsAt(b1Address), isEmpty);
    expect(w['O'].verdictsAt(b1Address), isEmpty, reason: 'with its proof');
    expect(w.views().values.toSet(), hasLength(1));
  });

  test(
    'a ban appealed: the top reconsiders it once, then it is final',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String a2 = w['A2'].myKey!;
      await w['S'].ban(
        target: a2,
        kind: 'content',
        entryId: 'e1',
        reason: 'spam',
      );
      await w.net.run();
      await w.approve('B', PyrT.ban);
      final PyrMatter m = w['A2'].myMatters().single;
      expect(m.kind, PyrMatterKind.ban);
      expect(await w['A2'].appealDecision(m.id, 'To nie spam'), isNotNull);
      await w.net.run();
      final PyrAppeal a = w['B'].appealsToAnswer().single;
      expect(a.deadline - a.at, pyrStepTimeMs(0));
      await w['B'].answerAppeal(a.id, ok: false, why: 'Spam');
      await w.net.run();
      await w.approve('S', PyrT.appealAnswer);
      final PyramidState st = w['A2'].state!;
      expect(st.appeals[a.id]!.ok, isFalse);
      expect(st.nextJudge(st.matters[m.id]!), isNull);
      expect(await w['A2'].appealDecision(m.id, 'Jeszcze raz'), isNull);
      expect(st.bans[m.id]!.lifted, isFalse);
    },
  );

  group('a verdict read outside the pyramid', () {
    /// A reader outside the pyramid with one friend who is a member.
    Future<({SimNetwork net, SimPhone friend, PyramidService reader})>
    reader() async {
      final SimNetwork net = SimNetwork();
      final SimPhone friend = net.phone('F');
      final SimPhone me = net.phone('R');
      net.befriend(friend, me);
      final PyramidService r = PyramidService(
        host: me,
        disk: MemoryLedgerDisk(),
        now: () => net.now,
      );
      me.attach(r.handle);
      await r.load();
      return (net: net, friend: friend, reader: r);
    }

    Future<PyramidRecord> signed(
      String type,
      int at,
      LedgerKeyPair by,
      Map<String, dynamic> fields,
    ) =>
        signedRecord(type, zenPyramidRoot!.id, at, <LedgerKeyPair>[by], fields);

    Future<void> pass(
      SimNetwork net,
      SimPhone from,
      SimPhone to,
      List<Map<String, dynamic>> items,
    ) async {
      await from.send(to.address, <String, dynamic>{
        'type': PyramidTypes.national,
        'vd': items,
      });
      await net.run();
    }

    testWidgets('shows on the profile at the accused\'s address; overturned '
        'only with the accused\'s appeal and an answer by somebody else', (
      WidgetTester tester,
    ) async {
      late ({SimNetwork net, SimPhone friend, PyramidService reader}) x;
      late PyramidRecord v;
      late LedgerKeyPair accused;
      await tester.runAsync(() async {
        x = await reader();
        final LedgerKeyPair judge = await LedgerKeyPair.generate();
        accused = await LedgerKeyPair.generate();
        v = await signed(PyrT.verdict, x.net.now, judge, <String, dynamic>{
          'case': 'c1',
          'guilty': true,
          'k': accused.id,
          'type': 'fraud',
          'text': 'Wziął zaliczkę i zniknął',
          'addrs': <String>['200::bad'],
        });
        await pass(x.net, x.friend, x.net['R'], <Map<String, dynamic>>[
          <String, dynamic>{'r': v.toJson(), 'n': 'Kasia'},
        ]);
      });
      expect(x.reader.verdictsAt('200::bad'), hasLength(1));

      Widget profile(String address) => MaterialApp(
        theme: ZenTheme.dark(),
        home: Scaffold(
          body: ListView(
            children: <Widget>[PyrVerdictList(pyr: x.reader, address: address)],
          ),
        ),
      );
      await tester.pumpWidget(profile('200::bad'));
      expect(find.byKey(const Key('pyr-verdict-badge')), findsOneWidget);
      expect(find.text(pyrVerdictLabel('fraud')), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (Widget x) =>
              x is SelectableText && x.data == 'Wziął zaliczkę i zniknął',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(profile('200::good'));
      expect(find.byKey(const Key('pyr-verdict-badge')), findsNothing);

      // The accused "overturns" it alone: not taken.
      await tester.runAsync(() async {
        final PyramidRecord appeal = await signed(
          PyrT.appeal,
          x.net.now,
          accused,
          <String, dynamic>{'of': v.id, 'why': 'Nie'},
        );
        final PyramidRecord self = await signed(
          PyrT.appealAnswer,
          x.net.now + 1,
          accused,
          <String, dynamic>{'appeal': appeal.id, 'ok': true},
        );
        await pass(x.net, x.friend, x.net['R'], <Map<String, dynamic>>[
          <String, dynamic>{
            'r': v.toJson(),
            'n': 'Kasia',
            'ov': <Map<String, dynamic>>[appeal.toJson(), self.toJson()],
          },
        ]);
      });
      expect(x.reader.verdictsAt('200::bad'), hasLength(1));

      // Accepted by somebody else: overturned.
      await tester.runAsync(() async {
        final LedgerKeyPair higher = await LedgerKeyPair.generate();
        final PyramidRecord appeal = await signed(
          PyrT.appeal,
          x.net.now,
          accused,
          <String, dynamic>{'of': v.id, 'why': 'Nie'},
        );
        final PyramidRecord ok = await signed(
          PyrT.appealAnswer,
          x.net.now + 1,
          higher,
          <String, dynamic>{'appeal': appeal.id, 'ok': true},
        );
        await pass(x.net, x.friend, x.net['R'], <Map<String, dynamic>>[
          <String, dynamic>{
            'r': v.toJson(),
            'n': 'Kasia',
            'ov': <Map<String, dynamic>>[appeal.toJson(), ok.toJson()],
          },
        ]);
      });
      expect(x.reader.verdictsAt('200::bad'), isEmpty);
      await tester.pumpWidget(profile('200::bad'));
      await tester.pump();
      expect(find.byKey(const Key('pyr-verdict-badge')), findsNothing);
    });
  });
}
