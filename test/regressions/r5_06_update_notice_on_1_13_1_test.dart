// Owner report R5-#6 (28.10.2026, after 1.14.0): no notice of the new version arrived on 1.13.1.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#6: a phone on 1.13.1 is told of the new version',
    () {},
    skip:
        'R5-#6 open: no notice of the new version arrived on 1.13.1. '
        'Fix in progress (update notices); the real test goes here.',
  );
}
