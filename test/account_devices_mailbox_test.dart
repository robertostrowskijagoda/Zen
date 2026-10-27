import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/relay/relay_models.dart';

import 'support/friends_world.dart';

/// Mailboxes when a friend's account has several devices (a second phone, a
/// computer) or moves to a new phone: on simulated friends (`FriendsWorld`)
/// with the real relay engines, social controllers and account routing.

/// How many envelopes for [owner] the phone [holder] keeps.
Future<int> _heldFor(FriendsPhone holder, FriendsPhone owner) async =>
    (await holder.relayStore.load()).mailbox[owner.address]?.length ?? 0;

/// The id of the message [text] [from] sent to [to].
Future<String> _idOf(FriendsPhone from, FriendsPhone to, String text) async =>
    (await from.thread(to))
        .firstWhere(
          (ChatMessage m) =>
              m.direction == ChatMessageDirection.outgoing && m.text == text,
        )
        .id;

void main() {
  group('a friend with two devices', () {
    test('each device has its own mailboxes; a message waits there for both '
        'and reaches both, and the sender counts the friend once', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'M1',
        'M2',
      ]);
      final FriendsPhone b2 = await w.addDevice(
        w['B'],
        'B2',
        device: SimDevice.desktop,
      );

      // The second device announced itself to A, who took it as Bartek's.
      final RelayState aState = await w['A'].relayStore.load();
      expect(aState.peers[b2.address]?.keys, isNotNull);
      expect(aState.peers[b2.address]?.relays, isNotEmpty);
      expect(aState.peers[b2.address]?.deviceClass, RelayDeviceClass.desktop);
      // And it chose mailboxes among the account's friends.
      expect(await w.mailboxesOf(b2), isNotEmpty);

      await w.setOnline(w['B'], false);
      await w.setOnline(b2, false);
      await w.send(w['A'], w['B'], 'do obu');
      await w.advance(const Duration(seconds: 30));
      // Copies for each device, sealed for each device's own key.
      int forB = 0;
      int forB2 = 0;
      for (final FriendsPhone m in <FriendsPhone>[w['M1'], w['M2']]) {
        forB += await _heldFor(m, w['B']);
        forB2 += await _heldFor(m, b2);
      }
      expect(forB, greaterThan(0));
      expect(forB2, greaterThan(0));

      await w.setOnline(w['B'], true);
      await w.setOnline(b2, true);
      await w.assertDelivered(w['B'], 'do obu', from: w['A']);
      await w.assertDelivered(b2, 'do obu', from: w['A']);
      expect(await b2.textsFrom(w['A']), <String>['do obu']);

      final String id = await _idOf(w['A'], w['B'], 'do obu');
      final MessageDeliveryProgress? progress =
          w['A'].engine.progress.value.messages[id];
      expect(progress?.recipients, 1, reason: 'one friend, not two devices');
      expect(progress?.delivered, 1);
      expect(
        await w['A'].deliveryOf(w['B'], 'do obu'),
        ChatMessageDeliveryState.delivered,
      );
    });

    test('mail from the second device waits in the sender\'s friends\' '
        'mailboxes like mail from the first', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'M1',
      ]);
      final FriendsPhone b2 = await w.addDevice(w['B'], 'B2');
      await w.setOnline(w['A'], false);
      await w.send(b2, w['A'], 'z drugiego');
      await w.advance(const Duration(seconds: 30));
      expect(await _heldFor(w['M1'], w['A']), greaterThan(0));
      await w.setOnline(w['A'], true);
      // Heard as Bartek, in the one conversation with him.
      await w.assertDelivered(w['A'], 'z drugiego', from: w['B']);
    });
  });

  group('a friend who moved to a new phone', () {
    test('the new phone gets its mail through its own mailboxes; the old '
        'phone, gone quiet, stops being a mailbox and the new one takes its '
        'place', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
      ]);
      expect(await w.mailboxesOf(w['A']), contains(w['B']));

      // Bartek moves to a new phone; the old one is switched off for good
      // (not unlinked: he did not get round to it).
      final FriendsPhone fresh = await w.addDevice(w['B'], 'B-new');
      await w.setOnline(w['B'], false);

      await w.setOnline(fresh, false);
      await w.send(w['A'], w['B'], 'po przeprowadzce');
      await w.advance(const Duration(seconds: 30));
      await w.setOnline(fresh, true);
      await w.assertDelivered(fresh, 'po przeprowadzce', from: w['A']);
      await w.until(
        () async =>
            await w['A'].deliveryOf(w['B'], 'po przeprowadzce') ==
            ChatMessageDeliveryState.delivered,
        reason: 'the sender seeing it delivered',
      );

      // Days pass: Bartek is seen every day (on the new phone), but his old
      // phone answers nothing. It is replaced by his new one.
      await w.advance(
        const Duration(days: 4),
        step: const Duration(minutes: 10),
      );
      final List<FriendsPhone> boxes = await w.mailboxesOf(w['A']);
      expect(boxes, isNot(contains(w['B'])));
      expect(boxes, contains(fresh));
      expect(w['A'].engine.overview.value.quiet, isEmpty);
    });

    test('a hand-picked mailbox follows the friend to the new phone', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
      await w.chooseMailboxes(w['A'], <FriendsPhone>[w['B']]);
      final FriendsPhone fresh = await w.addDevice(w['B'], 'B-new');
      await w.setOnline(w['B'], false);
      await w.advance(
        const Duration(days: 4),
        step: const Duration(minutes: 10),
      );
      // Still Bartek, chosen by hand, now on the phone that answers.
      expect(await w.mailboxesOf(w['A']), <FriendsPhone>[fresh]);
      expect(w['A'].engine.overview.value.isAutomatic, isFalse);
      expect(w['A'].engine.overview.value.mailboxFriends, <String>[
        w['B'].address,
      ]);
    });

    test('once the old phone is unlinked nothing goes there and it is no '
        'mailbox any more', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
      expect(await w.mailboxesOf(w['A']), contains(w['B']));
      final FriendsPhone fresh = await w.addDevice(w['B'], 'B-new');
      w.unlink(w['B']);
      await w.advance(const Duration(seconds: 30));
      final List<FriendsPhone> boxes = await w.mailboxesOf(w['A']);
      expect(boxes, isNot(contains(w['B'])));
      expect(boxes, contains(fresh));
      await w.send(w['A'], w['B'], 'tylko na nowy');
      await w.assertDelivered(fresh, 'tylko na nowy', from: w['A']);
      expect(await w['B'].textsFrom(w['A']), isNot(contains('tylko na nowy')));
    });
  });

  group("the account's devices", () {
    test(
      'mailboxes picked by hand on one device are picked on the others',
      () async {
        final FriendsWorld w = await FriendsWorld.create(<String>[
          'A',
          'B',
          'C',
        ]);
        final FriendsPhone a2 = await w.addDevice(w['A'], 'A2');
        final RelayMailboxSyncDomain here = RelayMailboxSyncDomain(
          w['A'].engine,
        );
        final RelayMailboxSyncDomain there = RelayMailboxSyncDomain(a2.engine);
        final int before = w['A'].engine.mailboxChoiceRevision.value;

        await w['A'].engine.setManualRelays(<String>[w['C'].address]);
        expect(w['A'].engine.mailboxChoiceRevision.value, before + 1);
        await there.write((await here.read())!);
        await w.settleMailboxes();
        expect(await w.mailboxesOf(a2), <FriendsPhone>[w['C']]);
        expect(a2.engine.overview.value.isAutomatic, isFalse);

        await w['A'].engine.setManualRelays(null);
        await there.write((await here.read())!);
        expect(a2.engine.overview.value.isAutomatic, isTrue);
      },
    );
  });
}
