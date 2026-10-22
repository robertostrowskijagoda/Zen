import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/groups/group_board.dart';
import 'package:zen/src/features/groups/group_board_service.dart';
import 'package:zen/src/features/media/media_guard.dart';

/// The "Tablica" tab of a group: the group's own space of posts,
/// newest first. Authors edit and remove their posts; the group's creator
/// may remove any.
class GroupBoardView extends StatefulWidget {
  const GroupBoardView({
    required this.board,
    required this.groupId,
    required this.nameOf,
    required this.canPost,
    this.blocks,
    this.sourcesOf,
    super.key,
  });

  final GroupBoardService board;
  final String groupId;

  /// Name to show for the author of [post].
  final String Function(GroupBoardPost post) nameOf;

  final bool canPost;

  /// Where posts' photos are fetched from (`null`: not running yet).
  final ChatMediaBlocks? blocks;

  /// Who may have the photo of a post: its author first, then the members.
  final List<String> Function(GroupBoardPost post)? sourcesOf;

  @override
  State<GroupBoardView> createState() => _GroupBoardViewState();
}

class _GroupBoardViewState extends State<GroupBoardView> {
  /// Photos being fetched or fetched (by reference id), for this view.
  final Map<String, Future<Uint8List?>> _photos =
      <String, Future<Uint8List?>>{};

  Future<Uint8List?> _photoOf(GroupBoardPost post) {
    final Map<String, dynamic> media = post.media!;
    final String id = media['id'] as String;
    return _photos.putIfAbsent(id, () async {
      final Uint8List? bytes = await _fetchPhoto(post, media);
      if (bytes == null) {
        // Tried again the next time the post is drawn anew.
        _photos.remove(id);
      }
      return bytes;
    });
  }

  Future<Uint8List?> _fetchPhoto(
    GroupBoardPost post,
    Map<String, dynamic> media,
  ) async {
    final ChatMediaBlocks? blocks = widget.blocks;
    if (blocks == null) {
      return null;
    }
    try {
      final Uint8List? bytes = await blocks.fetch(
        media,
        widget.sourcesOf?.call(post) ?? <String>[post.author],
        timeout: const Duration(minutes: 2),
      );
      if (bytes == null || bytes.length > kMaxBoardPhotoBytes) {
        return null;
      }
      // Shown only when it really is a picture (re-encoded, no metadata).
      final GuardedMedia guarded = await guardIncomingMedia(
        bytes,
        declared: MediaKind.image,
        mimeType: media['mime'] is String ? media['mime'] as String : null,
      );
      return guarded.kind == MediaKind.image ? guarded.bytes : null;
    } on Object {
      return null;
    }
  }

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
            borderRadius: context.zenRadius(18),
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
              if (post.media != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(0, 6, 10, 4),
                  child: _BoardPhoto(
                    key: Key('group-board-photo-${post.id}'),
                    bytes: _photoOf(post),
                  ),
                ),
              if (post.text.isNotEmpty)
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

/// A post's photo: a placeholder while it comes, a note when it cannot.
class _BoardPhoto extends StatelessWidget {
  const _BoardPhoto({required this.bytes, super.key});

  final Future<Uint8List?> bytes;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return FutureBuilder<Uint8List?>(
      future: bytes,
      builder: (BuildContext context, AsyncSnapshot<Uint8List?> snapshot) {
        final Uint8List? data = snapshot.data;
        if (data != null) {
          return ClipRRect(
            borderRadius: context.zenRadius(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 360),
              child: Image.memory(
                data,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                semanticLabel: t('Zdjęcie'),
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    _note(zen, t('Nie udało się otworzyć zdjęcia.')),
              ),
            ),
          );
        }
        if (snapshot.connectionState != ConnectionState.done) {
          return SizedBox(
            height: 120,
            child: Center(
              child: SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: zen.accent,
                ),
              ),
            ),
          );
        }
        return _note(zen, t('Zdjęcie jeszcze nie dotarło.'));
      },
    );
  }

  Widget _note(ZenColors zen, String text) => Row(
    children: <Widget>[
      Icon(Icons.image_not_supported_outlined, size: 18, color: zen.textMuted),
      const SizedBox(width: 6),
      Expanded(
        child: Text(text, style: TextStyle(color: zen.textMuted)),
      ),
    ],
  );
}
