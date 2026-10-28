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

/// "12 min temu", "3 godz. temu", "2 dni temu": how long before [nowMillis]
/// [atMillis] was.
String presenceAgoLabel(int atMillis, int nowMillis) {
  final int minutes = (nowMillis - atMillis) ~/ 60000;
  if (minutes < 1) {
    return t('przed chwilą');
  }
  if (minutes < 60) {
    return t('{n} min temu', {'n': minutes});
  }
  final int hours = minutes ~/ 60;
  if (hours < 24) {
    return t('{n} godz. temu', {'n': hours});
  }
  return tn(
    hours ~/ 24,
    one: '{n} dzień temu',
    few: '{n} dni temu',
    many: '{n} dni temu',
  );
}

/// The short name of [presence]: "w sieci", "w tle", "poza siecią",
/// "status nieznany"; `null` for a friend who does not show it.
String? presenceStateLabel(PeerPresence presence) => switch (presence) {
  PeerPresence.online => t('w sieci'),
  PeerPresence.background => t('w tle'),
  PeerPresence.offline => t('poza siecią'),
  PeerPresence.unknown => t('status nieznany'),
  PeerPresence.hidden => null,
};

/// What a friend's chat header says about their presence at [nowMillis]:
/// "w sieci"; "w tle · ostatnio otwierał(a) 5 min temu"; offline, when Zen
/// was last open there (or, without that, since when they are quiet); not
/// known now, and why ([unknownPresenceLine]); and `null` for a friend who
/// does not show it.
String? friendPresenceLine(FriendProfile friend, int nowMillis) {
  final PeerPresence shown = friend.shownPresence;
  if (shown == PeerPresence.unknown) {
    return unknownPresenceLine(friend, nowMillis);
  }
  final String? state = presenceStateLabel(shown);
  if (state == null || shown == PeerPresence.online) {
    return state;
  }
  final String? opened = lastOpenedLabel(friend.lastOpenedAtMillis, nowMillis);
  if (shown == PeerPresence.background) {
    return opened == null ? state : '$state · $opened';
  }
  return opened ??
      quietFriendLabel(friend.lastPresenceAtMillis, nowMillis) ??
      state;
}

/// Why a friend's presence is not known at [nowMillis], in words: this
/// device has no network; not checked since Zen started, with the last one
/// known ("status nieznany · ostatnio w sieci 12 min temu"); or their Zen
/// is too old to tell it.
String unknownPresenceLine(FriendProfile friend, int nowMillis) {
  final String state = t('status nieznany');
  switch (friend.presenceDoubt) {
    case PresenceDoubt.noNetwork:
      return t('Brak połączenia z siecią — status nieznany');
    case null:
      return t('Starsza wersja Zen — status nieznany');
    case PresenceDoubt.unchecked:
      final int at = friend.presenceAtMillis;
      final String? last = switch (friend.presence) {
        PeerPresence.online when at > 0 => t('ostatnio w sieci {ago}', {
          'ago': presenceAgoLabel(at, nowMillis),
        }),
        PeerPresence.background when at > 0 => t('ostatnio w tle {ago}', {
          'ago': presenceAgoLabel(at, nowMillis),
        }),
        _ =>
          lastOpenedLabel(friend.lastOpenedAtMillis, nowMillis) ??
              quietFriendLabel(friend.lastPresenceAtMillis, nowMillis),
      };
      return last == null ? state : '$state · $last';
  }
}
