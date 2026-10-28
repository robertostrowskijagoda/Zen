import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/key_file.dart';
import 'package:zen/src/features/runtime/opened_file_bridge.dart';
import 'package:zen/src/features/runtime/opened_files.dart';
import 'package:zen/src/features/update/release.dart';

/// Reads paths where they are, like a computer; `null` for what is not
/// there (a content address that could not be copied).
final class _Reader implements OpenedFileReader {
  final List<String> asked = <String>[];

  @override
  Future<String?> localPath(String file) async {
    asked.add(file);
    return await File(file).exists() ? file : null;
  }
}

Future<void> _real(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  group('what an opened file is', () {
    test('told by its first bytes, whatever its name', () {
      expect(
        zenOpenedFileKindOf('document.bin', ascii.encode('ZENACCT1....')),
        ZenOpenedFileKind.accountBackup,
      );
      // A newer backup is still a backup (its screen says what is needed).
      expect(
        zenOpenedFileKindOf('x', ascii.encode('ZENACCT2')),
        ZenOpenedFileKind.accountBackup,
      );
      expect(
        zenOpenedFileKindOf('plik', ascii.encode('ZENKEY\u0001')),
        ZenOpenedFileKind.keyFile,
      );
      expect(
        zenOpenedFileKindOf('1234', <int>[...ReleaseBundle.magic, 0, 0]),
        ZenOpenedFileKind.update,
      );
    });

    test('else by its name, a backup part included', () {
      const List<int> none = <int>[1, 2, 3];
      expect(
        zenOpenedFileKindOf('/a/zen-konto.$kAccountBackupExtension', none),
        ZenOpenedFileKind.accountBackup,
      );
      expect(
        zenOpenedFileKindOf('/a/ZEN-KONTO.ZENBACKUP.2', none),
        ZenOpenedFileKind.accountBackup,
      );
      expect(
        zenOpenedFileKindOf('k.$kKeyFileExtension', none),
        ZenOpenedFileKind.keyFile,
      );
      expect(
        zenOpenedFileKindOf('zen-1.14.0.$kUpdateFileExtension', none),
        ZenOpenedFileKind.update,
      );
      expect(zenOpenedFileKindOf('zdjęcie.jpg', none), ZenOpenedFileKind.other);
      expect(zenOpenedFileKindOf('pusty', <int>[]), ZenOpenedFileKind.other);
    });
  });

  group('links and files apart', () {
    test('files are content addresses, file addresses and bare paths', () {
      expect(
        zenOpenedFileOfLink(
          Uri.parse(
            'content://com.android.providers.downloads.documents/document/msf%3A12',
          ),
        ),
        'content://com.android.providers.downloads.documents/document/msf%3A12',
      );
      expect(
        zenOpenedFileOfLink(Uri.parse('file:///home/ala/a%20b.zenbackup')),
        '/home/ala/a b.zenbackup',
      );
      expect(
        zenOpenedFileOfLink(Uri.parse('/home/ala/zażółć.zenkey')),
        '/home/ala/zażółć.zenkey',
      );
    });

    test('links stay links', () {
      for (final String link in <String>[
        'zen://chat/200:1::1',
        'https://robertostrowskijagoda.github.io/Zen/#ABCD',
        'https://github.com/robertostrowskijagoda/Zen#ABCD',
        '--zen-profile=test',
      ]) {
        expect(isZenOpenedFileLink(Uri.parse(link)), isFalse, reason: link);
      }
    });

    test('a computer gives the file as an absolute path argument', () {
      expect(
        zenOpenedFileArgument(<String>[r'C:\Users\Ala\zen-konto.zenbackup']),
        r'C:\Users\Ala\zen-konto.zenbackup',
      );
      expect(
        zenOpenedFileArgument(<String>[
          '--zen-profile=a',
          '/home/ala/k.zenkey',
        ]),
        '/home/ala/k.zenkey',
      );
      expect(
        zenOpenedFileArgument(<String>[r'\\serwer\kopie\k.zenkey']),
        r'\\serwer\kopie\k.zenkey',
      );
      expect(zenOpenedFileArgument(<String>['--zen-profile=a']), isNull);
      expect(zenOpenedFileArgument(<String>['k.zenkey']), isNull);
      expect(zenOpenedFileArgument(<String>[]), isNull);
    });
  });

  group('the opened file waits for its screen', () {
    late Directory dir;
    late DateTime now;
    late _Reader reader;
    late ZenOpenedFiles files;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('zen-opened-');
      now = DateTime(2026, 10, 28, 12);
      reader = _Reader();
      files = ZenOpenedFiles(reader: reader, now: () => now);
    });

    tearDown(() {
      files.dispose();
      dir.deleteSync(recursive: true);
    });

    String write(String name, List<int> bytes) {
      final File file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
      return file.path;
    }

    test('read, told apart and taken once', () async {
      final String path = write('a.bin', ascii.encode('ZENKEY\u0001rest'));
      int changes = 0;
      files.addListener(() => changes++);
      await files.offer(path);
      expect(changes, 1);
      expect(files.pending?.kind, ZenOpenedFileKind.keyFile);
      expect(files.pending?.path, path);
      final ZenOpenedFile? taken = files.take();
      expect(taken?.path, path);
      expect(files.pending, isNull);
      expect(files.take(), isNull);
    });

    test('the same file handed over twice at once is one opening', () async {
      final String path = write('k.zenbackup', ascii.encode('ZENACCT1'));
      await files.offer(path);
      files.take();
      now = now.add(const Duration(seconds: 1));
      await files.offer(path);
      expect(files.pending, isNull);
      expect(reader.asked, hasLength(1));
      // Opened again later: a new opening.
      now = now.add(ZenOpenedFiles.repeatWindow);
      await files.offer(path);
      expect(files.pending?.kind, ZenOpenedFileKind.accountBackup);
    });

    test('a file that cannot be read still says so', () async {
      await files.offer('content://gone/document/1');
      expect(files.pending?.kind, ZenOpenedFileKind.other);
      expect(files.pending?.path, isNull);
    });

    test('only the newest file waits', () async {
      final String first = write('k.zenkey', ascii.encode('ZENKEY'));
      final String second = write('u.zenupdate', ReleaseBundle.magic);
      await files.offer(first);
      await files.offer(second);
      expect(files.pending?.path, second);
      expect(files.pending?.kind, ZenOpenedFileKind.update);
    });
  });

  group('the screen for an opened file', () {
    late Directory dir;
    late ZenOpenedFiles files;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('zen-opened-ui-');
      files = ZenOpenedFiles(reader: _Reader());
    });

    tearDown(() {
      files.dispose();
      dir.deleteSync(recursive: true);
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [zenOpenedFilesProvider.overrideWithValue(files)],
          child: MaterialApp(
            theme: ZenTheme.light(),
            home: const OpenedFileBridge(
              child: Scaffold(body: Text('aplikacja')),
            ),
          ),
        ),
      );
    }

    testWidgets('a backup opens "Mam kopię" with the file chosen', (
      WidgetTester tester,
    ) async {
      final String path = '${dir.path}/zen-konto.$kAccountBackupExtension';
      File(path).writeAsBytesSync(ascii.encode('ZENACCT1 not a real one'));
      await pump(tester);
      await tester.runAsync(() => files.offer(path));
      await _real(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account-backup-restore-screen')),
        findsOneWidget,
      );
      final Text parts = tester.widget<Text>(
        find.byKey(const Key('account-restore-parts')),
      );
      expect(parts.data, path);
      expect(files.pending, isNull);
    });

    testWidgets('a key backup opens "Przywróć klucz" asking its password', (
      WidgetTester tester,
    ) async {
      final String path = '${dir.path}/plik';
      File(path).writeAsBytesSync(ascii.encode('ZENKEY\u0001 not a real one'));
      await pump(tester);
      await tester.runAsync(() => files.offer(path));
      await _real(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('key-restore-screen')), findsOneWidget);
      expect(find.byKey(const Key('key-restore-password')), findsOneWidget);
    });

    testWidgets('a file that is not Zen\'s is only named so', (
      WidgetTester tester,
    ) async {
      final String path = '${dir.path}/zdjęcie.jpg';
      File(path).writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
      await pump(tester);
      await tester.runAsync(() => files.offer(path));
      await _real(tester);
      expect(find.textContaining('To nie jest plik Zen'), findsOneWidget);
      expect(find.text('aplikacja'), findsOneWidget);
    });

    testWidgets('a file that came before the screen opens once it is there', (
      WidgetTester tester,
    ) async {
      // Zen was locked: the file waited.
      final String path = '${dir.path}/k.$kAccountBackupExtension';
      File(path).writeAsBytesSync(ascii.encode('ZENACCT1'));
      await tester.runAsync(() => files.offer(path));
      await pump(tester);
      await _real(tester);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('account-backup-restore-screen')),
        findsOneWidget,
      );
    });
  });
}
