import 'dart:convert';
import 'dart:typed_data';

import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/storage/binary_buffer.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/format_version.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/social_event_text.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

abstract interface class SocialSnapshotStore {
  Future<SocialHubState?> load();

  Future<void> save(SocialHubState state);
}

final class FileSocialSnapshotStore implements SocialSnapshotStore {
  FileSocialSnapshotStore({
    required this.store,
    this.storageKey = 'social/hub',
  });

  static const int _versionMarker = 255;
  static const int _currentVersion = 8;

  /// The oldest layout this build reads (8: the one of 1.12.0).
  static const int _oldestVersion = 8;

  /// The keys of the JSON document at the end that this build writes.
  static const List<String> _knownJsonKeys = <String>[
    'rejectedInviteIds',
    'nicknames',
    'peerProfiles',
    'profileSentVersion',
    'callAcceptToken',
    'disappear',
    'notifyPrivacy',
    'inboxText',
    'peerVersions',
    'groups',
    'removedFriends',
    'friendsSince',
    'presence',
  ];

  /// Keys of the JSON document a newer build added: written back as read,
  /// so going back to an older build does not erase them.
  Map<String, Object?> _carried = const <String, Object?>{};

  final FileBinaryStore store;
  final String storageKey;

  @override
  Future<SocialHubState?> load() async {
    final Uint8List? bytes = await store.read(storageKey);
    if (bytes == null || bytes.isEmpty) {
      return null;
    }
    try {
      return _read(bytes);
    } on NewerFormatException {
      // Not damaged: a newer build wrote it. Kept exactly as it is (the
      // store refuses to write over it) until this build is updated.
      store.holdNewer(storageKey);
      rethrow;
    } on Object catch (error) {
      // Kept aside before anything can save over it: the friend list must
      // never be lost to a file this build cannot read.
      logZenWarning('Social snapshot unreadable, kept aside: $error');
      await store.write('$storageKey.unreadable', bytes);
      rethrow;
    }
  }

  /// The snapshot as [save] writes it; a [NewerFormatException] for a
  /// newer version, a [FormatException] for anything else unreadable.
  ///
  /// Fields added later go into the JSON document at the end (no new
  /// version needed; keys this build does not know are carried along by
  /// [save]). A change of the binary layout raises [_currentVersion] and
  /// keeps a branch here for every version down to [_oldestVersion].
  SocialHubState _read(Uint8List bytes) {
    final BinaryReader reader = BinaryReader(bytes);
    final int marker = reader.readUint8();
    final int version = reader.readUint8();
    if (marker == _versionMarker && version > _currentVersion) {
      throw NewerFormatException(
        storageKey,
        found: version,
        supported: _currentVersion,
      );
    }
    if (marker != _versionMarker ||
        formatAgeOf(
              version,
              current: _currentVersion,
              oldest: _oldestVersion,
            ) !=
            FormatAge.readable) {
      throw FormatException('Unsupported social snapshot version $version.');
    }
    final LifecycleSnapshot lifecycle = LifecycleSnapshot(
      visibility: enumAt(
        AppVisibilityState.values,
        reader.readUint8(),
        AppVisibilityState.background,
      ),
      generation: reader.readUint32(),
      capturedAtMillis: reader.readInt64(),
    );
    final int pendingSignalCount = reader.readUint32();

    final int friendCount = reader.readUint32();
    final Map<String, FriendProfile> friends = <String, FriendProfile>{};
    for (int index = 0; index < friendCount; index += 1) {
      final FriendProfile friend = FriendProfile(
        address: reader.readString(),
        displayName: reader.readString(),
        requestMessage: reader.readNullableString(),
        blockNote: reader.readNullableString(),
        inboxLimitMb: reader.readUint32(),
        autoCleanupDays: reader.readUint32(),
        status: enumAt(
          FriendRelationshipStatus.values,
          reader.readUint8(),
          FriendRelationshipStatus.none,
        ),
        isOnline: reader.readBool(),
        lastPresenceAtMillis: reader.readInt64(),
        lastMessagePreview: reader.readString(),
        lastActivityLabel: reader.readString(),
        unreadCount: reader.readUint32(),
      );
      friends[friend.address] = friend;
    }

    List<InboxEntry> inbox = _readInboxEntries(reader);
    List<InboxEntry> backgroundAlerts = _readInboxEntries(
      reader,
    ).where((e) => e.type != InboxEntryType.callInvite).toList();
    CallSession? activeCall;
    if (reader.readBool()) {
      final String id = reader.readString();
      final String peerAddress = reader.readString();
      final String displayName = reader.readString();
      final CallInviteKind kind = enumAt(
        CallInviteKind.values,
        reader.readUint8(),
        CallInviteKind.audio,
      );
      activeCall = CallSession(
        id: id,
        peerAddress: peerAddress,
        displayName: displayName,
        kind: kind,
        status: () {
          final int raw = reader.readUint8();
          return raw < CallSessionStatus.values.length
              ? CallSessionStatus.values[raw]
              : CallSessionStatus.ringing;
        }(),
        startedAtMillis: reader.readInt64(),
        isIncoming: reader.readBool(),
        isMuted: reader.readBool(),
        isSpeakerOn: reader.readBool(),
        isCameraEnabled: reader.readBool(),
      );
    }
    RuntimeRouteIntent? pendingLaunchIntent;
    if (reader.readBool()) {
      final String intentId = reader.readString();
      final RuntimeRouteTarget intentTarget = enumAt(
        RuntimeRouteTarget.values,
        reader.readUint8(),
        RuntimeRouteTarget.inbox,
      );
      final String? intentPeerAddress = reader.readNullableString();
      final String? intentTitle = reader.readNullableString();
      pendingLaunchIntent = RuntimeRouteIntent(
        id: intentId,
        target: intentTarget,
        peerAddress: intentPeerAddress,
        title: intentTitle,
        autoAcceptCall: reader.readBool(),
      );
    }

    final Map<String, GroupProfile> groups = <String, GroupProfile>{};
    final int groupCount = reader.readUint32();
    for (int i = 0; i < groupCount; i++) {
      final String id = reader.readString();
      final String name = reader.readString();
      final String description = reader.readString();
      final String avatarPreset = reader.readString();
      final String createdById = reader.readString();
      final int createdAtMillis = reader.readInt64();
      final String? lastMessagePreview = reader.readNullableString();
      final String? lastActivityLabel = reader.readNullableString();
      final int unreadCount = reader.readUint32();
      final int memberCount = reader.readUint32();
      final List<String> memberAddresses = <String>[];
      for (int m = 0; m < memberCount; m++) {
        memberAddresses.add(reader.readString());
      }
      final GroupProfile group = GroupProfile(
        id: id,
        name: name,
        description: description,
        avatarPreset: avatarPreset,
        createdById: createdById,
        createdAtMillis: createdAtMillis,
        memberAddresses: memberAddresses,
        lastMessagePreview: lastMessagePreview,
        lastActivityLabel: lastActivityLabel,
        unreadCount: unreadCount,
      );
      groups[id] = group;
    }

    // Invite bookkeeping.
    final List<String> rejectedGroupIds = <String>[];
    final List<String> rejectedInviteIds = <String>[];
    final Map<String, PeerPublicProfile> peerProfiles =
        <String, PeerPublicProfile>{};
    int profileSentVersion = 0;
    final Map<String, int> disappearingTimers = <String, int>{};
    final Map<String, int> disappearedMessages = <String, int>{};
    final Map<String, NotificationPrivacy> notificationPrivacy =
        <String, NotificationPrivacy>{};
    final Map<String, String> peerAppVersions = <String, String>{};
    final Map<String, int> removedFriends = <String, int>{};
    final Map<String, int> friendsSince = <String, int>{};
    final int extensionCount = reader.readUint32();
    for (int i = 0; i < extensionCount; i++) {
      final String id = reader.readString();
      final bool isInvitePending = reader.readBool();
      final int pendingCount = reader.readUint32();
      final List<String> pending = <String>[];
      for (int p = 0; p < pendingCount; p++) {
        pending.add(reader.readString());
      }
      final GroupProfile? group = groups[id];
      if (group != null) {
        groups[id] = group.copyWith(
          isInvitePending: isInvitePending,
          pendingInviteAddresses: pending,
        );
      }
    }
    final int rejectedCount = reader.readUint32();
    for (int i = 0; i < rejectedCount; i++) {
      rejectedGroupIds.add(reader.readString());
    }
    // Group-call fields of the active call.
    if (reader.readBool()) {
      final String? groupId = reader.readNullableString();
      final int participantCount = reader.readUint32();
      final List<String> participants = <String>[
        for (int i = 0; i < participantCount; i++) reader.readString(),
      ];
      activeCall = activeCall?.copyWith(
        isGroup: true,
        groupId: groupId,
        participantAddresses: participants,
      );
    }
    // Member display names per group.
    final int groupsWithNames = reader.readUint32();
    for (int i = 0; i < groupsWithNames; i++) {
      final String id = reader.readString();
      final int count = reader.readUint32();
      final Map<String, String> names = <String, String>{};
      for (int n = 0; n < count; n++) {
        final String address = reader.readString();
        names[address] = reader.readString();
      }
      final GroupProfile? group = groups[id];
      if (group != null) {
        groups[id] = group.copyWith(memberNames: names);
      }
    }
    // Newer fields as one JSON document: adding one never needs another
    // layout change.
    final Object? decoded = _tryDecodeJson(reader.readString());
    _carried = decoded is Map
        ? unknownFields(decoded, <String, Object?>{
            for (final String key in _knownJsonKeys) key: null,
          })
        : const <String, Object?>{};
    if (decoded is Map) {
      final Object? peers = decoded['peerProfiles'];
      if (peers is List) {
        for (final Object? raw in peers) {
          if (raw is Map<String, dynamic>) {
            final PeerPublicProfile peer = PeerPublicProfile.fromJson(raw);
            if (peer.address.isNotEmpty) {
              peerProfiles[peer.address] = peer;
            }
          }
        }
      }
      final Object? nicknames = decoded['nicknames'];
      if (nicknames is Map) {
        for (final MapEntry<dynamic, dynamic> e in nicknames.entries) {
          final FriendProfile? friend = friends[e.key];
          if (friend != null && e.value is String) {
            friends[friend.address] = friend.copyWith(
              nickname: e.value as String,
            );
          }
        }
      }
      // Friends' presence: [state, confirmed at, last opened at].
      final Object? presence = decoded['presence'];
      if (presence is Map) {
        for (final MapEntry<dynamic, dynamic> e in presence.entries) {
          final FriendProfile? friend = friends[e.key];
          final Object? v = e.value;
          if (friend != null &&
              v is List &&
              v.length == 3 &&
              v.every((Object? x) => x is int)) {
            friends[friend.address] = friend.copyWith(
              presence: enumAt(
                PeerPresence.values,
                v[0] as int,
                PeerPresence.offline,
              ),
              presenceAtMillis: v[1] as int,
              lastOpenedAtMillis: v[2] as int,
            );
          }
        }
      }
      profileSentVersion =
          (decoded['profileSentVersion'] as num?)?.toInt() ?? 0;
      final Object? callAcceptToken = decoded['callAcceptToken'];
      if (callAcceptToken is String && callAcceptToken.isNotEmpty) {
        activeCall = activeCall?.copyWith(acceptToken: callAcceptToken);
      }
      final Object? timers = decoded['disappear'];
      if (timers is Map) {
        for (final MapEntry<dynamic, dynamic> e in timers.entries) {
          if (e.key is String && e.value is int && (e.value as int) >= 0) {
            disappearingTimers[e.key as String] = e.value as int;
          }
        }
      }
      final Object? gone = decoded['disappeared'];
      if (gone is Map) {
        for (final MapEntry<dynamic, dynamic> e in gone.entries) {
          if (e.key is String && e.value is int) {
            disappearedMessages[e.key as String] = e.value as int;
          }
        }
      }
      final Object? levels = decoded['notifyPrivacy'];
      if (levels is Map) {
        for (final MapEntry<dynamic, dynamic> e in levels.entries) {
          for (final NotificationPrivacy level in NotificationPrivacy.values) {
            if (e.key is String && level.name == e.value) {
              notificationPrivacy[e.key as String] = level;
            }
          }
        }
      }
      final Object? versions = decoded['peerVersions'];
      if (versions is Map) {
        for (final MapEntry<dynamic, dynamic> e in versions.entries) {
          if (e.key is String &&
              friends.containsKey(e.key) &&
              e.value is String &&
              isValidAppVersion(e.value as String)) {
            peerAppVersions[e.key as String] = e.value as String;
          }
        }
      }
      // What the inbox texts say, so they are shown in the language of the
      // moment.
      final Object? inboxText = decoded['inboxText'];
      if (inboxText is Map) {
        inbox = _withInboxEvents(inbox, inboxText);
        backgroundAlerts = _withInboxEvents(backgroundAlerts, inboxText);
      }
      for (final (String key, Map<String, int> into)
          in <(String, Map<String, int>)>[
            ('removedFriends', removedFriends),
            ('friendsSince', friendsSince),
          ]) {
        final Object? times = decoded[key];
        if (times is Map) {
          for (final MapEntry<dynamic, dynamic> e in times.entries.take(
            kMaxRemovedFriends,
          )) {
            if (e.key is String && e.value is int) {
              into[e.key as String] = e.value as int;
            }
          }
        }
      }
      final Object? inviteIds = decoded['rejectedInviteIds'];
      if (inviteIds is List) {
        rejectedInviteIds.addAll(inviteIds.whereType<String>());
      }
      final Object? perGroup = decoded['groups'];
      if (perGroup is Map) {
        for (final MapEntry<dynamic, dynamic> entry in perGroup.entries) {
          final GroupProfile? group = groups[entry.key];
          final Object? value = entry.value;
          if (group == null || value is! Map) {
            continue;
          }
          final Object? pending = value['pendingInviteIds'];
          final Object? received = value['receivedInviteIds'];
          groups[group.id] = group.copyWith(
            pendingInviteIds: pending is Map
                ? <String, String>{
                    for (final MapEntry<dynamic, dynamic> e in pending.entries)
                      if (e.key is String && e.value is String)
                        e.key as String: e.value as String,
                  }
                : null,
            receivedInviteIds: received is List
                ? received.whereType<String>().toList(growable: false)
                : null,
          );
        }
      }
    }

    // A friend is shown under the name from their newest profile.
    for (final PeerPublicProfile peer in peerProfiles.values) {
      final FriendProfile? friend = friends[peer.address];
      final String name = peer.name.trim();
      if (friend != null && name.isNotEmpty && friend.displayName != name) {
        friends[peer.address] = friend.copyWith(displayName: name);
      }
    }
    return SocialHubState(
      lifecycle: lifecycle,
      friends: friends,
      groups: groups,
      inbox: inbox,
      pendingSignalCount: pendingSignalCount,
      backgroundAlerts: backgroundAlerts,
      activeCall: activeCall,
      pendingLaunchIntent: pendingLaunchIntent,
      rejectedGroupIds: rejectedGroupIds,
      rejectedInviteIds: rejectedInviteIds,
      peerProfiles: peerProfiles,
      profileSentVersion: profileSentVersion,
      disappearingTimers: disappearingTimers,
      disappearedMessages: disappearedMessages,
      notificationPrivacy: notificationPrivacy,
      peerAppVersions: peerAppVersions,
      removedFriends: removedFriends,
      friendsSince: friendsSince,
    );
  }

  static List<InboxEntry> _withInboxEvents(
    List<InboxEntry> entries,
    Map<dynamic, dynamic> texts,
  ) => <InboxEntry>[
    for (final InboxEntry entry in entries) _withInboxEvent(entry, texts),
  ];

  static InboxEntry _withInboxEvent(
    InboxEntry entry,
    Map<dynamic, dynamic> texts,
  ) {
    final Object? saved = texts[entry.id];
    if (saved is! Map) {
      return entry;
    }
    return entry.withEvents(
      titleEvent: SocialEventText.fromJson(saved['t']),
      bodyEvent: SocialEventText.fromJson(saved['b']),
    );
  }

  static Object? _tryDecodeJson(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(SocialHubState state) async {
    final BinaryWriter writer = BinaryWriter()
      ..writeUint8(_versionMarker)
      ..writeUint8(_currentVersion)
      ..writeUint8(state.lifecycle.visibility.index)
      ..writeUint32(state.lifecycle.generation)
      ..writeInt64(state.lifecycle.capturedAtMillis)
      ..writeUint32(state.pendingSignalCount)
      ..writeUint32(state.friends.length);

    for (final FriendProfile friend in state.friends.values) {
      writer
        ..writeString(friend.address)
        ..writeString(friend.displayName)
        ..writeNullableString(friend.requestMessage)
        ..writeNullableString(friend.blockNote)
        ..writeUint32(friend.inboxLimitMb)
        ..writeUint32(friend.autoCleanupDays)
        ..writeUint8(friend.status.index)
        ..writeBool(friend.isOnline)
        ..writeInt64(friend.lastPresenceAtMillis)
        ..writeString(friend.lastMessagePreview)
        ..writeString(friend.lastActivityLabel)
        ..writeUint32(friend.unreadCount);
    }

    _writeInboxEntries(writer, state.inbox);
    _writeInboxEntries(
      writer,
      state.backgroundAlerts
          .where((InboxEntry e) => e.type != InboxEntryType.callInvite)
          .toList(),
    );
    final CallSession? activeCall = state.activeCall;
    writer.writeBool(activeCall != null);
    if (activeCall != null) {
      writer
        ..writeString(activeCall.id)
        ..writeString(activeCall.peerAddress)
        ..writeString(activeCall.displayName)
        ..writeUint8(activeCall.kind.index)
        ..writeUint8(activeCall.status.index)
        ..writeInt64(activeCall.startedAtMillis)
        ..writeBool(activeCall.isIncoming)
        ..writeBool(activeCall.isMuted)
        ..writeBool(activeCall.isSpeakerOn)
        ..writeBool(activeCall.isCameraEnabled);
    }
    final RuntimeRouteIntent? pendingLaunchIntent = state.pendingLaunchIntent;
    writer.writeBool(pendingLaunchIntent != null);
    if (pendingLaunchIntent != null) {
      writer
        ..writeString(pendingLaunchIntent.id)
        ..writeUint8(pendingLaunchIntent.target.index)
        ..writeNullableString(pendingLaunchIntent.peerAddress)
        ..writeNullableString(pendingLaunchIntent.title)
        ..writeBool(pendingLaunchIntent.autoAcceptCall);
    }

    writer.writeUint32(state.groups.length);
    for (final GroupProfile group in state.groups.values) {
      writer
        ..writeString(group.id)
        ..writeString(group.name)
        ..writeString(group.description)
        ..writeString(group.avatarPreset)
        ..writeString(group.createdById)
        ..writeInt64(group.createdAtMillis)
        ..writeNullableString(group.lastMessagePreview)
        ..writeNullableString(group.lastActivityLabel)
        ..writeUint32(group.unreadCount)
        ..writeUint32(group.memberAddresses.length);
      for (final String member in group.memberAddresses) {
        writer.writeString(member);
      }
    }

    writer.writeUint32(state.groups.length);
    for (final GroupProfile group in state.groups.values) {
      writer
        ..writeString(group.id)
        ..writeBool(group.isInvitePending)
        ..writeUint32(group.pendingInviteAddresses.length);
      for (final String member in group.pendingInviteAddresses) {
        writer.writeString(member);
      }
    }
    writer.writeUint32(state.rejectedGroupIds.length);
    for (final String id in state.rejectedGroupIds) {
      writer.writeString(id);
    }
    final CallSession? groupCall = activeCall != null && activeCall.isGroup
        ? activeCall
        : null;
    writer.writeBool(groupCall != null);
    if (groupCall != null) {
      writer
        ..writeNullableString(groupCall.groupId)
        ..writeUint32(groupCall.participantAddresses.length);
      for (final String participant in groupCall.participantAddresses) {
        writer.writeString(participant);
      }
    }
    final List<GroupProfile> named = state.groups.values
        .where((GroupProfile g) => g.memberNames.isNotEmpty)
        .toList(growable: false);
    writer.writeUint32(named.length);
    for (final GroupProfile group in named) {
      writer
        ..writeString(group.id)
        ..writeUint32(group.memberNames.length);
      group.memberNames.forEach((String address, String name) {
        writer
          ..writeString(address)
          ..writeString(name);
      });
    }
    writer.writeString(
      jsonEncode(<String, dynamic>{
        ..._carried,
        'rejectedInviteIds': state.rejectedInviteIds,
        'nicknames': <String, String>{
          for (final FriendProfile friend in state.friends.values)
            if (friend.hasNickname) friend.address: friend.nickname,
        },
        'peerProfiles': <Map<String, dynamic>>[
          for (final PeerPublicProfile peer in state.peerProfiles.values)
            peer.toJson(),
        ],
        'presence': <String, List<int>>{
          for (final FriendProfile friend in state.friends.values)
            if (friend.presence != PeerPresence.offline ||
                friend.presenceAtMillis != 0 ||
                friend.lastOpenedAtMillis != 0)
              friend.address: <int>[
                friend.presence.index,
                friend.presenceAtMillis,
                friend.lastOpenedAtMillis,
              ],
        },
        'profileSentVersion': state.profileSentVersion,
        // Read by the other isolate to check the route the native call card
        // hands it (see `CallSession.acceptToken`).
        'callAcceptToken': ?activeCall?.acceptToken,
        'disappear': state.disappearingTimers,
        'disappeared': state.disappearedMessages,
        'notifyPrivacy': <String, String>{
          for (final MapEntry<String, NotificationPrivacy> e
              in state.notificationPrivacy.entries)
            e.key: e.value.name,
        },
        'inboxText': <String, Object?>{
          for (final InboxEntry e in <InboxEntry>[
            ...state.inbox,
            ...state.backgroundAlerts,
          ])
            if (e.titleEvent != null || e.bodyEvent != null)
              e.id: <String, Object?>{
                't': ?e.titleEvent?.toJson(),
                'b': ?e.bodyEvent?.toJson(),
              },
        },
        'peerVersions': <String, String>{
          for (final MapEntry<String, String> e
              in state.peerAppVersions.entries)
            if (state.friends.containsKey(e.key)) e.key: e.value,
        },
        'groups': <String, dynamic>{
          for (final GroupProfile group in state.groups.values)
            if (group.pendingInviteIds.isNotEmpty ||
                group.receivedInviteIds.isNotEmpty)
              group.id: <String, dynamic>{
                'pendingInviteIds': group.pendingInviteIds,
                'receivedInviteIds': group.receivedInviteIds,
              },
        },
        if (state.removedFriends.isNotEmpty)
          'removedFriends': state.removedFriends,
        if (state.friendsSince.isNotEmpty) 'friendsSince': state.friendsSince,
      }),
    );

    await store.write(storageKey, writer.toBytes());
  }

  List<InboxEntry> _readInboxEntries(BinaryReader reader) {
    final int count = reader.readUint32();
    final List<InboxEntry> entries = <InboxEntry>[];
    for (int index = 0; index < count; index += 1) {
      entries.add(
        InboxEntry(
          id: reader.readString(),
          type: enumAt(
            InboxEntryType.values,
            reader.readUint8(),
            InboxEntryType.message,
          ),
          title: reader.readString(),
          body: reader.readString(),
          createdAtMillis: reader.readInt64(),
          routeKey: reader.readNullableString(),
          peerAddress: reader.readNullableString(),
        ),
      );
    }
    return entries;
  }

  void _writeInboxEntries(BinaryWriter writer, List<InboxEntry> entries) {
    writer.writeUint32(entries.length);
    for (final InboxEntry entry in entries) {
      writer
        ..writeString(entry.id)
        ..writeUint8(entry.type.index)
        ..writeString(entry.title)
        ..writeString(entry.body)
        ..writeInt64(entry.createdAtMillis)
        ..writeNullableString(entry.routeKey)
        ..writeNullableString(entry.peerAddress);
    }
  }
}

final class MemorySocialSnapshotStore implements SocialSnapshotStore {
  MemorySocialSnapshotStore([SocialHubState? initialState])
    : _state = initialState;

  SocialHubState? _state;

  @override
  Future<SocialHubState?> load() async => _cloneState(_state);

  @override
  Future<void> save(SocialHubState state) async {
    _state = _cloneState(state);
  }

  SocialHubState? _cloneState(SocialHubState? state) {
    if (state == null) {
      return null;
    }
    return SocialHubState(
      lifecycle: state.lifecycle,
      friends: Map<String, FriendProfile>.from(state.friends),
      groups: Map<String, GroupProfile>.from(state.groups),
      inbox: List<InboxEntry>.from(state.inbox, growable: false),
      pendingSignalCount: state.pendingSignalCount,
      backgroundAlerts: List<InboxEntry>.from(
        state.backgroundAlerts,
        growable: false,
      ),
      activeCall: state.activeCall,
      pendingLaunchIntent: state.pendingLaunchIntent,
      rejectedGroupIds: List<String>.from(state.rejectedGroupIds),
      rejectedInviteIds: List<String>.from(state.rejectedInviteIds),
      peerProfiles: Map<String, PeerPublicProfile>.from(state.peerProfiles),
      profileSentVersion: state.profileSentVersion,
      disappearingTimers: Map<String, int>.from(state.disappearingTimers),
      disappearedMessages: Map<String, int>.from(state.disappearedMessages),
      notificationPrivacy: Map<String, NotificationPrivacy>.from(
        state.notificationPrivacy,
      ),
      peerAppVersions: Map<String, String>.from(state.peerAppVersions),
      removedFriends: Map<String, int>.from(state.removedFriends),
      friendsSince: Map<String, int>.from(state.friendsSince),
    );
  }
}
