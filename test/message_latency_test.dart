import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';

import 'support/friends_world.dart';

/// How fast messages travel, on the virtual clock of a [FriendsWorld]
/// (the real relay engines, social controllers and reliable transports):
/// each test states the longest a step may take, so a slower path is
/// caught. Time that passes inside [FriendsWorld.settle] is only the
/// simulated network's own delay.

/// The outgoing message [text] from [from] to [to], or `null`.
Future<ChatMessage?> _sent(
  FriendsPhone from,
  FriendsPhone to,
  String text,
) async {
  for (final ChatMessage m in await from.thread(to)) {
    if (m.direction == ChatMessageDirection.outgoing && m.text == text) {
      return m;
    }
  }
  return null;
}

void main() {
  group('both online', () {
    test('a message, its delivery mark and its read mark take no wait '
        'beyond the network', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final int sentAt = w.now;
      await w.send(w['A'], w['B'], 'od razu');
      await w.assertDelivered(
        w['B'],
        'od razu',
        from: w['A'],
        within: Duration.zero,
      );
      expect(
        await w['A'].deliveryOf(w['B'], 'od razu'),
        ChatMessageDeliveryState.delivered,
      );
      await w['B'].hub.markConversationRead(w['A'].address);
      await w.settle();
      expect((await _sent(w['A'], w['B'], 'od razu'))?.isRead, isTrue);
      expect(w.now - sentAt, lessThan(2000));
    });

    test('a group message reaches every online member with no wait', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
      ]);
      final String id = await w.createGroup(w['A'], 'Szybcy', <FriendsPhone>[
        w['B'],
        w['C'],
        w['D'],
      ]);
      final int sentAt = w.now;
      await w.sendGroup(w['B'], id, 'wszyscy naraz');
      for (final String n in <String>['A', 'C', 'D']) {
        expect(await w.groupTexts(w[n], id), <String>[
          'wszyscy naraz',
        ], reason: n);
      }
      expect(w.now - sentAt, lessThan(2000));
    });
  });

  test('a message for a locked phone is in its sealed inbox and announced '
      'with no wait', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.lock(w['B']);
    final int sentAt = w.now;
    await w.send(w['A'], w['B'], 'zablokowany');
    expect(w['B'].messageNotices, hasLength(1));
    expect(w.now - sentAt, lessThan(2000));
    await w.unlock(w['B']);
    expect(await w['B'].textsFrom(w['A']), <String>['zablokowany']);
  });

  test('a message for a phone that was offline arrives within 10 seconds '
      'of it coming back, the sender gone', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>[
      'A',
      'B',
      'M1',
      'M2',
    ]);
    await w.chooseMailboxes(w['B'], <FriendsPhone>[w['M1'], w['M2']]);
    await w.setOnline(w['B'], false);
    await w.send(w['A'], w['B'], 'po powrocie');
    await w.advance(const Duration(seconds: 10));
    await w.setOnline(w['A'], false);
    await w.setOnline(w['B'], true);
    await w.assertDelivered(
      w['B'],
      'po powrocie',
      from: w['A'],
      within: const Duration(seconds: 10),
    );
  });
}
