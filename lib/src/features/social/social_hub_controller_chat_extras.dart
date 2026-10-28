part of 'social_hub_controller.dart';

/// Files in a group up to this size travel inline in the group message
/// (through each member's reliable queue and mailboxes); larger ones as
/// content-addressed blocks (`chat_media_blocks.dart`), fetched by the
/// members from whoever has them.
const int kGroupInlineAttachmentBytes = 64 * 1024;

/// The largest file sent to a group.
const int kMaxGroupAttachmentBytes = 24 * 1024 * 1024;

/// Group files inline (without the blocks) at most this large.
const int kMaxGroupInlineFallbackBytes = 1024 * 1024;

/// How long one wait for a group file's blocks lasts before it is asked for
/// again (when the chat is opened).
const Duration kGroupMediaFetchTimeout = Duration(minutes: 10);

/// Longest text an edit may put in (as long as a group message).
const int _maxEditChars = 64 * 1024;

/// Some leeway for the sender's clock when an edit is checked against
/// [kChatEditWindow].
const Duration _editClockSkew = Duration(hours: 1);

/// [message] with the reply, forwarding and mentions [signal] carries.
ChatMessage _withSignalExtras(ChatMessage message, ZenSignal signal) {
  final Map<String, dynamic>? extras = signal.chatExtras;
  if (extras == null) {
    return message;
  }
  return message.copyWith(
    reply: ChatReply.fromJson(extras['re']),
    forwarded: extras['fwd'] == true,
    mentions: usedMentions(message.text, signalMentions(signal)),
  );
}

/// The reply, forwarding and mention fields of an outgoing message's
/// payload.
Map<String, dynamic> _outgoingChatExtras(ChatMessage message) =>
    <String, dynamic>{
      if (message.reply != null) 're': message.reply!.toJson(),
      if (message.forwarded) 'fwd': true,
      if (message.mentions.isNotEmpty)
        kMentionsKey: mentionsToJson(message.mentions),
    };

/// Reactions, replies, editing, deleting for everyone and forwarding, in
/// one-to-one and group chats; and files in groups.
mixin _SocialHubChatExtrasMixin on _SocialHubControllerBase {
  /// Group messages whose file is being fetched right now.
  final Set<String> _fetchingGroupMedia = <String>{};

  // ---------------------------------------------------------------------------
  // Replies
  // ---------------------------------------------------------------------------

  /// The quote for a reply to [original]: who wrote it and the start of its
  /// text — no text for a message that disappears, so the quote goes with
  /// the original.
  ChatReply replyTo(ChatMessage original) {
    final String label = original.type == ChatMessageType.text
        ? original.plainText
        : chatMessageLabelForType(
            original.type,
            fileName: original.fileName,
            mimeType: original.mimeType,
          );
    return ChatReply(
      messageId: original.id,
      sender: original.isOutgoing ? 'self' : original.sender,
      text: original.disappears || original.isDeleted
          ? ''
          : clipChatSnippet(label),
    );
  }

  // ---------------------------------------------------------------------------
  // Reactions
  // ---------------------------------------------------------------------------

  /// Puts this person's [emoji] on a message, or takes it back when it is
  /// the one already there (one reaction per person).
  Future<void> reactToMessage({
    required String conversationKey,
    required String messageId,
    required String emoji,
  }) async {
    final String chosen = emoji.trim();
    if (chosen.isEmpty || chosen.length > kMaxReactionChars) {
      return;
    }
    String sent = '';
    final bool changed = await _changeTimelineMessage(
      conversationKey,
      messageId,
      (ChatMessage m) {
        if (m.isDeleted || m.isSystem) {
          return null;
        }
        final Map<String, String> next = Map<String, String>.of(m.reactions);
        if (next['self'] == chosen) {
          next.remove('self');
        } else {
          next['self'] = chosen;
          sent = chosen;
        }
        return m.copyWith(reactions: next);
      },
    );
    if (changed) {
      if (sent.isNotEmpty) {
        unawaited(ref.read(zenSoundEffectsProvider).play(ZenSound.like));
      }
      await _sendChatChange(conversationKey, <String, dynamic>{
        'type': 'msg_react',
        'msgId': messageId,
        'emoji': sent,
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Editing
  // ---------------------------------------------------------------------------

  /// Whether [message] may still be edited here: one's own text message,
  /// not deleted, within [kChatEditWindow].
  bool canEditMessage(ChatMessage message, {int? nowMillis}) =>
      message.isOutgoing &&
      !message.isDeleted &&
      message.type == ChatMessageType.text &&
      (nowMillis ?? DateTime.now().millisecondsSinceEpoch) -
              message.sentAtMillis <=
          kChatEditWindow.inMilliseconds;

  /// Replaces the text of one's own message with [text] for everyone
  /// (marked "edytowano"; the earlier text is not kept).
  Future<void> editMessage({
    required String conversationKey,
    required String messageId,
    required String text,
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty || trimmed.length > _maxEditChars) {
      return;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool changed = await _changeTimelineMessage(
      conversationKey,
      messageId,
      (ChatMessage m) => !canEditMessage(m, nowMillis: now) || m.text == trimmed
          ? null
          : m.copyWith(text: trimmed, editedAtMillis: now),
    );
    if (changed) {
      await _sendChatChange(conversationKey, <String, dynamic>{
        'type': 'msg_edit',
        'msgId': messageId,
        'text': trimmed,
        'at': now,
      });
    }
  }

  // ---------------------------------------------------------------------------
  // Deleting for everyone
  // ---------------------------------------------------------------------------

  /// Whether this person may delete [message] for everyone in
  /// [conversationKey]: their own message, or any message of a group they
  /// created.
  bool canDeleteForEveryone(String conversationKey, ChatMessage message) {
    if (message.isDeleted || message.isSystem) {
      return false;
    }
    if (message.isOutgoing) {
      return true;
    }
    final GroupProfile? group = _groupOfKey(conversationKey);
    if (group == null) {
      return false;
    }
    // A group made on this device records its creator as 'self'.
    final String self = ref.read(runtimeNodeSnapshotProvider).localAddress;
    return group.createdById == 'self' ||
        (self.isNotEmpty &&
            PeerShareCodec.addressesEqual(group.createdById, self));
  }

  /// Deletes a message for everyone: its content goes here and on the
  /// other devices that got it; a note "Wiadomość usunięta" stays.
  Future<void> deleteMessageForEveryone({
    required String conversationKey,
    required String messageId,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    ChatMessage? before;
    final bool changed = await _changeTimelineMessage(
      conversationKey,
      messageId,
      (ChatMessage m) {
        if (!canDeleteForEveryone(conversationKey, m)) {
          return null;
        }
        before = m;
        return m.deletedAt(now);
      },
    );
    if (!changed) {
      return;
    }
    final ChatMessage? removed = before;
    if (removed != null) {
      await _deleteManagedAttachmentIfPresent(removed);
    }
    await _forgetQuotesOf(conversationKey, messageId);
    await _sendChatChange(conversationKey, <String, dynamic>{
      'type': 'msg_delete',
      'msgId': messageId,
      'at': now,
    });
  }

  // ---------------------------------------------------------------------------
  // Forwarding
  // ---------------------------------------------------------------------------

  /// Whether [message] can be passed on to another chat.
  bool canForwardMessage(ChatMessage message) =>
      !message.isDeleted &&
      !message.isSystem &&
      !message.disappears &&
      (message.type == ChatMessageType.text || message.hasAttachment);

  /// Sends a copy of [messageId] from [fromKey] to [toKey] (a friend's
  /// address or `group:<id>`), marked "przekazano". A disappearing message
  /// is never passed on.
  Future<void> forwardMessage({
    required String fromKey,
    required String messageId,
    required String toKey,
  }) async {
    final ChatMessage? message = (await _messageTimelineStore.load(
      fromKey,
    )).where((ChatMessage m) => m.id == messageId).firstOrNull;
    if (message == null || !canForwardMessage(message)) {
      throw StateError(t('Tej wiadomości nie można przekazać.'));
    }
    final String? groupId = toKey.startsWith('group:')
        ? toKey.substring('group:'.length)
        : null;
    if (message.type == ChatMessageType.text) {
      if (groupId != null) {
        await sendGroupMessage(
          groupId: groupId,
          // Mentions go as plain names: they meant the old chat's people.
          text: message.plainText,
          forwarded: true,
        );
      } else {
        await sendLocalMessage(
          peerAddress: toKey,
          // Mentions go as plain names: they meant the old chat's people.
          text: message.plainText,
          forwarded: true,
        );
      }
      return;
    }
    final Uint8List? bytes = message.attachmentBytes?.isNotEmpty == true
        ? message.attachmentBytes
        : null;
    final String? path = message.attachmentPath?.trim().isNotEmpty == true
        ? message.attachmentPath!.trim()
        : null;
    final String fileName = message.fileName ?? message.text;
    if (groupId != null) {
      await sendGroupAttachment(
        groupId: groupId,
        bytes: bytes,
        attachmentPath: path,
        fileName: fileName,
        mimeType: message.mimeType,
        type: message.type,
        durationMs: message.durationMs,
        forwarded: true,
      );
    } else {
      await sendLocalAttachment(
        peerAddress: toKey,
        bytes: bytes,
        attachmentPath: path,
        fileName: fileName,
        mimeType: message.mimeType,
        type: message.type,
        durationMs: message.durationMs,
        forwarded: true,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Files in groups
  // ---------------------------------------------------------------------------

  /// Sends a photo, film, file, voice message or GIF to a group. Small files
  /// travel inline in each member's message (through the reliable queue and
  /// the members' mailboxes); larger ones are sealed once as blocks that
  /// the members fetch from whoever already has them, so this phone does
  /// not upload a copy per member.
  Future<void> sendGroupAttachment({
    required String groupId,
    Uint8List? bytes,
    String? attachmentPath,
    required String fileName,
    String? mimeType,
    ChatMessageType? type,
    int? durationMs,
    ChatReply? replyTo,
    bool forwarded = false,
  }) async {
    final GroupProfile? group = state.groups[groupId];
    final String name = fileName.trim();
    if (group == null || name.isEmpty) {
      return;
    }
    if (group.isInvitePending) {
      throw StateError(t('Najpierw dołącz do grupy.'));
    }
    final String? path = attachmentPath?.trim().isNotEmpty == true
        ? attachmentPath!.trim()
        : null;
    final Uint8List? given = bytes == null || bytes.isEmpty ? null : bytes;
    if (given == null && path == null) {
      return;
    }
    final int size = given?.length ?? await _mediaVault.length(path!);
    if (size <= 0 || size > kMaxGroupAttachmentBytes) {
      throw FormatException(
        t('Plik jest za duży dla grupy (najwyżej {size}).', <String, Object?>{
          'size': formatAttachmentSize(kMaxGroupAttachmentBytes),
        }),
      );
    }
    final ChatMessageType resolvedType =
        type ??
        _attachmentTransport.inferType(mimeType: mimeType, fileName: name);
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final String key = 'group:$groupId';
    final String messageId = 'grp-msg-$timestamp-$groupId';
    final String label = chatMessageLabelForType(
      resolvedType,
      fileName: name,
      mimeType: mimeType,
    );
    await _messageTimelineStore.append(
      key,
      ChatMessage(
        id: messageId,
        sender: 'self',
        text: name,
        sentAtMillis: timestamp,
        direction: ChatMessageDirection.outgoing,
        type: resolvedType,
        attachmentBytes: given,
        attachmentPath: path,
        fileName: name,
        mimeType: mimeType,
        attachmentSizeBytes: size,
        durationMs: durationMs,
        deliveryState: ChatMessageDeliveryState.sending,
        reply: replyTo,
        forwarded: forwarded,
      ),
    );
    _bumpTimelineRevision();
    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      state.groups,
    );
    groups[groupId] = group.copyWith(
      lastMessagePreview: label,
      lastActivityLabel: t('Teraz'),
    );
    state = state.copyWith(groups: groups);
    await _persistState();
    final ChatMessage sent = (await _messageTimelineStore.load(
      key,
    )).firstWhere((ChatMessage m) => m.id == messageId);
    await _sendGroupFile(group, sent, skip: const <String>{});
  }

  /// The file of [message] (one's own, in [group]) to every member but
  /// those in [skip].
  @override
  Future<void> _sendGroupFile(
    GroupProfile group,
    ChatMessage message, {
    required Set<String> skip,
  }) async {
    final String key = 'group:${group.id}';
    try {
      final Uint8List bytes = message.attachmentBytes?.isNotEmpty == true
          ? message.attachmentBytes!
          : await _readGroupFileBytes(message.attachmentPath);
      final Map<String, dynamic> file = <String, dynamic>{
        'messageType': message.type.name,
        'fileName': ?message.fileName,
        'mimeType': ?message.mimeType,
        'attachmentSizeBytes': bytes.length,
        'durationMs': ?message.durationMs,
        ..._outgoingChatExtras(message),
      };
      final ChatMediaBlocks? blocks = ref
          .read(chatMediaBlocksHolderProvider)
          .blocks;
      if (blocks != null && bytes.length > kGroupInlineAttachmentBytes) {
        // Sealed once; the members share the blocks among themselves.
        file['media'] = await blocks.store(
          bytes,
          mime: message.mimeType ?? 'application/octet-stream',
          durationMs: message.durationMs,
        );
      } else {
        if (bytes.length > kMaxGroupInlineFallbackBytes) {
          throw FormatException(
            t('Ten plik jest za duży, żeby wysłać go teraz do grupy.'),
          );
        }
        final EncodedChatAttachment encoded = await _attachmentTransport.encode(
          bytes,
          type: message.type,
          mimeType: message.mimeType,
          fileName: message.fileName ?? message.text,
        );
        file['attachmentData'] = encoded.base64Data;
        final String? encoding = encoded.encoding;
        if (encoding != null) {
          file['attachmentEncoding'] = encoding;
        }
      }
      await _sendGroupMessageToMembers(
        group: group,
        messageId: message.id,
        text: message.fileName ?? message.text,
        timestamp: message.sentAtMillis,
        skip: skip,
        extra: file,
      );
    } catch (error, stackTrace) {
      logZenError('Sending a file to a group failed', error, stackTrace);
      await _updateMessageDeliveryState(
        peerAddress: key,
        messageId: message.id,
        deliveryState: ChatMessageDeliveryState.failed,
      );
      rethrow;
    }
  }

  Future<Uint8List> _readGroupFileBytes(String? path) async {
    final String? trimmed = path?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      throw const FormatException('Attachment payload is unavailable.');
    }
    return _mediaVault.read(trimmed);
  }

  /// A group message that arrived ([signal], already checked): kept once,
  /// with its file — inline, or fetched as blocks from the members.
  @override
  Future<void> _storeIncomingGroupMessage(
    ZenSignal signal,
    String messageId,
    int timestamp,
  ) async {
    final String groupId = signal.groupId!;
    final String key = 'group:$groupId';
    final ChatMessageType? type = signal.messageType;
    StoredAttachment? stored;
    Map<String, dynamic>? pending;
    if (type != null && type != ChatMessageType.text) {
      final String? inline = signal.attachmentData;
      final Object? media = signal.chatExtras?['media'];
      if (inline != null && inline.isNotEmpty) {
        try {
          final Uint8List bytes = await _attachmentTransport.decode(
            base64Data: inline,
            encoding: signal.attachmentEncoding,
          );
          if (bytes.isNotEmpty) {
            stored = await _persistIncomingAttachmentFile(
              peerAddress: key,
              messageId: messageId,
              bytes: bytes,
              type: type,
              mimeType: signal.mimeType,
              fileName: signal.fileName,
            );
          }
        } on FormatException catch (error) {
          logZenWarning('A group file was refused: ${error.message}');
        }
      } else if (media is Map) {
        pending = <String, dynamic>{
          ...Map<String, dynamic>.from(media),
          'src': signal.sender,
        };
      }
    }
    await _messageTimelineStore.append(
      key,
      _withSignalExtras(
        ChatMessage(
          id: messageId,
          sender: signal.sender,
          text: signal.content ?? '',
          sentAtMillis: _effectiveSentAt(signal, timestamp),
          direction: ChatMessageDirection.incoming,
          type: stored?.type ?? type ?? ChatMessageType.text,
          attachmentPath: stored?.path,
          fileName: stored?.fileName ?? signal.fileName,
          mimeType: stored?.mimeType ?? signal.mimeType,
          attachmentSizeBytes: stored?.sizeBytes ?? signal.attachmentSizeBytes,
          durationMs: signal.durationMs,
          pendingMedia: pending,
        ),
        signal,
      ),
    );
    _bumpTimelineRevision();
    if (pending != null) {
      unawaitedLogged(
        _fetchGroupMedia(groupId, messageId),
        context: 'Fetching a group file failed',
      );
    }
  }

  /// Asks again for the files of [groupId]'s messages that did not arrive
  /// yet (the chat was opened).
  Future<void> retryPendingGroupMedia(String groupId) async {
    final List<ChatMessage> thread = await _messageTimelineStore.load(
      'group:$groupId',
    );
    for (final ChatMessage m in thread) {
      if (m.pendingMedia != null && !m.isDeleted) {
        unawaitedLogged(
          _fetchGroupMedia(groupId, m.id),
          context: 'Fetching a group file failed',
        );
      }
    }
  }

  Future<void> _fetchGroupMedia(String groupId, String messageId) async {
    final String key = 'group:$groupId';
    final String slot = '$key|$messageId';
    final ChatMediaBlocks? blocks = ref
        .read(chatMediaBlocksHolderProvider)
        .blocks;
    if (blocks == null || !_fetchingGroupMedia.add(slot)) {
      return;
    }
    try {
      final ChatMessage? message = (await _messageTimelineStore.load(
        key,
      )).where((ChatMessage m) => m.id == messageId).firstOrNull;
      final Map<String, dynamic>? media = message?.pendingMedia;
      if (message == null || media == null) {
        return;
      }
      final String self = ref.read(runtimeNodeSnapshotProvider).localAddress;
      final Object? src = media['src'];
      final List<String> sources = <String>[
        if (src is String) src,
        for (final String member in normalizedGroupMembers(
          state.groups[groupId]?.memberAddresses ?? const <String>[],
        ))
          if (!PeerShareCodec.addressesEqual(member, self)) member,
      ];
      final Uint8List? bytes = await blocks.fetch(
        media,
        sources.toSet().toList(),
        timeout: kGroupMediaFetchTimeout,
      );
      if (bytes == null || !ref.mounted) {
        return;
      }
      StoredAttachment? stored;
      try {
        stored = await _persistIncomingAttachmentFile(
          peerAddress: key,
          messageId: messageId,
          bytes: bytes,
          type: message.type,
          mimeType: message.mimeType,
          fileName: message.fileName,
        );
      } on FormatException catch (error) {
        logZenWarning('A group file was refused: ${error.message}');
      }
      final StoredAttachment? file = stored;
      await _changeTimelineMessage(
        key,
        messageId,
        (ChatMessage m) => m.isDeleted
            ? null
            : file == null
            ? m.copyWith(pendingMedia: null)
            : m.copyWith(
                type: file.type,
                attachmentPath: file.path,
                fileName: file.fileName,
                mimeType: file.mimeType,
                attachmentSizeBytes: file.sizeBytes,
                pendingMedia: null,
              ),
      );
    } finally {
      _fetchingGroupMedia.remove(slot);
    }
  }

  // ---------------------------------------------------------------------------
  // Changes from others, and from this account's other devices
  // ---------------------------------------------------------------------------

  /// A reaction, an edit or a deletion from someone in the chat (already
  /// checked: a friend for a one-to-one chat, a member for a group). An
  /// edit or a deletion counts only from whoever wrote the message — or,
  /// for a deletion in a group, from the group's creator.
  @override
  Future<void> _handleChatChange(ZenSignal signal, int timestamp) async {
    final String? messageId = signal.messageId;
    if (messageId == null) {
      return;
    }
    final String? groupId = signal.groupId;
    final String key = groupId == null || groupId.isEmpty
        ? (state.friendByAddress(signal.sender)?.address ?? signal.sender)
        : 'group:$groupId';
    bool wrote(ChatMessage m) =>
        !m.isOutgoing &&
        !m.isSystem &&
        PeerShareCodec.addressesEqual(m.sender, signal.sender);
    ChatMessage? removed;
    await _changeTimelineMessage(key, messageId, (ChatMessage m) {
      switch (signal.type) {
        case ZenSignalType.messageReaction:
          if (m.isDeleted || m.isSystem) {
            return null;
          }
          final String emoji = (signal.chatExtras?['emoji'] as String?) ?? '';
          final Map<String, String> next = Map<String, String>.of(m.reactions);
          if (emoji.isEmpty) {
            next.remove(signal.sender);
          } else if (next.length < kMaxReactionsPerMessage ||
              next.containsKey(signal.sender)) {
            next[signal.sender] = emoji;
          }
          return m.copyWith(reactions: next);
        case ZenSignalType.messageEdit:
          final String text = signal.content?.trim() ?? '';
          // When it was edited, on this phone's clock as the message's
          // time is: a claim later than its arrival counts as the arrival.
          final int? claimed = signal.sentAtMillis;
          final int at = claimed == null || claimed > timestamp
              ? timestamp
              : claimed;
          if (!wrote(m) ||
              m.isDeleted ||
              m.type != ChatMessageType.text ||
              text.isEmpty ||
              at - m.sentAtMillis >
                  (kChatEditWindow + _editClockSkew).inMilliseconds) {
            return null;
          }
          return m.copyWith(text: text, editedAtMillis: at);
        case ZenSignalType.messageDelete:
          final GroupProfile? group = _groupOfKey(key);
          final bool byCreator =
              group != null &&
              PeerShareCodec.addressesEqual(group.createdById, signal.sender);
          if (m.isDeleted || m.isSystem || !(wrote(m) || byCreator)) {
            return null;
          }
          removed = m;
          return m.deletedAt(timestamp);
        default:
          return null;
      }
    });
    final ChatMessage? gone = removed;
    if (gone != null) {
      await _deleteManagedAttachmentIfPresent(gone);
      await _forgetQuotesOf(key, messageId);
    }
  }

  /// What another device of this account did to a message (mirrored):
  /// the same change here, as this person's own.
  @override
  Future<void> _applyMirroredChatChange(
    String peerAddress,
    Map<String, dynamic> payload,
  ) async {
    final Object? id = payload['msgId'];
    if (id is! String || id.isEmpty) {
      return;
    }
    final Object? groupId = payload['groupId'];
    final String key = groupId is String && groupId.isNotEmpty
        ? 'group:$groupId'
        : (state.friendByAddress(peerAddress)?.address ?? peerAddress);
    final int now = DateTime.now().millisecondsSinceEpoch;
    ChatMessage? removed;
    await _enqueueStateWork(() async {
      await _changeTimelineMessage(key, id, (ChatMessage m) {
        switch (payload['type']) {
          case 'msg_react':
            final Object? emoji = payload['emoji'];
            final Map<String, String> next = Map<String, String>.of(
              m.reactions,
            );
            if (emoji is String &&
                emoji.isNotEmpty &&
                emoji.length <= kMaxReactionChars) {
              next['self'] = emoji;
            } else {
              next.remove('self');
            }
            return m.isDeleted ? null : m.copyWith(reactions: next);
          case 'msg_edit':
            final Object? text = payload['text'];
            final Object? at = payload['at'];
            if (!m.isOutgoing || m.isDeleted || text is! String) {
              return null;
            }
            return m.copyWith(text: text, editedAtMillis: at is int ? at : now);
          case 'msg_delete':
            if (m.isDeleted) {
              return null;
            }
            removed = m;
            return m.deletedAt(now);
          default:
            return null;
        }
      });
    });
    final ChatMessage? gone = removed;
    if (gone != null) {
      await _deleteManagedAttachmentIfPresent(gone);
      await _forgetQuotesOf(key, id);
    }
  }

  // ---------------------------------------------------------------------------
  // Plumbing
  // ---------------------------------------------------------------------------

  GroupProfile? _groupOfKey(String key) => key.startsWith('group:')
      ? state.groups[key.substring('group:'.length)]
      : null;

  /// Applies [change] to message [messageId] of [key] (`null`: no change);
  /// returns whether it changed.
  Future<bool> _changeTimelineMessage(
    String key,
    String messageId,
    ChatMessage? Function(ChatMessage message) change,
  ) async {
    if (!ref.mounted) {
      return false;
    }
    final List<ChatMessage> thread = await _messageTimelineStore.load(key);
    final int index = thread.indexWhere((ChatMessage m) => m.id == messageId);
    if (index < 0) {
      return false;
    }
    final ChatMessage? next = change(thread[index]);
    if (next == null) {
      return false;
    }
    final List<ChatMessage> updated = List<ChatMessage>.of(thread);
    updated[index] = next;
    await _messageTimelineStore.save(key, updated);
    _bumpTimelineRevision();
    return true;
  }

  /// Drops the quoted text of [messageId] from the replies to it in [key]:
  /// it was deleted for everyone, so no quote keeps its words.
  Future<void> _forgetQuotesOf(String key, String messageId) async {
    if (!ref.mounted) {
      return;
    }
    final List<ChatMessage> thread = await _messageTimelineStore.load(key);
    final List<ChatMessage> updated = List<ChatMessage>.of(thread);
    bool changed = false;
    for (int i = 0; i < updated.length; i++) {
      final ChatReply? reply = updated[i].reply;
      if (reply != null &&
          reply.messageId == messageId &&
          reply.text.isNotEmpty) {
        updated[i] = updated[i].copyWith(
          reply: ChatReply(messageId: messageId, sender: reply.sender),
        );
        changed = true;
      }
    }
    if (changed) {
      await _messageTimelineStore.save(key, updated);
      _bumpTimelineRevision();
    }
  }

  /// A reaction, edit or deletion to everyone in [conversationKey]: the
  /// friend, or every other member of the group (reliable, mirrored to this
  /// account's other devices).
  Future<void> _sendChatChange(
    String conversationKey,
    Map<String, dynamic> payload,
  ) async {
    final GroupProfile? group = _groupOfKey(conversationKey);
    if (group == null) {
      if (!isRoutablePeerAddress(conversationKey) ||
          _isStrangerChatPeer(conversationKey)) {
        return;
      }
      await _sendFriendLifecycleSignal(
        peerAddress: conversationKey,
        payload: payload,
      );
      return;
    }
    final String self = ref.read(runtimeNodeSnapshotProvider).localAddress;
    final Map<String, dynamic> withGroup = <String, dynamic>{
      ...payload,
      'groupId': group.id,
    };
    await Future.wait(<Future<void>>[
      for (final String member in normalizedGroupMembers(group.memberAddresses))
        if (self.isEmpty || !PeerShareCodec.addressesEqual(member, self))
          _sendFriendLifecycleSignal(peerAddress: member, payload: withGroup),
    ]);
  }
}
