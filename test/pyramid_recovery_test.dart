import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/dev/sim/sim_network.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/pyramid_world.dart';

/// The wallet and the place in the pyramid come back after the account is
/// recovered on a new phone: the pyramid key comes from the account key,
/// the records from friends who keep the pyramid.
void main() {
  Uint8List accountSeed(int salt) => Uint8List.fromList(
    List<int>.generate(32, (int i) => (i * 13 + salt) & 0xFF),
  );

  /// S on top, A (whose pyramid key comes from its account) and B under
  /// S, A1 and A2 under A, B1 under B.
  Future<({PyramidWorld w, SimPhone a})> world(LedgerDisk aDisk) async {
    final PyramidWorld w = PyramidWorld();
    final SimPhone s = w.add('S');
    final SimPhone a = w.add('A', disk: aDisk, fromAccount: true);
    final SimPhone b = w.add('B');
    final SimPhone a1 = w.add('A1');
    final SimPhone a2 = w.add('A2');
    final SimPhone b1 = w.add('B1');
    await w.pyr(s).load();
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm');
    await w.join(s, a, year: 1991);
    await w.join(s, b);
    await w.join(a, a1);
    await w.join(a, a2);
    await w.join(b, b1, nat: 'DE');
    await w.sync();
    return (w: w, a: a);
  }

  test('a recovered account gets its place, its wallet and its private '
      'data back from the records friends keep', () async {
    final Uint8List seed = accountSeed(5);
    final MemoryLedgerDisk lost = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(lost, seed);
    final (:PyramidWorld w, :SimPhone a) = await world(lost);
    final String key = w['A'].myKey!;
    // The pyramid key is the one the account key gives.
    expect(
      (await LedgerKeyPair.fromSeed(
        await LedgerIdentity.derivePyramidSeed(seed),
      )).id,
      key,
    );

    // Money for A: S emits, B co-signs, the veto time passes; A pays A1.
    await w.fund('A', 4000);
    await w.sync();
    expect(w['S'].ledgerBalanceOf(key), 4000);
    expect(w['A'].balance, 4000);
    expect(await w['A'].pay(w['A1'].myKey!, 1000, memo: 'Obiad'), isNotNull);
    await w.net.run();
    final int balance = w['S'].ledgerBalanceOf(key);
    expect(balance, 3000);
    expect(w['A'].balance, balance);
    expect(w['A'].myData['g'], 'k');

    // A's phone is gone for good.
    w.net.setOnline(a, false);

    // The account comes back on a new phone from its paper copy (the key
    // file and the recovery circle give the same account key).
    final MemoryLedgerDisk fresh = MemoryLedgerDisk();
    await adoptPaperBackup(fresh, await PaperBackupAccount.fromSeed(seed));
    expect(fresh.files.containsKey(PyramidService.keyRecovered), isTrue);
    final SimPhone back = w.add('A-nowy', disk: fresh, fromAccount: true);
    // Its friends are back (the sealed copy friends keep), and they know
    // the new device.
    for (final String friend in <String>['S', 'A1', 'A2']) {
      w.net.befriend(back, w.net[friend]);
    }
    final PyramidService again = w.pyr(back);
    await again.load();
    expect(again.myKey, key);
    expect(again.recovering, isTrue);
    expect(again.isMember, isFalse);

    await w.sync();

    expect(again.isMember, isTrue);
    expect(again.state!.levelOf(key), w['S'].state!.levelOf(key));
    // The data confirmed at entry is found again from the commitment.
    expect(again.myData['by'], 1991);
    expect(again.myData['g'], 'k');
    expect(again.recovering, isFalse);
    expect(fresh.files.containsKey(PyramidService.keyRecovered), isFalse);

    // The new phone becomes the member's address for pyramid traffic.
    await w.duties(rounds: 2);
    await w.sync();
    expect(
      PeerShareCodec.normalizeAddress(w['S'].state!.members[key]!.addr),
      back.address,
    );
    // The wallet comes back from the treasurers: their signed statements
    // and the operations behind them.
    await w.net.advance(const Duration(minutes: 6));
    await w.duties(rounds: 1);
    expect(again.agreedStatement, isNotNull);
    expect(again.balance, balance);
    expect(
      again.myEntries.map((PyrLedgerEntry e) => e.memo),
      contains('Obiad'),
    );
    // The next order takes the next number.
    final PyramidRecord? next = await again.pay(w['A2'].myKey!, 500);
    expect(next!.integer('seq'), 2);
    await w.net.run();
    expect(w['S'].ledgerBalanceOf(key), balance - 500);
  });

  test('a recovered account that never was a member stops keeping the '
      "pyramid's records after a while", () async {
    final PyramidWorld w = PyramidWorld();
    final SimPhone s = w.add('S');
    await w.pyr(s).load();
    await w.pyr(s).found(myName: 'S', nat: 'PL', birthYear: 1980, gender: 'm');

    final MemoryLedgerDisk fresh = MemoryLedgerDisk();
    await adoptPaperBackup(
      fresh,
      await PaperBackupAccount.fromSeed(accountSeed(9)),
    );
    final SimPhone r = w.add('R', disk: fresh, fromAccount: true);
    w.net.befriend(r, s);
    final PyramidService p = w.pyr(r);
    await p.load();
    expect(p.recovering, isTrue);
    expect(p.sharedState()!['fol'], isNotNull);
    await w.sync();
    expect(p.isMember, isFalse);

    await w.net.advance(
      const Duration(milliseconds: kPyrRecoveryFollowMs + 60000),
    );
    await p.duties();
    expect(p.recovering, isFalse);
    expect(p.sharedState()!['fol'], isNull);
    expect(fresh.files.containsKey(PyramidService.keyRecovered), isFalse);
  });

  test(
    'a new device of an account without the mark takes no records',
    () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await LedgerIdentity.adoptAccount(disk, accountSeed(11));
      final PyramidWorld w = PyramidWorld();
      final SimPhone x = w.add('X', disk: disk, fromAccount: true);
      await w.pyr(x).load();
      expect(w.pyr(x).recovering, isFalse);
      expect(w.pyr(x).sharedState()!['fol'], isNull);
    },
  );

  test('a recovered head gets the power key back, and the same voting '
      'cards', () async {
    final PyramidWorld w = await PyramidWorld.six();
    // A becomes the head; the power key is handed over to a key made from
    // A's account.
    await w['A'].proposeSwap('', w['A'].myKey!);
    await w.net.run();
    await w.approve('B', PyrT.swap);
    await w.sync();
    await w.duties(rounds: 2);
    await w.sync();
    expect(w['A'].holdsPowerKey, isTrue);
    final String card = await w['A'].cardFor('vote-1');
    expect(await w['A'].cardFor('vote-2'), isNot(card));

    // A's phone is gone; the account comes back on a new one.
    final LedgerDisk old = w['A'].disk;
    final MemoryLedgerDisk fresh = MemoryLedgerDisk();
    w.linkDevice(old, fresh);
    await PyramidService.markRecovered(fresh);
    w.net.setOnline(w.net['A'], false);
    final SimPhone back = w.add('A-nowy', disk: fresh);
    for (final String friend in <String>['S', 'B', 'A1', 'A2']) {
      w.net.befriend(back, w.net[friend]);
    }
    final PyramidService again = w.pyr(back);
    await again.load();
    expect(again.holdsPowerKey, isFalse);
    await w.sync();
    await w.duties(rounds: 1);
    expect(again.isMember, isTrue);
    expect(again.myKey, w['A'].myKey);
    expect(again.holdsPowerKey, isTrue);
    expect(await again.cardFor('vote-1'), card);
  });
}
