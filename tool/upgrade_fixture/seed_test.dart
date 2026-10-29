// Writes the upgrade fixture of this checkout's version: an account made
// by the app's own code (friends, a group, messages, a queued signal,
// notifications, presence, the profile, the relay state, posts in the
// ledger, drafts and the settings, sealed under a test password with test
// keys only), as test/start_upgrade_test.dart reads it.
//
// Run it in a checkout of the release's tag, then copy the folder into
// test/fixtures/upgrade/<version> of the current tree (docs/TESTING.md,
// "Upgrade fixtures"):
//
//   ZEN_FIXTURE_OUT=<folder> flutter test tool/upgrade_fixture/seed_test.dart
//
// A newer release that changes what is stored adds it here as well.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/shell/composer_drafts.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const String friendA = '201:1111:2222:3333:4444:5555:6666:7777';
const String friendB = '202:aaaa:bbbb:cccc:dddd:eeee:ffff:1234';
const String pending = '203:1234:5678:9abc:def0:1234:5678:9abc';
const String password = 'fixture-password';
const int at = 1790000000000;

/// The test machines have no zstd library: envelopes are stored
/// uncompressed (a form the app writes too, when compressing does not help).
final class PassThroughCompressor implements BinaryCompressor {
  const PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => null;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}

final BinaryCodec codec = BinaryCodec(
  compressor: const PassThroughCompressor(),
);

final class DumpedSecrets implements AppSecurityCredentialsStore {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

FriendProfile friend(String address, String name, int n) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
  isOnline: true,
  lastPresenceAtMillis: at - n * 60000,
  lastMessagePreview: 'Wiadomość $n',
  lastActivityLabel: 'Teraz',
  unreadCount: n,
  presence: n.isOdd ? PeerPresence.online : PeerPresence.background,
  presenceAtMillis: at - n * 60000,
);

void main() {
  final String? target = Platform.environment['ZEN_FIXTURE_OUT'];
  test(
    'seed an upgrade fixture',
    skip: target == null
        ? 'Set ZEN_FIXTURE_OUT to the folder to write.'
        : false,
    () async {
      final String out = target!;
      final Directory dir = Directory(out);
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      final Directory account = Directory('$out/account')
        ..createSync(recursive: true);
      final DumpedSecrets secrets = DumpedSecrets();
      final LocalAppSecurityService security = LocalAppSecurityService(
        credentialsStore: secrets,
        passwordIterations: 1,
      );
      await security.initialize(settings: const AppSettings());
      await security.setPassword(password);

      final AppSettingsStore settingsStore =
          buildZenAppSettingsStoreForDirectory(
            account,
            codec: codec,
            secrets: secrets,
          );
      await settingsStore.save(
        const AppSettings(
          palette: AppPalette.blueprint,
          themeMode: AppThemeMode.dark,
          autoCleanupDays: 9,
          setupRevision: 3,
          permissionsSetupDone: true,
          accountSecureOffered: true,
          legalAcceptedVersion: 'fixture',
          legalAcceptedAtMillis: at,
          inAppSounds: false,
          mutedNotices: <NoticeKind>{NoticeKind.message},
        ),
      );

      final ZenPersistentStores stores = buildZenPersistentStoresForDirectory(
        account,
        codec: codec,
        dataProtector: EncryptedBinaryPayloadProtector(security),
        appSettingsStore: settingsStore,
      );
      final GroupProfile group = GroupProfile(
        id: 'group-fixture',
        name: 'Sąsiedzi',
        createdById: friendA,
        createdAtMillis: at,
        memberAddresses: const <String>[friendA, friendB],
        lastMessagePreview: 'Cześć wszystkim',
      );
      await stores.socialSnapshotStore.save(
        SocialHubState.empty().copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
              friendA: friend(friendA, 'Ada', 1),
              friendB: friend(friendB, 'Bartek', 2),
              pending: const FriendProfile(
                address: pending,
                displayName: 'Celina',
                status: FriendRelationshipStatus.pendingIncoming,
                requestMessage: 'Hej, to ja',
              ),
            },
          ),
          groups: <String, GroupProfile>{group.id: group},
          inbox: <InboxEntry>[
            const InboxEntry(
              id: 'inbox-1',
              type: InboxEntryType.friendRequest,
              title: 'Zaproszenie',
              body: 'Celina chce dołączyć',
              createdAtMillis: at,
              peerAddress: pending,
            ),
            const InboxEntry(
              id: 'inbox-2',
              type: InboxEntryType.message,
              title: 'Ada',
              body: 'Wiadomość 1',
              createdAtMillis: at + 1,
              peerAddress: friendA,
            ),
            const InboxEntry(
              id: 'inbox-3',
              type: InboxEntryType.mailbox,
              title: 'Skrzynka',
              body: 'Skrzynka nie odpowiada',
              createdAtMillis: at + 2,
            ),
            const InboxEntry(
              id: 'inbox-4',
              type: InboxEntryType.storage,
              title: 'Miejsce',
              body: 'Zen przekroczył limit',
              createdAtMillis: at + 3,
            ),
          ],
        ),
      );
      await stores.groupStore.save(<String, GroupProfile>{group.id: group});
      await stores.messageTimelineStore.save(friendA, <ChatMessage>[
        for (int i = 0; i < 6; i++)
          ChatMessage(
            id: 'a-$i',
            sender: i.isEven ? friendA : 'me',
            text: 'Wiadomość $i z Adą',
            sentAtMillis: at + i * 1000,
            direction: i.isEven
                ? ChatMessageDirection.incoming
                : ChatMessageDirection.outgoing,
          ),
      ]);
      await stores.messageTimelineStore.save('group:${group.id}', <ChatMessage>[
        const ChatMessage(
          id: 'g-1',
          sender: friendB,
          text: 'Cześć wszystkim',
          sentAtMillis: at,
          direction: ChatMessageDirection.incoming,
        ),
      ]);
      await stores.signalQueueStore.save(<QueuedSignal>[
        const QueuedSignal(
          id: 'q-1',
          signal: ZenSignal(
            type: ZenSignalType.message,
            sender: friendB,
            messageId: 'b-queued',
            content: 'Czekająca wiadomość',
          ),
          receivedAtMillis: at,
        ),
      ]);
      await stores.userProfileStore.save(
        const UserProfile(
          displayName: 'Fixture',
          customStatus: 'Na spacerze',
          bio: 'Konto testowe',
          updatedAtMillis: at,
        ),
      );
      await stores.relayStateStore.save(
        RelayState(
          currentRelays: <String>[friendA, friendB],
          relaySetVersion: 2,
          seen: <String, int>{'seen-1': at},
        ),
      );

      final LedgerArchive archive = LedgerArchive(disk: stores.ledgerDisk);
      final LedgerStore ledger = LedgerStore(
        clock: HlcClock(wallClock: () => at),
      );
      final BlobStore blobs = BlobStore(
        backend: DiskBlobChunkBackend(stores.ledgerDisk),
      );
      await archive.open(ledger, blobs);
      final LedgerAccountSetup setup = await LedgerAccountSetup.create();
      final LedgerAuthor author = LedgerAuthor(
        deviceKey: setup.deviceKey,
        certificate: setup.certificate,
        store: ledger,
      );
      final String space = accountSpace('feed', author.account);
      for (int i = 0; i < 4; i++) {
        await author.append(space, 'post', <String, dynamic>{
          'text': 'Post $i',
          'n': i,
        });
      }
      await archive.flush();
      final ComposerDrafts drafts = ComposerDrafts(stores.ledgerDisk);
      await drafts.load();
      drafts.put(
        ComposerDrafts.peerChat(friendA),
        const ComposerDraft(text: 'Niewysłana wiadomość'),
      );
      drafts.put(
        ComposerDrafts.newPost,
        const ComposerDraft(text: 'Szkic posta'),
      );
      await drafts.flush();

      final Map<String, int> sizes = <String, int>{};
      for (final FileSystemEntity e in account.listSync(recursive: true)) {
        if (e is File) {
          sizes[e.path
              .substring(account.path.length + 1)
              .replaceAll('\\', '/')] = e
              .lengthSync();
        }
      }
      File('$out/secure_storage.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(secrets.values),
      );
      File('$out/fixture.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(<String, Object>{
          'written': kAppVersion,
          'password': password,
          'space': space,
          'posts': 4,
          'friends': <String>[friendA, friendB],
          'pending': pending,
          'group': 'group-fixture',
          'messagesWithA': 6,
          'files': sizes,
        }),
      );
      expect(sizes, isNotEmpty);
      // ignore: avoid_print
      print(
        'Wrote ${sizes.length} files, '
        '${sizes.values.fold<int>(0, (int a, int b) => a + b)} bytes.',
      );
    },
  );
}
