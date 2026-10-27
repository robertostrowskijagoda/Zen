import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_digest.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The new reactions under your own posts, kept for the bell on the wall and
/// the app's notification list. Opening either marks everything as seen.
class ReactionNoticesFeed extends ChangeNotifier {
  ReactionNoticesFeed({required this.node, required this.nameOf}) {
    _changes = node.store.changed.listen((_) => _schedule());
    _added = node.store.added.listen((_) => _schedule());
    unawaited(_start());
  }

  final LedgerNode node;
  final String Function(String address) nameOf;

  ReactionsSeen? _seen;
  List<FeedPost> _own = const <FeedPost>[];
  List<ReactionNotice> _notices = const <ReactionNotice>[];
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _added;
  bool _scheduled = false;
  bool _disposed = false;

  /// What is new since the last time the user looked, newest post first.
  List<ReactionNotice> get notices => _notices;

  Future<void> _start() async {
    await node.start();
    final ReactionsSeen seen = await ReactionsSeen.load(node.disk);
    if (_disposed) {
      return;
    }
    _seen = seen;
    _refresh();
  }

  /// At most one new digest per frame, however many entries arrive.
  void _schedule() {
    if (_scheduled || _disposed) {
      return;
    }
    _scheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _scheduled = false;
        _refresh();
      })
      ..scheduleFrame();
  }

  void _refresh() {
    final ReactionsSeen? seen = _seen;
    if (_disposed || seen == null || !node.isReady) {
      return;
    }
    _own = <FeedPost>[
      for (final FeedPost p in buildFeed(node, nameOf: nameOf))
        if (p.isOwn && p.resharedBy.isEmpty) p,
    ];
    if (seen.fresh) {
      // First run: what is there now is not news.
      seen.markSeen(_own);
      unawaited(seen.save(node.disk));
    }
    _notices = seen.noticesFor(_own);
    notifyListeners();
  }

  /// Marks everything as seen; returns what was new.
  List<ReactionNotice> markSeen() {
    final List<ReactionNotice> shown = _notices;
    final ReactionsSeen? seen = _seen;
    if (seen != null) {
      seen.markSeen(_own);
      unawaited(seen.save(node.disk));
      _notices = const <ReactionNotice>[];
      notifyListeners();
    }
    return shown;
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_changes?.cancel());
    unawaited(_added?.cancel());
    super.dispose();
  }
}

/// The feed of reactions to your own posts; `null` while the ledger is off.
final Provider<ReactionNoticesFeed?> reactionNoticesProvider =
    Provider<ReactionNoticesFeed?>((Ref ref) {
      final LedgerNode? node = ref.watch(ledgerNodeProvider);
      if (node == null) {
        return null;
      }
      final ReactionNoticesFeed feed = ReactionNoticesFeed(
        node: node,
        nameOf: (String address) {
          final SocialHubState social = ref.read(socialHubControllerProvider);
          final FriendProfile? friend = social.friendByAddress(address);
          return friend == null ? address : social.nameFor(friend);
        },
      );
      ref.onDispose(feed.dispose);
      return feed;
    });

/// The bell on the wall: new likes and comments under your own posts,
/// gathered per post ("Bob i 3 inne osoby polubili…") instead of one
/// notification per like. Opening it marks everything as seen. Its sheet
/// also holds the switch of the notifications about friends' new posts.
class ReactionNoticesButton extends ConsumerWidget {
  const ReactionNoticesButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ReactionNoticesFeed? feed = ref.watch(reactionNoticesProvider);
    if (feed == null) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: feed,
      builder: (BuildContext context, Widget? _) {
        final int count = feed.notices.length;
        return IconButton(
          key: const Key('feed-notices'),
          tooltip: t('Reakcje na Twoje posty'),
          onPressed: () => unawaited(_open(context, feed)),
          icon: Badge(
            isLabelVisible: count > 0,
            label: Text('$count'),
            child: Icon(
              count > 0
                  ? Icons.notifications_active_rounded
                  : Icons.notifications_none_rounded,
            ),
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context, ReactionNoticesFeed feed) async {
    final List<ReactionNotice> notices = feed.markSeen();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _NoticesSheet(notices: notices),
    );
  }
}

class _NoticesSheet extends ConsumerWidget {
  const _NoticesSheet({required this.notices});

  final List<ReactionNotice> notices;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final bool posts = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.postNotifications,
      ),
    );
    return SafeArea(
      child: ListView(
        key: const Key('feed-notices-sheet'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          Text(
            t('Reakcje na Twoje posty'),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          if (notices.isEmpty)
            ZenEmpty(
              icon: Icons.notifications_none_rounded,
              title: t('Nic nowego.'),
              text: t(
                'Gdy ktoś polubi lub skomentuje Twój post, zobaczysz to tutaj.',
              ),
            ),
          for (final ReactionNotice n in notices) ...<Widget>[
            if (n.likes > 0)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(Icons.favorite_rounded, color: zen.danger),
                title: Text(noticeLikesText(n)),
              ),
            if (n.comments > 0)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: Icon(Icons.mode_comment_rounded, color: zen.accent),
                title: Text(noticeCommentsText(n)),
              ),
          ],
          const Divider(height: 24),
          SwitchListTile(
            key: const Key('feed-post-notifications'),
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            secondary: Icon(Icons.article_outlined, color: zen.accent),
            title: Text(t('Powiadomienia o nowych postach znajomych')),
            subtitle: Text(
              t(
                'Jedną osobę wyciszysz w menu jej posta albo rozmowy. Posty '
                'znajomych znajomych nie powiadamiają.',
              ),
            ),
            value: posts,
            onChanged: (bool on) => unawaited(
              ref
                  .read(appSettingsControllerProvider.notifier)
                  .setPostNotifications(on),
            ),
          ),
        ],
      ),
    );
  }
}
