// Bugs the new automatic tests of round R5 found (not reported from the
// field yet), as R5-F<n>. Each skipped test is replaced by the real one with
// the fix; docs/TESTING.md, "Field report -> regression test".
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-F1: a damaged relay state does not stop sending',
    () {},
    skip:
        'R5-F1 open: a damaged relay state file (outbox, mailboxes, mail held '
        'for friends) throws out of RelayEngine._load (relay_engine.dart) '
        'through FileRelayStateStore.load (relay_state_store.dart) on every '
        'send, so nothing goes out. Found by test/persistence_fuzz_test.dart.',
  );

  test(
    'R5-F2: a damaged conversation file does not block that conversation',
    () {},
    skip:
        'R5-F2 open: a damaged conversation file throws out of '
        'FileMessageTimelineStore._open (message_timeline_store.dart) on every '
        'append: the friend can no longer be written to. Found by '
        'test/persistence_fuzz_test.dart.',
  );

  test(
    'R5-F3: logging an error with a chained stack trace never throws',
    () {},
    skip:
        'R5-F3 open: logZenError (zen_log.dart) passes a chained trace '
        "(with '===== asynchronous gap =====') to debugPrintStack, which "
        'asserts in debug builds, so the error being logged is lost and a new '
        'one is thrown. Found by test/persistence_fuzz_test.dart.',
  );

  test(
    'R5-F4: the Go bridge never deadlocks when a session opens while '
    'packets come in',
    () {},
    skip:
        'R5-F4 open: the bridge packet loop (bridge_signaling.go, '
        'startPacketLoop -> openSignal) writes the session reply from inside '
        'the read loop (pq_session.go open(): e.write(source, reply)); when '
        "ironwood's session actor waits for that same reader, every later "
        'call into the core blocks for good, YggGetNodeInfo on the app UI '
        'thread included (traffic_meter.go sampleTrafficAt -> GetSessions): '
        'the app freezes. Found by tool/e2e.dart (test/e2e), about one run '
        'in three on Windows; the goroutines are in the job log.',
  );

  test(
    'R5-F5: a first contact (and the first after a restart) takes seconds, '
    'not 14',
    () {},
    skip:
        'R5-F5 open: two devices that never talked (or one just restarted) '
        'exchange nothing for about 14 s on one computer: the post-quantum '
        'session is set up first and its multi-packet key frames meet the '
        "one-packet buffer of Yggdrasil's ipv6rwc for a destination whose key "
        'is still being looked up (likely; see R5-#9, #15). Measured by '
        'test/e2e (kInvitationWithin, kAfterRestartWithin).',
  );
}
