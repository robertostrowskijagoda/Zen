import 'dart:math' as math;

import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/films/film_model.dart';

// The order films play in. There is no server and no global algorithm:
// the order is worked out on this phone from what it already knows (when
// a film was made, who it is from, what friends did with it).
//
//  1. Films not watched yet from the last week, best first: fresh ones,
//     those popular among friends (likes, reactions, comments, passes),
//     from close friends and answers to this account's films get ahead.
//     The same author does not play twice in a row when someone else can
//     come between.
//  2. Then older films not watched yet, newest first.
//  3. Then everything already watched and this account's own films, newest
//     first: the pager goes on as long as there is anything at all.

/// How long a film counts as fresh.
const Duration kFilmFreshWindow = Duration(days: 7);

/// How far ahead the order looks for another author to put between two
/// films of the same one.
const int _diversityLookahead = 3;

/// How strongly [film] is put forward among fresh films at [nowMillis];
/// [me] is this account (answers to its films come first).
double filmScore(FilmPost film, {required int nowMillis, String me = ''}) {
  final double ageHours = math.max(0, nowMillis - film.millis) / 3600000;
  final double fresh = 3 * math.exp(-ageHours / 24);
  final int friendLikes = film.likes
      .where((FeedLiker l) => l.account != me)
      .length;
  final int reacted = film.reactions.values.fold<int>(
    0,
    (int a, int b) => a + b,
  );
  final double engagement =
      friendLikes +
      0.5 * reacted +
      0.5 * film.commentCount +
      1.5 * film.passedBy.length;
  final double popular = math.log(1 + engagement) / math.ln2;
  final double close = film.close ? 1.5 : 0;
  final double answer = me.isNotEmpty && film.replyTo?.account == me ? 2 : 0;
  final double far = film.fromFriendOfFriend ? 0.5 : 0;
  return fresh + popular + close + answer - far;
}

int _newestFirst(FilmPost a, FilmPost b) {
  final int byTime = b.millis.compareTo(a.millis);
  return byTime != 0 ? byTime : a.id.compareTo(b.id);
}

/// [films] in the order they play (see the top of this file); [watched]
/// holds the ids already seen here.
List<FilmPost> orderFilms(
  Iterable<FilmPost> films, {
  required int nowMillis,
  Set<String> watched = const <String>{},
  String me = '',
}) {
  final int freshFrom = nowMillis - kFilmFreshWindow.inMilliseconds;
  final List<FilmPost> fresh = <FilmPost>[];
  final List<FilmPost> older = <FilmPost>[];
  final List<FilmPost> seen = <FilmPost>[];
  for (final FilmPost f in films) {
    if (f.isOwn || watched.contains(f.id)) {
      seen.add(f);
    } else if (f.millis >= freshFrom) {
      fresh.add(f);
    } else {
      older.add(f);
    }
  }
  final Map<String, double> scores = <String, double>{
    for (final FilmPost f in fresh)
      f.id: filmScore(f, nowMillis: nowMillis, me: me),
  };
  fresh.sort((FilmPost a, FilmPost b) {
    final int byScore = scores[b.id]!.compareTo(scores[a.id]!);
    return byScore != 0 ? byScore : _newestFirst(a, b);
  });
  older.sort(_newestFirst);
  seen.sort(_newestFirst);
  return <FilmPost>[..._spreadAuthors(fresh), ...older, ...seen];
}

/// [ranked] with films of one author kept apart where another author's
/// film within [_diversityLookahead] places can come between.
List<FilmPost> _spreadAuthors(List<FilmPost> ranked) {
  final List<FilmPost> pool = List<FilmPost>.of(ranked);
  final List<FilmPost> out = <FilmPost>[];
  while (pool.isNotEmpty) {
    int pick = 0;
    if (out.isNotEmpty && pool.first.account == out.last.account) {
      for (int i = 1; i < pool.length && i <= _diversityLookahead; i++) {
        if (pool[i].account != out.last.account) {
          pick = i;
          break;
        }
      }
    }
    out.add(pool.removeAt(pick));
  }
  return out;
}
