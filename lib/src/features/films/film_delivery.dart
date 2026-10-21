import 'package:flutter/foundation.dart';
import 'package:zen/src/features/films/film_model.dart';

// How films travel. A film is an encrypted blob cut into 256 KB pieces
// addressed by their hash (blob_store.dart), so any piece can be taken from
// anyone who has it and checked on arrival: from the author, from friends
// who watched it, from the author's mailboxes (friends who keep a copy of
// the author's newest films while the author is offline) and from any
// other friend.
//
// What is fetched, and when:
//
//  * the film on screen: all of it, played while it downloads;
//  * the next two: only their first piece (enough to start at once), and
//    their posters; nothing else in advance;
//  * a film scrolled past stops downloading (what came stays and the rest
//    comes when it is on screen again).
//
// Mobile data is used like Wi-Fi: the person asked for downloads everywhere
// by default (the "pobieranie mediów" setting can turn it off).

/// Films after the one on screen whose beginning is fetched in advance.
const int kFilmPrefetchAhead = 2;

/// Films after the one on screen whose posters are fetched in advance.
const int kFilmPosterAhead = 5;

/// Pieces fetched in advance from each of the next films.
const int kFilmPrefetchChunks = 1;

/// Where to ask for the pieces of a film, best first: the author's
/// devices, the people who passed it on or reacted to it (they have
/// watched it), the author's mailboxes, then every other friend. Never
/// this device itself, never twice.
List<String> filmSources({
  required Iterable<String> authorAddresses,
  Iterable<String> watchers = const <String>[],
  Iterable<String> mailboxes = const <String>[],
  Iterable<String> friends = const <String>[],
  String self = '',
}) {
  final List<String> out = <String>[];
  for (final Iterable<String> group in <Iterable<String>>[
    authorAddresses,
    watchers,
    mailboxes,
    friends,
  ]) {
    for (final String a in group) {
      if (a.isNotEmpty && a != self && !out.contains(a)) {
        out.add(a);
      }
    }
  }
  return out;
}

/// What to fetch right now, for the film on screen at [index] of [order].
@immutable
final class FilmFetchPlan {
  const FilmFetchPlan({
    this.full = const <String>[],
    this.heads = const <String>[],
    this.posters = const <String>[],
    this.pause = const <String>[],
  });

  /// Blobs to fetch whole (the film on screen).
  final List<String> full;

  /// Blobs to fetch only the beginning of.
  final List<String> heads;

  /// Posters to fetch (small, whole).
  final List<String> posters;

  /// Blobs being fetched that are not needed now.
  final List<String> pause;
}

/// The fetch plan when the film at [index] of [order] is on screen.
/// [complete] holds blobs already here in full, [headReady] those whose
/// beginning is here, [fetching] those being fetched whole now.
FilmFetchPlan planFilmFetch({
  required List<FilmPost> order,
  required int index,
  Set<String> complete = const <String>{},
  Set<String> headReady = const <String>{},
  Set<String> fetching = const <String>{},
  bool download = true,
}) {
  if (index < 0 || index >= order.length) {
    return FilmFetchPlan(pause: fetching.toList());
  }
  final FilmPost current = order[index];
  final List<String> full = <String>[];
  final List<String> heads = <String>[];
  final List<String> posters = <String>[];
  if (!complete.contains(current.video.id)) {
    full.add(current.video.id);
  }
  final String? poster = current.poster?.id;
  if (poster != null && !complete.contains(poster)) {
    posters.add(poster);
  }
  for (
    int i = index + 1;
    i < order.length && i <= index + kFilmPosterAhead;
    i++
  ) {
    final FilmPost next = order[i];
    final String? p = next.poster?.id;
    if (download &&
        p != null &&
        !complete.contains(p) &&
        !posters.contains(p)) {
      posters.add(p);
    }
    final String v = next.video.id;
    if (download &&
        i <= index + kFilmPrefetchAhead &&
        !complete.contains(v) &&
        !headReady.contains(v) &&
        !heads.contains(v) &&
        v != current.video.id) {
      heads.add(v);
    }
  }
  return FilmFetchPlan(
    full: full,
    heads: heads,
    posters: posters,
    pause: <String>[
      for (final String id in fetching)
        if (id != current.video.id) id,
    ],
  );
}

/// A film of someone this device keeps mail for (a mailbox).
typedef SeedCandidate = ({String author, String blob, int bytes, int millis});

/// Which films a mailbox keeps whole: per author it serves, the newest
/// films while they fit in [quotaBytes] (what the mailbox holds for one
/// sender). A film bigger than the quota is never kept.
Set<String> planMailboxSeeding(
  Iterable<SeedCandidate> candidates, {
  int quotaBytes = kFilmMaxBytes,
}) {
  final Map<String, List<SeedCandidate>> byAuthor =
      <String, List<SeedCandidate>>{};
  for (final SeedCandidate c in candidates) {
    (byAuthor[c.author] ??= <SeedCandidate>[]).add(c);
  }
  final Set<String> keep = <String>{};
  for (final List<SeedCandidate> list in byAuthor.values) {
    list.sort((SeedCandidate a, SeedCandidate b) {
      final int byTime = b.millis.compareTo(a.millis);
      return byTime != 0 ? byTime : a.blob.compareTo(b.blob);
    });
    int used = 0;
    for (final SeedCandidate c in list) {
      if (c.bytes <= 0 || used + c.bytes > quotaBytes) {
        // The newest that fit; an older one never jumps a bigger newer one.
        break;
      }
      used += c.bytes;
      keep.add(c.blob);
    }
  }
  return keep;
}

/// The order of the session after the films changed: what was already
/// played and the next [keepAhead] stay where they are (the pager must not
/// jump under the finger), the rest follows [ranked] — new films included.
List<String> mergeFilmOrder({
  required List<String> previous,
  required int index,
  required List<String> ranked,
  int keepAhead = kFilmPrefetchAhead,
}) {
  final Set<String> exists = ranked.toSet();
  final List<String> head = <String>[
    for (int i = 0; i < previous.length && i <= index + keepAhead; i++)
      if (exists.contains(previous[i])) previous[i],
  ];
  final Set<String> placed = head.toSet();
  return <String>[
    ...head,
    for (final String id in ranked)
      if (!placed.contains(id)) id,
  ];
}
