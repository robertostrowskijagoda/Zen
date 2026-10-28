// Owner report R5-#16 (28.10.2026, after 1.14.0): duplicate people in the Bluetooth "met" list.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#16: a person met over Bluetooth is listed once',
    () {},
    skip:
        'R5-#16 open: duplicate people in the Bluetooth "met" list. '
        'Fix in progress; the real test goes here.',
  );
}
