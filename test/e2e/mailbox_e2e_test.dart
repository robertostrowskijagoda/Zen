@Tags(<String>['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/zen_mesh.dart';

/// Three friends on real devices: a message to a friend whose device is off
/// waits at a mailbox (a third friend's device) and arrives when the friend
/// is back, with the sender gone by then; a post reaches a friend of a
/// friend.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String? skip = await zenMeshSkipReason();

  test(
    'offline and back through a mailbox; a post reaches a friend of a friend',
    () async {
      final ZenMesh mesh = await ZenMesh.open();
      final ZenDevice ala = await mesh.device('Ala');
      final ZenDevice ola = await mesh.device('Ola');
      final ZenDevice mia = await mesh.device('Mia');
      await mesh.befriend(ala, ola, within: kInvitationWithin);
      await mesh.befriend(ala, mia, within: kInvitationWithin);
      await mesh.befriend(ola, mia, within: kInvitationWithin);

      // Ola's device picks its mailboxes among friends (computers stay
      // online: good mailboxes) and tells them.
      mesh.mark('Ola picks Mia as a mailbox');
      await ola.waitForAsync(
        'Mia among its mailboxes',
        () async => (await ola.mailboxes()).any(
          (String a) => PeerShareCodec.addressesEqual(a, mia.address),
        ),
        within: const Duration(seconds: 90),
      );

      // Ola is away; Ala writes, then leaves too; Ola comes back.
      mesh.mark('Ola away, Ala writes and leaves');
      await ola.stop();
      await ala.send(ola, 'list do skrzynki');
      // Long enough for the direct try to fail and the deposit to land.
      await Future<void>.delayed(const Duration(seconds: 20));
      await ala.stop();
      mesh.mark('Ola back');
      await ola.start();
      final Duration took = await ola.waitForText(
        ala,
        'list do skrzynki',
        within: const Duration(seconds: 90),
      );
      mesh.timings.add('the mailbox handed it over in ${took.inSeconds} s');
      await ala.start();

      // Ala and Mia are not friends of each other's friends' posts here:
      // Mia (Ola's friend) is two steps from Ala only through Ola, so the
      // chain is Ala - Ola - Mia with Ala and Mia unfriended first.
      mesh.mark('a post two steps away');
      await mia.remove(ala);
      await ala.remove(mia);
      await ala.post('post Ali dla dalszych znajomych');
      await mia.waitFor(
        'Ala\'s post on the wall (through Ola)',
        () => mia.wall().contains('post Ali dla dalszych znajomych'),
        within: const Duration(seconds: 90),
      );
      mesh.report();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
