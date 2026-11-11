import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_collect.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_holder.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/key_file.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/account/presentation/key_backup_screen.dart';
import 'package:zen/src/features/chat/self_notes.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/passwords/password_vault_sync.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// The passwords and the notes to oneself come back with every way an
// account comes back or moves: another device of the account (its sync;
// the notes: account_sync_pruning_test.dart), a full copy (file), a second
// device or a move (the copy sent over), and after the recovery circle or
// a key copy (paper, key file), with a circle or without one, from the
// copy kept with friends. Each test sets them on the old device, brings
// the account back on a fresh one by that way, and finds them there. The
// only way that loses them is a key copy alone with no friend at all, and
// the app says so before.

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);

/// The old device's vault: two entries, one edited (with a history).
Future<PasswordVaultService> _oldVault(LedgerDisk disk) async {
  final PasswordVaultService vault = PasswordVaultService(
    disk: disk,
    random: Random(1),
  );
  final PasswordEntry bank = await vault.add(
    const PasswordFields(
      name: 'Bank',
      login: 'ania',
      password: 'stare-haslo',
      address: 'https://bank.example.com',
    ),
  );
  await vault.edit(
    bank.id,
    const PasswordFields(
      name: 'Bank',
      login: 'ania',
      password: 'nowe-haslo',
      address: 'https://bank.example.com',
    ),
  );
  await vault.add(
    const PasswordFields(
      name: 'Poczta',
      login: 'ania@example.com',
      password: 'poczta-123',
      address: 'android-app://com.example.mail',
    ),
  );
  return vault;
}

void _expectPasswords(PasswordVaultService vault) {
  expect(
    <String, String>{
      for (final PasswordEntry e in vault.entries) e.name: e.password,
    },
    <String, String>{'Bank': 'nowe-haslo', 'Poczta': 'poczta-123'},
  );
  final PasswordEntry bank = vault.entries.first;
  expect(bank.history.single.password, 'stare-haslo');
}

PasswordVaultService _freshVault() =>
    PasswordVaultService(disk: MemoryLedgerDisk(), random: Random(2));

// ---- the account's devices (its sync) ----

/// The account's devices on one net; a change larger than an entry of the
/// account's log may be (sealed and signed) is refused, as the log does.
final class _Net {
  final List<_Channel> devices = <_Channel>[];
  final List<(String, Map<String, dynamic>)> log =
      <(String, Map<String, dynamic>)>[];
  int largest = 0;
}

final class _Channel implements AccountSyncChannel {
  _Channel(this.net, this.device) {
    net.devices.add(this);
  }

  final _Net net;
  @override
  final String device;
  final StreamController<Map<String, dynamic>> _in =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<void> devices = StreamController<void>.broadcast();

  @override
  bool get hasOtherDevices => net.devices.length > 1;

  @override
  Iterable<Map<String, dynamic>> existing() => <Map<String, dynamic>>[
    for (final (String from, Map<String, dynamic> body) in net.log)
      if (from != device) body,
  ];

  @override
  Stream<Map<String, dynamic>> get incoming => _in.stream;

  @override
  Stream<void> get devicesChanged => devices.stream;

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    final String text = jsonEncode(body);
    // Sealed (base64) and signed (hybrid signature, certificate) on top.
    final int entry = utf8.encode(text).length * 4 ~/ 3 + 8 * 1024;
    if (entry > kMaxEntryBytes) {
      throw StateError('entry too large');
    }
    net.largest = max(net.largest, entry);
    final Map<String, dynamic> sent = jsonDecode(text) as Map<String, dynamic>;
    net.log.add((device, sent));
    for (final _Channel d in net.devices) {
      if (d != this) {
        scheduleMicrotask(() => d._in.add(sent));
      }
    }
    return true;
  }
}

/// One clock for the devices of a test, so "later" is certain.
int _clock = 1000000;

final class _Device {
  _Device(_Net net, String id, {int seed = 1})
    : channel = _Channel(net, id),
      vault = PasswordVaultService(
        disk: MemoryLedgerDisk(),
        random: Random(seed),
        now: () => _clock += 1,
      );

  final _Channel channel;
  final PasswordVaultService vault;
  late final PasswordVaultSyncDomain domain = PasswordVaultSyncDomain(vault);
  late final AccountStateSync sync = AccountStateSync(
    channel: channel,
    disk: MemoryLedgerDisk(),
    domains: <AccountSyncDomain>[domain],
    delay: const Duration(milliseconds: 1),
    scanEvery: const Duration(hours: 1),
  );
}

Future<void> _settle(List<_Device> devices) async {
  for (int round = 0; round < 6; round++) {
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    for (final _Device d in devices) {
      await d.sync.flush();
    }
  }
}

// ---- copies of the account ----

/// An account whose only data is its key and its passwords.
final class _Source implements AccountArchiveSource {
  _Source(this.disk, this.seed);

  @override
  final LedgerDisk disk;

  @override
  final Uint8List seed;

  @override
  String get account => 'acc-1';

  @override
  Map<String, dynamic> contacts() => <String, dynamic>{};

  @override
  Map<String, String> levels() => <String, String>{};

  @override
  List<String> conversationKeys() => const <String>[];

  @override
  Future<List<ChatMessage>> messages(String key) async => <ChatMessage>[];

  @override
  Map<String, dynamic> profile() => <String, dynamic>{};

  @override
  String? get avatarPath => null;

  @override
  String? get coverPath => null;

  @override
  Map<String, dynamic> settings() => <String, dynamic>{};

  @override
  Future<Map<String, Object>?> appLock() async => null;

  @override
  Map<String, dynamic>? pyramid() => null;

  @override
  Map<String, dynamic> dating() => <String, dynamic>{};

  @override
  Future<Map<String, dynamic>?> household() async => null;

  @override
  Future<Uint8List?> readState(String key) => disk.read(key);

  @override
  Future<Uint8List?> readFileRange(String path, int start, int end) async =>
      null;

  @override
  Future<int?> fileSize(String path) async => null;
}

/// A fresh device taking a copy in: its sections go where the app's sink
/// puts them (`AppAccountArchiveSink.apply`: the passwords merged into the
/// vault).
final class _NewDevice implements AccountArchiveSink {
  _NewDevice({this.account});

  String? account;
  final PasswordVaultService vault = _freshVault();
  final MemoryLedgerDisk disk = MemoryLedgerDisk();

  @override
  Future<String?> currentAccount() async => account;

  @override
  Future<bool> isFresh() async => true;

  @override
  Future<void> adoptAccount(AccountArchive archive) async {
    account = archive.account;
  }

  @override
  Future<void> writeRaw(
    String key,
    Uint8List value, {
    required bool onlyIfAbsent,
  }) async {
    if (!onlyIfAbsent || await disk.read(key) == null) {
      await disk.write(key, value);
    }
  }

  @override
  Future<AccountImportSummary> apply(
    AccountArchive archive,
    AccountArchiveBlob? Function(String id) file,
    void Function(int done, int total) progress, {
    required bool merge,
  }) async {
    final Object? passwords = archive.sections[CircleBackupSections.passwords];
    if (passwords != null) {
      await vault.mergeCopy(passwords);
    }
    return AccountImportSummary(parts: archive.scope);
  }

  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async {
    await whileStopped?.call();
  }
}

Future<Uint8List> _backupFile(AccountArchiveBuild build) async {
  final BytesBuilder out = BytesBuilder();
  await AccountBackupFile.write(
    archive: build.archive,
    blobs: build.blobs,
    password: 'haslo-kopii-1',
    cost: _light,
    out: (Uint8List bytes) async => out.add(bytes),
  );
  return out.takeBytes();
}

/// Reads a backup file, staging its files as the app does.
Future<AccountArchive> _readBackup(
  Uint8List file,
  AccountImportStaging staging,
) async {
  final ({AccountArchive? archive, AccountBackupError? error}) read =
      await AccountBackupFile.read(
        chunks: Stream<List<int>>.value(file),
        password: 'haslo-kopii-1',
        acceptedCosts: const <PasswordCost>[_light],
        file: (String id, int size) async => staging.writer(id),
      );
  expect(read.error, isNull);
  return read.archive!;
}

// ---- the copy with friends ----

final class _Linked extends MemorySignalTransport {
  _Linked(String address) : address = PeerShareCodec.normalizeAddress(address) {
    nodes[this.address] = this;
  }

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  /// What it sends that never arrives (a holder that stalls).
  bool Function(Map<String, dynamic> payload)? drops;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null && !(drops?.call(payload) ?? false)) {
      final Map<String, dynamic> wire =
          jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: wire),
      );
    }
  }
}

Future<_Linked> _started(String address) async {
  final _Linked t = _Linked(address);
  await t.start();
  return t;
}

/// The notes of the old device.
Future<SelfNotesService> _oldNotes() async {
  final SelfNotesService notes = SelfNotesService(disk: MemoryLedgerDisk());
  await notes.add('kod do furtki 4321');
  final SelfNote gone = (await notes.add('skasowana notatka'))!;
  await notes.delete(gone.id);
  return notes;
}

/// The old device's notes, stored on [disk].
Future<void> _notesOn(LedgerDisk disk) async {
  final SelfNotesService notes = SelfNotesService(disk: disk);
  await notes.add('kod do furtki 4321');
  final SelfNote gone = (await notes.add('skasowana notatka'))!;
  await notes.delete(gone.id);
}

/// The notes stored on [disk], read.
Future<SelfNotesService> _notesAt(LedgerDisk disk) async {
  final SelfNotesService notes = SelfNotesService(disk: disk);
  await notes.load();
  return notes;
}

void _expectNotes(SelfNotesService notes) {
  expect(notes.notes.map((SelfNote n) => n.text), <String>[
    'kod do furtki 4321',
  ]);
}

/// The passwords and notes part of the app's copy with friends
/// (`AppCircleBackupData` in recovery_providers.dart): padded in; no copy
/// while the vault cannot be read; merged back first.
final class _VaultData implements CircleBackupData {
  _VaultData(this.vault, [SelfNotesService? notes])
    : notes = notes ?? SelfNotesService(disk: MemoryLedgerDisk());

  final PasswordVaultService vault;
  final SelfNotesService notes;

  @override
  Future<CircleBackupContent> collect({required bool chats}) async {
    final Map<String, Object?>? section;
    try {
      section = await vault.exportForCopy();
    } on PasswordVaultException catch (error) {
      throw CircleBackupNotNow(error.error.name);
    }
    final Map<String, Object?>? notesSection = await notes.exportForCopy();
    return CircleBackupContent(
      sections: <String, Object?>{
        CircleBackupSections.profile: <String, Object?>{'displayName': 'Ania'},
        if (section != null)
          CircleBackupSections.passwords: padPasswordSection(section),
        if (notesSection != null)
          CircleBackupSections.notes: padPasswordSection(notesSection),
      },
    );
  }

  @override
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  ) async {
    final Object? passwords = content.sections[CircleBackupSections.passwords];
    if (passwords != null) {
      await vault.mergeCopy(passwords);
    }
    await notes.mergeCopy(content.sections[CircleBackupSections.notes]);
    progress(1, 1);
  }
}

Future<void> _settleCircle(List<CircleBackupService> services) async {
  for (int i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (final CircleBackupService s in services) {
      await s.idle;
    }
  }
}

CircleBackupIdentity _idOf(LedgerIdentity i) => CircleBackupIdentity(
  account: i.account,
  selfKey: i.selfKey!,
  deviceKey: i.deviceKey,
  certificate: i.certificate,
);

/// The old phone's copy with friends, kept by the holder at
/// [holderAddress]: a helper of its recovery circle ([circle]) or a chosen
/// friend only (no circle at all). Returns the holder's service.
Future<CircleBackupService> _copyWithFriends(
  LedgerIdentity me,
  PasswordVaultService vault, {
  SelfNotesService? notes,
  bool circle = true,
  String holderAddress = '200::b',
  bool clear = true,
}) async {
  if (clear) {
    _Linked.nodes.clear();
  }
  final _Linked tOwner = _Linked('200::a');
  final _Linked tHolder = _Linked(holderAddress);
  await tOwner.start();
  await tHolder.start();
  final CircleBackupService owner = CircleBackupService(
    transport: tOwner,
    disk: MemoryLedgerDisk(),
    data: _VaultData(vault, notes),
    identity: () => _idOf(me),
    holders: () => circle ? <String>[tHolder.address] : const <String>[],
    friendHolders: () => circle ? const <String>[] : <String>[tHolder.address],
    isInCircle: (_) => false,
    restoreCandidates: () => const <String>[],
  );
  final CircleBackupService holder = CircleBackupService(
    transport: tHolder,
    disk: MemoryLedgerDisk(),
    data: _VaultData(_freshVault()),
    identity: () => null,
    holders: () => const <String>[],
    isInCircle: (String a) => circle && a == me.account,
    isFriend: (String a) => a == me.account,
    restoreCandidates: () => const <String>[],
  );
  await holder.start();
  await owner.start();
  await _settleCircle(<CircleBackupService>[owner, holder]);
  expect(holder.holder.kept.keys, <String>[me.account]);
  expect(owner.status.value.holders, 1);
  // The holder cannot read a password or a note (nor tell how many there
  // are).
  final String kept = latin1.decode(<int>[
    for (final String id in holder.holder.manifestOf(me.account)!.chunks.keys)
      ...(await holder.holder.chunk(me.account, id))!,
  ]);
  expect(kept, isNot(contains('nowe-haslo')));
  expect(kept, isNot(contains('Bank')));
  expect(kept, isNot(contains('furtki')));
  await owner.stop();
  return holder;
}

/// The recovered account [recovered] (its key back by some way, [disk]
/// marked) fetches its copy and takes the passwords and notes in. A fresh
/// phone knows no friend: only the helpers or the friend named at the
/// restore are asked ([candidates]: friends known on the device).
Future<(PasswordVaultService, SelfNotesService)> _restoreFromFriends(
  LedgerIdentity recovered,
  LedgerDisk disk,
  CircleBackupService holder, {
  List<String> candidates = const <String>[],
}) async {
  final _Linked tNew = _Linked('200::c');
  await tNew.start();
  final PasswordVaultService vault = _freshVault();
  final SelfNotesService notes = SelfNotesService(disk: MemoryLedgerDisk());
  final CircleBackupService fresh = CircleBackupService(
    transport: tNew,
    disk: disk,
    data: _VaultData(vault, notes),
    identity: () => _idOf(recovered),
    holders: () => const <String>[],
    isInCircle: (_) => false,
    restoreCandidates: () => candidates,
  );
  await fresh.start();
  await _settleCircle(<CircleBackupService>[fresh, holder]);
  expect(fresh.restore.value.phase, CircleBackupRestorePhase.done);
  await fresh.stop();
  await holder.stop();
  return (vault, notes);
}

/// Back by the key copy on paper; [friend]: the invitation code of a friend
/// typed at the restore (its address).
Future<LedgerIdentity> _byPaper(
  LedgerIdentity me,
  MemoryLedgerDisk disk, {
  String? friend,
}) async {
  final PaperBackupDecoded read = decodePaperBackup(
    encodePaperBackup(me.accountKey!.seed),
  );
  return adoptPaperBackup(
    disk,
    await PaperBackupAccount.fromSeed(read.seed!),
    friends: <String>[?friend],
  );
}

/// Back by the key file (the restore screen takes it the same way).
Future<LedgerIdentity> _byKeyFile(
  LedgerIdentity me,
  MemoryLedgerDisk disk, {
  String? friend,
}) async {
  final Uint8List file = await encryptKeyFile(
    me.accountKey!.seed,
    'haslo-pliku-123',
    cost: _light,
  );
  final KeyFileDecoded read = await decryptKeyFile(file, 'haslo-pliku-123');
  return adoptPaperBackup(
    disk,
    await PaperBackupAccount.fromSeed(read.seed!),
    friends: <String>[?friend],
  );
}

void main() {
  for (final (
        String way,
        Future<LedgerIdentity> Function(
          LedgerIdentity,
          MemoryLedgerDisk, {
          String? friend,
        })
        recover,
      )
      in <
        (
          String,
          Future<LedgerIdentity> Function(
            LedgerIdentity,
            MemoryLedgerDisk, {
            String? friend,
          }),
        )
      >[('a key copy on paper', _byPaper), ('a key file', _byKeyFile)]) {
    for (final bool circle in <bool>[true, false]) {
      test('$way, ${circle ? 'a recovery circle' : 'no circle'}, a friend '
          '(no other device, no backup file): the passwords and notes from '
          'the copy with friends', () async {
        final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
          MemoryLedgerDisk(),
        );
        final PasswordVaultService vault = await _oldVault(MemoryLedgerDisk());
        final CircleBackupService holder = await _copyWithFriends(
          me,
          vault,
          notes: await _oldNotes(),
          circle: circle,
        );
        final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
        // The fresh phone knows nobody: the friend's invitation code typed
        // at the restore names whom to ask.
        final LedgerIdentity recovered = await recover(
          me,
          newDisk,
          friend: '200::b',
        );
        final (PasswordVaultService v, SelfNotesService n) =
            await _restoreFromFriends(recovered, newDisk, holder);
        _expectPasswords(v);
        _expectNotes(n);
      });
    }

    test('$way and no friend at all: the passwords and notes are lost, and '
        'the app said so before (where the key copy is made)', () async {
      _Linked.nodes.clear();
      final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
        MemoryLedgerDisk(),
      );
      final PasswordVaultService vault = await _oldVault(MemoryLedgerDisk());
      final _Linked tOwner = _Linked('200::a');
      await tOwner.start();
      final CircleBackupService owner = CircleBackupService(
        transport: tOwner,
        disk: MemoryLedgerDisk(),
        data: _VaultData(vault, await _oldNotes()),
        identity: () => _idOf(me),
        holders: () => const <String>[],
        isInCircle: (_) => false,
        restoreCandidates: () => const <String>[],
      );
      await owner.refresh(force: true);
      expect(tOwner.sentSignals, isEmpty, reason: 'nobody to keep it');
      expect(owner.status.value.candidates, 0);
      expect(
        CopyWithFriendsNote.textOf(owner.status.value),
        allOf(contains('Nie masz jeszcze znajomych'), contains('nie wrócą')),
      );

      final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
      final LedgerIdentity recovered = await recover(me, newDisk);
      final _Linked tNew = _Linked('200::c');
      await tNew.start();
      final PasswordVaultService fresh = _freshVault();
      final CircleBackupService restoring = CircleBackupService(
        transport: tNew,
        disk: newDisk,
        data: _VaultData(fresh),
        identity: () => _idOf(recovered),
        holders: () => const <String>[],
        isInCircle: (_) => false,
        restoreCandidates: () => const <String>[],
      );
      await restoring.start();
      await _settleCircle(<CircleBackupService>[restoring]);
      expect(restoring.restoring, isTrue);
      expect(fresh.entries, isEmpty);
      await restoring.stop();
    });
  }

  test('the note where the key copy is made says what a key alone brings '
      'back, and from whom', () {
    expect(
      CopyWithFriendsNote.textOf(const CircleBackupStatus(candidates: 2)),
      contains('jeszcze nie powstała'),
    );
    expect(
      CopyWithFriendsNote.textOf(
        const CircleBackupStatus(candidates: 2, holders: 2, lastAt: 1),
      ),
      allOf(contains('hasła, notatki'), contains('kod zaproszenia')),
    );
  });

  test('a holder decides: a circle it keeps a piece of, or an accepted friend '
      'within its budget; a 1.16.4 holder refuses a friend and another '
      'friend takes over; a friend removed drops it', () async {
    _Linked.nodes.clear();
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final PasswordVaultService vault = await _oldVault(MemoryLedgerDisk());
    final _Linked tOwner = _Linked('200::a');
    final _Linked tOld = _Linked('200::0');
    final _Linked tB = _Linked('200::b');
    for (final _Linked t in <_Linked>[tOwner, tOld, tB]) {
      await t.start();
    }
    // 1.16.4 knows only the circle: no `isFriend`, so a friend's copy is
    // refused (`cbk_no notInCircle`).
    final CircleBackupService old = CircleBackupService(
      transport: tOld,
      disk: MemoryLedgerDisk(),
      data: _VaultData(_freshVault()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    bool stillFriends = true;
    final CircleBackupService b = CircleBackupService(
      transport: tB,
      disk: MemoryLedgerDisk(),
      data: _VaultData(_freshVault()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      isFriend: (String a) => stillFriends && a == me.account,
      restoreCandidates: () => const <String>[],
    );
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: _VaultData(vault),
      identity: () => _idOf(me),
      holders: () => const <String>[],
      friendHolders: () => <String>[tOld.address, tB.address],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    for (final CircleBackupService s in <CircleBackupService>[old, b, owner]) {
      await s.start();
    }
    await _settleCircle(<CircleBackupService>[old, b, owner]);
    expect(old.holder.kept, isEmpty);
    expect(b.holder.kept.keys, <String>[me.account]);
    expect(owner.targets(), isNot(contains(tOld.address)));
    expect(owner.status.value.holders, 1);

    // A friend's copy stays within the friends' budget.
    final CircleBackupService tight = CircleBackupService(
      transport: await _started('200::d'),
      disk: MemoryLedgerDisk(),
      data: _VaultData(_freshVault()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      isFriend: (_) => true,
      restoreCandidates: () => const <String>[],
    );
    expect(tight.holder.friendsBytes, kCircleBackupFriendsBytes);

    // B no longer has the owner as a friend: it drops the copy.
    stillFriends = false;
    await b.tick();
    expect(b.holder.kept, isEmpty);
    for (final CircleBackupService s in <CircleBackupService>[old, b, owner]) {
      await s.stop();
    }
  });

  test('after a recovery the newest copy is taken, not the first to come '
      'whole; a holder that stalls is replaced by another one', () async {
    _Linked.nodes.clear();
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final PasswordVaultService vault = await _oldVault(MemoryLedgerDisk());
    int now = DateTime.now().millisecondsSinceEpoch;
    final _Linked tOwner = _Linked('200::a');
    final _Linked tOld = _Linked('200::b');
    final _Linked tNew = _Linked('200::e');
    for (final _Linked t in <_Linked>[tOwner, tOld, tNew]) {
      await t.start();
    }
    CircleBackupService holderAt(_Linked t) => CircleBackupService(
      transport: t,
      disk: MemoryLedgerDisk(),
      data: _VaultData(_freshVault()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      isFriend: (String a) => a == me.account,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    final CircleBackupService older = holderAt(tOld);
    final CircleBackupService newer = holderAt(tNew);
    List<String> keepers = <String>[tOld.address];
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: _VaultData(vault),
      identity: () => _idOf(me),
      holders: () => const <String>[],
      friendHolders: () => keepers,
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    for (final CircleBackupService s in <CircleBackupService>[
      older,
      newer,
      owner,
    ]) {
      await s.start();
    }
    await _settleCircle(<CircleBackupService>[older, newer, owner]);
    // A newer password, kept only by the second friend.
    await vault.add(const PasswordFields(name: 'Nowe', password: 'najnowsze'));
    keepers = <String>[tNew.address];
    now += const Duration(hours: 2).inMilliseconds;
    await owner.refresh(force: true);
    await _settleCircle(<CircleBackupService>[older, newer, owner]);
    expect(
      newer.holder.manifestOf(me.account)!.createdAt,
      greaterThan(older.holder.manifestOf(me.account)!.createdAt),
    );
    await owner.stop();

    final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
    final LedgerIdentity recovered = await _byPaper(me, newDisk);
    await CircleBackupService.markRestore(
      newDisk,
      helpers: <String>[tOld.address, tNew.address],
      at: now,
    );
    final PasswordVaultService fresh = _freshVault();
    final CircleBackupService restoring = CircleBackupService(
      transport: await _started('200::c'),
      disk: newDisk,
      data: _VaultData(fresh),
      identity: () => _idOf(recovered),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    await restoring.start();
    await _settleCircle(<CircleBackupService>[restoring, older, newer]);
    expect(restoring.restore.value.phase, CircleBackupRestorePhase.done);
    expect(
      fresh.entries.map((PasswordEntry e) => e.password),
      contains('najnowsze'),
    );

    // A holder that offers its copy and then sends no chunk: after a while
    // the newest copy another holder offered is taken instead.
    final MemoryLedgerDisk stallDisk = MemoryLedgerDisk();
    final LedgerIdentity again = await _byPaper(me, stallDisk);
    await CircleBackupService.markRestore(
      stallDisk,
      helpers: <String>[tOld.address, tNew.address],
      at: now,
    );
    tNew.drops = (Map<String, dynamic> p) => p['type'] == 'cbk_part';
    final PasswordVaultService fresh2 = _freshVault();
    final CircleBackupService stalled = CircleBackupService(
      transport: await _started('200::c'),
      disk: stallDisk,
      data: _VaultData(fresh2),
      identity: () => _idOf(again),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
      clock: () => now,
    );
    await stalled.start();
    await _settleCircle(<CircleBackupService>[stalled, older, newer]);
    expect(stalled.restore.value.phase, CircleBackupRestorePhase.downloading);
    now += const Duration(hours: 2).inMilliseconds;
    await stalled.tick();
    await _settleCircle(<CircleBackupService>[stalled, older, newer]);
    expect(stalled.restore.value.phase, CircleBackupRestorePhase.done);
    _expectPasswords(fresh2);
    for (final CircleBackupService s in <CircleBackupService>[
      older,
      newer,
      restoring,
      stalled,
    ]) {
      await s.stop();
    }
  });

  test('a device the account cut off gets no copy', () async {
    _Linked.nodes.clear();
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    final PasswordVaultService vault = await _oldVault(MemoryLedgerDisk());
    final CircleBackupService holder = await _copyWithFriends(
      me,
      vault,
      circle: false,
    );
    await holder.stop();
    bool revoked = true;
    final CircleBackupService cautious = CircleBackupService(
      transport: await _started('200::b'),
      disk: holder.disk,
      data: _VaultData(_freshVault()),
      identity: () => null,
      holders: () => const <String>[],
      isInCircle: (_) => false,
      isFriend: (String a) => a == me.account,
      isRevoked: (String account, String device) => revoked,
      restoreCandidates: () => const <String>[],
    );
    await cautious.start();
    final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
    final LedgerIdentity thief = await _byPaper(me, newDisk, friend: '200::b');
    final _Linked tThief = _Linked('200::c');
    await tThief.start();
    final CircleBackupService fetching = CircleBackupService(
      transport: tThief,
      disk: newDisk,
      data: _VaultData(_freshVault()),
      identity: () => _idOf(thief),
      holders: () => const <String>[],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    await fetching.start();
    await _settleCircle(<CircleBackupService>[fetching, cautious]);
    expect(fetching.restore.value.phase, CircleBackupRestorePhase.searching);
    expect(
      tThief.sentSignals.where(
        (({Map<String, dynamic> payload, String remoteAddress}) f) =>
            f.payload['type'] == 'cbk_get',
      ),
      isEmpty,
    );
    // The same device, not cut off: it gets the copy.
    revoked = false;
    await fetching.tick();
    await _settleCircle(<CircleBackupService>[fetching, cautious]);
    expect(fetching.restore.value.phase, CircleBackupRestorePhase.done);
    await fetching.stop();
    await cautious.stop();
  });

  test('a copy a friend serves is old: it only adds, it never undoes a '
      'newer password, a deletion or a cleared history', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final PasswordVaultService vault = await _oldVault(disk);
    final Map<String, Object?> old = padPasswordSection(
      (await vault.exportForCopy())!,
    );
    final PasswordEntry bank = vault.entries.first;
    final PasswordEntry mail = vault.entries.last;
    await vault.edit(
      bank.id,
      const PasswordFields(
        name: 'Bank',
        login: 'ania',
        password: 'najnowsze',
        address: 'https://bank.example.com',
      ),
    );
    await vault.clearHistory(bank.id);
    await vault.delete(mail.id);
    expect(await vault.mergeCopy(old), 0);
    expect(vault.entries.single.password, 'najnowsze');
    expect(vault.entries.single.history, isEmpty);
    expect(vault.entry(mail.id), isNull);
    expect(
      utf8.decode(disk.files[kPasswordVaultKey]!),
      isNot(contains('haslo')),
    );
    // The notes the same way: an older copy brings no deleted note back.
    final SelfNotesService notes = await _oldNotes();
    final Map<String, Object?> oldNotes = (await notes.exportForCopy())!;
    await notes.delete(notes.notes.single.id);
    expect(await notes.mergeCopy(padPasswordSection(oldNotes)), 0);
    expect(notes.notes, isEmpty);
  });

  test(
    'another device of the account: a fresh device gets every password '
    'through the sync, in parts no larger than an entry of the log',
    () async {
      final _Net net = _Net();
      final _Device old = _Device(net, 'dev-a', seed: 1);
      // Many passwords (an import): far more than one entry carries.
      final StringBuffer csv = StringBuffer('name,url,username,password\n');
      for (int i = 0; i < 400; i++) {
        csv.write('Konto $i,https://s$i.example.com,user$i,${'p$i-' * 8}\n');
      }
      expect(
        (await old.vault.importCsv(
          Uint8List.fromList(utf8.encode(csv.toString())),
        )).imported,
        400,
      );
      final PasswordEntry bank = await old.vault.add(
        const PasswordFields(name: 'Bank', password: 'stare-haslo'),
      );
      await old.vault.edit(
        bank.id,
        const PasswordFields(name: 'Bank', password: 'nowe-haslo'),
      );
      await old.sync.start();
      await _settle(<_Device>[old]);
      expect(net.log, isEmpty, reason: 'alone: nobody to send to');

      // A second device is linked (no passwords file there yet).
      final _Device fresh = _Device(net, 'dev-b', seed: 2);
      old.channel.devices.add(null);
      await _settle(<_Device>[old]);
      await fresh.sync.start();
      await _settle(<_Device>[old, fresh]);
      await fresh.vault.load();
      expect(fresh.vault.entries, hasLength(401));
      expect(fresh.vault.entry(bank.id)!.password, 'nowe-haslo');
      expect(
        fresh.vault.entry(bank.id)!.history.single.password,
        'stare-haslo',
      );
      expect(net.log.length, greaterThan(3), reason: 'sent in parts');
      expect(net.largest, lessThanOrEqualTo(kMaxEntryBytes));

      // Changed on both before either hears of the other: both passwords
      // stay, the newer one current, on both.
      final Future<PasswordEntry> phoneEdit = old.vault.edit(
        bank.id,
        const PasswordFields(name: 'Bank', password: 'z-telefonu'),
      );
      final Future<PasswordEntry> laptopEdit = fresh.vault.edit(
        bank.id,
        const PasswordFields(name: 'Bank', password: 'z-laptopa'),
      );
      await phoneEdit;
      await laptopEdit;
      await old.sync.flush();
      await fresh.sync.flush();
      await _settle(<_Device>[old, fresh]);
      for (final _Device d in <_Device>[old, fresh]) {
        await d.vault.load();
        final PasswordEntry e = d.vault.entry(bank.id)!;
        expect(e.password, 'z-laptopa');
        expect(e.conflict, isTrue);
        expect(
          e.history
              .where((PasswordHistoryItem h) => h.concurrent)
              .single
              .password,
          'z-telefonu',
        );
      }
      // A deletion goes everywhere.
      await fresh.vault.delete(bank.id);
      await _settle(<_Device>[old, fresh]);
      await old.vault.load();
      expect(old.vault.entry(bank.id), isNull);
      expect(old.vault.entries, hasLength(400));
      await old.sync.stop();
      await fresh.sync.stop();
      await old.domain.close();
      await fresh.domain.close();
    },
  );

  test(
    'a full account copy (file), even one with nothing ticked but the '
    'key: the passwords and the notes come back on a fresh install',
    () async {
      final MemoryLedgerDisk oldDisk = MemoryLedgerDisk();
      await _oldVault(oldDisk);
      await _notesOn(oldDisk);
      final _Source source = _Source(
        oldDisk,
        Uint8List.fromList(List<int>.filled(32, 7)),
      );
      for (final Set<AccountScope> scope in <Set<AccountScope>>[
        <AccountScope>{AccountScope.keys},
        kAllAccountScopes,
      ]) {
        final AccountArchiveBuild build = await buildAccountArchive(
          source,
          scope,
          at: 1,
        );
        expect(
          build.archive.sections,
          contains(CircleBackupSections.passwords),
        );
        final Uint8List file = await _backupFile(build);
        // The file never shows a password.
        expect(latin1.decode(file), isNot(contains('nowe-haslo')));

        final _NewDevice device = _NewDevice();
        final AccountImportStaging staging = AccountImportStaging(device.disk);
        final AccountArchive archive = await _readBackup(file, staging);
        final AccountArchiveImporter importer = AccountArchiveImporter(
          sink: device,
          staging: staging,
        );
        expect(await importer.take(archive), AccountImportOutcome.restarting);
        expect(await importer.resume(), isNotNull);
        _expectPasswords(device.vault);
        _expectNotes(await _notesAt(device.disk));
      }
      // Without the key no copy carries them.
      final AccountArchiveBuild contacts = await buildAccountArchive(
        source,
        <AccountScope>{AccountScope.contacts},
        at: 1,
      );
      expect(
        contacts.archive.sections,
        isNot(contains(CircleBackupSections.passwords)),
      );
    },
  );

  test(
    'a second device or a move (the copy sent to it): the passwords come '
    'and the notes along, and merge into a device that has the account',
    () async {
      final MemoryLedgerDisk oldDisk = MemoryLedgerDisk();
      await _oldVault(oldDisk);
      await _notesOn(oldDisk);
      final AccountArchiveBuild build = await buildAccountArchive(
        _Source(oldDisk, Uint8List.fromList(List<int>.filled(32, 7))),
        kAllAccountScopes,
        at: 1,
      );
      // Sent as the copy screen sends it: the manifest as JSON, the key
      // apart, the files block by block.
      final AccountArchive sent = AccountArchive.fromJson(
        jsonDecode(jsonEncode(build.archive.withoutSeed().toJson())),
      )!.withSeed(build.archive.seed!);
      final _NewDevice device = _NewDevice();
      final AccountImportStaging staging = AccountImportStaging(device.disk);
      for (final MapEntry<String, AccountArchiveBlob> f
          in build.blobs.entries) {
        final BytesBuilder all = BytesBuilder();
        await for (final Uint8List part in f.value.chunks()) {
          all.add(part);
        }
        await staging.put(f.key, all.takeBytes());
      }
      final AccountArchiveImporter importer = AccountArchiveImporter(
        sink: device,
        staging: staging,
      );
      expect(await importer.take(sent), AccountImportOutcome.restarting);
      await importer.resume();
      _expectPasswords(device.vault);
      _expectNotes(await _notesAt(device.disk));

      // The same account, with a password of its own: nothing is lost.
      final _NewDevice same = _NewDevice(account: 'acc-1');
      await same.vault.add(
        const PasswordFields(name: 'Tylko tu', password: 'moje'),
      );
      final AccountImportStaging staging2 = AccountImportStaging(same.disk);
      for (final MapEntry<String, AccountArchiveBlob> f
          in build.blobs.entries) {
        final BytesBuilder all = BytesBuilder();
        await for (final Uint8List part in f.value.chunks()) {
          all.add(part);
        }
        await staging2.put(f.key, all.takeBytes());
      }
      expect(
        await AccountArchiveImporter(sink: same, staging: staging2).take(sent),
        AccountImportOutcome.done,
      );
      expect(same.vault.entries.map((PasswordEntry e) => e.name), <String>[
        'Bank',
        'Poczta',
        'Tylko tu',
      ]);
    },
  );

  test('the recovery circle: the key from two helpers and the password, the '
      'passwords from the copy with friends', () async {
    final MemoryLedgerDisk oldDisk = MemoryLedgerDisk();
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(oldDisk);
    final PasswordVaultService vault = await _oldVault(MemoryLedgerDisk());
    final CircleBackupService holder = await _copyWithFriends(
      me,
      vault,
      notes: await _oldNotes(),
    );

    // The phone is lost. Two helpers give their halves back.
    final List<RecoveryPiece> pieces = await createRecoveryPieces(
      account: me.account,
      seed: me.accountKey!.seed,
      password: 'haslo-konta-123',
      helpers: 4,
      now: 1,
      cost: _light,
    );
    final List<RecoveredAccount> found = await recoverWithPassword(
      <Map<String, dynamic>>[
        for (final RecoveryPiece p in pieces.take(2))
          <String, dynamic>{...p.normal, 'account': me.account},
      ],
      'haslo-konta-123',
      acceptedCosts: const <PasswordCost>[_light],
    );
    final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
    final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
      newDisk,
      found.single.seed,
    );
    await CircleBackupService.markRestore(newDisk, helpers: <String>['200::b']);
    final (PasswordVaultService v, SelfNotesService n) =
        await _restoreFromFriends(recovered, newDisk, holder);
    _expectPasswords(v);
    _expectNotes(n);
  });

  test('while the vault cannot be read no copy with friends is made: the '
      'holders keep the last one with the passwords', () async {
    _Linked.nodes.clear();
    final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
      MemoryLedgerDisk(),
    );
    bool locked = true;
    final PasswordVaultService vault = PasswordVaultService(
      disk: MemoryLedgerDisk(),
      isLocked: () => locked,
    );
    final _Linked tOwner = _Linked('200::a');
    await tOwner.start();
    final CircleBackupService owner = CircleBackupService(
      transport: tOwner,
      disk: MemoryLedgerDisk(),
      data: _VaultData(vault),
      identity: () => _idOf(me),
      holders: () => <String>['200::b'],
      isInCircle: (_) => false,
      restoreCandidates: () => const <String>[],
    );
    await owner.refresh(force: true);
    expect(tOwner.sentSignals, isEmpty);
    locked = false;
    await owner.refresh(force: true);
    expect(tOwner.sentSignals, isNotEmpty);
  });
}
