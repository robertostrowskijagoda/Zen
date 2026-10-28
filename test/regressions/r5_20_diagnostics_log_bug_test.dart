// Owner report R5-#20 (28.10.2026, after 1.14.0): a bug in the diagnostics logs (details to come from the owner).
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#20: the diagnostics log has the reported defect fixed',
    () {},
    skip:
        'R5-#20 open: a bug in the diagnostics logs (details to come from the owner). '
        'Waiting for details. Found meanwhile: logZenError asserts in debug builds on a chained stack trace (zen_log.dart, debugPrintStack with \'===== asynchronous gap =====\'), seen by test/persistence_fuzz_test.dart.',
  );
}
