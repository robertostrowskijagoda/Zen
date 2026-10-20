import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/pyramid_world.dart';

/// The pyramid's people side, on the simulated network: admission only at
/// "Znajomy" (§20.2), reports climbing level by level with the signed
/// original (§21.4, S36), the paid introduction settled by the person
/// introduced (§24), the reach of posts and the anonymous statistics
/// summed up the tree (§22.1a, §20.2a), the badge (§20.2a).
void main() {
  Future<void> fund(PyramidWorld w, String who, int amount) async {
    await w['S'].emit(w[who].myKey!, amount, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
  }

  Future<LogEntry> signedPost(String text) async {
    final LedgerKeyPair account = await LedgerKeyPair.generate();
    final LedgerKeyPair device = await LedgerKeyPair.generate();
    final DeviceCertificate cert = await DeviceCertificate.issue(
      account: account,
      device: device.id,
      name: 'tel',
      issued: 1,
    );
    return LogEntry.create(
      deviceKey: device,
      certificate: cert,
      space: 'feed/${account.id}',
      writer: 'a' * 32,
      seq: 1,
      prev: '',
      hlc: const Hlc(1700000000000, 0),
      kind: 'post',
      body: <String, dynamic>{'text': text},
    );
  }

  test('a newcomer is admitted only at the level "Znajomy" (§20.2)', () async {
    final PyramidWorld w = PyramidWorld();
    final Map<String, FriendLevel> levels = <String, FriendLevel>{};
    final SimPhone s = w.add(
      'S',
      friendLevelOf: (String a) => levels[PeerShareCodec.normalizeAddress(a)],
    );
    await w.pyr(s).load();
    await w
        .pyr(s)
        .createPyramid(
          name: 'Ruch',
          myName: 'S',
          nat: 'PL',
          birthYear: 1980,
          gender: 'm',
        );
    expect(w['S'].state!.params.rules, kPyrRules);
    final SimPhone z = w.add('Z');
    w.net.befriend(s, z);
    await w.pyr(z).load();
    await w
        .pyr(z)
        .askToJoin(
          invite: w['S'].inviteCode()!,
          myName: 'Z',
          nat: 'PL',
          birthYear: 1995,
          gender: 'k',
        );
    await w.net.run();
    final PyrProposal p = w['S'].proposals.values.single;
    final String zAddr = PeerShareCodec.normalizeAddress(z.address);

    // Level unknown, then "Słaby znajomy": the head cannot sign.
    expect(w['S'].admitProblem(p), isNotNull);
    levels[zAddr] = FriendLevel.weak;
    expect(w['S'].admitProblem(p), contains('Znajomy'));
    await w['S'].approve(p.record.id);
    await w.net.run();
    expect(w['S'].state!.members, hasLength(1));
    expect(w['S'].proposals, contains(p.record.id), reason: 'still waiting');

    levels[zAddr] = FriendLevel.friend;
    expect(w['S'].admitProblem(p), isNull);
    await w['S'].approve(p.record.id);
    await w.net.run();
    expect(w['S'].state!.isMember(w['Z'].myKey!), isTrue);
  });

  test('a report climbs level by level to the top (§21.4)', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final int until = w.net.now + 90 * 24 * 3600 * 1000;
    // Reports of A's branch: A2; of the whole pyramid: B1.
    await w['S'].delegate(
      to: w['A2'].myKey!,
      power: 'reports',
      scope: '0',
      until: until,
    );
    await w['S'].delegate(to: w['B1'].myKey!, power: 'reports', until: until);
    await w.net.run();
    await w.approveAll('B', PyrT.delegate);
    await w.sync();
    expect(w['A1'].state!.delegations, hasLength(2));

    final PyrReport r = await w['A1'].report(
      reason: 'spam',
      target: w['B'].myKey!,
      evidence: 'Kup tanio',
    );
    await w.net.run();
    expect(w['A2'].inbox.keys, contains(r.id));
    expect(w['B1'].inbox, isEmpty);
    expect(w['S'].inbox, isEmpty);

    // No decision for 48 h: the next wider branch.
    await w.net.advance(const Duration(hours: 49));
    await w.duties();
    expect(w['B1'].inbox.keys, contains(r.id));
    expect(w['S'].inbox, isEmpty, reason: 'not yet the top');

    await w.net.advance(const Duration(hours: 49));
    await w.duties();
    expect(w['S'].inbox.keys, contains(r.id));
    expect(w['A1'].myReports[r.id]!.escalated, isTrue);
  });

  test(
    'a report carries the signed original; the ban names the entry (S36)',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final LogEntry post = await signedPost('Kup tanio!!!');
      final PyrReport good = await w['A1'].report(
        reason: 'spam',
        target: w['B1'].myKey!,
        evidence: 'Kup tanio!!!',
        contentHash: contentHash('Kup tanio!!!'),
        entryId: post.id,
        entry: post.toJson(),
      );
      // Changed text under the old signature: kept without the "original".
      final Map<String, dynamic> forged = post.toJson()
        ..['body'] = <String, dynamic>{'text': 'Coś innego'};
      final PyrReport bad = await w['A1'].report(
        reason: 'spam',
        target: w['B1'].myKey!,
        evidence: 'Coś innego',
        entry: forged,
      );
      await w.net.run();
      final PyrReport inGood = w['S'].inbox[good.id]!;
      expect(inGood.entry, isNotNull);
      expect(inGood.entryId, post.id);
      final PyrReport inBad = w['S'].inbox[bad.id]!;
      expect(inBad.entry, isNull);
      expect(inBad.entryId, isNull);

      await w['S'].decide(good.id, 'Ban treści', banKind: 'content');
      await w.net.run();
      await w.approveAll('B');
      await w.sync();
      final PyramidState st = w['A2'].state!;
      final int now = w.net.now;
      expect(st.bannedEntries(now), contains(post.id));
      // The hash stays for 1.10.0 phones.
      expect(st.bannedContent(now), contains(contentHash('Kup tanio!!!')));
    },
  );

  test(
    'a paid introduction is settled when the introduced person accepts (§24)',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String a1 = w['A1'].myKey!;
      final String a2 = w['A2'].myKey!;
      final String b1 = w['B1'].myKey!;
      await fund(w, 'A1', 10000);
      await w['B1'].setOffers(const <String, int>{'intro': 300});
      await w.net.run();

      expect(
        await w['A1'].sendMarket(
          b1,
          'intro',
          'Przedstaw mnie, proszę',
          introduce: a2,
        ),
        isTrue,
      );
      await w.net.run();
      final PyrMarketMessage atB1 = w['B1'].market.values.single;
      expect(atB1.introduce, a2);
      expect(atB1.amount, 300);
      await w['B1'].answerMarket(atB1.id, accept: true);
      await w.net.run();
      expect(
        w['S'].state!.balanceOf(b1),
        0,
        reason: 'the intermediary waits for the person introduced',
      );
      final PyrMarketMessage atA2 = w['A2'].market.values.single;
      expect(atA2.origin, a1);
      expect(atA2.from, b1);
      await w['A2'].answerMarket(atA2.id, accept: true);
      await w.net.run();
      expect(w['S'].state!.balanceOf(b1), 300);
      expect(w['S'].state!.balanceOf(a1), 9700);

      // Refused by the person introduced: the money goes back.
      await w.duties();
      expect(
        await w['A1'].sendMarket(b1, 'intro', 'Jeszcze raz', introduce: a2),
        isTrue,
      );
      await w.net.run();
      final PyrMarketMessage again = w['B1'].market.values.firstWhere(
        (PyrMarketMessage m) => m.text == 'Jeszcze raz',
      );
      await w['B1'].answerMarket(again.id, accept: true);
      await w.net.run();
      final PyrMarketMessage no = w['A2'].market.values.firstWhere(
        (PyrMarketMessage m) => m.text == 'Jeszcze raz',
      );
      await w['A2'].answerMarket(no.id, accept: false);
      await w.net.run();
      expect(w['S'].state!.balanceOf(a1), 9700);
      expect(w['S'].state!.balanceOf(b1), 300);
      await w.sync();
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'reach of a post and anonymous statistics come up the tree (§22.1a, §20.2a)',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidRecord? post = await w['A'].post('Spotkanie w sobotę');
      await w.net.run();
      await w.sync();
      expect(w['A1'].state!.posts.keys, contains(post!.id));
      w['A1'].markRead(<String>[post.id]);
      await w.duties();
      expect(w['A'].reachOf(post.id), (got: 2, read: 1));
      expect(w['A1'].reachOf(post.id), isNull, reason: 'only the author');

      // Six people: S a man born 1980, the others women born 1990.
      final List<int> stats = w['S'].branchStats()!;
      expect(stats.fold(0, (int a, int b) => a + b), 6);
      expect(stats.sublist(0, 4).fold(0, (int a, int b) => a + b), 5);
      expect(stats.sublist(4, 8).fold(0, (int a, int b) => a + b), 1);
      // A branch of three is too small to show.
      expect(w['A'].branchStats(), isNull);
    },
  );

  test('a badge shows the data confirmed at admission (§20.2a)', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String a = w['A'].myKey!;
    expect(await w['A'].showBadge(true), isNotNull);
    await w.net.run();
    expect(w['S'].state!.badges[a], (birthYear: 1990, gender: 'k'));
    await w['A'].showBadge(false);
    await w.net.run();
    expect(w['S'].state!.badges, isEmpty);
    expect(w.views().values.toSet(), hasLength(1));
  });
}
