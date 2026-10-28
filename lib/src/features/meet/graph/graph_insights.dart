import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/meet/graph/graph_model.dart';
import 'package:zen/src/features/meet/graph/graph_notes.dart';
import 'package:zen/src/features/meet/graph/open_to_meet.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// What the graph can tell from what this phone already knows: how it grew,
// whom it may be worth meeting, who connects the circles, whom this person
// has not seen for a long time. Pure functions: the same input gives the
// same answer (tests read them).

const int _dayMs = 24 * 3600 * 1000;

/// [months] back from [now] (a month counted as 30 days).
int monthsBack(int now, int months) => now - months * 30 * _dayMs;

/// A moment on the timeline that has not come (never met).
const double kTimelineNever = 2;

/// How the graph grew between [from] and [to], per person in the order of
/// the layout: when they appear and when they were first met in person,
/// as a share of the span (below 0: already there at [from]; at or past 1:
/// not yet at [to], [kTimelineNever]: never).
@immutable
final class GraphTimeline {
  GraphTimeline({
    required this.from,
    required this.to,
    required this.born,
    required this.met,
  }) : order = _orderOf(born),
       steps = _stepsOf(born, met);

  final int from;
  final int to;
  final Float32List born;
  final Float32List met;

  /// The people who come during the span (index into the layout), in the
  /// order they came; a tie keeps the layout's order.
  final Int32List order;

  /// The moments something happens on the span (someone comes, someone is
  /// met), each once, in order: where the timeline stops when it steps
  /// instead of gliding.
  final Float32List steps;

  static Int32List _orderOf(Float32List born) {
    final List<int> out =
        <int>[
          for (int i = 0; i < born.length; i++)
            if (born[i] >= 0 && born[i] <= 1) i,
        ]..sort((int a, int b) {
          final int byTime = born[a].compareTo(born[b]);
          return byTime != 0 ? byTime : a.compareTo(b);
        });
    return Int32List.fromList(out);
  }

  static Float32List _stepsOf(Float32List born, Float32List met) {
    final Set<double> at = <double>{
      for (final double b in born)
        if (b >= 0 && b <= 1) b,
      for (final double m in met)
        if (m >= 0 && m <= 1) m,
    };
    return Float32List.fromList(at.toList()..sort());
  }

  /// The share of the span [at] is.
  double phaseOf(int at) =>
      to <= from ? 1 : ((at - from) / (to - from)).clamp(0.0, 1.0);

  /// The moment at [phase].
  int timeAt(double phase) => from + ((to - from) * phase).round();

  /// Whether person [i] is on the graph at [phase].
  bool knownAt(int i, double phase) =>
      i < 0 || i >= born.length || born[i] <= phase;

  /// The first moment after [phase] when something happens (1: nothing
  /// more, the end).
  double nextStep(double phase) {
    for (final double s in steps) {
      if (s > phase + 1e-6) {
        return s;
      }
    }
    return 1;
  }

  /// Friends drawn and meetings at [phase] (for the counts under it).
  ({int people, int met}) countAt(double phase, List<GraphNode> nodes) {
    int people = 0;
    int metCount = 0;
    for (int i = 0; i < nodes.length && i < born.length; i++) {
      if (!nodes[i].isFriend || born[i] > phase) {
        continue;
      }
      people++;
      if (met[i] <= phase) {
        metCount++;
      }
    }
    return (people: people, met: metCount);
  }
}

/// The earliest of the dates above zero (0 when there is none).
int _earliest(Iterable<int> times) {
  int out = 0;
  for (final int at in times) {
    if (at > 0 && (out == 0 || at < out)) {
      out = at;
    }
  }
  return out;
}

/// The timeline of [nodes] from [from] to [to] out of [notes] (friends and
/// friends of friends seen since the dates were kept, a friend's first
/// message), [firstContact] (other first contact with a friend: a group
/// both are in) and [metAt] (the day a friend was met in person, from the
/// signed attestations). A friend comes on the earliest of these; a friend
/// of a friend comes when first seen, and no earlier than the first friend
/// who connects them.
GraphTimeline graphTimeline(
  List<GraphNode> nodes,
  GraphNotes notes, {
  required int from,
  required int to,
  Map<String, int> metAt = const <String, int>{},
  Map<String, int> firstContact = const <String, int>{},
}) {
  final double span = max(1, to - from).toDouble();
  double phase(int at) => at <= 0 ? -1 : (at - from) / span;
  final Float32List born = Float32List(nodes.length);
  final Float32List met = Float32List(nodes.length);
  final Map<String, double> bornOf = <String, double>{};
  for (int i = 0; i < nodes.length; i++) {
    final GraphNode n = nodes[i];
    double b;
    if (n.isFriend) {
      b = phase(
        _earliest(<int>[
          notes.friendSince[n.address] ?? 0,
          firstContact[n.address] ?? 0,
        ]),
      );
    } else {
      b = phase(notes.farSince[n.address] ?? 0);
      double earliestVia = double.infinity;
      for (final String v in n.via) {
        earliestVia = min(earliestVia, bornOf[v] ?? -1);
      }
      if (earliestVia.isFinite) {
        b = max(b, earliestVia);
      }
    }
    bornOf[n.address] = b;
    born[i] = b;
    final int? m = metAt[n.address];
    met[i] = m == null || m <= 0 ? kTimelineNever : max(b, phase(m));
  }
  return GraphTimeline(from: from, to: to, born: born, met: met);
}

/// The earliest day each person shares a group with this person (the day
/// the group was started), out of the groups joined: a first contact that
/// can be older than the friendship. Invitations not yet accepted count
/// for nothing.
Map<String, int> groupContactDays(Iterable<GroupProfile> groups) {
  final Map<String, int> out = <String, int>{};
  for (final GroupProfile g in groups) {
    if (g.isInvitePending || g.createdAtMillis <= 0) {
      continue;
    }
    for (final String member in g.memberAddresses) {
      final String a = PeerShareCodec.normalizeAddress(member);
      final int? had = out[a];
      if (had == null || g.createdAtMillis < had) {
        out[a] = g.createdAtMillis;
      }
    }
  }
  return out;
}

/// The whole story of [nodes]: from the day before the earliest date known
/// about anyone on them to the end of the day of [now] ([graphTimeline]).
/// With no dates at all, the last 12 months.
GraphTimeline graphGrowth(
  List<GraphNode> nodes,
  GraphNotes notes, {
  required int now,
  Map<String, int> metAt = const <String, int>{},
  Map<String, int> firstContact = const <String, int>{},
}) {
  final int to = now - now % _dayMs + _dayMs;
  final int first = _earliest(<int>[
    for (final GraphNode n in nodes) ...<int>[
      if (n.isFriend) ...<int>[
        notes.friendSince[n.address] ?? 0,
        firstContact[n.address] ?? 0,
        metAt[n.address] ?? 0,
      ] else
        notes.farSince[n.address] ?? 0,
    ],
  ]);
  final int from = first == 0 || first >= to
      ? monthsBack(to, 12)
      : first - first % _dayMs - _dayMs;
  return graphTimeline(
    nodes,
    notes,
    from: from,
    to: to,
    metAt: metAt,
    firstContact: firstContact,
  );
}

// ---- "Kogo warto poznać" ----

/// A friend of a friend it may be worth meeting.
@immutable
final class MeetSuggestion {
  const MeetSuggestion({
    required this.node,
    required this.mutual,
    required this.match,
  });

  final GraphNode node;

  /// Friends who know them.
  final int mutual;

  /// Their status or "open to meet" matches this person's.
  final bool match;
}

/// Whether two "open to meet" intentions go together.
bool openMatches(OpenToMeet? mine, OpenToMeet? theirs) {
  if (mine == null || theirs == null) {
    return false;
  }
  return mine == OpenToMeet.both || theirs == OpenToMeet.both || mine == theirs;
}

/// Friends of friends with the most mutual friends and a status or
/// intention matching this person's ([myStatus], [myOpen]): matching ones
/// need one mutual friend, the rest two. [skip]: already asked.
List<MeetSuggestion> whoToMeet(
  List<GraphNode> nodes,
  GraphFacts facts, {
  IntentStatus? myStatus,
  OpenToMeet? myOpen,
  Set<String> skip = const <String>{},
  int limit = 5,
}) {
  final List<MeetSuggestion> out = <MeetSuggestion>[];
  for (final GraphNode n in nodes) {
    if (n.ring != 4 || skip.contains(n.address)) {
      continue;
    }
    final int mutual = n.via.length;
    final IntentStatus? theirs = facts.statusOf(n.address);
    final bool statusMatch =
        myStatus != null &&
        theirs != null &&
        myStatus.kind != IntentKind.dnd &&
        theirs.kind == myStatus.kind;
    final bool match =
        statusMatch || openMatches(myOpen, facts.openOf(n.address));
    if (mutual >= 2 || (match && mutual >= 1)) {
      out.add(MeetSuggestion(node: n, mutual: mutual, match: match));
    }
  }
  int score(MeetSuggestion s) => s.mutual * 2 + (s.match ? 3 : 0);
  out.sort((MeetSuggestion a, MeetSuggestion b) {
    final int byScore = score(b).compareTo(score(a));
    return byScore != 0 ? byScore : a.node.name.compareTo(b.node.name);
  });
  return out.take(limit).toList();
}

// ---- "Mosty i samotne wyspy" ----

/// Who connects this person's circles, and which circles stand alone.
@immutable
final class BridgeReport {
  const BridgeReport({
    this.bridges = const <String>{},
    this.islands = const <int>{},
    this.hints = const <(String, String)>[],
  });

  /// Friends who alone connect two circles.
  final Set<String> bridges;

  /// Circles (cluster numbers) with no connection to another circle.
  final Set<int> islands;

  /// Two friends it may be worth introducing: one from a lone circle and
  /// one from the biggest other circle.
  final List<(String, String)> hints;

  bool get isEmpty => bridges.isEmpty && islands.isEmpty;
}

/// Bridges and islands among friends: [clusters] ([graphClusters]) and the
/// [links] between friends who know each other ([friendLinks]). A friend is
/// a bridge when every link between their circle and another one runs
/// through them; a circle of two or more friends without any such link is
/// an island. [mutual] picks who stands for a circle in a hint.
BridgeReport bridgesOf(
  List<GraphNode> nodes,
  Map<String, int> clusters,
  List<(String, String)> links, {
  Map<String, int> mutual = const <String, int>{},
}) {
  final Map<int, List<GraphNode>> friendsIn = <int, List<GraphNode>>{};
  for (final GraphNode n in nodes) {
    final int c = clusters[n.address] ?? -1;
    if (n.isFriend && c >= 0) {
      friendsIn.putIfAbsent(c, () => <GraphNode>[]).add(n);
    }
  }
  // Links across circles, by the pair of circles.
  final Map<(int, int), List<(String, String)>> across =
      <(int, int), List<(String, String)>>{};
  for (final (String a, String b) in links) {
    final int ca = clusters[a] ?? -1;
    final int cb = clusters[b] ?? -1;
    if (ca < 0 || cb < 0 || ca == cb) {
      continue;
    }
    across
        .putIfAbsent((min(ca, cb), max(ca, cb)), () => <(String, String)>[])
        .add((a, b));
  }
  final Set<String> bridges = <String>{};
  final Set<int> connected = <int>{};
  for (final MapEntry<(int, int), List<(String, String)>> e in across.entries) {
    connected
      ..add(e.key.$1)
      ..add(e.key.$2);
    Set<String>? common;
    for (final (String a, String b) in e.value) {
      final Set<String> ends = <String>{a, b};
      common = common == null ? ends : common.intersection(ends);
    }
    bridges.addAll(common ?? const <String>{});
  }
  final List<int> circles = friendsIn.keys.toList()..sort();
  final Set<int> islands = <int>{
    for (final int c in circles)
      if (friendsIn[c]!.length >= 2 && !connected.contains(c)) c,
  };
  GraphNode lead(int c) {
    final List<GraphNode> people = List<GraphNode>.of(friendsIn[c]!)
      ..sort((GraphNode a, GraphNode b) {
        final int byMutual = (mutual[b.address] ?? 0).compareTo(
          mutual[a.address] ?? 0,
        );
        return byMutual != 0 ? byMutual : a.name.compareTo(b.name);
      });
    return people.first;
  }

  final List<(String, String)> hints = <(String, String)>[];
  final List<int> bySize = List<int>.of(circles)
    ..sort((int a, int b) {
      final int bySize = friendsIn[b]!.length.compareTo(friendsIn[a]!.length);
      return bySize != 0 ? bySize : a.compareTo(b);
    });
  for (final int island in islands.toList()..sort()) {
    if (hints.length >= 3) {
      break;
    }
    final int? other = bySize.where((int c) => c != island).firstOrNull;
    if (other == null) {
      continue;
    }
    hints.add((lead(island).address, lead(other).address));
  }
  return BridgeReport(bridges: bridges, islands: islands, hints: hints);
}

// ---- "Zaniedbane więzi" ----

/// A friend not talked to or met for a long time.
@immutable
final class NeglectedFriend {
  const NeglectedFriend({required this.node, required this.last});

  final GraphNode node;

  /// The last conversation or meeting (0: none known).
  final int last;
}

/// Friends whose last conversation ([GraphNotes.lastTalk]) and last
/// meeting ([metAt]) are older than [GraphNotes.neglectWeeks] weeks,
/// closest friends first and the longest ago first. Only friends this
/// phone knows something about (their conversation was read, or a date
/// was noted), not newer than those weeks themselves and not snoozed.
List<NeglectedFriend> neglectedFriends(
  List<GraphNode> nodes,
  GraphNotes notes, {
  required int now,
  Map<String, int> metAt = const <String, int>{},
}) {
  final int limit = now - notes.neglectWeeks * 7 * _dayMs;
  final List<NeglectedFriend> out = <NeglectedFriend>[];
  for (final GraphNode n in nodes) {
    if (!n.isFriend) {
      continue;
    }
    final String a = n.address;
    if ((notes.snoozed[a] ?? 0) > now) {
      continue;
    }
    final int since = notes.friendSince[a] ?? 0;
    final bool knownBefore = since == 0 && notes.baseline > 0;
    if (!knownBefore && (since == 0 || since > limit)) {
      continue;
    }
    if (knownBefore && notes.baseline > limit && !notes.scanned.contains(a)) {
      // Nothing known yet about a friend from before the dates were kept.
      continue;
    }
    final int last = max(notes.lastTalk[a] ?? 0, metAt[a] ?? 0);
    if (last > limit) {
      continue;
    }
    if (last == 0 && !notes.scanned.contains(a)) {
      continue;
    }
    out.add(NeglectedFriend(node: n, last: last));
  }
  out.sort((NeglectedFriend x, NeglectedFriend y) {
    final int byRing = x.node.ring.compareTo(y.node.ring);
    return byRing != 0 ? byRing : x.last.compareTo(y.last);
  });
  return out;
}

// ---- words ----

/// Up to two initials of [name] ("Anna Kowalska" → "AK"), "?" for none.
String initialsOf(String name) {
  final List<String> words = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((String w) => w.isNotEmpty)
      .toList();
  final StringBuffer out = StringBuffer();
  for (final String w in words.take(2)) {
    final String ch = w.characters.first;
    out.write(ch.toUpperCase());
  }
  return out.isEmpty ? '?' : out.toString();
}

/// A way in words: "Ty → Ania → Bartek"; a long one keeps the first two
/// and the last two names with how many are between ("Ty → Ania → … 4 …
/// → Zenon").
String wayText(List<String> names, {int keepEnds = 2}) {
  if (names.length <= keepEnds * 2 + 1) {
    return names.join(' → ');
  }
  final int hidden = names.length - keepEnds * 2;
  return <String>[
    ...names.take(keepEnds),
    t('… {n} …', {'n': hidden}),
    ...names.skip(names.length - keepEnds),
  ].join(' → ');
}
