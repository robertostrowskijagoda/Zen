// Owner report R5-#8 (28.10.2026, after 1.14.0): after the update to 1.14 the app stayed on the logo until its data was wiped.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#8: the app starts after an update on the data the old version left',
    () {},
    skip:
        'R5-#8 open: after the update to 1.14 the app stayed on the logo until its data was wiped. '
        'Found meanwhile by test/persistence_fuzz_test.dart: a damaged ledger file (keys, identity, archive) keeps the ledger off for the session and leaves an unhandled error (follows.dart `_ready = _start()`). Upgrade fixtures: test/fixtures/upgrade (in progress).',
  );
}
