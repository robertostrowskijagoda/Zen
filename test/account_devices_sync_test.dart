import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/account/account_media.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<_Linked> _transport(String address) async {
  final _Linked t = _Linked(_a(address));
  _Linked.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(
  _Linked t, {
  MemoryLedgerDisk? disk,
  List<String> friends = const <String>[],
  List<String> greet = const <String>[],
}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    friendAddresses: () => friends,
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    greetAlso: () => greet,
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

/// The social layer as the sync sees it.
final class _Target implements ChatSyncTarget {
  final Map<String, List<ChatMessage>> chats = <String, List<ChatMessage>>{};
  final Map<String, Uint8List> files = <String, Uint8List>{};
  final List<String> forgottenFriends = <String>[];
  final List<String> leftGroups = <String>[];

  @override
  List<String> conversationKeys() => chats.keys.toList();

  @override
  Future<List<ChatMessage>> conversationMessages(String key) async =>
      chats[key] ?? const <ChatMessage>[];

  @override
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
    String? storedPath,
  }) async {
    final List<ChatMessage> list = chats[key] ??= <ChatMessage>[];
    if (!list.any((ChatMessage m) => m.id == message.id)) {
      list.add(message);
    }
    if (bytes != null) {
      files[message.id] = bytes;
    }
  }

  @override
  Future<void> forgetFriendFromOtherDevice(
    String address, {
    int atMillis = 0,
  }) async => forgottenFriends.add(address);

  @override
  Future<void> forgetGroupFromOtherDevice(String groupId) async =>
      leftGroups.add(groupId);
}

/// Mobile data or Wi-Fi, as the test says.
final class _Policy implements AccountMediaPolicy {
  bool allowed = true;

  @override
  Future<bool> mayFetchNow() async => allowed;
}

ChatMessage _text(String id, String text) => ChatMessage(
  id: id,
  sender: 'self',
  text: text,
  sentAtMillis: 1000,
  direction: ChatMessageDirection.outgoing,
  deliveryState: ChatMessageDeliveryState.delivered,
);

void main() {
  setUp(_Linked.nodes.clear);

  test('a linked device gets the history, copies, and removals', () async {
    final String a1 = _a('200::a1');
    final String a2 = _a('200::a2');
    final String b = _a('200::b');
    final _Linked t1 = await _transport(a1);
    final _Linked t2 = await _transport(a2);
    final _Linked tb = await _transport(b);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    final LedgerNode first = _node(t1, disk: d1, friends: <String>[b]);
    final LedgerNode bob = _node(tb, friends: <String>[a1]);
    await first.start();
    await bob.start();

    final _Target firstChats = _Target();
    firstChats.chats[b] = <ChatMessage>[
      _text('m1', 'cześć'),
      ChatMessage(
        id: 'm2',
        sender: b,
        text: '',
        sentAtMillis: 2000,
        direction: ChatMessageDirection.incoming,
        type: ChatMessageType.image,
        fileName: 'kot.jpg',
        mimeType: 'image/jpeg',
        attachmentBytes: Uint8List.fromList(<int>[1, 2, 3, 4, 5]),
      ),
    ];
    final DeviceChatSync firstSync = DeviceChatSync(
      node: first,
      target: firstChats,
    );
    await firstSync.start();
    addTearDown(firstSync.stop);

    // Link the second device.
    final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
    await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
    final LedgerNode second = _node(t2, disk: d2);
    await second.start();
    final _Target secondChats = _Target();
    final DeviceChatSync secondSync = DeviceChatSync(
      node: second,
      target: secondChats,
    );
    await secondSync.start();
    addTearDown(secondSync.stop);
    await second.rememberDeviceAddresses(<String>[a1]);
    await _settle(200);
    await firstSync.idle;
    await _settle(200);
    await secondSync.idle;

    expect(
      secondChats.chats[b]?.map((ChatMessage m) => m.id),
      containsAll(<String>['m1', 'm2']),
      reason: 'the history came over',
    );
    expect(secondChats.files['m2'], <int>[1, 2, 3, 4, 5]);

    // What the first device sends from now on is copied, with its file.
    firstSync.onOutgoing(
      b,
      ChatMessage(
        id: 'm3',
        sender: 'self',
        text: 'zdjęcie',
        sentAtMillis: 3000,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.image,
        attachmentBytes: Uint8List.fromList(<int>[9, 9]),
      ),
    );
    await _settle(200);
    await secondSync.idle;
    expect(secondChats.files['m3'], <int>[9, 9]);

    // A friend removed on the first device goes on the second too.
    await first.publishForOwnDevices(kContactRemovedKind, <String, dynamic>{
      'a': b,
    }, spaceKind: 'private');
    await first.publishForOwnDevices(kContactRemovedKind, <String, dynamic>{
      'g': 'g1',
    }, spaceKind: 'private');
    await _settle(120);
    await secondSync.idle;
    expect(secondChats.forgottenFriends, <String>[b]);
    expect(secondChats.leftGroups, <String>['g1']);
    expect(second.contactRemovals().keys, containsAll(<String>[b, 'group:g1']));

    // The friend never gets the chat copies (only the sealed contacts).
    expect(bob.store.entries(accountSpace('own', first.account)), isEmpty);
  });

  test(
    'a hello with someone else\'s certificate does not make a device',
    () async {
      final String a = _a('200::a');
      final String b = _a('200::b');
      final String x = _a('200::666');
      final _Linked ta = await _transport(a);
      final _Linked tb = await _transport(b);
      final _Linked tx = await _transport(x);
      final LedgerNode ania = _node(ta, friends: <String>[b]);
      final LedgerNode bob = _node(tb, friends: <String>[a]);
      await ania.start();
      await bob.start();
      await _settle();
      // The attacker copies Ania's hello (certificate and proof) and sends it
      // from its own address.
      final Map<String, dynamic> hers = ta.sentSignals
          .lastWhere((s) => s.payload['type'] == kLedgerHelloType)
          .payload;
      await tx.send(remoteAddress: b, payload: hers);
      await _settle();
      expect(bob.accountOfAnyAddress(x), isNull);
      expect(bob.addressesOfAccount(ania.account), <String>[a]);
    },
  );

  test('a group member\'s devices are recognised as that member', () async {
    final String me = _a('200::1');
    final String x1 = _a('200::21');
    final String x2 = _a('200::22');
    final _Linked tm = await _transport(me);
    final _Linked t1 = await _transport(x1);
    final _Linked t2 = await _transport(x2);
    final MemoryLedgerDisk dx1 = MemoryLedgerDisk();
    final MemoryLedgerDisk dx2 = MemoryLedgerDisk();
    final LedgerNode mine = _node(tm, greet: <String>[x1]);
    final LedgerNode first = _node(t1, disk: dx1, greet: <String>[me]);
    await mine.start();
    await first.start();
    final LedgerIdentity idx = await LedgerIdentity.loadOrCreate(dx1);
    await LedgerIdentity.adoptAccount(dx2, idx.accountKey!.seed);
    final LedgerNode second = _node(t2, disk: dx2, greet: <String>[me]);
    await second.start();
    await _settle();
    expect(mine.accountOfAnyAddress(x1), first.account);
    expect(mine.accountOfAnyAddress(x2), first.account);
    expect(mine.anyAddressesOf(first.account), containsAll(<String>[x1, x2]));
  });

  group('social hub', () {
    late ProviderContainer container;
    late SocialHubController hub;
    late Directory dir;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('zen-sync-');
      container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          supportDirectoryResolverProvider.overrideWithValue(() async => dir),
        ],
      );
      hub = container.read(socialHubControllerProvider.notifier);
      await hub.whenHydrated;
    });

    tearDown(() {
      container.dispose();
      dir.deleteSync(recursive: true);
    });

    test('a copy that lacks a removal known here is answered with this '
        "device's own; one that agrees is not", () async {
      final String ola = _a('200::7');
      final Map<String, dynamic> listing = <String, dynamic>{
        'v': 1,
        'friends': <Object>[
          <String, dynamic>{'a': ola, 'n': 'Ola'},
        ],
        'groups': <Object>[],
      };
      await hub.importContactsBackup(listing);
      expect(hub.contactsBackupBehind(hub.contactsBackup()), isFalse);
      await hub.removeFriend(peerAddress: ola);
      // Another device saved later, still listing Ola (as Zen 1.14.0 does,
      // or a newer one that has not heard of the removal yet).
      expect(hub.contactsBackupBehind(listing), isTrue);
      await hub.importContactsBackup(listing, backupAt: 1 << 50);
      expect(
        container.read(socialHubControllerProvider).friendByAddress(ola),
        isNull,
      );
      expect(hub.contactsBackupBehind(hub.contactsBackup()), isFalse);
    });

    test(
      'the newest backup renames, blocks, adds — not what was removed',
      () async {
        final String ola = _a('200::7');
        final String ewa = _a('200::8');
        final String gone = _a('200::9');
        await hub.importContactsBackup(<String, dynamic>{
          'v': 1,
          'friends': <Object>[
            <String, dynamic>{'a': ola, 'n': 'Ola'},
          ],
          'groups': <Object>[],
        }, backupAt: 10);
        await hub.importContactsBackup(
          <String, dynamic>{
            'v': 1,
            'friends': <Object>[
              <String, dynamic>{
                'a': ola,
                'n': 'Ola K.',
                'k': 'Ola z pracy',
                'b': 1,
              },
              <String, dynamic>{'a': ewa, 'n': 'Ewa'},
              <String, dynamic>{'a': gone, 'n': 'Usunięty'},
            ],
            'groups': <Object>[
              <String, dynamic>{
                'id': 'g1',
                'name': 'Rodzina',
                'm': <String>[ola],
              },
              <String, dynamic>{'id': 'g2', 'name': 'Stara', 'm': <String>[]},
            ],
          },
          removedAt: <String, int>{gone: 30, 'group:g2': 30},
          backupAt: 20,
        );
        final SocialHubState s = container.read(socialHubControllerProvider);
        expect(s.friendByAddress(ola)?.displayName, 'Ola K.');
        expect(s.friendByAddress(ola)?.nickname, 'Ola z pracy');
        expect(
          s.friendByAddress(ola)?.status,
          FriendRelationshipStatus.blocked,
        );
        expect(s.friendByAddress(ewa), isNotNull);
        expect(s.friendByAddress(gone), isNull, reason: 'removed later');
        expect(s.groups.keys, <String>['g1']);
        expect(contactsBackupOf(s)['friends'], hasLength(2));
        expect(
          (contactsBackupOf(s)['friends'] as List<Map<String, dynamic>>)
              .firstWhere((Map<String, dynamic> f) => f['a'] == ola)['k'],
          'Ola z pracy',
        );

        await hub.forgetFriendFromOtherDevice(ewa);
        await hub.forgetGroupFromOtherDevice('g1');
        final SocialHubState after = container.read(
          socialHubControllerProvider,
        );
        expect(after.friendByAddress(ewa), isNull);
        expect(after.groups, isEmpty);
      },
    );

    test('messages from other devices land once, files saved', () async {
      final String ola = _a('200::7');
      final ChatMessage m = ChatMessage(
        id: 'x1',
        sender: 'self',
        text: '',
        sentAtMillis: 5,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.file,
        fileName: 'plan.pdf',
      );
      await hub.importSyncedMessage(ola, m);
      await hub.importSyncedMessage(
        ola,
        m,
        bytes: Uint8List.fromList(<int>[7, 7, 7]),
      );
      final List<ChatMessage> list = await hub.conversationMessages(ola);
      expect(list, hasLength(1));
      // Kept encrypted, under a name that says nothing.
      expect(isMediaVaultPath(list.single.attachmentPath), isTrue);
      expect(list.single.attachmentPath, isNot(contains('plan')));
      expect(
        await container
            .read(mediaVaultProvider)
            .read(list.single.attachmentPath!),
        <int>[7, 7, 7],
      );
    });
  });

  test(
    'the timeline store reports what this device sends, once complete',
    () async {
      final SyncingMessageTimelineStore store = SyncingMessageTimelineStore(
        MemoryMessageTimelineStore(),
      );
      final List<String> reported = <String>[];
      store.onNewOutgoing = (String peer, ChatMessage m) => reported.add(m.id);
      await store.append('p', _text('t1', 'hej'));
      final ChatMessage photo = ChatMessage(
        id: 'f1',
        sender: 'self',
        text: '',
        sentAtMillis: 1,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.image,
      );
      await store.append('p', photo);
      expect(reported, <String>['t1'], reason: 'the photo is not in yet');
      await store.save('p', <ChatMessage>[
        _text('t1', 'hej'),
        photo.copyWith(attachmentPath: '/x/y.jpg'),
      ]);
      await store.save('p', <ChatMessage>[
        _text('t1', 'hej'),
        photo.copyWith(attachmentPath: '/x/y.jpg'),
      ]);
      expect(reported, <String>['t1', 'f1']);
      // Incoming messages are not reported.
      await store.append(
        'p',
        ChatMessage(
          id: 'in',
          sender: 'p',
          text: 'x',
          sentAtMillis: 2,
          direction: ChatMessageDirection.incoming,
        ),
      );
      expect(reported, hasLength(2));
    },
  );

  test('over mobile data a big file waits, the message does not', () async {
    final String a1 = _a('200::c1');
    final String a2 = _a('200::c2');
    final _Linked t1 = await _transport(a1);
    final _Linked t2 = await _transport(a2);
    final MemoryLedgerDisk d1 = MemoryLedgerDisk();
    final MemoryLedgerDisk d2 = MemoryLedgerDisk();
    final LedgerNode first = _node(t1, disk: d1);
    await first.start();
    final _Target firstChats = _Target();
    final DeviceChatSync firstSync = DeviceChatSync(
      node: first,
      target: firstChats,
    );
    await firstSync.start();
    addTearDown(firstSync.stop);

    final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
    await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
    final LedgerNode second = _node(t2, disk: d2);
    await second.start();
    final _Policy policy = _Policy()..allowed = false;
    final _Target secondChats = _Target();
    final DeviceChatSync secondSync = DeviceChatSync(
      node: second,
      target: secondChats,
      policy: policy,
      fileWait: const Duration(seconds: 5),
    );
    await secondSync.start();
    addTearDown(secondSync.stop);
    await second.rememberDeviceAddresses(<String>[a1]);
    await _settle(200);

    // A film of 700 KB: several pieces of the file store.
    final Uint8List film = Uint8List.fromList(
      List<int>.generate(700 * 1024, (int i) => i % 251),
    );
    firstSync.onOutgoing(
      'group:g1',
      ChatMessage(
        id: 'v1',
        sender: 'self',
        text: '',
        sentAtMillis: 5000,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.video,
        mimeType: 'video/mp4',
        attachmentBytes: film,
      ),
    );
    await _settle(200);
    await secondSync.idle;
    expect(
      secondChats.chats['group:g1']?.map((ChatMessage m) => m.id),
      contains('v1'),
      reason: 'the message is there at once',
    );
    expect(secondChats.files['v1'], isNull);
    expect(await secondSync.waitingFiles(), 1);

    // On Wi-Fi: the file comes.
    policy.allowed = true;
    await secondSync.retryWaitingFiles();
    await _settle(100);
    expect(secondChats.files['v1'], film);
    expect(await secondSync.waitingFiles(), 0);
  });
}
