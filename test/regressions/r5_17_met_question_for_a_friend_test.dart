// Owner report R5-#17 (28.10.2026, after 1.14.0): "spotkani?" shown for someone who is already a friend.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#17: a friend is never offered as "spotkani?"',
    () {},
    skip:
        'R5-#17 open: "spotkani?" shown for someone who is already a friend. '
        'Fix in progress; the real test goes here.',
  );
}
