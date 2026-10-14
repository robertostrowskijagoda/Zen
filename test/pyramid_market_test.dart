import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// Money in the pyramid beyond plain transfers (§24) and moving a
/// whole branch (§20.4), on the simulated network.
void main() {
  /// Emits [amount] to [who] (S proposes, B signs) and waits the 24 h.
  Future<void> fund(PyramidWorld w, String who, int amount) async {
    await w['S'].emit(w[who].myKey!, amount, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
  }

  test(
    'market prices by acquaintance: the receiver decides the level',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final SimPhone z = w.add('Z');
      await w.join(w.net['A1'], z);
      await w.sync();
      final String b1 = w['B1'].myKey!;
      final String zKey = w['Z'].myKey!;
      await fund(w, 'A', 10000);
      await fund(w, 'Z', 10000);

      await w['B1'].setOffers(
        const <String, int>{'reshare': 50},
        levels: const <String, Map<String, int>>{
          'inbox': <String, int>{'friend': 0, 'fof': 200, 'stranger': 1000},
        },
      );
      await w.net.run();
      final PyramidState st = w['S'].state!;
      // A price the same for everybody; a priced-by-level kind shows its top.
      expect(st.priceFor(b1, 'reshare', 'friend'), 50);
      expect(w['A'].priceOf(b1, 'inbox'), 1000);
      expect(st.priceFor(b1, 'inbox', 'fof'), 200);

      // A2 is B1's friend: free. A is a friend of a friend: 200.
      expect(w['A2'].priceToSend(b1, 'inbox'), (price: 0, level: 'friend'));
      expect(w['A'].priceToSend(b1, 'inbox'), (price: 200, level: 'fof'));
      // Z's friends do not know B1: Z cannot tell and pays the most.
      expect(w['Z'].priceToSend(b1, 'inbox'), (price: 1000, level: null));

      expect(await w['A2'].sendMarket(b1, 'inbox', 'Cześć!'), isTrue);
      expect(await w['A'].sendMarket(b1, 'inbox', 'Masz chwilę?'), isTrue);
      expect(await w['Z'].sendMarket(b1, 'inbox', 'Dzień dobry'), isTrue);
      await w.net.run();
      final Map<String, PyrMarketMessage> got = <String, PyrMarketMessage>{
        for (final PyrMarketMessage m in w['B1'].market.values) m.text: m,
      };
      expect(got['Cześć!']!.amount, 0);
      expect(got['Cześć!']!.level, 'friend');
      expect(got['Masz chwilę?']!.amount, 200);
      expect(got['Masz chwilę?']!.level, 'fof');
      expect(got['Dzień dobry']!.amount, 1000);
      expect(got['Dzień dobry']!.level, 'stranger');

      // Z claims friendship B1 does not see (one-sided): it pays the friend
      // price, B1 counts a stranger — the message is refused, money back.
      await w['B1'].setOffers(
        const <String, int>{},
        levels: const <String, Map<String, int>>{
          'inbox': <String, int>{'friend': 100, 'fof': 200, 'stranger': 1000},
        },
      );
      await w.net.run();
      // Z's own payment of 1000 still waits for B1's answer: B1 returns it.
      await w['B1'].answerMarket(got['Dzień dobry']!.id, accept: false);
      await w.sync();
      expect(w['Z'].state!.balanceOf(zKey), 10000);
      z.friendSet.add(w.net['B1'].address);
      expect(w['Z'].priceToSend(b1, 'inbox').price, 100);
      expect(
        await w['Z'].sendMarket(b1, 'inbox', 'Jesteśmy znajomymi'),
        isTrue,
      );
      await w.net.run();
      await w.sync();
      expect(
        w['B1'].market.values.where(
          (PyrMarketMessage m) => m.text == 'Jesteśmy znajomymi',
        ),
        isEmpty,
      );
      expect(
        w['S'].state!.balanceOf(zKey),
        10000,
        reason: 'the short payment went back',
      );
      expect(w['S'].state!.balanceOf(b1), 0);
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'an announcement through three intermediaries, each keeps a share',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String a1 = w['A1'].myKey!;
      final String a = w['A'].myKey!;
      final String s = w['S'].myKey!;
      final String b = w['B'].myKey!;
      await fund(w, 'A1', 10000);
      await w['A'].setOffers(const <String, int>{'ad': 300});
      await w['B'].setOffers(const <String, int>{'ad': 300});
      await w.net.run();

      // 3 steps × 500, paid up front, conditionally, to A.
      expect(
        await w['A1'].sendMarket(
          a,
          'ad',
          'Szukam mieszkania na Żoliborzu',
          steps: 3,
          share: 500,
        ),
        isTrue,
      );
      await w.net.run();
      expect(w['S'].state!.balanceOf(a1), 8500);
      final PyrMarketMessage atA = w['A'].market.values.single;
      expect(atA.amount, 500);
      expect(atA.hops, 2);

      // A accepts the text and passes it on to S; S on to B; B is the last.
      await w['A'].answerMarket(atA.id, accept: true, next: s);
      await w.net.run();
      final PyrMarketMessage atS = w['S'].market.values.single;
      expect(atS.origin, a1);
      expect(atS.from, a);
      expect(atS.hops, 1);
      await w['S'].answerMarket(atS.id, accept: true, next: b);
      await w.net.run();
      final PyrMarketMessage atB = w['B'].market.values.single;
      expect(atB.hops, 0);
      expect(atB.amount, 500);
      await w['B'].answerMarket(atB.id, accept: true);
      await w.sync();
      PyramidState st = w['B1'].state!;
      expect(st.balanceOf(a), 500);
      expect(st.balanceOf(s), 500);
      expect(st.balanceOf(b), 500);
      expect(st.balanceOf(a1), 8500);
      // Each one posted it to their branch.
      expect(
        st.posts.values.where(
          (PyrPost p) => p.text == 'Szukam mieszkania na Żoliborzu',
        ),
        hasLength(3),
      );

      // Again, 3 × 400: A passes on to S, S says no — the rest goes back to
      // the payer, A keeps its share.
      expect(
        await w['A1'].sendMarket(a, 'ad', 'Oddam rower', steps: 3, share: 400),
        isTrue,
      );
      await w.net.run();
      final PyrMarketMessage second = w['A'].market.values.firstWhere(
        (PyrMarketMessage m) => m.text == 'Oddam rower',
      );
      await w['A'].answerMarket(second.id, accept: true, next: s);
      await w.net.run();
      final PyrMarketMessage refuse = w['S'].market.values.firstWhere(
        (PyrMarketMessage m) => m.text == 'Oddam rower',
      );
      await w['S'].answerMarket(refuse.id, accept: false);
      await w.sync();
      st = w['B1'].state!;
      expect(st.balanceOf(a), 900);
      expect(st.balanceOf(a1), 8100);

      // A third one: A tries to change the text on the way; S sees the
      // payment's text hash does not match, refuses, the rest goes back.
      expect(
        await w['A1'].sendMarket(
          a,
          'ad',
          'Korepetycje z matematyki',
          steps: 2,
          share: 400,
        ),
        isTrue,
      );
      await w.net.run();
      final PyrMarketMessage third = w['A'].market.values.firstWhere(
        (PyrMarketMessage m) => m.text == 'Korepetycje z matematyki',
      );
      final PyramidRecord? hop = await w['A'].settle(
        third.payment!,
        true,
        next: s,
      );
      await w.sync();
      expect(w['S'].state!.escrows[hop!.id]!.to, s);
      await w.net['A'].send(w.net['S'].address, <String, dynamic>{
        'type': PyramidTypes.dm,
        'id': 'podmiana',
        'k': 'ad',
        'f': a,
        't': 'Kupię głosy',
        'x': hop.id,
        'a': 400,
        'h': 0,
        'o': a1,
      });
      await w.net.run();
      await w.sync();
      expect(w['S'].market.containsKey('podmiana'), isFalse);
      st = w['B1'].state!;
      expect(st.balanceOf(a), 1300);
      expect(st.balanceOf(a1), 7700);
      expect(st.escrows[hop.id]!.settled, isFalse);
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'moving with the whole branch needs the whole cell; a leaf just moves',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      String? path(String who) => w['S'].state!.pathOf(w[who].myKey!);

      // A moves under B with A1 and A2.
      await w['A'].proposeMigrate(w['B'].myKey!, branch: true);
      await w.net.run();
      await w.approve('B', PyrT.migrate);
      await w.approve('A1', PyrT.migrate);
      expect(path('A'), '0', reason: 'A2 has not agreed yet');
      await w.approve('A2', PyrT.migrate);
      await w.sync();
      expect(path('A'), '11');
      expect(path('A1'), '110');
      expect(path('A2'), '111');
      final PyramidState st = w['B1'].state!;
      expect(st.occupant.containsKey('0'), isFalse);
      expect(st.vacant, isEmpty, reason: 'nothing is left behind');
      expect(st.history.last.text, contains('z całą gałęzią'));

      // B1 has nobody below: "with the branch" is an ordinary move (into the
      // place A's branch left).
      await w['B1'].proposeMigrate(w['S'].myKey!, branch: true);
      await w.net.run();
      await w.approve('S', PyrT.migrate);
      await w.sync();
      expect(path('B1'), '0');
      expect(w.views().values.toSet(), hasLength(1));
    },
  );
}
