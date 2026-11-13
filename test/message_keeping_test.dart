import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';

import 'support/friends_world.dart';

/// A chat message is acknowledged to its sender (and remembered as seen)
/// only once the receiving app has it on its disk: an app that dies or
/// fails to write it in between gets it again, once, and the sender shows
/// "delivered" only then.

bool _isMessageFrom(SignalTransportFrame frame, FriendsPhone sender) =>
    frame.payload['type'] == 'message' && frame.from == sender.address;

void main() {
  test('an app that dies after its relay layer took a message in gets it '
      'again: nothing was acknowledged before the chat had it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // B's app dies right after its node took a frame in: the relay engine
    // handles it, nothing reaches the chat and nobody answers for it.
    final List<SimHandler> app = List<SimHandler>.of(b.sim.handlers);
    b.sim.handlers
      ..clear()
      ..add((SignalTransportFrame frame) async {
        await b.engine.handleIncoming(frame);
        return true;
      });
    await w.send(a, b, 'Zgubiona');
    await w.settle();
    expect(
      await a.deliveryOf(b, 'Zgubiona'),
      isNot(ChatMessageDeliveryState.delivered),
      reason: 'B never had it',
    );
    // B starts again on the same stores.
    b.sim.handlers
      ..clear()
      ..addAll(app);
    await w.advance(const Duration(hours: 2));

    expect(await b.textsFrom(a), <String>['Zgubiona']);
    expect(
      await a.deliveryOf(b, 'Zgubiona'),
      ChatMessageDeliveryState.delivered,
    );
  });

  test('a write that fails once: the message comes again, is kept exactly '
      'once, and the sender shows it delivered only then', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    int failures = 0;
    bool failing = true;
    b.appKeeps = (SignalTransportFrame frame) {
      if (failing && _isMessageFrom(frame, a)) {
        failures += 1;
        return false;
      }
      return true;
    };
    await w.send(a, b, 'Raz tylko');
    expect(failures, 1);
    expect(await b.textsFrom(a), isEmpty);
    expect(
      await a.deliveryOf(b, 'Raz tylko'),
      isNot(ChatMessageDeliveryState.delivered),
      reason: 'B failed to keep it: it must not show as delivered',
    );

    failing = false;
    await w.advance(const Duration(minutes: 5));
    expect(await b.textsFrom(a), <String>['Raz tylko']);
    expect(
      await a.deliveryOf(b, 'Raz tylko'),
      ChatMessageDeliveryState.delivered,
    );
    // Later copies (a mailbox's, a retry) change nothing.
    await w.advance(const Duration(minutes: 30));
    expect(await b.textsFrom(a), <String>['Raz tylko']);
  });

  test('while the stored friends cannot be read a message is not '
      'confirmed: it comes again and is kept once they can be', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // B's app starts on a busy phone: its friends do not read back.
    b.friendListUnreadable = true;
    await w.restartApp(b);
    expect(b.state.snapshotUnreadable, isTrue);
    await w.send(a, b, 'Nie zgub mnie');
    await w.advance(const Duration(minutes: 5));
    expect(await b.textsFrom(a), isEmpty);
    expect(
      await a.deliveryOf(b, 'Nie zgub mnie'),
      isNot(ChatMessageDeliveryState.delivered),
      reason: 'B could not keep it: it must not show as delivered',
    );

    // The next start reads them; the message comes again and is kept.
    b.friendListUnreadable = false;
    await w.restartApp(b);
    expect(b.state.snapshotUnreadable, isFalse);
    await w.until(
      () async => (await b.textsFrom(a)).contains('Nie zgub mnie'),
      within: const Duration(hours: 2),
      reason: 'the message coming again',
    );
    await w.until(
      () async =>
          await a.deliveryOf(b, 'Nie zgub mnie') ==
          ChatMessageDeliveryState.delivered,
      within: const Duration(minutes: 30),
      reason: 'the message showing delivered',
    );
    expect(await b.textsFrom(a), <String>['Nie zgub mnie']);
  });

  test('a group message too: not confirmed while the groups cannot be '
      'read, kept once they can be', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone c = w['C'];
    final String id = await w.createGroup(a, 'Klub', <FriendsPhone>[b, c]);
    b.friendListUnreadable = true;
    await w.restartApp(b);
    await w.sendGroup(a, id, 'Do wszystkich');
    await w.advance(const Duration(minutes: 5));
    expect(await w.groupTexts(c, id), contains('Do wszystkich'));
    expect(await w.groupTexts(b, id), isNot(contains('Do wszystkich')));

    b.friendListUnreadable = false;
    await w.restartApp(b);
    await w.until(
      () async => (await w.groupTexts(b, id)).contains('Do wszystkich'),
      within: const Duration(hours: 2),
      reason: 'the group message coming again',
    );
  });

  test('an edit that comes before its message is not confirmed: a restart '
      'before the message comes does not lose it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    // B's app does not keep A's message for now (its write fails), so the
    // edit that follows finds nothing to edit.
    bool failing = true;
    b.appKeeps = (SignalTransportFrame frame) =>
        !(failing && _isMessageFrom(frame, a));
    await w.send(a, b, 'Spotkanie o 17');
    final String messageId = (await a.thread(
      b,
    )).firstWhere((ChatMessage m) => m.text == 'Spotkanie o 17').id;
    // A's edit, as its app sends it (on the world's clock).
    await a.container
        .read(signalTransportProvider)
        .send(
          remoteAddress: b.address,
          payload: <String, dynamic>{
            'type': 'msg_edit',
            'msgId': messageId,
            'text': 'Spotkanie o 18',
            'at': w.now,
          },
        );
    await w.settle();
    expect(await b.textsFrom(a), isEmpty);
    // B's app starts again before the message comes: what waited in its
    // memory is gone.
    await w.restartApp(b);
    failing = false;
    await w.until(
      () async => (await b.textsFrom(a)).contains('Spotkanie o 18'),
      within: const Duration(hours: 2),
      reason: 'the edit reaching B after the restart',
    );
    expect(await b.textsFrom(a), <String>['Spotkanie o 18']);
  });

  test('an app that never answers for one message holds back nothing '
      'else: another friend\'s message is kept and confirmed', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone c = w['C'];
    b.appKeeps = (SignalTransportFrame frame) =>
        _isMessageFrom(frame, a) ? null : true;
    await w.send(a, b, 'Utknie');
    await w.send(c, b, 'Przejdzie');
    await w.deliver();
    expect(await b.textsFrom(c), <String>['Przejdzie']);
    expect(
      await c.deliveryOf(b, 'Przejdzie'),
      ChatMessageDeliveryState.delivered,
    );
    expect(await b.textsFrom(a), isEmpty);
    expect(
      await a.deliveryOf(b, 'Utknie'),
      isNot(ChatMessageDeliveryState.delivered),
    );

    // Once the app answers again, the next copy is kept.
    b.appKeeps = null;
    await w.advance(const Duration(minutes: 10));
    expect(await b.textsFrom(a), <String>['Utknie']);
    expect(await a.deliveryOf(b, 'Utknie'), ChatMessageDeliveryState.delivered);
  });
}
