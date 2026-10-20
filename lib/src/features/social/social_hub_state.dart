import 'package:flutter/foundation.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

enum InboxEntryType {
  friendRequest,
  friendAccepted,
  friendRemoved,
  transferCancelled,
  message,
  callInvite,
  friendRejected,
  friendCancelled,
  groupInvite,
}

@immutable
final class InboxEntry {
  const InboxEntry({
    required this.id,
    required this.type,
    required this.title,
    required this.body,
    required this.createdAtMillis,
    this.routeKey,
    this.peerAddress,
  });

  final String id;
  final InboxEntryType type;
  final String title;
  final String body;
  final int createdAtMillis;
  final String? routeKey;
  final String? peerAddress;
}

const Object _pendingLaunchIntentSentinel = Object();

const LifecycleSnapshot _defaultLifecycle = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

@immutable
final class SocialHubState {
  const SocialHubState({
    required this.lifecycle,
    required this.friends,
    this.groups = const <String, GroupProfile>{},
    required this.inbox,
    required this.pendingSignalCount,
    required this.backgroundAlerts,
    this.activeCall,
    this.pendingLaunchIntent,
    this.rejectedGroupIds = const <String>[],
    this.rejectedInviteIds = const <String>[],
    this.groupCalls = const <String, OngoingGroupCall>{},
    this.peerProfiles = const <String, PeerPublicProfile>{},
    this.profileSentVersion = 0,
    this.disappearingTimers = const <String, int>{},
    this.snapshotUnreadable = false,
  });

  factory SocialHubState.empty({
    LifecycleSnapshot lifecycle = _defaultLifecycle,
  }) {
    return SocialHubState(
      lifecycle: lifecycle,
      friends: const <String, FriendProfile>{},
      groups: const <String, GroupProfile>{},
      inbox: const <InboxEntry>[],
      pendingSignalCount: 0,
      backgroundAlerts: const <InboxEntry>[],
      pendingLaunchIntent: null,
    );
  }

  factory SocialHubState.preview() {
    return const SocialHubState(
      lifecycle: _defaultLifecycle,
      friends: <String, FriendProfile>{
        'ada.ygg': FriendProfile(
          address: 'ada.ygg',
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
          isOnline: true,
          lastMessagePreview:
              'Jestem online, mogę wejść na rozmowę za 5 minut.',
          lastActivityLabel: 'Teraz',
          unreadCount: 2,
        ),
        'maks.ygg': FriendProfile(
          address: 'maks.ygg',
          displayName: 'Maks',
          status: FriendRelationshipStatus.accepted,
          isOnline: true,
          lastMessagePreview:
              'Wrzucilem build i logi do naszej skrzynki odbiorczej.',
          lastActivityLabel: '08:41',
        ),
        'nina.ygg': FriendProfile(
          address: 'nina.ygg',
          displayName: 'Nina',
          status: FriendRelationshipStatus.accepted,
          lastMessagePreview: 'Transfer skończył się bez zrywania połączenia.',
          lastActivityLabel: 'Wczoraj',
        ),
      },
      groups: <String, GroupProfile>{
        'preview-group-1': GroupProfile(
          id: 'preview-group-1',
          name: 'Projekt Zen',
          description: 'Dyskusja o nowym wydaniu P2P',
          createdById: 'self',
          createdAtMillis: 1000,
          memberAddresses: <String>['ada.ygg', 'maks.ygg'],
          lastMessagePreview: 'Wrzucam najnowsze zmiany do repo.',
          lastActivityLabel: 'Teraz',
        ),
      },
      inbox: <InboxEntry>[
        InboxEntry(
          id: 'preview-accept',
          type: InboxEntryType.friendAccepted,
          title: 'Ada zaakceptowal(a) zaproszenie',
          body:
              'Połączenie zostało spiete od razu, bez czekania na tlo aplikacji.',
          createdAtMillis: 1003,
          routeKey: 'zen://inbox',
        ),
        InboxEntry(
          id: 'preview-request',
          type: InboxEntryType.friendRequest,
          title: 'Nowe zaproszenie od Kuby',
          body: 'Dodal notatke: "Mam paczke plikow do wrzucenia wieczorem".',
          createdAtMillis: 1002,
          routeKey: 'zen://inbox',
        ),
        InboxEntry(
          id: 'preview-transfer-cancel',
          type: InboxEntryType.transferCancelled,
          title: 'Transfer anulowany poprawnie',
          body: 'Obie strony dostaly ten sam stan i historia jest czysta.',
          createdAtMillis: 1001,
          routeKey: 'zen://inbox',
        ),
      ],
      pendingSignalCount: 0,
      backgroundAlerts: <InboxEntry>[],
      pendingLaunchIntent: null,
    );
  }

  final LifecycleSnapshot lifecycle;
  final Map<String, FriendProfile> friends;
  final Map<String, GroupProfile> groups;
  final List<InboxEntry> inbox;
  final int pendingSignalCount;
  final List<InboxEntry> backgroundAlerts;
  final CallSession? activeCall;
  final RuntimeRouteIntent? pendingLaunchIntent;

  /// Groups the user declined or left, newest last.
  ///
  /// Persisted, because the inviter keeps re-sending an invite until it hears
  /// back: kept only in memory, a restart (or the separate background-service
  /// isolate) forgot the refusal and the invite popped up all over again.
  final List<String> rejectedGroupIds;

  /// Invitations declined (or whose group was left), as `groupId|inviteId`.
  /// Re-sends of those stay quiet; a new invitation to the same group does
  /// not.
  final List<String> rejectedInviteIds;

  /// Group calls running right now, by group id (see [OngoingGroupCall]).
  final Map<String, OngoingGroupCall> groupCalls;

  /// What peers show about themselves, by normalized address.
  final Map<String, PeerPublicProfile> peerProfiles;

  /// Version of the user's own profile last sent to all friends.
  final int profileSentVersion;

  /// Disappearing messages (§14.1 point 10): conversation key (a friend's
  /// address or `group:<id>`) → seconds a message lives. Absent = off.
  final Map<String, int> disappearingTimers;

  /// True while the stored snapshot (friends, groups, inbox) could not be
  /// read back - neither the file nor its backup - although the app is
  /// unlocked: this state is a stand-in, not the user's data.
  ///
  /// It is not "no friends". While it is set nothing is saved over the
  /// snapshot (a later read, or the next start, may still succeed), peers
  /// get no automatic answers that could end a friendship, and the app says
  /// what happened. Never stored: it describes this run only.
  final bool snapshotUnreadable;

  /// Seconds messages in conversation [key] live (0 = they stay).
  int disappearSecondsFor(String key) {
    final int? direct = disappearingTimers[key];
    if (direct != null || key.startsWith('group:')) {
      return direct ?? 0;
    }
    final String canonical = PeerShareCodec.normalizeAddress(key);
    for (final MapEntry<String, int> e in disappearingTimers.entries) {
      if (!e.key.startsWith('group:') &&
          PeerShareCodec.addressesEqual(e.key, canonical)) {
        return e.value;
      }
    }
    return 0;
  }

  PeerPublicProfile? peerProfileOf(String address) =>
      peerProfiles[PeerShareCodec.normalizeAddress(address)];

  /// The name to show for [friend]: the name from their newest profile,
  /// else the one they told with their invitation or answer, else a neutral
  /// placeholder. (A nickname the user gave goes under it, see
  /// [FriendProfile.nickname].)
  String nameFor(FriendProfile friend) {
    final String own = peerProfileOf(friend.address)?.name.trim() ?? '';
    return own.isNotEmpty ? own : friend.displayLabel;
  }

  List<FriendProfile> get acceptedFriends {
    return _sortedFriendsForStatus(FriendRelationshipStatus.accepted);
  }

  List<FriendProfile> get pendingOutgoingFriends {
    return _sortedFriendsForStatus(FriendRelationshipStatus.pendingOutgoing);
  }

  List<FriendProfile> get blockedFriends {
    return _sortedFriendsForStatus(FriendRelationshipStatus.blocked);
  }

  /// Groups the user is in. An invitation not answered yet is not a group of
  /// theirs - it lives in the inbox until they join.
  List<GroupProfile> get groupList => groups.values
      .where((GroupProfile group) => !group.isInvitePending)
      .toList();

  GroupProfile? groupById(String id) => groups[id];

  FriendProfile? friendByAddress(String address) {
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

  SocialHubState copyWith({
    LifecycleSnapshot? lifecycle,
    Map<String, FriendProfile>? friends,
    Map<String, GroupProfile>? groups,
    List<InboxEntry>? inbox,
    int? pendingSignalCount,
    List<InboxEntry>? backgroundAlerts,
    Object? activeCall = _pendingLaunchIntentSentinel,
    Object? pendingLaunchIntent = _pendingLaunchIntentSentinel,
    List<String>? rejectedGroupIds,
    List<String>? rejectedInviteIds,
    Map<String, OngoingGroupCall>? groupCalls,
    Map<String, PeerPublicProfile>? peerProfiles,
    int? profileSentVersion,
    Map<String, int>? disappearingTimers,
    bool? snapshotUnreadable,
  }) {
    return SocialHubState(
      lifecycle: lifecycle ?? this.lifecycle,
      friends: friends ?? this.friends,
      groups: groups ?? this.groups,
      inbox: inbox ?? this.inbox,
      pendingSignalCount: pendingSignalCount ?? this.pendingSignalCount,
      backgroundAlerts: backgroundAlerts ?? this.backgroundAlerts,
      activeCall: identical(activeCall, _pendingLaunchIntentSentinel)
          ? this.activeCall
          : castCopyWithValue<CallSession>(activeCall, fieldName: 'activeCall'),
      pendingLaunchIntent:
          identical(pendingLaunchIntent, _pendingLaunchIntentSentinel)
          ? this.pendingLaunchIntent
          : castCopyWithValue<RuntimeRouteIntent>(
              pendingLaunchIntent,
              fieldName: 'pendingLaunchIntent',
            ),
      rejectedGroupIds: rejectedGroupIds ?? this.rejectedGroupIds,
      rejectedInviteIds: rejectedInviteIds ?? this.rejectedInviteIds,
      groupCalls: groupCalls ?? this.groupCalls,
      peerProfiles: peerProfiles ?? this.peerProfiles,
      profileSentVersion: profileSentVersion ?? this.profileSentVersion,
      disappearingTimers: disappearingTimers ?? this.disappearingTimers,
      snapshotUnreadable: snapshotUnreadable ?? this.snapshotUnreadable,
    );
  }

  List<FriendProfile> _sortedFriendsForStatus(FriendRelationshipStatus status) {
    final List<FriendProfile> entries = friends.values
        .where((FriendProfile friend) => friend.status == status)
        .toList(growable: false);
    entries.sort((FriendProfile left, FriendProfile right) {
      final int unreadDelta = right.unreadCount.compareTo(left.unreadCount);
      if (unreadDelta != 0) {
        return unreadDelta;
      }
      if (left.isOnline != right.isOnline) {
        return right.isOnline ? 1 : -1;
      }
      return left.displayLabel.compareTo(right.displayLabel);
    });
    return entries;
  }
}
