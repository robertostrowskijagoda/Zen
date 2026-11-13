// The account password protects the account key on every device of the
// account: a device that takes the account by a link, a copy, a backup file
// or a recovery keeps the key wrapped by it from the first byte, and a
// password set on one device reaches the others.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_copy.dart';
import 'package:zen/src/features/account/account_link.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 8, iterations: 1);
const String _password = 'konto-haslo-dlugie-1';

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
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle([int rounds = 60]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<_Linked> _transport(String address) async {
  final _Linked t = _Linked(_a(address));
  _Linked.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(_Linked t, MemoryLedgerDisk disk, {String name = 'U'}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk,
    friendAddresses: () => const <String>[],
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    deviceName: name,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

/// The first device of an account with the account password set.
Future<({MemoryLedgerDisk disk, LedgerIdentity identity, Uint8List seed})>
_firstWithPassword() async {
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final LedgerIdentity identity = await LedgerIdentity.loadOrCreate(disk);
  final Uint8List seed = identity.accountKey!.seed;
  await identity.setPassword(disk, _password, cost: _light);
  return (disk: disk, identity: identity, seed: seed);
}

/// What a device that took the account keeps, read back as at the next
/// start.
Future<void> _expectWrapped(
  MemoryLedgerDisk disk,
  String account,
  Uint8List seed,
) async {
  final LedgerIdentity again = (await LedgerIdentity.load(disk))!;
  expect(again.account, account);
  expect(again.hasPassword, isTrue);
  expect(again.accountKey, isNull, reason: 'not in reach without it');
  expect(again.offersKeyGuard, isFalse);
  expect(await again.unlock('zle-haslo-123'), isFalse);
  expect(await again.unlock(_password), isTrue);
  expect(again.accountKey!.seed, seed);
}

void main() {
  setUp(_Linked.nodes.clear);

  test('a device linked from one with an account password keeps the key '
      'wrapped by it from the first byte', () async {
    final first = await _firstWithPassword();
    final _Linked old = await _transport('200::1');
    final _Linked fresh = await _transport('200::2');
    final AccountLinkReceiver receiver = AccountLinkReceiver(transport: fresh)
      ..start();
    addTearDown(receiver.dispose);
    final AccountLinkSender sender = AccountLinkSender(
      transport: old,
      target: fresh.address,
    );
    addTearDown(sender.dispose);
    expect(await sender.start(), await receiver.digits);
    // The key is unlocked on the old device to send it, as on its screen.
    expect(await first.identity.unlock(_password), isTrue);
    final Future<void> sent = sender.send(
      seed: first.identity.accountKey!.seed,
      account: first.identity.account,
      siblings: <String>[old.address],
      wrapped: first.identity.wrapped,
    );
    final LinkedAccount got = await receiver.account;
    await receiver.confirm(got);
    await sent;
    first.identity.lock();

    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity linked = await LedgerIdentity.adoptAccount(
      disk,
      got.seed,
      wrapped: got.wrapped,
    );
    expect(linked.accountKey, isNull);
    await _expectWrapped(disk, first.identity.account, first.seed);
  });

  test('a copy from another device and a backup file carry the wrapping, '
      'never in the staged manifest', () async {
    final first = await _firstWithPassword();
    expect(await first.identity.unlock(_password), isTrue);
    final AccountArchiveBuilder b =
        AccountArchiveBuilder(
            account: first.identity.account,
            scope: kAllAccountScopes,
          )
          ..seed = first.identity.accountKey!.seed
          ..wrapped = first.identity.wrapped;
    b.sections['settings'] = <String, dynamic>{'look': 'calm'};
    final AccountArchiveBuild build = (archive: b.build(at: 9), blobs: b.blobs);
    first.identity.lock();
    expect(build.archive.wrapped, isNotNull);

    // Another device: the code, the digits, "Pozwól", the download.
    final _Linked old = await _transport('200::a');
    final _Linked fresh = await _transport('200::b');
    final AccountCopySource source = AccountCopySource(
      transport: old,
      address: old.address,
      prepare: () async =>
          AccountCopyContent(build: build, siblings: <String>[old.address]),
    );
    addTearDown(source.dispose);
    final AccountCopyTicket ticket = await source.open();
    final AccountImportStaging staging = AccountImportStaging(
      MemoryLedgerDisk(),
    );
    final AccountCopyTarget target = AccountCopyTarget(
      transport: fresh,
      ticket: ticket,
      staging: staging,
      deviceName: 'Nowy',
      blockTimeout: const Duration(milliseconds: 300),
    );
    addTearDown(target.dispose);
    await target.hello();
    await _settle(10);
    final Future<AccountCopyOffer?> offered = target.offer();
    await source.allow();
    final AccountCopyOffer offer = (await offered)!;
    final AccountArchive copied = await target.download(offer);
    expect(copied.wrapped, isNotNull);
    final MemoryLedgerDisk copyDisk = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      copyDisk,
      copied.seed!,
      wrapped: copied.wrapped,
    );
    await _expectWrapped(copyDisk, first.identity.account, first.seed);
    // What waits for the restart keeps neither the key nor its wrapping.
    await staging.saveManifest(copied);
    final AccountArchive staged = (await staging.manifest())!;
    expect(staged.seed, isNull);
    expect(staged.wrapped, isNull);

    // A backup file, read back.
    final BytesBuilder file = BytesBuilder();
    await AccountBackupFile.write(
      archive: build.archive,
      blobs: build.blobs,
      password: 'haslo-kopii-dlugie',
      cost: _light,
      out: (Uint8List bytes) async => file.add(bytes),
    );
    final Uint8List bytes = file.takeBytes();
    final ({AccountArchive? archive, AccountBackupError? error}) read =
        await AccountBackupFile.read(
          chunks: Stream<List<int>>.value(bytes),
          password: 'haslo-kopii-dlugie',
          acceptedCosts: const <PasswordCost>[_light],
          file: (String id, int size) async => _Drop(),
        );
    expect(read.error, isNull);
    expect(read.archive!.wrapped, isNotNull);
    final MemoryLedgerDisk restored = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      restored,
      read.archive!.seed!,
      wrapped: read.archive!.wrapped,
    );
    await _expectWrapped(restored, first.identity.account, first.seed);
  });

  test('a recovery through the circle keeps the key under the password '
      'typed for it', () async {
    final first = await _firstWithPassword();
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      disk,
      first.seed,
      password: _password,
      cost: _light,
    );
    await _expectWrapped(disk, first.identity.account, first.seed);
  });

  test('without an account password every way in keeps the key as before '
      'and offers to set the password', () async {
    final MemoryLedgerDisk firstDisk = MemoryLedgerDisk();
    final LedgerIdentity first = await LedgerIdentity.loadOrCreate(firstDisk);
    // The first device answered "Zabezpiecz konto" when it started.
    expect(first.offersKeyGuard, isFalse);
    final Uint8List seed = first.accountKey!.seed;
    // A link, a copy or a backup of an account without a password, a key
    // on paper or in a file: no wrapping comes along.
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(disk, seed);
    final LedgerIdentity taken = (await LedgerIdentity.load(disk))!;
    expect(taken.hasPassword, isFalse);
    expect(taken.accountKey!.seed, seed);
    expect(taken.offersKeyGuard, isTrue);
    await taken.setPassword(disk, _password, cost: _light);
    expect((await LedgerIdentity.load(disk))!.offersKeyGuard, isFalse);
    // A key on paper, the same.
    final MemoryLedgerDisk paper = MemoryLedgerDisk();
    final LedgerIdentity fromPaper = await adoptPaperBackup(
      paper,
      await PaperBackupAccount.fromSeed(seed),
    );
    expect(fromPaper.hasPassword, isFalse);
    expect(fromPaper.offersKeyGuard, isTrue);
    // "Nie teraz" is kept.
    final MemoryLedgerDisk other = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(other, seed);
    await (await LedgerIdentity.load(other))!.dismissKeyGuard(other);
    expect((await LedgerIdentity.load(other))!.offersKeyGuard, isFalse);
  });

  test('a wrapping the account key did not sign is never taken', () async {
    final first = await _firstWithPassword();
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerKeyPair stranger = await LedgerKeyPair.generate();
    final PasswordWrappedSeed unsigned = await PasswordWrappedSeed.wrap(
      first.seed,
      _password,
      cost: _light,
      at: 99,
    );
    final PasswordWrappedSeed foreign = await (await PasswordWrappedSeed.wrap(
      stranger.seed,
      _password,
      cost: _light,
      at: 99,
    )).signedBy(stranger);
    // At a link: the key stays here as it came, with the offer to protect
    // it.
    final LedgerIdentity linked = await LedgerIdentity.adoptAccount(
      disk,
      first.seed,
      wrapped: unsigned,
    );
    expect(linked.hasPassword, isFalse);
    expect(linked.offersKeyGuard, isTrue);
    // From a device of the account: refused, the key stays.
    expect(await linked.takeWrapping(disk, unsigned), isFalse);
    expect(await linked.takeWrapping(disk, foreign), isFalse);
    expect(linked.accountKey!.seed, first.seed);
    expect((await LedgerIdentity.load(disk))!.hasPassword, isFalse);
  });

  test('the password set on one device reaches its other devices, and an '
      'older one does not undo a newer one', () async {
    final _Linked t1 = await _transport('200::a1');
    final _Linked t2 = await _transport('200::a2');
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
    final Uint8List seed = id1.accountKey!.seed;
    // Linked while the account had no password (or from 1.16.5).
    await LedgerIdentity.adoptAccount(d2, seed);
    final LedgerNode first = _node(t1, d1);
    final LedgerNode second = _node(t2, d2);
    await first.start();
    await second.start();
    await second.rememberDeviceAddresses(<String>[t1.address]);
    await _settle(120);
    expect(first.siblingAddresses, <String>[t2.address]);
    expect(second.identity.accountKey, isNotNull);

    await first.identity.setPassword(d1, _password, cost: _light);
    first.identity.lock();
    await first.shareWrapping();
    await _settle(80);
    expect(second.identity.hasPassword, isTrue);
    expect(second.identity.accountKey, isNull);
    await _expectWrapped(d2, first.account, seed);

    // Changed on the second device later: the first one takes it.
    expect(await second.identity.unlock(_password), isTrue);
    await second.identity.setPassword(
      d2,
      'drugie-haslo-konta-2',
      cost: _light,
      now: first.identity.wrapped!.at + 1000,
    );
    second.identity.lock();
    final PasswordWrappedSeed newer = second.identity.wrapped!;
    await second.shareWrapping();
    await _settle(80);
    expect(first.identity.wrapped!.at, newer.at);
    expect(await first.identity.unlock('drugie-haslo-konta-2'), isTrue);
    first.identity.lock();
    // The older one coming back changes nothing.
    final LedgerIdentity older = (await LedgerIdentity.load(d1))!;
    expect(await older.unlock('drugie-haslo-konta-2'), isTrue);
    final PasswordWrappedSeed back = await (await PasswordWrappedSeed.wrap(
      seed,
      _password,
      cost: _light,
      at: newer.at - 1,
    )).signedBy(older.accountKey!);
    expect(await second.identity.takeWrapping(d2, back), isFalse);
    expect(second.identity.wrapped!.at, newer.at);
  });

  test('a wrapping from before 1.17.0 is signed once the key is unlocked, '
      'and then reaches the other devices', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity id = await LedgerIdentity.loadOrCreate(disk);
    final Uint8List seed = id.accountKey!.seed;
    await id.setPassword(disk, _password, cost: _light);
    // As 1.16.5 saved it: no time, no signature.
    final Map<String, dynamic> saved =
        jsonDecode(utf8.decode((await disk.read(LedgerIdentity.storageKey))!))
            as Map<String, dynamic>;
    (saved['wrapped'] as Map<String, dynamic>)
      ..remove('sig')
      ..remove('at');
    await disk.write(
      LedgerIdentity.storageKey,
      Uint8List.fromList(utf8.encode(jsonEncode(saved))),
    );
    final LedgerIdentity legacy = (await LedgerIdentity.load(disk))!;
    expect(legacy.wrapped!.signature, isNull);
    final PasswordWrappedSeed plain = legacy.wrapped!;
    final MemoryLedgerDisk other = MemoryLedgerDisk();
    final LedgerIdentity linked = await LedgerIdentity.adoptAccount(
      other,
      seed,
    );
    expect(await linked.takeWrapping(other, plain), isFalse);
    // The device offers to type the password once.
    expect(legacy.offersKeyGuard, isTrue);
    expect(await legacy.unlock(_password), isTrue);
    expect(await legacy.wrapped!.isSignedFor(legacy.account), isTrue);
    expect(legacy.offersKeyGuard, isFalse);
    expect((await LedgerIdentity.load(disk))!.wrapped!.signature, isNotNull);
    expect(await linked.takeWrapping(other, legacy.wrapped!), isTrue);
    expect(linked.accountKey, isNull);
  });
}

/// Drops the files of a copy (only its manifest matters here).
final class _Drop implements AccountFileWriter {
  @override
  Future<void> add(Uint8List chunk) async {}

  @override
  Future<void> close() async {}
}
