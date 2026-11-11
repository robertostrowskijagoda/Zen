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
    final Uint8List? initialBytes = bytes == null || bytes.isEmpty
        ? null
        : bytes;
    final String? normalizedPath = attachmentPath?.trim().isNotEmpty == true
        ? attachmentPath!.trim()
        : null;
    if ((initialBytes == null && normalizedPath == null) ||
        normalizedFileName.isEmpty) {
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
        Uint8List? attachmentBytes;
        StoredAttachment? stored;
        int? attachmentByteCount;
        if (signal.attachmentData != null &&
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
        final String messageId = _incomingMessageIdOf(signal);
        await _adoptDisappearTimerOf(signal, timestamp);
        final bool exists = await _timelineHasMessage(
          peerAddress: signal.sender,
          messageId: messageId,
        );
        if (!exists) {
          await _messageTimelineStore.append(
            signal.sender,
            _withSignalExtras(
              ChatMessage(
                id: messageId,
                sender: signal.sender,
                text: resolvedText,
                sentAtMillis: _effectiveSentAt(signal, timestamp),
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

  /// Another device of this account read the conversation with
  /// [peerAddress] up to the friend's message `msgId` and sent the friend
  /// its receipt: here it is read up to there too, its unread count drops
  /// and, once nothing in it is unread, its notification goes. Nothing is
  /// sent from here (the friend has the receipt already).
  @override
  Future<void> _applyReadFromOtherDevice(
    String peerAddress,
    Map<String, dynamic> payload,
  ) async {
    final Object? id = payload['msgId'];
    if (id is! String || id.trim().isEmpty) {
      return;
    }
    await _enqueueStateWork(() async {
      final FriendProfile? friend = state.friendByAddress(
        PeerShareCodec.normalizeAddress(peerAddress),
      );
      if (friend == null) {
        return;
      }
      final String peer = friend.address;
      final Set<String>? read = await _markIncomingReadUpTo(
        peerAddress: peer,
        messageId: id.trim(),
        readAtMillis: DateTime.now().millisecondsSinceEpoch,
      );
      if (read == null || !ref.mounted) {
        return;
      }
      // The friend's messages that came while this app was in the
      // background wait in the queue to be counted as unread once it is on
      // screen: the ones read on the other device are not counted. They
      // still name the last message in the chat list.
      bool fromFriend(QueuedSignal q) =>
          q.signal.type == ZenSignalType.message &&
          PeerShareCodec.addressesEqual(q.signal.sender, peer);
      final List<QueuedSignal> queue = await _queueStore.load();
      final List<QueuedSignal> readQueued = <QueuedSignal>[
        for (final QueuedSignal q in queue)
          if (fromFriend(q) && read.contains(_incomingMessageIdOf(q.signal))) q,
      ];
      final Set<String> unreadQueued = <String>{
        for (final QueuedSignal q in queue)
          if (fromFriend(q) && !read.contains(_incomingMessageIdOf(q.signal)))
            _incomingMessageIdOf(q.signal),
      };
      List<QueuedSignal> rest = queue;
      if (readQueued.isNotEmpty) {
        final Set<String> gone = <String>{
          for (final QueuedSignal q in readQueued) q.id,
        };
        rest = <QueuedSignal>[
          for (final QueuedSignal q in queue)
            if (!gone.contains(q.id)) q,
        ];
        await _queueStore.save(rest);
      }
      // Still unread and already counted: the friend's messages here that
      // are neither read nor waiting in the queue.
      final int unread = (await _messageTimelineStore.load(peer))
          .where(
            (ChatMessage m) =>
                m.direction == ChatMessageDirection.incoming &&
                m.readAtMillis == null &&
                !unreadQueued.contains(m.id),
          )
          .length;
      final QueuedSignal? newest = readQueued.isEmpty
          ? null
          : readQueued.reduce(
              (QueuedSignal a, QueuedSignal b) =>
                  b.receivedAtMillis >= a.receivedAtMillis ? b : a,
            );
      final bool nothingUnread = unread == 0 && unreadQueued.isEmpty;
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
        pendingSignalCount: readQueued.isEmpty ? null : rest.length,
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
