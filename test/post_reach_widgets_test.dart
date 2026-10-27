import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

Future<void> _settle() async {
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  testWidgets('the editor picks how far a public post goes; any other '
      'audience goes to friends only', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<PostDraft> drafts = <PostDraft>[];
    Future<void> open() => tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          onSubmit: (PostDraft d) async {
            drafts.add(d);
            return '';
          },
        ),
      ),
    );
    await open();
    await tester.enterText(find.byKey(const Key('post-text')), 'Daleko');
    await tester.pump();
    // Friends of friends at first.
    expect(find.byKey(const Key('post-reach')), findsOneWidget);
    expect(find.text('Znajomi znajomych'), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-reach')));
    await tester.pumpAndSettle();
    expect(find.text('Jak daleko ma dotrzeć?'), findsOneWidget);
    for (final PostReach r in PostReach.values) {
      expect(find.byKey(Key('post-reach-${r.name}')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('post-reach-third')));
    await tester.pumpAndSettle();
    expect(find.text('3. stopień'), findsOneWidget);

    await tester.tap(find.byKey(const Key('post-publish')));
    await tester.pumpAndSettle();
    expect(drafts.last.audience, Audience.public);
    expect(drafts.last.reach, PostReach.third);

    // For close friends there is nothing to pick: friends only.
    await tester.tap(find.byKey(const Key('post-audience')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('post-audience-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('post-reach')), findsNothing);
    await tester.tap(find.byKey(const Key('post-publish')));
    await tester.pumpAndSettle();
    expect(drafts.last.audience, Audience.close);
    expect(drafts.last.reach, PostReach.friends);
  });

  testWidgets('an edited post keeps its reach', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          editing: true,
          initialText: 'Było',
          initialReach: PostReach.third,
          onSubmit: (PostDraft d) async => null,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('3. stopień'), findsOneWidget);
    await tester.tap(find.byKey(const Key('post-reach')));
    await tester.pumpAndSettle();
    expect(find.text('Jak daleko ma dotrzeć?'), findsNothing);
  });

  testWidgets('the wall has chips for posts from two and three steps away', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: const MaterialApp(home: FeedScreen()),
      ),
    );
    await tester.runAsync(() => _settle());
    await tester.pump();
    final List<String> chips = <String>[
      for (final Element e in find.byType(ChoiceChip).evaluate())
        ((e.widget as ChoiceChip).label as Text).data!,
    ];
    expect(chips.take(5), <String>[
      'Wszystko',
      'Znajomi',
      '2. stopień',
      '3. stopień',
      'Przyjaciele',
    ]);

    await tester.tap(find.byKey(const Key('feed-filter-second')));
    await tester.pump();
    expect(find.text('Nic od znajomych znajomych'), findsOneWidget);
    await tester.tap(find.byKey(const Key('feed-filter-third')));
    await tester.pump();
    expect(find.text('Nic z trzeciego stopnia'), findsOneWidget);
    await tester.tap(find.byKey(const Key('feed-filter-friends')));
    await tester.pump();
    expect(find.text('Nic tu jeszcze nie ma od znajomych.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });
}
