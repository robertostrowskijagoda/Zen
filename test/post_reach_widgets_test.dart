import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
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

Widget _feed(MemoryLedgerDisk disk) => ProviderScope(
  overrides: [
    socialHubAutoHydrateProvider.overrideWithValue(false),
    signalTransportProvider.overrideWithValue(MemorySignalTransport()),
    ledgerNodeEnabledProvider.overrideWithValue(true),
    ledgerDiskProvider.overrideWithValue(disk),
  ],
  child: const MaterialApp(home: FeedScreen()),
);

void main() {
  testWidgets('the editor has no reach to pick: a new post starts public', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(500, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<PostDraft> drafts = <PostDraft>[];
    await tester.pumpWidget(
      MaterialApp(
        home: PostEditorScreen(
          onSubmit: (PostDraft d) async {
            drafts.add(d);
            return '';
          },
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('post-text')), 'Daleko');
    await tester.pump();
    expect(find.byKey(const Key('post-reach')), findsNothing);
    expect(find.text('Publiczny'), findsOneWidget);
    await tester.tap(find.byKey(const Key('post-publish')));
    await tester.pumpAndSettle();
    expect(drafts.last.audience, Audience.public);
  });

  testWidgets('a post written on the wall starts public', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_feed(MemoryLedgerDisk()));
    await tester.runAsync(() => _settle());
    await tester.pump();
    await tester.tap(find.byKey(const Key('feed-compose')));
    await tester.pumpAndSettle();
    expect(find.byType(PostEditorScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const Key('post-audience')),
        matching: find.text('Publiczny'),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('post-reach')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });

  testWidgets('the wall\'s chips say how far it looks, and the choice is '
      'kept', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await tester.pumpWidget(_feed(disk));
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
    PostReachService reach() => ProviderScope.containerOf(
      tester.element(find.byType(FeedScreen)),
    ).read(postReachProvider)!;
    // Friends of friends until the user picks otherwise.
    expect(reach().depth, kDefaultFeedDepth);

    await tester.tap(find.byKey(const Key('feed-filter-third')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.text('Nic z trzeciego stopnia'), findsOneWidget);
    expect(reach().depth, 3);
    // „Wszystko” keeps how far it looks.
    await tester.tap(find.byKey(const Key('feed-filter-all')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(reach().depth, 3);
    await tester.tap(find.byKey(const Key('feed-filter-second')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.text('Nic od znajomych znajomych'), findsOneWidget);
    await tester.tap(find.byKey(const Key('feed-filter-friends')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.text('Nic tu jeszcze nie ma od znajomych.'), findsOneWidget);
    expect(reach().depth, 1);

    // The app starts again on the same device: still friends only.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
    await tester.pumpWidget(_feed(disk));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(reach().depth, 1);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });
}
