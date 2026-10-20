import 'package:flutter/foundation.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The group board (§13): a space of posts that belongs to one group, apart
// from the group chat. Every member keeps the board of the group; a post
// is written by its author and goes to all members (`group_post`, a
// reliable frame, so members who are away get it from their relays). A
// member who joined later, or a new phone, asks the others what they have
// (`group_board_have`) and each answers with the posts it wrote itself
// (`group_board_put`): a post is only ever taken from its own author, so
// no member can put words in another's mouth. Its author may edit or
// remove a post; the group's creator may remove any post.

/// A new, edited or removed post, to every member (reliable).
const String kGroupPostType = 'group_post';

/// "These are the posts I have" (id → version), to the members.
const String kGroupBoardHaveType = 'group_board_have';

/// The answer to [kGroupBoardHaveType]: the asker's missing posts that the
/// one answering wrote.
const String kGroupBoardPutType = 'group_board_put';

/// Every frame of the group board.
const Set<String> kGroupBoardTypes = <String>{
  kGroupPostType,
  kGroupBoardHaveType,
  kGroupBoardPutType,
};

/// Longest post on the board.
const int kMaxBoardPostChars = 2000;

/// Posts (removed ones included) one board keeps; the oldest go first.
const int kMaxBoardPosts = 300;

/// New posts taken from one member of one group in an hour.
const int kMaxBoardPostsPerHour = 20;

/// Posts sent in one [kGroupBoardPutType] answer.
const int kMaxBoardPutPosts = 50;

/// Longest author name kept with a post.
const int _maxNameChars = 80;

final RegExp _postId = RegExp(r'^[0-9a-f]{8,32}$');

/// One post on a group board. [version] grows with every edit; the newest
/// version of a post wins everywhere.
@immutable
final class GroupBoardPost {
  const GroupBoardPost({
    required this.id,
    required this.author,
    required this.authorName,
    required this.text,
    required this.createdAt,
    required this.version,
    this.deleted = false,
  });

  /// A post as it travels or is stored, or `null` when anything is off.
  static GroupBoardPost? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? id = json['id'];
    final Object? author = json['a'];
    final Object? name = json['n'];
    final Object? text = json['x'];
    final Object? created = json['t'];
    final Object? version = json['v'];
    final bool deleted = json['d'] == true;
    if (id is! String ||
        !_postId.hasMatch(id) ||
        author is! String ||
        author.isEmpty ||
        author.length > 64 ||
        text is! String ||
        created is! int ||
        version is! int ||
        created <= 0 ||
        version < created) {
      return null;
    }
    final String body = text.trim();
    if (body.length > kMaxBoardPostChars || (!deleted && body.isEmpty)) {
      return null;
    }
    final String shown = name is String ? name.trim() : '';
    return GroupBoardPost(
      id: id,
      author: PeerShareCodec.normalizeAddress(author),
      authorName: shown.length > _maxNameChars
          ? shown.substring(0, _maxNameChars)
          : shown,
      text: deleted ? '' : body,
      createdAt: created,
      version: version,
      deleted: deleted,
    );
  }

  final String id;

  /// The author's address.
  final String author;

  /// The author's name as they gave it (shown when the app knows no
  /// better name for them).
  final String authorName;
  final String text;
  final int createdAt;
  final int version;

  /// Removed: kept only as a marker, so the post does not come back.
  final bool deleted;

  bool get edited => !deleted && version > createdAt;

  /// Whether this version replaces [other] (the same post).
  bool replaces(GroupBoardPost other) =>
      version > other.version ||
      (version == other.version && deleted && !other.deleted);

  GroupBoardPost copyWith({String? text, int? version, bool? deleted}) =>
      GroupBoardPost(
        id: id,
        author: author,
        authorName: authorName,
        text: text ?? this.text,
        createdAt: createdAt,
        version: version ?? this.version,
        deleted: deleted ?? this.deleted,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'a': author,
    if (authorName.isNotEmpty) 'n': authorName,
    'x': text,
    't': createdAt,
    'v': version,
    if (deleted) 'd': true,
  };
}

/// The posts of one board by id.
final class GroupBoard {
  GroupBoard([Map<String, GroupBoardPost>? posts])
    : posts = posts ?? <String, GroupBoardPost>{};

  final Map<String, GroupBoardPost> posts;

  /// Takes [post] when it is new or newer than the copy here; true when
  /// the board changed. Only [kMaxBoardPosts] posts stay (newest first).
  bool merge(GroupBoardPost post) {
    final GroupBoardPost? had = posts[post.id];
    if (had != null &&
        (!post.replaces(had) ||
            !PeerShareCodec.addressesEqual(had.author, post.author))) {
      return false;
    }
    posts[post.id] = post;
    if (posts.length > kMaxBoardPosts) {
      final List<GroupBoardPost> byAge = posts.values.toList()
        ..sort(
          (GroupBoardPost a, GroupBoardPost b) =>
              a.createdAt.compareTo(b.createdAt),
        );
      for (final GroupBoardPost old in byAge.take(
        posts.length - kMaxBoardPosts,
      )) {
        posts.remove(old.id);
      }
    }
    return posts[post.id] == post;
  }

  /// The posts to show: not removed, newest first.
  List<GroupBoardPost> get visible =>
      posts.values.where((GroupBoardPost p) => !p.deleted).toList()..sort(
        (GroupBoardPost a, GroupBoardPost b) =>
            b.createdAt.compareTo(a.createdAt),
      );

  /// What this board holds (id → version), for [kGroupBoardHaveType].
  Map<String, int> get versions => <String, int>{
    for (final GroupBoardPost p in posts.values) p.id: p.version,
  };

  /// Posts by [author] that [theirs] (someone's [versions]) lacks or has
  /// in an older version.
  List<GroupBoardPost> missingFor(Map<String, int> theirs, String author) =>
      <GroupBoardPost>[
        for (final GroupBoardPost p in posts.values)
          if (PeerShareCodec.addressesEqual(p.author, author) &&
              (theirs[p.id] ?? -1) < p.version)
            p,
      ];

  List<Map<String, dynamic>> toJson() => <Map<String, dynamic>>[
    for (final GroupBoardPost p in posts.values) p.toJson(),
  ];

  static GroupBoard fromJson(Object? json) {
    final GroupBoard board = GroupBoard();
    if (json is List) {
      for (final Object? item in json) {
        final GroupBoardPost? p = GroupBoardPost.fromJson(item);
        if (p != null) {
          board.merge(p);
        }
      }
    }
    return board;
  }
}
