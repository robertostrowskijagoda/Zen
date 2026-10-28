part of 'social_hub_controller.dart';

mixin _SocialHubRetentionMixin on _SocialHubControllerBase {
  @override
  Future<void> _applyRetentionAcrossConversations({
    required int nowMillis,
  }) async {
    for (final FriendProfile friend in state.friends.values) {
      await _applyConversationRetention(
        peerAddress: friend.address,
        nowMillis: nowMillis,
      );
    }
  }

  @override
  Future<void> _applyConversationRetention({
    required String peerAddress,
    required int nowMillis,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? friend = state.friendByAddress(canonical);
    if (friend == null) {
      return;
    }
    if (friend.autoCleanupDays <= 0 && friend.inboxLimitMb <= 0) {
      return;
    }
    final List<ChatMessage> thread = await _messageTimelineStore.load(
      peerAddress,
    );
    if (thread.isEmpty) {
      _syncFriendPreviewFromTimeline(
        peerAddress: peerAddress,
        thread: thread,
        resetUnread: true,
      );
      return;
    }

    int totalBytes = thread.fold<int>(
      0,
      (int sum, ChatMessage message) => sum + _messageStorageBytes(message),
    );
    final int cleanupCutoffMillis = friend.autoCleanupDays <= 0
        ? -1
        : nowMillis - Duration(days: friend.autoCleanupDays).inMilliseconds;
    final int sizeLimitBytes = friend.inboxLimitMb <= 0
        ? 0
        : friend.inboxLimitMb * 1024 * 1024;

    bool removedAny = false;
    final List<ChatMessage> retained = <ChatMessage>[];
    for (final ChatMessage message in thread) {
      if (cleanupCutoffMillis > 0 &&
          message.sentAtMillis < cleanupCutoffMillis) {
        removedAny = true;
        await _cleanupRetainedArtifacts(
          peerAddress: peerAddress,
          message: message,
        );
        totalBytes -= _messageStorageBytes(message);
        continue;
      }
      retained.add(message);
    }

    int removeCount = 0;
    if (sizeLimitBytes > 0) {
      while (removeCount < retained.length && totalBytes > sizeLimitBytes) {
        totalBytes -= _messageStorageBytes(retained[removeCount]);
        await _cleanupRetainedArtifacts(
          peerAddress: peerAddress,
          message: retained[removeCount],
        );
        removeCount += 1;
      }
    }
    if (removeCount > 0) {
      retained.removeRange(0, removeCount);
      removedAny = true;
    }

    if (removedAny) {
      await _messageTimelineStore.save(
        peerAddress,
        List<ChatMessage>.unmodifiable(retained),
      );
      _bumpTimelineRevision();
    }
    _syncFriendPreviewFromTimeline(
      peerAddress: peerAddress,
      thread: retained,
      resetUnread: retained.isEmpty,
    );
  }

  Future<void> _cleanupRetainedArtifacts({
    required String peerAddress,
    required ChatMessage message,
  }) async {
    await _deleteManagedAttachmentIfPresent(message);
    await _transferStore.deleteIncoming(peerAddress, message.id);
    await _transferStore.deleteOutgoing(peerAddress, message.id);
  }

  /// Removes one message from this phone only ("Usuń z mojego urządzenia"
  /// after a report): the other side keeps its copy. Its file and
  /// unfinished transfers go with it, and the chat list shows the message
  /// before it. [key] is a friend's address, or `group:<id>` for a group.
  /// False when the message is not there (any more).
  Future<bool> deleteMessageLocally({
    required String key,
    required String messageId,
  }) async {
    final List<ChatMessage> thread = await _messageTimelineStore.load(key);
    final int index = thread.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    if (index < 0) {
      return false;
    }
    final ChatMessage message = thread[index];
    final List<ChatMessage> rest = List<ChatMessage>.of(thread)
      ..removeAt(index);
    await _messageTimelineStore.save(key, List<ChatMessage>.unmodifiable(rest));
    await _deleteManagedAttachmentIfPresent(message);
    if (!key.startsWith('group:')) {
      await _transferStore.deleteIncoming(key, message.id);
      await _transferStore.deleteOutgoing(key, message.id);
    }
    if (!ref.mounted) {
      return true;
    }
    _bumpTimelineRevision();
    if (!key.startsWith('group:')) {
      _syncFriendPreviewFromTimeline(
        peerAddress: key,
        thread: rest,
        resetUnread: false,
      );
      await _persistState();
    }
    return true;
  }

  void _syncFriendPreviewFromTimeline({
    required String peerAddress,
    required List<ChatMessage> thread,
    required bool resetUnread,
  }) {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? friend = state.friendByAddress(canonical);
    if (friend == null) {
      return;
    }
    final ChatMessage? lastMessage = thread.isEmpty ? null : thread.last;
    final String nextPreview = lastMessage == null
        ? ''
        : chatPreviewLine(
            chatMessageText(
              lastMessage,
              peerName: friend.hasProfileName ? friend.displayLabel : null,
            ),
            type: lastMessage.type,
            fileName: lastMessage.fileName,
            mimeType: lastMessage.mimeType,
          );
    final String nextLabel = lastMessage == null
        ? ''
        : _activityLabelForMillis(lastMessage.sentAtMillis);
    final int nextUnreadCount = resetUnread ? 0 : friend.unreadCount;
    if (friend.lastMessagePreview == nextPreview &&
        friend.lastActivityLabel == nextLabel &&
        friend.unreadCount == nextUnreadCount) {
      return;
    }
    final Map<String, FriendProfile> friends = Map<String, FriendProfile>.from(
      state.friends,
    );
    _putFriend(
      friends,
      friend.copyWith(
        lastMessagePreview: nextPreview,
        lastActivityLabel: nextLabel,
        unreadCount: nextUnreadCount,
      ),
    );
    state = state.copyWith(friends: friends);
  }

  @override
  Future<void> _updateMessageDeliveryState({
    required String peerAddress,
    required String messageId,
    required ChatMessageDeliveryState deliveryState,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    final List<ChatMessage> thread = await timelineStore.load(peerAddress);
    final int index = thread.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    if (index < 0 || thread[index].deliveryState == deliveryState) {
      return;
    }
    final List<ChatMessage> next = List<ChatMessage>.from(
      thread,
      growable: false,
    );
    next[index] = next[index].copyWith(deliveryState: deliveryState);
    await timelineStore.save(peerAddress, next);
    _bumpTimelineRevision();
  }

  @override
  void _updateFriendPreview({
    required String peerAddress,
    required String preview,
    String? displayName,
  }) {
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final Map<String, FriendProfile> friends = Map<String, FriendProfile>.from(
      state.friends,
    );
    final FriendProfile? known = _friendFromMap(friends, peerAddress);
    if (known == null && isRoutablePeerAddress(peerAddress)) {
      // Writing to someone on the mesh never makes them a friend (it used
      // to, with the status "accepted": a removed friend sent a file came
      // back so). Only the local stand-ins of the preview are made here.
      return;
    }
    final FriendProfile base =
        known ??
        FriendProfile(
          address: peerAddress,
          status: FriendRelationshipStatus.accepted,
        );
    _putFriend(
      friends,
      base.copyWith(
        displayName: displayName ?? base.displayName,
        isOnline: true,
        lastPresenceAtMillis: timestamp,
        lastMessagePreview: preview,
        lastActivityLabel: t('Teraz'),
        unreadCount: 0,
      ),
    );
    state = state.copyWith(friends: friends);
  }
}
