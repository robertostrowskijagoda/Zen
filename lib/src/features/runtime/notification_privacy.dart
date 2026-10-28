import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
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
/// app does ([applyNoticeSettings]).
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
  });

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

  NotificationPrivacy levelOf(String key) => overrides[key] ?? privacy;

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
    final NotificationPrivacy level = levelOf(key);
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
    );
  }
}

/// The kit for [state] with the global level [privacy]: each friend's and
/// each joined group's own level, and the names (and a group's members) of
/// those whose level shows who wrote. A friend's other devices
/// ([directory]) count as the friend. The names group members gave
/// themselves stay out: a member who is not a friend is told about without
/// a name. [muted] and [sounds] are the notification switches.
LockedNoticeKit lockedNoticeKitOf(
  SocialHubState state, {
  required NotificationPrivacy privacy,
  AccountDeviceDirectory? directory,
  Set<NoticeKind> muted = const <NoticeKind>{},
  bool sounds = true,
}) {
  String normal(String address) => PeerShareCodec.normalizeAddress(address);
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
    final NotificationPrivacy level = own ?? privacy;
    for (final String device in devicesOf(friend.address)) {
      if (device.isEmpty) {
        continue;
      }
      if (own != null) {
        overrides[device] = own;
      }
      if (level != NotificationPrivacy.generic) {
        names[device] = friend.displayLabel;
      }
    }
  }
  for (final GroupProfile group in state.groups.values) {
    if (group.isInvitePending) {
      continue;
    }
    final String key = groupConversationKey(group.id);
    final NotificationPrivacy? own = state.ownNotificationPrivacyOf(key);
    if (own != null) {
      overrides[key] = own;
    }
    if ((own ?? privacy) == NotificationPrivacy.generic) {
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
        names[normal(member)] = friend.displayLabel;
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
    sounds: sounds,
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
