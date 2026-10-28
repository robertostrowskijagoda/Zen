// Owner report R5-#22 (28.10.2026, after 1.14.0): 1.14.0 sometimes did not start until its data was wiped.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#22: 1.14.0 starts without wiping its data',
    () {},
    skip:
        'R5-#22 open: 1.14.0 sometimes did not start until its data was wiped. '
        'Found by test/persistence_fuzz_test.dart: a settings file cut short, emptied, made huge or written by a newer version throws out of the first start-up step (FileAppSettingsStore.load, app_settings_store.dart) when its backup does not open either: the start never finishes. Found by the real-node tests (tool/e2e.dart): the Go bridge can deadlock (its packet loop writes a session reply from inside the read loop, pq_session.go open(); YggGetNodeInfo on the UI thread then waits forever).',
  );
}
