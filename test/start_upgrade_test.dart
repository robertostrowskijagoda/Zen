import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/shell/composer_drafts.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/start_harness.dart';

/// Every release leaves an account written by its own code in
/// `test/fixtures/upgrade/<version>` (docs/TESTING.md, "Upgrade fixtures"):
/// friends, a group, messages, a queued signal, notifications, presence,
/// the profile, the relay state, posts in the ledger, drafts and the
/// settings, sealed under a test password. The current build must start on
/// each of them within a bounded time, unlock it and find everything.
///
/// Then every file a start reads is damaged in turn (emptied, cut short,
/// overwritten with garbage, given a format version from the future): the
/// app must still start, never hang and never need its data wiped.
const String _fixtures = 'test/fixtures/upgrade';

List<Directory> _fixtureFolders() {
  final Directory root = Directory(_fixtures);
  if (!root.existsSync()) {
    return const <Directory>[];
  }
  final List<Directory> found = root.listSync().whereType<Directory>().toList()
    ..sort((Directory a, Directory b) => a.path.compareTo(b.path));
  return found;
}

Map<String, dynamic> _manifest(Directory fixture) =>
    jsonDecode(File('${fixture.path}/fixture.json').readAsStringSync())
        as Map<String, dynamic>;

String _nameOf(Directory folder) => folder.path.split(RegExp(r'[/\\]')).last;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(ZenStartTrace.debugReset);
  tearDown(() {
    ZenInstance.debugSetBaseDirectory(null);
    ZenStartTrace.debugReset();
  });

  final List<Directory> fixtures = _fixtureFolders();

  test('there is a fixture of every released version since 1.12.1', () {
    expect(
      fixtures.map(_nameOf),
      containsAll(<String>['1.12.1', '1.13.1', '1.14.0']),
    );
    for (final Directory fixture in fixtures) {
      int bytes = 0;
      for (final FileSystemEntity e in fixture.listSync(recursive: true)) {
        if (e is File) {
          bytes += e.lengthSync();
        }
      }
      // Kept small: a few dozen kilobytes each.
      expect(bytes, lessThan(256 * 1024), reason: _nameOf(fixture));
    }
  });

  for (final Directory fixture in fixtures) {
    final String version = _nameOf(fixture);
    test('Zen $version data: the current build starts on it, unlocks it and '
        'shows everything', () async {
      final Map<String, dynamic> manifest = _manifest(fixture);
      final Directory folder = copyFixture(
        Directory('${fixture.path}/account'),
        'zen-upgrade-$version-',
      );
      addTearDown(() => deleteQuietly(folder));
      final MapSecrets secrets = MapSecrets(readSecrets(fixture));
      final Stopwatch watch = Stopwatch()..start();

      final HarnessStart start = await startZenOn(folder, secrets: secrets);

      // The first screen: the lock screen of an account with a password.
      expect(start.result.appSecurityService.hasPassword, isTrue);
      expect(start.result.appSecurityService.isLocked, isTrue);
      expect(start.result.initialSettings.themeMode, AppThemeMode.dark);
      expect(start.result.initialSettings.autoCleanupDays, 9);
      expect(
        await start.result.appSecurityService.unlock(
          manifest['password'] as String,
        ),
        isTrue,
      );

      expect(await start.result.stores.signalQueueStore.load(), hasLength(1));

      final (ProviderContainer container, SocialHubState hub) =
          await hydrateHub(start.result);
      addTearDown(container.dispose);
      expect(hub.snapshotUnreadable, isFalse);
      final List<String> friends = (manifest['friends'] as List<dynamic>)
          .cast<String>();
      for (final String address in friends) {
        expect(
          hub.friendByAddress(address)?.status,
          FriendRelationshipStatus.accepted,
          reason: address,
        );
      }
      expect(
        hub.friendByAddress(manifest['pending'] as String)?.status,
        FriendRelationshipStatus.pendingIncoming,
      );
      expect(hub.groups.keys, contains(manifest['group']));
      expect(
        hub.inbox.map((InboxEntry e) => e.id),
        containsAll(<String>['inbox-1', 'inbox-2']),
      );

      final stores = start.result.stores;
      final List<ChatMessage> withA = await stores.messageTimelineStore.load(
        friends.first,
      );
      expect(withA, hasLength(manifest['messagesWithA']));
      expect(
        await stores.messageTimelineStore.load('group:${manifest['group']}'),
        hasLength(1),
      );
      // The signal queued before the update was read and taken by the
      // hydration (its flush), not left behind or dropped unread.
      expect(await stores.signalQueueStore.load(), isEmpty);
      expect(
        (await stores.groupStore.load()).keys,
        contains(manifest['group']),
      );
      expect((await stores.userProfileStore.load())?.displayName, 'Fixture');
      expect((await stores.relayStateStore.load()).currentRelays, friends);

      final LedgerStore ledger = LedgerStore(clock: HlcClock());
      await LedgerArchive(disk: stores.ledgerDisk).open(
        ledger,
        BlobStore(backend: DiskBlobChunkBackend(stores.ledgerDisk)),
      );
      expect(
        ledger.entries(manifest['space'] as String).length,
        greaterThanOrEqualTo(manifest['posts'] as int),
      );

      final ComposerDrafts drafts = ComposerDrafts(stores.ledgerDisk);
      await drafts.load();
      if (version.compareTo('1.14.0') >= 0) {
        expect(
          drafts[ComposerDrafts.peerChat(friends.first)]?.text,
          'Niewysłana wiadomość',
        );
        expect(drafts[ComposerDrafts.newPost]?.text, 'Szkic posta');
      }
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
    });
  }

  group('a damaged file never stops the start', () {
    final Directory? newest = fixtures.isEmpty ? null : fixtures.last;
    if (newest == null) {
      return;
    }
    final Directory account = Directory('${newest.path}/account');
    final List<String> files = <String>[
      for (final FileSystemEntity e in account.listSync(recursive: true))
        if (e is File)
          e.path.substring(account.path.length + 1).replaceAll('\\', '/'),
    ]..sort();
    final String password = _manifest(newest)['password'] as String;

    for (final String file in files) {
      for (final _Damage damage in _Damage.values) {
        test('${damage.name} $file', () async {
          final Directory folder = copyFixture(account, 'zen-damaged-');
          addTearDown(() => deleteQuietly(folder));
          final File target = File('${folder.path}/$file');
          damage.apply(target);
          // Its backup too, where there is one: nothing to fall back on.
          final File backup = File('${target.path}.bak');
          if (backup.existsSync()) {
            damage.apply(backup);
          }
          await _startsAndOpens(folder, newest, password);
          if (file.startsWith('settings/') && damage != _Damage.newerVersion) {
            // Set aside, not deleted; the next start is a normal one.
            expect(
              folder
                  .listSync(recursive: true)
                  .where((FileSystemEntity e) => e.path.contains('.damaged-')),
              isNotEmpty,
            );
            ZenStartTrace.debugReset();
            await _startsAndOpens(folder, newest, password);
          }
          if (file.startsWith('settings/') && damage == _Damage.newerVersion) {
            // A newer build's file is kept exactly as it is.
            expect(target.readAsBytesSync()[4], 0x7F);
          }
        });
      }
    }
  });
}

/// Starts on [folder] and opens the account within bounded times; every
/// store the first screens read answers (with data or an error the app
/// handles), none hangs.
Future<void> _startsAndOpens(
  Directory folder,
  Directory fixture,
  String password,
) async {
  final HarnessStart start = await startZenOn(
    folder,
    secrets: MapSecrets(readSecrets(fixture)),
  );
  expect(start.result.appSecurityService.isReady, isTrue);
  expect(await start.result.appSecurityService.unlock(password), isTrue);
  final (ProviderContainer container, SocialHubState _) = await hydrateHub(
    start.result,
  );
  container.dispose();
  final stores = start.result.stores;
  const Duration bound = Duration(seconds: 10);
  Future<void> answers(Future<Object?> Function() read) async {
    try {
      await read().timeout(bound);
    } on TimeoutException {
      fail('A store did not answer within ${bound.inSeconds} s.');
    } on Object {
      // An unreadable store is the store's caller's to handle.
    }
  }

  await answers(() => stores.signalQueueStore.load());
  await answers(() => stores.groupStore.load());
  await answers(() => stores.userProfileStore.load());
  await answers(() => stores.relayStateStore.load());
  await answers(
    () => stores.messageTimelineStore.load(
      '201:1111:2222:3333:4444:5555:6666:7777',
    ),
  );
  await answers(() => ComposerDrafts(stores.ledgerDisk).load());
  await answers(
    () => LedgerArchive(disk: stores.ledgerDisk).open(
      LedgerStore(clock: HlcClock()),
      BlobStore(backend: DiskBlobChunkBackend(stores.ledgerDisk)),
    ),
  );
}

enum _Damage {
  empty,
  truncated,
  garbage,
  newerVersion;

  void apply(File file) {
    final Uint8List bytes = file.readAsBytesSync();
    switch (this) {
      case _Damage.empty:
        file.writeAsBytesSync(const <int>[]);
      case _Damage.truncated:
        file.writeAsBytesSync(bytes.sublist(0, bytes.length ~/ 2));
      case _Damage.garbage:
        final Random random = Random(bytes.length);
        file.writeAsBytesSync(<int>[
          for (int i = 0; i < bytes.length; i++) random.nextInt(256),
        ]);
      case _Damage.newerVersion:
        // The format version of a plain envelope (byte 4); in a sealed
        // file the same place of its own header.
        if (bytes.length > 4) {
          bytes[4] = 0x7F;
        }
        file.writeAsBytesSync(bytes);
    }
  }
}
