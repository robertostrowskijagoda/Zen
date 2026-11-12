import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/account/recovery_service.dart';
import 'package:zen/src/features/chat/self_notes.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null && nodes[address] == this) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

/// A piece kept for a friend and forgotten on one device of the helper's
/// account goes from another device of the account too, even one away
/// for longer than deletions are carried between them: the pieces' state
/// carries a mark of what was forgotten.
String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<void> _settle([int rounds = 120]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

int _now = DateTime.now().millisecondsSinceEpoch;

final class _Device {
  _Device(this.address, this.disk)
    : transport = _Linked(_a(address)),
      notesDisk = MemoryLedgerDisk() {
    _Linked.nodes[_a(address)] = transport;
    notes = SelfNotesService(disk: notesDisk, now: () => _now += 1);
  }

  final String address;
  final MemoryLedgerDisk disk;
  final _Linked transport;
  final MemoryLedgerDisk notesDisk;
  late final SelfNotesService notes;
  late final LedgerNode node;
  late final AccountStateSync sync;
  late final StoredStateSyncDomain notesDomain;
  late final RecoveryService recovery;

  Future<void> start() async {
    await transport.start();
    node = LedgerNode(
      transport: transport,
      disk: disk,
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => transport.address,
      syncInterval: Duration.zero,
    );
    addTearDown(node.stop);
    await node.start();
  }

  Future<void> startSync() async {
    await notesDisk.write(kSelfNotesKey, Uint8List.fromList(utf8.encode('{}')));
    notesDomain = StoredStateSyncDomain(kSelfNotesKey, notesDisk, notes.load);
    final MemorySignalTransport rt = MemorySignalTransport();
    await rt.start();
    recovery = RecoveryService(
      transport: rt,
      disk: MemoryLedgerDisk(),
      isFriend: (_) => true,
      clock: () => _now,
      tickInterval: const Duration(hours: 1),
    );
    await recovery.start();
    sync = AccountStateSync(
      channel: LedgerAccountSyncChannel(node),
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[
        notesDomain,
        RecoveryPiecesSyncDomain(recovery),
      ],
      delay: const Duration(milliseconds: 1),
      scanEvery: const Duration(hours: 1),
      now: () => _now,
    );
    await sync.start();
    addTearDown(() async {
      await sync.stop();
      await recovery.stop();
      await notesDomain.close();
    });
  }

  void goOffline() => _Linked.nodes.remove(_a(address));

  Future<void> comeBack() async {
    _Linked.nodes[_a(address)] = transport;
    for (final String other in _Linked.nodes.keys.toList()) {
      if (other != _a(address)) {
        node.greet(other);
      }
    }
  }
}

Future<void> _exchange(List<_Device> devices) async {
  for (int round = 0; round < 4; round++) {
    for (final _Device d in devices) {
      d.notesDomain.poke();
      await d.sync.flush();
    }
    await _settle(60);
  }
}

void main() {
  setUp(() {
    LedgerNode.stateLogDropDelay = Duration.zero;
    _now = DateTime.now().millisecondsSinceEpoch;
  });
  tearDown(() {
    LedgerNode.stateLogDropDelay = const Duration(seconds: 30);
  });

  test('a piece forgotten on the phone goes from the tablet that was away '
      'for six weeks too', () async {
    _Linked.nodes.clear();
    final _Device first = _Device('200::a1', MemoryLedgerDisk());
    await first.start();
    final _Device second = _Device('200::a2', MemoryLedgerDisk());
    await LedgerIdentity.adoptAccount(
      second.disk,
      (await LedgerIdentity.loadOrCreate(first.disk)).accountKey!.seed,
    );
    await second.start();
    await second.node.rememberDeviceAddresses(<String>[_a('200::a1')]);
    await _settle(200);
    await first.startSync();
    await second.startSync();
    await _settle();

    // A friend Q's piece is kept by this account (it came to the phone).
    final LedgerIdentity q = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final RecoverySeal seal = await RecoverySeal.make(
      q.accountKey!.seed,
      'dobre-haslo-123',
      now: _now,
      cost: const PasswordCost(memoryKiB: 64, iterations: 1),
    );
    final RecoveryPiece piece = (await createGenerationPieces(
      account: q.account,
      seal: seal,
      holders: 2,
      generation: _now,
    )).first;
    await first.recovery.takeSyncState(<String, Object?>{
      'held': <String, Object?>{
        q.account: <String, dynamic>{
          'account': q.account,
          'from': _a('200::99'),
          'pieces': <Object?>[piece.toJson()],
          'at': _now,
        },
      },
    });
    await _exchange(<_Device>[first, second]);
    expect(second.recovery.heldFor, <String>[q.account]);

    // The tablet is put away. Q says to forget (or the friendship ended):
    // the phone drops the piece.
    second.goOffline();
    await first.recovery.takeSyncState(<String, Object?>{
      'held': <String, Object?>{},
    });
    expect(first.recovery.heldFor, isEmpty);
    await _exchange(<_Device>[first]);
    // Six weeks of ordinary use: notes written and deleted, the log
    // starts over now and then.
    for (int i = 0; i < 6; i++) {
      _now += const Duration(days: 7).inMilliseconds;
      final SelfNote n = (await first.notes.add('notatka $i'))!;
      await _exchange(<_Device>[first]);
      await first.notes.delete(n.id);
      await _exchange(<_Device>[first]);
    }
    final int rebasedFirst = first.sync.rebased;

    await second.comeBack();
    await _settle(200);
    await _exchange(<_Device>[first, second]);
    // Control: the tablet does take what the phone writes now.
    await first.notes.add('po powrocie');
    await _exchange(<_Device>[first, second]);
    await second.notes.load();
    expect(
      second.notes.notes.map((SelfNote n) => n.text),
      contains('po powrocie'),
    );
    expect(rebasedFirst, greaterThan(1));
    expect(first.recovery.heldFor, isEmpty);
    expect(second.recovery.heldFor, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
