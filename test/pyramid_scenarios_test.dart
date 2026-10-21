import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/pyramid/pyramid_cell_chat.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import 'support/pyramid_world.dart';

/// More situations of the pyramid on the simulated network: power and its
/// limits, the structure changing, advisory referenda and new rules signed
/// by the top, money between people,
/// "Polecenie", the power key, the cells' chats.
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

      // Outside its scope the delegation is worth nothing: A2's cell
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

      // Level 1 (A), the top: 2 of 3 of the top and most of level 2.
      await s.ban(target: a, kind: 'pause', until: now() + day);
      await w.net.run();
      await w.approve('B', PyrT.ban);
      expect(
        w['A2'].state!.silencedAt(a, now()),
        isFalse,
        reason: 'level 2 has not agreed',
      );
      await w.approve('A1', PyrT.ban);
      await w.approve('B1', PyrT.ban);
      expect(w['A2'].state!.silencedAt(a, now()), isTrue);

      // Revoked, the delegation stops working from now on; what B already
      // did with it stays: B1's pause holds.
      final int bansBefore = w['S'].state!.bans.length;
      await s.revokeDelegation(d.id);
      await w.net.run();
      await w.approve('A', PyrT.revoke);
      expect(w['B'].state!.delegations[d.id]!.revoked, isTrue);
      expect(w['S'].state!.bans, hasLength(bansBefore));
      expect(w['S'].state!.silencedAt(b1, now()), isTrue);
      await w['B'].ban(
        target: b1,
        kind: 'pause',
        until: now() + 2 * day,
        via: d.id,
      );
      await w.net.run();
      expect(w['S'].state!.bans, hasLength(bansBefore));

      // A dating report ends in a dating ban the app applies.
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
      // The only one below (B1) moves up with the head above.
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

      // B (in the top) is removed by its own cell (S and A1) and most of
      // level 2 (B1, the only one there), not by anybody else.
      await w['S'].proposeRemove(w['B'].myKey!);
      await w.net.run();
      await w.approve('A1', PyrT.remove);
      expect(path('B'), '1', reason: 'level 2 has not agreed');
      await w.approve('B1', PyrT.remove);
      expect(path('B'), isNull);
      final PyramidState st = w['B1'].state!;
      expect(st.occupant.keys.toSet(), <String>{'', '0', '00'});
      final Map<String, String> views = w.views()..remove('A2');
      expect(views.values.toSet(), hasLength(1), reason: views.toString());
    },
  );

  test('an advisory referendum, the top changes the rules, then a national '
      'section leads itself', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final SimPhone b2 = w.add('B2');
    await w.join(w.net['B'], b2, nat: 'DE');
    await w.sync();
    // Everybody votes (admitted straight by a member who votes).
    await w.knowAll();
    final PyramidService s = w['S'];

    // Any question, asked by the top (2 of 3).
    await s.referendum(
      question: 'Głosowania w komórkach przez 2 dni?',
      options: <String>['Tak', 'Nie'],
      end: w.net.now + 3600 * 1000,
    );
    await w.net.run();
    await w.approve('A', PyrT.referendum);
    final PyrReferendum ref = w['B2'].state!.referenda.values.single;
    for (final String who in <String>['S', 'A', 'B', 'A1', 'A2', 'B1', 'B2']) {
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
    // Published to everybody; it changes nothing by itself.
    expect(w['B1'].state!.resultOf(ref.id), <int>[6, 1]);
    expect(w['B2'].state!.params.version, 1);

    // The top decides: new rules, 2 of 3, public at once, in force a day
    // later.
    await s.changeRules(<String, dynamic>{'electionHours': 48});
    await w.net.run();
    await w.approve('B', PyrT.constitution);
    expect(w['B2'].state!.paramsChanges.values.single.done, isFalse);
    expect(w['B2'].state!.params.electionHours, 72);
    await w.net.advance(const Duration(milliseconds: kPyrParamsDelayMs));
    await w.net.advance(const Duration(minutes: 2));
    final PyramidState st = w['B2'].state!;
    expect(st.params.version, 2);
    expect(st.params.electionHours, 48);

    // No minimum number of people: the highest of a nationality leads.
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
    // The section's own alarm, without the top (a referendum is the
    // top's alone).
    await w['B1'].alarm('Hochwasser', scopeKind: 'nat', scopeNat: 'DE');
    await w.net.run();
    expect(w['S'].state!.alarms.single.scopeNat, 'DE');
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('the paid inbox and a free reshare between members', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String a1 = w['A1'].myKey!;
    final String b1 = w['B1'].myKey!;

    await w.fund('A1', 100000);

    await w['B1'].setOffers(<String, int>{'inbox': 500, 'reshare': 0});
    await w.net.run();
    expect(w['A1'].priceOf(b1, 'inbox'), 500);
    expect(await w['A1'].sendMarket(b1, 'inbox', 'Masz chwilę?'), isTrue);
    await w.net.run();
    final PyrMarketMessage got = w['B1'].market.values.single;
    expect(got.amount, 500);
    expect(w['B1'].balance, 0, reason: 'held until B1 answers');
    await w['B1'].answerMarket(got.id, accept: true);
    await w.net.run();
    expect(w['S'].ledgerBalanceOf(b1), 500);
    expect(w['S'].ledgerBalanceOf(a1), 99500);

    // A reshare on order: A1's own signed public post, which B1
    // sees before deciding and shares with B1's friends; paid after.
    final MemorySignalTransport transport = MemorySignalTransport();
    await transport.start();
    final LedgerNode ledger = LedgerNode(
      transport: transport,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(ledger.stop);
    await ledger.start();
    final LogEntry post = await ledger.publish(
      kPostKind,
      newPostBody('Sprzedam rower'),
    );
    final LogEntry secret = await ledger.publish(
      kPostKind,
      newPostBody('Tylko dla znajomych', audience: Audience.all),
    );
    expect(
      await w['A1'].sendMarket(
        b1,
        'reshare',
        '',
        post: secret.toCertifiedJson(),
      ),
      isFalse,
      reason: 'only a public post can be reshared',
    );
    await w['B1'].setOffers(<String, int>{'inbox': 500, 'reshare': 300});
    await w.net.run();
    expect(
      await w['A1'].sendMarket(b1, 'reshare', '', post: post.toCertifiedJson()),
      isTrue,
    );
    await w.net.run();
    final PyrMarketMessage reshare = w['B1'].market.values.firstWhere(
      (PyrMarketMessage m) => m.kind == 'reshare',
    );
    expect(reshare.text, 'Sprzedam rower', reason: 'the preview');
    expect(reshare.amount, 300);
    await w['B1'].answerMarket(reshare.id, accept: true);
    await w.net.run();
    expect(LogEntry.fromJson(w.reshared['B1']!.single)!.id, post.id);
    expect(w['S'].ledgerBalanceOf(b1), 800);
    expect(
      w['A2'].state!.posts,
      isEmpty,
      reason: 'a reshare goes to friends, not to the branch',
    );
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('"Polecenie": a full head still brings people in, to a place it picks; '
      'the newcomer votes once known in the cell or after 14 days', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidService s = w['S'];
    // S has A and B right under it, and no limit: nearest the top first.
    expect(s.freePlaces().take(3), <String>['11', '000', '001']);
    final SimPhone ola = w.add('Ola');
    await w.recommend(w.net['S'], ola, slot: '000');
    await w.sync();
    final String o = w['Ola'].myKey!;
    PyramidState st = w['B1'].state!;
    expect(st.pathOf(o), '000', reason: 'under A1, the place S picked');
    expect(st.members[o]!.admittedBy, s.myKey, reason: 'S vouches');
    expect(w['Ola'].isMember, isTrue);
    expect(st.canVote(o, w.net.now), isFalse, reason: 'nobody knows her');
    // Her cell's head confirms they know each other: she votes.
    expect(await w['A2'].confirmKnown(o), isNull, reason: 'another cell');
    await w['A1'].confirmKnown(o);
    await w.net.run();
    await w.sync();
    st = w['B1'].state!;
    expect(st.canVote(o, w.net.now), isTrue);
    expect(st.knownByOf(o), <String>[w['A1'].myKey!]);

    // Jan, by default nearest the top (under B): votes after 14 days.
    final SimPhone jan = w.add('Jan');
    await w.recommend(w.net['S'], jan);
    await w.sync();
    final String j = w['Jan'].myKey!;
    expect(w['S'].state!.pathOf(j), '11');
    expect(w['S'].state!.canVote(j, w.net.now), isFalse);
    await w.net.advance(const Duration(days: 15));
    expect(w['S'].state!.canVote(j, w.net.now), isTrue);
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('the power key follows the head: the old key hands it over', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidService s = w['S'];
    final String first = s.state!.powerKey!;
    expect(first, s.root!.powerKey);
    expect(s.holdsPowerKey, isTrue);
    // A and B make A the head of the pyramid: a swap at the top.
    await w['A'].proposeSwap('', w['A'].myKey!);
    await w.net.run();
    await w.approve('B', PyrT.swap);
    await w.sync();
    expect(w['B'].state!.head, w['A'].myKey);
    expect(w['B'].state!.handoverDue, isTrue);
    // A's app makes a new key and asks; S's app signs with the old one.
    await w.duties(rounds: 2);
    await w.sync();
    final PyramidState st = w['B1'].state!;
    expect(st.handoverDue, isFalse);
    expect(st.powerHead, w['A'].myKey);
    expect(st.powerKey, isNot(first));
    expect(w['A'].holdsPowerKey, isTrue);
    expect(w['S'].holdsPowerKey, isFalse);
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('the old head away: most of the top hands the power key over after '
      '72 h, not sooner', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String first = w['S'].state!.powerKey!;
    await w['A'].proposeSwap('', w['A'].myKey!);
    await w.net.run();
    await w.approve('B', PyrT.swap);
    await w.sync();
    // S is gone (its messages are lost).
    w.net.holdForOffline = false;
    w.net.setOnline(w.net['S'], false);
    await w.duties(rounds: 2);
    expect(w['B'].state!.powerKey, first, reason: 'B may not sign yet');
    await w.net.advance(const Duration(hours: 73));
    await w.duties(rounds: 2);
    await w.sync();
    final PyramidState st = w['B1'].state!;
    expect(st.powerHead, w['A'].myKey);
    expect(st.powerKey, isNot(first));
    expect(w['A'].holdsPowerKey, isTrue);
  });

  test('each cell has a group chat: the same for its members, following '
      'the cell', () async {
    final PyramidWorld w = await PyramidWorld.six();
    Map<String, PyrCellChat> chats(String who) =>
        pyramidCellChats(w[who].state!, w[who].myKey!, w.net[who].address);
    expect(chats('S'), hasLength(1), reason: 'the top cell');
    expect(chats('A'), hasLength(2), reason: 'the top and its own');
    expect(chats('A1'), hasLength(1));
    final String cellA = chats('A1').keys.single;
    expect(chats('A').keys, contains(cellA));
    expect(chats('A2').keys, <String>[cellA]);
    final PyramidState st = w['A1'].state!;
    expect(
      chats('A1')[cellA]!.members,
      containsAll(<String>[
        st.members[w['A'].myKey]!.addr,
        st.members[w['A2'].myKey]!.addr,
      ]),
    );
    expect(chats('B1').keys.single, isNot(cellA));
    // A1 becomes the head of A's cell: the same chat, new name.
    await w['A1'].proposeSwap('0', w['A1'].myKey!);
    await w.net.run();
    await w.approve('A2', PyrT.swap);
    await w.sync();
    expect(chats('A2').keys, <String>[cellA]);
    expect(chats('A2')[cellA]!.name, contains('A1'));
  });
}
