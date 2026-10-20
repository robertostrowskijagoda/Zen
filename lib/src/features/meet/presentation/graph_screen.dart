import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_glyphs.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
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
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// What the graph shows. Filters without data in the app stay hidden.
enum _GraphFilter {
  all(Icons.hub_rounded),
  friends(Icons.people_alt_rounded),
  far(Icons.person_search_rounded),
  pyramid(kPyramidIcon),
  status(Icons.bolt_rounded),
  nearby(Icons.bluetooth_searching_rounded);

  const _GraphFilter(this.icon);

  final IconData icon;

  String get label => switch (this) {
    _GraphFilter.all => t('Wszyscy'),
    _GraphFilter.friends => t('Znajomi'),
    _GraphFilter.far => t('Znajomi znajomych'),
    _GraphFilter.pyramid => t('Z mojej piramidy'),
    _GraphFilter.status => t('Ze statusem'),
    _GraphFilter.nearby => t('W pobliżu'),
  };
}

/// Friends of friends looked through when searching (drawn: far fewer).
const int _searchLimit = 5000;

/// A person drawn on the graph.
final class GraphNode {
  GraphNode({
    required this.address,
    required this.name,
    required this.ring,
    this.friend,
    this.via = const <String>[],
  });

  final String address;
  final String name;

  /// 1 = przyjaciele, 2 = znajomi, 3 = słabi znajomi, 4 = znajomi znajomych.
  final int ring;
  final FriendProfile? friend;

  /// Friends who connect to them (for friends of friends).
  final List<String> via;
  Offset at = Offset.zero;
}

/// Builds the rings: friends by level, then friends of friends from the
/// lists friends shared (§16.1). No index anywhere, just what reached
/// this phone. Addresses in [keep] are drawn even past the limit (the
/// person picked in search).
List<GraphNode> buildGraph({
  required SocialHubState social,
  required MeetBook book,
  required FriendLevel Function(String address) levelOf,
  int maxFriendsOfFriends = 80,
  Set<String> keep = const <String>{},
}) {
  final List<GraphNode> nodes = <GraphNode>[];
  final Set<String> mine = <String>{};
  for (final FriendProfile f in social.acceptedFriends) {
    final String a = PeerShareCodec.normalizeAddress(f.address);
    mine.add(a);
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
  for (final String friend in mine) {
    book.friendsOf(friend).forEach((String a, String name) {
      if (mine.contains(a)) {
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
  return nodes..addAll(fof.values);
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
    if (n.ring < 4) {
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

/// The shortest way from this person to [target] over what is known: this
/// person's [friends] (closest first; a closer friend wins a tie) and the
/// lists they shared. Breadth first. The addresses after "Ty", ending with
/// [target]; empty when it cannot be reached.
List<String> graphPath({
  required List<String> friends,
  required MeetBook book,
  required String target,
}) {
  final String goal = PeerShareCodec.normalizeAddress(target);
  final Map<String, String?> parent = <String, String?>{};
  final List<String> queue = <String>[];
  for (final String f in friends) {
    final String a = PeerShareCodec.normalizeAddress(f);
    if (!parent.containsKey(a)) {
      parent[a] = null;
      queue.add(a);
    }
  }
  for (int head = 0; head < queue.length; head++) {
    final String at = queue[head];
    if (at == goal) {
      break;
    }
    // Only friends' lists are known here, so the way is at most two steps.
    for (final String next in book.friendsOf(at).keys) {
      if (!parent.containsKey(next)) {
        parent[next] = at;
        queue.add(next);
      }
    }
  }
  if (!parent.containsKey(goal)) {
    return const <String>[];
  }
  final List<String> path = <String>[];
  String? at = goal;
  while (at != null) {
    path.insert(0, at);
    at = parent[at];
  }
  return path;
}

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
String _fold(String s) {
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
  final String q = _fold(query.trim());
  if (q.isEmpty) {
    return const <GraphNode>[];
  }
  final List<GraphNode> hits =
      nodes.where((GraphNode n) => _fold(n.name).contains(q)).toList()
        ..sort((GraphNode a, GraphNode b) {
          final int byRing = a.ring.compareTo(b.ring);
          return byRing != 0 ? byRing : a.name.compareTo(b.name);
        });
  return hits.take(limit).toList();
}

String _ringLabel(int ring) => switch (ring) {
  1 => t('Przyjaciel(-ółka)'),
  2 => t('Znajomy(-a)'),
  3 => t('Słaby(-a) znajomy(-a)'),
  _ => t('Znajomy(-a) znajomych'),
};

/// "Graf" (§16.1): you in the middle, friends around by closeness, friends
/// of friends further out; colours show who is up for what now. Search,
/// filters, the way to a person, and asking for an introduction (§24.1).
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

class _GraphScreenState extends ConsumerState<GraphScreen> {
  _GraphFilter _filter = _GraphFilter.all;
  final TextEditingController _search = TextEditingController();

  /// The person picked (tap or search): the way to them is drawn.
  String? _selected;

  /// Pinch-zoom and pan of the picture.
  final TransformationController _view = TransformationController();

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

  /// Zooms by [factor] around the middle of the picture (1…8 times).
  void _zoom(double factor, Size size) {
    final double now = _scale;
    final double target = (now * factor).clamp(1.0, 8.0);
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

  @override
  void dispose() {
    _view
      ..removeListener(_onView)
      ..dispose();
    _search.dispose();
    super.dispose();
  }

  /// A signed "met in person" attestation of this account (§6.2).
  bool _met(String address) =>
      ref.read(ledgerNodeProvider)?.hasMet(address) ?? false;

  Color _colorFor(MeetService meet, GraphNode n, ZenColors zen) {
    final IntentStatus? s = meet.book.intentOf(n.address, meet.now);
    return switch (s?.kind) {
      null => n.ring == 4 ? zen.textMuted : zen.accent,
      final IntentKind k => _intentTone(zen, k),
    };
  }

  void _layout(
    List<GraphNode> nodes,
    Size size, [
    Map<String, int> cluster = const <String, int>{},
  ]) {
    final Offset c = size.center(Offset.zero);
    final double r = min(size.width, size.height) / 2 - 28;
    // Only the rings that have people are drawn, spread from well outside
    // the centre (the "Ty" dot and its label) to the edge: with everyone on
    // one ring nobody sits on top of the centre.
    final List<int> used = <int>{
      for (final GraphNode n in nodes) n.ring,
    }.toList()..sort();
    // Communities get a sector each (the same on every ring), so people
    // who know each other sit next to each other.
    final List<int> groups = <int>{
      for (final GraphNode n in nodes) cluster[n.address] ?? -1,
    }.toList()..sort((int a, int b) => a == -1 ? 1 : (b == -1 ? -1 : a - b));
    final Map<int, (double, double)> sector = <int, (double, double)>{};
    if (groups.length > 1) {
      double start = -pi / 2;
      for (final int g in groups) {
        final int w = nodes
            .where((GraphNode n) => (cluster[n.address] ?? -1) == g)
            .length;
        final double span = 2 * pi * w / nodes.length;
        sector[g] = (start, span);
        start += span;
      }
    }
    for (int k = 0; k < used.length; k++) {
      final int ring = used[k];
      final List<GraphNode> on = nodes
          .where((GraphNode n) => n.ring == ring)
          .toList();
      final double radius = used.length == 1
          ? r * 0.62
          : r * (0.4 + 0.6 * k / (used.length - 1));
      if (sector.isEmpty) {
        for (int i = 0; i < on.length; i++) {
          final double angle = 2 * pi * i / max(on.length, 1) + ring * 0.4;
          on[i].at = c + Offset(cos(angle), sin(angle)) * radius;
        }
        continue;
      }
      for (final int g in groups) {
        final List<GraphNode> part =
            on.where((GraphNode n) => (cluster[n.address] ?? -1) == g).toList()
              ..sort((GraphNode a, GraphNode b) => a.name.compareTo(b.name));
        final (double, double) sec = sector[g]!;
        for (int i = 0; i < part.length; i++) {
          final double angle = sec.$1 + sec.$2 * (i + 0.5) / part.length;
          part[i].at = c + Offset(cos(angle), sin(angle)) * radius;
        }
      }
    }
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

  Future<void> _show(
    BuildContext context,
    MeetService meet,
    IntroService intro,
    GraphNode n, {
    required List<String> path,
    required List<String> via,
  }) async {
    final List<String> mutual = n.ring == 4
        ? via
        : meet.mutualFriends(n.address);
    final IntentStatus? s = meet.book.intentOf(n.address, meet.now);
    final bool far = n.ring == 4;
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
        final Color tone = _colorFor(meet, n, zen);
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
                          _ringLabel(n.ring),
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (s != null || _met(n.address)) ...<Widget>[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: <Widget>[
                    if (s != null)
                      ZenPill(
                        text: '${s.shownEmoji} ${s.shownLabel}',
                        tone: _intentTone(zen, s.kind),
                      ),
                    if (_met(n.address))
                      ZenPill(
                        text: t('spotkani osobiście'),
                        tone: zen.success,
                        icon: Icons.verified_rounded,
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
              if (far && path.isNotEmpty)
                ZenInfo(
                  icon: Icons.timeline_rounded,
                  tone: zen.accent,
                  title: t('Najkrótsza droga'),
                  text: <String>[
                    t('Ty'),
                    for (final String a in path)
                      a == n.address ? n.name : meet.host.nameOf(a),
                  ].join(' → '),
                ),
              if (n.friend != null) ...<Widget>[
                const SizedBox(height: 16),
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
                        address: n.friend!.address,
                      ),
                    );
                  },
                  icon: const Icon(Icons.account_circle_outlined),
                  label: Text(t('Zobacz profil')),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    unawaited(
                      Navigator.of(this.context).push(
                        MaterialPageRoute<void>(
                          builder: (BuildContext context) => ConversationScreen(
                            peerAddress: n.friend!.address,
                            title: n.name,
                          ),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.chat_bubble_outline_rounded),
                  label: Text(t('Napisz')),
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

  @override
  Widget build(BuildContext context) {
    final MeetService meet = ref.watch(meetServiceProvider);
    final NearbyService nearby = ref.watch(nearbyServiceProvider);
    final IntroService intro = ref.watch(introServiceProvider);
    final PyramidService pyramid = ref.watch(pyramidServiceProvider);
    final SocialHubState social = watchSocialPeople(ref);
    final LedgerNode? node = ref.watch(ledgerNodeProvider);
    return Scaffold(
      key: const Key('graph-screen'),
      appBar: ZenSectionBar(title: t('Graf znajomych')),
      body: ListenableBuilder(
        listenable: Listenable.merge(<Listenable>[meet, nearby]),
        builder: (BuildContext context, Widget? _) => _content(
          context,
          meet: meet,
          nearby: nearby,
          intro: intro,
          pyramid: pyramid,
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
    required PyramidService pyramid,
    required SocialHubState social,
    required LedgerNode? node,
  }) {
    final ZenColors zen = ZenColors.of(context);
    final int nowMs = meet.now;
    FriendLevel levelOf(String a) => node?.levelOf(a) ?? FriendLevel.friend;
    final Set<String> near = <String>{
      for (final NearbyPerson p in nearby.people)
        if (p.friend != null) PeerShareCodec.normalizeAddress(p.friend!),
    };
    final Set<String> inPyramid = pyramidFriendAddresses(pyramid);
    final String? selected = _selected;
    final List<GraphNode> all = buildGraph(
      social: social,
      book: meet.book,
      levelOf: levelOf,
      keep: <String>{?selected},
    );
    // Friends, closest first: the way through them wins a tie.
    final List<GraphNode> friendNodes =
        all.where((GraphNode n) => n.ring < 4).toList()
          ..sort((GraphNode a, GraphNode b) => a.ring.compareTo(b.ring));
    final List<String> friendOrder = <String>[
      for (final GraphNode n in friendNodes) n.address,
    ];
    final Map<String, int> ringOf = <String, int>{
      for (final GraphNode n in friendNodes) n.address: n.ring,
    };
    final List<String> path = selected == null
        ? const <String>[]
        : graphPath(friends: friendOrder, book: meet.book, target: selected);
    bool hasStatus(GraphNode n) => meet.book.intentOf(n.address, nowMs) != null;
    bool shows(_GraphFilter f, GraphNode n) => switch (f) {
      _GraphFilter.all => true,
      _GraphFilter.friends => n.ring < 4,
      _GraphFilter.far => n.ring == 4,
      _GraphFilter.pyramid => inPyramid.contains(n.address),
      _GraphFilter.status => hasStatus(n),
      _GraphFilter.nearby => near.contains(n.address),
    };
    final List<_GraphFilter> filters = <_GraphFilter>[
      for (final _GraphFilter f in _GraphFilter.values)
        if (f == _filter ||
            f == _GraphFilter.all ||
            all.any((GraphNode n) => shows(f, n)))
          f,
    ];
    final Set<String> onPath = path.toSet();
    final List<GraphNode> nodes = all
        .where((GraphNode n) => shows(_filter, n) || onPath.contains(n.address))
        .toList();
    final Set<String> drawn = <String>{
      for (final GraphNode n in nodes) n.address,
    };
    final Map<String, int> clusters = graphClusters(nodes, meet.book);
    final List<(String, String)> links = <(String, String)>[
      for (final (String, String) l in friendLinks(friendOrder, meet.book))
        if (drawn.contains(l.$1) && drawn.contains(l.$2)) l,
    ];
    final String query = _search.text;
    final List<GraphNode> hits = query.trim().isEmpty
        ? const <GraphNode>[]
        : searchGraph(
            buildGraph(
              social: social,
              book: meet.book,
              levelOf: levelOf,
              maxFriendsOfFriends: _searchLimit,
            ),
            query,
          );
    final Set<String> marked = <String>{
      for (final GraphNode h in hits) h.address,
    };

    void open(GraphNode n) {
      FocusScope.of(context).unfocus();
      setState(() => _selected = n.address);
      final List<String> via = <String>[...n.via]
        ..sort(
          (String a, String b) => (ringOf[a] ?? 9).compareTo(ringOf[b] ?? 9),
        );
      unawaited(
        _show(
          context,
          meet,
          intro,
          n,
          path: graphPath(
            friends: friendOrder,
            book: meet.book,
            target: n.address,
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
          min(outer.maxHeight - 230, outer.maxWidth * 1.15),
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
                                h.ring == 4
                                    ? Icons.person_search_rounded
                                    : Icons.people_alt_rounded,
                                color: _colorFor(meet, h, zen),
                              ),
                              title: Text(h.name),
                              subtitle: Text(
                                h.ring == 4
                                    ? t('Przez: {names}', {
                                        'names': h.via
                                            .map(meet.host.nameOf)
                                            .join(', '),
                                      })
                                    : _ringLabel(h.ring),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () => open(h),
                            ),
                        ],
                      ),
              ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                spacing: 8,
                children: <Widget>[
                  for (final _GraphFilter f in filters)
                    ChoiceChip(
                      key: Key('graph-filter-${f.name}'),
                      showCheckmark: false,
                      avatar: ZenIcon(f.icon, size: 18),
                      label: Text(f.label),
                      selected: _filter == f,
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                ],
              ),
            ),
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
                          _layout(nodes, size, clusters);
                          final Widget picture = ListenableBuilder(
                            listenable: _view,
                            builder: (BuildContext context, Widget? _) {
                              final double scale = _scale;
                              return GestureDetector(
                                key: const Key('graph-canvas'),
                                onTapUp: (TapUpDetails d) {
                                  GraphNode? hit;
                                  // The tap area stays the size of a finger
                                  // when the picture is zoomed in.
                                  double best = max(12, 28 / scale);
                                  for (final GraphNode n in nodes) {
                                    final double dist =
                                        (n.at - d.localPosition).distance;
                                    if (dist < best) {
                                      best = dist;
                                      hit = n;
                                    }
                                  }
                                  if (hit != null) {
                                    open(hit);
                                  } else if (_selected != null) {
                                    setState(() => _selected = null);
                                  }
                                },
                                child: CustomPaint(
                                  size: size,
                                  // Screen readers: every person is a button.
                                  foregroundPainter: _GraphSemantics(
                                    nodes: nodes,
                                    onOpen: open,
                                  ),
                                  painter: _GraphPainter(
                                    nodes: nodes,
                                    colorOf: (GraphNode n) =>
                                        _colorFor(meet, n, zen),
                                    met: (GraphNode n) => _met(n.address),
                                    line: zen.outline,
                                    guide: zen.outlineSoft,
                                    me: zen.accent,
                                    meText: zen.onAccent,
                                    text: zen.textPrimary,
                                    labelBg: zen.surfaceRaised,
                                    links: links,
                                    path: path,
                                    marked: marked,
                                    selected: selected,
                                    cluster: clusters,
                                    clusterColors: <Color>[
                                      for (int i = 0; i < 6; i++)
                                        zenTone(zen, i),
                                    ],
                                    scale: scale,
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
                                  maxScale: 8,
                                  child: SizedBox.fromSize(
                                    size: size,
                                    child: picture,
                                  ),
                                ),
                              ),
                              Positioned(
                                right: 8,
                                bottom: 8,
                                child: ListenableBuilder(
                                  listenable: _view,
                                  builder: (BuildContext context, Widget? _) =>
                                      Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: <Widget>[
                                          IconButton.filledTonal(
                                            key: const Key('graph-zoom-in'),
                                            tooltip: t('Przybliż'),
                                            onPressed: _scale >= 8
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
                                            icon: const Icon(
                                              Icons.remove_rounded,
                                            ),
                                          ),
                                        ],
                                      ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ),
            if (_filter != _GraphFilter.all && all.isNotEmpty)
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
            if (selected != null)
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
                        text: path.isEmpty
                            ? t('Tej osoby nie ma już na listach znajomych.')
                            : <String>[
                                t('Ty'),
                                for (final String a in path)
                                  _nameOn(a, all, hits, meet),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Wrap(
                spacing: 12,
                runSpacing: 6,
                alignment: WrapAlignment.center,
                children: <Widget>[
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.urgent),
                    label: t('pilne'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.talk),
                    label: t('pogadać'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.out),
                    label: t('wyjść'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.help),
                    label: t('pomoc'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.canHelp),
                    label: t('może pomóc'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.dnd),
                    label: t('nie przeszkadzać'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.dating),
                    label: t('randkuje'),
                  ),
                  _LegendDot(
                    color: _intentTone(zen, IntentKind.custom),
                    label: t('własny status'),
                  ),
                  _LegendDot(color: zen.accent, label: t('znajomi')),
                  _LegendDot(
                    color: zen.textMuted,
                    label: t('znajomi znajomych'),
                    small: true,
                  ),
                  _LegendDot(
                    color: zen.textSecondary,
                    label: t('spotkani'),
                    ring: true,
                  ),
                ],
              ),
            ),
            if (all.isNotEmpty && all.every((GraphNode n) => n.ring != 4))
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
            else if (all.any((GraphNode n) => n.ring == 4))
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

  /// The name of [address] on the way: a friend, or someone from the
  /// lists (also one found by search but not drawn).
  String _nameOn(
    String address,
    List<GraphNode> all,
    List<GraphNode> hits,
    MeetService meet,
  ) {
    for (final GraphNode n in <GraphNode>[...all, ...hits]) {
      if (n.address == address) {
        return n.name;
      }
    }
    return meet.host.nameOf(address);
  }
}

/// "Listy znajomych: od X z Y znajomych" (§16.1): who has not sent theirs,
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

/// The colour of a status on the graph (same as on the status panel).
Color _intentTone(ZenColors zen, IntentKind k) => intentTone(zen, k);

/// One entry of the legend under the graph.
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
        Text(label, style: TextStyle(color: zen.textSecondary, fontSize: 12)),
      ],
    );
  }
}

class _GraphPainter extends CustomPainter {
  _GraphPainter({
    required this.nodes,
    required this.colorOf,
    required this.met,
    required this.line,
    required this.guide,
    required this.me,
    required this.meText,
    required this.text,
    required this.labelBg,
    this.links = const <(String, String)>[],
    this.path = const <String>[],
    this.marked = const <String>{},
    this.selected,
    this.cluster = const <String, int>{},
    this.clusterColors = const <Color>[],
    this.scale = 1,
  });

  final List<GraphNode> nodes;

  /// Community of each person (-1: none) and the colours to tell them by.
  final Map<String, int> cluster;
  final List<Color> clusterColors;

  /// How far the picture is zoomed in: close up, friends of friends get
  /// their names too.
  final double scale;
  final Color Function(GraphNode) colorOf;
  final bool Function(GraphNode) met;
  final Color line;
  final Color guide;
  final Color me;
  final Color meText;
  final Color text;
  final Color labelBg;

  /// Friends who know each other.
  final List<(String, String)> links;

  /// The way from "Ty" to the person picked.
  final List<String> path;

  /// Found by search.
  final Set<String> marked;
  final String? selected;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = size.center(Offset.zero);
    final double r = min(size.width, size.height) / 2 - 28;
    // Faint rings: friends, acquaintances, weak ties, friends of friends.
    final Paint ringPaint = Paint()
      ..color = guide
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    // Drawn where the people actually are (see the layout).
    final Set<int> radii = <int>{
      for (final GraphNode n in nodes) (n.at - c).distance.round(),
    };
    for (final int radius
        in radii.isEmpty ? <int>[(r * 0.62).round()] : radii) {
      canvas.drawCircle(c, radius.toDouble(), ringPaint);
    }
    final Map<String, GraphNode> byAddress = <String, GraphNode>{
      for (final GraphNode n in nodes) n.address: n,
    };
    _halos(canvas);
    final Paint edge = Paint()
      ..color = line
      ..strokeCap = StrokeCap.round;
    for (final GraphNode n in nodes) {
      if (n.ring < 4) {
        canvas.drawLine(c, n.at, edge..strokeWidth = (4 - n.ring) * 0.8);
      } else {
        for (final String v in n.via) {
          final GraphNode? f = byAddress[v];
          if (f != null) {
            canvas.drawLine(f.at, n.at, edge..strokeWidth = 0.6);
          }
        }
      }
    }
    // Friends who know each other: bent away from the middle, so the line
    // does not run over "Ty".
    final Paint link = Paint()
      ..color = line.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    for (final (String a, String b) in links) {
      final GraphNode? x = byAddress[a];
      final GraphNode? y = byAddress[b];
      if (x == null || y == null) {
        continue;
      }
      final Offset mid = (x.at + y.at) / 2;
      final Offset away = mid - c;
      final Offset control = away.distance < 1
          ? mid + Offset(0, -r * 0.3)
          : mid + away * 0.35;
      canvas.drawPath(
        Path()
          ..moveTo(x.at.dx, x.at.dy)
          ..quadraticBezierTo(control.dx, control.dy, y.at.dx, y.at.dy),
        link,
      );
    }
    final Set<String> onPath = path.toSet();
    if (path.isNotEmpty) {
      final Paint way = Paint()
        ..color = me
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      Offset from = c;
      for (final String a in path) {
        final GraphNode? n = byAddress[a];
        if (n == null) {
          break;
        }
        canvas.drawLine(from, n.at, way);
        from = n.at;
      }
    }
    canvas.drawCircle(c, 26, Paint()..color = me.withValues(alpha: 0.16));
    canvas.drawCircle(c, 17, Paint()..color = me);
    _label(canvas, t('Ty'), c, color: meText, center: true, bold: true);
    for (final GraphNode n in nodes) {
      final Color col = colorOf(n);
      final double nr = n.ring == 4 ? 4.5 : 9;
      final bool lit =
          n.address == selected ||
          marked.contains(n.address) ||
          onPath.contains(n.address);
      if (n.ring < 4) {
        canvas.drawCircle(
          n.at,
          nr + 5,
          Paint()..color = col.withValues(alpha: 0.18),
        );
      }
      canvas.drawCircle(n.at, nr, Paint()..color = col);
      if (met(n)) {
        canvas.drawCircle(
          n.at,
          nr + 3.5,
          Paint()
            ..color = col
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      }
      if (lit) {
        canvas.drawCircle(
          n.at,
          nr + 7,
          Paint()
            ..color = me
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      }
      if (n.ring < 4 || lit || scale >= 2) {
        _label(
          canvas,
          n.name,
          n.at + Offset(0, nr + (lit ? 9 : 6)),
          color: text,
          pill: true,
        );
      }
    }
  }

  /// A soft blob behind each community (when there are at least two).
  void _halos(Canvas canvas) {
    final Map<int, List<GraphNode>> groups = <int, List<GraphNode>>{};
    for (final GraphNode n in nodes) {
      final int g = cluster[n.address] ?? -1;
      if (g >= 0) {
        groups.putIfAbsent(g, () => <GraphNode>[]).add(n);
      }
    }
    if (groups.length < 2 || clusterColors.isEmpty) {
      return;
    }
    for (final MapEntry<int, List<GraphNode>> e in groups.entries) {
      Offset sum = Offset.zero;
      for (final GraphNode n in e.value) {
        sum += n.at;
      }
      final Offset mid = sum / e.value.length.toDouble();
      double radius = 0;
      for (final GraphNode n in e.value) {
        radius = max(radius, (n.at - mid).distance);
      }
      final Color col = clusterColors[e.key % clusterColors.length];
      canvas
        ..drawCircle(
          mid,
          radius + 20,
          Paint()..color = col.withValues(alpha: 0.08),
        )
        ..drawCircle(
          mid,
          radius + 20,
          Paint()
            ..color = col.withValues(alpha: 0.28)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
    }
  }

  void _label(
    Canvas canvas,
    String s,
    Offset at, {
    required Color color,
    bool center = false,
    bool bold = false,
    bool pill = false,
  }) {
    final TextPainter tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontFamily: ZenText.sansFamily,
          fontWeight: bold || pill ? FontWeight.w700 : FontWeight.w400,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 84);
    final Offset topLeft = center
        ? at - Offset(tp.width / 2, tp.height / 2)
        : at - Offset(tp.width / 2, 0);
    if (pill) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            topLeft.dx - 5,
            topLeft.dy - 1.5,
            tp.width + 10,
            tp.height + 3,
          ),
          const Radius.circular(8),
        ),
        Paint()..color = labelBg.withValues(alpha: 0.88),
      );
    }
    tp.paint(canvas, topLeft);
  }

  /// What the picture shows: repainted only when that changes (B5).
  late final String _signature = <Object>[
    line.toARGB32(),
    guide.toARGB32(),
    me.toARGB32(),
    text.toARGB32(),
    labelBg.toARGB32(),
    for (final GraphNode n in nodes)
      '${n.address}|${n.name}|${n.ring}|${n.at.dx.round()}|'
          '${n.at.dy.round()}|${colorOf(n).toARGB32()}|${met(n)}|'
          '${n.via.join(',')}',
    'links:${links.map(((String, String) l) => '${l.$1}-${l.$2}').join(',')}',
    'path:${path.join('>')}',
    'marked:${(marked.toList()..sort()).join(',')}',
    'selected:${selected ?? ''}',
    'cluster:${(cluster.entries.map((MapEntry<String, int> e) => '${e.key}=${e.value}').toList()..sort()).join(',')}',
    'zoom:${scale >= 2}',
  ].join(';');

  @override
  bool shouldRepaint(_GraphPainter old) => old._signature != _signature;
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
  bool shouldRebuildSemantics(_GraphSemantics oldDelegate) => true;

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
