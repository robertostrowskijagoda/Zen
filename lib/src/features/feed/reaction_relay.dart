import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
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
const String kReactionsKind = 'rx';

/// Limits per bundle (it has to fit in one entry).
const int kMaxBundleLikers = 200;
const int kMaxBundleComments = 30;

/// One liker or comment as a bundle carries it.
typedef BundleLike = ({String account, String name});
typedef BundleComment = ({
  String id,
  String account,
  String name,
  String text,
  int millis,
});

/// Reactions to [postId] from one bundle entry, or `null` if malformed.
({List<BundleLike> likes, List<BundleComment> comments})? readBundle(
  LogEntry e,
) {
  if (e.kind != kReactionsKind) {
    return null;
  }
  final Object? likes = e.body['likes'];
  final Object? comments = e.body['comments'];
  if (likes is! List || comments is! List) {
    return null;
  }
  return (
    likes: <BundleLike>[
      for (final Object? l in likes.take(kMaxBundleLikers))
        if (l is Map && l['a'] is String && l['n'] is String)
          (account: l['a'] as String, name: l['n'] as String),
    ],
    comments: <BundleComment>[
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
    ],
  );
}

/// Newest bundle for each post in [acts].
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

String _nameFor(
  LedgerNode node,
  String address,
  String account,
  String Function(String address) nameOf,
) {
  final String own = latestProfile(node, account)?.name ?? '';
  return own.isNotEmpty ? own : nameOf(address);
}

/// Writes a fresh bundle for every post this account wrote or reshared
/// whose reactions changed. Returns how many bundles were written.
Future<int> relayReactions(
  LedgerNode node, {
  required String Function(String address) nameOf,
}) async {
  await node.start();
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
    return 0;
  }

  // The circle: this account and its friends, with the names they gave
  // themselves in their profiles.
  final String myName = latestProfile(node, node.account)?.name ?? '';
  final List<(String, String, List<LogEntry>)> circle =
      <(String, String, List<LogEntry>)>[
        (node.account, myName, node.entriesOf(spaceKind: 'acts')),
        for (final MapEntry<String, String> f in node.friendAccounts.entries)
          (
            f.value,
            _nameFor(node, f.key, f.value, nameOf),
            node.entriesOf(spaceKind: 'acts', ofAccount: f.value),
          ),
      ];
  final Map<String, LogEntry> myBundles = latestBundles(
    node.entriesOf(spaceKind: 'acts'),
  );

  int written = 0;
  for (final MapEntry<String, String> p in postsAuthor.entries) {
    final String postId = p.key;
    final Map<String, String> likes = <String, String>{};
    final Map<String, Map<String, dynamic>> comments =
        <String, Map<String, dynamic>>{};
    for (final (String, String, List<LogEntry>) member in circle) {
      if (likedPosts(member.$3).contains(postId)) {
        likes[member.$1] = member.$2;
      }
      for (final LogEntry e in member.$3) {
        final Object? text = e.body['text'];
        if (e.kind == kCommentKind &&
            e.body['post'] == postId &&
            text is String &&
            text.trim().isNotEmpty) {
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
    final String author = p.value;
    if (author != node.account) {
      final LogEntry? authors = latestBundles(
        node.entriesOf(spaceKind: 'acts', ofAccount: author),
      )[postId];
      final ({List<BundleLike> likes, List<BundleComment> comments})? bundle =
          authors == null ? null : readBundle(authors);
      if (bundle != null) {
        for (final BundleLike l in bundle.likes) {
          likes.putIfAbsent(l.account, () => l.name);
        }
        for (final BundleComment c in bundle.comments) {
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
    }
    final List<Map<String, dynamic>> sortedComments = comments.values.toList()
      ..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            (a['at'] as int).compareTo(b['at'] as int),
      );
    final Map<String, dynamic> body = <String, dynamic>{
      'post': postId,
      'likes': <Map<String, dynamic>>[
        for (final MapEntry<String, String> l
            in (likes.entries.toList()..sort(
                  (MapEntry<String, String> a, MapEntry<String, String> b) =>
                      a.key.compareTo(b.key),
                ))
                .take(kMaxBundleLikers))
          <String, dynamic>{'a': l.key, 'n': l.value},
      ],
      'comments': sortedComments.length > kMaxBundleComments
          ? sortedComments.sublist(sortedComments.length - kMaxBundleComments)
          : sortedComments,
    };
    final LogEntry? previous = myBundles[postId];
    if (previous == null
        ? (likes.isEmpty && comments.isEmpty)
        : canonicalJson(previous.body) == canonicalJson(body)) {
      continue;
    }
    try {
      await node.publish(kReactionsKind, body, spaceKind: 'acts');
      written++;
    } on ArgumentError {
      // Too big for one entry even after the limits: skip this round.
    }
  }
  return written;
}
