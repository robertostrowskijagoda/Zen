import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/groups/group_board.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What the group board needs from the app.
abstract interface class GroupBoardHost {
  /// This phone's address.
  String ownAddress();

  /// This person's name, as it goes with their posts.
  String ownName();

  /// The other members of [groupId] (never this phone), or `null` when
  /// this person is not in that group (or has not joined it yet).
  List<String>? membersOf(String groupId);

  /// Whether [address] may remove any post of [groupId] (its creator).
  bool isAdmin(String groupId, String address);

  Future<void> send(String to, Map<String, dynamic> payload);
}

/// The boards of this person's groups (see `group_board.dart`).
final class GroupBoardService extends ChangeNotifier {
  GroupBoardService({
    required this.host,
    required this.disk,
    int Function()? now,
    Random? random,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _random = random ?? Random.secure();

  final GroupBoardHost host;
  final LedgerDisk disk;
  final int Function() _now;
  final Random _random;

  final Map<String, GroupBoard> _boards = <String, GroupBoard>{};

  /// When each board last asked the members what they have.
  final Map<String, int> _askedAt = <String, int>{};

  /// New posts taken per group and author (their arrival times).
  final Map<String, List<int>> _arrivals = <String, List<int>>{};

  /// When each member of each board was last answered with its posts
  /// ("group|member" → when).
  final Map<String, int> _answeredAt = <String, int>{};

  /// How far ahead of this phone's clock a post may be dated: a post from
  /// the future would stay on top, outlive every other one when the board
  /// is trimmed and could not be removed.
  static const int _maxClockSkew = 24 * 3600 * 1000;

  /// How long after asking ([syncWith]) the answers are taken.
  static const int _syncWindow = 10 * 60 * 1000;

  /// Boards are read and written one at a time.
  Future<void> _lock = Future<void>.value();

  static String _keyOf(String groupId) =>
      'group_board/${sha256Hex(utf8.encode(groupId)).substring(0, 32)}';

  Future<T> _locked<T>(Future<T> Function() work) {
    final Future<T> result = _lock.then((_) => work());
    _lock = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  /// The board of [groupId] as read so far ([open] reads it).
  List<GroupBoardPost> postsOf(String groupId) =>
      _boards[groupId]?.visible ?? const <GroupBoardPost>[];

  /// Reads the board of [groupId] and asks the other members for posts
  /// missing here (at most every 10 minutes).
  Future<void> open(String groupId) async {
    await _locked(() => _board(groupId));
    notifyListeners();
    await syncWith(groupId);
  }

  Future<GroupBoard> _board(String groupId) async {
    final GroupBoard? had = _boards[groupId];
    if (had != null) {
      return had;
    }
    GroupBoard board = GroupBoard();
    try {
      final Uint8List? raw = await disk.read(_keyOf(groupId));
      if (raw != null) {
        board = GroupBoard.fromJson(jsonDecode(utf8.decode(raw)));
      }
    } on Object catch (error, stack) {
      logZenError('Tablica grupy: odczyt', error, stack);
    }
    return _boards[groupId] = board;
  }

  Future<void> _write(String groupId, GroupBoard board) => disk.write(
    _keyOf(groupId),
    Uint8List.fromList(utf8.encode(jsonEncode(board.toJson()))),
  );

  String _newId() => <String>[
    for (int i = 0; i < 16; i++) _random.nextInt(16).toRadixString(16),
  ].join();

  /// Writes a new post on the board of [groupId] and sends it to every
  /// member; [media] is the reference of its photo (already kept as
  /// blocks). Null when this person is not in the group, or the post has
  /// neither text nor a photo, or its text is too long.
  Future<GroupBoardPost?> publish(
    String groupId,
    String text, {
    Map<String, dynamic>? media,
  }) async {
    final GroupBoardHost h = host;
    final String body = text.trim();
    final List<String>? members = h.membersOf(groupId);
    if (members == null ||
        (body.isEmpty && media == null) ||
        body.length > kMaxBoardPostChars ||
        h.ownAddress().isEmpty) {
      return null;
    }
    final int at = _now();
    final GroupBoardPost post = GroupBoardPost(
      id: _newId(),
      author: PeerShareCodec.normalizeAddress(h.ownAddress()),
      authorName: h.ownName().trim(),
      text: body,
      createdAt: at,
      version: at,
      media: media,
    );
    // Checked as any post from the network is: a photo's reference the
    // others would drop (too large, malformed) does not go out, not even
    // as a post without its photo.
    final GroupBoardPost? checked = GroupBoardPost.fromJson(post.toJson());
    if (checked == null || (media != null && checked.media == null)) {
      return null;
    }
    await _store(groupId, post);
    await _broadcast(groupId, members, post);
    return post;
  }

  /// Changes the text of this person's own post.
  Future<bool> edit(String groupId, String postId, String text) async {
    final String body = text.trim();
    final GroupBoardPost? had = (await _locked(
      () => _board(groupId),
    )).posts[postId];
    if (had == null ||
        had.deleted ||
        !_isOwn(had) ||
        (body.isEmpty && had.media == null) ||
        body.length > kMaxBoardPostChars ||
        body == had.text) {
      return false;
    }
    return _change(
      groupId,
      had.copyWith(text: body, version: max(_now(), had.version + 1)),
    );
  }

  /// Removes a post: this person's own, or any one when they created the
  /// group.
  Future<bool> remove(String groupId, String postId) async {
    final GroupBoardHost h = host;
    final GroupBoardPost? had = (await _locked(
      () => _board(groupId),
    )).posts[postId];
    if (had == null ||
        had.deleted ||
        !(_isOwn(had) || h.isAdmin(groupId, h.ownAddress()))) {
      return false;
    }
    return _change(
      groupId,
      had.copyWith(
        text: '',
        version: max(_now(), had.version + 1),
        deleted: true,
      ),
    );
  }

  /// Whether this person wrote [post].
  bool isOwn(GroupBoardPost post) => _isOwn(post);

  /// Whether this person may remove [post] from the board of [groupId].
  bool canRemove(String groupId, GroupBoardPost post) {
    return _isOwn(post) || host.isAdmin(groupId, host.ownAddress());
  }

  bool _isOwn(GroupBoardPost post) {
    final String own = host.ownAddress();
    return own.isNotEmpty && PeerShareCodec.addressesEqual(own, post.author);
  }

  Future<bool> _change(String groupId, GroupBoardPost post) async {
    final List<String>? members = host.membersOf(groupId);
    if (members == null) {
      return false;
    }
    await _store(groupId, post);
    await _broadcast(groupId, members, post);
    return true;
  }

  Future<bool> _store(String groupId, GroupBoardPost post) async {
    final bool changed = await _locked(() async {
      final GroupBoard board = await _board(groupId);
      if (!board.merge(post)) {
        return false;
      }
      await _write(groupId, board);
      return true;
    });
    if (changed) {
      notifyListeners();
    }
    return changed;
  }

  Future<void> _broadcast(
    String groupId,
    List<String> members,
    GroupBoardPost post,
  ) async {
    for (final String member in members) {
      try {
        await host.send(member, <String, dynamic>{
          'type': kGroupPostType,
          'g': groupId,
          'p': post.toJson(),
        });
      } on Object catch (error, stack) {
        logZenError('Tablica grupy: wysyłka', error, stack);
      }
    }
  }

  /// Tells the other members of [groupId] what this board holds; each one
  /// answers with the posts it wrote that are missing here. At most every
  /// 10 minutes unless [force].
  Future<void> syncWith(String groupId, {bool force = false}) async {
    final GroupBoardHost h = host;
    final List<String>? members = h.membersOf(groupId);
    final int t = _now();
    final int? last = _askedAt[groupId];
    if (members == null ||
        members.isEmpty ||
        (!force && last != null && t - last < 10 * 60 * 1000)) {
      return;
    }
    _askedAt[groupId] = t;
    final Map<String, int> have = (await _locked(
      () => _board(groupId),
    )).versions;
    for (final String member in members) {
      try {
        await h.send(member, <String, dynamic>{
          'type': kGroupBoardHaveType,
          'g': groupId,
          'h': have,
        });
      } on Object catch (error, stack) {
        logZenError('Tablica grupy: synchronizacja', error, stack);
      }
    }
  }

  /// Handles a board frame; false for anything else.
  Future<bool> handle(SignalTransportFrame frame) async {
    final Object? type = frame.payload['type'];
    if (type is! String || !kGroupBoardTypes.contains(type)) {
      return false;
    }
    final Object? g = frame.payload['g'];
    if (g is! String || g.isEmpty || g.length > 128) {
      return true;
    }
    final String from = PeerShareCodec.normalizeAddress(frame.from);
    final List<String>? members = host.membersOf(g);
    if (members == null ||
        !members.any((String m) => PeerShareCodec.addressesEqual(m, from))) {
      return true;
    }
    switch (type) {
      case kGroupPostType:
        await _take(g, from, frame.payload['p']);
      case kGroupBoardPutType:
        final Object? posts = frame.payload['ps'];
        if (posts is List) {
          for (final Object? p in posts.take(kMaxBoardPutPosts)) {
            await _take(g, from, p, fromSync: true);
          }
        }
      case kGroupBoardHaveType:
        await _answerHave(g, from, frame.payload['h']);
    }
    return true;
  }

  /// [json] from [from], a member of [groupId]: taken when [from] wrote
  /// it (or removes it as the group's creator).
  Future<void> _take(
    String groupId,
    String from,
    Object? json, {
    bool fromSync = false,
  }) async {
    final GroupBoardPost? post = GroupBoardPost.fromJson(json);
    if (post == null) {
      return;
    }
    final bool byAuthor = PeerShareCodec.addressesEqual(post.author, from);
    if (!byAuthor && !(post.deleted && host.isAdmin(groupId, from))) {
      return;
    }
    final int t = _now();
    if (post.createdAt > t + _maxClockSkew ||
        post.version > t + _maxClockSkew) {
      return;
    }
    if (fromSync) {
      // Only answers to this phone's own question, not long after it.
      final int? asked = _askedAt[groupId];
      if (asked == null || t - asked > _syncWindow) {
        return;
      }
    }
    final GroupBoard board = await _locked(() => _board(groupId));
    if (!board.posts.containsKey(post.id) &&
        !(fromSync
            ? _admitArrival('$groupId|$from|sync', kMaxBoardPosts)
            : _admitArrival('$groupId|$from', kMaxBoardPostsPerHour))) {
      return;
    }
    await _store(groupId, post);
  }

  /// At most [limit] new posts an hour under [key]; counts this one.
  bool _admitArrival(String key, int limit) {
    final int t = _now();
    final List<int> times = _arrivals.putIfAbsent(key, () => <int>[])
      ..removeWhere((int at) => t - at > 3600 * 1000);
    if (times.length >= limit) {
      return false;
    }
    times.add(t);
    return true;
  }

  Future<void> _answerHave(String groupId, String from, Object? have) async {
    if (have is! Map) {
      return;
    }
    final Map<String, int> theirs = <String, int>{
      for (final MapEntry<Object?, Object?> e in have.entries.take(
        kMaxBoardPosts * 2,
      ))
        if (e.key is String && e.value is int) e.key as String: e.value as int,
    };
    final String own = host.ownAddress();
    if (own.isEmpty) {
      return;
    }
    // One answer per member per [_syncWindow]: asking over and over does
    // not make this phone send its posts over and over.
    final int t = _now();
    final String asker = '$groupId|$from';
    final int? last = _answeredAt[asker];
    if (last != null && t - last < _syncWindow) {
      return;
    }
    _answeredAt[asker] = t;
    final List<GroupBoardPost> missing = (await _locked(
      () => _board(groupId),
    )).missingFor(theirs, own);
    for (int i = 0; i < missing.length; i += kMaxBoardPutPosts) {
      await host.send(from, <String, dynamic>{
        'type': kGroupBoardPutType,
        'g': groupId,
        'ps': <Map<String, dynamic>>[
          for (final GroupBoardPost p
              in missing.skip(i).take(kMaxBoardPutPosts))
            p.toJson(),
        ],
      });
    }
  }
}
