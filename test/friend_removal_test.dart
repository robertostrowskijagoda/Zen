import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_presence.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

import 'support/friends_world.dart';

/// A friend removed stays removed: whatever they (or the app's own queues,
/// the locked service, the account's other devices) still send afterwards,
/// only a new invitation brings them back, as an invitation.

FriendRelationshipStatus? _statusOf(FriendsPhone on, FriendsPhone peer) =>
    on.state.friendByAddress(peer.address)?.status;

/// [p]'s app comes on the screen (what it kept for this moment is replayed).
Future<void> _toScreen(FriendsPhone p, FriendsWorld w) => p.hub.setLifecycle(
  LifecycleSnapshot(
    visibility: AppVisibilityState.foregroundFocused,
    generation: 1000 + w.now % 1000,
    capturedAtMillis: w.now,
  ),
);

/// What [from] sends [to] as a friend would, whether [to] still has them or
/// not: a message, its profile, a ping, and an old acceptance sent again.
Future<void> _friendlyTraffic(
  FriendsWorld w,
  FriendsPhone from,
  FriendsPhone to,
) async {
  await w.send(from, to, 'Hej, jesteś?');
  await from.hub.shareOwnProfileWith(to.address);
  await from.container
      .read(signalTransportProvider)
      .send(
        remoteAddress: to.address,
        payload: <String, dynamic>{
          'type': 'ping',
          ...presenceFields(own: PeerPresence.online),
        },
      );
  await from.container
      .read(signalTransportProvider)
      .send(
        remoteAddress: to.address,
        payload: const <String, dynamic>{
          'type': 'friend_accept',
          'senderName': 'Bartek',
        },
      );
  await w.settle();
}

void main() {
  _lockTests();
  group('a removed friend stays removed', () {
    test(
      'coming back to the screen replays nothing that brings them back',
      () async {
        final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
        final FriendsPhone a = w['A'];
        final FriendsPhone b = w['B'];
        // A's app was in the background when B accepted: B's acceptance
        // waits in A's queue for the app's return.
        await a.hub.removeFriend(peerAddress: b.address);
        await w.settle();
        expect(_statusOf(a, b), isNull);

        await _toScreen(a, w);
        await w.settle();
        expect(_statusOf(a, b), isNull, reason: 'not even as an invitation');
        expect(a.state.inbox.where((e) => e.peerAddress == b.address), isEmpty);
      },
    );

    test('what they send while the app is locked leaves them removed, and '
        'rings nothing', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      // B is away: the removal reaches them only later, so meanwhile they
      // still write as a friend.
      await w.setOnline(b, false);
      await a.hub.removeFriend(peerAddress: b.address);
      await w.lock(a);
      await w.setOnline(b, true);
      await _friendlyTraffic(w, b, a);
      await w.deliver();
      expect(
        a.messageNotices,
        isEmpty,
        reason: 'nothing from a removed friend',
      );

      await w.unlock(a);
      await w.deliver();
      await _toScreen(a, w);
      await w.settle();
      expect(_statusOf(a, b), isNull);
      expect(await a.textsFrom(b), isEmpty);
      expect(a.messageNotices, isEmpty);
    });

    test('mail their messages left in the mailboxes rings nothing; a '
        "friend's mail names the friend", () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B', 'C']);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      final FriendsPhone c = w['C'];
      await w.chooseMailboxes(a, <FriendsPhone>[c]);
      await w.setOnline(b, false);
      await a.hub.removeFriend(peerAddress: b.address);
      await w.setOnline(a, false);
      await w.setOnline(b, true);
      // A is away: what B and C write waits in A's mailbox (C).
      await w.send(b, a, 'Odezwij się');
      await w.send(c, a, 'Kolacja o 19?');
      await w.lock(a);
      final int before = a.notices.posted.length;
      await w.setOnline(a, true);
      await w.deliver();
      final List<RuntimeSystemNotification> told = a.notices.posted
          .skip(before)
          .toList();
      expect(told, hasLength(1), reason: 'one notice: C');
      expect(told.single.title, 'C', reason: 'whose mail it is');
      expect('${told.single.title} ${told.single.body}', isNot(contains('B')));

      await w.unlock(a);
      await w.deliver();
      expect(_statusOf(a, b), isNull);
      expect(await a.textsFrom(b), isEmpty);
      expect(await a.textsFrom(c), contains('Kolacja o 19?'));
    });

    test('a new invitation shows as one, and makes them a friend again once '
        'accepted', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      await a.hub.removeFriend(peerAddress: b.address);
      await w.deliver();
      expect(_statusOf(b, a), isNull, reason: 'B heard of it');

      // B asks again: an invitation, not a friend.
      await b.hub.sendFriendRequest(
        peerAddress: a.address,
        senderDisplayName: 'B',
      );
      await w.deliver();
      expect(_statusOf(a, b), FriendRelationshipStatus.pendingIncoming);
      await a.hub.acceptFriendRequest(
        peerAddress: b.address,
        senderDisplayName: 'A',
      );
      await w.deliver();
      expect(_statusOf(a, b), FriendRelationshipStatus.accepted);
      expect(_statusOf(b, a), FriendRelationshipStatus.accepted);
      expect(a.state.removedFriendAt(b.address), isNull);
      await w.send(b, a, 'Znowu razem');
      await w.assertDelivered(a, 'Znowu razem', from: b);

      // Removed once more, and A invites this time.
      await a.hub.removeFriend(peerAddress: b.address);
      await w.deliver();
      await w.befriend(a, b);
      expect(_statusOf(a, b), FriendRelationshipStatus.accepted);
    });
  });

  group("the account's devices agree on a removal", () {
    late Directory dir;
    setUp(() {
      _Linked.nodes.clear();
      _Linked.offline.clear();
      dir = Directory.systemTemp.createTempSync('zen-removal-');
      addTearDown(() {
        try {
          dir.deleteSync(recursive: true);
        } on FileSystemException {
          // Still open on Windows.
        }
      });
    });

    test('a device that still lists the friend does not bring them back, on '
        'either device; a new friendship goes to both', () async {
      final String fred = _a('200::f');
      final String gosia = _a('200::9');
      final _Device phone = await _Device.start('200::a1', dir);
      final _Device desktop = await _Device.start(
        '200::a2',
        dir,
        accountOf: phone,
      );
      await phone.node.rememberDeviceAddresses(<String>[desktop.address]);
      await desktop.node.rememberDeviceAddresses(<String>[phone.address]);
      for (final _Device d in <_Device>[phone, desktop]) {
        await d.seedFriends(<String, String>{fred: 'Fred', gosia: 'Gosia'});
      }
      await desktop.publishContacts();
      await _settle();

      // Removed on the phone; at once the desktop, which has not heard of
      // it yet, saves its copy (a nickname given) — newer than the removal.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      _Linked.offline.add(desktop.address);
      await phone.hub.removeFriend(peerAddress: fred);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await desktop.hub.setFriendNickname(
        peerAddress: gosia,
        nickname: 'Gosia z pracy',
      );
      await desktop.publishContacts();
      await _settle();
      _Linked.offline.clear();
      // Back in reach: hellos go at most once a second.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await phone.node.greetFriends();
      await desktop.node.greetFriends();
      await _settle(200);
      await phone.sync.idle;
      await desktop.sync.idle;

      // The phone takes the newest copy (the desktop's, which still lists
      // Fred and is newer than the removal): Fred stays gone.
      expect(<Object?>[
        for (final Object? f in phone.node.latestContacts()!['friends'] as List)
          (f! as Map<dynamic, dynamic>)['a'],
      ], contains(fred));
      expect(
        phone.node.latestContactsMillis,
        greaterThan(phone.node.contactRemovals()[fred]!),
      );
      await phone.takeContacts();
      expect(phone.friend(fred), isNull);
      expect(phone.friend(gosia)?.nickname, 'Gosia z pracy');
      // The desktop applied the removal and takes the copies too.
      await desktop.takeContacts();
      expect(desktop.friend(fred), isNull);
      // Each saves its copy again; nothing brings Fred back anywhere.
      await phone.publishContacts();
      await _settle();
      await desktop.takeContacts();
      await desktop.publishContacts();
      await _settle();
      await phone.takeContacts();
      expect(phone.friend(fred), isNull);
      expect(desktop.friend(fred), isNull);

      // Invited again from the phone and accepted: a friend on both.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await phone.hub.sendFriendRequest(peerAddress: fred);
      await phone.hub.receiveSignal(
        zenSignalFromTransportPayload(
          sender: fred,
          payload: const <String, dynamic>{
            'type': 'friend_accept',
            'senderName': 'Fred',
          },
        )!,
      );
      expect(phone.friend(fred)?.status, FriendRelationshipStatus.accepted);
      await phone.publishContacts();
      await _settle();
      await desktop.takeContacts();
      expect(desktop.friend(fred)?.status, FriendRelationshipStatus.accepted);
    });
  });

  group('a message notice of the locked service', () {
    for (final (NotificationPrivacy level, String title, String body)
        in <(NotificationPrivacy, String, String)>[
          (NotificationPrivacy.senderAndContent, 'B', 'Hej, o 18?'),
          (NotificationPrivacy.senderOnly, 'B', 'Nowa wiadomość'),
          (
            NotificationPrivacy.generic,
            'Nowa wiadomość',
            'Odblokuj Zen, żeby przeczytać.',
          ),
        ]) {
      test(
        'follows "${level.name}", whoever sends it (an older Zen too)',
        () async {
          final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
          final FriendsPhone a = w['A'];
          final FriendsPhone b = w['B'];
          a.noticePrivacy = level;
          await w.lock(a);
          // As Zen 1.12.1 sends a message: no name in it.
          await _sendRaw(b, a, <String, dynamic>{
            'type': 'message',
            'msgId': 'old-1',
            'text': 'Hej, o 18?',
            'createdAt': DateTime.utc(2026, 10, 28).toIso8601String(),
          });
          await w.deliver();
          final RuntimeSystemNotification notice = a.messageNotices.single;
          expect(notice.title, title);
          expect(notice.body, body);
        },
      );
    }

    test("an older Zen's other frames ring nothing; its message names the "
        'friend', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>['A', 'B']);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      await w.lock(a);
      final int before = a.notices.posted.length;
      List<RuntimeSystemNotification> told() =>
          a.notices.posted.skip(before).toList();
      // What a friend on Zen 1.12.1 / 1.13.x sends besides messages.
      for (final Map<String, dynamic> frame in <Map<String, dynamic>>[
        <String, dynamic>{'type': 'ping', 'presence': 'online', 'v': '1.12.1'},
        <String, dynamic>{'type': 'away', 'presence': 'background'},
        <String, dynamic>{'type': 'event', 'id': 'ev1', 'title': 'Grill'},
        <String, dynamic>{'type': 'intent', 'id': 'i1'},
        <String, dynamic>{'type': 'ask', 'id': 'q1'},
        <String, dynamic>{'type': 'lg_heads', 'h': 'x'},
        <String, dynamic>{'type': 'profile_update', 'name': 'B'},
        <String, dynamic>{'type': 'message_read', 'msgId': 'x'},
        <String, dynamic>{'type': 'message_ack', 'msgId': 'x'},
        <String, dynamic>{'type': 'typing', 'isTyping': true},
        <String, dynamic>{'type': 'disappear_timer', 'seconds': 0},
      ]) {
        await _sendRaw(b, a, frame);
      }
      await w.deliver();
      expect(told(), isEmpty, reason: 'only messages are told about');

      await _sendRaw(b, a, <String, dynamic>{
        'type': 'message',
        'msgId': 'old-2',
        'text': 'Jestem',
      });
      await w.deliver();
      expect(told().single.title, 'B');
      expect(told().single.body, 'Jestem');

      // After unlock (the app still in the background here) it tells of that
      // message only, by name; none of the other frames rings.
      await w.unlock(a);
      await w.deliver();
      for (final RuntimeSystemNotification n in told()) {
        expect(n.category, RuntimeSystemNotificationCategory.message);
        expect(n.title, 'B');
        expect(n.body, 'Jestem');
      }
      expect(await a.textsFrom(b), contains('Jestem'));
    });
  });
}

/// A snapshot store whose saves fail while the app is "locked" (as the
/// encrypted store does without the key).
final class _LockingSnapshotStore implements SocialSnapshotStore {
  _LockingSnapshotStore(SocialHubState seed)
    : _inner = MemorySocialSnapshotStore(seed);

  final MemorySocialSnapshotStore _inner;
  bool locked = false;

  @override
  Future<SocialHubState?> load() => _inner.load();

  @override
  Future<void> save(SocialHubState state) {
    if (locked) {
      throw StateError(
        'Encrypted storage is always on, but the app is locked.',
      );
    }
    return _inner.save(state);
  }
}

void _lockTests() {
  group('a removal right before the lock', () {
    test('a save that fails under the lock does not let the older copy '
        'bring the friend back at the return to the screen', () async {
      final String fred = _a('200::f');
      final Directory dir = Directory.systemTemp.createTempSync('zen-lock-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final _LockingSnapshotStore store = _LockingSnapshotStore(
        SocialHubState.empty(
          lifecycle: const LifecycleSnapshot(
            visibility: AppVisibilityState.background,
            generation: 1,
            capturedAtMillis: 0,
          ),
        ).copyWith(
          friends: <String, FriendProfile>{
            fred: FriendProfile(
              address: fred,
              displayName: 'Fred',
              status: FriendRelationshipStatus.accepted,
            ),
          },
        ),
      );
      final MemorySignalTransport out = MemorySignalTransport();
      await out.start();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(store),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          signalTransportProvider.overrideWithValue(out),
          supportDirectoryResolverProvider.overrideWithValue(() async => dir),
        ],
      );
      addTearDown(container.dispose);
      final SocialHubController hub = container.read(
        socialHubControllerProvider.notifier,
      );
      await hub.whenHydrated;
      await hub.setLifecycle(
        const LifecycleSnapshot(
          visibility: AppVisibilityState.background,
          generation: 2,
          capturedAtMillis: 1,
        ),
      );
      // The app locks while the removal is being saved.
      store.locked = true;
      await hub.removeFriend(peerAddress: fred);
      store.locked = false;

      await hub.setLifecycle(
        const LifecycleSnapshot(
          visibility: AppVisibilityState.foregroundFocused,
          generation: 3,
          capturedAtMillis: 2,
        ),
      );
      expect(
        container.read(socialHubControllerProvider).friendByAddress(fred),
        isNull,
      );
      expect((await store.load())!.friendByAddress(fred), isNull);
      expect((await store.load())!.removedFriendAt(fred), isNotNull);
    });

    test('what is saved during the lock still seals for a moment; nothing '
        'opens', () async {
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        hasPassword: true,
      );
      expect(await security.currentEncryptionKey(), isNotNull);
      security.lock();
      expect(await security.currentEncryptionKey(), isNull);
      expect(await security.currentSealingKey(), isNotNull);
      await Future<void>.delayed(
        kLockWriteGrace + const Duration(milliseconds: 50),
      );
      expect(await security.currentSealingKey(), isNull);
    });
  });
}

/// [from] sends [payload] to [to] reliably, as an older Zen built it.
Future<void> _sendRaw(
  FriendsPhone from,
  FriendsPhone to,
  Map<String, dynamic> payload,
) => from.transport.send(remoteAddress: to.address, payload: payload);

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// The account's devices on one in-memory link.
final class _Linked extends MemorySignalTransport {
  _Linked(this.address);

  static final Map<String, _Linked> nodes = <String, _Linked>{};

  /// Devices nothing gets to (what they send still goes out).
  static final Set<String> offline = <String>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null && !offline.contains(target.address)) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

/// One device of the account: its ledger, its social hub, and between them
/// what the app wires (ledgerNodeProvider): removals and conversations
/// through [DeviceChatSync], the friends' copy taken and saved.
final class _Device implements ChatSyncTarget {
  _Device._(this.address, this.node, this.container);

  final String address;
  final LedgerNode node;
  final ProviderContainer container;
  late final DeviceChatSync sync;

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  FriendProfile? friend(String address) =>
      container.read(socialHubControllerProvider).friendByAddress(address);

  static Future<_Device> start(
    String raw,
    Directory dir, {
    _Device? accountOf,
  }) async {
    final String address = _a(raw);
    final _Linked link = _Linked(address);
    _Linked.nodes[address] = link;
    await link.start();
    final MemoryLedgerDisk disk = MemoryLedgerDisk();
    if (accountOf != null) {
      await LedgerIdentity.adoptAccount(
        disk,
        accountOf.node.identity.accountKey!.seed,
      );
    }
    final LedgerNode node = LedgerNode(
      transport: link,
      disk: disk,
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => address,
      syncInterval: Duration.zero,
      helloInterval: Duration.zero,
    );
    addTearDown(node.stop);
    await node.start();
    final MemorySignalTransport out = MemorySignalTransport();
    await out.start();
    final ProviderContainer container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        signalTransportProvider.overrideWithValue(out),
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
      ],
    );
    addTearDown(container.dispose);
    final _Device device = _Device._(address, node, container);
    await device.hub.whenHydrated;
    // As ledgerNodeProvider: a removal goes to the account's devices.
    container.read(accountDirectoryHolderProvider).friendRemoved = (String a) =>
        unawaited(
          node.publishForOwnDevices(kContactRemovedKind, <String, dynamic>{
            'a': a,
          }, spaceKind: 'private'),
        );
    device.sync = DeviceChatSync(node: node, target: device);
    await device.sync.start();
    addTearDown(device.sync.stop);
    return device;
  }

  /// Friends the account had before any of this (no friendship times).
  Future<void> seedFriends(Map<String, String> names) async {
    await hub.importContactsBackup(<String, dynamic>{
      'v': 1,
      'friends': <Map<String, dynamic>>[
        for (final MapEntry<String, String> e in names.entries)
          <String, dynamic>{'a': e.key, 'n': e.value},
      ],
      'groups': const <Object>[],
    });
  }

  Future<void> publishContacts() => node.publishContacts(hub.contactsBackup());

  /// What the app does when a copy came (and at the start).
  Future<void> takeContacts() async {
    final Map<String, dynamic>? backup = node.latestContacts();
    if (backup != null) {
      await hub.importContactsBackup(
        backup,
        removedAt: node.contactRemovals(),
        backupAt: node.latestContactsMillis,
      );
    }
  }

  @override
  List<String> conversationKeys() => hub.conversationKeys();

  @override
  Future<List<ChatMessage>> conversationMessages(String key) =>
      hub.conversationMessages(key);

  @override
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
    String? storedPath,
  }) => hub.importSyncedMessage(
    key,
    message,
    bytes: bytes,
    storedPath: storedPath,
  );

  @override
  Future<void> forgetFriendFromOtherDevice(
    String address, {
    int atMillis = 0,
  }) => hub.forgetFriendFromOtherDevice(address, atMillis: atMillis);

  @override
  Future<void> forgetGroupFromOtherDevice(String groupId) =>
      hub.forgetGroupFromOtherDevice(groupId);
}
