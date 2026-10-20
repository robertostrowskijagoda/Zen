import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
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
const List<PasswordCost> _lightCosts = <PasswordCost>[_light];

/// The seed of the only account found, `null` when none.
Uint8List? _seedOf(List<RecoveredAccount> found) =>
    found.isEmpty ? null : found.single.seed;

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
    final LedgerKeyPair key = await LedgerKeyPair.generate();
    final Uint8List seed = key.seed;
    final List<RecoveryPiece> pieces = await createRecoveryPieces(
      account: key.id,
      seed: seed,
      password: _password,
      helpers: 6,
      now: 1,
      cost: _light,
    );
    expect(pieces, hasLength(6));
    // A received half names the account it is for.
    List<Map<String, dynamic>> normals(Iterable<int> i) =>
        <Map<String, dynamic>>[
          for (final int k in i)
            <String, dynamic>{
              ...RecoveryPiece.fromJson(pieces[k].toJson())!.normal,
              'account': key.id,
            },
        ];
    List<Map<String, dynamic>> emergencies(Iterable<int> i) =>
        <Map<String, dynamic>>[
          for (final int k in i)
            <String, dynamic>{...pieces[k].emergency, 'account': key.id},
        ];
    Future<Uint8List?> withPassword(
      List<Map<String, dynamic>> halves,
      String password,
    ) async => _seedOf(
      await recoverWithPassword(halves, password, acceptedCosts: _lightCosts),
    );

    expect(await withPassword(normals(<int>[1, 4]), _password), seed);
    expect(await withPassword(normals(<int>[1, 4]), 'zle-haslo-9'), isNull);
    expect(await withPassword(normals(<int>[2]), _password), isNull);
    expect(
      _seedOf(await recoverWithoutPassword(emergencies(<int>[0, 2, 3, 5]))),
      seed,
    );
    expect(await recoverWithoutPassword(emergencies(<int>[0, 2, 3])), isEmpty);
    // A cost the app does not write is never run.
    expect(await recoverWithPassword(normals(<int>[1, 4]), _password), isEmpty);

    // A stranger's fake half does not spoil the real ones.
    final Map<String, dynamic> fake = <String, dynamic>{
      ...pieces[0].normal,
      'share': b64(randomBytes(33)),
      'account': key.id,
    };
    expect(
      await withPassword(<Map<String, dynamic>>[
        fake,
        ...normals(<int>[3, 5]),
      ], _password),
      seed,
    );
    expect(
      () => createRecoveryPieces(
        account: key.id,
        seed: seed,
        password: 'krotkie',
        helpers: 6,
        now: 1,
        cost: _light,
      ),
      throwsArgumentError,
    );
  });

  test('the seed is bound to the account its pieces name', () async {
    final LedgerKeyPair mine = await LedgerKeyPair.generate();
    final LedgerKeyPair other = await LedgerKeyPair.generate();
    final List<RecoveryPiece> pieces = await createRecoveryPieces(
      account: mine.id,
      seed: mine.seed,
      password: _password,
      helpers: 5,
      now: 1,
      cost: _light,
    );
    List<Map<String, dynamic>> halves(
      List<RecoveryPiece> from, {
      String? account,
      String prefix = 'h',
    }) => <Map<String, dynamic>>[
      for (int i = 0; i < from.length; i++)
        <String, dynamic>{
          ...from[i].emergency,
          'account': ?account,
          'from': '$prefix$i',
        },
    ];

    // Named and checked.
    final RecoveredAccount got = (await recoverWithoutPassword(
      halves(pieces.take(4).toList(), account: mine.id),
    )).single;
    expect(got.account, mine.id);
    expect(got.seed, mine.seed);
    expect(got.helpers, <String>{'h0', 'h1', 'h2', 'h3'});
    expect(got.fingerprint, accountFingerprint(mine.id));

    // Halves that say they are another account's key are not taken.
    expect(
      await recoverWithoutPassword(
        halves(pieces.take(4).toList(), account: other.id),
      ),
      isEmpty,
    );

    // Halves that name no account are not used.
    expect(
      await recoverWithoutPassword(halves(pieces.take(4).toList())),
      isEmpty,
    );

    // A fake half naming the account does not count as a helper.
    final List<Map<String, dynamic>> mixed = <Map<String, dynamic>>[
      ...halves(pieces.take(5).toList(), account: mine.id),
      <String, dynamic>{
        ...pieces[0].emergency,
        'share': b64(randomBytes(33)),
        'account': mine.id,
        'from': 'fake',
      },
    ];
    final RecoveredAccount both = (await recoverWithoutPassword(mixed)).single;
    expect(both.helpers, hasLength(5));
    expect(both.helpers.contains('fake'), isFalse);

    // A full set for another account shows up as a second account.
    final List<RecoveryPiece> foreign = await createRecoveryPieces(
      account: other.id,
      seed: other.seed,
      password: _password,
      helpers: 4,
      now: 1,
      cost: _light,
    );
    final List<Map<String, dynamic>> all = <Map<String, dynamic>>[
      ...halves(pieces.take(4).toList(), account: mine.id),
      ...halves(foreign, account: other.id, prefix: 'x'),
    ];
    expect(
      (await recoverWithoutPassword(
        all,
      )).map((RecoveredAccount a) => a.account),
      unorderedEquals(<String>[mine.id, other.id]),
    );
    expect(claimedRecoveryAccounts(all), <String>{mine.id, other.id});
  });

  test('received halves keep only known fields and accepted costs', () async {
    final List<RecoveryPiece> pieces = await createRecoveryPieces(
      account: (await LedgerKeyPair.generate()).id,
      seed: randomBytes(32),
      password: _password,
      helpers: 4,
      now: 1,
    );
    final Map<String, dynamic> normal = pieces.first.normal;
    expect(recoveryHalfFields(normal, normal: true), isNotNull);
    expect(
      recoveryHalfFields(<String, dynamic>{
        ...normal,
        'cost': const PasswordCost().toJson(),
      }, normal: true),
      isNull,
      reason: 'only the cost pieces are written with is accepted',
    );
    expect(
      recoveryHalfFields(<String, dynamic>{
        ...normal,
        'cost': const PasswordCost(memoryKiB: 262144, iterations: 10).toJson(),
      }, normal: true),
      isNull,
    );
    expect(
      recoveryHalfFields(<String, dynamic>{
        ...pieces.first.emergency,
        'share': 'xx',
      }, normal: false),
      isNull,
    );
    final Map<String, dynamic>? kept = recoveryHalfFields(<String, dynamic>{
      ...pieces.first.emergency,
      'from': 'someone',
      'extra': List<int>.filled(1000, 1),
    }, normal: false);
    expect(kept!.keys, unorderedEquals(<String>['box', 'share']));
  });

  test('account fingerprints are 16 digits and differ per account', () async {
    final String a = (await LedgerKeyPair.generate()).id;
    final String b = (await LedgerKeyPair.generate()).id;
    expect(
      accountFingerprint(a),
      matches(RegExp(r'^\d{4} \d{4} \d{4} \d{4}$')),
    );
    expect(accountFingerprint(a), accountFingerprint(a));
    expect(accountFingerprint(a), isNot(accountFingerprint(b)));
  });

  test('a started recovery and its listed helpers survive a restart', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final RecoveryService first = RecoveryService(
      transport: MemorySignalTransport(),
      disk: disk,
      isFriend: (_) => false,
      clock: () => 5,
      tickInterval: const Duration(hours: 1),
    );
    addTearDown(first.stop);
    expect(await first.allowHelper('200::b1'), isFalse, reason: 'not started');
    await first.beginRecovery();
    expect(await first.allowHelper('200::b1'), isTrue);
    expect(await first.allowHelper('nie adres'), isFalse);

    final RecoveryService again = RecoveryService(
      transport: MemorySignalTransport(),
      disk: disk,
      isFriend: (_) => false,
      clock: () => 6,
      tickInterval: const Duration(hours: 1),
    );
    addTearDown(again.stop);
    await again.start();
    expect(again.collecting, isTrue);
    expect(again.allowedHelpers, <String>{
      PeerShareCodec.normalizeAddress('200::b1'),
    });
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
        acceptedCosts: _lightCosts,
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
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      await services[owner]!.distribute(
        helpers,
        await createRecoveryPieces(
          account: key.id,
          seed: key.seed,
          password: _password,
          helpers: 6,
          now: now,
          cost: _light,
        ),
      );
      await _settle();
      expect(services[owner]!.acks, hasLength(6));
      expect(services[helpers[0]]!.heldFor, <String>[owner]);
      expect(services[helpers[0]]!.heldAccount(owner), key.id);

      final RecoveryService f = services[fresh]!;
      await f.beginRecovery();
      // The person names who helps; only their pieces are taken.
      for (final String h in helpers.take(2)) {
        expect(await f.allowHelper(h), isTrue);
        await services[h]!.startHelping(owner, fresh);
      }
      await _settle();
      expect(services[owner]!.alarms, hasLength(2));
      // Nothing before the delay.
      for (final String h in helpers.take(2)) {
        await services[h]!.tick();
      }
      await _settle();
      expect(f.receivedCount(RecoveryKind.normal), 0);

      now += kNormalDelay.inMilliseconds;
      for (final String h in helpers.take(2)) {
        await services[h]!.tick();
      }
      await _settle();
      expect(f.receivedCount(RecoveryKind.normal), 2);
      // The helpers name the account the piece is for.
      expect(
        f
            .received(RecoveryKind.normal)
            .map((Map<String, dynamic> h) => h['account']),
        <String>[key.id, key.id],
      );
      final RecoveredAccount got = (await recoverWithPassword(
        f.received(RecoveryKind.normal),
        _password,
        acceptedCosts: _lightCosts,
      )).single;
      expect(got.seed, key.seed);
      expect(got.account, key.id);
      expect(got.helpers, helpers.take(2).toSet());

      await f.endRecovery();
      expect(f.collecting, isFalse);
      expect(f.receivedCount(RecoveryKind.normal), 0);
    });

    test('a new device takes pieces only while recovering, from listed '
        'helpers, one per sender, at the costs the app writes', () async {
      final String stranger = PeerShareCodec.normalizeAddress('200::66');
      await make(stranger, const <String>{});
      final LedgerKeyPair key = await LedgerKeyPair.generate();
      final List<RecoveryPiece> pieces = await createRecoveryPieces(
        account: key.id,
        seed: key.seed,
        password: _password,
        helpers: 4,
        now: now,
        cost: _light,
      );
      final RecoveryService f = services[fresh]!;
      Future<void> send(
        Map<String, dynamic> half, {
        RecoveryKind kind = RecoveryKind.emergency,
        Object? account,
      }) async {
        await nodes[stranger]!.send(
          remoteAddress: fresh,
          payload: <String, dynamic>{
            'type': RecoveryMessages.piece,
            'kind': kind.name,
            'half': half,
            'account': ?account,
          },
        );
        await _settle();
      }

      expect(f.collecting, isFalse);
      await send(pieces[0].emergency, account: key.id);
      expect(f.receivedCount(RecoveryKind.emergency), 0, reason: 'not started');

      await f.beginRecovery();
      expect(f.collecting, isTrue);
      // A fresh address nobody named cannot take the helpers' places (Z2-10).
      await send(pieces[0].emergency, account: key.id);
      expect(f.receivedCount(RecoveryKind.emergency), 0, reason: 'not named');

      expect(await f.allowHelper(stranger), isTrue);
      await send(pieces[0].emergency, account: key.id);
      await send(pieces[1].emergency, account: key.id);
      expect(f.receivedCount(RecoveryKind.emergency), 1, reason: 'one each');
      expect(f.received(RecoveryKind.emergency).single['from'], stranger);
      expect(f.received(RecoveryKind.emergency).single['account'], key.id);

      await send(<String, dynamic>{
        ...pieces[0].normal,
        'cost': const PasswordCost(memoryKiB: 262144, iterations: 10).toJson(),
      }, kind: RecoveryKind.normal);
      await send(pieces[0].normal, kind: RecoveryKind.normal, account: 'konto');
      expect(f.receivedCount(RecoveryKind.normal), 0);
      // A half that does not name its account is not taken.
      await send(pieces[0].normal, kind: RecoveryKind.normal);
      expect(f.receivedCount(RecoveryKind.normal), 0);
      await send(pieces[0].normal, kind: RecoveryKind.normal, account: key.id);
      expect(f.receivedCount(RecoveryKind.normal), 1);

      await f.endRecovery();
      expect(f.receivedCount(RecoveryKind.emergency), 0);
      await send(pieces[2].emergency, account: key.id);
      expect(f.receivedCount(RecoveryKind.emergency), 0, reason: 'ended');

      await f.beginRecovery();
      expect(f.allowedHelpers, isEmpty, reason: 'a fresh start');
      await f.allowHelper(stranger);
      now += RecoveryService.collectWindow.inMilliseconds;
      expect(f.collecting, isFalse);
      await send(pieces[2].emergency, account: key.id);
      expect(f.receivedCount(RecoveryKind.emergency), 0, reason: 'expired');
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
  testWidgets('the screen shows whose account the pieces open before '
      'taking it', (WidgetTester tester) async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(transport),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
        ],
        child: const MaterialApp(home: AccountRecoveryScreen()),
      ),
    );
    Future<void> waitFor(bool Function() done) async {
      for (int i = 0; i < 40 && !done(); i++) {
        await tester.runAsync(() => _settle());
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<void> tapKey(String key) async {
      final Finder f = find.byKey(Key(key));
      await tester.ensureVisible(f);
      await tester.pump();
      await tester.tap(f);
    }

    final Finder start = find.byKey(const Key('recovery-start'));
    await waitFor(() => start.evaluate().isNotEmpty);
    expect(find.byKey(const Key('recovery-recover-emergency')), findsNothing);
    expect(find.byKey(const Key('recovery-scope-before')), findsOneWidget);
    expect(find.textContaining('Nie wraca: historia czatów'), findsOneWidget);
    expect(find.textContaining('Nie wraca: portfel'), findsOneWidget);
    expect(find.textContaining('Nie wraca: profil randkowy'), findsOneWidget);
    expect(find.textContaining('Wraca: znajomi i grupy'), findsOneWidget);
    await tapKey('recovery-start');
    final Finder collecting = find.byKey(const Key('recovery-collecting'));
    await waitFor(() => collecting.evaluate().isNotEmpty);
    expect(collecting, findsOneWidget);
    // Only the helpers named here can send pieces (Z2-10).
    for (int i = 0; i < 4; i++) {
      final Finder code = find.byKey(const Key('recovery-helper-code'));
      await tester.ensureVisible(code);
      await tester.enterText(code, '200::b${i + 1}');
      await tapKey('recovery-helper-add');
      final Finder listed = find.byKey(
        Key(
          'recovery-helper-${PeerShareCodec.normalizeAddress('200::b${i + 1}')}',
        ),
      );
      await waitFor(() => listed.evaluate().isNotEmpty);
      expect(listed, findsOneWidget);
    }

    late LedgerKeyPair key;
    await tester.runAsync(() async {
      key = await LedgerKeyPair.generate();
      final List<RecoveryPiece> pieces = await createRecoveryPieces(
        account: key.id,
        seed: key.seed,
        password: _password,
        helpers: 4,
        now: 1,
        cost: _light,
      );
      await transport.start();
      for (int i = 0; i < 4; i++) {
        await transport.injectIncoming(
          from: '200::b${i + 1}',
          payload: <String, dynamic>{
            'type': RecoveryMessages.piece,
            'kind': RecoveryKind.emergency.name,
            'half': pieces[i].emergency,
            'account': key.id,
          },
        );
      }
      await _settle();
    });
    final Finder recover = find.byKey(const Key('recovery-recover-emergency'));
    await waitFor(
      () => tester.widget<OutlinedButton>(recover).onPressed != null,
    );
    await tapKey('recovery-recover-emergency');
    final Finder fingerprint = find.byKey(const Key('recovery-fingerprint-0'));
    await waitFor(() => fingerprint.evaluate().isNotEmpty);

    expect(
      tester.widget<SelectableText>(fingerprint).data,
      accountFingerprint(key.id),
    );
    expect(find.text('Klucze od 4 różnych osób'), findsOneWidget);
    expect(find.byKey(const Key('recovery-adopt-0')), findsOneWidget);
    expect(find.byKey(const Key('recovery-mixed-accounts')), findsNothing);
    expect(find.byKey(const Key('recovery-scope-after')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => _settle());
  });
}
