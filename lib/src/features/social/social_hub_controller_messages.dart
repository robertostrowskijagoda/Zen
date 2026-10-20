part of 'social_hub_controller.dart';

mixin _SocialHubMessagesMixin on _SocialHubControllerBase {
  Future<void> sendLocalMessage({
    required String peerAddress,
    required String text,
    String? displayName,
    int? sentAtMillis,
  }) async {
    final int timestamp = sentAtMillis ?? DateTime.now().millisecondsSinceEpoch;
    final String trimmed = text.trim();
    final String messageId = 'outgoing-$timestamp-$peerAddress';
    final bool requiresDeliveryAck = isRoutablePeerAddress(peerAddress);
    if (trimmed.isEmpty) {
      return;
    }

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
      ),
    );
    _bumpTimelineRevision();
    _updateFriendPreview(
      peerAddress: peerAddress,
      displayName: displayName,
      preview: trimmed,
    );
    try {
      await _sendNetworkMessage(
        peerAddress: peerAddress,
        messageId: messageId,
        text: trimmed,
        sentAtMillis: timestamp,
      );
      await _updateMessageDeliveryState(
        peerAddress: peerAddress,
        messageId: messageId,
        deliveryState: requiresDeliveryAck
            ? ChatMessageDeliveryState.sent
            : ChatMessageDeliveryState.delivered,
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
  }

  Future<void> sendTypingState({
    required String peerAddress,
    required bool isTyping,
  }) async {
    if (!isRoutablePeerAddress(peerAddress)) {
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
    String? gifUrl,
  }) async {
    final String? normalizedGifUrl = gifUrl?.trim().isNotEmpty == true
        ? gifUrl!.trim()
        : null;
    final bool isGifMessage = normalizedGifUrl != null;
    final String normalizedFileName = fileName.trim().isNotEmpty
        ? fileName.trim()
        : isGifMessage
        ? 'gif.gif'
        : '';
    final Uint8List? initialBytes = bytes == null || bytes.isEmpty
        ? null
        : bytes;
    final String? normalizedPath = attachmentPath?.trim().isNotEmpty == true
        ? attachmentPath!.trim()
        : null;
    if ((!isGifMessage && initialBytes == null && normalizedPath == null) ||
        normalizedFileName.isEmpty) {
      return;
    }
    final int timestamp = sentAtMillis ?? DateTime.now().millisecondsSinceEpoch;
    final String messageId = 'outgoing-$timestamp-$peerAddress';
    final bool requiresDeliveryAck = isRoutablePeerAddress(peerAddress);
    final String? resolvedMimeType = isGifMessage ? 'image/gif' : mimeType;
    final ChatMessageType resolvedType = isGifMessage
        ? ChatMessageType.image
        : type ??
              _attachmentTransport.inferType(
                mimeType: resolvedMimeType,
                fileName: normalizedFileName,
              );
    final int? attachmentSizeBytes;
    if (isGifMessage) {
      attachmentSizeBytes = null;
    } else if (initialBytes != null) {
      attachmentSizeBytes = initialBytes.length;
    } else {
      attachmentSizeBytes = await _mediaVault.length(normalizedPath!);
    }
    EncodedChatAttachment? encoded;
    Uint8List? inlineBytes = initialBytes;
    bool sendInline = !requiresDeliveryAck || isGifMessage;
    if (requiresDeliveryAck && !isGifMessage) {
      try {
        inlineBytes ??= attachmentSizeBytes! <= 1024 * 1024
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
      text: isGifMessage ? '' : normalizedFileName,
      sentAtMillis: timestamp,
      direction: ChatMessageDirection.outgoing,
      type: resolvedType,
      attachmentBytes: initialBytes,
      attachmentPath: normalizedPath,
      fileName: normalizedFileName,
      mimeType: resolvedMimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: durationMs,
      gifUrl: normalizedGifUrl,
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
      preview: isGifMessage
          ? '🎞 GIF'
          : chatMessageLabelForType(
              resolvedType,
              fileName: normalizedFileName,
              mimeType: resolvedMimeType,
              gifUrl: normalizedGifUrl,
            ),
    );

    if (!requiresDeliveryAck) {
      unawaited(_finalizeOutgoingMessage(peerAddress, timestamp));
      return;
    }

    try {
      if (isGifMessage) {
        await _sendNetworkAttachmentMessage(
          peerAddress: peerAddress,
          message: message,
        );
        await _updateMessageDeliveryState(
          peerAddress: peerAddress,
          messageId: messageId,
          deliveryState: requiresDeliveryAck
              ? ChatMessageDeliveryState.sent
              : ChatMessageDeliveryState.delivered,
        );
        return;
      }
      if (sendInline) {
        await _sendNetworkAttachmentMessage(
          peerAddress: peerAddress,
          message: message,
          encoded: encoded,
        );
        await _updateMessageDeliveryState(
          peerAddress: peerAddress,
          messageId: messageId,
          deliveryState: requiresDeliveryAck
              ? ChatMessageDeliveryState.sent
              : ChatMessageDeliveryState.delivered,
        );
      } else {
        await _queueOutgoingAttachmentTransfer(
          peerAddress: peerAddress,
          message: message,
          attachmentBytes: initialBytes,
          attachmentPath: normalizedPath,
          attachmentSizeBytes: attachmentSizeBytes!,
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
                gifUrl: signal.gifUrl,
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
                messageId: signal.messageId?.trim().isNotEmpty == true
                    ? signal.messageId!.trim()
                    : 'incoming-$timestamp-${signal.sender}',
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
              text: t('Nie udało się odebrać załącznika od {name}: {error}', {
                'name': _labelFor(signal, friends: state.friends),
                'error': error.message,
              }),
              timestamp: timestamp,
            );
            return;
          }
        }
        final String messageId = signal.messageId?.trim().isNotEmpty == true
            ? signal.messageId!.trim()
            : 'incoming-$timestamp-${signal.sender}';
        await _adoptDisappearTimerOf(signal, timestamp);
        final bool exists = await _timelineHasMessage(
          peerAddress: signal.sender,
          messageId: messageId,
        );
        if (!exists) {
          await _messageTimelineStore.append(
            signal.sender,
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
              gifUrl: signal.gifUrl,
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
          text: t('Połączenie z {name} jest gotowe.', {
            'name': _labelFor(signal, friends: state.friends),
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.friendReject:
        await _appendSystemMessage(
          peerAddress: signal.sender,
          text: t('{name} odrzucił(a) zaproszenie.', {
            'name': _labelFor(signal, friends: state.friends),
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.friendCancel:
        await _appendSystemMessage(
          peerAddress: signal.sender,
          text: t('{name} anulował(a) oczekujące zaproszenie.', {
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
            text: t('Transfer został anulowany i stan obu stron jest zgodny.'),
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
            currentCall.status == CallSessionStatus.active &&
            !_currentCallMatchesSignal(currentCall, signal) &&
            isRoutablePeerAddress(signal.sender)) {
          await _sendCallSignal(
            remoteAddress: signal.sender,
            type: 'busy',
            session: CallSession(
              id: signal.callId?.trim().isNotEmpty == true
                  ? signal.callId!.trim()
                  : 'call-$timestamp-${signal.sender}',
              peerAddress: signal.sender,
              displayName:
                  state.friends[signal.sender]?.displayLabel ??
                  _labelFor(signal, friends: state.friends),
              kind: _callKind(signal.content),
              status: CallSessionStatus.ringing,
              startedAtMillis: timestamp,
              isIncoming: true,
            ),
          );
          return;
        } else if (currentCall != null &&
            currentCall.status != CallSessionStatus.active &&
            !_currentCallMatchesSignal(currentCall, signal)) {
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
          text: t('Przyszło zaproszenie do rozmowy {kind}.', {
            'kind': _callKindLabel(signal.content),
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
            text: t('{name} odebrał(a) rozmowę {kind}.', {
              'name': _labelFor(signal, friends: state.friends),
              'kind': _callKindLabel(signal.content),
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
            text: t('{name} odebrał(a) rozmowę {kind}.', {
              'name': _labelFor(signal, friends: state.friends),
              'kind': _callKindLabel(signal.content),
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
          text: t(
            '{name} jest aktualnie zajęty(a) i nie może odebrać rozmowy '
            '{kind}.',
            {
              'name': _labelFor(signal, friends: state.friends),
              'kind': _callKindLabel(signal.content),
            },
          ),
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
          text: t('{name} odrzucił(a) rozmowę {kind}.', {
            'name': _labelFor(signal, friends: state.friends),
            'kind': _callKindLabel(signal.content),
          }),
          timestamp: timestamp,
        );
        return;
      case ZenSignalType.callEnd:
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
        if (missedIncomingCall && !_isUiFocused()) {
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
          text: t('{name} zakończył(a) rozmowę {kind}.', {
            'name': _labelFor(signal, friends: state.friends),
            'kind': _callKindLabel(signal.content),
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
          final String messageId =
              signal.messageId ?? 'grp-in-$timestamp-${signal.sender}';
          await _adoptDisappearTimerOf(signal, timestamp);
          await _messageTimelineStore.append(
            'group:${signal.groupId}',
            ChatMessage(
              id: messageId,
              sender: signal.sender,
              text: signal.content!,
              sentAtMillis: _effectiveSentAt(signal, timestamp),
              direction: ChatMessageDirection.incoming,
            ),
          );
          _bumpTimelineRevision();
        }
        return;
      case ZenSignalType.groupLeave:
        final GroupProfile? leftGroup = state.groups[signal.groupId ?? ''];
        if (leftGroup != null && groupHasMember(leftGroup, signal.sender)) {
          await _messageTimelineStore.append(
            'group:${leftGroup.id}',
            ChatMessage(
              id: 'system-leave-$timestamp-${signal.sender}',
              sender: 'system',
              text: t('{name} opuścił(a) grupę.', {
                'name': _labelFor(signal, friends: state.friends),
              }),
              sentAtMillis: timestamp,
              direction: ChatMessageDirection.system,
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
  }) async {
    if (!ref.mounted) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    final List<ChatMessage> thread = await timelineStore.load(peerAddress);
    final int index = thread.indexWhere(
      (ChatMessage message) => message.id == messageId,
    );
    final List<ChatMessage> next = List<ChatMessage>.from(
      thread,
      growable: true,
    );
    final ChatMessage updated = build(index >= 0 ? thread[index] : null);
    if (index >= 0) {
      next[index] = updated;
    } else {
      next.add(updated);
    }
    await timelineStore.save(peerAddress, List<ChatMessage>.unmodifiable(next));
    _bumpTimelineRevision();
  }

  @override
  Future<void> _appendSystemMessage({
    required String peerAddress,
    required String text,
    required int timestamp,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final MessageTimelineStore timelineStore = _messageTimelineStore;
    await timelineStore.append(
      peerAddress,
      ChatMessage(
        id: 'system-$timestamp-$peerAddress',
        sender: 'system',
        text: text,
        sentAtMillis: timestamp,
        direction: ChatMessageDirection.system,
      ),
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
  }) async {
    if (!isRoutablePeerAddress(peerAddress)) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: peerAddress,
          payload: _buildOutgoingTextPayload(
            messageId: messageId,
            text: text,
            sentAtMillis: sentAtMillis,
            ttl: state.disappearSecondsFor(peerAddress),
          ),
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
      if (message.gifUrl != null) 'gifUrl': message.gifUrl,
    };
    if (attachmentEncoding != null) {
      payload['attachmentEncoding'] = attachmentEncoding;
    }
    await ref
        .read(signalTransportProvider)
        .send(remoteAddress: peerAddress, payload: payload);
  }

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

  Future<void> _markMessageRead({
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
    if (index < 0 || thread[index].readAtMillis != null) {
      return;
    }
    final List<ChatMessage> next = List<ChatMessage>.from(
      thread,
      growable: false,
    );
    next[index] = next[index].copyWith(readAtMillis: readAtMillis);
    await timelineStore.save(peerAddress, next);
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
    await _markMessageRead(
      peerAddress: peerAddress,
      messageId: lastUnreadIncoming.id,
      readAtMillis: readAtMillis ?? DateTime.now().millisecondsSinceEpoch,
    );
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
    // second for the whole ringing window; the hangup used to get exactly one
    // attempt, and the peer that missed it stayed on a call that was over.
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

/// Display time of an incoming message: the sender's own timestamp, as long as
/// it is plausible. It is never later than the moment it arrived (a sender
/// clock running fast must not push it below newer messages) and not absurdly
/// old (relays keep mail for two weeks at most).
int _effectiveSentAt(ZenSignal signal, int receivedAtMillis) {
  final int? claimed = signal.sentAtMillis;
  if (claimed == null ||
      claimed > receivedAtMillis ||
      receivedAtMillis - claimed > const Duration(days: 15).inMilliseconds) {
    return receivedAtMillis;
  }
  return claimed;
}
