import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/groups/group_board.dart';
import 'package:zen/src/features/groups/group_board_service.dart';

/// The "Tablica" tab of a group (§13): the group's own space of posts,
/// newest first. Authors edit and remove their posts; the group's creator
/// may remove any.
class GroupBoardView extends StatefulWidget {
  const GroupBoardView({
    required this.board,
    required this.groupId,
    required this.nameOf,
    required this.canPost,
    super.key,
  });

  final GroupBoardService board;
  final String groupId;

  /// Name to show for the author of [post].
  final String Function(GroupBoardPost post) nameOf;

  final bool canPost;

  @override
  State<GroupBoardView> createState() => _GroupBoardViewState();
}

class _GroupBoardViewState extends State<GroupBoardView> {
  @override
  void initState() {
    super.initState();
    unawaited(widget.board.open(widget.groupId));
  }

  Future<void> _edit(GroupBoardPost post) async {
    final TextEditingController text = TextEditingController(text: post.text);
    final String? changed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Edytuj post')),
        content: TextField(
          key: const Key('group-board-edit-field'),
          controller: text,
          minLines: 2,
          maxLines: 8,
          maxLength: kMaxBoardPostChars,
          textCapitalization: TextCapitalization.sentences,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('group-board-edit-save'),
            onPressed: () => Navigator.of(context).pop(text.text),
            child: Text(t('Zapisz')),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
    if (changed != null) {
      await widget.board.edit(widget.groupId, post.id, changed);
    }
  }

  Future<void> _remove(GroupBoardPost post) async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Usunąć post z tablicy?')),
        content: Text(t('Zniknie u wszystkich uczestników grupy.')),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('group-board-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      ),
    );
    if (ok == true) {
      await widget.board.remove(widget.groupId, post.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.board,
      builder: (BuildContext context, Widget? _) => _posts(context),
    );
  }

  Widget _posts(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<GroupBoardPost> posts = widget.board.postsOf(widget.groupId);
    if (posts.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: ZenEmpty(
            icon: Icons.push_pin_outlined,
            title: t('Tablica grupy jest pusta'),
            text: widget.canPost
                ? t('Napisz post poniżej — zobaczą go wszyscy w grupie.')
                : t('Tu pojawią się posty grupy.'),
          ),
        ),
      );
    }
    return ListView.builder(
      key: const Key('group-board-list'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: posts.length,
      itemBuilder: (BuildContext context, int index) {
        final GroupBoardPost post = posts[index];
        final bool own = widget.board.isOwn(post);
        final bool canRemove = widget.board.canRemove(widget.groupId, post);
        final DateTime at = DateTime.fromMillisecondsSinceEpoch(post.createdAt);
        return Container(
          key: Key('group-board-post-${post.id}'),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 8, 4, 12),
          decoration: BoxDecoration(
            color: zen.surfaceRaised,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: zen.outlineSoft),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.push_pin_rounded, size: 14, color: zen.accent),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      own ? t('Ty') : widget.nameOf(post),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: zen.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                  Text(
                    post.edited
                        ? t('{date} · edytowano', <String, Object?>{
                            'date': ZenFormat.dateTime(at),
                          })
                        : ZenFormat.dateTime(at),
                    style: TextStyle(color: zen.textMuted, fontSize: 12),
                  ),
                  if (own || canRemove)
                    PopupMenuButton<String>(
                      key: Key('group-board-menu-${post.id}'),
                      iconSize: 18,
                      onSelected: (String action) => unawaited(
                        action == 'edit' ? _edit(post) : _remove(post),
                      ),
                      itemBuilder: (BuildContext context) =>
                          <PopupMenuEntry<String>>[
                            if (own)
                              PopupMenuItem<String>(
                                value: 'edit',
                                child: Text(t('Edytuj')),
                              ),
                            if (canRemove)
                              PopupMenuItem<String>(
                                value: 'remove',
                                child: Text(t('Usuń')),
                              ),
                          ],
                    )
                  else
                    const SizedBox(width: 10),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: CopyableText(
                  post.text,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
