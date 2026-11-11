import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);
const List<PasswordCost> _lightCosts = <PasswordCost>[_light];
const String _password = 'dobre-haslo-123';

/// Delivers between the services of a test; a node that is [offline]
/// gets nothing, and [dropped] message types never arrive (a helper on
/// 1.16.4 that ignores them).
final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.net);

  final String address;
  final _Net net;
  final Set<String> dropped = <String>{};

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String to = PeerShareCodec.normalizeAddress(remoteAddress);
    final _Linked? target = net.nodes[to];
    _traffic++;
    if (target == null ||
        net.offline.contains(to) ||
        target.dropped.contains(payload['type'])) {
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

/// Messages sent so far by any node of a test.
int _traffic = 0;

/// Waits until nothing was sent for a while (signing and checking a
/// device's signature take some time), at most a few seconds.
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

/// An account with its first device, as the recovery signs with it.
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

void main() {
  late _Net net;
  late int now;
  late Set<String> revoked;

  setUp(() {
    net = _Net();
    now = 1000000;
    revoked = <String>{};
  });

  Future<RecoveryService> make(
    String address, {
    Set<String> friends = const <String>{},
    RecoveryIdentity? Function()? identity,
    List<String>? Function()? holders,
    bool? Function(String account)? isFriendAccount,
    LedgerDisk? disk,
  }) async {
    final _Linked t = net.nodes[address] = _Linked(address, net);
    await t.start();
    final RecoveryService s = RecoveryService(
      transport: t,
      disk: disk ?? MemoryLedgerDisk(),
      isFriend: (String a) => friends.contains(a),
      identity: identity,
      holders: holders,
      isFriendAccount: isFriendAccount,
      isRevoked: (String account, String device) => revoked.contains(device),
      clock: () => now,
      tickInterval: const Duration(hours: 1),
      acceptedCosts: _lightCosts,
    );
    addTearDown(s.stop);
    await s.start();
    return s;
  }

  Future<RecoverySeal> seal(LedgerIdentity id, [String p = _password]) =>
      RecoverySeal.make(id.accountKey!.seed, p, now: now, cost: _light);

  /// [helper] gives [owner]'s pieces to [fresh] and the delay passes.
  Future<void> release(
    RecoveryService helper,
    String owner,
    String fresh,
  ) async {
    await helper.startHelping(owner, fresh);
    await _settle();
  }

  test('the account password: long, not easy to guess', () {
    for (final String weak in <String>[
      'krotkie-1',
      'aaaaaaaaaaaaaaaa',
      'qwertyuiop1234',
      'abcdefghijklmn',
      'password123456',
    ]) {
      expect(() => checkRecoveryPassword(weak), throwsArgumentError);
    }
    checkRecoveryPassword('korek-ryba-las-77');
    checkRecoveryPassword(_password);
  });

  test('threshold bands: 2 of up to 4, 3 of 5–9, 4 of 10 or more', () async {
    expect(
      <int>[for (int n = 2; n <= 12; n++) pieceThreshold(n)],
      <int>[2, 2, 2, 3, 3, 3, 3, 3, 4, 4, 4],
    );
    final (LedgerIdentity id, _) = await _account();
    final RecoverySeal s = await seal(id);
    for (final int n in <int>[4, 5, 9, 10]) {
      final List<RecoveryPiece> pieces = await createGenerationPieces(
        account: id.account,
        seal: s,
        holders: n,
        generation: 7,
      );
      final int t = pieceThreshold(n);
      List<Map<String, dynamic>> halves(int k) => <Map<String, dynamic>>[
        for (int i = 0; i < k; i++)
          <String, dynamic>{
            ...pieces[i].normal,
            'account': id.account,
            'from': 'h$i',
          },
      ];
      expect(pieces.first.threshold, t, reason: '$n holders');
      expect(
        await recoverWithPassword(
          halves(t - 1),
          _password,
          acceptedCosts: _lightCosts,
        ),
        isEmpty,
        reason: '${t - 1} of $n are not enough',
      );
      final List<RecoveredAccount> got = await recoverWithPassword(
        halves(t),
        _password,
        acceptedCosts: _lightCosts,
      );
      expect(got.single.seed, id.accountKey!.seed, reason: '$t of $n');
      expect(
        await recoverWithPassword(
          halves(t),
          'zle-haslo-zle',
          acceptedCosts: _lightCosts,
        ),
        isEmpty,
      );
    }
    // A share of one generation never completes another's.
    final List<RecoveryPiece> a = await createGenerationPieces(
      account: id.account,
      seal: s,
      holders: 3,
      generation: 1,
    );
    final List<RecoveryPiece> b = await createGenerationPieces(
      account: id.account,
      seal: s,
      holders: 3,
      generation: 2,
    );
    expect(
      await recoverWithPassword(
        <Map<String, dynamic>>[
          <String, dynamic>{...a[0].normal, 'account': id.account, 'from': 'x'},
          <String, dynamic>{...b[1].normal, 'account': id.account, 'from': 'y'},
        ],
        _password,
        acceptedCosts: _lightCosts,
      ),
      isEmpty,
    );
  });

  test('recovery end to end with 3 close friends', () async {
    final String owner = _a('200::a');
    final String fresh = _a('200::f');
    final List<String> close = <String>[
      _a('200::c1'),
      _a('200::c2'),
      _a('200::c3'),
    ];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: close.toSet(),
      identity: () => rid,
      holders: () => close,
    );
    final Map<String, RecoveryService> h = <String, RecoveryService>{
      for (final String c in close) c: await make(c, friends: <String>{owner}),
    };
    final RecoveryService f = await make(fresh);

    // Nothing is handed out before the password.
    await o.reconcile();
    expect(o.generation, isNull);
    expect(o.protection.secured, isFalse);

    await o.setSeal(await seal(id));
    await _settle();
    expect(o.generation!.threshold, 2);
    expect(o.generation!.holders.toSet(), close.toSet());
    expect(o.generation!.acked, 3);
    expect(o.protection.secured, isTrue);
    for (final RecoveryService helper in h.values) {
      // Kept under the owner's account, proved by its device's signature.
      expect(helper.heldFor, <String>[id.account]);
      expect(helper.heldAccount(id.account), id.account);
    }

    await f.beginRecovery();
    for (final String c in close.take(2)) {
      expect(await f.allowHelper(c), isTrue);
      await release(h[c]!, id.account, fresh);
    }
    expect(o.alarms, hasLength(2), reason: 'the old phone hears it');
    now += kNormalDelay.inMilliseconds;
    for (final String c in close.take(2)) {
      await h[c]!.tick();
    }
    await _settle();
    expect(f.receivedProgress, (got: 2, needed: 2));
    final RecoveredAccount got = (await recoverWithPassword(
      f.received(RecoveryKind.normal),
      _password,
      acceptedCosts: _lightCosts,
    )).single;
    expect(got.seed, id.accountKey!.seed);
    expect(got.account, id.account);
    expect(got.helpers, close.take(2).toSet());
  });

  test('pieces go out again until confirmed, and "secured" waits for enough '
      'confirmations', () async {
    final String owner = _a('200::a');
    final List<String> close = <String>[
      for (int i = 1; i <= 5; i++) _a('200::c$i'),
    ];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: close.toSet(),
      identity: () => rid,
      holders: () => close,
    );
    for (final String c in close) {
      await make(c, friends: <String>{owner});
    }
    net.offline.addAll(close.skip(2));
    await o.setSeal(await seal(id));
    await _settle();
    expect(o.generation!.threshold, 3, reason: 'five holders');
    expect(o.generation!.acked, 2);
    expect(o.protection.secured, isFalse, reason: '2 of 3 needed confirmed');

    // Back online: sent again after a while, not at once.
    net.offline.clear();
    await o.tick();
    await _settle();
    expect(o.generation!.acked, 2);
    now += kPieceRetry.inMilliseconds;
    await o.tick();
    await _settle();
    expect(o.generation!.acked, 5);
    expect(o.protection.secured, isTrue);

    // What the settings read: secured only so.
    final ProviderContainer c = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: const AppSettings(),
          hydrationEnabled: false,
        ),
        recoveryProtectionProvider.overrideWith(
          (Ref ref) => Stream<RecoveryProtection>.value(
            const RecoveryProtection(
              sealed: true,
              holders: 5,
              threshold: 3,
              acked: 2,
            ),
          ),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(recoveryProtectionProvider, (_, _) {});
    await c.read(recoveryProtectionProvider.future);
    expect(accountIsSecured(c.read), isFalse);
    await c
        .read(appSettingsControllerProvider.notifier)
        .setPaperBackupDone(true);
    expect(accountIsSecured(c.read), isTrue, reason: 'a key copy');
  });

  test('after friends stop being close, two former holders with the old '
      'password get nothing from honest helpers', () async {
    final String owner = _a('200::a');
    final String fresh = _a('200::f');
    final String a = _a('200::c1');
    final String b = _a('200::c2');
    final String c = _a('200::c3');
    final String d = _a('200::c4');
    final String e = _a('200::c5');
    List<String> close = <String>[a, b, c];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{a, b, c, d, e},
      identity: () => rid,
      holders: () => close,
    );
    final Map<String, RecoveryService> h = <String, RecoveryService>{
      for (final String x in <String>[a, b, c, d, e])
        x: await make(x, friends: <String>{owner}),
    };
    await o.setSeal(await seal(id));
    await _settle();
    expect(o.generation!.complete, isTrue);
    final int first = o.generation!.generation;

    // What A and B could copy out of their apps while they held pieces.
    final List<Map<String, dynamic>> copies = <Map<String, dynamic>>[
      for (final String x in <String>[a, b])
        <String, dynamic>{
          ...(h[x]!.syncState()['held']! as Map<String, Object?>).values
              .cast<Map<String, dynamic>>()
              .single['pieces']
              .first['normal'],
          'account': id.account,
          'from': x,
        },
    ];

    // A and B are no longer close; D and E are.
    close = <String>[c, d, e];
    now += 1000;
    await o.reconcile();
    await _settle();
    final RecoveryGeneration g = o.generation!;
    expect(g.generation, greaterThan(first));
    expect(g.complete, isTrue);
    // Honest former holders were told to forget, and did.
    for (final String x in <String>[a, b]) {
      expect(h[x]!.heldFor, isEmpty, reason: x);
      expect(() => h[x]!.startHelping(id.account, fresh), throwsStateError);
    }
    // The one who stays keeps only the new generation.
    final Map<String, dynamic> kept =
        (h[c]!.syncState()['held']! as Map<String, Object?>)[id.account]!
            as Map<String, dynamic>;
    expect(kept['pieces'], hasLength(1));
    expect(
      RecoveryPiece.fromJson((kept['pieces'] as List).first)!.generation,
      g.generation,
    );

    // So A and B together give a new device nothing.
    final RecoveryService f = await make(fresh);
    await f.beginRecovery();
    await f.allowHelper(a);
    await f.allowHelper(b);
    now += kNormalDelay.inMilliseconds;
    await h[a]!.tick();
    await h[b]!.tick();
    await _settle();
    expect(f.receivedCount(RecoveryKind.normal), 0);
    expect(
      await recoverWithPassword(
        f.received(RecoveryKind.normal),
        _password,
        acceptedCosts: _lightCosts,
      ),
      isEmpty,
    );
    // And an old share never completes a new one: A's old piece with C's
    // new one opens nothing.
    expect(
      await recoverWithPassword(
        <Map<String, dynamic>>[
          copies.first,
          <String, dynamic>{
            ...(kept['pieces'] as List).first['normal'] as Map<String, dynamic>,
            'account': id.account,
            'from': c,
          },
        ],
        _password,
        acceptedCosts: _lightCosts,
      ),
      isEmpty,
    );

    // What dishonest former holders can still do: pieces they copied out
    // of the app before they were told to forget are of a generation of
    // their own; together they open its circle box, and with the account
    // password of that time (known or guessed offline, one Argon2id run a
    // guess) they open the seed, which never changes. Only a password
    // they cannot guess protects against that.
    expect(
      (await recoverWithPassword(
        copies,
        _password,
        acceptedCosts: _lightCosts,
      )).single.seed,
      id.accountKey!.seed,
    );
  });

  test('a removed friend loses the piece by itself, weeks after', () async {
    final String owner = _a('200::a');
    final String x = _a('200::c1');
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{x, _a('200::c2')},
      identity: () => rid,
      holders: () => <String>[x, _a('200::c2')],
    );
    await make(_a('200::c2'), friends: <String>{owner});
    final Set<String> friends = <String>{owner};
    final RecoveryService helper = await make(
      x,
      friends: friends,
      isFriendAccount: (String account) => friends.isNotEmpty,
    );
    await o.setSeal(await seal(id));
    await _settle();
    expect(helper.heldFor, <String>[id.account]);
    // The owner's phone is gone (nobody says to forget); the friendship
    // ends here.
    net.offline.add(owner);
    friends.clear();
    await helper.tick();
    now += kPiecesAfterFriendship.inMilliseconds - 1;
    await helper.tick();
    expect(helper.heldFor, hasLength(1), reason: 'not yet');
    now += 1;
    await helper.tick();
    expect(helper.heldFor, isEmpty);
  });

  test('pieces follow a helper to a new phone, and come back to one '
      'restored from the key alone', () async {
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
    await make(y, friends: <String>{owner});
    final RecoveryService phone = await make(x, friends: <String>{owner});
    await o.setSeal(await seal(id));
    await _settle();

    // The helper's other device (and its move, its full copy) gets them.
    expect(kAccountRawKeys[AccountScope.keys], contains('recovery/pieces'));
    final RecoveryService other = await make(
      _a('200::c1b'),
      friends: <String>{owner},
    );
    await other.takeSyncState(phone.syncState());
    expect(other.heldFor, <String>[id.account]);
    final String fresh = _a('200::f');
    final RecoveryService f = await make(fresh);
    await f.beginRecovery();
    await f.allowHelper(_a('200::c1b'));
    await other.startHelping(id.account, fresh);
    now += kNormalDelay.inMilliseconds;
    await other.tick();
    await _settle();
    expect(f.receivedCount(RecoveryKind.normal), 1);

    // Forgotten on one device: gone from the other at the next sync.
    await phone.takeSyncState(<String, Object?>{'held': <String, Object?>{}});
    expect(phone.heldFor, isEmpty);

    // A phone restored from the key alone (nothing of the old one): the
    // piece comes back with the weekly offer.
    net.nodes.remove(x);
    final RecoveryService restored = await make(x, friends: <String>{owner});
    expect(restored.heldFor, isEmpty);
    now += kPieceReoffer.inMilliseconds;
    await o.tick();
    await _settle();
    expect(restored.heldFor, <String>[id.account]);

    // The owner's other device shows the same state of its pieces.
    final RecoveryService ownerOther = await make(_a('200::a2'));
    await ownerOther.takeSyncState(o.syncState());
    expect(ownerOther.protection.secured, isTrue);
    expect(ownerOther.handsOut, isFalse, reason: 'no seal there');
  });

  test('a cancel counts only from a device the account has not cut off, '
      'and a stopped release can still go out a week later', () async {
    final String owner = _a('200::a');
    final String thiefAddress = _a('200::a9');
    final String fresh = _a('200::f');
    final List<String> close = <String>[_a('200::c1'), _a('200::c2')];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    // The stolen phone: another device of the same account.
    final LedgerKeyPair stolenKey = await LedgerKeyPair.generate();
    final RecoveryIdentity stolen = RecoveryIdentity(
      account: id.account,
      deviceKey: stolenKey,
      certificate: await DeviceCertificate.issue(
        account: id.accountKey!,
        device: stolenKey,
        name: 'Telefon',
        issued: 1,
      ),
    );
    final RecoveryService o = await make(
      owner,
      friends: close.toSet(),
      identity: () => rid,
      holders: () => close,
    );
    final RecoveryService thief = await make(
      thiefAddress,
      friends: close.toSet(),
      identity: () => stolen,
    );
    final RecoveryService helper = await make(
      close.first,
      friends: <String>{owner, thiefAddress},
    );
    await make(close.last, friends: <String>{owner});
    await o.setSeal(await seal(id));
    await _settle();
    final RecoveryService f = await make(fresh);
    await f.beginRecovery();
    await f.allowHelper(close.first);

    Future<void> cancelFrom(RecoveryService s) async {
      await s.cancelAlarm(
        RecoveryAlarm(
          helper: close.first,
          to: fresh,
          kind: RecoveryKind.normal,
          due: now,
        ),
      );
      await _settle();
    }

    await helper.startHelping(id.account, fresh);
    await _settle();
    // The account cut the stolen phone off: its stop does not count.
    revoked.add(stolenKey.id);
    await cancelFrom(thief);
    expect(helper.pending.single.stopped, isNull);
    // Nor does an unsigned one from the owner's address.
    await net.nodes[owner]!.send(
      remoteAddress: close.first,
      payload: const <String, dynamic>{'type': RecoveryMessages.cancel},
    );
    await _settle();
    expect(helper.pending.single.stopped, isNull);

    // Not cut off yet: the thief keeps stopping every release.
    revoked.clear();
    await cancelFrom(thief);
    final PendingRelease stopped = helper.pending.single;
    expect(stopped.stopped, isNotNull);
    now += kNormalDelay.inMilliseconds;
    await helper.tick();
    await _settle();
    expect(f.receivedCount(RecoveryKind.normal), 0, reason: 'stopped');

    // The helper talked to the person and gives it after all: a week
    // later, with a new alarm; a stop no longer counts.
    await helper.overrideRelease(stopped);
    await _settle();
    expect(helper.pending.single.override, isTrue);
    expect(o.alarms.last.override, isTrue);
    await cancelFrom(thief);
    await cancelFrom(o);
    expect(helper.pending.single.stopped, isNull);
    now += kOverrideDelay.inMilliseconds - 1;
    await helper.tick();
    await _settle();
    expect(f.receivedCount(RecoveryKind.normal), 0, reason: 'not yet');
    now += 1;
    await helper.tick();
    await _settle();
    expect(f.receivedCount(RecoveryKind.normal), 1);
  });

  test('a 1.16.4 circle keeps working until enough close friends confirm '
      'the new pieces, then its people are told to forget', () async {
    final String owner = _a('200::a');
    final String fresh = _a('200::f');
    final List<String> chosen = <String>[
      _a('200::b1'),
      _a('200::b2'),
      _a('200::b3'),
    ];
    final List<String> closeAll = <String>[_a('200::c1'), _a('200::c2')];
    List<String> close = <String>[closeAll.first];
    final (LedgerIdentity id, RecoveryIdentity rid) = await _account();
    final RecoveryService o = await make(
      owner,
      friends: <String>{...chosen, ...closeAll},
      identity: () => rid,
      holders: () => close,
    );
    final Map<String, RecoveryService> h = <String, RecoveryService>{
      for (final String x in <String>[...chosen, ...closeAll])
        x: await make(x, friends: <String>{owner}),
    };
    // The third runs 1.16.4: it never hears "forget".
    net.nodes[chosen.last]!.dropped.add(RecoveryMessages.forget);

    // The circle chosen by hand in 1.16.4, under the password of then.
    await o.distribute(
      chosen,
      await createRecoveryPieces(
        account: id.account,
        seed: id.accountKey!.seed,
        password: _password,
        helpers: 3,
        now: now,
        cost: _light,
      ),
    );
    await _settle();
    expect(o.protection.secured, isTrue);

    // Upgraded: the password is given once; one close friend is not
    // enough for pieces, so the old circle stays as it is.
    await o.setSeal(await seal(id));
    await _settle();
    expect(o.generation, isNull);
    expect(o.protection.legacy, 3);
    expect(o.protection.secured, isTrue);

    // Two close friends: new pieces; one of them is away, so the new set
    // is not complete and the old circle still works.
    close = closeAll;
    net.offline.add(closeAll.last);
    await o.reconcile();
    await _settle();
    expect(o.generation!.complete, isFalse);
    expect(o.protection.legacy, 3);
    final RecoveryService f = await make(fresh);
    await f.beginRecovery();
    for (final String x in chosen.take(2)) {
      await f.allowHelper(x);
      await h[x]!.startHelping(owner, fresh);
    }
    now += kNormalDelay.inMilliseconds;
    for (final String x in chosen.take(2)) {
      await h[x]!.tick();
    }
    await _settle();
    expect(
      (await recoverWithPassword(
        f.received(RecoveryKind.normal),
        _password,
        acceptedCosts: _lightCosts,
      )).single.seed,
      id.accountKey!.seed,
    );

    // Both confirm: the old circle is told to forget its pieces.
    net.offline.clear();
    now += kPieceRetry.inMilliseconds;
    await o.tick();
    await _settle();
    expect(o.generation!.complete, isTrue);
    expect(o.protection.legacy, 0);
    expect(o.circle, isEmpty);
    expect(h[chosen.first]!.heldFor, isEmpty);
    expect(h[chosen[1]]!.heldFor, isEmpty);
    // A helper still on 1.16.4 ignores it and keeps its old piece.
    expect(h[chosen.last]!.heldFor, hasLength(1));
  });

  test('a helper keeps the generation before until the new one is complete, '
      'and gives both', () async {
    final String owner = _a('200::a');
    final String fresh = _a('200::f');
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
    // z joins; y and z are away, so only x has the new generation, which
    // is not complete: x keeps the one before too.
    close = <String>[x, y, z];
    net.offline.addAll(<String>[y, z]);
    now += 1000;
    await o.reconcile();
    await _settle();
    expect(o.generation!.holders, hasLength(3));
    expect(o.generation!.complete, isFalse);
    final Map<String, dynamic> kept =
        (h[x]!.syncState()['held']! as Map<String, Object?>)[id.account]!
            as Map<String, dynamic>;
    expect(kept['pieces'], hasLength(2));

    // The phone is lost now: x (both generations) and y (the one before)
    // still open the account together.
    net.offline.clear();
    net.offline.add(owner);
    final RecoveryService f = await make(fresh);
    await f.beginRecovery();
    for (final String a in <String>[x, y]) {
      await f.allowHelper(a);
      await h[a]!.startHelping(id.account, fresh);
    }
    now += kNormalDelay.inMilliseconds;
    for (final String a in <String>[x, y]) {
      await h[a]!.tick();
    }
    await _settle();
    expect(f.receivedCount(RecoveryKind.normal), 3);
    expect(
      (await recoverWithPassword(
        f.received(RecoveryKind.normal),
        _password,
        acceptedCosts: _lightCosts,
      )).single.seed,
      id.accountKey!.seed,
    );
  });
}
