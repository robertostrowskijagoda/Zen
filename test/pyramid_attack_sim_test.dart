import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/crypto/ring_signature.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// Attacks from the security review, played on the simulated network: what
/// a modified app or a hostile friend sends, and what honest phones do
/// with it (§20–24, §28).
void main() {
  const int hour = 3600 * 1000;

  /// Emits [amount] to [who] (S proposes, B signs) and waits the 24 h.
  Future<void> fund(PyramidWorld w, String who, int amount) async {
    await w['S'].emit(w[who].myKey!, amount, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
  }

  test(
    'junk from a friend is not kept: a broken ring, a forged ring, a time bomb, a strange pyramid',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final PyramidService b1 = w['B1'];
      final String py = b1.current!;
      final LedgerKeyPair x = await LedgerKeyPair.generate();
      final List<String> cell = <String>[
        w['A'].myKey!,
        w['A1'].myKey!,
        w['A2'].myKey!,
      ]..sort();
      final Map<String, dynamic> body = <String, dynamic>{
        't': PyrT.voteRequest,
        'py': py,
        'at': w.net.now,
        'by': const <String>[],
        'cell': '0',
        'head': w['A'].myKey,
        'ring': cell,
        'n': 'x',
      };
      Future<void> fromB(PyramidRecord r) => w.net['B'].send(
        w.net['B1'].address,
        <String, dynamic>{'type': PyramidTypes.record, 'r': r.toJson()},
      );
      // A key image that is not base64 (it crashed the fold on every phone).
      await w.net['B'].send(w.net['B1'].address, <String, dynamic>{
        'type': PyramidTypes.record,
        'r': <String, dynamic>{
          'b': body,
          'r': <String, dynamic>{
            'c': '1',
            's': <String>['1', '1', '1'],
            'i': '!!!',
          },
        },
      });
      // A well-formed ring signature by an outsider, claiming to be the cell.
      final List<String> fakeRing = <String>[
        x.id,
        w['A1'].myKey!,
        w['A2'].myKey!,
      ]..sort();
      final PyramidRecord outsider = PyramidRecord(
        body: body,
        ring: RingSignature.sign(
          seed: x.seed,
          ring: fakeRing.map((String k) => unb64(k, length: 32)!).toList(),
          context: PyramidState.voteRequestContext(py, '0', w['A'].myKey!),
          message: PyramidRecord(body: body).signedBytes,
        ),
      );
      await fromB(outsider);
      // Signed, but dated a day ahead.
      final PyramidRecord bomb = await PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.post,
          'py': py,
          'at': w.net.now + 24 * hour,
          'by': <String>[x.id],
          'text': 'Później',
          'lvl': 0,
        },
      ).signedBy(x);
      await fromB(bomb);
      // A pyramid nobody here keeps or joins.
      final PyramidRecord strange = await PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.genesis,
          'py': '',
          'at': w.net.now,
          'by': <String>[x.id],
          'name': 'Obca',
          'founder': <String, dynamic>{
            'k': x.id,
            'n': 'X',
            'nat': 'PL',
            'yr': 1990,
            'dc': '',
          },
        },
      ).signedBy(x);
      await fromB(strange);
      await w.net.run();
      expect(b1.keeps(outsider.id), isFalse);
      expect(b1.keeps(bomb.id), isFalse);
      expect(b1.keeps(strange.id), isFalse);
      expect(b1.knownPyramids, <String>[py]);
      // The pyramid goes on as before.
      await w['S'].post('Dalej działamy');
      await w.net.run();
      expect(b1.state!.posts.values.single.text, 'Dalej działamy');
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'a proposal signed late is published with a fresh time, signed again automatically',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String a1 = w['A1'].myKey!;
      await w['S'].emit(a1, 1000, 'Start');
      await w.net.run();
      final PyrProposal p = w['B'].proposals.values.single;
      final int proposedAt = p.record.at;
      // What B sees before signing: the record's own time first.
      expect(w['B'].recordDetails(p.record).first, startsWith('Czas rekordu'));
      expect(
        w['B'].recordDetails(p.record).any((String l) => l.startsWith('Uwaga')),
        isFalse,
      );
      // B looks at it 30 h later.
      await w.net.advance(const Duration(hours: 30));
      expect(
        w['B'].recordDetails(p.record).any((String l) => l.startsWith('Uwaga')),
        isTrue,
      );
      await w['B'].approve(p.record.id);
      await w.net.run();
      final PyrEmission e = w['A'].state!.emissions.values.single;
      expect(
        e.at,
        greaterThan(proposedAt + 29 * hour),
        reason: 'dated when signed, not when proposed',
      );
      expect(
        e.done,
        isFalse,
        reason: 'the third of the top still has 24 h to veto',
      );
      expect(
        w['A'].proposals.values.where(
          (PyrProposal x) => x.record.type == PyrT.emit,
        ),
        isEmpty,
      );
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'a back-dated emission: its money waits at the treasurers and the third can still veto',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      // Long enough after the pyramid began for a record dated a day back.
      await w.net.advance(const Duration(hours: 30));
      final PyramidService s = w['S'];
      final String a1 = w['A1'].myKey!;
      // S and B (colluding, with a modified app) sign an emission dated 25 h
      // back: its veto time is over the moment it appears.
      final PyramidRecord unsigned = PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.emit,
          'py': s.current,
          'at': w.net.now - 25 * hour,
          'by': <String>[s.myKey!, w['B'].myKey!]..sort(),
          'to': a1,
          'amount': 100000,
          'why': 'Wstecz',
        },
      );
      final PyramidRecord signed = await w['B'].signAsMe(
        await s.signAsMe(unsigned),
      );
      expect(await s.ingest(signed), isTrue);
      await w.net.run();
      final PyrEmission e = w['A'].state!.emissions.values.single;
      expect(
        e.done,
        isTrue,
        reason: 'no phone can prove the date wrong by itself',
      );
      expect(w['A'].seenLate(e.id), isTrue);
      expect(w['A'].canVeto(e), isTrue);
      expect(
        w.net['A'].notificationTitles,
        contains('Emisja dotarła z opóźnieniem'),
      );
      // A1 tries to spend it at once: no treasurer signs yet.
      expect(await w['A1'].pay(w['B1'].myKey!, 50000), isNotNull);
      await w.net.run();
      expect(w['B1'].state!.balanceOf(w['B1'].myKey!), 0);
      // A vetoes, dated inside the emission's own wait: it counts everywhere.
      await w['A'].veto(e.id);
      await w.net.run();
      for (final String who in <String>['S', 'B', 'A1', 'B1']) {
        expect(w[who].state!.emissions[e.id]!.vetoed, isTrue, reason: who);
        expect(w[who].state!.balanceOf(a1), 0, reason: who);
      }
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'a refund signed by the treasurers cannot be overtaken by an acceptance dated back',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      await fund(w, 'A1', 100000);
      final String a1 = w['A1'].myKey!;
      final String b1 = w['B1'].myKey!;
      await w['A1'].pay(b1, 10000, condBy: b1, condUntil: w.net.now + 2 * hour);
      await w.net.run();
      final PyrEscrow escrow = w['B1'].state!.escrows.values.single;
      // Time is up: A1 takes the money back (most treasurers sign).
      await w.net.advance(const Duration(hours: 3));
      await w['A1'].settle(escrow.id, false);
      await w.net.run();
      expect(w['S'].state!.escrows[escrow.id]!.settled, isFalse);
      expect(w['S'].state!.balanceOf(a1), 100000);
      // B1 signs an acceptance dated before the deadline and asks every
      // treasurer: none signs a second settlement of the same payment.
      final PyramidRecord late = await w['B1'].signAsMe(
        PyramidRecord(
          body: <String, dynamic>{
            't': PyrT.settle,
            'py': w['B1'].current,
            'at': escrow.until - hour,
            'by': <String>[b1],
            'x': escrow.id,
            'ok': true,
          },
        ),
      );
      final PyramidState st = w['B1'].state!;
      for (final String t in st.treasurers) {
        await w.net['B1'].send(st.members[t]!.addr, <String, dynamic>{
          'type': PyramidTypes.pay,
          'r': late.toJson(),
        });
      }
      await w.net.run();
      // Published without treasurers, it does not count.
      await w['B1'].ingest(late);
      await w.net.run();
      expect(w['S'].state!.rejected[late.id], contains('skarbników'));
      expect(w['S'].state!.balanceOf(b1), 0);
      expect(w['S'].state!.balanceOf(a1), 100000);
      expect(w.views().values.toSet(), hasLength(1));
    },
  );

  test(
    'a paid message with a made-up payment never gets in; one paid to someone else neither',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      await fund(w, 'A1', 100000);
      final String a1 = w['A1'].myKey!;
      final String b1 = w['B1'].myKey!;
      await w['B1'].setOffers(const <String, int>{'inbox': 500});
      await w.net.run();
      // A payment id nobody ever paid, with the price claimed.
      await w.net['A1'].send(w.net['B1'].address, <String, dynamic>{
        'type': PyramidTypes.dm,
        'id': 'zmyslona',
        'k': 'inbox',
        'f': a1,
        't': 'Zapłaciłem, naprawdę',
        'x': 'nie-ma-takiej-platnosci',
        'a': 500,
      });
      await w.net.run();
      await w.duties(rounds: 1);
      expect(w['B1'].market.containsKey('zmyslona'), isFalse);
      // A real payment, but to A: not B1's to take.
      final PyramidRecord? toA = await w['A1'].pay(
        w['A'].myKey!,
        500,
        condBy: w['A'].myKey,
      );
      await w.net.run();
      await w.net['A1'].send(w.net['B1'].address, <String, dynamic>{
        'type': PyramidTypes.dm,
        'id': 'cudza',
        'k': 'inbox',
        'f': a1,
        't': 'Zapłaciłem komuś innemu',
        'x': toA!.id,
        'a': 500,
      });
      await w.net.run();
      expect(w['B1'].market.containsKey('cudza'), isFalse);
      expect(
        w['S'].state!.escrows[toA.id]!.settled,
        isNull,
        reason: 'B1 cannot settle what is not its',
      );
      // The honest way works.
      expect(await w['A1'].sendMarket(b1, 'inbox', 'Dzień dobry'), isTrue);
      await w.net.run();
      expect(
        w['B1'].market.values
            .where((PyrMarketMessage m) => m.text == 'Dzień dobry')
            .single
            .amount,
        500,
      );
    },
  );

  test(
    'a crisis wave that does not count is shown unverified, never kept or passed on; an old one is ignored',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      final String py = w['S'].current!;
      // B alone (one of the top is not enough) signs an alarm.
      final PyramidRecord fake = await w['B'].signAsMe(
        PyramidRecord(
          body: <String, dynamic>{
            't': PyrT.alarm,
            'py': py,
            'at': w.net.now,
            'by': <String>[w['B'].myKey!],
            'text': 'Fałszywa ewakuacja',
            'scope': const <String, String>{'k': 'all', 'p': '', 'nat': ''},
            'until': w.net.now + 24 * hour,
          },
        ),
      );
      await w['A2'].onCrisisWave(<String, dynamic>{
        'v': kCrisisWaveVersion,
        'r': fake.toJson(),
      });
      expect(
        w.net['A2'].notificationTitles,
        contains('Komunikat (niesprawdzony)'),
      );
      expect(w['A2'].keeps(fake.id), isFalse);
      expect(w.waves['A2'], isNull, reason: 'not passed on');
      // A real one that is over: a replay is ignored.
      await w['S'].alarm('Krótki alarm', length: const Duration(hours: 1));
      await w.net.run();
      await w.approve('B', PyrT.alarm);
      final PyrAlarm real = w['A2'].state!.alarms.single;
      await w.net.advance(const Duration(hours: 2));
      final SimPhone z = w.add('Z');
      await w['Z'].load();
      await w['Z'].onCrisisWave(w['S'].crisisWave(real.id)!);
      expect(z.shown, isEmpty);
    },
  );

  test('sync answers friends only', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String py = w['B1'].current!;
    final SimPhone z = w.add('Z');
    await w['Z'].load();
    final int before = w.net['B1'].outbox.length;
    for (final Map<String, dynamic> ask in <Map<String, dynamic>>[
      <String, dynamic>{
        'type': PyramidTypes.ids,
        'py': py,
        'ids': const <String>[],
      },
      <String, dynamic>{'type': PyramidTypes.wantAll, 'py': py},
      <String, dynamic>{
        'type': PyramidTypes.hello,
        'py': <Map<String, dynamic>>[
          <String, dynamic>{'id': py, 'd': const <String, String>{}},
        ],
      },
    ]) {
      await z.send(w.net['B1'].address, ask);
    }
    await w.net.run();
    bool sentRecords() => w.net['B1'].outbox
        .skip(before)
        .any(
          (Map<String, dynamic> m) =>
              m['type'] == PyramidTypes.records ||
              m['type'] == PyramidTypes.ids,
        );
    expect(sentRecords(), isFalse);
    // A friend asking the same gets the pyramid.
    w.net.befriend(z, w.net['B1']);
    await z.send(w.net['B1'].address, <String, dynamic>{
      'type': PyramidTypes.ids,
      'py': py,
      'ids': const <String>[],
    });
    await w.net.run();
    expect(sentRecords(), isTrue);
  });

  test('a copy stripped of a signature is repaired by sync', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final SimPhone a2 = w.net['A2'];
    w.net
      ..holdForOffline = false
      ..setOnline(a2, false);
    await w['S'].emit(w['A1'].myKey!, 1000, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    final String id = w['S'].state!.emissions.keys.single;
    final PyramidRecord full = w['S'].recordOf(id)!;
    expect(full.sigs, hasLength(2));
    w.net
      ..setOnline(a2, true)
      ..holdForOffline = true;
    // A friend of A2 passes on a copy with one signature only.
    final String s = w['S'].myKey!;
    final PyramidRecord stripped = PyramidRecord(
      body: full.body,
      sigs: <String, String>{s: full.sigs[s]!},
    );
    await w.net['A'].send(a2.address, <String, dynamic>{
      'type': PyramidTypes.record,
      'r': stripped.toJson(),
    });
    await w.net.run();
    expect(w['A2'].recordOf(id)!.sigs, hasLength(1));
    expect(w['A2'].state!.emissions, isEmpty);
    // Sync compares signatures too, so the full copy comes.
    await w.sync();
    expect(w['A2'].recordOf(id)!.sigs, hasLength(2));
    expect(w['A2'].state!.emissions.keys, <String>[id]);
    expect(w.views().values.toSet(), hasLength(1));
  });

  test('a forged signature sent back is not counted', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final PyramidRecord r = (await w['S'].emit(w['A1'].myKey!, 1000, 'Start'))!;
    await w.net.run();
    final PyramidRecord forged = r.withSig(
      w['B'].myKey!,
      b64(List<int>.filled(64, 7)),
    );
    await w.net['B'].send(w.net['S'].address, <String, dynamic>{
      'type': PyramidTypes.signature,
      'r': forged.toJson(),
    });
    await w.net.run();
    expect(w['S'].state!.emissions, isEmpty);
    await w.approve('B', PyrT.emit);
    expect(w['S'].state!.emissions, hasLength(1));
  });

  test(
    'an order waiting for treasurers survives a restart and is sent again as it is',
    () async {
      final PyramidWorld w = await PyramidWorld.six();
      await fund(w, 'A1', 10000);
      final String b1 = w['B1'].myKey!;
      // Most treasurers are away; what is sent to them is lost.
      const List<String> away = <String>['S', 'A', 'B', 'B1'];
      w.net.holdForOffline = false;
      for (final String who in away) {
        w.net.setOnline(w.net[who], false);
      }
      final PyramidRecord? order = await w['A1'].pay(
        b1,
        2500,
        memo: 'za rower',
      );
      await w.net.run();
      expect(w['A1'].pendingPayments.map((PyramidRecord r) => r.id), <String>[
        order!.id,
      ]);
      // The app restarts: the order is still there.
      await w['A1'].load();
      expect(w['A1'].pendingPayments.map((PyramidRecord r) => r.id), <String>[
        order.id,
      ]);
      for (final String who in away) {
        w.net.setOnline(w.net[who], true);
      }
      w.net.holdForOffline = true;
      await w.duties(rounds: 1);
      await w.sync();
      expect(w['A1'].pendingPayments, isEmpty);
      expect(w['S'].state!.balanceOf(b1), 2500);
      expect(
        w['S'].state!.transfers.last.id,
        order.id,
        reason: 'the same order, not a new number',
      );
    },
  );
}
