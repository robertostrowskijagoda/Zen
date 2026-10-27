import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/presentation/mention_field.dart';

/// One entry of a message's long-press menu.
@immutable
final class ChatMenuItem {
  const ChatMenuItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.onSelected,
  });

  /// Also the menu entry's key: `bubble-<id>`.
  final String id;
  final IconData icon;
  final String label;
  final VoidCallback onSelected;
}

/// Shows [items] as a menu at [at] (a long press or a right click).
Future<void> showChatContextMenu(
  BuildContext context,
  Offset at,
  List<ChatMenuItem> items,
) async {
  if (items.isEmpty) {
    return;
  }
  final RenderBox overlay =
      Overlay.of(context).context.findRenderObject()! as RenderBox;
  final String? choice = await showMenu<String>(
    context: context,
    position: RelativeRect.fromRect(
      at & const Size(1, 1),
      Offset.zero & overlay.size,
    ),
    items: <PopupMenuEntry<String>>[
      for (final ChatMenuItem item in items)
        PopupMenuItem<String>(
          key: Key('bubble-${item.id}'),
          value: item.id,
          child: ListTile(
            dense: true,
            leading: Icon(item.icon),
            title: Text(item.label),
          ),
        ),
    ],
  );
  for (final ChatMenuItem item in items) {
    if (item.id == choice) {
      item.onSelected();
    }
  }
}

/// Text that can be copied from a long-press / right-click menu. Used for
/// chat bubbles and comments. With [onReport] the menu also has "Zgłoś"
/// — for what others wrote; [actions] come first (react, reply, …). The
/// tokens of [mentions] in [text] show as tappable names ([MentionText]);
/// a copy has "@name" in their place.
class CopyableText extends StatelessWidget {
  const CopyableText(
    this.text, {
    required this.style,
    this.onReport,
    this.actions = const <ChatMenuItem>[],
    this.mentions = const <Mention>[],
    this.mentionColor,
    super.key,
  });

  final String text;
  final TextStyle style;
  final VoidCallback? onReport;
  final List<ChatMenuItem> actions;
  final List<Mention> mentions;

  /// The colour of the mentions (the accent when `null`).
  final Color? mentionColor;

  Future<void> _menu(BuildContext context, Offset at) =>
      showChatContextMenu(context, at, <ChatMenuItem>[
        ...actions,
        ChatMenuItem(
          id: 'copy',
          icon: Icons.copy_rounded,
          label: t('Kopiuj'),
          // Like every other copy from the app: cleared from the clipboard
          // after a minute, unless something else was copied.
          onSelected: () =>
              unawaited(copyWithExpiry(mentionsAsPlainText(text, mentions))),
        ),
        if (onReport != null)
          ChatMenuItem(
            id: 'report',
            icon: Icons.flag_outlined,
            label: t('Zgłoś'),
            onSelected: onReport!,
          ),
      ]);

  @override
  Widget build(BuildContext context) => GestureDetector(
    onLongPressStart: (LongPressStartDetails d) =>
        unawaited(_menu(context, d.globalPosition)),
    onSecondaryTapDown: (TapDownDetails d) =>
        unawaited(_menu(context, d.globalPosition)),
    child: mentions.isEmpty
        ? Text(text, style: style)
        : MentionText(
            text,
            mentions: mentions,
            style: style,
            mentionColor: mentionColor,
          ),
  );
}
