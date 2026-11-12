import 'package:flutter_test/flutter_test.dart';

import 'support/friends_world.dart';

/// The disappearing-messages timer of a conversation is the one set last,
/// the same on every phone of it: a message written before a change and
/// arriving after it does not bring the old timer back.

void main() {
  test('disappearing messages switched off do not come back on when a '
      'message the friend wrote before the change arrives after it', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    await a.hub.setDisappearingTimer(b.address, 3600);
    await w.deliver();
    expect(b.state.disappearSecondsFor(a.address), 3600);
    // A is out of reach; B writes meanwhile (the timer is still on).
    await w.setOnline(a, false);
    await w.send(b, a, 'Zdjęcie dowodu wyślę później');
    await w.advance(const Duration(minutes: 1));
    // A, still offline, switches disappearing messages off: these talks
    // are to be kept.
    await a.hub.setDisappearingTimer(b.address, 0);
    expect(a.state.disappearSecondsFor(b.address), 0);
    await w.setOnline(a, true);
    await w.advance(const Duration(minutes: 3));
    expect(await a.textsFrom(b), contains('Zdjęcie dowodu wyślę później'));
    expect(
      a.state.disappearSecondsFor(b.address),
      0,
      reason: 'A switched it off after B wrote',
    );
    expect(b.state.disappearSecondsFor(a.address), 0);
    // A writes again: the timer travels with the message, and stays off.
    await w.send(a, b, 'Dobra');
    await w.advance(const Duration(minutes: 1));
    expect(a.state.disappearSecondsFor(b.address), 0);
    expect(b.state.disappearSecondsFor(a.address), 0);
  });

  test('both changing it while apart: both phones end with the later '
      'change', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone c = w['C'];
    await a.hub.setDisappearingTimer(b.address, 3600);
    await w.deliver();
    w.partition(<FriendsPhone>[a], <FriendsPhone>[b, c]);
    await a.hub.setDisappearingTimer(b.address, 0);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.hub.setDisappearingTimer(a.address, 86400);
    await w.send(b, a, 'Pisane przy dniu');
    await w.send(a, b, 'Pisane bez timera');
    await w.advance(const Duration(minutes: 1));
    w.heal();
    await w.advance(const Duration(minutes: 30));
    expect(await a.textsFrom(b), contains('Pisane przy dniu'));
    expect(await b.textsFrom(a), contains('Pisane bez timera'));
    expect(a.state.disappearSecondsFor(b.address), 86400);
    expect(b.state.disappearSecondsFor(a.address), 86400);
  });

  test('in a group a member\'s older message does not undo another '
      'member\'s later change', () async {
    final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
    final FriendsPhone a = w['A'];
    final FriendsPhone b = w['B'];
    final FriendsPhone c = w['C'];
    final String id = await w.createGroup(a, 'Klub', <FriendsPhone>[b, c]);
    await a.hub.setDisappearingTimer('group:$id', 3600);
    await w.deliver();
    expect(c.state.disappearSecondsFor('group:$id'), 3600);
    // B is cut off and writes; C switches the timer off meanwhile.
    w.partition(<FriendsPhone>[b], <FriendsPhone>[a, c]);
    await w.sendGroup(b, id, 'Stara wiadomość');
    await w.advance(const Duration(minutes: 1));
    await c.hub.setDisappearingTimer('group:$id', 0);
    await w.advance(const Duration(minutes: 1));
    w.heal();
    await w.advance(const Duration(minutes: 30));
    expect(await w.groupTexts(a, id), contains('Stara wiadomość'));
    for (final FriendsPhone p in <FriendsPhone>[a, b, c]) {
      expect(p.state.disappearSecondsFor('group:$id'), 0, reason: p.name);
    }
  });
}
