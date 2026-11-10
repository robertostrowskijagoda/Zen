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

/// The key of a group's `msg_react` and `msg_delete` that names the
/// author of the message they mean (the parser's `kChangeAuthorKey`).
const String _changeAuthorKey = 'author';

/// [message] with the reply, forwarding, mentions and poll [signal]
/// carries.
ChatMessage _withSignalExtras(ChatMessage message, ZenSignal signal) {
  final Map<String, dynamic>? extras = signal.chatExtras;
  if (extras == null) {
    return message;
  }
  return message.copyWith(
    reply: ChatReply.fromJson(extras['re']),
    forwarded: extras['fwd'] == true,
    mentions: usedMentions(message.text, signalMentions(signal)),
    poll: ChatPoll.fromJson(extras[kPollKey]),
    location: ChatLocation.fromJson(extras[kLocationKey]),
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
      if (message.location != null) kLocationKey: message.location!.toJson(),
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
    String? author;
    final bool changed = await _changeTimelineMessage(
      conversationKey,
      messageId,
      (ChatMessage m) {
        if (m.isDeleted ||
            m.isSystem ||
            _votesAfterClose(
              m,
              'self',
              chosen,
              DateTime.now().millisecondsSinceEpoch,
            )) {
          return null;
        }
        final Map<String, String> next = Map<String, String>.of(m.reactions);
        if (next['self'] == chosen) {
          next.remove('self');
        } else {
          next['self'] = chosen;
          sent = chosen;
        }
        author = _changeAuthorOf(conversationKey, m);
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
        _changeAuthorKey: ?author,
      });
    }
  }

  /// The author of [m] as the members of the group [conversationKey] know
  /// it (this device's address for one's own message), sent with a
  /// reaction to it or its deletion: members choose message ids themselves,
  /// so one id can belong to messages of two members, and only the author
  /// tells which one is meant. `null` in a one-to-one chat.
  String? _changeAuthorOf(String conversationKey, ChatMessage m) {
    if (_groupOfKey(conversationKey) == null) {
      return null;
    }
    final String author = m.isOutgoing
        ? ref.read(runtimeNodeSnapshotProvider).localAddress
        : m.sender;
    return author.isEmpty ? null : PeerShareCodec.normalizeAddress(author);
  }

  // ---------------------------------------------------------------------------
  // A shared position
  // ---------------------------------------------------------------------------

  /// Shares [location] in [conversationKey] (a friend's address or
  /// `group:<id>`) as a new message with [text] (what a Zen without this
  /// feature shows); the message's id.
  Future<String> sendLocationMessage({
    required String conversationKey,
    required String text,
    required ChatLocation location,
  }) async {
    final GroupProfile? group = _groupOfKey(conversationKey);
    if (group != null) {
      return sendGroupMessage(
        groupId: group.id,
        text: text,
        location: location,
      );
    }
    return sendLocalMessage(
      peerAddress: conversationKey,
      text: text,
      location: location,
    );
  }

  /// Puts a newer [location] (with its [text]) on one's own shared
  /// position [messageId], here and for everyone in the conversation.
  /// `false` when that message is no longer here (deleted, cleared).
  Future<bool> updateSharedLocation({
    required String conversationKey,
    required String messageId,
    required String text,
    required ChatLocation location,
  }) async {
    final bool changed = await _changeTimelineMessage(
      conversationKey,
      messageId,
      (ChatMessage m) => !m.isOutgoing || m.isDeleted || m.location == null
          ? null
          : m.copyWith(text: text, location: location),
    );
    if (changed) {
      await _sendChatChange(conversationKey, <String, dynamic>{
        'type': 'msg_edit',
        'msgId': messageId,
        'text': text,
        'at': location.atMillis,
        kLocationKey: location.toJson(),
      });
    }
    return changed;
  }

  /// Ends one's own poll [messageId] now, for everyone: votes cast after
  /// this do not count. `false` when it is not one's own open poll.
  Future<bool> endPoll({
    required String conversationKey,
    required String messageId,
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    ChatPoll? ended;
    final bool changed = await _changeTimelineMessage(
      conversationKey,
      messageId,
      (ChatMessage m) {
        final ChatPoll? poll = m.poll;
        if (!m.isOutgoing ||
            m.isDeleted ||
            poll == null ||
            poll.isClosedAt(now)) {
          return null;
        }
        ended = poll.endedAt(now);
        return m.copyWith(text: endedPollText(ended!), poll: ended);
      },
    );
    final ChatPoll? sent = ended;
    if (changed && sent != null) {
      await _sendChatChange(conversationKey, <String, dynamic>{
        'type': 'msg_edit',
        'msgId': messageId,
        'text': endedPollText(sent),
        'at': now,
        kPollKey: sent.toJson(),
      });
    }
    return changed;
  }

  /// Whether a reaction of [who] ([emoji], empty: taken back) to [m] would
  /// cast, change or take back a vote in a poll closed at [nowMillis].
  bool _votesAfterClose(
    ChatMessage m,
    String who,
    String emoji,
    int nowMillis,
  ) {
    final ChatPoll? poll = m.poll;
    return poll != null &&
        poll.isClosedAt(nowMillis) &&
        (poll.answerOf(emoji) != null ||
            poll.answerOf(m.reactions[who] ?? '') != null);
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
      // A poll's answers stay what the votes point at; a shared position
      // changes only with the position.
      message.poll == null &&
      message.location == null &&
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
      if (removed != null)
        _changeAuthorKey: ?_changeAuthorOf(conversationKey, removed),
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
    final String key = 'group:$groupId';
    final int timestamp = _outgoingStamp(key);
    final String messageId = _groupMessageId(timestamp, groupId);
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
      lastActivityLabel: activityStamp(DateTime.now().millisecondsSinceEpoch),
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
      } else {
        // Only the reference's known fields, never the map as it came.
        final Map<String, dynamic>? reference = chatMediaRefFromJson(media);
        if (reference != null) {
          pending = <String, dynamic>{...reference, 'src': signal.sender};
        }
      }
    }
    final ChatMessage message = _withSignalExtras(
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
    );
    final ChatReply? reply = message.reply;
    await _messageTimelineStore.append(
      key,
      reply == null
          ? message
          : message.copyWith(
              reply: _localGroupReply(
                await _messageTimelineStore.load(key),
                reply,
                signal.sender,
              ),
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
    final String? wireId = signal.messageId;
    if (wireId == null) {
      return;
    }
    final String? groupId = signal.groupId;
    final bool inGroup = groupId != null && groupId.isNotEmpty;
    final String key = inGroup
        ? 'group:$groupId'
        : (state.friendByAddress(signal.sender)?.address ?? signal.sender);
    final Object? author = signal.chatExtras?[_changeAuthorKey];
    final String? messageId = inGroup
        ? _groupChangeTarget(
            await _messageTimelineStore.load(key),
            wireId,
            type: signal.type,
            sender: signal.sender,
            author: author is String && author.isNotEmpty ? author : null,
          )
        : wireId;
    if (messageId == null) {
      return;
    }
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
          if (_votesAfterClose(m, signal.sender, emoji, timestamp)) {
            return null;
          }
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
          // A poll changes only by its author ending it, at any time.
          final ChatPoll? poll = m.poll;
          if (poll != null) {
            final ChatPoll? ended = !wrote(m) || m.isDeleted
                ? null
                : poll.endingOf(
                    signal.chatExtras?[kPollKey],
                    receivedAtMillis: timestamp,
                  );
            return ended == null
                ? null
                : m.copyWith(text: text.isEmpty ? m.text : text, poll: ended);
          }
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
          // A shared position's newer one: only on a message that shares
          // one, and never an older one over a newer.
          final ChatLocation? moved = ChatLocation.fromJson(
            signal.chatExtras?[kLocationKey],
          );
          if (m.location != null) {
            if (moved == null || moved.atMillis < m.location!.atMillis) {
              return null;
            }
            return m.copyWith(text: text, location: moved);
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
    final bool inGroup = groupId is String && groupId.isNotEmpty;
    final String key = inGroup
        ? 'group:$groupId'
        : (state.friendByAddress(peerAddress)?.address ?? peerAddress);
    final int now = DateTime.now().millisecondsSinceEpoch;
    ChatMessage? removed;
    String? target;
    await _enqueueStateWork(() async {
      // In a group the change names the message by the id the members know
      // (and by its author): here it may be kept under another key.
      final Object? author = payload[_changeAuthorKey];
      final String? messageId = inGroup
          ? _groupChangeTarget(
              await _messageTimelineStore.load(key),
              id,
              type: switch (payload['type']) {
                'msg_react' => ZenSignalType.messageReaction,
                'msg_edit' => ZenSignalType.messageEdit,
                _ => ZenSignalType.messageDelete,
              },
              sender: 'self',
              author: author is String && author.trim().isNotEmpty
                  ? PeerShareCodec.normalizeAddress(author)
                  : null,
            )
          : id;
      if (messageId == null) {
        return;
      }
      target = messageId;
      await _changeTimelineMessage(key, messageId, (ChatMessage m) {
        switch (payload['type']) {
          case 'msg_react':
            final Object? emoji = payload['emoji'];
            if (_votesAfterClose(
              m,
              'self',
              emoji is String ? emoji : '',
              now,
            )) {
              return null;
            }
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
            final ChatPoll? poll = m.poll;
            if (poll != null) {
              final ChatPoll? ended = poll.endingOf(
                payload[kPollKey],
                receivedAtMillis: now,
              );
              return ended == null ? null : m.copyWith(text: text, poll: ended);
            }
            if (m.location != null) {
              final ChatLocation? moved = ChatLocation.fromJson(
                payload[kLocationKey],
              );
              return moved == null || moved.atMillis < m.location!.atMillis
                  ? null
                  : m.copyWith(text: text, location: moved);
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
    final String? goneId = target;
    if (gone != null && goneId != null) {
      await _deleteManagedAttachmentIfPresent(gone);
      await _forgetQuotesOf(key, goneId);
    }
  }

  /// The messages of [thread] that came with the id [wireId], under it or
  /// under the key of their author ([groupMessageLocalId]).
  List<ChatMessage> _holdersOf(
    List<ChatMessage> thread,
    String wireId,
  ) => <ChatMessage>[
    for (final ChatMessage m in thread)
      if (!m.isSystem && (m.id == wireId || groupMessageWireId(m.id) == wireId))
        m,
  ];

  /// The key in a group's [thread] of the message a reaction, an edit or a
  /// deletion ([type]) from [sender] ('self': another device of this
  /// account) means, by [wireId] — the id the members know it by — or null
  /// when that cannot be told. Members choose message ids themselves, so
  /// one id can belong to messages of two members; a change naming the
  /// [author] of its message reaches only that author's message. Without
  /// one (a Zen before the author was sent): an edit or a deletion reaches
  /// the sender's own message; a reaction, or a deletion by the group's
  /// creator, only a message whose id no other message here holds — never
  /// a guess between two.
  String? _groupChangeTarget(
    List<ChatMessage> thread,
    String wireId, {
    required ZenSignalType type,
    required String sender,
    String? author,
  }) {
    final List<ChatMessage> holders = _holdersOf(thread, wireId);
    if (author != null && type != ZenSignalType.messageEdit) {
      final List<ChatMessage> by = <ChatMessage>[
        for (final ChatMessage m in holders)
          if (_sameGroupAuthor(m, author)) m,
      ];
      return by.length == 1 ? by.single.id : null;
    }
    if (type != ZenSignalType.messageReaction) {
      final List<ChatMessage> mine = <ChatMessage>[
        for (final ChatMessage m in holders)
          if (sender == 'self'
              ? m.isOutgoing
              : !m.isOutgoing &&
                    PeerShareCodec.addressesEqual(m.sender, sender))
            m,
      ];
      if (mine.isNotEmpty || type == ZenSignalType.messageEdit) {
        return mine.length == 1 ? mine.single.id : null;
      }
    }
    return holders.length == 1 ? holders.single.id : null;
  }

  /// [reply] (in a group message from [replier]) pointing at the message
  /// here it quotes. The quote names the original by its key on the
  /// replier's phone and by its author ('self': the replier); the bare id
  /// can belong to another member's message here, whose text and name the
  /// quote would then show and jump to. An original not here yet gets the
  /// key it will be kept under ([groupMessageSlot]).
  ChatReply _localGroupReply(
    List<ChatMessage> thread,
    ChatReply reply,
    String replier,
  ) {
    final String wireId = groupMessageWireId(reply.messageId);
    final String said = reply.sender.trim();
    final String? author = said.isEmpty
        ? null
        : PeerShareCodec.normalizeAddress(said == 'self' ? replier : said);
    final List<ChatMessage> holders = _holdersOf(thread, wireId);
    if (author == null) {
      return holders.length == 1
          ? ChatReply(
              messageId: holders.single.id,
              sender: reply.sender,
              text: reply.text,
            )
          : reply;
    }
    final bool own = _isOwnDeviceAddress(author);
    final ChatMessage? original = holders
        .where((ChatMessage m) => _sameGroupAuthor(m, author))
        .firstOrNull;
    final String alt = groupMessageLocalId(wireId, author);
    return ChatReply(
      messageId:
          original?.id ??
          (holders.isEmpty || own || alt.length > kMaxSignalIdChars
              ? wireId
              : alt),
      sender: own ? 'self' : author,
      text: reply.text,
    );
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
    await _saveTimelineChanges(key, thread, updated);
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
      await _saveTimelineChanges(key, thread, updated);
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
    final Object? id = payload['msgId'];
    final Map<String, dynamic> withGroup = <String, dynamic>{
      ...payload,
      // The members know the message by the id it came with.
      if (id is String) 'msgId': groupMessageWireId(id),
      'groupId': group.id,
    };
    await Future.wait(<Future<void>>[
      for (final String member in normalizedGroupMembers(group.memberAddresses))
        if (self.isEmpty || !PeerShareCodec.addressesEqual(member, self))
          _sendFriendLifecycleSignal(peerAddress: member, payload: withGroup),
    ]);
  }
}

/// What an ended poll says as its text (a Zen without polls shows it, and
/// the previews).
String endedPollText(ChatPoll poll) =>
    '${poll.asText}\n${t('Ankieta zakończona.')}';
