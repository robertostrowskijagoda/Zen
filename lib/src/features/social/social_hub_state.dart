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
import 'package:zen/src/features/social/block_book.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/friendship_book.dart';
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
    this.messageId,
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
    String? messageId,
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
      messageId: messageId,
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

  /// The chat message this entry tells of (its id as its sender gave it),
  /// for an entry about one: when the message is deleted, disappears, is
  /// edited or its chat is cleared, the entry goes or changes with it, so
  /// its words do not stay behind in the list or in the shade.
  final String? messageId;

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
    messageId: messageId,
  );

  /// This entry kept with the message it tells of ([messageId]).
  InboxEntry withMessageId(String? messageId) => InboxEntry(
    id: id,
    type: type,
    title: title,
    body: body,
    createdAtMillis: createdAtMillis,
    routeKey: routeKey,
    peerAddress: peerAddress,
    titleEvent: titleEvent,
    bodyEvent: bodyEvent,
    messageId: messageId,
  );

  /// This entry saying [body] (the message it tells of was edited).
  InboxEntry withBody(String body) => InboxEntry(
    id: id,
    type: type,
    title: title,
    body: body,
    createdAtMillis: createdAtMillis,
    routeKey: routeKey,
    peerAddress: peerAddress,
    titleEvent: titleEvent,
    messageId: messageId,
  );
}

const Object _pendingLaunchIntentSentinel = Object();

const LifecycleSnapshot _defaultLifecycle = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

/// [SocialHubState.mutedUntil] for "until switched on again".
const int kMutedForever = 8640000000000000;

@immutable
final class SocialHubState {
  const SocialHubState({
    required this.lifecycle,
    this.book = FriendshipBook.empty,
    this.blocks = BlockBook.empty,
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
    this.disappearTimersSetAt = const <String, int>{},
    this.disappearedMessages = const <String, int>{},
    this.readElsewhere = const <String, int>{},
    this.outgoingInvites = const <String, OutgoingInvite>{},
    this.notificationPrivacy = const <String, NotificationPrivacy>{},
    this.mutedUntil = const <String, int>{},
    this.groupNotifyAll = const <String, bool>{},
    this.snapshotUnreadable = false,
    this.peerAppVersions = const <String, String>{},
  });

  factory SocialHubState.empty({
    LifecycleSnapshot lifecycle = _defaultLifecycle,
  }) {
    return SocialHubState(
      lifecycle: lifecycle,
      groups: const <String, GroupProfile>{},
      inbox: const <InboxEntry>[],
      pendingSignalCount: 0,
      backgroundAlerts: const <InboxEntry>[],
      pendingLaunchIntent: null,
    );
  }

  factory SocialHubState.preview() {
    return SocialHubState(
      lifecycle: _defaultLifecycle,
      book: FriendshipBook.restore(
        profiles: const <String, FriendProfile>{
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
            lastMessagePreview:
                'Transfer skończył się bez zrywania połączenia.',
            lastActivityLabel: 'Wczoraj',
          ),
        },
      ),
      groups: const <String, GroupProfile>{
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
      inbox: const <InboxEntry>[
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
      backgroundAlerts: const <InboxEntry>[],
      pendingLaunchIntent: null,
    );
  }

  final LifecycleSnapshot lifecycle;

  /// Who is a friend, who is invited, who is blocked or was removed: the
  /// only way to change it (see [FriendshipBook]).
  final FriendshipBook book;

  /// Who is blocked, by person, in every feature (see [BlockBook]); the
  /// messenger's own blocks are in [book] too.
  final BlockBook blocks;

  /// Every entry of [book] by normalized address (read only).
  Map<String, FriendProfile> get friends => book.profiles;
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

  /// When each timer of [disappearingTimers] was set, on the clock of whoever
  /// set it (see `laterDisappearStamp`): only a later setting replaces it,
  /// so a message written before a change and arriving after it does not
  /// undo the change. Absent (0): set by Zen 1.16.5 or earlier.
  final Map<String, int> disappearTimersSetAt;

  /// Disappearing messages that are gone here (see
  /// `disappearedMessageKey`) → when they expired. A copy that comes late (from a mailbox, or
  /// sent again) is dropped instead of coming back with a new clock; each
  /// is forgotten once no copy can still be on its way.
  final Map<String, int> disappearedMessages;

  /// Messages read on another device of the account before they came here
  /// (see `readElsewhereKey`) → when that was told here. Such a message comes
  /// in read: no unread count, no notification. Each is forgotten once it
  /// came, or once no copy of it can still be on its way.
  final Map<String, int> readElsewhere;

  /// Invitations to become friends sent from here and not answered yet, by
  /// the invited address: whether each reached the other side (see
  /// [OutgoingInvite]). Absent: sent by Zen 1.16.5 or earlier, not known.
  final Map<String, OutgoingInvite> outgoingInvites;

  /// What is known of the invitation sent from here to [address].
  OutgoingInvite? outgoingInviteTo(String address) {
    final OutgoingInvite? exact = outgoingInvites[address];
    if (exact != null) {
      return exact;
    }
    for (final MapEntry<String, OutgoingInvite> e in outgoingInvites.entries) {
      if (PeerShareCodec.addressesEqual(e.key, address)) {
        return e.value;
      }
    }
    return null;
  }

  /// Conversations whose notifications tell more or less than the setting
  /// says (`AppSettings.notificationPrivacy`): conversation key (a
  /// friend's address or `group:<id>`) → its own level. Absent = "Jak
  /// globalnie". Only on this device.
  final Map<String, NotificationPrivacy> notificationPrivacy;

  /// Conversations muted for a while ("Wycisz…"): conversation key (a
  /// friend's address or `group:<id>`) → until when (milliseconds since
  /// the epoch; [kMutedForever] until switched on again). No notification
  /// and no sound for their messages meanwhile (a mention of this person
  /// still comes); the list in the app still has them. Only on this
  /// device.
  final Map<String, int> mutedUntil;

  /// Groups that say otherwise than the setting "W grupach tylko wzmianki"
  /// (`AppSettings.groupMentionsOnly`): group key → true for every
  /// message, false for mentions only.
  final Map<String, bool> groupNotifyAll;

  /// Whether conversation [key] is muted at [nowMillis].
  bool isMuted(String key, int nowMillis) {
    final int? until = mutedUntil[_mutedKey(key)];
    return until != null && until > nowMillis;
  }

  /// Until when conversation [key] is muted, or null.
  int? mutedUntilOf(String key, int nowMillis) {
    final int? until = mutedUntil[_mutedKey(key)];
    return until != null && until > nowMillis ? until : null;
  }

  String _mutedKey(String key) =>
      key.startsWith('group:') ? key : PeerShareCodec.normalizeAddress(key);

  /// Whether every message of the group [groupKey] is told about, not only
  /// mentions: its own choice, else ![mentionsOnly] (the setting).
  bool groupNotifiesAll(String groupKey, {required bool mentionsOnly}) =>
      groupNotifyAll[groupKey] ?? !mentionsOnly;

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

  /// When [address] was removed as a friend, `null` when it was not (or
  /// the friendship was made again since).
  int? removedFriendAt(String address) => book.removedAt(address);

  /// Seconds messages in conversation [key] live (0 = they stay).
  int disappearSecondsFor(String key) =>
      _conversationValue(disappearingTimers, key);

  /// When the timer of conversation [key] was set (0: not known).
  int disappearSetAtFor(String key) =>
      _conversationValue(disappearTimersSetAt, key);

  static int _conversationValue(Map<String, int> values, String key) {
    final int? direct = values[key];
    if (direct != null || key.startsWith('group:')) {
      return direct ?? 0;
    }
    final String canonical = PeerShareCodec.normalizeAddress(key);
    for (final MapEntry<String, int> e in values.entries) {
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
  /// The groups joined, the one with the latest message first (then by
  /// name).
  List<GroupProfile> get groupList =>
      groups.values
          .where((GroupProfile group) => !group.isInvitePending)
          .toList()
        ..sort((GroupProfile left, GroupProfile right) {
          final int activity = _activityOf(
            right.lastActivityLabel,
          ).compareTo(_activityOf(left.lastActivityLabel));
          return activity != 0 ? activity : left.name.compareTo(right.name);
        });

  GroupProfile? groupById(String id) => groups[id];

  FriendProfile? friendByAddress(String address) => book.profileOf(address);

  SocialHubState copyWith({
    LifecycleSnapshot? lifecycle,
    FriendshipBook? book,
    BlockBook? blocks,
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
    Map<String, int>? disappearTimersSetAt,
    Map<String, int>? disappearedMessages,
    Map<String, int>? readElsewhere,
    Map<String, OutgoingInvite>? outgoingInvites,
    Map<String, NotificationPrivacy>? notificationPrivacy,
    Map<String, int>? mutedUntil,
    Map<String, bool>? groupNotifyAll,
    bool? snapshotUnreadable,
    Map<String, String>? peerAppVersions,
  }) {
    return SocialHubState(
      lifecycle: lifecycle ?? this.lifecycle,
      book: book ?? this.book,
      blocks: blocks ?? this.blocks,
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
      disappearTimersSetAt: disappearTimersSetAt ?? this.disappearTimersSetAt,
      disappearedMessages: disappearedMessages ?? this.disappearedMessages,
      readElsewhere: readElsewhere ?? this.readElsewhere,
      outgoingInvites: outgoingInvites ?? this.outgoingInvites,
      notificationPrivacy: notificationPrivacy ?? this.notificationPrivacy,
      mutedUntil: mutedUntil ?? this.mutedUntil,
      groupNotifyAll: groupNotifyAll ?? this.groupNotifyAll,
      snapshotUnreadable: snapshotUnreadable ?? this.snapshotUnreadable,
      peerAppVersions: peerAppVersions ?? this.peerAppVersions,
    );
  }

  List<FriendProfile> _sortedFriendsForStatus(FriendRelationshipStatus status) {
    final List<FriendProfile> entries = friends.values
        .where((FriendProfile friend) => friend.status == status)
        .toList(growable: false);
    entries.sort((FriendProfile left, FriendProfile right) {
      // The latest conversation first, like any messenger: a new message
      // (sent or received) moves its friend to the top.
      final int activity = _activityOf(
        right.lastActivityLabel,
      ).compareTo(_activityOf(left.lastActivityLabel));
      if (activity != 0) {
        return activity;
      }
      // Never written to: online first, then in the background, as last
      // known (a friend hiding it comes after the offline ones; one whose
      // Zen is too old to tell it counts as offline here).
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

/// Whether [address] speaks in [group]: a member, or its creator as this
/// phone recorded it (an older list may not name them) — unless the
/// creator left: who left is on record ([GroupProfile.departedAt]), and a
/// creator who left is no member any more, whose messages, calls, timers,
/// edits and deletions no phone takes, nor tells of while locked. Only a
/// later invitation of them makes them a member again (and takes them off
/// that record).
bool speaksInGroup(GroupProfile group, String address) {
  bool same(String other) => PeerShareCodec.addressesEqual(other, address);
  if (address.isEmpty) {
    return false;
  }
  if (group.memberAddresses.any(same)) {
    return true;
  }
  return same(group.createdById) && !group.departedAt.keys.any(same);
}

/// The moment of the last message in a conversation ([activityStamp]); 0
/// for none (or an old text label, which says no day).
int _activityOf(String? label) =>
    label == null ? 0 : activityStampMillis(label) ?? 0;

int _presenceRank(PeerPresence presence) => switch (presence) {
  PeerPresence.online => 3,
  PeerPresence.background => 2,
  PeerPresence.offline ||
  PeerPresence.unknown ||
  PeerPresence.noConnection => 1,
  PeerPresence.hidden => 0,
};

/// How a message read on another device of the account before it came here
/// is remembered ([SocialHubState.readElsewhere]): its conversation key and
/// id, in a group also its author (members' ids are their own and may be
/// the same).
String readElsewhereKey(String conversation, String id, {String author = ''}) =>
    author.isEmpty
    ? '$conversation\n$id'
    : '$conversation\n$id\n${PeerShareCodec.normalizeAddress(author)}';

/// How long a message read on another device is waited for here: no copy
/// of it is on its way any more after that (mailboxes keep mail 14 days).
const Duration kReadElsewhereMemory = Duration(days: 15);

/// The most messages read elsewhere that are waited for (the oldest go).
const int kMaxReadElsewhere = 2000;

/// [remembered] (key → when it was told here) with [keys] added at
/// [nowMillis], less what no copy can reach any more and the oldest past
/// [kMaxReadElsewhere].
Map<String, int> rememberReadElsewhere(
  Map<String, int> remembered,
  Iterable<String> keys,
  int nowMillis,
) {
  final int forgetBefore = nowMillis - kReadElsewhereMemory.inMilliseconds;
  final Map<String, int> next = <String, int>{
    for (final MapEntry<String, int> e in remembered.entries)
      if (e.value >= forgetBefore &&
          e.value <= nowMillis + kReadElsewhereMemory.inMilliseconds)
        e.key: e.value,
  };
  for (final String key in keys) {
    next.remove(key);
    next[key] = nowMillis;
  }
  while (next.length > kMaxReadElsewhere) {
    next.remove(next.keys.first);
  }
  return next;
}

/// Where an invitation to become friends sent from here is
/// ([SocialHubState.outgoingInvites]). It travels directly only (the other
/// side is no friend yet, so no mailbox carries it): it arrives while both
/// devices are online at the same time, and is given up after two weeks.
enum OutgoingInviteStatus {
  /// Not at the other side yet.
  onItsWay,

  /// It reached the other side's device: the answer is theirs.
  delivered,

  /// Given up without reaching them; it can be sent again, and goes again
  /// by itself once they are heard from.
  lost,
}

/// An invitation to become friends sent from here, not answered yet.
@immutable
final class OutgoingInvite {
  const OutgoingInvite({
    this.status = OutgoingInviteStatus.onItsWay,
    this.token = '',
  });

  final OutgoingInviteStatus status;

  /// The token of the code it was sent with (`it`), to send it again as it
  /// was.
  final String token;

  OutgoingInvite copyWith({OutgoingInviteStatus? status}) =>
      OutgoingInvite(status: status ?? this.status, token: token);

  Map<String, dynamic> toJson() => <String, dynamic>{
    's': status.name,
    if (token.isNotEmpty) 'it': token,
  };

  /// One as [toJson] wrote it, or null for anything else.
  static OutgoingInvite? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final OutgoingInviteStatus? status = OutgoingInviteStatus.values
        .asNameMap()[json['s']];
    final Object? token = json['it'];
    if (status == null) {
      return null;
    }
    return OutgoingInvite(
      status: status,
      token: token is String && token.length <= 256 ? token : '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is OutgoingInvite && other.status == status && other.token == token;

  @override
  int get hashCode => Object.hash(status, token);
}

/// The most invitations whose way is kept ([SocialHubState.outgoingInvites]).
const int kMaxOutgoingInvites = 500;
