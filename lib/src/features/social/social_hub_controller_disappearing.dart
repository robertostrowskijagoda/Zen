part of 'social_hub_controller.dart';

/// Disappearing messages: a per-conversation timer, the
/// same on both sides, after which messages are deleted with their files.
///
/// * changing the timer tells the friend (or every group member) and this
///   account's other devices;
/// * every message carries the sender's timer, so a missed change catches
///   up with the next message;
/// * expiry is stamped as the message is stored here (see
///   [DisappearingTimelineStore]) and one timer sweeps at the next expiry;
/// * such messages never go into the ledger's lasting copies or history
///   bundles (see `DeviceChatSync`).
mixin _SocialHubDisappearingMixin on _SocialHubControllerBase {
  @override
  int _disappearSecondsFor(String key) =>
      ref.mounted ? state.disappearSecondsFor(key) : 0;

  /// The canonical key of [key]: a friend's stored address, or `group:<id>`.
  String _disappearKey(String key) {
    if (key.startsWith('group:')) {
      return key;
    }
    return state.friendByAddress(key)?.address ??
        PeerShareCodec.normalizeAddress(key);
  }

  /// Sets the timer of conversation [key] (a friend's address or
  /// `group:<id>`) to [seconds] (0 = off) and tells everyone concerned.
  Future<void> setDisappearingTimer(String key, int seconds) async {
    final int value = seconds <= 0 ? 0 : seconds;
    final String canonical = _disappearKey(key);
    final int now = DateTime.now().millisecondsSinceEpoch;
    bool changed = false;
    await _enqueueStateWork(() async {
      changed = await _storeDisappearTimer(
        canonical,
        value,
        note: value == 0
            ? t('Wyłączono znikające wiadomości.')
            : t('Włączono znikające wiadomości: {duration}.', {
                'duration': disappearLabel(value),
              }),
        timestamp: now,
      );
    });
    if (!changed) {
      return;
    }
    final Map<String, dynamic> payload = <String, dynamic>{
      'type': 'disappear_timer',
      'seconds': value,
      'at': now,
    };
    if (canonical.startsWith('group:')) {
      final String groupId = canonical.substring(6);
      final GroupProfile? group = state.groups[groupId];
      if (group == null) {
        return;
      }
      payload['groupId'] = groupId;
      final String localAddr = ref
          .read(runtimeNodeSnapshotProvider)
          .localAddress;
      for (final String member in normalizedGroupMembers(
        group.memberAddresses,
      )) {
        if (localAddr.isNotEmpty &&
            PeerShareCodec.addressesEqual(member, localAddr)) {
          continue;
        }
        unawaitedLogged(
          _sendFriendLifecycleSignal(
            peerAddress: member,
            payload: Map<String, dynamic>.of(payload),
          ),
          context: 'send disappearing timer to $member',
        );
      }
      return;
    }
    await _sendFriendLifecycleSignal(peerAddress: canonical, payload: payload);
  }

  /// Stores the timer; `true` when it changed. Runs inside the state queue.
  Future<bool> _storeDisappearTimer(
    String key,
    int seconds, {
    required String note,
    required int timestamp,
  }) async {
    if (state.disappearSecondsFor(key) == seconds) {
      return false;
    }
    final Map<String, int> timers =
        Map<String, int>.of(state.disappearingTimers)..removeWhere(
          (String k, int _) =>
              k == key ||
              (!key.startsWith('group:') &&
                  !k.startsWith('group:') &&
                  PeerShareCodec.addressesEqual(k, key)),
        );
    // Kept at 0 when switched off: messages stamped earlier still expire,
    // and the sweep knows to look here.
    timers[key] = seconds;
    state = state.copyWith(disappearingTimers: timers);
    await _persistState();
    await _appendSystemMessage(
      peerAddress: key,
      text: note,
      timestamp: timestamp,
    );
    return true;
  }

  /// The conversation key a signal from [signal.sender] belongs to, when
  /// the sender may set its timer: a friend, or a member of a joined group.
  String? _disappearKeyForSignal(ZenSignal signal) {
    final String? groupId = signal.groupId;
    if (groupId != null && groupId.isNotEmpty) {
      final GroupProfile? group = state.groups[groupId];
      if (group == null ||
          group.isInvitePending ||
          !(groupHasMember(group, signal.sender) ||
              PeerShareCodec.addressesEqual(
                group.createdById,
                signal.sender,
              ))) {
        return null;
      }
      return 'group:$groupId';
    }
    final FriendProfile? friend = state.friendByAddress(signal.sender);
    if (friend == null || friend.status != FriendRelationshipStatus.accepted) {
      return null;
    }
    return friend.address;
  }

  @override
  Future<void> _handleDisappearTimer(ZenSignal signal, int timestamp) async {
    final String? key = _disappearKeyForSignal(signal);
    if (key == null) {
      return;
    }
    final int seconds = sanitizeDisappearSeconds(signal.disappearSeconds);
    final String who = key.startsWith('group:')
        ? (_groupMemberLabel(key.substring(6), signal.sender))
        : _labelFor(signal, friends: state.friends);
    await _storeDisappearTimer(
      key,
      seconds,
      note: seconds == 0
          ? t('{name} wyłączył(a) znikające wiadomości.', {'name': who})
          : t('{name} włączył(a) znikające wiadomości: {duration}.', {
              'name': who,
              'duration': disappearLabel(seconds),
            }),
      timestamp: timestamp,
    );
  }

  /// A message arrived with the sender's timer: a change missed earlier
  /// catches up here (only switching on or changing — "off" travels with
  /// the timer signal, so an old message cannot switch it off).
  @override
  Future<void> _adoptDisappearTimerOf(ZenSignal signal, int timestamp) async {
    final int seconds = sanitizeDisappearSeconds(signal.disappearSeconds);
    if (seconds <= 0) {
      return;
    }
    final String? key = _disappearKeyForSignal(signal);
    if (key == null || state.disappearSecondsFor(key) == seconds) {
      return;
    }
    await _handleDisappearTimer(signal, timestamp);
  }

  String _groupMemberLabel(String groupId, String address) {
    final GroupProfile? group = state.groups[groupId];
    final String? named = group?.memberNames.entries
        .where(
          (MapEntry<String, String> e) =>
              PeerShareCodec.addressesEqual(e.key, address),
        )
        .map((MapEntry<String, String> e) => e.value)
        .firstOrNull;
    if (named != null && named.trim().isNotEmpty) {
      return named.trim();
    }
    final FriendProfile? friend = state.friendByAddress(address);
    return friend != null ? state.nameFor(friend) : t('Ktoś z grupy');
  }

  /// Another device of this account changed a timer: same here, quietly
  /// (it told the friend already).
  @override
  Future<void> _applyMirroredDisappearTimer(
    String peerAddress,
    Map<String, dynamic> payload,
  ) async {
    final Object? groupId = payload['groupId'];
    final String key;
    if (groupId is String && groupId.isNotEmpty) {
      if (!state.groups.containsKey(groupId)) {
        return;
      }
      key = 'group:$groupId';
    } else {
      final FriendProfile? friend = state.friendByAddress(peerAddress);
      if (friend == null) {
        return;
      }
      key = friend.address;
    }
    final int seconds = sanitizeDisappearSeconds(payload['seconds']);
    await _enqueueStateWork(() async {
      await _storeDisappearTimer(
        key,
        seconds,
        note: seconds == 0
            ? t('Wyłączono znikające wiadomości (na innym urządzeniu).')
            : t(
                'Włączono znikające wiadomości: {duration} '
                '(na innym urządzeniu).',
                {'duration': disappearLabel(seconds)},
              ),
        timestamp: DateTime.now().millisecondsSinceEpoch,
      );
    });
  }

  /// Every conversation that ever had a timer (only those can hold
  /// disappearing messages).
  Iterable<String> _disappearingKeys() =>
      List<String>.of(state.disappearingTimers.keys);

  /// Whether [signal] is a chat message that already disappeared here (a
  /// mailbox handing it over late, a retry from the sender): such a copy
  /// would come back with a new clock, be announced and counted unread
  /// again. It is dropped; a friend's message is still acknowledged, so
  /// the sender (and its mailboxes) stop sending it.
  @override
  Future<bool> _dropDisappearedCopy(ZenSignal signal) async {
    final String key;
    final String id;
    if (signal.type == ZenSignalType.message) {
      key = _disappearKey(signal.sender);
      id = _incomingMessageIdOf(signal);
    } else if (signal.type == ZenSignalType.groupMessage &&
        (signal.groupId?.isNotEmpty ?? false) &&
        (signal.messageId?.isNotEmpty ?? false)) {
      key = 'group:${signal.groupId}';
      id = signal.messageId!;
    } else {
      return false;
    }
    if (!state.disappearedMessages.containsKey(
      disappearedMessageKey(key, id),
    )) {
      // Expired but not swept yet (only conversations that ever had a
      // timer can hold such messages).
      final bool hadTimer =
          state.disappearingTimers.containsKey(key) ||
          state.disappearSecondsFor(key) > 0;
      if (!hadTimer || !await _disappearingStore.holdsExpired(key, id)) {
        return false;
      }
    }
    final String? ownId = signal.messageId?.trim();
    if (signal.type == ZenSignalType.message &&
        ownId != null &&
        ownId.isNotEmpty) {
      unawaitedLogged(
        _sendMessageAck(peerAddress: signal.sender, messageId: ownId),
        context: 'Acknowledging a disappeared message',
      );
    }
    return true;
  }

  /// True while a sweep runs: it saves what it remembered once, at the end.
  bool _sweepingDisappeared = false;

  @override
  Future<void> _onMessageExpired(String key, ChatMessage message) async {
    if (ref.mounted) {
      final int now = DateTime.now().millisecondsSinceEpoch;
      state = state.copyWith(
        disappearedMessages: rememberDisappeared(
          state.disappearedMessages,
          key: key,
          id: message.id,
          expiredAtMillis: message.expiresAtMillis ?? now,
          nowMillis: now,
        ),
      );
      if (!_sweepingDisappeared) {
        unawaitedLogged(
          _persistState(),
          context: 'Saving a disappeared message',
        );
      }
    }
    await _deleteManagedAttachmentIfPresent(message);
    if (!key.startsWith('group:')) {
      await _transferStore.deleteIncoming(key, message.id);
      await _transferStore.deleteOutgoing(key, message.id);
    }
  }

  /// Deletes what expired and waits for the next one.
  @override
  Future<void> sweepDisappearingMessages() async {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    final DisappearingTimelineStore store = _disappearingStore;
    final int removed;
    _sweepingDisappeared = true;
    try {
      removed = await store.sweep(_disappearingKeys());
    } finally {
      _sweepingDisappeared = false;
    }
    if (!ref.mounted) {
      return;
    }
    if (removed > 0) {
      // What disappeared is remembered (see `_dropDisappearedCopy`).
      await _persistState();
      _bumpTimelineRevision();
      for (final String key in _disappearingKeys()) {
        if (!key.startsWith('group:')) {
          final List<ChatMessage> thread = await store.load(key);
          if (!ref.mounted) {
            return;
          }
          _refreshPreviewAfterSweep(key, thread);
        }
      }
    }
    await _scheduleDisappearSweep();
  }

  void _refreshPreviewAfterSweep(String key, List<ChatMessage> thread) {
    final FriendProfile? friend = state.friendByAddress(key);
    if (friend == null) {
      return;
    }
    final String preview = thread.isEmpty
        ? ''
        : chatPreviewLine(
            thread.last.text,
            type: thread.last.type,
            fileName: thread.last.fileName,
            mimeType: thread.last.mimeType,
          );
    if (friend.lastMessagePreview == preview) {
      return;
    }
    final Map<String, FriendProfile> friends = Map<String, FriendProfile>.of(
      state.friends,
    );
    friends[friend.address] = friend.copyWith(lastMessagePreview: preview);
    state = state.copyWith(friends: friends);
  }

  Future<void> _scheduleDisappearSweep() async {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    if (state.disappearingTimers.isEmpty) {
      return;
    }
    final int? next = await _disappearingStore.nextExpiry(_disappearingKeys());
    _disappearTimer?.cancel();
    _disappearTimer = null;
    _disappearAt = null;
    if (next != null) {
      _noteExpiry(next);
    }
  }

  @override
  void _noteExpiry(int atMillis) {
    if (_controllerDisposed || !ref.mounted) {
      return;
    }
    final int? planned = _disappearAt;
    if (_disappearTimer != null && planned != null && planned <= atMillis) {
      return;
    }
    _disappearTimer?.cancel();
    _disappearAt = atMillis;
    final int wait = atMillis - DateTime.now().millisecondsSinceEpoch;
    _disappearTimer = Timer(
      Duration(milliseconds: wait.clamp(250, 6 * 3600 * 1000)),
      () {
        _disappearTimer = null;
        _disappearAt = null;
        unawaitedLogged(
          sweepDisappearingMessages(),
          context: 'Usuwanie znikających wiadomości',
        );
      },
    );
  }
}
