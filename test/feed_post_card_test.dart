import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/ledger_mesh.dart';

// A friend's post on the wall as its card shows it: who passed it on, and
// the muting of that person's new posts (the menu, what it says, and the
// mark on the card).

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Phones a–b[–c]: [reader] looks at the wall; the others are named in its
/// friends list ([friends] maps the phone's name to the name it shows).
Future<
  ({
    LedgerMesh mesh,
    LedgerNode node,
    PostReachService reach,
    SocialHubState social,
  })
>
_world(
  List<String> chain,
  String reader,
  Map<String, String> friends, {
  List<(String, String)>? links,
}) async {
  final LedgerMesh mesh = LedgerMesh();
  if (links == null) {
    mesh.chain(chain);
  } else {
    for (final (String x, String y) in links) {
      mesh.befriend(x, y);
    }
  }
  final Map<String, LedgerNode> nodes = <String, LedgerNode>{};
  for (final String n in chain) {
    nodes[n] = await mesh.add(n);
  }
  final PostReachService reach = PostReachService(
    node: nodes[reader]!,
    noticeAudience: () => noticeAudienceFor(FriendListAudience.friends),
    delay: Duration.zero,
    minGap: Duration.zero,
    retryAfter: Duration.zero,
  );
  addTearDown(reach.stop);
  await reach.start();
  for (final String n in chain) {
    if (n != reader) {
      // The other phones pass notices on as well.
      final PostReachService other = PostReachService(
        node: nodes[n]!,
        noticeAudience: () => noticeAudienceFor(FriendListAudience.friends),
        delay: Duration.zero,
        minGap: Duration.zero,
        retryAfter: Duration.zero,
      );
      addTearDown(other.stop);
      await other.start();
    }
  }
  await mesh.settle();
  final SocialHubState social = SocialHubState.empty().copyWith(
    friends: <String, FriendProfile>{
      for (final MapEntry<String, String> f in friends.entries)
        mesh.address(f.key): FriendProfile(
          address: mesh.address(f.key),
          displayName: f.value,
          status: FriendRelationshipStatus.accepted,
        ),
    },
  );
  return (mesh: mesh, node: nodes[reader]!, reach: reach, social: social);
}

Future<LogEntry> _post(LedgerNode node, String text) async => node.publish(
  kPostKind,
  await node.seal(Audience.public, newPostBody(text)),
);

Widget _feed(
  LedgerNode node,
  PostReachService reach,
  SocialHubState social,
  AppSettings settings,
) => ProviderScope(
  overrides: [
    ...buildAppSettingsProviderOverrides(
      store: MemoryAppSettingsStore(),
      initialState: settings,
      hydrationEnabled: false,
    ),
    socialHubAutoHydrateProvider.overrideWithValue(false),
    socialHubSeedProvider.overrideWithValue(social),
    signalTransportProvider.overrideWithValue(MemorySignalTransport()),
    ledgerNodeEnabledProvider.overrideWithValue(true),
    ledgerNodeProvider.overrideWithValue(node),
    postReachProvider.overrideWithValue(reach),
  ],
  child: const MaterialApp(home: FeedScreen()),
);

void main() {
  testWidgets('a post from a friend of a friend says who passed it on', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final w = (await tester.runAsync(
      () => _world(<String>['a', 'b', 'c'], 'c', <String, String>{'b': 'Bob'}),
    ))!;
    final LogEntry post = (await tester.runAsync(() async {
      final LogEntry e = await _post(w.mesh['a'], 'Z daleka');
      await w.mesh.settle();
      for (int i = 0; i < 3; i++) {
        await w.reach.round();
        await w.mesh.settle();
      }
      return e;
    }))!;
    await tester.pumpWidget(
      _feed(w.node, w.reach, w.social, const AppSettings()),
    );
    await tester.runAsync(() => _settle());
    await tester.pump();

    expect(find.text('Z daleka'), findsOneWidget);
    final Finder via = find.byKey(Key('feed-via-${post.id}'));
    expect(via, findsOneWidget);
    expect(
      find.descendant(of: via, matching: find.text('przez Bob')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });

  testWidgets('several friends who passed a post on: the first and how many '
      'more', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final w = (await tester.runAsync(
      () => _world(
        <String>['a', 'b1', 'b2', 'b3', 'c'],
        'c',
        <String, String>{'b1': 'Ala', 'b2': 'Bob', 'b3': 'Cyryl'},
        links: <(String, String)>[
          ('a', 'b1'),
          ('a', 'b2'),
          ('a', 'b3'),
          ('c', 'b1'),
          ('c', 'b2'),
          ('c', 'b3'),
        ],
      ),
    ))!;
    final LogEntry post = (await tester.runAsync(() async {
      final LogEntry e = await _post(w.mesh['a'], 'Z daleka');
      await w.mesh.settle();
      for (int i = 0; i < 3; i++) {
        await w.reach.round();
        await w.mesh.settle();
      }
      return e;
    }))!;
    await tester.pumpWidget(
      _feed(w.node, w.reach, w.social, const AppSettings()),
    );
    await tester.runAsync(() => _settle());
    await tester.pump();

    final Finder via = find.byKey(Key('feed-via-${post.id}'));
    expect(via, findsOneWidget);
    final String text = tester
        .widget<Text>(find.descendant(of: via, matching: find.byType(Text)))
        .data!;
    expect(text, matches(r'^przez \w+ i 2 inne osoby$'));
    expect(
      tester
          .widget<Text>(find.descendant(of: via, matching: find.byType(Text)))
          .maxLines,
      2,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });

  group('muting new posts of a friend from the card', () {
    Future<(ProviderContainer, LogEntry, String)> pumpWall(
      WidgetTester tester, {
      required bool postNotifications,
    }) async {
      tester.view.physicalSize = const Size(900, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final w = (await tester.runAsync(
        () => _world(<String>['a', 'b'], 'a', <String, String>{'b': 'Bob'}),
      ))!;
      final LogEntry post = (await tester.runAsync(() async {
        final LogEntry e = await _post(w.mesh['b'], 'Od Boba');
        await w.mesh.settle();
        return e;
      }))!;
      await tester.pumpWidget(
        _feed(
          w.node,
          w.reach,
          w.social,
          AppSettings(postNotifications: postNotifications),
        ),
      );
      await tester.runAsync(() => _settle());
      await tester.pump();
      expect(find.text('Od Boba'), findsOneWidget);
      return (
        ProviderScope.containerOf(tester.element(find.byType(FeedScreen))),
        post,
        w.mesh.address('b'),
      );
    }

    Future<void> chooseMute(WidgetTester tester, LogEntry post) async {
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('feed-mute-posts-${post.id}')));
      await tester.runAsync(() => _settle());
      await tester.pumpAndSettle();
    }

    testWidgets('muting is said, shown on the card and undone from the same '
        'menu', (WidgetTester tester) async {
      final (ProviderContainer container, LogEntry post, String bob) =
          await pumpWall(tester, postNotifications: true);
      expect(find.byKey(Key('feed-muted-${post.id}')), findsNothing);
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      expect(find.text('Wycisz posty tej osoby'), findsOneWidget);
      await tester.tap(find.byKey(Key('feed-mute-posts-${post.id}')));
      await tester.runAsync(() => _settle());
      await tester.pumpAndSettle();

      expect(
        container.read(appSettingsControllerProvider).mutedPostAuthors,
        contains(bob),
      );
      expect(find.byKey(Key('feed-muted-${post.id}')), findsOneWidget);

      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      expect(
        find.text('Włącz powiadomienia o postach tej osoby'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(Key('feed-mute-posts-${post.id}')));
      await tester.runAsync(() => _settle());
      await tester.pumpAndSettle();
      expect(
        container.read(appSettingsControllerProvider).mutedPostAuthors,
        isEmpty,
      );
      expect(find.byKey(Key('feed-muted-${post.id}')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => _settle());
    });

    testWidgets('with the switch for posts off it explains instead of '
        'muting', (WidgetTester tester) async {
      final (ProviderContainer container, LogEntry post, String _) =
          await pumpWall(tester, postNotifications: false);
      await chooseMute(tester, post);
      expect(
        find.text(
          'Powiadomienia o nowych postach znajomych są wyłączone w '
          'Ustawieniach.',
        ),
        findsOneWidget,
      );
      expect(
        container.read(appSettingsControllerProvider).mutedPostAuthors,
        isEmpty,
      );
      expect(find.byKey(Key('feed-muted-${post.id}')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() => _settle());
    });
  });
}
