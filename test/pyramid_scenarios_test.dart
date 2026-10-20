import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// More situations of the pyramid on the simulated network: power and its
/// limits, the structure changing, the constitution, money between people,
/// joining two pyramids.
void main() {
  const int day = 24 * 3600 * 1000;

  test(
    'delegation in scope, immunity of the higher levels, revoke, dating ban',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService s = w['S'];
      final String b1 = w['B1'].myKey!;
      final String a2 = w['A2'].myKey!;
      final String a = w['A'].myKey!;
      int now() => w.net.now;

      await s.delegate(
        to: w['B'].myKey!,
        power: 'pause',
        scope: '1',
        until: now() + 30 * day,
      );
      await w.net.run();
      await w.approve('A', PyrT.delegate);
      final PyrDelegation d = w['B1'].state!.delegations.values.single;
      expect(d.scope, '1');

      // B pauses B1 in its own branch, alone (B is all of B1's own cell).
      await w['B'].ban(
        target: b1,
        kind: 'pause',
        until: now() + day,
        via: d.id,
        reason: 'spam',
      );
      await w.net.run();
      expect(w['S'].state!.silencedAt(b1, now()), isTrue);
      await w['B1'].post('Hej');
      await w.net.run();
      expect(
        w['S'].state!.posts,
        isEmpty,
        reason: 'a paused person does not post',
      );

      // Outside its scope the delegation is worth nothing: A2's cell (A1)
      // agrees, A says no — and B alone is not the top.
      await w['B'].ban(
        target: a2,
        kind: 'pause',
        until: now() + day,
        via: d.id,
      );
      await w.net.run();
      for (final String id in w['A'].proposals.keys.toList()) {
        await w['A'].reject(id);
      }
      await w.approveAll('A1');
      expect(w['S'].state!.silencedAt(a2, now()), isFalse);

      // The top on A2 (level 2): 2 of the top AND 2 of A2's own cell.
      await s.ban(target: a2, kind: 'pause', until: now() + day);
      await w.net.run();
      await w.approve('B', PyrT.ban);
      expect(
        w['S'].state!.silencedAt(a2, now()),
        isFalse,
        reason: 'immunity: the cell has not agreed',
      );
      await w.approve('A', PyrT.ban);
      expect(
        w['S'].state!.silencedAt(a2, now()),
        isFalse,
        reason: 'one of the cell is not enough',
      );
      await w.approve('A1', PyrT.ban);
      expect(w['B1'].state!.silencedAt(a2, now()), isTrue);

      // Level 1 (A): A's own cell is the rest of the top, 2 of 3 do it.
      await s.ban(target: a, kind: 'pause', until: now() + day);
      await w.net.run();
      await w.approve('B', PyrT.ban);
      expect(w['A2'].state!.silencedAt(a, now()), isTrue);

      // Revoked, the delegation stops working.
      final int bansBefore = w['S'].state!.bans.length;
      await s.topDecision(<String, dynamic>{'t': PyrT.revoke, 'd': d.id});
      await w.net.run();
      await w.approve('A', PyrT.revoke);
      expect(w['B'].state!.delegations[d.id]!.revoked, isTrue);
      await w['B'].ban(
        target: b1,
        kind: 'pause',
        until: now() + 2 * day,
        via: d.id,
      );
      await w.net.run();
      expect(w['S'].state!.bans, hasLength(bansBefore));

      // A dating report ends in a dating ban the app applies (§19.6).
      await w['A2'].report(
        reason: 'harass',
        target: b1,
        evidence: 'zrzut',
        datingKey: 'dk-b1',
      );
      await w.net.run();
      final String rep = s.inbox.keys.single;
      await s.decide(
        rep,
        'Nękanie w randkach',
        banKind: 'dating',
        until: now() + 90 * day,
      );
      await w.net.run();
      await w.approveAll('B');
      expect(w['A1'].state!.bannedDatingKeys(now()), contains('dk-b1'));
      expect(w['A1'].state!.decisions[rep], 'Nękanie w randkach');
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'migrate, leave and fill, absence after 60 days, removal by the cell',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      String? path(String who) => w['S'].state!.pathOf(w[who].myKey!);

      // B1 moves under A1 (both sign).
      await w['B1'].proposeMigrate(w['A1'].myKey!);
      await w.net.run();
      await w.approve('A1', PyrT.migrate);
      expect(path('B1'), '000');

      // A leaves; the two under A agree that A1 moves up.
      await w['A'].leave();
      await w.net.run();
      expect(w['S'].state!.vacant, contains('0'));
      await w['A1'].proposeFill('0', w['A1'].myKey!);
      await w.net.run();
      await w.approve('A2', PyrT.fill);
      expect(path('A1'), '0');
      expect(w['S'].state!.vacant, contains('00'), reason: 'B1 is still below');
      // The only one below (B1) moves up with the head above (A1).
      await w['B1'].proposeFill('00', w['B1'].myKey!);
      await w.net.run();
      await w.approve('A1', PyrT.fill);
      expect(path('B1'), '00');

      // A2 goes silent: after 60 days two neighbours free the place.
      w.net.setOnline(w.net['A2'], false);
      await w.net.advance(const Duration(days: 61));
      await w['A1'].proposeAbsent(w['A2'].myKey!);
      await w.net.run();
      await w.approve('B1', PyrT.absent);
      expect(path('A2'), isNull);
      expect(w['S'].state!.members[w['A2'].myKey!]!.active, isFalse);

      // B is removed by its own cell (S and A1), not by anybody else.
      await w['S'].proposeRemove(w['B'].myKey!);
      await w.net.run();
      await w.approve('A1', PyrT.remove);
      expect(path('B'), isNull);
      final PyramidState st = w['B1'].state!;
      expect(st.occupant.keys.toSet(), <String>{'', '0', '00'});
      final Map<String, String> views = w.views()..remove('A2');
      expect(views.values.toSet(), hasLength(1), reason: views.toString());
    },
  );

  test(
    'constitution by referendum, then a national section leads itself',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final SimPhone b2 = w.add('B2');
      await w.join(w.net['B'], b2, nat: 'DE');
      await w.sync();
      // Votes count from members met in person by 2 others (§20.6).
      await w.meetAll();
      final PyramidService s = w['S'];

      // New rules need at least 72 h of voting (§21.7); asked for 1 h, the
      // app makes it 4 days.
      final int asked = w.net.now;
      await s.referendum(
        question: 'Sekcje narodowe od 1 osoby?',
        options: <String>['Tak', 'Nie'],
        end: w.net.now + 3600 * 1000,
        kind: 'constitution',
        params: <String, dynamic>{'version': 2, 'nationalMin': 1},
      );
      await w.net.run();
      await w.approve('A', PyrT.referendum);
      final PyrReferendum ref = w['B2'].state!.referenda.values.single;
      expect(ref.end - asked, greaterThanOrEqualTo(kPyrMinConstitutionMs));
      for (final String who in <String>[
        'S',
        'A',
        'B',
        'A1',
        'A2',
        'B1',
        'B2',
      ]) {
        expect(
          await w[who].voteReferendum(ref.id, who == 'A2' ? 1 : 0),
          isTrue,
          reason: who,
        );
      }
      await w.net.run();
      await w.net.advance(
        Duration(milliseconds: ref.end - w.net.now + 60 * 1000),
      );
      await w.duties();
      expect(w['B1'].state!.resultOf(ref.id), <int>[6, 1]);
      // Too early: the new rules wait until the sums had time to come up.
      await s.topDecision(<String, dynamic>{
        't': PyrT.constitution,
        'ref': ref.id,
      });
      await w.net.run();
      await w.approve('B', PyrT.constitution);
      expect(w['B2'].state!.params.version, 1);
      await w.net.advance(const Duration(milliseconds: kPyrTallyGraceMs));
      await s.topDecision(<String, dynamic>{
        't': PyrT.constitution,
        'ref': ref.id,
      });
      await w.net.run();
      await w.approve('B', PyrT.constitution);
      final PyramidState st = w['B2'].state!;
      expect(st.params.version, 2);
      expect(st.params.nationalMin, 1);

      // DE: B1 and B2 are on the same level; the earlier place leads.
      expect(st.nationalLead('DE'), w['B1'].myKey);
      expect(st.nationalLead('PL'), w['S'].myKey);
      final PyramidRecord? np = await w['B1'].natPost('Hallo zusammen');
      await w.net.run();
      expect(w['A1'].state!.natPosts.keys, contains(np!.id));
      await w['B2'].comment(np.id, 'Gerne');
      await w['A1'].comment(np.id, 'Ja też');
      await w.net.run();
      expect(
        w['S'].state!.natPosts[np.id]!.comments.map((PyrComment c) => c.text),
        <String>['Gerne'],
      );
      // The section's own referendum and alarm, without the top.
      await w['B1'].referendum(
        question: 'Treffen in Berlin?',
        options: <String>['Ja', 'Nein'],
        end: w.net.now + day,
        scopeKind: 'nat',
        scopeNat: 'DE',
      );
      await w['B1'].alarm('Hochwasser', scopeKind: 'nat', scopeNat: 'DE');
      await w.net.run();
      expect(
        w['S'].state!.referenda.values.where(
          (PyrReferendum r) => r.scopeNat == 'DE',
        ),
        hasLength(1),
      );
      expect(w['S'].state!.alarms.single.scopeNat, 'DE');
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test('the paid inbox and a free reshare between members', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidService s = w['S'];
    final String a1 = w['A1'].myKey!;
    final String b1 = w['B1'].myKey!;

    await s.emit(a1, 100000, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));

    await w['B1'].setOffers(<String, int>{'inbox': 500, 'reshare': 0});
    await w.net.run();
    expect(w['A1'].priceOf(b1, 'inbox'), 500);
    expect(await w['A1'].sendMarket(b1, 'inbox', 'Masz chwilę?'), isTrue);
    await w.net.run();
    final PyrMarketMessage got = w['B1'].market.values.single;
    expect(got.amount, 500);
    expect(w['B1'].state!.balanceOf(b1), 0, reason: 'held until B1 answers');
    await w['B1'].answerMarket(got.id, accept: true);
    await w.net.run();
    expect(w['S'].state!.balanceOf(b1), 500);
    expect(w['S'].state!.balanceOf(a1), 99500);

    // A free reshare: accepted, B1 posts it to its branch.
    expect(await w['A1'].sendMarket(b1, 'reshare', 'Sprzedam rower'), isTrue);
    await w.net.run();
    final PyrMarketMessage reshare = w['B1'].market.values.firstWhere(
      (PyrMarketMessage m) => m.kind == 'reshare',
    );
    await w['B1'].answerMarket(reshare.id, accept: true);
    await w.net.run();
    expect(w['A2'].state!.posts.values.single.text, 'Sprzedam rower');
    expect(w.views().values.toSet(), hasLength(1));
  });

  test(
    'a small pyramid joins a bigger one as a branch, the old one closes',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String ruch = w['S'].current!;
      final SimPhone t = w.add('T');
      final SimPhone t1 = w.add('T1');
      final SimPhone t2 = w.add('T2');
      await w.pyr(t).load();
      final String small = await w
          .pyr(t)
          .createPyramid(
            name: 'Mała',
            myName: 'T',
            nat: 'PL',
            birthYear: 1985,
            gender: 'k',
          );
      await w.join(t, t1);
      await w.join(t, t2);
      // T knows A1, and gets the bigger pyramid from A1 to look at.
      w.net.befriend(t, w.net['A1']);
      await w.sync();
      expect(await w['T'].fetchFriendsPyramids(), 1);
      await w.net.run();
      expect(w['T'].knownPyramids, containsAll(<String>[ruch, small]));

      final String a1 = w['A1'].myKey!;
      await w['T'].proposeMerge(ruch, a1, w['S'].state!.members[a1]!.addr);
      await w.net.run();
      await w.approve('T1', PyrT.merge);
      expect(
        w['S'].state!.members,
        hasLength(6),
        reason: 'A1 has not agreed yet',
      );
      await w.approve('A1', PyrT.merge);
      await w.sync();
      final PyramidState big = w['S'].state!;
      expect(big.members, hasLength(9));
      expect(big.pathOf(w['T'].myKey!), '000');
      expect(
        <String?>{big.pathOf(w['T1'].myKey!), big.pathOf(w['T2'].myKey!)},
        <String>{'0000', '0001'},
      );

      // The old top closes the small pyramid; everybody lives in the big one.
      await w.approve('T1', PyrT.merged);
      await w.sync();
      expect(w['T2'].stateOf(small)!.mergedInto, ruch);
      for (final String who in <String>['T', 'T1', 'T2']) {
        expect(w[who].current, ruch, reason: who);
      }
      expect(w.views().values.toSet(), hasLength(1));
    },
  );
}
