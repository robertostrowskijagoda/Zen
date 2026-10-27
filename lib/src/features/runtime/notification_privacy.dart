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
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
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

/// What [signal] says in a notice or an inbox entry: for a message with an
/// attachment only the label of its type (never the caption or file name),
/// otherwise its text.
String? signalNoticePreview(ZenSignal signal) {
  final String? content = signal.content;
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
/// and by group key) of only those conversations whose level shows the
/// sender. Sealed with the background key, like the other kits; the app
/// writes it whenever any of it changes ([lockedNoticeKitOf]).
///
/// A conversation the kit has no name for is told about without one: so is
/// everything from strangers and everything without a kit.
@immutable
final class LockedNoticeKit {
  const LockedNoticeKit({
    this.privacy = AppSettings.defaultNotificationPrivacy,
    this.overrides = const <String, NotificationPrivacy>{},
    this.names = const <String, String>{},
  });

  final NotificationPrivacy privacy;
  final Map<String, NotificationPrivacy> overrides;
  final Map<String, String> names;

  /// The most names and levels a kit holds.
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
    final String senderName = inGroup
        ? (names[sender] ??
              (sanitizePeerName(signal.displayName).isNotEmpty
                  ? sanitizePeerName(signal.displayName)
                  : t('Kontakt Zen')))
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
    );
  }
}

/// The kit for [state] with the global level [privacy]: each friend's and
/// each joined group's own level, and the names of those whose level shows
/// who wrote. A friend's other devices ([directory]) count as the friend.
LockedNoticeKit lockedNoticeKitOf(
  SocialHubState state, {
  required NotificationPrivacy privacy,
  AccountDeviceDirectory? directory,
}) {
  String normal(String address) => PeerShareCodec.normalizeAddress(address);
  final Map<String, NotificationPrivacy> overrides =
      <String, NotificationPrivacy>{};
  final Map<String, String> names = <String, String>{};
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
    group.memberNames.forEach((String address, String name) {
      final String member = normal(address);
      if (member.isNotEmpty && name.trim().isNotEmpty) {
        names.putIfAbsent(member, () => name);
      }
    });
    for (final String member in group.memberAddresses) {
      final FriendProfile? friend = state.friendByAddress(member);
      if (friend != null) {
        names[normal(member)] = friend.displayLabel;
      }
    }
  }
  return LockedNoticeKit(
    privacy: privacy,
    overrides: overrides,
    names: names.length > LockedNoticeKit.maxEntries
        ? Map<String, String>.fromEntries(
            names.entries.take(LockedNoticeKit.maxEntries),
          )
        : names,
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
