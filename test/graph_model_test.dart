import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/graph/gate_prices.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/presentation/graph_screen.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

String addr(String hex) => PeerShareCodec.normalizeAddress('200::$hex');

final String _ania = addr('a1');
final String _bartek = addr('b2');
final String _celina = addr('c3');
final String _xawery = addr('e5');
final String _lucja = addr('f6');
final String _zenon = addr('d7');

FriendProfile _friend(String address, String name) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
);

SocialHubState _social(Map<String, String> people) =>
    SocialHubState.empty().copyWith(
      friends: <String, FriendProfile>{
        for (final MapEntry<String, String> e in people.entries)
          e.key: _friend(e.key, e.value),
      },
    );

/// Prices the next feature will provide, made up for the tests.
final class _Prices implements GatePriceSource {
  _Prices(this.direct, this.intro);

  final Map<String, GatePrice> direct;
  final Map<String, GatePrice> intro;

  @override
  GatePrice? gateOf(String target, {String? via}) =>
      via == null ? direct[target] : intro['$via>$target'];

  @override
  Listenable? get changes => null;
}

GraphScene _scene(List<GraphNode> nodes) {
  final GraphLayout layout = graphLayout(nodes, const Size(400, 400));
  final Map<String, int> index = <String, int>{
    for (int i = 0; i < nodes.length; i++) nodes[i].address: i,
  };
  final List<int> ef = <int>[];
  final List<int> et = <int>[];
  for (int i = 0; i < nodes.length; i++) {
    if (nodes[i].isFriend) {
      ef.add(-1);
      et.add(i);
    } else {
      for (final String v in nodes[i].via) {
        ef.add(index[v]!);
        et.add(i);
      }
    }
  }
  return GraphScene(
    layout: layout,
    from: Float32List.fromList(layout.xy),
    edgeFrom: Int32List.fromList(ef),
    edgeTo: Int32List.fromList(et),
    links: Int32List(0),
  );
}

void main() {
  final ZenColors zen = ZenTheme.dark().extension<ZenColors>()!;

  group('routes', () {
    // Ania knows Bartek and Xawery; Celina knows Xawery.
    MeetBook book() => MeetBook()
      ..friendLists[_ania] = <String, String>{
        _bartek: 'Bartek',
        _xawery: 'Xawery',
      }
      ..friendLists[_celina] = <String, String>{_xawery: 'Xawery'};

    test('without prices the cost is the number of steps', () {
      final GraphRoute r = graphRoute(
        friends: <String>[_ania, _celina],
        book: book(),
        target: _xawery,
      );
      expect(r.path, <String>[_ania, _xawery]);
      expect(r.cost.hops, 2);
      expect(r.cost.unknown, 2, reason: 'no price data at all');
      expect(
        graphPath(friends: <String>[_ania], book: book(), target: addr('99')),
        isEmpty,
      );
    });

    test('the cheapest way can be longer than the shortest one', () {
      final _Prices prices = _Prices(
        <String, GatePrice>{
          _ania: const GatePrice.free(),
          _bartek: const GatePrice.price(500, shown: '5 zł'),
        },
        <String, GatePrice>{'$_ania>$_bartek': const GatePrice.free()},
      );
      final List<String> friends = <String>[_ania, _bartek];
      final GraphRoute short = graphRoute(
        friends: friends,
        book: book(),
        target: _bartek,
        prices: prices,
      );
      expect(short.path, <String>[_bartek]);
      expect(short.cost, const RouteCost(hops: 1, price: 500));
      final GraphRoute cheap = graphRoute(
        friends: friends,
        book: book(),
        target: _bartek,
        prices: prices,
        goal: RouteGoal.cheapest,
      );
      expect(cheap.path, <String>[_ania, _bartek]);
      expect(cheap.cost, const RouteCost(hops: 2));
      expect(cheap.gates, <GatePrice?>[
        const GatePrice.free(),
        const GatePrice.free(),
      ]);
    });

    test('a step that needs consent costs more than a free one', () {
      final _Prices prices = _Prices(
        <String, GatePrice>{
          _ania: const GatePrice.free(),
          _celina: const GatePrice.free(),
        },
        <String, GatePrice>{
          '$_ania>$_xawery': const GatePrice.consent(),
          '$_celina>$_xawery': const GatePrice.free(),
        },
      );
      final GraphRoute r = graphRoute(
        friends: <String>[_ania, _celina],
        book: book(),
        target: _xawery,
        prices: prices,
        goal: RouteGoal.cheapest,
      );
      expect(r.path, <String>[_celina, _xawery]);
      expect(routeCostText(r.cost, r.gates), '2 kroki');
    });
  });

  group('filters', () {
    final List<GraphNode> nodes = <GraphNode>[
      GraphNode(address: _ania, name: 'Ania', ring: 1),
      GraphNode(address: _bartek, name: 'Bartek', ring: 2),
      GraphNode(address: _celina, name: 'Celina', ring: 3),
      GraphNode(
        address: _xawery,
        name: 'Xawery',
        ring: 4,
        via: <String>[_ania],
      ),
      GraphNode(
        address: _lucja,
        name: 'Łucja',
        ring: 4,
        via: <String>[_ania, _bartek],
      ),
    ];
    final GraphFacts facts = GraphFacts(
      statusOf: (String a) => a == _bartek
          ? const IntentStatus(kind: IntentKind.talk, setAt: 1)
          : null,
      openOf: (String a) => a == _celina ? OpenToMeet.friends : null,
      nationsOf: (String a) =>
          a == _ania ? const <String>['PL'] : const <String>[],
      nearby: (String a) => a == _bartek,
      mutual: <String, int>{
        _ania: 2,
        _bartek: 0,
        _celina: 1,
        _xawery: 1,
        _lucja: 2,
      },
    );
    List<String> shown(GraphFilters f) => <String>[
      for (final GraphNode n in nodes)
        if (f.passes(n, facts)) n.name,
    ];

    test('the default shows everyone', () {
      expect(shown(const GraphFilters()), hasLength(5));
      expect(const GraphFilters().isEmpty, isTrue);
    });

    test('circle, mutual friends, nationality, status, nearby', () {
      expect(shown(const GraphFilters(rings: <int>{4})), <String>[
        'Xawery',
        'Łucja',
      ]);
      expect(shown(const GraphFilters(minMutual: 2)), <String>[
        'Ania',
        'Łucja',
      ]);
      expect(shown(const GraphFilters(nationality: 'PL')), <String>['Ania']);
      expect(shown(const GraphFilters(withStatus: true)), <String>[
        'Bartek',
        'Celina',
      ], reason: 'a status or "open to meet"');
      expect(shown(const GraphFilters(nearby: true)), <String>['Bartek']);
      const GraphFilters two = GraphFilters(rings: <int>{1, 2}, minMutual: 1);
      expect(shown(two), <String>['Ania']);
      expect(two.active, 2);
      expect(two.copyWith(nationality: () => 'PL').active, 3);
    });
  });

  group('privacy', () {
    test('a friend who hides their list adds nobody to the graph', () {
      // Ania shows her list; Bartek does not (nothing reached this phone).
      final MeetBook book = MeetBook()
        ..friendLists[_ania] = <String, String>{_xawery: 'Xawery'};
      final List<GraphNode> nodes = buildGraph(
        social: _social(<String, String>{_ania: 'Ania', _bartek: 'Bartek'}),
        book: book,
        levelOf: (String _) => FriendLevel.friend,
        maxFriendsOfFriends: kGraphMaxNodes,
      );
      expect(
        nodes.map((GraphNode n) => n.name),
        unorderedEquals(<String>['Ania', 'Bartek', 'Xawery']),
      );
      expect(
        nodes.singleWhere((GraphNode n) => n.address == _xawery).via,
        <String>[_ania],
      );
      expect(friendLinks(<String>[_ania, _bartek], book), isEmpty);
      final Map<String, int> mutual = mutualCounts(nodes, book);
      expect(mutual[_bartek], 0);
      expect(
        graphRoute(
          friends: <String>[_ania, _bartek],
          book: book,
          target: _zenon,
        ).isEmpty,
        isTrue,
        reason: 'nobody known through Bartek',
      );
    });

    test('the dating badge shows only on people who opted in', () {
      final List<GraphNode> nodes = <GraphNode>[
        GraphNode(address: _ania, name: 'Ania', ring: 2),
        GraphNode(address: _bartek, name: 'Bartek', ring: 2),
        GraphNode(
          address: _xawery,
          name: 'Xawery',
          ring: 4,
          via: <String>[_ania],
        ),
      ];
      final GraphFacts facts = GraphFacts(
        openOf: (String a) => a == _xawery ? OpenToMeet.dates : null,
      );
      final GraphScene scene = _scene(nodes);
      final GraphLook statuses = graphLook(
        scene: scene,
        mode: GraphMode.statuses,
        facts: facts,
        zen: zen,
      );
      expect(
        <String?>[for (final NodeLook l in statuses.nodes) l.tag],
        <String?>[null, null, 'randki'],
      );
      // Other modes say nothing about it.
      for (final GraphMode m in <GraphMode>[GraphMode.friends, GraphMode.met]) {
        final GraphLook look = graphLook(
          scene: scene,
          mode: m,
          facts: facts,
          zen: zen,
        );
        expect(look.nodes.every((NodeLook l) => l.tag == null), isTrue);
      }
    });
  });

  test('gates: prices on the lines, nothing when there is no data', () {
    final List<GraphNode> nodes = <GraphNode>[
      GraphNode(address: _ania, name: 'Ania', ring: 2),
      GraphNode(
        address: _xawery,
        name: 'Xawery',
        ring: 4,
        via: <String>[_ania],
      ),
    ];
    final GraphScene scene = _scene(nodes);
    final GraphLook none = graphLook(
      scene: scene,
      mode: GraphMode.gates,
      facts: GraphFacts(),
      zen: zen,
    );
    expect(none.edges.every((EdgeLook e) => e.tag == null), isTrue);
    final GraphLook priced = graphLook(
      scene: scene,
      mode: GraphMode.gates,
      facts: GraphFacts(),
      zen: zen,
      prices: _Prices(
        <String, GatePrice>{_ania: const GatePrice.free()},
        <String, GatePrice>{
          '$_ania>$_xawery': const GatePrice.price(500, shown: '5 zł'),
        },
      ),
    );
    expect(
      <String?>[for (final EdgeLook e in priced.edges) e.tag],
      <String?>['za darmo', '5 zł'],
    );
  });

  test('layout: everyone gets a place, crowded rings spread, and the mode '
      'bands move people', () {
    final List<GraphNode> nodes = <GraphNode>[
      for (int i = 0; i < 5; i++)
        GraphNode(address: addr('a$i'), name: 'F$i', ring: 2),
      for (int i = 0; i < 3000; i++)
        GraphNode(
          address: addr('b$i'),
          name: 'N$i',
          ring: 4,
          via: <String>[addr('a${i % 5}')],
        ),
    ];
    final GraphLayout a = graphLayout(nodes, const Size(400, 400));
    expect(a.xy.length, nodes.length * 2);
    expect(a.radii.length, greaterThan(2), reason: 'the outer band spreads');
    final GraphFacts facts = GraphFacts(met: (String x) => x == addr('a0'));
    final GraphLayout b = graphLayout(
      nodes,
      const Size(400, 400),
      bandOf: (GraphNode n) =>
          graphBand(GraphMode.met, n, facts, const <String, PyramidMark>{}),
    );
    double from(GraphLayout l, int i) => (l.at(i) - l.center).distance;
    expect(from(b, 1), greaterThan(from(a, 1)), reason: 'not met: outwards');
    expect(from(b, 0), lessThan(from(b, 1)), reason: 'met: inside');
  });
}
