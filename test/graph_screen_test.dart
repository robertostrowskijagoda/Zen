import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/graph/gate_prices.dart';
import 'package:zen/src/features/meet/graph/graph_providers.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

final String _ania = addr('a1');
final String _bartek = addr('b2');
final String _celina = addr('c3');
final String _xawery = addr('e5');
final String _lucja = addr('f6');

/// Friends as the statuses see them.
final class _Host implements MeetHost {
  _Host(this.names);

  final Map<String, String> names;

  @override
  Future<void> send(String to, Map<String, dynamic> payload) async {}

  @override
  List<String> friends() => names.keys.toList();

  @override
  List<String> closeFriends() => const <String>[];

  @override
  bool isFriend(String a) =>
      names.containsKey(PeerShareCodec.normalizeAddress(a));

  @override
  bool isSelf(String a) => false;

  @override
  String nameOf(String a) =>
      names[PeerShareCodec.normalizeAddress(a)] ?? 'Ktoś';

  @override
  Future<void> notify(RuntimeSystemNotification n) async {}

  @override
  Future<void> dismissNotification(String slotKey) async {}
}

SignalTransportFrame _list(String from, Map<String, String> people) =>
    SignalTransportFrame(
      from: from,
      payload: <String, dynamic>{
        'type': MeetTypes.friendList,
        'l': <Map<String, String>>[
          for (final MapEntry<String, String> e in people.entries)
            <String, String>{'a': e.key, 'n': e.value},
        ],
        'd': 'list-of-$from',
      },
      receivedAtMillis: 0,
    );

FriendProfile _friend(String address, String name) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
);

/// Ania shared her list (Xawery, Łucja and Bartek), Celina shared an empty
/// one, Bartek nothing yet.
MeetBook _book() => MeetBook()
  ..friendLists[_ania] = <String, String>{
    _xawery: 'Xawery',
    _lucja: 'Łucja',
    _bartek: 'Bartek',
  };

/// Gate prices as the next feature will give them (made up for the test).
final class _GatePrices extends ChangeNotifier implements GatePriceSource {
  Map<String, GatePrice> _prices = const <String, GatePrice>{};

  void set(Map<String, GatePrice> prices) {
    _prices = prices;
    notifyListeners();
  }

  @override
  GatePrice? gateOf(String target, {String? via}) =>
      _prices[via == null ? target : '$via>$target'];

  @override
  Listenable? get changes => this;
}

void main() {
  test('friends who know each other are linked once', () {
    expect(
      friendLinks(<String>[_celina, _bartek, _ania], _book()),
      <(String, String)>[(_ania, _bartek)],
    );
  });

  test('the way to someone goes through the closest friend who knows them', () {
    final MeetBook book = _book()
      ..friendLists[_celina] = <String, String>{_xawery: 'Xawery'};
    expect(
      graphPath(
        friends: <String>[_celina, _ania, _bartek],
        book: book,
        target: _xawery,
      ),
      <String>[_celina, _xawery],
    );
    expect(
      graphPath(
        friends: <String>[_ania, _bartek, _celina],
        book: book,
        target: _xawery,
      ),
      <String>[_ania, _xawery],
    );
    expect(
      graphPath(friends: <String>[_ania], book: book, target: _bartek),
      <String>[_ania, _bartek],
      reason: 'Bartek is known only from Ania',
    );
    expect(
      graphPath(friends: <String>[_ania], book: book, target: addr('99')),
      isEmpty,
    );
  });

  testWidgets('graph: list diagnostics, filters, search with Polish letters, '
      'the way to a person and asking for an introduction', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(480, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Host host = _Host(<String, String>{
      _ania: 'Ania',
      _bartek: 'Bartek',
      _celina: 'Celina',
    });
    final MeetService meet = MeetService(
      host: host,
      store: MeetStore(MemoryLedgerDisk()),
    );
    await tester.runAsync(() async {
      await meet.handle(
        _list(_ania, <String, String>{
          _xawery: 'Xawery',
          _lucja: 'Łucja',
          _bartek: 'Bartek',
        }),
      );
      await meet.handle(_list(_celina, const <String, String>{}));
    });
    final MemorySignalTransport transport = MemorySignalTransport();
    // Introductions are signed: this phone has ledger keys and an address.
    final MemoryLedgerDisk ledger = MemoryLedgerDisk();
    await tester.runAsync(() => LedgerIdentity.loadOrCreate(ledger));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: <String, FriendProfile>{
                _ania: _friend(_ania, 'Ania'),
                _bartek: _friend(_bartek, 'Bartek'),
                _celina: _friend(_celina, 'Celina'),
              },
            ),
          ),
          signalTransportProvider.overrideWithValue(transport),
          ledgerDiskProvider.overrideWithValue(ledger),
          introServiceProvider.overrideWith((Ref ref) {
            final IntroService intro = IntroService(
              host: MeetEventHost(
                AppMeetHost(ref),
                address: () => addr('01'),
                name: () => 'Ja',
              ),
              disk: ledger,
              meet: () => ref.read(meetServiceProvider),
              friending: AppIntroFriending(ref),
            );
            ref.onDispose(intro.dispose);
            return intro;
          }),
          meetServiceProvider.overrideWithValue(meet),
          pyramidServiceProvider.overrideWithValue(
            PyramidService(
              host: MeetEventHost(host, address: () => '', name: () => 'Ja'),
              disk: MemoryLedgerDisk(),
            ),
          ),
        ],
        child: MaterialApp(theme: ZenTheme.dark(), home: const GraphScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Lists: from Ania only; Bartek's has not come, Celina does not show hers.
    expect(find.text('Listy znajomych: od 1 z 3 znajomych'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('graph-lists-diag')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('graph-lists-diag')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Lista jeszcze nie doszła'), findsOneWidget);
    expect(find.text('Nie pokazuje listy'), findsOneWidget);
    // Pressed directly: inside the expanding tile the tap point can land on
    // its header while the rows settle.
    tester
        .widget<TextButton>(find.byKey(Key('graph-diag-ask-$_bartek')))
        .onPressed!();
    await tester.pump();
    await tester.pump();
    expect(
      transport.sentSignals.where(
        (({String remoteAddress, Map<String, dynamic> payload}) s) =>
            s.payload['type'] == IntroTypes.ask &&
            s.payload['k'] == IntroKind.list.name &&
            PeerShareCodec.addressesEqual(s.remoteAddress, _bartek),
      ),
      hasLength(1),
    );
    expect(find.text('Poproszono'), findsOneWidget);

    // Modes: the pyramid one only inside a pyramid.
    for (final String m in <String>['friends', 'statuses', 'met', 'gates']) {
      expect(find.byKey(Key('graph-mode-$m')), findsOneWidget);
    }
    expect(find.byKey(const Key('graph-mode-pyramid')), findsNothing);

    // Filters in a sheet: circles off, then on again.
    Future<void> tapInSheet(String key) async {
      await tester.ensureVisible(find.byKey(Key(key)));
      await tester.pump();
      await tester.tap(find.byKey(Key(key)));
      await tester.pump();
    }

    await tester.ensureVisible(find.byKey(const Key('graph-filters')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('graph-filters')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('graph-filters-sheet')), findsOneWidget);
    expect(find.byKey(const Key('graph-nearby')), findsNothing);
    await tapInSheet('graph-ring-2');
    expect(find.text('Widać: 2 z 5'), findsOneWidget);
    await tapInSheet('graph-ring-2');
    await tapInSheet('graph-ring-4');
    expect(find.text('Widać: 3 z 5'), findsOneWidget);
    await tapInSheet('graph-mutual-1');
    expect(
      find.text('Widać: 1 z 5'),
      findsOneWidget,
      reason: 'only Bartek is on a friend\'s list',
    );
    await tapInSheet('graph-filters-clear');
    expect(find.byKey(const Key('graph-count')), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('graph-filters-sheet')), findsNothing);

    // Search without Polish letters finds Łucja.
    await tester.ensureVisible(find.byKey(const Key('graph-search')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('graph-search')), 'luc');
    await tester.pump();
    expect(find.byKey(Key('graph-hit-$_lucja')), findsOneWidget);
    expect(find.byKey(Key('graph-hit-$_xawery')), findsNothing);

    // Picking Xawery draws the way and opens the person.
    await tester.enterText(find.byKey(const Key('graph-search')), 'xaw');
    await tester.pump();
    await tester.ensureVisible(find.byKey(Key('graph-hit-$_xawery')));
    await tester.pump();
    await tester.tap(find.byKey(Key('graph-hit-$_xawery')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('graph-person-sheet')), findsOneWidget);
    expect(find.text('Ty → Ania → Xawery'), findsWidgets);
    expect(find.byKey(const Key('graph-letter')), findsOneWidget);
    expect(find.byKey(const Key('graph-opinion')), findsOneWidget);

    // Asking Ania to open the gate: she has not set a price (no pyramid
    // here), so she decides; the dialog also shows the cheapest way.
    await tester.tap(find.byKey(const Key('graph-intro')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('intro-dialog')), findsOneWidget);
    expect(find.byKey(const Key('reach-plan')), findsOneWidget);
    expect(find.byKey(const Key('reach-run')), findsNothing);
    await tester.enterText(find.byKey(const Key('intro-note')), 'Cześć!');
    await tester.tap(find.byKey(const Key('intro-send')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final List<Map<String, dynamic>> asks = <Map<String, dynamic>>[
      for (final ({String remoteAddress, Map<String, dynamic> payload}) s
          in transport.sentSignals)
        if (s.payload['type'] == IntroTypes.ask &&
            s.payload['k'] == IntroKind.intro.name &&
            PeerShareCodec.addressesEqual(s.remoteAddress, _ania))
          s.payload,
    ];
    expect(asks, hasLength(1));
    expect(asks.single['a'], _xawery);
    expect(asks.single['t'], 'Cześć!');
    expect(find.byKey(const Key('intro-mine')), findsOneWidget);

    // Who sees my list: on request.
    await tester.ensureVisible(
      find.byKey(const Key('meet-list-audience-onRequest')),
    );
    await tester.pump();
    tester
        .widget<ChoiceChip>(
          find.byKey(const Key('meet-list-audience-onRequest')),
        )
        .onSelected!(true);
    // The meeting book was first read outside the fake clock (above).
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    expect(meet.book.friendListAudience, FriendListAudience.onRequest);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });

  test('communities: people who know each other share a cluster, the '
      'biggest first, friends of friends join those who connect them', () {
    final String a = addr('a1');
    final String b = addr('b2');
    final String c = addr('c3');
    final String d = addr('d4');
    final String e = addr('e5');
    final String f = addr('f6');
    final String loner = addr('f7');
    final String far = addr('99');
    final SocialHubState social = SocialHubState.empty().copyWith(
      friends: <String, FriendProfile>{
        for (final String x in <String>[a, b, c, d, e, f, loner])
          x: _friend(x, 'N$x'),
      },
    );
    final MeetBook book = MeetBook()
      ..friendLists[a] = <String, String>{b: 'B', c: 'C', d: 'D'}
      ..friendLists[b] = <String, String>{a: 'A', c: 'C', d: 'D'}
      ..friendLists[c] = <String, String>{a: 'A', b: 'B'}
      ..friendLists[e] = <String, String>{f: 'F', far: 'Far'}
      ..friendLists[f] = <String, String>{e: 'E', far: 'Far'};
    final List<GraphNode> nodes = buildGraph(
      social: social,
      book: book,
      levelOf: (String _) => FriendLevel.friend,
    );
    final Map<String, int> cl = graphClusters(nodes, book);
    expect(<int>{cl[a]!, cl[b]!, cl[c]!, cl[d]!}, <int>{0}, reason: 'biggest');
    expect(<int>{cl[e]!, cl[f]!, cl[far]!}, <int>{1});
    expect(cl[loner], -1);
    // The same input gives the same groups.
    expect(graphClusters(nodes, book), cl);
    expect(graphClusters(const <GraphNode>[], book), isEmpty);
  });

  testWidgets('graph: pinch-zoom buttons zoom the picture and a friend opens '
      'with a profile button', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Host host = _Host(<String, String>{
      _ania: 'Ania',
      _bartek: 'Bartek',
    });
    final MeetService meet = MeetService(
      host: host,
      store: MeetStore(MemoryLedgerDisk()),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: <String, FriendProfile>{
                _ania: _friend(_ania, 'Ania'),
                _bartek: _friend(_bartek, 'Bartek'),
              },
            ),
          ),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          meetServiceProvider.overrideWithValue(meet),
          pyramidServiceProvider.overrideWithValue(
            PyramidService(
              host: MeetEventHost(host, address: () => '', name: () => 'Ja'),
              disk: MemoryLedgerDisk(),
            ),
          ),
        ],
        child: MaterialApp(theme: ZenTheme.dark(), home: const GraphScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    double scale() => tester
        .widget<InteractiveViewer>(find.byKey(const Key('graph-viewer')))
        .transformationController!
        .value
        .getMaxScaleOnAxis();
    expect(scale(), 1);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('graph-zoom-out')))
          .onPressed,
      isNull,
      reason: 'nothing to zoom out of',
    );
    await tester.ensureVisible(find.byKey(const Key('graph-zoom-in')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('graph-zoom-in')));
    await tester.pump();
    expect(scale(), closeTo(1.6, 0.001));
    await tester.tap(find.byKey(const Key('graph-zoom-in')));
    await tester.pump();
    expect(scale(), closeTo(2.56, 0.001));
    for (int i = 0; i < 12; i++) {
      await tester.tap(
        find.byKey(const Key('graph-zoom-in')),
        warnIfMissed: false,
      );
      await tester.pump();
    }
    expect(scale(), lessThanOrEqualTo(12.0001));
    for (int i = 0; i < 12; i++) {
      await tester.tap(
        find.byKey(const Key('graph-zoom-out')),
        warnIfMissed: false,
      );
      await tester.pump();
    }
    expect(scale(), closeTo(1, 0.001));

    // A friend found by search: the card leads to their profile.
    await tester.ensureVisible(find.byKey(const Key('graph-search')));
    await tester.pump();
    await tester.enterText(find.byKey(const Key('graph-search')), 'ani');
    await tester.pump();
    await tester.tap(find.byKey(Key('graph-hit-$_ania')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('graph-person-sheet')), findsOneWidget);
    expect(find.byKey(const Key('graph-profile')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
  testWidgets('graph modes: legends, "open to meet" only for who opted in, '
      'gates without data and with prices, the cheapest route', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(480, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final _Host host = _Host(<String, String>{
      _ania: 'Ania',
      _bartek: 'Bartek',
    });
    final MeetService meet = MeetService(
      host: host,
      store: MeetStore(MemoryLedgerDisk()),
    );
    late final OpenToMeetService open;
    await tester.runAsync(() async {
      // Made outside the fake clock: its queue of work is a future, and
      // one made in the fake zone would never go on in here.
      open = OpenToMeetService(host: host, disk: MemoryLedgerDisk());
      await meet.handle(_list(_ania, <String, String>{_xawery: 'Xawery'}));
      // Ania opted in on her dating profile; Bartek did not.
      await open.handle(
        SignalTransportFrame(
          from: _ania,
          payload: <String, dynamic>{
            'type': OpenToMeetService.frameType,
            'o': 'd',
            'xs': 's',
          },
          receivedAtMillis: 0,
        ),
      );
    });
    final _GatePrices prices = _GatePrices();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              friends: <String, FriendProfile>{
                _ania: _friend(_ania, 'Ania'),
                _bartek: _friend(_bartek, 'Bartek'),
              },
            ),
          ),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          meetServiceProvider.overrideWithValue(meet),
          openToMeetServiceProvider.overrideWithValue(open),
          gatePriceSourceProvider.overrideWithValue(prices),
          pyramidServiceProvider.overrideWithValue(
            PyramidService(
              host: MeetEventHost(host, address: () => '', name: () => 'Ja'),
              disk: MemoryLedgerDisk(),
            ),
          ),
        ],
        child: MaterialApp(theme: ZenTheme.dark(), home: const GraphScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();

    Future<void> tapKey(Key key) async {
      await tester.ensureVisible(find.byKey(key));
      await tester.pump();
      await tester.tap(find.byKey(key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> closeSheet() async {
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    Future<void> openFromSearch(String query, String address) async {
      await tester.ensureVisible(find.byKey(const Key('graph-search')));
      await tester.pump();
      await tester.enterText(find.byKey(const Key('graph-search')), query);
      await tester.pump();
      await tapKey(Key('graph-hit-$address'));
    }

    expect(find.byKey(const Key('graph-legend-friends')), findsOneWidget);

    // Statuses: the legend has the badge; only Ania's card has it.
    await tapKey(const Key('graph-mode-statuses'));
    expect(find.byKey(const Key('graph-legend-statuses')), findsOneWidget);
    expect(find.byKey(const Key('graph-legend-open')), findsOneWidget);
    await openFromSearch('ani', _ania);
    expect(find.byKey(const Key('graph-open-pill')), findsOneWidget);
    expect(find.text('Szuka: randki'), findsOneWidget);
    await closeSheet();
    await openFromSearch('bart', _bartek);
    expect(find.byKey(const Key('graph-person-sheet')), findsOneWidget);
    expect(find.byKey(const Key('graph-open-pill')), findsNothing);
    await closeSheet();

    // Met in person.
    await tapKey(const Key('graph-mode-met'));
    expect(find.byKey(const Key('graph-legend-met')), findsOneWidget);
    expect(find.byKey(const Key('graph-legend-statuses')), findsNothing);

    // Gates: no data yet, said so.
    await tapKey(const Key('graph-mode-gates'));
    expect(find.byKey(const Key('graph-gates-nodata')), findsOneWidget);
    // Prices arrive (the source tells the graph).
    prices.set(<String, GatePrice>{
      _ania: const GatePrice.free(),
      '$_ania>$_xawery': const GatePrice.price(500, shown: '5 zł'),
    });
    await tester.pump();
    expect(find.byKey(const Key('graph-gates-nodata')), findsNothing);

    // Route: a hint first, then the way to Xawery with its price.
    await tapKey(const Key('graph-path-clear'));
    await tapKey(const Key('graph-mode-route'));
    expect(
      find.text(
        'Dotknij osoby na grafie albo wyszukaj ją, żeby zobaczyć drogę.',
      ),
      findsOneWidget,
    );
    await openFromSearch('xaw', _xawery);
    expect(find.byKey(const Key('graph-gate')), findsOneWidget);
    expect(find.text('5 zł'), findsWidgets);
    await closeSheet();
    expect(
      find.text('Ty → Ania → Xawery\n2 kroki · płatne: 5 zł'),
      findsOneWidget,
    );
    await tapKey(const Key('graph-goal-cheapest'));
    expect(
      find.text('Ty → Ania → Xawery\n2 kroki · płatne: 5 zł'),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}
