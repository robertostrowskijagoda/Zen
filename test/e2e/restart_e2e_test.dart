@Tags(<String>['e2e'])
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';

import 'support/zen_mesh.dart';

/// A restart on real devices: what was there is there again, messages get
/// through at once both ways, and presence settles.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String? skip = await zenMeshSkipReason();

  test(
    'a restart keeps friends, names and chats, messages get through at once '
    'and presence settles',
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
      final Stopwatch sinceStart = Stopwatch()..start();
      expect(ala.address, address, reason: 'the same identity');
      expect(ala.friendOf(ola)?.status, FriendRelationshipStatus.accepted);
      expect(ala.friendOf(ola)?.displayLabel, 'Ola');
      expect(
        (await ala.thread(ola)).map((m) => m.text),
        contains('przed restartem'),
      );
      // R5-F5: Ola writes at once, while her device still holds the
      // sessions of Ala's old process on every layer.
      mesh.mark('Ola writes');
      await ola.send(ala, 'po restarcie');
      final Duration first = await ala.waitForText(
        ola,
        'po restarcie',
        within: kAfterRestartWithin,
      );
      mesh.timings.add(
        'the first message after the restart took ${first.inMilliseconds} ms',
      );
      // R5-#15: not "?" for long after a start while the friend's Zen runs.
      // Confirmed by Ola's device after the start (a ping or pong of hers
      // reached Ala's app since), not remembered from before it. Not by the
      // stored presence time: a pong that changes nothing on the screen
      // moves it only when the state is saved next.
      await ala.waitFor('Ola\'s presence confirmed after the restart', () {
        final FriendProfile? f = ala.friendOf(ola);
        final int heard = max(
          ala.heardAtMillis(ola, 'ping'),
          ala.heardAtMillis(ola, 'pong'),
        );
        return f != null &&
            f.shownPresence == PeerPresence.online &&
            heard >= ala.startedAtMillis;
      }, within: const Duration(seconds: 45));
      mesh.timings.add(
        'presence settled ${sinceStart.elapsedMilliseconds} ms after the start',
      );
      // And the other way.
      mesh.mark('Ala answers');
      await ala.send(ola, 'też po restarcie');
      final Duration back = await ola.waitForText(
        ala,
        'też po restarcie',
        within: kAfterRestartWithin,
      );
      mesh.timings.add('the answer took ${back.inMilliseconds} ms');
      mesh.report();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
