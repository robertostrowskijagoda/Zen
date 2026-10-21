import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

// Films of friends of friends. Someone who likes a friend's public film
// passes it on to their own friends: a `film_pass` in their `acts` carries
// the film as its author signed it, with the device certificate, so a
// friend of theirs can check it came from the author without knowing them
// (the same way a reshare carries a post). Those friends see it only when
// they switched "Filmy znajomych znajomych" on. Only public films are ever
// passed on; the name and address of the author that go along are the
// passer's word (shown as "przez …"), the film itself is the author's.

/// Most films one account passes on in a day.
const int kMaxFilmPassesPerDay = 20;

/// Body passing on [film] (a public film, never someone's sealed one).
Map<String, dynamic> filmPassBody(
  LogEntry film, {
  String authorName = '',
  String authorAddress = '',
}) {
  if (film.kind != kFilmKind ||
      isSealed(film.body) ||
      film.body['aud'] != Audience.public.name) {
    throw ArgumentError.value(film.kind, 'film');
  }
  final String name = authorName.trim();
  final String address = authorAddress.trim();
  return <String, dynamic>{
    'fid': film.id,
    'film': film.toCertifiedJson(),
    if (name.isNotEmpty)
      'n': name.length > kMaxProfileName
          ? name.substring(0, kMaxProfileName)
          : name,
    if (address.isNotEmpty && address.length <= 64) 'a': address,
  };
}

/// The verified film inside [pass], or `null` if anything is off.
Future<LogEntry?> unpackFilmPass(LogEntry pass) async {
  if (pass.kind != kFilmPassKind) {
    return null;
  }
  final LogEntry? film = await verifiedEntry(pass.body['film']);
  if (film == null ||
      film.id != pass.body['fid'] ||
      film.kind != kFilmKind ||
      isSealed(film.body) ||
      film.body['aud'] != Audience.public.name ||
      film.space != accountSpace('feed', film.account)) {
    return null;
  }
  return film;
}

/// What a pass says about the author (the passer's word).
typedef FilmPassHint = ({String name, String address});

/// Checked passes, by pass entry id (a bad one maps to `null`).
final class FilmPassCache {
  final Map<String, LogEntry?> _checked = <String, LogEntry?>{};
  final Map<String, FilmPassHint> _hints = <String, FilmPassHint>{};

  bool isChecked(String passId) => _checked.containsKey(passId);

  LogEntry? originalOf(String passId) => _checked[passId];

  FilmPassHint? hintOf(String passId) => _hints[passId];

  /// Checks the passes among [entries] not seen yet; true if any new one
  /// was valid.
  Future<bool> checkAll(Iterable<LogEntry> entries) async {
    bool added = false;
    for (final LogEntry e in entries.toList()) {
      if (e.kind != kFilmPassKind || _checked.containsKey(e.id)) {
        continue;
      }
      _checked[e.id] = null;
      final LogEntry? film = await unpackFilmPass(e);
      _checked[e.id] = film;
      if (film != null) {
        final Object? n = e.body['n'];
        final Object? a = e.body['a'];
        _hints[e.id] = (
          name: n is String ? n : '',
          address: a is String && a.length <= 64 ? a : '',
        );
        added = true;
      }
    }
    return added;
  }
}

/// How many films [acts] (one account's) passed on since [sinceMillis].
int filmPassesSince(Iterable<LogEntry> acts, int sinceMillis) => acts
    .where(
      (LogEntry e) => e.kind == kFilmPassKind && e.hlc.millis >= sinceMillis,
    )
    .length;

/// Film ids [acts] (this account's own) already passed on.
Set<String> passedFilmIds(Iterable<LogEntry> acts) => <String>{
  for (final LogEntry e in acts)
    if (e.kind == kFilmPassKind && e.body['fid'] is String)
      e.body['fid'] as String,
};
