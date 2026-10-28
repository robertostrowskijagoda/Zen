// Owner report R5-#9 (28.10.2026, after 1.14.0): invitations arrived very late; the invitation should also show on the QR screen.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'R5-#9: an invitation shows at the invited person within seconds',
    () {},
    skip:
        'R5-#9 open: invitations arrived very late; the invitation should also show on the QR screen. '
        'Measured by test/e2e/friends_e2e_test.dart: about 14 s for a first contact on one computer (post-quantum session set-up; multi-packet key frames meet Yggdrasil\'s one-packet buffer while a key is looked up). kInvitationWithin in test/e2e/support/zen_mesh.dart is the bound to lower.',
  );
}
