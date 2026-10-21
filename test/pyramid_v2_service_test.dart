import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/hybrid_signature.dart';
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
/// "Znajomy", reports climbing level by level with the signed
/// original, the reach of posts and the anonymous statistics summed up
/// the tree, the badge.
void main() {
  Future<LogEntry> signedPost(String text) async {
    final LedgerKeyPair account = await LedgerKeyPair.generate();
    final LedgerKeyPair device = await LedgerKeyPair.generate();
    final DeviceCertificate cert = await DeviceCertificate.issue(
      account: account,
      device: device,
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

  test('a newcomer is admitted only at the level "Znajomy"', () async {
    final PyramidWorld w = PyramidWorld();
    final Map<String, FriendLevel> levels = <String, FriendLevel>{};
    final SimPhone s = w.add(
      'S',
      friendLevelOf: (String a) => levels[PeerShareCodec.normalizeAddress(a)],
    );
    await w.pyr(s).load();
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm');
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

  test('the birth year is required; a minor is admitted and the confirmed '
      'year is public in the pyramid', () async {
    final PyramidWorld w = PyramidWorld();
    final SimPhone s = w.add(
      'S',
      friendLevelOf: (String a) => FriendLevel.friend,
    );
    await w.pyr(s).load();
    expect(
      await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 0, gender: 'm'),
      isNull,
    );
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1970, gender: 'm');
    final SimPhone z = w.add('Z');
    w.net.befriend(s, z);
    await w.pyr(z).load();
    final int thisYear = DateTime.fromMillisecondsSinceEpoch(
      w.net.now,
      isUtc: true,
    ).year;
    for (final int bad in <int>[0, 1850, thisYear + 1]) {
      expect(
        await w
            .pyr(z)
            .askToJoin(
              invite: w['S'].inviteCode()!,
              myName: 'Z',
              nat: 'PL',
              birthYear: bad,
              gender: 'k',
            ),
        isFalse,
        reason: '$bad',
      );
    }
    expect(
      await w
          .pyr(z)
          .askToJoin(
            invite: w['S'].inviteCode()!,
            myName: 'Z',
            nat: 'PL',
            birthYear: thisYear - 12,
            gender: 'k',
          ),
      isTrue,
    );
    await w.net.run();
    final PyrProposal p = w['S'].proposals.values.single;
    // The admitting person signs the year itself.
    expect((p.record.body['m'] as Map)['yr'], thisYear - 12);
    expect(w['S'].admitProblem(p), isNull);
    await w['S'].approve(p.record.id);
    await w.net.run();
    final String zk = w['Z'].myKey!;
    expect(w['S'].state!.isMember(zk), isTrue);
    expect(w['S'].state!.members[zk]!.birthYear, thisYear - 12);
    expect(pyrAge(thisYear - 12, w.net.now), 12);
    // The gender stays a hash until shown.
    expect(w['S'].state!.badges, isEmpty);
  });

  test('a report climbs level by level to the top', () async {
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
    'a report carries the signed original; the ban names the entry',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final LogEntry post = await signedPost('Kup tanio!!!');
      final PyrReport good = await w['A1'].report(
        reason: 'spam',
        target: w['B1'].myKey!,
        evidence: 'Kup tanio!!!',
        entryId: post.id,
        entry: post.toCertifiedJson(),
      );
      // Changed text under the old signature: kept without the "original".
      final Map<String, dynamic> forged = post.toCertifiedJson()
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
    },
  );

  test('reach of a post and anonymous statistics come up the tree', () async {
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
  });

  test('a gender badge shows the data confirmed at admission', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String a = w['A'].myKey!;
    expect(w['S'].state!.members[a]!.birthYear, 1990);
    expect(await w['A'].showBadge(true), isNotNull);
    await w.net.run();
    expect(w['S'].state!.badges[a], 'k');
    await w['A'].showBadge(false);
    await w.net.run();
    expect(w['S'].state!.badges, isEmpty);
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('a record whose signature names a key not published here yet waits '
      'for the record that publishes it, and is checked then', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidService a1 = w['A1'];
    final String py = a1.current!;
    final int at = w.net.now;
    final LedgerKeyPair m = await LedgerKeyPair.generate();
    // A national-section post is read outside the pyramid: it carries the
    // key. A comment names it.
    final PyramidRecord intro = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.natPost,
        'py': py,
        'at': at,
        'by': <String>[m.id],
        'nat': 'PL',
        'text': 'Cześć',
      },
    ).signedBy(m);
    final PyramidRecord later = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.comment,
        'py': py,
        'at': at + 1,
        'by': <String>[m.id],
        'text': 'Dalej',
      },
    ).signedBy(m);
    expect(intro.sigs[m.id], hasLength(kKeyedHybridSignatureChars));
    expect(later.sigs[m.id], hasLength(kHybridSignatureChars));
    // As on a phone that has not seen the key published yet.
    HybridKeyBook.clear();
    expect(later.lacksKeys, isTrue);
    expect(await a1.ingest(later), isFalse);
    expect(a1.keeps(later.id), isFalse, reason: 'never taken unchecked');
    // The record that publishes it comes: both are taken, each checked.
    expect(await a1.ingest(intro), isTrue);
    expect(a1.keeps(intro.id), isTrue);
    expect(a1.keeps(later.id), isTrue);
    // A forged comment naming the same key is still refused.
    final PyramidRecord forged = PyramidRecord(
      body: <String, dynamic>{...later.body, 'text': 'Podróbka'},
      sigs: later.sigs,
    );
    expect(await a1.ingest(forged), isFalse);
  });
}
