part of 'social_hub_controller.dart';

/// Several devices of one account: what another own device sent, and
/// the backup of friends and groups the account's devices share.
mixin _SocialHubDevicesMixin on _SocialHubControllerBase {
  /// The device key [address] signed is not the one its session uses (or
  /// two signed sources name different keys): someone else may hold that
  /// address's node key. Shown in the conversation with that friend.
  Future<void> warnDeviceKeyMismatch(String address) async {
    final FriendProfile? friend = state.friendByAddress(address);
    if (friend == null) {
      return;
    }
    await _appendSystemMessage(
      peerAddress: friend.address,
      text: t(
        'Klucz urządzenia się nie zgadza. Ktoś inny może podszywać się '
        'pod ten adres; jego wiadomości są odrzucane. Zanim przekażesz coś '
        'ważnego, sprawdź to z tą osobą inną drogą.',
      ),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// The friend at [address] unlinked that device (lost or stolen): it is
  /// said in the conversation with them. Nothing goes there any more; the
  /// friend's other devices get the messages.
  Future<void> warnDeviceUnlinked(String address) async {
    final FriendProfile? friend = state.friendByAddress(address);
    if (friend == null) {
      return;
    }
    await _appendSystemMessage(
      peerAddress: friend.address,
      text: t(
        'Ta osoba odłączyła to urządzenie (zgubione lub skradzione). '
        'Nic stamtąd nie jest przyjmowane i nic tam nie wysyłamy. Wiadomości '
        'trafiają na jej pozostałe urządzenia; jeśli żadnego nie ma, dodaj '
        'ją ponownie.',
      ),
      timestamp: DateTime.now().millisecondsSinceEpoch,
    );
  }

  /// Another device of this account sent [payload] to [peerAddress]: show
  /// it in the conversation here too.
  Future<void> recordMirroredSend(
    String peerAddress,
    Map<String, dynamic> payload,
  ) async {
    final Object? type = payload['type'];
    if (type == 'disappear_timer') {
      await _applyMirroredDisappearTimer(peerAddress, payload);
      return;
    }
    if (type == 'group_message') {
      await _recordMirroredGroupMessage(payload);
      return;
    }
    if (type == 'msg_react' || type == 'msg_edit' || type == 'msg_delete') {
      // A reaction, edit or deletion made on another device.
      await _applyMirroredChatChange(peerAddress, payload);
      return;
    }
    if (type != 'message') {
      return;
    }
    final Object? id = payload['msgId'];
    final Object? text = payload['text'];
    if (id is! String || text is! String || text.trim().isEmpty) {
      return;
    }
    final FriendProfile? friend = state.friendByAddress(peerAddress);
    if (friend == null) {
      return;
    }
    final String peer = friend.address;
    if (sanitizeDisappearSeconds(payload['ttl']) > 0) {
      await _applyMirroredDisappearTimer(peer, <String, dynamic>{
        'seconds': payload['ttl'],
      });
    }
    final int sentAt =
        DateTime.tryParse('${payload['createdAt']}')?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    await _enqueueStateWork(() async {
      await _upsertTimelineMessage(
        peerAddress: peer,
        messageId: id,
        build: (ChatMessage? existing) =>
            existing ??
            ChatMessage(
              id: id,
              sender: 'self',
              text: text.trim(),
              sentAtMillis: sentAt,
              direction: ChatMessageDirection.outgoing,
              deliveryState: ChatMessageDeliveryState.sent,
              reply: ChatReply.fromJson(payload['re']),
              forwarded: payload['fwd'] == true,
            ),
      );
      _updateFriendPreview(peerAddress: peer, preview: text.trim());
    });
  }

  /// A disappearing group message another device of this account sent
  /// (lasting ones come through the ledger's copies instead).
  Future<void> _recordMirroredGroupMessage(Map<String, dynamic> payload) async {
    final Object? groupId = payload['groupId'];
    final Object? id = payload['msgId'];
    final Object? text = payload['text'];
    if (groupId is! String ||
        id is! String ||
        text is! String ||
        text.trim().isEmpty ||
        !state.groups.containsKey(groupId)) {
      return;
    }
    final String key = 'group:$groupId';
    if (sanitizeDisappearSeconds(payload['ttl']) > 0) {
      await _applyMirroredDisappearTimer(key, <String, dynamic>{
        'groupId': groupId,
        'seconds': payload['ttl'],
      });
    }
    final Object? at = payload['timestamp'];
    final int sentAt = at is int ? at : DateTime.now().millisecondsSinceEpoch;
    await _enqueueStateWork(() async {
      await _upsertTimelineMessage(
        peerAddress: key,
        messageId: id,
        build: (ChatMessage? existing) =>
            existing ??
            ChatMessage(
              id: id,
              sender: 'self',
              text: text.trim(),
              sentAtMillis: sentAt,
              direction: ChatMessageDirection.outgoing,
              deliveryState: ChatMessageDeliveryState.delivered,
              mentions: mentionsFromJson(payload[kMentionsKey]),
            ),
      );
    });
  }

  /// Another device of this account removed [address] as a friend at
  /// [atMillis] (it already told them): drop them here too, quietly, and
  /// remember it — unless the friendship was made again since (newer
  /// wins). [atMillis] 0: now.
  Future<void> forgetFriendFromOtherDevice(
    String address, {
    int atMillis = 0,
  }) async {
    final int at = atMillis > 0
        ? atMillis
        : DateTime.now().millisecondsSinceEpoch;
    await _enqueueStateWork(() async {
      final String key = PeerShareCodec.normalizeAddress(address);
      if ((state.friendsSince[key] ?? 0) > at) {
        // Made friends again after that removal.
        return;
      }
      final FriendProfile? have = state.friendByAddress(address);
      final SocialHubState before = state;
      if (have != null && have.status != FriendRelationshipStatus.blocked) {
        final Map<String, FriendProfile> friends =
            Map<String, FriendProfile>.of(state.friends);
        _removeFriend(friends, have.address);
        state = state.copyWith(friends: friends);
        await _dropQueuedSignalsFrom(key);
      }
      state = withFriendRemovedAt(state, key, at);
      if (!identical(state, before)) {
        await _persistState();
      }
    });
  }

  /// Another device of this account left group [groupId]: leave it here too
  /// (the members were told already).
  Future<void> forgetGroupFromOtherDevice(String groupId) async {
    if (!state.groups.containsKey(groupId)) {
      return;
    }
    await _dropGroupCallsFor(groupId);
    await _enqueueStateWork(() async {
      if (!state.groups.containsKey(groupId)) {
        return;
      }
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.of(
        state.groups,
      )..remove(groupId);
      state = state.copyWith(groups: groups);
      await _persistState();
    });
  }

  /// Conversation keys this device has (friends, and `group:<id>`).
  List<String> conversationKeys() => <String>[
    for (final FriendProfile f in state.friends.values)
      if (f.status == FriendRelationshipStatus.accepted) f.address,
    for (final String id in state.groups.keys) 'group:$id',
  ];

  /// The messages of conversation [key] (for another device of the
  /// account).
  Future<List<ChatMessage>> conversationMessages(String key) =>
      _messageTimelineStore.load(key);

  /// A message from another device of this account (a copy of what it sent,
  /// or its history) or from a copy of the account: added to conversation
  /// [key] by its send time unless already there, with its file when
  /// [bytes] are given — or [storedPath], a file of the media vault written
  /// piece by piece (deleted here when not needed).
  ///
  /// Never counted as unread and never announced: it is history, not news.
  /// A message here without its file takes [message]'s word on whether the
  /// file can still come ([ChatMessage.attachmentUnavailable]).
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
    String? storedPath,
  }) async {
    if (!key.startsWith('group:') &&
        state.friendByAddress(key) == null &&
        state.removedFriendAt(key) != null) {
      // The conversation with a removed friend was cleared here; another
      // device's older copy of it does not come back.
      if (storedPath != null && isMediaVaultPath(storedPath)) {
        await _mediaVault.delete(storedPath);
      }
      return;
    }
    StoredAttachment? stored;
    if (storedPath != null && isMediaVaultPath(storedPath)) {
      stored = StoredAttachment(
        path: storedPath,
        type: message.type,
        mimeType: message.mimeType ?? 'application/octet-stream',
        fileName: message.fileName ?? 'zalacznik-${message.type.name}',
        sizeBytes: message.attachmentSizeBytes ?? 0,
      );
    } else if (bytes != null && bytes.isNotEmpty) {
      stored = await _persistIncomingAttachmentFile(
        peerAddress: key,
        messageId: message.id,
        bytes: bytes,
        type: message.type,
        mimeType: message.mimeType,
        fileName: message.fileName,
      );
    }
    ChatMessage withFile(ChatMessage m) => stored == null
        ? m
        : m.copyWith(
            type: m.type == ChatMessageType.text ? m.type : stored.type,
            attachmentPath: stored.path,
            attachmentBytes: null,
            fileName: stored.fileName,
            mimeType: stored.mimeType,
            attachmentUnavailable: false,
          );
    bool unused = false;
    await _enqueueStateWork(() async {
      await _upsertTimelineMessage(
        peerAddress: key,
        messageId: message.id,
        // Recovered or older history goes before what came since.
        byTime: true,
        build: (ChatMessage? existing) {
          if (existing == null) {
            return withFile(message.copyWith(attachmentBytes: null));
          }
          // Only fill in a file that was missing here.
          final bool missing =
              (existing.attachmentPath == null ||
                  existing.attachmentPath!.isEmpty) &&
              existing.attachmentBytes == null;
          if (stored != null && missing) {
            return withFile(existing);
          }
          unused = stored != null;
          if (missing &&
              existing.type != ChatMessageType.text &&
              existing.attachmentUnavailable != message.attachmentUnavailable) {
            return existing.copyWith(
              attachmentUnavailable: message.attachmentUnavailable,
            );
          }
          return existing;
        },
      );
    });
    if (unused && storedPath != null) {
      await _mediaVault.delete(storedPath);
    }
  }

  /// Friends and groups, for the account's other devices (sealed by the
  /// ledger: only own devices can read it).
  Map<String, dynamic> contactsBackup() => contactsBackupOf(state);

  /// Adds what [backup] has and this device does not (a new or recovered
  /// device gets its friends and groups back). Returns how many friends
  /// and groups were added.
  ///
  /// The backup is the newest one any device saved, so names and blocks in
  /// it win too. [removedAt] holds when friends (address) and groups
  /// (`group:id`) were removed on some device; a group is not brought back
  /// unless the backup is newer ([backupAt]) — added again since.
  ///
  /// Friends go by each one's own times, never by the backup's: a device
  /// that still lists a removed friend (it saved before it heard of the
  /// removal, or saves for some other change) does not bring them back. A
  /// friend removed anywhere ([removedAt], the backup's own removals `x`,
  /// [SocialHubState.removedFriends]) comes back only with a friendship
  /// made after that removal (the backup's `s`, see
  /// [SocialHubState.friendsSince]); a removal newer than a friendship
  /// this device knows the time of removes that friend here.
  Future<int> importContactsBackup(
    Map<String, dynamic> backup, {
    Map<String, int> removedAt = const <String, int>{},
    int backupAt = 0,
  }) async {
    if (backup['v'] != 1) {
      if (formatAgeOf(backup['v'], current: 1) == FormatAge.newer) {
        // Saved by a newer Zen on another device of the account.
        ZenFormatGuard.instance.noteNewer('account/contacts');
      }
      return 0;
    }
    bool removedSince(String key) => (removedAt[key] ?? -1) >= backupAt;
    // Removals of friends this backup and the ledger know of.
    final Map<String, int> removals = <String, int>{};
    void noteRemoval(Object? address, Object? at) {
      if (address is! String || at is! int || at <= 0) {
        return;
      }
      if (address.startsWith('group:') || !isRoutablePeerAddress(address)) {
        return;
      }
      final String key = PeerShareCodec.normalizeAddress(address);
      if ((removals[key] ?? -1) < at) {
        removals[key] = at;
      }
    }

    removedAt.forEach(noteRemoval);
    final Object? x = backup['x'];
    if (x is Map) {
      for (final MapEntry<dynamic, dynamic> e in x.entries.take(
        kMaxRemovedFriends,
      )) {
        noteRemoval(e.key, e.value);
      }
    }
    int added = 0;
    await _enqueueStateWork(() async {
      final SocialHubState before = state;
      SocialHubState next = state;
      final Map<String, FriendProfile> friends = Map<String, FriendProfile>.of(
        state.friends,
      );
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.of(
        state.groups,
      );
      // Removals first: newer wins against the friendships known here.
      removals.forEach((String address, int at) {
        final FriendProfile? have = _friendFromMap(friends, address);
        final int since = next.friendsSince[address] ?? 0;
        if (since > at) {
          return;
        }
        if (have != null && have.status != FriendRelationshipStatus.blocked) {
          if (since == 0) {
            // A friendship from before its time was kept: only the
            // removal's own entry takes it away (applied once, see
            // DeviceChatSync), never an old one read again here.
            return;
          }
          _removeFriend(friends, address);
        }
        next = withFriendRemovedAt(next, address, at);
      });
      final Object? fs = backup['friends'];
      if (fs is List) {
        for (final Object? item in fs.take(5000)) {
          if (item is! Map) {
            continue;
          }
          final Object? a = item['a'];
          if (a is! String || !isRoutablePeerAddress(a)) {
            continue;
          }
          final String address = PeerShareCodec.normalizeAddress(a);
          final Object? rawName = item['n'];
          final String? n = rawName is String
              ? sanitizePeerName(rawName)
              : null;
          final Object? rawNickname = item['k'];
          final String k = rawNickname is String
              ? sanitizeFriendNickname(rawNickname)
              : '';
          final Object? rawSince = item['s'];
          final int since = rawSince is int && rawSince > 0 ? rawSince : 0;
          final FriendProfile? have = _friendFromMap(friends, address);
          if (have != null &&
              have.status == FriendRelationshipStatus.accepted &&
              since > (next.friendsSince[address] ?? 0)) {
            next = withFriendshipSince(next, address, since);
          }
          if (have != null) {
            // A newer name, a nickname given or (un)blocked on another
            // device.
            final FriendRelationshipStatus status = item['b'] == 1
                ? FriendRelationshipStatus.blocked
                : FriendRelationshipStatus.accepted;
            final bool settled =
                have.status == FriendRelationshipStatus.accepted ||
                have.status == FriendRelationshipStatus.blocked;
            if (settled &&
                ((n != null && n.isNotEmpty && n != have.displayName) ||
                    k != have.nickname ||
                    status != have.status)) {
              friends[have.address] = have.copyWith(
                displayName: n != null && n.isNotEmpty ? n : have.displayName,
                nickname: k,
                status: status,
              );
              added++;
            }
            continue;
          }
          final int? removed = next.removedFriendAt(address);
          if (removed != null && since <= removed) {
            // Removed after (or without a known) friendship in this copy:
            // a device that still lists them does not bring them back.
            continue;
          }
          if (since > 0) {
            next = withFriendshipSince(next, address, since);
          }
          friends[address] = FriendProfile(
            address: address,
            displayName: n ?? '',
            nickname: k,
            status: item['b'] == 1
                ? FriendRelationshipStatus.blocked
                : FriendRelationshipStatus.accepted,
          );
          added++;
        }
      }
      final Object? gs = backup['groups'];
      if (gs is List) {
        for (final Object? item in gs.take(1000)) {
          if (item is! Map) {
            continue;
          }
          final Object? id = item['id'];
          final Object? name = item['name'];
          final Object? members = item['m'];
          if (id is! String ||
              name is! String ||
              members is! List ||
              groups.containsKey(id) ||
              removedSince('group:$id')) {
            continue;
          }
          final Object? names = item['mn'];
          groups[id] = GroupProfile(
            id: id,
            name: name,
            description: item['d'] is String ? item['d'] as String : '',
            avatarPreset: item['avatar'] is String
                ? item['avatar'] as String
                : 'group_default',
            createdById: item['by'] is String ? item['by'] as String : '',
            createdAtMillis: item['at'] is int ? item['at'] as int : 0,
            memberAddresses: members.whereType<String>().toList(),
            memberNames: names is Map
                ? <String, String>{
                    for (final MapEntry<dynamic, dynamic> e in names.entries)
                      if (e.key is String && e.value is String)
                        e.key as String: e.value as String,
                  }
                : const <String, String>{},
          );
          added++;
        }
      }
      if (added == 0 &&
          identical(next, before) &&
          friends.length == before.friends.length) {
        return;
      }
      for (final String address in removals.keys) {
        if (_friendFromMap(friends, address) == null &&
            before.friendByAddress(address) != null) {
          await _dropQueuedSignalsFrom(address);
        }
      }
      state = next.copyWith(
        friends: friends,
        groups: groups,
        pendingSignalCount: state.pendingSignalCount,
      );
      await _persistState();
    });
    return added;
  }
}

// ---- (top level) ----

/// Friends and groups of [state], as the account's devices share them:
/// with when each friendship was made (`s`, when known) and the friends
/// removed since theirs (`x`: address → when), so the devices agree on
/// who is a friend friend by friend, the newer of the two winning.
/// (Zen 1.14.0 and older read `friends` and `groups` only.)
Map<String, dynamic> contactsBackupOf(
  SocialHubState state,
) => <String, dynamic>{
  'v': 1,
  'friends':
      <Map<String, dynamic>>[
        for (final FriendProfile f in state.friends.values)
          if (f.status == FriendRelationshipStatus.accepted ||
              f.status == FriendRelationshipStatus.blocked)
            <String, dynamic>{
              'a': PeerShareCodec.normalizeAddress(f.address),
              if (f.hasProfileName) 'n': f.displayName,
              if (f.hasNickname) 'k': f.nickname,
              if (f.status == FriendRelationshipStatus.blocked) 'b': 1,
              's': ?state
                  .friendsSince[PeerShareCodec.normalizeAddress(f.address)],
            },
      ]..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            (a['a'] as String).compareTo(b['a'] as String),
      ),
  'groups':
      <Map<String, dynamic>>[
        for (final GroupProfile g in state.groups.values)
          if (!g.isInvitePending)
            <String, dynamic>{
              'id': g.id,
              'name': g.name,
              if (g.description.isNotEmpty) 'd': g.description,
              'avatar': g.avatarPreset,
              'by': g.createdById,
              'at': g.createdAtMillis,
              'm': g.memberAddresses,
              if (g.memberNames.isNotEmpty) 'mn': g.memberNames,
            },
      ]..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            (a['id'] as String).compareTo(b['id'] as String),
      ),
  if (state.removedFriends.isNotEmpty)
    'x': <String, int>{
      for (final String address in state.removedFriends.keys.toList()..sort())
        if (state.removedFriendAt(address) case final int at) address: at,
    },
};
