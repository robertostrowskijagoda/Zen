import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/pebbles/pebble_card.dart';
import 'package:zen/src/features/pebbles/pebble_hosting.dart';
import 'package:zen/src/features/pebbles/pebble_service.dart';
import 'package:zen/src/features/pebbles/pebble_store.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_code_screen.dart';
import 'package:zen/src/features/pebbles/presentation/pebble_detail_screen.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

// The author's own pebble right after publishing: with nobody to ask it
// says so honestly, and "Losuj ponownie" never pretends to work.

final class _Peers implements PebblePeers {
  final List<String> friendList = <String>[];
  final Set<String> blocked = <String>{};

  @override
  String? accountOf(String address) => null;

  @override
  List<String> addressesOfAccount(String account) => const <String>[];

  @override
  List<String> friends() => friendList;

  @override
  bool isBlocked(String address) => blocked.contains(address);

  @override
  bool isFriend(String address) => friendList.contains(address);

  @override
  List<PebbleKeeperCandidate> keeperCandidates() => <PebbleKeeperCandidate>[
    for (final String f in friendList) PebbleKeeperCandidate(address: f),
  ];
}

const String _friendB = '200:aaaa:bbbb:cccc:dddd:eeee:ffff:0001';

void main() {
  late LedgerKeyPair key;
  late PebbleCard card;
  final Uint8List design = Uint8List.fromList(List<int>.filled(1000, 7));

  setUpAll(() async {
    key = await LedgerKeyPair.generate();
    card = await PebbleCard.sign(
      key: key,
      design: design,
      createdSeconds: 1767225600,
      look: const PebbleCardLook(
        shape: 2,
        seed: 9,
        material: 1,
        mainColour: 0x888888,
        secondColour: 0x222222,
      ),
      name: 'Kamyk testowy',
      note: 'przy ławce',
      authorName: 'Tester',
    );
  });

  Future<(PebbleService, _Peers, MemorySignalTransport)> pumpOwn(
    WidgetTester tester, {
    required List<String> friends,
    List<String> later = const <String>[],
    double textScale = 1,
  }) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Peers peers = _Peers()..friendList.addAll(friends);
    final MemorySignalTransport transport = MemorySignalTransport();
    // Made off the frame clock: the hosting's queue starts in that zone.
    final PebbleService service = (await tester.runAsync(() async {
      final PebbleStore store = PebbleStore(MemoryLedgerDisk());
      final PebbleService service = PebbleService(
        store: store,
        hosting: PebbleHosting(
          transport: transport,
          store: store,
          peers: peers,
          accountKey: () => key,
          serveCollected: () => true,
        ),
      );
      await service.start();
      await service.hosting.publish(card, design);
      return service;
    }))!;
    peers.friendList.addAll(later);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          pebbleServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          theme: ZenTheme.dark(),
          builder: (BuildContext context, Widget? child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: PebbleDetailScreen(card: card, justPublished: true),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    return (service, peers, transport);
  }

  Future<void> scrollTo(WidgetTester tester, Finder f) => tester
      .scrollUntilVisible(f, 200, scrollable: find.byType(Scrollable).first);

  for (final double scale in <double>[1, 2]) {
    testWidgets('no friends: the honest state, no "Losuj ponownie" '
        '(320 px, text ×$scale)', (WidgetTester tester) async {
      await pumpOwn(tester, friends: const <String>[], textScale: scale);
      final String info = tester
          .widget<Text>(
            find.descendant(
              of: find.byKey(const Key('pebble-published-info')),
              matching: find.byType(Text),
            ),
          )
          .data!;
      expect(info, isNot(contains('poprosiłeś')));
      final Finder count = find.byKey(const Key('pebble-keepers-count'));
      await scrollTo(tester, count);
      expect(
        tester.widget<Text>(count).data,
        'Nie masz jeszcze znajomych, którzy mogliby przechować kamyczek. '
        'Gdy dodasz znajomych, Zen poprosi ich sam.',
      );
      expect(find.text('Losuj ponownie'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('every friend asked already: "Losuj ponownie" is off and '
      'says why', (WidgetTester tester) async {
    final (PebbleService service, _, _) = await pumpOwn(
      tester,
      friends: const <String>[_friendB],
      textScale: 2,
    );
    expect(service.store.keepersOf(card.id), hasLength(1));
    final Finder info = find.descendant(
      of: find.byKey(const Key('pebble-published-info')),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(info).data, contains('poprosiłeś'));
    final Finder why = find.byKey(const Key('pebble-keepers-nobody-new'));
    await scrollTo(tester, why);
    expect(why, findsOneWidget);
    final TextButton button = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('Losuj ponownie'),
        matching: find.byType(TextButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a new friend: "Losuj ponownie" asks them and tells so', (
    WidgetTester tester,
  ) async {
    final (PebbleService service, _, _) = await pumpOwn(
      tester,
      friends: const <String>[_friendB],
      later: const <String>['200:aaaa:bbbb:cccc:dddd:eeee:ffff:0002'],
    );
    await scrollTo(tester, find.byKey(const Key('pebble-keepers-section')));
    // Pressed off the frame clock, where the hosting's queue runs.
    await tester.runAsync(() async {
      await tester.tap(find.text('Losuj ponownie'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(service.store.keepersOf(card.id), hasLength(2));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('Poproszono 1 znajomego o przechowanie kamyczka.'),
      findsOneWidget,
    );
  });

  double contrast(Color a, Color b) {
    final double la = a.computeLuminance();
    final double lb = b.computeLuminance();
    return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
  }

  for (final (String name, ThemeData theme) in <(String, ThemeData)>[
    ('dark', ZenTheme.dark()),
    ('light', ZenTheme.light()),
  ]) {
    testWidgets('"Pokaż kod": dark title and back arrow on the white page '
        'in the $name theme', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => PebbleCodeScreen.open(context, card),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final RichText title = tester.widget<RichText>(
        find.descendant(
          of: find.byKey(const Key('pebble-code-title')),
          matching: find.byType(RichText),
        ),
      );
      final Color ink = title.text.style!.color!;
      expect(contrast(ink, ZenFixed.qrPaper), greaterThanOrEqualTo(7));
      final Color arrow = IconTheme.of(
        tester.element(find.byType(BackButtonIcon)),
      ).color!;
      expect(contrast(arrow, ZenFixed.qrPaper), greaterThanOrEqualTo(4.5));
    });
  }

  testWidgets('a photo page keeps white type on black in a light theme', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ZenTheme.light(),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            appBar: zenFixedAppBar(
              context,
              background: ZenFixed.photoBackdrop,
              foreground: ZenFixed.onPhoto,
              title: const Text('2 / 5', key: Key('photo-title')),
            ),
          ),
        ),
      ),
    );
    final RichText title = tester.widget<RichText>(
      find.descendant(
        of: find.byKey(const Key('photo-title')),
        matching: find.byType(RichText),
      ),
    );
    expect(
      contrast(title.text.style!.color!, ZenFixed.photoBackdrop),
      greaterThanOrEqualTo(7),
    );
  });
}
