import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/core/ledger/ledger_archive.dart';

/// What the "Filmy" section remembers on this phone (in the encrypted
/// store): the sound switch, whether friends of friends' films show, which
/// films were watched here and when each film was last used (for the
/// cache).
final class FilmPrefs {
  FilmPrefs({
    this.muted = false,
    this.friendsOfFriends = false,
    Set<String>? watched,
    Map<String, int>? used,
  }) : watched = watched ?? <String>{},
       used = used ?? <String, int>{};

  /// Where it is kept.
  static const String diskKey = 'films/state';

  /// Most watched ids and cache times kept (the oldest go).
  static const int maxKept = 5000;

  bool muted;

  /// Show public films friends passed on (off until the person opts in).
  bool friendsOfFriends;

  /// Film ids watched on this phone (insertion order: oldest first).
  final Set<String> watched;

  /// Blob id → when it was last on screen or fetched.
  final Map<String, int> used;

  void markWatched(String filmId) {
    watched
      ..remove(filmId)
      ..add(filmId);
    while (watched.length > maxKept) {
      watched.remove(watched.first);
    }
  }

  void touch(String blobId, int millis) {
    used
      ..remove(blobId)
      ..[blobId] = millis;
    while (used.length > maxKept) {
      used.remove(used.keys.first);
    }
  }

  Uint8List toBytes() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(<String, dynamic>{
        'm': muted,
        'f': friendsOfFriends,
        'w': watched.toList(),
        'u': used,
      }),
    ),
  );

  static FilmPrefs fromBytes(Uint8List? raw) {
    if (raw == null || raw.isEmpty) {
      return FilmPrefs();
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return FilmPrefs();
      }
      final Object? w = json['w'];
      final Object? u = json['u'];
      return FilmPrefs(
        muted: json['m'] == true,
        friendsOfFriends: json['f'] == true,
        watched: <String>{
          if (w is List)
            for (final Object? id in w.take(maxKept))
              if (id is String && id.length <= 128) id,
        },
        used: <String, int>{
          if (u is Map)
            for (final MapEntry<Object?, Object?> e in u.entries.take(maxKept))
              if (e.key is String && e.value is int)
                e.key! as String: e.value! as int,
        },
      );
    } on FormatException {
      return FilmPrefs();
    }
  }

  static Future<FilmPrefs> load(LedgerDisk disk) async {
    try {
      return fromBytes(await disk.read(diskKey));
    } on Object {
      return FilmPrefs();
    }
  }

  Future<void> save(LedgerDisk disk) => disk.write(diskKey, toBytes());
}
