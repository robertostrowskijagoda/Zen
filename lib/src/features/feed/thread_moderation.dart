import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/log_entry.dart';

// The author's say over the threads under their posts: hiding a
// comment and blocking a person (their likes and comments disappear from
// all of the author's posts). Signed entries in the author's own `acts`
// space; the latest entry for a comment or a person wins, so both can be
// undone. Friends of the author read them directly; everyone further away
// gets them with the author's reaction bundles (`reaction_relay.dart`).
//
// The author cannot stop anyone from reading public posts: a block
// only takes the person's reactions out of the author's threads.

/// Entry kind: hide (or show again) one comment under the author's post.
const String kCommentHideKind = 'comment_hide';

/// Entry kind: block (or unblock) a person in all of the author's threads.
const String kThreadBlockKind = 'thread_block';

const int _maxBlockName = 60;

/// Body of hiding comment [commentId] under [postId] (or, with [on] false,
/// showing it again).
Map<String, dynamic> commentHideBody(
  String postId,
  String commentId, {
  bool on = true,
}) => <String, dynamic>{'post': postId, 'c': commentId, 'on': on ? 1 : 0};

/// Body of blocking [account] in the author's threads ([name] is how the
/// author saw them, for the list of blocked people).
Map<String, dynamic> threadBlockBody(
  String account, {
  String name = '',
  bool on = true,
}) => <String, dynamic>{
  'a': account,
  if (name.trim().isNotEmpty)
    'n': name.trim().length > _maxBlockName
        ? name.trim().substring(0, _maxBlockName)
        : name.trim(),
  'on': on ? 1 : 0,
};

/// What an author decided about their threads.
@immutable
final class ThreadModeration {
  const ThreadModeration({
    this.hidden = const <String, Set<String>>{},
    this.blocked = const <String, String>{},
  });

  static const ThreadModeration none = ThreadModeration();

  /// Post id → ids of the comments hidden under it.
  final Map<String, Set<String>> hidden;

  /// Blocked account → the name the author knew them by.
  final Map<String, String> blocked;

  bool get isEmpty => hidden.isEmpty && blocked.isEmpty;

  bool hidesComment(String postId, String commentId) =>
      hidden[postId]?.contains(commentId) ?? false;

  bool blocks(String account) => blocked.containsKey(account);

  /// This and [other] together (bundles add to what the author's own
  /// entries say).
  ThreadModeration merge(ThreadModeration other) {
    if (other.isEmpty) {
      return this;
    }
    if (isEmpty) {
      return other;
    }
    return ThreadModeration(
      hidden: <String, Set<String>>{
        for (final String post in <String>{
          ...hidden.keys,
          ...other.hidden.keys,
        })
          post: <String>{...?hidden[post], ...?other.hidden[post]},
      },
      blocked: <String, String>{...other.blocked, ...blocked},
    );
  }
}

/// The moderation in one author's [acts] (the latest entry per comment
/// and per person wins).
ThreadModeration threadModerationOf(Iterable<LogEntry> acts) {
  final Map<String, (int, bool, String)> comments =
      <String, (int, bool, String)>{};
  final Map<String, (int, bool, String)> people =
      <String, (int, bool, String)>{};
  for (final LogEntry e in acts) {
    final int at = e.hlc.toInt();
    final bool on = e.body['on'] == 1;
    if (e.kind == kCommentHideKind) {
      final Object? post = e.body['post'];
      final Object? c = e.body['c'];
      if (post is! String || c is! String) {
        continue;
      }
      final String key = '$post\n$c';
      final (int, bool, String)? had = comments[key];
      if (had == null || at >= had.$1) {
        comments[key] = (at, on, '');
      }
    } else if (e.kind == kThreadBlockKind) {
      final Object? a = e.body['a'];
      if (a is! String || a.isEmpty) {
        continue;
      }
      final Object? n = e.body['n'];
      final (int, bool, String)? had = people[a];
      if (had == null || at >= had.$1) {
        people[a] = (at, on, n is String ? n : '');
      }
    }
  }
  if (comments.isEmpty && people.isEmpty) {
    return ThreadModeration.none;
  }
  final Map<String, Set<String>> hidden = <String, Set<String>>{};
  for (final MapEntry<String, (int, bool, String)> c in comments.entries) {
    if (c.value.$2) {
      final int cut = c.key.indexOf('\n');
      (hidden[c.key.substring(0, cut)] ??= <String>{}).add(
        c.key.substring(cut + 1),
      );
    }
  }
  return ThreadModeration(
    hidden: hidden,
    blocked: <String, String>{
      for (final MapEntry<String, (int, bool, String)> p in people.entries)
        if (p.value.$2) p.key: p.value.$3,
    },
  );
}
