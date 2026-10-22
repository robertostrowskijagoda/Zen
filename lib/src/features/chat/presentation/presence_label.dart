import 'package:zen/src/app/i18n/zen_i18n.dart';

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
