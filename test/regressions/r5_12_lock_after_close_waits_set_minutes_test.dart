// Owner report R5-#12 (28.10.2026, after 1.14.0): the lock came at once after closing instead of after the set minutes.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#12: after closing, the app locks only after the minutes set',
    () {},
    skip:
        'R5-#12 open: the lock came at once after closing instead of after the set minutes. '
        'Fix pending; the real test goes here.',
  );
}
