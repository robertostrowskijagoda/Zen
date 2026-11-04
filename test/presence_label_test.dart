import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/presence_label.dart';

void main() {
  const int day = 24 * 60 * 60 * 1000;
  const int now = 1000 * day;

  test('a friend quiet for a week or more says since when', () {
    expect(quietFriendLabel(0, now), isNull, reason: 'never seen');
    expect(quietFriendLabel(now - 2 * day, now), isNull);
    expect(quietFriendLabel(now - 9 * day, now), 'w sieci 9 dni temu');
    expect(quietFriendLabel(now - 40 * day, now), 'w sieci ponad miesiąc temu');
  });

  test("a chat's last activity: the time today, else the date and time, "
      'worked out when shown', () {
    final int today = DateTime(2026, 11, 3, 18, 30).millisecondsSinceEpoch;
    String at(DateTime d) =>
        activityTimeLabel(activityStamp(d.millisecondsSinceEpoch), today);
    expect(at(DateTime(2026, 11, 3, 9, 5)), '09:05');
    expect(at(DateTime(2026, 11, 2, 23, 59)), '02.11 23:59');
    expect(at(DateTime(2025, 12, 31, 8, 0)), '31.12.2025 08:00');
    // A label an older store kept stays as it was.
    expect(activityTimeLabel('Wczoraj', today), 'Wczoraj');
    expect(activityTimeLabel('', today), '');
  });
}
