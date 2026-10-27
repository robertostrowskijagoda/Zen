import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/presentation/mention_field.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The reactions offered first (any emoji fits).
const List<String> kQuickReactions = <String>[
  '❤️',
  '👍',
  '😂',
  '😮',
  '😢',
  '🙏',
  '🔥',
  '👏',
];

/// What a deleted message shows in its place.
String deletedMessageLabel() => t('Wiadomość usunięta');

/// The text a quote shows for [original] (or the stored snippet).
String replyQuoteText(ChatReply reply, ChatMessage? original) {
  if (original == null) {
    return reply.text.isEmpty ? t('Wiadomość niedostępna') : reply.text;
  }
  if (original.isDeleted) {
    return deletedMessageLabel();
  }
  final String text = original.type == ChatMessageType.text
      ? original.text
      : chatMessageLabelForType(
          original.type,
          fileName: original.fileName,
          mimeType: original.mimeType,
        );
  return clipChatSnippet(text);
}

/// The quote at the top of a reply; a tap jumps to the original.
class ChatReplyQuote extends StatelessWidget {
  const ChatReplyQuote({
    super.key,
    required this.reply,
    required this.senderLabel,
    this.original,
    this.onTap,
    this.onAccent = false,
  });

  final ChatReply reply;
  final ChatMessage? original;
  final String senderLabel;
  final VoidCallback? onTap;

  /// Drawn on the accent gradient of a bubble.
  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color ink = onAccent ? zen.onAccent : zen.textPrimary;
    final Color line = onAccent ? zen.onAccent : zen.accent;
    return Semantics(
      button: onTap != null,
      label: t('Odpowiedź na wiadomość: {name}', <String, Object?>{
        'name': senderLabel,
      }),
      child: InkWell(
        key: Key('reply-quote-${reply.messageId}'),
        onTap: onTap,
        borderRadius: context.zenRadius(10),
        child: Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
          decoration: BoxDecoration(
            color: ink.withValues(alpha: 0.08),
            borderRadius: context.zenRadius(10),
            border: BorderDirectional(start: BorderSide(color: line, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                senderLabel,
                style: TextStyle(
                  color: line,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                replyQuoteText(reply, original),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: ink.withValues(alpha: 0.8),
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// "Przekazano" above a forwarded message.
class ChatForwardedMarker extends StatelessWidget {
  const ChatForwardedMarker({super.key, this.onAccent = false});

  final bool onAccent;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color ink = (onAccent ? zen.onAccent : zen.textMuted).withValues(
      alpha: 0.85,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.shortcut_rounded, size: 14, color: ink),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              t('Przekazano'),
              style: TextStyle(
                color: ink,
                fontSize: 12,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The reactions under a message: one chip per emoji with how many; a tap
/// puts this person's own (or takes it back), a long press shows who.
class ChatReactionsBar extends StatelessWidget {
  const ChatReactionsBar({
    super.key,
    required this.reactions,
    required this.onToggle,
    required this.nameOf,
  });

  /// Who (`self` or an address) → emoji.
  final Map<String, String> reactions;
  final void Function(String emoji) onToggle;
  final String Function(String who) nameOf;

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final Map<String, int> counts = <String, int>{};
    for (final String emoji in reactions.values) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }
    final String? mine = reactions['self'];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: <Widget>[
          for (final MapEntry<String, int> e in counts.entries)
            Semantics(
              button: true,
              label: tn(
                e.value,
                one: '{emoji}: {n} osoba',
                few: '{emoji}: {n} osoby',
                many: '{emoji}: {n} osób',
                args: <String, Object?>{'emoji': e.key},
              ),
              child: InkWell(
                key: Key('reaction-chip-${e.key}'),
                borderRadius: context.zenRadius(14),
                onTap: () => onToggle(e.key),
                onLongPress: () => unawaited(
                  showReactionPeople(
                    context,
                    reactions: reactions,
                    nameOf: nameOf,
                  ),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: e.key == mine
                        ? zen.accent.withValues(alpha: 0.18)
                        : zen.surfaceRaised,
                    borderRadius: context.zenRadius(14),
                    border: Border.all(
                      color: e.key == mine ? zen.accent : zen.outlineSoft,
                    ),
                  ),
                  child: Text(
                    '${e.key} ${e.value}',
                    style: TextStyle(color: zen.textPrimary, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Who reacted with what.
Future<void> showReactionPeople(
  BuildContext context, {
  required Map<String, String> reactions,
  required String Function(String who) nameOf,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: ListView(
        key: const Key('reaction-people'),
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: Text(
              t('Reakcje'),
              style: Theme.of(sheetContext).textTheme.titleMedium,
            ),
          ),
          for (final MapEntry<String, String> e in reactions.entries)
            ListTile(
              leading: Text(e.value, style: const TextStyle(fontSize: 22)),
              title: Text(nameOf(e.key)),
            ),
        ],
      ),
    ),
  );
}

/// Picks a reaction; `null` when dismissed.
Future<String?> pickReaction(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            key: const Key('reaction-picker'),
            alignment: WrapAlignment.center,
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String emoji in kQuickReactions)
                IconButton(
                  key: Key('reaction-pick-$emoji'),
                  tooltip: emoji,
                  onPressed: () => Navigator.of(sheetContext).pop(emoji),
                  icon: Text(emoji, style: const TextStyle(fontSize: 26)),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// The new text of an edited message; `null` when cancelled. The tokens of
/// [mentions] in [current] are edited as "@name" and come back as tokens
/// pointing into the same list (an edit adds nobody).
Future<String?> showEditMessageDialog(
  BuildContext context,
  String current, {
  List<Mention> mentions = const <Mention>[],
}) {
  final MentionTextController controller = MentionTextController()
    ..setStoredText(current, mentions);
  return showDialog<String>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      scrollable: true,
      title: Text(t('Edytuj wiadomość')),
      content: TextField(
        key: const Key('edit-message-field'),
        controller: controller,
        autofocus: true,
        minLines: 1,
        maxLines: 6,
        enableIMEPersonalizedLearning: false,
        textCapitalization: TextCapitalization.sentences,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('edit-message-save'),
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(controller.storedText(keep: mentions).text),
          child: Text(t('Zapisz')),
        ),
      ],
    ),
  ).whenComplete(controller.dispose);
}

/// Asks before a message is deleted for everyone, saying honestly what
/// that can and cannot do.
Future<bool> confirmDeleteForEveryone(BuildContext context) async {
  final ZenColors zen = ZenColors.of(context);
  final bool? go = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(t('Usunąć u wszystkich?')),
      content: SingleChildScrollView(
        child: Text(
          t(
            'Wiadomość zniknie z tej rozmowy u Ciebie i u pozostałych, '
            'także na ich innych urządzeniach. Kto zdążył ją przeczytać, '
            'mógł ją zapamiętać, a zmieniona wersja aplikacji może zachować '
            'kopię.',
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('delete-for-everyone-confirm'),
          style: FilledButton.styleFrom(backgroundColor: zen.danger),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t('Usuń u wszystkich')),
        ),
      ],
    ),
  );
  return go == true;
}

/// Picks the chat to forward to: a friend's address or `group:<id>`.
Future<String?> pickForwardTarget(BuildContext context, SocialHubState hub) {
  final List<FriendProfile> friends = hub.acceptedFriends;
  final List<GroupProfile> groups = <GroupProfile>[
    for (final GroupProfile g in hub.groups.values)
      if (!g.isInvitePending) g,
  ];
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (BuildContext sheetContext) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
        ),
        child: ListView(
          key: const Key('forward-targets'),
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: 16),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(
                t('Przekaż do'),
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            for (final FriendProfile f in friends)
              ListTile(
                key: Key('forward-to-${f.address}'),
                leading: const Icon(Icons.person_outline_rounded),
                title: Text(f.displayLabel),
                onTap: () => Navigator.of(sheetContext).pop(f.address),
              ),
            for (final GroupProfile g in groups)
              ListTile(
                key: Key('forward-to-group:${g.id}'),
                leading: const Icon(Icons.groups_outlined),
                title: Text(g.name),
                onTap: () => Navigator.of(sheetContext).pop('group:${g.id}'),
              ),
          ],
        ),
      ),
    ),
  );
}

/// The long-press menu entries of [message] in [conversationKey]:
/// react, reply, edit (one's own, within a day), forward, delete for
/// everyone (one's own; any in a group one created).
List<ChatMenuItem> chatMessageActions(
  BuildContext context,
  WidgetRef ref, {
  required ChatMessage message,
  required String conversationKey,
  required VoidCallback onReply,
}) {
  if (message.isSystem || message.isDeleted) {
    return const <ChatMenuItem>[];
  }
  final SocialHubController hub = ref.read(
    socialHubControllerProvider.notifier,
  );
  void report(Object error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error is StateError ? error.message : '$error')),
      );
    }
  }

  return <ChatMenuItem>[
    ChatMenuItem(
      id: 'react',
      icon: Icons.add_reaction_outlined,
      label: t('Zareaguj'),
      onSelected: () => unawaited(() async {
        final String? emoji = await pickReaction(context);
        if (emoji != null) {
          await hub.reactToMessage(
            conversationKey: conversationKey,
            messageId: message.id,
            emoji: emoji,
          );
        }
      }()),
    ),
    ChatMenuItem(
      id: 'reply',
      icon: Icons.reply_rounded,
      label: t('Odpowiedz'),
      onSelected: onReply,
    ),
    if (hub.canEditMessage(message))
      ChatMenuItem(
        id: 'edit',
        icon: Icons.edit_outlined,
        label: t('Edytuj'),
        onSelected: () => unawaited(() async {
          final String? text = await showEditMessageDialog(
            context,
            message.text,
            mentions: message.mentions,
          );
          if (text != null) {
            await hub.editMessage(
              conversationKey: conversationKey,
              messageId: message.id,
              text: text,
            );
          }
        }()),
      ),
    if (hub.canForwardMessage(message))
      ChatMenuItem(
        id: 'forward',
        icon: Icons.shortcut_rounded,
        label: t('Przekaż'),
        onSelected: () => unawaited(() async {
          final String? target = await pickForwardTarget(
            context,
            ref.read(socialHubControllerProvider),
          );
          if (target == null) {
            return;
          }
          try {
            await hub.forwardMessage(
              fromKey: conversationKey,
              messageId: message.id,
              toKey: target,
            );
            if (context.mounted) {
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(t('Przekazano.'))));
            }
          } on Object catch (error) {
            report(error);
          }
        }()),
      ),
    if (hub.canDeleteForEveryone(conversationKey, message))
      ChatMenuItem(
        id: 'delete-all',
        icon: Icons.delete_outline_rounded,
        label: t('Usuń u wszystkich'),
        onSelected: () => unawaited(() async {
          if (await confirmDeleteForEveryone(context)) {
            await hub.deleteMessageForEveryone(
              conversationKey: conversationKey,
              messageId: message.id,
            );
          }
        }()),
      ),
  ];
}

/// "Odpowiadasz: …" over the composer, with a way to cancel.
class ChatReplyComposerBar extends StatelessWidget {
  const ChatReplyComposerBar({
    super.key,
    required this.reply,
    required this.senderLabel,
    required this.onCancel,
  });

  final ChatReply reply;
  final String senderLabel;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      key: const Key('reply-composer-bar'),
      margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: zen.surfaceRaised,
        borderRadius: context.zenRadius(14),
        border: BorderDirectional(
          start: BorderSide(color: zen.accent, width: 3),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.reply_rounded, size: 18, color: zen.accent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  t('Odpowiadasz: {name}', <String, Object?>{
                    'name': senderLabel,
                  }),
                  style: TextStyle(
                    color: zen.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (reply.text.isNotEmpty)
                  Text(
                    reply.text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
              ],
            ),
          ),
          IconButton(
            key: const Key('reply-composer-cancel'),
            tooltip: t('Anuluj odpowiedź'),
            onPressed: onCancel,
            icon: const Icon(Icons.close_rounded, size: 18),
          ),
        ],
      ),
    );
  }
}

/// The "edytowano" note next to the time of an edited message.
String editedMarker() => t('edytowano');
