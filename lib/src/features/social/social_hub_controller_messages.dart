part of 'social_hub_controller.dart';

mixin _SocialHubMessagesMixin on _SocialHubControllerBase {
  /// The calls (`<caller>|<call id>`) noted as missed in this run, newest
  /// last: a caller re-sends its invite every second until "busy" lands, and
  /// the chat is read only for the first of them.
  final List<String> _missedCallsNoted = <String>[];

  /// Sends [text] to [peerAddress]; as a reply to [replyTo], or marked as
  /// [forwarded] from another chat.
  @override
  Future<String> sendLocalMessage({
    required String peerAddress,
    required String text,
    String? displayName,
    int? sentAtMillis,
    ChatReply? replyTo,
    bool forwarded = false,
    ChatLocation? location,
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) {
      return '';
    }
    final int timestamp = _outgoingStamp(peerAddress, sentAtMillis);
    final String messageId = _directMessageId(timestamp, peerAddress);
    final bool requiresDeliveryAck = isRoutablePeerAddress(peerAddress);
    // Someone who is not a friend: within the limits, and
    // with this person's mini-profile. Throws [StrangerMessageRefused].
    final bool toStranger = _isStrangerChatPeer(peerAddress);
    final Map<String, dynamic>? mini = toStranger
        ? await _strangerMessageMini(peerAddress, trimmed)
        : null;

    await _messageTimelineStore.append(
      peerAddress,
      ChatMessage(
        id: messageId,
        sender: 'self',
        text: trimmed,
        sentAtMillis: timestamp,
        direction: ChatMessageDirection.outgoing,
        deliveryState: requiresDeliveryAck
            ? ChatMessageDeliveryState.sending
            : ChatMessageDeliveryState.delivered,
        reply: replyTo,
        forwarded: forwarded,
        location: location,
      ),
    );
    _bumpTimelineRevision();
    if (toStranger) {
      await _noteStrangerMessageSent(peerAddress, trimmed, displayName);
    } else {
      _updateFriendPreview(
        peerAddress: peerAddress,
        displayName: displayName,
        preview: trimmed,
      );
    }
    try {
      await _sendNetworkMessage(
        peerAddress: peerAddress,
        messageId: messageId,
        text: trimmed,
        sentAtMillis: timestamp,
        miniProfile: mini,
        reply: replyTo,
        forwarded: forwarded,
        location: location,
      );
      await _markMessageQueued(
        conversationKey: peerAddress,
        messageId: messageId,
      );
    } catch (error, stackTrace) {
      logZenError('Sending local message failed', error, stackTrace);
      await _updateMessageDeliveryState(
        peerAddress: peerAddress,
        messageId: messageId,
        deliveryState: ChatMessageDeliveryState.failed,
      );
      rethrow;
    } finally {
      unawaited(_finalizeOutgoingMessage(peerAddress, timestamp));
    }
    return messageId;
  }

  Future<void> sendTypingState({
    required String peerAddress,
    required bool isTyping,
  }) async {
    // Not to someone who is not a friend: it would tell them when this
    // person is online.
    if (!isRoutablePeerAddress(peerAddress) ||
        _isStrangerChatPeer(peerAddress)) {
      return;
    }
    try {
      await ref
          .read(signalTransportProvider)
          .send(
            remoteAddress: peerAddress,
            payload: <String, dynamic>{'type': 'typing', 'isTyping': isTyping},
          );
    } catch (error, stackTrace) {
      logZenError('Sending typing signal failed', error, stackTrace);
    }
  }

  @override
  Future<void> sendLocalAttachment({
    required String peerAddress,
    Uint8List? bytes,
    String? attachmentPath,
    required String fileName,
    String? mimeType,
    String? displayName,
    int? sentAtMillis,
    ChatMessageType? type,
    int? durationMs,
    ChatReply? replyTo,
    bool forwarded = false,
  }) async {
    final String normalizedFileName = fileName.trim();
    if (normalizedFileName.isEmpty) {
      return;
    }
    // Whatever way it came here, it leaves without the location, device
    // and time data Zen knows how to remove.
    final ({Uint8List? bytes, String? path}) outgoing =
        await _attachmentWithoutMetadata(
          _mediaVault,
          bytes == null || bytes.isEmpty ? null : bytes,
          attachmentPath?.trim().isNotEmpty == true
              ? attachmentPath!.trim()
              : null,
        );
    final Uint8List? initialBytes = outgoing.bytes;
    final String? normalizedPath = outgoing.path;
    if (initialBytes == null && normalizedPath == null) {
      return;
    }
    final int timestamp = _outgoingStamp(peerAddress, sentAtMillis);
    final String messageId = _directMessageId(timestamp, peerAddress);
    final bool requiresDeliveryAck = isRoutablePeerAddress(peerAddress);
    final String? resolvedMimeType = mimeType;
    final ChatMessageType resolvedType =
        type ??
        _attachmentTransport.inferType(
          mimeType: resolvedMimeType,
          fileName: normalizedFileName,
        );
    final int attachmentSizeBytes;
    if (initialBytes != null) {
      attachmentSizeBytes = initialBytes.length;
    } else {
      attachmentSizeBytes = await _mediaVault.length(normalizedPath!);
    }
    EncodedChatAttachment? encoded;
    Uint8List? inlineBytes = initialBytes;
    bool sendInline = !requiresDeliveryAck;
    if (requiresDeliveryAck) {
      try {
        inlineBytes ??= attachmentSizeBytes <= 1024 * 1024
            ? await _readAttachmentBytesFromPath(normalizedPath!)
            : null;
        if (inlineBytes == null || inlineBytes.isEmpty) {
          throw const FormatException('Attachment payload is unavailable.');
        }
        encoded = await _attachmentTransport.encode(
          inlineBytes,
          type: resolvedType,
          mimeType: resolvedMimeType,
          fileName: normalizedFileName,
        );
        sendInline = true;
      } on FormatException {
        sendInline = false;
      } catch (error, stackTrace) {
        logZenError(
          'Preparing inline attachment payload failed',
          error,
          stackTrace,
        );
        sendInline = false;
      }
    }
    final ChatMessage message = ChatMessage(
      id: messageId,
      sender: 'self',
      text: normalizedFileName,
      sentAtMillis: timestamp,
      direction: ChatMessageDirection.outgoing,
      type: resolvedType,
      attachmentBytes: initialBytes,
      attachmentPath: normalizedPath,
      fileName: normalizedFileName,
      mimeType: resolvedMimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: durationMs,
      reply: replyTo,
      forwarded: forwarded,
      deliveryState: requiresDeliveryAck
          ? (sendInline
                ? ChatMessageDeliveryState.sending
                : ChatMessageDeliveryState.none)
          : ChatMessageDeliveryState.delivered,
    );

    await _messageTimelineStore.append(peerAddress, message);
    _bumpTimelineRevision();
    _updateFriendPreview(
      peerAddress: peerAddress,
      displayName: displayName,
      preview: chatMessageLabelForType(
        resolvedType,
        fileName: normalizedFileName,
        mimeType: resolvedMimeType,
      ),
    );

    if (!requiresDeliveryAck) {
      unawaited(_finalizeOutgoingMessage(peerAddress, timestamp));
      return;
    }

    try {
      if (sendInline) {
        await _sendNetworkAttachmentMessage(
          peerAddress: peerAddress,
          message: message,
          encoded: encoded,
        );
        await _markMessageQueued(
          conversationKey: peerAddress,
          messageId: messageId,
        );
      } else {
        await _queueOutgoingAttachmentTransfer(
          peerAddress: peerAddress,
          message: message,
          attachmentBytes: initialBytes,
          attachmentPath: normalizedPath,
          attachmentSizeBytes: attachmentSizeBytes,
        );
      }
    } catch (error, stackTrace) {
      logZenError('Sending attachment message failed', error, stackTrace);
      await _updateMessageDeliveryState(
        peerAddress: peerAddress,
        messageId: messageId,
        deliveryState: ChatMessageDeliveryState.failed,
      );
      rethrow;
    } finally {
      unawaited(_finalizeOutgoingMessage(peerAddress, timestamp));
    }
  }

  /// [messageId] is in the reliable queue now (on the disk, retried until
  /// delivered): "sending" becomes "sent". Anything further along — a
  /// receipt that already came back — stays as it is.
  Future<void> _markMessageQueued({
    required String conversationKey,
    required String messageId,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final List<ChatMessage> thread = await _messageTimelineStore.load(
      conversationKey,
    );
    final ChatMessage? message = thread
        .where((ChatMessage m) => m.id == messageId)
        .firstOrNull;
    if (message?.deliveryState != ChatMessageDeliveryState.sending) {
      return;
    }
    await _updateMessageDeliveryState(
      peerAddress: conversationKey,
      messageId: messageId,
      deliveryState: ChatMessageDeliveryState.sent,
    );
  }

  /// Sends one of this person's own messages again after it failed ("Nie
  /// udało się — ponów"), under the same id: whoever gets it twice keeps one
  /// copy. [conversationKey] is the friend's address or `group:<id>`; in a
  /// group only the members who did not confirm it get it again.
  Future<void> retryOutgoingMessage({
    required String conversationKey,
    required String messageId,
  }) async {
    final List<ChatMessage> thread = await _messageTimelineStore.load(
      conversationKey,
    );
    final ChatMessage? message = thread
        .where((ChatMessage m) => m.id == messageId)
        .firstOrNull;
    if (message == null ||
        !message.isOutgoing ||
        message.deliveryState == ChatMessageDeliveryState.delivered) {
      return;
    }
    if (conversationKey.startsWith('group:')) {
      await _retryGroupMessage(
        conversationKey.substring('group:'.length),
        message,
      );
      return;
    }
    final String peerAddress = conversationKey;
    if (!isRoutablePeerAddress(peerAddress)) {
      return;
    }
    await _updateMessageDeliveryState(
      peerAddress: peerAddress,
      messageId: messageId,
      deliveryState: ChatMessageDeliveryState.sending,
    );
    try {
      bool queued = true;
      if (message.type == ChatMessageType.text) {
        await _sendNetworkMessage(
          peerAddress: peerAddress,
          messageId: message.id,
          text: message.text,
          sentAtMillis: message.sentAtMillis,
          reply: message.reply,
          forwarded: message.forwarded,
          location: message.location,
          // The same message again: no new message against the limits.
          miniProfile: _isStrangerChatPeer(peerAddress)
              ? _ownStrangerMini()
              : null,
        );
      } else {
        queued = await _resendAttachment(peerAddress, message);
      }
      if (queued) {
        await _markMessageQueued(
          conversationKey: peerAddress,
          messageId: messageId,
        );
      }
    } catch (error, stackTrace) {
      logZenError('Sending a message again failed', error, stackTrace);
      await _updateMessageDeliveryState(
        peerAddress: peerAddress,
        messageId: messageId,
        deliveryState: ChatMessageDeliveryState.failed,
      );
      rethrow;
    } finally {
      unawaited(
        _finalizeOutgoingMessage(
          peerAddress,
          DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
  }

  Map<String, dynamic> _ownStrangerMini() {
    final MiniProfileTag mini =
        ref.read(strangerChatsProvider).ownMiniProfile?.call() ??
        MiniProfileTag(
          name: ref.read(userProfileControllerProvider).publicName.trim(),
        );
    return mini.toJson();
  }

  /// The attachment of [message] again: inline through the reliable queue
  /// when it is small enough (true), else as a transfer that waits for both
  /// devices or the recipient's mailboxes (false: the transfer moves the
  /// message's state on itself).
  Future<bool> _resendAttachment(
    String peerAddress,
    ChatMessage message,
  ) async {
    final String? path = message.attachmentPath?.trim().isNotEmpty == true
        ? message.attachmentPath!.trim()
        : null;
    Uint8List? bytes = message.attachmentBytes?.isNotEmpty == true
        ? message.attachmentBytes
        : null;
    final int size =
        message.attachmentSizeBytes ??
        bytes?.length ??
        (path == null ? 0 : await _mediaVault.length(path));
    if (bytes == null && path != null && size > 0 && size <= 1024 * 1024) {
      bytes = await _readAttachmentBytesFromPath(path);
    }
    if (bytes != null && bytes.isNotEmpty) {
      try {
        final EncodedChatAttachment encoded = await _attachmentTransport.encode(
          bytes,
          type: message.type,
          mimeType: message.mimeType,
          fileName: message.fileName ?? message.text,
        );
        await _sendNetworkAttachmentMessage(
          peerAddress: peerAddress,
          message: message,
          encoded: encoded,
        );
        return true;
      } on FormatException {
        if (path == null) {
          rethrow;
        }
      }
    }
    if (path == null) {
      throw const FormatException('Attachment payload is unavailable.');
    }
    await _updateMessageDeliveryState(
      peerAddress: peerAddress,
      messageId: message.id,
      deliveryState: ChatMessageDeliveryState.none,
    );
    await _queueOutgoingAttachmentTransfer(
      peerAddress: peerAddress,
      message: message,
      attachmentPath: path,
      attachmentSizeBytes: size,
    );
    return false;
  }

  Future<void> _retryGroupMessage(String groupId, ChatMessage message) async {
    final GroupProfile? group = state.groups[groupId];
    if (group == null || group.isInvitePending) {
      return;
    }
    final String key = 'group:$groupId';
    final RelayEngine? engine = ref.read(relayEngineProvider);
    final Set<String> confirmed = engine == null
        ? const <String>{}
        : await engine.deliveredRecipientsOf(message.id);
    await _updateMessageDeliveryState(
      peerAddress: key,
      messageId: message.id,
      deliveryState: ChatMessageDeliveryState.sending,
    );
    if (message.type != ChatMessageType.text) {
      await _sendGroupFile(group, message, skip: confirmed);
      return;
    }
    await _sendGroupMessageToMembers(
      group: group,
      messageId: message.id,
      text: message.text,
      timestamp: message.sentAtMillis,
      skip: confirmed,
      extra: _outgoingChatExtras(message),
    );
  }

  /// Hands a group message to the reliable transport for every member but
  /// this device (and those in [skip]) and waits until each copy is queued;
  /// then it shows as sent (or delivered, with nobody else in the group).
  /// Each member's copy is acknowledged, retried and left in that member's
  /// mailboxes while it is offline; the group's status adds them up.
  @override
  Future<void> _sendGroupMessageToMembers({
    required GroupProfile group,
    required String messageId,
    required String text,
    required int timestamp,
    required Set<String> skip,
    Map<String, dynamic> extra = const <String, dynamic>{},
  }) async {
    final String key = 'group:${group.id}';
    final String senderDisplayName = ref
        .read(userProfileControllerProvider)
        .publicName;
    final String localAddr = ref.read(runtimeNodeSnapshotProvider).localAddress;
    final int seconds = state.disappearSecondsFor(key);
    final int? ttl = seconds > 0 ? seconds : null;
    final int setAt = state.disappearSetAtFor(key);
    final List<Future<void>> sends = <Future<void>>[];
    for (final String member in normalizedGroupMembers(group.memberAddresses)) {
      if (localAddr.isNotEmpty &&
          PeerShareCodec.addressesEqual(member, localAddr)) {
        continue;
      }
      if (skip.any(
        (String done) => PeerShareCodec.addressesEqual(done, member),
      )) {
        continue;
      }
      // Goes through the reliable transport (acked, retried, relayed to
      // offline members); receivers drop repeat copies by message id.
      sends.add(
        _sendFriendLifecycleSignal(
          peerAddress: member,
          payload: <String, dynamic>{
            'type': 'group_message',
            'groupId': group.id,
            'groupName': group.name,
            'msgId': messageId,
            'text': text,
            'senderName': senderDisplayName,
            'timestamp': timestamp,
            'ttl': ?ttl,
            if (setAt > 0) kDisappearSetAtKey: setAt,
            // A reply, forwarding, a file.
            ...extra,
          },
        ),
      );
    }
    await Future.wait(sends);
    if (sends.isEmpty && skip.isEmpty) {
      // Nobody else in the group: nothing to wait for.
      await _updateMessageDeliveryState(
        peerAddress: key,
        messageId: messageId,
        deliveryState: ChatMessageDeliveryState.delivered,
      );
      return;
    }
    await _markMessageQueued(conversationKey: key, messageId: messageId);
  }

  Future<void> _finalizeOutgoingMessage(
    String peerAddress,
    int timestamp,
  ) async {
    try {
      await _applyConversationRetention(
        peerAddress: peerAddress,
        nowMillis: timestamp,
      );
      await _persistState();
    } catch (error, stackTrace) {
      logZenError('Finalizing outgoing message failed', error, stackTrace);
    }
  }

  /// The plain bytes of a file to send: the user's own file, or an
  /// encrypted one (a voice message) opened from the vault.
  Future<Uint8List> _readAttachmentBytesFromPath(String path) {
    return _mediaVault.read(path);
  }

  /// How far behind this phone's clock each friend's clock is known to be
  /// (or this phone's ahead of theirs), by normalised address: set when a
  /// message of theirs had to go in by when it came ([_placedSentAt]), and
  /// lowered by every later message of theirs (a message cannot come before
  /// it was written, so its own lead says the clocks are at most that far
  /// apart). Forgotten after [ClockSkewTracker.sampleLifetime]; in memory
  /// only.
  final Map<String, ({int lead, int at})> _clockLeadOf =
      <String, ({int lead, int at})>{};

  /// What [_clockLeadOf] holds for [sender] at [nowMillis] (0: nothing).
  int _clockLeadFor(String sender, int nowMillis) {
    final ({int lead, int at})? known = _clockLeadOf[sender];
    if (known == null ||
        nowMillis - known.at > ClockSkewTracker.sampleLifetime.inMilliseconds) {
      _clockLeadOf.remove(sender);
      return 0;
    }
    return known.lead;
  }

  void _noteClockLead(String sender, int lead, int atMillis) {
    if (lead <= 0) {
      _clockLeadOf.remove(sender);
      return;
    }
    if (!_clockLeadOf.containsKey(sender) &&
        _clockLeadOf.length >= _kMaxClockOffsets) {
      _clockLeadOf.remove(_clockLeadOf.keys.first);
    }
    _clockLeadOf[sender] = (lead: lead, at: atMillis);
  }

  /// When a member's or friend's message goes in its conversation: by the
  /// time its sender put on it ([_effectiveSentAt]) — never above a message
  /// from here they confirmed they have (delivered, or read) when it came.
  /// Their answer was put above the question when their clock ran behind
  /// (or this phone's ahead). Such a message goes in by when it came, and
  /// the difference is kept ([_clockLeadOf]): their next messages are read
  /// through it, so they stay in their order after it.
  ///
  /// What really was written before keeps its time and its place: one older
  /// than a message of theirs already here (a late copy from a mailbox, as
  /// `_markedIfLateCopy` says), and one written before a message from here
  /// they did not have yet (this phone was away). History from another
  /// device of the account comes another way (`importSyncedMessage`). The
  /// time shown is the one it is placed by: theirs, or when it came — never
  /// made up.
  ///
  /// In a group "confirmed" is that some member has the message from here:
  /// a member who was offline then and wrote before it comes back after it.
  @override
  Future<int> _placedSentAt(
    ZenSignal signal,
    int receivedAtMillis,
    String conversationKey,
  ) async {
    final String sender = PeerShareCodec.normalizeAddress(signal.sender);
    final int? claimed = signal.sentAtMillis;
    final int base = _effectiveSentAt(signal, receivedAtMillis);
    final int lead = _clockLeadFor(sender, receivedAtMillis);
    // Their time as this phone's clock reads it, never after it came.
    final int placed = claimed == null
        ? base
        : min(receivedAtMillis, max(base, claimed + lead));
    if (claimed != null && lead > 0) {
      _noteClockLead(
        sender,
        min(lead, receivedAtMillis - claimed),
        receivedAtMillis,
      );
    }
    final List<ChatMessage> thread;
    try {
      thread = await _messageTimelineStore.load(conversationKey);
    } on Object catch (error) {
      logZenWarning('Reading a chat to place a message failed: $error');
      return placed;
    }
    int? confirmed;
    int? theirs;
    for (final ChatMessage m in thread) {
      if (m.isOutgoing &&
          (m.deliveryState == ChatMessageDeliveryState.delivered ||
              m.readAtMillis != null)) {
        confirmed = max(confirmed ?? m.sentAtMillis, m.sentAtMillis);
      } else if (m.direction == ChatMessageDirection.incoming &&
          PeerShareCodec.addressesEqual(m.sender, signal.sender)) {
        theirs = max(theirs ?? m.sentAtMillis, m.sentAtMillis);
      }
    }
    if (confirmed == null ||
        placed >= confirmed ||
        (theirs != null && placed < theirs)) {
      return placed;
    }
    final int arrived = max(confirmed, receivedAtMillis);
    if (claimed != null) {
      _noteClockLead(sender, arrived - claimed, receivedAtMillis);
    }
    return arrived;
  }

  @override
  Future<void> _persistSignalArtifacts(ZenSignal signal, int timestamp) async {
    switch (signal.type) {
      case ZenSignalType.message:
        final ChatMessageType resolvedType =
            signal.messageType ?? ChatMessageType.text;
        final String? content = signal.content?.trim();
        final String resolvedText = (content != null && content.isNotEmpty)
            ? content
            : chatMessageLabelForType(
                resolvedType,
                fileName: signal.fileName,
                mimeType: signal.mimeType,
              );
        if (resolvedText.isEmpty) {
          return;
        }
        if (signal.isPlaceholder &&
            signal.messageType != null &&
            signal.messageType != ChatMessageType.text) {
          await _persistIncomingAttachmentPlaceholder(
            signal: signal,
            timestamp: timestamp,
          );
          return;
        }
        final String messageId = _incomingMessageIdOf(signal);
        // A copy of a message already here (a retry, a mailbox's copy, the
        // relay layer handing it over again) only has its delivery ack sent
        // again: its file is not written into the vault once more (a second
        // file nothing refers to, never deleted), and the timer it carries
        // is as old as the message.
        final bool exists = await _timelineHasMessage(
          peerAddress: signal.sender,
          messageId: messageId,
        );
        Uint8List? attachmentBytes;
        StoredAttachment? stored;
        int? attachmentByteCount;
        if (!exists &&
            signal.attachmentData != null &&
            signal.attachmentData!.isNotEmpty) {
          try {
            attachmentBytes = await _attachmentTransport.decode(
              base64Data: signal.attachmentData!,
              encoding: signal.attachmentEncoding,
            );
            attachmentByteCount = attachmentBytes.length;
            if (attachmentByteCount > 0) {
              stored = await _persistIncomingAttachmentFile(
                peerAddress: signal.sender,
                messageId: _incomingMessageIdOf(signal),
                bytes: attachmentBytes,
                type: signal.messageType ?? ChatMessageType.file,
                mimeType: signal.mimeType,
                fileName: signal.fileName,
              );
              attachmentBytes = null;
            }
          } on FormatException catch (error) {
            await _appendSystemMessage(
              peerAddress: signal.sender,
              event: SocialEventText('chat.attachmentFailed', <String, String>{
                'name': _labelFor(signal, friends: state.friends),
                'error': error.message,
              }),
              timestamp: timestamp,
            );
            return;
          }
        }
        if (!exists) {
          // Before it is stored: it is stamped with the timer it brings.
          await _adoptDisappearTimerOf(signal, timestamp);
          await _messageTimelineStore.append(
            signal.sender,
            _withSignalExtras(
              ChatMessage(
                id: messageId,
                sender: signal.sender,
                text: resolvedText,
                sentAtMillis: await _placedSentAt(
                  signal,
                  timestamp,
                  signal.sender,
                ),
                direction: ChatMessageDirection.incoming,
                // A stored attachment is what it really is (media guard).
                type: stored?.type ?? resolvedType,
                attachmentBytes: attachmentBytes,
                attachmentPath: stored?.path,
                fileName: stored?.fileName ?? signal.fileName,
                mimeType: stored?.mimeType ?? signal.mimeType,
                attachmentSizeBytes:
                    stored?.sizeBytes ??
                    signal.attachmentSizeBytes ??
                    attachmentByteCount,
                durationMs: signal.durationMs,
              ),
              signal,
            ),
          );
          _bumpTimelineRevision();
        }
        if (signal.messageId != null && signal.messageId!.trim().isNotEmpty) {
          unawaited(
            _sendMessageAck(
              peerAddress: signal.sender,
              messageId: signal.messageId!.trim(),
            ).catchError((Object error, StackTrace stackTrace) {
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stackTrace,
                  library: 'zen',
                  context: ErrorDescription('while sending a message ack'),
                ),
              );
            }),
          );
        }
        if (!exists) {
          unawaited(
            _applyConversationRetention(
              peerAddress: signal.sender,
              nowMillis: timestamp,
            ).catchError((Object error, StackTrace stackTrace) {
              logZenError(
                'Incoming message retention failed',
                error,
                stackTrace,
              );
            }),
          );
        }
        if (!exists &&
            _openConversationAddress == signal.sender &&
            _isUiFocused()) {
          unawaited(
            ref.read(zenSoundEffectsProvider).play(ZenSound.messageReceived),
          );
        }
        if (_openConversationAddress == signal.sender && _isUiInteractive()) {
          unawaited(
            _sendReadReceiptIfNeeded(
              signal.sender,
              readAtMillis: timestamp,
            ).catchError((Object error, StackTrace stackTrace) {
              FlutterError.reportError(
                FlutterErrorDetails(
                  exception: error,
                  stack: stackTrace,
                  library: 'zen',
                  context: ErrorDescription('while sending a read receipt'),
                ),
              );
            }),
          );
        }
        return;
      case ZenSignalType.messageChunk:
        await _persistIncomingAttachmentChunk(
          signal: signal,
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.transferOffer:
        await _acceptIncomingRealtimeAttachmentTransfer(
          signal: signal,
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.transferAnswer:
        await _applyOutgoingRealtimeTransferAnswer(signal);
        return;
      case ZenSignalType.messageChunkAck:
        await _ackOutgoingAttachmentChunk(signal);
        return;
      case ZenSignalType.ack:
        if (signal.content == 'message' &&
            signal.messageId != null &&
            signal.messageId!.trim().isNotEmpty) {
          await _updateMessageDeliveryState(
            peerAddress: signal.sender,
            messageId: signal.messageId!.trim(),
            deliveryState: ChatMessageDeliveryState.delivered,
          );
        }
        return;
      case ZenSignalType.messageRead:
        if (signal.messageId != null && signal.messageId!.trim().isNotEmpty) {
          await _markMessageRead(
            peerAddress: signal.sender,
            messageId: signal.messageId!.trim(),
            readAtMillis: timestamp,
          );
        }
        return;
      case ZenSignalType.friendAccept:
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('chat.connected', <String, String>{
            // Not known yet: said without a name, the chat puts the name in
            // once their profile tells it.
            'name': _realNameFor(signal, friends: state.friends) ?? '',
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.friendReject:
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('chat.inviteRejected', <String, String>{
            'name': _labelFor(signal, friends: state.friends),
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.friendCancel:
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('chat.inviteCancelled', <String, String>{
            'name': _labelFor(signal, friends: state.friends),
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.friendRemove:
        final String canonical = PeerShareCodec.normalizeAddress(signal.sender);
        await _messageTimelineStore.save(canonical, const <ChatMessage>[]);
        _bumpTimelineRevision();
        return;
      case ZenSignalType.transferCancel:
        if (signal.messageId != null && signal.messageId!.trim().isNotEmpty) {
          await _closeRealtimeTransferSession(
            signal.sender,
            signal.messageId!.trim(),
          );
          await _transferStore.deleteIncoming(
            signal.sender,
            signal.messageId!.trim(),
          );
          await _transferStore.deleteOutgoing(
            signal.sender,
            signal.messageId!.trim(),
          );
          await _updateMessageDeliveryState(
            peerAddress: signal.sender,
            messageId: signal.messageId!.trim(),
            deliveryState: ChatMessageDeliveryState.failed,
          );
        } else {
          await _appendSystemMessage(
            peerAddress: signal.sender,
            event: const SocialEventText('chat.transferCancelled'),
            timestamp: timestamp,
          );
        }
        return;
      case ZenSignalType.callInvite:
        final CallSession? currentCall = state.activeCall;
        if (_isSimultaneousCallGlare(currentCall, signal)) {
          if (_shouldPreferLocalOutgoingCall(
            currentCall!,
            signal.callId?.trim() ?? '',
          )) {
            return;
          }
          await _closeCallMediaSession();
          _pendingIncomingCallAccept = true;
        } else if (currentCall != null &&
            !_currentCallMatchesSignal(currentCall, signal)) {
          if (_secondCallAgainst(currentCall, signal) !=
              _SecondCall.takesOver) {
            await _refuseSecondCall(currentCall, signal, timestamp);
            return;
          }
          // The person whose call rings here calls anew (their phone
          // started over): the new call takes the old one's place.
          await _closeCallMediaSession();
        } else if (_isKnownCallSignal(currentCall, signal)) {
          // The caller re-sends its invite once per second: the ringing
          // deadline is already armed and the "invite arrived" note is already
          // in the timeline, so a repeat has nothing left to add.
          //
          // Still ringing here while this side already answered means the
          // answer is what got lost — the caller would keep inviting until the
          // deadline and then hang up a call that was picked up. Use its own
          // repeat as the cue to send the answer again.
          if (currentCall != null &&
              !currentCall.isIncoming &&
              currentCall.status != CallSessionStatus.active) {
            try {
              await _callMedia.resendLocalAnswer(currentCall.id);
            } catch (error, stackTrace) {
              logZenError(
                'Re-sending the call answer failed',
                error,
                stackTrace,
              );
            }
          }
          return;
        }
        if (state.activeCall != null &&
            state.activeCall!.status == CallSessionStatus.ringing) {
          _armCallRingingTimeout(state.activeCall!);
        }
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('call.inviteIn', <String, String>{
            'kind': _callKind(signal.content).name,
            // The ring reached this phone: the caller's later word that it
            // went unanswered adds nothing (see `_noteMissedCall`).
            if (signal.callId?.trim().isNotEmpty ?? false)
              _kCallEventArg: signal.callId!.trim(),
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.callOffer:
        await _handleIncomingCallOffer(signal: signal, timestamp: timestamp);
        return;
      case ZenSignalType.callAnswer:
        // The callee answered: re-inviting past this point would only knock
        // its session back into the ringing state.
        final bool wasRingingAnswer =
            state.activeCall?.status == CallSessionStatus.ringing;
        if (_isKnownCallSignal(state.activeCall, signal)) {
          _stopCallReRing();
        }
        await _handleIncomingCallAnswer(signal);
        if (wasRingingAnswer) {
          await _appendSystemMessage(
            peerAddress: signal.sender,
            event: SocialEventText('call.answeredBy', <String, String>{
              'name': _labelFor(signal, friends: state.friends),
              'kind': _callKind(signal.content).name,
            }),
            timestamp: timestamp,
          );
        }
        return;
      case ZenSignalType.callRinging:
        // Deliberately does not stop the invite loop: that loop is also the
        // only retry channel for a lost answer, and it costs one small
        // datagram per second. It ends when the answer lands (or the ringing
        // deadline does).
        return;
      case ZenSignalType.callOfferRequest:
        await _handleCallOfferRequest(signal);
        return;
      case ZenSignalType.callAccept:
        final bool wasRingingAccept =
            state.activeCall?.status == CallSessionStatus.ringing;
        if (_isKnownCallSignal(state.activeCall, signal)) {
          _stopCallReRing();
        }
        if (wasRingingAccept) {
          await _appendSystemMessage(
            peerAddress: signal.sender,
            event: SocialEventText('call.answeredBy', <String, String>{
              'name': _labelFor(signal, friends: state.friends),
              'kind': _callKind(signal.content).name,
            }),
            timestamp: timestamp,
          );
        }
        return;
      case ZenSignalType.callBusy:
        if (!_isTeardownForCurrentCall(signal)) {
          return;
        }
        await _closeCallMediaSession();
        await _dismissCallNotification(signal.sender);
        state = state.copyWith(
          backgroundAlerts: _removeCallAlertsForPeer(
            state.backgroundAlerts,
            signal.sender,
          ),
          inbox: _removeCallAlertsForPeer(state.inbox, signal.sender),
        );
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('call.busy', <String, String>{
            'name': _labelFor(signal, friends: state.friends),
            'kind': _callKind(signal.content).name,
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.callDecline:
        if (!_isTeardownForCurrentCall(signal)) {
          return;
        }
        await _closeCallMediaSession();
        await _dismissCallNotification(signal.sender);
        state = state.copyWith(
          backgroundAlerts: _removeCallAlertsForPeer(
            state.backgroundAlerts,
            signal.sender,
          ),
          inbox: _removeCallAlertsForPeer(state.inbox, signal.sender),
        );
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('call.declinedBy', <String, String>{
            'name': _labelFor(signal, friends: state.friends),
            'kind': _callKind(signal.content).name,
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.callEnd:
        if (isMissedCallNotice(signal) &&
            !_isKnownCallSignal(state.activeCall, signal)) {
          // The caller's word, sent reliably after its ring, that nobody
          // answered. A call still on file here (its hangup got lost) ends
          // below as a hangup ends it.
          await _noteMissedCallNotice(signal, timestamp);
          return;
        }
        if (!_isTeardownForCurrentCall(signal)) {
          return;
        }
        final CallSession? endedCall = state.activeCall;
        final bool missedIncomingCall =
            endedCall != null &&
            endedCall.isIncoming &&
            endedCall.status == CallSessionStatus.ringing &&
            _currentCallMatchesSignal(endedCall, signal);
        await _closeCallMediaSession();
        await _dismissCallNotification(signal.sender);
        state = state.copyWith(
          backgroundAlerts: _removeCallAlertsForPeer(
            state.backgroundAlerts,
            signal.sender,
          ),
          inbox: _removeCallAlertsForPeer(state.inbox, signal.sender),
        );
        if (missedIncomingCall && await _nobodySeesTheApp()) {
          // The caller hung up before anyone answered: a dismissible
          // missed-call note, posted into the per-peer slot. Only while the
          // app is off screen - with the app open the conversation already
          // shows it.
          await _systemNotifications.show(
            _missedCallSystemNotification(
              session: endedCall,
              createdAtMillis: timestamp,
            ),
          );
        }
        await _appendSystemMessage(
          peerAddress: signal.sender,
          event: SocialEventText('call.endedBy', <String, String>{
            'name': _labelFor(signal, friends: state.friends),
            'kind': _callKind(signal.content).name,
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.groupMessage:
        if (signal.groupId != null && signal.content != null) {
          if (state.groups[signal.groupId]?.isInvitePending ?? false) {
            // Kept so the invitation can show what the group talks about,
            // but only so much before the user decides to join.
            final List<ChatMessage> preJoin = await _messageTimelineStore.load(
              'group:${signal.groupId}',
            );
            if (preJoin.length >= kMaxPendingGroupMessages) {
              return;
            }
          }
          // The same message again (sent again after a retry, or both
          // directly and from a mailbox) is kept once: null.
          final String? messageId = signal.messageId == null
              ? 'grp-in-$timestamp-${signal.sender}'
              : await _incomingGroupMessageKey(signal);
          if (messageId == null) {
            return;
          }
          await _adoptDisappearTimerOf(signal, timestamp);
          // With its file (inline, or fetched as blocks), reply, forwarding.
          await _storeIncomingGroupMessage(signal, messageId, timestamp);
          if (_openGroupId == signal.groupId && _isUiFocused()) {
            unawaited(
              ref.read(zenSoundEffectsProvider).play(ZenSound.messageReceived),
            );
          }
          if (_openGroupId == signal.groupId && _isUiInteractive()) {
            // Read here as it comes: so on the account's other devices.
            unawaitedLogged(
              _mirrorGroupRead(signal.groupId!),
              context: 'Telling another device a group was read failed',
            );
          }
        }
        return;
      case ZenSignalType.groupLeave:
        final GroupProfile? leftGroup = state.groups[signal.groupId ?? ''];
        if (leftGroup != null && groupHasMember(leftGroup, signal.sender)) {
          final SocialEventText left = SocialEventText(
            'group.left',
            <String, String>{'name': _labelFor(signal, friends: state.friends)},
          );
          await _messageTimelineStore.append(
            'group:${leftGroup.id}',
            chatMessageWithEvent(
              ChatMessage(
                id: 'system-leave-$timestamp-${signal.sender}',
                sender: 'system',
                text: left.render(),
                sentAtMillis: timestamp,
                direction: ChatMessageDirection.system,
              ),
              left,
            ),
          );
          _bumpTimelineRevision();
        }
        return;
      case ZenSignalType.groupInvite:
      case ZenSignalType.groupUpdate:
      case ZenSignalType.groupInviteAck:
      case ZenSignalType.groupCallInvite:
      case ZenSignalType.groupCallJoin:
      case ZenSignalType.groupCallLeave:
      case ZenSignalType.groupCallState:
      case ZenSignalType.groupCallOffer:
      case ZenSignalType.groupCallAnswer:
      case ZenSignalType.groupCallDecline:
      case ZenSignalType.profileUpdate:
      case ZenSignalType.disappearTimer:
      case ZenSignalType.messageReaction:
      case ZenSignalType.messageEdit:
      case ZenSignalType.messageDelete:
      case ZenSignalType.friendRequest:
      case ZenSignalType.deepLink:
      case ZenSignalType.presence:
      case ZenSignalType.typing:
      case ZenSignalType.unknown:
        return;
    }
  }

  @override
  Future<bool> _timelineHasMessage({
    required String peerAddress,
    required String messageId,
  }) async {
    final List<ChatMessage> thread = await _messageTimelineStore.load(
      peerAddress,
    );
    return thread.any((ChatMessage message) => message.id == messageId);
  }

  @override
  Future<void> _upsertTimelineMessage({
    required String peerAddress,
    required String messageId,
    required ChatMessage Function(ChatMessage? existing) build,
    bool byTime = false,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    final List<ChatMessage> thread = await timelineStore.load(peerAddress);
    final int index = thread.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    final ChatMessage updated = build(index >= 0 ? thread[index] : null);
    final List<ChatMessage> next;
    if (index >= 0) {
      next = List<ChatMessage>.from(thread)..[index] = updated;
    } else if (byTime) {
      next = insertChronologically(thread, updated);
    } else {
      next = <ChatMessage>[...thread, updated];
    }
    await _saveTimelineChanges(peerAddress, thread, next);
    _bumpTimelineRevision();
  }

  @override
  Future<void> _appendSystemMessage({
    required String peerAddress,
    String? text,
    SocialEventText? event,
    required int timestamp,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    final ChatMessage message = ChatMessage(
      id: 'system-$timestamp-$peerAddress',
      sender: 'system',
      text: text ?? event?.render() ?? '',
      sentAtMillis: timestamp,
      direction: ChatMessageDirection.system,
    );
    await timelineStore.append(
      peerAddress,
      event == null ? message : chatMessageWithEvent(message, event),
    );
    _bumpTimelineRevision();
    await _applyConversationRetention(
      peerAddress: peerAddress,
      nowMillis: timestamp,
    );
  }

  Future<void> _sendNetworkMessage({
    required String peerAddress,
    required String messageId,
    required String text,
    required int sentAtMillis,
    Map<String, dynamic>? miniProfile,
    ChatReply? reply,
    bool forwarded = false,
    ChatLocation? location,
  }) async {
    if (!isRoutablePeerAddress(peerAddress)) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: peerAddress,
          payload: <String, dynamic>{
            ..._buildOutgoingTextPayload(
              messageId: messageId,
              text: text,
              sentAtMillis: sentAtMillis,
              ttl: state.disappearSecondsFor(peerAddress),
              ttlAt: state.disappearSetAtFor(peerAddress),
            ),
            'mp': ?miniProfile,
            if (reply != null) 're': reply.toJson(),
            if (forwarded) 'fwd': true,
            if (location != null) kLocationKey: location.toJson(),
          },
        );
  }

  Future<void> _sendNetworkAttachmentMessage({
    required String peerAddress,
    required ChatMessage message,
    EncodedChatAttachment? encoded,
  }) async {
    if (!isRoutablePeerAddress(peerAddress)) {
      return;
    }
    final String? attachmentEncoding = encoded?.encoding;
    final Map<String, dynamic> payload = <String, dynamic>{
      ..._buildOutgoingTextPayload(
        messageId: message.id,
        text: message.text,
        sentAtMillis: message.sentAtMillis,
        ttl: state.disappearSecondsFor(peerAddress),
        ttlAt: state.disappearSetAtFor(peerAddress),
      ),
      'messageType': message.type.name,
      if (encoded != null) 'attachmentData': encoded.base64Data,
      if (message.fileName != null) 'fileName': message.fileName,
      if (message.mimeType != null) 'mimeType': message.mimeType,
      if (message.attachmentSizeBytes != null)
        'attachmentSizeBytes': message.attachmentSizeBytes,
      if (message.durationMs != null) 'durationMs': message.durationMs,
      ..._outgoingChatExtras(message),
    };
    if (attachmentEncoding != null) {
      payload['attachmentEncoding'] = attachmentEncoding;
    }
    await ref
        .read(signalTransportProvider)
        .send(remoteAddress: peerAddress, payload: payload);
  }

  @override
  Future<void> _sendMessageAck({
    required String peerAddress,
    required String messageId,
  }) async {
    if (!isRoutablePeerAddress(peerAddress) || messageId.isEmpty) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: peerAddress,
          payload: <String, dynamic>{'type': 'message_ack', 'msgId': messageId},
        );
  }

  /// The friend's receipt: they read one's message [messageId]. After the
  /// conversation's other delivery changes, so neither writes over the
  /// other ([_editDeliveryOf]). Only for a receipt that came from the
  /// friend; this person reading the friend's messages is
  /// [_markIncomingReadUpTo].
  Future<void> _markMessageRead({
    required String peerAddress,
    required String messageId,
    required int readAtMillis,
  }) => _editDeliveryOf(
    peerAddress,
    () => _markMessageReadNow(
      peerAddress: peerAddress,
      messageId: messageId,
      readAtMillis: readAtMillis,
    ),
  );

  Future<void> _markMessageReadNow({
    required String peerAddress,
    required String messageId,
    required int readAtMillis,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    final List<ChatMessage> thread = await timelineStore.load(peerAddress);
    final int index = thread.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    // A receipt names a message this person sent: one naming a message of
    // the friend's says nothing about what they read.
    if (index < 0 || !thread[index].isOutgoing) {
      return;
    }
    // The receipt names the newest message they read: every one this person
    // sent before it is read too (it used to stay "delivered" under a read
    // one).
    final int upTo = thread[index].sentAtMillis;
    final List<ChatMessage> next = List<ChatMessage>.from(
      thread,
      growable: false,
    );
    bool changed = false;
    for (int i = 0; i < next.length; i++) {
      final ChatMessage m = next[i];
      final bool covered =
          i == index ||
          (m.isOutgoing && !m.isSystem && i < index && m.sentAtMillis <= upTo);
      if (covered && m.readAtMillis == null) {
        next[i] = m.copyWith(readAtMillis: readAtMillis);
        changed = true;
      }
    }
    if (!changed) {
      return;
    }
    await _saveTimelineChanges(peerAddress, thread, next);
    _bumpTimelineRevision();
  }

  @override
  Future<void> _sendReadReceiptIfNeeded(
    String peerAddress, {
    int? readAtMillis,
  }) async {
    if (!isRoutablePeerAddress(peerAddress)) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    final List<ChatMessage> thread = await timelineStore.load(peerAddress);
    ChatMessage? lastUnreadIncoming;
    for (final ChatMessage message in thread.reversed) {
      if (!message.isOutgoing &&
          !message.isSystem &&
          message.readAtMillis == null) {
        lastUnreadIncoming = message;
        break;
      }
    }
    if (lastUnreadIncoming == null || lastUnreadIncoming.id.trim().isEmpty) {
      return;
    }
    try {
      await ref
          .read(signalTransportProvider)
          .send(
            remoteAddress: peerAddress,
            payload: <String, dynamic>{
              'type': 'message_read',
              'msgId': lastUnreadIncoming.id,
            },
          );
    } catch (error, stackTrace) {
      logZenError('Sending read receipt failed', error, stackTrace);
      return;
    }
    // Every message of the friend's up to the one named is read now, so the
    // next opening finds nothing unread and sends no further receipt.
    await _markIncomingReadUpTo(
      peerAddress: peerAddress,
      messageId: lastUnreadIncoming.id,
      readAtMillis: readAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
    // Read on the account's other devices too, also what has not reached
    // them yet: the friend's messages up to there go with it.
    final int upTo = thread.indexOf(lastUnreadIncoming);
    await _tellOwnDevicesRead(peerAddress, <String, dynamic>{
      'type': 'message_read',
      'msgId': lastUnreadIncoming.id,
      _kReadRefsKey: <String>[
        for (int i = upTo; i >= 0; i--)
          if (thread[i].direction == ChatMessageDirection.incoming &&
              thread[i].id.isNotEmpty)
            thread[i].id,
      ].take(_kMaxReadRefs).toList(growable: false),
    });
  }

  /// Tells this account's other devices — never the friend or the members
  /// — that the conversation [to] (a friend's address or `group:<id>`) was
  /// read here as [payload] says: through the queue, so a device that is
  /// off gets it when it is back ([relayIsReadCopy]).
  Future<void> _tellOwnDevicesRead(
    String to,
    Map<String, dynamic> payload,
  ) async {
    final SignalTransport transport = ref.read(signalTransportProvider);
    if (transport is! AccountRoutingTransport) {
      return;
    }
    try {
      await transport.tellOwnDevices(to, payload);
    } on Object catch (error) {
      logZenWarning('Telling another device a chat was read failed: $error');
    }
  }

  /// This person read the conversation with [peerAddress] up to the
  /// friend's message [messageId] (here, or on another device of the
  /// account): it and every message of the friend's before it are read.
  /// One's own messages stay as they are: only the friend's receipt says
  /// they were read ([_markMessageRead]); marking them here showed
  /// "Przeczytano" under messages the friend never opened. Returns the ids
  /// of the friend's messages read by now, or null when [messageId] is no
  /// message of the friend's here.
  Future<Set<String>?> _markIncomingReadUpTo({
    required String peerAddress,
    required String messageId,
    required int readAtMillis,
  }) async {
    Set<String>? read;
    await _editDeliveryOf(peerAddress, () async {
      read = await _markIncomingReadUpToNow(
        peerAddress: peerAddress,
        messageId: messageId,
        readAtMillis: readAtMillis,
      );
    });
    return read;
  }

  Future<Set<String>?> _markIncomingReadUpToNow({
    required String peerAddress,
    required String messageId,
    required int readAtMillis,
  }) async {
    if (!ref.mounted) {
      return null;
    }
    bool friends(ChatMessage m) => m.direction == ChatMessageDirection.incoming;
    final List<ChatMessage> thread = await _messageTimelineStore.load(
      peerAddress,
    );
    final int index = thread.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    if (index < 0 || !friends(thread[index])) {
      return null;
    }
    // What came before it here, or was written before it (another device of
    // the account may have got the friend's messages in another order).
    final int upTo = thread[index].sentAtMillis;
    final List<ChatMessage> next = List<ChatMessage>.from(
      thread,
      growable: false,
    );
    bool changed = false;
    for (int i = 0; i < next.length; i++) {
      final ChatMessage m = next[i];
      if (friends(m) &&
          m.readAtMillis == null &&
          (i <= index || m.sentAtMillis <= upTo)) {
        next[i] = m.copyWith(readAtMillis: readAtMillis);
        changed = true;
      }
    }
    if (changed) {
      await _saveTimelineChanges(peerAddress, thread, next);
      _bumpTimelineRevision();
    }
    return <String>{
      for (final ChatMessage m in next)
        if (friends(m) && m.readAtMillis != null) m.id,
    };
  }

  /// The friend's messages [ids] in the conversation with [peerAddress] are
  /// read, and only those: they were read on another device of the account
  /// (one that came here only now, or the ones there before a newest one
  /// not here yet). Returns the ids of the friend's messages read by now.
  Future<Set<String>> _markIncomingReadIds({
    required String peerAddress,
    required Set<String> ids,
    required int readAtMillis,
  }) async {
    Set<String> read = const <String>{};
    await _editDeliveryOf(peerAddress, () async {
      if (!ref.mounted) {
        return;
      }
      final List<ChatMessage> thread = await _messageTimelineStore.load(
        peerAddress,
      );
      final List<ChatMessage> next = List<ChatMessage>.from(
        thread,
        growable: false,
      );
      bool changed = false;
      for (int i = 0; i < next.length; i++) {
        final ChatMessage m = next[i];
        if (m.direction == ChatMessageDirection.incoming &&
            m.readAtMillis == null &&
            ids.contains(m.id)) {
          next[i] = m.copyWith(readAtMillis: readAtMillis);
          changed = true;
        }
      }
      if (changed) {
        await _saveTimelineChanges(peerAddress, thread, next);
        _bumpTimelineRevision();
      }
      read = <String>{
        for (final ChatMessage m in next)
          if (m.direction == ChatMessageDirection.incoming &&
              m.readAtMillis != null)
            m.id,
      };
    });
    return read;
  }

  /// Another device of this account read the conversation with
  /// [peerAddress] up to the friend's message `msgId` and sent the friend
  /// its receipt: here it is read up to there too, its unread count drops
  /// and, once nothing in it is unread, its notification goes. Nothing is
  /// sent from here (the friend has the receipt already).
  ///
  /// The messages it read ([_kReadRefsKey], and `msgId`) that are not here
  /// yet are remembered: they come in read ([_takenAsReadElsewhere]). A copy
  /// from Zen 1.16.5 names only `msgId`.
  @override
  Future<void> _applyReadFromOtherDevice(
    String peerAddress,
    Map<String, dynamic> payload,
  ) async {
    final Object? id = payload['msgId'];
    if (id is! String || id.trim().isEmpty || id.length > kMaxSignalIdChars) {
      return;
    }
    final Set<String> refs = <String>{
      id.trim(),
      for (final Object? r in _readRefsOf(payload[_kReadRefsKey]))
        if (r is String && r.isNotEmpty && r.length <= kMaxSignalIdChars) r,
    };
    await _enqueueStateWork(() async {
      final FriendProfile? friend = state.friendByAddress(
        PeerShareCodec.normalizeAddress(peerAddress),
      );
      if (friend == null) {
        return;
      }
      final String peer = friend.address;
      final int now = DateTime.now().millisecondsSinceEpoch;
      final Set<String> here = <String>{
        for (final ChatMessage m in await _messageTimelineStore.load(peer))
          if (m.direction == ChatMessageDirection.incoming) m.id,
      };
      final List<String> absent = <String>[
        for (final String r in refs)
          if (!here.contains(r))
            readElsewhereKey(PeerShareCodec.normalizeAddress(peer), r),
      ];
      if (absent.isNotEmpty) {
        state = state.copyWith(
          readElsewhere: rememberReadElsewhere(
            state.readElsewhere,
            absent,
            now,
          ),
        );
      }
      Set<String>? read = await _markIncomingReadUpTo(
        peerAddress: peer,
        messageId: id.trim(),
        readAtMillis: now,
      );
      // The newest one read there is not here yet: the earlier ones that
      // are.
      final List<String> present = refs.where(here.contains).toList();
      if (read == null && present.isNotEmpty) {
        read = await _markIncomingReadIds(
          peerAddress: peer,
          ids: present.toSet(),
          readAtMillis: now,
        );
      }
      if (read == null || !ref.mounted) {
        if (absent.isNotEmpty && ref.mounted) {
          await _persistState();
        }
        return;
      }
      // The friend's messages that came while this app was in the
      // background wait in the queue to be counted as unread once it is on
      // screen: the ones read on the other device are not counted. They
      // still name the last message in the chat list.
      final List<QueuedSignal> queue = await _queueStore.load();
      final _QueueAfterRead after = _queueAfterRead(
        queue: queue,
        thread: await _messageTimelineStore.load(peer),
        read: read,
        idOf: (QueuedSignal q) =>
            q.signal.type == ZenSignalType.message &&
                PeerShareCodec.addressesEqual(q.signal.sender, peer)
            ? _incomingMessageIdOf(q.signal)
            : null,
        unreadHere: (ChatMessage m) =>
            m.direction == ChatMessageDirection.incoming &&
            m.readAtMillis == null,
      );
      final List<QueuedSignal> rest = after.rest;
      if (after.changed) {
        await _queueStore.save(rest);
      }
      final List<QueuedSignal> readQueued = after.read;
      final int unread = after.unread;
      final QueuedSignal? newest = readQueued.isEmpty
          ? null
          : readQueued.reduce(
              (QueuedSignal a, QueuedSignal b) =>
                  b.receivedAtMillis >= a.receivedAtMillis ? b : a,
            );
      final bool nothingUnread = unread == 0 && after.waiting == 0;
      final InboxEntry? alert = nothingUnread
          ? state.backgroundAlerts
                .where(
                  (InboxEntry e) =>
                      _backgroundAlertDedupKeyForEntry(e) == 'message:$peer',
                )
                .firstOrNull
          : null;
      state = state.copyWith(
        book: state.book.edit(
          peer,
          (FriendProfile f) => f.copyWith(
            unreadCount: f.unreadCount < unread ? f.unreadCount : unread,
            lastMessagePreview: newest == null
                ? null
                : _clipText(
                    chatPreviewLine(
                      newest.signal.content ?? t('Nowa wiadomość'),
                      type: newest.signal.messageType,
                      fileName: newest.signal.fileName,
                      mimeType: newest.signal.mimeType,
                    ),
                    kMaxStoredPreviewChars,
                  ),
            lastActivityLabel: newest == null
                ? null
                : activityStamp(newest.receivedAtMillis),
          ),
        ),
        backgroundAlerts: alert == null
            ? null
            : state.backgroundAlerts
                  .where((InboxEntry e) => e.id != alert.id)
                  .toList(growable: false),
        pendingSignalCount: after.changed ? rest.length : null,
      );
      await _persistState();
      if (nothingUnread) {
        await _systemNotifications.dismissSlot('message:$peer');
        if (alert != null) {
          await _systemNotifications.dismiss(alert.id);
        }
      }
    });
  }

  /// What was read last of each group here and told to this account's
  /// other devices ([_mirrorGroupRead]), by group id: the same is not told
  /// again.
  final Map<String, String> _groupReadMirrored = <String, String>{};

  /// Tells this account's other devices — never the members — that the
  /// group [groupId] was read here up to its newest message from a member
  /// (`group_read`, as a copy of what this device did, [kMirrorType]): its
  /// unread count drops there too and its notification goes. Groups have
  /// no read receipts, so nothing else would say it. A Zen before 1.16.5
  /// on another device ignores it.
  ///
  /// It goes through the queue ([_tellOwnDevicesRead]), once per newest
  /// message, with the members' messages up to there ([_kReadRefsKey]), so
  /// a device that gets them later takes them in read.
  @override
  Future<void> _mirrorGroupRead(String groupId) async {
    final List<ChatMessage> members = (await _messageTimelineStore.load(
      'group:$groupId',
    )).where(_isMemberMessage).toList(growable: false);
    final ChatMessage? newest = members.lastOrNull;
    if (newest == null || _groupReadMirrored[groupId] == newest.id) {
      return;
    }
    if (_groupReadMirrored.length >= 256) {
      _groupReadMirrored.remove(_groupReadMirrored.keys.first);
    }
    _groupReadMirrored[groupId] = newest.id;
    await _tellOwnDevicesRead('group:$groupId', <String, dynamic>{
      'type': _kGroupReadType,
      'groupId': groupId,
      'msgId': groupMessageWireId(newest.id),
      'author': newest.sender,
      _kReadRefsKey: <Map<String, dynamic>>[
        for (final ChatMessage m in members.reversed.take(_kMaxReadRefs))
          <String, dynamic>{'m': groupMessageWireId(m.id), 'a': m.sender},
      ],
    });
  }

  /// Another device of this account read the group `groupId` up to the
  /// message `msgId` of the member `author` ([_mirrorGroupRead]): here it
  /// is read up to there too, as a one-to-one chat read there is
  /// ([_applyReadFromOtherDevice]): its unread count drops to the members'
  /// messages after it, and once none is left its notifications go.
  @override
  Future<void> _applyGroupReadFromOtherDevice(
    Map<String, dynamic> payload,
  ) async {
    final Object? groupId = payload['groupId'];
    final Object? id = payload['msgId'];
    final Object? author = payload['author'];
    if (groupId is! String ||
        id is! String ||
        author is! String ||
        groupId.isEmpty ||
        id.isEmpty ||
        author.isEmpty ||
        id.length > kMaxSignalIdChars) {
      return;
    }
    // The members' messages read there ([_kReadRefsKey]); a copy from Zen
    // 1.16.5 names only the newest.
    final Set<(String, String)> refs = <(String, String)>{
      (id, author),
      for (final Object? r in _readRefsOf(payload[_kReadRefsKey]))
        if (r is Map &&
            r['m'] is String &&
            r['a'] is String &&
            (r['m'] as String).isNotEmpty &&
            (r['m'] as String).length <= kMaxSignalIdChars &&
            (r['a'] as String).isNotEmpty)
          (r['m'] as String, r['a'] as String),
    };
    await _enqueueStateWork(() async {
      final GroupProfile? group = state.groups[groupId];
      if (group == null || group.isInvitePending || !ref.mounted) {
        return;
      }
      final String key = 'group:$groupId';
      final List<ChatMessage> thread = await _messageTimelineStore.load(key);
      int indexOf((String, String) r) => thread.indexWhere(
        (ChatMessage m) =>
            _isMemberMessage(m) &&
            groupMessageWireId(m.id) == r.$1 &&
            _sameGroupAuthor(m, r.$2),
      );
      final int index = indexOf((id, author));
      // What is not here yet comes in read.
      final List<String> absent = <String>[
        for (final (String, String) r in refs)
          if (indexOf(r) < 0) readElsewhereKey(key, r.$1, author: r.$2),
      ];
      if (absent.isNotEmpty) {
        state = state.copyWith(
          readElsewhere: rememberReadElsewhere(
            state.readElsewhere,
            absent,
            DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }
      // What came before it here, or was written before it (this device
      // may have got the members' messages in another order); with the
      // newest one not here yet, the ones read there that are.
      final int upTo = index < 0 ? 0 : thread[index].sentAtMillis;
      final Set<String> read = <String>{
        for (int i = 0; i < thread.length; i++)
          if (_isMemberMessage(thread[i]) &&
              index >= 0 &&
              (i <= index || thread[i].sentAtMillis <= upTo))
            thread[i].id,
        for (final (String, String) r in refs)
          if (indexOf(r) case final int i when i >= 0) thread[i].id,
      };
      if (read.isEmpty) {
        if (absent.isNotEmpty) {
          await _persistState();
        }
        return;
      }
      String? keyOf(QueuedSignal q) {
        final String? wire = q.signal.messageId?.trim();
        if (q.signal.type != ZenSignalType.groupMessage ||
            q.signal.groupId != groupId ||
            wire == null ||
            wire.isEmpty) {
          return null;
        }
        return thread
            .where(
              (ChatMessage m) =>
                  _isMemberMessage(m) &&
                  groupMessageWireId(m.id) == wire &&
                  _sameGroupAuthor(m, q.signal.sender),
            )
            .firstOrNull
            ?.id;
      }

      final _QueueAfterRead after = _queueAfterRead(
        queue: await _queueStore.load(),
        thread: thread,
        read: read,
        idOf: keyOf,
        unreadHere: (ChatMessage m) =>
            _isMemberMessage(m) && !read.contains(m.id),
      );
      if (after.changed) {
        await _queueStore.save(after.rest);
      }
      final bool nothingUnread = after.unread == 0 && after.waiting == 0;
      bool tellsOfGroup(InboxEntry e) =>
          (e.id.startsWith('group-message-') ||
              e.id.startsWith('group-mention-')) &&
          _groupIdOfRouteKey(e.routeKey) == groupId;
      final List<InboxEntry> alerts = nothingUnread
          ? state.backgroundAlerts.where(tellsOfGroup).toList(growable: false)
          : const <InboxEntry>[];
      state = state.copyWith(
        groups: <String, GroupProfile>{
          ...state.groups,
          groupId: group.copyWith(
            unreadCount: min(group.unreadCount, after.unread),
          ),
        },
        backgroundAlerts: alerts.isEmpty
            ? null
            : state.backgroundAlerts
                  .where((InboxEntry e) => !tellsOfGroup(e))
                  .toList(growable: false),
        pendingSignalCount: after.changed ? after.rest.length : null,
      );
      await _persistState();
      if (nothingUnread) {
        for (final String slot in _chatNoticeSlots(key, '')) {
          await _systemNotifications.dismissSlot(slot);
        }
        for (final InboxEntry alert in alerts) {
          await _systemNotifications.dismiss(alert.id);
        }
      }
    });
  }

  /// The caller's word that another device of this account answered or
  /// declined the call ringing here ([isCallTakenElsewhere]): the ring, the
  /// call card and the call's notification go, and nothing is missed - no
  /// missed-call notice, no "ended" or missed line in the chat, nothing in
  /// the inbox. Only the call on file (by its id); a call already over here
  /// is left as it is.
  @override
  Future<void> _endCallTakenElsewhere(ZenSignal signal, int timestamp) async {
    if (!_isTeardownForCurrentCall(signal)) {
      return;
    }
    final bool ringingHere = _isKnownCallSignal(state.activeCall, signal);
    if (ringingHere) {
      await _closeCallMediaSession();
    }
    await _dismissCallNotification(signal.sender);
    state =
        _applySignal(
          state,
          signal,
          timestamp,
          appSettings: _appSettings,
          tick: _friendshipTick,
          openConversationAddress: _openConversationAddress,
          openGroupId: _openGroupId,
          dismissedOrRejectedGroupIds: _dismissedOrRejectedGroupIds,
        ).copyWith(
          backgroundAlerts: _removeCallAlertsForPeer(
            state.backgroundAlerts,
            signal.sender,
          ),
          inbox: _removeCallAlertsForPeer(state.inbox, signal.sender),
        );
    _syncCallRingingTimeout();
    await _persistState();
    await _syncRingingCallWindow();
  }

  /// [signal], a friend's or a member's message just kept here, was read on
  /// another device of the account before it came
  /// ([SocialHubState.readElsewhere]): it goes into the chat read. The chat
  /// list names it, but it counts as no unread message, raises no
  /// notification and waits for nothing in the queue. Returns whether it
  /// was such a message.
  @override
  Future<bool> _takenAsReadElsewhere(ZenSignal signal, int timestamp) async {
    if (state.readElsewhere.isEmpty) {
      return false;
    }
    final String? remembered = _readElsewhereKeyOf(signal);
    if (remembered == null) {
      return false;
    }
    state = state.copyWith(
      readElsewhere: Map<String, int>.of(state.readElsewhere)
        ..remove(remembered),
    );
    final String sender = PeerShareCodec.normalizeAddress(signal.sender);
    final String? groupId = signal.type == ZenSignalType.groupMessage
        ? signal.groupId
        : null;
    if (groupId == null) {
      await _markIncomingReadIds(
        peerAddress: sender,
        ids: <String>{_incomingMessageIdOf(signal)},
        readAtMillis: timestamp,
      );
    }
    final SocialHubState before = state;
    SocialHubState next = _applySignal(
      before,
      signal,
      timestamp,
      appSettings: _appSettings,
      tick: _friendshipTick,
      openConversationAddress: _openConversationAddress,
      openGroupId: _openGroupId,
      dismissedOrRejectedGroupIds: _dismissedOrRejectedGroupIds,
    );
    if (groupId != null) {
      final GroupProfile? was = before.groups[groupId];
      final GroupProfile? now = next.groups[groupId];
      if (was != null && now != null) {
        next = next.copyWith(
          groups: <String, GroupProfile>{
            ...next.groups,
            groupId: now.copyWith(unreadCount: was.unreadCount),
          },
        );
      }
    } else {
      final int unread = before.friendByAddress(sender)?.unreadCount ?? 0;
      next = next.copyWith(
        book: next.book.edit(
          sender,
          (FriendProfile f) => f.copyWith(unreadCount: unread),
        ),
      );
    }
    state = next.copyWith(inbox: before.inbox);
    await _persistState();
    return true;
  }

  /// The key [signal] (a friend's or a member's message) is remembered by
  /// as read on another device ([readElsewhereKey]), or `null` when it is
  /// not. In a group the author may be another device of the same member.
  String? _readElsewhereKeyOf(ZenSignal signal) {
    final String? wire = signal.messageId?.trim();
    if (signal.type == ZenSignalType.message) {
      final String key = readElsewhereKey(
        PeerShareCodec.normalizeAddress(signal.sender),
        _incomingMessageIdOf(signal),
      );
      return state.readElsewhere.containsKey(key) ? key : null;
    }
    final String? groupId = signal.groupId;
    if (signal.type != ZenSignalType.groupMessage ||
        groupId == null ||
        wire == null ||
        wire.isEmpty) {
      return null;
    }
    final String exact = readElsewhereKey(
      'group:$groupId',
      wire,
      author: signal.sender,
    );
    if (state.readElsewhere.containsKey(exact)) {
      return exact;
    }
    final String prefix = '${readElsewhereKey('group:$groupId', wire)}\n';
    final ChatMessage asTheirs = ChatMessage(
      id: wire,
      sender: signal.sender,
      text: '',
      sentAtMillis: 0,
      direction: ChatMessageDirection.incoming,
    );
    for (final String key in state.readElsewhere.keys) {
      if (key.startsWith(prefix) &&
          _sameGroupAuthor(asTheirs, key.substring(prefix.length))) {
        return key;
      }
    }
    return null;
  }

  @override
  Future<void> _sendFriendLifecycleSignal({
    required String peerAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String target = PeerShareCodec.normalizeAddress(peerAddress);
    if (!isRoutablePeerAddress(target)) {
      logZenWarning(
        'Cannot send friend lifecycle signal (${payload['type']}): peer address "$target" is not routable.',
      );
      return;
    }
    try {
      await ref
          .read(signalTransportProvider)
          .send(remoteAddress: target, payload: payload);
    } catch (error, stackTrace) {
      logZenError(
        'Failed to send friend lifecycle signal (${payload['type']}) to "$target"',
        error,
        stackTrace,
      );
    }
    // Retries, acknowledgements and offline delivery through friends' relays
    // are the transport's job now (see `RelayEngine`); the fixed burst of
    // four copies that used to live here only produced duplicates.
  }

  @override
  Future<void> _sendCallSignal({
    required String remoteAddress,
    required String type,
    required CallSession session,
  }) async {
    if (!isRoutablePeerAddress(remoteAddress)) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: remoteAddress,
          payload: <String, dynamic>{
            'type': type,
            'callId': session.id,
            'kind': session.kind.name,
          },
        );
  }

  /// True when [signal] tears down the call this side is actually on, and has
  /// not been handled yet.
  ///
  /// Teardown signals are re-sent, so a late repeat for a finished call would
  /// otherwise close the media session of the next call with the same peer —
  /// or append a second "call ended" line for the same one. Nothing on file
  /// means the call is already gone here, and the follow-up bookkeeping
  /// (missed-call note, notification cleanup) still has to run once.
  bool _isTeardownForCurrentCall(ZenSignal signal) {
    if (_isCallAlreadyTornDown(signal.callId)) {
      return false;
    }
    if (state.activeCall != null &&
        !_isKnownCallSignal(state.activeCall, signal)) {
      return false;
    }
    _rememberTornDownCall(signal.callId);
    return true;
  }

  /// Another call coming while this phone is on one, rings out, or is rung
  /// ([_secondCallAgainst]): the caller hears "busy", and the call already
  /// here goes on untouched, its media too. Closing them dropped a call
  /// still ringing out for the newcomer's, and the person called was never
  /// told: their phone rang on, and answered it waited on "Łączenie…" for a
  /// call that was gone. The one who called is noted as a missed call.
  ///
  /// Not while the call here is being ended (hung up, its ring run out): the
  /// newcomer's invite comes again a second later and then rings as any call
  /// does.
  Future<void> _refuseSecondCall(
    CallSession current,
    ZenSignal signal,
    int timestamp,
  ) async {
    if (_isCallAlreadyTornDown(current.id) ||
        _secondCallAgainst(current, signal) != _SecondCall.busy) {
      return;
    }
    final String callId = signal.callId?.trim() ?? '';
    final CallSession refused = CallSession(
      id: callId.isNotEmpty ? callId : 'call-$timestamp-${signal.sender}',
      peerAddress: signal.sender,
      displayName:
          state.friends[signal.sender]?.displayLabel ??
          _labelFor(signal, friends: state.friends),
      kind: _callKind(signal.content),
      status: CallSessionStatus.ringing,
      startedAtMillis: timestamp,
      isIncoming: true,
    );
    if (isRoutablePeerAddress(signal.sender)) {
      try {
        await _sendCallSignal(
          remoteAddress: signal.sender,
          type: 'busy',
          session: refused,
        );
      } catch (error, stackTrace) {
        logZenError('Answering a second call "busy" failed', error, stackTrace);
      }
    }
    if (callId.isNotEmpty) {
      // The caller re-sends its invite every second until "busy" lands:
      // noted once, by its call id.
      await _noteMissedCall(refused, timestamp: timestamp);
    }
  }

  /// A caller's word that its ring went unanswered ([isMissedCallNotice]),
  /// for a call not on file here: noted as a missed call at the time it was
  /// made (never later than now: the caller's clock may run ahead).
  Future<void> _noteMissedCallNotice(ZenSignal signal, int timestamp) async {
    final String callId = signal.callId?.trim() ?? '';
    if (callId.isEmpty || _isCallAlreadyTornDown(callId)) {
      // Ended here while it rang (the caller hung up, the ring ran out, it
      // was declined): that left its own note already.
      return;
    }
    final int calledAt = min(signal.sentAtMillis ?? timestamp, timestamp);
    await _noteMissedCall(
      CallSession(
        id: callId,
        peerAddress: signal.sender,
        displayName:
            state.friends[signal.sender]?.displayLabel ??
            _labelFor(signal, friends: state.friends),
        kind: _callKind(signal.content),
        status: CallSessionStatus.ringing,
        startedAtMillis: calledAt,
        isIncoming: true,
      ),
      timestamp: timestamp,
    );
  }

  /// Notes in the chat with [call]'s caller that [call] went unanswered
  /// here, once per call: nothing when the chat already tells of that call
  /// (its invite came, or it was noted as missed before). The line stands
  /// at the time the call was made. Its notification comes as the app's
  /// other missed-call notices do: while nobody sees the app, from a friend,
  /// with "Połączenia" on ([missedCallTold]).
  Future<void> _noteMissedCall(
    CallSession call, {
    required int timestamp,
  }) async {
    final String peer = call.peerAddress;
    final String key = '$peer|${call.id}';
    if (_missedCallsNoted.contains(key)) {
      return;
    }
    _missedCallsNoted.add(key);
    while (_missedCallsNoted.length > 64) {
      _missedCallsNoted.removeAt(0);
    }
    final List<ChatMessage> thread = await _messageTimelineStore.load(peer);
    if (thread.any(
      (ChatMessage m) => chatMessageEvent(m)?.args[_kCallEventArg] == call.id,
    )) {
      return;
    }
    final SocialEventText missed = SocialEventText(
      'call.missed',
      <String, String>{'kind': call.kind.name, _kCallEventArg: call.id},
    );
    await _upsertTimelineMessage(
      peerAddress: peer,
      messageId: 'system-missed-${call.id}',
      build: (ChatMessage? existing) =>
          existing ??
          chatMessageWithEvent(
            ChatMessage(
              id: 'system-missed-${call.id}',
              sender: 'system',
              text: missed.render(),
              sentAtMillis: call.startedAtMillis,
              direction: ChatMessageDirection.system,
            ),
            missed,
          ),
      byTime: true,
    );
    if (missedCallTold(peer, _alertFacts) && await _nobodySeesTheApp()) {
      await _systemNotifications.show(
        _missedCallSystemNotification(
          session: call,
          createdAtMillis: timestamp,
        ),
      );
    }
  }

  @override
  Future<void> _sendCallSignalQuietly({
    required String remoteAddress,
    required String type,
    required CallSession session,
  }) async {
    await _attemptCallSignal(
      remoteAddress: remoteAddress,
      type: type,
      session: session,
    );
    // Every quiet send is a teardown ('hangup' / 'call_decline'), and it goes
    // out as a single unacknowledged datagram. The invite is re-sent once a
    // second for the whole ringing window; a single hangup could be missed, and
    // the peer would stay on a call that was over.
    for (final Duration delay in _callTeardownRetryDelays) {
      final Timer timer = Timer(delay, () {
        if (!ref.mounted) {
          return;
        }
        unawaitedLogged(
          _attemptCallSignal(
            remoteAddress: remoteAddress,
            type: type,
            session: session,
          ),
          context: 'Re-sending the "$type" call signal failed',
        );
      });
      _callTeardownRetries.add(timer);
    }
  }

  Future<void> _attemptCallSignal({
    required String remoteAddress,
    required String type,
    required CallSession session,
  }) async {
    try {
      await _sendCallSignal(
        remoteAddress: remoteAddress,
        type: type,
        session: session,
      );
    } catch (error, stackTrace) {
      logZenError(
        'Sending the "$type" call signal failed; tearing down locally anyway',
        error,
        stackTrace,
      );
    }
  }
}

/// The argument of a call's chat line ([SocialEventText]) that names the
/// call (`call.inviteIn`, `call.missed`): a missed call the caller tells of
/// afterwards is noted only for a call the chat does not tell of yet.
const String _kCallEventArg = 'call';

/// How a call's invite or offer is met while another call is on file here.
enum _SecondCall {
  /// It takes the place of the call ringing here: the same person calls
  /// anew (their phone started over).
  takesOver,

  /// "Busy": the call here goes on.
  busy,

  /// Left alone: the person this phone calls, calling in a form the call
  /// on file cannot be told apart from (no call id).
  ignored,
}

/// How a call [signal] (an invite or an offer) of a call other than
/// [current] is met. A call already talking, one ringing out, one being
/// answered, a group call ringing in, and a call ringing in from someone
/// else all stay; the newcomer hears "busy". Only the person whose call
/// rings here may replace it with a new call of theirs, as the state
/// reducer does (`_shouldKeepCurrentCallOnIncomingSignal`). Two people
/// calling each other at once are told apart before this
/// (`_isSimultaneousCallGlare`).
_SecondCall _secondCallAgainst(CallSession current, ZenSignal signal) {
  if (current.status == CallSessionStatus.active) {
    return _SecondCall.busy;
  }
  if (current.isIncoming &&
      current.status == CallSessionStatus.ringing &&
      current.peerAddress == signal.sender) {
    return _SecondCall.takesOver;
  }
  if (!current.isGroup &&
      PeerShareCodec.addressesEqual(current.peerAddress, signal.sender)) {
    return _SecondCall.ignored;
  }
  return _SecondCall.busy;
}

/// The id of a friend's chat message: its own, else one made from what it
/// says (who wrote it, when, the text) — the same for every copy, however
/// late one comes, as the locked receiver tells such frames apart.
String _incomingMessageIdOf(ZenSignal signal) {
  final String? own = signal.messageId?.trim();
  if (own != null && own.isNotEmpty) {
    return own;
  }
  final String hash = frameContentHash(<String, dynamic>{
    'from': signal.sender,
    'at': signal.sentAtMillis,
    'text': signal.content,
    'file': signal.fileName,
  });
  return 'incoming-$hash';
}

/// A copy for this account's other devices only: a group read here up to
/// a member's message ([_SocialHubMessagesMixin._mirrorGroupRead]).
const String _kGroupReadType = 'group_read';

/// What a reading told to the account's other devices covers (in a copy of
/// `message_read` or `group_read`): the messages read up to there, newest
/// first, at most [_kMaxReadRefs] — ids, in a group `{m: id, a: author}`.
/// Zen 1.16.5 ignores it.
const String _kReadRefsKey = 'r';
const int _kMaxReadRefs = 20;

/// The entries of [raw] (a [_kReadRefsKey] list), at most [_kMaxReadRefs].
Iterable<Object?> _readRefsOf(Object? raw) =>
    raw is List ? raw.take(_kMaxReadRefs) : const <Object?>[];

/// A message from a member (or a friend), not one's own and not a note.
bool _isMemberMessage(ChatMessage m) =>
    m.direction == ChatMessageDirection.incoming;

/// What a chat read on another device of the account leaves of the
/// background queue ([_queueAfterRead]).
final class _QueueAfterRead {
  const _QueueAfterRead({
    required this.rest,
    required this.read,
    required this.unread,
    required this.waiting,
    required this.changed,
  });

  /// The queue without the copies of messages read there, the others
  /// standing for no more messages than are still unread.
  final List<QueuedSignal> rest;

  /// The copies taken out.
  final List<QueuedSignal> read;

  /// The chat's unread messages here that no copy still waiting stands
  /// for: the ones already counted.
  final int unread;

  /// Copies of the chat still waiting (each counted once Zen is back on
  /// the screen, with the messages folded into it).
  final int waiting;

  /// Whether [rest] differs from the queue.
  final bool changed;
}

/// [queue] after a chat was read on another device of the account up to
/// where [read] (ids of [thread]) says. [idOf] names the message of
/// [thread] a copy is of (`null`: a copy of something else). A copy of a
/// message read goes. A copy still waiting stands for its own message and,
/// past the queue's cap, for older ones folded into it
/// ([QueuedSignal.count]): those are taken from the unread messages before
/// it that no other copy stands for, and a count with fewer such messages
/// left (some were read there) is cut to them. Counted by id alone, the
/// folded messages were taken for counted ones, and replayed they were
/// counted as unread again.
_QueueAfterRead _queueAfterRead({
  required List<QueuedSignal> queue,
  required List<ChatMessage> thread,
  required Set<String> read,
  required String? Function(QueuedSignal q) idOf,
  required bool Function(ChatMessage m) unreadHere,
}) {
  final List<String> unreadIds = <String>[
    for (final ChatMessage m in thread)
      if (unreadHere(m)) m.id,
  ];
  final Map<String, int> place = <String, int>{
    for (int i = 0; i < unreadIds.length; i++) unreadIds[i]: i,
  };
  final Set<String> claimed = <String>{};
  final List<QueuedSignal> rest = <QueuedSignal>[];
  final List<QueuedSignal> taken = <QueuedSignal>[];
  int waiting = 0;
  bool changed = false;
  for (final QueuedSignal q in queue) {
    final String? id = idOf(q);
    if (id == null) {
      rest.add(q);
      continue;
    }
    if (read.contains(id)) {
      taken.add(q);
      changed = true;
      continue;
    }
    waiting++;
    claimed.add(id);
    final int more = q.count - 1;
    int took = 0;
    for (
      int i = (place[id] ?? unreadIds.length) - 1;
      i >= 0 && took < more;
      i--
    ) {
      if (claimed.add(unreadIds[i])) {
        took++;
      }
    }
    if (took < more) {
      rest.add(
        QueuedSignal(
          id: q.id,
          signal: q.signal,
          receivedAtMillis: q.receivedAtMillis,
          count: 1 + took,
        ),
      );
      changed = true;
    } else {
      rest.add(q);
    }
  }
  return _QueueAfterRead(
    rest: rest,
    read: taken,
    unread: unreadIds.where((String id) => !claimed.contains(id)).length,
    waiting: waiting,
    changed: changed,
  );
}

/// Friends whose clock this phone keeps in mind
/// ([_SocialHubMessagesMixin._clockLeadOf]).
const int _kMaxClockOffsets = 256;

/// Display time of an incoming message: the sender's own timestamp, as long as
/// it is plausible. It is never later than the moment it arrived (a sender
/// clock running fast must not push it below newer messages) and not absurdly
/// old (relays keep mail for two weeks at most).
int _effectiveSentAt(ZenSignal signal, int receivedAtMillis) {
  final int? claimed = signal.sentAtMillis;
  if (claimed != null) {
    // What friends' timestamps say about this phone's clock.
    ClockSkewTracker.instance.observe(signal.sender, claimed, receivedAtMillis);
  }
  if (claimed == null ||
      claimed > receivedAtMillis ||
      receivedAtMillis - claimed > const Duration(days: 15).inMilliseconds) {
    return receivedAtMillis;
  }
  return claimed;
}

/// [bytes], or the file at [path] (a plain path or one of [vault]'s), as
/// they leave this device: without the location, device and time data
/// `outgoing_media.dart` removes. What has nothing to remove, a kind it
/// does not know and a file too large to be read for it stay as they
/// are; a file that lost something goes on as bytes in memory.
Future<({Uint8List? bytes, String? path})> _attachmentWithoutMetadata(
  MediaVault vault,
  Uint8List? bytes,
  String? path,
) async {
  if (bytes != null) {
    return (bytes: await stripOutgoingMetadataSized(bytes), path: path);
  }
  if (path == null) {
    return (bytes: null, path: null);
  }
  try {
    final int length = await vault.length(path);
    if (length <= 0 || length > kMaxCleanedTransferBytes) {
      return (bytes: null, path: path);
    }
    final Uint8List head = await vault.readRange(path, 0, min(16, length));
    if (!canStripMetadata(head)) {
      return (bytes: null, path: path);
    }
    final Uint8List whole = await vault.read(path);
    final Uint8List clean = await stripOutgoingMetadataSized(whole);
    return identical(clean, whole)
        ? (bytes: null, path: path)
        : (bytes: clean, path: null);
  } on Object catch (error, stackTrace) {
    // Unreadable here: the send itself says what is wrong with it.
    logZenError('Reading an attachment to clean failed', error, stackTrace);
    return (bytes: null, path: path);
  }
}
