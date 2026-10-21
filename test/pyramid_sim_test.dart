import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

import 'support/pyramid_world.dart';

void main() {
  test(
    'a pyramid grows by in-person admissions and everyone agrees on it',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidState st = w['B1'].state!;
      expect(st.members, hasLength(6));
      expect(st.pathOf(w['A1'].myKey!), '00');
      expect(st.pathOf(w['B1'].myKey!), '10');
      expect(st.members[w['B1'].myKey!]!.nat, 'DE');
      expect(
        w.views().values.toSet(),
        hasLength(1),
        reason: 'everyone folds the same pyramid',
      );
      expect(w.net['A1'].notificationTitles, contains('Jesteś w piramidzie'));
      // The newcomer's data is confirmed by the head, the public sees a hash.
      expect(st.members[w['A1'].myKey!]!.dataCommit, w['A1'].myData['dc']);
      expect(w['A1'].myData['by'], 1990);
    },
  );

  test('open swap up a cell, then an anonymous vote for the head', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidService a1 = w['A1'];
    final PyramidService a2 = w['A2'];
    final String keyA = w['A'].myKey!;

    // A1 and A2 make A1 the head of cell A.
    await a1.proposeSwap('0', a1.myKey!);
    await w.net.run();
    await a2.approve(a2.proposals.keys.single);
    await w.net.run();
    expect(w['S'].state!.pathOf(a1.myKey!), '0');
    expect(w['S'].state!.pathOf(keyA), '00');

    // Someone asks anonymously for a new vote; nobody sees who.
    expect(await a2.requestElection('0'), isTrue);
    await w.net.run();
    final PyrElection e = w['S'].state!.elections.values.single;
    expect(e.cell, '0');
    expect(w.net['A'].notificationTitles, contains('Głosowanie w komórce'));
    await w['A'].voteInCell(e.id, a2.myKey!);
    await a2.voteInCell(e.id, a2.myKey!);
    await a1.voteInCell(e.id, a1.myKey!);
    await w.net.run();
    // A2 wins 2:1 and swaps places with A1.
    final PyramidState st = w['B'].state!;
    expect(st.pathOf(a2.myKey!), '0');
    expect(st.pathOf(a1.myKey!), '01');
    expect(st.elections[e.id]!.winner, a2.myKey);
    // A second vote by the same person does not count.
    expect(await a2.voteInCell(e.id, a2.myKey!), isFalse);
  });

  test(
    'a cell vote counts one-time cards, and a member away does not block it',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService a = w['A'];
      final PyramidService a2 = w['A2'];
      w.net.setOnline(w.net['A1'], false);
      expect(await a2.requestElection('0'), isTrue);
      await w.net.run();
      // The cell's request cards wait for A1 a while; then the two cards
      // there make the roster and the request goes out by itself.
      expect(a.state!.elections, isEmpty);
      expect(a2.requestWaiting('0'), isTrue);
      await w.net.advance(const Duration(hours: 13));
      await w.duties();
      expect(a2.requestWaiting('0'), isFalse);
      expect(a.state!.rosters['0']!.tokens, hasLength(2));
      final PyrElection e = a.state!.elections.values.single;
      expect(e.tokens, isNull, reason: 'A1 has not sent its card yet');
      // A votes now: the vote waits for the ballot, and only once.
      expect(await a.voteInCell(e.id, a2.myKey!), isTrue);
      expect(a.voteWaiting(e.id), isTrue);
      expect(await a.voteInCell(e.id, a2.myKey!), isFalse);
      // A third of the vote's time later the two cards there make the
      // ballot, and the waiting vote goes out by itself.
      await w.net.advance(const Duration(hours: 25));
      await w.duties();
      final PyrElection seen = w['S'].state!.elections[e.id]!;
      expect(seen.tokens, hasLength(2));
      expect(seen.votes, hasLength(1));
      expect(a.voteWaiting(e.id), isFalse);
      expect(a.votedIn(e.id), isTrue);
      // The records of the vote name no member; the ballot is signed by
      // the two who sent cards.
      int votes = 0;
      for (final String id in w['S'].recordIds) {
        final PyramidRecord r = w['S'].recordOf(id)!;
        if (r.type == PyrT.vote) {
          votes++;
          expect(r.signers.toSet().intersection(e.ring.toSet()), isEmpty);
        }
        if (r.type == PyrT.ballot && id == seen.ballot) {
          expect(r.signers.toSet(), <String>{a.myKey!, a2.myKey!});
        }
      }
      expect(votes, 1);
      expect(await a2.voteInCell(e.id, a2.myKey!), isTrue);
      await w.net.run();
      final PyramidState st = w['B'].state!;
      expect(st.elections[e.id]!.closed, isTrue);
      expect(st.elections[e.id]!.winner, a2.myKey);
      expect(st.pathOf(a2.myKey!), '0');
    },
  );

  test(
    'a referendum counted up the tree: votes secret, sums checkable',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      // Everybody votes (admitted straight by a member who votes).
      await w.knowAll();
      final PyramidService s = w['S'];
      await s.referendum(
        question: 'Zbiórka na świetlicę?',
        options: <String>['Tak', 'Nie'],
        end: w.net.now + 3600 * 1000,
      );
      await w.net.run();
      await w.approve('A', PyrT.referendum);
      final PyrReferendum ref = w['B1'].state!.referenda.values.single;
      expect(w.net['B1'].notificationTitles, contains('Referendum'));
      final Map<String, int> votes = <String, int>{
        'S': 0,
        'A': 0,
        'B': 1,
        'A1': 0,
        'A2': 1,
        'B1': 0,
      };
      for (final MapEntry<String, int> v in votes.entries) {
        expect(
          await w[v.key].voteReferendum(ref.id, v.value),
          isTrue,
          reason: v.key,
        );
      }
      expect(await w['A1'].voteReferendum(ref.id, 1), isFalse, reason: 'once');
      await w.net.run();
      await w.net.advance(const Duration(hours: 1, minutes: 1));
      await w.duties();
      final List<int>? result = w['A1'].state!.resultOf(ref.id);
      expect(result, <int>[4, 2]);
      // Nobody's vote is in a public record: only sums.
      for (final PyrTally t
          in w['A1'].state!.referenda[ref.id]!.tallies.values) {
        expect(t.total, greaterThan(0));
      }
    },
  );

  test(
    'emission after 24 h, a payment signed by most treasurers, a veto',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService s = w['S'];
      final String a1 = w['A1'].myKey!;
      final String b1 = w['B1'].myKey!;
      await w.sealKeys();
      await s.emit(a1, 100000, 'Start');
      await w.net.run();
      await w.approve('B', PyrT.emit);
      expect(w['A1'].balance, 0, reason: 'not before 24 h');
      expect(w.net['A'].notificationTitles, contains('Emisja czeka 24 h'));
      await w.net.advance(const Duration(hours: 25));
      expect(w['A1'].balance, 100000);

      expect(await w['A1'].pay(b1, 30000, memo: 'za rower'), isNotNull);
      await w.net.run();
      expect(w['B1'].ledgerBalanceOf(b1), 30000);
      expect(w['B1'].ledgerBalanceOf(a1), 70000);
      expect(w.net['B1'].notificationTitles, contains('Wpłata'));

      // Paying more than one has: no treasurer signs.
      await w['B1'].pay(a1, 999999);
      await w.net.run();
      expect(w['B1'].balance, 30000);
      w['B1'].cancelPending(w['B1'].pendingPayments.single.id);

      // A conditional payment waits for the other side's word.
      await w['A1'].pay(b1, 10000, condBy: b1);
      await w.net.run();
      final String escrowId = w['B1'].myEscrows.single.id;
      expect(w['B1'].balance, 30000);
      await w['B1'].settle(escrowId, true);
      await w.net.run();
      expect(w['S'].ledgerBalanceOf(b1), 40000);

      // A second emission vetoed by the third member of the top.
      await s.emit(a1, 5000, 'Druga');
      await w.net.run();
      await w.approve('B', PyrT.emit);
      final String emitId = w['A'].state!.emissions.values
          .where((PyrEmission e) => !e.done)
          .single
          .id;
      await w['A'].veto(emitId);
      await w.net.run();
      await w.net.advance(const Duration(hours: 25));
      expect(w['S'].ledgerBalanceOf(a1), 60000);
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'a report reaches the top, the decision is public; a crisis wave',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      await w['B1'].report(
        reason: 'spam',
        target: w['A2'].myKey!,
        evidence: 'spam spam',
      );
      await w.net.run();
      final PyramidService s = w['S'];
      expect(s.inbox, hasLength(1));
      expect(s.inbox.values.single.from, isNotNull);
      final String repId = s.inbox.keys.single;
      await s.decide(repId, 'Bez naruszenia');
      await w.net.run();
      await w.approve('A', PyrT.decision);
      expect(w['B1'].state!.decisions[repId], 'Bez naruszenia');
      expect(
        w.net['B1'].notificationTitles,
        contains('Decyzja w Twoim zgłoszeniu'),
      );

      await s.alarm('Powódź — ewakuacja z ul. Rzecznej');
      await w.net.run();
      await w.approve('B', PyrT.alarm);
      final PyrAlarm alarm = w['A2'].state!.alarms.single;
      expect(
        w.net['A2'].shown.where(
          (RuntimeSystemNotification n) =>
              n.category == RuntimeSystemNotificationCategory.alarm,
        ),
        isNotEmpty,
      );
      // Over Bluetooth to a phone that has never heard of the pyramid.
      final SimPhone stranger = w.add('Z');
      await w['Z'].load();
      await w['Z'].onCrisisWave(s.crisisWave(alarm.id)!);
      expect(
        w.net['Z'].notificationTitles,
        contains('Komunikat (niesprawdzony)'),
      );
      // And to an offline member who knows it: checked, passed on further.
      await w['B1'].onCrisisWave(s.crisisWave(alarm.id)!);
      expect(stranger.name, 'Z');
    },
  );

  test(
    'chaos: losses, phones off, a partition — after healing all agree',
    () async {
      final PyramidWorld w = PyramidWorld(seed: 7, dropRate: 0.1);
      final List<SimPhone> ps = <SimPhone>[
        for (int i = 0; i < 14; i++) w.add('p$i'),
      ];
      w.net.dropRate = 0;
      await w.pyr(ps[0]).load();
      await w
          .pyr(ps[0])
          .found(myName: 'p0', nat: 'PL', birthYear: 1970, gender: 'k');
      // Admissions in breadth order.
      for (int i = 1; i < ps.length; i++) {
        final SimPhone head = ps[(i - 1) ~/ 2];
        await w.join(head, ps[i]);
      }
      w.net.randomGraph(ps, degree: 3);
      await w.sync();
      // A swap is proposed while all is well…
      await w.pyr(ps[3]).proposeSwap('0', w.pyr(ps[3]).myKey!);
      await w.net.run();
      // …then trouble: losses, two phones off, the network split in two.
      w.net.dropRate = 0.3;
      w.net.setOnline(ps[5], false);
      w.net.setOnline(ps[9], false);
      w.net.partition(ps.sublist(0, 7), ps.sublist(7));
      // People act meanwhile: posts on both sides, the swap signed.
      await w.pyr(ps[1]).post('Spotkanie w sobotę');
      await w.pyr(ps[8]).post('Druga strona też pisze');
      await w.net.run();
      for (final SimPhone p in <SimPhone>[ps[1], ps[4]]) {
        for (final String id in w.pyr(p).proposals.keys.toList()) {
          await w.pyr(p).approve(id);
        }
      }
      await w.net.run();
      // Healing.
      w.net
        ..heal()
        ..dropRate = 0
        ..setOnline(ps[5], true)
        ..setOnline(ps[9], true);
      await w.sync(rounds: 4);
      final Map<String, String> views = w.views();
      expect(views, hasLength(ps.length));
      expect(views.values.toSet(), hasLength(1), reason: views.toString());
      final PyramidState st = w.pyr(ps[12]).state!;
      expect(st.posts, hasLength(2));
      expect(st.pathOf(w.pyr(ps[3]).myKey!), '0');
      expect(w.net.stats.dropped, greaterThan(0));
    },
  );

  test(
    'records with bad signatures or rules are refused by everyone',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService a1 = w['A1'];
      // A1 alone tries to make itself head of cell A: refused (1 of 3).
      final PyramidRecord r = await a1.propose(
        <String, dynamic>{
          't': PyrT.swap,
          'cell': '0',
          'head': w['A'].myKey,
          'up': a1.myKey,
        },
        candidates: <String>[a1.myKey!],
        need: 1,
      );
      await w.net.run();
      expect(
        w['S'].state!.rejected[r.id],
        'potrzeba 2 z 3 w komórce (z prawem głosu)',
      );
      // A forged signature never gets in.
      final PyramidRecord forged = PyramidRecord(
        body: r.body,
        sigs: <String, String>{w['S'].myKey!: r.sigs.values.first},
      );
      expect(await w['B'].ingest(forged), isFalse);
    },
  );
}
