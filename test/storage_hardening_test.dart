import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/core/storage/storage_health.dart';
import 'package:zen/src/core/storage/unmetered_network.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/features/settings/app_settings.dart';

final class _NoCompression implements BinaryCompressor {
  final List<int> levels = <int>[];

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async {
    levels.add(level);
    return null;
  }

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => null;
}

final class _NamingProtector
    implements KeyedBinaryPayloadProtector, BinaryStoreNameKeySource {
  @override
  Future<Uint8List> seal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> unseal(Uint8List payload) async => payload;

  @override
  Future<Uint8List> sealFor(String storageKey, Uint8List payload) async =>
      payload;

  @override
  Future<Uint8List> unsealFor(String storageKey, Uint8List payload) async =>
      payload;

  @override
  bool isSealed(Uint8List payload) => true;

  @override
  Future<Uint8List?> fileNameKey() async => Uint8List(32)..fillRange(0, 32, 7);
}

Uint8List _bytes(int length) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => i % 251));

List<String> _files(Directory root) => root
    .listSync(recursive: true)
    .whereType<File>()
    .map((File f) => f.path.substring(root.path.length + 1))
    .toList();

final class _FakeClipboard implements ClipboardAccess {
  String? text;
  bool readable = true;

  @override
  Future<void> write(String value) async => text = value;

  @override
  Future<String?> read() async => readable ? text : null;
}

void main() {
  group('hidden names for meet/list and ledger', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zen_hidden_names');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('are stored under keyed names, not readable ones', () async {
      final FileBinaryStore store = FileBinaryStore(
        dir,
        codec: BinaryCodec(compressor: _NoCompression()),
        protector: _NamingProtector(),
      );
      await store.write('meet/list/abcdef', _bytes(40));
      await store.write('ledger/log-0123-0', _bytes(40));
      await store.write('ledger/index', _bytes(40));

      final List<String> files = _files(dir);
      expect(files, hasLength(3));
      for (final String f in files) {
        expect(f, startsWith('$kHiddenNamesFolder${Platform.pathSeparator}'));
        expect(f, isNot(contains('abcdef')));
        expect(f, isNot(contains('log-0123')));
      }
      expect(await store.read('meet/list/abcdef'), _bytes(40));
      expect(await store.read('ledger/log-0123-0'), _bytes(40));
    });

    test('files written under readable names are moved on first use', () async {
      final BinaryCodec codec = BinaryCodec(compressor: _NoCompression());
      final _NamingProtector protector = _NamingProtector();
      // An old install: names not hidden.
      final FileBinaryStore old = FileBinaryStore(
        dir,
        codec: codec,
        protector: protector,
        hiddenNamePrefixes: const <String>{},
      );
      await old.write('meet/list/abcdef', _bytes(64));
      await old.write('meet/list/abcdef', _bytes(65)); // leaves a .bak
      await old.write('ledger/log-0123-0', _bytes(70));
      expect(_files(dir).any((String f) => f.contains('abcdef')), isTrue);

      final FileBinaryStore fresh = FileBinaryStore(
        dir,
        codec: codec,
        protector: protector,
      );
      expect(await fresh.read('meet/list/abcdef'), _bytes(65));
      expect(await fresh.read('ledger/log-0123-0'), _bytes(70));

      final List<String> files = _files(dir);
      expect(files.any((String f) => f.contains('abcdef')), isFalse);
      expect(files.any((String f) => f.contains('log-0123')), isFalse);
      expect(
        files.every(
          (String f) =>
              f.startsWith('$kHiddenNamesFolder${Platform.pathSeparator}'),
        ),
        isTrue,
      );
      // The previous copy came along as the backup.
      expect(files.any((String f) => f.endsWith('.bak')), isTrue);
    });

    test('a write racing the first read does not lose the old data', () async {
      final BinaryCodec codec = BinaryCodec(compressor: _NoCompression());
      final _NamingProtector protector = _NamingProtector();
      await FileBinaryStore(
        dir,
        codec: codec,
        protector: protector,
        hiddenNamePrefixes: const <String>{},
      ).write('ledger/index', _bytes(30));
      final FileBinaryStore fresh = FileBinaryStore(
        dir,
        codec: codec,
        protector: protector,
      );
      final List<Uint8List?> reads = await Future.wait(<Future<Uint8List?>>[
        fresh.read('ledger/index'),
        fresh.read('ledger/index'),
      ]);
      expect(reads[0], _bytes(30));
      expect(reads[1], _bytes(30));
    });
  });

  group('file size limit', () {
    late Directory dir;

    setUp(() async {
      ZenStorageHealth.instance.clear();
      dir = await Directory.systemTemp.createTemp('zen_size_limit');
    });

    tearDown(() async {
      ZenStorageHealth.instance.clear();
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test(
      'warns well before the cap and clears when the file shrinks',
      () async {
        final _NoCompression compressor = _NoCompression();
        final FileBinaryStore store = FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: compressor, maxPayloadBytes: 800),
          maxFileBytes: 1000,
        );

        await store.write('dating/state', _bytes(100));
        expect(ZenStorageHealth.instance.hasWarning, isFalse);

        await store.write('dating/state', _bytes(500));
        expect(
          ZenStorageHealth.instance.fillOf('dating/state'),
          StorageFill.warn,
        );
        expect(
          ZenStorageHealth.instance.fillOfPrefix('dating/'),
          StorageFill.warn,
        );
        expect(ZenStorageHealth.instance.warnings.single.category, 'dating');

        compressor.levels.clear();
        await store.write('dating/state', _bytes(780));
        expect(
          ZenStorageHealth.instance.fillOf('dating/state'),
          StorageFill.critical,
        );
        // Close to the cap: a harder compression level was tried.
        expect(compressor.levels, contains(kZenBinaryHeavyCompressionLevel));
        expect(await store.read('dating/state'), _bytes(780));

        await store.write('dating/state', _bytes(100));
        expect(ZenStorageHealth.instance.hasWarning, isFalse);
      },
    );

    test('flags a payload over the cap before refusing it', () async {
      final FileBinaryStore store = FileBinaryStore(
        dir,
        codec: BinaryCodec(compressor: _NoCompression(), maxPayloadBytes: 800),
        maxFileBytes: 1000,
      );
      await expectLater(
        () => store.write('meet/state', _bytes(900)),
        throwsFormatException,
      );
      expect(ZenStorageHealth.instance.worst, StorageFill.full);
    });

    test('the health notifies listeners only when a level changes', () {
      final ZenStorageHealth health = ZenStorageHealth();
      int calls = 0;
      health.addListener(() => calls++);
      health.record('a/b', bytes: 60, limit: 100);
      health.record('a/b', bytes: 62, limit: 100);
      expect(calls, 1);
      health.record('a/b', bytes: 80, limit: 100);
      expect(calls, 2);
      health.record('a/b', bytes: 10, limit: 100);
      expect(calls, 3);
      expect(health.hasWarning, isFalse);
    });

    test('old temporary files are swept, fresh ones are left', () async {
      final FileBinaryStore store = FileBinaryStore(
        dir,
        codec: BinaryCodec(compressor: _NoCompression()),
      );
      await store.write('state/x', _bytes(10));
      final File stale = File('${dir.path}/state/x.zenbin.1.2.tmp')
        ..writeAsBytesSync(<int>[1]);
      stale.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 3)),
      );
      final File fresh = File('${dir.path}/state/y.zenbin.3.4.tmp')
        ..writeAsBytesSync(<int>[1]);

      expect(await store.sweepOrphanTemporaries(), 1);
      expect(stale.existsSync(), isFalse);
      expect(fresh.existsSync(), isTrue);
      expect(await store.read('state/x'), _bytes(10));
    });
  });

  group('Windows data folder', () {
    test('the roaming path is re-rooted under the local one', () {
      expect(
        ZenInstance.windowsLocalPathFor(
          r'C:\Users\A\AppData\Roaming\com.example\zen',
          roamingRoot: r'C:\Users\A\AppData\Roaming',
          localRoot: r'C:\Users\A\AppData\Local',
        ),
        r'C:\Users\A\AppData\Local\com.example\zen',
      );
      expect(
        ZenInstance.windowsLocalPathFor(
          r'c:\users\a\appdata\roaming\zen',
          roamingRoot: r'C:\Users\A\AppData\Roaming\',
          localRoot: r'C:\Users\A\AppData\Local',
        ),
        r'C:\Users\A\AppData\Local\zen',
      );
      expect(
        ZenInstance.windowsLocalPathFor(
          r'C:\Users\A\AppData\Roaming2\zen',
          roamingRoot: r'C:\Users\A\AppData\Roaming',
          localRoot: r'C:\Users\A\AppData\Local',
        ),
        isNull,
      );
      expect(
        ZenInstance.windowsLocalPathFor(
          r'D:\portable\zen',
          roamingRoot: r'C:\Users\A\AppData\Roaming',
          localRoot: r'C:\Users\A\AppData\Local',
        ),
        isNull,
      );
      expect(
        ZenInstance.windowsLocalPathFor(
          r'C:\x',
          roamingRoot: null,
          localRoot: r'C:\y',
        ),
        isNull,
      );
    });

    test('roaming data moves to the local folder once', () async {
      final Directory root = await Directory.systemTemp.createTemp('zen_mig');
      addTearDown(() => root.delete(recursive: true));
      final Directory roaming = Directory('${root.path}/Roaming/zen')
        ..createSync(recursive: true);
      File('${roaming.path}/data/a.zenbin')
        ..createSync(recursive: true)
        ..writeAsStringSync('keys');
      final Directory local = Directory('${root.path}/Local/zen');

      final Directory used = await ZenInstance.migrateSupportDirectory(
        roaming: roaming,
        local: local,
      );

      expect(used.path, local.path);
      expect(File('${local.path}/data/a.zenbin').readAsStringSync(), 'keys');
      expect(roaming.existsSync(), isFalse);

      // Second start: the local data stays in use.
      final Directory again = await ZenInstance.migrateSupportDirectory(
        roaming: roaming,
        local: local,
      );
      expect(again.path, local.path);
      expect(File('${local.path}/data/a.zenbin').existsSync(), isTrue);
    });

    test('the secure storage file stays where its plugin reads it', () async {
      final Directory root = await Directory.systemTemp.createTemp('zen_mig');
      addTearDown(() => root.delete(recursive: true));
      final Directory roaming = Directory('${root.path}/Roaming/zen')
        ..createSync(recursive: true);
      File('${roaming.path}/flutter_secure_storage.dat').writeAsStringSync('k');
      File('${roaming.path}/data/a.zenbin')
        ..createSync(recursive: true)
        ..writeAsStringSync('keys');
      final Directory local = Directory('${root.path}/Local/zen');

      await ZenInstance.migrateSupportDirectory(roaming: roaming, local: local);
      await ZenInstance.keepSecureStorageInRoaming(
        roaming: roaming,
        local: local,
      );

      expect(
        File('${roaming.path}/flutter_secure_storage.dat').readAsStringSync(),
        'k',
      );
      expect(File('${local.path}/data/a.zenbin').existsSync(), isTrue);
    });

    test('existing local data wins and roaming is left alone', () async {
      final Directory root = await Directory.systemTemp.createTemp('zen_mig');
      addTearDown(() => root.delete(recursive: true));
      final Directory roaming = Directory('${root.path}/Roaming/zen')
        ..createSync(recursive: true);
      File('${roaming.path}/old.txt').writeAsStringSync('old');
      final Directory local = Directory('${root.path}/Local/zen')
        ..createSync(recursive: true);
      File('${local.path}/new.txt').writeAsStringSync('new');

      final Directory used = await ZenInstance.migrateSupportDirectory(
        roaming: roaming,
        local: local,
      );
      expect(used.path, local.path);
      expect(File('${roaming.path}/old.txt').existsSync(), isTrue);
    });

    test('a fresh install just gets the local folder', () async {
      final Directory root = await Directory.systemTemp.createTemp('zen_mig');
      addTearDown(() => root.delete(recursive: true));
      final Directory used = await ZenInstance.migrateSupportDirectory(
        roaming: Directory('${root.path}/Roaming/zen'),
        local: Directory('${root.path}/Local/zen'),
      );
      expect(used.path, '${root.path}/Local/zen');
      expect(used.existsSync(), isTrue);
    });

    test('when the move fails the roaming folder stays in use', () async {
      final Directory root = await Directory.systemTemp.createTemp('zen_mig');
      addTearDown(() => root.delete(recursive: true));
      final Directory roaming = Directory('${root.path}/Roaming/zen')
        ..createSync(recursive: true);
      File('${roaming.path}/a.txt').writeAsStringSync('a');
      // The local folder would have to live under a regular file.
      final File blocker = File('${root.path}/blocker')..writeAsStringSync('x');
      final Directory used = await ZenInstance.migrateSupportDirectory(
        roaming: roaming,
        local: Directory('${blocker.path}/zen'),
      );
      expect(used.path, roaming.path);
      expect(File('${roaming.path}/a.txt').existsSync(), isTrue);
    });
  });

  group('media only on Wi-Fi', () {
    List<InternetAddress> ip(String a) => <InternetAddress>[InternetAddress(a)];

    test('mobile data alone is metered, Wi-Fi or cable is not', () {
      expect(
        UnmeteredNetwork.classify(<NetInterfaceInfo>[
          NetInterfaceInfo('rmnet_data1', ip('10.1.2.3')),
          NetInterfaceInfo('lo', ip('127.0.0.1')),
        ]),
        isFalse,
      );
      expect(
        UnmeteredNetwork.classify(<NetInterfaceInfo>[
          NetInterfaceInfo('rmnet_data1', ip('10.1.2.3')),
          NetInterfaceInfo('wlan0', ip('192.168.1.5')),
        ]),
        isTrue,
      );
      expect(
        UnmeteredNetwork.classify(<NetInterfaceInfo>[
          NetInterfaceInfo('pdp_ip0', ip('10.1.2.3')),
        ]),
        isFalse,
      );
      expect(
        UnmeteredNetwork.classify(<NetInterfaceInfo>[
          NetInterfaceInfo('pdp_ip0', ip('10.1.2.3')),
          NetInterfaceInfo('en0', ip('192.168.0.9')),
        ]),
        isTrue,
      );
      // Nothing recognisable (or an empty list): never block for good.
      expect(UnmeteredNetwork.classify(const <NetInterfaceInfo>[]), isTrue);
      // A mobile interface without an address is not in use.
      expect(
        UnmeteredNetwork.classify(<NetInterfaceInfo>[
          const NetInterfaceInfo('rmnet0', <InternetAddress>[]),
        ]),
        isTrue,
      );
    });

    test('the cached answer follows the last look', () async {
      List<NetInterfaceInfo> now = <NetInterfaceInfo>[
        NetInterfaceInfo('rmnet0', ip('10.0.0.2')),
      ];
      final UnmeteredNetwork network = UnmeteredNetwork(
        lister: () async => now,
        isMobile: true,
      );
      expect(network.onUnmetered, isFalse); // not looked yet
      await network.refresh();
      expect(network.onUnmetered, isFalse);
      now = <NetInterfaceInfo>[NetInterfaceInfo('wlan0', ip('192.168.1.2'))];
      await network.refresh();
      expect(network.onUnmetered, isTrue);
    });

    test('a computer is always unmetered', () {
      expect(UnmeteredNetwork(isMobile: false).onUnmetered, isTrue);
    });

    test('a failing lookup does not block media for good', () async {
      final UnmeteredNetwork network = UnmeteredNetwork(
        lister: () async => throw const SocketException('no'),
        isMobile: true,
      );
      await network.refresh();
      expect(network.onUnmetered, isTrue);
    });

    test('the setting is on for new installs, off for older files', () {
      expect(const AppSettings().mediaOnlyOnWifi, isTrue);
      expect(
        AppSettings.fromJson(<String, dynamic>{}).mediaOnlyOnWifi,
        isFalse,
      );
      final AppSettings round = AppSettings.fromJson(
        const AppSettings(mediaOnlyOnWifi: false).toJson(),
      );
      expect(round.mediaOnlyOnWifi, isFalse);
      expect(
        AppSettings.fromJson(const AppSettings().toJson()).mediaOnlyOnWifi,
        isTrue,
      );
    });

    test('auto download needs the switch and, on Wi-Fi-only, Wi-Fi', () {
      const AppSettings wifiOnly = AppSettings();
      expect(wifiOnly.allowsAutoDownload(onUnmetered: true), isTrue);
      expect(wifiOnly.allowsAutoDownload(onUnmetered: false), isFalse);
      const AppSettings anywhere = AppSettings(mediaOnlyOnWifi: false);
      expect(anywhere.allowsAutoDownload(onUnmetered: false), isTrue);
      const AppSettings off = AppSettings(autoDownloadMedia: false);
      expect(off.allowsAutoDownload(onUnmetered: true), isFalse);
    });
  });

  group('expiring clipboard', () {
    test('clears what it copied, but not something copied later', () async {
      final _FakeClipboard board = _FakeClipboard();
      final ExpiringClipboard clip = ExpiringClipboard(
        access: board,
        isInForeground: () => true,
      );
      await clip.copy('code-1', ttl: const Duration(milliseconds: 30));
      expect(board.text, 'code-1');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(board.text, '');
      expect(clip.pendingText, isNull);

      await clip.copy('code-2', ttl: const Duration(milliseconds: 30));
      board.text = 'something else';
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(board.text, 'something else');
    });

    test('a newer copy restarts the clock', () async {
      final _FakeClipboard board = _FakeClipboard();
      final ExpiringClipboard clip = ExpiringClipboard(
        access: board,
        isInForeground: () => true,
      );
      await clip.copy('a', ttl: const Duration(milliseconds: 30));
      await clip.copy('b', ttl: const Duration(milliseconds: 200));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(board.text, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(board.text, '');
    });

    test('in the background it waits for the app to come back', () async {
      final _FakeClipboard board = _FakeClipboard()..readable = false;
      bool foreground = false;
      final ExpiringClipboard clip = ExpiringClipboard(
        access: board,
        isInForeground: () => foreground,
      );
      await clip.copy('secret', ttl: const Duration(milliseconds: 20));
      board.text = 'secret';
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(board.text, 'secret');
      expect(clip.pendingText, 'secret');

      board.readable = true;
      foreground = true;
      clip.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(board.text, '');
      expect(clip.pendingText, isNull);
    });

    test('clearNow wipes the copied text at once', () async {
      final _FakeClipboard board = _FakeClipboard();
      final ExpiringClipboard clip = ExpiringClipboard(
        access: board,
        isInForeground: () => true,
      );
      await clip.copy('k');
      await clip.clearNow();
      expect(board.text, '');
    });
  });
}
