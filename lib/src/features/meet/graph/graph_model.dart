import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/meet/graph/gate_prices.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Most people drawn on the graph (friends of friends past it are still
/// found by search).
const int kGraphMaxNodes = 5000;

/// Most people drawn further away than friends of friends (known from
/// gates friends passed on, or open to meet further out).
const int kGraphMaxFar = 1500;

/// What the graph shows. Each mode only colours what this phone already
/// knows; none of them asks anyone for more.
enum GraphMode {
  /// Who knows whom, closeness (the default).
  friends,

  /// Statuses, online, "Szukam: randki/znajomości".
  statuses,

  /// Met in person, closeness levels as line styles.
  met,

  /// Members of this person's pyramid, their line and levels.
  pyramid,

  /// Gate prices on the lines (paid introductions, message prices).
  gates,

  /// The shortest or cheapest way to a person.
  route,

  /// How the graph grew: 3, 6, 12 months ago (dates kept on this phone).
  time,

  /// Friends who alone connect circles, and circles without connections.
  bridges,

  /// Friends not talked to or met for a long time (only for this person).
  neglect;

  String get label => switch (this) {
    GraphMode.friends => t('Znajomi'),
    GraphMode.statuses => t('Statusy'),
    GraphMode.met => t('Spotkani'),
    GraphMode.pyramid => t('Piramida'),
    GraphMode.gates => t('Bramy'),
    GraphMode.route => t('Ścieżka'),
    GraphMode.time => t('Oś czasu'),
    GraphMode.bridges => t('Mosty'),
    GraphMode.neglect => t('Dawno'),
  };
}

/// A person drawn on the graph.
final class GraphNode {
  GraphNode({
    required this.address,
    required this.name,
    required this.ring,
    this.friend,
    List<String>? via,
  }) : via = via ?? <String>[];

  final String address;
  final String name;

  /// 1 = przyjaciele, 2 = znajomi, 3 = słabi znajomi, 4 = znajomi znajomych,
  /// 5 = further away (through gates friends passed on, or open to meet).
  final int ring;
  final FriendProfile? friend;

  /// Friends who connect to them (for friends of friends); for people
  /// further away, the people drawn who know them.
  final List<String> via;

  /// Where the layout put them (the end of an animation).
  Offset at = Offset.zero;

  bool get isFriend => ring < 4;

  /// Further away than friends of friends.
  bool get isFar => ring >= 5;
}

/// Someone known beyond friends of friends: their own name and the people
/// who know them (gatekeepers, or the friend of a friend who passed on
/// that they are open to meet).
typedef FarPerson = ({String name, Set<String> via});

/// Builds the rings: friends by level, then friends of friends from the
/// lists friends shared, then [far] people (ring 5) known through someone
/// already drawn. Nothing but what reached this phone: a friend who does
/// not show their list adds nobody. Addresses in [keep] are drawn even past
/// the limit (the person picked in search). [self]: this person's own
/// addresses, never drawn as someone else.
List<GraphNode> buildGraph({
  required SocialHubState social,
  required MeetBook book,
  required FriendLevel Function(String address) levelOf,
  int maxFriendsOfFriends = 80,
  Set<String> keep = const <String>{},
  Map<String, FarPerson> far = const <String, FarPerson>{},
  int maxFar = kGraphMaxFar,
  bool Function(String address)? self,
}) {
  final List<GraphNode> nodes = <GraphNode>[];
  final Set<String> mine = <String>{};
  final List<String> order = <String>[];
  for (final FriendProfile f in social.acceptedFriends) {
    final String a = PeerShareCodec.normalizeAddress(f.address);
    if (!mine.add(a)) {
      continue;
    }
    order.add(a);
    final int ring = switch (levelOf(f.address)) {
      FriendLevel.close => 1,
      FriendLevel.friend => 2,
      FriendLevel.weak => 3,
    };
    nodes.add(
      GraphNode(address: a, name: social.nameFor(f), ring: ring, friend: f),
    );
  }
  final Map<String, GraphNode> fof = <String, GraphNode>{};
  for (final String friend in order) {
    book.friendsOf(friend).forEach((String a, String name) {
      if (mine.contains(a) || (self?.call(a) ?? false)) {
        return;
      }
      final GraphNode? had = fof[a];
      if (had != null) {
        had.via.add(friend);
      } else if (fof.length < maxFriendsOfFriends || keep.contains(a)) {
        fof[a] = GraphNode(
          address: a,
          name: name.isEmpty ? t('ktoś') : name,
          ring: 4,
          via: <String>[friend],
        );
      }
    });
  }
  nodes.addAll(fof.values);
  if (far.isEmpty) {
    return nodes;
  }
  // Further out, step by step: someone is drawn once a person who knows
  // them is (so every one of them hangs on a line to the middle).
  final Set<String> drawn = <String>{
    for (final GraphNode n in nodes) n.address,
  };
  final Map<String, FarPerson> left = <String, FarPerson>{
    for (final MapEntry<String, FarPerson> e in far.entries)
      if (!drawn.contains(PeerShareCodec.normalizeAddress(e.key)) &&
          !(self?.call(PeerShareCodec.normalizeAddress(e.key)) ?? false))
        PeerShareCodec.normalizeAddress(e.key): e.value,
  };
  int added = 0;
  bool grew = true;
  while (grew && left.isNotEmpty) {
    grew = false;
    final List<GraphNode> wave = <GraphNode>[];
    final List<String> keys = left.keys.toList()..sort();
    for (final String a in keys) {
      if (added >= maxFar && !keep.contains(a)) {
        continue;
      }
      final List<String> via = <String>[
        for (final String v in left[a]!.via)
          if (drawn.contains(PeerShareCodec.normalizeAddress(v)))
            PeerShareCodec.normalizeAddress(v),
      ]..sort();
      if (via.isEmpty) {
        continue;
      }
      final String name = left[a]!.name;
      wave.add(
        GraphNode(
          address: a,
          name: name.isEmpty ? t('ktoś') : name,
          ring: 5,
          via: via,
        ),
      );
      added++;
    }
    for (final GraphNode n in wave) {
      left.remove(n.address);
      drawn.add(n.address);
      nodes.add(n);
      grew = true;
    }
  }
  return nodes;
}

/// Two friends who know each other (one has the other on the list they
/// shared): each pair once, in a stable order.
List<(String, String)> friendLinks(Iterable<String> friends, MeetBook book) {
  final List<String> mine =
      friends.map(PeerShareCodec.normalizeAddress).toSet().toList()..sort();
  final Set<String> known = mine.toSet();
  final Set<String> seen = <String>{};
  final List<(String, String)> out = <(String, String)>[];
  for (final String a in mine) {
    for (final String b in book.friendsOf(a).keys) {
      if (b == a || !known.contains(b)) {
        continue;
      }
      final (String, String) pair = a.compareTo(b) < 0 ? (a, b) : (b, a);
      if (seen.add('${pair.$1}|${pair.$2}')) {
        out.add(pair);
      }
    }
  }
  return out;
}

/// How many of this person's friends know each person: for a friend, the
/// other friends who have them on their shared list; for a friend of a
/// friend, the friends who connect them.
Map<String, int> mutualCounts(List<GraphNode> nodes, MeetBook book) {
  final Map<String, int> out = <String, int>{};
  for (final GraphNode n in nodes) {
    if (n.isFriend) {
      for (final String a in book.friendsOf(n.address).keys) {
        out.update(a, (int c) => c + 1, ifAbsent: () => 1);
      }
    }
  }
  return <String, int>{
    for (final GraphNode n in nodes)
      n.address: n.isFriend
          ? (out[n.address] ?? 0)
          : (n.isFar ? 0 : n.via.length),
  };
}

/// Communities among the people on the graph (a simple label propagation
/// over "knows": friends who know each other, and friends of friends with
/// the friends who connect them). The result maps an address to a cluster
/// number: 0, 1, … for groups of two or more (the biggest first), -1 for
/// everyone who belongs to no group. Deterministic for the same input.
Map<String, int> graphClusters(List<GraphNode> nodes, MeetBook book) {
  final Set<String> known = <String>{
    for (final GraphNode n in nodes) n.address,
  };
  final Map<String, Set<String>> adj = <String, Set<String>>{
    for (final String a in known) a: <String>{},
  };
  void join(String a, String b) {
    if (a != b && known.contains(a) && known.contains(b)) {
      adj[a]!.add(b);
      adj[b]!.add(a);
    }
  }

  for (final GraphNode n in nodes) {
    if (n.isFriend) {
      for (final String other in book.friendsOf(n.address).keys) {
        join(n.address, PeerShareCodec.normalizeAddress(other));
      }
    } else {
      for (final String v in n.via) {
        join(n.address, v);
      }
    }
  }
  final List<String> order = known.toList()..sort();
  final Map<String, String> label = <String, String>{
    for (final String a in order) a: a,
  };
  for (int round = 0; round < 12; round++) {
    bool changed = false;
    for (final String a in order) {
      final Map<String, int> counts = <String, int>{};
      for (final String n in adj[a]!) {
        counts.update(label[n]!, (int c) => c + 1, ifAbsent: () => 1);
      }
      if (counts.isEmpty) {
        continue;
      }
      String best = counts.keys.first;
      for (final MapEntry<String, int> e in counts.entries) {
        final int c = counts[best]!;
        if (e.value > c || (e.value == c && e.key.compareTo(best) < 0)) {
          best = e.key;
        }
      }
      if (best != label[a]) {
        label[a] = best;
        changed = true;
      }
    }
    if (!changed) {
      break;
    }
  }
  final Map<String, List<String>> groups = <String, List<String>>{};
  for (final String a in order) {
    groups.putIfAbsent(label[a]!, () => <String>[]).add(a);
  }
  final List<List<String>> real =
      <List<String>>[
        for (final List<String> g in groups.values)
          if (g.length >= 2) g,
      ]..sort((List<String> x, List<String> y) {
        final int bySize = y.length.compareTo(x.length);
        return bySize != 0 ? bySize : x.first.compareTo(y.first);
      });
  final Map<String, int> out = <String, int>{
    for (final String a in order) a: -1,
  };
  for (int i = 0; i < real.length; i++) {
    for (final String a in real[i]) {
      out[a] = i;
    }
  }
  return out;
}

/// A name for each community: the chat group most of its people share
/// (when at least half of them, and two or more, are in it), else
/// "Krąg {name}" after the friend in it who knows most of the others.
/// [groups]: group name → its members (normalised addresses).
Map<int, String> clusterNames(
  List<GraphNode> nodes,
  Map<String, int> clusters, {
  Map<String, Set<String>> groups = const <String, Set<String>>{},
  Map<String, int> mutual = const <String, int>{},
}) {
  final Map<int, List<GraphNode>> members = <int, List<GraphNode>>{};
  for (final GraphNode n in nodes) {
    final int c = clusters[n.address] ?? -1;
    if (c >= 0) {
      members.putIfAbsent(c, () => <GraphNode>[]).add(n);
    }
  }
  final List<String> groupNames = groups.keys.toList()..sort();
  final Map<int, String> out = <int, String>{};
  for (final MapEntry<int, List<GraphNode>> e in members.entries) {
    final List<GraphNode> people = e.value;
    String? best;
    int bestCount = 0;
    for (final String g in groupNames) {
      final Set<String> inGroup = groups[g]!;
      int c = 0;
      for (final GraphNode n in people) {
        if (inGroup.contains(n.address)) {
          c++;
        }
      }
      if (c > bestCount) {
        best = g;
        bestCount = c;
      }
    }
    if (best != null && bestCount >= 2 && bestCount * 2 >= people.length) {
      out[e.key] = best;
      continue;
    }
    final List<GraphNode> friends =
        people.where((GraphNode n) => n.isFriend).toList()
          ..sort((GraphNode a, GraphNode b) {
            final int byMutual = (mutual[b.address] ?? 0).compareTo(
              mutual[a.address] ?? 0,
            );
            return byMutual != 0 ? byMutual : a.name.compareTo(b.name);
          });
    final GraphNode lead = friends.isNotEmpty ? friends.first : people.first;
    out[e.key] = t('Krąg: {name}', {'name': lead.name});
  }
  return out;
}

// ---- routes ----

/// What the route should be best at.
enum RouteGoal { shortest, cheapest }

/// What a route costs: steps, the sum of known prices, how many steps
/// need someone's consent and how many have no price data.
@immutable
final class RouteCost {
  const RouteCost({
    this.hops = 0,
    this.price = 0,
    this.consents = 0,
    this.unknown = 0,
  });

  final int hops;
  final int price;
  final int consents;
  final int unknown;

  RouteCost plus(GatePrice? gate) => RouteCost(
    hops: hops + 1,
    price: price + (gate?.kind == GateKind.price ? gate!.amount : 0),
    consents: consents + ((gate?.consent ?? false) ? 1 : 0),
    unknown: unknown + (gate == null ? 1 : 0),
  );

  /// Shortest: fewer steps, then cheaper. Cheapest: cheaper, fewer
  /// consents, more known, then fewer steps.
  int compareFor(RouteGoal goal, RouteCost o) {
    final List<(int, int)> keys = goal == RouteGoal.shortest
        ? <(int, int)>[
            (hops, o.hops),
            (price, o.price),
            (consents, o.consents),
            (unknown, o.unknown),
          ]
        : <(int, int)>[
            (price, o.price),
            (consents, o.consents),
            (unknown, o.unknown),
            (hops, o.hops),
          ];
    for (final (int a, int b) in keys) {
      if (a != b) {
        return a.compareTo(b);
      }
    }
    return 0;
  }

  @override
  bool operator ==(Object other) =>
      other is RouteCost &&
      other.hops == hops &&
      other.price == price &&
      other.consents == consents &&
      other.unknown == unknown;

  @override
  int get hashCode => Object.hash(hops, price, consents, unknown);

  @override
  String toString() => 'RouteCost($hops, $price, $consents, $unknown)';
}

/// The way from this person to someone: the addresses after "Ty" (the
/// last is the target), the gate of each step and what it all costs.
@immutable
final class GraphRoute {
  const GraphRoute({
    this.path = const <String>[],
    this.gates = const <GatePrice?>[],
    this.cost = const RouteCost(),
  });

  final List<String> path;
  final List<GatePrice?> gates;
  final RouteCost cost;

  bool get isEmpty => path.isEmpty;
}

/// The best way to [target] over what is known: this person's [friends]
/// (closest first; on a tie the closer friend wins), the lists they shared
/// and — with [friendsOf] — what friends passed on about people further
/// away. Each step costs what [prices] says (nothing known: one hop).
/// Dijkstra with a heap, any number of steps; empty when [target] cannot be
/// reached.
GraphRoute graphRoute({
  required List<String> friends,
  required MeetBook book,
  required String target,
  GatePriceSource prices = const NoGatePrices(),
  RouteGoal goal = RouteGoal.shortest,
  Map<String, String> Function(String person)? friendsOf,
}) {
  final String goalAddress = PeerShareCodec.normalizeAddress(target);
  const String me = '';
  final Set<String> walked = <String>{};
  final Map<String, RouteCost> best = <String, RouteCost>{
    me: const RouteCost(),
  };
  final Map<String, String> parent = <String, String>{};
  final Map<String, GatePrice?> gateTo = <String, GatePrice?>{};
  final Set<String> done = <String>{};
  final _Heap heap = _Heap(goal)..push(me, const RouteCost());
  final List<String> mine = <String>[
    for (final String f in friends) PeerShareCodec.normalizeAddress(f),
  ];
  while (heap.isNotEmpty) {
    final (String at, RouteCost cost) = heap.pop();
    if (!done.add(at)) {
      continue;
    }
    if (at == goalAddress) {
      break;
    }
    final Iterable<String> next = at == me
        ? mine
        : (friendsOf ?? book.friendsOf)(
            at,
          ).keys.map(PeerShareCodec.normalizeAddress);
    for (final String n in next) {
      if (done.contains(n) || n == me) {
        continue;
      }
      final GatePrice? gate = at == me
          ? prices.gateOf(n)
          : prices.gateOf(n, via: at);
      final RouteCost c = cost.plus(gate);
      final RouteCost? had = best[n];
      if (had == null || c.compareFor(goal, had) < 0) {
        best[n] = c;
        parent[n] = at;
        gateTo[n] = gate;
        heap.push(n, c);
      }
    }
  }
  if (!parent.containsKey(goalAddress)) {
    return const GraphRoute();
  }
  final List<String> path = <String>[];
  final List<GatePrice?> gates = <GatePrice?>[];
  String at = goalAddress;
  while (at != me && walked.add(at)) {
    path.add(at);
    gates.add(gateTo[at]);
    at = parent[at]!;
  }
  return GraphRoute(
    path: path.reversed.toList(),
    gates: gates.reversed.toList(),
    cost: best[goalAddress]!,
  );
}

/// The shortest way (in steps) to [target]: see [graphRoute].
List<String> graphPath({
  required List<String> friends,
  required MeetBook book,
  required String target,
}) => graphRoute(friends: friends, book: book, target: target).path;

/// A small binary heap for [graphRoute]: by cost, then by the order
/// pushed (so ties keep the order of the friends).
final class _Heap {
  _Heap(this.goal);

  final RouteGoal goal;
  final List<(String, RouteCost, int)> _items = <(String, RouteCost, int)>[];
  int _seq = 0;

  bool get isNotEmpty => _items.isNotEmpty;

  bool _less((String, RouteCost, int) a, (String, RouteCost, int) b) {
    final int c = a.$2.compareFor(goal, b.$2);
    return c != 0 ? c < 0 : a.$3 < b.$3;
  }

  void push(String at, RouteCost cost) {
    _items.add((at, cost, _seq++));
    int i = _items.length - 1;
    while (i > 0) {
      final int p = (i - 1) >> 1;
      if (!_less(_items[i], _items[p])) {
        break;
      }
      final (String, RouteCost, int) tmp = _items[i];
      _items[i] = _items[p];
      _items[p] = tmp;
      i = p;
    }
  }

  (String, RouteCost) pop() {
    final (String, RouteCost, int) top = _items.first;
    final (String, RouteCost, int) last = _items.removeLast();
    if (_items.isNotEmpty) {
      _items[0] = last;
      int i = 0;
      while (true) {
        final int l = 2 * i + 1;
        final int r = l + 1;
        int m = i;
        if (l < _items.length && _less(_items[l], _items[m])) {
          m = l;
        }
        if (r < _items.length && _less(_items[r], _items[m])) {
          m = r;
        }
        if (m == i) {
          break;
        }
        final (String, RouteCost, int) tmp = _items[i];
        _items[i] = _items[m];
        _items[m] = tmp;
        i = m;
      }
    }
    return (top.$1, top.$2);
  }
}

// ---- search ----

const Map<String, String> _polishMarks = <String, String>{
  'ą': 'a',
  'ć': 'c',
  'ę': 'e',
  'ł': 'l',
  'ń': 'n',
  'ó': 'o',
  'ś': 's',
  'ź': 'z',
  'ż': 'z',
};

/// Lower case without Polish marks ("lukasz" finds "Łukasz").
String foldName(String s) {
  final StringBuffer out = StringBuffer();
  for (final String ch in s.toLowerCase().split('')) {
    out.write(_polishMarks[ch] ?? ch);
  }
  return out.toString();
}

/// People whose name has [query]: friends first, then by name.
List<GraphNode> searchGraph(
  List<GraphNode> nodes,
  String query, {
  int limit = 8,
}) {
  final String q = foldName(query.trim());
  if (q.isEmpty) {
    return const <GraphNode>[];
  }
  final List<GraphNode> hits =
      nodes.where((GraphNode n) => foldName(n.name).contains(q)).toList()
        ..sort((GraphNode a, GraphNode b) {
          final int byRing = a.ring.compareTo(b.ring);
          return byRing != 0 ? byRing : a.name.compareTo(b.name);
        });
  return hits.take(limit).toList();
}

// ---- what is known about each person ----

/// A pyramid member as this person (a member) sees them.
@immutable
final class PyramidMark {
  const PyramidMark({required this.level, this.line = false});

  /// Their level in the tree (0 = the top).
  final int level;

  /// Above or below this person in the same branch ("Twoja linia").
  final bool line;
}

/// What this phone already knows about the people on the graph. Every
/// lookup only reads what was shown to this person; nothing is asked for.
final class GraphFacts {
  GraphFacts({
    IntentStatus? Function(String address)? statusOf,
    bool Function(String address)? online,
    OpenToMeet? Function(String address)? openOf,
    bool Function(String address)? met,
    bool Function(String address)? nearby,
    List<String> Function(String address)? nationsOf,
    PyramidMark? Function(String address)? pyramidOf,
    bool Function(String address, String label)? inLabel,
    this.mutual = const <String, int>{},
  }) : _inLabel = inLabel,
       _statusOf = statusOf,
       _online = online,
       _openOf = openOf,
       _met = met,
       _nearby = nearby,
       _nationsOf = nationsOf,
       _pyramidOf = pyramidOf;

  final IntentStatus? Function(String address)? _statusOf;
  final bool Function(String address)? _online;
  final OpenToMeet? Function(String address)? _openOf;
  final bool Function(String address)? _met;
  final bool Function(String address)? _nearby;
  final List<String> Function(String address)? _nationsOf;
  final PyramidMark? Function(String address)? _pyramidOf;
  final bool Function(String address, String label)? _inLabel;

  /// Friends who know each person ([mutualCounts]).
  final Map<String, int> mutual;

  final Map<String, List<String>> _nations = <String, List<String>>{};

  IntentStatus? statusOf(String a) => _statusOf?.call(a);
  bool online(String a) => _online?.call(a) ?? false;
  OpenToMeet? openOf(String a) => _openOf?.call(a);
  bool met(String a) => _met?.call(a) ?? false;
  bool nearby(String a) => _nearby?.call(a) ?? false;
  PyramidMark? pyramidOf(String a) => _pyramidOf?.call(a);
  int mutualOf(String a) => mutual[a] ?? 0;

  /// Whether [a] is in the circle this person named [label] (privately).
  bool inLabel(String a, String label) => _inLabel?.call(a, label) ?? false;

  /// Nationalities the person's profile shows this phone (codes).
  List<String> nationsOf(String a) =>
      _nations[a] ??= _nationsOf?.call(a) ?? const <String>[];

  /// A status, being online or "open to meet".
  bool hasStatus(String a) =>
      statusOf(a) != null || online(a) || openOf(a) != null;
}

/// Quick choices of who is drawn: everyone, friends and close friends, or
/// close friends only ("Przyjaciele").
enum RingPreset {
  all(<int>{1, 2, 3, 4, 5}),
  friends(<int>{1, 2}),
  close(<int>{1});

  const RingPreset(this.rings);

  final Set<int> rings;

  String get label => switch (this) {
    RingPreset.all => t('Wszyscy'),
    RingPreset.friends => t('Znajomi i przyjaciele'),
    RingPreset.close => t('Przyjaciele'),
  };

  /// The preset [rings] are, if any.
  static RingPreset? of(Set<int> rings) => RingPreset.values
      .where((RingPreset p) => setEquals(p.rings, rings))
      .firstOrNull;
}

/// The filters of the graph. The default shows everyone.
@immutable
final class GraphFilters {
  const GraphFilters({
    this.rings = allRings,
    this.minMutual = 0,
    this.nationality,
    this.withStatus = false,
    this.nearby = false,
    this.label,
  });

  /// Which circles: 1 przyjaciele, 2 znajomi, 3 słabi, 4 znajomi znajomych,
  /// 5 dalej.
  final Set<int> rings;

  /// At least this many mutual friends (0: any).
  final int minMutual;

  /// Only people whose profile shows this nationality.
  final String? nationality;
  final bool withStatus;
  final bool nearby;

  /// Only the people of the circle this person named so (its id).
  final String? label;

  static const Set<int> allRings = <int>{1, 2, 3, 4, 5};

  /// How many filters are on.
  int get active =>
      (setEquals(rings, allRings) ? 0 : 1) +
      (minMutual > 0 ? 1 : 0) +
      (nationality != null ? 1 : 0) +
      (withStatus ? 1 : 0) +
      (nearby ? 1 : 0) +
      (label != null ? 1 : 0);

  bool get isEmpty => active == 0;

  bool passes(GraphNode n, GraphFacts f) =>
      rings.contains(n.ring) &&
      (minMutual <= 0 || f.mutualOf(n.address) >= minMutual) &&
      (nationality == null || f.nationsOf(n.address).contains(nationality)) &&
      (!withStatus || f.hasStatus(n.address)) &&
      (!nearby || f.nearby(n.address)) &&
      (label == null || f.inLabel(n.address, label!));

  GraphFilters copyWith({
    Set<int>? rings,
    int? minMutual,
    String? Function()? nationality,
    bool? withStatus,
    bool? nearby,
    String? Function()? label,
  }) => GraphFilters(
    rings: rings ?? this.rings,
    minMutual: minMutual ?? this.minMutual,
    nationality: nationality != null ? nationality() : this.nationality,
    withStatus: withStatus ?? this.withStatus,
    nearby: nearby ?? this.nearby,
    label: label != null ? label() : this.label,
  );

  @override
  bool operator ==(Object other) =>
      other is GraphFilters &&
      setEquals(other.rings, rings) &&
      other.minMutual == minMutual &&
      other.nationality == nationality &&
      other.withStatus == withStatus &&
      other.nearby == nearby &&
      other.label == label;

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(rings),
    minMutual,
    nationality,
    withStatus,
    nearby,
    label,
  );
}

// ---- layout ----

/// Where everyone sits: positions in the order of [nodes] (x, y pairs),
/// and the radii of the rings drawn behind them.
final class GraphLayout {
  GraphLayout({
    required this.nodes,
    required this.xy,
    required this.radii,
    required this.center,
  });

  final List<GraphNode> nodes;
  final Float32List xy;
  final List<double> radii;
  final Offset center;

  Offset at(int i) => Offset(xy[2 * i], xy[2 * i + 1]);
}

/// Lays [nodes] out in rings around the centre: the band [bandOf] gives
/// (default: the circle), inner bands closer; communities get the same
/// angular sector on every band, so people who know each other sit next
/// to each other. A crowded band is spread over a few close rings. Also
/// sets [GraphNode.at]. Linear in the number of people (plus sorting).
GraphLayout graphLayout(
  List<GraphNode> nodes,
  Size size, {
  Map<String, int> cluster = const <String, int>{},
  int Function(GraphNode n)? bandOf,
}) {
  final Offset c = size.center(Offset.zero);
  final double r = max(40.0, min(size.width, size.height) / 2 - 28);
  final Float32List xy = Float32List(nodes.length * 2);
  if (nodes.isEmpty) {
    return GraphLayout(
      nodes: nodes,
      xy: xy,
      radii: <double>[r * 0.62],
      center: c,
    );
  }
  int band(GraphNode n) => bandOf?.call(n) ?? n.ring;
  final List<int> used = <int>{
    for (final GraphNode n in nodes) band(n),
  }.toList()..sort();
  // Communities: a sector each, by size.
  final Map<int, int> sizeOf = <int, int>{};
  for (final GraphNode n in nodes) {
    sizeOf.update(
      cluster[n.address] ?? -1,
      (int v) => v + 1,
      ifAbsent: () => 1,
    );
  }
  final List<int> groups = sizeOf.keys.toList()
    ..sort((int a, int b) => a == -1 ? 1 : (b == -1 ? -1 : a - b));
  final Map<int, (double, double)> sector = <int, (double, double)>{};
  double start = -pi / 2;
  for (final int g in groups) {
    final double span = 2 * pi * sizeOf[g]! / nodes.length;
    sector[g] = (start, span);
    start += span;
  }
  // Buckets: band → group → indexes.
  final Map<int, Map<int, List<int>>> buckets = <int, Map<int, List<int>>>{};
  for (int i = 0; i < nodes.length; i++) {
    final GraphNode n = nodes[i];
    buckets
        .putIfAbsent(band(n), () => <int, List<int>>{})
        .putIfAbsent(cluster[n.address] ?? -1, () => <int>[])
        .add(i);
  }
  final List<double> radii = <double>[];
  final double gap = used.length > 1 ? r * 0.6 / (used.length - 1) : r * 0.3;
  for (int k = 0; k < used.length; k++) {
    final int b = used[k];
    final double radius = used.length == 1
        ? r * 0.62
        : r * (0.4 + 0.6 * k / (used.length - 1));
    final Map<int, List<int>> inBand = buckets[b]!;
    final int count = inBand.values.fold(
      0,
      (int s, List<int> l) => s + l.length,
    );
    // About 7 px of the ring per person; more and the band gets more rings.
    final int rings = (count * 7 / (2 * pi * radius)).ceil().clamp(1, 8);
    final double step = min(9.0, gap * 0.8 / max(rings, 1));
    final bool outermost = k == used.length - 1;
    for (int s = 0; s < rings; s++) {
      radii.add(
        outermost && rings > 1
            ? radius - s * step
            : radius + (s - (rings - 1) / 2) * step,
      );
    }
    for (final int g in groups) {
      final List<int> part = inBand[g] ?? const <int>[];
      if (part.isEmpty) {
        continue;
      }
      part.sort((int x, int y) => nodes[x].name.compareTo(nodes[y].name));
      final (double from, double span) = sector[g]!;
      final double turn = groups.length == 1 ? b * 0.4 : 0.0;
      for (int i = 0; i < part.length; i++) {
        final int s = i % rings;
        final double rr = outermost && rings > 1
            ? radius - s * step
            : radius + (s - (rings - 1) / 2) * step;
        final double angle = from + turn + span * (i + 0.5) / part.length;
        final int at = part[i];
        xy[2 * at] = c.dx + cos(angle) * rr;
        xy[2 * at + 1] = c.dy + sin(angle) * rr;
        nodes[at].at = Offset(xy[2 * at], xy[2 * at + 1]);
      }
    }
  }
  return GraphLayout(nodes: nodes, xy: xy, radii: radii, center: c);
}
