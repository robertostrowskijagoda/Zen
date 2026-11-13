part of 'social_hub_controller.dart';

SocialHubState _applySignal(
  SocialHubState current,
  ZenSignal signal,
  int receivedAtMillis, {
  required AppSettings appSettings,
  required FriendshipTick tick,
  required String? openConversationAddress,
  String? openGroupId,
  Set<String>? dismissedOrRejectedGroupIds,
}) {
  if (!_isSignalAllowedFromPeer(current, signal) ||
      _refusedAsStaleCode(current, signal, appSettings.inviteToken)) {
    return current;
  }
  final FriendshipBook book = current.book;
  final Map<String, FriendProfile> friends = current.friends;
  final InboxEntry inboxEntry = _buildInboxEntry(
    signal: signal,
    receivedAtMillis: receivedAtMillis,
    friends: current.friends,
    groups: current.groups,
  );
  // A friendship made by an answer: their name, the chat ready.
  FriendProfile connected(FriendProfile base) => _withAppRetentionDefaults(
    _friendReducer
        .applyAccepted(current: base, displayName: signal.displayName)
        .copyWith(
          isOnline: true,
          lastPresenceAtMillis: receivedAtMillis,
          lastMessagePreview: t('Połączenie gotowe. Możesz pisać od razu.'),
          lastActivityLabel: activityStamp(
            DateTime.now().millisecondsSinceEpoch,
          ),
        ),
    appSettings,
  );

  switch (signal.type) {
    case ZenSignalType.friendRequest:
      final FriendProfile? requester = book.profileOf(signal.sender);
      if (requester?.status == FriendRelationshipStatus.pendingOutgoing) {
        // Both asked each other at the same time: that is consent from both
        // sides, so the friendship is made here (and an accept goes back,
        // see receiveSignal) instead of two requests waiting on each other.
        return current.copyWith(
          book: book.admit(
            signal.sender,
            FriendshipEvidence.bothInvited,
            tick,
            shape: connected,
          ),
        );
      }
      if (requester?.status == FriendRelationshipStatus.accepted) {
        // Friends already: a request again changes nothing. It is the copy
        // of an invitation kept for the queue and replayed after the person
        // accepted it (which made the friend a pending request again), or
        // theirs sent again after our answer got lost (receiveSignal
        // answers that one).
        return current;
      }
      FriendshipBook next = book;
      List<InboxEntry> requestInbox = current.inbox;
      if (requester == null) {
        // A new invitation: strangers can send any number of them, so the
        // oldest unanswered ones make room (accepted friends never do).
        final (FriendshipBook roomy, List<String> evicted) = book
            .withoutOldestInvitations(
              keep: kMaxPendingIncomingFriendRequests - 1,
            );
        next = roomy;
        for (final String evictedPeer in evicted) {
          requestInbox = _removeEntriesForPeer(
            requestInbox,
            evictedPeer,
            types: const <InboxEntryType>{InboxEntryType.friendRequest},
          );
        }
      }
      return current.copyWith(
        book: next.invitedBy(
          signal.sender,
          (FriendProfile base) => _withAppRetentionDefaults(
            _friendReducer.applyIncomingRequest(
              address: signal.sender,
              displayName: signal.displayName ?? '',
              requestMessage: signal.content,
              current: base,
            ),
            appSettings,
          ),
        ),
        inbox: _prependSocialLifecycleInbox(requestInbox, inboxEntry),
      );
    case ZenSignalType.friendAccept:
      switch (book.meaningOfAccept(signal.sender)) {
        case AcceptMeaning.nothing:
          return current;
        case AcceptMeaning.invitation:
          // Nobody here invited them: an accept cannot make a stranger a
          // friend. It is handled as the invitation it really is, which
          // the user still has to confirm.
          return _applySignal(
            current,
            _unsolicitedAcceptAsRequest(signal),
            receivedAtMillis,
            appSettings: appSettings,
            tick: tick,
            openConversationAddress: openConversationAddress,
            openGroupId: openGroupId,
            dismissedOrRejectedGroupIds: dismissedOrRejectedGroupIds,
          );
        case AcceptMeaning.admits:
          return current.copyWith(
            book: book.admit(
              signal.sender,
              FriendshipEvidence.theyAcceptedMine,
              tick,
              shape: connected,
            ),
          );
        case AcceptMeaning.repeated:
          return current.copyWith(book: book.edit(signal.sender, connected));
      }
    case ZenSignalType.friendReject:
      return current.copyWith(
        book:
            book.profileOf(signal.sender)?.status ==
                FriendRelationshipStatus.pendingOutgoing
            ? book.withdraw(signal.sender)
            : null,
        inbox: _prependSocialLifecycleInbox(current.inbox, inboxEntry),
      );
    case ZenSignalType.friendCancel:
      return current.copyWith(
        book:
            book.profileOf(signal.sender)?.status ==
                FriendRelationshipStatus.pendingIncoming
            ? book.withdraw(signal.sender)
            : null,
        inbox: _prependSocialLifecycleInbox(current.inbox, inboxEntry),
      );
    case ZenSignalType.friendRemove:
      // They ended it: the book remembers it, so that nothing that comes
      // later brings them back on its own.
      return current.copyWith(
        book:
            book.profileOf(signal.sender)?.status ==
                FriendRelationshipStatus.accepted
            ? book.remove(signal.sender, tick)
            : book.withdraw(signal.sender),
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
      return current.copyWith(
        book: book.edit(
          signal.sender,
          (FriendProfile typingFriend) => typingFriend.copyWith(
            isOnline: true,
            lastPresenceAtMillis: receivedAtMillis,
            isTyping: signal.isTyping,
          ),
        ),
      );
    case ZenSignalType.message:
      final bool isConversationOpen =
          PeerShareCodec.addressesEqual(
            signal.sender,
            openConversationAddress ?? '',
          ) &&
          current.lifecycle.isInteractive;
      // Written a moment before it came: straight from them, who are there
      // now. A copy that waited in a mailbox (or a retry from long ago)
      // says nothing of whether they are there, and leaves their presence.
      final bool heardNow = _messageHeardNow(signal, receivedAtMillis);
      // An older message than one of theirs already here (a late copy from
      // a mailbox): counted, but the chat list keeps the newer line.
      final bool late = signal.chatExtras?[_kLateCopyKey] == true;
      return current.copyWith(
        book: book.edit(
          signal.sender,
          (FriendProfile currentFriend) => currentFriend.copyWith(
            isOnline: heardNow ? true : null,
            isTyping: false,
            lastPresenceAtMillis: heardNow
                ? max(currentFriend.lastPresenceAtMillis, receivedAtMillis)
                : null,
            lastMessagePreview: late
                ? null
                : _clipText(
                    chatPreviewLine(
                      signal.content ?? t('Nowa wiadomość'),
                      type: signal.messageType,
                      fileName: signal.fileName,
                      mimeType: signal.mimeType,
                    ),
                    kMaxStoredPreviewChars,
                  ),
            lastActivityLabel: late
                ? null
                : activityStamp(DateTime.now().millisecondsSinceEpoch),
            unreadCount: isConversationOpen ? 0 : currentFriend.unreadCount + 1,
          ),
        ),
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
        // `_groupAfterInvite`), never re-add the invite to the inbox.
        // Anyone outside the group who learned the id adds nothing.
        // The inviter's list of the members, asked for after joining (an
        // update that adds someone is not that list).
        final bool awaited =
            signal.inviteId == null &&
            _groupInviteNewcomerOf(signal) == null &&
            existingGroup.awaitingMembersFrom.isNotEmpty &&
            PeerShareCodec.addressesEqual(
              existingGroup.awaitingMembersFrom,
              signal.sender,
            );
        final GroupProfile? updated = _groupAfterInvite(
          existingGroup,
          signal,
          takeDepartures: awaited,
        );
        final bool membersCame = updated != null && awaited;
        if (updated == null ||
            (_sameGroupMembership(updated, existingGroup) && !membersCame)) {
          return current;
        }
        final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
          current.groups,
        );
        groups[groupId] = updated.copyWith(
          awaitingMembersFrom: membersCame ? '' : null,
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
        lastActivityLabel: activityStamp(DateTime.now().millisecondsSinceEpoch),
        lastMessagePreview: t('Zaproszono Cię do grupy.'),
        isInvitePending: true,
        receivedInviteIds: <String>[?signal.inviteId],
        inviteMemberNames: signal.memberNames ?? const <String>[],
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
            chatPreviewLine(
              mentionsAsPlainText(
                signal.content ?? t('Nowa wiadomość grupowa'),
                signalMentions(signal),
              ),
              type: signal.messageType,
              fileName: signal.fileName,
              mimeType: signal.mimeType,
            ),
            kMaxStoredPreviewChars,
          ),
          lastActivityLabel: activityStamp(
            DateTime.now().millisecondsSinceEpoch,
          ),
          unreadCount: isGroupOpen ? 0 : existing.unreadCount + 1,
          memberNames: senderName == null || senderName.isEmpty
              ? null
              : <String, String>{
                  ...existing.memberNames,
                  signal.sender: senderName,
                },
        );
        // Like a 1:1 message: the in-app list tells of it unless the group
        // is open (an invitation not answered yet tells nothing).
        if (!isGroupOpen && !existing.isInvitePending) {
          return current.copyWith(
            groups: groups,
            inbox: _prependInbox(current.inbox, inboxEntry),
          );
        }
      }
      return current.copyWith(groups: groups);
    case ZenSignalType.groupLeave:
      final String groupId = signal.groupId ?? '';
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.from(
        current.groups,
      );
      final GroupProfile? existing = groups[groupId];
      if (existing != null) {
        groups[groupId] = _groupAfterLeave(
          existing,
          signal.sender,
          _groupStampOf(signal.sentAtMillis) ?? receivedAtMillis,
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
    case ZenSignalType.messageReaction:
    case ZenSignalType.messageEdit:
    case ZenSignalType.messageDelete:
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
        if (current.activeCall!.status == CallSessionStatus.active) {
          // A renegotiation (a camera or a screen on or off): its kind is
          // set where the offer is applied, which also counts our own
          // camera and shared screen; the offer alone says only theirs.
          return current;
        }
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
          displayName: _labelFor(signal, friends: friends),
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
                displayName: _labelFor(signal, friends: friends),
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

/// What [signal] says in a notice or an inbox entry: for a message with an
/// attachment only the label of its type (never the caption or file name),
/// otherwise its text.
String? _signalPreviewText(ZenSignal signal) => signalNoticePreview(signal);

/// The id the entry about the group message [signal] keeps
/// ([InboxEntry.messageId]): the one its sender gave it, by which the
/// members change and delete it.
String? _noticeGroupMessageId(ZenSignal signal) {
  final String? id = signal.messageId?.trim();
  return id == null || id.isEmpty ? null : id;
}

/// Whether [entry] tells of [message] of the conversation [key] (a friend's
/// address, or `group:<id>`): the same sender, the same chat, the same id.
bool _entryTellsOf(InboxEntry entry, String key, ChatMessage message) {
  final String? id = entry.messageId;
  if (id == null || message.isOutgoing || message.isSystem) {
    return false;
  }
  if (!PeerShareCodec.addressesEqual(entry.peerAddress ?? '', message.sender)) {
    return false;
  }
  final String? groupId = _groupIdOfRouteKey(entry.routeKey);
  if (key.startsWith('group:')) {
    return groupId == key.substring('group:'.length) &&
        id == groupMessageWireId(message.id);
  }
  return groupId == null && id == message.id;
}

/// Whether the queued copy [queued] (kept for the app's return) is
/// [message] of the conversation [key]: replayed, it would put the
/// message's words back into the list.
bool _queuedSignalIs(QueuedSignal queued, String key, ChatMessage message) {
  final ZenSignal signal = queued.signal;
  if (message.isOutgoing ||
      message.isSystem ||
      !PeerShareCodec.addressesEqual(signal.sender, message.sender)) {
    return false;
  }
  if (key.startsWith('group:')) {
    return signal.type == ZenSignalType.groupMessage &&
        signal.groupId == key.substring('group:'.length) &&
        signal.messageId?.trim() == groupMessageWireId(message.id);
  }
  return signal.type == ZenSignalType.message &&
      _incomingMessageIdOf(signal) == message.id;
}

/// [signal] saying [text] instead (its queued copy after an edit).
ZenSignal _signalWithContent(ZenSignal signal, String text) => ZenSignal(
  type: signal.type,
  sender: signal.sender,
  callId: signal.callId,
  messageId: signal.messageId,
  routeKey: signal.routeKey,
  displayName: signal.displayName,
  content: text,
  messageType: signal.messageType,
  attachmentData: signal.attachmentData,
  attachmentEncoding: signal.attachmentEncoding,
  fileName: signal.fileName,
  mimeType: signal.mimeType,
  attachmentSizeBytes: signal.attachmentSizeBytes,
  durationMs: signal.durationMs,
  isPlaceholder: signal.isPlaceholder,
  attachmentTransferBytes: signal.attachmentTransferBytes,
  chunkIndex: signal.chunkIndex,
  chunkCount: signal.chunkCount,
  chunkData: signal.chunkData,
  sessionDescription: signal.sessionDescription,
  groupId: signal.groupId,
  groupName: signal.groupName,
  memberAddresses: signal.memberAddresses,
  memberNames: signal.memberNames,
  avatarPreset: signal.avatarPreset,
  bio: signal.bio,
  isTyping: signal.isTyping,
  sentAtMillis: signal.sentAtMillis,
  inviteId: signal.inviteId,
  cameraOn: signal.cameraOn,
  disappearSeconds: signal.disappearSeconds,
  miniProfile: signal.miniProfile,
  chatExtras: signal.chatExtras,
);

/// The notification slots that can show the messages of conversation
/// [key] from [sender] (see [_notificationDedupKeyForSignal]).
List<String> _chatNoticeSlots(String key, String sender) {
  if (key.startsWith('group:')) {
    final String groupId = key.substring('group:'.length);
    return <String>['group-message:$groupId', 'group-mention:$groupId'];
  }
  return <String>['message:${sender.trim()}'];
}

/// The in-app list's entry about [signal]. Group messages name their
/// sender as [_groupSenderLabel] does and their group by the name this
/// device keeps for it ([groups]).
InboxEntry _buildInboxEntry({
  required ZenSignal signal,
  required int receivedAtMillis,
  Map<String, FriendProfile>? friends,
  Map<String, GroupProfile>? groups,
}) {
  final String label = signal.type == ZenSignalType.groupMessage
      ? _groupSenderLabel(signal, friends)
      : _labelFor(signal, friends: friends);
  final String groupName = _groupNameOf(signal, groups);
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
      bodyText: _signalPreviewText(signal),
      createdAtMillis: receivedAtMillis,
      routeKey: buildConversationRouteKey(
        peerAddress: signal.sender,
        title: label,
      ),
      peerAddress: signal.sender,
      messageId: _incomingMessageIdOf(signal),
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
    // A mention of this person: its own entry, at the message.
    ZenSignalType.groupMessage when signalMentionsYou(signal) =>
      InboxEntry.fromEvents(
        id: 'group-mention-$receivedAtMillis-${signal.sender}',
        type: InboxEntryType.mention,
        title: SocialEventText('inbox.mention', <String, String>{
          'name': label,
        }),
        body: SocialEventText('inbox.groupMention.body', <String, String>{
          'group': groupName,
        }),
        bodyText: _signalPreviewText(signal),
        createdAtMillis: receivedAtMillis,
        routeKey: buildGroupRouteKey(
          groupId: signal.groupId ?? 'grp-${signal.sender}',
          title: groupName,
          // The key the message is kept under here: its id, or the
          // sender's own key when another member's message holds the id.
          messageId: switch (signal.chatExtras?[_kStoredKeyKey]) {
            final String key when key.isNotEmpty => key,
            _ => signal.messageId,
          },
        ),
        peerAddress: signal.sender,
        messageId: _noticeGroupMessageId(signal),
      ),
    ZenSignalType.groupMessage => InboxEntry.fromEvents(
      id: 'group-message-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.message,
      title: SocialEventText('inbox.groupMessage', <String, String>{
        'group': groupName,
        'name': label,
      }),
      body: const SocialEventText('inbox.groupMessage.body'),
      bodyText: _signalPreviewText(signal),
      createdAtMillis: receivedAtMillis,
      routeKey: buildGroupRouteKey(
        groupId: signal.groupId ?? 'grp-${signal.sender}',
        title: groupName,
      ),
      peerAddress: signal.sender,
      messageId: _noticeGroupMessageId(signal),
    ),
    ZenSignalType.groupCallInvite => InboxEntry.fromEvents(
      id: 'group-call-$receivedAtMillis-${signal.sender}',
      type: InboxEntryType.callInvite,
      title: SocialEventText('inbox.groupCall', <String, String>{
        'group': groupName,
      }),
      body: const SocialEventText('inbox.groupCall.body'),
      createdAtMillis: receivedAtMillis,
      routeKey: buildGroupRouteKey(
        groupId: signal.groupId ?? 'grp-${signal.sender}',
        title: groupName,
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
    ZenSignalType.messageReaction ||
    ZenSignalType.messageEdit ||
    ZenSignalType.messageDelete ||
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
      bodyText: _signalPreviewText(signal),
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
  required Map<String, GroupProfile>? groups,
  required NotificationPrivacy privacy,
}) {
  if (!_isUserFacingSignal(signal.type)) {
    // Receipts, typing, presence and membership bookkeeping would only
    // surface as a meaningless "Nowe zdarzenie" banner.
    return null;
  }
  if (signal.type == ZenSignalType.groupMessage &&
      _noticeGroupOf(signal, groups) == null) {
    // Not from a member of a joined group: no banner as that group.
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
    groups: groups,
  );
  // A chat message's banner tells no more than its notification would
  // (at "Nadawca i treść" it stays as the inbox entry has it).
  final NoticeText? chat = privacy == NotificationPrivacy.senderAndContent
      ? null
      : _chatNoticeText(
          signal: signal,
          friends: friends,
          groups: groups,
          privacy: privacy,
        );
  return RuntimeNotification(
    id: entry.id,
    title: chat?.title ?? entry.title,
    body: chat?.body ?? entry.body,
    createdAtMillis: entry.createdAtMillis,
    routeKey: entry.routeKey,
    dedupKey: _notificationDedupKeyForSignal(signal),
  );
}

/// What the notification about the chat message [signal] says at
/// [privacy]; `null` for anything that is not a chat message.
///
/// A group message names its sender as [_groupSenderLabel] does, in the
/// group as this device keeps it ([groups]); one from anyone who is not a
/// member of a joined group says only that something came.
NoticeText? _chatNoticeText({
  required ZenSignal signal,
  required NotificationPrivacy privacy,
  Map<String, FriendProfile>? friends,
  required Map<String, GroupProfile>? groups,
}) {
  if (signal.type != ZenSignalType.message &&
      signal.type != ZenSignalType.groupMessage) {
    return null;
  }
  if (signal.type == ZenSignalType.message) {
    return messageNoticeText(
      level: privacy,
      sender: _resolvedPeerLabel(
        address: signal.sender,
        displayName: signal.displayName,
        knownName: _namedFriendLabel(friends?[signal.sender], signal),
      ),
      preview: _signalPreviewText(signal),
    );
  }
  final GroupProfile? group = _noticeGroupOf(signal, groups);
  if (group == null) {
    return messageNoticeText(level: NotificationPrivacy.generic, sender: '');
  }
  final String sender = _groupSenderLabel(signal, friends);
  if (signalMentionsYou(signal)) {
    return mentionNoticeText(
      level: privacy,
      sender: sender,
      group: group.name,
      preview: _signalPreviewText(signal),
    );
  }
  return messageNoticeText(
    level: privacy,
    sender: sender,
    group: group.name,
    preview: _signalPreviewText(signal),
  );
}

RuntimeSystemNotification _systemNotificationFromEntry({
  required InboxEntry entry,
  required ZenSignal signal,
  Map<String, FriendProfile>? friends,
  required Map<String, GroupProfile>? groups,
  required NotificationPrivacy privacy,
}) {
  final String senderLabel = _resolvedPeerLabel(
    address: signal.sender,
    displayName: signal.displayName,
    knownName: _namedFriendLabel(friends?[signal.sender], signal),
  );
  final String title;
  final String body;
  final NoticeText? chat = _chatNoticeText(
    signal: signal,
    friends: friends,
    groups: groups,
    privacy: privacy,
  );

  switch (signal.type) {
    case ZenSignalType.message:
    case ZenSignalType.groupMessage:
      title = chat!.title;
      body = chat.body;
    case ZenSignalType.callInvite:
    case ZenSignalType.callOffer:
      title = senderLabel;
      final String kind = _callKindLabel(signal.content);
      body = t('Przychodzące połączenie {kind}...', {'kind': kind});
    case ZenSignalType.friendRequest:
      // Who and their own words (the central redaction hides them as the
      // notification level asks).
      title = entry.title;
      final String note = (signal.content ?? '').trim();
      body = note.isNotEmpty ? note : entry.body;
    case ZenSignalType.groupCallInvite:
      final String groupName = _groupNameOf(signal, groups).trim();
      title = groupName.isNotEmpty ? groupName : t('Połączenie grupowe');
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
    // Messages already got the form their conversation's level asks for
    // above; everything else is left to the central redaction.
    contentRedacted: chat != null,
    // What the notification switches of the settings see.
    kind: switch (signal.type) {
      ZenSignalType.message ||
      ZenSignalType.groupMessage => chatNoticeKind(signal),
      ZenSignalType.friendRequest ||
      ZenSignalType.friendAccept ||
      ZenSignalType.groupInvite => NoticeKind.invitation,
      _ => null,
    },
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
      ZenSignalType.messageReaction ||
      ZenSignalType.messageEdit ||
      ZenSignalType.messageDelete ||
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
    // Per sender: another member's message with the same id is another
    // message.
    return messageId != null && messageId.isNotEmpty
        ? 'group:$group:$sender:$messageId'
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
    // A mention stands apart from the group's other messages.
    ZenSignalType.groupMessage when signalMentionsYou(signal) =>
      'group-mention:${signal.groupId ?? sender}',
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
    ZenSignalType.messageReaction ||
    ZenSignalType.messageEdit ||
    ZenSignalType.messageDelete => 'chat-change:$sender',
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
  final FriendProfile? friend = _friendIn(friends, signal.sender);
  if (friend == null) {
    return _resolvedPeerLabel(
      address: signal.sender,
      displayName: signal.displayName,
    );
  }
  return _realNameFor(signal, friends: friends) ?? friend.displayLabel;
}

/// The name of [signal]'s sender when it is known: the one a friend told
/// before, else the one the signal carries (an answer to an invitation
/// brings it); null when neither is a real name. The placeholder of a
/// friend whose name is not known yet ("Kontakt Zen") never wins over the
/// name in the signal: an accepted invitation used to say "Połączenie z
/// Kontakt Zen jest gotowe" although the answer named the person.
String? _realNameFor(ZenSignal signal, {Map<String, FriendProfile>? friends}) {
  final FriendProfile? friend = _friendIn(friends, signal.sender);
  if (friend != null && friend.hasProfileName) {
    return friend.displayLabel;
  }
  final String carried = sanitizePeerName(signal.displayName);
  return isRealPeerName(signal.sender, carried) ? carried : null;
}

/// The entry for [address] in [friends], whatever its status.
FriendProfile? _friendIn(Map<String, FriendProfile>? friends, String address) {
  if (friends == null) {
    return null;
  }
  final FriendProfile? direct =
      friends[address] ?? friends[PeerShareCodec.normalizeAddress(address)];
  if (direct != null) {
    return direct;
  }
  for (final MapEntry<String, FriendProfile> entry in friends.entries) {
    if (PeerShareCodec.addressesEqual(entry.key, address)) {
      return entry.value;
    }
  }
  return null;
}

/// The joined group in [groups] that the group message [signal] may be told
/// about as: only one its sender is a member of. Anyone may claim to write
/// in a group, so a message from anyone else is never told about as that
/// group.
GroupProfile? _noticeGroupOf(
  ZenSignal signal,
  Map<String, GroupProfile>? groups,
) {
  final GroupProfile? group = groups?[signal.groupId ?? ''];
  if (group == null || group.isInvitePending) {
    return null;
  }
  return speaksInGroup(group, signal.sender) ? group : null;
}

/// Who wrote a group message, as its notices and inbox entries name them:
/// a friend by the name this person gave them, any other member as
/// "Kontakt Zen". The name a member gives itself (in the message, and so in
/// the group's member names) is never shown as if it were known.
String _groupSenderLabel(
  ZenSignal signal,
  Map<String, FriendProfile>? friends,
) {
  final FriendProfile? friend = _friendIn(friends, signal.sender);
  return friend != null && friend.status == FriendRelationshipStatus.accepted
      ? friend.displayLabel
      : t('Kontakt Zen');
}

/// The name of the group [signal] belongs to: the one this device keeps
/// for it, not one the sender put in the message (that is used only for a
/// group this device does not have).
String _groupNameOf(ZenSignal signal, Map<String, GroupProfile>? groups) =>
    groups?[signal.groupId ?? '']?.name ?? signal.groupName ?? '';

/// [friend]'s name when they told one; `null` for the "Kontakt Zen"
/// placeholder, so the name their message carries is used instead (a
/// friend whose profile never came, e.g. from an older Zen, was announced
/// as "Kontakt Zen" although the message named them).
String? _namedFriendLabel(FriendProfile? friend, ZenSignal signal) {
  if (friend == null || friend.hasProfileName) {
    return friend?.displayLabel;
  }
  return (signal.displayName?.trim().isNotEmpty ?? false)
      ? null
      : friend.displayLabel;
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
  int ttlAt = 0,
}) {
  return <String, dynamic>{
    'type': 'message',
    'msgId': messageId,
    'text': text,
    'createdAt': DateTime.fromMillisecondsSinceEpoch(
      sentAtMillis,
    ).toUtc().toIso8601String(),
    // Disappearing messages: the sender's timer, and when it was set (so
    // an older setting arriving late does not undo a newer one).
    if (ttl > 0) 'ttl': ttl,
    if (ttlAt > 0) kDisappearSetAtKey: ttlAt,
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

/// [friend]'s presence as it stands at [nowMillis] when nothing was heard
/// from them for a while (read back from the store, back on the network or
/// on the screen), [confirmedAtMillis], [seenAtMillis] and [openedAtMillis]
/// being what memory knows besides the friend: what the last confirmed
/// state is worth by now ([presenceAt]: offline when it would have
/// expired), however long ago, so a start shows every status at once; not
/// known ([PresenceDoubt.unchecked]) only for a friend never heard from.
/// [friend] itself when nothing changes, or they do not show it.
FriendProfile _rememberedPresence(
  FriendProfile friend, {
  required int nowMillis,
  Duration foregroundFor = kPresenceForegroundFor,
  Duration offlineAfter = kPresenceOfflineAfter,
  Duration backgroundFor = kPresenceBackgroundFor,
  int confirmedAtMillis = 0,
  int seenAtMillis = 0,
  int openedAtMillis = 0,
}) {
  if (friend.presence == PeerPresence.hidden) {
    return friend;
  }
  final int confirmed = max(friend.presenceAtMillis, confirmedAtMillis);
  final int seen = max(friend.lastPresenceAtMillis, seenAtMillis);
  final bool sameTimes =
      confirmed == friend.presenceAtMillis &&
      seen == friend.lastPresenceAtMillis;
  if (confirmed <= 0) {
    // Never heard from: nothing to show but that it is not known.
    if (friend.presenceDoubt == PresenceDoubt.unchecked && sameTimes) {
      return friend;
    }
    return friend.copyWith(presenceDoubt: PresenceDoubt.unchecked);
  }
  // Confirmed longer ago than kPresenceRememberedFor too: what it is worth
  // by now (offline, "ostatnio w sieci …") shows at once, not "status
  // nieznany" until the first answers came; an answer puts it right.
  final PeerPresence presence = presenceAt(
    presence: friend.presence,
    presenceAtMillis: confirmed,
    nowMillis: nowMillis,
    foregroundFor: foregroundFor,
    backgroundFor: backgroundFor,
  );
  // Online until the last confirmation: Zen was last open there then.
  final int opened =
      friend.presence == PeerPresence.online && presence != friend.presence
      ? max(friend.lastOpenedAtMillis, openedAtMillis)
      : friend.lastOpenedAtMillis;
  final bool unreachable =
      friend.isOnline &&
      seen > 0 &&
      nowMillis - seen >= offlineAfter.inMilliseconds;
  if (friend.presenceDoubt == null &&
      presence == friend.presence &&
      sameTimes &&
      opened == friend.lastOpenedAtMillis &&
      !unreachable) {
    return friend;
  }
  return friend.copyWith(
    isOnline: unreachable ? false : null,
    presence: presence,
    presenceAtMillis: confirmed,
    lastPresenceAtMillis: seen,
    presenceDoubt: null,
    lastOpenedAtMillis: opened,
  );
}

/// [book] as read back from the store at [nowMillis]: each one's
/// presence as [_rememberedPresence] has it, unless [keep] gives it (what
/// memory knows of that friend).
FriendshipBook _withRememberedPresence(
  FriendshipBook book, {
  required int nowMillis,
  FriendProfile? Function(FriendProfile friend)? keep,
}) => book.editAll(
  (FriendProfile friend) => switch (keep?.call(friend)) {
    final FriendProfile known =>
      friend.presence == PeerPresence.hidden ||
              friend.presenceDoubt == known.presenceDoubt
          ? friend
          : friend.copyWith(presenceDoubt: known.presenceDoubt),
    null => _rememberedPresence(friend, nowMillis: nowMillis),
  },
);

/// [stored] (the friends read back from the store) with each friend's
/// presence as [known] (memory, with its latest confirmations) has it when
/// memory's was confirmed later: the state, its time, whether they are
/// reachable and when last seen, and the last opening that goes with it.
/// The rest of each friend is the stored one.
FriendshipBook _withNewerPresence(
  FriendshipBook stored,
  FriendshipBook known,
) => stored.editAll((FriendProfile friend) {
  final FriendProfile? mine = known.profileOf(friend.address);
  if (mine == null || mine.presenceAtMillis <= friend.presenceAtMillis) {
    return friend;
  }
  return friend.copyWith(
    isOnline: mine.isOnline,
    lastPresenceAtMillis: max(
      mine.lastPresenceAtMillis,
      friend.lastPresenceAtMillis,
    ),
    presence: mine.presence,
    presenceAtMillis: mine.presenceAtMillis,
    lastOpenedAtMillis: mine.lastOpenedAtMillis,
  );
});

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
  if (_isManagedGroupMembershipSignal(signal)) {
    return false;
  }
  if (signal.type == ZenSignalType.callInvite ||
      signal.type == ZenSignalType.groupCallInvite) {
    // Who may ring this phone: the rule the locked receiver keeps too.
    return callInviteAdmitted(signal, _HubAlertFacts(hubState));
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
          speaksInGroup(callGroup, signal.sender);
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
      // it - it used to silently re-add them as a member. Nor does a
      // creator who left.
      return speaksInGroup(targetGroup, signal.sender);
    case ZenSignalType.groupUpdate:
    case ZenSignalType.groupLeave:
    case ZenSignalType.groupInviteAck:
      if (status == FriendRelationshipStatus.accepted) {
        return true;
      }
      final GroupProfile? grp = hubState.groups[signal.groupId ?? ''];
      return grp != null && speaksInGroup(grp, signal.sender);
    case ZenSignalType.disappearTimer:
    case ZenSignalType.messageReaction:
    case ZenSignalType.messageEdit:
    case ZenSignalType.messageDelete:
      // A friend for the 1:1 chat; a member of a joined group for a group.
      final String? timerGroupId = signal.groupId;
      if (timerGroupId == null || timerGroupId.isEmpty) {
        return status == FriendRelationshipStatus.accepted;
      }
      final GroupProfile? timerGroup = hubState.groups[timerGroupId];
      return timerGroup != null &&
          !timerGroup.isInvitePending &&
          speaksInGroup(timerGroup, signal.sender);
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
    // A call ringing in stays, whoever else calls (they hear "busy" from
    // the signal's own handling); only its caller may replace it with a
    // new call of theirs. Taken in, another caller's offer or invite put
    // their call on the screen in its place, and their invite left an
    // incoming-call entry in the inbox for a call refused as "busy".
    return _secondCallAgainst(call, signal) != _SecondCall.takesOver;
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

/// The key a group message with the id [wireId] by [author] (an address, or
/// 'self') is kept under when another author's message already holds that
/// id: members choose ids themselves, so one who learned another's id
/// could otherwise send it first and have the real message dropped as a
/// copy. The same for every device (from the id and the author alone).
String groupMessageLocalId(String wireId, String author) =>
    '$wireId$_altIdMark${sha256Hex(utf8.encode(PeerShareCodec.normalizeAddress(author))).substring(0, 16)}';

const String _altIdMark = '#';

/// The id members know the group message kept here as [localId] by (see
/// [groupMessageLocalId]).
String groupMessageWireId(String localId) {
  final int mark = localId.lastIndexOf(_altIdMark);
  return mark < 0 ? localId : localId.substring(0, mark);
}

/// Where in [thread] a group message with the id [wireId] by [author] goes,
/// or null when it is already there ([byAuthor]: whether a message here is
/// that author's). The first author of an id keeps it as it is; another
/// author's message with it goes under [groupMessageLocalId]. An id that
/// already looks like such a key never takes a bare slot, so nobody can
/// take another's key in advance.
///
/// Only the same author's message under the id or under one of the
/// author's keys makes it a copy. A key held by another author's message is
/// no copy but a conflict: before 1.16.4 every id was kept as it came, so a
/// member could have sent the very key another's message would need; the
/// message then goes under the author's next key ([_groupMessageKey]).
String? groupMessageSlot(
  List<ChatMessage> thread,
  String wireId,
  String author,
  bool Function(ChatMessage message) byAuthor,
) {
  // The keys that read back to this id: held, and held by this author.
  final Set<String> held = <String>{};
  final Set<String> own = <String>{};
  for (final ChatMessage m in thread) {
    if (m.id == wireId || groupMessageWireId(m.id) == wireId) {
      held.add(m.id);
      if (byAuthor(m)) {
        own.add(m.id);
      }
    }
  }
  if (own.contains(wireId)) {
    return null;
  }
  // Each of the author's keys is the id with a mark, so each one held is
  // one of [held]: among one more than that many keys one is free. Every
  // key up to there is looked at, as the author's message may sit past a
  // free one (a message before it disappeared).
  String? free;
  for (int n = 0; n <= held.length; n++) {
    final String key = _groupMessageKey(wireId, author, n);
    if (own.contains(key)) {
      return null;
    }
    if (!held.contains(key)) {
      free ??= key;
    }
  }
  if (!wireId.contains(_altIdMark) && !held.contains(wireId)) {
    return wireId;
  }
  return free != null && free.length <= kMaxSignalIdChars ? free : null;
}

/// The [n]th key of a group message with the id [wireId] by [author]: the
/// first is [groupMessageLocalId], each next one is for when the one before
/// is held by another author's message. All of them are [wireId] with a
/// mark and a part of the same length, so [groupMessageWireId] reads the id
/// back from any of them.
String _groupMessageKey(String wireId, String author, int n) {
  if (n == 0) {
    return groupMessageLocalId(wireId, author);
  }
  final String who = PeerShareCodec.normalizeAddress(author);
  return '$wireId$_altIdMark'
      '${sha256Hex(utf8.encode('$who$_altIdMark$n')).substring(0, 16)}';
}

/// Whether another feature keeps [group]'s member list
/// ([SocialHubController.syncManagedGroups]: the pyramid's cell chats,
/// worked out from the pyramid). Nobody's signal and no "add" in the app
/// changes it: a cell member could otherwise bring anyone into the cell's
/// chat on everybody's phone. Its id says so, whoever made a group under it.
bool isManagedGroup(GroupProfile group) => isManagedGroupId(group.id);

/// An invitation, member-list sync, leave, update or invitation receipt for
/// a managed group's id: nobody's to send, as only the feature that keeps
/// the group makes or changes it ([SocialHubController.syncManagedGroups]).
bool _isManagedGroupMembershipSignal(ZenSignal signal) =>
    switch (signal.type) {
      ZenSignalType.groupInvite ||
      ZenSignalType.groupInviteAck ||
      ZenSignalType.groupLeave ||
      ZenSignalType.groupUpdate => true,
      _ => false,
    } &&
    isManagedGroupId(signal.groupId ?? '');

/// What the rules shared with the locked receiver ([incomingAlertOf]) read
/// in the app: friends and joined groups from [state], the switches from
/// [settings], this device's address [self].
final class _HubAlertFacts implements AlertFacts {
  _HubAlertFacts(
    this.state, {
    this.settings = const AppSettings(),
    this.self = '',
  });

  final SocialHubState state;
  final AppSettings settings;

  @override
  final String self;

  @override
  bool isFriend(String address) =>
      state.friendByAddress(address)?.status ==
      FriendRelationshipStatus.accepted;

  @override
  bool speaksIn(String groupId, String address) {
    final GroupProfile? group = state.groups[groupId];
    return group != null &&
        !group.isInvitePending &&
        speaksInGroup(group, address);
  }

  @override
  bool mutes(NoticeKind kind) => settings.mutes(kind);

  @override
  bool chatMuted(String key, int nowMillis) => state.isMuted(key, nowMillis);

  @override
  bool groupNotifiesAll(String groupKey) => state.groupNotifiesAll(
    groupKey,
    mentionsOnly: settings.groupMentionsOnly,
  );
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

/// How far ahead of this phone's clock a time a member gives for a leave
/// or an addition may lie: as much leeway as an edit gets. A later one
/// counts as this moment plus the leeway, so nobody can stamp a change
/// that no real one could ever follow.
const int _kGroupStampLeewayMillis = 60 * 60 * 1000;

/// A time a peer gave for a change of a group's members (its own clock),
/// or null when it gave none usable.
int? _groupStampOf(int? at) {
  if (at == null || at <= 0) {
    return null;
  }
  final int latest =
      DateTime.now().millisecondsSinceEpoch + _kGroupStampLeewayMillis;
  return at > latest ? latest : at;
}

/// The time [stamps] hold for [address] (any spelling of it), or null.
int? _groupStampFor(Map<String, int> stamps, String address) {
  final int? exact = stamps[address];
  if (exact != null) {
    return exact;
  }
  for (final MapEntry<String, int> e in stamps.entries) {
    if (PeerShareCodec.addressesEqual(e.key, address)) {
      return e.value;
    }
  }
  return null;
}

/// [stamps] without [address] (any spelling of it).
Map<String, int> _withoutGroupStamp(Map<String, int> stamps, String address) {
  if (_groupStampFor(stamps, address) == null) {
    return stamps;
  }
  return <String, int>{
    for (final MapEntry<String, int> e in stamps.entries)
      if (!PeerShareCodec.addressesEqual(e.key, address)) e.key: e.value,
  };
}

/// [stamps] with [address] at [at], or at the later time it had already;
/// bounded ([boundedGroupMembershipStamps]).
Map<String, int> _withGroupStamp(
  Map<String, int> stamps,
  String address,
  int at,
) {
  final int? had = _groupStampFor(stamps, address);
  return boundedGroupMembershipStamps(<String, int>{
    ..._withoutGroupStamp(stamps, address),
    PeerShareCodec.normalizeAddress(address): had != null && had > at
        ? had
        : at,
  });
}

/// The one address a `group_invite` member-list update says its sender
/// adds ([kGroupAddedKey]), or null (an invitation, the members' list for
/// someone who joined, or an update from a Zen before 1.16.5).
String? _groupInviteNewcomerOf(ZenSignal signal) =>
    switch (signal.chatExtras?[kGroupAddedKey]) {
      final String address when address.isNotEmpty => address,
      _ => null,
    };

/// Who left the group and when, as the members' list for someone who just
/// joined tells it ([kGroupLeftKey]).
Map<String, int> _groupInviteDeparturesOf(ZenSignal signal) {
  final Object? left = signal.chatExtras?[kGroupLeftKey];
  if (left is! Map) {
    return const <String, int>{};
  }
  return <String, int>{
    for (final MapEntry<dynamic, dynamic> e in left.entries)
      if (e.key is String && e.value is int) e.key as String: e.value as int,
  };
}

/// Who left [group] and when, for the members' list sent to someone who
/// just joined ([kGroupLeftKey]), and who of the members was added by name
/// and when ([kGroupAddsKey]; the newcomer's own time among them, which
/// its leave is stamped after).
Map<String, dynamic> _groupDeparturesPayload(GroupProfile group) =>
    <String, dynamic>{
      if (group.departedAt.isNotEmpty)
        kGroupLeftKey: Map<String, int>.of(group.departedAt),
      if (group.addedAt.isNotEmpty)
        kGroupAddsKey: <String, int>{
          for (final MapEntry<String, int> e in group.addedAt.entries)
            if (groupHasMember(group, e.key)) e.key: e.value,
        },
    };

/// Who was added by name and when, as a `group_invite` tells it
/// ([kGroupAddsKey]).
Map<String, int> _groupInviteAddsOf(ZenSignal signal) {
  final Object? adds = signal.chatExtras?[kGroupAddsKey];
  if (adds is! Map) {
    return const <String, int>{};
  }
  return <String, int>{
    for (final MapEntry<dynamic, dynamic> e in adds.entries.take(
      kMaxGroupMemberCount,
    ))
      if (e.key is String && (e.key as String).isNotEmpty && e.value is int)
        e.key as String: e.value as int,
  };
}

/// How far back an addition by name counts as one other members may not
/// have heard of yet: as long as a member-list update can be on its way
/// (mailboxes keep mail 14 days).
const Duration kGroupAddRecentFor = Duration(days: 15);

/// The most additions one update tells of besides its own
/// ([kGroupAddsKey]); the newest.
const int kMaxGroupAddsTold = 64;

/// The members of [group] added by name lately ([kGroupAddRecentFor]) and
/// when, newest first, at most [kMaxGroupAddsTold]: what an update tells
/// besides the one it makes, so whoever knows of more can tell the
/// newcomer (`_tellOfAddsMissed`).
Map<String, int> _recentGroupAdds(GroupProfile group, int nowMillis) {
  final int since = nowMillis - kGroupAddRecentFor.inMilliseconds;
  final List<MapEntry<String, int>> recent =
      <MapEntry<String, int>>[
        for (final MapEntry<String, int> e in group.addedAt.entries)
          if (e.value >= since && groupHasMember(group, e.key)) e,
      ]..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            b.value.compareTo(a.value),
      );
  return <String, int>{
    for (final MapEntry<String, int> e in recent.take(kMaxGroupAddsTold))
      e.key: e.value,
  };
}

/// Whether [a] and [b] say the same of a group's members: the same list,
/// the same leaves and additions on record.
bool _sameGroupMembership(GroupProfile a, GroupProfile b) =>
    listEquals(a.memberAddresses, b.memberAddresses) &&
    mapEquals(a.departedAt, b.departedAt) &&
    mapEquals(a.addedAt, b.addedAt);

/// [group] after its member [leaver] left at [at] (the leaver's own clock,
/// else when the leave arrived): out of the members and the invitations
/// waiting for an answer, and on record as gone, so no list a step behind
/// brings them back. A leave stamped before the leaver was last added by
/// name is an older one (it arrived late, or a copy of it did) and changes
/// nothing. Only the leaver's own `group_leave` comes here: nobody can
/// record someone else's leave.
GroupProfile _groupAfterLeave(GroupProfile group, String leaver, int at) {
  final int? added = _groupStampFor(group.addedAt, leaver);
  if (added != null && added > at) {
    return group;
  }
  bool stays(String m) => !PeerShareCodec.addressesEqual(m, leaver);
  return group.copyWith(
    // A creator who left has no say over the group any more, also once
    // someone adds them again as a member ([_groupAfterInvite]).
    createdById: stays(group.createdById) ? null : '',
    memberAddresses: group.memberAddresses.where(stays).toList(),
    pendingInviteAddresses: group.pendingInviteAddresses.where(stays).toList(),
    pendingInviteIds: <String, String>{
      for (final MapEntry<String, String> e in group.pendingInviteIds.entries)
        if (stays(e.key)) e.key: e.value,
    },
    departedAt: _withGroupStamp(group.departedAt, leaver, at),
    addedAt: _withoutGroupStamp(group.addedAt, leaver),
  );
}

/// Whether [signal], a `group_leave`, is older than the last time its
/// sender was added to [group] by name: a late copy of a leave the person
/// took back by joining again.
bool _isStaleGroupLeave(
  GroupProfile group,
  ZenSignal signal,
  int receivedAtMillis,
) {
  final int? added = _groupStampFor(group.addedAt, signal.sender);
  return added != null &&
      added > (_groupStampOf(signal.sentAtMillis) ?? receivedAtMillis);
}

/// [group] - a group this device already has - after a `group_invite` (an
/// invitation or a member-list update) from its sender, or null when that
/// signal may not change it.
///
/// The creator, as this device recorded it (whoever brought this device
/// in), speaks for the group: every address of its list is taken. Any
/// other member brings in one person per signal: the one its update names
/// ([kGroupAddedKey]), or from a Zen before 1.16.5, the one address its
/// list has that this device has not seen - a list with more such
/// addresses is no addition anyone made in the app (it could pull any
/// number of strangers into everyone's group traffic and presence), so
/// none of them is taken. Nothing from outside the group, nor from a
/// creator who left it, changes anything.
///
/// Nobody's list brings back someone who left ([GroupProfile.departedAt]):
/// a list carries no time, and a member a step behind (offline when the
/// leave went out) still lists them. Only an addition by name stamped
/// later than the leave does: a new invitation of that person.
///
/// [takeDepartures]: this is the members' list this device waited for
/// after joining (from the inviter, whose list it takes whole anyway), so
/// the leaves it tells of are taken too ([kGroupLeftKey]); anyone else's
/// word on who left is never taken - a member could otherwise put anyone
/// out of the group on everybody's phone.
/// [selfAddress] (this device; may be unknown) never counts as someone
/// unknown, and no leave told of takes it out.
GroupProfile? _groupAfterInvite(
  GroupProfile group,
  ZenSignal signal, {
  String selfAddress = '',
  bool takeDepartures = false,
}) {
  if (isManagedGroup(group)) {
    return null;
  }
  bool isSelf(String address) =>
      selfAddress.isNotEmpty &&
      PeerShareCodec.addressesEqual(address, selfAddress);
  final bool fromCreator =
      PeerShareCodec.addressesEqual(group.createdById, signal.sender) &&
      _groupStampFor(group.departedAt, signal.sender) == null;
  if (!fromCreator && !groupHasMember(group, signal.sender)) {
    return null;
  }
  Map<String, int> departed = group.departedAt;
  Map<String, int> added = group.addedAt;
  List<String> members = group.memberAddresses;
  String creator = group.createdById;
  if (takeDepartures) {
    _groupInviteDeparturesOf(signal).forEach((String address, int raw) {
      final int? at = _groupStampOf(raw);
      final int? addedAt = _groupStampFor(added, address);
      if (at == null ||
          isSelf(address) ||
          PeerShareCodec.addressesEqual(address, signal.sender) ||
          (addedAt != null && addedAt > at)) {
        return;
      }
      departed = _withGroupStamp(departed, address, at);
      added = _withoutGroupStamp(added, address);
      members = members
          .where((String m) => !PeerShareCodec.addressesEqual(m, address))
          .toList();
      if (PeerShareCodec.addressesEqual(address, creator)) {
        creator = '';
      }
    });
  }
  final List<String> taken = <String>[];
  final String? newcomer = _groupInviteNewcomerOf(signal);
  if (newcomer != null && !isSelf(newcomer)) {
    final int? at = _groupStampOf(signal.sentAtMillis);
    final int? left = _groupStampFor(departed, newcomer);
    // An addition stamped after the leave is a new invitation; one without
    // a time can prove nothing against a leave.
    if (left == null || (at != null && at > left)) {
      taken.add(newcomer);
      departed = _withoutGroupStamp(departed, newcomer);
      if (at != null) {
        added = _withGroupStamp(added, newcomer, at);
      }
      if (left != null && PeerShareCodec.addressesEqual(newcomer, creator)) {
        // The creator left and comes back as a member like any other: the
        // say they gave up does not come back with them.
        creator = '';
      }
    }
  }
  final List<String> incoming = normalizedGroupMembers(<String>[
    signal.sender,
    ...?signal.memberAddresses,
  ]);
  // Additions by name its sender tells of, with their times
  // ([kGroupAddsKey]): from the inviter, of everyone; from a member, of
  // others added at about the time the newcomer was (its list a step
  // behind). Each is what the sender could have made one by one, and none
  // is taken over a later leave.
  final List<String> stamped = <String>[];
  _groupInviteAddsOf(signal).forEach((String address, int raw) {
    final int? at = _groupStampOf(raw);
    if (at == null ||
        !incoming.any(
          (String a) => PeerShareCodec.addressesEqual(a, address),
        )) {
      return;
    }
    final int? left = _groupStampFor(departed, address);
    if (left != null && at <= left) {
      return;
    }
    if (isSelf(address) ||
        groupHasMember(group, address) ||
        taken.any((String a) => PeerShareCodec.addressesEqual(a, address))) {
      // Only the inviter's word on when someone already here came counts
      // (its own time, which this device's leave is stamped after).
      if (fromCreator && left == null) {
        added = _withGroupStamp(added, address, at);
      }
      return;
    }
    stamped.add(address);
    departed = _withoutGroupStamp(departed, address);
    added = _withGroupStamp(added, address, at);
    if (left != null && PeerShareCodec.addressesEqual(address, creator)) {
      creator = '';
    }
  });
  taken.addAll(stamped);
  final List<String> unknown = <String>[
    for (final String address in incoming)
      if (!groupHasMember(group, address) &&
          !isSelf(address) &&
          _groupStampFor(departed, address) == null &&
          !taken.any((String a) => PeerShareCodec.addressesEqual(a, address)))
        address,
  ];
  // This device in the sender's list is no stranger to anyone.
  taken.addAll(incoming.where(isSelf));
  if (fromCreator || (newcomer == null && unknown.length <= 1)) {
    taken.addAll(unknown);
  }
  return group.copyWith(
    createdById: creator,
    memberAddresses: cappedGroupMembers(
      normalizedGroupMembers(<String>[...members, ...taken]),
    ),
    departedAt: departed,
    addedAt: added,
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

/// Whether [signal] starts something new with this person from someone
/// who did not use their current code ("Zmień kod", [inviteToken] set): a
/// friend request without the current code's token (an accept nobody here
/// asked for is one too) or an invitation to a group not known here, from
/// anyone who is not a friend, not invited from here and whose own request
/// did not already wait. Refused (see `_refuseStaleCode`) and kept nowhere.
bool _refusedAsStaleCode(
  SocialHubState state,
  ZenSignal signal,
  String inviteToken,
) {
  if (inviteToken.isEmpty) {
    return false;
  }
  switch (state.friendByAddress(signal.sender)?.status) {
    case FriendRelationshipStatus.accepted ||
        FriendRelationshipStatus.pendingOutgoing ||
        FriendRelationshipStatus.pendingIncoming ||
        FriendRelationshipStatus.blocked:
      return false;
    default:
      break;
  }
  switch (signal.type) {
    case ZenSignalType.friendRequest:
      return PeerShareCodec.fromStaleCode(inviteToken, signal.inviteId);
    case ZenSignalType.friendAccept:
      // Nobody here invited them (see above): the request it amounts to
      // carries no code.
      return true;
    case ZenSignalType.groupInvite:
      return !state.groups.containsKey(signal.groupId ?? '');
    default:
      return false;
  }
}

/// A `friend_accept` nobody here asked for, as the request it amounts to.
ZenSignal _unsolicitedAcceptAsRequest(ZenSignal signal) {
  return ZenSignal(
    type: ZenSignalType.friendRequest,
    sender: signal.sender,
    displayName: signal.displayName,
  );
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

/// What the person creating a group, or adding to one, is told when it
/// would list more than [kMaxGroupMemberCount] people (themselves too).
String groupFullText() =>
    t('Grupa może mieć najwyżej {n} osób.', {'n': kMaxGroupMemberCount});

/// Whether [group] lists [kMaxGroupMemberCount] people already: nobody more
/// can be added ([groupFullText]).
bool isGroupFull(GroupProfile group) =>
    normalizedGroupMembers(group.memberAddresses).length >=
    kMaxGroupMemberCount;

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

/// How long before its arrival a message may have been written for it to
/// count as a sign that its sender is there (a direct one takes moments;
/// one written longer ago waited in a mailbox or in its sender's queue, and
/// says nothing of now).
const Duration _kMessageAsPresence = Duration(minutes: 2);

/// Set by the hub on a message older than one of its sender's already in
/// the chat ([ZenSignal.chatExtras], never sent): see `_applySignal`.
const String _kLateCopyKey = 'zLateCopy';

/// Set by the hub on a group message kept under a key other than its id
/// ([groupMessageSlot]: another member's message holds the id), with that
/// key ([ZenSignal.chatExtras], never sent): a mention's notification opens
/// the chat at it, not at the other member's message.
const String _kStoredKeyKey = 'zKey';

/// Whether [signal] (a chat message that came at [receivedAtMillis]) was
/// written so shortly before that its sender is there now. One without its
/// time counts as heard now, as before, and so does one dated after its
/// arrival (the sender's clock runs ahead).
bool _messageHeardNow(ZenSignal signal, int receivedAtMillis) {
  final int? sentAt = signal.sentAtMillis;
  return sentAt == null ||
      receivedAtMillis - sentAt <= _kMessageAsPresence.inMilliseconds;
}
