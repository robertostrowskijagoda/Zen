import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/settings/diagnostics_log_file.dart';

/// Saving the diagnostics log: the person always says where (the save
/// dialog on a computer, the system's file browser open at Downloads on a
/// phone); a cancelled dialog writes nothing, and a failure is thrown, not
/// swallowed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory logs;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('zen-log-file-');
    logs = Directory('${root.path}/logs')..createSync();
    await ZenDiagnosticsLog.attach(logs, source: 'ui');
    ZenDiagnosticsLog.write('INFO  something happened');
    await ZenDiagnosticsLog.settled;
  });

  tearDown(() async {
    await ZenDiagnosticsLog.settled;
    root.deleteSync(recursive: true);
  });

  test('the file is named after the date and time', () {
    expect(
      diagnosticsLogFileName(DateTime(2026, 3, 9, 7, 5, 9)),
      'zen-dziennik-20260309-070509.txt',
    );
  });

  test('on a phone the person picks the place; the log is written for '
      'it', () async {
    String? asked;
    String? written;
    final AccountBackupSaved? saved = await saveDiagnosticsLog(
      system: AccountBackupSystem.android,
      now: DateTime(2026, 3, 9, 7, 5, 9),
      saveAs: (String name, Future<void> Function(File file) write) async {
        asked = name;
        final File file = File('${root.path}/picked.txt');
        await write(file);
        written = await file.readAsString();
        return 'content://documents/1';
      },
    );
    expect(asked, 'zen-dziennik-20260309-070509.txt');
    expect(written, contains('something happened'));
    expect(saved!.shown, <String>['zen-dziennik-20260309-070509.txt']);
    expect(saved.canOpen, isFalse);
  });

  test('on a phone a closed file browser saves nothing; a failure is '
      'thrown', () async {
    expect(
      await saveDiagnosticsLog(
        system: AccountBackupSystem.ios,
        saveAs: (String name, Future<void> Function(File file) write) async =>
            null,
      ),
      isNull,
    );
    await expectLater(
      saveDiagnosticsLog(
        system: AccountBackupSystem.android,
        saveAs: (String name, Future<void> Function(File file) write) async =>
            throw PlatformException(code: 'io', message: 'no room'),
      ),
      throwsA(isA<PlatformException>()),
    );
  });

  test('on a computer the chosen file is written, and a cancelled dialog '
      'writes nothing', () async {
    final String target = '${root.path}/chosen.txt';
    final AccountBackupSaved? saved = await saveDiagnosticsLog(
      system: AccountBackupSystem.desktop,
      pickTarget: (String name) async => target,
    );
    expect(saved!.shown, <String>[target]);
    expect(saved.canOpen, isTrue);
    expect(await File(target).readAsString(), contains('something happened'));

    expect(
      await saveDiagnosticsLog(
        system: AccountBackupSystem.desktop,
        pickTarget: (String name) async => null,
      ),
      isNull,
    );
  });
}
