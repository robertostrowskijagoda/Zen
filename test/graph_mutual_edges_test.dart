import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

final String _ania = addr('a1');
final String _bartek = addr('b2');
final String _celina = addr('c3');
final String _daria = addr('d4');
final String _xawery = addr('e5');

/// Pairs come out as (smaller, larger).
(String, String) _pair(String a, String b) =>
    a.compareTo(b) < 0 ? (a, b) : (b, a);

/// Friend lists as each friend shared them: friend -> the people on it.
MeetBook _book(Map<String, List<String>> lists) {
  final MeetBook book = MeetBook();
  lists.forEach((String friend, List<String> people) {
    book.friendLists[friend] = <String, String>{
      for (final String p in people) p: 'Osoba $p',
    };
  });
  return book;
}

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

void main() {
  group('friendLinks: two friends who know each other get one line', () {
    test('one-sided knowledge is enough: A has B on the list', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek],
      });
      expect(friendLinks(<String>[_ania, _bartek], book), <(String, String)>[
        _pair(_ania, _bartek),
      ]);
    });

    test('and the other way round: only B has A on the list', () {
      final MeetBook book = _book(<String, List<String>>{
        _bartek: <String>[_ania],
      });
      expect(friendLinks(<String>[_ania, _bartek], book), <(String, String)>[
        _pair(_ania, _bartek),
      ]);
    });

    test('both directions give the same single line, whatever the order', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek],
        _bartek: <String>[_ania],
      });
      final List<(String, String)> expected = <(String, String)>[
        _pair(_ania, _bartek),
      ];
      expect(friendLinks(<String>[_ania, _bartek], book), expected);
      expect(friendLinks(<String>[_bartek, _ania], book), expected);
    });

    test('no line when they do not know each other', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_xawery],
        _bartek: <String>[_daria],
      });
      expect(friendLinks(<String>[_ania, _bartek], book), isEmpty);
      expect(friendLinks(<String>[_ania, _bartek], MeetBook()), isEmpty);
      expect(friendLinks(const <String>[], book), isEmpty);
    });

    test('a line only joins two of my friends, never a friend of a friend', () {
      // Ania knows Bartek (a friend) and Xawery (not a friend of mine).
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek, _xawery],
        _bartek: <String>[_xawery],
      });
      final List<(String, String)> links = friendLinks(<String>[
        _ania,
        _bartek,
      ], book);
      expect(links, <(String, String)>[_pair(_ania, _bartek)]);
      expect(
        links.expand(((String, String) p) => <String>[p.$1, p.$2]),
        isNot(contains(_xawery)),
      );
    });

    test('asymmetric data: a friend who hides the list is still linked '
        'from the other side', () {
      // Bartek shows nothing (no list came), Ania has him on hers.
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek, _celina],
      });
      expect(
        friendLinks(<String>[_ania, _bartek, _celina], book),
        <(String, String)>[_pair(_ania, _bartek), _pair(_ania, _celina)],
      );
    });

    test('no loops: someone on their own list gets no line', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_ania],
      });
      expect(friendLinks(<String>[_ania], book), isEmpty);
      final MeetBook withOther = _book(<String, List<String>>{
        _ania: <String>[_ania, _bartek],
      });
      final List<(String, String)> links = friendLinks(<String>[
        _ania,
        _bartek,
      ], withOther);
      expect(links, hasLength(1));
      expect(links.every(((String, String) p) => p.$1 != p.$2), isTrue);
    });

    test('no duplicates: the same friend given twice, in other spellings', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek],
        _bartek: <String>[_ania],
      });
      final List<(String, String)> links = friendLinks(<String>[
        _ania,
        '  ${_ania.toUpperCase()} ',
        '200:0:0:0:0:0:0:a1',
        _bartek,
        _bartek,
      ], book);
      expect(links, <(String, String)>[_pair(_ania, _bartek)]);
    });

    test('addresses are compared normalised', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek],
      });
      expect(
        friendLinks(<String>['200:0:0:0:0:0:0:A1', '200::B2'], book),
        <(String, String)>[_pair(_ania, _bartek)],
      );
    });

    test('three friends who all know each other: three lines, once each; '
        'a chain does not close', () {
      final MeetBook all = _book(<String, List<String>>{
        _ania: <String>[_bartek, _celina],
        _bartek: <String>[_ania, _celina],
        _celina: <String>[_ania, _bartek],
      });
      final List<(String, String)> triangle = friendLinks(<String>[
        _celina,
        _ania,
        _bartek,
      ], all);
      expect(triangle, hasLength(3));
      expect(triangle.toSet(), <(String, String)>{
        _pair(_ania, _bartek),
        _pair(_ania, _celina),
        _pair(_bartek, _celina),
      });
      final MeetBook chain = _book(<String, List<String>>{
        _ania: <String>[_bartek],
        _celina: <String>[_bartek],
      });
      expect(
        friendLinks(<String>[_ania, _bartek, _celina], chain).toSet(),
        <(String, String)>{_pair(_ania, _bartek), _pair(_bartek, _celina)},
        reason: 'Ania and Celina do not know each other',
      );
    });

    test('the same input always gives the same lines in the same order', () {
      final MeetBook book = _book(<String, List<String>>{
        _celina: <String>[_ania, _daria],
        _bartek: <String>[_daria],
      });
      final List<(String, String)> first = friendLinks(<String>[
        _daria,
        _celina,
        _bartek,
        _ania,
      ], book);
      final List<(String, String)> second = friendLinks(<String>[
        _ania,
        _bartek,
        _celina,
        _daria,
      ], book);
      expect(first, second);
      expect(first, hasLength(3));
    });
  });

  group('buildGraph and the lines agree', () {
    test('a friend on a friend\'s list is not drawn twice, and gets a line '
        'with them', () {
      final MeetBook book = _book(<String, List<String>>{
        _ania: <String>[_bartek, _xawery],
      });
      final SocialHubState social = SocialHubState.empty().copyWith(
        book: FriendshipBook.restore(
          profiles: <String, FriendProfile>{
            _ania: _friend(_ania, 'Ania'),
            _bartek: _friend(_bartek, 'Bartek'),
          },
        ),
      );
      final List<GraphNode> nodes = buildGraph(
        social: social,
        book: book,
        levelOf: (String _) => FriendLevel.friend,
      );
      expect(
        nodes.map((GraphNode n) => n.address),
        unorderedEquals(<String>[_ania, _bartek, _xawery]),
      );
      expect(nodes.where((GraphNode n) => n.address == _bartek), hasLength(1));
      final GraphNode bartek = nodes.singleWhere(
        (GraphNode n) => n.address == _bartek,
      );
      expect(bartek.isFriend, isTrue, reason: 'stays in the friends circles');
      final List<(String, String)> links = friendLinks(<String>[
        for (final GraphNode n in nodes)
          if (n.isFriend) n.address,
      ], book);
      expect(links, <(String, String)>[_pair(_ania, _bartek)]);
    });
  });

  group('the picture: lines between friends who know each other', () {
    Future<List<(String, String)>> drawnLinks(
      WidgetTester tester, {
      required Map<String, String> friends,
      required Map<String, Map<String, String>> lists,
    }) async {
      tester.view.physicalSize = const Size(480, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final _Host host = _Host(friends);
      final MeetService meet = MeetService(
        host: host,
        store: MeetStore(MemoryLedgerDisk()),
      );
      await tester.runAsync(() async {
        for (final MapEntry<String, Map<String, String>> e in lists.entries) {
          await meet.handle(_list(e.key, e.value));
        }
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                book: FriendshipBook.restore(
                  profiles: <String, FriendProfile>{
                    for (final MapEntry<String, String> e in friends.entries)
                      e.key: _friend(e.key, e.value),
                  },
                ),
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
      final GraphPainter painter = tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .map((CustomPaint p) => p.painter)
          .whereType<GraphPainter>()
          .single;
      final List<GraphNode> nodes = painter.scene.layout.nodes;
      final List<int> raw = painter.scene.links.toList();
      expect(raw.length.isEven, isTrue);
      final List<(String, String)> out = <(String, String)>[
        for (int i = 0; i < raw.length; i += 2)
          _pair(nodes[raw[i]].address, nodes[raw[i + 1]].address),
      ];
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 5));
      });
      return out;
    }

    testWidgets('Ania has Bartek on her list: one line Ania-Bartek, none '
        'to Celina, none to the friend of a friend', (
      WidgetTester tester,
    ) async {
      final List<(String, String)> links = await drawnLinks(
        tester,
        friends: <String, String>{
          _ania: 'Ania',
          _bartek: 'Bartek',
          _celina: 'Celina',
        },
        lists: <String, Map<String, String>>{
          _ania: <String, String>{_bartek: 'Bartek', _xawery: 'Xawery'},
          _celina: const <String, String>{},
        },
      );
      expect(links, <(String, String)>[_pair(_ania, _bartek)]);
    });

    testWidgets('only Bartek has Ania on his list: the same line, drawn once', (
      WidgetTester tester,
    ) async {
      final List<(String, String)> links = await drawnLinks(
        tester,
        friends: <String, String>{_ania: 'Ania', _bartek: 'Bartek'},
        lists: <String, Map<String, String>>{
          _bartek: <String, String>{_ania: 'Ania'},
        },
      );
      expect(links, <(String, String)>[_pair(_ania, _bartek)]);
    });

    testWidgets('both have each other: still one line, no loops', (
      WidgetTester tester,
    ) async {
      final List<(String, String)> links = await drawnLinks(
        tester,
        friends: <String, String>{_ania: 'Ania', _bartek: 'Bartek'},
        lists: <String, Map<String, String>>{
          _ania: <String, String>{_bartek: 'Bartek', _ania: 'Ania'},
          _bartek: <String, String>{_ania: 'Ania'},
        },
      );
      expect(links, <(String, String)>[_pair(_ania, _bartek)]);
      expect(links.every(((String, String) p) => p.$1 != p.$2), isTrue);
    });

    testWidgets('friends who do not know each other get no line', (
      WidgetTester tester,
    ) async {
      final List<(String, String)> links = await drawnLinks(
        tester,
        friends: <String, String>{_ania: 'Ania', _bartek: 'Bartek'},
        lists: <String, Map<String, String>>{
          _ania: <String, String>{_xawery: 'Xawery'},
          _bartek: <String, String>{_xawery: 'Xawery'},
        },
      );
      expect(links, isEmpty, reason: 'a shared acquaintance is not a link');
    });
  });
}
