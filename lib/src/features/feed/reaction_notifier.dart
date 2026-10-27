import 'dart:async';

import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_digest.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

/// Id prefix of the system notifications about reactions. The title of such
/// a notification names who liked or commented, so with "Powiadomienia bez
/// treści" on it is replaced like the other revealing titles
/// (`PrivacyRedactingNotificationService.hidesTitle`).
const String kReactionNoticeIdPrefix = 'react-';

/// The collective notifications about reactions to your posts as
/// system notifications, not only on the bell of the wall: one per post,
/// "Cela i 3 inne osoby polubiły Twój post „…”", updated in place as more
/// reactions arrive. It reads the same digest as the bell, but keeps its own
/// record of what it announced, so neither takes news from the other.
///
/// Nothing is posted while the app is on screen ([shouldNotify] false): you
/// are looking at it, and what arrives then counts as announced.
final class ReactionSystemNotifier {
  ReactionSystemNotifier({
    required this.node,
    required this.nameOf,
    required this.notify,
    required this.shouldNotify,
    this.quiet = const Duration(seconds: 20),
    int Function()? now,
  }) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final LedgerNode node;
  final String Function(String address) nameOf;
  final Future<void> Function(RuntimeSystemNotification notification) notify;

  /// False while the app is in front.
  final bool Function() shouldNotify;

  /// Quiet time before a burst of reactions is announced.
  final Duration quiet;
  final int Function() _now;

  StreamSubscription<LogEntry>? _added;
  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  void start() {
    _added ??= node.store.added.listen((LogEntry e) {
      if (e.kind == kLikeKind ||
          e.kind == kCommentKind ||
          e.kind == kReactionsKind ||
          e.kind == kReactionsPageKind) {
        _schedule();
      }
    });
    _schedule();
  }

  void _schedule() {
    if (_disposed) {
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      quiet,
      () => unawaitedLogged(
        check(),
        context: 'Powiadomienia o reakcjach nie powiodły się',
      ),
    );
  }

  /// Announces what is new under your posts since the last time; returns how
  /// many notifications were posted.
  Future<int> check() async {
    if (_busy || _disposed) {
      return 0;
    }
    _busy = true;
    try {
      await node.start();
      if (!node.isReady || node.isSuspended) {
        return 0;
      }
      final ReactionsSeen seen = await ReactionsSeen.load(
        node.disk,
        key: kNotifiedReactionsKey,
      );
      final List<FeedPost> own = <FeedPost>[
        for (final FeedPost p in buildFeed(node, nameOf: nameOf))
          if (p.isOwn && p.resharedBy.isEmpty) p,
      ];
      // First run: what is there is not news. In front of the app: you see it.
      final bool announce = !seen.fresh && shouldNotify();
      final List<ReactionNotice> notices = announce
          ? seen.noticesFor(own)
          : const <ReactionNotice>[];
      for (final ReactionNotice n in notices) {
        await notify(reactionNotification(n, createdAtMillis: _now()));
      }
      seen.markSeen(own);
      await seen.save(node.disk);
      return notices.length;
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    unawaited(_added?.cancel());
    _added = null;
  }
}

/// The system notification for [n]: the title says what happened ("Cela
/// i 3 inne osoby polubiły Twój post „…”"), the body the comments when there
/// are both. One slot per post, so later reactions update it.
RuntimeSystemNotification reactionNotification(
  ReactionNotice n, {
  required int createdAtMillis,
}) {
  final String likes = noticeLikesText(n);
  final String comments = noticeCommentsText(n);
  return RuntimeSystemNotification(
    id: '$kReactionNoticeIdPrefix${n.postId}',
    title: likes.isNotEmpty ? likes : comments,
    body: likes.isNotEmpty && comments.isNotEmpty
        ? comments
        : t('Reakcje na Twoje posty'),
    createdAtMillis: createdAtMillis,
    category: RuntimeSystemNotificationCategory.social,
    slotKey: '$kReactionNoticeIdPrefix${n.postId}',
    // A tap opens the Tablica, where the post and its reactions are.
    routeKey: buildFeedRouteKey(FeedFilter.all.name),
  );
}
