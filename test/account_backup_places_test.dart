import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_backup_places.dart';
import 'package:zen/src/features/account/account_recovery.dart';

const PasswordCost _light = PasswordCost(memoryKiB: 64, iterations: 1);

const MethodChannel _channel = MethodChannel('zen/system-test');

AccountArchiveBuild _copy() {
  final AccountArchiveBuilder b = AccountArchiveBuilder(
    account: 'acc',
    scope: <AccountScope>{...kAllAccountScopes},
  )..seed = Uint8List.fromList(List<int>.filled(32, 1));
  b.sections['settings'] = <String, dynamic>{'x': 1};
  b.addBytes(Uint8List.fromList(List<int>.filled(5000, 2)));
  return (archive: b.build(at: 1), blobs: b.blobs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late Directory downloads;
  late Directory documents;
  late Directory external;
  late Directory temp;
  late List<MethodCall> calls;
  late List<String> remembered;
  Object? Function(MethodCall call) answer = (MethodCall call) => null;

  setUp(() {
    root = Directory.systemTemp.createTempSync('zen-places-');
    downloads = Directory('${root.path}/Downloads')..createSync();
    documents = Directory('${root.path}/Documents')..createSync();
    external = Directory('${root.path}/external')..createSync();
    temp = Directory('${root.path}/tmp')..createSync();
    calls = <MethodCall>[];
    remembered = <String>[];
    answer = (MethodCall call) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (MethodCall call) async {
          calls.add(call);
          return answer(call);
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    root.deleteSync(recursive: true);
  });

  PlatformAccountBackupPlaces places(
    AccountBackupSystem system, {
    int? sdk,
    bool noDownloads = false,
    Future<String?> Function()? picker,
    List<String>? revealed,
  }) => PlatformAccountBackupPlaces(
    system: system,
    channel: _channel,
    androidSdk: () async => sdk,
    downloads: () async => noDownloads ? null : downloads,
    documents: () async => documents,
    appExternal: () async => external,
    temporary: () async => temp,
    directoryPicker: picker ?? () async => null,
    reveal: (String path) async => revealed?.add(path),
    remember: (String path) async => remembered.add(path),
  );

  group('the default folder', () {
    test('Windows, macOS and Linux: Downloads', () async {
      final AccountBackupFolder folder = await places(
        AccountBackupSystem.desktop,
      ).defaultFolder();
      expect(folder.kind, AccountBackupFolderKind.directory);
      expect(folder.path, downloads.path);
      expect(folder.label, downloads.path);
    });

    test('a computer with no Downloads folder: Documents', () async {
      final AccountBackupFolder folder = await places(
        AccountBackupSystem.desktop,
        noDownloads: true,
      ).defaultFolder();
      expect(folder.path, documents.path);
    });

    test('Android 10 and newer: Downloads, no storage permission', () async {
      for (final int sdk in <int>[29, 30, 34]) {
        final AccountBackupFolder folder = await places(
          AccountBackupSystem.android,
          sdk: sdk,
        ).defaultFolder();
        expect(folder.kind, AccountBackupFolderKind.downloads, reason: '$sdk');
        expect(folder.label, 'Pobrane');
      }
    });

    test('Android before 10 (or unknown): the app\'s own folder', () async {
      for (final int? sdk in <int?>[28, 24, null]) {
        final AccountBackupFolder folder = await places(
          AccountBackupSystem.android,
          sdk: sdk,
        ).defaultFolder();
        expect(folder.kind, AccountBackupFolderKind.directory, reason: '$sdk');
        expect(folder.path, '${external.path}${Platform.pathSeparator}Zen');
      }
    });

    test('iPhone: the app\'s Documents, which the Files app shows', () async {
      final AccountBackupFolder folder = await places(
        AccountBackupSystem.ios,
      ).defaultFolder();
      expect(folder.kind, AccountBackupFolderKind.directory);
      expect(folder.path, documents.path);
      expect(folder.label, isNot(documents.path));
    });
  });

  group('choosing a folder', () {
    test('a computer: the folder dialog\'s answer', () async {
      final AccountBackupFolder? folder = await places(
        AccountBackupSystem.desktop,
        picker: () async => '${root.path}/mine',
      ).chooseFolder();
      expect(folder, AccountBackupFolder.directory('${root.path}/mine'));
    });

    test('cancelled on a computer or iPhone: nothing', () async {
      for (final AccountBackupSystem system in <AccountBackupSystem>[
        AccountBackupSystem.desktop,
        AccountBackupSystem.ios,
      ]) {
        expect(
          await places(system, picker: () async => null).chooseFolder(),
          isNull,
        );
        expect(
          await places(system, picker: () async => '').chooseFolder(),
          isNull,
        );
      }
    });

    test('Android: the system\'s folder chooser', () async {
      answer = (MethodCall call) => <String, Object>{
        'tree': 'content://tree/primary%3AKopie',
        'label': 'Kopie',
      };
      final AccountBackupFolder? folder = await places(
        AccountBackupSystem.android,
        sdk: 34,
      ).chooseFolder();
      expect(calls.single.method, 'pickFolder');
      expect(folder!.kind, AccountBackupFolderKind.picked);
      expect(folder.tree, 'content://tree/primary%3AKopie');
      expect(folder.label, 'Kopie');
    });

    test('Android: a cancelled chooser gives nothing', () async {
      expect(
        await places(AccountBackupSystem.android, sdk: 34).chooseFolder(),
        isNull,
      );
    });
  });

  group('writing', () {
    test('a plain folder is written to directly', () async {
      final PlatformAccountBackupPlaces p = places(AccountBackupSystem.desktop);
      final AccountBackupFolder folder = AccountBackupFolder.directory(
        '${root.path}/new/deeper',
      );
      final AccountBackupSaved saved = await saveAccountBackup(
        places: p,
        folder: folder,
        name: 'zen-konto.$kAccountBackupExtension',
        build: _copy(),
        password: 'dobre hasło 1',
        cost: _light,
      );
      final String file =
          '${root.path}/new/deeper${Platform.pathSeparator}'
          'zen-konto.$kAccountBackupExtension';
      expect(saved.shown, <String>[file]);
      expect(saved.canOpen, isTrue);
      expect(File(file).existsSync(), isTrue);
      expect(calls, isEmpty);
    });

    test(
      'Downloads on Android: staged, handed over, the staging gone',
      () async {
        final List<String> sent = <String>[];
        answer = (MethodCall call) {
          final Map<Object?, Object?> args =
              call.arguments as Map<Object?, Object?>;
          for (final Object? path in args['paths']! as List<Object?>) {
            expect(File(path! as String).existsSync(), isTrue);
            sent.add(path as String);
          }
          return <String, Object>{
            'names': <String>['${args['name']}'],
            'uris': <String>['content://media/external/downloads/41'],
          };
        };
        final PlatformAccountBackupPlaces p = places(
          AccountBackupSystem.android,
          sdk: 34,
        );
        final AccountBackupSaved saved = await saveAccountBackup(
          places: p,
          folder: AccountBackupFolder.downloads(),
          name: 'zen-konto.$kAccountBackupExtension',
          build: _copy(),
          password: 'dobre hasło 1',
          cost: _light,
        );
        expect(calls.single.method, 'exportToDownloads');
        expect(sent.single, startsWith(temp.path));
        expect(saved.shown, <String>[
          'Pobrane/zen-konto.$kAccountBackupExtension',
        ]);
        expect(saved.canOpen, isTrue);
        // Only the file that stays is remembered for the panic password, by
        // the address the system deletes it by.
        expect(remembered, <String>['content://media/external/downloads/41']);
        expect(temp.listSync(), isEmpty);
      },
    );

    test('a folder the person picked on Android', () async {
      answer = (MethodCall call) => <String, Object>{
        'names': <String>['zen-konto (1).$kAccountBackupExtension'],
        'uris': <String>['content://tree/x/document/y'],
      };
      final AccountBackupFolder folder = AccountBackupFolder.picked(
        tree: 'content://tree/x',
        label: 'Kopie',
      );
      final AccountBackupSaved saved = await saveAccountBackup(
        places: places(AccountBackupSystem.android, sdk: 34),
        folder: folder,
        name: 'zen-konto.$kAccountBackupExtension',
        build: _copy(),
        password: 'dobre hasło 1',
        cost: _light,
      );
      expect(calls.single.method, 'exportToFolder');
      expect(
        (calls.single.arguments as Map<Object?, Object?>)['tree'],
        'content://tree/x',
      );
      expect(saved.shown, <String>[
        'Kopie/zen-konto (1).$kAccountBackupExtension',
      ]);
      // The copy in the picked folder is deleted by the panic password too.
      expect(remembered, <String>['content://tree/x/document/y']);
      expect(temp.listSync(), isEmpty);
    });

    test('a failed hand-over throws and still removes the staging', () async {
      // The system gives no name: nothing was saved.
      answer = (MethodCall call) => null;
      await expectLater(
        saveAccountBackup(
          places: places(AccountBackupSystem.android, sdk: 34),
          folder: AccountBackupFolder.downloads(),
          name: 'zen-konto.$kAccountBackupExtension',
          build: _copy(),
          password: 'dobre hasło 1',
          cost: _light,
        ),
        throwsStateError,
      );
      expect(temp.listSync(), isEmpty);
      expect(remembered, isEmpty);
    });
  });

  group('showing the folder', () {
    test('a computer shows the file; an iPhone has nothing to show', () async {
      final List<String> revealed = <String>[];
      final AccountBackupFolder folder = AccountBackupFolder.directory('/x');
      final AccountBackupSaved saved = AccountBackupSaved(
        folder: folder,
        shown: const <String>['/x/k.zenbackup'],
        canOpen: true,
      );
      expect(
        await places(
          AccountBackupSystem.desktop,
          revealed: revealed,
        ).open(saved),
        isTrue,
      );
      expect(revealed, <String>['/x/k.zenbackup']);
      expect(await places(AccountBackupSystem.ios).open(saved), isFalse);
    });

    test('Android opens Downloads or the chosen folder', () async {
      answer = (MethodCall call) => true;
      final PlatformAccountBackupPlaces p = places(
        AccountBackupSystem.android,
        sdk: 34,
      );
      expect(
        await p.open(
          AccountBackupSaved(
            folder: AccountBackupFolder.downloads(),
            shown: const <String>['Pobrane/k'],
          ),
        ),
        isTrue,
      );
      expect(calls.last.method, 'openDownloads');
      expect(
        await p.open(
          AccountBackupSaved(
            folder: AccountBackupFolder.picked(tree: 'content://t', label: 'K'),
            shown: const <String>['K/k'],
          ),
        ),
        isTrue,
      );
      expect(calls.last.method, 'openFolder');
    });
  });
}
