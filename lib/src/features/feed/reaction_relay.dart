import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

/// Entry kind of a reaction bundle in the writer's `acts/<account>` space
/// (§11): the likes and comments a post got in the writer's circle, so they
/// reach people outside it along the reshare tree.
///
/// Who writes one: the author (for their own posts) and everyone who
/// reshared a post, who also passes on the author's bundle. Bundles never
/// contain other resharers' bundles, so nothing echoes back and taking a
/// like back reaches everyone with the next bundle.
///
/// A bundle is page 0: up to [kMaxBundleLikers] likes and the newest
/// [kMaxBundleComments] comments, exactly as older versions write and read
/// it. When there is more, page 0 also says how many there are in all
/// (`nl`, `nc`) and how many pages (`np`), and the rest follows in
/// [kReactionsPageKind] entries (older versions ignore them and show the
/// first page). The author's decisions about the thread (hidden comments,
/// blocked people: `thread_moderation.dart`) travel with page 0 as `hid`
/// and `blk`, so resharers further away can apply them to their circles.
const String kReactionsKind = 'rx';

/// Entry kind of a further page of a bundle (`pg` ≥ 1).
const String kReactionsPageKind = 'rxp';

/// Limits per bundle page (it has to fit in one entry).
const int kMaxBundleLikers = 200;
const int kMaxBundleComments = 30;

/// Pages per post at most (page 0 included): 2000 likes, 300 comments.
const int kMaxBundlePages = 10;

/// Most blocked accounts a bundle passes on.
const int _maxBundleBlocked = 200;

/// Entry kinds (besides likes, comments, bundles and reshares) after which
/// bundles are written again: removed posts (their tombstones travel to
/// friends of resharers), hidden comments, blocked people, further pages.
const Set<String> kReactionRelayExtraKinds = <String>{
  kPostDeleteKind,
  kReshareDeleteKind,
  kCommentHideKind,
  kThreadBlockKind,
  kReactionsPageKind,
};

/// One liker or comment as a bundle carries it.
typedef BundleLike = ({String account, String name});
typedef BundleComment = ({
  String id,
  String account,
  String name,
  String text,
  int millis,
});

List<BundleLike> _likesOf(Object? likes) => <BundleLike>[
  if (likes is List)
    for (final Object? l in likes.take(kMaxBundleLikers))
      if (l is Map && l['a'] is String && l['n'] is String)
        (account: l['a'] as String, name: l['n'] as String),
];

List<BundleComment> _commentsOf(Object? comments) => <BundleComment>[
  if (comments is List)
    for (final Object? c in comments.take(kMaxBundleComments))
      if (c is Map &&
          c['id'] is String &&
          c['a'] is String &&
          c['n'] is String &&
          c['t'] is String &&
          c['at'] is int)
        (
          id: c['id'] as String,
          account: c['a'] as String,
          name: c['n'] as String,
          text: (c['t'] as String).length > kMaxCommentChars
              ? (c['t'] as String).substring(0, kMaxCommentChars)
              : c['t'] as String,
          millis: c['at'] as int,
        ),
];

/// Reactions to [postId] from one bundle entry, or `null` if malformed.
({List<BundleLike> likes, List<BundleComment> comments})? readBundle(
  LogEntry e,
) {
  if (e.kind != kReactionsKind && e.kind != kReactionsPageKind) {
    return null;
  }
  final Object? likes = e.body['likes'];
  final Object? comments = e.body['comments'];
  if (likes is! List || comments is! List) {
    return null;
  }
  return (likes: _likesOf(likes), comments: _commentsOf(comments));
}

/// Newest bundle (page 0) for each post in [acts].
Map<String, LogEntry> latestBundles(Iterable<LogEntry> acts) {
  final Map<String, LogEntry> latest = <String, LogEntry>{};
  for (final LogEntry e in acts) {
    final Object? post = e.body['post'];
    if (e.kind != kReactionsKind || post is! String) {
      continue;
    }
    final LogEntry? had = latest[post];
    if (had == null || e.hlc > had.hlc) {
      latest[post] = e;
    }
  }
  return latest;
}

/// Newest further pages: post id → page number → entry.
Map<String, Map<int, LogEntry>> _latestPages(Iterable<LogEntry> acts) {
  final Map<String, Map<int, LogEntry>> latest = <String, Map<int, LogEntry>>{};
  for (final LogEntry e in acts) {
    final Object? post = e.body['post'];
    final Object? pg = e.body['pg'];
    if (e.kind != kReactionsPageKind ||
        post is! String ||
        pg is! int ||
        pg < 1 ||
        pg >= kMaxBundlePages) {
      continue;
    }
    final Map<int, LogEntry> pages = latest[post] ??= <int, LogEntry>{};
    final LogEntry? had = pages[pg];
    if (had == null || e.hlc > had.hlc) {
      pages[pg] = e;
    }
  }
  return latest;
}

/// Everything one writer's bundles say about one post (all pages).
@immutable
final class PostReactions {
  const PostReactions({
    required this.likes,
    required this.comments,
    required this.likeTotal,
    required this.commentTotal,
    this.moderation = ThreadModeration.none,
  });

  final List<BundleLike> likes;
  final List<BundleComment> comments;

  /// How many there are in all, as the writer knew (at least as many as
  /// listed).
  final int likeTotal;
  final int commentTotal;

  /// What the author decided about the thread, as passed on.
  final ThreadModeration moderation;
}

int _total(Object? n, int listed) =>
    n is int && n > listed && n < 100000000 ? n : listed;

/// The bundles in one writer's [acts], merged page by page: post id →
/// reactions.
Map<String, PostReactions> readBundles(Iterable<LogEntry> acts) {
  final List<LogEntry> list = acts is List<LogEntry> ? acts : acts.toList();
  final Map<String, Map<int, LogEntry>> pages = _latestPages(list);
  final Map<String, PostReactions> out = <String, PostReactions>{};
  for (final MapEntry<String, LogEntry> b in latestBundles(list).entries) {
    final ({List<BundleLike> likes, List<BundleComment> comments})? first =
        readBundle(b.value);
    if (first == null) {
      continue;
    }
    final Object? np = b.value.body['np'];
    final int count = np is int && np > 1 && np <= kMaxBundlePages ? np : 1;
    final Map<String, BundleLike> likes = <String, BundleLike>{
      for (final BundleLike l in first.likes) l.account: l,
    };
    final Map<String, BundleComment> comments = <String, BundleComment>{
      for (final BundleComment c in first.comments) c.id: c,
    };
    for (int pg = 1; pg < count; pg++) {
      final LogEntry? page = pages[b.key]?[pg];
      final ({List<BundleLike> likes, List<BundleComment> comments})? more =
          page == null ? null : readBundle(page);
      if (more == null) {
        continue;
      }
      for (final BundleLike l in more.likes) {
        likes.putIfAbsent(l.account, () => l);
      }
      for (final BundleComment c in more.comments) {
        comments.putIfAbsent(c.id, () => c);
      }
    }
    final Object? hid = b.value.body['hid'];
    final Object? blk = b.value.body['blk'];
    final ThreadModeration moderation = ThreadModeration(
      hidden: <String, Set<String>>{
        if (hid is List && hid.isNotEmpty)
          b.key: <String>{
            for (final Object? id in hid.take(1000))
              if (id is String) id,
          },
      },
      blocked: <String, String>{
        if (blk is List)
          for (final Object? a in blk.take(_maxBundleBlocked))
            if (a is String && a.isNotEmpty) a: '',
      },
    );
    final List<BundleComment> sorted = comments.values.toList()
      ..sort(
        (BundleComment x, BundleComment y) => x.millis.compareTo(y.millis),
      );
    out[b.key] = PostReactions(
      likes: likes.values.toList(),
      comments: sorted,
      likeTotal: _total(b.value.body['nl'], likes.length),
      commentTotal: _total(b.value.body['nc'], sorted.length),
      moderation: moderation,
    );
  }
  return out;
}

String _nameFor(
  LedgerNode node,
  String address,
  String account,
  String Function(String address) nameOf,
) {
  final String own = latestProfile(node, account)?.name ?? '';
  return own.isNotEmpty ? own : nameOf(address);
}

/// What [author] decided about the threads under their posts, as far as
/// this node can tell: their own signed entries (this account or a
/// friend), plus what their bundles passed on (for one post).
ThreadModeration authorModeration(
  LedgerNode node,
  String author, {
  ThreadModeration passedOn = ThreadModeration.none,
}) {
  final bool readable =
      author == node.account || node.friendAccounts.containsValue(author);
  final ThreadModeration own = readable
      ? threadModerationOf(
          node.entriesOf(
            spaceKind: 'acts',
            ofAccount: author == node.account ? null : author,
          ),
        )
      : ThreadModeration.none;
  return own.merge(passedOn);
}

/// Writes a fresh bundle for every post this account wrote or reshared
/// whose reactions changed, and passes on tombstones of reshared posts
/// (see [relayTombstones]). Returns how many entries were written.
Future<int> relayReactions(
  LedgerNode node, {
  required String Function(String address) nameOf,
}) async {
  await node.start();
  int written = await relayTombstones(node);
  // Posts to report on: own posts, and reshared ones with their author.
  final Map<String, String> postsAuthor = <String, String>{};
  for (final LogEntry e in node.entriesOf()) {
    if (e.kind == kPostKind) {
      postsAuthor[e.id] = node.account;
    } else if (e.kind == kReshareKind) {
      final LogEntry? original = LogEntry.fromJson(e.body['entry']);
      if (original != null) {
        postsAuthor[original.id] = original.account;
      }
    }
  }
  if (postsAuthor.isEmpty) {
    return written;
  }

  // The circle: this account and its friends, with the names they gave
  // themselves in their profiles.
  final String myName = latestProfile(node, node.account)?.name ?? '';
  final List<LogEntry> myActs = node.entriesOf(spaceKind: 'acts');
  final List<(String, String, List<LogEntry>)> circle =
      <(String, String, List<LogEntry>)>[
        (node.account, myName, myActs),
        for (final MapEntry<String, String> f in node.friendAccounts.entries)
          (
            f.value,
            _nameFor(node, f.key, f.value, nameOf),
            node.entriesOf(spaceKind: 'acts', ofAccount: f.value),
          ),
      ];
  final Map<String, LogEntry> myBundles = latestBundles(myActs);
  final Map<String, Map<int, LogEntry>> myPages = _latestPages(myActs);
  final Map<String, Map<String, PostReactions>> authorsBundles =
      <String, Map<String, PostReactions>>{};
  final Map<String, ThreadModeration> ownModeration =
      <String, ThreadModeration>{};

  for (final MapEntry<String, String> p in postsAuthor.entries) {
    final String postId = p.key;
    final String author = p.value;
    // What the author's own bundle says (resharers pass it on).
    final PostReactions? authors = author == node.account
        ? null
        : (authorsBundles[author] ??= readBundles(
            node.entriesOf(spaceKind: 'acts', ofAccount: author),
          ))[postId];
    final ThreadModeration mod = (ownModeration[author] ??= authorModeration(
      node,
      author,
    )).merge(authors?.moderation ?? ThreadModeration.none);
    final Map<String, String> likes = <String, String>{};
    final Map<String, Map<String, dynamic>> comments =
        <String, Map<String, dynamic>>{};
    for (final (String, String, List<LogEntry>) member in circle) {
      if (mod.blocks(member.$1)) {
        continue;
      }
      if (likedPosts(member.$3).contains(postId)) {
        likes[member.$1] = member.$2;
      }
      for (final LogEntry e in member.$3) {
        final Object? text = e.body['text'];
        if (e.kind == kCommentKind &&
            e.body['post'] == postId &&
            text is String &&
            text.trim().isNotEmpty &&
            !mod.hidesComment(postId, e.id)) {
          comments[e.id] = <String, dynamic>{
            'id': e.id,
            'a': member.$1,
            'n': member.$2,
            't': text,
            'at': e.hlc.millis,
          };
        }
      }
    }
    // Resharers also pass on what the author's circle said.
    if (authors != null) {
      for (final BundleLike l in authors.likes) {
        if (!mod.blocks(l.account)) {
          likes.putIfAbsent(l.account, () => l.name);
        }
      }
      for (final BundleComment c in authors.comments) {
        if (mod.blocks(c.account) || mod.hidesComment(postId, c.id)) {
          continue;
        }
        comments.putIfAbsent(
          c.id,
          () => <String, dynamic>{
            'id': c.id,
            'a': c.account,
            'n': c.name,
            't': c.text,
            'at': c.millis,
          },
        );
      }
    }
    final List<Map<String, dynamic>> likeList = <Map<String, dynamic>>[
      for (final MapEntry<String, String> l
          in likes.entries.toList()..sort(
            (MapEntry<String, String> a, MapEntry<String, String> b) =>
                a.key.compareTo(b.key),
          ))
        <String, dynamic>{'a': l.key, 'n': l.value},
    ];
    // Newest comments first into the pages (page 0 has the newest).
    final List<Map<String, dynamic>> newestFirst = comments.values.toList()
      ..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            (b['at'] as int).compareTo(a['at'] as int),
      );
    final int likePages = (likeList.length / kMaxBundleLikers).ceil();
    final int commentPages = (newestFirst.length / kMaxBundleComments).ceil();
    final int pageCount = math.min(
      kMaxBundlePages,
      math.max(1, math.max(likePages, commentPages)),
    );
    List<Map<String, dynamic>> likesOn(int page) =>
        likeList.skip(page * kMaxBundleLikers).take(kMaxBundleLikers).toList();
    List<Map<String, dynamic>> commentsOn(int page) =>
        newestFirst
            .skip(page * kMaxBundleComments)
            .take(kMaxBundleComments)
            .toList()
          ..sort(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                (a['at'] as int).compareTo(b['at'] as int),
          );
    final List<String> hidden = (mod.hidden[postId]?.toList() ?? <String>[])
      ..sort();
    final List<String> blocked = (mod.blocked.keys.toList()..sort())
        .take(_maxBundleBlocked)
        .toList();
    final Map<String, dynamic> body = <String, dynamic>{
      'post': postId,
      'likes': likesOn(0),
      'comments': commentsOn(0),
      if (likeList.length > kMaxBundleLikers) 'nl': likeList.length,
      if (newestFirst.length > kMaxBundleComments) 'nc': newestFirst.length,
      if (pageCount > 1) 'np': pageCount,
      if (hidden.isNotEmpty) 'hid': hidden,
      if (blocked.isNotEmpty) 'blk': blocked,
    };
    final LogEntry? previous = myBundles[postId];
    final bool nothing =
        likes.isEmpty && comments.isEmpty && hidden.isEmpty && blocked.isEmpty;
    if (previous == null
        ? nothing
        : canonicalJson(previous.body) == canonicalJson(body)) {
      continue;
    }
    try {
      await node.publish(kReactionsKind, body, spaceKind: 'acts');
      written++;
    } on ArgumentError {
      // Too big for one entry even after the limits: skip this round.
      continue;
    }
    for (int pg = 1; pg < pageCount; pg++) {
      final Map<String, dynamic> page = <String, dynamic>{
        'post': postId,
        'pg': pg,
        'likes': likesOn(pg),
        'comments': commentsOn(pg),
      };
      final LogEntry? had = myPages[postId]?[pg];
      if (had != null && canonicalJson(had.body) == canonicalJson(page)) {
        continue;
      }
      try {
        await node.publish(kReactionsPageKind, page, spaceKind: 'acts');
        written++;
      } on ArgumentError {
        // Too big: this page waits for the next round.
      }
    }
  }
  return written;
}

/// Passes on the author's tombstone of every post this account reshared
/// and the author removed (§10): a [kReshareDeleteKind] entry in this
/// account's feed carrying the signed `post_del`, so friends of this
/// account (who may not follow the author) hide the post too. The
/// tombstone comes from the author's feed, or from a friend who passed it
/// on. Returns how many were written.
Future<int> relayTombstones(LedgerNode node) async {
  await node.start();
  final Map<String, String> resharedAuthor = <String, String>{};
  final Set<String> passedOn = <String>{};
  for (final LogEntry e in node.entriesOf()) {
    if (e.kind == kReshareKind) {
      final LogEntry? original = LogEntry.fromJson(e.body['entry']);
      if (original != null) {
        resharedAuthor[original.id] = original.account;
      }
    } else if (e.kind == kReshareDeleteKind) {
      final Object? post = e.body['post'];
      if (post is String) {
        passedOn.add(post);
      }
    }
  }
  int written = 0;
  for (final MapEntry<String, String> r in resharedAuthor.entries) {
    if (passedOn.contains(r.key)) {
      continue;
    }
    final LogEntry? tomb = await _tombstoneFor(node, r.key, r.value);
    if (tomb == null) {
      continue;
    }
    await node.publish(kReshareDeleteKind, reshareDeleteBody(tomb));
    passedOn.add(r.key);
    written++;
  }
  return written;
}

Future<LogEntry?> _tombstoneFor(
  LedgerNode node,
  String postId,
  String author,
) async {
  if (author != node.account) {
    for (final LogEntry e in node.entriesOf(ofAccount: author)) {
      if (e.kind == kPostDeleteKind &&
          e.account == author &&
          e.body['post'] == postId) {
        return e;
      }
    }
  }
  for (final String friend in node.friendAccounts.values) {
    for (final LogEntry e in node.entriesOf(ofAccount: friend)) {
      if (e.kind != kReshareDeleteKind || e.body['post'] != postId) {
        continue;
      }
      final LogEntry? tomb = await unpackTombstone(e);
      if (tomb != null && tomb.account == author) {
        return tomb;
      }
    }
  }
  return null;
}
