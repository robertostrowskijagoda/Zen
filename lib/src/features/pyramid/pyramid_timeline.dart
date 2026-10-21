import 'dart:isolate';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Above this many moves the timeline is worked out off the UI thread.
const int kPyrTimelineIsolateMoves = 20000;

/// At most about this many keyframes are kept (memory stays small however
/// long the pyramid's life).
const int kPyrTimelineKeyframes = 64;

/// One step of the pyramid's history: the moves one record (or one vote)
/// made, with what the public history says about it.
@immutable
final class PyrTimelineStep {
  const PyrTimelineStep({
    required this.at,
    required this.cause,
    required this.text,
    required this.moves,
  });

  final int at;
  final String cause;
  final String text;
  final List<PyrMove> moves;
}

/// The places of the pyramid through time, replayed from the moves of the
/// fold ([PyramidState.moves]): each step is one record that moved
/// somebody. Positions after any step come from the nearest keyframe
/// before it, so scrubbing costs at most [every] steps.
final class PyrTimeline {
  PyrTimeline._(this.steps, this.every, this._keyframes, this.names);

  final List<PyrTimelineStep> steps;

  /// Steps between keyframes.
  final int every;

  /// Keyframe j: who sits where (key → path) after `j * every` steps.
  final List<Map<String, String>> _keyframes;

  /// Pseudonyms, by key.
  final Map<String, String> names;

  static final PyrTimeline empty = PyrTimeline._(
    const <PyrTimelineStep>[],
    1,
    <Map<String, String>>[<String, String>{}],
    const <String, String>{},
  );

  int get length => steps.length;

  /// Keyframes kept (tests).
  @visibleForTesting
  int get keyframeCount => _keyframes.length;

  /// Who sits where (key → path) after the first [count] steps (0: nobody
  /// yet, [length]: now).
  Map<String, String> positionsAfter(int count) {
    final int n = count.clamp(0, steps.length);
    final int k = min(n ~/ every, _keyframes.length - 1);
    final Map<String, String> out = Map<String, String>.of(_keyframes[k]);
    for (int i = k * every; i < n; i++) {
      _apply(out, steps[i]);
    }
    return out;
  }

  static void _apply(Map<String, String> into, PyrTimelineStep step) {
    for (final PyrMove m in step.moves) {
      final String? p = m.path;
      if (p == null) {
        into.remove(m.key);
      } else {
        into[m.key] = p;
      }
    }
  }

  /// The timeline of [s]: its moves, the words of its history and its
  /// members' pseudonyms (nothing a member does not see already).
  static PyrTimeline ofState(PyramidState s, {int? every}) =>
      build(s.moves, _texts(s), _names(s), fallback: _fallback(), every: every);

  /// [ofState], off the UI thread when the history is long.
  static Future<PyrTimeline> ofStateAsync(PyramidState s) {
    final List<PyrMove> moves = List<PyrMove>.of(s.moves);
    final Map<String, String> texts = _texts(s);
    final Map<String, String> names = _names(s);
    // Translated here: the other isolate has no texts loaded.
    final String fallback = _fallback();
    if (moves.length <= kPyrTimelineIsolateMoves) {
      return Future<PyrTimeline>.value(
        build(moves, texts, names, fallback: fallback),
      );
    }
    return Isolate.run(() => build(moves, texts, names, fallback: fallback));
  }

  static String _fallback() => t('Zmiana miejsc w piramidzie');

  static Map<String, String> _texts(PyramidState s) {
    final Map<String, String> out = <String, String>{};
    for (final PyrHistory h in s.history) {
      final String? had = out[h.recordId];
      out[h.recordId] = had == null ? h.text : '$had · ${h.text}';
    }
    return out;
  }

  static Map<String, String> _names(PyramidState s) => <String, String>{
    for (final PyrMember m in s.members.values) m.key: m.name,
  };

  /// Groups [moves] into steps (one per cause, in order) and keeps a
  /// keyframe every [every] steps (by default so that there are at most
  /// about [kPyrTimelineKeyframes]).
  static PyrTimeline build(
    List<PyrMove> moves,
    Map<String, String> texts,
    Map<String, String> names, {
    String fallback = '',
    int? every,
  }) {
    final List<PyrTimelineStep> steps = <PyrTimelineStep>[];
    List<PyrMove> group = <PyrMove>[];
    void close() {
      if (group.isEmpty) {
        return;
      }
      final PyrMove first = group.first;
      steps.add(
        PyrTimelineStep(
          at: first.at,
          cause: first.cause,
          text: texts[first.cause] ?? fallback,
          moves: List<PyrMove>.unmodifiable(group),
        ),
      );
      group = <PyrMove>[];
    }

    for (final PyrMove m in moves) {
      if (group.isNotEmpty && group.first.cause != m.cause) {
        close();
      }
      group.add(m);
    }
    close();
    final int step = max(
      1,
      every ?? (steps.length / kPyrTimelineKeyframes).ceil(),
    );
    final List<Map<String, String>> keyframes = <Map<String, String>>[
      <String, String>{},
    ];
    final Map<String, String> now = <String, String>{};
    for (int i = 0; i < steps.length; i++) {
      _apply(now, steps[i]);
      if ((i + 1) % step == 0) {
        keyframes.add(Map<String, String>.of(now));
      }
    }
    return PyrTimeline._(
      List<PyrTimelineStep>.unmodifiable(steps),
      step,
      keyframes,
      Map<String, String>.unmodifiable(names),
    );
  }
}

/// The places shown of the tree [positions] (key → path): all of it when
/// small (at most [whole] people); otherwise the top three levels and,
/// around each of [focus], their line up, their cell, the cell below and
/// the one below that — what a member sees from their place.
Set<String> pyrVisiblePaths(
  Map<String, String> positions,
  Iterable<String> focus, {
  int whole = 31,
}) {
  final Set<String> occupied = positions.values.toSet();
  if (occupied.length <= whole) {
    return occupied;
  }
  final Set<String> out = <String>{
    for (final String p in occupied)
      if (p.length <= 2) p,
  };
  for (final String k in focus) {
    final String? p = positions[k];
    if (p == null) {
      continue;
    }
    String q = p;
    out.add(q);
    while (q.isNotEmpty) {
      q = PyrPath.parent(q);
      out.add(q);
    }
    out.add(PyrPath.sibling(p));
    for (final String c in PyrPath.children(p)) {
      out
        ..add(c)
        ..addAll(PyrPath.children(c));
    }
  }
  return out.where(occupied.contains).toSet();
}
