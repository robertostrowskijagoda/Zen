import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_backup_io.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/account_import_layer.dart';
import 'package:zen/src/features/account/presentation/account_restore_info.dart';
import 'package:zen/src/features/account/presentation/account_secure_stage.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);

/// Backup files at fixed places (no dialogs): the default folder is the
/// one of [path]; [chosen] is what the folder chooser answers (null: the
/// person cancels).
final class _Places implements AccountBackupPlaces {
  _Places(this.path, {this.chosen});

  final String path;
  AccountBackupFolder? chosen;
  int chooserCalls = 0;
  final List<AccountBackupFolder> written = <AccountBackupFolder>[];

  AccountBackupFolder get defaultPlace =>
      AccountBackupFolder.directory(File(path).parent.path);

  @override
  Future<String?> pick() async => path;

  @override
  Future<AccountBackupFolder> defaultFolder() async => defaultPlace;

  @override
  Future<AccountBackupFolder?> chooseFolder() async {
    chooserCalls++;
    return chosen;
  }

  @override
  Future<String> workPath(AccountBackupFolder folder, String name) async {
    written.add(folder);
    return folder == defaultPlace ? path : '${folder.path}/$name';
  }

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

/// A device that takes copies, in memory.
final class _Sink implements AccountArchiveSink {
  _Sink(this.account);

  final String account;
  final MemoryLedgerDisk disk = MemoryLedgerDisk();
  int applied = 0;

  @override
  Future<String?> currentAccount() async => account;

  @override
  Future<bool> isFresh() async => false;

  @override
  Future<void> adoptAccount(AccountArchive archive) async {}

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

AccountArchiveBuild _copy(Set<AccountScope> scope, {String account = 'acc'}) {
  final AccountArchiveBuilder b = AccountArchiveBuilder(
    account: account,
    scope: scope,
  )..seed = Uint8List.fromList(List<int>.filled(32, 1));
  b.sections['settings'] = <String, dynamic>{'x': 1};
  b.addBytes(Uint8List.fromList(List<int>.filled(5000, 2)));
  return (archive: b.build(at: 1), blobs: b.blobs);
}

Future<void> _real(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

Widget _app(Widget home, {List<Override> overrides = const <Override>[]}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: ZenTheme.light(), home: home),
    );

void main() {
  testWidgets('"Co da się odzyskać i jak": every way against every part', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(const AccountRestoreInfoScreen()));
    expect(find.byKey(const Key('account-restore-table')), findsOneWidget);
    for (final AccountRestoreMethod m in AccountRestoreMethod.values) {
      expect(find.text(accountRestoreMethodLabel(m)), findsWidgets);
    }
    for (final AccountRestoreRow r in accountRestoreRows()) {
      expect(find.text(r.label), findsOneWidget);
      // Another device brings everything back, except the settings of
      // the device itself, which stay on it (note 6).
      expect(
        r.cells[AccountRestoreMethod.device],
        r.label == 'Ustawienia'
            ? (AccountRestoreCell.partly, 6)
            : (AccountRestoreCell.yes, null),
      );
      expect(r.cells.length, AccountRestoreMethod.values.length);
    }
    // Every note the table points to is there.
    final Set<int> used = <int>{
      for (final AccountRestoreRow r in accountRestoreRows())
        for (final (AccountRestoreCell, int?) c in r.cells.values) ?c.$2,
    };
    expect(accountRestoreNotes().keys, containsAll(used));
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('first start: a way back ends the first start and opens once '
      'the app runs', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    late WidgetRef seen;
    await tester.pumpWidget(
      _app(
        Consumer(
          builder: (BuildContext context, WidgetRef ref, Widget? child) {
            seen = ref;
            return const AccountSecureStage();
          },
        ),
        overrides: <Override>[
          appSettingsStoreProvider.overrideWithValue(store),
        ],
      ),
    );
    expect(find.text('Jak zaczynasz?'), findsOneWidget);
    expect(find.byKey(const Key('account-start-new')), findsOneWidget);
    expect(find.byKey(const Key('account-backup-open')), findsNothing);
    await tester.tap(find.byKey(const Key('account-copy-receive-open')));
    await tester.pumpAndSettle();
    expect(
      seen.read(accountStartActionProvider).value,
      AccountStartAction.device,
    );
    expect((await store.load())!.accountSecureOffered, isTrue);
  });

  testWidgets('the restore and backup buttons', (WidgetTester tester) async {
    bool circle = false;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: SingleChildScrollView(
            child: AccountCopyActions(circle: () => circle = true),
          ),
        ),
      ),
    );
    for (final String key in <String>[
      'account-backup-open',
      'account-copy-send-open',
      'account-restore-backup-open',
      'account-copy-receive-open',
      'account-restore-circle-open',
      'account-restore-info-link',
    ]) {
      expect(find.byKey(Key(key)), findsOneWidget, reason: key);
    }
    await tester.tap(find.byKey(const Key('account-restore-circle-open')));
    expect(circle, isTrue);
    await tester.tap(find.byKey(const Key('account-restore-info-link')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('account-restore-info')), findsOneWidget);
  });

  testWidgets('"Mam backup": a wrong password, then the right one', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory dir = Directory.systemTemp.createTempSync('zen-ui-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/k.$kAccountBackupExtension';
    await tester.runAsync(
      () => writeAccountBackup(
        build: _copy(kAllAccountScopes),
        password: 'dobre hasło 1',
        first: path,
        cost: _light,
        remember: false,
      ),
    );
    final _Sink sink = _Sink('acc');
    await tester.pumpWidget(
      _app(
        const AccountBackupRestoreScreen(),
        overrides: <Override>[
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
    expect(find.byKey(const Key('account-restore-key')), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-restore-pick')));
    await _real(tester);
    expect(find.byKey(const Key('account-restore-parts')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('account-restore-password')),
      'złe hasło',
    );
    await tester.tap(find.byKey(const Key('account-restore-run')));
    await _real(tester);
    expect(find.text('Złe hasło albo plik został zmieniony.'), findsOneWidget);
    expect(sink.applied, 0);

    await tester.enterText(
      find.byKey(const Key('account-restore-password')),
      'dobre hasło 1',
    );
    await tester.tap(find.byKey(const Key('account-restore-run')));
    await _real(tester);
    expect(find.textContaining('Kopia przyjęta'), findsOneWidget);
    expect(sink.applied, 1);
  });

  testWidgets('"Mam backup" refuses another account on a device with data', (
    WidgetTester tester,
  ) async {
    final Directory dir = Directory.systemTemp.createTempSync('zen-ui-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/k.$kAccountBackupExtension';
    await tester.runAsync(
      () => writeAccountBackup(
        build: _copy(kAllAccountScopes, account: 'someone-else'),
        password: 'dobre hasło 1',
        first: path,
        cost: _light,
        remember: false,
      ),
    );
    final _Sink sink = _Sink('acc');
    await tester.pumpWidget(
      _app(
        const AccountBackupRestoreScreen(),
        overrides: <Override>[
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
    await _real(tester);
    expect(find.textContaining('To kopia innego konta'), findsOneWidget);
    expect(sink.applied, 0);
    expect(sink.disk.files, isEmpty);
  });

  testWidgets('"Utwórz kopię zapasową": the chosen parts, the size and the '
      'file', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final Directory dir = Directory.systemTemp.createTempSync('zen-ui-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = '${dir.path}/k.$kAccountBackupExtension';
    final List<Set<AccountScope>> asked = <Set<AccountScope>>[];
    await tester.pumpWidget(
      _app(
        const AccountBackupScreen(),
        overrides: <Override>[
          socialHubAutoHydrateProvider.overrideWithValue(false),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
          accountBackupPlacesProvider.overrideWithValue(_Places(path)),
          accountBackupCostProvider.overrideWithValue(_light),
          accountArchiveCollectorProvider.overrideWithValue((
            Set<AccountScope> scope, {
            bool measureOnly = false,
          }) async {
            asked.add(<AccountScope>{...scope});
            return _copy(scope);
          }),
        ],
      ),
    );
    await _real(tester);
    expect(find.textContaining('Około'), findsOneWidget);
    for (final AccountScope s in AccountScope.values) {
      expect(find.byKey(Key('account-backup-scope-${s.name}')), findsOneWidget);
    }
    // The account and its keys cannot be left out.
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('account-backup-scope-keys')),
          )
          .onChanged,
      isNull,
    );
    await tester.tap(find.byKey(const Key('account-backup-scope-films')));
    await _real(tester);
    expect(asked.last, isNot(contains(AccountScope.films)));

    await tester.enterText(
      find.byKey(const Key('account-backup-password')),
      'dobre hasło 1',
    );
    await tester.enterText(
      find.byKey(const Key('account-backup-repeat')),
      'inne hasło 1',
    );
    await tester.tap(find.byKey(const Key('account-backup-create')));
    await _real(tester);
    expect(find.text('Hasła się różnią.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('account-backup-repeat')),
      'dobre hasło 1',
    );
    await tester.ensureVisible(find.byKey(const Key('account-backup-create')));
    await tester.tap(find.byKey(const Key('account-backup-create')));
    for (int i = 0; i < 5; i++) {
      await _real(tester);
    }
    expect(find.byKey(const Key('account-backup-done')), findsOneWidget);
    expect(asked.last, contains(AccountScope.keys));
    expect(asked.last, isNot(contains(AccountScope.films)));
    final ({AccountArchive? archive, AccountBackupError? error})? read =
        await tester.runAsync(
          () => AccountBackupFile.read(
            chunks: readAccountBackupParts(<String>[path]),
            password: 'dobre hasło 1',
            acceptedCosts: <PasswordCost>[_light],
            file: (String id, int size) async =>
                AccountImportStaging(MemoryLedgerDisk()).writer(id),
          ),
        );
    expect(read!.error, isNull);
    expect(read.archive!.seed, isNotNull);
    expect(read.archive!.scope, isNot(contains(AccountScope.films)));
    // The default folder is named, the finished file is shown and can be
    // opened.
    expect(
      find.descendant(
        of: find.byKey(const Key('account-backup-done')),
        matching: find.textContaining(path),
      ),
      findsOneWidget,
    );
    expect(find.byKey(const Key('account-backup-open-folder')), findsOneWidget);
  });

  group('the folder of a backup', () {
    Future<void> pumpBackup(WidgetTester tester, _Places places) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          const AccountBackupScreen(),
          overrides: <Override>[
            socialHubAutoHydrateProvider.overrideWithValue(false),
            signalTransportProvider.overrideWithValue(MemorySignalTransport()),
            ledgerNodeEnabledProvider.overrideWithValue(true),
            ledgerDiskProvider.overrideWithValue(MemoryLedgerDisk()),
            accountBackupPlacesProvider.overrideWithValue(places),
            accountBackupCostProvider.overrideWithValue(_light),
            accountArchiveCollectorProvider.overrideWithValue(
              (Set<AccountScope> scope, {bool measureOnly = false}) async =>
                  _copy(scope),
            ),
          ],
        ),
      );
      await _real(tester);
    }

    Future<void> create(WidgetTester tester) async {
      await tester.enterText(
        find.byKey(const Key('account-backup-password')),
        'dobre hasło 1',
      );
      await tester.enterText(
        find.byKey(const Key('account-backup-repeat')),
        'dobre hasło 1',
      );
      await tester.ensureVisible(
        find.byKey(const Key('account-backup-create')),
      );
      await tester.tap(find.byKey(const Key('account-backup-create')));
      for (int i = 0; i < 5; i++) {
        await _real(tester);
      }
    }

    testWidgets('the default one is shown and written to', (
      WidgetTester tester,
    ) async {
      final Directory dir = Directory.systemTemp.createTempSync('zen-ui-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final _Places places = _Places('${dir.path}/k.$kAccountBackupExtension');
      await pumpBackup(tester, places);
      expect(
        find.text('${dir.path} (domyślnie)'),
        findsOneWidget,
        reason: 'the default folder is named',
      );
      await create(tester);
      expect(places.written.single, places.defaultPlace);
      expect(File(places.path).existsSync(), isTrue);
    });

    testWidgets('another one the person chooses is used and shown', (
      WidgetTester tester,
    ) async {
      final Directory dir = Directory.systemTemp.createTempSync('zen-ui-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final Directory other = Directory('${dir.path}/inne')..createSync();
      final _Places places = _Places(
        '${dir.path}/k.$kAccountBackupExtension',
        chosen: AccountBackupFolder.directory(other.path),
      );
      await pumpBackup(tester, places);
      await tester.tap(find.byKey(const Key('account-backup-folder-choose')));
      await _real(tester);
      expect(find.text(other.path), findsOneWidget);
      expect(find.textContaining('(domyślnie)'), findsNothing);
      await create(tester);
      expect(places.written.single.path, other.path);
      expect(other.listSync().single.path, endsWith(kAccountBackupExtension));
      expect(find.textContaining(other.path), findsWidgets);
      expect(File(places.path).existsSync(), isFalse);
      // Back to the default.
      await tester.tap(find.byKey(const Key('account-backup-folder-default')));
      await _real(tester);
      expect(find.text('${dir.path} (domyślnie)'), findsOneWidget);
    });

    testWidgets('a cancelled chooser keeps the default', (
      WidgetTester tester,
    ) async {
      final Directory dir = Directory.systemTemp.createTempSync('zen-ui-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final _Places places = _Places('${dir.path}/k.$kAccountBackupExtension');
      await pumpBackup(tester, places);
      await tester.tap(find.byKey(const Key('account-backup-folder-choose')));
      await _real(tester);
      expect(places.chooserCalls, 1);
      expect(find.text('${dir.path} (domyślnie)'), findsOneWidget);
      expect(
        find.byKey(const Key('account-backup-folder-default')),
        findsNothing,
      );
      await create(tester);
      expect(places.written.single, places.defaultPlace);
      expect(File(places.path).existsSync(), isTrue);
    });
  });
}
