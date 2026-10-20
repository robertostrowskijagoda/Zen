import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// Keeps the last wall [buildFeed] made. It walks every log of every friend,
/// so the wall is built again only when something it reads may have changed:
/// the ledger or what is readable in it ([revision], which the caller bumps
/// on `store.changed`, `openedChanges` and newly checked reshares), the
/// friends and followed accounts, one of their names, or the language.
final class FeedMemo {
  List<FeedPost>? _posts;
  int _revision = -1;
  String _language = '';
  Map<String, String> _inputs = const <String, String>{};

  /// Others' posts on the wall (own posts are on the profile), newest first.
  List<FeedPost> wallOf(
    LedgerNode node, {
    required int revision,
    required String Function(String address) nameOf,
    ReshareCache? reshares,
  }) {
    final Map<String, String> inputs = <String, String>{
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
    final List<FeedPost> posts = List<FeedPost>.unmodifiable(<FeedPost>[
      for (final FeedPost p in buildFeed(
        node,
        nameOf: nameOf,
        reshares: reshares,
      ))
        if (!p.isOwn) p,
    ]);
    _posts = posts;
    _revision = revision;
    _language = ZenI18n.code;
    _inputs = inputs;
    return posts;
  }
}
