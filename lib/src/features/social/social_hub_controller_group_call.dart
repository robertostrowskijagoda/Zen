part of 'social_hub_controller.dart';

/// How often a participant announces itself (and how often stale state is
/// swept away). Zero disables the periodic work (tests drive it by hand).
final Provider<Duration> groupCallHeartbeatIntervalProvider =
    Provider<Duration>((Ref ref) => const Duration(seconds: 8));

/// A participant not heard from for this long is considered gone.
final Provider<Duration> groupCallPresenceTimeoutProvider = Provider<Duration>(
  (Ref ref) => const Duration(seconds: 30),
);

/// How often the one who started a call rings the members not in it yet.
final Provider<Duration> groupCallReRingIntervalProvider = Provider<Duration>(
  (Ref ref) => const Duration(seconds: 3),
);

/// How long a new group call keeps ringing the others. When nobody joined
/// by then, the call ends by itself.
final Provider<Duration> groupCallRingWindowProvider = Provider<Duration>(
  (Ref ref) => const Duration(seconds: 45),
);

/// Group calls.
///
/// A group call is a *room*, not a phone call: whoever starts it is in it at
/// once, members get a ring, and anyone in the group can join (or leave and
/// rejoin) while it lasts. Nobody has to pick up at the same time.
///
/// Signalling, all direct datagrams (never relayed - a ring hours late is
/// worse than none):
///
/// * `group_call_invite` - rings the members not in the call yet;
/// * `group_call_join` - "I am in now", to every member;
/// * `group_call_state` - every participant's heartbeat, to every member, so
///   people outside the call see it running and can join;
/// * `group_call_leave` / `group_call_decline`;
/// * `gc_offer` / `gc_answer` - the media legs.
///
/// Media is a full mesh. Of every pair of participants the one with the
/// lower address makes the offer, so exactly one side of each pair ever
/// does; the other only answers. Two calls started at the same moment in one
/// group merge into the older one.
mixin _SocialHubGroupCallMixin on _SocialHubControllerBase {
  Timer? _groupCallTicker;
  Timer? _groupCallReRingTimer;
  int _groupCallRingStartedAt = 0;
  bool _groupCallEverConnected = false;

  /// Members who declined this device's ring for the current call.
  final Set<String> _groupRingDeclinedBy = <String>{};

  /// Calls this device declined or missed: their re-rings stay silent.
  final List<String> _silencedGroupCallIds = <String>[];

  /// When the leg to each peer started connecting.
  final Map<String, int> _groupLegStartedAt = <String, int>{};

  int get _nowMillis => DateTime.now().millisecondsSinceEpoch;

  String get _selfAddress => PeerShareCodec.normalizeAddress(
    ref.read(runtimeNodeSnapshotProvider).localAddress,
  );

  bool _isSelfAddress(String address) {
    final String self = _selfAddress;
    return self.isNotEmpty && PeerShareCodec.addressesEqual(address, self);
  }

  /// The group call this device is in (not merely ringing for).
  CallSession? get _joinedGroupCall {
    final CallSession? session = state.activeCall;
    return session != null &&
            session.isGroup &&
            session.status != CallSessionStatus.ringing
        ? session
        : null;
  }

  @override
  void _wireGroupCallMedia() {
    final GroupCallMedia media = _groupMedia;
    media.sendSignal = _sendGroupCallPayload;
    media.onLegState = _handleGroupLegState;
    ref.onDispose(() {
      _groupCallTicker?.cancel();
      _groupCallTicker = null;
      _groupCallReRingTimer?.cancel();
      _groupCallReRingTimer = null;
      media.sendSignal = null;
      media.onLegState = null;
      unawaited(media.close());
    });
  }

  Future<void> _sendGroupCallPayload(
    String peer,
    Map<String, dynamic> payload,
  ) async {
    if (!isRoutablePeerAddress(peer)) {
      return;
    }
    try {
      await ref
          .read(signalTransportProvider)
          .send(remoteAddress: peer, payload: payload);
    } catch (error, stackTrace) {
      logZenError(
        'Sending ${payload['type']} to $peer failed',
        error,
        stackTrace,
      );
    }
  }

  List<String> _otherMembers(GroupProfile group) {
    return normalizedGroupMembers(
      group.memberAddresses,
    ).where((String member) => !_isSelfAddress(member)).toList(growable: false);
  }

  Map<String, dynamic> _groupCallPayload(
    String type,
    OngoingGroupCall call, {
    GroupProfile? group,
  }) {
    final String senderName = ref
        .read(userProfileControllerProvider)
        .publicName;
    return <String, dynamic>{
      'type': type,
      'groupId': call.groupId,
      'callId': call.callId,
      'kind': call.kind.name,
      'participants': call.participantAddresses,
      'camera': _groupMedia.hasLocalVideo,
      if (group != null) 'groupName': group.name,
      if (senderName.trim().isNotEmpty) 'senderName': senderName.trim(),
    };
  }

  void _broadcastGroupCall(
    GroupProfile group,
    Map<String, dynamic> payload, {
    bool Function(String member)? where,
  }) {
    for (final String member in _otherMembers(group)) {
      if (where != null && !where(member)) {
        continue;
      }
      unawaitedLogged(
        _sendGroupCallPayload(member, payload),
        context: 'group call ${payload['type']} to $member',
      );
    }
  }

  void _putGroupCall(OngoingGroupCall? call, {required String groupId}) {
    final Map<String, OngoingGroupCall> calls =
        Map<String, OngoingGroupCall>.from(state.groupCalls);
    if (call == null) {
      calls.remove(groupId);
    } else {
      calls[groupId] = call;
    }
    state = state.copyWith(groupCalls: calls);
  }

  /// Keeps the joined session's participant list in step with the record.
  bool _syncJoinedParticipants() {
    final CallSession? joined = _joinedGroupCall;
    if (joined == null) {
      return false;
    }
    final OngoingGroupCall? call = state.groupCalls[joined.groupId];
    final List<String> participants = call != null && call.callId == joined.id
        ? call.participantAddresses
        : const <String>[];
    if (listEquals(participants, joined.participantAddresses)) {
      return false;
    }
    if (participants.isNotEmpty) {
      _groupCallEverConnected = true;
    }
    state = state.copyWith(
      activeCall: joined.copyWith(participantAddresses: participants),
    );
    return true;
  }

  // ---------------------------------------------------------------------------
  // Incoming signals
  // ---------------------------------------------------------------------------

  @override
  Future<void> _handleGroupCallSignal(ZenSignal signal) async {
    final String? groupId = signal.groupId;
    final String? callId = signal.callId;
    final GroupProfile? group = state.groups[groupId ?? ''];
    if (groupId == null || callId == null || group == null) {
      return;
    }
    final String sender = PeerShareCodec.normalizeAddress(signal.sender);
    if (_isSelfAddress(sender)) {
      return;
    }
    final CallInviteKind kind = _callKind(signal.content);
    final int now = _nowMillis;

    // Two calls in one group (started at the same moment): the older one wins
    // and everyone ends up there.
    final CallSession? mine = _joinedGroupCall;
    final String? myCallId = mine != null && mine.groupId == groupId
        ? mine.id
        : null;
    final OngoingGroupCall? known = state.groupCalls[groupId];
    final String? currentCallId =
        myCallId ?? (known != null && !known.isEmpty ? known.callId : null);
    final bool isFarewell =
        signal.type == ZenSignalType.groupCallLeave ||
        signal.type == ZenSignalType.groupCallDecline;
    if (currentCallId != null && currentCallId != callId) {
      if (callId.compareTo(currentCallId) > 0) {
        final OngoingGroupCall? myCall = state.groupCalls[groupId];
        if (myCallId != null &&
            !isFarewell &&
            myCall != null &&
            myCall.callId == myCallId) {
          // Point them at the call that stays.
          unawaitedLogged(
            _sendGroupCallPayload(
              sender,
              _groupCallPayload('group_call_state', myCall, group: group),
            ),
            context: 'redirecting $sender to the running group call',
          );
        }
        return;
      }
      if (isFarewell) {
        return;
      }
      // Theirs is older: drop ours and move over, without ever passing through
      // "no call" (the call screen would close) and keeping mute/camera.
      if (mine != null && myCallId != null) {
        await _abandonGroupCallForMigration(mine, group);
        _putGroupCall(null, groupId: groupId);
        _markGroupCallPresence(
          group: group,
          callId: callId,
          kind: kind,
          sender: sender,
          now: now,
          cameraOn: signal.cameraOn,
          reportedParticipants: signal.memberAddresses,
        );
        await _joinGroupCallNow(
          group,
          state.groupCalls[groupId]!,
          cameraOn: mine.isCameraEnabled,
          muted: mine.isMuted,
        );
      }
      final CallSession? ringing = state.activeCall;
      if (ringing != null &&
          ringing.isGroup &&
          ringing.groupId == groupId &&
          ringing.status == CallSessionStatus.ringing) {
        state = state.copyWith(activeCall: null);
        _syncCallRingingTimeout();
        await _dismissCallNotificationsFor(ringing);
      }
      if (mine == null) {
        _putGroupCall(null, groupId: groupId);
      }
    }

    switch (signal.type) {
      case ZenSignalType.groupCallLeave:
        await _handleGroupCallLeave(group, callId, sender);
        return;
      case ZenSignalType.groupCallDecline:
        final CallSession? joined = _joinedGroupCall;
        if (joined != null && joined.id == callId) {
          _groupRingDeclinedBy.add(sender);
        }
        return;
      case ZenSignalType.groupCallInvite:
      case ZenSignalType.groupCallJoin:
      case ZenSignalType.groupCallState:
      case ZenSignalType.groupCallOffer:
      case ZenSignalType.groupCallAnswer:
        break;
      default:
        return;
    }

    // The sender is in this call.
    _markGroupCallPresence(
      group: group,
      callId: callId,
      kind: kind,
      sender: sender,
      now: now,
      cameraOn: signal.cameraOn,
      reportedParticipants: signal.memberAddresses,
    );
    _ensureGroupCallTicker();

    final CallSession? joined = _joinedGroupCall;
    if (joined != null && joined.id == callId) {
      final bool changed = _syncJoinedParticipants();
      if (signal.cameraOn != null) {
        _groupMedia.setRemoteCamera(sender, signal.cameraOn!);
      }
      switch (signal.type) {
        case ZenSignalType.groupCallJoin:
          // Let the newcomer know about this participant straight away.
          unawaitedLogged(
            _sendGroupCallPayload(
              sender,
              _groupCallPayload(
                'group_call_state',
                state.groupCalls[groupId]!,
                group: group,
              ),
            ),
            context: 'greeting $sender in the group call',
          );
          // A join from someone we still hold a leg to means they came back
          // (after a crash, or a leave that got lost): that leg is dead.
          if (_groupMedia.hasLeg(sender)) {
            _groupLegStartedAt.remove(sender);
            await _groupMedia.dropPeer(sender);
          }
          _ensureGroupLegs();
        case ZenSignalType.groupCallOffer:
          final Map<String, dynamic>? description = signal.sessionDescription;
          if (description != null) {
            await _groupMedia.handleOffer(sender, description);
          }
        case ZenSignalType.groupCallAnswer:
          final Map<String, dynamic>? description = signal.sessionDescription;
          if (description != null) {
            await _groupMedia.handleAnswer(sender, description);
          }
        default:
          _ensureGroupLegs();
      }
      if (changed) {
        await _persistState();
      }
      return;
    }

    final CallSession? current = state.activeCall;
    if (current != null &&
        current.isGroup &&
        current.id == callId &&
        current.status == CallSessionStatus.ringing) {
      // A re-ring (or news about who is in) for the call already ringing.
      final List<String> participants =
          state.groupCalls[groupId]?.participantAddresses ??
          current.participantAddresses;
      if (!listEquals(participants, current.participantAddresses)) {
        state = state.copyWith(
          activeCall: current.copyWith(participantAddresses: participants),
        );
      }
      return;
    }

    if (signal.type == ZenSignalType.groupCallInvite) {
      await _ringForGroupCall(group, state.groupCalls[groupId]!);
    }
  }

  void _markGroupCallPresence({
    required GroupProfile group,
    required String callId,
    required CallInviteKind kind,
    required String sender,
    required int now,
    bool? cameraOn,
    List<String>? reportedParticipants,
  }) {
    final OngoingGroupCall? existing = state.groupCalls[group.id];
    final OngoingGroupCall base = existing != null && existing.callId == callId
        ? existing
        : OngoingGroupCall(
            groupId: group.id,
            callId: callId,
            kind: kind,
            startedAtMillis: now,
          );
    final Map<String, int> participants = Map<String, int>.from(
      base.participants,
    )..[sender] = now;
    final Set<String> departed = Set<String>.from(base.departed)
      ..remove(sender);
    for (final String raw in reportedParticipants ?? const <String>[]) {
      final String member = PeerShareCodec.normalizeAddress(raw);
      // Second-hand news only adds people nobody said were gone, and never
      // refreshes anyone: otherwise two stale lists keep each other alive.
      if (member.isEmpty ||
          _isSelfAddress(member) ||
          participants.containsKey(member) ||
          departed.contains(member) ||
          !groupHasMember(group, member)) {
        continue;
      }
      participants[member] = now;
    }
    final Set<String> camera = Set<String>.from(base.cameraOn);
    if (cameraOn == true) {
      camera.add(sender);
    } else if (cameraOn == false) {
      camera.remove(sender);
    }
    _putGroupCall(
      base.copyWith(
        kind: kind == CallInviteKind.video ? CallInviteKind.video : null,
        participants: participants,
        departed: departed,
        cameraOn: camera,
      ),
      groupId: group.id,
    );
  }

  Future<void> _handleGroupCallLeave(
    GroupProfile group,
    String callId,
    String sender,
  ) async {
    final OngoingGroupCall? call = state.groupCalls[group.id];
    if (call == null || call.callId != callId) {
      return;
    }
    _putGroupCall(
      call.copyWith(
        participants: Map<String, int>.from(call.participants)..remove(sender),
        departed: <String>{...call.departed, sender},
        cameraOn: Set<String>.from(call.cameraOn)..remove(sender),
      ),
      groupId: group.id,
    );
    final CallSession? joined = _joinedGroupCall;
    if (joined != null && joined.id == callId) {
      _groupLegStartedAt.remove(sender);
      await _groupMedia.dropPeer(sender);
      if (_syncJoinedParticipants()) {
        await _persistState();
      }
    }
    await _settleEmptyGroupCall(group.id);
  }

  /// Forgets a call nobody is in any more; a ring for it stops as missed.
  Future<void> _settleEmptyGroupCall(String groupId) async {
    final OngoingGroupCall? call = state.groupCalls[groupId];
    if (call == null || !call.isEmpty) {
      return;
    }
    final CallSession? joined = _joinedGroupCall;
    if (joined != null && joined.id == call.callId) {
      // We are still in it, just alone for now.
      return;
    }
    _putGroupCall(null, groupId: groupId);
    final CallSession? current = state.activeCall;
    if (current != null &&
        current.isGroup &&
        current.id == call.callId &&
        current.status == CallSessionStatus.ringing) {
      await _stopGroupRing(current, missed: true, tellOthers: false);
    }
  }

  // ---------------------------------------------------------------------------
  // Ringing
  // ---------------------------------------------------------------------------

  Future<void> _ringForGroupCall(
    GroupProfile group,
    OngoingGroupCall call,
  ) async {
    if (state.activeCall != null ||
        _silencedGroupCallIds.contains(call.callId)) {
      // Busy (the others see this member stays out), or already declined.
      return;
    }
    final CallSession session = CallSession(
      id: call.callId,
      peerAddress: group.id,
      displayName: group.name,
      kind: call.kind,
      status: CallSessionStatus.ringing,
      startedAtMillis: _nowMillis,
      isIncoming: true,
      isGroup: true,
      groupId: group.id,
      participantAddresses: call.participantAddresses,
      isSpeakerOn: call.kind == CallInviteKind.video,
      isCameraEnabled: call.kind == CallInviteKind.video,
    );
    state = state.copyWith(activeCall: session);
    _syncCallRingingTimeout();
    await _persistState();
    await _syncRingingCallWindow();
  }

  void _silenceGroupCall(String callId) {
    if (_silencedGroupCallIds.contains(callId)) {
      return;
    }
    _silencedGroupCallIds.add(callId);
    if (_silencedGroupCallIds.length > 32) {
      _silencedGroupCallIds.removeAt(0);
    }
  }

  /// Ends the local ring for [session] without joining.
  Future<void> _stopGroupRing(
    CallSession session, {
    required bool missed,
    required bool tellOthers,
  }) async {
    _silenceGroupCall(session.id);
    final String? groupId = session.groupId;
    final GroupProfile? group = state.groups[groupId ?? ''];
    if (tellOthers && group != null) {
      final OngoingGroupCall? call = state.groupCalls[group.id];
      final Map<String, dynamic> decline = <String, dynamic>{
        'type': 'group_call_decline',
        'groupId': group.id,
        'callId': session.id,
      };
      // Whoever is in the call keeps ringing until told otherwise.
      for (final String participant
          in call?.participantAddresses ?? session.participantAddresses) {
        unawaitedLogged(
          _sendGroupCallPayload(participant, decline),
          context: 'declining the group call of $participant',
        );
      }
    }
    if (state.activeCall?.id == session.id) {
      state = state.copyWith(activeCall: null);
    }
    _syncCallRingingTimeout();
    await _dismissCallNotificationsFor(session);
    await _syncRingingCallWindow();
    if (groupId != null) {
      await _appendGroupSystemMessage(
        groupId,
        SocialEventText(
          missed ? 'groupCall.missed' : 'groupCall.declined',
          <String, String>{'kind': session.kind.name},
        ),
      );
      if (missed && !_isUiFocused()) {
        final int now = _nowMillis;
        await _systemNotifications.show(
          RuntimeSystemNotification(
            id: 'group-call-missed-$now-$groupId',
            title: t('Nieodebrane połączenie grupowe'),
            body: t('{name}: połączenie {kind}.', {
              'name': session.displayName,
              'kind': _callKindWord(session.kind),
            }),
            createdAtMillis: now,
            routeKey: buildGroupRouteKey(
              groupId: groupId,
              title: session.displayName,
            ),
            slotKey: callNotificationSlotKey(groupId),
            category: RuntimeSystemNotificationCategory.call,
          ),
        );
      }
    }
    await _persistState();
  }

  @override
  Future<void> _declineGroupRing(CallSession session) {
    return _stopGroupRing(session, missed: false, tellOthers: true);
  }

  @override
  Future<void> _expireGroupRing(CallSession session) {
    // Fired by a timer: take a turn like everything else, and only if that
    // very ring is still going (it may have been answered in between).
    return _enqueueStateWork(() async {
      final CallSession? current = state.activeCall;
      if (current == null ||
          current.id != session.id ||
          current.status != CallSessionStatus.ringing) {
        return;
      }
      await _stopGroupRing(current, missed: true, tellOthers: true);
    });
  }

  /// Leaves [session] on the way to another call in the same group: tells
  /// the others and closes the media, but leaves `activeCall` for the join
  /// that follows to replace.
  Future<void> _abandonGroupCallForMigration(
    CallSession session,
    GroupProfile group,
  ) async {
    _groupCallReRingTimer?.cancel();
    _groupCallReRingTimer = null;
    _broadcastGroupCall(group, <String, dynamic>{
      'type': 'group_call_leave',
      'groupId': group.id,
      'callId': session.id,
    });
    _groupLegStartedAt.clear();
    _silenceGroupCall(session.id);
    await _groupMedia.close();
  }

  @override
  Future<void> _acceptGroupRing(CallSession session) async {
    final GroupProfile? group = state.groups[session.groupId ?? ''];
    if (group == null) {
      state = state.copyWith(activeCall: null);
      await _persistState();
      return;
    }
    final OngoingGroupCall call =
        state.groupCalls[group.id] ??
        OngoingGroupCall(
          groupId: group.id,
          callId: session.id,
          kind: session.kind,
          startedAtMillis: session.startedAtMillis,
          participants: <String, int>{
            for (final String p in session.participantAddresses) p: _nowMillis,
          },
        );
    await _joinGroupCallNow(group, call);
  }

  // ---------------------------------------------------------------------------
  // Joining, starting, leaving
  // ---------------------------------------------------------------------------

  /// Starts a call in [groupId], or joins the one already running there.
  Future<void> startGroupCall({
    required String groupId,
    required CallInviteKind kind,
  }) {
    return _enqueueStateWork(() async {
      final GroupProfile? group = state.groups[groupId];
      if (group == null) {
        throw FormatException(t('Nie znaleziono grupy.'));
      }
      if (group.isInvitePending) {
        throw FormatException(t('Najpierw dołącz do grupy.'));
      }
      final CallSession? current = state.activeCall;
      if (current != null) {
        if (current.isGroup &&
            current.groupId == groupId &&
            current.status != CallSessionStatus.ringing) {
          return;
        }
        throw FormatException(
          t('Zakończ aktualną rozmowę, zanim zaczniesz nową.'),
        );
      }
      final OngoingGroupCall? running = state.groupCalls[groupId];
      if (running != null && !running.isEmpty) {
        await _joinGroupCallNow(
          group,
          running,
          cameraOn: kind == CallInviteKind.video,
        );
        return;
      }
      if (_otherMembers(group).isEmpty) {
        throw FormatException(t('W grupie nie ma nikogo poza Tobą.'));
      }
      final int now = _nowMillis;
      // Unpredictable: the call id is what a group call's signals are matched
      // on, so it must not be guessable from the clock.
      final String callId =
          'gcall-$now-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
      await _joinGroupCallNow(
        group,
        OngoingGroupCall(
          groupId: groupId,
          callId: callId,
          kind: kind,
          startedAtMillis: now,
        ),
        starting: true,
      );
    });
  }

  /// Joins the call running in [groupId] (the "Dołącz" on the group screen).
  Future<void> joinGroupCall({required String groupId, bool video = false}) {
    return _enqueueStateWork(() async {
      final GroupProfile? group = state.groups[groupId];
      final OngoingGroupCall? running = state.groupCalls[groupId];
      if (group == null || running == null || running.isEmpty) {
        throw FormatException(t('To połączenie już się zakończyło.'));
      }
      final CallSession? current = state.activeCall;
      if (current != null) {
        if (current.isGroup && current.id == running.callId) {
          if (current.status == CallSessionStatus.ringing) {
            await _joinGroupCallNow(group, running, cameraOn: video);
          }
          return;
        }
        throw FormatException(t('Zakończ aktualną rozmowę, zanim dołączysz.'));
      }
      await _joinGroupCallNow(group, running, cameraOn: video);
    });
  }

  Future<void> _joinGroupCallNow(
    GroupProfile group,
    OngoingGroupCall call, {
    bool starting = false,
    bool? cameraOn,
    bool muted = false,
  }) async {
    final bool camera = cameraOn ?? call.kind == CallInviteKind.video;
    final CallSession session = CallSession(
      id: call.callId,
      peerAddress: group.id,
      displayName: group.name,
      kind: camera ? CallInviteKind.video : call.kind,
      status: CallSessionStatus.active,
      startedAtMillis: _nowMillis,
      isGroup: true,
      groupId: group.id,
      participantAddresses: call.participantAddresses,
      isSpeakerOn: camera,
      isCameraEnabled: camera,
    );
    final CallSession? ringing = state.activeCall;
    _putGroupCall(call, groupId: group.id);
    state = state.copyWith(activeCall: session);
    _syncCallRingingTimeout();
    _groupRingDeclinedBy.clear();
    _groupLegStartedAt.clear();
    _groupCallEverConnected = call.participants.isNotEmpty;
    if (ringing != null) {
      await _dismissCallNotificationsFor(ringing);
    }
    await _syncRingingCallWindow();
    try {
      await _groupMedia.start(
        callId: call.callId,
        groupId: group.id,
        localAddress: _selfAddress,
        kind: session.kind,
        cameraOn: camera,
      );
    } catch (error, stackTrace) {
      logZenError('Opening group call media failed', error, stackTrace);
      if (state.activeCall?.id == session.id) {
        state = state.copyWith(activeCall: null);
      }
      if (call.isEmpty) {
        _putGroupCall(null, groupId: group.id);
      }
      await _groupMedia.close();
      await _persistState();
      throw FormatException(
        t('Nie udało się włączyć mikrofonu. Sprawdź uprawnienia aplikacji.'),
      );
    }
    if (muted) {
      await _groupMedia.setMuted(true);
    }
    if (state.activeCall?.id == session.id) {
      state = state.copyWith(
        activeCall: session.copyWith(
          isCameraEnabled: _groupMedia.hasLocalVideo,
          isMuted: muted,
        ),
      );
    }
    await _persistState();
    _broadcastGroupCall(
      group,
      _groupCallPayload(
        starting ? 'group_call_invite' : 'group_call_join',
        call,
        group: group,
      ),
    );
    _ensureGroupLegs();
    _ensureGroupCallTicker();
    if (starting) {
      _startGroupReRing(group.id, call.callId);
    }
    await _appendGroupSystemMessage(
      group.id,
      starting
          ? SocialEventText('groupCall.started', <String, String>{
              'kind': session.kind.name,
            })
          : const SocialEventText('groupCall.joined'),
    );
  }

  @override
  Future<void> _leaveGroupCall(CallSession session) async {
    final bool othersRemain =
        (state.groupCalls[session.groupId ?? '']?.participants.isNotEmpty ??
        false);
    await _leaveJoinedGroupCall(
      session,
      note: othersRemain
          ? const SocialEventText('groupCall.left')
          : const SocialEventText('groupCall.ended'),
    );
  }

  Future<void> _leaveJoinedGroupCall(
    CallSession session, {
    required SocialEventText? note,
  }) async {
    _groupCallReRingTimer?.cancel();
    _groupCallReRingTimer = null;
    final String? groupId = session.groupId;
    final GroupProfile? group = state.groups[groupId ?? ''];
    if (group != null) {
      _broadcastGroupCall(group, <String, dynamic>{
        'type': 'group_call_leave',
        'groupId': group.id,
        'callId': session.id,
      });
    }
    _groupLegStartedAt.clear();
    await _groupMedia.close();
    if (state.activeCall?.id == session.id) {
      state = state.copyWith(activeCall: null);
    }
    if (groupId != null) {
      final OngoingGroupCall? call = state.groupCalls[groupId];
      if (call != null && call.callId == session.id && call.isEmpty) {
        _putGroupCall(null, groupId: groupId);
      }
    }
    // Leaving means not being rung back into the same call.
    _silenceGroupCall(session.id);
    await _dismissCallNotificationsFor(session);
    if (groupId != null && note != null) {
      await _appendGroupSystemMessage(groupId, note);
    }
    await _persistState();
    _ensureGroupCallTicker();
  }

  // ---------------------------------------------------------------------------
  // Legs, heartbeat, re-ring
  // ---------------------------------------------------------------------------

  /// Starts every missing leg this side is responsible for (see the mixin
  /// doc: the lower address offers).
  void _ensureGroupLegs() {
    final CallSession? joined = _joinedGroupCall;
    if (joined == null) {
      return;
    }
    final String self = _selfAddress;
    final int now = _nowMillis;
    for (final String peer in joined.participantAddresses) {
      if (self.compareTo(peer) >= 0) {
        continue;
      }
      final GroupCallLegState? leg = _groupMedia.legState(peer);
      if (leg == null || leg == GroupCallLegState.failed) {
        _groupLegStartedAt[peer] = now;
        unawaitedLogged(
          _groupMedia.connectTo(peer),
          context: 'connecting the group call to $peer',
        );
      }
    }
  }

  void _handleGroupLegState(
    String callId,
    String peer,
    GroupCallLegState legState,
  ) {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    final CallSession? joined = _joinedGroupCall;
    if (joined == null || joined.id != callId) {
      return;
    }
    switch (legState) {
      case GroupCallLegState.connected:
        _groupLegStartedAt.remove(peer);
        _groupCallEverConnected = true;
      case GroupCallLegState.failed:
        // The offering side rebuilds it on the next tick; the answering side
        // waits for that offer.
        _groupLegStartedAt.remove(peer);
      case GroupCallLegState.connecting:
        break;
    }
  }

  void _ensureGroupCallTicker() {
    final bool needed =
        _joinedGroupCall != null ||
        state.groupCalls.isNotEmpty ||
        (state.activeCall?.isGroup ?? false);
    if (!needed) {
      _groupCallTicker?.cancel();
      _groupCallTicker = null;
      return;
    }
    if (_groupCallTicker != null) {
      return;
    }
    final Duration interval = ref.read(groupCallHeartbeatIntervalProvider);
    if (interval <= Duration.zero) {
      return;
    }
    _groupCallTicker = Timer.periodic(interval, (_) {
      unawaitedLogged(
        _enqueueStateWork(tickGroupCalls),
        context: 'Group call heartbeat failed',
      );
    });
  }

  /// One heartbeat: announce ourselves, forget whoever went silent, retry
  /// stuck legs. Runs on a timer; public so tests can step it.
  @visibleForTesting
  Future<void> tickGroupCalls() async {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    final int now = _nowMillis;
    final int timeout = ref
        .read(groupCallPresenceTimeoutProvider)
        .inMilliseconds;
    final CallSession? joined = _joinedGroupCall;

    // Forget participants that went silent.
    bool changed = false;
    for (final OngoingGroupCall call in state.groupCalls.values.toList()) {
      final List<String> silent = call.participants.entries
          .where((MapEntry<String, int> e) => now - e.value > timeout)
          .map((MapEntry<String, int> e) => e.key)
          .toList(growable: false);
      if (silent.isEmpty) {
        continue;
      }
      changed = true;
      _putGroupCall(
        call.copyWith(
          participants: Map<String, int>.from(call.participants)
            ..removeWhere((String k, int _) => silent.contains(k)),
          departed: <String>{...call.departed, ...silent},
          cameraOn: Set<String>.from(call.cameraOn)..removeAll(silent),
        ),
        groupId: call.groupId,
      );
      if (joined != null && joined.id == call.callId) {
        for (final String peer in silent) {
          _groupLegStartedAt.remove(peer);
          await _groupMedia.dropPeer(peer);
        }
      }
      await _settleEmptyGroupCall(call.groupId);
    }
    if (changed && _syncJoinedParticipants()) {
      await _persistState();
    }

    final CallSession? stillJoined = _joinedGroupCall;
    if (stillJoined != null) {
      final GroupProfile? group = state.groups[stillJoined.groupId ?? ''];
      final OngoingGroupCall? call =
          state.groupCalls[stillJoined.groupId ?? ''];
      if (group != null && call != null && call.callId == stillJoined.id) {
        _broadcastGroupCall(
          group,
          _groupCallPayload('group_call_state', call, group: group),
        );
      }
      // Stuck legs: repeat the offer, and rebuild one that is hopeless.
      final String self = _selfAddress;
      for (final String peer in stillJoined.participantAddresses) {
        if (self.compareTo(peer) >= 0) {
          continue;
        }
        final GroupCallLegState? leg = _groupMedia.legState(peer);
        final int? since = _groupLegStartedAt[peer];
        if (leg == GroupCallLegState.connecting && since != null) {
          if (now - since > timeout) {
            await _groupMedia.dropPeer(peer);
            _groupLegStartedAt.remove(peer);
          } else {
            unawaitedLogged(
              _groupMedia.resendOffer(peer),
              context: 'repeating the group call offer to $peer',
            );
          }
        }
      }
      _ensureGroupLegs();
    }
    _ensureGroupCallTicker();
  }

  void _startGroupReRing(String groupId, String callId) {
    _groupCallReRingTimer?.cancel();
    _groupCallRingStartedAt = _nowMillis;
    final Duration interval = ref.read(groupCallReRingIntervalProvider);
    if (interval <= Duration.zero) {
      return;
    }
    _groupCallReRingTimer = Timer.periodic(interval, (_) {
      unawaitedLogged(
        _enqueueStateWork(() => reRingGroupCall(callId)),
        context: 'Group call re-ring failed',
      );
    });
  }

  /// Rings the members still outside the call again; ends a call nobody
  /// joined once the ringing window is over. Public so tests can step it.
  @visibleForTesting
  Future<void> reRingGroupCall(String callId) async {
    final CallSession? joined = _joinedGroupCall;
    if (joined == null || joined.id != callId) {
      _groupCallReRingTimer?.cancel();
      _groupCallReRingTimer = null;
      return;
    }
    final GroupProfile? group = state.groups[joined.groupId ?? ''];
    final OngoingGroupCall? call = state.groupCalls[joined.groupId ?? ''];
    if (group == null || call == null) {
      return;
    }
    final Duration window = ref.read(groupCallRingWindowProvider);
    if (_nowMillis - _groupCallRingStartedAt >= window.inMilliseconds) {
      _groupCallReRingTimer?.cancel();
      _groupCallReRingTimer = null;
      if (!_groupCallEverConnected && call.isEmpty) {
        await _leaveJoinedGroupCall(
          joined,
          note: const SocialEventText('groupCall.nobody'),
        );
      }
      return;
    }
    final Map<String, dynamic> invite = _groupCallPayload(
      'group_call_invite',
      call,
      group: group,
    );
    _broadcastGroupCall(
      group,
      invite,
      where: (String member) =>
          !call.participants.containsKey(member) &&
          !_groupRingDeclinedBy.contains(member),
    );
  }

  /// Tells the group about a change of this participant (camera on/off).
  Future<void> _announceGroupCallState() async {
    final CallSession? joined = _joinedGroupCall;
    if (joined == null) {
      return;
    }
    final GroupProfile? group = state.groups[joined.groupId ?? ''];
    final OngoingGroupCall? call = state.groupCalls[joined.groupId ?? ''];
    if (group == null || call == null || call.callId != joined.id) {
      return;
    }
    _broadcastGroupCall(
      group,
      _groupCallPayload('group_call_state', call, group: group),
    );
  }

  @override
  Future<void> _toggleGroupCall(GroupCallToggle toggle) {
    // Queued, and the session re-read after every await: a toggle racing a
    // leave (or a move to another call) must not bring the old call back.
    return _enqueueStateWork(() async {
      final CallSession? session = _joinedGroupCall;
      if (session == null) {
        return;
      }
      switch (toggle) {
        case GroupCallToggle.mute:
          await _groupMedia.setMuted(!session.isMuted);
        case GroupCallToggle.speaker:
          await _groupMedia.setSpeakerOn(!session.isSpeakerOn);
        case GroupCallToggle.camera:
          await _groupMedia.setCameraEnabled(!session.isCameraEnabled);
      }
      final CallSession? current = _joinedGroupCall;
      if (current == null || current.id != session.id) {
        return;
      }
      state = state.copyWith(
        activeCall: switch (toggle) {
          GroupCallToggle.mute => current.copyWith(isMuted: !session.isMuted),
          GroupCallToggle.speaker => current.copyWith(
            isSpeakerOn: !session.isSpeakerOn,
          ),
          GroupCallToggle.camera => current.copyWith(
            isCameraEnabled: _groupMedia.hasLocalVideo,
          ),
        },
      );
      if (toggle == GroupCallToggle.camera) {
        await _announceGroupCallState();
      }
      await _persistState();
    });
  }

  /// The user left (or was removed from) [groupId]: its call goes with it.
  @override
  Future<void> _dropGroupCallsFor(String groupId) async {
    final CallSession? current = state.activeCall;
    if (current != null && current.isGroup && current.groupId == groupId) {
      if (current.status == CallSessionStatus.ringing) {
        await _stopGroupRing(current, missed: false, tellOthers: true);
      } else {
        await _leaveJoinedGroupCall(current, note: null);
      }
    }
    if (state.groupCalls.containsKey(groupId)) {
      _putGroupCall(null, groupId: groupId);
    }
    _ensureGroupCallTicker();
  }

  Future<void> _appendGroupSystemMessage(
    String groupId,
    SocialEventText event,
  ) async {
    final int now = _nowMillis;
    final String text = event.render();
    await _messageTimelineStore.append(
      'group:$groupId',
      chatMessageWithEvent(
        ChatMessage(
          id: 'grp-sys-$now-${text.hashCode}',
          sender: 'system',
          text: text,
          sentAtMillis: now,
          direction: ChatMessageDirection.system,
        ),
        event,
      ),
    );
    _bumpTimelineRevision();
  }
}
