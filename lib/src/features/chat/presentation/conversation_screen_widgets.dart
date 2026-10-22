part of 'conversation_screen.dart';

enum _CaptureOption { photo, video, gallery, audio }

enum _ConversationMenuAction {
  acceptRequest,
  rejectRequest,
  cancelRequest,
  setNickname,
  retentionSettings,
  disappearingMessages,
  blockFriend,
  removeFriend,
  unblockFriend,
  clearHistory,
  reportPerson,
}

String _conversationSubtitle({
  required FriendProfile? friend,
  required String peerAddress,
}) {
  return _conversationRelationshipStatusLabel(friend) ?? '';
}

String? _conversationRelationshipStatusLabel(FriendProfile? friend) {
  return switch (friend?.status) {
    FriendRelationshipStatus.pendingIncoming => t('Zaproszenie oczekuje'),
    FriendRelationshipStatus.pendingOutgoing => t('Czekasz na akceptację'),
    FriendRelationshipStatus.blocked => t('Relacja zablokowana'),
    FriendRelationshipStatus.none => null,
    // No relationship at all (a chat opened from a link, for one): say so,
    // so nothing on screen passes them off as someone the user knows.
    null => t('Nieznajomy'),
    FriendRelationshipStatus.accepted =>
      friend?.isOnline == true ? t('Aktywny teraz') : t('Offline'),
  };
}

bool _isSameDay(int aMillis, int bMillis) {
  final DateTime a = DateTime.fromMillisecondsSinceEpoch(aMillis);
  final DateTime b = DateTime.fromMillisecondsSinceEpoch(bMillis);
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Date separator between message days: a small centred pill ("Dziś",
/// "Wczoraj", "12.03.2025").
class _DaySeparator extends StatelessWidget {
  const _DaySeparator({super.key, required this.millis});

  final int millis;

  String _label() {
    final DateTime date = DateTime.fromMillisecondsSinceEpoch(millis);
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime day = DateTime(date.year, date.month, date.day);
    final int diff = today.difference(day).inDays;
    if (diff == 0) {
      return t('Dziś');
    }
    if (diff == 1) {
      return t('Wczoraj');
    }
    return ZenFormat.date(date);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 14),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: zen.surfaceRaised.withValues(alpha: 0.85),
            borderRadius: context.zenRadius(999),
            border: Border.all(color: zen.outlineSoft),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Text(
              _label(),
              style: TextStyle(
                color: zen.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  const _TypingBubble({super.key, required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: zen.surfaceRaised,
          borderRadius: ZenLook.of(context).bubbleRadius(outgoing: false),
          border: Border.all(color: zen.outlineSoft),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  t('{name} pisze', {'name': name}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ZenAnimatedDots(color: zen.accent, size: 4),
            ],
          ),
        ),
      ),
    );
  }
}

List<PopupMenuEntry<_ConversationMenuAction>> _conversationMenuItems({
  required FriendProfile? friend,
  required bool hasMessages,
  required int messageCount,
  int disappearSeconds = 0,
}) {
  final List<PopupMenuEntry<_ConversationMenuAction>> items =
      <PopupMenuEntry<_ConversationMenuAction>>[];
  final String? statusLabel = _conversationRelationshipStatusLabel(friend);
  if (statusLabel != null) {
    items.add(
      PopupMenuItem<_ConversationMenuAction>(
        enabled: false,
        child: Text(t('Status: {status}', {'status': statusLabel})),
      ),
    );
  }
  if (friend?.status == FriendRelationshipStatus.accepted) {
    items.add(
      PopupMenuItem<_ConversationMenuAction>(
        enabled: false,
        child: Text(
          t('Retencja: {cleanup} • Limit: {limit}', <String, Object?>{
            'cleanup': _cleanupSummary(friend!),
            'limit': _storageLimitSummary(friend),
          }),
        ),
      ),
    );
  }
  if (messageCount > 0) {
    items.add(
      PopupMenuItem<_ConversationMenuAction>(
        enabled: false,
        child: Text(t('Wpisy w rozmowie: {count}', {'count': messageCount})),
      ),
    );
  }
  if (items.isNotEmpty) {
    items.add(const PopupMenuDivider());
  }
  switch (friend?.status) {
    case FriendRelationshipStatus.pendingIncoming:
      items.addAll(<PopupMenuEntry<_ConversationMenuAction>>[
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.acceptRequest,
          child: Text(t('Akceptuj')),
        ),
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.rejectRequest,
          child: Text(t('Odrzuc')),
        ),
      ]);
      break;
    case FriendRelationshipStatus.pendingOutgoing:
      items.add(
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.cancelRequest,
          child: Text(t('Anuluj zaproszenie')),
        ),
      );
      break;
    case FriendRelationshipStatus.accepted:
      items.addAll(<PopupMenuEntry<_ConversationMenuAction>>[
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.setNickname,
          child: Text(t('Pseudonim')),
        ),
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.retentionSettings,
          child: Text(t('Retencja rozmowy')),
        ),
        PopupMenuItem<_ConversationMenuAction>(
          key: const Key('conversation-disappearing-menu'),
          value: _ConversationMenuAction.disappearingMessages,
          child: Text(
            t('Znikające wiadomości: {label}', {
              'label': disappearLabel(disappearSeconds),
            }),
          ),
        ),
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.blockFriend,
          child: Text(t('Zablokuj')),
        ),
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.removeFriend,
          child: Text(t('Usuń znajomego')),
        ),
      ]);
      break;
    case FriendRelationshipStatus.blocked:
      items.add(
        PopupMenuItem<_ConversationMenuAction>(
          value: _ConversationMenuAction.unblockFriend,
          child: Text(t('Odblokuj')),
        ),
      );
      break;
    case FriendRelationshipStatus.none:
    case null:
      break;
  }
  if (hasMessages) {
    if (items.isNotEmpty) {
      items.add(const PopupMenuDivider());
    }
    items.add(
      PopupMenuItem<_ConversationMenuAction>(
        value: _ConversationMenuAction.clearHistory,
        child: Text(t('Wyczyść historię')),
      ),
    );
  }
  // Last, so the everyday actions keep their places.
  if (items.isNotEmpty) {
    items.add(const PopupMenuDivider());
  }
  items.add(
    PopupMenuItem<_ConversationMenuAction>(
      key: const Key('conversation-menu-report'),
      value: _ConversationMenuAction.reportPerson,
      child: Text(t('Zgłoś osobę')),
    ),
  );
  if (items.isEmpty) {
    items.add(
      PopupMenuItem<_ConversationMenuAction>(
        enabled: false,
        child: Text(t('Brak akcji')),
      ),
    );
  }
  return items;
}

/// The file of a chat message as its bubble shows it (photo, GIF, film,
/// voice message, file; a placeholder while it is still coming), for
/// group chats too.
class ChatAttachmentBody extends StatelessWidget {
  const ChatAttachmentBody({super.key, required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) => switch (message.type) {
    _ when !message.hasAttachment => _AttachmentStubContent(message: message),
    ChatMessageType.image => _ImageAttachmentContent(message: message),
    ChatMessageType.voice => _VoiceAttachmentContent(message: message),
    ChatMessageType.video => _VideoAttachmentContent(message: message),
    _ => _FileAttachmentContent(message: message),
  };
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.conversationKey,
    this.entranceDelay,
    this.onReport,
    this.actions = const <ChatMenuItem>[],
    this.replyOriginal,
    this.replySenderLabel = '',
    this.onJumpToReply,
    this.onToggleReaction,
    this.nameOf,
    this.highlighted = false,
  });

  final ChatMessage message;

  /// The long-press menu's own entries (react, reply, edit, forward,
  /// delete for everyone).
  final List<ChatMenuItem> actions;

  /// The message this one replies to, when it is in the conversation.
  final ChatMessage? replyOriginal;
  final String replySenderLabel;
  final VoidCallback? onJumpToReply;
  final ValueChanged<String>? onToggleReaction;
  final String Function(String who)? nameOf;

  /// Just jumped to (from a reply): outlined for a moment.
  final bool highlighted;

  /// The conversation the message is in (the friend's address): where its
  /// delivery status and "Ponów" act.
  final String conversationKey;

  /// "Zgłoś" in the long-press menu of a message we received.
  final VoidCallback? onReport;

  /// When non-null the bubble plays its fade-slide entrance with this
  /// stagger delay; null renders statically (scroll rebuilds, stream updates).
  final Duration? entranceDelay;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    if (message.isSystem) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: zen.accentTertiary.withValues(alpha: 0.10),
              borderRadius: context.zenRadius(16),
              border: Border.all(
                color: zen.accentTertiary.withValues(alpha: 0.22),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Text(
                chatMessageText(message),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final bool outgoing = message.isOutgoing;
    // Text bubbles we send get the accent gradient; media we send sit on an
    // accent-tinted surface so their own colours stay readable. A look with
    // its own bubbles (lit outlines, bevels) draws them instead.
    final ZenLook look = ZenLook.of(context);
    final bool isTextMessage = message.type == ChatMessageType.text;
    final bool onGradient = outgoing && isTextMessage && look.filledBubbles;
    final Color metaColor = onGradient
        ? zen.onAccent.withValues(alpha: 0.72)
        : zen.textMuted;

    final Widget content = switch (message.type) {
      _ when message.isDeleted => Text(
        deletedMessageLabel(),
        key: Key('deleted-message-${message.id}'),
        style: TextStyle(
          color: onGradient ? zen.onAccent : zen.textMuted,
          fontSize: 14,
          fontStyle: FontStyle.italic,
        ),
      ),
      ChatMessageType.image when message.hasAttachment =>
        _ImageAttachmentContent(message: message),
      ChatMessageType.image => _AttachmentStubContent(message: message),
      ChatMessageType.voice => _VoiceAttachmentContent(message: message),
      ChatMessageType.file => _FileAttachmentContent(message: message),
      ChatMessageType.video => _VideoAttachmentContent(message: message),
      _ => CopyableText(
        message.text,
        style: TextStyle(
          color: onGradient ? zen.onAccent : zen.textPrimary,
          fontSize: 15,
          height: 1.4,
          fontWeight: FontWeight.w500,
        ),
        onReport: outgoing ? null : onReport,
        actions: actions,
      ),
    };
    // Files have no text to long-press: the same menu, on the bubble.
    final Widget body =
        message.type == ChatMessageType.text ||
            message.isDeleted ||
            actions.isEmpty
        ? content
        : GestureDetector(
            onLongPressStart: (LongPressStartDetails d) => unawaited(
              showChatContextMenu(context, d.globalPosition, actions),
            ),
            onSecondaryTapDown: (TapDownDetails d) => unawaited(
              showChatContextMenu(context, d.globalPosition, actions),
            ),
            child: content,
          );
    final ChatReply? reply = message.isDeleted ? null : message.reply;

    final BoxDecoration? themed = look.bubble(zen, outgoing: outgoing);
    final BoxDecoration decoration;
    if (themed != null) {
      decoration = themed;
    } else if (onGradient) {
      decoration = BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            zen.accent,
            Color.lerp(zen.accent, zen.accentSecondary, 0.35)!,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: look.bubbleRadius(outgoing: true),
        boxShadow: ZenLook.of(context).tinted(
          zen,
          zen.accent,
          radius: 12,
          alpha: 0.18,
          offset: const Offset(0, 4),
        ),
      );
    } else if (outgoing) {
      decoration = BoxDecoration(
        color: Color.alphaBlend(
          zen.accent.withValues(alpha: 0.14),
          zen.surfaceRaised,
        ),
        borderRadius: look.bubbleRadius(outgoing: true),
        border: Border.all(color: zen.accent.withValues(alpha: 0.28)),
      );
    } else {
      decoration = BoxDecoration(
        color: zen.surfaceRaised,
        borderRadius: look.bubbleRadius(outgoing: false),
        border: Border.all(color: zen.outlineSoft),
      );
    }

    final Widget bubble = Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          final double maxWidth = constraints.maxWidth.isFinite
              ? (constraints.maxWidth * 0.82).clamp(160.0, 440.0)
              : 440.0;
          return ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxWidth),
            child: DecoratedBox(
              decoration: decoration,
              position: DecorationPosition.background,
              child: DecoratedBox(
                decoration: highlighted
                    ? BoxDecoration(
                        borderRadius: look.bubbleRadius(outgoing: outgoing),
                        border: Border.all(color: zen.accent, width: 2),
                      )
                    : const BoxDecoration(),
                position: DecorationPosition.foreground,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 9, 12, 7),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (message.forwarded && !message.isDeleted)
                        ChatForwardedMarker(onAccent: onGradient),
                      if (reply != null)
                        ChatReplyQuote(
                          reply: reply,
                          original: replyOriginal,
                          senderLabel: replySenderLabel,
                          onTap: onJumpToReply,
                          onAccent: onGradient,
                        ),
                      body,
                      if (!message.isDeleted && message.reactions.isNotEmpty)
                        ChatReactionsBar(
                          reactions: message.reactions,
                          onToggle: (String emoji) =>
                              onToggleReaction?.call(emoji),
                          nameOf: nameOf ?? (String who) => who,
                        ),
                      const SizedBox(height: 3),
                      Padding(
                        padding: EdgeInsets.zero,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (message.isEdited &&
                                !message.isDeleted) ...<Widget>[
                              Text(
                                editedMarker(),
                                style: TextStyle(
                                  color: metaColor,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                              const SizedBox(width: 4),
                            ],
                            Text(
                              _timeLabel(message.sentAtMillis),
                              style: TextStyle(
                                color: metaColor,
                                fontSize: 11,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (outgoing) ...<Widget>[
                              const SizedBox(width: 2),
                              // Icon by status; long press: its label, tap:
                              // details, legend and "Ponów".
                              MessageDeliveryBadge(
                                message: message,
                                conversationKey: conversationKey,
                                onAccent: onGradient,
                              ),
                            ] else if (message.deliveryState ==
                                ChatMessageDeliveryState.sending) ...<Widget>[
                              // An attachment still coming in.
                              const SizedBox(width: 4),
                              Icon(
                                Icons.schedule_rounded,
                                size: 14,
                                color: zen.textMuted,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );

    final Duration? entranceDelay = this.entranceDelay;
    if (entranceDelay == null) {
      return bubble;
    }
    return ZenFadeSlide(
      duration: const Duration(milliseconds: 300),
      delay: entranceDelay,
      offset: Offset(outgoing ? 10 : -10, 6),
      child: bubble,
    );
  }

  String _timeLabel(int millis) {
    return ZenFormat.time(DateTime.fromMillisecondsSinceEpoch(millis));
  }
}

/// Longest side, in pixels, a chat image is decoded at. A bubble is at most
/// a phone's width; this stays sharp on dense screens.
const int _kChatImageDecodeMaxPx = 1440;

/// [image] decoded to fit within [_kChatImageDecodeMaxPx] on both sides,
/// keeping its aspect ratio and never scaling a small image up.
ImageProvider<Object> _chatImageProvider(ImageProvider<Object> image) {
  return ResizeImage(
    image,
    width: _kChatImageDecodeMaxPx,
    height: _kChatImageDecodeMaxPx,
    policy: ResizeImagePolicy.fit,
  );
}

class _ImageAttachmentContent extends StatelessWidget {
  const _ImageAttachmentContent({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Uint8List? held = message.attachmentBytes;
    final bool isGifFile =
        (message.mimeType?.toLowerCase() == 'image/gif') ||
        (message.fileName?.toLowerCase().endsWith('.gif') ?? false) ||
        (held != null && looksLikeGif(held));
    // GIFs play as far as the media settings allow (tap to play
    // otherwise) and stay still for reduced motion.
    final Widget image = isGifFile && message.attachmentBytes != null
        ? ZenGif(
            bytes: message.attachmentBytes,
            width: double.infinity,
            height: 220,
            errorBuilder: _buildImageError,
          )
        : isGifFile && message.attachmentPath != null
        ? ZenGif(
            file: File(message.attachmentPath!),
            width: double.infinity,
            height: 220,
            errorBuilder: _buildImageError,
          )
        // Decoded no larger than the bubble can show: a peer's image may
        // declare any dimensions, and decoding a huge one at full size could
        // exhaust memory (one 20000 px square is 1.6 GB of pixels).
        : message.attachmentBytes != null
        ? Image(
            image: _chatImageProvider(MemoryImage(message.attachmentBytes!)),
            fit: BoxFit.cover,
            width: double.infinity,
            height: 220,
            errorBuilder: _buildImageError,
          )
        : message.attachmentPath != null
        ? Image(
            // An encrypted file is decrypted in memory only.
            image: _chatImageProvider(mediaFileImage(message.attachmentPath!)),
            fit: BoxFit.cover,
            width: double.infinity,
            height: 220,
            errorBuilder: _buildImageError,
          )
        : _buildImageError(context, StateError('missing attachment'), null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ClipRRect(borderRadius: context.zenRadius(16), child: image),
        if (message.fileName != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            message.fileName!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: zen.textPrimary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
        if (message.attachmentSizeBytes != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            formatAttachmentSize(message.attachmentSizeBytes!),
            style: TextStyle(color: zen.textMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildImageError(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  ) {
    final ZenColors zen = ZenColors.of(context);
    return SizedBox(
      height: 160,
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: zen.textMuted,
          size: 40,
        ),
      ),
    );
  }
}

class _FileAttachmentContent extends StatelessWidget {
  const _FileAttachmentContent({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: zen.accent.withValues(alpha: 0.14),
            borderRadius: context.zenRadius(14),
            border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Icon(Icons.insert_drive_file_outlined, color: zen.accent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                message.fileName ?? message.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message.attachmentSizeBytes == null
                    ? t('Nieznany rozmiar')
                    : formatAttachmentSize(message.attachmentSizeBytes!),
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: message.hasAttachment
                    ? () => _saveAttachmentCopy(context, message)
                    : null,
                icon: const Icon(Icons.download_rounded),
                label: Text(
                  message.hasAttachment
                      ? t('Zapisz kopie')
                      : t('Transfer w toku'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AttachmentStubContent extends StatelessWidget {
  const _AttachmentStubContent({required this.message});

  final ChatMessage message;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final IconData icon = switch (message.type) {
      ChatMessageType.image => Icons.image_outlined,
      ChatMessageType.voice => Icons.mic_none_rounded,
      ChatMessageType.video => Icons.videocam_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        DecoratedBox(
          decoration: BoxDecoration(
            color: zen.accent.withValues(alpha: 0.14),
            borderRadius: context.zenRadius(14),
            border: Border.all(color: zen.accent.withValues(alpha: 0.24)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(11),
            child: Icon(icon, color: zen.accent),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                message.fileName ?? message.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: zen.textPrimary,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message.attachmentSizeBytes == null
                    ? t('Transfer w toku')
                    : formatAttachmentSize(message.attachmentSizeBytes!),
                style: TextStyle(color: zen.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _showNicknameDialog({
  required BuildContext context,
  required SocialHubController controller,
  required FriendProfile friend,
}) async {
  final String? nickname = await promptForFriendNickname(
    context: context,
    friend: friend,
  );
  if (nickname == null || !context.mounted) {
    return;
  }
  try {
    await controller.setFriendNickname(
      peerAddress: friend.address,
      nickname: nickname,
    );
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    _showActionError(
      context,
      t('Nie udało się zapisać pseudonimu: {error}', {'error': error}),
    );
  }
}

Future<void> _showRetentionSettingsDialog({
  required BuildContext context,
  required SocialHubController controller,
  required FriendProfile friend,
}) async {
  String cleanupDraft = '${friend.autoCleanupDays}';
  String limitDraft = '${friend.inboxLimitMb}';
  final _RetentionSettingsDraft? draft =
      await showDialog<_RetentionSettingsDraft>(
        context: context,
        builder: (BuildContext context) {
          final ZenColors zen = ZenColors.of(context);
          return AlertDialog(
            title: Text(t('Retencja rozmowy')),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    t(
                      '0 = nigdy nie czyść i bez limitu danych. Te ustawienia '
                      'działają tylko dla tej rozmowy.',
                    ),
                    style: TextStyle(color: zen.textSecondary, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    key: const Key('retention-cleanup-field'),
                    initialValue: cleanupDraft,
                    autofocus: true,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('Auto-czyszczenie (dni)'),
                    ),
                    onChanged: (String value) {
                      cleanupDraft = value;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    key: const Key('retention-limit-field'),
                    initialValue: limitDraft,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: t('Limit danych rozmowy (MB)'),
                    ),
                    onChanged: (String value) {
                      limitDraft = value;
                    },
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t('Anuluj')),
              ),
              FilledButton(
                key: const Key('retention-settings-save'),
                onPressed: () {
                  Navigator.of(context).pop(
                    _RetentionSettingsDraft(
                      autoCleanupDaysText: cleanupDraft,
                      inboxLimitMbText: limitDraft,
                    ),
                  );
                },
                child: Text(t('Zapisz')),
              ),
            ],
          );
        },
      );
  if (draft == null || !context.mounted) {
    return;
  }
  final int? cleanupDays = int.tryParse(draft.autoCleanupDaysText.trim());
  final int? inboxLimitMb = int.tryParse(draft.inboxLimitMbText.trim());
  if (cleanupDays == null || cleanupDays < 0) {
    _showActionError(context, t('Podaj poprawną liczbę dni (0 lub więcej).'));
    return;
  }
  if (inboxLimitMb == null || inboxLimitMb < 0) {
    _showActionError(
      context,
      t('Podaj poprawny limit danych w MB (0 lub więcej).'),
    );
    return;
  }
  try {
    await controller.configureConversationRetention(
      peerAddress: friend.address,
      autoCleanupDays: cleanupDays,
      inboxLimitMb: inboxLimitMb,
    );
  } on FormatException catch (error) {
    if (!context.mounted) {
      return;
    }
    _showActionError(context, error.message);
  } catch (error) {
    if (!context.mounted) {
      return;
    }
    _showActionError(
      context,
      t('Nie udało się zapisać retencji: {error}', {'error': error}),
    );
  }
}

String _cleanupSummary(FriendProfile friend) {
  return tn(
    friend.autoCleanupDays <= 0 ? 0 : friend.autoCleanupDays,
    one: '{n} dzień',
    few: '{n} dni',
    many: '{n} dni',
  );
}

String _storageLimitSummary(FriendProfile friend) {
  return friend.inboxLimitMb <= 0 ? '0 MB' : '${friend.inboxLimitMb} MB';
}

final class _RetentionSettingsDraft {
  const _RetentionSettingsDraft({
    required this.autoCleanupDaysText,
    required this.inboxLimitMbText,
  });

  final String autoCleanupDaysText;
  final String inboxLimitMbText;
}

void _showActionError(BuildContext context, String message) {
  if (!context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
