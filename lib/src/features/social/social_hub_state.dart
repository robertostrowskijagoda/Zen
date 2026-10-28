import 'package:flutter/foundation.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_event_text.dart';

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

  /// New posts of friends on the Tablica (`post_notifier.dart`).
  post,

  /// Someone mentioned this person in a group chat, a post or a comment
  /// (`mentions.dart`).
  mention,

  /// One of this device's mailboxes stopped answering and needs replacing
  /// (`mailbox_quiet_notice.dart`).
  mailbox,

  /// Zen took more than its limit: friends' photos and videos were
  /// deleted, or there are none left to delete (`storage_limit_warning.dart`).
  storage,
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
    this.titleEvent,
    this.bodyEvent,
  });

  /// An entry whose [title] (and [body], unless [bodyText] is given: what
  /// a friend wrote) is said by events, so the inbox shows it in the
  /// language of the moment ([displayTitle], [displayBody]).
  factory InboxEntry.fromEvents({
    required String id,
    required InboxEntryType type,
    required SocialEventText title,
    SocialEventText? body,
    String? bodyText,
    required int createdAtMillis,
    String? routeKey,
    String? peerAddress,
  }) {
    final SocialEventText? bodyEvent = bodyText == null ? body : null;
    return InboxEntry(
      id: id,
      type: type,
      title: title.render(),
      body: bodyText ?? bodyEvent?.render() ?? '',
      createdAtMillis: createdAtMillis,
      routeKey: routeKey,
      peerAddress: peerAddress,
      titleEvent: title,
      bodyEvent: bodyEvent,
    );
  }

  final String id;
  final InboxEntryType type;

  /// The title in the language it was made in (older entries have only
  /// this; also what notifications and matching use).
  final String title;

  /// The body in the language it was made in, see [title].
  final String body;
  final int createdAtMillis;
  final String? routeKey;
  final String? peerAddress;

  /// What the title says, put into words when it is shown.
  final SocialEventText? titleEvent;

  /// What the body says, when it is not a friend's own words.
  final SocialEventText? bodyEvent;

  /// The title in the app's current language.
  String get displayTitle => titleEvent?.render(title) ?? title;

  /// The body in the app's current language.
  String get displayBody => bodyEvent?.render(body) ?? body;

  /// This entry with its events (read back from where they are kept).
  InboxEntry withEvents({
    SocialEventText? titleEvent,
    SocialEventText? bodyEvent,
  }) => InboxEntry(
    id: id,
    type: type,
    title: title,
    body: body,
    createdAtMillis: createdAtMillis,
    routeKey: routeKey,
    peerAddress: peerAddress,
    titleEvent: titleEvent ?? this.titleEvent,
    bodyEvent: bodyEvent ?? this.bodyEvent,
  );
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
    this.disappearedMessages = const <String, int>{},
    this.notificationPrivacy = const <String, NotificationPrivacy>{},
    this.snapshotUnreadable = false,
    this.peerAppVersions = const <String, String>{},
    this.removedFriends = const <String, int>{},
    this.friendsSince = const <String, int>{},
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
          presence: PeerPresence.online,
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
          presence: PeerPresence.background,
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

  /// Disappearing messages: conversation key (a friend's
  /// address or `group:<id>`) → seconds a message lives. Absent = off.
  final Map<String, int> disappearingTimers;

  /// Disappearing messages that are gone here (see
  /// `disappearedMessageKey`) → when they expired. A copy that comes late (from a mailbox, or
  /// sent again) is dropped instead of coming back with a new clock; each
  /// is forgotten once no copy can still be on its way.
  final Map<String, int> disappearedMessages;

  /// Conversations whose notifications tell more or less than the setting
  /// says (`AppSettings.notificationPrivacy`): conversation key (a
  /// friend's address or `group:<id>`) → its own level. Absent = "Jak
  /// globalnie". Only on this device.
  final Map<String, NotificationPrivacy> notificationPrivacy;

  /// True while the stored snapshot (friends, groups, inbox) could not be
  /// read back - neither the file nor its backup - although the app is
  /// unlocked: this state is a stand-in, not the user's data.
  ///
  /// It is not "no friends". While it is set nothing is saved over the
  /// snapshot (a later read, or the next start, may still succeed), peers
  /// get no automatic answers that could end a friendship, and the app says
  /// what happened. Never stored: it describes this run only.
  final bool snapshotUnreadable;

  /// The Zen version each friend last named in a ping or pong, by
  /// [FriendProfile.address]. Self-reported: only for the "friends have a
  /// newer Zen" hint, never for anything that guards security.
  final Map<String, String> peerAppVersions;

  /// Friends who were removed (here, on another device of the account, or
  /// who removed this person): normalized address → when. Nothing that
  /// comes later brings them back on its own — a backup or another device
  /// that still lists them, a copy of an old acceptance, their messages;
  /// only a new invitation does, and it shows as one. Shared with the
  /// account's other devices (the newer of a removal and a friendship
  /// wins, see [friendsSince]).
  final Map<String, int> removedFriends;

  /// When a friendship was made on this account (an invitation answered,
  /// here or on another device), by normalized address; absent for the
  /// friendships made before this was kept. A removal older than this
  /// does not undo it.
  final Map<String, int> friendsSince;

  /// When [address] was removed as a friend, `null` when it was not (or
  /// the friendship was made again since).
  int? removedFriendAt(String address) {
    final int? at = removedFriends[PeerShareCodec.normalizeAddress(address)];
    if (at == null) {
      return null;
    }
    final int since =
        friendsSince[PeerShareCodec.normalizeAddress(address)] ?? 0;
    return since > at ? null : at;
  }

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

  /// The level conversation [key] has of its own, `null` when it follows
  /// the setting.
  NotificationPrivacy? ownNotificationPrivacyOf(String key) {
    final NotificationPrivacy? direct = notificationPrivacy[key];
    if (direct != null || key.startsWith('group:')) {
      return direct;
    }
    final String canonical = PeerShareCodec.normalizeAddress(key);
    for (final MapEntry<String, NotificationPrivacy> e
        in notificationPrivacy.entries) {
      if (!e.key.startsWith('group:') &&
          PeerShareCodec.addressesEqual(e.key, canonical)) {
        return e.value;
      }
    }
    return null;
  }

  /// How much a notification about conversation [key] tells: its own
  /// level, else [global].
  NotificationPrivacy notificationPrivacyFor(
    String key, {
    required NotificationPrivacy global,
  }) => ownNotificationPrivacyOf(key) ?? global;

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

  /// The name [address] goes by on screen (a group's messages, posts and
  /// members): a friend's own name ([nameFor]); for anyone else, or a
  /// friend whose name has not come yet, the name they gave themselves
  /// where they were met ([selfNamed]: the group's member names); else
  /// [fallback] ("Kontakt Zen" for a friend). Notifications are stricter:
  /// they name only friends (notification_privacy.dart).
  String displayNameOf(
    String address, {
    String? selfNamed,
    required String fallback,
  }) {
    final FriendProfile? friend = friendByAddress(address);
    if (friend != null) {
      final String own = nameFor(friend);
      if (friend.hasProfileName || own != friend.displayLabel) {
        return own;
      }
    }
    final String self = sanitizePeerName(selfNamed);
    if (self.isNotEmpty) {
      return self;
    }
    return friend?.displayLabel ?? fallback;
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
    Map<String, int>? disappearedMessages,
    Map<String, NotificationPrivacy>? notificationPrivacy,
    bool? snapshotUnreadable,
    Map<String, String>? peerAppVersions,
    Map<String, int>? removedFriends,
    Map<String, int>? friendsSince,
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
      disappearedMessages: disappearedMessages ?? this.disappearedMessages,
      notificationPrivacy: notificationPrivacy ?? this.notificationPrivacy,
      snapshotUnreadable: snapshotUnreadable ?? this.snapshotUnreadable,
      peerAppVersions: peerAppVersions ?? this.peerAppVersions,
      removedFriends: removedFriends ?? this.removedFriends,
      friendsSince: friendsSince ?? this.friendsSince,
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
      // Online first, then in the background, as last known (a friend
      // hiding it comes after the offline ones; one whose Zen is too old to
      // tell it counts as offline here).
      final int presenceDelta = _presenceRank(
        right.presence,
      ).compareTo(_presenceRank(left.presence));
      if (presenceDelta != 0) {
        return presenceDelta;
      }
      return left.displayLabel.compareTo(right.displayLabel);
    });
    return entries;
  }
}

int _presenceRank(PeerPresence presence) => switch (presence) {
  PeerPresence.online => 3,
  PeerPresence.background => 2,
  PeerPresence.offline ||
  PeerPresence.unknown ||
  PeerPresence.noConnection => 1,
  PeerPresence.hidden => 0,
};

/// The most removed friends remembered ([SocialHubState.removedFriends]);
/// past it the oldest removals are forgotten.
const int kMaxRemovedFriends = 2000;

/// [state] with [address] removed as a friend at [atMillis] (a later
/// removal already known stays). The friend list itself is not touched.
SocialHubState withFriendRemovedAt(
  SocialHubState state,
  String address,
  int atMillis,
) {
  final String key = PeerShareCodec.normalizeAddress(address);
  if (key.isEmpty || (state.removedFriends[key] ?? -1) >= atMillis) {
    return state;
  }
  final Map<String, int> removed = <String, int>{
    ...state.removedFriends,
    key: atMillis,
  };
  if (removed.length > kMaxRemovedFriends) {
    final List<MapEntry<String, int>> byAge = removed.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            a.value.compareTo(b.value),
      );
    for (final MapEntry<String, int> e in byAge.take(
      removed.length - kMaxRemovedFriends,
    )) {
      removed.remove(e.key);
    }
  }
  return state.copyWith(removedFriends: removed);
}

/// [state] with the friendship with [address] made here just now (an
/// invitation answered): it comes after any removal known here, even one
/// in the same millisecond.
SocialHubState withFriendshipMadeNow(SocialHubState state, String address) {
  final int removedAt =
      state.removedFriends[PeerShareCodec.normalizeAddress(address)] ?? 0;
  final int now = DateTime.now().millisecondsSinceEpoch;
  return withFriendshipSince(
    state,
    address,
    now > removedAt ? now : removedAt + 1,
  );
}

/// [state] with the friendship with [address] made at [atMillis] (an
/// invitation answered): a removal from before no longer counts.
SocialHubState withFriendshipSince(
  SocialHubState state,
  String address,
  int atMillis,
) {
  final String key = PeerShareCodec.normalizeAddress(address);
  if (key.isEmpty) {
    return state;
  }
  final int? removedAt = state.removedFriends[key];
  return state.copyWith(
    friendsSince: (state.friendsSince[key] ?? -1) >= atMillis
        ? null
        : <String, int>{...state.friendsSince, key: atMillis},
    removedFriends: removedAt != null && removedAt < atMillis
        ? (Map<String, int>.of(state.removedFriends)..remove(key))
        : null,
  );
}
