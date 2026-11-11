import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/account_state_sync_app.dart';
import 'package:zen/src/features/chat/self_notes.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/password_vault_sync.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The account's log of states between its devices is pruned: a device's
// state log starts over now and then (a checkpoint, every state as it is
// written again, what came before dropped here and on the other devices),
// so an overwritten or deleted password or note leaves the log, the
// memory and a new full copy within the bound, without a device that was
// away bringing it back. A virtual clock moves time.

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

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<void> _settle([int rounds = 120]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The test's clock (the states' times; the ledger keeps its own).
int _now = DateTime.now().millisecondsSinceEpoch;

/// Devices whose Zen is locked.
final Set<String> _locked = <String>{};

const String _secret = 'tajne-stare-haslo';
const String _noteSecret = 'notatka-do-skasowania';

/// One device of the account: its node, vault, notes and sync.
final class _Device {
  _Device(this.address, this.disk, {required int seed})
    : transport = _Linked(_a(address)),
      vault = PasswordVaultService(
        disk: MemoryLedgerDisk(),
        now: () => _now += 1,
        random: Random(seed),
        isLocked: () => _locked.contains(address),
      ),
      notesDisk = MemoryLedgerDisk() {
    _Linked.nodes[_a(address)] = transport;
    notes = SelfNotesService(disk: notesDisk, now: () => _now += 1);
  }

  final String address;
  final MemoryLedgerDisk disk;
  final _Linked transport;
  final PasswordVaultService vault;
  final MemoryLedgerDisk notesDisk;
  late final SelfNotesService notes;
  late final LedgerNode node;
  late final AccountStateSync sync;
  late final PasswordVaultSyncDomain passwords;
  late final StoredStateSyncDomain notesDomain;

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
    // An empty notes store (a device with no note yet reads as "not
    // readable" and would wait for its first note).
    await notesDisk.write(kSelfNotesKey, Uint8List.fromList(utf8.encode('{}')));
    passwords = PasswordVaultSyncDomain(vault);
    notesDomain = StoredStateSyncDomain(kSelfNotesKey, notesDisk, notes.load);
    sync = AccountStateSync(
      channel: LedgerAccountSyncChannel(node),
      disk: MemoryLedgerDisk(),
      domains: <AccountSyncDomain>[notesDomain, passwords],
      delay: const Duration(milliseconds: 1),
      scanEvery: const Duration(hours: 1),
      now: () => _now,
    );
    await sync.start();
    addTearDown(() async {
      await sync.stop();
      await passwords.close();
      await notesDomain.close();
    });
  }

  /// Whether [text] is anywhere in this device's log of the account's own
  /// entries (opened), or in what the node holds opened in memory.
  bool holds(String text) =>
      node.store
          .entries(accountSpace('own', node.account))
          .any((LogEntry e) => jsonEncode(node.bodyOf(e)).contains(text)) ||
      node.debugOpenedBodies.any(
        (Map<String, dynamic> b) => jsonEncode(b).contains(text),
      );

  /// The ids of the entries of the account's own log held here.
  Set<String> ownIds() => <String>{
    for (final LogEntry e in node.store.entries(
      accountSpace('own', node.account),
    ))
      e.id,
  };

  /// What a full account copy (with conversations) carries of the log.
  Future<String> fullCopyOfLog() async {
    await node.archive.flush();
    final Map<String, Uint8List> files = await LedgerArchive.exportFiles(
      disk,
      keepSpace: (_) => true,
      withPieces: false,
    );
    return files.values.map(latin1.decode).join('\n');
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

Future<(_Device, _Device)> _twoDevices() async {
  _Linked.nodes.clear();
  final _Device first = _Device('200::a1', MemoryLedgerDisk(), seed: 1);
  await first.start();
  final _Device second = _Device('200::a2', MemoryLedgerDisk(), seed: 2);
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
  return (first, second);
}

Future<void> _exchange(List<_Device> devices) async {
  for (int round = 0; round < 4; round++) {
    for (final _Device d in devices) {
      d.notesDomain.poke();
      await d.sync.flush();
    }
    await _settle(60);
  }
  for (final _Device d in devices) {
    await d.vault.load();
    await d.notes.load();
  }
}

void main() {
  setUp(() {
    LedgerNode.stateLogDropDelay = Duration.zero;
    _now = DateTime.now().millisecondsSinceEpoch;
    _locked.clear();
  });
  tearDown(() {
    LedgerNode.stateLogDropDelay = const Duration(seconds: 30);
  });

  test('a deleted password, a cleared history and a deleted note leave the '
      'log, the memory and a new full copy within the bound', () async {
    final (_Device first, _Device second) = await _twoDevices();
    final PasswordEntry bank = await first.vault.add(
      const PasswordFields(name: 'Bank', password: _secret),
    );
    final PasswordEntry mail = await first.vault.add(
      const PasswordFields(name: 'Poczta', password: 'pierwsze-haslo'),
    );
    await first.vault.edit(
      mail.id,
      const PasswordFields(name: 'Poczta', password: 'drugie-haslo'),
    );
    final SelfNote note = (await first.notes.add(_noteSecret))!;
    await _exchange(<_Device>[first, second]);
    expect(second.vault.entry(bank.id)?.password, _secret);
    expect(second.notes.notes.single.text, _noteSecret);
    final Set<String> before = first.ownIds();

    await first.vault.delete(bank.id);
    await first.vault.clearHistory(mail.id);
    await first.notes.delete(note.id);
    await _exchange(<_Device>[first, second]);
    expect(second.vault.entry(bank.id), isNull);
    expect(second.vault.entry(mail.id)!.history, isEmpty);
    expect(second.notes.notes, isEmpty);
    // Within the bound the old changes are still in the log.
    expect(first.holds(_secret), isTrue);

    _now += kAccountSyncRebaseEvery.inMilliseconds + 1;
    await _exchange(<_Device>[first, second]);
    for (final _Device d in <_Device>[first, second]) {
      expect(d.sync.rebased, greaterThan(0));
      for (final String text in <String>[
        _secret,
        'pierwsze-haslo',
        _noteSecret,
      ]) {
        expect(d.holds(text), isFalse, reason: '$text on ${d.address}');
      }
      expect(
        utf8.decode(
          (d.vault.disk as MemoryLedgerDisk).files[kPasswordVaultKey]!,
        ),
        isNot(contains(_secret)),
      );
      // A full copy made now carries none of the dropped changes.
      final String copy = await d.fullCopyOfLog();
      for (final String id in before) {
        expect(copy, isNot(contains(id)));
      }
    }
    // What is current is still there, on both.
    expect(second.vault.entry(mail.id)!.password, 'drugie-haslo');
  });

  test('a device away for less than the bound gets the deletions and brings '
      'nothing back', () async {
    final (_Device first, _Device second) = await _twoDevices();
    final PasswordEntry bank = await first.vault.add(
      const PasswordFields(name: 'Bank', password: _secret),
    );
    final SelfNote note = (await first.notes.add(_noteSecret))!;
    await _exchange(<_Device>[first, second]);
    expect(second.vault.entry(bank.id)?.password, _secret);

    second.goOffline();
    await first.vault.delete(bank.id);
    await first.notes.delete(note.id);
    _now += kAccountSyncRebaseEvery.inMilliseconds + 1;
    await _exchange(<_Device>[first]);
    expect(first.sync.rebased, greaterThan(0));
    expect(first.holds(_secret), isFalse);

    _now += const Duration(days: 3).inMilliseconds;
    await second.comeBack();
    await _settle(200);
    await _exchange(<_Device>[first, second]);
    for (final _Device d in <_Device>[first, second]) {
      expect(d.vault.entry(bank.id), isNull, reason: d.address);
      expect(d.notes.notes, isEmpty, reason: d.address);
    }
  });

  test('a device away for longer than the bound converges: the deleted '
      'password stays deleted, its text goes from that device too', () async {
    final (_Device first, _Device second) = await _twoDevices();
    final PasswordEntry bank = await first.vault.add(
      const PasswordFields(name: 'Bank', password: _secret),
    );
    await first.vault.add(
      const PasswordFields(name: 'Poczta', password: 'zostaje'),
    );
    final SelfNote note = (await first.notes.add(_noteSecret))!;
    await _exchange(<_Device>[first, second]);

    second.goOffline();
    await first.vault.delete(bank.id);
    await first.notes.delete(note.id);
    // Weeks pass; the log starts over several times, the deletions are no
    // longer written into it again.
    for (int i = 0; i < 6; i++) {
      _now += const Duration(days: 7).inMilliseconds;
      await first.vault.add(PasswordFields(name: 'Nowe $i', password: 'n$i'));
      await _exchange(<_Device>[first]);
    }
    expect(first.holds(_secret), isFalse);

    await second.comeBack();
    await _settle(200);
    await _exchange(<_Device>[first, second]);
    for (final _Device d in <_Device>[first, second]) {
      expect(d.vault.entry(bank.id), isNull, reason: d.address);
      expect(d.vault.entries, hasLength(7), reason: d.address);
      expect(d.notes.notes, isEmpty, reason: d.address);
    }
    // The returning device's vault no longer holds the old password (the
    // deletion's marker in the state saw it), and the first never took it
    // back.
    expect(
      utf8.decode(
        (second.vault.disk as MemoryLedgerDisk).files[kPasswordVaultKey]!,
      ),
      isNot(contains(_secret)),
    );
    expect(first.holds(_secret), isFalse);
  });

  test('while Zen is locked no opened change stays in memory; at the unlock '
      'what came meanwhile is taken', () async {
    final (_Device first, _Device second) = await _twoDevices();
    await first.vault.add(
      const PasswordFields(name: 'Bank', password: _secret),
    );
    await _exchange(<_Device>[first, second]);
    expect(second.holds(_secret), isTrue);

    _locked.add(second.address);
    second.sync.lock();
    second.vault.forget();
    expect(second.holds(_secret), isFalse);
    // A change arrives while locked: not opened, not kept.
    await first.vault.add(
      const PasswordFields(name: 'Poczta', password: 'w-czasie-blokady'),
    );
    await first.sync.flush();
    await _settle(120);
    expect(second.holds('w-czasie-blokady'), isFalse);

    _locked.remove(second.address);
    second.sync.unlock();
    await _settle(120);
    await second.sync.idle;
    await _exchange(<_Device>[second]);
    expect(
      second.vault.entries.map((PasswordEntry e) => e.password),
      containsAll(<String>[_secret, 'w-czasie-blokady']),
    );
  });
}
