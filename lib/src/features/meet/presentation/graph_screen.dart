import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/graph/gate_prices.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/graph/graph_providers.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/ask_screen.dart';
import 'package:zen/src/features/meet/presentation/intent_widgets.dart';
import 'package:zen/src/features/meet/presentation/intro_widgets.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

export 'package:zen/src/features/meet/graph/graph_model.dart';

IconData _modeIcon(GraphMode m) => switch (m) {
  GraphMode.friends => Icons.hub_rounded,
  GraphMode.statuses => Icons.bolt_rounded,
  GraphMode.met => Icons.handshake_rounded,
  GraphMode.pyramid => kPyramidIcon,
  GraphMode.gates => Icons.toll_rounded,
  GraphMode.route => Icons.route_rounded,
};

String _ringLabel(int ring) => switch (ring) {
  1 => t('Przyjaciel(-ółka)'),
  2 => t('Znajomy(-a)'),
  3 => t('Słaby(-a) znajomy(-a)'),
  _ => t('Znajomy(-a) znajomych'),
};

String _ringFilterLabel(int ring) => switch (ring) {
  1 => t('Przyjaciele'),
  2 => t('Znajomi'),
  3 => t('Słabi znajomi'),
  _ => t('Znajomi znajomych'),
};

/// "5 min temu", "3 godz. temu", "2 dni temu".
String _ago(int ms, int now) {
  final int minutes = max(0, (now - ms) ~/ 60000);
  if (minutes < 1) {
    return t('przed chwilą');
  }
  if (minutes < 60) {
    return t('{n} min temu', {'n': minutes});
  }
  final int hours = minutes ~/ 60;
  if (hours < 24) {
    return t('{n} godz. temu', {'n': hours});
  }
  return tn(
    hours ~/ 24,
    one: '{n} dzień temu',
    few: '{n} dni temu',
    many: '{n} dni temu',
  );
}

/// What a route costs, in words: "2 kroki · 5 · 1 zgoda".
String routeCostText(RouteCost c, List<GatePrice?> gates) {
  final List<String> parts = <String>[
    tn(c.hops, one: '{n} krok', few: '{n} kroki', many: '{n} kroków'),
    if (c.price > 0)
      t('płatne: {prices}', {
        'prices': <String>[
          for (final GatePrice? g in gates)
            if (g?.kind == GateKind.price) g!.label,
        ].join(' + '),
      }),
    if (c.consents > 0)
      tn(c.consents, one: '{n} zgoda', few: '{n} zgody', many: '{n} zgód'),
    // Some steps priced, some not (none priced: only the steps count).
    if (c.unknown > 0 && c.unknown < c.hops)
      tn(
        c.unknown,
        one: '{n} krok bez danych o cenie',
        few: '{n} kroki bez danych o cenie',
        many: '{n} kroków bez danych o cenie',
      ),
  ];
  return parts.join(' · ');
}

/// Pyramid members on the graph as this person (a member) sees them:
/// their level and whether they are on this person's line. Empty outside a
/// pyramid: nothing beyond what membership already shows.
Map<String, PyramidMark> pyramidMarks(PyramidService? pyr) {
  if (pyr == null || !pyr.isMember) {
    return const <String, PyramidMark>{};
  }
  final PyramidState? s = pyr.state;
  final String? me = pyr.myKey;
  if (s == null || me == null) {
    return const <String, PyramidMark>{};
  }
  final String? mine = s.pathOf(me);
  final Map<String, PyramidMark> out = <String, PyramidMark>{};
  for (final PyrMember m in s.members.values) {
    if (!m.active || m.addr.isEmpty || m.key == me) {
      continue;
    }
    final String? p = s.pathOf(m.key);
    if (p == null) {
      continue;
    }
    out[PeerShareCodec.normalizeAddress(m.addr)] = PyramidMark(
      level: p.length,
      line: mine != null && (p.startsWith(mine) || mine.startsWith(p)),
    );
  }
  return out;
}

/// The look of each person and line in [mode]. Pure: the same inputs
/// give the same picture (tests read it).
GraphLook graphLook({
  required GraphScene scene,
  required GraphMode mode,
  required GraphFacts facts,
  required ZenColors zen,
  GatePriceSource prices = const NoGatePrices(),
  Map<String, PyramidMark> pyramid = const <String, PyramidMark>{},
  String? selected,
  Set<String> marked = const <String>{},
  List<String> route = const <String>[],
}) {
  final List<GraphNode> nodes = scene.layout.nodes;
  final bool crowded = nodes.length > 1500;
  final Set<String> onRoute = route.toSet();
  final Map<String, int> index = <String, int>{
    for (int i = 0; i < nodes.length; i++) nodes[i].address: i,
  };
  final bool routing = mode == GraphMode.route && route.isNotEmpty;
  final Color dating = zenTone(zen, 4);
  final Color pyr = zenTone(zen, 3);
  Color dim(Color c, [double a = 0.28]) => c.withValues(alpha: a);

  final List<NodeLook> looks = <NodeLook>[];
  for (final GraphNode n in nodes) {
    final String a = n.address;
    final bool lit = a == selected || marked.contains(a) || onRoute.contains(a);
    final double radius = n.isFriend
        ? switch (n.ring) {
            1 => 10.0,
            2 => 9.0,
            _ => 7.5,
          }
        : (crowded ? 3.0 : 4.5);
    Color fill = n.isFriend
        ? switch (n.ring) {
            1 => zen.accent,
            2 => zen.accent.withValues(alpha: 0.82),
            _ => zen.accent.withValues(alpha: 0.58),
          }
        : zen.textMuted;
    Color? ring;
    Color? dot;
    String? tag;
    Color? tagTone;
    switch (mode) {
      case GraphMode.friends:
      case GraphMode.gates:
        break;
      case GraphMode.statuses:
        final IntentStatus? s = facts.statusOf(a);
        final OpenToMeet? open = facts.openOf(a);
        final bool online = facts.online(a);
        fill = s != null
            ? intentTone(zen, s.kind)
            : (online || open != null ? fill : dim(fill, 0.35));
        dot = online ? zen.success : null;
        final List<String> bits = <String>[
          if (s != null) s.shownEmoji,
          if (open != null) open.label,
        ];
        if (bits.isNotEmpty) {
          tag = bits.join(' ');
          tagTone = open != null ? dating : intentTone(zen, s!.kind);
        }
      case GraphMode.met:
        final bool met = facts.met(a);
        ring = met ? zen.success : null;
        dot = facts.nearby(a) ? zen.accentSecondary : null;
        if (!n.isFriend) {
          fill = dim(fill, 0.45);
        }
      case GraphMode.pyramid:
        final PyramidMark? m = pyramid[a];
        if (m == null) {
          fill = dim(fill, 0.22);
        } else {
          fill = pyr;
          ring = m.line ? zen.accent : null;
          tag = t('poz. {level}', {'level': m.level});
          tagTone = m.line ? zen.accent : pyr;
        }
      case GraphMode.route:
        if (routing && !onRoute.contains(a)) {
          fill = dim(fill, 0.2);
        }
    }
    if (lit) {
      ring = zen.accent;
    }
    looks.add(
      NodeLook(
        fill: fill,
        radius: lit && !n.isFriend ? 6.0 : radius,
        ring: ring,
        dot: dot,
        tag: tag,
        tagTone: tagTone,
        label: lit,
      ),
    );
  }

  final List<EdgeLook> edges = <EdgeLook>[];
  for (int e = 0; e < scene.edgeCount; e++) {
    final int from = scene.edgeFrom[e];
    final GraphNode to = nodes[scene.edgeTo[e]];
    final bool spoke = from < 0;
    final double width = spoke ? (4 - min(to.ring, 3)) * 0.8 : 0.6;
    Color color = spoke ? zen.outline : zen.outline.withValues(alpha: 0.5);
    bool dashed = false;
    String? tag;
    switch (mode) {
      case GraphMode.friends:
        break;
      case GraphMode.statuses:
        color = color.withValues(alpha: spoke ? 0.45 : 0.25);
      case GraphMode.met:
        if (spoke) {
          final bool met = facts.met(to.address);
          color = met ? zen.success : zen.outline;
          dashed = !met;
          edges.add(
            EdgeLook(
              color: color,
              width: met ? width + 0.6 : 1.1,
              dashed: dashed,
            ),
          );
          continue;
        }
        color = zen.outline.withValues(alpha: 0.3);
      case GraphMode.pyramid:
        final PyramidMark? m = pyramid[to.address];
        color = m == null
            ? zen.outline.withValues(alpha: 0.18)
            : (m.line ? zen.accent : pyr.withValues(alpha: 0.7));
      case GraphMode.gates:
        final GatePrice? g = spoke
            ? prices.gateOf(to.address)
            : prices.gateOf(to.address, via: nodes[from].address);
        if (g != null) {
          tag = g.label;
          color = switch (g.kind) {
            GateKind.free => zen.success,
            GateKind.price => zen.warning,
            GateKind.consent => zen.accentSecondary,
          };
        } else {
          color = zen.outline.withValues(alpha: spoke ? 0.6 : 0.3);
        }
      case GraphMode.route:
        if (routing) {
          color = color.withValues(alpha: 0.2);
        }
    }
    edges.add(EdgeLook(color: color, width: width, dashed: dashed, tag: tag));
  }
  return GraphLook(
    nodes: looks,
    edges: edges,
    link: switch (mode) {
      GraphMode.friends => zen.outline.withValues(alpha: 0.6),
      GraphMode.route when routing => zen.outline.withValues(alpha: 0.12),
      _ => zen.outline.withValues(alpha: 0.3),
    },
    route: <int>[
      if (routing || mode != GraphMode.route)
        for (final String a in route)
          if (index[a] case final int i) i,
    ],
    showHalos: mode == GraphMode.friends,
  );
}

/// The band (ring) each person sits on in [mode]: modes that are about one
/// thing pull those people inwards, so changing the mode moves people.
int graphBand(
  GraphMode mode,
  GraphNode n,
  GraphFacts f,
  Map<String, PyramidMark> pyr,
) {
  switch (mode) {
    case GraphMode.statuses:
      final bool on =
          f.statusOf(n.address) != null || f.openOf(n.address) != null;
      return n.isFriend ? (on ? 1 : 2) : (on ? 3 : 4);
    case GraphMode.met:
      return n.isFriend ? (f.met(n.address) ? 1 : 2) : 4;
    case GraphMode.pyramid:
      final PyramidMark? m = pyr[n.address];
      return m == null ? (n.isFriend ? 3 : 4) : (m.line ? 1 : 2);
    case GraphMode.friends:
    case GraphMode.gates:
    case GraphMode.route:
      return n.ring;
  }
}

/// "Graf": you in the middle, friends around by closeness, friends of
/// friends further out. Modes show statuses, meetings, the pyramid, gate
/// prices and the way to a person; search, filters, focus and the card of
/// each person with what can be done.
class GraphScreen extends ConsumerStatefulWidget {
  const GraphScreen({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const GraphScreen(),
    ),
  );

  @override
  ConsumerState<GraphScreen> createState() => _GraphScreenState();
}

/// The people and what is known about them, rebuilt only when the data
/// behind them changes.
final class _GraphData {
  _GraphData({
    required this.key,
    required this.all,
    required this.friendOrder,
    required this.ringOf,
    required this.mutual,
    required this.met,
  });

  final Object key;
  final List<GraphNode> all;
  final List<String> friendOrder;
  final Map<String, int> ringOf;
  final Map<String, int> mutual;
  final Set<String> met;
}

class _GraphScreenState extends ConsumerState<GraphScreen>
    with SingleTickerProviderStateMixin {
  GraphMode _mode = GraphMode.friends;
  GraphFilters _filters = const GraphFilters();
  RouteGoal _goal = RouteGoal.shortest;
  final TextEditingController _search = TextEditingController();

  /// The person picked (tap or search): the way to them is drawn.
  String? _selected;

  /// Pinch-zoom and pan of the picture.
  final TransformationController _view = TransformationController();

  /// Positions moving to a new layout (a mode or filter change).
  late final AnimationController _move = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 380),
    value: 1,
  );
  final GraphLabelCache _labels = GraphLabelCache();

  _GraphData? _data;
  GraphScene? _scene;
  Object? _sceneKey;
  Size _canvas = Size.zero;

  /// Nationalities read from profiles (read again when the filters open).
  final Map<String, List<String>> _nations = <String, List<String>>{};

  double get _scale => _view.value.getMaxScaleOnAxis();

  /// Zoomed in: dragging pans the picture, so the page stops scrolling
  /// under the finger (zoom out to scroll again).
  bool _zoomed = false;

  void _onView() {
    final bool zoomed = _scale > 1.001;
    if (zoomed != _zoomed && mounted) {
      setState(() => _zoomed = zoomed);
    }
  }

  @override
  void initState() {
    super.initState();
    _view.addListener(_onView);
  }

  @override
  void dispose() {
    _view
      ..removeListener(_onView)
      ..dispose();
    _move.dispose();
    _labels.clear();
    _search.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A new theme or text scale: labels are laid out again.
    _labels.clear();
  }

  static const double _maxScale = 12;

  /// Zooms by [factor] around the middle of the picture (1…12 times).
  void _zoom(double factor, Size size) {
    final double now = _scale;
    final double target = (now * factor).clamp(1.0, _maxScale);
    if (target <= 1.0001) {
      _view.value = Matrix4.identity();
      return;
    }
    final double f = target / now;
    final Offset c = size.center(Offset.zero);
    _view.value =
        (Matrix4.identity()
          ..translateByDouble(c.dx, c.dy, 0, 1)
          ..scaleByDouble(f, f, 1, 1)
          ..translateByDouble(-c.dx, -c.dy, 0, 1)) *
        _view.value;
  }

  /// Brings [address] to the middle of the picture, zoomed in.
  void _focus(String address) {
    final GraphScene? scene = _scene;
    if (scene == null || _canvas.isEmpty) {
      return;
    }
    final int i = scene.layout.nodes.indexWhere(
      (GraphNode n) => n.address == address,
    );
    if (i < 0) {
      return;
    }
    final Offset p = scene.layout.at(i);
    final double s = max(_scale, 2.6);
    final Offset c = _canvas.center(Offset.zero);
    _view.value = Matrix4.identity()
      ..translateByDouble(c.dx - p.dx * s, c.dy - p.dy * s, 0, 1)
      ..scaleByDouble(s, s, 1, 1);
  }

  void _snack(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _askList(IntroService intro, String friend, String name) async {
    final IntroCase? c = await intro.askList(friend);
    if (!mounted) {
      return;
    }
    setState(() {});
    _snack(
      c == null
          ? t('Nie można teraz poprosić.')
          : t('Poproszono o listę: {name}.', {'name': name}),
    );
  }

  void _setMode(GraphMode mode) {
    if (mode == _mode) {
      return;
    }
    setState(() => _mode = mode);
  }

  /// The people, rebuilt when the friends, their lists or levels change.
  _GraphData _dataFor({
    required SocialHubState social,
    required MeetBook book,
    required LedgerNode? node,
  }) {
    FriendLevel levelOf(String a) => node?.levelOf(a) ?? FriendLevel.friend;
    final String levels = <String>[
      for (final FriendProfile f in social.acceptedFriends)
        '${f.address}:${levelOf(f.address).index}',
    ].join(',');
    final Object key = Object.hash(
      identityHashCode(book),
      identityHashCode(social.friends),
      levels,
      _selected,
    );
    final _GraphData? had = _data;
    if (had != null && had.key == key) {
      return had;
    }
    final List<GraphNode> all = buildGraph(
      social: social,
      book: book,
      levelOf: levelOf,
      maxFriendsOfFriends: kGraphMaxNodes,
      keep: <String>{?_selected},
    );
    // Friends, closest first: the way through them wins a tie.
    final List<GraphNode> friends =
        all.where((GraphNode n) => n.isFriend).toList()
          ..sort((GraphNode a, GraphNode b) => a.ring.compareTo(b.ring));
    return _data = _GraphData(
      key: key,
      all: all,
      friendOrder: <String>[for (final GraphNode n in friends) n.address],
      ringOf: <String, int>{
        for (final GraphNode n in friends) n.address: n.ring,
      },
      mutual: mutualCounts(all, book),
      met: <String>{
        if (node != null)
          for (final GraphNode n in friends)
            if (node.hasMet(n.address)) n.address,
      },
    );
  }

  List<String> _nationsOf(LedgerNode? node, GraphNode n) {
    if (node == null || !node.isReady || !n.isFriend) {
      return const <String>[];
    }
    return _nations[n.address] ??= () {
      final String? account = node.knownAccountOf(n.address);
      return account == null
          ? const <String>[]
          : readProfile(node, account)?.nationalities ?? const <String>[];
    }();
  }

  /// The scene for [nodes]: laid out again only when who is drawn, the
  /// bands or the size change; then the people glide to their new places.
  GraphScene _sceneFor({
    required List<GraphNode> nodes,
    required Size size,
    required MeetBook book,
    required GraphFacts facts,
    required Map<String, PyramidMark> pyramid,
    required Map<String, int> ringOf,
    required List<GroupProfile> groups,
    required ZenColors zen,
  }) {
    final Object key = Object.hash(
      Object.hashAll(<String>[for (final GraphNode n in nodes) n.address]),
      size,
      _mode,
      Object.hashAll(<int>[
        for (final GraphNode n in nodes) graphBand(_mode, n, facts, pyramid),
      ]),
      identityHashCode(_data),
    );
    final GraphScene? old = _scene;
    if (old != null && _sceneKey == key) {
      return old;
    }
    final Map<String, int> clusters = graphClusters(nodes, book);
    final GraphLayout layout = graphLayout(
      nodes,
      size,
      cluster: clusters,
      bandOf: (GraphNode n) => graphBand(_mode, n, facts, pyramid),
    );
    final Map<String, int> index = <String, int>{
      for (int i = 0; i < nodes.length; i++) nodes[i].address: i,
    };
    // Where everyone was: new people come out of the friend who brings
    // them (or the middle).
    final Map<String, int> before = <String, int>{
      if (old != null)
        for (int i = 0; i < old.layout.nodes.length; i++)
          old.layout.nodes[i].address: i,
    };
    final Float32List from = Float32List(nodes.length * 2);
    Offset? was(String a) {
      final int? i = before[a];
      return i == null || old == null ? null : old.layout.at(i);
    }

    for (int i = 0; i < nodes.length; i++) {
      final GraphNode n = nodes[i];
      final Offset p =
          was(n.address) ??
          (n.via.isEmpty ? null : was(n.via.first)) ??
          layout.center;
      from
        ..[2 * i] = p.dx
        ..[2 * i + 1] = p.dy;
    }
    // Lines: "Ty" to each friend, each friend of a friend to the friends who
    // know them (closest first, a few at most).
    final List<int> ef = <int>[];
    final List<int> et = <int>[];
    for (int i = 0; i < nodes.length; i++) {
      final GraphNode n = nodes[i];
      if (n.isFriend) {
        ef.add(-1);
        et.add(i);
        continue;
      }
      final List<String> via = <String>[...n.via]
        ..sort(
          (String a, String b) => (ringOf[a] ?? 9).compareTo(ringOf[b] ?? 9),
        );
      for (final String v in via.take(6)) {
        final int? f = index[v];
        if (f != null) {
          ef.add(f);
          et.add(i);
        }
      }
    }
    final List<int> links = <int>[
      for (final (String a, String b) in friendLinks(<String>[
        for (final GraphNode n in nodes)
          if (n.isFriend) n.address,
      ], book))
        if (index[a] case final int x)
          if (index[b] case final int y) ...<int>[x, y],
    ];
    // Communities: a soft blob each, named after a shared chat group or
    // the friend who knows most of them.
    final Map<String, Set<String>> groupMembers = <String, Set<String>>{
      for (final GroupProfile g in groups)
        if (g.name.trim().isNotEmpty)
          g.name.trim(): <String>{
            for (final String m in g.memberAddresses)
              PeerShareCodec.normalizeAddress(m),
          },
    };
    final Map<int, String> names = clusterNames(
      nodes,
      clusters,
      groups: groupMembers,
      mutual: facts.mutual,
    );
    final Map<int, List<Offset>> spots = <int, List<Offset>>{};
    for (int i = 0; i < nodes.length; i++) {
      final int c = clusters[nodes[i].address] ?? -1;
      if (c >= 0) {
        spots.putIfAbsent(c, () => <Offset>[]).add(layout.at(i));
      }
    }
    final List<GraphHalo> halos = <GraphHalo>[
      for (final MapEntry<int, List<Offset>> e in spots.entries.take(12))
        () {
          Offset sum = Offset.zero;
          for (final Offset p in e.value) {
            sum += p;
          }
          final Offset mid = sum / e.value.length.toDouble();
          double r = 0;
          for (final Offset p in e.value) {
            r = max(r, (p - mid).distance);
          }
          return GraphHalo(
            center: mid,
            radius: r + 20,
            color: zenTone(zen, e.key % 6),
            name: names[e.key] ?? '',
          );
        }(),
    ];
    _sceneKey = key;
    final GraphScene scene = GraphScene(
      layout: layout,
      from: from,
      edgeFrom: Int32List.fromList(ef),
      edgeTo: Int32List.fromList(et),
      links: Int32List.fromList(links),
      halos: halos,
    );
    _scene = scene;
    // Glide only when someone actually moves (a status that came changes
    // the data, not the places).
    bool moves = false;
    for (int i = 0; i < from.length && !moves; i++) {
      moves = (from[i] - layout.xy[i]).abs() > 0.5;
    }
    if (old != null && moves) {
      _move.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          unawaited(_move.forward(from: 0));
        }
      });
    }
    return scene;
  }

  @override
  Widget build(BuildContext context) {
    final MeetService meet = ref.watch(meetServiceProvider);
    final NearbyService nearby = ref.watch(nearbyServiceProvider);
    final IntroService intro = ref.watch(introServiceProvider);
    final PyramidService pyramid = ref.watch(pyramidServiceProvider);
    final OpenToMeetService open = ref.watch(openToMeetServiceProvider);
    final GatePriceSource prices = ref.watch(gatePriceSourceProvider);
    // The pyramid mode only while the pyramid is switched on.
    final bool pyramidOn = ref
        .watch(featureFlagsProvider)
        .isEnabled(ZenFeature.pyramid);
    final SocialHubState social = watchSocialPeople(ref);
    final LedgerNode? node = ref.watch(ledgerNodeProvider);
    return Scaffold(
      key: const Key('graph-screen'),
      appBar: ZenSectionBar(title: t('Graf znajomych')),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          meet,
          nearby,
          open,
          if (pyramidOn) pyramid,
          ?prices.changes,
        ]),
        builder: (BuildContext context, Widget? _) => _content(
          context,
          meet: meet,
          nearby: nearby,
          intro: intro,
          pyramid: pyramidOn ? pyramid : null,
          open: open,
          prices: prices,
          social: social,
          node: node,
        ),
      ),
    );
  }

  Widget _content(
    BuildContext context, {
    required MeetService meet,
    required NearbyService nearby,
    required IntroService intro,
    required PyramidService? pyramid,
    required OpenToMeetService open,
    required GatePriceSource prices,
    required SocialHubState social,
    required LedgerNode? node,
  }) {
    final ZenColors zen = ZenColors.of(context);
    final int nowMs = meet.now;
    final _GraphData data = _dataFor(
      social: social,
      book: meet.book,
      node: node,
    );
    final List<GraphNode> all = data.all;
    final Map<String, GraphNode> byAddress = <String, GraphNode>{
      for (final GraphNode n in all) n.address: n,
    };
    final Set<String> near = <String>{
      for (final NearbyPerson p in nearby.people)
        if (p.friend != null) PeerShareCodec.normalizeAddress(p.friend!),
    };
    final Map<String, PyramidMark> pyr = pyramidMarks(pyramid);
    final GraphFacts facts = GraphFacts(
      statusOf: (String a) => meet.book.intentOf(a, nowMs),
      online: (String a) => byAddress[a]?.friend?.isOnline ?? false,
      openOf: open.openOf,
      met: data.met.contains,
      nearby: near.contains,
      nationsOf: (String a) {
        final GraphNode? n = byAddress[a];
        return n == null ? const <String>[] : _nationsOf(node, n);
      },
      pyramidOf: (String a) => pyr[a],
      mutual: data.mutual,
    );
    final List<GraphMode> modes = <GraphMode>[
      for (final GraphMode m in GraphMode.values)
        if (m != GraphMode.pyramid || pyr.isNotEmpty || _mode == m) m,
    ];
    final String? selected = _selected;
    final GraphRoute route = selected == null
        ? const GraphRoute()
        : graphRoute(
            friends: data.friendOrder,
            book: meet.book,
            target: selected,
            prices: _mode == GraphMode.route ? prices : const NoGatePrices(),
            goal: _mode == GraphMode.route ? _goal : RouteGoal.shortest,
          );
    final Set<String> onRoute = route.path.toSet();
    final List<GraphNode> nodes = all
        .where(
          (GraphNode n) =>
              _filters.passes(n, facts) ||
              onRoute.contains(n.address) ||
              n.address == selected,
        )
        .toList();
    final String query = _search.text;
    final List<GraphNode> hits = query.trim().isEmpty
        ? const <GraphNode>[]
        : searchGraph(all, query);
    final Set<String> marked = <String>{
      for (final GraphNode h in hits) h.address,
    };

    void openPerson(GraphNode n) {
      FocusScope.of(context).unfocus();
      setState(() => _selected = n.address);
      final List<String> via = <String>[...n.via]
        ..sort(
          (String a, String b) =>
              (data.ringOf[a] ?? 9).compareTo(data.ringOf[b] ?? 9),
        );
      unawaited(
        _show(
          context,
          meet: meet,
          intro: intro,
          node: node,
          n: n,
          facts: facts,
          prices: prices,
          route: graphRoute(
            friends: data.friendOrder,
            book: meet.book,
            target: n.address,
            prices: prices,
            goal: _mode == GraphMode.route ? _goal : RouteGoal.shortest,
          ),
          via: via,
        ),
      );
    }

    // One scrolling page: the graph gets most of the screen, but never
    // pushes the legend and the tiles below off a small screen or under
    // large text.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints outer) {
        final double graphHeight = max<double>(
          260,
          min(outer.maxHeight - 260, outer.maxWidth * 1.15),
        );
        return ListView(
          padding: EdgeInsets.zero,
          physics: _zoomed ? const NeverScrollableScrollPhysics() : null,
          children: <Widget>[
            if (all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: TextField(
                  key: const Key('graph-search'),
                  controller: _search,
                  onChanged: (_) => setState(() {}),
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: t('Szukaj w grafie'),
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: t('Wyczyść'),
                            icon: const Icon(Icons.close_rounded, size: 18),
                            onPressed: () {
                              _search.clear();
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
            if (query.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: hits.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          t('Nikogo takiego w Twoim grafie.'),
                          style: TextStyle(color: zen.textSecondary),
                        ),
                      )
                    : ZenGroup(
                        children: <Widget>[
                          for (final GraphNode h in hits)
                            ListTile(
                              key: Key('graph-hit-${h.address}'),
                              dense: true,
                              leading: Icon(
                                h.isFriend
                                    ? Icons.people_alt_rounded
                                    : Icons.person_search_rounded,
                                color: h.isFriend ? zen.accent : zen.textMuted,
                              ),
                              title: Text(h.name),
                              subtitle: Text(
                                h.isFriend
                                    ? _ringLabel(h.ring)
                                    : t('Przez: {names}', {
                                        'names': h.via
                                            .map(meet.host.nameOf)
                                            .join(', '),
                                      }),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: IconButton(
                                key: Key('graph-hit-focus-${h.address}'),
                                tooltip: t('Pokaż na grafie'),
                                icon: const Icon(
                                  Icons.center_focus_strong_rounded,
                                ),
                                onPressed: () {
                                  FocusScope.of(context).unfocus();
                                  setState(() => _selected = h.address);
                                  WidgetsBinding.instance.addPostFrameCallback(
                                    (_) => _focus(h.address),
                                  );
                                },
                              ),
                              onTap: () => openPerson(h),
                            ),
                        ],
                      ),
              ),
            _modeBar(context, modes),
            if (_mode == GraphMode.route)
              _routeBar(context, route, selected, all, meet),
            SizedBox(
              height: graphHeight,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(26),
                  border: Border.all(color: zen.outlineSoft),
                  gradient: RadialGradient(
                    colors: <Color>[
                      Color.alphaBlend(
                        zen.accent.withValues(alpha: 0.10),
                        zen.surface,
                      ),
                      zen.surface,
                    ],
                    radius: 0.9,
                  ),
                ),
                clipBehavior: Clip.antiAlias,
                child: all.isEmpty
                    ? Center(
                        child: SingleChildScrollView(
                          child: ZenEmpty(
                            icon: Icons.hub_rounded,
                            title: t('Tu będzie Twój graf'),
                            text: t(
                              'Dodaj znajomych, a pojawią się wokół Ciebie — '
                              'najbliżsi najbliżej środka.',
                            ),
                          ),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (BuildContext context, BoxConstraints box) {
                          final Size size = box.biggest;
                          _canvas = size;
                          final GraphScene scene = _sceneFor(
                            nodes: nodes,
                            size: size,
                            book: meet.book,
                            facts: facts,
                            pyramid: pyr,
                            ringOf: data.ringOf,
                            groups: social.groups.values.toList(),
                            zen: zen,
                          );
                          final GraphLook look = graphLook(
                            scene: scene,
                            mode: _mode,
                            facts: facts,
                            zen: zen,
                            prices: prices,
                            pyramid: pyr,
                            selected: selected,
                            marked: marked,
                            route: route.path,
                          );
                          return _canvasView(
                            context,
                            scene,
                            look,
                            size,
                            openPerson,
                          );
                        },
                      ),
              ),
            ),
            if (!_filters.isEmpty && all.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Text(
                  t('Widać: {count} z {total}', {
                    'count': nodes.length,
                    'total': all.length,
                  }),
                  key: const Key('graph-count'),
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ),
            if (selected != null && _mode != GraphMode.route)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 0),
                child: Row(
                  children: <Widget>[
                    Expanded(
                      child: ZenInfo(
                        key: const Key('graph-path'),
                        icon: Icons.timeline_rounded,
                        tone: zen.accent,
                        title: t('Skąd znasz'),
                        text: route.isEmpty
                            ? t('Tej osoby nie ma już na listach znajomych.')
                            : <String>[
                                t('Ty'),
                                for (final String a in route.path)
                                  _nameOn(a, byAddress, meet),
                              ].join(' → '),
                      ),
                    ),
                    IconButton(
                      key: const Key('graph-path-clear'),
                      tooltip: t('Wyczyść'),
                      onPressed: () => setState(() => _selected = null),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
            _legend(context, nodes, facts, prices),
            if (all.isNotEmpty && all.every((GraphNode n) => n.isFriend))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: ZenInfo(
                  icon: Icons.info_outline_rounded,
                  tone: zenTone(zen, 1),
                  text: t(
                    'Znajomi znajomych pojawią się, gdy znajomi pokażą Ci '
                    'swoje listy znajomych.',
                  ),
                ),
              )
            else if (all.any((GraphNode n) => !n.isFriend))
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: ZenInfo(
                  key: const Key('graph-far-hint'),
                  icon: Icons.waving_hand_rounded,
                  tone: zenTone(zen, 2),
                  text: t(
                    'Dotknij znajomego znajomych, żeby poprosić o '
                    'przedstawienie, napisać list albo zapytać o opinię.',
                  ),
                ),
              ),
            _ListsDiagnostics(
              meet: meet,
              intro: intro,
              social: social,
              onAsk: (String friend, String name) =>
                  unawaited(_askList(intro, friend, name)),
            ),
            const IntroInboxSection(padding: EdgeInsets.fromLTRB(16, 6, 16, 0)),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: MyIntrosTile(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: ZenTile(
                key: const Key('graph-ask'),
                icon: Icons.help_center_rounded,
                tone: zenTone(zen, 6),
                title: t('Zapytaj sieć'),
                subtitle: t(
                  'Dentysta, przyczepka, mieszkanie — zapytaj znajomych i ich '
                  'znajomych.',
                ),
                onTap: () => unawaited(AskScreen.open(context)),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: ZenGroup(
                children: <Widget>[
                  FriendListAudienceTile(),
                  GateSettingsTile(),
                  RelayLettersSwitch(),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        );
      },
    );
  }

  /// The modes, and the filters button with how many are on.
  Widget _modeBar(BuildContext context, List<GraphMode> modes) {
    final int active = _filters.active;
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.only(left: 16, right: 8),
              child: Row(
                spacing: 8,
                children: <Widget>[
                  for (final GraphMode m in modes)
                    ChoiceChip(
                      key: Key('graph-mode-${m.name}'),
                      showCheckmark: false,
                      avatar: ZenIcon(_modeIcon(m), size: 18),
                      label: Text(m.label),
                      selected: _mode == m,
                      onSelected: (_) => _setMode(m),
                    ),
                ],
              ),
            ),
          ),
          Badge(
            isLabelVisible: active > 0,
            label: Text('$active'),
            child: IconButton.filledTonal(
              key: const Key('graph-filters'),
              tooltip: t('Filtry'),
              onPressed: () => unawaited(_openFilters(context)),
              icon: const Icon(Icons.tune_rounded),
            ),
          ),
        ],
      ),
    );
  }

  /// "Ścieżka": shortest or cheapest, and the route to the person picked.
  Widget _routeBar(
    BuildContext context,
    GraphRoute route,
    String? selected,
    List<GraphNode> all,
    MeetService meet,
  ) {
    final ZenColors zen = ZenColors.of(context);
    final Map<String, GraphNode> byAddress = <String, GraphNode>{
      for (final GraphNode n in all) n.address: n,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SegmentedButton<RouteGoal>(
            segments: <ButtonSegment<RouteGoal>>[
              ButtonSegment<RouteGoal>(
                value: RouteGoal.shortest,
                icon: const Icon(Icons.timeline_rounded),
                label: Text(
                  t('Najkrótsza'),
                  key: const Key('graph-goal-shortest'),
                ),
              ),
              ButtonSegment<RouteGoal>(
                value: RouteGoal.cheapest,
                icon: const Icon(Icons.savings_rounded),
                label: Text(
                  t('Najtańsza'),
                  key: const Key('graph-goal-cheapest'),
                ),
              ),
            ],
            selected: <RouteGoal>{_goal},
            onSelectionChanged: (Set<RouteGoal> s) =>
                setState(() => _goal = s.first),
          ),
          const SizedBox(height: 8),
          ZenInfo(
            key: const Key('graph-route'),
            icon: Icons.route_rounded,
            tone: zen.accent,
            title: selected == null ? null : t('Droga'),
            text: selected == null
                ? t(
                    'Dotknij osoby na grafie albo wyszukaj ją, żeby zobaczyć drogę.',
                  )
                : route.isEmpty
                ? t('Nie widać drogi do tej osoby przez Twoich znajomych.')
                : '${<String>[t('Ty'), for (final String a in route.path) _nameOn(a, byAddress, meet)].join(' → ')}\n'
                      '${routeCostText(route.cost, route.gates)}',
          ),
        ],
      ),
    );
  }

  Widget _canvasView(
    BuildContext context,
    GraphScene scene,
    GraphLook look,
    Size size,
    void Function(GraphNode) openPerson,
  ) {
    final ZenColors zen = ZenColors.of(context);
    final List<GraphNode> nodes = scene.layout.nodes;
    final Widget picture = ListenableBuilder(
      listenable: _view,
      builder: (BuildContext context, Widget? _) {
        final double scale = _scale;
        // Coarse steps of zoom and of the part on screen: the picture is
        // painted again only when the level of detail changes, not on every
        // frame of a pinch or a pan (those only move the layer).
        final double lod = scale >= 2.5
            ? 2.5
            : (scale >= 1.8 ? 1.8 : (scale >= 1.6 ? 1.6 : 1));
        Rect? visible;
        if (lod >= 1.6) {
          final Rect r = MatrixUtils.inverseTransformRect(
            _view.value,
            Offset.zero & size,
          );
          const double q = 64;
          visible = Rect.fromLTRB(
            (r.left / q).floorToDouble() * q,
            (r.top / q).floorToDouble() * q,
            (r.right / q).ceilToDouble() * q,
            (r.bottom / q).ceilToDouble() * q,
          );
        }
        return GestureDetector(
          key: const Key('graph-canvas'),
          onTapUp: (TapUpDetails d) {
            GraphNode? hit;
            // The tap area stays the size of a finger when the picture is
            // zoomed in.
            double best = max(10, 28 / scale);
            for (final GraphNode n in nodes) {
              final double dist = (n.at - d.localPosition).distance;
              if (dist < best) {
                best = dist;
                hit = n;
              }
            }
            if (hit != null) {
              openPerson(hit);
            } else if (_selected != null) {
              setState(() => _selected = null);
            }
          },
          child: RepaintBoundary(
            child: CustomPaint(
              size: size,
              // Screen readers: every person is a button.
              foregroundPainter: _GraphSemantics(
                nodes: nodes,
                onOpen: openPerson,
              ),
              painter: GraphPainter(
                scene: scene,
                look: look,
                progress: _move,
                labels: _labels,
                me: zen.accent,
                meText: zen.onAccent,
                text: zen.textPrimary,
                labelBg: zen.surfaceRaised,
                guide: zen.outlineSoft,
                scale: lod,
                visible: visible,
              ),
            ),
          ),
        );
      },
    );
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: InteractiveViewer(
            key: const Key('graph-viewer'),
            transformationController: _view,
            minScale: 1,
            maxScale: _maxScale,
            child: SizedBox.fromSize(size: size, child: picture),
          ),
        ),
        Positioned(
          right: 8,
          bottom: 8,
          child: ListenableBuilder(
            listenable: _view,
            builder: (BuildContext context, Widget? _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                IconButton.filledTonal(
                  key: const Key('graph-zoom-in'),
                  tooltip: t('Przybliż'),
                  onPressed: _scale >= _maxScale
                      ? null
                      : () => _zoom(1.6, size),
                  icon: const Icon(Icons.add_rounded),
                ),
                IconButton.filledTonal(
                  key: const Key('graph-zoom-out'),
                  tooltip: t('Oddal'),
                  onPressed: _scale <= 1.001
                      ? null
                      : () => _zoom(1 / 1.6, size),
                  icon: const Icon(Icons.remove_rounded),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// The filters: circle, mutual friends, nationality, status, nearby.
  Future<void> _openFilters(BuildContext context) async {
    _nations.clear();
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    final NearbyService nearby = ref.read(nearbyServiceProvider);
    final List<GraphNode> all = _data?.all ?? const <GraphNode>[];
    final Set<String> codes = <String>{
      for (final GraphNode n in all)
        if (n.isFriend) ..._nationsOf(node, n),
      ?_filters.nationality,
    };
    final bool anyNear = nearby.people.any(
      (NearbyPerson p) => p.friend != null,
    );
    final bool anyFar = all.any((GraphNode n) => !n.isFriend);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSheet) {
          final ZenColors zen = ZenColors.of(context);
          void apply(GraphFilters f) {
            setSheet(() {});
            setState(() => _filters = f);
          }

          final GraphFilters f = _filters;
          return SingleChildScrollView(
            key: const Key('graph-filters-sheet'),
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t('Filtry grafu'),
                  style: zen.display(
                    color: zen.textPrimary,
                    size: 20,
                    weight: FontWeight.w600,
                  ),
                ),
                ZenSection(t('Krąg')),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final int ring in <int>[1, 2, 3, if (anyFar) 4])
                      FilterChip(
                        key: Key('graph-ring-$ring'),
                        label: Text(_ringFilterLabel(ring)),
                        selected: f.rings.contains(ring),
                        onSelected: (bool on) => apply(
                          f.copyWith(
                            rings: on
                                ? <int>{...f.rings, ring}
                                : (<int>{...f.rings}..remove(ring)),
                          ),
                        ),
                      ),
                  ],
                ),
                ZenSection(t('Wspólni znajomi')),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final int k in <int>[0, 1, 2, 3, 5])
                      ChoiceChip(
                        key: Key('graph-mutual-$k'),
                        label: Text(
                          k == 0
                              ? t('dowolnie')
                              : t('co najmniej {n}', {'n': k}),
                        ),
                        selected: f.minMutual == k,
                        onSelected: (_) => apply(f.copyWith(minMutual: k)),
                      ),
                  ],
                ),
                ZenSection(t('Narodowość')),
                if (codes.isEmpty)
                  Text(
                    t('Nikt ze znajomych nie pokazuje Ci narodowości.'),
                    style: TextStyle(color: zen.textMuted, fontSize: 13.5),
                  )
                else
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      ChoiceChip(
                        key: const Key('graph-nat-any'),
                        label: Text(t('dowolna')),
                        selected: f.nationality == null,
                        onSelected: (_) =>
                            apply(f.copyWith(nationality: () => null)),
                      ),
                      for (final String c in codes.toList()..sort())
                        ChoiceChip(
                          key: Key('graph-nat-$c'),
                          label: Text('${flagOf(c)} $c'),
                          selected: f.nationality == c,
                          onSelected: (_) =>
                              apply(f.copyWith(nationality: () => c)),
                        ),
                    ],
                  ),
                const SizedBox(height: 8),
                ZenGroup(
                  children: <Widget>[
                    SwitchListTile(
                      key: const Key('graph-with-status'),
                      value: f.withStatus,
                      title: Text(t('Tylko ze statusem')),
                      subtitle: Text(
                        t('Status, online albo „otwarty(-a) na poznanie”.'),
                      ),
                      onChanged: (bool v) => apply(f.copyWith(withStatus: v)),
                    ),
                    if (anyNear || f.nearby)
                      SwitchListTile(
                        key: const Key('graph-nearby'),
                        value: f.nearby,
                        title: Text(t('Tylko w pobliżu')),
                        onChanged: (bool v) => apply(f.copyWith(nearby: v)),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('graph-filters-clear'),
                  onPressed: f.isEmpty
                      ? null
                      : () => apply(const GraphFilters()),
                  icon: const Icon(Icons.filter_alt_off_rounded),
                  label: Text(t('Wyczyść filtry')),
                ),
                const SizedBox(height: 4),
                Text(
                  t(
                    'Graf pokazuje tylko to, co ludzie Ci pokazali: listy '
                    'znajomych, które Ci udostępnili, i pola profilu widoczne '
                    'dla Ciebie.',
                  ),
                  style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The legend of the mode.
  Widget _legend(
    BuildContext context,
    List<GraphNode> nodes,
    GraphFacts facts,
    GatePriceSource prices,
  ) {
    final ZenColors zen = ZenColors.of(context);
    final List<Widget> items = switch (_mode) {
      GraphMode.friends => <Widget>[
        _LegendDot(color: zen.accent, label: t('przyjaciele')),
        _LegendDot(
          color: zen.accent.withValues(alpha: 0.58),
          label: t('słabsza więź'),
        ),
        _LegendDot(
          color: zen.textMuted,
          label: t('znajomi znajomych'),
          small: true,
        ),
        _LegendLine(color: zen.outline, label: t('grubsza linia = bliżej')),
        _LegendDot(
          color: zenTone(zen, 0),
          label: t('krąg (wspólne grono)'),
          ring: true,
        ),
      ],
      GraphMode.statuses => <Widget>[
        for (final (IntentKind k, String label) in <(IntentKind, String)>[
          (IntentKind.urgent, t('pilne')),
          (IntentKind.talk, t('pogadać')),
          (IntentKind.out, t('wyjść')),
          (IntentKind.help, t('pomoc')),
          (IntentKind.canHelp, t('może pomóc')),
          (IntentKind.dnd, t('nie przeszkadzać')),
          (IntentKind.custom, t('własny status')),
        ])
          _LegendDot(color: intentTone(zen, k), label: label),
        _LegendDot(color: zen.success, label: t('online'), small: true),
        _LegendTag(
          key: const Key('graph-legend-open'),
          color: zenTone(zen, 4),
          label: t('randki / znajomości — otwarci na poznanie'),
        ),
      ],
      GraphMode.met => <Widget>[
        _LegendLine(color: zen.success, label: t('spotkani osobiście')),
        _LegendLine(color: zen.outline, label: t('jeszcze nie'), dashed: true),
        _LegendDot(
          color: zen.accentSecondary,
          label: t('teraz w pobliżu'),
          small: true,
        ),
      ],
      GraphMode.pyramid => <Widget>[
        _LegendDot(color: zenTone(zen, 3), label: t('w Twojej piramidzie')),
        _LegendDot(color: zen.accent, label: t('Twoja linia'), ring: true),
        _LegendTag(
          color: zenTone(zen, 3),
          label: t('poz. = poziom w piramidzie'),
        ),
      ],
      GraphMode.gates => <Widget>[
        _LegendLine(color: zen.success, label: t('za darmo')),
        _LegendLine(color: zen.warning, label: t('płatne')),
        _LegendLine(color: zen.accentSecondary, label: t('za zgodą')),
        _LegendLine(color: zen.outline, label: t('brak danych')),
      ],
      GraphMode.route => <Widget>[
        _LegendLine(color: zen.accent, label: t('droga')),
        _LegendDot(color: zen.accent, label: t('osoby na drodze'), ring: true),
      ],
    };
    bool gateData = false;
    if (_mode == GraphMode.gates) {
      for (final GraphNode n in nodes.take(400)) {
        if (n.isFriend
            ? prices.gateOf(n.address) != null
            : n.via.any(
                (String v) => prices.gateOf(n.address, via: v) != null,
              )) {
          gateData = true;
          break;
        }
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            key: Key('graph-legend-${_mode.name}'),
            spacing: 12,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: items,
          ),
          if (_mode == GraphMode.gates && !gateData) ...<Widget>[
            const SizedBox(height: 8),
            ZenInfo(
              key: const Key('graph-gates-nodata'),
              icon: Icons.toll_rounded,
              tone: zen.textSecondary,
              text: t(
                'Brak danych o cenach bramek. Gdy ktoś ustali cenę '
                'wiadomości albo przedstawienia, zobaczysz ją tu na liniach.',
              ),
            ),
          ],
          if (_mode == GraphMode.statuses &&
              !nodes.any(
                (GraphNode n) => facts.hasStatus(n.address),
              )) ...<Widget>[
            const SizedBox(height: 8),
            ZenInfo(
              icon: Icons.bolt_rounded,
              tone: zen.textSecondary,
              text: t('Nikt w tej chwili nie ma statusu.'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _show(
    BuildContext context, {
    required MeetService meet,
    required IntroService intro,
    required LedgerNode? node,
    required GraphNode n,
    required GraphFacts facts,
    required GatePriceSource prices,
    required GraphRoute route,
    required List<String> via,
  }) async {
    final bool far = !n.isFriend;
    final List<String> mutual = far ? via : meet.mutualFriends(n.address);
    final IntentStatus? s = facts.statusOf(n.address);
    final OpenToMeet? openTo = facts.openOf(n.address);
    final PyramidMark? pyr = facts.pyramidOf(n.address);
    final bool met = facts.met(n.address);
    final FriendProfile? friend = n.friend;
    // The profile's status line, when the profile shows it to this person.
    String statusLine = '';
    if (!far && node != null && node.isReady) {
      final String? account = node.knownAccountOf(n.address);
      if (account != null) {
        statusLine = readProfile(node, account)?.status.trim() ?? '';
      }
    }
    final GatePrice? gate = far
        ? (via.isEmpty ? null : prices.gateOf(n.address, via: via.first))
        : prices.gateOf(n.address);
    final bool asked =
        far &&
        via.any(
          (String f) =>
              intro.pending(IntroKind.intro, f, target: n.address) != null,
        );
    final bool listMissing = !far && meet.book.friendsOf(n.address).isEmpty;
    final bool listAsked =
        listMissing && intro.pending(IntroKind.list, n.address) != null;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        final Color tone = s != null
            ? intentTone(zen, s.kind)
            : (far ? zen.textMuted : zen.accent);
        final String trimmed = n.name.trim();
        void then(Future<void> Function() action) {
          Navigator.of(context).pop();
          unawaited(action());
        }

        return SingleChildScrollView(
          key: const Key('graph-person-sheet'),
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: tone.withValues(alpha: 0.18),
                    foregroundColor: tone,
                    child: Text(
                      trimmed.isEmpty
                          ? '?'
                          : trimmed.characters.first.toUpperCase(),
                      style: zen.display(
                        color: tone,
                        size: 24,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          n.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 22,
                            weight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          <String>[
                            _ringLabel(n.ring),
                            if (friend != null && friend.isOnline)
                              t('online')
                            else if (friend != null &&
                                friend.lastPresenceAtMillis > 0)
                              t('widziany(-a) {ago}', {
                                'ago': _ago(
                                  friend.lastPresenceAtMillis,
                                  meet.now,
                                ),
                              }),
                          ].join(' · '),
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('graph-focus'),
                    tooltip: t('Pokaż na grafie'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      _focus(n.address);
                    },
                    icon: const Icon(Icons.center_focus_strong_rounded),
                  ),
                ],
              ),
              if (s != null ||
                  met ||
                  openTo != null ||
                  pyr != null) ...<Widget>[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    if (s != null)
                      ZenPill(
                        text: '${s.shownEmoji} ${s.shownLabel}',
                        tone: intentTone(zen, s.kind),
                      ),
                    if (openTo != null)
                      ZenPill(
                        key: const Key('graph-open-pill'),
                        text: t('Szuka: {what}', {'what': openTo.label}),
                        tone: zenTone(zen, 4),
                        icon: Icons.favorite_border_rounded,
                      ),
                    if (met)
                      ZenPill(
                        text: t('spotkani osobiście'),
                        tone: zen.success,
                        icon: Icons.verified_rounded,
                      ),
                    if (pyr != null)
                      ZenPill(
                        text: pyr.line
                            ? t('Twoja linia · poz. {level}', {
                                'level': pyr.level,
                              })
                            : t('Piramida · poz. {level}', {
                                'level': pyr.level,
                              }),
                        tone: zenTone(zen, 3),
                        icon: kPyramidIcon,
                      ),
                  ],
                ),
                if (s != null && s.shownNote.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(
                    '„${s.shownNote}”',
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 14.5,
                      height: 1.35,
                    ),
                  ),
                ],
              ],
              if (statusLine.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  statusLine,
                  key: const Key('graph-status-line'),
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 14,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              if (mutual.isNotEmpty || !far) ...<Widget>[
                const SizedBox(height: 12),
                ZenInfo(
                  icon: Icons.people_alt_rounded,
                  tone: zenTone(zen, 1),
                  title: mutual.isEmpty
                      ? null
                      : (far ? t('Znacie się przez') : t('Wspólni znajomi')),
                  text: mutual.isEmpty
                      ? t('Brak wspólnych znajomych (albo ich nie pokazują).')
                      : mutual.map(meet.host.nameOf).join(', '),
                ),
              ],
              if (far && route.path.isNotEmpty)
                ZenInfo(
                  icon: Icons.timeline_rounded,
                  tone: zen.accent,
                  title: t('Najlepsza droga'),
                  text:
                      '${<String>[t('Ty'), for (final String a in route.path) a == n.address ? n.name : meet.host.nameOf(a)].join(' → ')}\n${routeCostText(route.cost, route.gates)}',
                ),
              ZenInfo(
                key: const Key('graph-gate'),
                icon: Icons.toll_rounded,
                tone: zen.textSecondary,
                title: far ? t('Przedstawienie') : t('Wiadomość'),
                text: gate == null ? t('brak danych') : gate.label,
              ),
              if (far)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: OutlinedButton.icon(
                    key: const Key('graph-show-route'),
                    onPressed: () {
                      Navigator.of(context).pop();
                      setState(() {
                        _selected = n.address;
                        _mode = GraphMode.route;
                      });
                    },
                    icon: const Icon(Icons.route_rounded),
                    label: Text(t('Pokaż drogę')),
                  ),
                ),
              if (friend != null) ...<Widget>[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('graph-write'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(
                      Navigator.of(this.context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) => ConversationScreen(
                            peerAddress: friend.address,
                            title: n.name,
                          ),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: Text(t('Napisz')),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('graph-profile'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(
                      ProfileScreen.open(this.context, address: friend.address),
                    );
                  },
                  icon: const Icon(Icons.account_circle_outlined),
                  label: Text(t('Profil')),
                ),
                if (listMissing) ...<Widget>[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    key: const Key('graph-ask-list'),
                    onPressed: listAsked
                        ? null
                        : () => then(() => _askList(intro, n.address, n.name)),
                    icon: const Icon(Icons.visibility_rounded),
                    label: Text(
                      listAsked
                          ? t('Prośba o listę wysłana')
                          : t('Poproś o listę znajomych'),
                    ),
                  ),
                ],
              ],
              if (far && via.isNotEmpty) ...<Widget>[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('graph-intro'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: asked
                      ? null
                      : () => then(
                          () => askIntroduction(
                            this.context,
                            ref,
                            target: n.address,
                            targetName: n.name,
                            via: via,
                          ),
                        ),
                  icon: const Icon(Icons.waving_hand_rounded),
                  label: Text(
                    asked
                        ? t('Prośba o przedstawienie wysłana')
                        : t('Poproś o przedstawienie'),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('graph-letter'),
                        onPressed: () => then(
                          () => sendLetterTo(
                            this.context,
                            ref,
                            target: n.address,
                            targetName: n.name,
                            via: via,
                          ),
                        ),
                        icon: const Icon(Icons.mail_outline_rounded),
                        label: Text(t('Napisz list')),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        key: const Key('graph-opinion'),
                        onPressed: () => then(
                          () => askOpinion(
                            this.context,
                            ref,
                            targetName: n.name,
                            via: via,
                          ),
                        ),
                        icon: const Icon(Icons.rate_review_rounded),
                        label: Text(t('Zapytaj o opinię')),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// The name of [address] on the way: someone drawn, else the friends'
  /// name for them.
  String _nameOn(
    String address,
    Map<String, GraphNode> byAddress,
    MeetService meet,
  ) => byAddress[address]?.name ?? meet.host.nameOf(address);
}

/// "Listy znajomych: od X z Y znajomych": who has not sent theirs,
/// each with a way to ask for it.
class _ListsDiagnostics extends StatelessWidget {
  const _ListsDiagnostics({
    required this.meet,
    required this.intro,
    required this.social,
    required this.onAsk,
  });

  final MeetService meet;
  final IntroService intro;
  final SocialHubState social;
  final void Function(String friend, String name) onAsk;

  @override
  Widget build(BuildContext context) {
    final List<FriendProfile> friends = social.acceptedFriends;
    if (friends.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final List<FriendProfile> missing = <FriendProfile>[
      for (final FriendProfile f in friends)
        if (meet.book.friendsOf(f.address).isEmpty) f,
    ];
    final int have = friends.length - missing.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: ZenGroup(
        children: <Widget>[
          ExpansionTile(
            key: const Key('graph-lists-diag'),
            leading: Icon(
              Icons.format_list_bulleted_rounded,
              color: zen.textSecondary,
            ),
            title: Text(
              tn(
                friends.length,
                one: 'Listy znajomych: od {have} z {n} znajomego',
                few: 'Listy znajomych: od {have} z {n} znajomych',
                many: 'Listy znajomych: od {have} z {n} znajomych',
                args: {'have': have},
              ),
            ),
            subtitle: Text(
              missing.isEmpty
                  ? t('Masz listy od wszystkich znajomych.')
                  : t('Bez listy: {count}. Rozwiń, żeby zobaczyć kto.', {
                      'count': missing.length,
                    }),
            ),
            children: <Widget>[
              for (final FriendProfile f in missing) _missingRow(context, f),
            ],
          ),
        ],
      ),
    );
  }

  Widget _missingRow(BuildContext context, FriendProfile f) {
    final String a = PeerShareCodec.normalizeAddress(f.address);
    final String name = social.nameFor(f);
    final bool asked = intro.pending(IntroKind.list, a) != null;
    return ListTile(
      key: Key('graph-diag-row-$a'),
      dense: true,
      title: Text(name),
      subtitle: Text(
        meet.book.friendListDigests.containsKey(a)
            ? t('Nie pokazuje listy')
            : t('Lista jeszcze nie doszła'),
      ),
      trailing: TextButton(
        key: Key('graph-diag-ask-$a'),
        onPressed: asked ? null : () => onAsk(a, name),
        child: Text(asked ? t('Poproszono') : t('Poproś')),
      ),
    );
  }
}

/// One entry of the legend: a dot.
class _LegendDot extends StatelessWidget {
  const _LegendDot({
    required this.color,
    required this.label,
    this.small = false,
    this.ring = false,
  });

  final Color color;
  final String label;
  final bool small;
  final bool ring;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final double d = small ? 7 : 10;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: ring ? 12 : d,
          height: ring ? 12 : d,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: ring ? null : color,
            border: ring ? Border.all(color: color, width: 1.5) : null,
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: TextStyle(color: zen.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// One entry of the legend: a line (dashed or not).
class _LegendLine extends StatelessWidget {
  const _LegendLine({
    required this.color,
    required this.label,
    this.dashed = false,
  });

  final Color color;
  final String label;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 2,
          children: <Widget>[
            for (int i = 0; i < (dashed ? 3 : 1); i++)
              Container(
                width: dashed ? 5 : 18,
                height: 2.4,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: TextStyle(color: zen.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// One entry of the legend: a badge.
class _LegendTag extends StatelessWidget {
  const _LegendTag({required this.color, required this.label, super.key});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color),
          ),
          child: Text('…', style: TextStyle(color: color, fontSize: 10)),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            label,
            style: TextStyle(color: zen.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}

/// Screen readers cannot see a canvas: every person drawn on the graph
/// becomes a button with the name and the circle they belong to. Paints
/// nothing.
class _GraphSemantics extends CustomPainter {
  _GraphSemantics({required this.nodes, required this.onOpen});

  final List<GraphNode> nodes;
  final void Function(GraphNode) onOpen;

  /// The first nodes (closest friends first) — enough to browse, light on
  /// the accessibility tree.
  static const int maxNodes = 120;

  static String ringLabel(int ring) => switch (ring) {
    1 => t('najbliżsi'),
    2 => t('znajomi'),
    3 => t('słabi znajomi'),
    _ => t('znajomi znajomych'),
  };

  @override
  void paint(Canvas canvas, Size size) {}

  @override
  bool shouldRepaint(_GraphSemantics oldDelegate) => false;

  @override
  bool shouldRebuildSemantics(_GraphSemantics oldDelegate) =>
      !identical(oldDelegate.nodes, nodes);

  @override
  SemanticsBuilderCallback get semanticsBuilder =>
      (Size size) => <CustomPainterSemantics>[
        for (final GraphNode n in nodes.take(maxNodes))
          CustomPainterSemantics(
            key: ValueKey<String>(n.address),
            rect: Rect.fromCenter(center: n.at, width: 44, height: 44),
            properties: SemanticsProperties(
              label: t('{name}, {circle}', {
                'name': n.name,
                'circle': ringLabel(n.ring),
              }),
              textDirection: ZenI18n.language.rtl
                  ? TextDirection.rtl
                  : TextDirection.ltr,
              button: true,
              onTap: () => onOpen(n),
            ),
          ),
      ];
}
