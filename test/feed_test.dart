import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('a post needs text and has a length limit', () {
    expect(() => newPostBody('   '), throwsArgumentError);
    expect(() => newPostBody('x' * (kMaxPostChars + 1)), throwsArgumentError);
    expect(newPostBody('  Cześć  '), <String, dynamic>{
      'text': 'Cześć',
      'aud': 'public',
    });
  });

  test('the wall shows my posts and my friends\', newest first', () async {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    await ta.start();
    await tb.start();
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();
    await a.publish(kPostKind, newPostBody('Od Ady'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.publish(kPostKind, newPostBody('Od Boba'));
    await b.publish('hologram', <String, dynamic>{'x': 1});
    await _settle();

    final List<FeedPost> feed = buildFeed(
      a,
      nameOf: (String address) => address == bob ? 'Bob' : '?',
    );
    expect(feed.map((FeedPost p) => p.text), <String>['Od Boba', 'Od Ady']);
    expect(feed.first.authorLabel, 'Bob');
    expect(feed.last.isOwn, isTrue);
  });

  test('likes travel to friends and can be taken back', () async {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    await ta.start();
    await tb.start();
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();
    await a.publish(kPostKind, newPostBody('Polub mnie'));
    await _settle();
    final String postId = buildFeed(b, nameOf: (_) => 'Ada').single.id;

    await b.publish(kLikeKind, likeBody(postId), spaceKind: 'acts');
    await a.publish(kLikeKind, likeBody(postId), spaceKind: 'acts');
    await _settle();
    FeedPost post = buildFeed(
      a,
      nameOf: (String address) => address == bob ? 'Bob' : '?',
    ).single;
    expect(post.likedByMe, isTrue);
    expect(post.likers, unorderedEquals(<String>['Ty', 'Bob']));

    await b.publish(kLikeKind, likeBody(postId, on: false), spaceKind: 'acts');
    await _settle();
    post = buildFeed(
      a,
      nameOf: (String address) => address == bob ? 'Bob' : '?',
    ).single;
    expect(post.likers, <String>['Ty']);
    expect(buildFeed(b, nameOf: (_) => 'Ada').single.likedByMe, isFalse);
  });

  test('comments need text and are shown oldest first', () async {
    expect(() => commentBody('p', '  '), throwsArgumentError);
    expect(
      () => commentBody('p', 'x' * (kMaxCommentChars + 1)),
      throwsArgumentError,
    );
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    await ta.start();
    await tb.start();
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();
    await a.publish(kPostKind, newPostBody('Co myślicie?'));
    await _settle();
    final String postId = buildFeed(b, nameOf: (_) => 'Ada').single.id;
    await b.publish(
      kCommentKind,
      commentBody(postId, 'Super'),
      spaceKind: 'acts',
    );
    await _settle();
    await a.publish(
      kCommentKind,
      commentBody(postId, 'Dzięki'),
      spaceKind: 'acts',
    );
    await _settle();
    final FeedPost post = buildFeed(
      a,
      nameOf: (String address) => address == bob ? 'Bob' : '?',
    ).single;
    expect(
      post.comments.map((FeedComment c) => '${c.authorLabel}: ${c.text}'),
      <String>['Bob: Super', 'Ty: Dzięki'],
    );
  });

  test('a reshare brings a friend of a friend\'s post, checked', () async {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final String cel = PeerShareCodec.normalizeAddress('200::c');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    final _Linked tc = nodes[cel] = _Linked(cel, nodes);
    for (final _Linked t in <_Linked>[ta, tb, tc]) {
      await t.start();
    }
    LedgerNode make(_Linked t, List<String> friends) {
      final LedgerNode n = LedgerNode(
        transport: t,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => friends,
        bridges: BridgeBook(probe: (String _) async => null),
      );
      addTearDown(n.stop);
      return n;
    }

    final LedgerNode a = make(ta, <String>[bob]);
    final LedgerNode b = make(tb, <String>[ada, cel]);
    final LedgerNode c = make(tc, <String>[bob]);
    await a.start();
    await b.start();
    await c.start();
    await a.publish(kPostKind, newPostBody('Warto przeczytać'));
    await _settle();
    final FeedPost fromAda = buildFeed(b, nameOf: (_) => 'Ada').single;
    await b.publish(kReshareKind, reshareBody(fromAda.entry!));
    await _settle();

    String names(String address) => address == bob ? 'Bob' : '?';
    expect(buildFeed(c, nameOf: names), isEmpty);
    final ReshareCache cache = ReshareCache();
    expect(await cache.checkAll(c.entriesOf(ofAccount: b.account)), isTrue);
    final FeedPost seen = buildFeed(c, nameOf: names, reshares: cache).single;
    expect(seen.text, 'Warto przeczytać');
    expect(seen.authorLabel, 'Znajomy znajomego');
    expect(seen.resharedBy, <String>['Bob']);
    expect(seen.id, fromAda.id);

    // Bob's own wall does not show Ada's post twice.
    final ReshareCache bobCache = ReshareCache();
    await bobCache.checkAll(b.entriesOf());
    expect(
      buildFeed(b, nameOf: (_) => 'Ada', reshares: bobCache),
      hasLength(1),
    );

    // A forged text inside a reshare is refused.
    final Map<String, dynamic> forged = fromAda.entry!.toCertifiedJson();
    forged['body'] = <String, dynamic>{'text': 'Podróbka', 'aud': 'public'};
    final LogEntry fake = await b.publish(kReshareKind, <String, dynamic>{
      'entry': forged,
    });
    expect(await unpackReshare(fake), isNull);
    // Only posts can be reshared.
    expect(() => reshareBody(fake), throwsArgumentError);
  });

  test('only the author can edit or remove a post', () async {
    expect(() => editPostBody('p', ' '), throwsArgumentError);
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');
    final Map<String, _Linked> nodes = <String, _Linked>{};
    final _Linked ta = nodes[ada] = _Linked(ada, nodes);
    final _Linked tb = nodes[bob] = _Linked(bob, nodes);
    await ta.start();
    await tb.start();
    final LedgerNode a = LedgerNode(
      transport: ta,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[bob],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    final LedgerNode b = LedgerNode(
      transport: tb,
      disk: MemoryLedgerDisk(),
      friendAddresses: () => <String>[ada],
      bridges: BridgeBook(probe: (String _) async => null),
    );
    addTearDown(a.stop);
    addTearDown(b.stop);
    await a.start();
    await b.start();
    final LogEntry first = await a.publish(kPostKind, newPostBody('Pierwszy'));
    final LogEntry second = await a.publish(kPostKind, newPostBody('Drugi'));
    await _settle();

    // Bob's tombstone or edit for Ada's post means nothing.
    await b.publish(kPostDeleteKind, deletePostBody(first.id));
    await b.publish(kPostEditKind, editPostBody(second.id, 'Przerobione'));
    await _settle();
    expect(
      buildFeed(b, nameOf: (_) => 'Ada').map((FeedPost p) => p.text),
      <String>['Drugi', 'Pierwszy'],
    );

    await a.publish(
      kPostEditKind,
      editPostBody(second.id, 'Drugi, poprawiony'),
    );
    await a.publish(kPostDeleteKind, deletePostBody(first.id));
    await _settle();
    final List<FeedPost> wall = buildFeed(b, nameOf: (_) => 'Ada');
    expect(wall.single.text, 'Drugi, poprawiony');
    expect(wall.single.edited, isTrue);
    expect(wall.single.id, second.id);
  });

  testWidgets('the editor publishes a post with a photo onto the profile', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Uint8List photo = Uint8List.fromList(
      img.encodePng(img.Image(width: 64, height: 48)),
    );
    final MemorySignalTransport transport = MemorySignalTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(transport),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: MaterialApp(
          home: FeedScreen(pickPhotos: () async => <Uint8List>[photo]),
        ),
      ),
    );
    // Key generation and signing run outside the fake clock.
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.text('Nic tu jeszcze nie ma od znajomych.'), findsOneWidget);

    Future<void> until(bool Function() done) async {
      for (int i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => _settle());
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    await tester.tap(find.byKey(const Key('feed-compose')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('post-editor')), findsOneWidget);
    FilledButton publish() =>
        tester.widget<FilledButton>(find.byKey(const Key('post-publish')));
    expect(publish().onPressed, isNull, reason: 'empty post');

    await tester.enterText(
      find.byKey(const Key('post-text')),
      'Pierwszy post w sieci',
    );
    await tester.pump();
    expect(find.text('21 / $kMaxPostChars'), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-tool-photo')));
    await until(
      () => find.byKey(const Key('post-media-remove-0')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('post-media-remove-0')), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-audience')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.byKey(const Key('post-audience-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Wszyscy znajomi'), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-publish')));
    await until(
      () =>
          find.byKey(const Key('feed-published')).evaluate().isNotEmpty &&
          find.byKey(const Key('post-editor')).evaluate().isEmpty,
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(const Key('post-editor')), findsNothing);
    // Own posts are not on the wall — they are on the profile.
    expect(find.text('Pierwszy post w sieci'), findsNothing);
    expect(find.text('Nic tu jeszcze nie ma od znajomych.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('feed-published-show')));
    await until(() => find.text('Pierwszy post w sieci').evaluate().isNotEmpty);
    expect(find.byKey(const Key('profile-screen')), findsOneWidget);
    expect(find.text('Pierwszy post w sieci'), findsOneWidget);

    final Finder image = find.byWidgetPredicate(
      (Widget w) =>
          w is Image &&
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('feed-image-'),
    );
    await until(() => image.evaluate().isNotEmpty);
    expect(image, findsOneWidget);

    await tester.tap(image);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await until(
      () => find.byKey(const Key('feed-photo-viewer')).evaluate().isNotEmpty,
    );
    expect(find.byKey(const Key('feed-photo-viewer')), findsOneWidget);

    // Leave no timers or subscriptions behind.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });

  testWidgets('closing a written post asks before throwing it away', (
    WidgetTester tester,
  ) async {
    bool published = false;
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          onSubmit: (PostDraft d) async {
            published = true;
            return null;
          },
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('post-text')), 'Szkic');
    await tester.tap(find.byKey(const Key('post-close')));
    await tester.pumpAndSettle();
    expect(find.text('Odrzucić post?'), findsOneWidget);
    await tester.tap(find.text('Pisz dalej'));
    await tester.pumpAndSettle();
    expect(find.text('Szkic'), findsOneWidget);
    expect(published, isFalse);
  });
}
