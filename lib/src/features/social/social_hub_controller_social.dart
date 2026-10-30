part of 'social_hub_controller.dart';

mixin _SocialHubSocialMixin on _SocialHubControllerBase {
  Future<void> _dismissForegroundNotifications(
    String peerAddress, {
    Set<ZenSignalType>? types,
  }) async {
    final Set<ZenSignalType> resolvedTypes =
        types ??
        const <ZenSignalType>{
          ZenSignalType.friendRequest,
          ZenSignalType.friendAccept,
          ZenSignalType.friendReject,
          ZenSignalType.friendCancel,
          ZenSignalType.friendRemove,
        };
    for (final ZenSignalType type in resolvedTypes) {
      await _notificationCenter.dismiss('foreground-${type.name}-$peerAddress');
    }
  }

  /// The name this person gives itself in an invitation or an answer:
  /// [given] when the screen passed one, else the name chosen in the
  /// profile; null when there is none (the other side shows its own label
  /// then). Every way of inviting (a scanned code, an event, a dinner, the
  /// neighbours) tells it, not only the screens that remembered to pass it.
  String? _ownSenderName(String? given) {
    final String chosen = given?.trim() ?? '';
    if (chosen.isNotEmpty) {
      return chosen;
    }
    final String own = ref
        .read(userProfileControllerProvider)
        .publicName
        .trim();
    return own.isEmpty ? null : own;
  }

  /// Invites [peerAddress]. Their name is not chosen here: it comes from
  /// their profile with their answer ([knownName]: the name they use where
  /// they were met, shown until then). [nickname] is an optional note shown
  /// under it, only on this account.
  Future<void> sendFriendRequest({
    required String peerAddress,
    String knownName = '',
    String nickname = '',
    String? senderDisplayName,
    String? message,
  }) async {
    final String normalizedAddress = PeerShareCodec.normalizeAddress(
      peerAddress,
    );
    if (normalizedAddress.isEmpty) {
      return;
    }
    final FriendProfile? current = state.friendByAddress(normalizedAddress);
    if (current?.status == FriendRelationshipStatus.accepted ||
        current?.status == FriendRelationshipStatus.blocked) {
      return;
    }

    final String? senderName = _ownSenderName(senderDisplayName);
    await _sendFriendLifecycleSignal(
      peerAddress: normalizedAddress,
      payload: <String, dynamic>{
        'type': 'friend_request',
        'senderName': ?senderName,
        if (message != null && message.trim().isNotEmpty)
          'message': message.trim(),
      },
    );

    state = state.copyWith(
      book: state.book.invite(
        normalizedAddress,
        (FriendProfile base) => _withAppRetentionDefaults(
          _friendReducer
              .applyOutgoingRequest(
                address: normalizedAddress,
                knownName: knownName,
                nickname: nickname,
                requestMessage: message?.trim(),
                current: base,
              )
              .copyWith(
                lastMessagePreview: t('Zaproszenie oczekuje na odpowiedź.'),
                lastActivityLabel: t('Teraz'),
              ),
          _appSettings,
        ),
        nicknameChanged: sanitizeFriendNickname(nickname).isNotEmpty,
      ),
    );
    await _persistState();
  }

  Future<void> configureConversationRetention({
    required String peerAddress,
    required int inboxLimitMb,
    required int autoCleanupDays,
  }) async {
    if (inboxLimitMb < 0) {
      throw FormatException(t('Limit danych nie może być ujemny.'));
    }
    if (autoCleanupDays < 0) {
      throw FormatException(
        t('Liczba dni auto-czyszczenia nie może być ujemna.'),
      );
    }
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null) {
      throw FormatException(t('Nie znaleziono tej rozmowy.'));
    }

    state = state.copyWith(
      book: state.book.edit(
        canonical,
        (FriendProfile f) => f.copyWith(
          inboxLimitMb: inboxLimitMb,
          autoCleanupDays: autoCleanupDays,
        ),
      ),
    );
    await _applyConversationRetention(
      peerAddress: canonical,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistState();
  }

  /// Notifications about conversation [key] (a friend's address or
  /// `group:<id>`) tell as much as [level]; `null` goes back to the setting
  /// ("Jak globalnie"). Only on this device.
  Future<void> setConversationNotificationPrivacy(
    String key,
    NotificationPrivacy? level,
  ) async {
    final bool group = key.startsWith('group:');
    final String canonical = group
        ? key
        : state.friendByAddress(key)?.address ??
              PeerShareCodec.normalizeAddress(key);
    await _enqueueStateWork(() async {
      final Map<String, NotificationPrivacy> levels =
          Map<String, NotificationPrivacy>.of(state.notificationPrivacy)
            ..removeWhere(
              (String k, NotificationPrivacy _) =>
                  k == canonical ||
                  (!group &&
                      !k.startsWith('group:') &&
                      PeerShareCodec.addressesEqual(k, canonical)),
            );
      if (level != null) {
        levels[canonical] = level;
      }
      state = state.copyWith(notificationPrivacy: levels);
      await _persistState();
    });
  }

  /// Puts [entry] at the top of the inbox, in place of an entry with the
  /// same id (an update of the same news: "3 nowe posty" after "2 nowe
  /// posty"). For news that does not come as a signal: friends' new posts.
  Future<void> putInboxEntry(InboxEntry entry) async {
    await _enqueueStateWork(() async {
      state = _withTrimmedInbox(
        state.copyWith(
          inbox: _prependInbox(
            state.inbox
                .where((InboxEntry e) => e.id != entry.id)
                .toList(growable: false),
            entry,
          ),
        ),
        _appSettings,
      );
      await _persistState();
    });
  }

  /// Accepts the invitation from [peerAddress]; they keep the name from
  /// their profile.
  Future<void> acceptFriendRequest({
    required String peerAddress,
    String? senderDisplayName,
  }) async {
    peerAddress = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(peerAddress);
    if (current == null ||
        current.status != FriendRelationshipStatus.pendingIncoming) {
      return;
    }

    final String? senderName = _ownSenderName(senderDisplayName);
    await _sendFriendLifecycleSignal(
      peerAddress: peerAddress,
      payload: <String, dynamic>{
        'type': 'friend_accept',
        'senderName': ?senderName,
      },
    );

    final String peer = peerAddress;
    bool accepted = false;
    // In turn with the signals and the re-read of the stored state when
    // the app comes back (the queue): run beside them, a re-read that
    // started before would put the request back over the answer.
    await _enqueueStateWork(() async {
      final FriendProfile? waiting = state.friendByAddress(peer);
      if (waiting == null ||
          waiting.status != FriendRelationshipStatus.pendingIncoming) {
        return;
      }
      final FriendshipBook book = state.book.admit(
        peer,
        FriendshipEvidence.iAcceptedTheirs,
        _friendshipTick,
        shape: (FriendProfile base) => _withAppRetentionDefaults(
          _friendReducer
              .applyAccepted(current: base)
              .copyWith(
                isOnline: true,
                lastPresenceAtMillis: DateTime.now().millisecondsSinceEpoch,
                lastMessagePreview: t(
                  'Połączenie gotowe. Możesz pisać od razu.',
                ),
                lastActivityLabel: t('Teraz'),
              ),
          _appSettings,
        ),
      );
      final FriendProfile updated = book.profileOf(peer)!;
      final List<InboxEntry> nextInbox = _removeEntriesForPeer(
        state.inbox,
        peer,
        types: const <InboxEntryType>{InboxEntryType.friendRequest},
      );
      final List<InboxEntry> nextAlerts = _removeEntriesForPeer(
        state.backgroundAlerts,
        peer,
        types: const <InboxEntryType>{InboxEntryType.friendRequest},
      );
      await _dismissRemovedAlerts(state.backgroundAlerts, nextAlerts);
      await _dismissForegroundNotifications(
        peer,
        types: const <ZenSignalType>{ZenSignalType.friendRequest},
      );
      // The invitation is answered: its copy kept for the app's return
      // must not be replayed over the answer.
      await _dropQueuedFriendRequests(peer);
      state = state.copyWith(
        book: book,
        inbox: nextInbox,
        backgroundAlerts: nextAlerts,
      );
      await _appendSystemMessage(
        peerAddress: peer,
        event: SocialEventText('chat.connected', <String, String>{
          // Not known yet: said without a name, the chat puts the name in
          // once their profile tells it.
          'name': updated.hasProfileName ? updated.displayLabel : '',
        }),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
      await _persistState();
      accepted = true;
    });
    if (accepted) {
      // A new friend should see who they are talking to.
      unawaitedLogged(
        _sendOwnProfileTo(peer),
        context: 'Sending the profile to a new friend failed',
      );
    }
  }

  /// Drops the copies of [peer]'s invitations kept in the queue for when
  /// the app comes back (the invitation was answered here).
  Future<void> _dropQueuedFriendRequests(String peer) async {
    final List<QueuedSignal> queue = await _queueStore.load();
    final List<QueuedSignal> rest = queue
        .where(
          (QueuedSignal q) =>
              q.signal.type != ZenSignalType.friendRequest ||
              !PeerShareCodec.addressesEqual(q.signal.sender, peer),
        )
        .toList(growable: false);
    if (rest.length != queue.length) {
      await _queueStore.save(rest);
    }
  }

  Future<void> rejectFriendRequest({required String peerAddress}) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null ||
        current.status != FriendRelationshipStatus.pendingIncoming) {
      return;
    }

    await _sendFriendLifecycleSignal(
      peerAddress: canonical,
      payload: const <String, dynamic>{'type': 'friend_reject'},
    );

    // In turn with the signals and the re-read of the stored state (see
    // acceptFriendRequest).
    await _enqueueStateWork(() async {
      if (state.friendByAddress(canonical)?.status !=
          FriendRelationshipStatus.pendingIncoming) {
        return;
      }
      final List<InboxEntry> nextInbox = _removeEntriesForPeer(
        state.inbox,
        canonical,
        types: const <InboxEntryType>{InboxEntryType.friendRequest},
      );
      final List<InboxEntry> nextAlerts = _removeEntriesForPeer(
        state.backgroundAlerts,
        canonical,
        types: const <InboxEntryType>{InboxEntryType.friendRequest},
      );
      await _dismissRemovedAlerts(state.backgroundAlerts, nextAlerts);
      await _dismissForegroundNotifications(
        canonical,
        types: const <ZenSignalType>{ZenSignalType.friendRequest},
      );
      await _dropQueuedFriendRequests(canonical);
      state = state.copyWith(
        book: state.book.withdraw(canonical),
        inbox: nextInbox,
        backgroundAlerts: nextAlerts,
      );
      await _persistState();
    });
  }

  Future<void> cancelOutgoingRequest({required String peerAddress}) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null ||
        current.status != FriendRelationshipStatus.pendingOutgoing) {
      return;
    }

    await _sendFriendLifecycleSignal(
      peerAddress: canonical,
      payload: const <String, dynamic>{'type': 'friend_cancel'},
    );
    await _cancelQueuedTraffic(canonical, keep: 'friend_cancel');

    await _dismissForegroundNotifications(canonical);
    state = state.copyWith(
      book: state.book.withdraw(canonical),
      activeCall:
          _currentCallMatches(call: state.activeCall, peerAddress: canonical)
          ? null
          : state.activeCall,
    );
    await _persistState();
  }

  Future<void> removeFriend({required String peerAddress}) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null || current.status == FriendRelationshipStatus.none) {
      return;
    }

    await _sendFriendLifecycleSignal(
      peerAddress: canonical,
      payload: const <String, dynamic>{'type': 'friend_remove'},
    );
    await _cancelQueuedTraffic(canonical, keep: 'friend_remove');
    // The account's other devices remove them too.
    ref.read(accountDirectoryHolderProvider).friendRemoved?.call(canonical);

    // In turn with the signals: one in flight must not put back the
    // friend list it read before the removal.
    await _enqueueStateWork(() async {
      final List<InboxEntry> nextInbox = _removeEntriesForPeer(
        state.inbox,
        canonical,
      );
      final List<InboxEntry> nextAlerts = _removeEntriesForPeer(
        state.backgroundAlerts,
        canonical,
      );
      await _dismissRemovedAlerts(state.backgroundAlerts, nextAlerts);
      await _dismissForegroundNotifications(canonical);
      // What they sent that waits for the app's return is of no use now.
      await _dropQueuedSignalsFrom(canonical);

      await _messageTimelineStore.save(canonical, const <ChatMessage>[]);
      _bumpTimelineRevision();

      // The book remembers it: nothing brings them back on its own.
      state = state.copyWith(
        book: state.book.remove(canonical, _friendshipTick, dropPending: true),
        inbox: nextInbox,
        backgroundAlerts: nextAlerts,
        activeCall:
            _currentCallMatches(call: state.activeCall, peerAddress: canonical)
            ? null
            : state.activeCall,
      );
      await _persistState();
    });
  }

  /// Sets what this user calls [peerAddress] (shown under their own name);
  /// '' removes it. Their name itself comes from their profile.
  Future<void> setFriendNickname({
    required String peerAddress,
    required String nickname,
  }) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null) {
      throw FormatException(t('Znajomy nie został znaleziony.'));
    }
    // The account's other devices take it from the contacts backup.
    state = state.copyWith(
      book: state.book.edit(
        canonical,
        (FriendProfile f) =>
            f.copyWith(nickname: sanitizeFriendNickname(nickname)),
        nicknameChanged: true,
      ),
    );
    await _persistState();
  }

  Future<void> blockFriend({required String peerAddress, String? note}) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    if (canonical.isEmpty) {
      return;
    }
    final FriendshipBook book = state.book.block(
      canonical,
      _friendshipTick,
      shape: (FriendProfile base) => _friendReducer
          .applyBlocked(
            current: base,
            note: note?.trim().isNotEmpty == true ? note!.trim() : null,
          )
          .copyWith(isOnline: false, lastPresenceAtMillis: 0, unreadCount: 0),
    );

    final List<InboxEntry> nextInbox = _removeEntriesForPeer(
      state.inbox,
      canonical,
    );
    final List<InboxEntry> nextAlerts = _removeEntriesForPeer(
      state.backgroundAlerts,
      canonical,
    );
    await _dismissRemovedAlerts(state.backgroundAlerts, nextAlerts);
    await _dismissForegroundNotifications(canonical);
    await _cancelQueuedTraffic(canonical);

    final List<QueuedSignal> queue = await _queueStore.load();
    final List<QueuedSignal> nextQueue = queue
        .where(
          (QueuedSignal entry) =>
              !PeerShareCodec.addressesEqual(entry.signal.sender, canonical),
        )
        .toList(growable: false);
    if (queue.length != nextQueue.length) {
      await _queueStore.save(nextQueue);
    }

    state = state.copyWith(
      book: book,
      inbox: nextInbox,
      backgroundAlerts: nextAlerts,
      pendingSignalCount: nextQueue.length,
      activeCall:
          _currentCallMatches(call: state.activeCall, peerAddress: canonical)
          ? null
          : state.activeCall,
    );
    await _persistState();
  }

  Future<void> unblockFriend({required String peerAddress}) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null || current.status != FriendRelationshipStatus.blocked) {
      return;
    }

    state = state.copyWith(
      book: state.book.unblock(
        canonical,
        _friendshipTick,
        shape: (FriendProfile base) => _friendReducer
            .applyRemoved(current: base)
            .copyWith(isOnline: false, lastPresenceAtMillis: 0, unreadCount: 0),
      ),
    );
    await _persistState();
  }

  Future<void> sendCallInvite({
    required String peerAddress,
    required CallInviteKind kind,
  }) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? friend = state.friendByAddress(canonical);
    if (!isRoutablePeerAddress(canonical) ||
        friend?.status != FriendRelationshipStatus.accepted) {
      return;
    }
    if (state.activeCall != null) {
      throw FormatException(
        t(
          'Zakończenie aktualnej rozmowy jest wymagane przed nowym '
          'połączeniem.',
        ),
      );
    }
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final CallSession session = CallSession(
      id: 'call-$timestamp-$peerAddress',
      peerAddress: peerAddress,
      displayName: friend!.displayLabel,
      kind: kind,
      status: CallSessionStatus.ringing,
      startedAtMillis: timestamp,
      isSpeakerOn: kind == CallInviteKind.video,
      isCameraEnabled: kind == CallInviteKind.video,
    );
    state = state.copyWith(activeCall: session);
    _armCallRingingTimeout(session);
    await _persistState();
    bool inviteSent = false;
    try {
      await _sendCallSignal(
        remoteAddress: peerAddress,
        type: 'call_invite',
        session: session,
      );
      inviteSent = true;
      _armCallReRing(session);
      await _callMedia.startOutgoing(
        callId: session.id,
        remoteAddress: peerAddress,
        kind: kind,
      );
    } catch (error, stackTrace) {
      logZenError('Starting outgoing call failed', error, stackTrace);
      _cancelCallRingingTimeout();
      if (inviteSent) {
        await _sendCallSignalQuietly(
          remoteAddress: peerAddress,
          type: 'hangup',
          session: session,
        );
      }
      await _closeCallMediaSession();
      if (_currentCallMatches(
        call: state.activeCall,
        peerAddress: peerAddress,
        callId: session.id,
      )) {
        state = state.copyWith(activeCall: null);
        await _persistState();
      }
      rethrow;
    }
    await _appendSystemMessage(
      peerAddress: peerAddress,
      event: SocialEventText('call.inviteOut', <String, String>{
        'kind': kind.name,
      }),
      timestamp: timestamp,
    );
  }

  Future<void> acceptIncomingCall({required String peerAddress}) {
    return _enqueueStateWork(
      () => _acceptIncomingCall(peerAddress: peerAddress),
    );
  }

  Future<void> _acceptIncomingCall({required String peerAddress}) async {
    final CallSession? session = state.activeCall;
    if (!_currentCallMatches(call: session, peerAddress: peerAddress) ||
        session == null ||
        (session.status != CallSessionStatus.ringing &&
            session.status != CallSessionStatus.connecting)) {
      return;
    }
    if (session.isGroup) {
      if (session.status == CallSessionStatus.ringing) {
        await _acceptGroupRing(session);
      }
      return;
    }
    _cancelCallRingingTimeout();
    if (session.status == CallSessionStatus.connecting &&
        !_pendingIncomingCallAccept) {
      // Handshake already running; a second accept would re-request the SDP
      // offer and stall the call for seconds.
      return;
    }
    final ZenSignal? offer = _pendingIncomingCallOffer;
    final CallInviteKind nextKind =
        offer != null && _currentCallMatchesSignal(session, offer)
        ? _callKind(offer.content)
        : session.kind;
    state = state.copyWith(
      activeCall: session.copyWith(
        kind: nextKind,
        status: CallSessionStatus.connecting,
        isIncoming: false,
        isSpeakerOn: session.isSpeakerOn || nextKind == CallInviteKind.video,
        isCameraEnabled: nextKind == CallInviteKind.video,
      ),
      backgroundAlerts: _removeCallAlertsForPeer(
        state.backgroundAlerts,
        session.peerAddress,
      ),
      inbox: _removeCallAlertsForPeer(state.inbox, session.peerAddress),
    );
    final Future<void> housekeeping = Future.wait<void>(<Future<void>>[
      _dismissCallNotificationsFor(session),
      _persistState(),
    ]);
    if (offer == null ||
        !_currentCallMatchesSignal(state.activeCall, offer) ||
        offer.sessionDescription == null) {
      _pendingIncomingCallAccept = true;
      // The SDP offer can be missing after a background/foreground handoff
      // or an app restart (it lives only in memory). Ask the caller to send
      // it again and arm a timeout so we fail cleanly instead of hanging on
      // "Łączenie…" forever.
      unawaited(housekeeping);
      await _requestCallOfferResend(state.activeCall!);
      _armPendingOfferTimeout(state.activeCall!);
      return;
    }
    // Media in parallel with notification/snapshot IO so getUserMedia is not
    // blocked on disk and the call screen does not sit on "Łączenie…".
    await _acceptIncomingCallWithOffer(
      session: state.activeCall!,
      offer: offer,
    );
    unawaited(housekeeping);
  }

  Future<void> _requestCallOfferResend(CallSession session) async {
    final String targetAddress =
        session.isGroup && session.participantAddresses.isNotEmpty
        ? session.participantAddresses.first
        : session.peerAddress;
    if (!isRoutablePeerAddress(targetAddress)) {
      return;
    }
    try {
      await ref
          .read(signalTransportProvider)
          .send(
            remoteAddress: targetAddress,
            payload: <String, dynamic>{
              'type': 'call_offer_request',
              'callId': session.id,
              'kind': session.kind.name,
              if (session.isGroup && session.groupId != null)
                'groupId': session.groupId,
            },
          );
    } catch (error, stackTrace) {
      logZenError('Requesting call offer resend failed', error, stackTrace);
    }
  }

  @override
  void _armCallRingingTimeout(CallSession session) {
    if (_armedRingingCallId == session.id && _callRingingTimeoutTimer != null) {
      // Re-arming on every follow-up signal of the same call would push the
      // deadline forever, and a call nobody answers would ring for good.
      return;
    }
    _callRingingTimeoutTimer?.cancel();
    _callRingingTimeoutTimer = null;
    _armedRingingCallId = null;
    final Duration timeout = ref.read(callRingingWaitTimeoutProvider);
    if (timeout <= Duration.zero) {
      // Zero disables the deadline entirely.
      return;
    }
    _armedRingingCallId = session.id;
    _callRingingTimeoutTimer = Timer(timeout, () {
      unawaited(_expireRingingCall(session.id));
    });
  }

  /// Keeps the ringing deadline in sync with whatever call is on screen.
  ///
  /// Incoming sessions are created straight from the signal reducer and never
  /// go through [sendCallInvite], so without this an unanswered incoming call
  /// would ring until the app is restarted.
  @override
  void _syncCallRingingTimeout() {
    final CallSession? session = state.activeCall;
    if (session == null || session.status != CallSessionStatus.ringing) {
      _cancelCallRingingTimeout();
      return;
    }
    _armCallRingingTimeout(session);
  }

  void _cancelCallRingingTimeout() {
    _callRingingTimeoutTimer?.cancel();
    _callRingingTimeoutTimer = null;
    _armedRingingCallId = null;
    _stopCallReRing();
  }

  /// Periodically re-sends the invite while an outgoing call keeps ringing.
  ///
  /// The invite goes out as one datagram with no ACK; a single lost frame used
  /// to leave the callee silent for the whole ringing window. Repeats are
  /// safe: the callee deduplicates them by callId and just rings again. The
  /// ringing timeout armed next to this timer is the hard stop.
  void _armCallReRing(CallSession session) {
    _stopCallReRing();
    final Duration interval = ref.read(callReRingIntervalProvider);
    if (interval <= Duration.zero) {
      // Zero disables re-ringing entirely.
      return;
    }
    _callReRingTimer = Timer.periodic(interval, (_) {
      unawaited(_reRingCallInvite(session.id));
    });
  }

  Future<void> _reRingCallInvite(String callId) async {
    if (!ref.mounted) {
      return;
    }
    final CallSession? session = state.activeCall;
    if (session == null ||
        session.id != callId ||
        session.isIncoming ||
        session.status != CallSessionStatus.ringing) {
      _stopCallReRing();
      return;
    }
    try {
      await _sendCallSignal(
        remoteAddress: session.peerAddress,
        type: 'call_invite',
        session: session,
      );
    } catch (error, stackTrace) {
      // A failed turn must not break the loop — the next tick retries, and the
      // ringing timeout ends the call if the peer stays unreachable.
      logZenError('Re-sending the call invite failed', error, stackTrace);
    }
  }

  Future<void> _expireRingingCall(String callId) async {
    if (!ref.mounted) {
      return;
    }
    final CallSession? session = state.activeCall;
    if (session == null ||
        session.id != callId ||
        session.status != CallSessionStatus.ringing) {
      return;
    }
    if (session.isGroup) {
      _cancelCallRingingTimeout();
      await _expireGroupRing(session);
      return;
    }
    _pendingIncomingCallAccept = false;
    _pendingIncomingCallOffer = null;
    _cancelCallRingingTimeout();
    _pendingOfferTimeoutTimer?.cancel();
    _pendingOfferTimeoutTimer = null;
    _rememberTornDownCall(session.id);
    await _sendCallSignalQuietly(
      remoteAddress: session.peerAddress,
      type: session.isIncoming ? 'call_decline' : 'hangup',
      session: session,
    );
    await _closeCallMediaSession();
    if (_currentCallMatches(
      call: state.activeCall,
      peerAddress: session.peerAddress,
      callId: callId,
    )) {
      state = state.copyWith(
        activeCall: null,
        backgroundAlerts: _removeCallAlertsForPeer(
          state.backgroundAlerts,
          session.peerAddress,
        ),
        inbox: _removeCallAlertsForPeer(state.inbox, session.peerAddress),
      );
      await _persistState();
    }
    // Only this call's own notification: clearing everything here used to
    // wipe unrelated message notifications whenever a call rang out.
    await _dismissCallNotificationsFor(session);
    if (session.isIncoming && !_isUiFocused()) {
      // The ringing deadline expired with no answer: leave a missed-call
      // notification behind, or the call is invisible once the ring stops.
      // Only while the app is off screen - on screen the conversation's own
      // system message already says it, and a shade entry on top of an open
      // app is pure noise.
      await _systemNotifications.show(
        _missedCallSystemNotification(
          session: session,
          createdAtMillis: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }
    await _appendSystemMessage(
      peerAddress: session.peerAddress,
      event: SocialEventText(
        session.isIncoming ? 'call.missed' : 'call.noAnswer',
        <String, String>{'kind': session.kind.name},
      ),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistState();
  }

  void _armPendingOfferTimeout(CallSession session) {
    _pendingOfferTimeoutTimer?.cancel();
    _callOfferResendTimer?.cancel();
    _callOfferResendTimer = null;
    final Duration timeout = ref.read(callOfferWaitTimeoutProvider);
    if (timeout <= Duration.zero) {
      return;
    }
    // The resend request is a single unacknowledged datagram, and it goes out
    // exactly when the runtime node is being handed back from the background
    // service — the most likely moment for it to be dropped. Answering a call
    // the app was not running for then hangs on "Łączenie…" until the wait
    // expires, so keep asking until the offer lands.
    final Duration retryInterval = ref.read(callOfferResendIntervalProvider);
    if (retryInterval > Duration.zero) {
      _callOfferResendTimer = Timer.periodic(retryInterval, (_) {
        final CallSession? current = state.activeCall;
        if (!ref.mounted ||
            !_pendingIncomingCallAccept ||
            current == null ||
            current.id != session.id) {
          _callOfferResendTimer?.cancel();
          _callOfferResendTimer = null;
          return;
        }
        unawaited(_requestCallOfferResend(current));
      });
    }
    _pendingOfferTimeoutTimer = Timer(timeout, () {
      unawaited(_expirePendingOfferWait(session.id));
    });
  }

  Future<void> _expirePendingOfferWait(String callId) async {
    if (!ref.mounted || !_pendingIncomingCallAccept) {
      return;
    }
    final CallSession? session = state.activeCall;
    if (session == null ||
        session.id != callId ||
        (session.status != CallSessionStatus.ringing &&
            session.status != CallSessionStatus.connecting)) {
      return;
    }
    _pendingIncomingCallAccept = false;
    _pendingIncomingCallOffer = null;
    _cancelCallRingingTimeout();
    await _sendCallSignalQuietly(
      remoteAddress: session.peerAddress,
      type: 'hangup',
      session: session,
    );
    await _closeCallMediaSession();
    if (_currentCallMatches(
      call: state.activeCall,
      peerAddress: session.peerAddress,
      callId: callId,
    )) {
      state = state.copyWith(activeCall: null);
      await _persistState();
    }
    await _appendSystemMessage(
      peerAddress: session.peerAddress,
      event: SocialEventText('call.failed', <String, String>{
        'kind': session.kind.name,
      }),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
    await _persistState();
  }

  Future<void> declineIncomingCall({required String peerAddress}) {
    return _enqueueStateWork(
      () => _declineIncomingCall(peerAddress: peerAddress),
    );
  }

  Future<void> _declineIncomingCall({required String peerAddress}) async {
    final CallSession? session = state.activeCall;
    if (!_currentCallMatches(call: session, peerAddress: peerAddress) ||
        session == null ||
        session.status != CallSessionStatus.ringing) {
      return;
    }
    if (session.isGroup) {
      await _declineGroupRing(session);
      return;
    }
    _cancelCallRingingTimeout();
    _pendingIncomingCallAccept = false;
    _pendingIncomingCallOffer = null;
    // Both sides can hang up at once; claiming the id here keeps the peer's
    // crossing teardown from adding a second line to the conversation.
    _rememberTornDownCall(session.id);
    await _sendCallSignalQuietly(
      // The session's own address, not the caller's argument: that one comes
      // from a route key or a screen and only has to compare equal.
      remoteAddress: session.peerAddress,
      type: 'call_decline',
      session: session,
    );
    await _closeCallMediaSession();
    state = state.copyWith(
      activeCall: null,
      backgroundAlerts: _removeCallAlertsForPeer(
        state.backgroundAlerts,
        session.peerAddress,
      ),
      inbox: _removeCallAlertsForPeer(state.inbox, session.peerAddress),
    );
    // Only this call's notifications; other chats' ones stay put.
    await _dismissCallNotificationsFor(session);
    if (session.isGroup && session.groupId != null) {
      final int timestamp = DateTime.now().millisecondsSinceEpoch;
      await _messageTimelineStore.append(
        'group:${session.groupId}',
        ChatMessage(
          id: 'grp-sys-$timestamp',
          sender: 'system',
          text: t('Odrzucono połączenie grupowe ({kind}).', {
            'kind': _callKindWord(session.kind),
          }),
          sentAtMillis: timestamp,
          direction: ChatMessageDirection.incoming,
          deliveryState: ChatMessageDeliveryState.delivered,
        ),
      );
      _bumpTimelineRevision();
    } else {
      await _appendSystemMessage(
        peerAddress: peerAddress,
        event: SocialEventText('call.declined', <String, String>{
          'kind': session.kind.name,
        }),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    }
    await _persistState();
  }

  Future<void> endActiveCall({required String peerAddress}) {
    return _enqueueStateWork(() => _endActiveCall(peerAddress: peerAddress));
  }

  Future<void> _endActiveCall({required String peerAddress}) async {
    final CallSession? session = state.activeCall;
    if (!_currentCallMatches(call: session, peerAddress: peerAddress) ||
        session == null) {
      return;
    }
    if (session.isGroup) {
      if (session.status == CallSessionStatus.ringing && session.isIncoming) {
        await _declineGroupRing(session);
      } else {
        await _leaveGroupCall(session);
      }
      return;
    }
    _cancelCallRingingTimeout();
    _pendingIncomingCallAccept = false;
    _pendingIncomingCallOffer = null;
    _rememberTornDownCall(session.id);
    if (session.isGroup) {
      for (final String participant in session.participantAddresses) {
        await _sendCallSignalQuietly(
          remoteAddress: participant,
          type: 'hangup',
          session: session,
        );
      }
    } else {
      await _sendCallSignalQuietly(
        remoteAddress: session.peerAddress,
        type: 'hangup',
        session: session,
      );
    }
    await _closeCallMediaSession();
    state = state.copyWith(
      activeCall: null,
      backgroundAlerts: _removeCallAlertsForPeer(
        state.backgroundAlerts,
        session.peerAddress,
      ),
      inbox: _removeCallAlertsForPeer(state.inbox, session.peerAddress),
    );
    // Only this call's notifications; other chats' ones stay put.
    await _dismissCallNotificationsFor(session);
    if (session.isGroup && session.groupId != null) {
      await _messageTimelineStore.append(
        'group:${session.groupId}',
        ChatMessage(
          id: 'grp-sys-${DateTime.now().millisecondsSinceEpoch}',
          sender: 'system',
          text: t('Zakończono połączenie grupowe ({kind}).', {
            'kind': _callKindWord(session.kind),
          }),
          sentAtMillis: DateTime.now().millisecondsSinceEpoch,
          direction: ChatMessageDirection.incoming,
          deliveryState: ChatMessageDeliveryState.delivered,
        ),
      );
      _bumpTimelineRevision();
    } else {
      await _appendSystemMessage(
        peerAddress: peerAddress,
        event: SocialEventText('call.ended', <String, String>{
          'kind': session.kind.name,
        }),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    }
    await _persistState();
  }

  Future<void> toggleActiveCallMute() async {
    if (state.activeCall?.isGroup ?? false) {
      return _toggleGroupCall(GroupCallToggle.mute);
    }
    final CallSession? session = state.activeCall;
    if (session == null || session.status != CallSessionStatus.active) {
      return;
    }
    final bool nextMuted = !session.isMuted;
    if (session.isGroup) {
      await _groupMedia.setMuted(nextMuted);
    } else {
      await _callMedia.setMuted(nextMuted);
    }
    state = state.copyWith(activeCall: session.copyWith(isMuted: nextMuted));
    await _persistState();
  }

  Future<void> toggleActiveCallSpeaker() async {
    if (state.activeCall?.isGroup ?? false) {
      return _toggleGroupCall(GroupCallToggle.speaker);
    }
    final CallSession? session = state.activeCall;
    if (session == null || session.status != CallSessionStatus.active) {
      return;
    }
    final bool nextSpeakerOn = !session.isSpeakerOn;
    if (session.isGroup) {
      await _groupMedia.setSpeakerOn(nextSpeakerOn);
    } else {
      await _callMedia.setSpeakerOn(nextSpeakerOn);
    }
    state = state.copyWith(
      activeCall: session.copyWith(isSpeakerOn: nextSpeakerOn),
    );
    await _persistState();
  }

  Future<void> toggleActiveCallCamera() async {
    if (state.activeCall?.isGroup ?? false) {
      return _toggleGroupCall(GroupCallToggle.camera);
    }
    final CallSession? session = state.activeCall;
    if (session == null || session.status != CallSessionStatus.active) {
      return;
    }
    final bool nextCameraEnabled = !session.isCameraEnabled;
    await _callMedia.setCameraEnabled(nextCameraEnabled);
    state = state.copyWith(
      activeCall: session.copyWith(
        kind: nextCameraEnabled && session.kind == CallInviteKind.audio
            ? CallInviteKind.video
            : session.kind,
        isCameraEnabled: nextCameraEnabled,
      ),
    );
    await _persistState();
  }

  Future<void> _acceptIncomingCallWithOffer({
    required CallSession session,
    required ZenSignal offer,
  }) async {
    final Map<String, dynamic>? description = offer.sessionDescription;
    if (description == null) {
      throw FormatException(
        t('Brakuje opisu sesji dla przychodzącej rozmowy.'),
      );
    }
    _pendingOfferTimeoutTimer?.cancel();
    _pendingOfferTimeoutTimer = null;
    _pendingIncomingCallAccept = false;
    _pendingIncomingCallOffer = null;
    final String targetAddress =
        session.isGroup && session.participantAddresses.isNotEmpty
        ? session.participantAddresses.first
        : session.peerAddress;
    try {
      await _callMedia.acceptIncoming(
        callId: session.id,
        remoteAddress: targetAddress,
        kind: _callKind(offer.content),
        remoteDescription: description,
      );
      if (session.isGroup && session.groupId != null) {
        await _messageTimelineStore.append(
          'group:${session.groupId}',
          ChatMessage(
            id: 'grp-sys-${DateTime.now().millisecondsSinceEpoch}',
            sender: 'system',
            text: t('Dołączono do połączenia grupowego ({kind}).', {
              'kind': _callKindLabel(offer.content),
            }),
            sentAtMillis: DateTime.now().millisecondsSinceEpoch,
            direction: ChatMessageDirection.incoming,
            deliveryState: ChatMessageDeliveryState.delivered,
          ),
        );
        _bumpTimelineRevision();
      } else {
        await _appendSystemMessage(
          peerAddress: session.peerAddress,
          event: SocialEventText('call.answered', <String, String>{
            'kind': _callKind(offer.content).name,
          }),
          timestamp: DateTime.now().millisecondsSinceEpoch,
        );
      }
    } catch (error, stackTrace) {
      logZenError('Accepting incoming call failed', error, stackTrace);
      // Notify the caller so it does not stay stuck in the ringing state.
      await _sendCallSignalQuietly(
        remoteAddress: targetAddress,
        type: 'hangup',
        session: session,
      );
      await _closeCallMediaSession();
      if (_currentCallMatches(
        call: state.activeCall,
        peerAddress: session.peerAddress,
        callId: session.id,
      )) {
        state = state.copyWith(activeCall: null);
        await _persistState();
      }
      rethrow;
    }
  }

  @override
  Future<void> _handleCallOfferRequest(ZenSignal signal) async {
    final CallSession? session = state.activeCall;
    if (!_currentCallMatchesSignal(session, signal) ||
        session == null ||
        session.isIncoming) {
      return;
    }
    try {
      await _callMedia.resendLocalOffer(signal.callId?.trim() ?? session.id);
    } catch (error, stackTrace) {
      logZenError('Resending call offer failed', error, stackTrace);
    }
  }

  @override
  Future<void> _handleIncomingCallOffer({
    required ZenSignal signal,
    required int timestamp,
  }) async {
    final String? callId = signal.callId?.trim();
    final Map<String, dynamic>? description = signal.sessionDescription;
    if (callId == null || callId.isEmpty || description == null) {
      return;
    }
    final CallSession? currentCall = state.activeCall;
    if (_isSimultaneousCallGlare(currentCall, signal)) {
      if (_shouldPreferLocalOutgoingCall(currentCall!, callId)) {
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
          id: callId,
          peerAddress: signal.sender,
          displayName: _labelFor(signal, friends: state.friends),
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
    }
    final CallSession? nextCurrentCall = state.activeCall;
    if (_currentCallMatches(
          call: nextCurrentCall,
          peerAddress: signal.sender,
          callId: callId,
        ) &&
        nextCurrentCall?.status == CallSessionStatus.active) {
      await _callMedia.handleRemoteOffer(
        kind: _callKind(signal.content),
        remoteDescription: description,
      );
      state = state.copyWith(
        activeCall: nextCurrentCall!.copyWith(kind: _callKind(signal.content)),
      );
      await _persistState();
      return;
    }

    _pendingIncomingCallOffer = signal;
    CallSession? nextSession = nextCurrentCall;
    if (!_currentCallMatches(
      call: nextSession,
      peerAddress: signal.sender,
      callId: callId,
    )) {
      nextSession = CallSession(
        id: callId,
        peerAddress: signal.sender,
        displayName: _labelFor(signal, friends: state.friends),
        kind: _callKind(signal.content),
        status: CallSessionStatus.ringing,
        startedAtMillis: timestamp,
        isIncoming: true,
        isSpeakerOn: _callKind(signal.content) == CallInviteKind.video,
        isCameraEnabled: false,
      );
      state = state.copyWith(activeCall: nextSession);
      await _persistState();
    }
    if (nextSession != null && isRoutablePeerAddress(signal.sender)) {
      await _sendCallSignal(
        remoteAddress: signal.sender,
        type: 'ringing',
        session: nextSession,
      );
    }
    if (_pendingIncomingCallAccept &&
        nextSession != null &&
        _currentCallMatchesSignal(nextSession, signal)) {
      // The unqueued one: this already runs inside the queue.
      await _acceptIncomingCall(peerAddress: signal.sender);
    }
  }

  @override
  Future<void> _handleIncomingCallAnswer(ZenSignal signal) async {
    final CallSession? session = state.activeCall;
    if (!_currentCallMatchesSignal(session, signal)) {
      return;
    }
    final Map<String, dynamic>? description = signal.sessionDescription;
    if (description == null) {
      return;
    }
    _stopCallReRing();
    await _callMedia.applyRemoteAnswer(description);
    final CallInviteKind kind = _callKind(signal.content);
    if (session != null) {
      state = state.copyWith(
        activeCall: session.copyWith(
          kind: kind,
          status: CallSessionStatus.connecting,
        ),
      );
      await _persistState();
    }
  }

  @override
  Future<void> _closeCallMediaSession() async {
    _pendingOfferTimeoutTimer?.cancel();
    _pendingOfferTimeoutTimer = null;
    _pendingIncomingCallOffer = null;
    _pendingIncomingCallAccept = false;
    await _callMedia.close();
  }

  @override
  void _handleCallMediaStatusChanged(
    String callId,
    CallMediaSessionLifecycle status,
  ) {
    // The WebRTC callbacks are detached on dispose, but one can already be in
    // flight when that happens.
    if (!ref.mounted) {
      return;
    }
    final CallSession? session = state.activeCall;
    if (session == null || session.id != callId) {
      return;
    }
    switch (status) {
      case CallMediaSessionLifecycle.connecting:
        if (session.status != CallSessionStatus.connecting) {
          state = state.copyWith(
            activeCall: session.copyWith(status: CallSessionStatus.connecting),
          );
          unawaited(_persistState());
        }
        return;
      case CallMediaSessionLifecycle.active:
        // Connected: the ringing deadline no longer applies, and the ringing
        // notification the call was answered from has to go with it.
        _cancelCallRingingTimeout();
        _stopCallReRing();
        unawaitedLogged(
          _dismissCallNotification(session.peerAddress),
          context: 'Dismissing the connected call notification failed',
        );
        state = state.copyWith(
          activeCall: session.copyWith(
            status: CallSessionStatus.active,
            kind: _callMedia.activeKind ?? session.kind,
            isCameraEnabled: _callMedia.hasLocalVideo,
          ),
        );
        unawaited(_persistState());
        return;
      case CallMediaSessionLifecycle.ended:
        _pendingIncomingCallOffer = null;
        _pendingIncomingCallAccept = false;
        _cancelCallRingingTimeout();
        state = state.copyWith(
          activeCall: null,
          backgroundAlerts: _removeCallAlertsForPeer(
            state.backgroundAlerts,
            session.peerAddress,
          ),
          inbox: _removeCallAlertsForPeer(state.inbox, session.peerAddress),
        );
        unawaited(_persistState());
        return;
    }
  }

  @override
  void _handleCallMediaError(String? callId, Object error) {
    // Through the log helpers: no logcat output in release builds.
    logZenWarning('Call media error ($callId): $error');
    if (!ref.mounted) {
      return;
    }
    final CallSession? session = state.activeCall;
    if (session == null || (callId != null && session.id != callId)) {
      return;
    }
    _pendingIncomingCallOffer = null;
    _pendingIncomingCallAccept = false;
    _pendingOfferTimeoutTimer?.cancel();
    _pendingOfferTimeoutTimer = null;
    _cancelCallRingingTimeout();
    // Tell the peer so it does not stay stuck in the ringing state.
    unawaited(
      _sendCallSignalQuietly(
        remoteAddress: session.peerAddress,
        type: 'hangup',
        session: session,
      ),
    );
    state = state.copyWith(
      activeCall: null,
      backgroundAlerts: _removeCallAlertsForPeer(
        state.backgroundAlerts,
        session.peerAddress,
      ),
      inbox: _removeCallAlertsForPeer(state.inbox, session.peerAddress),
    );
    _bumpTimelineRevision();
    unawaited(_persistState());
  }

  Future<ConversationHistoryPreview> previewConversationHistory({
    required String peerAddress,
  }) async {
    final List<ChatMessage> messages = await _messageTimelineStore.load(
      peerAddress,
    );
    final int attachmentBytes = messages.fold<int>(
      0,
      (int total, ChatMessage message) =>
          total + (message.attachmentSizeBytes ?? 0),
    );
    return ConversationHistoryPreview(
      messageCount: messages.length,
      attachmentBytes: attachmentBytes,
    );
  }

  Future<void> clearConversationHistory({required String peerAddress}) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final List<ChatMessage> messages = await _messageTimelineStore.load(
      canonical,
    );
    if (messages.isEmpty) {
      return;
    }

    await _messageTimelineStore.save(canonical, const <ChatMessage>[]);
    for (final ChatMessage message in messages) {
      await _deleteManagedAttachmentIfPresent(message);
      await _transferStore.deleteIncoming(canonical, message.id);
      await _transferStore.deleteOutgoing(canonical, message.id);
    }
    _bumpTimelineRevision();

    final FriendProfile? current = state.friendByAddress(canonical);
    if (current == null) {
      return;
    }

    state = state.copyWith(
      book: state.book.edit(
        canonical,
        (FriendProfile f) => f.copyWith(
          lastMessagePreview: '',
          lastActivityLabel: '',
          unreadCount: 0,
        ),
      ),
    );
    await _persistState();
  }

  Future<void> markConversationRead(String peerAddress) async {
    final String canonical = PeerShareCodec.normalizeAddress(peerAddress);
    final FriendProfile? friend = state.friendByAddress(canonical);
    if (friend == null) {
      return;
    }

    if (friend.unreadCount > 0) {
      state = state.copyWith(
        book: state.book.edit(
          canonical,
          (FriendProfile f) => f.copyWith(unreadCount: 0),
        ),
      );
      await _persistState();
    }
    await _sendReadReceiptIfNeeded(canonical);
  }

  /// A `ping`, `pong` or `away` from [peerAddress] ([report]: what it said
  /// about their presence). A ping or pong also says they can be reached
  /// directly now ([reachable]); an "away" from a device about to stop
  /// receiving says the opposite.
  Future<void> updatePeerPresence({
    required String peerAddress,
    required PresenceReport report,
    bool reachable = true,
    int? observedAtMillis,
  }) {
    return _enqueueStateWork(
      () => _updatePeerPresence(
        peerAddress: peerAddress,
        report: report,
        reachable: reachable && report.reachable,
        observedAtMillis: observedAtMillis,
      ),
    );
  }

  Future<void> _updatePeerPresence({
    required String peerAddress,
    required PresenceReport report,
    required bool reachable,
    int? observedAtMillis,
  }) async {
    if (reachable) {
      // A pong is the most reliable "this peer is up right now" we get.
      unawaitedLogged(
        syncGroupInvitesToPeer(peerAddress),
        context: 'Syncing group invites on presence failed',
      );
    }
    final FriendProfile? friend = state.friendByAddress(peerAddress);
    if (friend == null) {
      return;
    }
    final int timestamp =
        observedAtMillis ?? DateTime.now().millisecondsSinceEpoch;
    final String key = PeerShareCodec.normalizeAddress(friend.address);
    final int openedAt = report.lastOpenedAt(timestamp);
    if (reachable) {
      _presenceSeenAt[key] = timestamp;
    }
    _presenceConfirmedAt[key] = timestamp;
    _openedAt[key] = openedAt;
    // Most pongs change nothing visible: the friend was online and still
    // is. Those stay in memory; the state (and every screen watching it)
    // changes only when something shows, or the stored time is old. The
    // last opening shows only once they are not online.
    final bool openedShows =
        report.presence != PeerPresence.online &&
        (openedAt - friend.lastOpenedAtMillis).abs() >=
            const Duration(minutes: 1).inMilliseconds;
    final bool visible =
        friend.isOnline != reachable ||
        friend.presence != report.presence ||
        friend.presenceDoubt != null ||
        (openedAt == 0) != (friend.lastOpenedAtMillis == 0) ||
        openedShows;
    final bool stale =
        timestamp - friend.presenceAtMillis >
            kPresenceStoreEvery.inMilliseconds ||
        (reachable &&
            timestamp - friend.lastPresenceAtMillis >
                kPresenceStoreEvery.inMilliseconds);
    if (!visible && !stale) {
      return;
    }
    state = state.copyWith(
      book: state.book.edit(
        friend.address,
        (FriendProfile f) => f.copyWith(
          isOnline: reachable,
          lastPresenceAtMillis: reachable ? timestamp : null,
          presence: report.presence,
          presenceAtMillis: timestamp,
          // Heard from them just now: no longer in doubt.
          presenceDoubt: null,
          lastOpenedAtMillis: openedAt,
        ),
      ),
    );
    _persistSoon();
  }

  /// Whether this device reaches the network, as it changes: without it
  /// nothing from friends can come, so every friend shows "brak
  /// połączenia" ([PresenceDoubt.noNetwork]: the last state known is kept
  /// and does not expire into "offline"); back on it, each one shows what
  /// that state is worth by now, or "status nieznany" when it was confirmed
  /// longer than [kPresenceRememberedFor] ago ([_rememberedPresence]),
  /// until they answer or the answers had time to come ([decayPresence]
  /// with `settleUnchecked`).
  Future<void> notePresenceNetwork({
    required bool reachable,
    Duration offlineAfter = kPresenceOfflineAfter,
    Duration foregroundFor = kPresenceForegroundFor,
    int? nowMillis,
  }) {
    return _enqueueStateWork(() async {
      final int timestamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
      _reviewPresence(
        (FriendProfile friend) => !reachable
            ? _inDoubt(friend, PresenceDoubt.noNetwork)
            : friend.presenceDoubt == PresenceDoubt.noNetwork
            ? _rechecked(
                friend,
                nowMillis: timestamp,
                offlineAfter: offlineAfter,
                foregroundFor: foregroundFor,
              )
            : friend,
      );
    });
  }

  /// Zen came back to the screen after a while: a friend whose presence
  /// would have expired by now shows what it is worth (offline), however
  /// long ago it was confirmed, until they answer the pings that go out
  /// now.
  Future<void> recheckStalePresence({
    required Duration offlineAfter,
    required Duration foregroundFor,
    int? nowMillis,
  }) {
    return _enqueueStateWork(() async {
      final int timestamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
      _reviewPresence((FriendProfile friend) {
        if (friend.presenceDoubt != null) {
          return friend;
        }
        final int confirmed = max(
          friend.presenceAtMillis,
          _presenceConfirmedAt[PeerShareCodec.normalizeAddress(
                friend.address,
              )] ??
              0,
        );
        final PeerPresence now = presenceAt(
          presence: friend.presence,
          presenceAtMillis: confirmed,
          nowMillis: timestamp,
          foregroundFor: foregroundFor,
          backgroundFor: offlineAfter,
        );
        if (now == friend.presence) {
          return friend;
        }
        return _rechecked(
          friend,
          nowMillis: timestamp,
          offlineAfter: offlineAfter,
          foregroundFor: foregroundFor,
        );
      });
    });
  }

  /// [friend] in doubt for [doubt], with the last confirmation as memory
  /// has it, for "ostatnio w sieci 2 godz. temu" (the state keeps an older
  /// time while nothing shows).
  FriendProfile _inDoubt(FriendProfile friend, PresenceDoubt doubt) {
    if (friend.presenceDoubt == doubt) {
      return friend;
    }
    final String key = PeerShareCodec.normalizeAddress(friend.address);
    return friend.copyWith(
      presenceDoubt: doubt,
      presenceAtMillis: max(
        friend.presenceAtMillis,
        _presenceConfirmedAt[key] ?? 0,
      ),
      lastPresenceAtMillis: max(
        friend.lastPresenceAtMillis,
        _presenceSeenAt[key] ?? 0,
      ),
    );
  }

  /// [friend]'s presence at [nowMillis] after a while without a word
  /// ([_rememberedPresence]), with what memory knows of them.
  FriendProfile _rechecked(
    FriendProfile friend, {
    required int nowMillis,
    required Duration offlineAfter,
    required Duration foregroundFor,
  }) {
    final String key = PeerShareCodec.normalizeAddress(friend.address);
    return _rememberedPresence(
      friend,
      nowMillis: nowMillis,
      foregroundFor: foregroundFor,
      offlineAfter: offlineAfter,
      confirmedAtMillis: _presenceConfirmedAt[key] ?? 0,
      seenAtMillis: _presenceSeenAt[key] ?? 0,
      openedAtMillis: _openedAt[key] ?? 0,
    );
  }

  /// Each accepted friend who shows presence as [review] has it now; one
  /// change of the state. Doubt lives only in memory; a state that settles
  /// is saved with the next save.
  void _reviewPresence(FriendProfile Function(FriendProfile friend) review) {
    final FriendshipBook book = state.book.editAll(
      (FriendProfile friend) =>
          friend.status != FriendRelationshipStatus.accepted ||
              friend.presence == PeerPresence.hidden
          ? friend
          : review(friend),
    );
    if (!identical(book, state.book)) {
      state = state.copyWith(book: book);
      _persistSoon();
    }
  }

  /// Shows nothing more of [peerAddress]'s presence (a weak acquaintance:
  /// no statuses either way), whatever they showed before.
  Future<void> hidePeerPresence(String peerAddress) {
    return _enqueueStateWork(() async {
      final FriendProfile? friend = state.friendByAddress(peerAddress);
      if (friend == null ||
          (friend.presence == PeerPresence.hidden &&
              friend.lastOpenedAtMillis == 0)) {
        return;
      }
      _openedAt.remove(PeerShareCodec.normalizeAddress(friend.address));
      state = state.copyWith(
        book: state.book.edit(
          friend.address,
          (FriendProfile f) =>
              f.copyWith(presence: PeerPresence.hidden, lastOpenedAtMillis: 0),
        ),
      );
      _persistSoon();
    });
  }

  /// Remembers the Zen version an accepted friend named in a ping or pong.
  /// Self-reported: it only feeds the "friends have a newer Zen"
  /// hint, nothing else may depend on it.
  Future<void> notePeerAppVersion({
    required String peerAddress,
    required String version,
  }) {
    return _enqueueStateWork(() async {
      if (!isValidAppVersion(version)) {
        return;
      }
      final FriendProfile? friend = state.friendByAddress(peerAddress);
      if (friend == null ||
          friend.status != FriendRelationshipStatus.accepted ||
          state.peerAppVersions[friend.address] == version) {
        return;
      }
      state = state.copyWith(
        peerAppVersions: <String, String>{
          ...state.peerAppVersions,
          friend.address: version,
        },
      );
      _persistSoon();
    });
  }

  /// Friends with no sign of life lately count as offline: "online" after
  /// [foregroundFor] without one, "w tle" (and being reachable at all)
  /// after [offlineAfter]. A friend whose presence is in doubt keeps the
  /// last one known: with no network nothing could come; one not checked
  /// lately ([PresenceDoubt.unchecked]) is settled only with
  /// [settleUnchecked] (the answers to a round had time to come), and then
  /// shows what that last state is worth by now.
  Future<void> decayPresence({
    required Duration offlineAfter,
    required Duration foregroundFor,
    bool settleUnchecked = false,
    int? nowMillis,
  }) {
    return _enqueueStateWork(
      () => _decayPresence(
        offlineAfter: offlineAfter,
        foregroundFor: foregroundFor,
        settleUnchecked: settleUnchecked,
        nowMillis: nowMillis,
      ),
    );
  }

  Future<void> _decayPresence({
    required Duration offlineAfter,
    required Duration foregroundFor,
    required bool settleUnchecked,
    int? nowMillis,
  }) async {
    if (offlineAfter <= Duration.zero) {
      return;
    }
    final int timestamp = nowMillis ?? DateTime.now().millisecondsSinceEpoch;
    final FriendshipBook book = state.book.editAll((FriendProfile friend) {
      final String key = PeerShareCodec.normalizeAddress(friend.address);
      final int seen = max(
        friend.lastPresenceAtMillis,
        _presenceSeenAt[key] ?? 0,
      );
      final int confirmed = max(
        friend.presenceAtMillis,
        _presenceConfirmedAt[key] ?? 0,
      );
      final bool unreachable =
          friend.isOnline &&
          seen > 0 &&
          timestamp - seen >= offlineAfter.inMilliseconds;
      final PresenceDoubt? doubt = friend.presenceDoubt;
      final bool settles = doubt == PresenceDoubt.unchecked && settleUnchecked;
      final PeerPresence presence = doubt != null && !settles
          ? friend.presence
          : presenceAt(
              presence: friend.presence,
              presenceAtMillis: confirmed,
              nowMillis: timestamp,
              foregroundFor: foregroundFor,
              backgroundFor: offlineAfter,
            );
      if (!unreachable && !settles && presence == friend.presence) {
        return friend;
      }
      return friend.copyWith(
        isOnline: unreachable ? false : null,
        lastPresenceAtMillis: seen,
        presence: presence,
        presenceAtMillis: confirmed,
        presenceDoubt: settles ? null : doubt,
        // Online until now: they last had Zen open at the last sign.
        lastOpenedAtMillis: friend.presence == PeerPresence.online
            ? max(friend.lastOpenedAtMillis, _openedAt[key] ?? 0)
            : null,
      );
    });
    if (identical(book, state.book)) {
      return;
    }
    state = state.copyWith(book: book);
    // Going offline is rare and shows, so it is saved now.
    await _persistState();
  }

  /// The group chat is on screen: its messages count as read and stay quiet.
  Future<void> enterGroupConversation(String groupId) async {
    _openGroupId = groupId;
    await markGroupRead(groupId);
  }

  void leaveGroupConversation(String groupId) {
    if (_openGroupId == groupId) {
      _openGroupId = null;
    }
  }

  Future<void> markGroupRead(String groupId) async {
    final GroupProfile? group = state.groups[groupId];
    if (group == null || group.unreadCount == 0) {
      return;
    }
    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      state.groups,
    );
    groups[groupId] = group.copyWith(unreadCount: 0);
    state = state.copyWith(groups: groups);
    await _persistState();
  }

  Future<void> enterConversation(String peerAddress) async {
    _openConversationAddress = peerAddress;
    await markConversationRead(peerAddress);
  }

  void leaveConversation(String peerAddress) {
    if (_openConversationAddress == peerAddress) {
      _openConversationAddress = null;
    }
  }

  /// A new group of this person and [memberAddresses]; with nobody chosen
  /// it is a group of one, and members are invited later
  /// ([addMemberToGroup]).
  Future<GroupProfile> createGroup({
    required String name,
    required String description,
    required List<String> memberAddresses,
    String avatarPreset = 'group_default',
  }) async {
    final int now = DateTime.now().millisecondsSinceEpoch;
    final String localAddr = ref.read(runtimeNodeSnapshotProvider).localAddress;
    final List<String> invitees = normalizedGroupMembers(memberAddresses)
        .where(
          (String member) =>
              localAddr.isEmpty ||
              !PeerShareCodec.addressesEqual(member, localAddr),
        )
        .toList(growable: false);
    if (name.trim().isEmpty) {
      throw FormatException(t('Nadaj grupie nazwę.'));
    }
    final String groupId = 'group-$now-${invitees.length}';
    final GroupProfile group = GroupProfile(
      id: groupId,
      name: name.trim(),
      description: description.trim(),
      avatarPreset: avatarPreset,
      createdById: 'self',
      createdAtMillis: now,
      memberAddresses: List<String>.unmodifiable(
        normalizedGroupMembers(<String>[
          if (localAddr.isNotEmpty) localAddr,
          ...invitees,
        ]),
      ),
      lastActivityLabel: t('Teraz'),
      lastMessagePreview: t('Utworzono grupę.'),
      // Everyone stays on this list until their device confirms the invite;
      // see [syncGroupInvitesToPeer].
      pendingInviteAddresses: invitees,
      pendingInviteIds: <String, String>{
        for (final String member in invitees) member: _newInviteId(),
      },
    );

    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      state.groups,
    );
    groups[groupId] = group;
    state = state.copyWith(groups: groups);
    await _persistState();

    for (final String member in invitees) {
      unawaitedLogged(
        _sendFriendLifecycleSignal(
          peerAddress: member,
          payload: _groupInvitePayload(
            group,
            inviteId: group.pendingInviteIds[member],
          ),
        ),
        context: 'broadcast group invite to $member',
      );
    }
    return group;
  }

  /// Groups kept in step with something outside the chats (the cells of
  /// the pyramid): every member's device works out the same members, so
  /// nothing is sent — each group whose id starts with [prefix] is only
  /// created, updated or dropped here, as [wanted] says.
  Future<void> syncManagedGroups(
    String prefix,
    Map<String, ({String name, List<String> members})> wanted,
  ) async {
    await _enqueueStateWork(() async {
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.of(
        state.groups,
      );
      bool changed = false;
      for (final String id in groups.keys.toList()) {
        if (id.startsWith(prefix) && !wanted.containsKey(id)) {
          groups.remove(id);
          changed = true;
        }
      }
      for (final MapEntry<String, ({String name, List<String> members})> e
          in wanted.entries) {
        if (!e.key.startsWith(prefix)) {
          continue;
        }
        final List<String> members = cappedGroupMembers(
          normalizedGroupMembers(e.value.members),
        );
        final GroupProfile? had = groups[e.key];
        if (had == null) {
          groups[e.key] = GroupProfile(
            id: e.key,
            name: e.value.name,
            createdById: prefix,
            createdAtMillis: DateTime.now().millisecondsSinceEpoch,
            memberAddresses: members,
            lastActivityLabel: t('Teraz'),
            lastMessagePreview: t('Czat Twojej komórki w piramidzie.'),
          );
          changed = true;
        } else if (had.name != e.value.name ||
            had.isInvitePending ||
            !listEquals(had.memberAddresses, members)) {
          groups[e.key] = had.copyWith(
            name: e.value.name,
            memberAddresses: members,
            isInvitePending: false,
          );
          changed = true;
        }
      }
      if (changed) {
        state = state.copyWith(groups: groups);
        await _persistState();
      }
    });
  }

  Future<void> addMemberToGroup({
    required String groupId,
    required String memberAddress,
  }) async {
    final GroupProfile? current = state.groups[groupId];
    final String member = PeerShareCodec.normalizeAddress(memberAddress);
    if (current == null ||
        current.isInvitePending ||
        isManagedGroup(current) ||
        member.isEmpty ||
        groupHasMember(current, member)) {
      return;
    }
    final GroupProfile updated = current.copyWith(
      memberAddresses: normalizedGroupMembers(<String>[
        ...current.memberAddresses,
        member,
      ]),
      pendingInviteAddresses: normalizedGroupMembers(<String>[
        ...current.pendingInviteAddresses,
        member,
      ]),
      pendingInviteIds: <String, String>{
        ...current.pendingInviteIds,
        member: _newInviteId(),
      },
      lastActivityLabel: t('Teraz'),
    );
    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      state.groups,
    );
    groups[groupId] = updated;
    state = state.copyWith(groups: groups);
    await _persistState();

    final Map<String, dynamic> sync = _groupInvitePayload(updated);
    final String localAddr = ref.read(runtimeNodeSnapshotProvider).localAddress;
    // The newcomer gets the invite; everyone already in the group gets the
    // same payload as a member-list update (they merge it without any inbox
    // entry). Without that, the others dropped the newcomer's messages as
    // coming from a stranger.
    for (final String recipient in updated.memberAddresses) {
      if (localAddr.isNotEmpty &&
          PeerShareCodec.addressesEqual(recipient, localAddr)) {
        continue;
      }
      // Only the newcomer gets a real invitation (with its id).
      final bool isNewcomer = PeerShareCodec.addressesEqual(recipient, member);
      unawaitedLogged(
        _sendFriendLifecycleSignal(
          peerAddress: recipient,
          payload: isNewcomer
              ? _groupInvitePayload(
                  updated,
                  inviteId: updated.pendingInviteIds[member],
                )
              : sync,
        ),
        context: 'sync group membership to $recipient',
      );
    }
  }

  Future<void> acceptGroupInvite({
    required String groupId,
    required String groupName,
    String? senderAddress,
    List<String>? memberAddresses,
    String? inboxEntryId,
  }) async {
    SocialHubState next = _withoutRejectedGroup(state, groupId);
    final GroupProfile? existing = next.groups[groupId];
    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      next.groups,
    );
    if (existing == null) {
      final String localAddr = ref
          .read(runtimeNodeSnapshotProvider)
          .localAddress;
      groups[groupId] = GroupProfile(
        id: groupId,
        name: groupName,
        createdById: senderAddress ?? 'unknown',
        createdAtMillis: DateTime.now().millisecondsSinceEpoch,
        memberAddresses: normalizedGroupMembers(<String>[
          if (senderAddress != null && senderAddress.isNotEmpty) senderAddress,
          if (localAddr.isNotEmpty) localAddr,
          ...?memberAddresses,
        ]),
        lastActivityLabel: t('Teraz'),
        lastMessagePreview: t('Dołączono do grupy.'),
      );
    } else if (existing.isInvitePending) {
      groups[groupId] = existing.copyWith(
        isInvitePending: false,
        lastMessagePreview: t('Dołączono do grupy.'),
        lastActivityLabel: t('Teraz'),
      );
    }
    bool isInviteFor(InboxEntry entry) =>
        entry.id == inboxEntryId ||
        (entry.type == InboxEntryType.groupInvite &&
            (entry.routeKey?.contains(groupId) ?? false));
    final List<InboxEntry> staleAlerts = next.backgroundAlerts
        .where(isInviteFor)
        .toList(growable: false);
    next = next.copyWith(
      groups: groups,
      inbox: next.inbox
          .where((InboxEntry e) => !isInviteFor(e))
          .toList(growable: false),
      backgroundAlerts: next.backgroundAlerts
          .where((InboxEntry e) => !isInviteFor(e))
          .toList(growable: false),
    );
    state = next;
    for (final InboxEntry alert in staleAlerts) {
      await _systemNotifications.dismiss(alert.id);
    }
    if (inboxEntryId != null) {
      await _systemNotifications.dismiss(inboxEntryId);
    }
    await _persistState();
    final String? inviter = senderAddress ?? existing?.createdById;
    if (inviter != null && isRoutablePeerAddress(inviter)) {
      _replyToGroupSignal(
        peerAddress: inviter,
        type: 'group_invite_ack',
        groupId: groupId,
      );
    }
  }

  Future<void> rejectGroupInvite({
    required String groupId,
    required String inboxEntryId,
    String? senderAddress,
  }) async {
    final GroupProfile? group = state.groups[groupId];
    await leaveGroup(groupId: groupId);
    // The inviter normally is a member and already got the leave from
    // `leaveGroup`; only a group we never had locally needs this one.
    final bool inviterAlreadyTold =
        group != null &&
        senderAddress != null &&
        groupHasMember(group, senderAddress);
    if (senderAddress != null &&
        senderAddress.isNotEmpty &&
        !inviterAlreadyTold) {
      unawaitedLogged(
        _sendFriendLifecycleSignal(
          peerAddress: senderAddress,
          payload: <String, dynamic>{'type': 'group_leave', 'groupId': groupId},
        ),
        context: 'send group leave to $senderAddress',
      );
    }
    final List<InboxEntry> nextInbox = state.inbox
        .where(
          (InboxEntry e) =>
              e.id != inboxEntryId &&
              !(e.type == InboxEntryType.groupInvite &&
                  (e.routeKey?.contains(groupId) ?? false)),
        )
        .toList();
    final List<InboxEntry> nextAlerts = state.backgroundAlerts
        .where(
          (InboxEntry e) =>
              e.id != inboxEntryId &&
              !(e.type == InboxEntryType.groupInvite &&
                  (e.routeKey?.contains(groupId) ?? false)),
        )
        .toList();
    for (final InboxEntry alert in state.backgroundAlerts) {
      if (alert.id == inboxEntryId ||
          (alert.type == InboxEntryType.groupInvite &&
              (alert.routeKey?.contains(groupId) ?? false))) {
        await _systemNotifications.dismiss(alert.id);
      }
    }
    await _systemNotifications.dismiss(inboxEntryId);
    final List<QueuedSignal> queue = await _queueStore.load();
    final List<QueuedSignal> nextQueue = queue
        .where(
          (QueuedSignal q) =>
              !(q.signal.type == ZenSignalType.groupInvite &&
                  q.signal.groupId == groupId),
        )
        .toList();
    if (queue.length != nextQueue.length) {
      await _queueStore.save(nextQueue);
    }
    state = state.copyWith(
      inbox: nextInbox,
      backgroundAlerts: nextAlerts,
      pendingSignalCount: nextQueue.length,
    );
    await _persistState();
  }

  Future<void> leaveGroup({required String groupId}) async {
    await _dropGroupCallsFor(groupId);
    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      state.groups,
    );
    final GroupProfile? removed = groups.remove(groupId);
    if (removed != null) {
      // The account's other devices leave it too.
      ref.read(accountDirectoryHolderProvider).groupLeft?.call(groupId);
    }
    state = _withRejectedGroup(
      state,
      groupId,
      inviteIds: removed?.receivedInviteIds ?? const <String>[],
    ).copyWith(groups: groups);
    await _persistState();
    if (removed == null) {
      return;
    }
    final String localAddr = ref.read(runtimeNodeSnapshotProvider).localAddress;
    for (final String member in removed.memberAddresses) {
      if (localAddr.isNotEmpty &&
          PeerShareCodec.addressesEqual(member, localAddr)) {
        continue;
      }
      unawaitedLogged(
        _sendFriendLifecycleSignal(
          peerAddress: member,
          payload: <String, dynamic>{'type': 'group_leave', 'groupId': groupId},
        ),
        context: 'broadcast group leave to $member',
      );
    }
  }

  /// Sends [text] to a group; as a reply to [replyTo], or marked as
  /// [forwarded] from another chat. Its `<@N>` tokens name [mentions]
  /// (`mentions.dart`): only members of the group are kept, and only those
  /// the text really names.
  @override
  Future<void> sendGroupMessage({
    required String groupId,
    required String text,
    ChatReply? replyTo,
    bool forwarded = false,
    List<Mention> mentions = const <Mention>[],
  }) async {
    final GroupProfile? group = state.groups[groupId];
    if (group == null || text.trim().isEmpty) {
      return;
    }
    if (group.isInvitePending) {
      throw StateError(t('Najpierw dołącz do grupy.'));
    }
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final String messageId = 'grp-msg-$timestamp-$groupId';
    // Someone outside the group is never mentioned: such a text goes with
    // plain names.
    final bool members = usedMentions(
      text,
      mentions,
    ).every((Mention m) => groupHasMember(group, m.address));
    final String trimmed =
        (members ? text : mentionsAsPlainText(text, mentions)).trim();
    final List<Mention> named = members ? mentions : const <Mention>[];
    final String said = mentionsAsPlainText(trimmed, named);

    await _messageTimelineStore.append(
      'group:$groupId',
      ChatMessage(
        id: messageId,
        sender: 'self',
        text: trimmed,
        sentAtMillis: timestamp,
        direction: ChatMessageDirection.outgoing,
        // "Sent" once every member's copy is queued, "delivered" once all
        // confirmed it (the relay layer's report).
        deliveryState: ChatMessageDeliveryState.sending,
        reply: replyTo,
        forwarded: forwarded,
        mentions: named,
      ),
    );
    _bumpTimelineRevision();

    final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
      state.groups,
    );
    groups[groupId] = group.copyWith(
      lastMessagePreview: said,
      lastActivityLabel: t('Teraz'),
    );
    state = state.copyWith(groups: groups);
    await _persistState();

    await _sendGroupMessageToMembers(
      group: group,
      messageId: messageId,
      text: trimmed,
      timestamp: timestamp,
      skip: const <String>{},
      extra: <String, dynamic>{
        if (replyTo != null) 're': replyTo.toJson(),
        if (forwarded) 'fwd': true,
        if (named.isNotEmpty) kMentionsKey: mentionsToJson(named),
      },
    );
  }

  Future<void> _dismissRemovedAlerts(
    List<InboxEntry> current,
    List<InboxEntry> next,
  ) async {
    final Set<String> keptIds = next
        .map((InboxEntry entry) => entry.id)
        .toSet();
    for (final InboxEntry entry in current) {
      if (!keptIds.contains(entry.id)) {
        await _notificationCenter.dismiss(entry.id);
      }
    }
  }
}
