import 'package:flutter_test/flutter_test.dart';
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
}
