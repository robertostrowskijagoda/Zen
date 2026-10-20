import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_identity.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/paper_backup.dart';
import 'package:zen/src/features/account/presentation/account_secure_stage.dart';
import 'package:zen/src/features/account/presentation/paper_backup_screen.dart';
import 'package:zen/src/features/account/presentation/paper_restore_screen.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';

Widget _app(Widget home, {List<Override> overrides = const <Override>[]}) =>
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(theme: ZenTheme.light(), home: home),
    );

void main() {
  test('encode and decode round trip, grouped like the paper', () {
    for (int i = 0; i < 20; i++) {
      final Uint8List seed = randomBytes(32);
      final String code = encodePaperBackup(seed);
      expect(code, hasLength(kPaperBackupLength));
      expect(code, matches(RegExp(r'^[A-Z2-7]+$')));
      expect(paperBackupGroups(code), hasLength(kPaperBackupGroups));
      final String written = formatPaperBackup(code);
      expect(written.split('-'), hasLength(kPaperBackupGroups));
      for (final String text in <String>[
        code,
        written,
        formatPaperBackup(code, separator: ' ').toLowerCase(),
        paperBackupQrData(code),
        '  $written\n',
      ]) {
        final PaperBackupDecoded decoded = decodePaperBackup(text);
        expect(decoded.isOk, isTrue, reason: text);
        expect(decoded.seed, seed);
      }
    }
  });

  test('wrong checksum, length and characters are refused', () {
    final Uint8List seed = randomBytes(32);
    final String code = encodePaperBackup(seed);

    // Every single-character typo is caught by the checksum.
    const String alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
    for (int i = 0; i < code.length; i++) {
      final String other = alphabet[(alphabet.indexOf(code[i]) + 1) % 32];
      final String typo = code.replaceRange(i, i + 1, other);
      expect(
        decodePaperBackup(typo).error,
        PaperBackupError.checksum,
        reason: 'position $i',
      );
    }
    expect(decodePaperBackup(code.substring(1)).error, PaperBackupError.length);
    expect(decodePaperBackup('').error, PaperBackupError.length);
    expect(
      decodePaperBackup('${code.substring(0, 55)}9').error,
      PaperBackupError.characters,
    );
    expect(
      decodePaperBackup('${code.substring(0, 55)}!').error,
      PaperBackupError.characters,
    );
    // Look-alike digits read as letters; the checksum still decides.
    expect(
      decodePaperBackup(code.replaceAll('O', '0').replaceAll('B', '8')).seed,
      seed,
    );
    expect(() => encodePaperBackup(Uint8List(31)), throwsArgumentError);
  });

  test('the check asks two different groups and compares loosely', () {
    final String code = encodePaperBackup(randomBytes(32));
    for (int i = 0; i < 30; i++) {
      final List<int> asked = pickCheckGroups(Random(i));
      expect(asked, hasLength(2));
      expect(asked[0], lessThan(asked[1]));
      expect(asked.every((int g) => g >= 0 && g < kPaperBackupGroups), isTrue);
    }
    final String group = paperBackupGroups(code)[5];
    expect(paperBackupGroupMatches(code, 5, group.toLowerCase()), isTrue);
    expect(paperBackupGroupMatches(code, 5, ' $group '), isTrue);
    expect(paperBackupGroupMatches(code, 4, group), isFalse);
    expect(paperBackupGroupMatches(code, 99, group), isFalse);
  });

  test('restore adopts exactly the account of the paper copy', () async {
    final MemoryLedgerDisk first = MemoryLedgerDisk();
    final LedgerIdentity original = await LedgerIdentity.loadOrCreate(first);
    final String code = encodePaperBackup(original.accountKey!.seed);

    // A fresh phone with an account of its own.
    final MemoryLedgerDisk fresh = MemoryLedgerDisk();
    final LedgerIdentity own = await LedgerIdentity.loadOrCreate(fresh);
    expect(own.account, isNot(original.account));

    final PaperBackupAccount found = await PaperBackupAccount.fromSeed(
      decodePaperBackup(formatPaperBackup(code)).seed!,
    );
    expect(found.account, original.account);
    expect(found.fingerprint, accountFingerprint(original.account));

    final LedgerIdentity adopted = await adoptPaperBackup(fresh, found);
    expect(adopted.account, original.account);
    expect(adopted.deviceKey.id, isNot(original.deviceKey.id));
    final LedgerIdentity? saved = await LedgerIdentity.read(fresh);
    expect(saved!.account, original.account);
    expect(saved.certificate.account, original.account);

    // A seed that is not the confirmed account's key is refused.
    final PaperBackupAccount wrong = PaperBackupAccount(
      seed: randomBytes(32),
      account: original.account,
    );
    await expectLater(
      adoptPaperBackup(MemoryLedgerDisk(), wrong),
      throwsStateError,
    );
  });

  testWidgets('the check accepts the right groups and records the copy', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final String code = encodePaperBackup(
      Uint8List.fromList(List<int>.generate(32, (int i) => i * 7 + 1)),
    );
    int confirmed = 0;
    await tester.pumpWidget(
      _app(
        Scaffold(
          body: PaperBackupView(
            code: code,
            random: Random(3),
            onConfirmed: () async => confirmed++,
          ),
        ),
      ),
    );
    final List<String> groups = paperBackupGroups(code);
    for (int i = 0; i < kPaperBackupGroups; i++) {
      expect(find.text(groups[i]), findsOneWidget);
    }
    expect(find.byKey(const Key('paper-backup-qr')), findsNothing);
    await tester.tap(find.byKey(const Key('paper-backup-qr-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('paper-backup-qr')), findsOneWidget);

    await tester.tap(find.byKey(const Key('paper-backup-written')));
    await tester.pump();
    final List<int> asked = pickCheckGroups(Random(3));

    // A wrong answer is refused.
    await tester.enterText(find.byKey(const Key('paper-check-0')), 'AAAA');
    await tester.enterText(
      find.byKey(const Key('paper-check-1')),
      groups[asked[1]],
    );
    await tester.tap(find.byKey(const Key('paper-check-confirm')));
    await tester.pump();
    expect(find.byKey(const Key('paper-check-error')), findsOneWidget);
    expect(confirmed, 0);

    await tester.enterText(
      find.byKey(const Key('paper-check-0')),
      groups[asked[0]].toLowerCase(),
    );
    await tester.tap(find.byKey(const Key('paper-check-confirm')));
    await tester.pump();
    expect(confirmed, 1);
    expect(find.byKey(const Key('paper-backup-done')), findsOneWidget);
  });

  testWidgets(
    'restore screen: typo refused, fingerprint shown, account taken',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final Uint8List seed = randomBytes(32);
      final String code = encodePaperBackup(seed);
      final LedgerKeyPair pair =
          await tester.runAsync(() => LedgerKeyPair.fromSeed(seed))
              as LedgerKeyPair;
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      await tester.pumpWidget(
        _app(
          const PaperRestoreScreen(),
          overrides: <Override>[ledgerDiskProvider.overrideWithValue(disk)],
        ),
      );

      final String typo = code.replaceRange(3, 4, code[3] == 'A' ? 'B' : 'A');
      await tester.enterText(
        find.byKey(const Key('paper-restore-input')),
        typo,
      );
      await tester.tap(find.byKey(const Key('paper-restore-check')));
      await tester.pump();
      expect(find.byKey(const Key('paper-restore-message')), findsOneWidget);
      expect(find.byKey(const Key('paper-restore-adopt')), findsNothing);

      await tester.enterText(
        find.byKey(const Key('paper-restore-input')),
        formatPaperBackup(code),
      );
      await tester.tap(find.byKey(const Key('paper-restore-check')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('paper-restore-fingerprint')),
            )
            .data,
        accountFingerprint(pair.id),
      );
      expect(await LedgerIdentity.read(disk), isNull, reason: 'not yet taken');

      await tester.tap(find.byKey(const Key('paper-restore-adopt')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
      expect(find.byKey(const Key('paper-restore-done')), findsOneWidget);
      final LedgerIdentity? saved = await tester.runAsync<LedgerIdentity?>(
        () => LedgerIdentity.read(disk),
      );
      expect(saved!.account, pair.id);
    },
  );

  test('the new settings survive a round trip and default to not done', () {
    expect(const AppSettings().accountSecureOffered, isFalse);
    expect(const AppSettings().paperBackupDone, isFalse);
    final AppSettings done = const AppSettings().copyWith(
      accountSecureOffered: true,
      paperBackupDone: true,
    );
    final AppSettings back = AppSettings.fromJson(done.toJson());
    expect(back.accountSecureOffered, isTrue);
    expect(back.paperBackupDone, isTrue);
    expect(AppSettings.fromJson(<String, dynamic>{}).paperBackupDone, isFalse);
  });

  testWidgets('"Zabezpiecz konto": later is remembered', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(
      const AppSettings(),
    );
    await tester.pumpWidget(
      _app(
        const AccountSecureStage(),
        overrides: <Override>[
          appSettingsStoreProvider.overrideWithValue(store),
        ],
      ),
    );
    expect(find.byKey(const Key('account-secure-circle')), findsOneWidget);
    expect(find.byKey(const Key('account-secure-paper')), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-secure-later')));
    await tester.pumpAndSettle();
    expect((await store.load())!.accountSecureOffered, isTrue);
  });
}
