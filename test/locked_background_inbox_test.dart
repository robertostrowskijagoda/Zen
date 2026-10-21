import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/security/hybrid_kem.dart';
import 'package:zen/src/features/security/sealed_inbox.dart';
import 'package:zen/src/features/security/security_payload_protector.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/counting_kem.dart';

// Not IPv6: kept as they are by the address normalization.
const String _ada = 'ada.ygg';
const String _bob = 'bob.ygg';
const String _member = 'member.ygg';
const String _stranger = 'stranger.ygg';
const String _troll = 'troll.ygg';
const String _mailbox = 'mailbox.ygg';

/// 60 bytes sealed and framed: length, version, KEM ciphertext, nonce,
/// the bytes and the tag.
const int _framed60 = 4 + 1 + kHybridCiphertextBytes + 12 + 60 + 16;

Uint8List _masterKey([int seed = 7]) =>
    Uint8List.fromList(List<int>.generate(32, (int i) => i + seed));

void main() {
  late Directory support;
  late MemorySecurityCredentialsStore credentials;
  late FileBackgroundVault appVault;
  late FileBackgroundVault serviceVault;

  setUp(() async {
    support = await Directory.systemTemp.createTemp('zen-inbox-');
    credentials = MemorySecurityCredentialsStore();
    appVault = FileBackgroundVault(
      supportDirectory: () async => support,
      credentials: credentials,
      createKey: true,
    );
    serviceVault = FileBackgroundVault(
      supportDirectory: () async => support,
      credentials: credentials,
    );
  });

  tearDown(() async {
    if (await support.exists()) {
      await support.delete(recursive: true);
    }
  });

  Future<BackgroundCapability> publishFor(Uint8List masterKey) async {
    await appVault.publish(
      BackgroundCapabilityDraft(
        inboxPublicKey: await inboxPublicKeyFor(masterKey),
        friends: const <String>{_ada, _bob},
        groupMembers: const <String>{_member},
        blocked: const <String>{_troll},
        mailboxes: const <String>[_mailbox],
      ),
    );
    final BackgroundCapability? capability = await serviceVault.load();
    expect(capability, isNotNull);
    return capability!;
  }

  Future<String> allBytesUnder(Directory dir) async {
    final List<int> all = <int>[];
    await for (final FileSystemEntity e in dir.list(recursive: true)) {
      if (e is File) {
        all.addAll(await e.readAsBytes());
      }
    }
    return latin1.decode(all, allowInvalid: true);
  }

  group('no master key in the service', () {
    test('the payload sent to the service carries no key at all', () {
      final Map<String, dynamic> data = const AndroidBackgroundBootstrapPayload(
        settings: AppSettings(),
      ).toData();
      expect(
        data.keys,
        isNot(anyOf(contains('encryptionKey'), contains('hasPassword'))),
      );
      for (final Object? value in data.values) {
        expect(value is String && value.length >= 40, isFalse);
      }
    });

    test('the service never makes the background key, the app does', () async {
      expect(await loadBackgroundKey(credentials), isNull);
      final BackgroundKeyProtector service = BackgroundKeyProtector(
        credentials,
      );
      await expectLater(
        service.sealFor('runtime/yggdrasil.config', Uint8List(3)),
        throwsStateError,
      );
      expect(
        await credentials.read(appSecurityBackgroundKeyStorageKey),
        isNull,
      );

      final BackgroundKeyProtector app = BackgroundKeyProtector(
        credentials,
        createKey: true,
      );
      final Uint8List sealed = await app.sealFor(
        'runtime/yggdrasil.config',
        Uint8List.fromList(utf8.encode('{"PrivateKey":"abc"}')),
      );
      expect(latin1.decode(sealed, allowInvalid: true), isNot(contains('abc')));
      // The service opens it with the same key, and only for its own place.
      expect(
        utf8.decode(
          await service.unsealFor('runtime/yggdrasil.config', sealed),
        ),
        '{"PrivateKey":"abc"}',
      );
      await expectLater(
        service.unsealFor('elsewhere', sealed),
        throwsA(anything),
      );
    });

    test(
      'the background key opens nothing sealed with the master key',
      () async {
        final MemoryAppSecurityService security = MemoryAppSecurityService(
          credentialsStore: credentials,
          encryptionKey: _masterKey(),
        );
        final Uint8List underMaster = await EncryptedBinaryPayloadProtector(
          security,
        ).sealFor('threads/ada', Uint8List.fromList(utf8.encode('cześć')));
        await expectLater(
          BackgroundKeyProtector(
            credentials,
            createKey: true,
          ).unsealFor('threads/ada', underMaster),
          throwsA(isA<UnsupportedStoredPayloadException>()),
        );
      },
    );

    test('a wipe destroys the background key with the master key', () async {
      final LocalAppSecurityService security = LocalAppSecurityService(
        credentialsStore: credentials,
        passwordIterations: 10,
      );
      await security.initialize(settings: const AppSettings());
      await loadBackgroundKey(credentials, create: true);
      expect(
        await credentials.read(appSecurityBackgroundKeyStorageKey),
        isNotNull,
      );
      await security.reset();
      expect(
        await credentials.read(appSecurityBackgroundKeyStorageKey),
        isNull,
      );
    });
  });

  group('capability', () {
    test('recognises contacts without storing their addresses', () async {
      final BackgroundCapability capability = await publishFor(_masterKey());
      expect(capability.kindOf(_ada), BackgroundContactKind.friend);
      expect(capability.kindOf(_bob), BackgroundContactKind.friend);
      expect(capability.kindOf(_member), BackgroundContactKind.groupMember);
      expect(capability.kindOf(_troll), BackgroundContactKind.blocked);
      expect(capability.kindOf(_stranger), BackgroundContactKind.stranger);
      expect(capability.mailboxes, <String>[_mailbox]);
      final String onDisk = await allBytesUnder(support);
      for (final String address in <String>[_ada, _bob, _member, _troll]) {
        expect(onDisk, isNot(contains(address)));
      }
    });

    test('is unreadable without the background key', () async {
      await publishFor(_masterKey());
      await credentials.delete(appSecurityBackgroundKeyStorageKey);
      expect(await serviceVault.load(), isNull);
    });

    test('is drawn from the app state: friends, devices, groups', () {
      final SocialHubState state =
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foreground,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            friends: const <String, FriendProfile>{
              _ada: FriendProfile(
                address: _ada,
                displayName: 'Ada',
                status: FriendRelationshipStatus.accepted,
              ),
              _troll: FriendProfile(
                address: _troll,
                displayName: 'T',
                status: FriendRelationshipStatus.blocked,
              ),
              _stranger: FriendProfile(
                address: _stranger,
                displayName: 'S',
                status: FriendRelationshipStatus.pendingIncoming,
              ),
            },
            groups: const <String, GroupProfile>{
              'g1': GroupProfile(
                id: 'g1',
                name: 'G',
                createdById: _ada,
                createdAtMillis: 1,
                memberAddresses: <String>[_ada, _member, _troll],
              ),
              'g2': GroupProfile(
                id: 'g2',
                name: 'Invite',
                createdById: _bob,
                createdAtMillis: 1,
                memberAddresses: <String>[_bob],
                isInvitePending: true,
              ),
            },
          );
      final BackgroundCapabilityDraft draft = backgroundCapabilityDraftOf(
        state,
        inboxPublicKey: Uint8List(32),
        mailboxes: const <String>[_mailbox],
      );
      expect(draft.friends, <String>{_ada});
      expect(draft.blocked, <String>{_troll});
      expect(draft.groupMembers, <String>{_member});
      expect(draft.mailboxes, <String>[_mailbox]);
    });
  });

  group('sealed inbox', () {
    test('a record opens only with the inbox key of the master key', () async {
      final Uint8List plain = Uint8List.fromList(utf8.encode('tajne'));
      final Uint8List record = await sealInboxRecord(
        plain,
        await inboxPublicKeyFor(_masterKey()),
      );
      expect(
        latin1.decode(record, allowInvalid: true),
        isNot(contains('tajne')),
      );
      expect(
        await openInboxRecord(record, await inboxKeyPairFor(_masterKey())),
        orderedEquals(plain),
      );
      expect(
        await openInboxRecord(record, await inboxKeyPairFor(_masterKey(9))),
        isNull,
      );
      final Uint8List tampered = Uint8List.fromList(record)..[40] ^= 1;
      expect(
        await openInboxRecord(tampered, await inboxKeyPairFor(_masterKey())),
        isNull,
      );
    });

    test('records are sealed with the hybrid KEM, once per batch of '
        'records, and opened with one decapsulation each', () async {
      final CountingKem kem = CountingKem();
      debugOverrideHybridKem(kem);
      addTearDown(() => debugOverrideHybridKem(null));
      final File file = File('${support.path}/inbox.zbox');
      final SealedInboxWriter writer = SealedInboxWriter(
        file: file,
        recipientPublicKey: await inboxPublicKeyFor(_masterKey()),
      );
      for (int i = 0; i < 5; i++) {
        expect(await writer.append(Uint8List.fromList(<int>[i])), isTrue);
      }
      expect(kem.encapsulations, 1, reason: 'no KEM operation per record');
      expect(
        await file.length(),
        5 * (4 + 1 + kHybridCiphertextBytes + 12 + 1 + 16),
      );
      final List<Uint8List> records = await readSealedInbox(
        file,
        await inboxKeyPairFor(_masterKey()),
      );
      expect(records.map((Uint8List r) => r.single).toList(), <int>[
        0,
        1,
        2,
        3,
        4,
      ]);
      expect(kem.decapsulations, 1);
    });

    test('a record cut short by a killed write is cut off', () async {
      final File file = File('${support.path}/inbox.zbox');
      final Uint8List publicKey = await inboxPublicKeyFor(_masterKey());
      final SealedInboxWriter first = SealedInboxWriter(
        file: file,
        recipientPublicKey: publicKey,
      );
      expect(await first.append(Uint8List.fromList(<int>[1, 2, 3])), isTrue);
      // Half of the next record, as a killed process leaves it.
      final Uint8List half = (await sealInboxRecord(
        Uint8List.fromList(<int>[9, 9]),
        publicKey,
      )).sublist(0, 20);
      await file.writeAsBytes(<int>[
        ...ByteData(4).buffer.asUint8List()..[0] = 100,
        ...half,
      ], mode: FileMode.append);
      final SealedInboxWriter second = SealedInboxWriter(
        file: file,
        recipientPublicKey: publicKey,
      );
      expect(await second.append(Uint8List.fromList(<int>[4, 5])), isTrue);
      final HybridKeyPair key = await inboxKeyPairFor(_masterKey());
      final List<Uint8List> records = await readSealedInbox(file, key);
      expect(records.map((Uint8List r) => r.toList()).toList(), <List<int>>[
        <int>[1, 2, 3],
        <int>[4, 5],
      ]);
    });

    test('a full inbox refuses instead of overwriting', () async {
      final SealedInboxWriter writer = SealedInboxWriter(
        file: File('${support.path}/inbox.zbox'),
        recipientPublicKey: await inboxPublicKeyFor(_masterKey()),
        maxFileBytes: _framed60 + 100,
      );
      expect(await writer.append(Uint8List(60)), isTrue);
      expect(await writer.append(Uint8List(60)), isFalse);
      expect(
        await writer.append(Uint8List(kSealedInboxMaxRecordBytes + 1)),
        isFalse,
      );
    });
  });

  group('inbox shares', () {
    test('one sender cannot fill the inbox for the others; drained, it '
        'starts over', () async {
      final File file = File('${support.path}/inbox.zbox');
      final SealedInboxWriter writer = SealedInboxWriter(
        file: file,
        recipientPublicKey: await inboxPublicKeyFor(_masterKey()),
        maxFileBytes: 10 * _framed60,
        maxBytesPerSender: 2 * _framed60 + 50,
        maxStrangerBytes: _framed60 + 50,
      );
      Future<bool> put(String? sender, {bool stranger = false}) =>
          writer.append(Uint8List(60), sender: sender, stranger: stranger);
      expect(await put('200::a'), isTrue);
      expect(await put('200::a'), isTrue);
      expect(await put('200::a'), isFalse, reason: 'its share is used');
      expect(await put('200::b'), isTrue, reason: 'others still get theirs');
      expect(await put('200::c', stranger: true), isTrue);
      expect(
        await put('200::d', stranger: true),
        isFalse,
        reason: 'strangers share one small budget',
      );
      expect(await put(null), isTrue, reason: "the phone's own records");
      // The app drains the inbox (takes the file away).
      await file.rename('${support.path}/drained.zbox');
      expect(await put('200::a'), isTrue);
      expect(await file.length(), _framed60);
    });
  });

  group('locked receiver', () {
    late MemorySignalTransport transport;
    late MemoryRuntimeSystemNotificationService notices;
    late LockedReceiver receiver;

    Future<void> startReceiver(
      BackgroundCapability capability, {
      Duration ringTimeout = const Duration(seconds: 6),
    }) async {
      transport = MemorySignalTransport();
      notices = MemoryRuntimeSystemNotificationService();
      receiver = LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: SealedInboxWriter(
          file: await serviceVault.inboxFile(),
          recipientPublicKey: capability.inboxPublicKey,
        ),
        notices: notices,
        ringTimeout: ringTimeout,
        mailboxPollInterval: Duration.zero,
      );
      await receiver.start();
    }

    tearDown(() async {
      await receiver.stop();
    });

    Future<void> receive(String from, Map<String, dynamic> payload) async {
      await receiver.handleFrame(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: 1000,
        ),
      );
    }

    test(
      'keeps a friend\'s message sealed, acknowledges it after, and tells only '
      'that a message came',
      () async {
        await startReceiver(await publishFor(_masterKey()));
        // Its mailboxes are asked for held mail.
        expect(transport.sentSignals.single.remoteAddress, _mailbox);
        expect(transport.sentSignals.single.payload['type'], 'rly_poll');
        transport.sentSignals.clear();

        await receive(_ada, <String, dynamic>{
          'type': 'message',
          '_rid': 'r1',
          'text': 'Spotkajmy się o 18 pod mostem',
          'senderName': 'Ada',
        });

        expect(receiver.keptCount, 1);
        expect(transport.sentSignals.single.remoteAddress, _ada);
        expect(transport.sentSignals.single.payload, <String, dynamic>{
          'type': 'rly_ack',
          'rid': 'r1',
        });
        final RuntimeSystemNotification notice =
            notices.activeNotifications.single;
        expect(notice.category, RuntimeSystemNotificationCategory.message);
        expect('${notice.title} ${notice.body}', isNot(contains('Ada')));
        expect('${notice.title} ${notice.body}', isNot(contains('mostem')));
        // Nothing readable on the disk.
        final String onDisk = await allBytesUnder(support);
        expect(onDisk, isNot(contains('mostem')));
        expect(onDisk, isNot(contains('Ada')));
        expect(onDisk, isNot(contains(_ada)));
      },
    );

    test('a repeat is kept once and acknowledged again', () async {
      await startReceiver(await publishFor(_masterKey()));
      transport.sentSignals.clear();
      final Map<String, dynamic> message = <String, dynamic>{
        'type': 'message',
        '_rid': 'r1',
        'text': 'x',
      };
      await receive(_ada, message);
      await receive(_ada, message);
      expect(receiver.keptCount, 1);
      expect(
        transport.sentSignals.where((s) => s.payload['type'] == 'rly_ack'),
        hasLength(2),
      );
    });

    test(
      'what cannot be kept is not acknowledged: the sender keeps it',
      () async {
        final BackgroundCapability capability = await publishFor(_masterKey());
        transport = MemorySignalTransport();
        notices = MemoryRuntimeSystemNotificationService();
        receiver = LockedReceiver(
          transport: transport,
          capability: capability,
          inbox: SealedInboxWriter(
            file: await serviceVault.inboxFile(),
            recipientPublicKey: capability.inboxPublicKey,
            maxFileBytes: 64,
          ),
          notices: notices,
          mailboxPollInterval: Duration.zero,
        );
        await receiver.start();
        transport.sentSignals.clear();
        await receive(_ada, <String, dynamic>{
          'type': 'message',
          '_rid': 'full',
          'text': 'x',
        });
        expect(receiver.keptCount, 0);
        expect(transport.sentSignals, isEmpty);
        expect(notices.activeNotifications, isEmpty);
      },
    );

    test('one friend cannot fill the inbox for the others', () async {
      final BackgroundCapability capability = await publishFor(_masterKey());
      transport = MemorySignalTransport();
      notices = MemoryRuntimeSystemNotificationService();
      receiver = LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: SealedInboxWriter(
          file: await serviceVault.inboxFile(),
          recipientPublicKey: capability.inboxPublicKey,
          maxBytesPerSender: 3000,
        ),
        notices: notices,
        mailboxPollInterval: Duration.zero,
      );
      await receiver.start();
      final String text = 'x' * 200;
      for (int i = 0; i < 4; i++) {
        await receive(_ada, <String, dynamic>{
          'type': 'message',
          '_rid': 'ada$i',
          'text': text,
        });
      }
      final int fromAda = receiver.keptCount;
      expect(fromAda, lessThan(4));
      await receive(_bob, <String, dynamic>{
        'type': 'message',
        '_rid': 'bob',
        'text': text,
      });
      expect(receiver.keptCount, fromAda + 1);
      // What was not kept was not acknowledged: Ada's phone keeps it.
      expect(
        transport.sentSignals
            .where((s) => s.payload['type'] == 'rly_ack')
            .map((s) => s.payload['rid']),
        isNot(contains('ada3')),
      );
    });

    test('answers friends\' presence, nobody else\'s', () async {
      await startReceiver(await publishFor(_masterKey()));
      transport.sentSignals.clear();
      await receive(_ada, <String, dynamic>{'type': 'ping'});
      await receive(_stranger, <String, dynamic>{'type': 'ping'});
      await receive(_troll, <String, dynamic>{'type': 'ping'});
      expect(transport.sentSignals.single.remoteAddress, _ada);
      expect(transport.sentSignals.single.payload['type'], 'pong');
      expect(transport.sentSignals.single.payload['state'], 'background');
      expect(receiver.keptCount, 0);
    });

    test('strangers leave only what was meant to arrive, and only a little; '
        'the blocked nothing', () async {
      await startReceiver(await publishFor(_masterKey()));
      await receive(_stranger, <String, dynamic>{'type': 'ledger_hello'});
      expect(receiver.keptCount, 0);
      for (int i = 0; i < kLockedStrangerFramesPerSender + 3; i++) {
        await receive(_stranger, <String, dynamic>{
          'type': 'friend_request',
          '_rid': 'fr$i',
        });
      }
      expect(receiver.keptCount, kLockedStrangerFramesPerSender);
      await receive(_troll, <String, dynamic>{'type': 'message', '_rid': 'z'});
      expect(receiver.keptCount, kLockedStrangerFramesPerSender);
    });

    test(
      'mailbox duties for friends pause; mail for this phone is kept',
      () async {
        await startReceiver(await publishFor(_masterKey()));
        transport.sentSignals.clear();
        await receive(_ada, <String, dynamic>{
          'type': 'rly_deposit',
          'env': 'x',
        });
        await receive(_ada, <String, dynamic>{'type': 'rly_poll'});
        expect(receiver.keptCount, 0);
        expect(transport.sentSignals, isEmpty);
        await receive(_mailbox, <String, dynamic>{
          'type': 'rly_mail',
          'items': <String>['sealed'],
        });
        // The mailbox is not a friend here: only friends' mail frames count.
        await receive(_ada, <String, dynamic>{
          'type': 'rly_mail',
          'items': <String>['sealed'],
        });
        expect(receiver.keptCount, 1);
      },
    );

    test('the ledger sync waits for unlock; its keys are kept', () async {
      await startReceiver(await publishFor(_masterKey()));
      await receive(_ada, <String, dynamic>{'type': 'lg_heads', 'h': 'x'});
      await receive(_ada, <String, dynamic>{'type': 'lg_blob_chunk', 'c': 'x'});
      expect(receiver.keptCount, 0);
      await receive(_ada, <String, dynamic>{'type': 'lg_keys', 'k': 'x'});
      expect(receiver.keptCount, 1);
    });

    test('a ring is told but not kept, and leaves a missed call', () async {
      await startReceiver(
        await publishFor(_masterKey()),
        ringTimeout: const Duration(milliseconds: 40),
      );
      await receive(_ada, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'c1',
      });
      await receive(_ada, <String, dynamic>{
        'type': 'call_invite',
        'callId': 'c1',
      });
      expect(receiver.keptCount, 0);
      final RuntimeSystemNotification ring = notices.activeNotifications.single;
      expect(ring.category, RuntimeSystemNotificationCategory.call);
      expect(ring.isRingingCall, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(
        notices.activeNotifications.map(
          (RuntimeSystemNotification n) => n.slotKey,
        ),
        <String>[kLockedMissedCallSlot],
      );
    });

    test('a friend\'s alarm is loud; anyone else\'s is only kept', () async {
      await startReceiver(await publishFor(_masterKey()));
      await receive(_member, <String, dynamic>{
        'type': 'alarm',
        'id': 'a0',
        '_rid': 'x0',
      });
      expect(notices.activeNotifications, isEmpty);
      await receive(_ada, <String, dynamic>{
        'type': 'alarm',
        'id': 'a1',
        '_rid': 'x1',
      });
      final RuntimeSystemNotification alarm =
          notices.activeNotifications.single;
      expect(alarm.category, RuntimeSystemNotificationCategory.alarm);
      expect(alarm.isRingingCall, isTrue);
      expect(receiver.keptCount, 2);
    });

    test('without an alarm kit the power-button shortcut says the alarm did '
        'not go out', () async {
      await startReceiver(await publishFor(_masterKey()));
      await receiver.onPowerShortcut();
      expect(notices.activeNotifications.single.slotKey, kLockedPowerAlarmSlot);
    });

    test('unlocking drains everything, in order, once; without the master key '
        'nothing opens', () async {
      final Uint8List masterKey = _masterKey();
      await startReceiver(await publishFor(masterKey));
      for (int i = 0; i < 20; i++) {
        await receive(i.isEven ? _ada : _bob, <String, dynamic>{
          'type': 'message',
          '_rid': 'm$i',
          'text': 'wiadomość $i',
        });
      }
      await receive(_ada, <String, dynamic>{
        'type': 'event',
        '_rid': 'e1',
        'title': 'Grill',
      });
      await receiver.stop();
      expect(await appVault.hasInbox(), isTrue);

      // Another master key (another account, a wipe): nothing opens.
      final Directory copy = await Directory.systemTemp.createTemp('zen-c-');
      addTearDown(() => copy.delete(recursive: true));
      final File inbox = await serviceVault.inboxFile();
      await inbox.copy('${copy.path}/inbox.zbox');
      expect(
        await readSealedInbox(
          File('${copy.path}/inbox.zbox'),
          await inboxKeyPairFor(_masterKey(99)),
        ),
        isEmpty,
      );

      final List<SignalTransportFrame> delivered = <SignalTransportFrame>[];
      final int count = await appVault.drain(
        masterKey: masterKey,
        settle: Duration.zero,
        deliver: (Uint8List record) async {
          delivered.add(decodeInboxFrame(record)!);
        },
      );
      expect(count, 21);
      expect(
        delivered.map((SignalTransportFrame f) => f.payload['_rid']),
        <String>[for (int i = 0; i < 20; i++) 'm$i', 'e1'],
      );
      expect(delivered.first.from, _ada);
      expect(delivered.first.payload['text'], 'wiadomość 0');
      expect(delivered.first.receivedAtMillis, 1000);
      expect(await appVault.hasInbox(), isFalse);
      expect(
        await appVault.drain(
          masterKey: masterKey,
          settle: Duration.zero,
          deliver: (Uint8List _) async {},
        ),
        0,
      );
    });

    test('doors: knocks and neighbour flats\' frames are kept for the app, '
        'never answered, once each and within a budget of their own', () async {
      final Uint8List masterKey = _masterKey();
      final BackgroundCapability capability = await publishFor(masterKey);
      final StreamController<SignalTransportFrame> doors =
          StreamController<SignalTransportFrame>.broadcast();
      addTearDown(doors.close);
      transport = MemorySignalTransport();
      notices = MemoryRuntimeSystemNotificationService();
      receiver = LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: SealedInboxWriter(
          file: await serviceVault.inboxFile(),
          recipientPublicKey: capability.inboxPublicKey,
        ),
        notices: notices,
        doorFrames: doors.stream,
        mailboxPollInterval: Duration.zero,
      );
      await receiver.start();
      transport.sentSignals.clear();

      SignalTransportFrame atDoor(String from, String type, String rid) =>
          SignalTransportFrame(
            from: from,
            payload: <String, dynamic>{
              'type': type,
              '_rid': rid,
              'b': <String, dynamic>{'n': 'Kowalscy spod 12'},
            },
            receivedAtMillis: 1000,
            door: true,
          );

      final SignalTransportFrame knock = atDoor(
        _stranger,
        kFlatKnockType,
        'k1',
      );
      await receiver.handleDoorFrame(knock);
      await receiver.handleDoorFrame(knock);
      expect(receiver.keptCount, 1, reason: 'a knock retried is kept once');
      expect(
        transport.sentSignals,
        isEmpty,
        reason: 'a door never says who runs it',
      );
      final RuntimeSystemNotification notice =
          notices.activeNotifications.single;
      expect(notice.category, RuntimeSystemNotificationCategory.social);
      expect('${notice.title} ${notice.body}', isNot(contains('Kowalscy')));

      // Only flat frames, never one that does not claim the door, never from
      // the blocked.
      await receiver.handleDoorFrame(atDoor(_stranger, 'message', 'm1'));
      await receiver.handleDoorFrame(
        SignalTransportFrame(
          from: _stranger,
          payload: const <String, dynamic>{'type': 'flat_msg', '_rid': 'x'},
          receivedAtMillis: 1000,
        ),
      );
      await receiver.handleDoorFrame(atDoor(_troll, 'flat_msg', 't1'));
      expect(receiver.keptCount, 1);

      // A sealed knock at a mailbox door run for a friend, as the node
      // hands it over.
      doors.add(atDoor(_mailbox, kFlatSealType, 's1'));
      for (int i = 0; i < 200 && receiver.keptCount < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(receiver.keptCount, 2);

      // One door cannot fill the inbox.
      for (int i = 0; i < 10; i++) {
        await receiver.handleDoorFrame(atDoor('door.ygg', 'flat_msg', 'f$i'));
      }
      expect(receiver.keptCount, 2 + kLockedDoorFramesPerSender);
      await receiver.stop();

      // After unlock they come back as frames that came to a door: only the
      // neighbours section sees them.
      final List<SignalTransportFrame> delivered = <SignalTransportFrame>[];
      await appVault.drain(
        masterKey: masterKey,
        settle: Duration.zero,
        deliver: (Uint8List record) async {
          delivered.add(decodeInboxFrame(record)!);
        },
      );
      expect(delivered, hasLength(2 + kLockedDoorFramesPerSender));
      expect(delivered.every((SignalTransportFrame f) => f.door), isTrue);
      expect(delivered.first.payload['type'], kFlatKnockType);
      expect(delivered.first.from, _stranger);
    });

    test('a drain cut short is read again, before what came later', () async {
      final Uint8List masterKey = _masterKey();
      await startReceiver(await publishFor(masterKey));
      await receive(_ada, <String, dynamic>{'type': 'message', '_rid': 'a'});
      // The app was killed while delivering: the first file stays.
      await expectLater(
        appVault.drain(
          masterKey: masterKey,
          settle: Duration.zero,
          deliver: (Uint8List _) async => throw StateError('killed'),
        ),
        throwsStateError,
      );
      // The service kept receiving meanwhile.
      await receive(_ada, <String, dynamic>{'type': 'message', '_rid': 'b'});
      final List<Object?> order = <Object?>[];
      await appVault.drain(
        masterKey: masterKey,
        settle: Duration.zero,
        deliver: (Uint8List record) async {
          order.add(decodeInboxFrame(record)!.payload['_rid']);
        },
      );
      expect(order, <String>['a', 'b']);
      expect(await appVault.hasInbox(), isFalse);
    });
  });

  test('a frame survives the inbox exactly', () {
    const SignalTransportFrame frame = SignalTransportFrame(
      from: _ada,
      payload: <String, dynamic>{
        'type': 'message',
        'n': 3,
        'list': <Object?>[1, 'a', null],
      },
      receivedAtMillis: 42,
    );
    final SignalTransportFrame back = decodeInboxFrame(
      encodeInboxFrame(frame),
    )!;
    expect(back.from, _ada);
    expect(back.receivedAtMillis, 42);
    expect(back.payload, frame.payload);
    expect(back.door, isFalse);
    expect(decodeInboxFrame(Uint8List.fromList(<int>[1, 2])), isNull);
    expect(
      decodeInboxFrame(
        encodeInboxFrame(
          const SignalTransportFrame(
            from: _ada,
            payload: <String, dynamic>{'type': kFlatKnockType},
            receivedAtMillis: 1,
            door: true,
          ),
        ),
      )!.door,
      isTrue,
    );
  });

  test('the door kit opens only in the background folder with the background '
      'key, and keeps only well-formed door keys', () async {
    final String doorKey = 'ab' * 32;
    final String hosted = 'cd' * 32;
    await lockedDoorKitFile(
      supportDirectory: () async => support,
      credentials: credentials,
      createKey: true,
    ).write(
      LockedDoorKit(
        doorKey: doorKey,
        mailboxDoorKeys: <String>[hosted],
      ).toJson(),
    );
    final String onDisk = await allBytesUnder(support);
    expect(onDisk, isNot(contains(doorKey)));
    expect(onDisk, isNot(contains(hosted)));
    final LockedDoorKit kit = LockedDoorKit.fromJson(
      await lockedDoorKitFile(
        supportDirectory: () async => support,
        credentials: credentials,
      ).read(),
    )!;
    expect(kit.doorKey, doorKey);
    expect(kit.mailboxDoorKeys, <String>[hosted]);
    expect(
      LockedDoorKit.fromJson(<String, dynamic>{
        'v': 1,
        'dk': 'not a key',
        'mb': <Object?>['xyz', 3, hosted],
      })!.mailboxDoorKeys,
      <String>[hosted],
    );
    // Another background key (a wipe): nothing opens.
    await credentials.delete(appSecurityBackgroundKeyStorageKey);
    expect(
      await lockedDoorKitFile(
        supportDirectory: () async => support,
        credentials: credentials,
      ).read(),
      isNull,
    );
  });
}
