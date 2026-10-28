// Owner report R5-#15 (28.10.2026, after 1.14.0): status "?" after a restart although the friend\'s service was running.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#15: after a restart a friend\'s presence settles while their Zen runs',
    () {},
    skip:
        'R5-#15 open: status "?" after a restart although the friend\'s service was running. '
        'test/e2e/restart_e2e_test.dart waits for presence confirmed after the start; after a restart the first contact of R5-#9 repeats (about 14 s).',
  );
}
