import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Fewer holders of the pieces wait a week unless confirmed with the
/// account password, and the person is told; who stopped answering is
/// named; forgotten pieces carry a mark between the account's devices.
void main() {
  late _Net net;
  late int now;

  setUp(() {
    net = _Net();
    now = 1000000;
  });

  Future<RecoveryService> make(
    String address, {
    Set<String> friends = const <String>{},
    RecoveryIdentity? Function()? identity,
    List<String>? Function()? holders,
  }) async {
    final _Linked t = net.nodes[address] = _Linked(address, net);
    await t.start();
    final RecoveryService s = RecoveryService(
      transport: t,
      disk: MemoryLedgerDisk(),
      isFriend: (String a) => friends.contains(a),
      identity: identity,
      holders: holders,
      clock: () => now,
      tickInterval: const Duration(hours: 1),
      acceptedCosts: _lightCosts,
    );
    addTearDown(s.stop);
    await s.start();
    return s;
  }

  Future<RecoverySeal> seal(LedgerIdentity id) =>
      RecoverySeal.make(id.accountKey!.seed, _password, now: now, cost: _light);

  test('below two close friends after the wait, the pieces are forgotten; '
      'the person is told, and it waits again if it goes further', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    final String z = _a('200::c3');
    List<String> close = <String>[x, y, z];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, y, z},
      identity: () => rid,
      holders: () => close,
    );
    final List<RecoveryReduction> told = <RecoveryReduction>[];
    o.onReduction = told.add;
    final RecoveryService hx = await make(x, friends: <String>{owner});
    final RecoveryService hy = await make(y, friends: <String>{owner});
    final RecoveryService hz = await make(z, friends: <String>{owner});
    await o.setSeal(await seal(id));
    await _settle();
    expect(o.generation!.holders, hasLength(3));

    close = <String>[x, y];
    now += 1000;
    await o.reconcile();
    await _settle();
    expect(told.single.holders, 2);
    expect(o.protection.reduction!.due, now + kReductionDelay.inMilliseconds);
    expect(o.generation!.holders, hasLength(3), reason: 'waits');
    // Further, a day later: the wait starts again.
    now += const Duration(days: 1).inMilliseconds;
    close = <String>[x];
    await o.reconcile();
    await _settle();
    expect(told, hasLength(2));
    expect(told.last.holders, 0);
    now += kReductionDelay.inMilliseconds - 1000;
    await o.tick();
    await _settle();
    expect(hz.heldFor, isNotEmpty, reason: 'the wait is not over');
    now += 2000;
    await o.tick();
    await _settle();
    expect(o.generation!.holders, isEmpty);
    expect(o.protection.reduction, isNull);
    expect(hx.heldFor, isEmpty);
    expect(hy.heldFor, isEmpty);
    expect(hz.heldFor, isEmpty);
  });

  test('confirmed with the account password, it is made at once; a wrong '
      'password changes nothing', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    List<String> close = <String>[x, y];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, y},
      identity: () => rid,
      holders: () => close,
    );
    final RecoveryService hx = await make(x, friends: <String>{owner});
    final RecoveryService hy = await make(y, friends: <String>{owner});
    await o.setSeal(await seal(id));
    await _settle();
    close = <String>[x];
    now += 1000;
    await o.reconcile();
    await _settle();
    expect(o.protection.reduction, isNotNull);
    expect(await o.confirmReduction('zle-haslo-12345'), isFalse);
    await _settle();
    expect(hx.heldFor, isNotEmpty);
    expect(await o.confirmReduction(_password), isTrue);
    await _settle();
    expect(o.protection.reduction, isNull);
    expect(hx.heldFor, isEmpty);
    expect(hy.heldFor, isEmpty);
  });

  test('a close friend back before the wait is over: nothing changes and '
      'nothing waits', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    List<String> close = <String>[x, y];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, y},
      identity: () => rid,
      holders: () => close,
    );
    await make(x, friends: <String>{owner});
    final RecoveryService hy = await make(y, friends: <String>{owner});
    await o.setSeal(await seal(id));
    await _settle();
    final int g = o.generation!.generation;
    close = <String>[x];
    now += 1000;
    await o.reconcile();
    close = <String>[x, y];
    now += 1000;
    await o.reconcile();
    await _settle();
    expect(o.protection.reduction, isNull);
    now += kReductionDelay.inMilliseconds * 2;
    await o.tick();
    await _settle();
    expect(o.generation!.generation, g);
    expect(hy.heldFor, isNotEmpty);
  });

  test('who stopped answering is named', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, y},
      identity: () => rid,
      holders: () => <String>[x, y],
    );
    await make(x, friends: <String>{owner});
    await make(y, friends: <String>{owner});
    await o.setSeal(await seal(id));
    await _settle();
    expect(o.protection.silent, isEmpty);
    net.nodes.remove(y);
    for (int week = 0; week < 6; week++) {
      now += kPieceReoffer.inMilliseconds;
      await o.tick();
      await _settle();
    }
    expect(o.protection.silent, <String>[y]);
    expect(o.isSilent(y), isTrue);
    expect(o.isSilent(x), isFalse);
  });

  test('a confirmation saved before confirmations had a time counts from '
      'the update on', () {
    const RecoveryGeneration old = RecoveryGeneration(
      generation: 5,
      threshold: 2,
      device: 'd',
      sealAt: 1,
      holders: <String>['x', 'y'],
      acks: <String, int>{'x': 5, 'y': 5},
    );
    final RecoveryGeneration g = RecoveryGeneration.fromJson(
      old.withAckTimes(1000).toJson(),
    )!;
    expect(g.ackedNow(1000 + kAckFresh.inMilliseconds - 1), 2);
    expect(g.ackedNow(1000 + kAckFresh.inMilliseconds), 0);
  });

  test('the mark of forgotten pieces drops them on a device that still '
      'keeps them, and goes when they are kept again', () async {
    final RecoveryService phone = await make(_a('200::d1'));
    final RecoveryService tablet = await make(_a('200::d2'));
    final LedgerIdentity q = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final RecoveryPiece piece = (await createGenerationPieces(
      account: q.account,
      seal: await seal(q),
      holders: 2,
      generation: now,
    )).first;
    final Map<String, Object?> held = <String, Object?>{
      q.account: <String, dynamic>{
        'account': q.account,
        'from': _a('200::99'),
        'pieces': <Object?>[piece.toJson()],
        'at': now,
      },
    };
    await phone.takeSyncState(<String, Object?>{'held': held});
    await tablet.takeSyncState(<String, Object?>{'held': held});
    // Forgotten on the phone.
    await phone.takeSyncState(<String, Object?>{'held': <String, Object?>{}});
    final Map<String, Object?> state = phone.syncState();
    expect(state['forgot'], contains(q.account));
    // The deletion did not reach the tablet (its own unit is still in the
    // state it takes), the mark did.
    await tablet.takeSyncState(<String, Object?>{...state, 'held': held});
    expect(tablet.heldFor, isEmpty);
    expect(tablet.syncState()['forgot'], contains(q.account));
    // A newer generation kept again on the phone: no mark any more there.
    final RecoveryPiece newer = (await createGenerationPieces(
      account: q.account,
      seal: await seal(q),
      holders: 2,
      generation: now + 1,
    )).first;
    await phone.takeSyncState(<String, Object?>{
      'held': <String, Object?>{
        q.account: <String, dynamic>{
          'account': q.account,
          'from': _a('200::99'),
          'pieces': <Object?>[newer.toJson()],
          'at': now + 1,
        },
      },
      'forgot': state['forgot'],
    });
    expect(phone.heldFor, <String>[q.account]);
  });
}

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);
const List<PasswordCost> _lightCosts = <PasswordCost>[_light];
const String _password = 'dobre-haslo-123';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.net);

  final String address;
  final _Net net;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String to = PeerShareCodec.normalizeAddress(remoteAddress);
    final _Linked? target = net.nodes[to];
    _traffic++;
    if (target == null || net.offline.contains(to)) {
      return;
    }
    scheduleMicrotask(
      () => target.injectIncoming(from: address, payload: payload),
    );
  }
}

final class _Net {
  final Map<String, _Linked> nodes = <String, _Linked>{};
  final Set<String> offline = <String>{};
}

int _traffic = 0;

Future<void> _settle() async {
  int quiet = 0;
  int seen = _traffic;
  for (int i = 0; i < 500 && quiet < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    if (_traffic == seen) {
      quiet++;
    } else {
      seen = _traffic;
      quiet = 0;
    }
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<(LedgerIdentity, RecoveryIdentity)> _account() async {
  final LedgerIdentity id = await LedgerIdentity.loadOrCreate(
    MemoryLedgerDisk(),
  );
  return (
    id,
    RecoveryIdentity(
      account: id.account,
      deviceKey: id.deviceKey,
      certificate: id.certificate,
    ),
  );
}
