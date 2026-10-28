@Tags(<String>['e2e'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';

import 'support/zen_mesh.dart';

/// Two people on real devices: the invitation, the names, messages both
/// ways, what a device in the background shows, presence, and a removed
/// friend who keeps writing.
Future<void> main() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final String? skip = await zenMeshSkipReason();

  test(
    'invitation by QR code, names, messages both ways, the background, '
    'presence and a removed friend',
    () async {
      final ZenMesh mesh = await ZenMesh.open();
      final ZenDevice ala = await mesh.device('Ala');
      final ZenDevice ola = await mesh.device('Ola');

      // R5-#9, #10: the invitation arrives in time and both see the names
      // the people chose, never "Kontakt Zen".
      await mesh.befriend(ala, ola, within: kInvitationWithin);

      // Messages both ways, while both are on the screen.
      mesh.mark('messages on the screen');
      await ala.send(ola, 'cześć Ola');
      await ola.waitForText(ala, 'cześć Ola', within: kMessageWithin);
      await ola.send(ala, 'cześć Ala');
      await ala.waitForText(ola, 'cześć Ala', within: kMessageWithin);

      // R5-#18: Ola leaves the screen; Ala must not keep seeing her online.
      mesh.mark('Ola goes to the background');
      await ola.setOnScreen(false);
      await ala.waitFor(
        'Ola shown "w tle"',
        () => ala.friendOf(ola)?.shownPresence == PeerPresence.background,
        within: const Duration(seconds: 20),
      );

      // R5-#11: a message to a device in the background makes exactly one
      // notification, which names the sender and says what came (the
      // default privacy level).
      await ala.send(ola, 'jesteś tam?');
      await ola.waitForText(ala, 'jesteś tam?', within: kMessageWithin);
      await ola.waitFor(
        'a notification for the message',
        () => ola.notices.messages.isNotEmpty,
        within: const Duration(seconds: 10),
      );
      final RuntimeSystemNotification notice = ola.notices.messages.single;
      expect('${notice.title} ${notice.body}', contains('Ala'));
      expect(notice.body, contains('jesteś tam?'));
      await ola.setOnScreen(true);

      // R5-#14 (and #11): Ola removes Ala; Ala's device keeps writing and
      // greeting; Ala must stay removed, also after Ola's restart.
      mesh.mark('Ola removes Ala');
      await ola.remove(ala);
      bool removed() {
        final FriendProfile? f = ola.friendOf(ala);
        return f == null || f.status != FriendRelationshipStatus.accepted;
      }

      expect(removed(), isTrue);
      await ala.send(ola, 'wróć do mnie');
      await ola.holdsFor(
        'Ala staying removed',
        () async => removed(),
        period: const Duration(seconds: 15),
      );
      await ola.restart();
      await ola.holdsFor(
        'Ala staying removed after a restart',
        () async => removed(),
        period: const Duration(seconds: 15),
      );
      mesh.report();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
