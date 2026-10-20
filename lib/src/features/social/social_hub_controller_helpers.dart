part of 'social_hub_controller.dart';

SocialHubState _applySignal(
  SocialHubState current,
  ZenSignal signal,
  int receivedAtMillis, {
  required AppSettings appSettings,
  required String? openConversationAddress,
  String? openGroupId,
  Set<String>? dismissedOrRejectedGroupIds,
}) {
  if (!_isSignalAllowedFromPeer(current, signal)) {
    return current;
  }
  final Map<String, FriendProfile> friends = Map<String, FriendProfile>.from(
    current.friends,
  );
  final InboxEntry inboxEntry = _buildInboxEntry(
    signal: signal,
    receivedAtMillis: receivedAtMillis,
    friends: current.friends,
  );

  switch (signal.type) {
    case ZenSignalType.friendRequest:
      final FriendProfile? requester = _friendFromMap(friends, signal.sender);
      if (requester != null &&
          requester.status == FriendRelationshipStatus.pendingOutgoing) {
        // Both asked each other at the same time: that is consent from both
        // sides, so the friendship is made here (and an accept goes back,
        // see receiveSignal) instead of two requests waiting on each other.
        final FriendProfile mutual = _friendReducer
            .applyAccepted(current: requester, displayName: signal.displayName)
            .copyWith(
              isOnline: true,
              lastPresenceAtMillis: receivedAtMillis,
              lastMessagePreview: t('Połączenie gotowe. Możesz pisać od razu.'),
              lastActivityLabel: t('Teraz'),
            );
        _putFriend(friends, _withAppRetentionDefaults(mutual, appSettings));
        return current.copyWith(friends: friends);
      }
      List<InboxEntry> requestInbox = current.inbox;
      if (requester == null) {
        // A new invitation: strangers can send any number of them, so the
        // oldest unanswered ones make room (accepted friends never do).
        for (final String evicted in _evictOldestPendingIncoming(
          friends,
          keep: kMaxPendingIncomingFriendRequests - 1,
        )) {
          requestInbox = _removeEntriesForPeer(
            requestInbox,
            evicted,
            types: const <InboxEntryType>{InboxEntryType.friendRequest},
          );
        }
      }
      final FriendProfile updated = _friendReducer.applyIncomingRequest(
        address: signal.sender,
        displayName: signal.displayName ?? '',
        requestMessage: signal.content,
        current: requester,
      );
      final FriendProfile resolved = _withAppRetentionDefaults(
        updated,
        appSettings,
      );
      _putFriend(friends, resolved);
      return current.copyWith(
        friends: friends,
        inbox: _prependSocialLifecycleInbox(requestInbox, inboxEntry),
      );
    case ZenSignalType.friendAccept:
      final FriendProfile? acceptedBase = _friendFromMap(
        friends,
        signal.sender,
      );
      if (acceptedBase?.status == FriendRelationshipStatus.pendingIncoming ||
          acceptedBase?.status == FriendRelationshipStatus.blocked) {
        // Their request already waits for the user's answer; an accept on
        // top of it changes nothing.
        return current;
      }
      if (acceptedBase == null ||
          !FriendLifecycleReducer.isSolicitedRemoteAccept(acceptedBase)) {
        // Nobody here invited them: an accept cannot make a stranger a
        // friend. It is handled as the invitation it really is, which the
        // user still has to confirm.
        return _applySignal(
          current,
          _unsolicitedAcceptAsRequest(signal),
          receivedAtMillis,
          appSettings: appSettings,
          openConversationAddress: openConversationAddress,
          openGroupId: openGroupId,
          dismissedOrRejectedGroupIds: dismissedOrRejectedGroupIds,
        );
      }
      final FriendProfile updated = _friendReducer
          .applyAccepted(current: acceptedBase, displayName: signal.displayName)
          .copyWith(
            isOnline: true,
            lastPresenceAtMillis: receivedAtMillis,
            lastMessagePreview: t('Połączenie gotowe. Możesz pisać od razu.'),
            lastActivityLabel: t('Teraz'),
          );
      final FriendProfile resolved = _withAppRetentionDefaults(
        updated,
        appSettings,
      );
      _putFriend(friends, resolved);
      return current.copyWith(friends: friends);
    case ZenSignalType.friendReject:
      final FriendProfile? rejected = _friendFromMap(friends, signal.sender);
      if (rejected?.status == FriendRelationshipStatus.pendingOutgoing) {
        _removeFriend(friends, signal.sender);
      }
      return current.copyWith(
        friends: friends,
        inbox: _prependSocialLifecycleInbox(current.inbox, inboxEntry),
      );
    case ZenSignalType.friendCancel:
      final FriendProfile? cancelled = _friendFromMap(friends, signal.sender);
      if (cancelled?.status == FriendRelationshipStatus.pendingIncoming) {
        _removeFriend(friends, signal.sender);
      }
      return current.copyWith(
        friends: friends,
        inbox: _prependSocialLifecycleInbox(current.inbox, inboxEntry),
      );
    case ZenSignalType.friendRemove:
      _removeFriend(friends, signal.sender);
      return current.copyWith(
        friends: friends,
        activeCall:
            _currentCallMatches(
              call: current.activeCall,
              peerAddress: signal.sender,
            )
            ? null
            : current.activeCall,
        inbox: _prependSocialLifecycleInbox(current.inbox, inboxEntry),
      );
    case ZenSignalType.typing:
      final FriendProfile? typingFriend = _friendFromMap(
        friends,
        signal.sender,
      );
      if (typingFriend != null) {
        _putFriend(
          friends,
          typingFriend.copyWith(
            isOnline: true,
            lastPresenceAtMillis: receivedAtMillis,
            isTyping: signal.isTyping,
          ),
        );
      }
      return current.copyWith(friends: friends);
    case ZenSignalType.message:
      final bool isConversationOpen =
          PeerShareCodec.addressesEqual(
            signal.sender,
            openConversationAddress ?? '',
          ) &&
          current.lifecycle.isInteractive;
      final FriendProfile? currentFriend = _friendFromMap(
        friends,
        signal.sender,
      );
      if (currentFriend != null) {
        _putFriend(
          friends,
          currentFriend.copyWith(
            isOnline: true,
            isTyping: false,
            lastPresenceAtMillis: receivedAtMillis,
            lastMessagePreview: _clipText(
              signal.content ?? t('Nowa wiadomość'),
              kMaxStoredPreviewChars,
            ),
            lastActivityLabel: t('Teraz'),
            unreadCount: isConversationOpen ? 0 : currentFriend.unreadCount + 1,
          ),
        );
      }
      return current.copyWith(
        friends: friends,
        inbox: isConversationOpen
            ? current.inbox
            : _prependInbox(current.inbox, inboxEntry),
      );
    case ZenSignalType.groupInvite:
      final String groupId = signal.groupId ?? 'grp-${signal.sender}';
      if ((dismissedOrRejectedGroupIds != null &&
              dismissedOrRejectedGroupIds.contains(groupId)) ||
          current.rejectedGroupIds.contains(groupId)) {
        return current;
      }
      final GroupProfile? existingGroup = current.groups[groupId];
      if (existingGroup != null) {
        // Already a member of this group: merge what the sender may add (see
        // `_groupMembersAfterInvite`), never re-add the invite to the inbox.
        // Anyone outside the group who learned the id adds nothing.
        final List<String>? updatedMembers = _groupMembersAfterInvite(
          existingGroup,
          signal,
        );
        if (updatedMembers == null ||
            updatedMembers.length == existingGroup.memberAddresses.length) {
          return current;
        }
        final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
          current.groups,
        );
        groups[groupId] = existingGroup.copyWith(
          memberAddresses: updatedMembers,
        );
        return current.copyWith(groups: groups);
      }
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
        current.groups,
      );
      // Anyone may invite, so unanswered invitations are capped: the oldest
      // ones make room. Joined groups are never touched.
      final List<String> evictedInvites = _evictOldestPendingGroupInvites(
        groups,
        keep: kMaxPendingGroupInvites - 1,
      );
      final List<InboxEntry> inviteInbox = evictedInvites.isEmpty
          ? current.inbox
          : current.inbox
                .where(
                  (InboxEntry entry) =>
                      entry.type != InboxEntryType.groupInvite ||
                      !evictedInvites.contains(
                        _groupIdOfRouteKey(entry.routeKey),
                      ),
                )
                .toList(growable: false);
      final List<String> inviteMembers = cappedGroupMembers(
        normalizedGroupMembers(<String>[
          signal.sender,
          ...?signal.memberAddresses,
        ]),
      );
      groups[groupId] = GroupProfile(
        id: groupId,
        name: signal.groupName?.trim().isNotEmpty == true
            ? signal.groupName!.trim()
            : switch (friends[signal.sender]?.displayLabel) {
                final String name => t('Grupa od {name}', {'name': name}),
                null => t('Grupa od znajomego'),
              },
        description: signal.content ?? '',
        createdById: signal.sender,
        createdAtMillis: receivedAtMillis,
        memberAddresses: inviteMembers,
        lastActivityLabel: t('Teraz'),
        lastMessagePreview: t('Zaproszono Cię do grupy.'),
        isInvitePending: true,
        receivedInviteIds: <String>[?signal.inviteId],
        memberNames: <String, String>{
          if (signal.displayName?.trim().isNotEmpty ?? false)
            signal.sender: signal.displayName!.trim(),
        },
      );
      final bool alreadyHasInvite = inviteInbox.any(
        (InboxEntry entry) =>
            entry.type == InboxEntryType.groupInvite &&
            ((entry.routeKey?.contains(groupId) ?? false) ||
                (signal.groupName != null &&
                    signal.groupName!.trim().isNotEmpty &&
                    entry.title.contains(signal.groupName!.trim()))),
      );
      if (alreadyHasInvite) {
        return current.copyWith(groups: groups, inbox: inviteInbox);
      }
      return current.copyWith(
        groups: groups,
        inbox: _prependInbox(inviteInbox, inboxEntry),
      );
    case ZenSignalType.groupMessage:
      final String groupId = signal.groupId ?? '';
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
        current.groups,
      );
      final GroupProfile? existing = groups[groupId];
      if (existing != null) {
        final bool isGroupOpen =
            openGroupId == groupId && current.lifecycle.isInteractive;
        final String? senderName = signal.displayName?.trim();
        groups[groupId] = existing.copyWith(
          lastMessagePreview: _clipText(
            signal.content ?? t('Nowa wiadomość grupowa'),
            kMaxStoredPreviewChars,
          ),
          lastActivityLabel: t('Teraz'),
          unreadCount: isGroupOpen ? 0 : existing.unreadCount + 1,
          memberNames: senderName == null || senderName.isEmpty
              ? null
              : <String, String>{
                  ...existing.memberNames,
                  signal.sender: senderName,
                },
        );
      }
      return current.copyWith(groups: groups);
    case ZenSignalType.groupLeave:
      final String groupId = signal.groupId ?? '';
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
        current.groups,
      );
      final GroupProfile? existing = groups[groupId];
      if (existing != null) {
        final List<String> updated = existing.memberAddresses
            .where(
              (String m) => !PeerShareCodec.addressesEqual(m, signal.sender),
            )
            .toList();
        final List<String> pending = existing.pendingInviteAddresses
            .where(
              (String m) => !PeerShareCodec.addressesEqual(m, signal.sender),
            )
            .toList();
        groups[groupId] = existing.copyWith(
          memberAddresses: updated,
          pendingInviteAddresses: pending,
          pendingInviteIds: <String, String>{
            for (final MapEntry<String, String> e
                in existing.pendingInviteIds.entries)
              if (!PeerShareCodec.addressesEqual(e.key, signal.sender))
                e.key: e.value,
          },
        );
      }
      return current.copyWith(groups: groups);
    case ZenSignalType.groupInviteAck:
      final GroupProfile? acked = current.groups[signal.groupId ?? ''];
      if (acked == null ||
          !acked.pendingInviteAddresses.any(
            (String m) => PeerShareCodec.addressesEqual(m, signal.sender),
          )) {
        return current;
      }
      final Map<String, GroupProfile> ackedGroups =
          Map<String, GroupProfile>.from(current.groups);
      ackedGroups[acked.id] = acked.copyWith(
        pendingInviteAddresses: acked.pendingInviteAddresses
            .where(
              (String m) => !PeerShareCodec.addressesEqual(m, signal.sender),
            )
            .toList(growable: false),
        pendingInviteIds: <String, String>{
          for (final MapEntry<String, String> e
              in acked.pendingInviteIds.entries)
            if (!PeerShareCodec.addressesEqual(e.key, signal.sender))
              e.key: e.value,
        },
      );
      return current.copyWith(groups: ackedGroups);
    case ZenSignalType.groupCallInvite:
    case ZenSignalType.groupCallJoin:
    case ZenSignalType.groupCallLeave:
    case ZenSignalType.groupCallState:
    case ZenSignalType.groupCallOffer:
    case ZenSignalType.groupCallAnswer:
    case ZenSignalType.groupCallDecline:
    case ZenSignalType.profileUpdate:
    case ZenSignalType.disappearTimer:
      // Group calls have their own coordinator (see the group call part).
      return current;
    case ZenSignalType.groupUpdate:
      return current;
    case ZenSignalType.messageRead:
      return current;
    case ZenSignalType.transferCancel:
      return current.copyWith(inbox: _prependInbox(current.inbox, inboxEntry));
    case ZenSignalType.transferOffer:
    case ZenSignalType.transferAnswer:
      return current;
    case ZenSignalType.callOffer:
      if (_shouldKeepCurrentCallOnIncomingSignal(current.activeCall, signal)) {
        return current;
      }
      if (_currentCallMatchesSignal(current.activeCall, signal) &&
          current.activeCall != null) {
        return current.copyWith(
          activeCall: current.activeCall!.copyWith(
            kind: _callKind(signal.content),
          ),
        );
      }
      return current.copyWith(
        activeCall: CallSession(
          id: signal.callId?.trim().isNotEmpty == true
              ? signal.callId!.trim()
              : 'call-$receivedAtMillis-${signal.sender}',
          peerAddress: signal.sender,
          displayName:
              friends[signal.sender]?.displayLabel ?? _labelFor(signal),
          kind: _callKind(signal.content),
          status: CallSessionStatus.ringing,
          startedAtMillis: receivedAtMillis,
          isIncoming: true,
          isSpeakerOn: _callKind(signal.content) == CallInviteKind.video,
          isCameraEnabled: false,
        ),
      );
    case ZenSignalType.callInvite:
      if (_shouldKeepCurrentCallOnIncomingSignal(current.activeCall, signal)) {
        return current;
      }
      if (_isKnownCallSignal(current.activeCall, signal)) {
        final CallSession known = current.activeCall!;
        if (!known.isIncoming || known.status != CallSessionStatus.ringing) {
          // The caller keeps re-sending its invite until it sees the answer.
          // Rewriting an answered - or already connected - session back into a
          // ringing incoming one drops the user into the accept/decline
          // overlay in the middle of their own call.
          return current;
        }
        return current.copyWith(
          activeCall: known.copyWith(
            kind: _callKind(signal.content),
            status: CallSessionStatus.ringing,
            isSpeakerOn: _callKind(signal.content) == CallInviteKind.video,
          ),
        );
      }
      return current.copyWith(
        inbox: _prependInbox(current.inbox, inboxEntry),
        activeCall:
            current.activeCall == null ||
                current.activeCall!.peerAddress == signal.sender
            ? CallSession(
                id: signal.callId?.trim().isNotEmpty == true
                    ? signal.callId!.trim()
                    : 'call-$receivedAtMillis-${signal.sender}',
                peerAddress: signal.sender,
                displayName:
                    friends[signal.sender]?.displayLabel ?? _labelFor(signal),
                kind: _callKind(signal.content),
                status: CallSessionStatus.ringing,
                startedAtMillis: receivedAtMillis,
                isIncoming: true,
                isSpeakerOn: _callKind(signal.content) == CallInviteKind.video,
                isCameraEnabled: false,
              )
            : current.activeCall,
      );
    case ZenSignalType.callAnswer:
      if (!_currentCallMatchesSignal(current.activeCall, signal)) {
        return current;
      }
      return current.copyWith(
        activeCall: current.activeCall!.copyWith(
          kind: _callKind(signal.content),
          isIncoming: false,
        ),
      );
    case ZenSignalType.callRinging:
      if (!_currentCallMatchesSignal(current.activeCall, signal) ||
          current.activeCall == null ||
          current.activeCall!.isIncoming) {
        return current;
      }
      return current.copyWith(
        activeCall: current.activeCall!.copyWith(
          status: CallSessionStatus.ringing,
        ),
      );
    case ZenSignalType.callOfferRequest:
      return current;
    case ZenSignalType.callAccept:
      if (!_currentCallMatchesSignal(current.activeCall, signal)) {
        return current;
      }
      return current.copyWith(
        activeCall: current.activeCall!.copyWith(
          status: CallSessionStatus.active,
          isIncoming: false,
          kind: _callKind(signal.content),
        ),
      );
    case ZenSignalType.callBusy:
    case ZenSignalType.callDecline:
    case ZenSignalType.callEnd:
      // Matched on the callId as well: teardown signals are re-sent, and a
      // late repeat for a finished call must not take down the next call with
      // the same peer.
      return _isKnownCallSignal(current.activeCall, signal)
          ? current.copyWith(activeCall: null)
          : current;
    case ZenSignalType.messageChunk:
    case ZenSignalType.messageChunkAck:
      return current;
    case ZenSignalType.ack:
    case ZenSignalType.presence:
    case ZenSignalType.unknown:
      return current;
    case ZenSignalType.deepLink:
      final RuntimeRouteIntent? launchIntent = _runtimeIntentForSignal(
        signal,
        receivedAtMillis,
      );
      if (launchIntent == null) {
        return current;
      }
      return current.copyWith(pendingLaunchIntent: launchIntent);
  }
}

FriendProfile _withAppRetentionDefaults(
  FriendProfile profile,
  AppSettings settings,
) {
  final int inboxLimitMb =
      profile.inboxLimitMb > 0 || settings.inboxLimitMb <= 0
      ? profile.inboxLimitMb
      : settings.inboxLimitMb;
  final int autoCleanupDays =
      profile.autoCleanupDays > 0 || settings.autoCleanupDays <= 0
      ? profile.autoCleanupDays
      : settings.autoCleanupDays;
  if (inboxLimitMb == profile.inboxLimitMb &&
      autoCleanupDays == profile.autoCleanupDays) {
    return profile;
  }
  return profile.copyWith(
    inboxLimitMb: inboxLimitMb,
    autoCleanupDays: autoCleanupDays,
  );
}

SocialHubState _withTrimmedInbox(SocialHubState state, AppSettings settings) {
  final Set<String> keptInboxIds = _trimmedInboxEntryIds(
    entries: state.inbox,
    friends: state.friends,
    settings: settings,
  );
  if (keptInboxIds.length == state.inbox.length) {
    return state;
  }
  return state.copyWith(
    inbox: state.inbox
        .where((InboxEntry entry) => keptInboxIds.contains(entry.id))
        .toList(growable: false),
  );
}

Set<String> _trimmedInboxEntryIds({
  required List<InboxEntry> entries,
  required Map<String, FriendProfile> friends,
  required AppSettings settings,
}) {
  final Map<String, List<InboxEntry>> grouped = <String, List<InboxEntry>>{};
  final Set<String> keptIds = <String>{};

  for (final InboxEntry entry in entries) {
    final String peerAddress = entry.peerAddress?.trim() ?? '';
    if (peerAddress.isEmpty) {
      keptIds.add(entry.id);
      continue;
    }
    grouped.putIfAbsent(peerAddress, () => <InboxEntry>[]).add(entry);
  }

  for (final MapEntry<String, List<InboxEntry>> group in grouped.entries) {
    final int limitMb = _effectiveInboxLimitMbForPeer(
      peerAddress: group.key,
      friends: friends,
      settings: settings,
    );
    if (limitMb <= 0) {
      keptIds.addAll(group.value.map((InboxEntry entry) => entry.id));
      continue;
    }
    final int targetBytes = ((limitMb * 1024 * 1024) * 0.95).floor();
    int usedBytes = 0;
    final List<InboxEntry> sorted = group.value.toList(growable: false)
      ..sort(
        (InboxEntry left, InboxEntry right) =>
            right.createdAtMillis.compareTo(left.createdAtMillis),
      );
    for (final InboxEntry entry in sorted) {
      final int entryBytes = _estimateInboxEntryBytes(entry);
      if (usedBytes + entryBytes > targetBytes && usedBytes > 0) {
        continue;
      }
      keptIds.add(entry.id);
      usedBytes += entryBytes;
    }
  }

  return keptIds;
}

int _effectiveInboxLimitMbForPeer({
  required String peerAddress,
  required Map<String, FriendProfile> friends,
  required AppSettings settings,
}) {
  final FriendProfile? friend = friends[peerAddress];
  if (friend == null || friend.inboxLimitMb <= 0) {
    return settings.inboxLimitMb;
  }
  return friend.inboxLimitMb;
}

int _estimateInboxEntryBytes(InboxEntry entry) {
  return utf8
      .encode(
        '${entry.id}\n${entry.title}\n${entry.body}\n${entry.routeKey ?? ''}\n${entry.peerAddress ?? ''}\n',
      )
      .length;
}

InboxEntry _buildInboxEntry({
  required ZenSignal signal,
  required int receivedAtMillis,
  Map<String, FriendProfile>? friends,
}) {
  final String label = _resolvedPeerLabel(
    address: signal.sender,
    displayName: signal.displayName,
    knownName: friends?[signal.sender]?.displayLabel,
  );
  return switch (signal.type) {
    ZenSignalType.friendRequest => InboxEntry.fromEvents(
      id: 'friend-request-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.friendRequest,
      title: SocialEventText('inbox.friendRequest', <String, String>{
        'name': label,
      }),
      body: const SocialEventText('inbox.friendRequest.body'),
      bodyText: signal.content,
      createdAtMillis: receivedAtMillis,
      routeKey: buildInboxRouteKey(),
      peerAddress: signal.sender,
    ),
    ZenSignalType.friendAccept => InboxEntry.fromEvents(
      id: 'friend-accept-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.friendAccepted,
      title: SocialEventText('inbox.friendAccepted', <String, String>{
        'name': label,
      }),
      body: const SocialEventText('inbox.friendAccepted.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.friendReject => InboxEntry.fromEvents(
      id: 'friend-reject-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.friendRejected,
      title: SocialEventText('inbox.friendRejected', <String, String>{
        'name': label,
      }),
      body: const SocialEventText('inbox.friendRejected.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildInboxRouteKey(),
      peerAddress: signal.sender,
    ),
    ZenSignalType.friendCancel => InboxEntry.fromEvents(
      id: 'friend-cancel-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.friendCancelled,
      title: SocialEventText('inbox.friendCancelled', <String, String>{
        'name': label,
      }),
      body: const SocialEventText('inbox.friendCancelled.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildInboxRouteKey(),
      peerAddress: signal.sender,
    ),
    ZenSignalType.friendRemove => InboxEntry.fromEvents(
      id: 'friend-remove-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.friendRemoved,
      title: SocialEventText('inbox.friendRemoved', <String, String>{
        'name': label,
      }),
      body: const SocialEventText('inbox.friendRemoved.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildInboxRouteKey(),
      peerAddress: signal.sender,
    ),
    ZenSignalType.transferCancel => InboxEntry.fromEvents(
      id: 'transfer-cancel-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.transferCancelled,
      title: const SocialEventText('inbox.transferCancelled'),
      body: const SocialEventText('inbox.transferCancelled.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildInboxRouteKey(),
      peerAddress: signal.sender,
    ),
    ZenSignalType.message => InboxEntry.fromEvents(
      id: 'message-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.message', <String, String>{'name': label}),
      body: const SocialEventText('inbox.message.body'),
      bodyText: signal.content,
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callInvite => InboxEntry.fromEvents(
      id: 'call-invite-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.callInvite,
      title: SocialEventText('inbox.callFrom', <String, String>{'name': label}),
      body: SocialEventText('inbox.callFrom.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildCallRouteKey(peerAddress: signal.sender, title: label),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callOffer => InboxEntry.fromEvents(
      id: 'call-offer-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.callInvite,
      title: SocialEventText('inbox.callFrom', <String, String>{'name': label}),
      body: SocialEventText('inbox.callFrom.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildCallRouteKey(peerAddress: signal.sender, title: label),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callAnswer => InboxEntry.fromEvents(
      id: 'call-answer-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.callAnswered', <String, String>{
        'name': label,
      }),
      body: SocialEventText('inbox.callAnswered.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callAccept => InboxEntry.fromEvents(
      id: 'call-accept-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.callAnswered', <String, String>{
        'name': label,
      }),
      body: SocialEventText('inbox.callAnswered.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callDecline => InboxEntry.fromEvents(
      id: 'call-decline-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.callDeclined', <String, String>{
        'name': label,
      }),
      body: SocialEventText('inbox.callDeclined.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callBusy => InboxEntry.fromEvents(
      id: 'call-busy-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.callBusy', <String, String>{'name': label}),
      body: SocialEventText('inbox.callBusy.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.callEnd => InboxEntry.fromEvents(
      id: 'call-end-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.callEnded', <String, String>{
        'name': label,
      }),
      body: SocialEventText('inbox.callEnded.body', <String, String>{
        'kind': _callKind(signal.content).name,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.groupInvite => InboxEntry.fromEvents(
      id: 'group-invite-${signal.groupId ?? signal.sender}',
      type: InboxEntryType.groupInvite,
      title: SocialEventText('inbox.groupInvite', <String, String>{
        'group': signal.groupName ?? '',
      }),
      body: SocialEventText('inbox.groupInvite.body', <String, String>{
        'name': label,
      }),
      createdAtMillis: receivedAtMillis,
      routeKey: buildGroupRouteKey(
        groupId: signal.groupId ?? 'grp-${signal.sender}',
        title: signal.groupName,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.groupMessage => InboxEntry.fromEvents(
      id: 'group-message-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.groupMessage', <String, String>{
        'group': signal.groupName ?? '',
        'name': label,
      }),
      body: const SocialEventText('inbox.groupMessage.body'),
      bodyText: signal.content,
      createdAtMillis: receivedAtMillis,
      routeKey: buildGroupRouteKey(
        groupId: signal.groupId ?? 'grp-${signal.sender}',
        title: signal.groupName,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.groupCallInvite => InboxEntry.fromEvents(
      id: 'group-call-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.callInvite,
      title: SocialEventText('inbox.groupCall', <String, String>{
        'group': signal.groupName ?? '',
      }),
      body: const SocialEventText('inbox.groupCall.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildGroupRouteKey(
        groupId: signal.groupId ?? 'grp-${signal.sender}',
        title: signal.groupName,
      ),
      peerAddress: signal.sender,
    ),
    ZenSignalType.groupUpdate ||
    ZenSignalType.groupLeave ||
    ZenSignalType.groupInviteAck ||
    ZenSignalType.groupCallJoin ||
    ZenSignalType.groupCallLeave ||
    ZenSignalType.groupCallState ||
    ZenSignalType.groupCallOffer ||
    ZenSignalType.groupCallAnswer ||
    ZenSignalType.groupCallDecline ||
    ZenSignalType.profileUpdate ||
    ZenSignalType.disappearTimer ||
    ZenSignalType.callRinging ||
    ZenSignalType.callOfferRequest ||
    ZenSignalType.transferOffer ||
    ZenSignalType.transferAnswer ||
    ZenSignalType.ack ||
    ZenSignalType.messageRead ||
    ZenSignalType.messageChunk ||
    ZenSignalType.messageChunkAck ||
    ZenSignalType.deepLink ||
    ZenSignalType.presence ||
    ZenSignalType.typing ||
    ZenSignalType.unknown => InboxEntry.fromEvents(
      id: 'background-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: const SocialEventText('inbox.event'),
      body: SocialEventText('inbox.event.body', <String, String>{
        'name': label,
      }),
      bodyText: signal.content,
      createdAtMillis: receivedAtMillis,
      routeKey: null,
      peerAddress: signal.sender,
    ),
  };
}

// Keep only the newest lifecycle event per peer so an accepted invite replaces
// older "pending" rows instead of leaving stale request entries behind.
List<InboxEntry> _prependSocialLifecycleInbox(
  List<InboxEntry> source,
  InboxEntry entry,
) {
  final String peerAddress = entry.peerAddress?.trim() ?? '';
  if (peerAddress.isEmpty) {
    return _prependInbox(source, entry);
  }
  final List<InboxEntry> filtered = source
      .where(
        (InboxEntry existing) =>
            (existing.peerAddress?.trim() ?? '') != peerAddress ||
            !_isSocialLifecycleInboxType(existing.type),
      )
      .toList(growable: false);
  return _prependInbox(filtered, entry);
}

bool _isSocialLifecycleInboxType(InboxEntryType type) => switch (type) {
  InboxEntryType.friendRequest ||
  InboxEntryType.friendAccepted ||
  InboxEntryType.friendRejected ||
  InboxEntryType.friendCancelled ||
  InboxEntryType.friendRemoved => true,
  _ => false,
};

bool _isSocialLifecycleSignalType(ZenSignalType type) => switch (type) {
  ZenSignalType.friendRequest ||
  ZenSignalType.friendAccept ||
  ZenSignalType.friendReject ||
  ZenSignalType.friendCancel ||
  ZenSignalType.friendRemove ||
  ZenSignalType.groupInvite ||
  ZenSignalType.groupUpdate ||
  ZenSignalType.groupLeave ||
  ZenSignalType.groupInviteAck => true,
  _ => false,
};

/// Call signals that must reach the persisted state even while the UI is
/// away: the invite creates the ringing session the notification buttons act
/// on, and the teardown signals clear it so a cancelled call does not linger
/// until the ringing deadline.
bool _isIncomingRingingNotificationSignal(ZenSignalType type) => switch (type) {
  ZenSignalType.callInvite ||
  ZenSignalType.callOffer ||
  ZenSignalType.callRinging ||
  ZenSignalType.groupCallInvite => true,
  _ => false,
};

bool _isCallSessionSignalType(ZenSignalType type) => switch (type) {
  ZenSignalType.callInvite ||
  ZenSignalType.callBusy ||
  ZenSignalType.callDecline ||
  ZenSignalType.callEnd ||
  ZenSignalType.groupCallInvite => true,
  _ => false,
};

/// True when [signal] is about the very call [call] already holds.
///
/// The caller re-sends its invite once per second until the callee answers, so
/// every repeat has to be recognised as "the call already on file" — including
/// after the answer, where the session is no longer incoming.
bool _isKnownCallSignal(CallSession? call, ZenSignal signal) {
  return call != null && _currentCallMatchesSignal(call, signal);
}

/// True when [signal] belongs to an incoming call that is still ringing — the
/// state a missed-call follow-up is built from.
bool _isRingingIncomingCallMatch(CallSession? call, ZenSignal signal) {
  return call != null &&
      call.isIncoming &&
      call.status == CallSessionStatus.ringing &&
      _currentCallMatchesSignal(call, signal);
}

/// Re-ringed invites share the callId, so a repeat already sitting in the
/// queue is dropped instead of growing it once per re-ring turn.
bool _isDuplicateQueuedCallInvite(List<QueuedSignal> queue, ZenSignal signal) {
  if (signal.type != ZenSignalType.callInvite) {
    return false;
  }
  return queue.any(
    (QueuedSignal entry) =>
        entry.signal.type == ZenSignalType.callInvite &&
        entry.signal.callId == signal.callId &&
        PeerShareCodec.addressesEqual(entry.signal.sender, signal.sender),
  );
}

List<InboxEntry> _prependInbox(List<InboxEntry> source, InboxEntry entry) {
  final List<InboxEntry> merged = <InboxEntry>[entry, ...source];
  if (merged.length <= 24) {
    return merged;
  }
  return merged.sublist(0, 24);
}

RuntimeNotification? _foregroundNotificationForSignal({
  required ZenSignal signal,
  required int receivedAtMillis,
  Map<String, FriendProfile>? friends,
}) {
  if (!_isUserFacingSignal(signal.type)) {
    // Receipts, typing, presence and membership bookkeeping would only
    // surface as a meaningless "Nowe zdarzenie" banner.
    return null;
  }
  if (signal.type == ZenSignalType.friendAccept ||
      signal.type == ZenSignalType.callInvite ||
      signal.type == ZenSignalType.callOffer ||
      signal.type == ZenSignalType.callRinging ||
      signal.type == ZenSignalType.callAnswer ||
      signal.type == ZenSignalType.callAccept ||
      signal.type == ZenSignalType.callDecline ||
      signal.type == ZenSignalType.callBusy ||
      signal.type == ZenSignalType.callEnd) {
    return null;
  }
  final InboxEntry entry = _buildInboxEntry(
    signal: signal,
    receivedAtMillis: receivedAtMillis,
    friends: friends,
  );
  return RuntimeNotification(
    id: entry.id,
    title: entry.title,
    body: entry.body,
    createdAtMillis: entry.createdAtMillis,
    routeKey: entry.routeKey,
    dedupKey: _notificationDedupKeyForSignal(signal),
  );
}

RuntimeSystemNotification _systemNotificationFromEntry({
  required InboxEntry entry,
  required ZenSignal signal,
  Map<String, FriendProfile>? friends,
  bool hideContent = false,
}) {
  final String senderLabel = _resolvedPeerLabel(
    address: signal.sender,
    displayName: signal.displayName,
    knownName: friends?[signal.sender]?.displayLabel,
  );
  final String title;
  final String body;

  switch (signal.type) {
    case ZenSignalType.message:
      title = senderLabel;
      body =
          !hideContent &&
              signal.content != null &&
              signal.content!.trim().isNotEmpty
          ? signal.content!.trim()
          : t('Nowa wiadomość');
    case ZenSignalType.groupMessage:
      title = (signal.groupName != null && signal.groupName!.trim().isNotEmpty)
          ? signal.groupName!.trim()
          : t('Wiadomość grupowa');
      body =
          !hideContent &&
              signal.content != null &&
              signal.content!.trim().isNotEmpty
          ? '$senderLabel: ${signal.content!.trim()}'
          : t('{name} wysłał(a) wiadomość', {'name': senderLabel});
    case ZenSignalType.callInvite:
    case ZenSignalType.callOffer:
      title = senderLabel;
      final String kind = _callKindLabel(signal.content);
      body = t('Przychodzące połączenie {kind}...', {'kind': kind});
    case ZenSignalType.groupCallInvite:
      title = (signal.groupName != null && signal.groupName!.trim().isNotEmpty)
          ? signal.groupName!.trim()
          : t('Połączenie grupowe');
      body = t('Trwa połączenie grupowe.');
    default:
      title = entry.title;
      body = entry.body;
  }

  return RuntimeSystemNotification(
    id: entry.id,
    title: title,
    body: body,
    createdAtMillis: entry.createdAtMillis,
    routeKey: entry.routeKey,
    slotKey: _notificationDedupKeyForSignal(signal),
    suppressionKey: switch (signal.type) {
      ZenSignalType.message ||
      ZenSignalType.groupMessage => _messageNotificationSuppressionKey(signal),
      // The same key the call notification slot uses, so tearing the slot down
      // also forgets the window - otherwise the next call from that peer
      // inside the window would be swallowed silently.
      ZenSignalType.callOffer ||
      ZenSignalType.callRinging => callNotificationSlotKey(signal.sender),
      _ => null,
    },
    isRingingCall:
        signal.type == ZenSignalType.callInvite ||
        signal.type == ZenSignalType.callOffer ||
        signal.type == ZenSignalType.groupCallInvite,
    // Messages already got their content-free form above (keeping who
    // wrote); everything else is left to the central redaction.
    contentRedacted:
        hideContent &&
        (signal.type == ZenSignalType.message ||
            signal.type == ZenSignalType.groupMessage),
    category: switch (signal.type) {
      ZenSignalType.friendRequest ||
      ZenSignalType.friendAccept ||
      ZenSignalType.friendReject ||
      ZenSignalType.friendCancel ||
      ZenSignalType.friendRemove ||
      ZenSignalType.groupInvite ||
      ZenSignalType.groupUpdate ||
      ZenSignalType.groupLeave ||
      ZenSignalType.groupInviteAck => RuntimeSystemNotificationCategory.social,
      ZenSignalType.message ||
      ZenSignalType.groupMessage => RuntimeSystemNotificationCategory.message,
      ZenSignalType.callInvite ||
      ZenSignalType.callAnswer ||
      ZenSignalType.callAccept ||
      ZenSignalType.callBusy ||
      ZenSignalType.callDecline ||
      ZenSignalType.callEnd ||
      ZenSignalType.callOffer ||
      ZenSignalType.callRinging ||
      ZenSignalType.callOfferRequest ||
      ZenSignalType.groupCallJoin ||
      ZenSignalType.groupCallLeave ||
      ZenSignalType.groupCallState ||
      ZenSignalType.groupCallOffer ||
      ZenSignalType.groupCallAnswer ||
      ZenSignalType.groupCallDecline ||
      ZenSignalType.profileUpdate ||
      ZenSignalType.disappearTimer ||
      ZenSignalType.groupCallInvite => RuntimeSystemNotificationCategory.call,
      ZenSignalType.transferCancel =>
        RuntimeSystemNotificationCategory.transfer,
      ZenSignalType.transferOffer ||
      ZenSignalType.transferAnswer ||
      ZenSignalType.ack ||
      ZenSignalType.messageRead ||
      ZenSignalType.messageChunk ||
      ZenSignalType.messageChunkAck ||
      ZenSignalType.deepLink ||
      ZenSignalType.presence ||
      ZenSignalType.typing ||
      ZenSignalType.unknown => RuntimeSystemNotificationCategory.social,
    },
  );
}

String? _messageNotificationSuppressionKey(ZenSignal signal) {
  final String sender = signal.sender.trim();
  if (sender.isEmpty) {
    return null;
  }
  final String? messageId = signal.messageId?.trim();
  if (signal.type == ZenSignalType.groupMessage) {
    final String group = signal.groupId ?? sender;
    return messageId != null && messageId.isNotEmpty
        ? 'group:$group:$messageId'
        : null;
  }
  return messageId != null && messageId.isNotEmpty
      ? 'message:$sender:$messageId'
      : null;
}

/// Missed-call follow-up for an incoming call that rang but was never
/// answered (the caller hung up, or the ringing deadline expired).
///
/// Posted into the same per-peer slot as the ringing notification, so it
/// replaces whatever the call left behind instead of stacking.
RuntimeSystemNotification _missedCallSystemNotification({
  required CallSession session,
  required int createdAtMillis,
}) {
  return RuntimeSystemNotification(
    id: 'call-missed-$createdAtMillis-${session.peerAddress}',
    title: t('Nieodebrane połączenie'),
    body: t('{name} — połączenie {kind} bez odpowiedzi.', {
      'name': session.displayName,
      'kind': _callKindWord(session.kind),
    }),
    createdAtMillis: createdAtMillis,
    routeKey: buildCallRouteKey(
      peerAddress: session.peerAddress,
      title: session.displayName,
    ),
    slotKey: callNotificationSlotKey(session.peerAddress),
    category: RuntimeSystemNotificationCategory.call,
  );
}

/// Notification slot every call signal from [peerAddress] shares.
///
/// Must stay in step with the call branch of [_notificationDedupKeyForSignal]:
/// the ringing notification is posted under this slot and has to be
/// cancellable from the signal that ends the call.
String callNotificationSlotKey(String peerAddress) {
  return 'call:${peerAddress.trim()}';
}

String? _notificationDedupKeyForSignal(ZenSignal signal) {
  final String sender = signal.sender.trim();
  if (sender.isEmpty) {
    return null;
  }
  return switch (signal.type) {
    ZenSignalType.friendRequest ||
    ZenSignalType.friendAccept ||
    ZenSignalType.friendReject ||
    ZenSignalType.friendCancel ||
    ZenSignalType.friendRemove => 'social:$sender',
    ZenSignalType.groupInvite ||
    ZenSignalType.groupUpdate ||
    ZenSignalType.groupLeave ||
    ZenSignalType.groupInviteAck => 'group:${signal.groupId ?? sender}',
    ZenSignalType.message => 'message:$sender',
    ZenSignalType.groupMessage => 'group-message:${signal.groupId ?? sender}',
    ZenSignalType.callInvite ||
    ZenSignalType.callOffer ||
    ZenSignalType.callRinging ||
    ZenSignalType.callOfferRequest ||
    ZenSignalType.callAnswer ||
    ZenSignalType.callAccept ||
    ZenSignalType.callBusy ||
    ZenSignalType.callDecline ||
    ZenSignalType.callEnd => callNotificationSlotKey(sender),
    ZenSignalType.groupCallInvite ||
    ZenSignalType.groupCallJoin ||
    ZenSignalType.groupCallLeave ||
    ZenSignalType.groupCallState ||
    ZenSignalType.groupCallOffer ||
    ZenSignalType.groupCallAnswer ||
    ZenSignalType.groupCallDecline => callNotificationSlotKey(
      signal.groupId ?? sender,
    ),
    ZenSignalType.profileUpdate => 'profile:$sender',
    ZenSignalType.disappearTimer => 'disappear:$sender',
    ZenSignalType.transferCancel => 'transfer:$sender',
    ZenSignalType.transferOffer ||
    ZenSignalType.transferAnswer ||
    ZenSignalType.ack ||
    ZenSignalType.messageRead ||
    ZenSignalType.messageChunk ||
    ZenSignalType.messageChunkAck ||
    ZenSignalType.deepLink ||
    ZenSignalType.presence ||
    ZenSignalType.typing ||
    ZenSignalType.unknown => null,
  };
}

List<InboxEntry> _prependBackgroundAlert(
  List<InboxEntry> source,
  InboxEntry entry, {
  required ZenSignal signal,
}) {
  final String? dedupKey = _notificationDedupKeyForSignal(signal);
  if (dedupKey == null) {
    return _prependInbox(source, entry);
  }
  final List<InboxEntry> filtered = source
      .where(
        (InboxEntry existing) =>
            _backgroundAlertDedupKeyForEntry(existing) != dedupKey,
      )
      .toList(growable: false);
  return _prependInbox(filtered, entry);
}

String? _backgroundAlertDedupKeyForEntry(InboxEntry entry) {
  final String peerAddress = entry.peerAddress?.trim() ?? '';
  if (peerAddress.isEmpty) {
    return null;
  }
  final String id = entry.id;
  if (id.startsWith('friend-')) {
    return 'social:$peerAddress';
  }
  if (id.startsWith('message-')) {
    return 'message:$peerAddress';
  }
  if (id.startsWith('call-')) {
    return 'call:$peerAddress';
  }
  if (id.startsWith('transfer-cancel-')) {
    return 'transfer:$peerAddress';
  }
  return null;
}

String _labelFor(ZenSignal signal, {Map<String, FriendProfile>? friends}) {
  String? knownName = friends?[signal.sender]?.displayLabel;
  if (knownName == null && friends != null) {
    final String normalized = PeerShareCodec.normalizeAddress(signal.sender);
    knownName = friends[normalized]?.displayLabel;
    if (knownName == null) {
      for (final MapEntry<String, FriendProfile> entry in friends.entries) {
        if (PeerShareCodec.addressesEqual(entry.key, signal.sender)) {
          knownName = entry.value.displayLabel;
          break;
        }
      }
    }
  }
  return _resolvedPeerLabel(
    address: signal.sender,
    displayName: signal.displayName,
    knownName: knownName,
  );
}

String _resolvedPeerLabel({
  required String address,
  String? displayName,
  String? knownName,
}) {
  // A locally assigned friend name always wins over whatever the signal
  // carried; the raw share code is only a last resort for strangers.
  final String? known = knownName?.trim();
  if (known != null && known.isNotEmpty) {
    return known;
  }
  final String? label = displayName?.trim();
  if (label != null && label.isNotEmpty) {
    return label;
  }
  return PeerShareCodec.displayNameForAddress(address);
}

RuntimeRouteIntent? _runtimeIntentForSignal(ZenSignal signal, int timestamp) {
  final String? routeKey = signal.type == ZenSignalType.deepLink
      ? signal.routeKey
      : _buildInboxEntry(signal: signal, receivedAtMillis: timestamp).routeKey;
  return runtimeRouteIntentFromRouteKey(
    id: 'launch-$timestamp-${signal.sender}',
    routeKey: routeKey,
  );
}

String _nextLaunchIntentId() {
  return 'launch-${DateTime.now().microsecondsSinceEpoch}';
}

Map<String, dynamic> _buildOutgoingTextPayload({
  required String messageId,
  required String text,
  required int sentAtMillis,
  int ttl = 0,
}) {
  return <String, dynamic>{
    'type': 'message',
    'msgId': messageId,
    'text': text,
    'createdAt': DateTime.fromMillisecondsSinceEpoch(
      sentAtMillis,
    ).toUtc().toIso8601String(),
    // Disappearing messages: the sender's timer (§14.1 point 10).
    if (ttl > 0) 'ttl': ttl,
  };
}

int _messageStorageBytes(ChatMessage message) {
  return utf8.encode(message.id).length +
      utf8.encode(message.sender).length +
      utf8.encode(message.text).length +
      utf8.encode(message.fileName ?? '').length +
      utf8.encode(message.mimeType ?? '').length +
      (message.attachmentSizeBytes ?? message.attachmentBytes?.length ?? 0) +
      (message.durationMs != null ? 8 : 0) +
      (message.readAtMillis != null ? 8 : 0) +
      64;
}

String _activityLabelForMillis(int sentAtMillis) {
  final DateTime now = DateTime.now();
  final DateTime sentAt = DateTime.fromMillisecondsSinceEpoch(sentAtMillis);
  final Duration delta = now.difference(sentAt);
  if (delta < const Duration(minutes: 1)) {
    return t('Teraz');
  }
  if (delta < const Duration(days: 1) &&
      now.day == sentAt.day &&
      now.month == sentAt.month &&
      now.year == sentAt.year) {
    return ZenFormat.time(sentAt);
  }
  final DateTime yesterday = now.subtract(const Duration(days: 1));
  if (yesterday.day == sentAt.day &&
      yesterday.month == sentAt.month &&
      yesterday.year == sentAt.year) {
    return t('Wczoraj');
  }
  return ZenFormat.dayMonth(sentAt);
}

String _presenceLastSeenLabel({
  required int nowMillis,
  required int lastSeenAtMillis,
}) {
  final int deltaMillis = nowMillis <= lastSeenAtMillis
      ? 0
      : nowMillis - lastSeenAtMillis;
  final Duration delta = Duration(milliseconds: deltaMillis);
  if (delta < const Duration(minutes: 1)) {
    return t('Przed chwila');
  }
  if (delta < const Duration(hours: 1)) {
    return t('{count} min temu', {'count': delta.inMinutes});
  }
  if (delta < const Duration(days: 1)) {
    return t('{count} h temu', {'count': delta.inHours});
  }
  return t('{count} d temu', {'count': delta.inDays});
}

List<InboxEntry> _removeEntriesForPeer(
  List<InboxEntry> entries,
  String peerAddress, {
  Set<InboxEntryType>? types,
}) {
  return entries
      .where((InboxEntry entry) {
        final String? entryPeer = entry.peerAddress;
        if (entryPeer == null ||
            !PeerShareCodec.addressesEqual(entryPeer, peerAddress)) {
          return true;
        }
        return types != null && !types.contains(entry.type);
      })
      .toList(growable: false);
}

FriendProfile? _friendFromMap(
  Map<String, FriendProfile> friends,
  String address,
) {
  final String canonical = PeerShareCodec.normalizeAddress(address);
  final FriendProfile? direct = friends[canonical] ?? friends[address];
  if (direct != null) {
    return direct;
  }
  for (final FriendProfile friend in friends.values) {
    if (PeerShareCodec.addressesEqual(friend.address, canonical)) {
      return friend;
    }
  }
  return null;
}

/// Stores [profile] under its canonical address (dropping stale spellings
/// of it). A profile without a real name never wipes the name the peer
/// already told, and the nickname stays what this user set unless
/// [nicknameChanged].
void _putFriend(
  Map<String, FriendProfile> friends,
  FriendProfile profile, {
  bool nicknameChanged = false,
}) {
  final String canonical = PeerShareCodec.normalizeAddress(profile.address);
  final FriendProfile? existing = _friendFromMap(friends, canonical);
  final List<String> staleKeys = <String>[];
  friends.forEach((String key, FriendProfile current) {
    if (key == canonical) {
      return;
    }
    if (PeerShareCodec.addressesEqual(key, canonical) ||
        PeerShareCodec.addressesEqual(current.address, canonical)) {
      staleKeys.add(key);
    }
  });
  for (final String key in staleKeys) {
    friends.remove(key);
  }
  FriendProfile stored = profile.address == canonical
      ? profile
      : profile.copyWith(address: canonical);
  if (existing != null) {
    if (existing.hasProfileName && !stored.hasProfileName) {
      stored = stored.copyWith(displayName: existing.displayName);
    }
    if (!nicknameChanged) {
      stored = stored.copyWith(nickname: existing.nickname);
    }
  }
  friends[canonical] = stored;
}

void _removeFriend(Map<String, FriendProfile> friends, String address) {
  final String canonical = PeerShareCodec.normalizeAddress(address);
  final List<String> staleKeys = <String>[];
  friends.forEach((String key, FriendProfile existing) {
    if (key == canonical ||
        key == address ||
        PeerShareCodec.addressesEqual(key, canonical) ||
        PeerShareCodec.addressesEqual(existing.address, canonical)) {
      staleKeys.add(key);
    }
  });
  for (final String key in staleKeys) {
    friends.remove(key);
  }
}

Map<String, FriendProfile> _canonicalizeFriends(
  Map<String, FriendProfile> friends,
) {
  final Map<String, FriendProfile> next = <String, FriendProfile>{};
  for (final FriendProfile friend in friends.values) {
    _putFriend(next, friend);
  }
  return next;
}

/// Friend gate: every signal arriving over the mesh must come from a peer
/// with a relationship that authorizes that signal type. The mesh itself
/// authenticates senders (address = identity key) and encrypts payloads
/// end-to-end; this gate decides which authenticated peers may drive the
/// app.
bool _isSignalAllowedFromPeer(SocialHubState hubState, ZenSignal signal) {
  final FriendProfile? profile = hubState.friendByAddress(signal.sender);
  final FriendRelationshipStatus status =
      profile?.status ?? FriendRelationshipStatus.none;
  if (status == FriendRelationshipStatus.blocked) {
    return false;
  }
  switch (signal.type) {
    case ZenSignalType.friendRequest:
    case ZenSignalType.groupInvite:
      // How new relationships/groups start; allowed from any non-blocked peer.
      return true;
    case ZenSignalType.friendAccept:
      // Let through so it can be looked at, but it only completes an
      // invitation sent from here: from anyone else it is downgraded to an
      // incoming request (see `FriendLifecycleReducer.applyRemoteAccepted`).
      return true;
    case ZenSignalType.friendReject:
    case ZenSignalType.friendCancel:
    case ZenSignalType.friendRemove:
      // Lifecycle events only make sense for peers we already know about.
      return profile != null;
    case ZenSignalType.ack:
    case ZenSignalType.messageRead:
    case ZenSignalType.message:
    case ZenSignalType.messageChunk:
    case ZenSignalType.messageChunkAck:
    case ZenSignalType.transferOffer:
    case ZenSignalType.transferAnswer:
    case ZenSignalType.transferCancel:
    case ZenSignalType.callInvite:
    case ZenSignalType.callOffer:
    case ZenSignalType.callAnswer:
    case ZenSignalType.callRinging:
    case ZenSignalType.callBusy:
    case ZenSignalType.callAccept:
    case ZenSignalType.callDecline:
    case ZenSignalType.callEnd:
    case ZenSignalType.callOfferRequest:
      return status == FriendRelationshipStatus.accepted;
    case ZenSignalType.groupCallInvite:
    case ZenSignalType.groupCallJoin:
    case ZenSignalType.groupCallLeave:
    case ZenSignalType.groupCallState:
    case ZenSignalType.groupCallOffer:
    case ZenSignalType.groupCallAnswer:
    case ZenSignalType.groupCallDecline:
      // Only members of a group the user has joined: a call must never ring
      // (or connect) for a group they have not accepted, and friendship
      // alone does not make someone part of the call.
      final GroupProfile? callGroup = hubState.groups[signal.groupId ?? ''];
      return callGroup != null &&
          !callGroup.isInvitePending &&
          (groupHasMember(callGroup, signal.sender) ||
              PeerShareCodec.addressesEqual(
                callGroup.createdById,
                signal.sender,
              ));
    case ZenSignalType.profileUpdate:
      // Anyone the user has a relationship with (the photo of someone who
      // just accepted can arrive before the acceptance itself).
      return status == FriendRelationshipStatus.accepted ||
          status == FriendRelationshipStatus.pendingOutgoing ||
          status == FriendRelationshipStatus.pendingIncoming;
    case ZenSignalType.groupMessage:
      // Traffic for a group this device is not in (never joined, declined,
      // or left) is noise, even from a friend: it used to land in a hidden
      // timeline and still raise a notification for a group the user left.
      final GroupProfile? targetGroup = hubState.groups[signal.groupId ?? ''];
      if (targetGroup == null) {
        return false;
      }
      if (targetGroup.isInvitePending &&
          status != FriendRelationshipStatus.accepted) {
        // A group the user has not joined is only an invitation: anyone can
        // create one, so only friends' messages are kept for the preview
        // until they decide.
        return false;
      }
      // Membership, not friendship, decides: a friend outside the group (or
      // a late message from someone who already left) must not post into
      // it - it used to silently re-add them as a member.
      return groupHasMember(targetGroup, signal.sender) ||
          PeerShareCodec.addressesEqual(targetGroup.createdById, signal.sender);
    case ZenSignalType.groupUpdate:
    case ZenSignalType.groupLeave:
    case ZenSignalType.groupInviteAck:
      if (status == FriendRelationshipStatus.accepted) {
        return true;
      }
      final GroupProfile? grp = hubState.groups[signal.groupId ?? ''];
      return grp != null &&
          (groupHasMember(grp, signal.sender) ||
              PeerShareCodec.addressesEqual(grp.createdById, signal.sender));
    case ZenSignalType.disappearTimer:
      // A friend for the 1:1 chat; a member of a joined group for a group.
      final String? timerGroupId = signal.groupId;
      if (timerGroupId == null || timerGroupId.isEmpty) {
        return status == FriendRelationshipStatus.accepted;
      }
      final GroupProfile? timerGroup = hubState.groups[timerGroupId];
      return timerGroup != null &&
          !timerGroup.isInvitePending &&
          (groupHasMember(timerGroup, signal.sender) ||
              PeerShareCodec.addressesEqual(
                timerGroup.createdById,
                signal.sender,
              ));
    case ZenSignalType.deepLink:
    case ZenSignalType.presence:
    case ZenSignalType.typing:
    case ZenSignalType.unknown:
      return status == FriendRelationshipStatus.accepted;
  }
}

bool _currentCallMatchesSignal(CallSession? call, ZenSignal signal) {
  if (call == null) {
    return false;
  }
  if (call.isGroup) {
    if (signal.groupId != null && signal.groupId == call.groupId) {
      final String? normalizedCallId = signal.callId?.trim();
      return normalizedCallId == null ||
          normalizedCallId.isEmpty ||
          normalizedCallId == call.id;
    }
  }
  return _currentCallMatches(
    call: call,
    peerAddress: signal.sender,
    callId: signal.callId,
  );
}

bool _shouldKeepCurrentCallOnIncomingSignal(
  CallSession? call,
  ZenSignal signal,
) {
  if (call == null || _currentCallMatchesSignal(call, signal)) {
    return false;
  }
  if (call.status == CallSessionStatus.active) {
    return true;
  }
  if (_isSimultaneousCallGlare(call, signal)) {
    final String incomingCallId = signal.callId?.trim() ?? '';
    if (incomingCallId.isEmpty) {
      return true;
    }
    return _shouldPreferLocalOutgoingCall(call, incomingCallId);
  }
  if (call.isIncoming && call.status == CallSessionStatus.ringing) {
    return false;
  }
  return true;
}

bool _isSimultaneousCallGlare(CallSession? call, ZenSignal signal) {
  final String incomingCallId = signal.callId?.trim() ?? '';
  return call != null &&
      !call.isIncoming &&
      call.status != CallSessionStatus.active &&
      PeerShareCodec.addressesEqual(call.peerAddress, signal.sender) &&
      incomingCallId.isNotEmpty &&
      call.id != incomingCallId;
}

bool _shouldPreferLocalOutgoingCall(CallSession call, String incomingCallId) {
  return call.id.compareTo(incomingCallId) <= 0;
}

String _callKindLabel(String? rawKind) {
  return _callKindWord(_callKind(rawKind));
}

/// "wideo" or "audio", as it is put into the call texts.
String _callKindWord(CallInviteKind kind) {
  return kind == CallInviteKind.video ? t('wideo') : t('audio');
}

CallInviteKind _callKind(String? rawKind) {
  return rawKind == CallInviteKind.video.name
      ? CallInviteKind.video
      : CallInviteKind.audio;
}

bool _currentCallMatches({
  required CallSession? call,
  required String peerAddress,
  String? callId,
}) {
  if (call == null) {
    return false;
  }
  final bool match =
      PeerShareCodec.addressesEqual(call.peerAddress, peerAddress) ||
      (call.isGroup &&
          (call.groupId == peerAddress ||
              call.participantAddresses.contains(peerAddress)));
  if (!match) {
    return false;
  }
  final String? normalizedCallId = callId?.trim();
  return normalizedCallId == null ||
      normalizedCallId.isEmpty ||
      normalizedCallId == call.id;
}

/// Canonical, de-duplicated member list.
///
/// Addresses reach a group from three places — the local node, the friend
/// list and the inviter's payload — and not always in the same textual form.
/// Stored raw, one peer could sit in the list twice and receive every group
/// message twice.
List<String> normalizedGroupMembers(Iterable<String> addresses) {
  final List<String> result = <String>[];
  final Set<String> seen = <String>{};
  for (final String raw in addresses) {
    final String canonical = PeerShareCodec.normalizeAddress(raw);
    if (canonical.isEmpty || canonical == 'self') {
      continue;
    }
    if (seen.add(canonical)) {
      result.add(canonical);
    }
  }
  return result;
}

/// Membership test that tolerates the different spellings of one address.
bool groupHasMember(GroupProfile group, String address) {
  if (group.hasMember(address)) {
    return true;
  }
  return group.memberAddresses.any(
    (String member) => PeerShareCodec.addressesEqual(member, address),
  );
}

/// The member list of [group] - a group this device already has - after a
/// `group_invite` (an invitation or a member-list sync) from its sender, or
/// null when that signal may not change it.
///
/// The creator, as this device recorded it (whoever brought this device
/// in), speaks for the group: its list is merged as it comes. Any other
/// member brings in at most one address per signal: adding someone in the
/// app adds one person, and the sync that follows names exactly one address
/// the others have not seen yet. A list with more unknown addresses from an
/// ordinary member is no addition anyone made in the app - it could pull
/// any number of strangers into everyone's group traffic and presence - so
/// it changes nothing. Neither does anything from outside the group.
/// [selfAddress] (this device; may be unknown) never counts as unknown.
List<String>? _groupMembersAfterInvite(
  GroupProfile group,
  ZenSignal signal, {
  String selfAddress = '',
}) {
  final bool fromCreator = PeerShareCodec.addressesEqual(
    group.createdById,
    signal.sender,
  );
  if (!fromCreator && !groupHasMember(group, signal.sender)) {
    return null;
  }
  final List<String> incoming = normalizedGroupMembers(<String>[
    signal.sender,
    ...?signal.memberAddresses,
  ]);
  if (!fromCreator) {
    final int unknown = incoming
        .where(
          (String address) =>
              !groupHasMember(group, address) &&
              (selfAddress.isEmpty ||
                  !PeerShareCodec.addressesEqual(address, selfAddress)),
        )
        .length;
    if (unknown > 1) {
      return null;
    }
  }
  return cappedGroupMembers(
    normalizedGroupMembers(<String>[...group.memberAddresses, ...incoming]),
  );
}

/// Signals worth a system notification while the app is visible but not
/// focused. Deliberately short: bookkeeping (leave, acks, receipts) and call
/// signalling (which has its own ringing UI) never qualify.
bool _isNotifiableWhileUnfocused(ZenSignalType type) => switch (type) {
  ZenSignalType.message ||
  ZenSignalType.groupMessage ||
  ZenSignalType.groupInvite ||
  ZenSignalType.friendRequest ||
  ZenSignalType.friendAccept => true,
  _ => false,
};

/// Signals a person would recognise as an event of their own.
bool _isUserFacingSignal(ZenSignalType type) => switch (type) {
  ZenSignalType.friendRequest ||
  ZenSignalType.friendAccept ||
  ZenSignalType.friendReject ||
  ZenSignalType.friendCancel ||
  ZenSignalType.friendRemove ||
  ZenSignalType.message ||
  ZenSignalType.groupMessage ||
  ZenSignalType.groupInvite ||
  ZenSignalType.groupCallInvite ||
  ZenSignalType.transferCancel ||
  ZenSignalType.callInvite ||
  ZenSignalType.callOffer ||
  ZenSignalType.callAnswer ||
  ZenSignalType.callAccept ||
  ZenSignalType.callDecline ||
  ZenSignalType.callBusy ||
  ZenSignalType.callEnd => true,
  _ => false,
};

/// One member must never be kept under two spellings of the same address
/// (and messaged twice); normalised on load as well.
Map<String, GroupProfile> _canonicalizeGroups(
  Map<String, GroupProfile> groups,
) {
  return <String, GroupProfile>{
    for (final MapEntry<String, GroupProfile> entry in groups.entries)
      entry.key: entry.value.copyWith(
        memberAddresses: normalizedGroupMembers(entry.value.memberAddresses),
        pendingInviteAddresses: normalizedGroupMembers(
          entry.value.pendingInviteAddresses,
        ),
      ),
  };
}

/// Most unanswered incoming friend requests kept at once. Anyone can send
/// one, from as many identities as they like; past this the oldest pending
/// requests make room. Accepted friends are never evicted.
const int kMaxPendingIncomingFriendRequests = 100;

/// Most group invitations not answered yet kept at once (oldest go first).
const int kMaxPendingGroupInvites = 50;

/// Longest message preview kept on a friend or group row. The full text
/// lives in the timeline; the preview only ever shows a line or two.
const int kMaxStoredPreviewChars = 1000;

/// Pre-join messages kept for a group the user has not joined yet.
const int kMaxPendingGroupMessages = 200;

/// [value] cut to at most [maxChars] UTF-16 units, never splitting a
/// surrogate pair.
String _clipText(String value, int maxChars) {
  if (value.length <= maxChars) {
    return value;
  }
  if (maxChars <= 0) {
    return '';
  }
  int end = maxChars;
  final int last = value.codeUnitAt(end - 1);
  if (last >= 0xD800 && last <= 0xDBFF) {
    end -= 1;
  }
  return value.substring(0, end);
}

/// A `friend_accept` nobody here asked for, as the request it amounts to.
ZenSignal _unsolicitedAcceptAsRequest(ZenSignal signal) {
  return ZenSignal(
    type: ZenSignalType.friendRequest,
    sender: signal.sender,
    displayName: signal.displayName,
  );
}

/// Removes the oldest pending incoming requests until at most [keep] remain.
/// The map keeps insertion order, so the first ones are the oldest.
List<String> _evictOldestPendingIncoming(
  Map<String, FriendProfile> friends, {
  required int keep,
}) {
  final List<String> pendingKeys = <String>[
    for (final MapEntry<String, FriendProfile> entry in friends.entries)
      if (entry.value.status == FriendRelationshipStatus.pendingIncoming)
        entry.key,
  ];
  final int excess = pendingKeys.length - keep;
  if (excess <= 0) {
    return const <String>[];
  }
  final List<String> evicted = pendingKeys.sublist(0, excess);
  for (final String key in evicted) {
    friends.remove(key);
  }
  return evicted;
}

/// Removes the oldest group invitations not answered yet until at most
/// [keep] remain. Groups the user joined are never touched.
List<String> _evictOldestPendingGroupInvites(
  Map<String, GroupProfile> groups, {
  required int keep,
}) {
  final List<GroupProfile> pending =
      groups.values
          .where((GroupProfile group) => group.isInvitePending)
          .toList()
        ..sort(
          (GroupProfile a, GroupProfile b) =>
              a.createdAtMillis.compareTo(b.createdAtMillis),
        );
  final int excess = pending.length - keep;
  if (excess <= 0) {
    return const <String>[];
  }
  final List<String> evicted = <String>[
    for (final GroupProfile group in pending.take(excess)) group.id,
  ];
  for (final String id in evicted) {
    groups.remove(id);
  }
  return evicted;
}

/// The group id a `zen://group/<id>` route key points at, if any.
String? _groupIdOfRouteKey(String? routeKey) {
  final Uri? uri = routeKey == null ? null : Uri.tryParse(routeKey);
  if (uri == null || uri.host != 'group' || uri.pathSegments.isEmpty) {
    return null;
  }
  return uri.pathSegments.first;
}

/// [members] cut to [kMaxGroupMemberCount], keeping the ones listed first
/// (existing members come first in every merge).
List<String> cappedGroupMembers(List<String> members) {
  return members.length <= kMaxGroupMemberCount
      ? members
      : members.sublist(0, kMaxGroupMemberCount);
}

/// Most friend requests / group invitations kept in the background queue.
const int kMaxQueuedInvitations = 64;

/// [queue] without its oldest invitation entries, so at most [keep] remain.
/// Every other entry keeps its place.
List<QueuedSignal> _withoutOldestQueuedInvitations(
  List<QueuedSignal> queue, {
  required int keep,
}) {
  bool isInvitation(QueuedSignal entry) =>
      entry.signal.type == ZenSignalType.friendRequest ||
      entry.signal.type == ZenSignalType.groupInvite;
  int excess = queue.where(isInvitation).length - keep;
  if (excess <= 0) {
    return queue;
  }
  final List<QueuedSignal> kept = <QueuedSignal>[];
  for (final QueuedSignal entry in queue) {
    if (excess > 0 && isInvitation(entry)) {
      excess -= 1;
      continue;
    }
    kept.add(entry);
  }
  return kept;
}
