import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/pyramid/pyramid_gate_wallet.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

import 'support/pyramid_world.dart';

/// Gates and first messages in the pyramid's points, on the simulated
/// network: conditional payments the one paid keeps or returns, and the
/// first-message price on the price list by level of acquaintance.
void main() {
  /// Emits [amount] to [who] (S proposes, B signs) and waits the 24 h.
  Future<void> fund(PyramidWorld w, String who, int amount) async {
    await w['S'].emit(w[who].myKey!, amount, 'Start');
    await w.net.run();
    await w.approve('B', PyrT.emit);
    await w.net.advance(const Duration(hours: 25));
  }

  test('a gate\'s payment waits, then is kept or returned; the payer takes '
      'it back only after its time', () async {
    final PyramidWorld w = await PyramidWorld.six();
    await fund(w, 'A1', 10000);
    final PyramidGateWallet a1 = PyramidGateWallet(() => w['A1']);
    final PyramidGateWallet b1 = PyramidGateWallet(() => w['B1']);
    final String a1Key = w['A1'].myKey!;
    final String b1Key = w['B1'].myKey!;
    expect(a1.myKey, a1Key);
    expect(a1.keyOf(w.net['B1'].address), b1Key);
    expect(a1.balance, 10000);

    final String? kept = await a1.hold(b1Key, 500, memo: 'Brama');
    await w.net.run();
    await w.sync();
    final GateHold hold = b1.held(kept!)!;
    expect(hold.from, a1Key);
    expect(hold.to, b1Key);
    expect(hold.condBy, b1Key);
    expect(hold.amount, 500);
    expect(hold.settled, isNull);
    expect(a1.balance, 9500);
    expect(await b1.settle(kept, keep: true), isTrue);
    await w.net.run();
    await w.sync();
    expect(w['S'].state!.balanceOf(b1Key), 500);
    expect(b1.held(kept)!.settled, isTrue);

    final String? returned = await a1.hold(b1Key, 300, memo: 'Wiadomość');
    await w.net.run();
    await w.sync();
    expect(await b1.settle(returned!, keep: false), isTrue);
    await w.net.run();
    await w.sync();
    expect(w['S'].state!.balanceOf(a1Key), 9500);

    // Nobody answers: the payer takes it back after the time.
    final String? quiet = await a1.hold(b1Key, 200, memo: 'Brama');
    await w.net.run();
    await w.sync();
    expect(a1.held(quiet!)!.settled, isNull);
    expect(
      a1.held(quiet)!.until - w.net.now,
      greaterThan(kGateMinHold.inMilliseconds),
      reason: 'long enough for a gatekeeper to take it',
    );
    await w.net.advance(kGateHoldTime + const Duration(hours: 1));
    await a1.settle(quiet, keep: false);
    await w.net.run();
    await w.sync();
    expect(a1.held(quiet)!.settled, isFalse);
    expect(w['S'].state!.balanceOf(a1Key), 9500);
  });

  test('points go to an address only once the device there proved the key: '
      'a member who wrote in somebody else\'s address gets nothing', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final SimPhone v = w.add('V');
    await w.pyr(v).load();
    final PyramidGateWallet a1 = PyramidGateWallet(
      () => w['A1'],
      proofWait: const Duration(seconds: 2),
    );
    final String b1Key = w['B1'].myKey!;
    final String a2Key = w['A2'].myKey!;

    final Future<String?> b1 = a1.payeeKeyOf(w.net['B1'].address);
    await w.net.run();
    expect(await b1, b1Key, reason: 'B1\'s device answered with its key');

    // A2 claims V's address (V is not in the pyramid).
    final PyramidRecord claim = await w['A2'].signAsMe(
      PyramidRecord(
        body: <String, dynamic>{
          't': PyrT.address,
          'py': w['A2'].current,
          'at': w.net.now,
          'by': <String>[a2Key],
          'k': a2Key,
          'addr': v.address,
        },
      ),
    );
    expect(await w['A2'].ingest(claim), isTrue);
    await w.net.run();
    await w.sync();
    expect(a1.keyOf(v.address), a2Key, reason: 'A2\'s own word');
    final Future<String?> victim = a1.payeeKeyOf(v.address);
    await w.net.run();
    expect(await victim, isNull, reason: 'V\'s device holds no such key');

    // A device that does not answer at all: nobody either.
    w.net['A'].online = false;
    final Future<String?> quiet = a1.payeeKeyOf(w.net['A'].address);
    await w.net.run();
    expect(await quiet, isNull);
  });

  test('the first-message price on the price list: by level, a level left '
      'out is closed, the rest of the list stays', () async {
    final PyramidWorld w = await PyramidWorld.six();
    final String b1 = w['B1'].myKey!;
    final String b1Address = w.net['B1'].address;
    await w['B1'].setOffers(const <String, int>{'reshare': 300});
    await w.net.run();
    final Map<String, int> levels = messagePriceLevels(
      fof: true,
      strangers: false,
      price: 200,
    );
    expect(await syncMessagePrice(w['B1'], levels), isTrue);
    await w.net.run();
    await w.sync();
    final PyramidState st = w['A1'].state!;
    expect(st.offerLevels[b1]!['inbox'], <String, int>{
      'friend': 0,
      'fof': 200,
    });
    expect(st.offers[b1]!['reshare'], 300, reason: 'the rest stays');
    expect(w['A1'].closedTo(b1, 'stranger'), isTrue);
    expect(w['A1'].closedTo(b1, 'fof'), isFalse);
    // A1 knows B1 through B: a friend of a friend pays 2 pkt.
    expect(
      pyramidMessageTerms(w['A1'], b1Address),
      const DirectTerms.price(200, payable: true),
    );
    // Nothing new: nothing published again.
    expect(await syncMessagePrice(w['B1'], levels), isFalse);

    // Closed to everybody outside friends.
    await syncMessagePrice(
      w['B1'],
      messagePriceLevels(fof: false, strangers: false, price: 0),
    );
    await w.net.run();
    await w.sync();
    expect(pyramidMessageTerms(w['A1'], b1Address), const DirectTerms.closed());
    expect(
      await w['A1'].sendMarket(b1, 'inbox', 'Dzień dobry'),
      isFalse,
      reason: 'the paid inbox follows the same price',
    );
  });
}
