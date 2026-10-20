import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/groups/group_board.dart';

/// The "Tablica" tab of a group: posts pinned to the group, newest first.
class GroupBoardView extends StatelessWidget {
  const GroupBoardView({
    required this.messages,
    required this.senderName,
    required this.canPost,
    super.key,
  });

  /// All group messages; the board picks its own posts.
  final List<ChatMessage> messages;

  /// Name to show for the author of a post.
  final String Function(ChatMessage message) senderName;

  final bool canPost;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<ChatMessage> posts = boardPostsOf(messages);
    if (posts.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: ZenEmpty(
            icon: Icons.push_pin_outlined,
            title: t('Tablica grupy jest pusta'),
            text: canPost
                ? t('Napisz post poniżej — zostanie przypięty dla całej grupy.')
                : t('Tu pojawią się posty przypięte do grupy.'),
          ),
        ),
      );
    }
    return ListView.builder(
      key: const Key('group-board-list'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      itemCount: posts.length,
      itemBuilder: (BuildContext context, int index) {
        final ChatMessage post = posts[index];
        final DateTime at = DateTime.fromMillisecondsSinceEpoch(
          post.sentAtMillis,
        );
        return Container(
          key: Key('group-board-post-${post.id}'),
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
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
                      post.isOutgoing ? t('Ty') : senderName(post),
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
                    ZenFormat.dateTime(at),
                    style: TextStyle(color: zen.textMuted, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              CopyableText(
                post.text,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 15,
                  height: 1.35,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
