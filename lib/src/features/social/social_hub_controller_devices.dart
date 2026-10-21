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
            ),
      );
    });
  }

  /// Another device of this account removed [address] as a friend (it
  /// already told them): drop them here too, quietly.
  Future<void> forgetFriendFromOtherDevice(String address) async {
    await _enqueueStateWork(() async {
      final FriendProfile? have = state.friendByAddress(address);
      if (have == null) {
        return;
      }
      final Map<String, FriendProfile> friends = Map<String, FriendProfile>.of(
        state.friends,
      );
      _removeFriend(friends, have.address);
      state = state.copyWith(friends: friends);
      await _persistState();
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
  /// or its history): added to conversation [key] unless already there,
  /// with its file when [bytes] are given.
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
  }) async {
    StoredAttachment? stored;
    if (bytes != null && bytes.isNotEmpty) {
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
          );
    await _enqueueStateWork(() async {
      await _upsertTimelineMessage(
        peerAddress: key,
        messageId: message.id,
        build: (ChatMessage? existing) {
          if (existing == null) {
            return withFile(message.copyWith(attachmentBytes: null));
          }
          // Only fill in a file that was missing here.
          final bool missing =
              (existing.attachmentPath == null ||
                  existing.attachmentPath!.isEmpty) &&
              existing.attachmentBytes == null;
          return stored != null && missing ? withFile(existing) : existing;
        },
      );
    });
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
  /// (`group:id`) were removed on some device; they are not brought back
  /// unless the backup is newer ([backupAt]) — added again since.
  Future<int> importContactsBackup(
    Map<String, dynamic> backup, {
    Map<String, int> removedAt = const <String, int>{},
    int backupAt = 0,
  }) async {
    if (backup['v'] != 1) {
      return 0;
    }
    bool removedSince(String key) => (removedAt[key] ?? -1) >= backupAt;
    int added = 0;
    await _enqueueStateWork(() async {
      final Map<String, FriendProfile> friends = Map<String, FriendProfile>.of(
        state.friends,
      );
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.of(
        state.groups,
      );
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
          final FriendProfile? have = state.friendByAddress(address);
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
          if (removedSince(address)) {
            continue;
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
      if (added == 0) {
        return;
      }
      state = state.copyWith(friends: friends, groups: groups);
      await _persistState();
    });
    return added;
  }
}

// ---- (top level) ----

/// Friends and groups of [state], as the account's devices share them.
Map<String, dynamic> contactsBackupOf(SocialHubState state) =>
    <String, dynamic>{
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
    };
