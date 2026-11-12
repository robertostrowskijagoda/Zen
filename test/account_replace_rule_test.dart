import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_backup_io.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/account/account_holdings.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/account_replace_dialog.dart';
import 'package:zen/src/features/account/presentation/key_restore_screen.dart';
import 'package:zen/src/features/chat/self_notes.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/passwords/password_vault_service.dart';
import 'package:zen/src/features/runtime/opened_file_bridge.dart';
import 'package:zen/src/features/runtime/opened_files.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);

/// What the four kinds of device in these tests hold.
const AccountHoldings _fresh = AccountHoldings(account: 'here');
const AccountHoldings _notesAndPasswords = AccountHoldings(
  account: 'here',
  notes: 3,
  passwords: 2,
);
const AccountHoldings _withFriends = AccountHoldings(
  account: 'here',
  name: 'Ala',
  friends: 4,
);

/// A device that takes copies, in memory; fresh or not as [holdings] say
/// (the app's sink asks [readAccountHoldings] the same way).
final class _Sink implements AccountArchiveSink {
  _Sink(this.holdings);

  final AccountHoldings holdings;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  int applied = 0;
  AccountArchive? adopted;

  @override
  Future<String?> currentAccount() async => holdings.account;

  @override
  Future<bool> isFresh() async => holdings.isFresh;

  @override
  Future<void> adoptAccount(AccountArchive archive) async {
    adopted = archive;
  }

  @override
  Future<void> writeRaw(
    String key,
    Uint8List value, {
    required bool onlyIfAbsent,
  }) => disk.write(key, value);

  @override
  Future<AccountImportSummary> apply(
    AccountArchive archive,
    AccountArchiveBlob? Function(String id) file,
    void Function(int done, int total) progress, {
    required bool merge,
  }) async {
    applied++;
    return const AccountImportSummary();
  }

  @override
  Future<void> restart({Future<void> Function()? whileStopped}) async {
    await whileStopped?.call();
  }
}

final class _Places implements AccountBackupPlaces {
  _Places(this.path);

  final String path;

  @override
  Future<String?> pick() async => path;

  @override
  Future<AccountBackupFolder> defaultFolder() async =>
      AccountBackupFolder.directory(File(path).parent.path);

  @override
  Future<AccountBackupFolder?> chooseFolder() async => null;

  @override
  Future<String> workPath(AccountBackupFolder folder, String name) async =>
      path;

  @override
  Future<AccountBackupSaved> deliver(
    AccountBackupFolder folder,
    String first,
    List<String> parts,
  ) async => AccountBackupSaved(folder: folder, shown: parts, canOpen: true);

  @override
  Future<void> release(AccountBackupFolder folder, String first) async {}

  @override
  Future<bool> open(AccountBackupSaved saved) async => true;
}

/// A backup of the account `incoming`, named Ola, with its key.
AccountArchiveBuild _copyOfIncoming() {
  final AccountArchiveBuilder b = AccountArchiveBuilder(
    account: 'incoming',
    scope: kAllAccountScopes,
  )..seed = Uint8List.fromList(List<int>.filled(32, 7));
  b.sections['profile'] = <String, dynamic>{'displayName': 'Ola'};
  return (archive: b.build(at: 1), blobs: b.blobs);
}

Future<void> _real(WidgetTester tester, [int rounds = 10]) async {
  for (int i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

/// A few frames of time: a dialog opens while the screen below still shows
/// its spinner (it waits for the answer), so nothing settles.
Future<void> _frames(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

Widget _app(Widget home, {List<Override> overrides = const <Override>[]}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: ZenTheme.light(), home: home),
    );

Override _holdings(AccountHoldings holdings) =>
    accountHoldingsProvider.overrideWithValue(() async => holdings);

/// A screen that asks [mayTakeAccountHere] for [incoming], as the link and
/// the copy from another device do, and keeps the answer.
class _Asker extends ConsumerWidget {
  const _Asker(this.incoming, this.answers);

  final String incoming;
  final List<bool> answers;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    body: Center(
      child: FilledButton(
        key: const Key('ask'),
        onPressed: () async => answers.add(
          await mayTakeAccountHere(context, ref, incoming: incoming),
        ),
        child: const Text('weź konto'),
      ),
    ),
  );
}

Future<Uint8List> _vaultWith(int n) async {
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  final PasswordVaultService vault = PasswordVaultService(disk: disk);
  for (int i = 0; i < n; i++) {
    await vault.add(PasswordFields(name: 'Bank $i', password: 'tajne $i'));
  }
  return (await disk.read(kPasswordVaultKey))!;
}

Uint8List _notes(int n, {int deleted = 0}) => Uint8List.fromList(
  utf8.encode(
    jsonEncode(<String, Object?>{
      for (int i = 0; i < n; i++)
        'n$i': SelfNote(
          id: 'n$i',
          text: 'notatka $i',
          atMillis: i + 1,
        ).toJson(),
      for (int i = 0; i < deleted; i++)
        'd$i': SelfNote(
          id: 'd$i',
          text: '',
          atMillis: 100 + i,
          deleted: true,
        ).toJson(),
    }),
  ),
);

void main() {
  tearDown(AccountPasswordCarry.instance.clear);

  group('one rule: what is here decides', () {
    test('a device with nothing of its own is fresh; a name, notes, '
        'passwords, posts, invitations, friends, groups, pyramid, dating, '
        'pebbles or an account password each make it not', () {
      expect(_fresh.isFresh, isTrue);
      expect(_fresh.describe(), isEmpty);
      for (final AccountHoldings h in const <AccountHoldings>[
        AccountHoldings(name: 'Ala'),
        AccountHoldings(notes: 1),
        AccountHoldings(passwords: 1),
        AccountHoldings(posts: 1),
        AccountHoldings(chats: 1),
        AccountHoldings(invitations: 1),
        AccountHoldings(friends: 1),
        AccountHoldings(groups: 1),
        AccountHoldings(pyramid: true),
        AccountHoldings(dating: true),
        AccountHoldings(pebbles: 1),
        AccountHoldings(accountPassword: true),
      ]) {
        expect(h.isFresh, isFalse);
        expect(h.describe(), hasLength(1));
      }
      // The rule before counted friends, groups and the pyramid only: a
      // notebook and a password vault were "fresh".
      expect(_notesAndPasswords.isFresh, isFalse);
    });

    test('notes and passwords are counted as they are stored', () async {
      expect(selfNotesCountOf(null), 0);
      expect(selfNotesCountOf(Uint8List.fromList(utf8.encode('{}'))), 0);
      expect(selfNotesCountOf(_notes(2, deleted: 3)), 2);
      expect(selfNotesCountOf(Uint8List.fromList(<int>[1, 2, 3])), 1);
      expect(passwordsCountOf(null), 0);
      expect(passwordsCountOf(await _vaultWith(3)), 3);
    });

    test('a link used to keep what was here under the account it brought: '
        'the notes and the vault stayed on the disk the new account starts '
        'on (and its devices sync them as its own)', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final LedgerIdentity before = await LedgerIdentity.loadOrCreate(disk);
      await disk.write(kSelfNotesKey, _notes(2));
      await disk.write(kPasswordVaultKey, await _vaultWith(2));
      final LedgerKeyPair other = await LedgerKeyPair.generate();
      await LedgerIdentity.adoptAccount(disk, other.seed);
      final LedgerIdentity after = (await LedgerIdentity.load(disk))!;
      expect(after.account, isNot(before.account));
      expect(selfNotesCountOf(await disk.read(kSelfNotesKey)), 2);
      expect(passwordsCountOf(await disk.read(kPasswordVaultKey)), 2);
    });
  });

  group('the link and the copy from another device', () {
    Future<List<bool>> ask(
      WidgetTester tester,
      AccountHoldings here, {
      String incoming = 'incoming',
    }) async {
      final List<bool> answers = <bool>[];
      await tester.pumpWidget(
        _app(_Asker(incoming, answers), overrides: <Override>[_holdings(here)]),
      );
      await tester.tap(find.byKey(const Key('ask')));
      await tester.pumpAndSettle();
      return answers;
    }

    testWidgets('a fresh device takes the account at once', (
      WidgetTester tester,
    ) async {
      expect(await ask(tester, _fresh), <bool>[true]);
      expect(find.byKey(const Key('account-replace-dialog')), findsNothing);
    });

    testWidgets('the same account merges as before', (
      WidgetTester tester,
    ) async {
      expect(await ask(tester, _withFriends, incoming: 'here'), <bool>[true]);
    });

    testWidgets('a device with notes and passwords: both accounts named, what '
        'would be lost, a backup offered, nothing taken', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<bool> answers = <bool>[];
      await tester.pumpWidget(
        _app(
          _Asker('incoming', answers),
          overrides: <Override>[_holdings(_notesAndPasswords)],
        ),
      );
      await tester.tap(find.byKey(const Key('ask')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('account-replace-dialog')), findsOneWidget);
      expect(find.text(accountFingerprint('here')), findsOneWidget);
      expect(find.text(accountFingerprint('incoming')), findsOneWidget);
      expect(find.text('• 3 notatki'), findsOneWidget);
      expect(find.text('• 2 zapisane hasła'), findsOneWidget);
      expect(find.byKey(const Key('account-replace-loss')), findsOneWidget);
      expect(find.byKey(const Key('account-replace-backup')), findsOneWidget);
      expect(find.byKey(const Key('account-replace-wipe')), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-replace-cancel')));
      await tester.pumpAndSettle();
      expect(answers, <bool>[false]);
      expect(AccountPasswordCarry.instance.isHeld, isFalse);
    });

    testWidgets('a device with friends: the same question, the other account '
        'goes beside this one', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final List<bool> answers = <bool>[];
      await tester.pumpWidget(
        _app(
          _Asker('incoming', answers),
          overrides: <Override>[_holdings(_withFriends)],
        ),
      );
      await tester.tap(find.byKey(const Key('ask')));
      await tester.pumpAndSettle();
      expect(find.text('Ala'), findsOneWidget);
      expect(find.text('• 4 znajomych'), findsOneWidget);
      // No passwords here: nothing to take along.
      expect(find.byKey(const Key('account-replace-passwords')), findsNothing);
      await tester.tap(find.byKey(const Key('account-replace-add')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-account-page')), findsOneWidget);
      expect(answers, <bool>[false]);
    });

    testWidgets('the passwords go along only when ticked', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await disk.write(
        kPasswordVaultKey,
        (await tester.runAsync(() => _vaultWith(2)))!,
      );
      Future<void> choose({required bool tick}) async {
        final List<bool> answers = <bool>[];
        // A new app each time ("Dodaj konto" stays open from the last).
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(
          _app(
            _Asker('incoming', answers),
            overrides: <Override>[
              _holdings(_notesAndPasswords),
              ledgerDiskProvider.overrideWithValue(disk),
            ],
          ),
        );
        await tester.tap(find.byKey(const Key('ask')));
        await tester.pumpAndSettle();
        final CheckboxListTile box = tester.widget<CheckboxListTile>(
          find.byKey(const Key('account-replace-passwords')),
        );
        expect(box.value, isFalse, reason: 'off unless ticked');
        if (tick) {
          await tester.tap(find.byKey(const Key('account-replace-passwords')));
          await tester.pump();
        }
        await tester.tap(find.byKey(const Key('account-replace-add')));
        await _real(tester, 4);
        await tester.pumpAndSettle();
      }

      await choose(tick: false);
      expect(AccountPasswordCarry.instance.isHeld, isFalse);

      await choose(tick: true);
      expect(AccountPasswordCarry.instance.isHeld, isTrue);
      // They go into the account taken next, once.
      final PasswordVaultService next = PasswordVaultService(
        disk: MemoryLedgerDisk(),
      );
      await tester.runAsync(() async {
        await takeCarriedPasswords(() => next);
        await next.load();
      });
      expect(next.entries, hasLength(2));
      expect(AccountPasswordCarry.instance.isHeld, isFalse);
    });

    test('the passwords held for the next account do not wait for ever', () {
      AccountPasswordCarry.instance.put(<String, Object?>{'e': 1}, now: 0);
      expect(
        AccountPasswordCarry.instance.take(
          now: AccountPasswordCarry.keep.inMilliseconds + 1,
        ),
        isNull,
      );
    });
  });

  group('a backup file', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('zen-replace-');
      path = '${dir.path}/k.$kAccountBackupExtension';
    });

    tearDown(() => dir.deleteSync(recursive: true));

    Future<_Sink> restore(WidgetTester tester, AccountHoldings here) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => writeAccountBackup(
          build: _copyOfIncoming(),
          password: 'dobre hasło 1',
          first: path,
          cost: _light,
          remember: false,
        ),
      );
      final _Sink sink = _Sink(here);
      await tester.pumpWidget(
        _app(
          const AccountBackupRestoreScreen(),
          overrides: <Override>[
            _holdings(here),
            accountBackupPlacesProvider.overrideWithValue(_Places(path)),
            accountBackupAcceptedCostsProvider.overrideWithValue(<PasswordCost>[
              _light,
            ]),
            accountArchiveImporterProvider.overrideWithValue(
              AccountArchiveImporter(
                sink: sink,
                staging: AccountImportStaging(sink.disk),
              ),
            ),
          ],
        ),
      );
      await tester.tap(find.byKey(const Key('account-restore-pick')));
      await _real(tester);
      await tester.enterText(
        find.byKey(const Key('account-restore-password')),
        'dobre hasło 1',
      );
      await tester.tap(find.byKey(const Key('account-restore-run')));
      await _real(tester, 20);
      await _frames(tester);
      return sink;
    }

    testWidgets('onto a fresh device: taken, no question', (
      WidgetTester tester,
    ) async {
      final _Sink sink = await restore(tester, _fresh);
      expect(find.byKey(const Key('account-replace-dialog')), findsNothing);
      expect(sink.adopted?.account, 'incoming');
    });

    testWidgets('onto a device with only notes and passwords: the question, '
        'the copy named by its name, nothing taken', (
      WidgetTester tester,
    ) async {
      final _Sink sink = await restore(tester, _notesAndPasswords);
      expect(find.byKey(const Key('account-replace-dialog')), findsOneWidget);
      expect(find.text('Ola'), findsOneWidget);
      expect(sink.adopted, isNull);
      expect(sink.applied, 0);
      expect(sink.disk.files, isEmpty);
    });

    testWidgets('onto a device with friends: the question, nothing taken', (
      WidgetTester tester,
    ) async {
      final _Sink sink = await restore(tester, _withFriends);
      expect(find.byKey(const Key('account-replace-dialog')), findsOneWidget);
      expect(sink.adopted, isNull);
    });

    testWidgets('opened from the file manager while Zen was locked: it waits, '
        'then the same question', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(
        () => writeAccountBackup(
          build: _copyOfIncoming(),
          password: 'dobre hasło 1',
          first: path,
          cost: _light,
          remember: false,
        ),
      );
      final ZenOpenedFiles files = ZenOpenedFiles(reader: const _Reader());
      addTearDown(files.dispose);
      // Locked: the bridge is not built yet, the file waits.
      await tester.runAsync(() => files.offer(path));
      final _Sink sink = _Sink(_notesAndPasswords);
      await tester.pumpWidget(
        _app(
          const OpenedFileBridge(child: Scaffold(body: Text('aplikacja'))),
          overrides: <Override>[
            zenOpenedFilesProvider.overrideWithValue(files),
            _holdings(_notesAndPasswords),
            accountBackupAcceptedCostsProvider.overrideWithValue(<PasswordCost>[
              _light,
            ]),
            accountArchiveImporterProvider.overrideWithValue(
              AccountArchiveImporter(
                sink: sink,
                staging: AccountImportStaging(sink.disk),
              ),
            ),
          ],
        ),
      );
      await _real(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account-backup-restore-screen')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('account-restore-password')),
        'dobre hasło 1',
      );
      await tester.tap(find.byKey(const Key('account-restore-run')));
      await _real(tester, 20);
      await _frames(tester);
      expect(find.byKey(const Key('account-replace-dialog')), findsOneWidget);
      expect(sink.adopted, isNull);
    });
  });

  group('a key on paper or in a file', () {
    Future<(MemoryLedgerDisk, String)> adopt(
      WidgetTester tester,
      AccountHoldings here,
    ) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Uint8List seed = randomBytes(32);
      final LedgerKeyPair pair = (await tester.runAsync(
        () => LedgerKeyPair.fromSeed(seed),
      ))!;
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await tester.pumpWidget(
        _app(
          const KeyRestoreScreen(),
          overrides: <Override>[
            ledgerDiskProvider.overrideWithValue(disk),
            _holdings(here),
          ],
        ),
      );
      await tester.enterText(
        find.byKey(const Key('paper-restore-input')),
        formatPaperBackup(encodePaperBackup(seed)),
      );
      await tester.tap(find.byKey(const Key('paper-restore-check')));
      await _real(tester, 5);
      await tester.tap(find.byKey(const Key('paper-restore-adopt')));
      await _real(tester, 5);
      await tester.pumpAndSettle();
      return (disk, pair.id);
    }

    testWidgets('onto a fresh device: taken', (WidgetTester tester) async {
      final (MemoryLedgerDisk disk, String account) = await adopt(
        tester,
        _fresh,
      );
      expect(find.byKey(const Key('paper-restore-done')), findsOneWidget);
      final LedgerIdentity? saved = await tester.runAsync<LedgerIdentity?>(
        () => LedgerIdentity.read(disk),
      );
      expect(saved?.account, account);
    });

    testWidgets('onto a device with notes and passwords: the question, not '
        'taken', (WidgetTester tester) async {
      final (MemoryLedgerDisk disk, String _) = await adopt(
        tester,
        _notesAndPasswords,
      );
      expect(find.byKey(const Key('account-replace-dialog')), findsOneWidget);
      await tester.tap(find.byKey(const Key('account-replace-cancel')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('paper-restore-done')), findsNothing);
      expect(await tester.runAsync(() => LedgerIdentity.read(disk)), isNull);
    });

    testWidgets('onto a device with friends: the question, not taken', (
      WidgetTester tester,
    ) async {
      final (MemoryLedgerDisk disk, String _) = await adopt(
        tester,
        _withFriends,
      );
      expect(find.byKey(const Key('account-replace-dialog')), findsOneWidget);
      expect(await tester.runAsync(() => LedgerIdentity.read(disk)), isNull);
    });
  });
}

final class _Reader implements OpenedFileReader {
  const _Reader();

  @override
  Future<String?> localPath(String file) async => file;
}
