import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// The pieces of the account key with close friends never get fewer by
/// surprise: going below two close friends waits, two changes in a row do
/// not take the last complete set from a holder, "forget older" goes only
/// to those who keep the new set, and a holder who stopped answering no
/// longer makes the account secured.
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

  Future<List<RecoveredAccount>> recoverFrom(
    List<RecoveryService> helpers,
    String owner,
  ) async {
    final String fresh = _a('200::f');
    final RecoveryService f = await make(fresh);
    await f.beginRecovery();
    for (final RecoveryService h in helpers) {
      final String address = net.nodes.entries
          .firstWhere((MapEntry<String, _Linked> e) => e.value == h.transport)
          .key;
      await f.allowHelper(address);
      await h.startHelping(owner, fresh);
    }
    now += kNormalDelay.inMilliseconds;
    for (final RecoveryService h in helpers) {
      await h.tick();
    }
    await _settle();
    return recoverWithPassword(
      f.received(RecoveryKind.normal),
      _password,
      acceptedCosts: _lightCosts,
    );
  }

  test('one close friend less than two: the pieces stay with both for the '
      'wait, and a recovery with them still works', () async {
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
    expect(o.protection.secured, isTrue);

    // Someone holding the unlocked phone for a minute (or the person by
    // mistake) takes the "Przyjaciel" level off one of the two.
    close = <String>[x];
    now += 1000;
    await o.reconcile();
    await _settle();
    expect(hx.heldFor, isNotEmpty, reason: 'nothing is forgotten at once');
    expect(hy.heldFor, isNotEmpty);
    expect(o.generation!.holders, <String>[x, y]);
    expect(o.protection.secured, isTrue);

    // The phone is gone the next day: x and y still give the account back.
    now += const Duration(days: 1).inMilliseconds;
    net.offline.add(owner);
    final List<RecoveredAccount> got = await recoverFrom(<RecoveryService>[
      hx,
      hy,
    ], id.account);
    expect(got.map((RecoveredAccount r) => r.account), <String>[id.account]);
  });

  test('two changes of the close friends in a row: the holder who was '
      'online keeps the last complete set, and it still opens', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    final String z = _a('200::c3');
    final String w = _a('200::c4');
    List<String> close = <String>[x, y];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, y, z, w},
      identity: () => rid,
      holders: () => close,
    );
    final Map<String, RecoveryService> h = <String, RecoveryService>{
      for (final String a in <String>[x, y, z, w])
        a: await make(a, friends: <String>{owner}),
    };
    await o.setSeal(await seal(id));
    await _settle();
    expect(o.generation!.complete, isTrue);
    final int first = o.generation!.generation;

    // y, z and w are away; the person marks z, then (minutes later) w as
    // close. x is online and takes both new generations.
    net.offline.addAll(<String>[y, z, w]);
    close = <String>[x, y, z];
    now += 60 * 1000;
    await o.reconcile();
    await _settle();
    close = <String>[x, y, z, w];
    now += 60 * 1000;
    await o.reconcile();
    await _settle();
    expect(o.generation!.complete, isFalse);
    expect(_generationsAt(h[x]!, id.account), contains(first));

    // The phone is lost before y, z, w came back: x and y open it.
    net.offline
      ..clear()
      ..add(owner);
    final List<RecoveredAccount> got = await recoverFrom(<RecoveryService>[
      h[x]!,
      h[y]!,
    ], id.account);
    expect(got.map((RecoveredAccount r) => r.account), <String>[id.account]);
  });

  test('a real change of the close friends still completes, and then the '
      'older set is forgotten by those who keep the new one', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final String y = _a('200::c2');
    final String z = _a('200::c3');
    List<String> close = <String>[x, y];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, y, z},
      identity: () => rid,
      holders: () => close,
    );
    final Map<String, RecoveryService> h = <String, RecoveryService>{
      for (final String a in <String>[x, y, z])
        a: await make(a, friends: <String>{owner}),
    };
    await o.setSeal(await seal(id));
    await _settle();
    final int first = o.generation!.generation;

    // z is away when it becomes close: x and y confirm, the new set is
    // complete (2 of 3) and "forget older" goes to x and y only.
    net.offline.add(z);
    close = <String>[x, y, z];
    now += 60 * 1000;
    await o.reconcile();
    await _settle();
    final int second = o.generation!.generation;
    expect(o.generation!.complete, isTrue);
    expect(_generationsAt(h[x]!, id.account), <int>[second]);
    expect(_generationsAt(h[y]!, id.account), <int>[second]);
    final _Linked out = net.nodes[owner]!;
    expect(
      out.sent
          .where(
            (({String to, Map<String, dynamic> payload}) s) =>
                s.payload['type'] == RecoveryMessages.forget,
          )
          .map((({String to, Map<String, dynamic> payload}) s) => s.to)
          .toSet(),
      <String>{x, y},
    );
    expect(first, lessThan(second));

    // z comes back: it gets its piece, confirms, and is told then.
    net.offline.clear();
    now += kPieceRetry.inMilliseconds;
    await o.tick();
    await _settle();
    expect(_generationsAt(h[z]!, id.account), <int>[second]);
    expect(o.generation!.acked, 3);
  });

  test('a holder who stopped answering no longer makes the account secured; '
      'those who answer the weekly offers keep it so', () async {
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
    expect(o.protection.secured, isTrue);
    // Both answer for half a year.
    for (int week = 0; week < 26; week++) {
      now += kPieceReoffer.inMilliseconds;
      await o.tick();
      await _settle();
    }
    expect(o.protection.secured, isTrue);
    // y removed Zen (still an accepted friend here): its weekly offers go
    // unanswered.
    net.nodes.remove(y);
    for (int week = 0; week < 6; week++) {
      now += kPieceReoffer.inMilliseconds;
      await o.tick();
      await _settle();
    }
    expect(o.protection.secured, isFalse);
    expect(o.protection.acked, 1);
  });
}

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);
const List<PasswordCost> _lightCosts = <PasswordCost>[_light];
const String _password = 'dobre-haslo-123';

List<int> _generationsAt(RecoveryService holder, String account) => <int>[
  for (final Object? p
      in ((holder.syncState()['held']! as Map<String, Object?>)[account]!
              as Map<String, dynamic>)['pieces']
          as List)
    RecoveryPiece.fromJson(p)!.generation,
];

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.net);

  final String address;
  final _Net net;
  final List<({String to, Map<String, dynamic> payload})> sent =
      <({String to, Map<String, dynamic> payload})>[];

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String to = PeerShareCodec.normalizeAddress(remoteAddress);
    sent.add((to: to, payload: payload));
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
