import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/settings/diagnostics_log_file.dart';

const MethodChannel _channel = MethodChannel('zen/system-test');

/// Saving the diagnostics log: Downloads through the media store on an
/// Android phone (the app's own `Android/data` folder is hidden from file
/// managers), the app's folder before Android 10, the save dialog on a
/// computer; and a failure is thrown, not swallowed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory logs;
  late List<MethodCall> calls;
  late List<String> stagedText;
  Object? Function(MethodCall call) answer = (MethodCall call) => null;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('zen-log-file-');
    logs = Directory('${root.path}/logs')..createSync();
    calls = <MethodCall>[];
    stagedText = <String>[];
    answer = (MethodCall call) => null;
    await ZenDiagnosticsLog.attach(logs, source: 'ui');
    ZenDiagnosticsLog.write('INFO  something happened');
    await ZenDiagnosticsLog.settled;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          calls.add(call);
          if (call.method == 'exportToDownloads') {
            // The staged copy is read while it still exists.
            final List<Object?> paths =
                (call.arguments as Map<Object?, Object?>)['paths']!
                    as List<Object?>;
            stagedText.add(await File(paths.first! as String).readAsString());
          }
          return answer(call);
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await ZenDiagnosticsLog.settled;
    root.deleteSync(recursive: true);
  });

  PlatformAccountBackupPlaces places({int? sdk}) => PlatformAccountBackupPlaces(
    system: AccountBackupSystem.android,
    channel: _channel,
    androidSdk: () async => sdk,
    documents: () async => Directory('${root.path}/Documents')..createSync(),
    appExternal: () async => Directory('${root.path}/external')..createSync(),
    temporary: () async => Directory('${root.path}/tmp')..createSync(),
    remember: (String path) async {},
  );

  test('the file is named after the date and time', () {
    expect(
      diagnosticsLogFileName(DateTime(2026, 3, 9, 7, 5)),
      'zen-dziennik-20260309-0705.txt',
    );
  });

  test('Android 10+: the log goes to Downloads and the staged copy is '
      'removed', () async {
    answer = (MethodCall call) => <String, Object>{
      'names': <String>['zen-dziennik-20260309-0705.txt'],
      'uris': <String>['content://downloads/1'],
    };
    final AccountBackupSaved? saved = await saveDiagnosticsLog(
      places: places(sdk: 30),
      system: AccountBackupSystem.android,
      now: DateTime(2026, 3, 9, 7, 5),
    );

    final MethodCall export = calls.singleWhere(
      (MethodCall c) => c.method == 'exportToDownloads',
    );
    expect(
      (export.arguments as Map<Object?, Object?>)['name'],
      'zen-dziennik-20260309-0705.txt',
    );
    expect(stagedText.single, contains('something happened'));
    expect(saved!.folder.kind, AccountBackupFolderKind.downloads);
    expect(saved.shown, <String>['Pobrane/zen-dziennik-20260309-0705.txt']);
    expect(saved.canOpen, isTrue);
    final Directory tmp = Directory('${root.path}/tmp');
    expect(tmp.listSync(), isEmpty);
  });

  test('Android 10+: a failing media store is reported, nothing is left '
      'behind', () async {
    answer = (MethodCall call) => null;
    await expectLater(
      saveDiagnosticsLog(
        places: places(sdk: 33),
        system: AccountBackupSystem.android,
      ),
      throwsStateError,
    );
    expect(Directory('${root.path}/tmp').listSync(), isEmpty);

    answer = (MethodCall call) =>
        throw PlatformException(code: 'io', message: 'no room');
    await expectLater(
      saveDiagnosticsLog(
        places: places(sdk: 33),
        system: AccountBackupSystem.android,
      ),
      throwsA(isA<PlatformException>()),
    );
    expect(Directory('${root.path}/tmp').listSync(), isEmpty);
  });

  test('before Android 10: the log goes to the app\'s Zen folder', () async {
    final AccountBackupSaved? saved = await saveDiagnosticsLog(
      places: places(sdk: 28),
      system: AccountBackupSystem.android,
      now: DateTime(2026, 3, 9, 7, 5),
    );
    expect(calls, isEmpty);
    final String path = saved!.shown.single;
    expect(path, endsWith('zen-dziennik-20260309-0705.txt'));
    expect(path, contains('Zen'));
    expect(await File(path).readAsString(), contains('something happened'));
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
