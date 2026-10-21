import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/films/film_model.dart';

/// The part of a recording that becomes the film: from [startMs] to
/// [endMs]. Always at least [kFilmMinMs] and at most [kFilmHardMaxMs] long
/// and inside the recording.
@immutable
final class FilmTrim {
  const FilmTrim({required this.startMs, required this.endMs});

  /// The whole recording, cut to [maxMs] (the default film length) when
  /// it is longer.
  factory FilmTrim.initial(int durationMs, {int maxMs = kFilmDefaultMaxMs}) =>
      FilmTrim(startMs: 0, endMs: math.max(0, math.min(durationMs, maxMs)));

  final int startMs;
  final int endMs;

  int get lengthMs => endMs - startMs;

  /// Longer than a film usually is (allowed up to [kFilmHardMaxMs]).
  bool get overDefault => lengthMs > kFilmDefaultMaxMs;

  /// Whether nothing is cut off a recording of [durationMs].
  bool isWhole(int durationMs) => startMs <= 0 && endMs >= durationMs;

  /// The start moved to [ms] in a recording of [durationMs]; the end
  /// follows when the film would get longer than [kFilmHardMaxMs].
  FilmTrim withStart(int ms, int durationMs) {
    final int minLength = math.min(kFilmMinMs, durationMs);
    final int start = ms.clamp(0, math.max(0, endMs - minLength));
    final int end = math.min(endMs, start + kFilmHardMaxMs);
    return FilmTrim(startMs: start, endMs: end);
  }

  /// The end moved to [ms]; the start follows when the film would get
  /// longer than [kFilmHardMaxMs].
  FilmTrim withEnd(int ms, int durationMs) {
    final int minLength = math.min(kFilmMinMs, durationMs);
    final int end = ms.clamp(
      math.min(startMs + minLength, durationMs),
      durationMs,
    );
    final int start = math.max(startMs, end - kFilmHardMaxMs);
    return FilmTrim(startMs: start, endMs: end);
  }

  @override
  bool operator ==(Object other) =>
      other is FilmTrim && other.startMs == startMs && other.endMs == endMs;

  @override
  int get hashCode => Object.hash(startMs, endMs);

  @override
  String toString() => 'FilmTrim($startMs..$endMs)';
}

/// "0:07", "1:30": a time in a film.
String filmClock(int ms) {
  final int seconds = (math.max(0, ms) / 1000).round();
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
