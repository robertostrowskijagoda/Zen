import 'package:flutter/foundation.dart';

// The films kept on this phone: a cache of 1 GB of other people's films
// (whole or the pieces fetched so far, posters included). When it is full
// the films already watched go first, the ones not used for longest first;
// only then films not watched yet, the same way. Never this account's own
// films (they are the original everyone else fetches), the films a mailbox
// keeps for a friend, or what is on screen and about to play.
//
// A film taken off the phone is not refused: it can come back when it is
// watched again.

/// How much of other people's films is kept.
const int kFilmCacheBytes = 1024 * 1024 * 1024;

/// One film (or poster) held, for the cache.
@immutable
final class FilmCacheItem {
  const FilmCacheItem({
    required this.id,
    required this.bytes,
    required this.lastUsedMillis,
    this.watched = false,
  });

  final String id;

  /// Bytes on the phone now (a partly fetched film counts what came).
  final int bytes;

  /// When it was last on screen (or fetched, if never shown).
  final int lastUsedMillis;
  final bool watched;
}

/// Which of [items] go so the rest fits in [limitBytes]: watched ones
/// first, then the others, least recently used first in each group. Ids in
/// [keep] are never picked and count towards the limit like the rest.
List<String> planFilmCacheEviction(
  Iterable<FilmCacheItem> items, {
  int limitBytes = kFilmCacheBytes,
  Set<String> keep = const <String>{},
}) {
  int total = 0;
  final List<FilmCacheItem> candidates = <FilmCacheItem>[];
  for (final FilmCacheItem i in items) {
    total += i.bytes;
    if (!keep.contains(i.id) && i.bytes > 0) {
      candidates.add(i);
    }
  }
  if (total <= limitBytes) {
    return const <String>[];
  }
  candidates.sort((FilmCacheItem a, FilmCacheItem b) {
    if (a.watched != b.watched) {
      return a.watched ? -1 : 1;
    }
    final int byUse = a.lastUsedMillis.compareTo(b.lastUsedMillis);
    return byUse != 0 ? byUse : a.id.compareTo(b.id);
  });
  final List<String> out = <String>[];
  for (final FilmCacheItem i in candidates) {
    if (total <= limitBytes) {
      break;
    }
    out.add(i.id);
    total -= i.bytes;
  }
  return out;
}
