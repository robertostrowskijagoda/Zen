import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/shamir.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);
const String _password = 'dobre-haslo-123';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 20; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('Shamir: any threshold of shares gives the secret back', () {
    final Uint8List secret = randomBytes(32);
    final List<Uint8List> shares = shamirSplit(secret, 3, 6);
    for (int a = 0; a < 6; a++) {
      for (int b = a + 1; b < 6; b++) {
        for (int c = b + 1; c < 6; c++) {
          expect(
            shamirCombine(<Uint8List>[shares[a], shares[b], shares[c]]),
            secret,
          );
        }
      }
    }
    expect(
      shamirCombine(<Uint8List>[shares[0], shares[1]]),
      isNot(equals(secret)),
    );
    expect(
      () => shamirCombine(<Uint8List>[shares[0], shares[0]]),
      throwsArgumentError,
    );
  });

  test('the seed comes back with 2 pieces + password, or 4 without', () async {
    final Uint8List seed = randomBytes(32);
    final List<RecoveryPiece> pieces = await createRecoveryPieces(
      account: 'konto',
      seed: seed,
      password: _password,
      helpers: 6,
      now: 1,
      cost: _light,
    );
    expect(pieces, hasLength(6));
    List<Map<String, dynamic>> normals(
      Iterable<int> i,
    ) => <Map<String, dynamic>>[
      for (final int k in i) RecoveryPiece.fromJson(pieces[k].toJson())!.normal,
    ];
    List<Map<String, dynamic>> emergencies(Iterable<int> i) =>
        <Map<String, dynamic>>[for (final int k in i) pieces[k].emergency];

    expect(await recoverWithPassword(normals(<int>[1, 4]), _password), seed);
    expect(
      await recoverWithPassword(normals(<int>[1, 4]), 'zle-haslo-9'),
      null,
    );
    expect(await recoverWithPassword(normals(<int>[2]), _password), isNull);
    expect(await recoverWithoutPassword(emergencies(<int>[0, 2, 3, 5])), seed);
    expect(await recoverWithoutPassword(emergencies(<int>[0, 2, 3])), isNull);

    // A stranger's fake half does not spoil the real ones.
    final Map<String, dynamic> fake = <String, dynamic>{
      ...pieces[0].normal,
      'share': b64(randomBytes(33)),
    };
    expect(
      await recoverWithPassword(<Map<String, dynamic>>[
        fake,
        ...normals(<int>[3, 5]),
      ], _password),
      seed,
    );
    expect(
      () => createRecoveryPieces(
        account: 'konto',
        seed: seed,
        password: 'krotkie',
        helpers: 6,
        now: 1,
        cost: _light,
      ),
      throwsArgumentError,
    );
  });

  test('with a password the account key is stored only wrapped', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity first = await LedgerIdentity.loadOrCreate(disk);
    final Uint8List seed = first.accountKey!.seed;
    await first.setPassword(disk, _password, cost: _light);
    expect(first.hasPassword, isTrue);

    final LedgerIdentity again = await LedgerIdentity.loadOrCreate(disk);
    expect(again.account, first.account);
    expect(again.accountKey, isNull);
    expect(await again.unlock('zle-haslo-9'), isFalse);
    expect(await again.unlock(_password), isTrue);
    expect(again.accountKey!.seed, seed);
    again.lock();
    expect(again.accountKey, isNull);

    // A new device of the same account (after recovery).
    final MemoryLedgerDisk other = MemoryLedgerDisk();
    final LedgerIdentity adopted = await LedgerIdentity.adoptAccount(
      other,
      seed,
    );
    expect(adopted.account, first.account);
    expect(adopted.deviceKey.id, isNot(first.deviceKey.id));
    expect(adopted.certificate.account, first.account);
  });

  group('over the network', () {
    final String owner = PeerShareCodec.normalizeAddress('200::a');
    final String fresh = PeerShareCodec.normalizeAddress('200::f');
    final List<String> helpers = <String>[
      for (int i = 1; i <= 6; i++) PeerShareCodec.normalizeAddress('200::b$i'),
    ];
    late Map<String, _Linked> nodes;
    late Map<String, RecoveryService> services;
    late int now;

    Future<RecoveryService> make(String address, Set<String> friends) async {
      final _Linked t = nodes[address] = _Linked(address, nodes);
      await t.start();
      final RecoveryService s = RecoveryService(
        transport: t,
        disk: MemoryLedgerDisk(),
        isFriend: (String a) => friends.contains(a),
        clock: () => now,
        tickInterval: const Duration(hours: 1),
      );
      addTearDown(s.stop);
      await s.start();
      return services[address] = s;
    }

    setUp(() async {
      nodes = <String, _Linked>{};
      services = <String, RecoveryService>{};
      now = 1000;
      await make(owner, helpers.toSet());
      for (final String h in helpers) {
        await make(h, <String>{owner});
      }
      await make(fresh, const <String>{});
    });

    test('helpers keep pieces and release them after the delay', () async {
      final Uint8List seed = randomBytes(32);
      await services[owner]!.distribute(
        helpers,
        await createRecoveryPieces(
          account: 'konto',
          seed: seed,
          password: _password,
          helpers: 6,
          now: now,
          cost: _light,
        ),
      );
      await _settle();
      expect(services[owner]!.acks, hasLength(6));
      expect(services[helpers[0]]!.heldFor, <String>[owner]);

      for (final String h in helpers.take(2)) {
        await services[h]!.startHelping(owner, fresh);
      }
      await _settle();
      expect(services[owner]!.alarms, hasLength(2));
      // Nothing before the delay.
      for (final String h in helpers.take(2)) {
        await services[h]!.tick();
      }
      await _settle();
      expect(services[fresh]!.receivedCount(RecoveryKind.normal), 0);

      now += kNormalDelay.inMilliseconds;
      for (final String h in helpers.take(2)) {
        await services[h]!.tick();
      }
      await _settle();
      final RecoveryService f = services[fresh]!;
      expect(f.receivedCount(RecoveryKind.normal), 2);
      expect(
        await recoverWithPassword(f.received(RecoveryKind.normal), _password),
        seed,
      );
    });

    test('the owner stops a release from the old device', () async {
      await services[owner]!.distribute(
        helpers,
        await createRecoveryPieces(
          account: 'konto',
          seed: randomBytes(32),
          password: _password,
          helpers: 6,
          now: now,
          cost: _light,
        ),
      );
      await _settle();
      await services[helpers[2]]!.startHelping(owner, fresh);
      await _settle();
      await services[owner]!.cancelAlarm(services[owner]!.alarms.single);
      await _settle();
      expect(services[helpers[2]]!.pending, isEmpty);
      now += kEmergencyDelay.inMilliseconds;
      await services[helpers[2]]!.tick();
      await _settle();
      expect(services[fresh]!.receivedCount(RecoveryKind.normal), 0);
    });

    test('strangers cannot plant pieces with helpers', () async {
      await nodes[fresh]!.send(
        remoteAddress: helpers[0],
        payload: <String, dynamic>{
          'type': RecoveryMessages.store,
          'piece': (await createRecoveryPieces(
            account: 'obcy',
            seed: randomBytes(32),
            password: _password,
            helpers: 4,
            now: now,
            cost: _light,
          )).first.toJson(),
        },
      );
      await _settle();
      expect(services[helpers[0]]!.heldFor, isEmpty);
    });
  });

  testWidgets('the screen asks for matching passwords and enough helpers', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: const MaterialApp(home: AccountRecoveryScreen()),
      ),
    );
    for (int i = 0; i < 20; i++) {
      await tester.runAsync(() => _settle());
      await tester.pump(const Duration(milliseconds: 50));
      if (find
          .byKey(const Key('recovery-set-password'))
          .evaluate()
          .isNotEmpty) {
        break;
      }
    }
    expect(find.text('Nikt jeszcze nie powierzył Ci klucza.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('recovery-password')),
      'abcdefgh',
    );
    await tester.enterText(
      find.byKey(const Key('recovery-password-repeat')),
      'abcdefgX',
    );
    await tester.tap(find.byKey(const Key('recovery-set-password')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.text('Hasła się różnią.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('recovery-password-repeat')),
      'abcdefgh',
    );
    await tester.tap(find.byKey(const Key('recovery-set-password')));
    await tester.runAsync(() => _settle());
    await tester.pump();
    expect(find.textContaining('co najmniej 4 znajomych'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });
}
