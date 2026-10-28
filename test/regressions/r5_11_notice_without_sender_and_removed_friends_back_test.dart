// Owner report R5-#11 (28.10.2026, after 1.14.0): a notification without sender or content despite the setting; after opening the app removed contacts came back.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#11: a message notice names the sender and says what came, as set',
    () {},
    skip:
        'R5-#11 open: a notification without sender or content despite the setting; after opening the app removed contacts came back. '
        'test/e2e/friends_e2e_test.dart checks one notice per message with sender and text at the default level, and a removed friend staying removed after a restart.',
  );
}
