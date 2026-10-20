part of 'social_hub_controller.dart';

/// Messages to and from people who are not friends, in the ordinary chats
/// (§13, §24.1; the rules are in `stranger_chats.dart`).
mixin _SocialHubStrangersMixin on _SocialHubControllerBase {
  @override
  bool _isStrangerChatPeer(String address) {
    if (state.snapshotUnreadable || !isRoutablePeerAddress(address)) {
      // A lost friend list would make every friend look like a stranger.
      return false;
    }
    final FriendRelationshipStatus status =
        state.friendByAddress(address)?.status ?? FriendRelationshipStatus.none;
    return status != FriendRelationshipStatus.accepted &&
        status != FriendRelationshipStatus.blocked;
  }

  /// The mini-profile to send with a message to someone who is not a
  /// friend (§9); also checks the limits. Throws [StrangerMessageRefused].
  @override
  Future<Map<String, dynamic>> _strangerMessageMini(
    String peerAddress,
    String text,
  ) async {
    final StrangerChatBook book = ref.read(strangerChatsProvider);
    await book.load();
    final String? refusal = book.refusalToSend(peerAddress, text);
    if (refusal != null) {
      throw StrangerMessageRefused(refusal);
    }
    final MiniProfileTag mini =
        book.ownMiniProfile?.call() ??
        MiniProfileTag(
          name: ref.read(userProfileControllerProvider).displayName.trim(),
        );
    return mini.toJson();
  }

  @override
  Future<void> _noteStrangerMessageSent(
    String peerAddress,
    String text,
    String? name,
  ) => ref
      .read(strangerChatsProvider)
      .noteSent(peerAddress, text, name: name ?? '');

  /// A signal from someone who is not a friend that belongs to a
  /// conversation with them: their message (with their mini-profile, text
  /// only, within the limits) or the delivery and read receipts of this
  /// person's own. True when handled here (taken or dropped).
  @override
  Future<bool> _handleStrangerChatSignal(
    ZenSignal signal,
    int timestamp,
  ) async {
    if (!_isStrangerChatPeer(signal.sender)) {
      return false;
    }
    final StrangerChatBook book = ref.read(strangerChatsProvider);
    switch (signal.type) {
      case ZenSignalType.ack:
      case ZenSignalType.messageRead:
        await book.load();
        if (book.chatWith(signal.sender) != null) {
          await _persistSignalArtifacts(signal, timestamp);
        }
        return true;
      case ZenSignalType.message:
        break;
      default:
        return false;
    }
    await book.load();
    final String text = signal.content?.trim() ?? '';
    final String id = signal.messageId?.trim() ?? '';
    // The mini-profile marks a message meant for someone who is not a
    // friend; one with nothing usable in it shows as "Kontakt Zen".
    final Map<String, dynamic>? attached = signal.miniProfile;
    final MiniProfileTag? tag = attached == null
        ? null
        : MiniProfileTag.fromJson(attached) ?? const MiniProfileTag(name: '');
    final MiniProfileTag? mini = tag == null
        ? null
        : MiniProfileTag(name: sanitizePeerName(tag.name), avatar: tag.avatar);
    final bool textOnly =
        (signal.attachmentData?.isEmpty ?? true) &&
        !signal.isPlaceholder &&
        (signal.messageType ?? ChatMessageType.text) == ChatMessageType.text;
    if (mini == null ||
        !textOnly ||
        text.isEmpty ||
        text.length > kMaxStrangerMessageChars ||
        id.isEmpty) {
      return true;
    }
    if (await _timelineHasMessage(peerAddress: signal.sender, messageId: id)) {
      // A repeat: only the delivery ack goes again.
      await _persistSignalArtifacts(signal, timestamp);
      return true;
    }
    if (!book.admits(signal.sender)) {
      return true;
    }
    final bool onScreen =
        PeerShareCodec.addressesEqual(
          _openConversationAddress ?? '',
          signal.sender,
        ) &&
        _isUiFocused();
    await book.noteReceived(signal.sender, text, mini: mini, read: onScreen);
    await _persistSignalArtifacts(signal, timestamp);
    if (!onScreen) {
      final String name = mini.name.isEmpty ? t('Kontakt Zen') : mini.name;
      await _presentSystemNotification(
        RuntimeSystemNotification(
          id: 'stranger-$id',
          title: t('{name} (spoza znajomych)', <String, Object?>{'name': name}),
          body: _appSettings.hideNotificationContent
              ? t('Nowa wiadomość')
              : text,
          createdAtMillis: timestamp,
          category: RuntimeSystemNotificationCategory.message,
          routeKey: buildConversationRouteKey(
            peerAddress: signal.sender,
            title: name,
          ),
          slotKey: 'stranger-message',
          contentRedacted: _appSettings.hideNotificationContent,
        ),
      );
    }
    return true;
  }
}
