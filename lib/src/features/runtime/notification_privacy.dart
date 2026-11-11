import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_tech_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

// What a notification about a chat message says at each
// [NotificationPrivacy] level, in one place for every poster: the app's
// own notifications (social_hub_controller_helpers.dart), a message from
// someone who is not a friend, and the locked background receiver, which
// reads the levels and the names from the [LockedNoticeKit].

/// The title and the body of one notification.
typedef NoticeText = ({String title, String body});

/// What the diagnostics log says of a posted notification ([logNoticePosted]):
/// its [kind] (a short fixed word), the privacy [level] applied (`null`:
/// none, a call or an alarm), whether the sender was [known] (named by
/// this person), and the Zen [version] the sender last named, when known.
typedef NoticeLog = ({
  String kind,
  NotificationPrivacy? level,
  bool known,
  String? version,
});

/// What a poster tells the app's notification service about the
/// notification it posts, for the diagnostics log
/// (PrivacyRedactingNotificationService writes the line).
final Expando<NoticeLog> noticeLogs = Expando<NoticeLog>('noticeLog');

/// One TECH line for a notification just posted by [process] (`ui`, `svc`):
/// its kind, the level applied, whether the sender was known and their
/// Zen version when known — never the text or a name.
void logNoticePosted(String process, NoticeLog log) {
  final String? version = log.version;
  ZenTechLog.event('notice', <String, Object?>{
    'p': process,
    'kind': log.kind,
    'level': switch (log.level) {
      NotificationPrivacy.senderAndContent => 'sender-content',
      NotificationPrivacy.senderOnly => 'sender-only',
      NotificationPrivacy.generic => 'generic',
      null => null,
    },
    'known': log.known,
    // A log word starts with a letter and has no dots: 1.13.1 is v1-13-1.
    'ver': version == null ? null : 'v${version.replaceAll('.', '-')}',
  });
}

/// The [NoticeLog.kind] of [notification] when its poster says no more.
String noticeLogKindOf(RuntimeSystemNotification notification) =>
    switch (notification.category) {
      RuntimeSystemNotificationCategory.message => 'message',
      RuntimeSystemNotificationCategory.social => 'social',
      RuntimeSystemNotificationCategory.call => 'call',
      RuntimeSystemNotificationCategory.transfer => 'transfer',
      RuntimeSystemNotificationCategory.alarm => 'alarm',
      RuntimeSystemNotificationCategory.update => 'update',
    };

/// What a chat message's notification says at [level]: [sender] wrote it,
/// in the group chat [group] when that is not `null` ('' for a group
/// without a name), [preview] is its text (or the label of its attachment).
///
/// * [NotificationPrivacy.senderAndContent]: who and what ("Ada" / "Hej!";
///   in a group "Ekipa" / "Ada: Hej!"); without a preview as below.
/// * [NotificationPrivacy.senderOnly]: who, never what ("Ada" / "Nowa
///   wiadomość"; "Ekipa" / "Ada wysłał(a) wiadomość").
/// * [NotificationPrivacy.generic]: only that something came: "Nowa
///   wiadomość" and [genericBody] (by default "open Zen to see").
NoticeText messageNoticeText({
  required NotificationPrivacy level,
  required String sender,
  String? group,
  String? preview,
  String? genericBody,
}) {
  if (level == NotificationPrivacy.generic) {
    return (
      title: t('Nowa wiadomość'),
      body: genericBody ?? t('Otwórz Zen, aby zobaczyć szczegóły.'),
    );
  }
  final String? text = level == NotificationPrivacy.senderAndContent
      ? preview?.trim()
      : null;
  final bool hasText = text != null && text.isNotEmpty;
  if (group == null) {
    return (title: sender, body: hasText ? text : t('Nowa wiadomość'));
  }
  return (
    title: group.trim().isNotEmpty ? group.trim() : t('Wiadomość grupowa'),
    body: hasText
        ? '$sender: $text'
        : t('{name} wysłał(a) wiadomość', {'name': sender}),
  );
}

/// What the notification about a mention says at [level]: [sender]
/// mentioned this person in the group chat [group] when that is not `null`
/// ('' for a group without a name), else in a post or a comment;
/// [preview] is what they wrote.
///
/// * [NotificationPrivacy.senderAndContent]: who and what ("Ada
///   wspomniał(a) o Tobie" / "Hej @Bob!"; in a group "Ekipa" / "Ada
///   wspomniał(a) o Tobie: Hej @Bob!").
/// * [NotificationPrivacy.senderOnly]: who, never what.
/// * [NotificationPrivacy.generic]: in a group what any message says ("Nowa
///   wiadomość"), elsewhere only "Ktoś wspomniał o Tobie", and
///   [genericBody].
NoticeText mentionNoticeText({
  required NotificationPrivacy level,
  required String sender,
  String? group,
  String? preview,
  String? genericBody,
}) {
  final String body = genericBody ?? t('Otwórz Zen, aby zobaczyć szczegóły.');
  if (level == NotificationPrivacy.generic) {
    return group == null
        ? (title: t('Ktoś wspomniał o Tobie'), body: body)
        : messageNoticeText(
            level: level,
            sender: sender,
            genericBody: genericBody,
          );
  }
  final String? text = level == NotificationPrivacy.senderAndContent
      ? preview?.trim()
      : null;
  final bool hasText = text != null && text.isNotEmpty;
  final String said = t('{name} wspomniał(a) o Tobie', {'name': sender});
  if (group == null) {
    return (title: said, body: hasText ? text : body);
  }
  return (
    title: group.trim().isNotEmpty ? group.trim() : t('Wiadomość grupowa'),
    body: hasText ? '$said: $text' : said,
  );
}

/// The key of the mark a group message gets on this device when it
/// mentions this person and may say so ([signalMentionsYou]). Set only
/// here, after the checks (never read from what came over the wire).
const String kMentionsYouKey = 'mentionsYou';

/// Whether [signal] was found to mention this person (see
/// [kMentionsYouKey]).
bool signalMentionsYou(ZenSignal signal) =>
    signal.chatExtras?[kMentionsYouKey] == true;

/// The people a chat or group message [signal] mentions.
List<Mention> signalMentions(ZenSignal signal) =>
    mentionsFromJson(signal.chatExtras?[kMentionsKey]);

/// What [signal] says in a notice or an inbox entry: for a message with an
/// attachment only the label of its type (never the caption or file name),
/// otherwise its text (mentions as "@name").
String? signalNoticePreview(ZenSignal signal) {
  final String? raw = signal.content;
  final String? content = raw == null
      ? null
      : mentionsAsPlainText(raw, signalMentions(signal));
  final ChatMessageType? type = signal.messageType;
  if (content == null && (type == null || type == ChatMessageType.text)) {
    return null;
  }
  return chatPreviewLine(
    content ?? '',
    type: type,
    fileName: signal.fileName,
    mimeType: signal.mimeType,
  );
}

/// The most characters of a message the locked background receiver puts in
/// a notice. It reads an incoming message only in memory, to say this
/// much; the whole message goes into the sealed inbox, which only the
/// unlocked app opens (docs/SECURITY_MODEL.md).
const int kLockedNoticePreviewChars = 80;

/// [text] cut to [max] characters (whole characters, not UTF-16 halves),
/// with "…" when anything was cut.
String shortNoticePreview(String text, {int max = kLockedNoticePreviewChars}) {
  final String trimmed = text.trim();
  final List<int> runes = trimmed.runes.toList(growable: false);
  if (runes.length <= max) {
    return trimmed;
  }
  return '${String.fromCharCodes(runes.take(max - 1)).trimRight()}…';
}

/// The per-conversation key of the group chat [groupId] (the 1:1 chat's
/// key is the friend's address), as `SocialHubState.notificationPrivacy`
/// and the disappearing-message timers use it.
String groupConversationKey(String groupId) => 'group:$groupId';

/// The conversation [signal] belongs to: its group chat, else the sender's
/// 1:1 chat.
String conversationKeyOfSignal(ZenSignal signal) {
  final String? groupId = signal.groupId?.trim();
  return groupId != null && groupId.isNotEmpty
      ? groupConversationKey(groupId)
      : signal.sender;
}

/// What a phone knows of people and of the settings when it decides what an
/// incoming chat message or call makes it do ([incomingAlertOf]). The
/// unlocked app answers from its own state and settings, the locked
/// receiver from the background capability and the [LockedNoticeKit]
/// ([LockedNoticeKit.alertFacts]); both decide with the same functions
/// below, so a locked phone rings, shows the call card or tells of a
/// message exactly when the app would. Whatever one side does not know
/// counts as "no", which is the quiet outcome.
abstract interface class AlertFacts {
  /// Whether [address] is a friend (one of a friend's devices among them).
  bool isFriend(String address);

  /// Whether [address] speaks in the group [groupId] this device joined: a
  /// member, or the one who made it. `false` for a group it only was
  /// invited to, one it is not in, and whenever it is not known.
  bool speaksIn(String groupId, String address);

  /// This device's own address (`''` when not known).
  String get self;

  /// Whether the news of [kind] is switched off in the settings.
  bool mutes(NoticeKind kind);

  /// Whether the conversation [key] ([conversationKeyOfSignal]) is muted at
  /// [nowMillis] ("Wycisz…").
  bool chatMuted(String key, int nowMillis);

  /// Whether the group chat [groupKey] tells of every message, not only of
  /// mentions of this person.
  bool groupNotifiesAll(String groupKey);
}

/// What an incoming frame makes a phone do, the same for the unlocked app
/// and the locked receiver.
enum IncomingAlert {
  /// Nothing to see or hear (it may still be kept for the app).
  nothing,

  /// A notification.
  notice,

  /// The phone rings and shows the call card (and the call's notice).
  ring,
}

/// Whether [signal] is a call that may ring here, from someone who may
/// call: a call from a friend, a group call from someone who speaks in that
/// joined group. Anything else (a group member who is no friend calling
/// alone, a group call for a group not joined) never rings.
bool callInviteAdmitted(ZenSignal signal, AlertFacts facts) {
  switch (signal.type) {
    case ZenSignalType.callInvite:
      return facts.isFriend(signal.sender);
    case ZenSignalType.groupCallInvite:
      final String groupId = signal.groupId ?? '';
      return groupId.isNotEmpty && facts.speaksIn(groupId, signal.sender);
    default:
      return false;
  }
}

/// Whether the call [signal] rings and shows its card: admitted
/// ([callInviteAdmitted]) and "Połączenia" not switched off (then neither
/// the ring nor the card, while Zen is not on the screen).
bool callRings(ZenSignal signal, AlertFacts facts) =>
    callInviteAdmitted(signal, facts) && !facts.mutes(NoticeKind.call);

/// Whether [signal] is a caller's word that its ring ended unanswered
/// ([kCallMissedType]), read as the end of that call.
bool isMissedCallNotice(ZenSignal signal) =>
    signal.type == ZenSignalType.callEnd &&
    signal.chatExtras?[kMissedCallMark] == true;

/// Whether a call from [caller] that nobody answered here leaves a notice:
/// from a friend (only friends may ring), and "Połączenia" not switched off.
/// The chat notes the missed call either way.
bool missedCallTold(String caller, AlertFacts facts) =>
    facts.isFriend(caller) && !facts.mutes(NoticeKind.call);

/// How long the limit on mention notices from one person counts back.
const Duration kMentionAlertWindow = Duration(minutes: 10);

/// Group messages of one sender per [kMentionAlertWindow] that may say they
/// mention this person; past it they notify like any other message.
const int kMaxMentionAlertsPerSender = 5;

/// Whether the group message [signal] mentions this device and comes from
/// someone who speaks in that group (anyone else mentions nobody), before
/// the limit per sender ([MentionAlerts]).
bool mentionsThisDevice(ZenSignal signal, AlertFacts facts) {
  if (signal.type != ZenSignalType.groupMessage) {
    return false;
  }
  final String groupId = signal.groupId ?? '';
  final String self = facts.self;
  return groupId.isNotEmpty &&
      self.isNotEmpty &&
      !PeerShareCodec.addressesEqual(signal.sender, self) &&
      facts.speaksIn(groupId, signal.sender) &&
      mentionsAnyOf(
        signal.content ?? '',
        signalMentions(signal),
        addresses: <String>[self],
      );
}

/// The mention notices each sender recently got ([kMaxMentionAlertsPerSender]
/// per [kMentionAlertWindow], counted by the sender's identity, so one
/// person's many addresses share it). One per app and one per run of the
/// locked receiver.
final class MentionAlerts {
  final Map<String, List<int>> _times = <String, List<int>>{};

  /// The most senders remembered.
  static const int maxSenders = 4096;

  /// Whether [sender] may have one more mention notice at [nowMillis],
  /// counting it when so.
  bool take(String sender, int nowMillis) {
    final int windowStart = nowMillis - kMentionAlertWindow.inMilliseconds;
    final String key = PeerShareCodec.identityKeyForAddress(sender);
    final List<int> times = _times[key] ??= <int>[];
    times.removeWhere((int at) => at < windowStart);
    if (times.length >= kMaxMentionAlertsPerSender) {
      return false;
    }
    times.add(nowMillis);
    while (_times.length > maxSenders) {
      _times.remove(_times.keys.first);
    }
    return true;
  }
}

/// [signal] marked as mentioning this person ([kMentionsYouKey]) when
/// [mentionsThisDevice] and its sender is still within [alerts]; anything
/// else comes back unchanged.
ZenSignal withMentionOfSelf(
  ZenSignal signal,
  AlertFacts facts,
  MentionAlerts alerts,
  int nowMillis,
) {
  if (!mentionsThisDevice(signal, facts) ||
      !alerts.take(signal.sender, nowMillis)) {
    return signal;
  }
  return signal.withChatExtras(<String, dynamic>{
    ...?signal.chatExtras,
    kMentionsYouKey: true,
  });
}

/// Whether the chat message [signal] makes no notice: its conversation is
/// muted, or it is a group's message in a group that tells only of
/// mentions. A mention of this person ([withMentionOfSelf]) always comes.
bool chatIsQuiet(ZenSignal signal, AlertFacts facts, int nowMillis) {
  if (signal.type != ZenSignalType.message &&
      signal.type != ZenSignalType.groupMessage) {
    return false;
  }
  if (signalMentionsYou(signal)) {
    return false;
  }
  final String key = conversationKeyOfSignal(signal);
  if (facts.chatMuted(key, nowMillis)) {
    return true;
  }
  return signal.type == ZenSignalType.groupMessage &&
      !facts.groupNotifiesAll(key);
}

/// The switch a chat message's notice answers to: a message, a group
/// message, or a mention of this person.
NoticeKind chatNoticeKind(ZenSignal signal) => switch (signal.type) {
  ZenSignalType.groupMessage when signalMentionsYou(signal) =>
    NoticeKind.mention,
  ZenSignalType.groupMessage => NoticeKind.groupMessage,
  _ => NoticeKind.message,
};

/// What the call or chat message [signal] (a group message already passed
/// through [withMentionOfSelf]) makes this phone do; `null` for any other
/// signal, which these rules do not cover.
///
/// * A call: [IncomingAlert.ring] when [callRings], else nothing.
/// * A missed call told by its caller ([isMissedCallNotice]): a notice when
///   [missedCallTold], else nothing. Never a ring.
/// * A message: a notice when it comes from a friend; a group message: when
///   its sender speaks in that joined group. Either: unless the
///   conversation is quiet ([chatIsQuiet]) or its switch
///   ([chatNoticeKind]) is off.
IncomingAlert? incomingAlertOf(
  ZenSignal signal,
  AlertFacts facts, {
  required int nowMillis,
}) {
  switch (signal.type) {
    case ZenSignalType.callInvite || ZenSignalType.groupCallInvite:
      return callRings(signal, facts)
          ? IncomingAlert.ring
          : IncomingAlert.nothing;
    case ZenSignalType.callEnd when isMissedCallNotice(signal):
      return missedCallTold(signal.sender, facts)
          ? IncomingAlert.notice
          : IncomingAlert.nothing;
    case ZenSignalType.message:
      if (!facts.isFriend(signal.sender)) {
        return IncomingAlert.nothing;
      }
    case ZenSignalType.groupMessage:
      final String groupId = signal.groupId ?? '';
      if (groupId.isEmpty || !facts.speaksIn(groupId, signal.sender)) {
        return IncomingAlert.nothing;
      }
    default:
      return null;
  }
  return chatIsQuiet(signal, facts, nowMillis) ||
          facts.mutes(chatNoticeKind(signal))
      ? IncomingAlert.nothing
      : IncomingAlert.notice;
}

/// What the locked background receiver (Android's service, an iPhone's
/// background wakes) needs to tell who wrote (and at most
/// [kLockedNoticePreviewChars] of what) in its notifications: the level
/// ([privacy]) and the conversations'
/// own levels ([overrides]); and the names ([names]: by normalized address
/// and by group key) and the members ([members]: by group key) of only
/// those conversations whose level shows the sender. Sealed with the
/// background key, like the other kits; the app writes it whenever any of
/// it changes ([lockedNoticeKitOf]).
///
/// The kit also carries the notification switches of the settings: the
/// kinds of news that are off ([muted]) and whether the notification
/// sounds are on ([sounds]), which the locked receiver applies like the
/// app does ([applyNoticeSettings]); and what it takes to decide, as the
/// app does, whether a group message or a group call counts at all: who
/// speaks in each joined group ([memberTags]), the muted conversations and
/// the groups' choice of mentions only ([alertFacts]).
///
/// A conversation the kit has no name for is told about without one: so is
/// everything from strangers, a group message from anyone the kit does not
/// list as a member of that group, and everything without a kit. A name
/// the sender gave itself is never shown: only the names this person gave
/// their friends.
@immutable
final class LockedNoticeKit {
  const LockedNoticeKit({
    this.privacy = AppSettings.defaultNotificationPrivacy,
    this.overrides = const <String, NotificationPrivacy>{},
    this.names = const <String, String>{},
    this.members = const <String, Set<String>>{},
    this.muted = const <NoticeKind>{},
    this.sounds = true,
    this.versions = const <String, String>{},
    this.removed = const <String>{},
    this.inviteToken = '',
    this.kindLevels = const <NoticeKind, NotificationPrivacy>{},
    this.mutedChats = const <String, int>{},
    this.groupNotifyAll = const <String, bool>{},
    this.groupMentionsOnly = true,
    this.self = '',
    this.memberTags = const <String>{},
    this.speakersKnown = true,
  });

  /// Conversations muted for a while (`SocialHubState.mutedUntil`).
  final Map<String, int> mutedChats;

  /// Groups' own choice of every message or mentions only
  /// (`SocialHubState.groupNotifyAll`).
  final Map<String, bool> groupNotifyAll;

  /// "W grupach tylko wzmianki" (`AppSettings.groupMentionsOnly`).
  final bool groupMentionsOnly;

  /// This device's address: a group message from someone who speaks in
  /// that group and mentions it is told about even in a muted conversation
  /// or a mentions-only group (within [kMaxMentionAlertsPerSender]).
  final String self;

  /// Who speaks in which joined group, every joined group whatever its
  /// level: one [memberTag] per group and member (the one who made it and
  /// each device of a friend among them). A tag recognises a member of a
  /// group whose id is known; it does not list anyone. What decides whether
  /// a group message or a group call counts ([AlertFacts.speaksIn]); kits
  /// written before 1.16.5 have none, and then only [members] count.
  final Set<String> memberTags;

  /// Whether this kit says who speaks in the joined groups ([memberTags]).
  /// A kit written before 1.16.5 does not (it lists the members only of
  /// groups whose level shows the sender): until the app is unlocked once
  /// and writes a new one, the locked receiver takes the word of the
  /// background capability instead, as 1.16.4 did (a friend, or a member
  /// of some joined group), so nobody's group calls and messages go quiet
  /// over an update.
  final bool speakersKnown;

  /// The tag of [address] as one who speaks in the group chat [groupKey]
  /// ([groupConversationKey]).
  static String memberTag(String groupKey, String address) => crypto.sha256
      .convert(
        utf8.encode('$groupKey\n${PeerShareCodec.normalizeAddress(address)}'),
      )
      .toString()
      .substring(0, 32);

  static final RegExp _tagPattern = RegExp(r'^[0-9a-f]{32}$');

  /// Whether [address] speaks in the joined group [groupId], as far as the
  /// kit knows.
  bool speaksIn(String groupId, String address) {
    final String key = groupConversationKey(groupId);
    return memberTags.contains(memberTag(key, address)) ||
        (members[key]?.contains(PeerShareCodec.normalizeAddress(address)) ??
            false);
  }

  /// The facts the locked receiver decides with ([incomingAlertOf]): the
  /// kit's, and who is a friend ([isFriend], from the background
  /// capability). [inJoinedGroup] (the capability's word that an address
  /// is a friend or a member of some joined group) counts only for a kit
  /// that does not say who speaks where ([speakersKnown]).
  AlertFacts alertFacts({
    required bool Function(String address) isFriend,
    bool Function(String address)? inJoinedGroup,
  }) => _KitAlertFacts(this, isFriend, inJoinedGroup);

  /// The kinds of news with a level of their own
  /// (`AppSettings.noticePrivacy`): a conversation's own level comes first,
  /// the general [privacy] last.
  final Map<NoticeKind, NotificationPrivacy> kindLevels;

  /// The token of this person's invitation code (`AppSettings.inviteToken`):
  /// a friend request without it is not told about while locked
  /// ([PeerShareCodec.fromStaleCode]).
  final String inviteToken;

  /// Friends this person removed (normalized addresses): an acceptance
  /// from them answers nothing and is not told about.
  final Set<String> removed;

  /// The Zen version friends last named, by normalized address: only for
  /// the diagnostics log's line about a notice ([logNoticePosted]).
  final Map<String, String> versions;

  /// The name of [address] for a notice about their own chat, `null` when
  /// the kit has none or their level shows nobody.
  String? senderName(String address) {
    final String key = PeerShareCodec.normalizeAddress(address);
    final String? name = names[key];
    return name == null ||
            levelOf(key, NoticeKind.message) == NotificationPrivacy.generic
        ? null
        : name;
  }

  /// The Zen version [address] last named, `null` when not known.
  String? versionOf(String address) =>
      versions[PeerShareCodec.normalizeAddress(address)];

  final NotificationPrivacy privacy;
  final Map<String, NotificationPrivacy> overrides;
  final Map<String, String> names;

  /// The normalized addresses of each group's members (a friend's other
  /// devices among them), by group key.
  final Map<String, Set<String>> members;

  /// The kinds of news switched off in the settings.
  final Set<NoticeKind> muted;

  /// Whether the notification sounds are on.
  final bool sounds;

  /// [notice] as the locked receiver may post it: `null` when its kind is
  /// switched off, quiet when the notification sounds are.
  RuntimeSystemNotification? settingsApplied(
    RuntimeSystemNotification notice,
  ) => applyNoticeSettings(notice, muted: muted.contains, sounds: sounds);

  /// Which kind of news the chat message [payload] from [from] is: one in a
  /// group chat, or one from a person.
  NoticeKind messageKind({
    required String from,
    required Map<String, dynamic> payload,
  }) {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: PeerShareCodec.normalizeAddress(from),
      payload: payload,
    );
    return signal?.type == ZenSignalType.groupMessage
        ? NoticeKind.groupMessage
        : NoticeKind.message;
  }

  /// The most names and levels a kit holds, and the most members of all
  /// its groups together.
  static const int maxEntries = 2000;

  /// The level of a notice about the conversation [key], of [kind]: the
  /// conversation's own, the kind's own, or the general one.
  NotificationPrivacy levelOf(String key, [NoticeKind? kind]) =>
      overrides[key] ??
      (kind == null || !kind.hasPrivacy ? null : kindLevels[kind]) ??
      privacy;

  /// What the notice about an invitation from [from] ([type]
  /// `friend_request`) or its acceptance (`friend_accept`) says while the
  /// app is locked: who, and the invitation's own words, as far as the
  /// notification level allows; `null` for another type. The name is the
  /// one this person gave them, else the one they sent.
  NoticeText? invitationNotice({
    required String from,
    required String type,
    required Map<String, dynamic> payload,
  }) {
    final String key = PeerShareCodec.normalizeAddress(from);
    final NotificationPrivacy level = levelOf(key, NoticeKind.invitation);
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: key,
      payload: payload,
    );
    final String name = (names[key] ?? signal?.displayName ?? '').trim();
    final bool request = type == 'friend_request';
    if (!request && type != 'friend_accept') {
      return null;
    }
    if (level == NotificationPrivacy.generic || name.isEmpty) {
      return (
        title: request
            ? t('Nowe zaproszenie do znajomych')
            : t('Ktoś przyjął Twoje zaproszenie'),
        body: t('Odblokuj Zen, żeby zobaczyć szczegóły.'),
      );
    }
    if (!request) {
      return (
        title: t('{name} zaakceptował(a) zaproszenie', {'name': name}),
        body: t('Możecie już pisać i dzwonić.'),
      );
    }
    final String note = level == NotificationPrivacy.senderAndContent
        ? (signal?.content ?? '').trim()
        : '';
    return (
      title: t('Nowe zaproszenie od {name}', {'name': name}),
      body: note.isNotEmpty ? note : t('Chce dodać Cię do znajomych.'),
    );
  }

  /// What the notice about the chat message [payload] from [from] says;
  /// [genericBody] is the body when it says only that something came.
  NoticeText messageNotice({
    required String from,
    required Map<String, dynamic> payload,
    required String genericBody,
  }) {
    final NoticeText generic = messageNoticeText(
      level: NotificationPrivacy.generic,
      sender: '',
      genericBody: genericBody,
    );
    final String sender = PeerShareCodec.normalizeAddress(from);
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: sender,
      payload: payload,
    );
    if (signal == null ||
        (signal.type != ZenSignalType.message &&
            signal.type != ZenSignalType.groupMessage)) {
      return generic;
    }
    final bool inGroup = signal.type == ZenSignalType.groupMessage;
    final String key = inGroup ? conversationKeyOfSignal(signal) : sender;
    final NotificationPrivacy level = levelOf(
      key,
      inGroup ? NoticeKind.groupMessage : NoticeKind.message,
    );
    final String? known = names[key];
    if (level == NotificationPrivacy.generic || known == null) {
      return generic;
    }
    // Anyone may claim to write in a group: only its members are told
    // about by name, and only by the name this person gave them.
    if (inGroup && !(members[key]?.contains(sender) ?? false)) {
      return generic;
    }
    final String senderName = inGroup
        ? (names[sender] ?? t('Kontakt Zen'))
        : known;
    final String? preview = signalNoticePreview(signal);
    return messageNoticeText(
      level: level,
      sender: senderName,
      group: inGroup ? known : null,
      // Never the whole message: the notice stays in the system's history.
      preview: preview == null ? null : shortNoticePreview(preview),
      genericBody: genericBody,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'p': privacy.name,
    if (overrides.isNotEmpty)
      'o': <String, String>{
        for (final MapEntry<String, NotificationPrivacy> e in overrides.entries)
          e.key: e.value.name,
      },
    if (names.isNotEmpty) 'n': names,
    if (members.isNotEmpty)
      'm': <String, List<String>>{
        for (final MapEntry<String, Set<String>> e in members.entries)
          e.key: e.value.toList(growable: false),
      },
    if (muted.isNotEmpty)
      'q': <String>[for (final NoticeKind k in muted) k.name],
    if (!sounds) 's': false,
    if (versions.isNotEmpty) 'ver': versions,
    if (removed.isNotEmpty) 'x': removed.toList(growable: false),
    if (inviteToken.isNotEmpty) 'it': inviteToken,
    if (mutedChats.isNotEmpty) 'mu': mutedChats,
    if (groupNotifyAll.isNotEmpty) 'ga': groupNotifyAll,
    if (!groupMentionsOnly) 'gm': false,
    if (self.isNotEmpty) 'me': self,
    // Always there, empty too: its presence says the kit knows who speaks
    // where ([speakersKnown]).
    'gt': memberTags.toList(growable: false),
    if (kindLevels.isNotEmpty)
      'k': <String, String>{
        for (final MapEntry<NoticeKind, NotificationPrivacy> e
            in kindLevels.entries)
          e.key.name: e.value.name,
      },
  };

  static LockedNoticeKit? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return null;
    }
    NotificationPrivacy? level(Object? name) {
      for (final NotificationPrivacy value in NotificationPrivacy.values) {
        if (value.name == name) {
          return value;
        }
      }
      return null;
    }

    bool fits(Object? key) =>
        key is String && key.isNotEmpty && key.length <= 300;
    final Object? o = json['o'];
    final Object? n = json['n'];
    final Object? m = json['m'];
    final Object? q = json['q'];
    int memberCount = 0;
    final Map<String, Set<String>> members = <String, Set<String>>{};
    if (m is Map) {
      for (final MapEntry<dynamic, dynamic> e in m.entries.take(maxEntries)) {
        final Object? list = e.value;
        if (!fits(e.key) || list is! List) {
          continue;
        }
        final Set<String> group = <String>{};
        for (final Object? address in list) {
          if (memberCount >= maxEntries) {
            break;
          }
          if (fits(address)) {
            group.add(address as String);
            memberCount += 1;
          }
        }
        members[e.key as String] = group;
      }
    }
    return LockedNoticeKit(
      // An unreadable level says the least.
      privacy: level(json['p']) ?? NotificationPrivacy.generic,
      overrides: <String, NotificationPrivacy>{
        if (o is Map)
          for (final MapEntry<dynamic, dynamic> e in o.entries.take(maxEntries))
            if (fits(e.key) && level(e.value) != null)
              e.key as String: level(e.value)!,
      },
      names: <String, String>{
        if (n is Map)
          for (final MapEntry<dynamic, dynamic> e in n.entries.take(maxEntries))
            if (fits(e.key) && e.value is String)
              e.key as String: sanitizePeerName(e.value as String),
      },
      members: members,
      muted: <NoticeKind>{
        if (q is List)
          for (final Object? name in q)
            if (NoticeKind.byName(name) case final NoticeKind kind) kind,
      },
      sounds: json['s'] != false,
      versions: <String, String>{
        if (json['ver'] case final Map<dynamic, dynamic> ver)
          for (final MapEntry<dynamic, dynamic> e in ver.entries.take(
            maxEntries,
          ))
            if (fits(e.key) &&
                e.value is String &&
                isValidAppVersion(e.value as String))
              e.key as String: e.value as String,
      },
      removed: <String>{
        if (json['x'] case final List<dynamic> x)
          for (final Object? address in x.take(maxEntries))
            if (fits(address)) address as String,
      },
      inviteToken: switch (json['it']) {
        final String token when PeerShareCodec.isInviteToken(token) => token,
        _ => '',
      },
      mutedChats: <String, int>{
        if (json['mu'] case final Map<dynamic, dynamic> mu)
          for (final MapEntry<dynamic, dynamic> e in mu.entries.take(
            maxEntries,
          ))
            if (fits(e.key) && e.value is int) e.key as String: e.value as int,
      },
      groupNotifyAll: <String, bool>{
        if (json['ga'] case final Map<dynamic, dynamic> ga)
          for (final MapEntry<dynamic, dynamic> e in ga.entries.take(
            maxEntries,
          ))
            if (fits(e.key) && e.value is bool)
              e.key as String: e.value as bool,
      },
      groupMentionsOnly: json['gm'] != false,
      self: switch (json['me']) {
        final String me when fits(me) => me,
        _ => '',
      },
      memberTags: <String>{
        if (json['gt'] case final List<dynamic> gt)
          for (final Object? tag in gt.take(maxEntries))
            if (tag is String && _tagPattern.hasMatch(tag)) tag,
      },
      speakersKnown: json['gt'] is List,
      kindLevels: <NoticeKind, NotificationPrivacy>{
        if (json['k'] case final Map<dynamic, dynamic> k)
          for (final MapEntry<dynamic, dynamic> e in k.entries)
            if ((NoticeKind.byName(e.key), level(e.value)) case (
              final NoticeKind kind,
              final NotificationPrivacy l,
            ))
              kind: l,
      },
    );
  }
}

/// [LockedNoticeKit.alertFacts]: what the locked receiver knows.
final class _KitAlertFacts implements AlertFacts {
  _KitAlertFacts(this._kit, this._isFriend, this._inJoinedGroup);

  final LockedNoticeKit _kit;
  final bool Function(String address) _isFriend;
  final bool Function(String address)? _inJoinedGroup;

  @override
  bool isFriend(String address) =>
      _isFriend(PeerShareCodec.normalizeAddress(address));

  @override
  bool speaksIn(String groupId, String address) =>
      _kit.speaksIn(groupId, address) ||
      (!_kit.speakersKnown &&
          (_inJoinedGroup?.call(PeerShareCodec.normalizeAddress(address)) ??
              false));

  @override
  String get self => _kit.self;

  @override
  bool mutes(NoticeKind kind) => _kit.muted.contains(kind);

  @override
  bool chatMuted(String key, int nowMillis) {
    final int? until =
        _kit.mutedChats[key.startsWith('group:')
            ? key
            : PeerShareCodec.normalizeAddress(key)];
    return until != null && until > nowMillis;
  }

  @override
  bool groupNotifiesAll(String groupKey) =>
      _kit.groupNotifyAll[groupKey] ?? !_kit.groupMentionsOnly;
}

/// The kit for [state] with the global level [privacy]: each friend's and
/// each joined group's own level, and the names (and a group's members) of
/// those whose level shows who wrote. A friend's other devices
/// ([directory]) count as the friend. The names group members gave
/// themselves stay out: a member who is not a friend is told about without
/// a name. Who speaks in each joined group goes in as tags, whatever the
/// group's level ([LockedNoticeKit.memberTags]). [muted] and [sounds] are
/// the notification switches.
LockedNoticeKit lockedNoticeKitOf(
  SocialHubState state, {
  required NotificationPrivacy privacy,
  AccountDeviceDirectory? directory,
  Set<NoticeKind> muted = const <NoticeKind>{},
  bool sounds = true,
  String inviteToken = '',
  Map<NoticeKind, NotificationPrivacy> kindLevels =
      const <NoticeKind, NotificationPrivacy>{},
  bool groupMentionsOnly = true,
  String self = '',
}) {
  String normal(String address) => PeerShareCodec.normalizeAddress(address);
  // A name is worth keeping when some notice may show it: the general
  // level or one kind's own.
  final bool anyShowsNames =
      privacy != NotificationPrivacy.generic ||
      kindLevels.values.any(
        (NotificationPrivacy l) => l != NotificationPrivacy.generic,
      );
  final Map<String, NotificationPrivacy> overrides =
      <String, NotificationPrivacy>{};
  final Map<String, String> names = <String, String>{};
  final Map<String, Set<String>> members = <String, Set<String>>{};
  int memberCount = 0;
  Iterable<String> devicesOf(String address) {
    final String? account = directory?.accountOf(address);
    return <String>{
      normal(address),
      if (directory != null && account != null)
        ...directory.addressesOf(account).map(normal),
    };
  }

  for (final FriendProfile friend in state.friends.values) {
    if (friend.status != FriendRelationshipStatus.accepted) {
      continue;
    }
    final NotificationPrivacy? own = state.ownNotificationPrivacyOf(
      friend.address,
    );
    final bool showsName = own == null
        ? anyShowsNames
        : own != NotificationPrivacy.generic;
    for (final String device in devicesOf(friend.address)) {
      if (device.isEmpty) {
        continue;
      }
      if (own != null) {
        overrides[device] = own;
      }
      if (showsName) {
        names[device] = state.nameFor(friend);
      }
    }
  }
  final Set<String> memberTags = <String>{};
  for (final GroupProfile group in state.groups.values) {
    if (group.isInvitePending) {
      continue;
    }
    final String key = groupConversationKey(group.id);
    // Who speaks in it, whatever its level: whether a group message or a
    // group call counts at all is decided by that (as the app decides).
    for (final String speaker in <String>[
      ...group.memberAddresses,
      group.createdById,
    ]) {
      for (final String device in devicesOf(speaker)) {
        if (device.isNotEmpty &&
            memberTags.length < LockedNoticeKit.maxEntries) {
          memberTags.add(LockedNoticeKit.memberTag(key, device));
        }
      }
    }
    final NotificationPrivacy? own = state.ownNotificationPrivacyOf(key);
    if (own != null) {
      overrides[key] = own;
    }
    if (own == null
        ? (kindLevels[NoticeKind.groupMessage] ?? privacy) ==
              NotificationPrivacy.generic
        : own == NotificationPrivacy.generic) {
      continue;
    }
    names[key] = group.name;
    final Set<String> listed = <String>{};
    for (final String member in group.memberAddresses) {
      for (final String device in devicesOf(member)) {
        if (device.isNotEmpty &&
            memberCount < LockedNoticeKit.maxEntries &&
            listed.add(device)) {
          memberCount += 1;
        }
      }
      // Only a friend's name was given here: someone whose request still
      // waits named themselves.
      final FriendProfile? friend = state.friendByAddress(member);
      if (friend != null &&
          friend.status == FriendRelationshipStatus.accepted) {
        names[normal(member)] = state.nameFor(friend);
      }
    }
    members[key] = listed;
  }
  return LockedNoticeKit(
    privacy: privacy,
    overrides: overrides,
    names: names.length > LockedNoticeKit.maxEntries
        ? Map<String, String>.fromEntries(
            names.entries.take(LockedNoticeKit.maxEntries),
          )
        : names,
    members: members,
    muted: muted,
    removed: <String>{
      for (final String address in state.book.removedAddresses) normal(address),
    },
    versions: <String, String>{
      for (final MapEntry<String, String> e in state.peerAppVersions.entries)
        if (state.friendByAddress(e.key)?.status ==
            FriendRelationshipStatus.accepted)
          normal(e.key): e.value,
    },
    sounds: sounds,
    inviteToken: inviteToken,
    kindLevels: kindLevels,
    mutedChats: <String, int>{
      for (final MapEntry<String, int> e in state.mutedUntil.entries)
        if (e.value > DateTime.now().millisecondsSinceEpoch) e.key: e.value,
    },
    groupNotifyAll: state.groupNotifyAll,
    groupMentionsOnly: groupMentionsOnly,
    self: normal(self),
    memberTags: memberTags,
  );
}

/// Where the notice kit is kept.
BackgroundKitFile lockedNoticeKitFile({
  required Future<Directory> Function() supportDirectory,
  required AppSecurityCredentialsStore credentials,
  bool createKey = false,
}) => BackgroundKitFile(
  supportDirectory: supportDirectory,
  credentials: credentials,
  storageKey: 'background/notice-kit',
  fileName: 'notice-kit.zenbg',
  createKey: createKey,
);
