@Tags(<String>['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';

import 'support/zen_mesh.dart';

/// A restart on real devices: what was there is there again, presence
/// settles and messages flow again.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String? skip = await zenMeshSkipReason();

  test(
    'a restart keeps friends, names and chats, and presence settles',
    () async {
      final ZenMesh mesh = await ZenMesh.open();
      final ZenDevice ala = await mesh.device('Ala');
      final ZenDevice ola = await mesh.device('Ola');
      await mesh.befriend(ala, ola, within: kInvitationWithin);
      await ala.send(ola, 'przed restartem');
      await ola.waitForText(ala, 'przed restartem', within: kMessageWithin);
      final String address = ala.address;

      // R5-#8, #22: the start after an update or a restart finishes.
      mesh.mark('Ala restarts');
      await ala.restart();
      expect(ala.address, address, reason: 'the same identity');
      expect(ala.friendOf(ola)?.status, FriendRelationshipStatus.accepted);
      expect(ala.friendOf(ola)?.displayLabel, 'Ola');
      expect(
        (await ala.thread(ola)).map((m) => m.text),
        contains('przed restartem'),
      );
      // R5-#15: not "?" for long after a start while the friend's Zen runs.
      // Confirmed by Ola's device after the start, not remembered from
      // before it.
      final Duration settled = await ala.waitFor(
        'Ola\'s presence confirmed after the restart',
        () {
          final FriendProfile? f = ala.friendOf(ola);
          return f != null &&
              f.shownPresence == PeerPresence.online &&
              f.presenceAtMillis >= ala.startedAtMillis;
        },
        within: const Duration(seconds: 45),
      );
      mesh.timings.add('presence settled ${settled.inSeconds} s after start');
      // And both ways after it.
      await ola.send(ala, 'po restarcie');
      await ala.waitForText(ola, 'po restarcie', within: kAfterRestartWithin);
      mesh.report();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
