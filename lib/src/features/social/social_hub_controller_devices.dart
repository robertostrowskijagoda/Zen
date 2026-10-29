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
  /// [atMillis] (it already told them; 0: now): the book takes the removal
  /// unless what it knows of them is later (a friendship made again since).
  Future<void> forgetFriendFromOtherDevice(
    String address, {
    int atMillis = 0,
  }) async {
    await _enqueueStateWork(() async {
      final FriendshipTick tick = _friendshipTick;
      final FriendshipBook book = state.book.remove(
        address,
        tick,
        // Its own removal entry (Zen 1.14.0 writes only that one): no device
        // named, so any record of the same moment wins over it.
        at: atMillis > 0 ? FriendshipStamp(Hlc(atMillis, 0), '') : null,
      );
      if (!identical(book, state.book)) {
        state = state.copyWith(book: book);
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
        state.book.standingOf(key) == FriendshipStanding.removed) {
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

  /// Takes in [backup], the newest copy any device of the account saved
  /// (or a copy of the account): a new or recovered device gets its friends
  /// and groups back. Returns how many friends and groups were added or
  /// changed.
  ///
  /// Who is a friend goes by the copy's records, merged into the book by
  /// its one rule (the later record per friend wins, see [FriendshipBook]):
  /// a device that still lists a removed friend brings nobody back. Names
  /// and nicknames of friends in it win (it is the newest copy). A group is
  /// not brought back when [removedAt] says it was left on some device
  /// since the copy was saved ([backupAt]).
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
    final Map<String, FriendshipRecord> records = contactsBackupRecords(
      backup,
      backupAt: backupAt,
    );
    // What the copy shows of each friend: name, nickname.
    final Map<String, (String?, String)> shown = <String, (String?, String)>{};
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
        final Object? rawName = item['n'];
        final Object? rawNickname = item['k'];
        shown[PeerShareCodec.normalizeAddress(a)] = (
          rawName is String ? sanitizePeerName(rawName) : null,
          rawNickname is String ? sanitizeFriendNickname(rawNickname) : '',
        );
      }
    }
    int added = 0;
    await _enqueueStateWork(() async {
      final FriendshipTick tick = _friendshipTick;
      final FriendshipBook before = state.book;
      FriendshipBook book = before;
      // The removal entries every device writes for the account's others
      // (all Zen 1.14.0 writes; each is taken once, as it comes: see
      // DeviceChatSync). Read again here only for someone the book knows
      // nothing of, so that a copy saved before such a removal does not
      // bring them in; a friend kept here from before records is not taken
      // away by an old entry read again.
      removedAt.forEach((String address, int at) {
        if (address.startsWith('group:') ||
            at <= 0 ||
            !isRoutablePeerAddress(address) ||
            book.recordOf(address) != null) {
          return;
        }
        book = book.remove(address, tick, at: FriendshipStamp(Hlc(at, 0), ''));
      });
      records.forEach((String address, FriendshipRecord record) {
        final (String?, String)? seen = shown[address];
        book = book.merge(
          address,
          record,
          tick,
          shape: seen == null
              ? null
              : (FriendProfile base) => base.copyWith(
                  displayName: seen.$1 != null && seen.$1!.isNotEmpty
                      ? seen.$1
                      : null,
                  nickname: seen.$2,
                ),
        );
      });
      shown.forEach((String address, (String?, String) seen) {
        final FriendProfile? have = book.profileOf(address);
        if (have == null ||
            (have.status != FriendRelationshipStatus.accepted &&
                have.status != FriendRelationshipStatus.blocked)) {
          return;
        }
        final String? n = seen.$1;
        final String k = seen.$2;
        if ((n != null && n.isNotEmpty && n != have.displayName) ||
            k != have.nickname) {
          // A newer name, or a nickname given on another device.
          book = book.edit(
            address,
            (FriendProfile f) => f.copyWith(
              displayName: n != null && n.isNotEmpty ? n : f.displayName,
              nickname: k,
            ),
            nicknameChanged: true,
          );
          if (before.profileOf(address) != null) {
            added++;
          }
        }
      });
      for (final String address in book.profiles.keys) {
        if (before.profileOf(address) == null) {
          added++;
        }
      }
      final Map<String, GroupProfile> groups = Map<String, GroupProfile>.of(
        state.groups,
      );
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
      if (identical(book, before) && groups.length == state.groups.length) {
        return;
      }
      state = state.copyWith(book: book, groups: groups);
      await _persistState();
    });
    return added;
  }

  /// Whether this device knows something about who is a friend that
  /// [backup] (the newest copy) lacks or has older: then its own copy goes
  /// out, so the account's devices end up agreeing.
  bool contactsBackupBehind(Map<String, dynamic> backup) {
    final Map<String, FriendshipRecord> theirs = friendshipRecordsFromJson(
      backup['r'],
    );
    for (final MapEntry<String, FriendshipRecord> e
        in state.book.records.entries) {
      final FriendshipRecord? copy = theirs[e.key];
      if (copy == null || e.value.beats(copy)) {
        return true;
      }
    }
    return false;
  }
}

// ---- (top level) ----

/// Friends and groups of [state], as the account's devices share them,
/// with the book's records (`r`, see [FriendshipBook.records]): who is a
/// friend, blocked or removed, and since when — the devices merge them
/// record by record. (Zen 1.14.0 reads `friends` and `groups` only.)
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
      if (state.book.records.isNotEmpty)
        'r': friendshipRecordsToJson(state.book.records),
    };

/// The records [backup] holds ([contactsBackupOf]). A copy of Zen 1.14.0
/// has none: a friend it lists counts as one of unknown time (older than
/// any record, so it adds only someone nothing is known of), a block it
/// lists as made when the copy was saved ([backupAt]). What test builds of
/// 1.15 wrote (`s`: friendship times, `x`: removals) is taken as records.
Map<String, FriendshipRecord> contactsBackupRecords(
  Map<String, dynamic> backup, {
  int backupAt = 0,
}) {
  final Map<String, FriendshipRecord> records = friendshipRecordsFromJson(
    backup['r'],
  )..removeWhere((String address, _) => !isRoutablePeerAddress(address));
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
      if (records.containsKey(address)) {
        continue;
      }
      final Object? since = item['s'];
      records[address] = item['b'] == 1
          ? FriendshipRecord(
              FriendshipMark.blocked,
              FriendshipStamp(Hlc(backupAt > 0 ? backupAt : 0, 0), ''),
            )
          : FriendshipRecord(
              FriendshipMark.friend,
              since is int && since > 0
                  ? FriendshipStamp(Hlc(since, 0), '')
                  : FriendshipStamp.zero,
            );
    }
  }
  final Object? x = backup['x'];
  if (x is Map) {
    for (final MapEntry<dynamic, dynamic> e in x.entries.take(
      kMaxRemovedFriends,
    )) {
      final Object? address = e.key;
      final Object? at = e.value;
      if (address is! String ||
          at is! int ||
          at <= 0 ||
          !isRoutablePeerAddress(address)) {
        continue;
      }
      final String key = PeerShareCodec.normalizeAddress(address);
      final FriendshipRecord removal = FriendshipRecord(
        FriendshipMark.removed,
        FriendshipStamp(Hlc(at, 0), ''),
      );
      final FriendshipRecord? have = records[key];
      if (have == null || removal.beats(have)) {
        records[key] = removal;
      }
    }
  }
  return records;
}
