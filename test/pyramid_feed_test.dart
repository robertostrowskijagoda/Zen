import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/feed/presentation/pyramid_feed_card.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

import 'support/pyramid_world.dart';

/// The pyramid's posts on the Tablica (§22): who sees which, under which
/// chip, once; the Pyramid only points there.
void main() {
  List<String> ids(Iterable<PyrFeedPost> posts) => <String>[
    for (final PyrFeedPost p in posts) p.id,
  ];

  List<String> shown(FeedFilter f, PyramidFeed feed) => <String>[
    for (final FeedItem i in composeFeed(f, wall: const [], pyramid: feed))
      i.id,
  ];

  test('a member: the top and the line up (not another branch), own posts '
      'under „Piramida” only, the section of their nationality under „Kraj” '
      'only', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidRecord top = (await w['S'].post('Do całej piramidy'))!;
    final PyramidRecord line = (await w['A'].post('Do gałęzi A'))!;
    final PyramidRecord other = (await w['B'].post('Do gałęzi B'))!;
    final PyramidRecord own = (await w['A1'].post('Mój post'))!;
    final PyramidRecord natPl = (await w['A2'].natPost('Cześć, sekcja PL'))!;
    final PyramidRecord natDe = (await w['B1'].natPost('Hallo'))!;
    await w.net.run();
    await w.sync();

    final PyramidFeed a1 = w['A1'].feed;
    expect(a1.member, isTrue);
    expect(ids(a1.pyramid), <String>[top.id, line.id, own.id]);
    expect(ids(a1.national), <String>[natPl.id]);
    expect(ids(a1.posts), isNot(contains(other.id)));
    expect(ids(a1.posts), isNot(contains(natDe.id)));
    expect(
      a1.posts.firstWhere((PyrFeedPost p) => p.id == line.id).name,
      'A',
      reason: 'the pyramid pseudonym',
    );
    expect(a1.posts.every((PyrFeedPost p) => p.canComment), isTrue);
    expect(feedFiltersFor(a1), FeedFilter.values);

    expect(shown(FeedFilter.all, a1).toSet(), <String>{top.id, line.id});
    expect(shown(FeedFilter.pyramid, a1), <String>[top.id, line.id, own.id]);
    expect(shown(FeedFilter.national, a1), <String>[natPl.id]);
    expect(shown(FeedFilter.friends, a1), isEmpty);
    for (final FeedFilter f in FeedFilter.values) {
      final List<String> got = shown(f, a1);
      expect(got.toSet(), hasLength(got.length), reason: 'once: $f');
    }

    final PyramidFeed b = w['B'].feed;
    expect(ids(b.pyramid), <String>[top.id, other.id]);
    expect(
      b.posts.firstWhere((PyrFeedPost p) => p.id == top.id).kind,
      PyrFeedKind.top,
    );
    expect(ids(w['B1'].feed.national), <String>[natDe.id]);
  });

  test('somebody outside reads the top and the section member friends pass '
      'on, cannot comment, and has the chips only with such posts', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final SimPhone o = w.add('O');
    final SimPhone p = w.add('P');
    w.profileNationalities
      ..['O'] = <String>['DE']
      ..['P'] = <String>['DE'];
    await w.pyr(o).load();
    await w.pyr(p).load();
    w.net.befriend(w.net['B1'], o);

    final PyramidRecord top = (await w['S'].post('Do całej piramidy'))!;
    final PyramidRecord line = (await w['B'].post('Do gałęzi B'))!;
    final PyramidRecord nat = (await w['B1'].natPost('Hallo zusammen'))!;
    await w.net.run();

    final PyramidFeed f = w['O'].feed;
    expect(f.member, isFalse);
    expect(w['O'].isMember, isFalse);
    expect(ids(f.pyramid), <String>[top.id]);
    expect(ids(f.national), <String>[nat.id]);
    expect(ids(f.posts), isNot(contains(line.id)));
    expect(f.posts.any((PyrFeedPost x) => x.canComment), isFalse);
    expect(
      f.posts.firstWhere((PyrFeedPost x) => x.id == top.id).kind,
      PyrFeedKind.top,
    );
    expect(w['O'].keeps(top.id), isFalse, reason: 'read-only: no record');
    expect(shown(FeedFilter.all, f), <String>[top.id]);
    expect(shown(FeedFilter.pyramid, f), <String>[top.id]);
    expect(shown(FeedFilter.national, f), <String>[nat.id]);
    expect(feedFiltersFor(f), FeedFilter.values);

    // Anybody can sign "level 0": a post of the top counts outside only
    // from the head the power key's line (from the pinned genesis) names.
    final LedgerKeyPair fake = await LedgerKeyPair.generate();
    final PyramidRecord forged = await PyramidRecord(
      body: <String, dynamic>{
        't': PyrT.post,
        'py': w['S'].current,
        'at': w.net.now,
        'by': <String>[fake.id],
        'lvl': 0,
        'text': 'Fałszywy szczyt',
      },
    ).signedBy(fake);
    final List<Map<String, dynamic>> foundChain = <Map<String, dynamic>>[
      for (final String id in w['S'].recordIds)
        if (w['S'].recordOf(id)!.type == PyrT.found)
          w['S'].recordOf(id)!.toJson(),
    ];
    expect(foundChain, hasLength(1));
    await w.net['B1'].send(o.address, <String, dynamic>{
      'type': PyramidTypes.national,
      'ps': <Map<String, dynamic>>[
        <String, dynamic>{
          'r': forged.toJson(),
          'm': <String, dynamic>{'n': 'S'},
        },
      ],
      'hc': foundChain,
    });
    await w.net.run();
    expect(ids(w['O'].feed.pyramid), <String>[top.id]);

    // No member friend: nothing, no chips.
    expect(w['P'].feed.posts, isEmpty);
    expect(feedFiltersFor(w['P'].feed), isEmpty);

    // A friend that comes later, without a nationality in the profile,
    // gets the top's posts with the hello, once.
    final SimPhone l = w.add('L');
    await w.pyr(l).load();
    w.net.befriend(w.net['B'], l);
    await w['L'].greet();
    await w.net.run();
    expect(
      <String>[for (final PyrNationalPost p in w['L'].topPosts()) p.id],
      <String>[top.id],
    );
    expect(feedFiltersFor(w['L'].feed), <FeedFilter>[
      FeedFilter.all,
      FeedFilter.friends,
      FeedFilter.pyramid,
    ]);
    bool passed(Map<String, dynamic> m) => m['type'] == PyramidTypes.national;
    final int sent = w.net['B'].outbox.where(passed).length;
    await w['L'].greet();
    await w.net.run();
    expect(
      w.net['B'].outbox.where(passed),
      hasLength(sent),
      reason: 'nothing newer than what L has',
    );
  });

  test('one notification for new posts, updated in place, opening the '
      'Tablica on „Piramida”; read posts are not new', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidRecord top = (await w['S'].post('Pierwszy'))!;
    await w.net.run();
    final PyramidRecord line = (await w['A'].post('Drugi'))!;
    await w.net.run();
    await w.sync();

    List<RuntimeSystemNotification> posts(String who) =>
        <RuntimeSystemNotification>[
          for (final RuntimeSystemNotification n in w.net[who].shown)
            if (n.id == kPyrPostsNotification) n,
        ];
    expect(posts('A1'), hasLength(2));
    expect(
      posts('A1').every(
        (RuntimeSystemNotification n) => n.slotKey == kPyrPostsNotification,
      ),
      isTrue,
    );
    expect(posts('A1').last.stackCount, 2);
    expect(posts('A1').last.routeKey, buildFeedRouteKey('pyramid'));
    final RuntimeRouteIntent? route = runtimeRouteIntentFromRouteKey(
      id: 'n',
      routeKey: posts('A1').last.routeKey,
    );
    expect(route?.target, RuntimeRouteTarget.feed);
    expect(FeedFilter.parse(route?.rawInput), FeedFilter.pyramid);
    expect(
      w.net['A1'].shown.where(
        (RuntimeSystemNotification n) => n.id.startsWith('pyr-post-'),
      ),
      isEmpty,
      reason: 'never one per post',
    );
    expect(posts('B').last.stackCount, 1, reason: 'A is not in B\'s line');
    expect(posts('A'), hasLength(1), reason: 'not for one\'s own post');

    w['A1'].markRead(<String>[top.id, line.id]);
    expect(w['A1'].feed.unread(w['A1'].wasRead, w['A1'].now), isEmpty);
    await w['S'].post('Trzeci');
    await w.net.run();
    expect(posts('A1'), hasLength(3));
    expect(posts('A1').last.stackCount, 1);
  });

  group('screens', () {
    Widget app(PyramidService pyr, Widget home) => ProviderScope(
      // A scope of its own per person.
      key: ValueKey<PyramidService>(pyr),
      overrides: [
        ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        pyramidServiceProvider.overrideWithValue(pyr),
      ],
      child: MaterialApp(theme: ZenTheme.dark(), home: home),
    );

    testWidgets('the Pyramid has no posts tabs, only the way to the Tablica '
        'with „Piramida” on', (WidgetTester tester) async {
      late PyramidWorld w;
      await tester.runAsync(() async {
        w = await PyramidWorld.six();
        await w['S'].post('Pierwszy');
        await w['A'].post('Drugi');
        await w.net.run();
      });
      await tester.pumpWidget(app(w['A1'], const PyramidScreen()));
      await tester.pump();
      expect(find.text('Polityka'), findsNothing);
      expect(find.text('Kraj'), findsNothing);
      final Finder entry = find.byKey(const Key('pyr-posts-entry'));
      await tester.ensureVisible(entry);
      await tester.pump();
      expect(find.text('Posty piramidy: 2 nowe'), findsOneWidget);
      expect(find.byKey(const Key('pyr-post')), findsOneWidget);

      final int before = feedOpenRequest.value;
      await tester.tap(find.byKey(const Key('pyr-open-feed')));
      await tester.pump();
      expect(feedFilterRequest.value, FeedFilter.pyramid);
      expect(feedOpenRequest.value, before + 1);
      feedFilterRequest.value = null;
    });

    testWidgets('a card counts as read only after being on the screen for a '
        'second; a member comments, a reader outside does not', (
      WidgetTester tester,
    ) async {
      late PyramidWorld w;
      late PyramidRecord top;
      await tester.runAsync(() async {
        w = await PyramidWorld.six();
        final SimPhone o = w.add('O');
        await w.pyr(o).load();
        w.net.befriend(w.net['B1'], o);
        top = (await w['S'].post('Do całej piramidy'))!;
        await w.net.run();
      });
      final PyrFeedPost post = w['A1'].feed.posts.single;
      expect(post.id, top.id);
      await tester.pumpWidget(
        app(
          w['A1'],
          Scaffold(
            body: ListView(
              children: <Widget>[PyramidFeedCard(pyr: w['A1'], post: post)],
            ),
          ),
        ),
      );
      expect(find.text('PIRAMIDA · szczyt'), findsOneWidget);
      expect(find.text('S'), findsWidgets, reason: 'the pseudonym');
      expect(find.byKey(Key('feed-pyr-comment-${top.id}')), findsOneWidget);
      expect(find.byKey(Key('feed-pyr-report-${top.id}')), findsOneWidget);
      expect(w['A1'].wasRead(top.id), isFalse, reason: 'built is not read');
      await tester.pump(const Duration(milliseconds: 500));
      expect(w['A1'].wasRead(top.id), isFalse);
      await tester.pump(const Duration(milliseconds: 600));
      expect(w['A1'].wasRead(top.id), isTrue);

      // Below the fold (built ahead, not seen): not read.
      final PyrFeedPost outside = w['O'].feed.posts.single;
      await tester.pumpWidget(
        app(
          w['O'],
          Scaffold(
            body: ListView(
              children: <Widget>[
                const SizedBox(height: 620),
                PyramidFeedCard(pyr: w['O'], post: outside),
              ],
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(w['O'].wasRead(top.id), isFalse);
      await tester.drag(find.byType(ListView), const Offset(0, -400));
      await tester.pump();
      // On the screen now (finders skip what is below the fold).
      expect(find.byKey(Key('feed-pyr-comment-${top.id}')), findsNothing);
      expect(find.textContaining('tylko do czytania'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1100));
      expect(w['O'].wasRead(top.id), isTrue);
    });
  });
}
