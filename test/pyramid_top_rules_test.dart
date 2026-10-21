import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The top's immunity (removing or banning a member of the top cell takes
/// 2 of 3 of the top and most of level 2) and posts to the whole pyramid
/// (the head's, or with the head's delegation, showing who wrote them).
void main() {
  const int t0 = FoldWorld.t0;
  const int h = FoldWorld.hour;
  const int day = FoldWorld.day;

  late FoldWorld w;

  setUp(() async {
    // kFoldTree: S at the top; A, B under S; A1, A2, B1 at level 2 (three:
    // most is two); X, Y below A1.
    w = await FoldWorld.make();
  });

  group('the top\'s immunity', () {
    test(
      'removing a member of the top: their cell and most of level 2',
      () async {
        final PyramidRecord cellOnly = await w.rec(
          PyrT.remove,
          t0 + day,
          <String>['S', 'B'],
          <String, dynamic>{'k': w.id('A')},
        );
        final PyramidRecord oneBelow = await w.rec(
          PyrT.remove,
          t0 + day + 1,
          <String>['S', 'B', 'A1'],
          <String, dynamic>{'k': w.id('A')},
        );
        PyramidState st = w.fold(<PyramidRecord>[cellOnly, oneBelow]);
        expect(st.levelTwo, hasLength(3));
        expect(st.levelTwoNeed, 2);
        expect(st.rejected[cellOnly.id], contains('poziomu 2'));
        expect(st.rejected[oneBelow.id], contains('poziomu 2'));
        expect(st.isMember(w.id('A')), isTrue);
        final PyramidRecord enough = await w.rec(
          PyrT.remove,
          t0 + day + 2,
          <String>['S', 'B', 'A1', 'B1'],
          <String, dynamic>{'k': w.id('A')},
        );
        st = w.fold(<PyramidRecord>[enough]);
        expect(st.applied, contains(enough.id));
        expect(st.isMember(w.id('A')), isFalse);
        // Appealed as usual: above whoever decided.
        expect(st.matters[enough.id]?.party, w.id('A'));
        // Below the top, the own cell alone as before.
        final PyramidRecord leaf = await w.rec(
          PyrT.remove,
          t0 + day + 3,
          <String>['A', 'A2'],
          <String, dynamic>{'k': w.id('A1')},
        );
        expect(w.fold(<PyramidRecord>[leaf]).applied, contains(leaf.id));
      },
    );

    test('banning the head: 2 of 3 of the top and most of level 2; one '
        'post of theirs only by the top', () async {
      Future<PyramidRecord> ban(int at, List<String> by, String kind) =>
          w.rec(PyrT.ban, at, by, <String, dynamic>{
            'target': w.id('S'),
            'kind': kind,
            'reason': 'test',
            if (kind == 'pause') 'until': at + day,
          });
      final PyramidRecord topOnly = await ban(t0 + day, <String>[
        'A',
        'B',
      ], 'pause');
      final PyramidRecord withBelow = await ban(t0 + day + h, <String>[
        'A',
        'B',
        'A2',
        'B1',
      ], 'pause');
      final PyramidRecord content = await ban(t0 + day + 2 * h, <String>[
        'A',
        'B',
      ], 'content');
      final PyramidState st = w.fold(<PyramidRecord>[
        topOnly,
        withBelow,
        content,
      ]);
      expect(st.rejected[topOnly.id], contains('poziomu 2'));
      expect(st.applied, contains(withBelow.id));
      expect(st.applied, contains(content.id));
      expect(st.inTopCell(w.id('S')), isTrue);
      expect(st.inTopCell(w.id('A1')), isFalse);
    });
  });

  group('posts to the whole pyramid', () {
    Future<PyramidRecord> grant(
      List<String> by, {
      int at = t0 + day,
      String to = 'X',
      bool sub = false,
      String scope = '',
    }) => w.rec(PyrT.delegate, at, by, <String, dynamic>{
      'to': w.id(to),
      'power': 'posts',
      'scope': scope,
      'limit': 0,
      'until': at + 10 * day,
      'sub': sub,
    });

    Future<PyramidRecord> post(String who, int at, int lvl, {String? via}) =>
        w.rec(
          PyrT.post,
          at,
          <String>[who],
          <String, dynamic>{
            'text': 'Do wszystkich',
            'lvl': lvl,
            'all': true,
            'via': ?via,
          },
        );

    test('only the head gives it, to the whole pyramid, not passed on; the '
        'post shows who wrote it', () async {
      final PyramidRecord byHead = await grant(<String>['S']);
      final PyramidRecord byTop = await grant(<String>[
        'A',
        'B',
      ], at: t0 + day + 1);
      final PyramidRecord passedOn = await grant(
        <String>['S'],
        at: t0 + day + 2,
        sub: true,
      );
      final PyramidRecord branch = await grant(
        <String>['S'],
        at: t0 + day + 3,
        scope: '0',
      );
      expect(byHead.signsWithKeys, isTrue, reason: 'read outside too');
      final PyramidRecord ok = await post('X', t0 + 2 * day, 3, via: byHead.id);
      final PyramidRecord without = await post('X', t0 + 2 * day + 1, 3);
      final PyramidRecord other = await post(
        'Y',
        t0 + 2 * day + 2,
        3,
        via: byHead.id,
      );
      final PyramidRecord head = await post('S', t0 + 2 * day + 3, 0);
      final PyramidState st = w.fold(<PyramidRecord>[
        byHead,
        byTop,
        passedOn,
        branch,
        ok,
        without,
        other,
        head,
      ]);
      expect(st.applied, contains(byHead.id));
      for (final PyramidRecord r in <PyramidRecord>[byTop, passedOn, branch]) {
        expect(st.rejected[r.id], contains('tylko szef'), reason: r.id);
      }
      expect(st.posts[ok.id]!.toWhole, isTrue);
      expect(st.posts[ok.id]!.via, byHead.id);
      expect(st.rejected[without.id], contains('delegacją'));
      expect(st.rejected[other.id], contains('delegacją'));
      expect(st.posts[head.id]!.toWhole, isTrue);

      // On B1's Tablica (another branch): from the top, by X, delegated.
      final PyramidFeed feed = pyramidFeedOf(
        state: st,
        me: w.id('B1'),
        now: t0 + 3 * day,
      );
      final PyrFeedPost shown = feed.posts.firstWhere(
        (PyrFeedPost p) => p.id == ok.id,
      );
      expect(shown.kind, PyrFeedKind.top);
      expect(shown.delegated, isTrue);
      expect(shown.name, 'X');
      expect(
        feed.posts.firstWhere((PyrFeedPost p) => p.id == head.id).delegated,
        isFalse,
      );
    });

    test('the head takes it back alone; it ends at its time', () async {
      final PyramidRecord g = await grant(<String>['S']);
      final PyramidRecord revoke = await w.rec(
        PyrT.revoke,
        t0 + 2 * day,
        <String>['S'],
        <String, dynamic>{'d': g.id, 'acts': const <String>[]},
      );
      final PyramidRecord after = await post('X', t0 + 3 * day, 3, via: g.id);
      PyramidState st = w.fold(<PyramidRecord>[g, revoke, after]);
      expect(st.applied, contains(revoke.id));
      expect(st.rejected[after.id], contains('delegacją'));
      final PyramidRecord late = await post('X', t0 + 12 * day, 3, via: g.id);
      st = w.fold(<PyramidRecord>[g, late]);
      expect(st.rejected[late.id], contains('delegacją'));
    });

    test('a reader outside checks the delegation against the power key\'s '
        'line', () async {
      final PyramidRecord g = await grant(<String>['S']);
      final PyramidRecord ok = await post('X', t0 + 2 * day, 3, via: g.id);
      final List<PyrCertifiedHead> heads = await certifiedHeads(
        w.records.first,
        w.records,
      );
      PyrNationalPost read(PyramidRecord post, PyramidRecord? grant) =>
          PyrNationalPost.fromJson(<String, dynamic>{
            'r': post.toJson(),
            'm': <String, dynamic>{'n': 'X'},
            if (grant != null) 'g': grant.toJson(),
          })!;
      expect(await byGrantOfHead(heads, read(ok, g)), isTrue);
      // Without its delegation it is not even read.
      expect(
        PyrNationalPost.fromJson(<String, dynamic>{'r': ok.toJson()}),
        isNull,
      );
      // A "delegation" signed by somebody else than the head.
      final PyramidRecord fake = await grant(<String>['A'], at: t0 + day + 5);
      final PyramidRecord withFake = await post(
        'X',
        t0 + 2 * day + 1,
        3,
        via: fake.id,
      );
      expect(await byGrantOfHead(heads, read(withFake, fake)), isFalse);
      // Written after it ended.
      final PyramidRecord late = await post('X', t0 + 12 * day, 3, via: g.id);
      expect(await byGrantOfHead(heads, read(late, g)), isFalse);
    });

    test('on the network: the head lets B1 write to everybody; a friend '
        'outside reads it with B1\'s name', () async {
      final PyramidWorld world = await PyramidWorld.six();
      final SimPhone o = world.add('O');
      await world.pyr(o).load();
      world.net.befriend(world.net['B1'], o);
      final String b1 = world['B1'].myKey!;
      expect(world['B1'].canPostToAll, isFalse);
      expect(await world['B1'].post('Zakazane', toAll: true), isNull);
      expect(
        await world['S'].delegatePosts(b1, until: world.net.now + 5 * day),
        isNotNull,
      );
      await world.net.run();
      await world.sync();
      expect(world['B1'].canPostToAll, isTrue);
      final PyramidRecord? sent = await world['B1'].post(
        'Do wszystkich od B1',
        toAll: true,
      );
      expect(sent, isNotNull);
      await world.net.run();
      // A2, in another branch, has it from the top.
      final PyrFeedPost there = world['A2'].feed.posts.firstWhere(
        (PyrFeedPost p) => p.id == sent!.id,
      );
      expect(there.kind, PyrFeedKind.top);
      expect(there.delegated, isTrue);
      expect(there.name, 'B1');
      // O, outside: passed on with the delegation, checked.
      final List<PyrNationalPost> top = world['O'].topPosts();
      expect(top.map((PyrNationalPost p) => p.id), contains(sent!.id));
      expect(
        top.firstWhere((PyrNationalPost p) => p.id == sent.id).delegated,
        isTrue,
      );
      // The head takes it back.
      final String d = world['S'].state!.delegations.values
          .firstWhere((PyrDelegation x) => x.power == 'posts')
          .id;
      expect(await world['S'].revokeDelegation(d), isNotNull);
      await world.net.run();
      await world.sync();
      expect(world['B1'].canPostToAll, isFalse);
    });
  });
}
