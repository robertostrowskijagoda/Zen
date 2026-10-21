import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_model.dart';

// Collective notifications about reactions to your posts: not one
// per like, but "Bob i 3 inne osoby polubiły Twój post „…”". What was
// already seen is remembered per post (who liked, which comments), so the
// digest only speaks of what is new since the user last looked.

const String _seenKey = 'feed/seen_reactions';

/// What was already announced as a system notification, kept apart
/// from what the bell on the wall has shown.
const String kNotifiedReactionsKey = 'feed/notified_reactions';

/// Posts remembered at most (the newest ones).
const int _maxSeenPosts = 200;

/// New reactions to one of your posts.
@immutable
final class ReactionNotice {
  const ReactionNotice({
    required this.postId,
    required this.excerpt,
    required this.likers,
    required this.likes,
    required this.commenters,
    required this.comments,
    required this.millis,
  });

  final String postId;

  /// The beginning of the post ('' for a post with only photos).
  final String excerpt;

  /// Names of new likers, friends first.
  final List<String> likers;

  /// How many new likes.
  final int likes;

  /// Names of who wrote the new comments (each once).
  final List<String> commenters;

  /// How many new comments.
  final int comments;

  /// When the post was written (newest notices first).
  final int millis;
}

/// What was seen of each own post: liker accounts (or names when the
/// account is unknown) and comment ids.
final class ReactionsSeen {
  ReactionsSeen._(this._posts, {required bool fresh, required String key})
    : _fresh = fresh,
      _key = key;

  /// Nothing seen yet: the first digest takes everything as seen, so a
  /// new version does not announce old reactions.
  factory ReactionsSeen.empty({String key = _seenKey}) => ReactionsSeen._(
    <String, ({Set<String> likes, Set<String> comments})>{},
    fresh: true,
    key: key,
  );

  final String _key;

  final Map<String, ({Set<String> likes, Set<String> comments})> _posts;

  bool _fresh;

  /// Nothing marked as seen yet.
  bool get fresh => _fresh;

  /// The seen set kept under [key] (the bell's by default).
  static Future<ReactionsSeen> load(
    LedgerDisk disk, {
    String key = _seenKey,
  }) async {
    final Uint8List? raw = await disk.read(key);
    if (raw == null) {
      return ReactionsSeen.empty(key: key);
    }
    try {
      final Object? json = jsonDecode(utf8.decode(raw));
      if (json is! Map) {
        return ReactionsSeen.empty(key: key);
      }
      Set<String> strings(Object? v) => <String>{
        if (v is List)
          for (final Object? s in v)
            if (s is String) s,
      };
      return ReactionsSeen._(
        <String, ({Set<String> likes, Set<String> comments})>{
          for (final MapEntry<dynamic, dynamic> e in json.entries)
            if (e.key is String && e.value is Map)
              e.key as String: (
                likes: strings((e.value as Map<dynamic, dynamic>)['l']),
                comments: strings((e.value as Map<dynamic, dynamic>)['c']),
              ),
        },
        fresh: false,
        key: key,
      );
    } on FormatException {
      return ReactionsSeen.empty(key: key);
    }
  }

  Future<void> save(LedgerDisk disk) => disk.write(
    _key,
    Uint8List.fromList(
      utf8.encode(
        jsonEncode(<String, dynamic>{
          for (final MapEntry<
                String,
                ({Set<String> likes, Set<String> comments})
              >
              e
              in _posts.entries)
            e.key: <String, dynamic>{
              'l': e.value.likes.toList(),
              'c': e.value.comments.toList(),
            },
        }),
      ),
    ),
  );

  static String _likeKey(FeedLiker l) =>
      l.account.isNotEmpty ? l.account : 'n:${l.name}';

  /// The new reactions to [own] (your own posts), newest post first.
  List<ReactionNotice> noticesFor(List<FeedPost> own) {
    if (fresh) {
      return const <ReactionNotice>[];
    }
    final List<ReactionNotice> out = <ReactionNotice>[];
    for (final FeedPost p in own) {
      final ({Set<String> likes, Set<String> comments})? seen = _posts[p.id];
      final List<FeedLiker> newLikes = <FeedLiker>[
        for (final FeedLiker l in p.likes)
          if (l.account != _selfOf(p) &&
              !(seen?.likes.contains(_likeKey(l)) ?? false))
            l,
      ];
      final List<FeedComment> newComments = <FeedComment>[
        for (final FeedComment c in p.comments)
          if (!c.hiddenByAuthor &&
              c.account != _selfOf(p) &&
              !(seen?.comments.contains(c.id) ?? false))
            c,
      ];
      if (newLikes.isEmpty && newComments.isEmpty) {
        continue;
      }
      final String text = p.text.replaceAll(RegExp(r'\s+'), ' ').trim();
      out.add(
        ReactionNotice(
          postId: p.id,
          excerpt: text.length > 40 ? '${text.substring(0, 40)}…' : text,
          likers: <String>[for (final FeedLiker l in newLikes) l.name],
          likes: newLikes.length,
          commenters: <String>{
            for (final FeedComment c in newComments) c.authorLabel,
          }.toList(),
          comments: newComments.length,
          millis: p.millis,
        ),
      );
    }
    out.sort(
      (ReactionNotice a, ReactionNotice b) => b.millis.compareTo(a.millis),
    );
    return out;
  }

  /// Your own account as the author of [p] (your own like is no news).
  static String _selfOf(FeedPost p) => p.account;

  /// Marks everything on [own] as seen.
  void markSeen(List<FeedPost> own) {
    _fresh = false;
    final List<FeedPost> newest = List<FeedPost>.of(own)
      ..sort((FeedPost a, FeedPost b) => b.millis.compareTo(a.millis));
    _posts
      ..clear()
      ..addAll(<String, ({Set<String> likes, Set<String> comments})>{
        for (final FeedPost p in newest.take(_maxSeenPosts))
          p.id: (
            likes: <String>{for (final FeedLiker l in p.likes) _likeKey(l)},
            comments: <String>{for (final FeedComment c in p.comments) c.id},
          ),
      });
  }
}

/// "Bob i 3 inne osoby polubiły Twój post „Hej…”".
String noticeLikesText(ReactionNotice n) {
  if (n.likes <= 0) {
    return '';
  }
  final String post = n.excerpt.isEmpty
      ? t('Twój post')
      : t('Twój post „{text}”', {'text': n.excerpt});
  final String first = n.likers.isEmpty ? t('Ktoś') : n.likers.first;
  final int others = n.likes - 1;
  if (others <= 0) {
    return t('{name} polubił(a) {post}', {'name': first, 'post': post});
  }
  return tn(
    others,
    one: '{name} i {n} inna osoba polubili {post}',
    few: '{name} i {n} inne osoby polubili {post}',
    many: '{name} i {n} innych osób polubiło {post}',
    args: <String, Object?>{'name': first, 'post': post},
  );
}

/// "Kasia i Bob skomentowali Twój post „Hej…” (3 komentarze)".
String noticeCommentsText(ReactionNotice n) {
  if (n.comments <= 0) {
    return '';
  }
  final String post = n.excerpt.isEmpty
      ? t('Twój post')
      : t('Twój post „{text}”', {'text': n.excerpt});
  final String first = n.commenters.isEmpty ? t('Ktoś') : n.commenters.first;
  final int others = n.commenters.length - 1;
  if (others <= 0) {
    return tn(
      n.comments,
      one: '{name} skomentował(a) {post}',
      few: '{name} skomentował(a) {post} ({n} komentarze)',
      many: '{name} skomentował(a) {post} ({n} komentarzy)',
      args: <String, Object?>{'name': first, 'post': post},
    );
  }
  return tn(
    others,
    one: '{name} i {n} inna osoba skomentowali {post}',
    few: '{name} i {n} inne osoby skomentowali {post}',
    many: '{name} i {n} innych osób skomentowało {post}',
    args: <String, Object?>{'name': first, 'post': post},
  );
}
