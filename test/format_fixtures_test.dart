import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/account/account_archive.dart';
import 'package:zen/src/features/account/account_copy.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/account_state_sync.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/neighbors/flat_model.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';
import 'package:zen/src/features/update/release.dart';

/// Samples of every stored and sent format as 1.12.0 wrote them, read by
/// the current build. Once released, a format is a promise: phones keep
/// files for years, people keep backups, stickers hang on doors, and older
/// builds keep talking to newer ones.
///
/// The samples are written once, by the 1.12.0 release build (a run of
/// this test outside CI writes the missing ones; in CI a missing one
/// fails), and committed. After that they are never edited or written
/// again; a later build that cannot read one has broken a promise. A new
/// format adds its own sample (a new test here).
const String _dir = 'test/fixtures/formats/1.12.0';

final bool _writeMissing =
    Platform.environment['ZEN_WRITE_FORMAT_FIXTURES'] == '1' ||
    !Platform.environment.containsKey('CI');

const int _at = 1790000000000;

/// The sample [name], written by [make] when it is missing and writing is
/// on (never otherwise, never over an existing one).
Future<Map<String, dynamic>> _sample(
  String name,
  Future<Map<String, dynamic>> Function() make,
) async {
  final File file = File('$_dir/$name.json');
  if (!file.existsSync()) {
    if (!_writeMissing) {
      fail(
        'No 1.12.0 sample of "$name". Write the samples once with the '
        'release build (flutter test test/format_fixtures_test.dart outside '
        'CI) and commit test/fixtures/formats/1.12.0.',
      );
    }
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
        'format': name,
        'written': '1.12.0',
        ...await make(),
      }),
    );
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

final class _Plain implements BinaryCompressor {
  const _Plain();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}

Future<Directory> _temp() async {
  final Directory dir = await Directory.systemTemp.createTemp('zen-format-');
  addTearDown(() => dir.delete(recursive: true));
  return dir;
}

FileBinaryStore _store(Directory dir) =>
    FileBinaryStore(dir, codec: BinaryCodec(compressor: const _Plain()));

/// Every key stored in [dir] (a store without hidden names) with its
/// payload, base64.
Future<Map<String, String>> _payloads(Directory dir) async {
  final BinaryCodec codec = BinaryCodec(compressor: const _Plain());
  final Map<String, String> out = <String, String>{};
  await for (final FileSystemEntity e in dir.list(recursive: true)) {
    if (e is! File || !e.path.endsWith('.zenbin')) {
      continue;
    }
    final String relative = e.path.substring(
      dir.path.length + 1,
      e.path.length - '.zenbin'.length,
    );
    final String key = relative
        .split(Platform.pathSeparator)
        .map(Uri.decodeComponent)
        .join('/');
    out[key] = base64.encode(await codec.decode(await e.readAsBytes()));
  }
  return out;
}

/// A fresh store holding the payloads of [sample] (`files`).
Future<FileBinaryStore> _restored(Map<String, dynamic> sample) async {
  final FileBinaryStore store = _store(await _temp());
  final Map<String, dynamic> files = sample['files'] as Map<String, dynamic>;
  for (final MapEntry<String, dynamic> e in files.entries) {
    await store.write(e.key, base64.decode(e.value as String));
  }
  return store;
}

final String _ada = PeerShareCodec.normalizeAddress('200::d1');

void main() {
  group('stored formats of 1.12.0 still open', () {
    test('friends (social/hub)', () async {
      final Map<String, dynamic> sample = await _sample('friends', () async {
        final Directory dir = await _temp();
        await FileSocialSnapshotStore(store: _store(dir)).save(
          SocialHubState(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 3,
              capturedAtMillis: _at,
            ),
            friends: <String, FriendProfile>{
              _ada: FriendProfile(
                address: _ada,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
                unreadCount: 2,
              ),
            },
            inbox: const <InboxEntry>[
              InboxEntry(
                id: 'i1',
                type: InboxEntryType.message,
                title: 'Ada',
                body: 'Hej',
                createdAtMillis: _at,
              ),
            ],
            pendingSignalCount: 0,
            backgroundAlerts: const <InboxEntry>[],
            peerAppVersions: <String, String>{_ada: '1.12.0'},
          ),
        );
        return <String, dynamic>{'files': await _payloads(dir)};
      });
      final SocialHubState? state = await FileSocialSnapshotStore(
        store: await _restored(sample),
      ).load();
      final FriendProfile ada = state!.friends[_ada]!;
      expect(ada.displayName, 'Ada');
      expect(ada.status, FriendRelationshipStatus.accepted);
      expect(ada.unreadCount, 2);
      expect(state.inbox.single.body, 'Hej');
      expect(state.peerAppVersions[_ada], '1.12.0');
    });

    test('conversations (threads)', () async {
      final Map<String, dynamic> sample = await _sample('chats', () async {
        final Directory dir = await _temp();
        await FileMessageTimelineStore(
          store: _store(dir),
        ).save(_ada, <ChatMessage>[
          ChatMessage(
            id: 'm1',
            sender: _ada,
            text: 'Hej',
            sentAtMillis: _at,
            direction: ChatMessageDirection.incoming,
            deliveryState: ChatMessageDeliveryState.delivered,
          ),
          const ChatMessage(
            id: 'm2',
            sender: 'me',
            text: 'Cześć',
            sentAtMillis: _at + 1000,
            direction: ChatMessageDirection.outgoing,
            deliveryState: ChatMessageDeliveryState.sent,
          ),
        ]);
        return <String, dynamic>{'files': await _payloads(dir)};
      });
      final List<ChatMessage> thread = await FileMessageTimelineStore(
        store: await _restored(sample),
      ).load(_ada);
      expect(thread.map((ChatMessage m) => m.text), <String>['Hej', 'Cześć']);
      expect(thread.last.deliveryState, ChatMessageDeliveryState.sent);
      expect(thread.first.direction, ChatMessageDirection.incoming);
    });

    test('settings', () async {
      final Map<String, dynamic> sample = await _sample('settings', () async {
        final Directory dir = await _temp();
        await FileAppSettingsStore(
          store: _store(dir),
        ).save(const AppSettings(themeMode: AppThemeMode.dark));
        return <String, dynamic>{'files': await _payloads(dir)};
      });
      final AppSettings? settings = await FileAppSettingsStore(
        store: await _restored(sample),
      ).load();
      expect(settings?.themeMode, AppThemeMode.dark);
    });

    test('signals waiting to be handled (signals/pending)', () async {
      final Map<String, dynamic> sample = await _sample('queue', () async {
        final Directory dir = await _temp();
        await FileSignalQueueStore(store: _store(dir)).save(<QueuedSignal>[
          QueuedSignal(
            id: 'q1',
            signal: ZenSignal(
              type: ZenSignalType.message,
              sender: _ada,
              messageId: 'm1',
              content: 'Hej',
            ),
            receivedAtMillis: _at,
          ),
        ]);
        return <String, dynamic>{'files': await _payloads(dir)};
      });
      final List<QueuedSignal> queue = await FileSignalQueueStore(
        store: await _restored(sample),
      ).load();
      expect(queue.single.signal.type, ZenSignalType.message);
      expect(queue.single.signal.content, 'Hej');
    });

    test('the outbox and held mail (relay/…)', () async {
      final Map<String, dynamic> sample = await _sample('relay', () async {
        final Directory dir = await _temp();
        await FileRelayStateStore(store: _store(dir)).save(
          RelayState(
            identity: await RelayIdentity.generate(),
            outbox: <String, RelayOutboxEntry>{
              'r1': RelayOutboxEntry(
                rid: 'r1',
                recipient: _ada,
                payload: <String, dynamic>{
                  'type': 'message',
                  'text': 'x' * (kRelayInlinePayloadChars + 1),
                },
                createdAtMillis: _at,
                expiresAtMillis: _at + 1000,
                relayable: false,
              ),
              'r2': RelayOutboxEntry(
                rid: 'r2',
                recipient: _ada,
                payload: const <String, dynamic>{
                  'type': 'message',
                  'text': 'Hej',
                },
                createdAtMillis: _at,
                expiresAtMillis: _at + 1000,
                relayable: true,
              ),
            },
            mailbox: <String, Map<String, Map<String, dynamic>>>{
              _ada: <String, Map<String, dynamic>>{
                'e1': <String, dynamic>{'id': 'e1', 'b': 'AAAA'},
              },
            },
          ),
        );
        return <String, dynamic>{'files': await _payloads(dir)};
      });
      final RelayState state = await FileRelayStateStore(
        store: await _restored(sample),
      ).load();
      expect(state.identity, isNotNull);
      expect(
        (state.outbox['r1']!.payload['text'] as String).length,
        kRelayInlinePayloadChars + 1,
      );
      expect(state.outbox['r2']!.payload['text'], 'Hej');
      expect(state.mailbox[_ada]!['e1']!['b'], 'AAAA');
    });

    test('the ledger (index, certificates, segments, file lists)', () async {
      final Map<String, dynamic> sample = await _sample('ledger', () async {
        final MemoryLedgerDisk disk = MemoryLedgerDisk();
        final LedgerArchive archive = LedgerArchive(disk: disk, segmentSize: 3);
        final LedgerStore store = LedgerStore(
          clock: HlcClock(wallClock: () => _at),
        );
        final BlobStore blobs = BlobStore(backend: DiskBlobChunkBackend(disk));
        await archive.open(store, blobs);
        final LedgerAccountSetup setup = await LedgerAccountSetup.create();
        final LedgerAuthor author = LedgerAuthor(
          deviceKey: setup.deviceKey,
          certificate: setup.certificate,
          store: store,
        );
        final String space = accountSpace('feed', author.account);
        for (int i = 0; i < 5; i++) {
          await author.append(space, 'post', <String, dynamic>{'n': i});
        }
        final LogEntry checkpoint = await author.checkpoint(space);
        await author.append(space, 'post', <String, dynamic>{'n': 5});
        store.pruneBefore(space, author.writer, checkpoint.seq);
        final String blob = await blobs.put(
          Uint8List.fromList(List<int>.generate(3000, (int i) => i % 251)),
          mime: 'image/jpeg',
        );
        await archive.flush();
        return <String, dynamic>{
          'space': space,
          'writer': author.writer,
          'blob': blob,
          'files': <String, String>{
            for (final MapEntry<String, Uint8List> e in disk.files.entries)
              e.key: base64.encode(e.value),
          },
        };
      });
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      (sample['files'] as Map<String, dynamic>).forEach((String k, dynamic v) {
        disk.files[k] = base64.decode(v as String);
      });
      final LedgerStore store = LedgerStore(
        clock: HlcClock(wallClock: () => _at),
      );
      final BlobStore blobs = BlobStore(backend: DiskBlobChunkBackend(disk));
      final LedgerArchive archive = LedgerArchive(disk: disk, segmentSize: 3);
      await archive.open(store, blobs);
      final String space = sample['space'] as String;
      final String writer = sample['writer'] as String;
      expect(store.headOf(space, writer), 7);
      expect(store.baseOf(space, writer).base, 5);
      expect(store.entries(space).first.kind, kLedgerCheckpointKind);
      expect(await blobs.read(sample['blob'] as String), hasLength(3000));
      expect(archive.incompleteLogs, isEmpty);
    });

    test('a backup file (.zenbackup)', () async {
      const PasswordCost light = PasswordCost(memoryKiB: 64, iterations: 1);
      final Map<String, dynamic> sample = await _sample('zenbackup', () async {
        final Uint8List data = Uint8List.fromList(utf8.encode('{"f":1}'));
        final String id = (AccountHasher()..add(data)).close();
        final BytesBuilder out = BytesBuilder();
        await AccountBackupFile.write(
          archive: AccountArchive(
            account: 'acc-1',
            createdAt: _at,
            scope: const <AccountScope>{AccountScope.settings},
            sections: const <String, Object?>{
              CircleBackupSections.settings: <String, Object?>{'theme': 'dark'},
            },
            raw: <String, String>{'films/state': id},
            files: <String, int>{id: data.length},
          ),
          blobs: <String, AccountArchiveBlob>{
            id: AccountArchiveBlob.bytes(data),
          },
          password: 'hasło próbne 1',
          cost: light,
          out: (Uint8List bytes) async => out.add(bytes),
        );
        return <String, dynamic>{
          'password': 'hasło próbne 1',
          'file': base64.encode(out.takeBytes()),
        };
      });
      final Map<String, Uint8List> files = <String, Uint8List>{};
      final ({AccountArchive? archive, AccountBackupError? error}) read =
          await AccountBackupFile.read(
            chunks: Stream<List<int>>.value(
              base64.decode(sample['file'] as String),
            ),
            password: sample['password'] as String,
            acceptedCosts: const <PasswordCost>[light],
            file: (String id, int size) async =>
                _Collect((Uint8List bytes) => files[id] = bytes),
          );
      expect(read.error, isNull);
      expect(read.archive!.account, 'acc-1');
      expect(
        (read.archive!.sections[CircleBackupSections.settings]!
            as Map)['theme'],
        'dark',
      );
      expect(utf8.decode(files[read.archive!.raw['films/state']]!), '{"f":1}');
    });

    test('a copy at the recovery circle', () async {
      final Map<String, dynamic> sample = await _sample('circle', () async {
        final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
          MemoryLedgerDisk(),
        );
        final CircleBackupBuild build = await buildCircleBackup(
          content: const CircleBackupContent(
            sections: <String, Object?>{
              CircleBackupSections.profile: <String, Object?>{
                'displayName': 'Ola',
              },
            },
          ),
          account: me.account,
          selfKey: me.selfKey!,
          deviceKey: me.deviceKey,
          certificate: me.certificate,
          at: _at,
        );
        return <String, dynamic>{
          'account': me.account,
          'selfKey': b64(me.selfKey!),
          'manifest': build.manifest.json,
          'chunks': <String, String>{
            for (final MapEntry<String, Uint8List> e in build.chunks.entries)
              e.key: base64.encode(e.value),
          },
        };
      });
      final CircleBackupManifest manifest = CircleBackupManifest.parse(
        sample['manifest'],
      )!;
      final CircleBackupOpened opened = await openCircleBackup(
        manifest: manifest,
        chunks: <String, Uint8List>{
          for (final MapEntry<String, dynamic> e
              in (sample['chunks'] as Map<String, dynamic>).entries)
            e.key: base64.decode(e.value as String),
        },
        account: sample['account'] as String,
        selfKey: unb64(sample['selfKey'], length: 32)!,
      );
      expect(opened.error, isNull);
      expect(
        (opened.content!.sections[CircleBackupSections.profile]!
            as Map)['displayName'],
        'Ola',
      );
    });
  });

  group('sent and printed formats of 1.12.0 are still read', () {
    test('a door sticker (QR and link)', () async {
      final Map<String, dynamic> sample = await _sample('sticker', () async {
        final FlatDoorCode door = FlatDoorCode(
          key: base64Url.encode(List<int>.filled(32, 7)),
          door: 'abc',
          inbox: _ada,
          name: 'Nowakowie, m. 12',
        );
        return <String, dynamic>{'qr': door.toQr(), 'link': door.toLink()};
      });
      for (final String text in <String>[
        sample['qr'] as String,
        sample['link'] as String,
      ]) {
        final FlatDoorCode? door = FlatDoorCode.parse(text);
        expect(door?.name, 'Nowakowie, m. 12', reason: text);
        expect(door?.inbox, _ada, reason: text);
      }
    });

    test('an invitation link', () async {
      final Map<String, dynamic> sample = await _sample('invite', () async {
        return <String, dynamic>{
          'link': PeerShareCodec.buildLocalProfile(address: _ada)!.qrData,
        };
      });
      final String link = sample['link'] as String;
      expect(PeerShareCodec.inviteCodeFromLink(link), isNotNull);
      expect(PeerShareCodec.parseTarget(link).address, _ada);
    });

    test('an account copy code', () async {
      final Map<String, dynamic> sample = await _sample(
        'copy_ticket',
        () async {
          return <String, dynamic>{
            'ticket': AccountCopyTicket(
              address: _ada,
              key: Uint8List.fromList(List<int>.filled(32, 3)),
              token: Uint8List.fromList(List<int>.filled(16, 4)),
            ).encode(),
          };
        },
      );
      expect(
        AccountCopyTicket.parse(sample['ticket'] as String)?.address,
        _ada,
      );
    });

    test('a release manifest', () async {
      final Map<String, dynamic> sample = await _sample('release', () async {
        return <String, dynamic>{
          'manifest': ReleaseManifest(
            version: '1.12.0',
            build: 12,
            publishedAt: _at,
            files: <ReleaseFile>[
              ReleaseFile(
                platform: 'android',
                name: 'Zen.apk',
                size: 1000,
                blob: 'a' * 64,
                sha256: 'b' * 64,
              ),
            ],
          ).toJson(),
        };
      });
      final ReleaseManifest? manifest = ReleaseManifest.fromJson(
        sample['manifest'],
      );
      expect(manifest?.fileFor('android')?.name, 'Zen.apk');
      // Signed as written: read back, it encodes to the same bytes.
      expect(
        canonicalJson(manifest!.toJson()),
        canonicalJson(sample['manifest']),
      );
    });

    test('a ping/pong greeting', () async {
      final Map<String, dynamic> sample = await _sample('hello', () async {
        return <String, dynamic>{'hello': versionHello()};
      });
      final PeerVersion? hello = PeerVersion.fromPayload(
        sample['hello'] as Map<String, dynamic>,
      );
      expect(hello, isNotNull);
      expect(hello!.minVersion, isNotNull);
      expect(hello.caps, contains('ledger1'));
    });

    test('settings sent to the account\'s other devices', () async {
      final Map<String, dynamic> sample = await _sample('sync_units', () async {
        // What [AccountStateSync] publishes for a changed setting, exactly
        // as the build sends it (its units, not the settings' own keys).
        final _Channel out = _Channel(
          <Map<String, dynamic>>[],
          device: 'dev-a',
        );
        final AccountStateSync sender = AccountStateSync(
          channel: out,
          disk: MemoryLedgerDisk(),
          domains: <AccountSyncDomain>[_Domain('dark')],
          delay: const Duration(milliseconds: 1),
          scanEvery: const Duration(hours: 1),
        );
        await sender.start();
        await sender.idle;
        await sender.stop();
        return <String, dynamic>{'body': out.published.single};
      });
      final _Domain domain = _Domain();
      final AccountStateSync sync = AccountStateSync(
        channel: _Channel(<Map<String, dynamic>>[
          sample['body'] as Map<String, dynamic>,
        ]),
        disk: MemoryLedgerDisk(),
        domains: <AccountSyncDomain>[domain],
        delay: const Duration(milliseconds: 1),
        scanEvery: const Duration(hours: 1),
      );
      await sync.start();
      await sync.idle;
      expect(domain.state['theme'], 'dark');
      await sync.stop();
    });
  });
}

/// Collects one file of a backup.
final class _Collect implements AccountFileWriter {
  _Collect(this.done);

  final void Function(Uint8List bytes) done;
  final BytesBuilder _out = BytesBuilder(copy: false);

  @override
  Future<void> add(Uint8List chunk) async => _out.add(chunk);

  @override
  Future<void> close() async => done(_out.takeBytes());
}

final class _Domain implements AccountSyncDomain {
  _Domain([String theme = 'light']) : state = <String, Object?>{'theme': theme};

  Map<String, Object?> state;

  @override
  String get id => 'settings';

  @override
  Set<String> get wholeKeys => const <String>{};

  @override
  Future<Map<String, Object?>?> read() async =>
      Map<String, Object?>.from(state);

  @override
  Future<void> write(Map<String, Object?> next) async {
    state = Map<String, Object?>.from(next);
  }

  @override
  Stream<void> get changes => const Stream<void>.empty();
}

final class _Channel implements AccountSyncChannel {
  _Channel(this.sent, {this.device = 'dev-b'});

  final List<Map<String, dynamic>> sent;

  /// What this device sent.
  final List<Map<String, dynamic>> published = <Map<String, dynamic>>[];

  @override
  final String device;

  @override
  bool get hasOtherDevices => true;

  @override
  Iterable<Map<String, dynamic>> existing() => sent;

  @override
  Stream<Map<String, dynamic>> get incoming =>
      const Stream<Map<String, dynamic>>.empty();

  @override
  Stream<void> get devicesChanged => const Stream<void>.empty();

  @override
  Future<bool> publish(Map<String, dynamic> body) async {
    published.add(body);
    return true;
  }
}
