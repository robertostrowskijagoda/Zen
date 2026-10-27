import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';

/// Quiet this long, a friend's chat header says since when.
const Duration kQuietFriendAfter = Duration(days: 7);

/// "w sieci 9 dni temu" for a friend not seen online for at least
/// [kQuietFriendAfter] (they may have lost the phone or removed Zen), or
/// `null` when they were seen lately or never ([lastSeenMillis] 0).
String? quietFriendLabel(int lastSeenMillis, int nowMillis) {
  if (lastSeenMillis <= 0) {
    return null;
  }
  final Duration quiet = Duration(milliseconds: nowMillis - lastSeenMillis);
  if (quiet < kQuietFriendAfter) {
    return null;
  }
  if (quiet.inDays >= 30) {
    return t('w sieci ponad miesiąc temu');
  }
  return tn(
    quiet.inDays,
    one: 'w sieci {n} dzień temu',
    few: 'w sieci {n} dni temu',
    many: 'w sieci {n} dni temu',
  );
}

/// "ostatnio otwierał(a) 5 min temu": when a friend last had Zen open on
/// the screen ([lastOpenedMillis]), or `null` when it is not known (0).
String? lastOpenedLabel(int lastOpenedMillis, int nowMillis) {
  if (lastOpenedMillis <= 0) {
    return null;
  }
  final int ago = nowMillis - lastOpenedMillis;
  final Duration since = Duration(milliseconds: ago < 0 ? 0 : ago);
  if (since < const Duration(minutes: 1)) {
    return t('ostatnio otwierał(a) przed chwilą');
  }
  if (since < const Duration(hours: 1)) {
    return tn(
      since.inMinutes,
      one: 'ostatnio otwierał(a) {n} min temu',
      few: 'ostatnio otwierał(a) {n} min temu',
      many: 'ostatnio otwierał(a) {n} min temu',
    );
  }
  if (since < const Duration(days: 1)) {
    return tn(
      since.inHours,
      one: 'ostatnio otwierał(a) {n} godz. temu',
      few: 'ostatnio otwierał(a) {n} godz. temu',
      many: 'ostatnio otwierał(a) {n} godz. temu',
    );
  }
  if (since.inDays >= 30) {
    return t('ostatnio otwierał(a) ponad miesiąc temu');
  }
  return tn(
    since.inDays,
    one: 'ostatnio otwierał(a) {n} dzień temu',
    few: 'ostatnio otwierał(a) {n} dni temu',
    many: 'ostatnio otwierał(a) {n} dni temu',
  );
}

/// The short name of [presence]: "w sieci", "w tle", "poza siecią"; `null` for
/// a friend who does not show it.
String? presenceStateLabel(PeerPresence presence) => switch (presence) {
  PeerPresence.online => t('w sieci'),
  PeerPresence.background => t('w tle'),
  PeerPresence.offline => t('poza siecią'),
  PeerPresence.hidden => null,
};

/// What a friend's chat header says about their presence at [nowMillis]:
/// "w sieci"; "w tle · ostatnio otwierał(a) 5 min temu"; offline, when Zen
/// was last open there (or, without that, since when they are quiet); and
/// `null` for a friend who does not show it.
String? friendPresenceLine(FriendProfile friend, int nowMillis) {
  final String? state = presenceStateLabel(friend.presence);
  if (state == null || friend.presence == PeerPresence.online) {
    return state;
  }
  final String? opened = lastOpenedLabel(friend.lastOpenedAtMillis, nowMillis);
  if (friend.presence == PeerPresence.background) {
    return opened == null ? state : '$state · $opened';
  }
  return opened ??
      quietFriendLabel(friend.lastPresenceAtMillis, nowMillis) ??
      state;
}
