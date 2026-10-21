import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// What the graph keeps for this person only, on this phone: since when
// each friend (and each friend of a friend) is known, the last
// conversation with each friend, private names of circles and the gentle
// reminders. Nothing of it ever leaves the phone.

/// Longest private name of a circle.
const int kCircleLabelMaxChars = 40;

/// Private circle names kept at most.
const int kCircleLabelsMax = 60;

/// Friends of friends whose first sighting is kept at most.
const int kGraphNotesMaxFar = 5000;

/// The "dawno się nie widzieliście" choices, in weeks.
const List<int> kNeglectWeekChoices = <int>[4, 8, 12, 26];

String _n(String a) => PeerShareCodec.normalizeAddress(a);

/// A circle named by this person: the name and the people it had when
/// named (the circle found on the graph that shares most of them gets it).
@immutable
final class CircleLabel {
  const CircleLabel({
    required this.id,
    required this.name,
    required this.members,
  });

  final String id;
  final String name;
  final Set<String> members;

  CircleLabel copyWith({String? name, Set<String>? members}) => CircleLabel(
    id: id,
    name: name ?? this.name,
    members: members ?? this.members,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'n': name,
    'm': members.toList()..sort(),
  };

  static CircleLabel? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? n = json['n'];
    final Object? m = json['m'];
    if (id is! String || id.isEmpty || id.length > 40 || n is! String) {
      return null;
    }
    final String name = cleanCircleLabel(n);
    if (name.isEmpty) {
      return null;
    }
    return CircleLabel(
      id: id,
      name: name,
      members: <String>{
        if (m is List)
          for (final Object? a in m.take(kGraphNotesMaxFar))
            if (a is String && a.isNotEmpty && a.length <= 64) _n(a),
      },
    );
  }
}

/// A circle name as typed: one line, trimmed, clipped.
String cleanCircleLabel(String text) {
  final String one = text
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (one.length <= kCircleLabelMaxChars) {
    return one;
  }
  return one.substring(0, kCircleLabelMaxChars).trim();
}

/// The label of the circle with [members], if one fits: the label whose
/// people overlap the most, at least half of the bigger of the two.
CircleLabel? labelFor(Set<String> members, Iterable<CircleLabel> labels) {
  CircleLabel? best;
  double bestScore = 0;
  for (final CircleLabel l in labels) {
    if (l.members.isEmpty || members.isEmpty) {
      continue;
    }
    final int common = l.members.where(members.contains).length;
    final double score = common / max(l.members.length, members.length);
    if (score >= 0.5 && score > bestScore) {
      best = l;
      bestScore = score;
    }
  }
  return best;
}

/// What the graph keeps on this phone.
final class GraphNotes {
  GraphNotes();

  /// When this phone started keeping dates (0: not yet).
  int baseline = 0;

  /// Friends: since when (0: already a friend before the dates were kept).
  final Map<String, int> friendSince = <String, int>{};

  /// Friends of friends: first seen (0: before the dates were kept).
  final Map<String, int> farSince = <String, int>{};

  /// Friends: the last message either way, as far as this phone knows.
  final Map<String, int> lastTalk = <String, int>{};

  /// Friends whose conversation was read once for its dates.
  final Set<String> scanned = <String>{};

  /// Private names of circles, by id.
  final Map<String, CircleLabel> labels = <String, CircleLabel>{};

  /// "Dawno się nie widzieliście" after this many weeks.
  int neglectWeeks = 8;

  /// Friends the reminder skips until then.
  final Map<String, int> snoozed = <String, int>{};

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'b': baseline,
    'fs': friendSince,
    'ff': farSince,
    'lt': lastTalk,
    'sc': scanned.toList()..sort(),
    'lb': <Map<String, dynamic>>[
      for (final CircleLabel l in labels.values) l.toJson(),
    ],
    'nw': neglectWeeks,
    'sn': snoozed,
  };

  static Map<String, int> _times(Object? json, int cap) {
    final Map<String, int> out = <String, int>{};
    if (json is Map) {
      for (final MapEntry<dynamic, dynamic> e in json.entries) {
        if (out.length >= cap) {
          break;
        }
        if (e.key is String && e.value is int && (e.value as int) >= 0) {
          out[_n(e.key as String)] = e.value as int;
        }
      }
    }
    return out;
  }

  static GraphNotes fromJson(Object? json) {
    final GraphNotes notes = GraphNotes();
    if (json is! Map || json['v'] != 1) {
      return notes;
    }
    final Object? b = json['b'];
    final Object? nw = json['nw'];
    final Object? sc = json['sc'];
    final Object? lb = json['lb'];
    notes
      ..baseline = b is int && b > 0 ? b : 0
      ..neglectWeeks = nw is int && kNeglectWeekChoices.contains(nw) ? nw : 8;
    notes.friendSince.addAll(_times(json['fs'], 20000));
    notes.farSince.addAll(_times(json['ff'], kGraphNotesMaxFar));
    notes.lastTalk.addAll(_times(json['lt'], 20000));
    notes.snoozed.addAll(_times(json['sn'], 20000));
    if (sc is List) {
      notes.scanned.addAll(sc.whereType<String>().map(_n));
    }
    if (lb is List) {
      for (final Object? l in lb.take(kCircleLabelsMax)) {
        final CircleLabel? label = CircleLabel.fromJson(l);
        if (label != null) {
          notes.labels[label.id] = label;
        }
      }
    }
    return notes;
  }
}

/// Keeps [GraphNotes]: dates noted as the graph changes (from now on, and
/// from the conversations already on this phone), private circle names
/// and the gentle reminders.
final class GraphNotesService extends ChangeNotifier {
  GraphNotesService({required this.disk, int Function()? now, Random? random})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
      _random = random ?? Random.secure();

  static const String storeKey = 'meet/graph-notes';

  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;

  GraphNotes _notes = GraphNotes();
  Future<void>? _loading;
  bool _unreadable = false;
  bool _disposed = false;
  bool _scanning = false;

  GraphNotes get notes => _notes;

  int get now => _now();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  /// Grows with every change (to rebuild what depends on the notes).
  int get revision => _revision;
  int _revision = 0;

  void _changed() {
    _revision++;
    if (!_disposed) {
      notifyListeners();
    }
  }

  Future<void> load() => _loading ??= _read();

  Future<void> _read() async {
    try {
      _unreadable = true;
      final Uint8List? raw = await disk.read(storeKey);
      _notes = raw == null
          ? GraphNotes()
          : GraphNotes.fromJson(jsonDecode(utf8.decode(raw)));
      _unreadable = false;
    } on Object catch (error, stack) {
      logZenError('Graf: odczyt notatek', error, stack);
    }
    _changed();
  }

  Future<void> _save() async {
    if (_unreadable) {
      _changed();
      return;
    }
    try {
      await disk.write(
        storeKey,
        Uint8List.fromList(utf8.encode(jsonEncode(_notes.toJson()))),
      );
    } on Object catch (error, stack) {
      logZenError('Graf: zapis notatek', error, stack);
    }
    _changed();
  }

  /// Notes who is on the graph now: a friend or a friend of a friend seen
  /// for the first time gets today's date. The very first time, everyone
  /// already there counts as "before the dates were kept". Friends who are
  /// gone are forgotten (with their dates and reminders).
  Future<void> observe({
    required Iterable<String> friends,
    Iterable<String> far = const <String>[],
  }) async {
    await load();
    final Set<String> mine = friends.map(_n).toSet();
    if (mine.isEmpty && _notes.friendSince.isEmpty) {
      return;
    }
    final int ms = _now();
    final bool first = _notes.baseline == 0;
    bool changed = false;
    if (first) {
      _notes.baseline = ms;
      changed = true;
    }
    for (final String f in mine) {
      if (!_notes.friendSince.containsKey(f)) {
        _notes.friendSince[f] = first ? 0 : ms;
        changed = true;
      }
    }
    if (mine.isNotEmpty) {
      final int before = _notes.friendSince.length;
      _notes.friendSince.removeWhere((String a, int _) => !mine.contains(a));
      _notes.lastTalk.removeWhere((String a, int _) => !mine.contains(a));
      _notes.snoozed.removeWhere((String a, int _) => !mine.contains(a));
      _notes.scanned.removeWhere((String a) => !mine.contains(a));
      changed = changed || before != _notes.friendSince.length;
    }
    for (final String a in far.map(_n)) {
      if (_notes.farSince.length >= kGraphNotesMaxFar) {
        break;
      }
      if (!mine.contains(a) && !_notes.farSince.containsKey(a)) {
        _notes.farSince[a] = first ? 0 : ms;
        changed = true;
      }
    }
    if (changed) {
      await _save();
    }
  }

  /// The last conversation with [friend] was at [at] (a message either
  /// way).
  Future<void> noteTalk(String friend, int at) async {
    await load();
    final String a = _n(friend);
    if (at <= (_notes.lastTalk[a] ?? 0)) {
      return;
    }
    _notes.lastTalk[a] = at;
    await _save();
  }

  /// Reads the dates out of the conversations already on this phone, one
  /// friend at a time: the first message (the friendship's start, when it
  /// was before the dates were kept) and the last one that was a real
  /// message. [messagesOf] gives a friend's messages; [all]: read again
  /// also those read before (only for [friends]).
  Future<void> scanConversations(
    Iterable<String> friends,
    Future<List<ChatMessage>> Function(String friend) messagesOf, {
    bool all = false,
  }) async {
    await load();
    if (_scanning) {
      return;
    }
    _scanning = true;
    try {
      bool changed = false;
      for (final String friend in friends.toList()) {
        if (_disposed) {
          return;
        }
        final String a = _n(friend);
        if (!all && _notes.scanned.contains(a)) {
          continue;
        }
        final List<ChatMessage> messages;
        try {
          messages = await messagesOf(friend);
        } on Object {
          continue;
        }
        int first = 0;
        int last = 0;
        for (final ChatMessage m in messages) {
          final int at = m.sentAtMillis;
          if (at <= 0) {
            continue;
          }
          if (first == 0 || at < first) {
            first = at;
          }
          if (m.direction != ChatMessageDirection.system && at > last) {
            last = at;
          }
        }
        final int? since = _notes.friendSince[a];
        if (first > 0 && since != null && (since == 0 || first < since)) {
          _notes.friendSince[a] = first;
        }
        if (last > (_notes.lastTalk[a] ?? 0)) {
          _notes.lastTalk[a] = last;
        }
        _notes.scanned.add(a);
        changed = true;
      }
      if (changed) {
        await _save();
      }
    } finally {
      _scanning = false;
    }
  }

  /// Names the circle of [members] [name] (only this person sees it);
  /// renames the label that already fits it.
  Future<CircleLabel?> setLabel(Set<String> members, String name) async {
    await load();
    final String clean = cleanCircleLabel(name);
    if (clean.isEmpty || members.isEmpty) {
      return null;
    }
    final Set<String> people = members.map(_n).toSet();
    final CircleLabel? had = labelFor(people, _notes.labels.values);
    final CircleLabel label;
    if (had != null) {
      label = had.copyWith(name: clean, members: people);
    } else {
      if (_notes.labels.length >= kCircleLabelsMax) {
        return null;
      }
      label = CircleLabel(
        id: List<String>.generate(
          12,
          (_) => _random.nextInt(36).toRadixString(36),
        ).join(),
        name: clean,
        members: people,
      );
    }
    _notes.labels[label.id] = label;
    await _save();
    return label;
  }

  /// Forgets the private name [id].
  Future<void> removeLabel(String id) async {
    await load();
    if (_notes.labels.remove(id) != null) {
      await _save();
    }
  }

  /// "Dawno" after [weeks] weeks.
  Future<void> setNeglectWeeks(int weeks) async {
    await load();
    if (!kNeglectWeekChoices.contains(weeks) || weeks == _notes.neglectWeeks) {
      return;
    }
    _notes.neglectWeeks = weeks;
    await _save();
  }

  /// The reminder skips [friend] for [time].
  Future<void> snooze(String friend, Duration time) async {
    await load();
    _notes.snoozed[_n(friend)] = _now() + time.inMilliseconds;
    await _save();
  }
}
