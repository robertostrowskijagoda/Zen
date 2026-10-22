import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/feed/presentation/comment_composer.dart';
import 'package:zen/src/features/feed/presentation/comment_pictures.dart';
import 'package:zen/src/features/feed/presentation/reactor_avatar.dart';
import 'package:zen/src/features/feed/thread_moderation.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';

/// Who likes [post]: you and your friends first, then the others;
/// "i N innych osób" for those known only by number. With [node] a stranger
/// shows the photo of their mini-profile, and with [mutualFriends] (account
/// → how many friends you have in common) the line "N wspólnych znajomych".
Future<void> showPostLikers(
  BuildContext context,
  FeedPost post, {
  LedgerNode? node,
  int Function(String account)? mutualFriends,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (BuildContext context) =>
      _LikersSheet(post: post, node: node, mutualFriends: mutualFriends),
);

/// The line under the name of someone who is not your friend: how many
/// friends you share.
Widget? mutualFriendsLine(
  String account,
  int Function(String account)? mutualFriends, {
  Key? key,
}) {
  final String? text = mutualFriends == null
      ? null
      : mutualFriendsText(mutualFriends(account));
  if (text == null) {
    return null;
  }
  return Text(text, key: key, style: const TextStyle(fontSize: 12.5));
}

class _LikersSheet extends StatelessWidget {
  const _LikersSheet({required this.post, this.node, this.mutualFriends});

  final FeedPost post;
  final LedgerNode? node;
  final int Function(String account)? mutualFriends;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int unnamed = post.likeTotal - post.likes.length;
    return SafeArea(
      child: ListView(
        key: const Key('post-likers'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: <Widget>[
          Text(
            t('Polubili ({count})', {'count': post.likeTotal}),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          if (post.likeTotal == 0)
            ZenEmpty(
              icon: Icons.favorite_border_rounded,
              title: t('Jeszcze nikt.'),
            ),
          for (final FeedLiker l in post.likes)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: ReactorAvatar(
                node: node,
                avatar: l.avatar,
                name: l.name,
                size: 36,
              ),
              title: Text(l.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: l.friend
                  ? null
                  : mutualFriendsLine(
                      l.account,
                      mutualFriends,
                      key: Key('post-liker-mutual-${l.account}'),
                    ),
              trailing: l.friend
                  ? Icon(Icons.people_alt_rounded, size: 18, color: zen.accent)
                  : null,
            ),
          if (unnamed > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
              child: Text(
                tn(
                  unnamed,
                  one: '…i {n} inna osoba',
                  few: '…i {n} inne osoby',
                  many: '…i {n} innych osób',
                ),
                key: const Key('post-likers-more'),
                style: TextStyle(color: zen.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

/// The comments under [post], with a field to write one. Under your own
/// post you decide about the thread: hide a comment (only you still
/// see it) or block its author in all your threads.
Future<void> showPostComments(
  BuildContext context,
  LedgerNode node,
  FeedPost post, {
  VoidCallback? onChanged,
  int Function(String account)? mutualFriends,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (BuildContext context) => PostCommentsSheet(
    node: node,
    post: post,
    onChanged: onChanged,
    mutualFriends: mutualFriends,
  ),
);

class PostCommentsSheet extends StatefulWidget {
  const PostCommentsSheet({
    required this.node,
    required this.post,
    this.onChanged,
    this.mutualFriends,
    super.key,
  });

  final LedgerNode node;
  final FeedPost post;
  final VoidCallback? onChanged;

  /// Account → how many friends you have in common, for the line under
  /// the name of a commenter who is not your friend.
  final int Function(String account)? mutualFriends;

  @override
  State<PostCommentsSheet> createState() => _PostCommentsSheetState();
}

class _PostCommentsSheetState extends State<PostCommentsSheet> {
  String? _error;

  /// Own comments removed while the sheet is open.
  final Set<String> _removed = <String>{};

  /// Decisions made while the sheet is open (comment id → hidden).
  final Map<String, bool> _hidden = <String, bool>{};
  final Set<String> _blocked = <String>{};
  final List<FeedComment> _written = <FeedComment>[];

  bool get _mine => widget.post.account == widget.node.account;

  bool _isHidden(FeedComment c) => _hidden[c.id] ?? c.hiddenByAuthor;

  Future<void> _setHidden(FeedComment c, bool hide) async {
    try {
      await widget.node.publish(
        kCommentHideKind,
        commentHideBody(widget.post.id, c.id, on: hide),
        spaceKind: 'acts',
      );
      if (mounted) {
        setState(() => _hidden[c.id] = hide);
      }
      widget.onChanged?.call();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = t('Nie udało się: {error}', {'error': e}));
      }
    }
  }

  Future<void> _block(FeedComment c) async {
    final bool? sure = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(
          t('Zablokować w Twoich wątkach: {name}?', {'name': c.authorLabel}),
        ),
        content: Text(
          t(
            'Polubienia i komentarze tej osoby znikną spod wszystkich '
            'Twoich postów. Posty publiczne nadal może czytać.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('comment-block-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: Text(t('Zablokuj')),
          ),
        ],
      ),
    );
    if (!(sure ?? false)) {
      return;
    }
    try {
      await widget.node.publish(
        kThreadBlockKind,
        threadBlockBody(c.account, name: c.authorLabel),
        spaceKind: 'acts',
      );
      if (mounted) {
        setState(() => _blocked.add(c.account));
      }
      widget.onChanged?.call();
    } on Object catch (e) {
      if (mounted) {
        setState(() => _error = t('Nie udało się: {error}', {'error': e}));
      }
    }
  }

  Future<String?> _send(String text, List<CommentPicture> pictures) async {
    try {
      final LogEntry entry = await publishComment(
        widget.node,
        widget.post.id,
        text,
        pictures: pictures,
      );
      final FeedComment? mine = feedCommentFrom(
        entry,
        authorLabel: t('Ty'),
        account: widget.node.account,
      );
      if (mounted && mine != null) {
        setState(() {
          _error = null;
          _written.add(mine);
        });
      }
      widget.onChanged?.call();
      return null;
    } on ArgumentError catch (e) {
      return '${e.message}';
    } on Object catch (e) {
      return t('Nie udało się: {error}', {'error': e});
    }
  }

  Future<void> _delete(FeedComment c) async {
    final String? failed = await confirmDeleteComment(
      context,
      widget.node,
      widget.post.id,
      c,
    );
    if (!mounted || failed == '') {
      return;
    }
    setState(() {
      if (failed == null) {
        _removed.add(c.id);
      } else {
        _error = failed;
      }
    });
    if (failed == null) {
      widget.onChanged?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<FeedComment> comments = <FeedComment>[
      for (final FeedComment c in widget.post.comments)
        if (!_blocked.contains(c.account)) c,
      ..._written,
    ].where((FeedComment c) => !_removed.contains(c.id)).toList();
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        child: ListView(
          key: const Key('post-comments'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: <Widget>[
            Text(
              t('Komentarze ({count})', {'count': comments.length}),
              style: TextStyle(
                color: zen.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            if (comments.isEmpty)
              ZenEmpty(
                icon: Icons.forum_outlined,
                title: t('Jeszcze nic.'),
                text: t('Napisz pierwszy komentarz.'),
              ),
            for (final FeedComment c in comments)
              _CommentRow(
                comment: c,
                node: widget.node,
                mutual:
                    c.account.isEmpty ||
                        c.account == widget.node.account ||
                        widget.node.friendAccounts.containsValue(c.account)
                    ? null
                    : mutualFriendsLine(
                        c.account,
                        widget.mutualFriends,
                        key: Key('post-comment-mutual-${c.id}'),
                      ),
                hidden: _isHidden(c),
                onHide: _mine ? () => unawaited(_setHidden(c, true)) : null,
                onShow: _mine ? () => unawaited(_setHidden(c, false)) : null,
                onBlock:
                    _mine &&
                        c.account.isNotEmpty &&
                        c.account != widget.node.account
                    ? () => unawaited(_block(c))
                    : null,
                onDelete: canDeleteComment(widget.node, c)
                    ? () => unawaited(_delete(c))
                    : null,
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  _error!,
                  key: const Key('post-comment-error'),
                  style: TextStyle(color: zen.danger, fontSize: 12.5),
                ),
              ),
            const SizedBox(height: 6),
            CommentComposer(
              fieldKey: const Key('post-comment-field'),
              sendKey: const Key('post-comment-send'),
              onSend: _send,
            ),
          ],
        ),
      ),
    );
  }
}

class _CommentRow extends StatelessWidget {
  const _CommentRow({
    required this.comment,
    required this.node,
    required this.mutual,
    required this.hidden,
    this.onHide,
    this.onShow,
    this.onBlock,
    this.onDelete,
  });

  final FeedComment comment;
  final LedgerNode node;

  /// "N wspólnych znajomych" under the name, for someone who is not a
  /// friend.
  final Widget? mutual;
  final bool hidden;
  final VoidCallback? onHide;
  final VoidCallback? onShow;
  final VoidCallback? onBlock;

  /// Removes this account's own comment.
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool canModerate =
        onHide != null || onBlock != null || onDelete != null;
    return Opacity(
      key: Key('post-comment-${comment.id}'),
      opacity: hidden ? 0.55 : 1,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ReactorAvatar(
              node: node,
              avatar: comment.avatar,
              name: comment.authorLabel,
              size: 34,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(
                  color: zen.surfaceMuted,
                  borderRadius: ZenLook.of(
                    context,
                  ).bubbleRadius(outgoing: false),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      comment.authorLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                    if (mutual != null)
                      DefaultTextStyle.merge(
                        style: TextStyle(color: zen.textMuted),
                        child: mutual!,
                      ),
                    const SizedBox(height: 3),
                    if (comment.text.trim().isNotEmpty)
                      SelectableText(
                        comment.text,
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: zen.textPrimary,
                        ),
                      ),
                    CommentPictures(node: node, comment: comment),
                    if (hidden) ...<Widget>[
                      const SizedBox(height: 4),
                      Text(
                        t('Ukryty — widzisz go tylko Ty.'),
                        key: Key('post-comment-hidden-${comment.id}'),
                        style: TextStyle(
                          color: zen.textMuted,
                          fontSize: 12,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (canModerate)
              PopupMenuButton<String>(
                key: Key('post-comment-menu-${comment.id}'),
                tooltip: t('Więcej'),
                icon: Icon(Icons.more_vert_rounded, color: zen.textSecondary),
                onSelected: (String v) => (switch (v) {
                  'hide' => onHide,
                  'show' => onShow,
                  'delete' => onDelete,
                  _ => onBlock,
                })?.call(),
                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                  if (!hidden && onHide != null)
                    PopupMenuItem<String>(
                      key: const Key('post-comment-hide'),
                      value: 'hide',
                      child: ListTile(
                        leading: const Icon(Icons.visibility_off_outlined),
                        title: Text(t('Ukryj komentarz')),
                      ),
                    ),
                  if (hidden && onShow != null)
                    PopupMenuItem<String>(
                      key: const Key('post-comment-show'),
                      value: 'show',
                      child: ListTile(
                        leading: const Icon(Icons.visibility_outlined),
                        title: Text(t('Pokaż komentarz')),
                      ),
                    ),
                  if (onDelete != null)
                    PopupMenuItem<String>(
                      key: const Key('post-comment-delete'),
                      value: 'delete',
                      child: ListTile(
                        leading: const Icon(Icons.delete_outline_rounded),
                        title: Text(t('Usuń komentarz')),
                      ),
                    ),
                  if (onBlock != null)
                    PopupMenuItem<String>(
                      key: const Key('post-comment-block'),
                      value: 'block',
                      child: ListTile(
                        leading: const Icon(Icons.block_rounded),
                        title: Text(t('Zablokuj w moich wątkach')),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
