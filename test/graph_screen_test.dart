import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
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

    // Filters only for what there is data for.
    await tester.ensureVisible(find.byKey(const Key('graph-filter-far')));
    await tester.pump();
    expect(find.byKey(const Key('graph-filter-far')), findsOneWidget);
    expect(find.byKey(const Key('graph-filter-pyramid')), findsNothing);
    expect(find.byKey(const Key('graph-filter-status')), findsNothing);
    expect(find.byKey(const Key('graph-filter-nearby')), findsNothing);
    await tester.tap(find.byKey(const Key('graph-filter-far')));
    await tester.pump();
    expect(find.text('Widać: 2 z 5'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('graph-filter-friends')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('graph-filter-friends')));
    await tester.pump();
    expect(find.text('Widać: 3 z 5'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('graph-filter-all')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('graph-filter-all')));
    await tester.pump();
    expect(find.byKey(const Key('graph-count')), findsNothing);

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

    // Asking Ania to introduce: consent is the currency (no pyramid here).
    await tester.tap(find.byKey(const Key('graph-intro')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('intro-dialog')), findsOneWidget);
    expect(find.byKey(const Key('intro-pyramid-note')), findsNothing);
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
}
