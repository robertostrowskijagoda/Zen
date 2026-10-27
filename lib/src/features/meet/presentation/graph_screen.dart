import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/meet/events/event_service.dart';
import 'package:zen/src/features/meet/graph/gate_prices.dart';
import 'package:zen/src/features/meet/graph/graph_full_screen.dart';
import 'package:zen/src/features/meet/graph/graph_insights.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/graph/graph_painter.dart';
import 'package:zen/src/features/meet/graph/graph_panels.dart';
import 'package:zen/src/features/meet/graph/graph_providers.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/graph/trust_map.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/meet/presentation/ask_screen.dart';
import 'package:zen/src/features/meet/presentation/gate_widgets.dart';
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
  GraphMode.time => Icons.history_rounded,
  GraphMode.bridges => Icons.device_hub_rounded,
  GraphMode.neglect => Icons.hourglass_bottom_rounded,
};

String _ringLabel(int ring) => switch (ring) {
  1 => t('Przyjaciel(-ółka)'),
  2 => t('Znajomy(-a)'),
  3 => t('Słaby(-a) znajomy(-a)'),
  4 => t('Znajomy(-a) znajomych'),
  _ => t('Dalsza znajomość'),
};

String _ringFilterLabel(int ring) => switch (ring) {
  1 => t('Przyjaciele'),
  2 => t('Znajomi'),
  3 => t('Słabi znajomi'),
  4 => t('Znajomi znajomych'),
  _ => t('Dalej'),
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
  final Set<String> mates = s.cellmates(me).toSet();
  final int now = pyr.now;
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
      cellmate: mates.contains(m.key),
      met: s.metWith(me, m.key, now),
    );
  }
  return out;
}

/// The look of each person and line in [mode]. Pure: the same inputs
/// give the same picture (tests read it). [bridges] and [islands] (people
/// of lone circles) for "Mosty", [neglected] for "Dawno".
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
  Set<String> bridges = const <String>{},
  Set<String> islands = const <String>{},
  Set<String> neglected = const <String>{},
  Set<String> focus = const <String>{},
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
    final bool lit =
        a == selected ||
        marked.contains(a) ||
        onRoute.contains(a) ||
        (mode == GraphMode.route && !routing && focus.contains(a));
    final double radius = n.isFriend
        ? switch (n.ring) {
            1 => 10.0,
            2 => 9.0,
            _ => 7.5,
          }
        : n.isFar
        ? (crowded ? 2.5 : 3.5)
        : (crowded ? 3.0 : 4.5);
    Color fill = n.isFriend
        ? switch (n.ring) {
            1 => zen.accent,
            2 => zen.accent.withValues(alpha: 0.82),
            _ => zen.accent.withValues(alpha: 0.58),
          }
        : n.isFar
        ? zen.textMuted.withValues(alpha: 0.7)
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
        if ((routing && !onRoute.contains(a)) ||
            (!routing && focus.isNotEmpty && !focus.contains(a))) {
          fill = dim(fill, 0.2);
        }
      case GraphMode.time:
        break;
      case GraphMode.bridges:
        if (bridges.contains(a)) {
          ring = zen.accent;
          tag = t('most');
          tagTone = zen.accent;
        } else if (islands.contains(a)) {
          fill = zenTone(zen, 5);
        } else {
          fill = dim(fill, n.isFriend ? 0.45 : 0.2);
        }
      case GraphMode.neglect:
        if (neglected.contains(a)) {
          fill = zen.accentSecondary;
          ring = zen.accentSecondary.withValues(alpha: 0.5);
        } else {
          fill = dim(fill, n.isFriend ? 0.4 : 0.15);
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
        // In a cell together, not yet confirmed as known: dashed.
        dashed = spoke && (m?.unmetCellmate ?? false);
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
      case GraphMode.time:
        break;
      case GraphMode.bridges:
        color = color.withValues(alpha: spoke ? 0.4 : 0.2);
      case GraphMode.neglect:
        if (spoke && neglected.contains(to.address)) {
          color = zen.accentSecondary;
          dashed = true;
        } else {
          color = color.withValues(alpha: spoke ? 0.35 : 0.15);
        }
    }
    edges.add(EdgeLook(color: color, width: width, dashed: dashed, tag: tag));
  }
  return GraphLook(
    nodes: looks,
    edges: edges,
    link: switch (mode) {
      GraphMode.friends || GraphMode.time => zen.outline.withValues(alpha: 0.6),
      GraphMode.bridges => zen.outline.withValues(alpha: 0.5),
      GraphMode.route when routing => zen.outline.withValues(alpha: 0.12),
      _ => zen.outline.withValues(alpha: 0.3),
    },
    route: <int>[
      if (routing || mode != GraphMode.route)
        for (final String a in route)
          if (index[a] case final int i) i,
    ],
    showHalos: mode == GraphMode.friends || mode == GraphMode.bridges,
  );
}

/// The band (ring) each person sits on in [mode]: modes that are about one
/// thing pull those people inwards, so changing the mode moves people.
int graphBand(
  GraphMode mode,
  GraphNode n,
  GraphFacts f,
  Map<String, PyramidMark> pyr, {
  Set<String> neglected = const <String>{},
}) {
  switch (mode) {
    case GraphMode.statuses:
      final bool on =
          f.statusOf(n.address) != null || f.openOf(n.address) != null;
      if (n.isFar) {
        return on ? 4 : 5;
      }
      return n.isFriend ? (on ? 1 : 2) : (on ? 3 : 4);
    case GraphMode.met:
      return n.isFriend ? (f.met(n.address) ? 1 : 2) : n.ring;
    case GraphMode.pyramid:
      final PyramidMark? m = pyr[n.address];
      return m == null ? (n.isFriend ? 3 : n.ring) : (m.line ? 1 : 2);
    case GraphMode.neglect:
      return n.isFriend ? (neglected.contains(n.address) ? 1 : 2) : n.ring;
    case GraphMode.friends:
    case GraphMode.gates:
    case GraphMode.route:
    case GraphMode.time:
    case GraphMode.bridges:
      return n.ring;
  }
}

/// "Graf": you in the middle, friends around by closeness, friends of
/// friends further out. Modes show statuses, meetings, the pyramid, gate
/// prices and the way to a person; search, filters, focus and the card of
/// each person with what can be done.
class GraphScreen extends ConsumerStatefulWidget {
  const GraphScreen({
    super.key,
    this.fullScreen = false,
    this.initial = const GraphView(),
    this.onLeave,
  });

  /// The graph alone on the whole screen, its controls as an overlay that
  /// hides by itself.
  final bool fullScreen;

  /// How to look at it first (the mode, filters… of the screen it came
  /// from).
  final GraphView initial;

  /// Full screen: how it was looked at when it closed.
  final ValueChanged<GraphView>? onLeave;

  static Future<void> open(BuildContext context) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const GraphScreen(),
    ),
  );

  /// "Bezpieczna randka": the graph in the "Ścieżka" mode with [friends] —
  /// the trusted friends this person and a dating match [name] both know
  /// (shown only after both agreed) — lit, to ask them for an opinion.
  static Future<void> openSafeDate(
    BuildContext context, {
    required String name,
    required Iterable<String> friends,
  }) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => GraphScreen(
        initial: GraphView(
          mode: GraphMode.route,
          focus: <String>{
            for (final String f in friends) PeerShareCodec.normalizeAddress(f),
          },
          focusName: name,
        ),
      ),
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
    required this.book,
  });

  final Object key;
  final List<GraphNode> all;
  final List<String> friendOrder;
  final Map<String, int> ringOf;
  final Map<String, int> mutual;
  final Set<String> met;
  final MeetBook book;

  /// Communities among everyone ([graphClusters]): the same colours and
  /// names whatever the filters.
  late final Map<String, int> clusters = graphClusters(all, book);

  /// Friends who know each other ([friendLinks]).
  late final List<(String, String)> links = friendLinks(friendOrder, book);

  /// Bridges and lone circles ([bridgesOf]).
  late final BridgeReport bridges = bridgesOf(
    all,
    clusters,
    links,
    mutual: mutual,
  );
}

class _GraphScreenState extends ConsumerState<GraphScreen>
    with TickerProviderStateMixin {
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

  /// Where the timeline is (0: 12 months ago … 1: now); runs when played.
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
    value: 1,
  );

  /// Months back the timeline shows (0: now).
  int _timeMonths = 0;
  GraphTimeline? _timeline;
  Object? _timelineKey;

  /// People further away, read again only when friends passed on more.
  Map<String, FarPerson> _far = const <String, FarPerson>{};
  Object? _farToken;

  /// Conversations were read once for their dates (this screen's life).
  bool _scanned = false;

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
    final GraphView v = widget.initial;
    _mode = v.mode;
    _filters = v.filters;
    _goal = v.goal;
    _selected = v.selected;
    _timeMonths = v.timeMonths;
    _focus = v.focus;
    _focusName = v.focusName;
    if (_mode == GraphMode.time) {
      _clock.value = timelinePhase(_timeMonths);
    }
    if (widget.fullScreen) {
      _chrome = ref.read(graphFullScreenChromeProvider);
      unawaited(_chrome!.enter());
      _armHide();
    }
  }

  /// "Bezpieczna randka": friends lit in the "Ścieżka" mode, and with whom.
  Set<String> _focus = const <String>{};
  String _focusName = '';

  // ---- full screen ----

  /// The system's bars while full screen (null otherwise).
  FullScreenChrome? _chrome;

  /// The overlay controls are shown (always, outside full screen).
  bool _chromeShown = true;
  Timer? _hide;

  /// A computer: a double click also switches full screen.
  static bool get _desktopInput => switch (defaultTargetPlatform) {
    TargetPlatform.windows ||
    TargetPlatform.linux ||
    TargetPlatform.macOS => true,
    _ => false,
  };

  GraphView _currentView() => GraphView(
    mode: _mode,
    filters: _filters,
    goal: _goal,
    selected: _selected,
    timeMonths: _timeMonths,
    focus: _focus,
    focusName: _focusName,
  );

  /// Full screen on, or back from it.
  Future<void> _toggleFull() async {
    if (widget.fullScreen) {
      await Navigator.of(context).maybePop();
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        pageBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondary,
            ) => GraphScreen(
              fullScreen: true,
              initial: _currentView(),
              onLeave: _backFromFull,
            ),
        transitionsBuilder:
            (
              BuildContext context,
              Animation<double> animation,
              Animation<double> secondary,
              Widget child,
            ) => FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  /// Back from full screen: looked at as it was left there.
  void _backFromFull(GraphView v) {
    if (!mounted) {
      return;
    }
    setState(() {
      _mode = v.mode;
      _filters = v.filters;
      _goal = v.goal;
      _selected = v.selected;
      _timeMonths = v.timeMonths;
    });
    if (_mode == GraphMode.time) {
      _clock.value = timelinePhase(_timeMonths);
    }
  }

  /// A touch, a click or the mouse moving: the controls come back for a
  /// while.
  void _poke() {
    if (!widget.fullScreen) {
      return;
    }
    if (!_chromeShown) {
      setState(() => _chromeShown = true);
    }
    _armHide();
  }

  void _armHide() {
    _hide?.cancel();
    _hide = Timer(kGraphChromeHideAfter, () {
      if (mounted && _chromeShown) {
        setState(() => _chromeShown = false);
      }
    });
  }

  /// Controls that hide by themselves in full screen.
  Widget _fading(Widget child) => AnimatedOpacity(
    opacity: _chromeShown ? 1 : 0,
    duration: const Duration(milliseconds: 250),
    child: IgnorePointer(ignoring: !_chromeShown, child: child),
  );

  /// The full-screen page: [picture] fills it, the mode bar (and the
  /// route's or timeline's controls) float on top while shown.
  Widget _fullLayout(
    BuildContext context, {
    required Widget picture,
    required List<GraphMode> modes,
    required GraphRoute route,
    required String? selected,
    required List<GraphNode> all,
    required MeetService meet,
    required bool timed,
    required GraphNotes kept,
  }) {
    final ZenColors zen = ZenColors.of(context);
    return Listener(
      key: const Key('graph-full-layout'),
      onPointerDown: (_) => _poke(),
      onPointerHover: (_) => _poke(),
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ColoredBox(color: zen.surface, child: picture),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: SafeArea(
              bottom: false,
              child: _fading(
                Container(
                  key: const Key('graph-full-controls'),
                  margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                  padding: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: zen.surfaceRaised.withValues(alpha: 0.9),
                    borderRadius: context.zenRadius(18),
                    border: Border.all(color: zen.outlineSoft),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      _modeBar(context, modes),
                      if (_mode == GraphMode.route)
                        _routeBar(context, route, selected, all, meet),
                      if (timed)
                        GraphTimeBar(
                          months: _timeMonths,
                          onMonths: _setTime,
                          playing: _clock.isAnimating,
                          onPlay: _playTime,
                          clock: _clock,
                          timeline: _timeline,
                          nodes: _scene?.layout.nodes ?? const <GraphNode>[],
                          baseline: kept.baseline,
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _hide?.cancel();
    final FullScreenChrome? chrome = _chrome;
    if (chrome != null) {
      unawaited(chrome.exit());
    }
    final ValueChanged<GraphView>? leave = widget.onLeave;
    if (leave != null) {
      final GraphView v = _currentView();
      // Not while the tree is being taken down: right after.
      WidgetsBinding.instance.addPostFrameCallback((_) => leave(v));
    }
    _view
      ..removeListener(_onView)
      ..dispose();
    _move.dispose();
    _clock.dispose();
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
  void _centerOn(String address) {
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
    if (_clock.isAnimating) {
      _clock.stop();
    }
    setState(() => _mode = mode);
    if (mode == GraphMode.time) {
      _clock.value = timelinePhase(_timeMonths);
    }
  }

  /// The timeline at [months] back (0: now).
  void _setTime(int months) {
    _clock.stop();
    setState(() => _timeMonths = months);
    _clock.value = timelinePhase(months);
  }

  /// Plays how the graph grew over the last 12 months (or stops it).
  void _playTime() {
    if (_clock.isAnimating) {
      _clock.stop();
      setState(() {});
      return;
    }
    setState(() => _timeMonths = 0);
    unawaited(
      _clock.forward(from: 0).whenComplete(() {
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  /// People further away: friends of gatekeepers friends passed on, and
  /// people open to meet further out (as far as the graph reaches).
  Map<String, FarPerson> _farFor(IntroService intro, OpenToMeetService open) {
    final Map<String, FarPerson> daters = open.farOpen();
    final Object token = Object.hash(
      identityHashCode(intro.relayedToken),
      daters.length,
      Object.hashAllUnordered(daters.keys),
    );
    if (token != _farToken) {
      _farToken = token;
      final Map<String, FarPerson> merged = <String, FarPerson>{
        for (final MapEntry<String, FarPerson> e in intro.farPeople().entries)
          e.key: (name: e.value.name, via: <String>{...e.value.via}),
      };
      daters.forEach((String a, FarPerson p) {
        final FarPerson? had = merged[a];
        merged[a] = (
          name: had == null || had.name.isEmpty ? p.name : had.name,
          via: <String>{...?had?.via, ...p.via},
        );
      });
      _far = merged;
    }
    return _far;
  }

  /// The people, rebuilt when the friends, their lists or levels change.
  _GraphData _dataFor({
    required SocialHubState social,
    required MeetBook book,
    required LedgerNode? node,
    Map<String, FarPerson> far = const <String, FarPerson>{},
    String own = '',
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
      identityHashCode(far),
      own,
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
      far: far,
      self: own.isEmpty
          ? null
          : (String a) => PeerShareCodec.addressesEqual(a, own),
    );
    // Friends, closest first: the way through them wins a tie.
    final List<GraphNode> friends =
        all.where((GraphNode n) => n.isFriend).toList()
          ..sort((GraphNode a, GraphNode b) => a.ring.compareTo(b.ring));
    final _GraphData data = _data = _GraphData(
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
      book: book,
    );
    // Dates from now on: who came since the graph was last drawn.
    final GraphNotesService notes = ref.read(graphNotesProvider);
    unawaitedLogged(
      notes.observe(
        friends: data.friendOrder,
        far: <String>[
          for (final GraphNode n in all)
            if (!n.isFriend) n.address,
        ],
      ),
      context: 'Graf: daty',
    );
    return data;
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
    required Map<String, int> clusters,
    required String Function(int cluster) circleName,
    required ZenColors zen,
    Set<String> neglected = const <String>{},
    Object names = '',
  }) {
    int band(GraphNode n) =>
        graphBand(_mode, n, facts, pyramid, neglected: neglected);
    final Object key = Object.hash(
      Object.hashAll(<String>[for (final GraphNode n in nodes) n.address]),
      size,
      _mode,
      Object.hashAll(<int>[for (final GraphNode n in nodes) band(n)]),
      identityHashCode(_data),
      names,
    );
    final GraphScene? old = _scene;
    if (old != null && _sceneKey == key) {
      return old;
    }
    final GraphLayout layout = graphLayout(
      nodes,
      size,
      cluster: clusters,
      bandOf: band,
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
    // Communities: a soft blob each, named by this person, else after a
    // shared chat group or the friend who knows most of them.
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
            name: circleName(e.key),
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
    final GraphNotesService notes = ref.watch(graphNotesProvider);
    final Widget screen = Scaffold(
      key: Key(widget.fullScreen ? 'graph-full-screen' : 'graph-screen'),
      appBar: widget.fullScreen
          ? null
          : ZenSectionBar(title: t('Graf znajomych')),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[
          meet,
          nearby,
          open,
          intro,
          notes,
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
          notes: notes,
        ),
      ),
    );
    // F11 switches full screen, Esc leaves it (keyboards, mostly computers).
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            unawaited(_toggleFull()),
        if (widget.fullScreen)
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              unawaited(_toggleFull()),
      },
      child: Focus(autofocus: true, child: screen),
    );
  }

  /// The circles of [data] with their names: the one this person gave
  /// (privately) or the automatic one.
  List<GraphCircle> _circlesOf(
    _GraphData data,
    GraphNotesService notes,
    SocialHubState social,
  ) {
    final Object key = Object.hash(
      identityHashCode(data),
      notes.revision,
      identityHashCode(social.groups),
    );
    if (key == _circlesKey) {
      return _circles;
    }
    _circlesKey = key;
    return _circles = _makeCircles(data, notes.notes, social);
  }

  Object? _circlesKey;
  List<GraphCircle> _circles = const <GraphCircle>[];

  List<GraphCircle> _makeCircles(
    _GraphData data,
    GraphNotes kept,
    SocialHubState social,
  ) {
    final Map<String, Set<String>> groupMembers = <String, Set<String>>{
      for (final GroupProfile g in social.groups.values)
        if (g.name.trim().isNotEmpty)
          g.name.trim(): <String>{
            for (final String m in g.memberAddresses)
              PeerShareCodec.normalizeAddress(m),
          },
    };
    final Map<int, String> auto = clusterNames(
      data.all,
      data.clusters,
      groups: groupMembers,
      mutual: data.mutual,
    );
    final Map<int, Set<String>> members = <int, Set<String>>{};
    data.clusters.forEach((String a, int c) {
      if (c >= 0) {
        members.putIfAbsent(c, () => <String>{}).add(a);
      }
    });
    final List<int> ids = members.keys.toList()..sort();
    return <GraphCircle>[
      for (final int c in ids)
        (
          id: c,
          name: auto[c] ?? '',
          label: labelFor(members[c]!, kept.labels.values),
          members: members[c]!,
        ),
    ];
  }

  /// The days friends were met in person, read again only when the people
  /// or what is known about meetings changed.
  Map<String, int> _metDaysFor(LedgerNode? node, _GraphData data) {
    final Object key = Object.hash(
      identityHashCode(data),
      node?.isReady ?? false,
      data.met.length,
    );
    if (key != _metKey) {
      _metKey = key;
      _metDays = metDays(node);
    }
    return _metDays;
  }

  Object? _metKey;
  Map<String, int> _metDays = const <String, int>{};

  /// Friends whose conversations were read again this time.
  final Set<String> _refreshed = <String>{};

  /// Reads the dates out of conversations already on this phone: everyone
  /// once, and [again] (those "Dawno" would show) once more, after this
  /// frame.
  void _scanLater(
    GraphNotesService notes,
    SocialHubState social,
    Iterable<String> again,
  ) {
    final List<String> fresh = <String>[
      for (final String a in again)
        if (_refreshed.add(a)) a,
    ];
    if (_scanned && fresh.isEmpty) {
      return;
    }
    final bool first = !_scanned;
    _scanned = true;
    final Map<String, String> addressOf = <String, String>{
      for (final FriendProfile f in social.acceptedFriends)
        PeerShareCodec.normalizeAddress(f.address): f.address,
    };
    final Future<List<ChatMessage>> Function(String) load = ref
        .read(messageTimelineStoreProvider)
        .load;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaitedLogged(() async {
        if (first) {
          await notes.scanConversations(addressOf.values, load);
        }
        if (fresh.isNotEmpty) {
          await notes.scanConversations(
            <String>[for (final String a in fresh) addressOf[a] ?? a],
            load,
            all: true,
          );
        }
      }(), context: 'Graf: daty z rozmów');
    });
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
    required GraphNotesService notes,
  }) {
    final ZenColors zen = ZenColors.of(context);
    final int nowMs = meet.now;
    final _GraphData data = _dataFor(
      social: social,
      book: meet.book,
      node: node,
      far: _farFor(intro, open),
      own: intro.host.ownAddress(),
    );
    final List<GraphNode> all = data.all;
    final GraphNotes kept = notes.notes;
    // Circles, with the names this person gave them (only they see them).
    final List<GraphCircle> circles = _circlesOf(data, notes, social);
    final Map<int, GraphCircle> circleById = <int, GraphCircle>{
      for (final GraphCircle c in circles) c.id: c,
    };
    String circleName(int c) {
      final GraphCircle? x = circleById[c];
      return x == null ? '' : (x.label?.name ?? x.name);
    }

    final Map<String, Set<String>> labelPeople = <String, Set<String>>{
      for (final CircleLabel l in kept.labels.values)
        l.id: <String>{
          ...l.members,
          for (final GraphCircle c in circles)
            if (c.label?.id == l.id) ...c.members,
        },
    };
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
      inLabel: (String a, String label) =>
          labelPeople[label]?.contains(a) ?? false,
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
            friendsOf: intro.knownFriendsOf,
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
    // What the modes about this person's own circle need.
    final bool timed = _mode == GraphMode.time;
    final Map<String, int> metAt = timed || _mode == GraphMode.neglect
        ? _metDaysFor(node, data)
        : const <String, int>{};
    final List<NeglectedFriend> neglectedList = _mode == GraphMode.neglect
        ? neglectedFriends(all, kept, now: nowMs, metAt: metAt)
        : const <NeglectedFriend>[];
    final Set<String> neglected = <String>{
      for (final NeglectedFriend f in neglectedList) f.node.address,
    };
    if (timed || _mode == GraphMode.neglect) {
      _scanLater(notes, social, neglected);
    }
    final BridgeReport? bridges = _mode == GraphMode.bridges
        ? data.bridges
        : null;
    final Set<String> islandPeople = <String>{
      if (bridges != null)
        for (final GraphNode n in all)
          if (n.isFriend &&
              bridges.islands.contains(data.clusters[n.address] ?? -1))
            n.address,
    };
    final IntentStatus? myIntent = meet.book.myIntent;
    final Set<String> asked = <String>{
      for (final IntroCase c in intro.mine)
        if (c.isPending) c.target,
    };
    final List<MeetSuggestion> suggestions = _mode == GraphMode.friends
        ? whoToMeet(
            all,
            facts,
            myStatus: myIntent != null && myIntent.activeAt(nowMs)
                ? myIntent
                : null,
            myOpen: open.mine,
            skip: asked,
          )
        : const <MeetSuggestion>[];
    String nameOfAny(String a) => byAddress[a]?.name ?? meet.host.nameOf(a);

    // The people who connect [n], closest friends first.
    List<String> viaOf(GraphNode n) => <String>[...n.via]
      ..sort(
        (String a, String b) =>
            (data.ringOf[a] ?? 9).compareTo(data.ringOf[b] ?? 9),
      );

    void openPerson(GraphNode n) {
      FocusScope.of(context).unfocus();
      setState(() => _selected = n.address);
      final List<String> via = viaOf(n);
      unawaited(
        _show(
          context,
          meet: meet,
          intro: intro,
          node: node,
          n: n,
          facts: facts,
          prices: prices,
          pyramid: pyramid,
          route: graphRoute(
            friends: data.friendOrder,
            book: meet.book,
            target: n.address,
            prices: prices,
            goal: _mode == GraphMode.route ? _goal : RouteGoal.shortest,
            friendsOf: intro.knownFriendsOf,
          ),
          via: via,
          nameOf: nameOfAny,
        ),
      );
    }

    final Widget picture = all.isEmpty
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
                clusters: data.clusters,
                circleName: circleName,
                zen: zen,
                neglected: neglected,
                names: Object.hashAll(<String>[
                  for (final GraphCircle c in circles) c.label?.name ?? c.name,
                ]),
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
                bridges: bridges?.bridges ?? const <String>{},
                islands: islandPeople,
                neglected: neglected,
                focus: _focus,
              );
              return _canvasView(
                context,
                scene,
                look,
                size,
                openPerson,
                timeline: timed
                    ? _timelineFor(scene, notes, metAt, nowMs)
                    : null,
              );
            },
          );
    if (widget.fullScreen) {
      return _fullLayout(
        context,
        picture: picture,
        modes: modes,
        route: route,
        selected: selected,
        all: all,
        meet: meet,
        timed: timed,
        kept: kept,
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
                                            .map(nameOfAny)
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
                                    (_) => _centerOn(h.address),
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
            if (timed)
              GraphTimeBar(
                months: _timeMonths,
                onMonths: _setTime,
                playing: _clock.isAnimating,
                onPlay: _playTime,
                clock: _clock,
                timeline: _timeline,
                nodes: _scene?.layout.nodes ?? const <GraphNode>[],
                baseline: kept.baseline,
              ),
            SizedBox(
              height: graphHeight,
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                decoration: BoxDecoration(
                  borderRadius: context.zenRadius(26),
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
                child: picture,
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
                padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 8, 0),
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
            if (bridges != null)
              BridgesSection(
                report: bridges,
                nameOf: nameOfAny,
                circleName: circleName,
                onIntroduce: (String a, String b) => unawaited(
                  introduceFriends(
                    context,
                    ref,
                    a: a,
                    b: b,
                    nameA: nameOfAny(a),
                    nameB: nameOfAny(b),
                  ),
                ),
              ),
            if (_mode == GraphMode.neglect)
              NeglectSection(
                items: neglectedList,
                weeks: kept.neglectWeeks,
                onWeeks: (int w) => unawaited(notes.setNeglectWeeks(w)),
                now: nowMs,
                onWrite: _write,
                onLater: (GraphNode n) => unawaited(
                  notes.snooze(n.address, const Duration(days: 28)),
                ),
              ),
            if (_mode == GraphMode.friends) ...<Widget>[
              MeetSuggestionsSection(
                items: suggestions,
                nameOf: nameOfAny,
                onAsk: (MeetSuggestion s) =>
                    unawaited(_quickIntro(intro, s.node, viaOf(s.node))),
                onAdd: (MeetSuggestion s) =>
                    unawaited(_addFriend(intro, s.node, viaOf(s.node))),
                onOpen: (MeetSuggestion s) => openPerson(s.node),
              ),
              CirclesSection(
                circles: <GraphCircle>[
                  for (final GraphCircle c in circles)
                    if (c.members.length >= 2) c,
                ],
                onRename: (GraphCircle c) => unawaited(_renameCircle(notes, c)),
              ),
            ],
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

  /// The timeline of [scene] over the last 12 months, built again only
  /// when the people, the notes or the day change.
  GraphTimeline _timelineFor(
    GraphScene scene,
    GraphNotesService notes,
    Map<String, int> metAt,
    int nowMs,
  ) {
    const int day = 24 * 3600 * 1000;
    final int to = nowMs - nowMs % day + day;
    final Object key = Object.hash(
      identityHashCode(scene),
      notes.revision,
      identityHashCode(metAt),
      to,
    );
    final GraphTimeline? had = _timeline;
    if (had != null && key == _timelineKey) {
      return had;
    }
    _timelineKey = key;
    final GraphTimeline made = graphTimeline(
      scene.layout.nodes,
      notes.notes,
      from: monthsBack(to, 12),
      to: to,
      metAt: metAt,
    );
    _timeline = made;
    // The bar above the picture shows what the new timeline says.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
    return made;
  }

  /// Opens the conversation with friend [n].
  void _write(GraphNode n) {
    final FriendProfile? friend = n.friend;
    if (friend == null) {
      return;
    }
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) =>
              ConversationScreen(peerAddress: friend.address, title: n.name),
        ),
      ),
    );
  }

  /// One tap: asks the closest friend in [via] to introduce this person to
  /// [n] (a priced gate opens the dialog with its price instead).
  Future<void> _quickIntro(
    IntroService intro,
    GraphNode n,
    List<String> via,
  ) async {
    if (via.isEmpty) {
      return;
    }
    final String middle = via.first;
    final GateTerms? terms = intro.gateTermsOf(middle);
    if (terms != null && !terms.free) {
      await askIntroduction(
        context,
        ref,
        target: n.address,
        targetName: n.name,
        via: via,
      );
      return;
    }
    final IntroCase? c = await intro.askIntro(
      middle: middle,
      target: n.address,
      targetName: n.name,
    );
    if (!mounted) {
      return;
    }
    setState(() {});
    _snack(
      c == null
          ? t('Nie można teraz poprosić.')
          : t('Prośba poszła do: {name}.', {'name': intro.host.nameOf(middle)}),
    );
  }

  /// "Dodaj do znajomych" on someone who is not a friend: a friend request
  /// through the closest friend who knows them, or directly when no friend
  /// does. They decide.
  Future<void> _addFriend(
    IntroService intro,
    GraphNode n,
    List<String> via,
  ) async {
    final String middle = n.ring == 4 && via.isNotEmpty ? via.first : '';
    if (intro.friendAskTo(n.address) == null && intro.friendAsksLeft() <= 0) {
      _snack(
        t(
          'Wysłano już {n} zaproszeń z grafu w tym tygodniu. Spróbuj za '
          'kilka dni.',
          {'n': kFriendAsksPerWeek},
        ),
      );
      return;
    }
    final IntroCase? c = await intro.askFriend(
      target: n.address,
      targetName: n.name,
      middle: middle,
    );
    if (!mounted) {
      return;
    }
    setState(() {});
    _snack(
      c == null
          ? t('Nie można teraz wysłać zaproszenia.')
          : middle.isEmpty
          ? t('Zaproszenie poszło do: {name}.', {'name': n.name})
          : t('Zaproszenie idzie przez: {via}. Decyduje: {name}.', {
              'via': intro.host.nameOf(middle),
              'name': n.name,
            }),
    );
  }

  /// Gives circle [c] a private name (or takes it back).
  Future<void> _renameCircle(GraphNotesService notes, GraphCircle c) async {
    final CircleLabel? label = c.label;
    final String? name = await askCircleName(
      context,
      current: label?.name ?? c.name,
      named: label != null,
    );
    if (name == null) {
      return;
    }
    if (cleanCircleLabel(name).isEmpty) {
      if (label != null) {
        await notes.removeLabel(label.id);
      }
      return;
    }
    await notes.setLabel(c.members, name);
  }

  /// The modes, and the filters button with how many are on.
  Widget _modeBar(BuildContext context, List<GraphMode> modes) {
    final int active = _filters.active;
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(0, 4, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsetsDirectional.only(start: 16, end: 8),
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
          IconButton(
            key: const Key('graph-snapshot'),
            tooltip: t('Zrzut grafu bez danych osobowych'),
            onPressed: _scene == null || _data == null
                ? null
                : () => unawaited(
                    showGraphSnapshot(
                      context,
                      ref,
                      scene: _scene!,
                      clusters: _data!.clusters,
                    ),
                  ),
            icon: const Icon(Icons.photo_camera_outlined),
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

  /// Asks the gatekeepers at the edge of what is known what lies further:
  /// more people and longer ways show up as the answers come.
  Future<void> _explore() async {
    final int asked = await ref.read(introServiceProvider).exploreFurther();
    if (!mounted) {
      return;
    }
    _snack(
      asked > 0
          ? t(
              'Pytam o dalsze drogi ({n}). Nowe osoby i drogi pojawią się na '
              'grafie.',
              {'n': asked},
            )
          : t('Teraz nie ma kogo pytać dalej. Spróbuj za chwilę.'),
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
          // The route (who leads to whom) can be copied.
          SelectionArea(
            child: ZenInfo(
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
          ),
          if (_focus.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            SelectionArea(
              child: ZenInfo(
                key: const Key('graph-safe-date'),
                icon: Icons.shield_rounded,
                tone: zen.success,
                title: t('Bezpieczna randka'),
                text: t(
                  'Wspólni zaufani znajomi z: {name} — {names}. Dotknij '
                  'kogoś na grafie, żeby zapytać o opinię.',
                  {
                    'name': _focusName,
                    'names': <String>[
                      for (final String a in _focus)
                        _nameOn(a, byAddress, meet),
                    ].join(', '),
                  },
                ),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: const Key('graph-explore'),
              onPressed: () => unawaited(_explore()),
              icon: const Icon(Icons.travel_explore_rounded),
              label: Text(t('Szukaj dalszych dróg')),
            ),
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
    void Function(GraphNode) openPerson, {
    GraphTimeline? timeline,
  }) {
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
          // A double click on a computer: full screen on or off.
          onDoubleTap: _desktopInput ? () => unawaited(_toggleFull()) : null,
          onTapUp: (TapUpDetails d) {
            GraphNode? hit;
            // The tap area stays the size of a finger when the picture is
            // zoomed in.
            double best = max(10, 28 / scale);
            for (int i = 0; i < nodes.length; i++) {
              final GraphNode n = nodes[i];
              // Not on the timeline yet: not there to tap.
              if (timeline != null &&
                  i < timeline.born.length &&
                  timeline.born[i] > _clock.value) {
                continue;
              }
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
                labels: _labels..direction = Directionality.of(context),
                me: zen.accent,
                meText: zen.onAccent,
                text: zen.textPrimary,
                labelBg: zen.surfaceRaised,
                guide: zen.outlineSoft,
                scale: lod,
                visible: visible,
                timeline: timeline,
                clock: timeline == null ? null : _clock,
                metTone: zen.success,
                labelRadius: ZenLook.of(context).radius(8),
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
        PositionedDirectional(
          end: 8,
          bottom: 8,
          child: ListenableBuilder(
            listenable: _view,
            builder: (BuildContext context, Widget? _) => _fading(
              SafeArea(
                top: false,
                left: false,
                right: widget.fullScreen,
                bottom: widget.fullScreen,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    IconButton.filledTonal(
                      key: const Key('graph-full-toggle'),
                      tooltip: widget.fullScreen
                          ? t('Zamknij pełny ekran')
                          : t('Pełny ekran'),
                      onPressed: () => unawaited(_toggleFull()),
                      icon: Icon(
                        widget.fullScreen
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                      ),
                    ),
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
    final bool anyFar = all.any((GraphNode n) => n.ring == 4);
    final bool anyFurther = all.any((GraphNode n) => n.isFar);
    final List<CircleLabel> labels =
        ref.read(graphNotesProvider).notes.labels.values.toList()
          ..sort((CircleLabel a, CircleLabel b) => a.name.compareTo(b.name));
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
                    for (final RingPreset p in RingPreset.values)
                      ChoiceChip(
                        key: Key('graph-rings-${p.name}'),
                        showCheckmark: false,
                        label: Text(p.label),
                        selected: RingPreset.of(f.rings) == p,
                        onSelected: (_) => apply(f.copyWith(rings: p.rings)),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    for (final int ring in <int>[
                      1,
                      2,
                      3,
                      if (anyFar) 4,
                      if (anyFurther) 5,
                    ])
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
                if (labels.isNotEmpty || f.label != null) ...<Widget>[
                  ZenSection(t('Twoje nazwy grup znajomych')),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      ChoiceChip(
                        key: const Key('graph-label-any'),
                        label: Text(t('dowolny')),
                        selected: f.label == null,
                        onSelected: (_) => apply(f.copyWith(label: () => null)),
                      ),
                      for (final CircleLabel l in labels)
                        ChoiceChip(
                          key: Key('graph-label-${l.id}'),
                          avatar: const Icon(Icons.lock_outline_rounded),
                          label: Text(l.name),
                          selected: f.label == l.id,
                          onSelected: (_) =>
                              apply(f.copyWith(label: () => l.id)),
                        ),
                    ],
                  ),
                ],
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
      GraphMode.time => <Widget>[
        _LegendDot(color: zen.accent, label: t('znajomi wtedy')),
        _LegendDot(
          color: zen.success,
          label: t('spotkani osobiście do tego dnia'),
          ring: true,
        ),
      ],
      GraphMode.bridges => <Widget>[
        _LegendDot(
          color: zen.accent,
          label: t('most — jedyne połączenie grup znajomych'),
          ring: true,
        ),
        _LegendDot(color: zenTone(zen, 5), label: t('samotny krąg')),
      ],
      GraphMode.neglect => <Widget>[
        _LegendDot(
          color: zen.accentSecondary,
          label: t('dawno się nie widzieliście'),
        ),
        _LegendLine(
          color: zen.accentSecondary,
          label: t('więź do odnowienia'),
          dashed: true,
        ),
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
    required PyramidService? pyramid,
    required GraphRoute route,
    required List<String> via,
    required String Function(String address) nameOf,
  }) async {
    final bool far = !n.isFriend;
    // Further than friends of friends: those who know them are not friends.
    final bool further = n.isFar;
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
    final bool friendAsked = far && intro.friendAskTo(n.address) != null;
    final TrustMap trust = _trustOf(node, n, pyramid, meet);
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

        return SelectionArea(
          // The person's card: names, notes and texts can be copied.
          child: SingleChildScrollView(
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
                        _centerOn(n.address);
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
                        : mutual.map(nameOf).join(', '),
                  ),
                ],
                if (!far || !trust.isEmpty) TrustMapView(map: trust),
                if (far && route.path.isNotEmpty)
                  ZenInfo(
                    key: const Key('graph-best-way'),
                    icon: Icons.timeline_rounded,
                    tone: zen.accent,
                    title: t('Najlepsza droga'),
                    text:
                        '${wayText(<String>[t('Ty'), for (final String a in route.path) a == n.address ? n.name : nameOf(a)])}\n${routeCostText(route.cost, route.gates)}',
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
                            builder: (BuildContext context) =>
                                ConversationScreen(
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
                        ProfileScreen.open(
                          this.context,
                          address: friend.address,
                        ),
                      );
                    },
                    icon: const Icon(Icons.account_circle_outlined),
                    label: Text(t('Profil')),
                  ),
                  const SizedBox(height: 8),
                  // The gate to this person's own friends, free for this
                  // friend (nobody asks for it here: they ask in a chat).
                  StatefulBuilder(
                    builder: (BuildContext context, StateSetter set) {
                      final bool free = intro.gates.isFreeFor(n.address);
                      return SwitchListTile(
                        key: const Key('graph-gate-free'),
                        contentPadding: EdgeInsets.zero,
                        value: free,
                        title: Text(t('Otwórz za darmo')),
                        subtitle: Text(
                          t(
                            'Twoja brama do Twoich znajomych jest dla tej osoby '
                            'za darmo, bez względu na cenę.',
                          ),
                        ),
                        onChanged: (bool v) => unawaited(() async {
                          await intro.setGateFree(n.address, free: v);
                          set(() {});
                        }()),
                      );
                    },
                  ),
                  if (listMissing) ...<Widget>[
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      key: const Key('graph-ask-list'),
                      onPressed: listAsked
                          ? null
                          : () =>
                                then(() => _askList(intro, n.address, n.name)),
                      icon: const Icon(Icons.visibility_rounded),
                      label: Text(
                        listAsked
                            ? t('Prośba o listę wysłana')
                            : t('Poproś o listę znajomych'),
                      ),
                    ),
                  ],
                ],
                if (far) ...<Widget>[
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    key: const Key('graph-add-friend'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: friendAsked
                        ? null
                        : () => then(
                            () => _addFriend(
                              intro,
                              n,
                              further ? const <String>[] : via,
                            ),
                          ),
                    icon: const Icon(Icons.person_add_alt_rounded),
                    label: Text(
                      friendAsked
                          ? t('Zaproszenie wysłane')
                          : t('Dodaj do znajomych'),
                    ),
                  ),
                ],
                if (further) ...<Widget>[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const Key('graph-reach'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                    ),
                    onPressed: () => then(
                      () => reachPerson(
                        this.context,
                        ref,
                        target: n.address,
                        targetName: n.name,
                      ),
                    ),
                    icon: const Icon(Icons.route_rounded),
                    label: Text(t('Jak dotrzeć')),
                  ),
                ],
                if (far && !further && via.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 8),
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
          ),
        );
      },
    );
  }

  /// The trust map of [n]: meetings, gratitude cards, the pyramid and
  /// gatherings, as far as this phone knows them.
  TrustMap _trustOf(
    LedgerNode? node,
    GraphNode n,
    PyramidService? pyramid,
    MeetService meet,
  ) {
    int? since;
    for (final PyrMember m
        in pyramid?.state?.members.values ?? const <PyrMember>[]) {
      if (m.active &&
          m.addr.isNotEmpty &&
          PeerShareCodec.addressesEqual(m.addr, n.address)) {
        since = m.joinedAt;
        break;
      }
    }
    EventService? events;
    try {
      events = ref.read(eventServiceProvider);
    } on Object {
      events = null;
    }
    bool went(EventService service, MeetEvent e, String? who) {
      bool going(EventGuest? g) =>
          g != null && (g.status == GuestStatus.going || g.checkedIn);
      if (who == null) {
        return e.isMine || going(service.myGuest(e));
      }
      return (!e.isMine && PeerShareCodec.addressesEqual(e.organizer, who)) ||
          going(e.guest(who));
    }

    final EventService? service = events;
    return trustMapOf(
      address: n.address,
      node: node,
      nameOf: meet.host.nameOf,
      pyramidSince: since,
      events: service?.events ?? const <MeetEvent>[],
      went: service == null
          ? null
          : (MeetEvent e, String? who) => went(service, e, who),
      now: meet.now,
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
                  borderRadius: context.zenRadius(2),
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
            borderRadius: context.zenRadius(8),
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
    4 => t('znajomi znajomych'),
    _ => t('dalsze znajomości'),
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
