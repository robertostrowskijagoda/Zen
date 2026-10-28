part of 'social_hub_controller.dart';

mixin _SocialHubLifecycleSignalMixin on _SocialHubControllerBase {
  @override
  SocialHubState build() {
    final SocialHubState initialState = ref.read(socialHubSeedProvider);
    if (!_hydrationScheduled) {
      _hydrationScheduled = true;
      final CallMediaSessionController callMedia = _callMedia;
      callMedia.onStatusChanged = _handleCallMediaStatusChanged;
      callMedia.onError = _handleCallMediaError;
      _wireGroupCallMedia();
      _watchOwnProfile();
      // Image providers and players of this isolate find the vault there.
      ref.read(mediaVaultProvider);
      ref.onDispose(() {
        _controllerDisposed = true;
        _persistSoonTimer?.cancel();
        _persistSoonTimer = null;
        // Nothing is going to read the snapshot any more; leaving writers
        // parked on it would strand them.
        _markHydrationSettled();
        callMedia.onStatusChanged = null;
        callMedia.onError = null;
        _pendingOfferTimeoutTimer?.cancel();
        _pendingOfferTimeoutTimer = null;
        _callRingingTimeoutTimer?.cancel();
        _callRingingTimeoutTimer = null;
        _callOfferResendTimer?.cancel();
        _callOfferResendTimer = null;
        _stopCallReRing();
        _cancelCallTeardownRetries();
        _disappearTimer?.cancel();
        _disappearTimer = null;
        unawaited(callMedia.close());
        for (final RealtimeAttachmentTransferSession session
            in _activeRealtimeTransfers.values) {
          unawaited(session.close());
        }
        _activeRealtimeTransfers.clear();
      });
      if (ref.read(socialHubAutoHydrateProvider)) {
        // Queued right here, not from a microtask: that puts the read of the
        // stored snapshot ahead of every other piece of state work, so nothing
        // can persist the empty seed before it lands. Nothing awaits it, so an
        // error would otherwise surface as an unhandled async error.
        unawaitedLogged(
          hydrateFromStore(),
          context: 'Hydrating the social hub failed',
        );
      } else {
        // Hydration is the embedder's job here (the background service does it
        // as its first step); persisting must not stay blocked on it.
        _markHydrationSettled();
      }
    }
    return initialState;
  }

  bool _relayReportsWatched = false;

  /// Takes the mailbox layer's delivery news (`RelayEngine.takeDeliveryReports`)
  /// into the chats: a message that expired unacknowledged in the queue is
  /// marked failed, one too large for mailboxes goes back to "sending" (it
  /// only arrives while both devices are online), and a group message is
  /// delivered once every member confirmed it.
  void _watchRelayDeliveryReports() {
    if (_relayReportsWatched) {
      return;
    }
    final RelayEngine? engine = ref.read(relayEngineProvider);
    if (engine == null) {
      return;
    }
    _relayReportsWatched = true;
    void onChange() {
      if (engine.deliveryReportCount.value > 0 && ref.mounted) {
        unawaitedLogged(
          _drainRelayDeliveryReports(engine),
          context: 'Applying mailbox delivery reports failed',
        );
      }
    }

    engine.deliveryReportCount.addListener(onChange);
    ref.onDispose(() => engine.deliveryReportCount.removeListener(onChange));
    onChange();
  }

  Future<void> _drainRelayDeliveryReports(RelayEngine engine) async {
    final List<RelayDeliveryReport> reports = await engine
        .takeDeliveryReports();
    for (final RelayDeliveryReport report in reports) {
      if (_controllerDisposed || !ref.mounted) {
        return;
      }
      String peer = report.recipient;
      final String? groupId = report.groupId;
      if (groupId != null) {
        peer = 'group:$groupId';
      } else {
        for (final String address in state.friends.keys) {
          if (PeerShareCodec.addressesEqual(address, report.recipient)) {
            peer = address;
            break;
          }
        }
      }
      final List<ChatMessage> thread = await _messageTimelineStore.load(peer);
      final int index = thread.indexWhere(
        (ChatMessage m) => m.id == report.messageId,
      );
      if (index < 0) {
        continue;
      }
      final ChatMessageDeliveryState current = thread[index].deliveryState;
      // A delivered message stays delivered (its ack may beat the report).
      if (current != ChatMessageDeliveryState.sending &&
          current != ChatMessageDeliveryState.sent) {
        continue;
      }
      final ChatMessageDeliveryState next = switch (report.status) {
        RelayDeliveryStatus.expired => ChatMessageDeliveryState.failed,
        RelayDeliveryStatus.directOnly => ChatMessageDeliveryState.sending,
        RelayDeliveryStatus.delivered => ChatMessageDeliveryState.delivered,
      };
      if (next == current) {
        continue;
      }
      await _updateMessageDeliveryState(
        peerAddress: peer,
        messageId: report.messageId,
        deliveryState: next,
      );
    }
  }

  Future<void> setLifecycle(LifecycleSnapshot snapshot) {
    return _enqueueStateWork(() => _setLifecycle(snapshot));
  }

  Future<void> _setLifecycle(LifecycleSnapshot snapshot) async {
    final LifecycleSnapshot previous = state.lifecycle;
    state = state.copyWith(lifecycle: snapshot);
    if (_isUiInteractive(snapshot)) {
      if (previous.isBackgroundLike) {
        await _adoptSnapshotWrittenInBackground();
        if (!ref.mounted) {
          return;
        }
      }
      // Only once the user is actually looking: a visible but unfocused
      // window still needs its notifications.
      if (_isUiFocused(snapshot)) {
        await _systemNotifications.clear();
      }
      if (!ref.mounted) {
        return;
      }
      // The unqueued flush: this already runs inside the queue.
      await _flushPendingSignals();
      if (!ref.mounted) {
        return;
      }
      // Back to a conversation that stayed open: what came in meanwhile
      // (no read receipt went while nobody looked) is seen now. The
      // conversation is not entered again, so this is the only moment.
      final String? open = _openConversationAddress;
      if (open != null && !_isUiInteractive(previous)) {
        await _sendReadReceiptIfNeeded(open);
        if (!ref.mounted) {
          return;
        }
      }
      await _syncRingingCallWindow();
      if (!ref.mounted) {
        return;
      }
      await _resumeOutgoingAttachmentTransfers();
      return;
    }
    if (!ref.mounted) {
      return;
    }
    await _persistState();
  }

  /// Takes over what another isolate stored while this one was away.
  ///
  /// On Android the foreground service runs its own copy of this controller
  /// while the app is in the background, and it persists everything it
  /// handles. The UI isolate still holds the state from before it left the
  /// screen; persisting that on the way back (every flush does) overwrote the
  /// service's work — accepted friends, joined groups, alerts. A no-op
  /// wherever only one isolate writes, because the stored snapshot then
  /// already equals the in-memory one.
  Future<void> _adoptSnapshotWrittenInBackground() async {
    if (!_hydrationCompleted) {
      return;
    }
    if (state.snapshotUnreadable) {
      // Still on a stand-in for a snapshot that could not be read: the way
      // back is the full read, which may succeed now (a passing storage
      // error). Failing again changes nothing.
      try {
        await _hydrateFromStore();
      } on Object catch (error, stackTrace) {
        logZenError(
          'Re-reading the unreadable snapshot failed',
          error,
          stackTrace,
        );
      }
      return;
    }
    final SocialHubState before = state;
    final SocialHubState? persisted;
    try {
      persisted = await _snapshotStore.load();
    } catch (error, stackTrace) {
      logZenError('Re-reading the stored snapshot failed', error, stackTrace);
      return;
    }
    if (persisted == null || _controllerDisposed || !ref.mounted) {
      return;
    }
    if (!identical(state, before)) {
      // Changed while it was read, by something outside this queue (the
      // person's own action): what is in memory is newer than what was
      // read, and stays.
      return;
    }
    final CallSession? current = state.activeCall;
    final bool mediaOwnsCall =
        current != null &&
        (_callMedia.activeCallId == current.id ||
            _groupMedia.activeCallId == current.id);
    state = _withTrimmedInbox(
      persisted.copyWith(
        lifecycle: state.lifecycle,
        friends: _canonicalizeFriends(persisted.friends),
        activeCall: mediaOwnsCall
            ? current
            : _restorableCallSession(persisted.activeCall),
        groupCalls: state.groupCalls,
        pendingLaunchIntent:
            state.pendingLaunchIntent ?? persisted.pendingLaunchIntent,
      ),
      _appSettings,
    );
    _dismissedOrRejectedGroupIds.addAll(state.rejectedGroupIds);
    _syncCallRingingTimeout();
  }

  Future<void> hydrateFromStore() {
    return _enqueueStateWork(_hydrateFromStore);
  }

  bool _awaitingUnlockHydration = false;

  /// Repeats the read once the app is unlocked. Not through the work queue:
  /// work queued meanwhile may be parked on the writers, which this read
  /// releases.
  void _hydrateOnUnlock() {
    if (_awaitingUnlockHydration) {
      return;
    }
    _awaitingUnlockHydration = true;
    final AppSecurityService security = _security;
    void onChange() {
      if (_controllerDisposed || !ref.mounted) {
        security.removeListener(onChange);
        return;
      }
      if (_isSecurityBlockingUi) {
        return;
      }
      security.removeListener(onChange);
      _awaitingUnlockHydration = false;
      unawaitedLogged(
        _hydrateFromStore(fromUnlock: true),
        context: 'Hydrating the social hub after unlock failed',
      );
    }

    security.addListener(onChange);
    ref.onDispose(() => security.removeListener(onChange));
  }

  Future<void> _hydrateFromStore({bool fromUnlock = false}) async {
    final SocialHubState? persisted;
    try {
      persisted = await _snapshotStore.load();
    } on Object {
      if (_isSecurityBlockingUi && !_controllerDisposed) {
        // Read while the app was still locked (something above the lock
        // screen woke the hub up early): the store has no key yet. Releasing
        // the writers now would let the empty seed overwrite every friend
        // and conversation right after unlocking — so they stay parked and
        // the read is repeated once the app is unlocked.
        _hydrateOnUnlock();
        return;
      }
      if (!_snapshotLoaded && !_controllerDisposed && ref.mounted) {
        // Unlocked, and still neither the snapshot nor its backup reads
        // back. The empty seed is not "no friends": treated as such, every
        // friend's ping would look like a stranger's, and the first save
        // would bury the snapshot under it. Marked, so that saving stays
        // paused, presence and reflexes stay quiet, and the user is told.
        logZenWarning(
          'Social snapshot unreadable: friends and groups are not loaded.',
        );
        state = state.copyWith(snapshotUnreadable: true);
      }
      // The writers are released all the same (nothing may wait forever);
      // while the state is marked unreadable, saving does nothing.
      _markHydrationSettled();
      rethrow;
    }
    _snapshotLoaded = true;
    _markHydrationSettled();
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    _watchRelayDeliveryReports();
    if (persisted == null) {
      if (state.snapshotUnreadable) {
        // A later read found nothing stored at all: nothing left to protect.
        state = state.copyWith(snapshotUnreadable: false);
      }
      return;
    }
    state = _withTrimmedInbox(
      persisted.copyWith(
        // The lifecycle belongs to this process, never to the snapshot. Taking
        // the stored one back makes an app that is on screen believe it is in
        // the background: the pending queue is not flushed and every incoming
        // signal raises a system notification on top of the open app.
        lifecycle: state.lifecycle,
        friends: _canonicalizeFriends(persisted.friends),
        groups: _canonicalizeGroups(persisted.groups),
        activeCall:
            state.activeCall ?? _restorableCallSession(persisted.activeCall),
        groupCalls: state.groupCalls,
      ),
      _appSettings,
    );
    _dismissedOrRejectedGroupIds.addAll(state.rejectedGroupIds);
    _syncCallRingingTimeout();
    if (fromUnlock) {
      // This read ran outside the work queue (see _hydrateOnUnlock) and has
      // just released the signals parked on it. The rest goes through the
      // queue, after them — never alongside them, or the flush below would
      // overwrite what they write.
      unawaitedLogged(
        _enqueueStateWork(_finishHydration),
        context: 'Finishing the social hub hydration failed',
      );
      return;
    }
    await _finishHydration();
  }

  /// Everything after the snapshot is in `state`; runs inside the queue.
  Future<void> _finishHydration() async {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    await _applyRetentionAcrossConversations(
      nowMillis: DateTime.now().millisecondsSinceEpoch,
    );
    // Disappearing messages that expired while the app was closed.
    if (state.disappearingTimers.isNotEmpty) {
      await sweepDisappearingMessages();
    }
    // The unqueued flush: this already runs inside the queue.
    await _flushPendingSignals();
    if (!ref.mounted) {
      return;
    }
    await _resumeOutgoingAttachmentTransfers();
    if (!ref.mounted) {
      return;
    }
    await _pruneStaleIncomingTransfers();
    if (!ref.mounted) {
      return;
    }
    // Friends may still hold an older profile.
    await _broadcastOwnProfileIfChanged();
  }

  /// Handles one incoming signal, strictly one at a time.
  ///
  /// Handling is asynchronous all the way down — timelines, the queue and the
  /// snapshot all go through encrypted stores — while every step reads and
  /// writes `state`. Two signals in flight at once each start from the
  /// snapshot they read on entry, so the second one loses whatever the first
  /// wrote. A call makes that immediate: the invite and its SDP offer arrive
  /// together and the caller re-sends the invite once a second, so both would
  /// decide the call is brand new and both would raise the ringing
  /// notification — over and over, on a call that was already answered.
  Future<void> receiveSignal(ZenSignal signal, {int? receivedAtMillis}) {
    final Future<void> handled = _enqueueStateWork(() async {
      if (!_hydrationCompleted) {
        // Locked app: the stored friends are not read yet, so every friend
        // would look like a stranger, and whatever this signal adds would be
        // replaced by the snapshot read after unlocking. It waits for that
        // read instead.
        await _hydrationSettled.future;
        if (_controllerDisposed || !ref.mounted) {
          return;
        }
      }
      final FriendRelationshipStatus? before =
          signal.type == ZenSignalType.friendRequest
          ? state
                .friendByAddress(PeerShareCodec.normalizeAddress(signal.sender))
                ?.status
          : null;
      final bool askedThemToo =
          before == FriendRelationshipStatus.pendingOutgoing;
      // A friend asking again lost our answer: it only goes again (they
      // were let in once already) — no notice, no request, no queue copy.
      final bool friendsAlready = before == FriendRelationshipStatus.accepted;
      if (!friendsAlready) {
        await _handleIncomingSignal(signal, receivedAtMillis: receivedAtMillis);
      }
      if ((askedThemToo || friendsAlready) &&
          state
                  .friendByAddress(
                    PeerShareCodec.normalizeAddress(signal.sender),
                  )
                  ?.status ==
              FriendRelationshipStatus.accepted) {
        // Mutual requests: tell them it is done (their side may still wait
        // with its own request) and show who we are.
        final String peer = PeerShareCodec.normalizeAddress(signal.sender);
        unawaitedLogged(
          _sendFriendLifecycleSignal(
            peerAddress: peer,
            payload: const <String, dynamic>{'type': 'friend_accept'},
          ),
          context: 'Answering a mutual friend request failed',
        );
        unawaitedLogged(
          _sendOwnProfileTo(peer),
          context: 'Sending the profile after a mutual request failed',
        );
      }
    });
    // Any signal proves the peer is reachable right now: the moment to hand
    // it the group invites it missed while it was offline.
    return handled.whenComplete(() {
      if (_controllerDisposed || !ref.mounted) {
        return;
      }
      if (signal.type == ZenSignalType.friendAccept &&
          state.friendByAddress(signal.sender)?.status ==
              FriendRelationshipStatus.accepted) {
        // They said yes: now they should see who we are. Only for an accept
        // that really completed an invitation from here; an unsolicited one
        // stays a request and gets nothing.
        unawaitedLogged(
          _sendOwnProfileTo(signal.sender),
          context: 'Sending the profile after an accept failed',
        );
      }
      if (signal.type == ZenSignalType.groupInviteAck ||
          signal.type == ZenSignalType.groupLeave) {
        return;
      }
      unawaitedLogged(
        syncGroupInvitesToPeer(signal.sender),
        context: 'Syncing group invites after a signal failed',
      );
    });
  }

  /// Shows in the group's chat whom an ordinary member (not the creator)
  /// brought in, so a member list never grows behind everyone's back.
  Future<void> _noteGroupMembersAdded({
    required GroupProfile before,
    required List<String> after,
    required ZenSignal signal,
    required String localAddress,
    required int timestamp,
  }) async {
    final List<String> newcomers = <String>[
      for (final String address in after)
        if (!groupHasMember(before, address) &&
            (localAddress.isEmpty ||
                !PeerShareCodec.addressesEqual(address, localAddress)))
          address,
    ];
    if (newcomers.isEmpty || !ref.mounted) {
      return;
    }
    final String names = newcomers
        .map((String address) {
          final FriendProfile? friend = state.friendByAddress(address);
          return _resolvedPeerLabel(
            address: address,
            knownName: friend != null
                ? state.nameFor(friend)
                : state.peerProfileOf(address)?.name,
          );
        })
        .join(', ');
    final SocialEventText added = SocialEventText(
      'group.added',
      <String, String>{
        'name': _labelFor(signal, friends: state.friends),
        'members': names,
      },
    );
    await _messageTimelineStore.append(
      'group:${before.id}',
      chatMessageWithEvent(
        ChatMessage(
          id: 'system-added-$timestamp-${newcomers.first}',
          sender: 'system',
          text: added.render(),
          sentAtMillis: timestamp,
          direction: ChatMessageDirection.system,
        ),
        added,
      ),
    );
    _bumpTimelineRevision();
  }

  Future<void> _handleIncomingSignal(
    ZenSignal signal, {
    int? receivedAtMillis,
  }) async {
    signal = signal.withSender(PeerShareCodec.normalizeAddress(signal.sender));
    final int timestamp =
        receivedAtMillis ?? DateTime.now().millisecondsSinceEpoch;
    final FriendProfile? knownPeer = state.friendByAddress(signal.sender);
    if (signal.type == ZenSignalType.friendAccept &&
        knownPeer?.status != FriendRelationshipStatus.blocked &&
        !FriendLifecycleReducer.isSolicitedRemoteAccept(knownPeer)) {
      if (knownPeer?.status == FriendRelationshipStatus.pendingIncoming) {
        // Their request already waits for the user; "accepting" on their
        // own side skips nothing.
        return;
      }
      // Nobody here invited them. An accept must never turn a stranger into
      // a friend; it goes through everything below as the invitation it
      // amounts to, which the user still has to confirm.
      signal = _unsolicitedAcceptAsRequest(signal);
    }
    // Someone who is not a friend writing in an ordinary chat:
    // let in only within the limits, with their mini-profile.
    if (await _handleStrangerChatSignal(signal, timestamp)) {
      return;
    }
    if (!_isSignalAllowedFromPeer(state, signal)) {
      // Dropped without a word: an answer would tell anyone probing an
      // address that the device is online right there.
      return;
    }
    // Invitations are the one thing anyone may send. Beyond the caps on what
    // is kept (see `kMaxPendingIncomingFriendRequests`), a flood from one
    // identity is dropped outright, and a flood from many only stops
    // ringing the phone.
    final bool isStrangerInvite =
        (signal.type == ZenSignalType.friendRequest ||
            signal.type == ZenSignalType.groupInvite) &&
        knownPeer?.status != FriendRelationshipStatus.accepted;
    if (isStrangerInvite && !_admitStrangerInvite(signal.sender, timestamp)) {
      return;
    }
    final bool muteStrangerAlert =
        isStrangerInvite && !_admitStrangerAlert(signal.sender, timestamp);
    if (signal.type == ZenSignalType.profileUpdate) {
      await _handleProfileUpdate(signal);
      return;
    }
    if (signal.type == ZenSignalType.disappearTimer) {
      await _handleDisappearTimer(signal, timestamp);
      return;
    }
    if (signal.type == ZenSignalType.messageReaction ||
        signal.type == ZenSignalType.messageEdit ||
        signal.type == ZenSignalType.messageDelete) {
      // A reaction, an edit or a deletion of a message already here.
      await _handleChatChange(signal, timestamp);
      return;
    }
    if (_isGroupCallSignalType(signal.type)) {
      // Group calls run their own, real-time protocol: nothing is queued,
      // nothing goes through the generic notification path.
      await _handleGroupCallSignal(signal);
      return;
    }
    if (_isRepeatedLifecycleDelivery(signal, timestamp)) {
      // Lifecycle and group bookkeeping signals go out several times in a row
      // (see `_sendFriendLifecycleSignal`). The first copy did all the work;
      // every further copy used to raise the same notification again.
      return;
    }
    if (signal.type == ZenSignalType.groupInvite) {
      final String? gid = signal.groupId;
      if (gid != null && gid.isNotEmpty) {
        if (_isGroupRejected(gid) && _isFreshInvitation(signal)) {
          // Declined or left before, but this is a new invitation (someone
          // added the user again), not a re-send of the old one.
          state = _withoutRejectedGroup(state, gid);
        }
        if (_isGroupRejected(gid)) {
          // Tell the inviter to stop re-sending: it keeps the invite queued
          // until it hears back.
          _replyToGroupSignal(
            peerAddress: signal.sender,
            type: 'group_leave',
            groupId: gid,
          );
          return;
        }
        if (!state.groups.containsKey(gid) &&
            !groupInviteAllowed(
              ref.read(appSettingsControllerProvider).groupInviteFrom,
              isFriend: knownPeer?.status == FriendRelationshipStatus.accepted,
              level: ref.read(friendLevelLookupProvider).of(signal.sender),
            )) {
          // Below the level this person takes invitations from: said
          // no at once, so the inviter stops re-sending.
          _replyToGroupSignal(
            peerAddress: signal.sender,
            type: 'group_leave',
            groupId: gid,
          );
          return;
        }
        // Receipt, not acceptance: it only stops the inviter's re-sends.
        _replyToGroupSignal(
          peerAddress: signal.sender,
          type: 'group_invite_ack',
          groupId: gid,
        );
        if (state.groups.containsKey(gid)) {
          final GroupProfile existing = state.groups[gid]!;
          final bool fromCreator = PeerShareCodec.addressesEqual(
            existing.createdById,
            signal.sender,
          );
          if (!groupHasMember(existing, signal.sender) && !fromCreator) {
            // Only people already in the group may extend it.
            return;
          }
          final String localAddr = ref
              .read(runtimeNodeSnapshotProvider)
              .localAddress;
          // Only the creator may extend the list freely; any other member
          // brings in one person at a time (see `_groupMembersAfterInvite`).
          final List<String> updatedMembers =
              _groupMembersAfterInvite(
                existing,
                signal,
                selfAddress: localAddr,
              ) ??
              existing.memberAddresses;
          final String? inviteId = signal.inviteId;
          final bool newInvitation =
              existing.isInvitePending &&
              inviteId != null &&
              !existing.receivedInviteIds.contains(inviteId);
          if (updatedMembers.length != existing.memberAddresses.length ||
              newInvitation) {
            final Map<String, GroupProfile> groups =
                Map<String, GroupProfile>.from(state.groups);
            groups[gid] = existing.copyWith(
              memberAddresses: updatedMembers,
              receivedInviteIds: newInvitation
                  ? <String>[...existing.receivedInviteIds, inviteId]
                  : null,
            );
            state = state.copyWith(groups: groups);
            await _persistState();
            if (!fromCreator && !existing.isInvitePending) {
              await _noteGroupMembersAdded(
                before: existing,
                after: updatedMembers,
                signal: signal,
                localAddress: localAddr,
                timestamp: timestamp,
              );
            }
          }
          return;
        }
        if (state.inbox.any(
              (InboxEntry e) =>
                  e.type == InboxEntryType.groupInvite &&
                  (e.routeKey?.contains(gid) ?? false),
            ) ||
            state.backgroundAlerts.any(
              (InboxEntry e) =>
                  e.type == InboxEntryType.groupInvite &&
                  (e.routeKey?.contains(gid) ?? false),
            )) {
          return;
        }
      }
    }
    if (await _dropDisappearedCopy(signal)) {
      // A late copy of a disappearing message that is already gone here.
      return;
    }
    if (signal.type == ZenSignalType.message &&
        await _timelineHasMessage(
          peerAddress: signal.sender,
          messageId: _incomingMessageIdOf(signal),
        )) {
      // A copy of a message already on file (a re-send, or a datagram the
      // mesh delivered twice). Persisting it again only re-sends the delivery
      // ack the sender may have missed; it must not count as unread again,
      // go back into the inbox, or ring the phone a second time.
      await _persistSignalArtifacts(signal, timestamp);
      return;
    }
    if (signal.type == ZenSignalType.groupMessage &&
        (signal.messageId?.trim().isNotEmpty ?? false) &&
        await _timelineHasMessage(
          peerAddress: 'group:${signal.groupId}',
          messageId: signal.messageId!.trim(),
        )) {
      return;
    }
    // A group message that mentions this person says so (within limits).
    signal = _withMentionOfSelf(signal, timestamp);
    // Both flags are captured before anything mutates the call state.
    //
    // A repeated invite, offer, or ringing signal for the call already on file is just the
    // caller's re-ring — including after the user answered it — and must not
    // raise the notification (or the queue) again.
    final bool isRepeatRingingSignal =
        (signal.type == ZenSignalType.callInvite ||
            signal.type == ZenSignalType.callOffer ||
            signal.type == ZenSignalType.callRinging) &&
        _isKnownCallSignal(state.activeCall, signal);
    // A caller-cancelled ringing call posts its own missed-call note from
    // `_persistSignalArtifacts`, which runs next and clears the session — so
    // the generic "ended" entry has to be recognised as handled from here.
    final bool missedCallHandled =
        signal.type == ZenSignalType.callEnd &&
        _isRingingIncomingCallMatch(state.activeCall, signal);
    // Teardown signals are re-sent. The first copy did the bookkeeping — the
    // missed-call note included — so a repeat must not put a generic "call
    // ended" entry over it.
    final bool repeatedTeardown =
        (signal.type == ZenSignalType.callEnd ||
            signal.type == ZenSignalType.callDecline ||
            signal.type == ZenSignalType.callBusy) &&
        _isCallAlreadyTornDown(signal.callId);
    await _persistSignalArtifacts(signal, timestamp);
    if (signal.type == ZenSignalType.friendRemove) {
      // They ended it: nothing we still have queued for them should keep
      // being retried or parked in their mailboxes.
      await _cancelQueuedTraffic(signal.sender);
    }
    final LifecycleSnapshot routingLifecycle = _effectiveLifecycleForRouting();
    final SignalHandlingPlan plan = _routing.planFor(
      signal: signal,
      lifecycle: routingLifecycle,
    );
    final QueuedSignal queued = QueuedSignal(
      id: '$timestamp-${signal.type.index}-${signal.sender}',
      signal: signal,
      receivedAtMillis: timestamp,
    );
    List<QueuedSignal> queue = plan.persist
        ? await _queueStore.load()
        : const <QueuedSignal>[];

    final bool isDuplicateInQueue =
        _isDuplicateQueuedCallInvite(queue, signal) ||
        (signal.type == ZenSignalType.groupInvite &&
            signal.groupId != null &&
            queue.any(
              (QueuedSignal q) =>
                  q.signal.type == ZenSignalType.groupInvite &&
                  q.signal.groupId == signal.groupId,
            ));

    if (plan.persist && !isDuplicateInQueue) {
      queue = <QueuedSignal>[
        // Invitations are applied to the state the moment they arrive (see
        // `_isSocialLifecycleSignalType`); their queue copies only replay
        // what is already there. Anyone can send them, so past a cap the
        // oldest copies go - never the newest, whose order still matters.
        ...(isStrangerInvite
            ? _withoutOldestQueuedInvitations(
                queue,
                keep: kMaxQueuedInvitations - 1,
              )
            : queue),
        queued,
      ];
      await _queueStore.save(queue);
    }

    final bool isCallSignal =
        signal.type == ZenSignalType.callInvite ||
        signal.type == ZenSignalType.callOffer ||
        signal.type == ZenSignalType.callRinging ||
        signal.type == ZenSignalType.groupCallInvite;

    final RuntimeNotification? foregroundNotification =
        _isUiFocused() &&
            !isRepeatRingingSignal &&
            !isCallSignal &&
            !muteStrangerAlert
        ? _foregroundNotificationForSignal(
            signal: signal,
            receivedAtMillis: timestamp,
            friends: state.friends,
            groups: state.groups,
            privacy: _noticePrivacyFor(signal),
          )
        : null;

    if (!plan.deliverToUi) {
      final bool isCallSignal =
          signal.type == ZenSignalType.callInvite ||
          signal.type == ZenSignalType.callOffer ||
          signal.type == ZenSignalType.callRinging ||
          signal.type == ZenSignalType.groupCallInvite;
      final bool popupAlreadyPresented =
          signal.callId != null &&
          signal.callId!.trim().isNotEmpty &&
          _wasCallPopupPresented(signal.callId);
      final bool isRejectedOrExistingGroup =
          signal.type == ZenSignalType.groupInvite &&
          (signal.groupId != null &&
              (_dismissedOrRejectedGroupIds.contains(signal.groupId) ||
                  state.groups.containsKey(signal.groupId) ||
                  state.inbox.any(
                    (InboxEntry e) =>
                        e.type == InboxEntryType.groupInvite &&
                        (e.routeKey?.contains(signal.groupId!) ?? false),
                  ) ||
                  state.backgroundAlerts.any(
                    (InboxEntry e) =>
                        e.type == InboxEntryType.groupInvite &&
                        (e.routeKey?.contains(signal.groupId!) ?? false),
                  )));
      final bool skipSystemNotification =
          _isSilencedGroupSignal(signal) ||
          muteStrangerAlert ||
          isRepeatRingingSignal ||
          missedCallHandled ||
          popupAlreadyPresented ||
          isRejectedOrExistingGroup;
      final InboxEntry? backgroundEntry =
          (plan.showSystemNotification || isCallSignal) &&
              !repeatedTeardown &&
              !isRepeatRingingSignal &&
              !popupAlreadyPresented &&
              !isRejectedOrExistingGroup &&
              !_isSilencedGroupSignal(signal)
          ? _buildInboxEntry(
              signal: signal,
              receivedAtMillis: timestamp,
              friends: state.friends,
              groups: state.groups,
            )
          : null;
      final List<InboxEntry> backgroundAlerts =
          backgroundEntry != null &&
              backgroundEntry.type != InboxEntryType.callInvite
          ? _prependBackgroundAlert(
              state.backgroundAlerts,
              backgroundEntry,
              signal: signal,
            )
          : state.backgroundAlerts;
      if (backgroundEntry != null) {
        final bool displayed =
            skipSystemNotification ||
                _isIncomingRingingNotificationSignal(signal.type)
            ? false
            : await _presentSystemNotification(
                _systemNotificationFromEntry(
                  entry: backgroundEntry,
                  signal: signal,
                  friends: state.friends,
                  groups: state.groups,
                  privacy: _noticePrivacyFor(signal),
                ),
              );
        if (displayed && backgroundEntry.type != InboxEntryType.callInvite) {
          final Set<String> nextIds = backgroundAlerts
              .map((InboxEntry entry) => entry.id)
              .toSet();
          for (final InboxEntry previous in state.backgroundAlerts) {
            if (!nextIds.contains(previous.id)) {
              await _systemNotifications.dismiss(previous.id);
            }
          }
        }
      }
      // Lifecycle signals change the relationship itself, so apply them to
      // the persisted state right away instead of waiting for the next
      // foreground flush — otherwise a stale snapshot could restore the old
      // "pending" status after the queue was already drained. Call signals
      // are applied for the same reason: the notification buttons act on
      // `activeCall`, and a cancelled call must not linger until the ringing
      // deadline.
      SocialHubState backgroundState = state;
      if (_isSocialLifecycleSignalType(signal.type) ||
          _isCallSessionSignalType(signal.type)) {
        backgroundState = _withTrimmedInbox(
          _applySignal(
            backgroundState,
            signal,
            timestamp,
            appSettings: _appSettings,
            openConversationAddress: _openConversationAddress,
            openGroupId: _openGroupId,
            dismissedOrRejectedGroupIds: _dismissedOrRejectedGroupIds,
          ),
          _appSettings,
        );
      }
      state = backgroundState.copyWith(
        pendingSignalCount: queue.length,
        backgroundAlerts: backgroundAlerts,
      );
      _syncCallRingingTimeout();
      await _persistState();
      if (isCallSignal || missedCallHandled || repeatedTeardown) {
        await _syncRingingCallWindow();
      }
      return;
    }

    state = _applySignal(
      state,
      signal,
      timestamp,
      appSettings: _appSettings,
      openConversationAddress: _openConversationAddress,
      openGroupId: _openGroupId,
      dismissedOrRejectedGroupIds: _dismissedOrRejectedGroupIds,
    );
    state = _withTrimmedInbox(state, _appSettings);
    if (plan.persist) {
      queue = queue
          .where((QueuedSignal entry) => entry.id != queued.id)
          .toList(growable: false);
      await _queueStore.save(queue);
    }
    state = state.copyWith(pendingSignalCount: queue.length);
    _syncCallRingingTimeout();
    if (foregroundNotification != null) {
      await _notificationCenter.show(foregroundNotification);
    }
    await _persistState();
    final bool isCurrentChatOpen =
        signal.type == ZenSignalType.message &&
        PeerShareCodec.addressesEqual(
          _openConversationAddress ?? '',
          signal.sender,
        ) &&
        _isUiFocused();

    final bool callAlreadyHandled =
        state.activeCall != null &&
        _currentCallMatchesSignal(state.activeCall, signal) &&
        (state.activeCall!.status == CallSessionStatus.active ||
            state.activeCall!.status == CallSessionStatus.connecting ||
            !state.activeCall!.isIncoming);

    final bool popupAlreadyPresented =
        signal.callId != null &&
        signal.callId!.trim().isNotEmpty &&
        _wasCallPopupPresented(signal.callId);

    // The window can be on screen without the user looking at it (a desktop
    // window behind another app, a split-screen pane). Such a signal used to
    // be applied silently: no in-app banner (that needs focus) and no system
    // notification (that needed the app to be fully in the background), so
    // e.g. a group invite simply never announced itself.
    final bool notifiesWhileUnfocused =
        !_isUiFocused() && _isNotifiableWhileUnfocused(signal.type);
    // Ringing itself is the native/in-app popup. A shade notification is
    // only for a missed call after the ring stops.
    final bool shouldShowSystemNotification =
        (plan.showSystemNotification || notifiesWhileUnfocused) &&
        !_isIncomingRingingNotificationSignal(signal.type) &&
        !_isUiFocused() &&
        !isRepeatRingingSignal &&
        !callAlreadyHandled &&
        !popupAlreadyPresented &&
        !muteStrangerAlert &&
        !_isSilencedGroupSignal(signal) &&
        (!isCurrentChatOpen || isCallSignal);

    if (shouldShowSystemNotification) {
      final InboxEntry notifyEntry = _buildInboxEntry(
        signal: signal,
        receivedAtMillis: timestamp,
        friends: state.friends,
        groups: state.groups,
      );
      await _presentSystemNotification(
        _systemNotificationFromEntry(
          entry: notifyEntry,
          signal: signal,
          friends: state.friends,
          groups: state.groups,
          privacy: _noticePrivacyFor(signal),
        ),
      );
    }

    if (isCallSignal || missedCallHandled || repeatedTeardown) {
      await _syncRingingCallWindow();
    }
  }

  Future<void> dismissBackgroundAlert(String id) async {
    state = state.copyWith(
      backgroundAlerts: state.backgroundAlerts
          .where((InboxEntry entry) => entry.id != id)
          .toList(growable: false),
    );
    await _systemNotifications.dismiss(id);
    await _persistState();
  }

  Future<void> clearBackgroundAlerts() async {
    if (state.backgroundAlerts.isEmpty) {
      return;
    }
    for (final InboxEntry entry in state.backgroundAlerts) {
      await _systemNotifications.dismiss(entry.id);
    }
    state = state.copyWith(backgroundAlerts: const <InboxEntry>[]);
    await _persistState();
  }

  @override
  Future<void> dismissInboxEntry(String id) async {
    await _systemNotifications.dismiss(id);
    final List<InboxEntry> nextInbox = state.inbox
        .where((InboxEntry entry) => entry.id != id)
        .toList(growable: false);
    final List<InboxEntry> nextAlerts = state.backgroundAlerts
        .where((InboxEntry entry) => entry.id != id)
        .toList(growable: false);
    if (nextInbox.length == state.inbox.length &&
        nextAlerts.length == state.backgroundAlerts.length) {
      return;
    }
    state = state.copyWith(inbox: nextInbox, backgroundAlerts: nextAlerts);
    await _persistState();
  }

  Future<void> clearInbox() async {
    if (state.inbox.isEmpty && state.backgroundAlerts.isEmpty) {
      return;
    }
    for (final InboxEntry entry in state.backgroundAlerts) {
      await _systemNotifications.dismiss(entry.id);
    }
    state = state.copyWith(
      inbox: const <InboxEntry>[],
      backgroundAlerts: const <InboxEntry>[],
    );
    await _persistState();
  }

  @override
  Future<void> resetLocalState() async {
    final List<RealtimeAttachmentTransferSession> realtimeTransfers =
        _activeRealtimeTransfers.values.toList(growable: false);
    _activeRealtimeTransfers.clear();
    _activeOutgoingTransfers.clear();
    _openConversationAddress = null;
    _pendingIncomingCallOffer = null;
    _pendingIncomingCallAccept = false;
    await _closeCallMediaSession();
    for (final RealtimeAttachmentTransferSession session in realtimeTransfers) {
      await session.close();
    }
    await _queueStore.save(const <QueuedSignal>[]);
    await _notificationCenter.clear();
    await _systemNotifications.clear();
    state = SocialHubState.empty().copyWith(lifecycle: state.lifecycle);
    _bumpTimelineRevision();
    await _persistState();
  }

  Future<void> requestLaunchFromRouteKey(String? routeKey) async {
    RuntimeRouteIntent intent =
        runtimeRouteIntentFromRouteKey(
          id: _nextLaunchIntentId(),
          routeKey: routeKey,
        ) ??
        RuntimeRouteIntent.inbox(id: _nextLaunchIntentId());
    if (intent.target == RuntimeRouteTarget.call &&
        !intent.autoAcceptCall &&
        (intent.acceptToken?.isNotEmpty ?? false)) {
      // The native call card hands over the route the other isolate built:
      // its token is the ringing call's own, stored with the call. Anything
      // else - a web page, another app, a peer's deep link - only opens the
      // call, it never answers it.
      if (!_hydrationCompleted) {
        await _hydrationSettled.future;
        if (_controllerDisposed || !ref.mounted) {
          return;
        }
      }
      final CallSession? call = state.activeCall;
      final String? callToken = call?.acceptToken;
      if (call != null &&
          callToken != null &&
          callToken.isNotEmpty &&
          callToken == intent.acceptToken &&
          intent.answersCall(call.id) &&
          PeerShareCodec.addressesEqual(
            call.peerAddress,
            intent.peerAddress ?? '',
          )) {
        intent = intent.withAutoAcceptCall();
      }
    }
    final RuntimeRouteIntent? pending = state.pendingLaunchIntent;
    final CallSession? ringing = state.activeCall;
    if (pending != null &&
        pending.autoAcceptCall &&
        !intent.autoAcceptCall &&
        pending.target == RuntimeRouteTarget.call &&
        intent.target == RuntimeRouteTarget.call &&
        ringing != null &&
        ringing.isIncoming &&
        ringing.status == CallSessionStatus.ringing &&
        PeerShareCodec.addressesEqual(
          ringing.peerAddress,
          intent.peerAddress ?? '',
        ) &&
        PeerShareCodec.addressesEqual(
          pending.peerAddress ?? '',
          intent.peerAddress ?? '',
        )) {
      // Already about to answer this very call; a plain route to it (one of
      // several ways the app gets woken up for it) must not undo that.
      return;
    }
    await _setPendingLaunchIntent(intent);
  }

  Future<void> clearPendingLaunchIntent() async {
    if (state.pendingLaunchIntent == null) {
      return;
    }
    state = state.copyWith(pendingLaunchIntent: null);
    await _persistState();
  }

  Future<void> flushPendingSignals() {
    return _enqueueStateWork(_flushPendingSignals);
  }

  Future<void> _flushPendingSignals() async {
    if (!ref.mounted || !_isUiInteractive()) {
      return;
    }

    List<QueuedSignal> queue = await _queueStore.load();
    if (!ref.mounted) {
      return;
    }
    if (queue.isEmpty) {
      state = state.copyWith(pendingSignalCount: 0);
      await _persistState();
      return;
    }

    final LifecycleSnapshot routingLifecycle = _effectiveLifecycleForRouting();
    queue = List<QueuedSignal>.from(queue, growable: false)
      ..sort((QueuedSignal left, QueuedSignal right) {
        final int priorityDelta = _routing
            .planFor(signal: left.signal, lifecycle: routingLifecycle)
            .priority
            .index
            .compareTo(
              _routing
                  .planFor(signal: right.signal, lifecycle: routingLifecycle)
                  .priority
                  .index,
            );
        if (priorityDelta != 0) {
          return priorityDelta;
        }
        return left.receivedAtMillis.compareTo(right.receivedAtMillis);
      });

    SocialHubState next = state;
    for (final QueuedSignal queued in queue) {
      next = _applySignal(
        next,
        queued.signal,
        queued.receivedAtMillis,
        appSettings: _appSettings,
        openConversationAddress: _openConversationAddress,
        openGroupId: _openGroupId,
        dismissedOrRejectedGroupIds: _dismissedOrRejectedGroupIds,
      );
    }

    if (!ref.mounted) {
      return;
    }
    await _queueStore.save(const <QueuedSignal>[]);
    state = _withTrimmedInbox(
      next.copyWith(pendingSignalCount: 0),
      _appSettings,
    );
    _syncCallRingingTimeout();
    await _persistState();
  }

  /// Filters the call session coming back from disk.
  ///
  /// The snapshot outlives the process; a media session does not. A call that
  /// was still marked active when the app died has no peer connection behind
  /// it any more, so restoring it leaves a permanent "call in progress" chip
  /// on screen and — because [sendCallInvite] refuses to start a call while
  /// `activeCall` is set — blocks every new call, with no way out.
  ///
  /// A restored *ringing* call is kept while it is still fresh: that is the
  /// handoff back from the foreground service, which picks up incoming calls
  /// while the app is away. Past the ringing window it is a leftover from a
  /// call that ended with nothing running, and restoring it makes the app ring
  /// for a call nobody is placing.
  CallSession? _restorableCallSession(CallSession? session) {
    if (session == null) {
      return null;
    }
    if (session.status == CallSessionStatus.ringing) {
      final Duration window = ref.read(callRingingWaitTimeoutProvider);
      if (window <= Duration.zero) {
        return session;
      }
      final int ageMillis =
          DateTime.now().millisecondsSinceEpoch - session.startedAtMillis;
      return ageMillis > window.inMilliseconds ? null : session;
    }
    // An active call is only real while this isolate owns its media.
    return _callMedia.activeCallId == session.id ||
            _groupMedia.activeCallId == session.id
        ? session
        : null;
  }
}
