import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_cache.dart';
import 'package:zen/src/features/films/film_delivery.dart';
import 'package:zen/src/features/films/film_feed.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_order.dart';
import 'package:zen/src/features/films/film_pass.dart';
import 'package:zen/src/features/films/film_prefs.dart';
import 'package:zen/src/features/films/film_publish.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/video_compressor.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What the "Filmy" screens need: the films in playing order and what can
/// be done with them. [FilmsController] is the real one; tests use fakes.
abstract class FilmsBackend extends ChangeNotifier {
  /// The films were read at least once.
  bool get ready;

  /// The films in the order they play this session.
  List<FilmPost> get films;

  /// The film on screen.
  int get index;

  /// The person swiped to the film at [value].
  set index(int value);

  bool get muted;
  Future<void> setMuted(bool muted);

  /// Public films friends passed on show too.
  bool get friendsOfFriends;
  Future<void> setFriendsOfFriends(bool on);

  /// Whether films can be compressed and trimmed on this device.
  Future<bool> canCompress();

  /// The film [id] when it is in the list.
  FilmPost? byId(String id) {
    for (final FilmPost f in films) {
      if (f.id == id) {
        return f;
      }
    }
    return null;
  }

  /// The position of [id] in [films], or -1.
  int indexOf(String id) => films.indexWhere((FilmPost f) => f.id == id);

  /// Likes [film] or takes the like back; an error for the person, or null.
  Future<String?> toggleLike(FilmPost film);

  /// Reacts with [emoji] ('' takes the reaction back).
  Future<String?> react(FilmPost film, String emoji);

  /// Comments on [film] with [text] and [pictures] (photos and GIFs made
  /// ready with `commentPicture`).
  Future<String?> comment(
    FilmPost film,
    String text, {
    List<CommentPicture> pictures = const <CommentPicture>[],
  });

  /// The ledger behind the films, when there is one: comments' pictures
  /// are read from it, and own comments can be removed through it.
  LedgerNode? get ledger => null;

  /// [film] was watched (long enough to count).
  void markWatched(FilmPost film);

  /// Removes this account's own [film].
  Future<String?> delete(FilmPost film);

  /// The film's bytes when it is here whole (to send in a chat); starts
  /// fetching it otherwise and gives null.
  Future<Uint8List?> filmBytes(FilmPost film);

  /// Compresses and publishes [draft]; the new film is shown first.
  Future<LogEntry> publish(FilmDraft draft, {FilmPublishProgress? onProgress});

  /// Reads the films again (pull to refresh, the end card).
  Future<void> refresh();

  /// Puts the film [filmId] on screen (a new own film, an answer's
  /// original); nothing when it is not in the list.
  void focus(String filmId);
}

/// The "Filmy" section over a [LedgerNode] (see film_model.dart,
/// film_order.dart, film_delivery.dart and film_cache.dart).
final class FilmsController extends FilmsBackend {
  FilmsController({
    required this.node,
    required this.disk,
    required this.nameOf,
    this.mailboxes,
    VideoCompressor? compressor,
    this.temporaryPath,
    int Function()? clock,
  }) : compressor = compressor ?? PlatformVideoCompressor.instance,
       _clock = clock ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final LedgerNode node;
  final LedgerDisk disk;

  /// A friend's display name by address.
  final String Function(String address) nameOf;

  /// The mailboxes friends announced (`RelayEngine.announcedMailboxes`);
  /// null where there are none.
  final Future<Map<String, List<String>>> Function()? mailboxes;
  final VideoCompressor compressor;

  /// Where a compressed film is written before it is sealed (the
  /// temporary media folder when null).
  final Future<String> Function()? temporaryPath;
  final int Function() _clock;

  FilmPrefs _prefs = FilmPrefs();
  final FilmPassCache _passes = FilmPassCache();
  List<FilmPost> _films = const <FilmPost>[];
  List<String> _order = const <String>[];
  int _index = 0;
  bool _ready = false;
  bool _disposed = false;
  Timer? _rebuildSoon;
  Timer? _housekeeping;
  Timer? _seenFlush;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  /// Films watched here whose views are not written yet.
  final Set<String> _seenPending = <String>{};

  /// Blobs being fetched whole for the screen.
  final Set<String> _fetching = <String>{};

  /// Blobs a mailbox keeps whole for the friends it serves.
  Set<String> _seeded = <String>{};
  Map<String, List<String>> _mailboxes = const <String, List<String>>{};

  @override
  bool get ready => _ready;

  @override
  List<FilmPost> get films => _films;

  @override
  int get index => _index;

  @override
  set index(int value) {
    if (_films.isEmpty) {
      _index = 0;
      return;
    }
    final int next = value.clamp(0, _films.length - 1);
    if (next == _index) {
      return;
    }
    _index = next;
    _planFetches();
    notifyListeners();
  }

  @override
  bool get muted => _prefs.muted;

  @override
  bool get friendsOfFriends => _prefs.friendsOfFriends;

  /// Starts reading the films and following changes.
  Future<void> start() async {
    await node.start();
    _prefs = await FilmPrefs.load(disk);
    if (_disposed) {
      return;
    }
    // A film fetched only to its start before the app was closed must not
    // come down whole now that nothing remembers why it was wanted.
    for (final String id in node.blobs.wanted.toList()) {
      if (_prefs.used.containsKey(id)) {
        node.replicator.pauseBlob(id);
      }
    }
    _subs
      ..add(node.store.added.listen(_onEntry))
      ..add(node.openedChanges.listen((_) => _scheduleRebuild()))
      ..add(node.mediaCompleted.listen(_onMediaDone));
    _housekeeping = Timer.periodic(
      const Duration(minutes: 10),
      (_) => unawaitedLogged(_houseKeep(), context: 'Filmy: porządki'),
    );
    await _rebuild();
    unawaitedLogged(_houseKeep(), context: 'Filmy: porządki');
  }

  @override
  void dispose() {
    _disposed = true;
    _rebuildSoon?.cancel();
    _housekeeping?.cancel();
    _seenFlush?.cancel();
    for (final StreamSubscription<Object?> s in _subs) {
      unawaited(s.cancel());
    }
    unawaitedLogged(_flushSeen(), context: 'Filmy: obejrzane');
    for (final String id in _fetching) {
      node.replicator.pauseBlob(id);
    }
    super.dispose();
  }

  void _onEntry(LogEntry e) {
    if (e.kind == kFilmKind ||
        e.kind == kPostDeleteKind ||
        e.kind == kFilmPassKind ||
        e.kind == kLikeKind ||
        e.kind == kCommentKind ||
        e.kind == kCommentDeleteKind ||
        e.kind == kFilmReactionKind ||
        e.kind == kFilmSeenKind) {
      _scheduleRebuild();
    }
  }

  void _onMediaDone(String id) {
    if (_fetching.remove(id)) {
      _prefs.touch(id, _clock());
    }
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _scheduleRebuild() {
    _rebuildSoon?.cancel();
    _rebuildSoon = Timer(const Duration(milliseconds: 300), () {
      unawaitedLogged(_rebuild(), context: 'Filmy: odczyt');
    });
  }

  @override
  Future<void> refresh() async {
    // Everything after the film on screen is ranked again.
    await _rebuild();
  }

  Future<void> _rebuild() async {
    if (_disposed || !node.isReady) {
      return;
    }
    if (_prefs.friendsOfFriends) {
      await _passes.checkAll(<LogEntry>[
        for (final String account in node.friendAccounts.values)
          ...node.entriesOf(spaceKind: 'acts', ofAccount: account),
      ]);
    }
    if (_disposed) {
      return;
    }
    final List<FilmPost> built = buildFilms(
      NodeFilmLedgerView(node),
      nameOf: nameOf,
      passes: _passes,
      friendsOfFriends: _prefs.friendsOfFriends,
    );
    final List<FilmPost> ranked = orderFilms(
      built,
      nowMillis: _clock(),
      watched: <String>{
        ..._prefs.watched,
        ...seenFilms(node.entriesOf(spaceKind: 'acts')),
      },
      me: node.account,
    );
    final String? current = _index < _order.length ? _order[_index] : null;
    _order = mergeFilmOrder(
      previous: _order,
      index: _index,
      ranked: <String>[for (final FilmPost f in ranked) f.id],
    );
    final Map<String, FilmPost> byId = <String, FilmPost>{
      for (final FilmPost f in built) f.id: f,
    };
    _films = <FilmPost>[for (final String id in _order) byId[id]!];
    final int kept = current == null ? -1 : _order.indexOf(current);
    _index = kept >= 0
        ? kept
        : math.min(_index, math.max(0, _films.length - 1));
    _ready = true;
    _planFetches();
    notifyListeners();
  }

  @override
  void focus(String filmId) {
    final int at = _order.indexOf(filmId);
    if (at < 0) {
      return;
    }
    if (at != _index) {
      // Moved right after the film on screen, so the way back stays.
      final List<String> order = List<String>.of(_order)..removeAt(at);
      final int to = math.min(at < _index ? _index : _index + 1, order.length);
      order.insert(to, filmId);
      final Map<String, FilmPost> byId = <String, FilmPost>{
        for (final FilmPost f in _films) f.id: f,
      };
      _order = order;
      _films = <FilmPost>[for (final String id in order) byId[id]!];
      _index = to;
    }
    _planFetches();
    notifyListeners();
  }

  // ---- fetching ----

  Set<String> _completeOf(Iterable<String> ids) => <String>{
    for (final String id in ids)
      if (node.blobs.isComplete(id)) id,
  };

  bool _headHere(String id) {
    final BlobManifest? m = node.blobs.manifest(id);
    return m != null &&
        (m.chunks.isEmpty || node.blobs.backend.has(m.chunks.first));
  }

  void _planFetches() {
    if (_films.isEmpty) {
      return;
    }
    final int to = math.min(_films.length, _index + kFilmPosterAhead + 1);
    final List<FilmPost> near = _films.sublist(_index, to);
    final Set<String> ids = <String>{
      for (final FilmPost f in near) ...f.blobIds,
    };
    final FilmFetchPlan plan = planFilmFetch(
      order: _films,
      index: _index,
      complete: _completeOf(ids),
      headReady: <String>{
        for (final String id in ids)
          if (_headHere(id)) id,
      },
      fetching: _fetching,
      download: node.autoDownloadMedia(),
    );
    final int now = _clock();
    final Map<String, FilmPost> owner = <String, FilmPost>{
      for (final FilmPost f in near)
        for (final String id in f.blobIds) id: f,
    };
    for (final String id in plan.pause) {
      if (!_seeded.contains(id)) {
        node.replicator.pauseBlob(id);
        _fetching.remove(id);
      }
    }
    for (final String id in plan.full) {
      _fetching.add(id);
      _prefs.touch(id, now);
      node.replicator.fetchBlob(id, _sourcesOf(owner[id]!));
    }
    for (final String id in plan.posters) {
      _prefs.touch(id, now);
      node.replicator.fetchBlob(id, _sourcesOf(owner[id]!));
    }
    for (final String id in plan.heads) {
      _prefs.touch(id, now);
      node.replicator.fetchBlob(
        id,
        _sourcesOf(owner[id]!),
        firstChunks: kFilmPrefetchChunks,
      );
    }
    _prefs.touch(_films[_index].video.id, now);
    _saveSoon();
  }

  /// Where the pieces of [film] can come from (see [filmSources]).
  List<String> _sourcesOf(FilmPost film) {
    String norm(String a) => PeerShareCodec.normalizeAddress(a);
    final List<String> author = film.isOwn
        ? node.siblingAddresses
        : <String>[
            ...node.addressesOfAccount(film.account),
            if (film.authorAddress.isNotEmpty) norm(film.authorAddress),
          ];
    final List<String> watchers = <String>[
      ...film.passerAddresses.map(norm),
      for (final FeedLiker l in film.likes)
        if (l.account != node.account) ...node.addressesOfAccount(l.account),
      for (final FeedComment c in film.comments)
        if (c.authorAddress.isNotEmpty) norm(c.authorAddress),
    ];
    final List<String> boxes = <String>[
      for (final String a in author) ...?_mailboxes[a]?.map(norm),
    ];
    return filmSources(
      authorAddresses: author,
      watchers: watchers,
      mailboxes: boxes,
      friends: node.friendAccounts.keys,
      self: norm(node.ownAddress),
    );
  }

  // ---- housekeeping: mailbox copies and the cache ----

  Future<void> _houseKeep() async {
    if (_disposed || !node.isReady) {
      return;
    }
    await _refreshMailboxes();
    _seedForServedFriends();
    await _trimCache();
    _retryCurrent();
  }

  /// The film on screen may have waited on sources that went offline.
  void _retryCurrent() {
    if (_films.isEmpty || _disposed) {
      return;
    }
    final FilmPost f = _films[_index];
    if (!node.blobs.isComplete(f.video.id)) {
      node.replicator.fetchBlob(f.video.id, _sourcesOf(f));
    }
  }

  Future<void> _refreshMailboxes() async {
    final Future<Map<String, List<String>>> Function()? read = mailboxes;
    if (read == null) {
      return;
    }
    try {
      final Map<String, List<String>> raw = await read();
      _mailboxes = <String, List<String>>{
        for (final MapEntry<String, List<String>> e in raw.entries)
          PeerShareCodec.normalizeAddress(e.key): e.value,
      };
    } on Object catch (error, stack) {
      logZenError('Filmy: skrzynki znajomych', error, stack);
    }
  }

  /// A mailbox keeps the newest films of the friends it serves whole, up
  /// to [kFilmMaxBytes] each ([planMailboxSeeding]), so they can be
  /// fetched while the author is offline.
  void _seedForServedFriends() {
    final String self = PeerShareCodec.normalizeAddress(node.ownAddress);
    if (self.isEmpty) {
      return;
    }
    final Set<String> served = <String>{
      for (final MapEntry<String, List<String>> e in _mailboxes.entries)
        if (e.value.map(PeerShareCodec.normalizeAddress).contains(self)) e.key,
    };
    final Set<String> servedAccounts = <String>{
      for (final String a in served) ?node.accountOf(a),
    };
    final List<SeedCandidate> candidates = <SeedCandidate>[];
    final Map<String, FilmPost> filmOf = <String, FilmPost>{};
    for (final FilmPost f in _films) {
      if (f.isOwn || !servedAccounts.contains(f.account)) {
        continue;
      }
      filmOf[f.video.id] = f;
      final BlobManifest? m = node.blobs.manifest(f.video.id);
      if (m == null) {
        // The size is not known yet: its start tells.
        node.replicator.fetchBlob(
          f.video.id,
          _sourcesOf(f),
          firstChunks: kFilmPrefetchChunks,
        );
        continue;
      }
      candidates.add((
        author: f.account,
        blob: f.video.id,
        bytes: m.size,
        millis: f.millis,
      ));
    }
    _seeded = planMailboxSeeding(candidates);
    for (final String id in _seeded) {
      if (!node.blobs.isComplete(id)) {
        node.replicator.fetchBlob(id, _sourcesOf(filmOf[id]!));
      }
    }
  }

  /// Bytes of [id] on the phone now.
  int _bytesHere(String id) {
    final BlobManifest? m = node.blobs.manifest(id);
    if (m == null) {
      return 0;
    }
    int bytes = 0;
    for (int i = 0; i < m.chunks.length; i++) {
      if (node.blobs.backend.has(m.chunks[i])) {
        bytes += m.chunkLength(i);
      }
    }
    return bytes;
  }

  Future<void> _trimCache() async {
    final Set<String> own = <String>{
      for (final FilmPost f in _films)
        if (f.isOwn) ...f.blobIds,
    };
    final Set<String> watchedBlobs = <String>{
      for (final FilmPost f in _films)
        if (_prefs.watched.contains(f.id)) ...f.blobIds,
    };
    final Set<String> keep = <String>{..._seeded, ..._fetching};
    for (
      int i = _index;
      i < _films.length && i <= _index + kFilmPrefetchAhead;
      i++
    ) {
      keep.addAll(_films[i].blobIds);
    }
    final List<FilmCacheItem> items = <FilmCacheItem>[
      for (final MapEntry<String, int> u in _prefs.used.entries)
        if (!own.contains(u.key))
          FilmCacheItem(
            id: u.key,
            bytes: _bytesHere(u.key),
            lastUsedMillis: u.value,
            watched: watchedBlobs.contains(u.key),
          ),
    ];
    final List<String> evict = planFilmCacheEviction(items, keep: keep);
    if (evict.isEmpty) {
      return;
    }
    for (final String id in evict) {
      // Off the phone, but not refused: it may be fetched again.
      await node.blobs.refuse(id);
      node.blobs.refused.remove(id);
      _prefs.used.remove(id);
    }
    node.blobs.onChanged?.call();
    await _save();
  }

  // ---- what the person does ----

  @override
  Future<void> setMuted(bool muted) async {
    _prefs.muted = muted;
    notifyListeners();
    await _save();
  }

  @override
  Future<void> setFriendsOfFriends(bool on) async {
    _prefs.friendsOfFriends = on;
    await _save();
    await _rebuild();
  }

  @override
  Future<bool> canCompress() => compressor.available();

  @override
  void markWatched(FilmPost film) {
    if (_prefs.watched.contains(film.id)) {
      return;
    }
    _prefs.markWatched(film.id);
    _saveSoon();
    // The author counts views of friends only: a film of a friend of a
    // friend is not reported anywhere.
    if (!film.isOwn &&
        !film.fromFriendOfFriend &&
        node.friendAccounts.containsValue(film.account)) {
      _seenPending.add(film.id);
      _seenFlush ??= Timer(const Duration(seconds: 30), () {
        unawaitedLogged(_flushSeen(), context: 'Filmy: obejrzane');
      });
      if (_seenPending.length >= 16) {
        unawaitedLogged(_flushSeen(), context: 'Filmy: obejrzane');
      }
    }
  }

  Future<void> _flushSeen() async {
    _seenFlush?.cancel();
    _seenFlush = null;
    if (_seenPending.isEmpty) {
      return;
    }
    final Set<String> already = seenFilms(node.entriesOf(spaceKind: 'acts'));
    final List<String> fresh = <String>[
      for (final String id in _seenPending)
        if (!already.contains(id)) id,
    ];
    _seenPending.clear();
    for (final Map<String, dynamic> body in filmSeenBodies(fresh)) {
      await node.publish(kFilmSeenKind, body, spaceKind: 'acts');
    }
  }

  @override
  Future<String?> toggleLike(FilmPost film) async {
    try {
      final bool on = !film.likedByMe;
      await node.publish(
        kLikeKind,
        likeBody(film.id, on: on, mini: ownMiniProfile(node)),
        spaceKind: 'acts',
      );
      if (on) {
        await _maybePass(film);
      }
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  /// A liked public film of a friend goes on to this account's friends
  /// (see film_pass.dart), at most [kMaxFilmPassesPerDay] a day.
  Future<void> _maybePass(FilmPost film) async {
    final LogEntry? entry = film.entry;
    if (entry == null ||
        film.isOwn ||
        film.fromFriendOfFriend ||
        film.audience != Audience.public ||
        !node.friendAccounts.containsValue(film.account)) {
      return;
    }
    final List<LogEntry> acts = node.entriesOf(spaceKind: 'acts');
    if (passedFilmIds(acts).contains(film.id) ||
        filmPassesSince(
              acts,
              _clock() - const Duration(days: 1).inMilliseconds,
            ) >=
            kMaxFilmPassesPerDay) {
      return;
    }
    await node.publish(
      kFilmPassKind,
      filmPassBody(
        entry,
        authorName: film.authorLabel,
        authorAddress: film.authorAddress,
      ),
      spaceKind: 'acts',
    );
  }

  @override
  Future<String?> react(FilmPost film, String emoji) async {
    try {
      await node.publish(
        kFilmReactionKind,
        filmReactionBody(film.id, film.myReaction == emoji ? '' : emoji),
        spaceKind: 'acts',
      );
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  @override
  LedgerNode? get ledger => node;

  @override
  Future<String?> comment(
    FilmPost film,
    String text, {
    List<CommentPicture> pictures = const <CommentPicture>[],
  }) async {
    try {
      await publishComment(node, film.id, text, pictures: pictures);
      return null;
    } on ArgumentError catch (e) {
      return e.message as String?;
    } on Object catch (e) {
      return '$e';
    }
  }

  @override
  Future<String?> delete(FilmPost film) async {
    if (!film.isOwn) {
      return null;
    }
    try {
      await node.publish(kPostDeleteKind, deletePostBody(film.id));
      return null;
    } on Object catch (e) {
      return '$e';
    }
  }

  @override
  Future<Uint8List?> filmBytes(FilmPost film) async {
    if (!node.blobs.isComplete(film.video.id)) {
      _fetching.add(film.video.id);
      node.replicator.fetchBlob(film.video.id, _sourcesOf(film));
      return null;
    }
    return openSafePlayable(node.blobs, film.video);
  }

  @override
  Future<LogEntry> publish(
    FilmDraft draft, {
    FilmPublishProgress? onProgress,
  }) async {
    final LogEntry entry = await publishFilm(
      node,
      draft,
      compressor: compressor,
      onProgress: onProgress,
      temporaryPath: temporaryPath,
    );
    await _rebuild();
    focus(entry.id);
    return entry;
  }

  // ---- saving ----

  Timer? _saveTimer;

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), () {
      unawaitedLogged(_save(), context: 'Filmy: zapis');
    });
  }

  Future<void> _save() async {
    _saveTimer?.cancel();
    try {
      await _prefs.save(disk);
    } on Object catch (error, stack) {
      logZenError('Filmy: zapis', error, stack);
    }
  }
}
