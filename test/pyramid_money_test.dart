import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/presentation/pyramid_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

import 'support/pyramid_world.dart';

/// Money and the inboxes of the pyramid: reports only from members and
/// within limits, treasurer signatures never replaced.
void main() {
  /// Emits [amount] to [who] (S proposes, B signs) and waits the 24 h.
  Future<void> fund(PyramidWorld w, String who, int amount) async {
    await w['S'].emit(w[who].myKey!, amount, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
  }

  Map<String, dynamic> stored(PyramidService s, String key) =>
      jsonDecode(utf8.decode((s.disk as MemoryLedgerDisk).files[key]!))
          as Map<String, dynamic>;

  test('money reads back as the wallet shows it', () {
    // Grouped with non-breaking spaces.
    expect(parseMoney(formatMoney(123456789)), 123456789);
    expect(formatMoney(123456789), contains(','));
  });

  group('reports', () {
    test(
      'only members, only to those who take them, cut to size and counted',
      () async {
        final PyramidWorld w = await PyramidWorld.six();
        final PyramidService s = w['S'];
        final SimPhone z = w.add('Z');
        await w['Z'].load();
        Map<String, dynamic> report(String id, {String evidence = 'x'}) =>
            <String, dynamic>{
              'type': PyramidTypes.report,
              'id': id,
              'why': 'spam',
              'at': w.net.now,
              't': '',
              'ev': evidence,
            };

        // A stranger's reports do not get in.
        await z.send(w.net['S'].address, report('obcy'));
        await w.net.run();
        expect(s.inbox, isEmpty);

        // A member floods the top with huge reports: a few are kept, cut.
        final String huge = 'x' * 100000;
        for (int i = 0; i < 15; i++) {
          await w.net['B1'].send(
            w.net['S'].address,
            report('r$i', evidence: huge),
          );
        }
        // A member who is neither the top nor a delegate takes none.
        await w.net['B1'].send(w.net['A1'].address, report('boczny'));
        await w.net.run();
        expect(s.inbox, hasLength(kPyrReportsPerSender));
        expect(
          s.inbox.values.every(
            (PyrReport r) => r.evidence.length <= kPyrReportEvidenceChars,
          ),
          isTrue,
        );
        expect(w['A1'].inbox, isEmpty);

        // Kept under their own key, never in the main state.
        expect(stored(s, 'pyramid/me').containsKey('in'), isFalse);
        expect(
          stored(s, 'pyramid/reports')['in'] as List,
          hasLength(kPyrReportsPerSender),
        );
        await s.load();
        expect(s.inbox, hasLength(kPyrReportsPerSender));
      },
    );
  });

  test('a stranger cannot erase or replace a treasurer signature', () async {
    final PyramidWorld w = await PyramidWorld.six();
    await fund(w, 'A1', 10000);
    final String b1 = w['B1'].myKey!;
    // Most treasurers are away: the order waits with A1's and A2's.
    const List<String> away = <String>['S', 'A', 'B', 'B1'];
    w.net.holdForOffline = false;
    for (final String who in away) {
      w.net.setOnline(w.net[who], false);
    }
    final PyramidRecord? order = await w['A1'].pay(b1, 2500);
    await w.net.run();
    final String a2 = w['A2'].myKey!;
    final String good = w['A1'].pendingPayments.single.tsigs[a2]!;
    final SimPhone z = w.add('Z');
    await w['Z'].load();
    for (final String k in <String>[a2, w['S'].myKey!]) {
      await z.send(w.net['A1'].address, <String, dynamic>{
        'type': PyramidTypes.paySig,
        'id': order!.id,
        'k': k,
        's': b64(List<int>.filled(64, 7)),
      });
    }
    await w.net.run();
    final PyramidRecord after = w['A1'].pendingPayments.single;
    expect(after.tsigs[a2], good);
    expect(after.tsigs.containsKey(w['S'].myKey), isFalse);
    expect(
      order!.withTreasurerSig(a2, 'x').withTreasurerSig(a2, 'y').tsigs[a2],
      'x',
    );
    // The real treasurers come back: the order goes out again, through.
    for (final String who in away) {
      w.net.setOnline(w.net[who], true);
    }
    w.net.holdForOffline = true;
    await w.net.advance(const Duration(minutes: 31));
    await w.duties(rounds: 1);
    await w.sync();
    expect(w['S'].state!.balanceOf(b1), 2500);
  });
}
