// Owner report R5-#14 (28.10.2026, after 1.14.0): removed friends come back.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#14: a removed friend stays removed whatever their device sends',
    () {},
    skip:
        'R5-#14 open: removed friends come back. '
        'test/e2e/friends_e2e_test.dart: removed, the friend keeps writing, a restart; the field case (their ledger, the account\'s other devices) is not covered yet.',
  );
}
