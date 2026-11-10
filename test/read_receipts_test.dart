import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/messages/message_delivery_status.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import 'support/friends_world.dart';

/// Read marks in one-to-one chats: "Przeczytano" under one's own message
/// only when the friend's receipt says so, one receipt per reading, and a
/// chat read on one device of the account is read on its others.

LifecycleSnapshot _screen(
  FriendsWorld w,
  int generation, {
  AppVisibilityState v = AppVisibilityState.foregroundFocused,
}) => LifecycleSnapshot(
  visibility: v,
  generation: generation,
  capturedAtMillis: w.now,
);

ChatMessage _own(List<ChatMessage> thread, String text) =>
    thread.singleWhere((ChatMessage m) => m.isOutgoing && m.text == text);

ChatMessage _theirs(List<ChatMessage> thread, String text) =>
    thread.singleWhere(
      (ChatMessage m) =>
          m.direction == ChatMessageDirection.incoming && m.text == text,
    );

MessageDeliveryStage _shown(FriendsWorld w, ChatMessage m) =>
    MessageDeliveryStatus.of(m, nowMillis: w.now)!.stage;

/// The read receipts [p]'s app gets.
List<String> _receiptsAt(FriendsPhone p) {
  final List<String> receipts = <String>[];
  final StreamSubscription<SignalTransportFrame> sub = p.appTransport.frames
      .listen((SignalTransportFrame f) {
        if (f.payload['type'] == 'message_read') {
          receipts.add('${f.payload['msgId']}');
        }
      });
  addTearDown(sub.cancel);
  return receipts;
}

void main() {
  test(
    'reading a friend\'s message never marks one\'s own messages read: '
    'messages that crossed stay "delivered" until the friend reads them',
    () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      // A has no network for a while; both write meanwhile.
      await w.setOnline(a, false);
      await w.send(b, a, 'Jesteś już?');
      await w.advance(const Duration(minutes: 1));
      await w.send(a, b, 'Spóźnię się 10 minut');
      await w.setOnline(a, true);
      await w.assertDelivered(b, 'Spóźnię się 10 minut', from: a);
      await w.assertDelivered(a, 'Jesteś już?', from: b);

      // B reads A's message; A does not open the chat with B.
      await b.hub.enterConversation(a.address);
      await w.deliver();

      expect(_theirs(await a.thread(b), 'Jesteś już?').readAtMillis, isNull);
      final ChatMessage mine = _own(await b.thread(a), 'Jesteś już?');
      expect(mine.readAtMillis, isNull);
      expect(_shown(w, mine), isNot(MessageDeliveryStage.read));
      expect(_theirs(await b.thread(a), 'Spóźnię się 10 minut').isRead, isTrue);
    },
  );

  test('a friend\'s message landing in the open chat does not mark one\'s '
      'own unread message read', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await b.hub.setLifecycle(_screen(w, 20));
    await b.hub.enterConversation(a.address);
    await w.send(b, a, 'Pytanie');
    await w.assertDelivered(a, 'Pytanie', from: b);
    // A writes about something else without opening B's message.
    await w.send(a, b, 'Inna sprawa');
    await w.assertDelivered(b, 'Inna sprawa', from: a);
    await w.deliver();

    final ChatMessage mine = _own(await b.thread(a), 'Pytanie');
    expect(mine.readAtMillis, isNull);
    expect(_shown(w, mine), isNot(MessageDeliveryStage.read));
    expect(_theirs(await b.thread(a), 'Inna sprawa').isRead, isTrue);
  });

  test('the friend\'s receipt still shows "Przeczytano" under one\'s '
      'message and every earlier one', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.send(a, b, 'Pierwsza');
    await w.advance(const Duration(seconds: 2));
    await w.send(a, b, 'Druga');
    await w.deliver();
    for (final ChatMessage m in (await a.thread(
      b,
    )).where((ChatMessage m) => m.isOutgoing)) {
      expect(_shown(w, m), isNot(MessageDeliveryStage.read));
    }

    await b.hub.enterConversation(a.address);
    await w.deliver();

    final List<ChatMessage> atA = await a.thread(b);
    expect(_shown(w, _own(atA, 'Pierwsza')), MessageDeliveryStage.read);
    expect(_shown(w, _own(atA, 'Druga')), MessageDeliveryStage.read);
  });

  test('a receipt naming one of the friend\'s own messages marks nothing '
      'read', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await w.send(b, a, 'Moja');
    await w.advance(const Duration(seconds: 2));
    await w.send(a, b, 'Twoja');
    await w.deliver();
    final ChatMessage theirs = _theirs(await b.thread(a), 'Twoja');

    await b.hub.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageRead,
        sender: a.address,
        messageId: theirs.id,
      ),
      receivedAtMillis: w.now,
    );

    final List<ChatMessage> atB = await b.thread(a);
    expect(_own(atB, 'Moja').readAtMillis, isNull);
    expect(_theirs(atB, 'Twoja').readAtMillis, isNull);
  });

  test('reading sends one receipt, and opening the chat again sends none '
      'for the older messages', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final List<String> receipts = _receiptsAt(a);
    for (final String text in <String>['jeden', 'dwa', 'trzy']) {
      await w.send(a, b, text);
      await w.advance(const Duration(seconds: 2));
    }
    await w.deliver();

    await b.hub.enterConversation(a.address);
    b.hub.leaveConversation(a.address);
    await w.deliver();
    expect(receipts, hasLength(1));
    expect(receipts.single, _theirs(await b.thread(a), 'trzy').id);

    for (int i = 0; i < 2; i++) {
      await b.hub.enterConversation(a.address);
      b.hub.leaveConversation(a.address);
      await w.deliver();
    }
    expect(receipts, hasLength(1), reason: 'nothing new was read');
    for (final ChatMessage m in (await b.thread(
      a,
    )).where((ChatMessage m) => m.direction == ChatMessageDirection.incoming)) {
      expect(m.isRead, isTrue, reason: m.text);
    }
  });

  test('a chat read on one device of the account is read on the other: '
      'no unread count, no notification', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone b2 = await w.addDevice(b, 'B2');
    await b.hub.setLifecycle(_screen(w, 20));
    await w.send(a, b, 'Na obu?');
    await w.deliver();
    expect(await b.textsFrom(a), contains('Na obu?'));
    expect(await b2.textsFrom(a), contains('Na obu?'));
    expect(b2.shownMessageNotices, hasLength(1));

    // Read on B (the phone); B2 (the computer) is in the background.
    await b.hub.enterConversation(a.address);
    await w.deliver();
    expect(b.state.friendByAddress(a.address)?.unreadCount, 0);
    expect(b2.shownMessageNotices, isEmpty);
    expect(_theirs(await b2.thread(a), 'Na obu?').isRead, isTrue);

    // B2 comes to the screen later.
    await b2.hub.setLifecycle(_screen(w, 30, v: AppVisibilityState.foreground));
    expect(b2.state.friendByAddress(a.address)?.unreadCount, 0);
    expect(b2.state.friendByAddress(a.address)?.lastMessagePreview, 'Na obu?');
    expect(b2.state.backgroundAlerts, isEmpty);
    // Nothing went back to A from B2.
    final List<String> receipts = _receiptsAt(a);
    await w.deliver();
    expect(receipts, isEmpty);
  });

  test('a chat read on one device stays unread on the other for what came '
      'after it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone b2 = await w.addDevice(b, 'B2');
    await b.hub.setLifecycle(_screen(w, 20));
    // B2 is on the screen, though not looked at (a window behind another).
    await b2.hub.setLifecycle(_screen(w, 10, v: AppVisibilityState.foreground));
    await w.send(a, b, 'Raz');
    await w.deliver();
    expect(b2.state.friendByAddress(a.address)?.unreadCount, 1);

    // B reads "Raz" and leaves the chat; then "Dwa" comes.
    await b.hub.enterConversation(a.address);
    b.hub.leaveConversation(a.address);
    await w.send(a, b, 'Dwa');
    await w.deliver();
    expect(b.state.friendByAddress(a.address)?.unreadCount, 1);
    expect(b2.state.friendByAddress(a.address)?.unreadCount, 1);
    final List<ChatMessage> atB2 = await b2.thread(a);
    expect(_theirs(atB2, 'Raz').isRead, isTrue);
    expect(_theirs(atB2, 'Dwa').isRead, isFalse);
  });

  test('a device of the account on 1.16.4 takes nothing from the copy of a '
      'reading', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone b2 = await w.addDevice(b, 'B2');
    // What 1.16.4 does with a copy from another device of the account: it
    // knows these kinds only, and drops any other.
    const Set<String> known1164 = <String>{
      'message',
      'disappear_timer',
      'group_message',
      'msg_react',
      'msg_edit',
      'msg_delete',
    };
    final List<Map<String, dynamic>> dropped = <Map<String, dynamic>>[];
    b2.mirrored = (String peer, Map<String, dynamic> p) async {
      if (known1164.contains(p['type'])) {
        await b2.hub.recordMirroredSend(peer, p);
      } else {
        dropped.add(p);
      }
    };
    // Anything that reaches B2 bare, as a receipt from someone.
    final List<SignalTransportFrame> bare = <SignalTransportFrame>[];
    final StreamSubscription<SignalTransportFrame> sub = b2.appTransport.frames
        .listen((SignalTransportFrame f) {
          if (f.payload['type'] == 'message_read') {
            bare.add(f);
          }
        });
    addTearDown(sub.cancel);
    await b.hub.setLifecycle(_screen(w, 20));
    await b2.hub.setLifecycle(_screen(w, 21, v: AppVisibilityState.foreground));
    await w.send(b, a, 'Moja');
    await w.send(a, b, 'Twoja');
    await w.deliver();
    Future<List<String>> marks() async => <String>[
      for (final ChatMessage m in await b2.thread(a))
        '${m.text}:${m.readAtMillis}',
    ];
    final List<String> b2Before = await marks();
    expect(b2Before, hasLength(2));

    await b.hub.enterConversation(a.address);
    await w.deliver();

    expect(dropped, <Map<String, dynamic>>[
      <String, dynamic>{
        'type': 'message_read',
        'msgId': _theirs(await b.thread(a), 'Twoja').id,
      },
    ]);
    expect(bare, isEmpty);
    expect(await marks(), b2Before);
    expect(b2.state.friendByAddress(a.address)?.unreadCount, 1);
    // The friend got its receipt all the same.
    expect(
      _shown(w, _own(await a.thread(b), 'Twoja')),
      MessageDeliveryStage.read,
    );
  });
}
