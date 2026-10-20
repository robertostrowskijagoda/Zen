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
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The bell on the wall: new likes and comments under your own posts,
/// gathered per post ("Bob i 3 inne osoby polubili…", §11) instead of one
/// notification per like. Opening it marks everything as seen.
class ReactionNoticesButton extends ConsumerStatefulWidget {
  const ReactionNoticesButton({required this.node, super.key});

  final LedgerNode node;

  @override
  ConsumerState<ReactionNoticesButton> createState() =>
      _ReactionNoticesButtonState();
}

class _ReactionNoticesButtonState extends ConsumerState<ReactionNoticesButton> {
  ReactionsSeen? _seen;
  List<FeedPost> _own = const <FeedPost>[];
  List<ReactionNotice> _notices = const <ReactionNotice>[];
  StreamSubscription<void>? _changes;
  StreamSubscription<void>? _added;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _changes = widget.node.store.changed.listen((_) => _schedule());
    _added = widget.node.store.added.listen((_) => _schedule());
    unawaited(_start());
  }

  Future<void> _start() async {
    await widget.node.start();
    final ReactionsSeen seen = await ReactionsSeen.load(widget.node.disk);
    if (!mounted) {
      return;
    }
    _seen = seen;
    _refresh();
  }

  /// At most one new digest per frame, however many entries arrive.
  void _schedule() {
    if (_scheduled || !mounted) {
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

  String _nameOf(String address) {
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final FriendProfile? friend = social.friendByAddress(address);
    return friend == null ? address : social.nameFor(friend);
  }

  void _refresh() {
    final ReactionsSeen? seen = _seen;
    if (!mounted || seen == null || !widget.node.isReady) {
      return;
    }
    _own = <FeedPost>[
      for (final FeedPost p in buildFeed(widget.node, nameOf: _nameOf))
        if (p.isOwn && p.resharedBy.isEmpty) p,
    ];
    if (seen.fresh) {
      // First run: what is there now is not news.
      seen.markSeen(_own);
      unawaited(seen.save(widget.node.disk));
    }
    setState(() => _notices = seen.noticesFor(_own));
  }

  @override
  void dispose() {
    unawaited(_changes?.cancel());
    unawaited(_added?.cancel());
    super.dispose();
  }

  Future<void> _open() async {
    final List<ReactionNotice> notices = _notices;
    final ReactionsSeen? seen = _seen;
    if (seen != null) {
      seen.markSeen(_own);
      unawaited(seen.save(widget.node.disk));
      setState(() => _notices = const <ReactionNotice>[]);
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _NoticesSheet(notices: notices),
    );
  }

  @override
  Widget build(BuildContext context) {
    final int count = _notices.length;
    return IconButton(
      key: const Key('feed-notices'),
      tooltip: t('Reakcje na Twoje posty'),
      onPressed: () => unawaited(_open()),
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
  }
}

class _NoticesSheet extends StatelessWidget {
  const _NoticesSheet({required this.notices});

  final List<ReactionNotice> notices;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
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
        ],
      ),
    );
  }
}
