import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_decisions.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

void main() {
  test('a person under a ban appeals once; the top sees it and can lift the '
      'ban', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String b1 = w['B1'].myKey!;
    await w['S'].ban(target: b1, kind: 'content', entryId: 'h', reason: 'spam');
    await w.net.run();
    await w.approve('B', PyrT.ban);
    final PyramidState st = w['B1'].state!;
    final List<PyrBan> bans = bansAgainst(w['B1'], st, b1);
    expect(bans, hasLength(1));
    final String banId = bans.single.id;

    expect(await w['B1'].appeal(banId, '  '), isFalse, reason: 'no reason');
    expect(await w['B1'].appeal(banId, 'To pomyłka'), isTrue);
    expect(w['B1'].sentAppeals, contains(banId));
    expect(await w['B1'].appeal(banId, 'Jeszcze raz'), isFalse, reason: 'once');
    await w.net.run();
    expect(w['S'].appeals, hasLength(1));
    expect(w['S'].appeals.single['rep'], banId);
    expect(w['S'].appeals.single['k'], b1);

    // The status survives a restart.
    await w['B1'].load();
    expect(w['B1'].sentAppeals, contains(banId));

    // The top lifts the ban: it is no longer active, but still shown as
    // lifted because it was appealed.
    await w['S'].topDecision(<String, dynamic>{'t': PyrT.unban, 'ban': banId});
    await w.net.run();
    await w.approve('B', PyrT.unban);
    final List<PyrBan> after = bansAgainst(w['B1'], w['B1'].state!, b1);
    expect(after.single.lifted, isTrue);
  });
}
