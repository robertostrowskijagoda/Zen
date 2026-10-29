import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/utils/copy_with_cast.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

enum FriendRelationshipStatus {
  none,
  pendingIncoming,
  pendingOutgoing,
  accepted,
  blocked,
}

@immutable
final class FriendProfile {
  const FriendProfile({
    required this.address,
    this.displayName = '',
    this.nickname = '',
    this.requestMessage,
    this.blockNote,
    this.inboxLimitMb = 0,
    this.autoCleanupDays = 0,
    this.status = FriendRelationshipStatus.none,
    this.isOnline = false,
    this.lastPresenceAtMillis = 0,
    this.presence = PeerPresence.offline,
    this.presenceAtMillis = 0,
    this.presenceDoubt,
    this.lastOpenedAtMillis = 0,
    this.lastMessagePreview = '',
    this.lastActivityLabel = '',
    this.unreadCount = 0,
    this.isTyping = false,
  });

  final String address;

  /// The name the peer gave itself in its profile (it comes with its
  /// invitation, its answer and every profile update). Not editable here.
  final String displayName;

  /// What *this* user calls the peer, shown under [displayName] ("Kasia z
  /// pracy"). Only on this account's devices; '' when not set.
  final String nickname;
  final String? requestMessage;
  final String? blockNote;
  final int inboxLimitMb;
  final int autoCleanupDays;
  final FriendRelationshipStatus status;

  /// Reachable directly now (any sign of life lately, a ping, a pong, a
  /// message): what delivery decides by. Not what the person is doing:
  /// that is [presence].
  final bool isOnline;
  final int lastPresenceAtMillis;

  /// What the friend's Zen is doing, as they announced it (`ping`, `pong`,
  /// `away`), and when that was last confirmed.
  final PeerPresence presence;
  final int presenceAtMillis;

  /// Why [presence] is not shown as it is, `null` when it is: only in
  /// memory (a friend read back from the store whose presence was confirmed
  /// longer than kPresenceRememberedFor ago is [PresenceDoubt.unchecked]
  /// until they answer, see [shownPresence]).
  final PresenceDoubt? presenceDoubt;

  /// What the screens show: [PeerPresence.hidden] for a friend who does not
  /// show it; [PeerPresence.noConnection] while this device has no network;
  /// [PeerPresence.unknown] while it is not checked lately or their Zen is
  /// too old to tell it; [presence] otherwise.
  PeerPresence get shownPresence => presence == PeerPresence.hidden
      ? PeerPresence.hidden
      : switch (presenceDoubt) {
          PresenceDoubt.noNetwork => PeerPresence.noConnection,
          PresenceDoubt.unchecked => PeerPresence.unknown,
          null => presence,
        };

  /// When the friend last had Zen open on the screen, as they told it;
  /// 0 when not known or they keep it to themselves.
  final int lastOpenedAtMillis;
  final String lastMessagePreview;
  final String lastActivityLabel;
  final int unreadCount;
  final bool isTyping;

  /// The peer's name. Never leaks the raw mesh address: a peer that has not
  /// told its name yet (or an auto-generated technical label: the raw share
  /// code or the "Zen <code>" placeholder a nameless app sends) is "Kontakt
  /// Zen".
  String get displayLabel =>
      hasProfileName ? displayName.trim() : t('Kontakt Zen');

  /// True when the peer has told its real name (not a generated label).
  bool get hasProfileName => isRealPeerName(address, displayName);

  /// True when this user gave the peer a nickname.
  bool get hasNickname => nickname.trim().isNotEmpty;

  FriendProfile copyWith({
    String? address,
    String? displayName,
    String? nickname,
    Object? requestMessage = _sentinel,
    Object? blockNote = _sentinel,
    int? inboxLimitMb,
    int? autoCleanupDays,
    FriendRelationshipStatus? status,
    bool? isOnline,
    int? lastPresenceAtMillis,
    PeerPresence? presence,
    int? presenceAtMillis,
    Object? presenceDoubt = _sentinel,
    int? lastOpenedAtMillis,
    String? lastMessagePreview,
    String? lastActivityLabel,
    int? unreadCount,
    bool? isTyping,
  }) {
    return FriendProfile(
      address: address ?? this.address,
      displayName: displayName ?? this.displayName,
      nickname: nickname ?? this.nickname,
      requestMessage: identical(requestMessage, _sentinel)
          ? this.requestMessage
          : castCopyWithValue<String>(
              requestMessage,
              fieldName: 'requestMessage',
            ),
      blockNote: identical(blockNote, _sentinel)
          ? this.blockNote
          : castCopyWithValue<String>(blockNote, fieldName: 'blockNote'),
      inboxLimitMb: inboxLimitMb ?? this.inboxLimitMb,
      autoCleanupDays: autoCleanupDays ?? this.autoCleanupDays,
      status: status ?? this.status,
      isOnline: isOnline ?? this.isOnline,
      lastPresenceAtMillis: lastPresenceAtMillis ?? this.lastPresenceAtMillis,
      presence: presence ?? this.presence,
      presenceAtMillis: presenceAtMillis ?? this.presenceAtMillis,
      presenceDoubt: identical(presenceDoubt, _sentinel)
          ? this.presenceDoubt
          : castCopyWithValue<PresenceDoubt>(
              presenceDoubt,
              fieldName: 'presenceDoubt',
            ),
      lastOpenedAtMillis: lastOpenedAtMillis ?? this.lastOpenedAtMillis,
      lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
      lastActivityLabel: lastActivityLabel ?? this.lastActivityLabel,
      unreadCount: unreadCount ?? this.unreadCount,
      isTyping: isTyping ?? this.isTyping,
    );
  }
}

const Object _sentinel = Object();

/// Whether [name] is a name the peer at [address] gave itself, not a label
/// made up for it (empty, "Kontakt Zen", the raw share code or the
/// "Zen <code>" placeholder a nameless app sends).
bool isRealPeerName(String address, String? name) {
  final String trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == 'Kontakt Zen') {
    return false;
  }
  final String shareId = PeerShareCodec.shareIdForAddress(address);
  return trimmed != shareId && trimmed != 'Zen $shareId';
}
