import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';

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

  /// Whether every message [from] sent is past "Czeka u Ciebie": taken by
  /// the recipient's phone (its service), as the sender's relay layer sees.
  bool allTaken(FriendsPhone from) {
    final Iterable<MessageDeliveryProgress> all =
        from.engine.progress.value.messages.values;
    return all.isNotEmpty &&
        all.every(
          (MessageDeliveryProgress p) => p.delivered > 0 || p.pending == 0,
        );
  }

  // The reported "Czeka u Ciebie — odbiorca offline" while the recipient's
  // Zen receives in the background: its phone was off the network for a
  // while and came back; nothing told the sender, whose next try was 10,
  // 30 or 60 minutes away (in a world with no mailboxes for it, an hour
  // and more went by). The sender's open Zen now asks again every 2
  // minutes, one small frame.
  for (final int minutes in <int>[1, 5, 20, 45, 180]) {
    test('a message for a locked phone off the network for $minutes min is '
        'taken within 2 minutes of it coming back, the sender Zen open '
        'and no mailboxes', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      await w.lock(w['B']);
      await w.setOnline(w['B'], false);
      await w.send(w['A'], w['B'], 'jestem');
      await w.send(w['A'], w['B'], 'i jeszcze');
      await w.advance(Duration(minutes: minutes));
      expect(allTaken(w['A']), isFalse, reason: 'it was away');
      final int back = w.now;
      await w.setOnline(w['B'], true);
      while (!allTaken(w['A'])) {
        expect(
          w.now - back,
          lessThanOrEqualTo(
            const Duration(minutes: 2, seconds: 30).inMilliseconds,
          ),
          reason:
              'still "Czeka u Ciebie" ${(w.now - back) ~/ 1000}s after it '
              'came back',
        );
        await w.advance(const Duration(seconds: 5));
      }
      await w.unlock(w['B']);
      expect(await w['B'].textsFrom(w['A']), <String>['jestem', 'i jeszcze']);
    });
  }

  test('while the recipient stays away for 3 hours, the asking costs one '
      'small frame per 2 minutes for it, however many messages wait', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    await w.lock(w['B']);
    await w.setOnline(w['B'], false);
    for (int i = 0; i < 8; i++) {
      await w.send(w['A'], w['B'], 'wiadomość $i');
    }
    await w.advance(const Duration(minutes: 5));
    final int before = w.net.stats.byType['message'] ?? 0;
    await w.advance(const Duration(hours: 3));
    final int sent = (w.net.stats.byType['message'] ?? 0) - before;
    // 90 probes in 3 hours, plus each message's own few long-backoff tries.
    expect(sent, lessThanOrEqualTo(90 + 8 * 4), reason: '$sent messages sent');
    expect(sent, greaterThanOrEqualTo(80), reason: 'it kept asking');
  });
}
