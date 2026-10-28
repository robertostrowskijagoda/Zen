// Owner report R5-#18 (28.10.2026, after 1.14.0): a friend shown online for a while although their app was in the background.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#18: a friend whose Zen is in the background is not shown online',
    () {},
    skip:
        'R5-#18 open: a friend shown online for a while although their app was in the background. '
        'test/e2e/friends_e2e_test.dart checks "w tle" within 20 s on a computer; the phone case (locked service answering pings) is not covered there.',
  );
}
