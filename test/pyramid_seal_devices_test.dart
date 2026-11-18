import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// The open questions of the era seals: a treasurer with two devices, and
/// a payee handed a payment the treasurers do not count.
void main() {
  test('a treasurer\'s second device signs no seal: only the device at the '
      'address of its member record seals, so one person on two devices '
      'never signs two seals of an era', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final MemoryLedgerDisk d = MemoryLedgerDisk();
    w.linkDevice(w['A'].disk, d);
    final SimPhone other = w.add(
      'A+',
      disk: d,
      otherDevices: () => <String>[w.net['A'].address],
    );
    w.net
      ..befriend(w.net['A'], other)
      ..befriend(w.net['S'], other);
    await w['A+'].load();
    await w['A+'].mergeFromOwnDevice(w['A'].sharedState()!);
    await w.sync();
    final String a = w['A'].myKey!;
    expect(w['A+'].myKey, a);
    expect(w['A+'].state!.treasurers, contains(a));
    // The era is due; the device at the member's address is away.
    w.net.holdForOffline = false;
    w.net.setOnline(w.net['A'], false);
    await w.net.advance(const Duration(hours: 7));
    await w['A+'].duties();
    await w.net.advance(const Duration(minutes: 11));
    await w['A+'].duties();
    await w.net.run();
    final List<String> signed = <String>[
      for (final String id in w['A+'].recordIds)
        if (w['A+'].recordOf(id)! case final PyramidRecord r
            when r.type == PyrT.seal && r.signers.contains(a))
          id,
    ];
    expect(signed, isEmpty);
    // The device at the address seals as before.
    w.net.setOnline(w.net['A'], true);
    w.net.holdForOffline = true;
    await w.duties(rounds: 1);
    await w.net.advance(const Duration(minutes: 11));
    await w.duties(rounds: 3);
    await w.sync();
    expect(w['S'].state!.seals, hasLength(2));
    expect(w['S'].state!.seals.last.signers, contains(a));
    expect(w['S'].state!.sealCheaters, isEmpty);
  });

  test('a payee handed a final order whose number the treasurers released, '
      'without the release, counts no money: a payment comes in only once '
      'the treasurers\' agreed statement lists it', () async {
    const int day = FoldWorld.day;
    const int start = FoldWorld.t0 + 2 * day + FoldWorld.hour;
    final FoldWorld w = await FoldWorld.make();
    w.records.add(await w.sealFirst());
    final PyrEmitNote note = PyrEmitNote(
      rc: pyrEmitCommit(w.id('A1'), 'salt'),
      to: w.id('A1'),
      salt: 'salt',
    );
    final PyramidRecord e = await w.rec(
      PyrT.emit,
      FoldWorld.t0 + day,
      <String>['S', 'A'],
      <String, dynamic>{'rc': note.rc, 'amount': 1000},
    );
    final PyramidState st = w.fold(<PyramidRecord>[e], now: start + day);
    Future<PyramidRecord> signed(PyramidRecord r, List<String> who) async {
      for (final String n in who) {
        r = r.withTreasurerSig(
          w.id(n),
          b64(await w[n].sign(PyramidRecord.treasurerBytes(r.id))),
        );
      }
      return r;
    }

    // A1's number 1, final through a signature its treasurer kept from the
    // others (X): the others saw it split and released the span.
    final PyramidRecord hidden = await signed(
      await w.rec(
        PyrT.transfer,
        start,
        <String>['A1'],
        <String, dynamic>{
          'from': w.id('A1'),
          'to': w.id('B1'),
          'amount': 800,
          'seq': 1,
          'after': 1,
          'memo': '',
        },
      ),
      <String>['S', 'A', 'B', 'A1', 'X'],
    );
    final PyramidRecord release = await signed(
      PyrLedger.releaseOf(
        pyramid: w.py,
        slot: '${w.id('A1')}|1',
        prev: '',
        at: st.sealedTo,
      ),
      <String>['S', 'A', 'B', 'A2', 'Y'],
    );
    final PyrLedger treasurer = PyrLedger()
      ..mergeNote(note)
      ..merge(hidden)
      ..mergeRelease(release);
    expect(
      treasurer.compute(st, whole: true).counted,
      isNot(contains(hidden.id)),
    );
    // The payee has the order and not the release: it would count it, but
    // as money waiting for the statement, never as balance.
    final PyrLedger payee = PyrLedger()..merge(hidden);
    final PyrLedgerView v = payee.compute(st, hold: w.id('B1'));
    expect(v.counted, contains(hidden.id));
    expect(v.held, contains(hidden.id));
    expect(v.balanceOf(w.id('B1')), 0);
  });
}
