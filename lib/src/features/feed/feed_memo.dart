import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// Keeps the last wall [buildFeed] made. It walks every log of every friend,
/// so the wall is built again only when something it reads may have changed:
/// the ledger or what is readable in it ([revision], which the caller bumps
/// on `store.changed`, `openedChanges` and newly checked reshares), the
/// friends and followed accounts, one of their names, the pyramid's members,
/// or the language.
final class FeedMemo {
  List<FeedPost>? _posts;
  int _revision = -1;
  String _language = '';
  Map<String, String> _inputs = const <String, String>{};

  /// Others' posts on the wall (own posts are on the profile), newest first.
  /// Friends' posts older than the 12 months they are kept are left
  /// out; [nowMillis] is the clock (tests).
  List<FeedPost> wallOf(
    LedgerNode node, {
    required int revision,
    required String Function(String address) nameOf,
    ReshareCache? reshares,
    HeldPosts? held,
    Set<String> pyramidAddresses = const <String>{},
    int? nowMillis,
  }) {
    final Map<String, String> inputs = <String, String>{
      for (final String a in pyramidAddresses) 'p $a': '',
      for (final MapEntry<String, String> e in node.friendAccounts.entries)
        'f ${e.key}': '${e.value} ${nameOf(e.key)}',
      for (final MapEntry<String, String> e in node.followedAccounts.entries)
        'o ${e.key}': '${e.value} ${nameOf(e.key)}',
    };
    final List<FeedPost>? kept = _posts;
    if (kept != null &&
        _revision == revision &&
        _language == ZenI18n.code &&
        mapEquals(_inputs, inputs)) {
      return kept;
    }
    final int now = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final Set<String> friends = node.friendAccounts.values.toSet();
    final List<FeedPost> posts = List<FeedPost>.unmodifiable(<FeedPost>[
      for (final FeedPost p in buildFeed(
        node,
        nameOf: nameOf,
        reshares: reshares,
        held: held,
        pyramidAddresses: pyramidAddresses,
        nowMillis: now,
      ))
        if (!p.isOwn && keptOnWall(p, now, friends)) p,
    ]);
    _posts = posts;
    _revision = revision;
    _language = ZenI18n.code;
    _inputs = inputs;
    return posts;
  }
}
