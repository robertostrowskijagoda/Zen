// Owner report R5-#10 (28.10.2026, after 1.14.0): "połączenie z Kontakt Zen jest gotowe" instead of the friend\'s name.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#10: the notice of a new friend names them, never "Kontakt Zen"',
    () {},
    skip:
        'R5-#10 open: "połączenie z Kontakt Zen jest gotowe" instead of the friend\'s name. '
        'test/e2e/friends_e2e_test.dart checks the names both sides show; the notice\'s text itself is not checked there yet.',
  );
}
