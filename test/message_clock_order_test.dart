import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/health/clock_skew_tracker.dart';

import 'support/friends_world.dart';

/// The order of a chat when a clock is wrong: a friend's message that came
/// straight from them never goes above a message they are known to have
/// had (one of theirs already here, or one from here they confirmed). One
/// phone's clock behind (or this phone's ahead) put the answer above the
/// question. What really was written before (a message that waited while
/// this phone was away, a late copy) still goes where its time says.

const Duration _behind = Duration(hours: 1);

List<String> _texts(List<ChatMessage> thread) => <String>[
  for (final ChatMessage m in thread)
    if (!m.isSystem) m.text,
];

ChatMessage _one(List<ChatMessage> thread, String text) =>
    thread.singleWhere((ChatMessage m) => m.text == text);

void main() {
  setUp(ClockSkewTracker.instance.clear);
  tearDown(ClockSkewTracker.instance.clear);

  test('a friend whose clock is an hour behind has the answer shown below '
      'the question, at the time it came, and their next message below '
      'it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.send(a, b, 'Idziesz dziś?');
    await w.assertDelivered(b, 'Idziesz dziś?', from: a);
    await w.advance(const Duration(minutes: 2));
    // B's phone clock is one hour behind (a manual time, a wrong zone).
    await b.hub.sendLocalMessage(
      peerAddress: a.address,
      text: 'Tak, o 18',
      sentAtMillis: w.now - _behind.inMilliseconds,
    );
    await w.assertDelivered(a, 'Tak, o 18', from: b);
    final int cameAt = w.now;
    await w.advance(const Duration(minutes: 1));
    await b.hub.sendLocalMessage(
      peerAddress: a.address,
      text: 'Będę z Kasią',
      sentAtMillis: w.now - _behind.inMilliseconds,
    );
    await w.assertDelivered(a, 'Będę z Kasią', from: b);

    final List<ChatMessage> atA = await a.thread(b);
    expect(_texts(atA), <String>['Idziesz dziś?', 'Tak, o 18', 'Będę z Kasią']);
    // The time under it is when it came, not an hour before the question.
    expect(
      _one(atA, 'Tak, o 18').sentAtMillis,
      inInclusiveRange(cameAt - 5000, cameAt),
    );
  });

  test('in a group too: a member an hour behind answers below the '
      'question on the phone that asked, and their next message below '
      'that', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    await w.befriendAll();
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone c = w['C'];
    final String group = await w.createGroup(a, 'Ekipa', <FriendsPhone>[b, c]);
    await w.sendGroup(a, group, 'Kto bierze piłkę?');
    await w.advance(const Duration(minutes: 1));
    for (final String text in <String>['Ja', 'I pompkę']) {
      await b.hub.sendGroupMessage(
        groupId: group,
        text: text,
        sentAtMillis: w.now - _behind.inMilliseconds,
      );
      await w.settle();
      await w.advance(const Duration(seconds: 30));
    }
    expect(await w.groupTexts(a, group), <String>[
      'Kto bierze piłkę?',
      'Ja',
      'I pompkę',
    ]);
  });

  test('a message written while this phone was away, before a message from '
      'here its sender never had, keeps its time and its place', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.setOnline(a, false);
    final int written = w.now;
    await w.send(b, a, 'Jesteś już?');
    await w.advance(const Duration(minutes: 3));
    await w.send(a, b, 'Spóźnię się 10 minut');
    await w.advance(const Duration(minutes: 3));
    await w.setOnline(a, true);
    await w.assertDelivered(a, 'Jesteś już?', from: b);
    await w.assertDelivered(b, 'Spóźnię się 10 minut', from: a);

    final List<ChatMessage> atA = await a.thread(b);
    expect(_texts(atA), <String>['Jesteś już?', 'Spóźnię się 10 minut']);
    expect(_one(atA, 'Jesteś już?').sentAtMillis, written);
  });
}
