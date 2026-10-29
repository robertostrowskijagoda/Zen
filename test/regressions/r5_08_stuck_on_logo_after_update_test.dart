// Owner report R5-#8 (28.10.2026, after 1.14.0): after the update to 1.14 the app stayed on the logo until its data was wiped.
//
// docs/TESTING.md, "Field report -> regression test": the test that fails
// while the bug is there and passes once it is fixed replaces the skipped
// one below, under the same name prefix; skip only while the fix is not in.
//
// Fixed in the start (every step bounded and logged, the node's calls off
// the UI thread, secure storage that does not answer no longer waited for:
// guarded_settings_store.dart, f5b9d873) and in the Go bridge (R5-F4);
// guarded by the tests below, test/start_upgrade_test.dart (every release's
// data), test/start_watchdog_test.dart and test/guarded_settings_store_test.dart.
//
// Found meanwhile by test/persistence_fuzz_test.dart: a damaged ledger file
// (an archive part, the keys, the identity) threw out of LedgerNode._start
// (the store reports a seal that no longer opens as
// SecretBoxAuthenticationError, which no loader caught), so posts, profiles
// and the account's devices stayed off for the session, and FollowLedger
// left the error unhandled (follows.dart, `_ready = _start()`).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/guarded_settings_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import '../support/damaged_files.dart';
import '../support/start_harness.dart';

/// Secure storage that never answers (the Keystore after an update).
final class _SilentSecrets implements AppSecurityCredentialsStore {
  @override
  Future<String?> read(String key) => Completer<String?>().future;

  @override
  Future<void> write(String key, String value) => Completer<void>().future;

  @override
  Future<void> delete(String key) => Completer<void>().future;
}

/// The upgrade fixtures were written on Windows and are read only there
/// (test/start_upgrade_test.dart, `writtenElsewhere`).
final Object _fixturesWrittenElsewhere = Platform.isWindows
    ? false
    : 'The upgrade fixtures were written on Windows, whose hidden file names '
          'come from keys folded to lower case.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() {
    ZenInstance.debugSetBaseDirectory(null);
    ZenStartTrace.debugReset();
  });

  test(
    'R5-#8: the app starts after an update on the data the old version left',
    () async {
      final List<Directory> fixtures =
          Directory(
              'test/fixtures/upgrade',
            ).listSync().whereType<Directory>().toList()
            ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
      expect(fixtures, isNotEmpty);
      for (final Directory fixture in fixtures) {
        final Map<String, dynamic> manifest =
            jsonDecode(File('${fixture.path}/fixture.json').readAsStringSync())
                as Map<String, dynamic>;
        final Directory folder = copyFixture(
          Directory('${fixture.path}/account'),
          'zen-r5-08-upgrade-',
        );
        addTearDown(() => deleteQuietly(folder));
        ZenStartTrace.debugReset();
        final HarnessStart start = await startZenOn(
          folder,
          secrets: MapSecrets(readSecrets(fixture)),
        );
        expect(start.result.appSecurityService.isLocked, isTrue);
        expect(
          await start.result.appSecurityService.unlock(
            manifest['password'] as String,
          ),
          isTrue,
          reason: fixture.path,
        );
        final (ProviderContainer container, SocialHubState hub) =
            await hydrateHub(start.result);
        container.dispose();
        expect(hub.snapshotUnreadable, isFalse, reason: fixture.path);
        expect(hub.friends, isNotEmpty, reason: fixture.path);
      }
    },
    skip: _fixturesWrittenElsewhere,
  );

  test('R5-#8: secure storage that does not answer after the update never '
      'holds the start on the logo', () {
    // The settings are the first step of the start; the Keystore can stop
    // answering after an update or a restore, and the start waited on it.
    fakeAsync((FakeAsync async) {
      final GuardedAppSettingsStore settings = GuardedAppSettingsStore(
        inner: MemoryAppSettingsStore(
          const AppSettings(
            lockMode: AppLockMode.background,
            autoCleanupDays: 4,
          ),
        ),
        secrets: _SilentSecrets(),
      );
      AppSettings? loaded;
      settings.load().then((AppSettings? value) => loaded = value);
      async.elapse(const Duration(seconds: 30));
      expect(loaded?.autoCleanupDays, 4);
      expect(loaded?.lockMode, AppLockMode.background);
    });
  });

  late Directory root;
  late FileBinaryStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('zen-r5-08-');
    store = sealedStore(root);
    DamagedIdentityNotice.instance.clear();
  });

  tearDown(() async {
    DamagedIdentityNotice.instance.clear();
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Windows keeps a file open a moment longer.
    }
  });

  Future<LedgerNode> node() async {
    final MemorySignalTransport transport = MemorySignalTransport();
    await transport.start();
    final LedgerNode n = LedgerNode(
      transport: transport,
      disk: FileLedgerDisk(store),
      friendAddresses: () => const <String>[],
    );
    addTearDown(n.stop);
    return n;
  }

  test('R5-#8: a damaged archive part or key file is set aside and the '
      'ledger starts with the rest', () async {
    final LedgerNode first = await node();
    await first.start();
    await first.publish('post', <String, dynamic>{'text': 'Pierwszy'});
    await first.archive.flush();
    final String account = first.account;
    final List<String> damaged = <String>[
      for (final (String space, String writer, int _, bool _)
          in first.store.logs)
        LedgerArchive.logKeyOf(space, writer, 0),
      LedgerArchive.certificatesKeyOf(account),
      LedgerArchive.revocationsKey,
    ];
    await first.stop();
    for (final String key in damaged) {
      if (await store.read(key) != null) {
        await damageStored(store, key);
      }
    }

    final LedgerNode again = await node();
    await again.start();

    expect(again.isReady, isTrue);
    expect(again.account, account, reason: 'the same account goes on');
    final LogEntry post = await again.publish('post', <String, dynamic>{
      'text': 'Drugi',
    });
    expect(post.account, account);
    expect(setAsideUnder(root), isNotEmpty);
  });

  test('R5-#8: a damaged identity is never replaced by a new account; the '
      'ledger stays off with a notice and nothing is left unhandled', () async {
    final LedgerIdentity original = await LedgerIdentity.loadOrCreate(
      FileLedgerDisk(store),
    );
    final File file = await damageStored(store, LedgerIdentity.storageKey);
    final Uint8List damagedBytes = file.readAsBytesSync();
    final FileLedgerDisk disk = FileLedgerDisk(store);

    expect(await LedgerIdentity.exists(disk), isTrue);
    expect(await LedgerIdentity.read(disk), isNull);
    await expectLater(
      LedgerIdentity.loadOrCreate(disk),
      throwsA(isA<DamagedLedgerIdentityException>()),
    );

    final List<Object> unhandled = <Object>[];
    final Completer<void> done = Completer<void>();
    runZonedGuarded(
      () async {
        final LedgerNode n = await node();
        // Attached as the app does: its start in the background.
        FollowLedger.of(n);
        await expectLater(
          n.start(),
          throwsA(isA<DamagedLedgerIdentityException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        done.complete();
      },
      (Object error, StackTrace _) {
        unhandled.add(error);
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );
    await done.future;

    expect(unhandled, isEmpty);
    expect(DamagedIdentityNotice.instance.damaged, isTrue);
    // Kept as it was: the account key is in it and nowhere else.
    expect(file.readAsBytesSync(), damagedBytes);
    expect(original.account, isNotEmpty);
  });

  test('R5-#8: an identity whose account key still reads becomes a new '
      'device of the same account', () async {
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    final LedgerIdentity original = await LedgerIdentity.loadOrCreate(disk);
    final Map<String, dynamic> json =
        jsonDecode(utf8.decode(disk.files[LedgerIdentity.storageKey]!))
            as Map<String, dynamic>;
    json['cert'] = 'damaged';
    await disk.write(
      LedgerIdentity.storageKey,
      Uint8List.fromList(utf8.encode(jsonEncode(json))),
    );

    final LedgerIdentity recovered = await LedgerIdentity.loadOrCreate(disk);

    expect(recovered.account, original.account);
    expect(recovered.deviceKey.id, isNot(original.deviceKey.id));
  });
}
