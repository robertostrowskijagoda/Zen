part of 'social_hub_controller.dart';

mixin _SocialHubTransfersMixin on _SocialHubControllerBase {
  @override
  Future<void> _queueOutgoingAttachmentTransfer({
    required String peerAddress,
    required ChatMessage message,
    Uint8List? attachmentBytes,
    String? attachmentPath,
    required int attachmentSizeBytes,
  }) async {
    final AttachmentTransferStore transferStore = _transferStore;
    OutgoingAttachmentTransfer transfer = OutgoingAttachmentTransfer(
      peerAddress: peerAddress,
      messageId: message.id,
      text: message.text,
      sentAtMillis: message.sentAtMillis,
      type: message.type,
      attachmentBytes: attachmentBytes,
      attachmentPath: attachmentPath,
      fileName: message.fileName,
      mimeType: message.mimeType,
      attachmentSizeBytes: attachmentSizeBytes,
      durationMs: message.durationMs,
    );
    await transferStore.saveOutgoing(transfer);
    try {
      await _sendAttachmentPlaceholder(transfer);
      transfer = transfer.copyWith(placeholderSent: true);
      await transferStore.saveOutgoing(transfer);
    } catch (error, stackTrace) {
      logZenError(
        'Queueing outgoing attachment placeholder failed',
        error,
        stackTrace,
      );
      await transferStore.deleteOutgoing(peerAddress, message.id);
      rethrow;
    }
    unawaited(
      _driveOutgoingAttachmentTransfer(
        peerAddress: peerAddress,
        messageId: message.id,
      ),
    );
  }

  @override
  Future<void> _persistIncomingAttachmentPlaceholder({
    required ZenSignal signal,
    required int timestamp,
  }) async {
    final String messageId = signal.messageId?.trim().isNotEmpty == true
        ? signal.messageId!.trim()
        : 'incoming-transfer-$timestamp-${signal.sender}';
    await _upsertTimelineMessage(
      peerAddress: signal.sender,
      messageId: messageId,
      build: (ChatMessage? existing) {
        final ChatMessage base =
            existing ??
            ChatMessage(
              id: messageId,
              sender: signal.sender,
              text: signal.content ?? t('📎 Załącznik'),
              sentAtMillis: timestamp,
              direction: ChatMessageDirection.incoming,
              type: signal.messageType ?? ChatMessageType.file,
              fileName: signal.fileName,
              mimeType: signal.mimeType,
              attachmentSizeBytes: signal.attachmentSizeBytes,
              durationMs: signal.durationMs,
              deliveryState: ChatMessageDeliveryState.sending,
            );
        return base.copyWith(
          text: signal.content ?? base.text,
          type: signal.messageType ?? base.type,
          fileName: signal.fileName ?? base.fileName,
          mimeType: signal.mimeType ?? base.mimeType,
          attachmentSizeBytes:
              signal.attachmentSizeBytes ?? base.attachmentSizeBytes,
          durationMs: signal.durationMs ?? base.durationMs,
          deliveryState: base.hasAttachment
              ? base.deliveryState
              : ChatMessageDeliveryState.sending,
        );
      },
    );
    await _applyConversationRetention(
      peerAddress: signal.sender,
      nowMillis: timestamp,
    );
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
    final int? chunkCount = signal.chunkCount;
    final int? transferBytes = signal.attachmentTransferBytes;
    if (chunkCount == null ||
        chunkCount <= 0 ||
        transferBytes == null ||
        transferBytes <= 0) {
      return;
    }
    final IncomingAttachmentTransfer? existing = await _transferStore
        .loadIncoming(signal.sender, messageId);
    if (existing != null) {
      // Announced once; a later placeholder cannot resize it.
      return;
    }
    if (!isPlausibleIncomingTransfer(
          transferBytes: transferBytes,
          chunkCount: chunkCount,
        ) ||
        !await _hasRoomForIncomingTransfer(signal.sender)) {
      // Bigger than anything this app can store, or too many unfinished
      // transfers from this peer at once: refused up front instead of
      // buffering whatever arrives.
      await _updateMessageDeliveryState(
        peerAddress: signal.sender,
        messageId: messageId,
        deliveryState: ChatMessageDeliveryState.failed,
      );
      return;
    }
    final IncomingAttachmentTransfer transfer = IncomingAttachmentTransfer(
      peerAddress: signal.sender,
      messageId: messageId,
      text: signal.content ?? t('📎 Załącznik'),
      sentAtMillis: timestamp,
      type: signal.messageType ?? ChatMessageType.file,
      transferBytes: transferBytes,
      chunkCount: chunkCount,
      fileName: signal.fileName,
      mimeType: signal.mimeType,
      attachmentSizeBytes: signal.attachmentSizeBytes,
      durationMs: signal.durationMs,
    );
    await _transferStore.saveIncoming(transfer);
  }

  @override
  Future<void> _persistIncomingAttachmentChunk({
    required ZenSignal signal,
    required int timestamp,
  }) async {
    final String messageId = signal.messageId?.trim() ?? '';
    final String chunkData = signal.chunkData?.trim() ?? '';
    final int chunkIndex = signal.chunkIndex ?? -1;
    final int chunkCount = signal.chunkCount ?? 0;
    final int transferBytes = signal.attachmentTransferBytes ?? 0;
    if (messageId.isEmpty ||
        chunkData.isEmpty ||
        chunkIndex < 0 ||
        chunkCount <= 0 ||
        transferBytes <= 0) {
      return;
    }

    if (chunkIndex >= chunkCount ||
        chunkData.length > kMaxIncomingAttachmentChunkBytes * 4 ~/ 3 + 4 ||
        !isPlausibleIncomingTransfer(
          transferBytes: transferBytes,
          chunkCount: chunkCount,
        )) {
      return;
    }

    await _persistIncomingAttachmentPlaceholder(
      signal: signal,
      timestamp: timestamp,
    );
    final Uint8List bytes;
    try {
      bytes = Uint8List.fromList(base64Decode(chunkData));
    } on FormatException {
      return;
    }

    // The placeholder step above creates the transfer record, or refuses it
    // (too big, too many at once): no record, nothing to add to.
    final IncomingAttachmentTransfer? current = await _transferStore
        .loadIncoming(signal.sender, messageId);
    if (current == null ||
        current.chunkCount != chunkCount ||
        current.transferBytes != transferBytes ||
        !current.acceptsChunk(chunkIndex, bytes.length)) {
      // A chunk that does not fit what was announced: out of range, over
      // the announced size, or a different transfer under the same id.
      return;
    }
    final IncomingAttachmentTransfer updated = current.addChunk(
      chunkIndex,
      bytes,
    );
    await _transferStore.saveIncoming(updated);
    unawaited(
      _sendAttachmentChunkAck(
        peerAddress: signal.sender,
        messageId: messageId,
        chunkIndex: chunkIndex,
      ).catchError((Object error, StackTrace stackTrace) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'zen',
            context: ErrorDescription('while sending an attachment chunk ack'),
          ),
        );
      }),
    );

    if (!updated.isComplete) {
      return;
    }

    final Uint8List attachmentBytes = updated.assembleBytes();
    final StoredAttachment stored = await _persistIncomingAttachmentFile(
      peerAddress: signal.sender,
      messageId: messageId,
      bytes: attachmentBytes,
      type: signal.messageType ?? updated.type,
      mimeType: signal.mimeType ?? updated.mimeType,
      fileName: signal.fileName ?? updated.fileName,
    );
    await _upsertTimelineMessage(
      peerAddress: signal.sender,
      messageId: messageId,
      build: (ChatMessage? existing) {
        final ChatMessage base =
            existing ??
            ChatMessage(
              id: messageId,
              sender: signal.sender,
              text: signal.content ?? t('📎 Załącznik'),
              sentAtMillis: timestamp,
              direction: ChatMessageDirection.incoming,
              type: signal.messageType ?? ChatMessageType.file,
            );
        // What it really is, not what the sender claimed (media guard).
        return base.copyWith(
          text: signal.content ?? base.text,
          type: stored.type,
          attachmentBytes: null,
          attachmentPath: stored.path,
          fileName: stored.fileName,
          mimeType: stored.mimeType,
          attachmentSizeBytes: stored.sizeBytes,
          durationMs:
              signal.durationMs ?? updated.durationMs ?? base.durationMs,
          deliveryState: ChatMessageDeliveryState.none,
        );
      },
    );
    await _applyConversationRetention(
      peerAddress: signal.sender,
      nowMillis: timestamp,
    );
    await _transferStore.deleteIncoming(signal.sender, messageId);
    // The whole file is here: a delivery receipt the sender gets even if it
    // is offline now (the chunks may have come from its friends' mailboxes,
    // long after it sent them).
    unawaitedLogged(
      _sendAttachmentDeliveredAck(
        peerAddress: signal.sender,
        messageId: messageId,
      ),
      context: 'Sending an attachment delivery receipt failed',
    );
  }

  Future<void> _sendAttachmentDeliveredAck({
    required String peerAddress,
    required String messageId,
  }) async {
    if (!ref.mounted ||
        !isRoutablePeerAddress(peerAddress) ||
        messageId.isEmpty) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: peerAddress,
          payload: <String, dynamic>{'type': 'message_ack', 'msgId': messageId},
        );
  }

  @override
  Future<void> _ackOutgoingAttachmentChunk(ZenSignal signal) async {
    final String messageId = signal.messageId?.trim() ?? '';
    final int chunkIndex = signal.chunkIndex ?? -1;
    if (messageId.isEmpty || chunkIndex < 0) {
      return;
    }
    final OutgoingAttachmentTransfer? transfer = await _transferStore
        .loadOutgoing(signal.sender, messageId);
    if (transfer == null || transfer.ackedChunkIndexes.contains(chunkIndex)) {
      return;
    }
    final OutgoingAttachmentTransfer updated = transfer.copyWith(
      ackedChunkIndexes: <int>[...transfer.ackedChunkIndexes, chunkIndex]
        ..sort(),
    );
    await _transferStore.saveOutgoing(updated);
    if (!updated.isComplete) {
      return;
    }
    await _upsertTimelineMessage(
      peerAddress: signal.sender,
      messageId: messageId,
      build: (ChatMessage? existing) {
        final ChatMessage base =
            existing ??
            ChatMessage(
              id: messageId,
              sender: 'self',
              text: updated.text,
              sentAtMillis: updated.sentAtMillis,
              direction: ChatMessageDirection.outgoing,
              type: updated.type,
            );
        return base.copyWith(
          text: updated.text,
          type: updated.type,
          attachmentBytes: updated.attachmentBytes,
          attachmentPath: updated.attachmentPath ?? base.attachmentPath,
          fileName: updated.fileName ?? base.fileName,
          mimeType: updated.mimeType ?? base.mimeType,
          attachmentSizeBytes:
              updated.attachmentSizeBytes ??
              base.attachmentSizeBytes ??
              updated.transferBytes,
          durationMs: updated.durationMs ?? base.durationMs,
          deliveryState: ChatMessageDeliveryState.delivered,
        );
      },
    );
    await _transferStore.deleteOutgoing(signal.sender, messageId);
  }

  /// Whether [peerAddress] may start one more chunked incoming transfer.
  /// Stale leftovers are swept first, so an abandoned transfer does not
  /// count against the peer forever.
  Future<bool> _hasRoomForIncomingTransfer(String peerAddress) async {
    final AttachmentTransferStore store = _transferStore;
    if (await store.countIncoming(peerAddress) <
        kMaxConcurrentIncomingTransfersPerPeer) {
      return true;
    }
    await _sweepStaleIncomingTransfers(force: true);
    return await store.countIncoming(peerAddress) <
        kMaxConcurrentIncomingTransfersPerPeer;
  }

  int _lastIncomingTransferSweepMillis = 0;

  @override
  Future<void> _pruneStaleIncomingTransfers() {
    return _sweepStaleIncomingTransfers(force: false);
  }

  /// Drops unfinished incoming transfers nobody wrote to for
  /// [kIncomingAttachmentTransferExpiry]: the sender gave up (or never
  /// meant to finish), and the half-received chunks would otherwise sit in
  /// storage for good. At most once an hour unless [force]d.
  Future<void> _sweepStaleIncomingTransfers({required bool force}) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        now - _lastIncomingTransferSweepMillis <
            const Duration(hours: 1).inMilliseconds) {
      return;
    }
    _lastIncomingTransferSweepMillis = now;
    try {
      await _transferStore.deleteStaleIncoming(
        olderThanMillis: now - kIncomingAttachmentTransferExpiry.inMilliseconds,
      );
    } catch (error, stackTrace) {
      logZenError(
        'Sweeping stale incoming transfers failed',
        error,
        stackTrace,
      );
    }
  }

  @override
  Future<void> _acceptIncomingRealtimeAttachmentTransfer({
    required ZenSignal signal,
    required int timestamp,
  }) async {
    final String messageId = signal.messageId?.trim() ?? '';
    final Map<String, dynamic>? description = signal.sessionDescription;
    final int transferBytes = signal.attachmentTransferBytes ?? 0;
    if (messageId.isEmpty || description == null || transferBytes <= 0) {
      return;
    }
    final String key = AttachmentTransferStore.scopeKey(
      signal.sender,
      messageId,
    );
    if (_activeRealtimeTransfers.containsKey(key)) {
      return;
    }
    final String peerPrefix = AttachmentTransferStore.peerScopePrefix(
      signal.sender,
    );
    if (transferBytes > kMaxIncomingAttachmentBytes ||
        _activeRealtimeTransfers.length >= kMaxConcurrentRealtimeTransfers ||
        _activeRealtimeTransfers.keys
                .where((String active) => active.startsWith(peerPrefix))
                .length >=
            kMaxConcurrentRealtimeTransfersPerPeer) {
      // Each offer costs a peer connection and the whole file in memory:
      // past these limits the offer is left unanswered and the sender falls
      // back to the chunked path once its handshake times out.
      return;
    }
    await _upsertTimelineMessage(
      peerAddress: signal.sender,
      messageId: messageId,
      build: (ChatMessage? existing) {
        final ChatMessage base =
            existing ??
            ChatMessage(
              id: messageId,
              sender: signal.sender,
              text: signal.content ?? t('📎 Załącznik'),
              sentAtMillis: timestamp,
              direction: ChatMessageDirection.incoming,
              type: signal.messageType ?? ChatMessageType.file,
              fileName: signal.fileName,
              mimeType: signal.mimeType,
              attachmentSizeBytes:
                  signal.attachmentSizeBytes ?? signal.attachmentTransferBytes,
              durationMs: signal.durationMs,
              deliveryState: ChatMessageDeliveryState.sending,
            );
        return base.copyWith(
          text: signal.content ?? base.text,
          type: signal.messageType ?? base.type,
          fileName: signal.fileName ?? base.fileName,
          mimeType: signal.mimeType ?? base.mimeType,
          attachmentSizeBytes:
              signal.attachmentSizeBytes ??
              signal.attachmentTransferBytes ??
              base.attachmentSizeBytes,
          durationMs: signal.durationMs ?? base.durationMs,
          deliveryState: base.hasAttachment
              ? ChatMessageDeliveryState.none
              : ChatMessageDeliveryState.sending,
        );
      },
    );
    final RealtimeAttachmentTransferSession session = _realtimeTransferFactory(
      transferId: messageId,
      remoteAddress: signal.sender,
    );
    _activeRealtimeTransfers[key] = session;
    session.onComplete = (Uint8List attachmentBytes) {
      if (!ref.mounted) {
        return;
      }
      unawaitedLogged(
        _finishIncomingRealtimeAttachmentTransfer(
          signal: signal,
          timestamp: timestamp,
          attachmentBytes: attachmentBytes,
        ),
        context: 'Finishing incoming realtime attachment transfer failed',
      );
    };
    session.onError = (Object error) {
      if (!_shouldSuppressRealtimeTransferError(error)) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            library: 'zen',
            context: ErrorDescription(
              'while receiving a realtime attachment transfer',
            ),
          ),
        );
      }
      unawaitedLogged(
        _closeRealtimeTransferSession(signal.sender, messageId),
        context: 'Closing failed incoming realtime transfer session failed',
      );
    };
    try {
      await session.acceptIncoming(
        description: description,
        fileSize: transferBytes,
      );
    } catch (error, stackTrace) {
      if (!_shouldSuppressRealtimeTransferError(error)) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'zen',
            context: ErrorDescription(
              'while accepting a realtime attachment transfer',
            ),
          ),
        );
      }
      await _closeRealtimeTransferSession(signal.sender, messageId);
    }
  }

  Future<void> _finishIncomingRealtimeAttachmentTransfer({
    required ZenSignal signal,
    required int timestamp,
    required Uint8List attachmentBytes,
  }) async {
    final String messageId = signal.messageId?.trim() ?? '';
    if (messageId.isEmpty || !ref.mounted) {
      return;
    }
    final StoredAttachment stored = await _persistIncomingAttachmentFile(
      peerAddress: signal.sender,
      messageId: messageId,
      bytes: attachmentBytes,
      type: signal.messageType ?? ChatMessageType.file,
      mimeType: signal.mimeType,
      fileName: signal.fileName,
    );
    if (!ref.mounted) {
      return;
    }
    await _upsertTimelineMessage(
      peerAddress: signal.sender,
      messageId: messageId,
      build: (ChatMessage? existing) {
        final ChatMessage base =
            existing ??
            ChatMessage(
              id: messageId,
              sender: signal.sender,
              text: signal.content ?? t('📎 Załącznik'),
              sentAtMillis: timestamp,
              direction: ChatMessageDirection.incoming,
              type: signal.messageType ?? ChatMessageType.file,
            );
        // What it really is, not what the sender claimed (media guard).
        return base.copyWith(
          text: signal.content ?? base.text,
          type: stored.type,
          attachmentBytes: null,
          attachmentPath: stored.path,
          fileName: stored.fileName,
          mimeType: stored.mimeType,
          attachmentSizeBytes: stored.sizeBytes,
          durationMs: signal.durationMs ?? base.durationMs,
          deliveryState: ChatMessageDeliveryState.none,
        );
      },
    );
    if (!ref.mounted) {
      return;
    }
    await _applyConversationRetention(
      peerAddress: signal.sender,
      nowMillis: timestamp,
    );
    if (!ref.mounted) {
      return;
    }
    await _transferStore.deleteIncoming(signal.sender, messageId);
    await _closeRealtimeTransferSession(signal.sender, messageId);
  }

  @override
  Future<void> _applyOutgoingRealtimeTransferAnswer(ZenSignal signal) async {
    final String messageId = signal.messageId?.trim() ?? '';
    final Map<String, dynamic>? description = signal.sessionDescription;
    if (messageId.isEmpty || description == null) {
      return;
    }
    final RealtimeAttachmentTransferSession? session =
        _activeRealtimeTransfers[AttachmentTransferStore.scopeKey(
          signal.sender,
          messageId,
        )];
    if (session == null) {
      return;
    }
    try {
      await session.applyRemoteAnswer(description);
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'zen',
          context: ErrorDescription(
            'while applying a realtime attachment transfer answer',
          ),
        ),
      );
      await _closeRealtimeTransferSession(signal.sender, messageId);
    }
  }

  @override
  Future<void> _closeRealtimeTransferSession(
    String peerAddress,
    String messageId,
  ) async {
    if (messageId.isEmpty) {
      return;
    }
    final String key = AttachmentTransferStore.scopeKey(peerAddress, messageId);
    final RealtimeAttachmentTransferSession? session = _activeRealtimeTransfers
        .remove(key);
    if (session == null) {
      return;
    }
    await session.close();
  }

  @override
  Future<void> _resumeOutgoingAttachmentTransfers() async {
    if (!ref.mounted) {
      return;
    }
    final AttachmentTransferStore transferStore = _transferStore;
    final List<OutgoingAttachmentTransfer> transfers = await transferStore
        .loadAllOutgoing();
    if (!ref.mounted) {
      return;
    }
    for (final OutgoingAttachmentTransfer transfer in transfers) {
      unawaited(
        _driveOutgoingAttachmentTransfer(
          peerAddress: transfer.peerAddress,
          messageId: transfer.messageId,
        ),
      );
    }
  }

  Future<void> _driveOutgoingAttachmentTransfer({
    required String peerAddress,
    required String messageId,
  }) async {
    if (!ref.mounted) {
      return;
    }
    final AttachmentTransferStore transferStore = _transferStore;
    final String key = AttachmentTransferStore.scopeKey(peerAddress, messageId);
    if (!_activeOutgoingTransfers.add(key)) {
      return;
    }
    try {
      OutgoingAttachmentTransfer? transfer = await transferStore.loadOutgoing(
        peerAddress,
        messageId,
      );
      if (transfer == null) {
        return;
      }
      if (!transfer.placeholderSent) {
        await _sendAttachmentPlaceholder(transfer);
        transfer = transfer.copyWith(placeholderSent: true);
        await transferStore.saveOutgoing(transfer);
      }
      final bool completedViaRealtime =
          await _tryRealtimeOutgoingAttachmentTransfer(transfer);
      if (completedViaRealtime) {
        final OutgoingAttachmentTransfer? completed = await transferStore
            .loadOutgoing(peerAddress, messageId);
        if (completed == null) {
          return;
        }
        await _upsertTimelineMessage(
          peerAddress: peerAddress,
          messageId: messageId,
          build: (ChatMessage? existing) {
            final ChatMessage base =
                existing ??
                ChatMessage(
                  id: messageId,
                  sender: 'self',
                  text: completed.text,
                  sentAtMillis: completed.sentAtMillis,
                  direction: ChatMessageDirection.outgoing,
                  type: completed.type,
                );
            return base.copyWith(
              text: completed.text,
              type: completed.type,
              attachmentBytes: completed.attachmentBytes,
              attachmentPath: completed.attachmentPath ?? base.attachmentPath,
              fileName: completed.fileName ?? base.fileName,
              mimeType: completed.mimeType ?? base.mimeType,
              attachmentSizeBytes:
                  completed.attachmentSizeBytes ??
                  base.attachmentSizeBytes ??
                  completed.transferBytes,
              durationMs: completed.durationMs ?? base.durationMs,
              deliveryState: ChatMessageDeliveryState.delivered,
            );
          },
        );
        await transferStore.deleteOutgoing(peerAddress, messageId);
        return;
      }
      if (await _handOutgoingAttachmentToMailboxes(transfer)) {
        return;
      }
      final AttachmentTransferDispatchResult result = await _transferRunner.run(
        loadState: () async {
          final OutgoingAttachmentTransfer? current = await transferStore
              .loadOutgoing(peerAddress, messageId);
          if (current == null) {
            return null;
          }
          return AttachmentTransferDispatchState(
            chunkCount: current.chunkCount,
            ackedChunkIndexes: current.ackedChunkIndexes,
          );
        },
        sendChunk: (int chunkIndex) async {
          final OutgoingAttachmentTransfer? current = await transferStore
              .loadOutgoing(peerAddress, messageId);
          if (current == null) {
            return false;
          }
          return _sendAttachmentChunk(current, chunkIndex);
        },
      );
      if (result == AttachmentTransferDispatchResult.completed) {
        final OutgoingAttachmentTransfer? completed = await transferStore
            .loadOutgoing(peerAddress, messageId);
        if (completed == null) {
          return;
        }
        await _upsertTimelineMessage(
          peerAddress: peerAddress,
          messageId: messageId,
          build: (ChatMessage? existing) {
            final ChatMessage base =
                existing ??
                ChatMessage(
                  id: messageId,
                  sender: 'self',
                  text: completed.text,
                  sentAtMillis: completed.sentAtMillis,
                  direction: ChatMessageDirection.outgoing,
                  type: completed.type,
                );
            return base.copyWith(
              text: completed.text,
              type: completed.type,
              attachmentBytes: completed.attachmentBytes,
              attachmentPath: completed.attachmentPath ?? base.attachmentPath,
              fileName: completed.fileName ?? base.fileName,
              mimeType: completed.mimeType ?? base.mimeType,
              attachmentSizeBytes:
                  completed.attachmentSizeBytes ??
                  base.attachmentSizeBytes ??
                  completed.transferBytes,
              durationMs: completed.durationMs ?? base.durationMs,
              deliveryState: ChatMessageDeliveryState.delivered,
            );
          },
        );
        await transferStore.deleteOutgoing(peerAddress, messageId);
        return;
      }
      if (result == AttachmentTransferDispatchResult.sendFailed) {
        await _sendAttachmentTransferCancel(
          peerAddress: peerAddress,
          messageId: messageId,
        );
        await _updateMessageDeliveryState(
          peerAddress: peerAddress,
          messageId: messageId,
          deliveryState: ChatMessageDeliveryState.failed,
        );
        await transferStore.deleteOutgoing(peerAddress, messageId);
      }
    } finally {
      _activeOutgoingTransfers.remove(key);
    }
  }

  /// The realtime path did not work — most often because the recipient is
  /// offline. If the recipient announced mailboxes that can hold the file,
  /// it goes there: sealed chunks wait with its friends (within their
  /// quota, for as long as messages wait) and its app gets them as the
  /// usual chunks once it is back. Otherwise — or if the mailboxes cannot take it — the caller goes
  /// on with the chunked transfer, which needs both devices online.
  ///
  /// Returns whether the mailboxes took it over; the message then shows as
  /// sent, and as delivered once the recipient's receipt comes back.
  Future<bool> _handOutgoingAttachmentToMailboxes(
    OutgoingAttachmentTransfer transfer,
  ) async {
    final RelayEngine? engine = ref.read(relayEngineProvider);
    if (engine == null || !engine.supportsBlobs || !ref.mounted) {
      return false;
    }
    final MediaVault vault = _mediaVault;
    final bool handed;
    try {
      if (!await engine.canSendAttachmentTo(
        transfer.peerAddress,
        bytes: transfer.transferBytes,
        chunkSize: transfer.chunkSizeBytes,
      )) {
        return false;
      }
      handed = await engine.submitAttachment(
        recipient: transfer.peerAddress,
        messageId: transfer.messageId,
        meta: <String, dynamic>{
          'text': transfer.text,
          'createdAt': DateTime.fromMillisecondsSinceEpoch(
            transfer.sentAtMillis,
          ).toUtc().toIso8601String(),
          'messageType': transfer.type.name,
          'fileName': ?transfer.fileName,
          'mimeType': ?transfer.mimeType,
          'attachmentSizeBytes': ?transfer.attachmentSizeBytes,
          'durationMs': ?transfer.durationMs,
        },
        totalBytes: transfer.transferBytes,
        chunkSize: transfer.chunkSizeBytes,
        readChunk: (int index) => transfer.chunkAt(index, vault: vault),
      );
    } catch (error, stackTrace) {
      logZenError(
        'Handing an attachment to the mailboxes failed',
        error,
        stackTrace,
      );
      return false;
    }
    if (!handed || !ref.mounted) {
      return handed;
    }
    await _upsertTimelineMessage(
      peerAddress: transfer.peerAddress,
      messageId: transfer.messageId,
      build: (ChatMessage? existing) {
        final ChatMessage base =
            existing ??
            ChatMessage(
              id: transfer.messageId,
              sender: 'self',
              text: transfer.text,
              sentAtMillis: transfer.sentAtMillis,
              direction: ChatMessageDirection.outgoing,
              type: transfer.type,
              attachmentBytes: transfer.attachmentBytes,
              attachmentPath: transfer.attachmentPath,
              fileName: transfer.fileName,
              mimeType: transfer.mimeType,
              attachmentSizeBytes: transfer.attachmentSizeBytes,
              durationMs: transfer.durationMs,
            );
        // Its receipt may already be in: delivered stays delivered.
        return base.deliveryState == ChatMessageDeliveryState.delivered
            ? base
            : base.copyWith(deliveryState: ChatMessageDeliveryState.sent);
      },
    );
    await _transferStore.deleteOutgoing(
      transfer.peerAddress,
      transfer.messageId,
    );
    return true;
  }

  Future<bool> _tryRealtimeOutgoingAttachmentTransfer(
    OutgoingAttachmentTransfer transfer,
  ) async {
    final Uint8List? bytes = transfer.attachmentBytes;
    if (bytes == null || bytes.isEmpty) {
      return false;
    }
    final String key = AttachmentTransferStore.scopeKey(
      transfer.peerAddress,
      transfer.messageId,
    );
    final RealtimeAttachmentTransferSession session =
        _activeRealtimeTransfers[key] ??
        _realtimeTransferFactory(
          transferId: transfer.messageId,
          remoteAddress: transfer.peerAddress,
        );
    _activeRealtimeTransfers[key] = session;
    try {
      await session.send(
        bytes: bytes,
        text: transfer.text,
        type: transfer.type,
        fileName: transfer.fileName,
        mimeType: transfer.mimeType,
        attachmentSizeBytes: transfer.attachmentSizeBytes,
        durationMs: transfer.durationMs,
      );
      await _closeRealtimeTransferSession(
        transfer.peerAddress,
        transfer.messageId,
      );
      return true;
    } catch (error, stackTrace) {
      if (!_shouldSuppressRealtimeTransferError(error)) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'zen',
            context: ErrorDescription(
              'while sending a realtime attachment transfer',
            ),
          ),
        );
      }
      await _closeRealtimeTransferSession(
        transfer.peerAddress,
        transfer.messageId,
      );
      return false;
    }
  }

  bool _shouldSuppressRealtimeTransferError(Object error) {
    return error is TimeoutException ||
        (error is StateError &&
            '$error'.contains('WebRTC relay is unavailable'));
  }

  Future<void> _sendAttachmentPlaceholder(
    OutgoingAttachmentTransfer transfer,
  ) async {
    if (!ref.mounted) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: transfer.peerAddress,
          payload: <String, dynamic>{
            'type': 'message_placeholder',
            'msgId': transfer.messageId,
            'text': transfer.text,
            'createdAt': DateTime.fromMillisecondsSinceEpoch(
              transfer.sentAtMillis,
            ).toUtc().toIso8601String(),
            'messageType': transfer.type.name,
            if (transfer.fileName != null) 'fileName': transfer.fileName,
            if (transfer.mimeType != null) 'mimeType': transfer.mimeType,
            if (transfer.attachmentSizeBytes != null)
              'attachmentSizeBytes': transfer.attachmentSizeBytes,
            if (transfer.durationMs != null) 'durationMs': transfer.durationMs,
            'attachmentTransferBytes': transfer.transferBytes,
            'chunkCount': transfer.chunkCount,
          },
        );
  }

  Future<bool> _sendAttachmentChunk(
    OutgoingAttachmentTransfer transfer,
    int chunkIndex,
  ) async {
    if (!ref.mounted) {
      return false;
    }
    try {
      final Uint8List chunkBytes = await transfer.chunkAt(
        chunkIndex,
        vault: _mediaVault,
      );
      await ref
          .read(signalTransportProvider)
          .send(
            remoteAddress: transfer.peerAddress,
            payload: <String, dynamic>{
              'type': 'message_chunk',
              'msgId': transfer.messageId,
              'text': transfer.text,
              'createdAt': DateTime.fromMillisecondsSinceEpoch(
                transfer.sentAtMillis,
              ).toUtc().toIso8601String(),
              'messageType': transfer.type.name,
              if (transfer.fileName != null) 'fileName': transfer.fileName,
              if (transfer.mimeType != null) 'mimeType': transfer.mimeType,
              if (transfer.attachmentSizeBytes != null)
                'attachmentSizeBytes': transfer.attachmentSizeBytes,
              if (transfer.durationMs != null)
                'durationMs': transfer.durationMs,
              'attachmentTransferBytes': transfer.transferBytes,
              'chunkIndex': chunkIndex,
              'chunkCount': transfer.chunkCount,
              'chunkData': base64Encode(chunkBytes),
            },
          );
      return true;
    } catch (error, stackTrace) {
      logZenError('Sending attachment chunk failed', error, stackTrace);
      return false;
    }
  }

  Future<void> _sendAttachmentChunkAck({
    required String peerAddress,
    required String messageId,
    required int chunkIndex,
  }) {
    if (!ref.mounted) {
      return Future<void>.value();
    }
    return ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: peerAddress,
          payload: <String, dynamic>{
            'type': 'message_chunk_ack',
            'msgId': messageId,
            'chunkIndex': chunkIndex,
          },
        );
  }

  Future<void> _sendAttachmentTransferCancel({
    required String peerAddress,
    required String messageId,
  }) async {
    if (!ref.mounted ||
        !isRoutablePeerAddress(peerAddress) ||
        messageId.isEmpty) {
      return;
    }
    await ref
        .read(signalTransportProvider)
        .send(
          remoteAddress: peerAddress,
          payload: <String, dynamic>{
            'type': 'message_transfer_cancel',
            'msgId': messageId,
          },
        );
  }
}
