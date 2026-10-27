import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/features/account/account_routing_transport.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/locked_presence.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_signal_module.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
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

/// A mailbox envelope as it travels (sealed contents made up): [id] is
/// its payload's reliable id.
Map<String, dynamic> _envelope(
  String id, {
  required String from,
  String to = 'me.ygg',
  int now = 1000000,
}) => <String, dynamic>{
  'id': id,
  's': from,
  'r': to,
  'c': now,
  'x': now + const Duration(days: 1).inMilliseconds,
  'q': base64Url.encode(List<int>.filled(kHybridCiphertextBytes, 1)),
  'n': base64Url.encode(List<int>.filled(12, 1)),
  'b': base64Url.encode(List<int>.filled(40, 1)),
};

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

    test('a friend\'s unlinked phone in a shared group is not let in', () {
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
            },
            groups: const <String, GroupProfile>{
              'g1': GroupProfile(
                id: 'g1',
                name: 'G',
                createdById: _member,
                createdAtMillis: 1,
                memberAddresses: <String>[_ada, _member],
              ),
            },
          );
      final BackgroundCapabilityDraft draft = backgroundCapabilityDraftOf(
        state,
        inboxPublicKey: Uint8List(32),
        directory: _UnlinkedAda(),
      );
      expect(draft.friends, isNot(contains(_ada)));
      expect(draft.groupMembers, <String>{_member});
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
      LockedNoticeKit? noticeKit,
      LockedPresenceKit? presenceKit,
      Duration noticeThrottle = const Duration(minutes: 1),
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
        noticeKit: noticeKit,
        presence: presenceKit,
        noticeThrottle: noticeThrottle,
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

    test('the phone stays awake only for what is kept or rings', () async {
      final _WakeCalls wake = _WakeCalls();
      ZenWake.platform = wake;
      addTearDown(() => ZenWake.platform = const TimerWakePlatform());
      await startReceiver(await publishFor(_masterKey()));

      // Dropped at once: nothing more than the arrival's own moment.
      await receive(_ada, const <String, dynamic>{'type': 'pong'});
      await receive(_ada, const <String, dynamic>{'type': 'away'});
      await receive(_ada, const <String, dynamic>{'type': 'lg_hello'});
      await receive(_ada, const <String, dynamic>{'type': 'rly_deposit'});
      expect(wake.calls, isEmpty);

      // Kept: held while it goes into the inbox, let go right after.
      await receive(_ada, <String, dynamic>{
        'type': 'message',
        '_rid': 'w1',
        'text': 'Hej',
      });
      expect(wake.calls, <String>[
        'hold locked-keep 20',
        'release locked-keep 1000',
      ]);
      wake.calls.clear();

      // A ring: awake while it rings, so its end is noticed.
      await receive(_bob, const <String, dynamic>{'type': 'call_invite'});
      expect(wake.calls, <String>['hold ring 8']);
    });

    test('polls that find nothing come less often, and often again once '
        'something came', () async {
      final _BeatAlarms wake = _BeatAlarms();
      int clock = 0;
      ZenWake.platform = wake;
      ZenWake.nowMillis = () => clock;
      addTearDown(() {
        ZenWake.resetForTest();
        ZenWake.platform = const TimerWakePlatform();
        ZenWake.nowMillis = () => DateTime.now().millisecondsSinceEpoch;
      });
      final BackgroundCapability capability = await publishFor(_masterKey());
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
        pollAnswerGrace: Duration.zero,
      );
      await receiver.start();
      expect(receiver.mailboxPollWait, kLockedMailboxPollInterval);

      Future<void> nextPoll() async {
        final WakeTimer alarm = wake.live.single;
        clock += wake.delayOf(alarm).inMilliseconds;
        await wake.ring(alarm);
      }

      final List<int> waits = <int>[];
      for (int i = 0; i < 5; i++) {
        await nextPoll();
        waits.add(receiver.mailboxPollWait!.inMinutes);
      }
      expect(waits, <int>[10, 20, 30, 30, 30]);
      expect(
        transport.sentSignals.where((s) => s.payload['type'] == 'rly_poll'),
        hasLength(6),
        reason: 'one at the start and one on each wake',
      );
      expect(wake.delayOf(wake.live.single), kLockedMailboxPollMaxInterval);

      // A message came: more may follow, the mailboxes are asked again soon.
      await receive(_ada, <String, dynamic>{
        'type': 'message',
        '_rid': 'b1',
        'text': 'Hej',
      });
      expect(receiver.mailboxPollWait, kLockedMailboxPollInterval);
      expect(wake.delayOf(wake.live.single), kLockedMailboxPollInterval);
      await nextPoll();
      expect(
        receiver.mailboxPollWait,
        kLockedMailboxPollInterval,
        reason: 'the poll right after still counts what came',
      );
      await nextPoll();
      expect(receiver.mailboxPollWait, const Duration(minutes: 10));
    });

    test('the wait between polls doubles up to its longest', () {
      Duration wait = kLockedMailboxPollInterval;
      final List<int> minutes = <int>[];
      for (int i = 0; i < 5; i++) {
        wait = nextMailboxPollWait(last: wait, keptSince: false);
        minutes.add(wait.inMinutes);
      }
      expect(minutes, <int>[10, 20, 30, 30, 30]);
      expect(
        nextMailboxPollWait(last: wait, keptSince: true),
        kLockedMailboxPollInterval,
      );
      expect(
        kLockedMailboxPollMaxInterval.inMinutes %
            kLockedMailboxPollInterval.inMinutes,
        0,
        reason: 'the polls keep to the beat\'s wakes',
      );
    });

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

    group('a message\'s notice follows the notification privacy level', () {
      const LockedNoticeKit names = LockedNoticeKit(
        names: <String, String>{
          _ada: 'Ada',
          _member: 'Marek',
          'group:g1': 'Ekipa',
        },
        members: <String, Set<String>>{
          'group:g1': <String>{_ada, _member},
        },
      );
      LockedNoticeKit kit({
        NotificationPrivacy privacy = NotificationPrivacy.senderAndContent,
        Map<String, NotificationPrivacy> overrides =
            const <String, NotificationPrivacy>{},
      }) => LockedNoticeKit(
        privacy: privacy,
        overrides: overrides,
        names: names.names,
        members: names.members,
      );

      Future<RuntimeSystemNotification> noticeFor(
        LockedNoticeKit? noticeKit,
        String from,
        Map<String, dynamic> payload,
      ) async {
        await startReceiver(
          await publishFor(_masterKey()),
          noticeKit: noticeKit,
        );
        await receive(from, payload);
        return notices.activeNotifications.single;
      }

      const Map<String, dynamic> direct = <String, dynamic>{
        'type': 'message',
        '_rid': 'p1',
        'text': 'Spotkajmy się o 18',
        'senderName': 'Ada',
      };
      const Map<String, dynamic> inGroup = <String, dynamic>{
        'type': 'group_message',
        '_rid': 'p2',
        'groupId': 'g1',
        'groupName': 'Ekipa',
        'text': 'Kto idzie?',
        'senderName': 'Marek',
      };

      test('"Nadawca i treść": who and what, in a group too', () async {
        RuntimeSystemNotification notice = await noticeFor(kit(), _ada, direct);
        expect(notice.title, 'Ada');
        expect(notice.body, 'Spotkajmy się o 18');
        await receiver.stop();
        notice = await noticeFor(kit(), _member, inGroup);
        expect(notice.title, 'Ekipa');
        expect(notice.body, 'Marek: Kto idzie?');
      });

      test(
        'a group message names only members, never by the name they sent',
        () async {
          // Not a member of the group: only that something came.
          RuntimeSystemNotification notice = await noticeFor(
            kit(),
            _bob,
            <String, dynamic>{...inGroup, '_rid': 'p3', 'senderName': 'Ada'},
          );
          expect(notice.title, 'Nowa wiadomość');
          expect('${notice.title} ${notice.body}', isNot(contains('Ada')));
          expect('${notice.title} ${notice.body}', isNot(contains('Kto')));
          await receiver.stop();
          // A member the kit has no name for: never the name it chose.
          notice = await noticeFor(
            LockedNoticeKit(
              names: const <String, String>{'group:g1': 'Ekipa', _ada: 'Ada'},
              members: names.members,
            ),
            _member,
            <String, dynamic>{...inGroup, '_rid': 'p4', 'senderName': 'Ada'},
          );
          expect(notice.title, 'Ekipa');
          expect(notice.body, 'Kontakt Zen: Kto idzie?');
        },
      );

      test('"Tylko nadawca": who, never what', () async {
        final RuntimeSystemNotification notice = await noticeFor(
          kit(privacy: NotificationPrivacy.senderOnly),
          _ada,
          direct,
        );
        expect(notice.title, 'Ada');
        expect(notice.body, 'Nowa wiadomość');
      });

      test(
        '"Tylko informacja", no kit, or no name: only that it came',
        () async {
          for (final (LockedNoticeKit?, String) run
              in <(LockedNoticeKit?, String)>[
                (kit(privacy: NotificationPrivacy.generic), _ada),
                (null, _ada),
                // A friend the kit has no name for.
                (kit(), _bob),
              ]) {
            final RuntimeSystemNotification notice = await noticeFor(
              run.$1,
              run.$2,
              direct,
            );
            expect(notice.title, 'Nowa wiadomość');
            expect('${notice.title} ${notice.body}', isNot(contains('Ada')));
            expect('${notice.title} ${notice.body}', isNot(contains('18')));
            await receiver.stop();
          }
        },
      );

      test('a conversation\'s own level beats the global one', () async {
        RuntimeSystemNotification notice = await noticeFor(
          kit(
            privacy: NotificationPrivacy.generic,
            overrides: const <String, NotificationPrivacy>{
              _ada: NotificationPrivacy.senderAndContent,
            },
          ),
          _ada,
          direct,
        );
        expect(notice.title, 'Ada');
        expect(notice.body, 'Spotkajmy się o 18');
        await receiver.stop();
        notice = await noticeFor(
          kit(
            overrides: const <String, NotificationPrivacy>{
              'group:g1': NotificationPrivacy.generic,
            },
          ),
          _member,
          inGroup,
        );
        expect(notice.title, 'Nowa wiadomość');
        expect(notice.body, isNot(contains('Kto idzie')));
      });

      test('a call rings whatever the level', () async {
        await startReceiver(
          await publishFor(_masterKey()),
          noticeKit: kit(privacy: NotificationPrivacy.generic),
        );
        await receive(_bob, const <String, dynamic>{'type': 'call_invite'});
        final RuntimeSystemNotification ring =
            notices.activeNotifications.single;
        expect(ring.category, RuntimeSystemNotificationCategory.call);
        expect(ring.isRingingCall, isTrue);
        expect(ring.title, 'Połączenie przychodzące');
      });
    });

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
      final int openedAt = DateTime.now().millisecondsSinceEpoch - 600000;
      await startReceiver(
        await publishFor(_masterKey()),
        presenceKit: LockedPresenceKit(
          shownTo: const <String>{_ada},
          lastOpenedAtMillis: openedAt,
        ),
      );
      transport.sentSignals.clear();
      await receive(_ada, <String, dynamic>{'type': 'ping'});
      await receive(_stranger, <String, dynamic>{'type': 'ping'});
      await receive(_troll, <String, dynamic>{'type': 'ping'});
      expect(transport.sentSignals.single.remoteAddress, _ada);
      expect(transport.sentSignals.single.payload['type'], 'pong');
      expect(transport.sentSignals.single.payload['state'], 'background');
      // Zen was last open here about ten minutes ago.
      expect(
        transport.sentSignals.single.payload['lo'] as int,
        inInclusiveRange(599, 605),
      );
      expect(receiver.keptCount, 0);
    });

    test(
      'a pong says "w tle" only to friends the presence kit names',
      () async {
        await startReceiver(
          await publishFor(_masterKey()),
          presenceKit: const LockedPresenceKit(shownTo: <String>{_bob}),
        );
        transport.sentSignals.clear();
        await receive(_ada, <String, dynamic>{'type': 'ping'});
        await receive(_bob, <String, dynamic>{'type': 'ping'});
        final Map<String, dynamic> toAda = transport.sentSignals
            .singleWhere((s) => s.remoteAddress == _ada)
            .payload;
        final Map<String, dynamic> toBob = transport.sentSignals
            .singleWhere((s) => s.remoteAddress == _bob)
            .payload;
        // Ada (say, a weak acquaintance) learns only that the phone answers.
        expect(toAda['type'], 'pong');
        expect(toAda.containsKey('state'), isFalse);
        expect(toAda.containsKey('lo'), isFalse);
        // Bob sees "w tle"; the last opening is kept to the person.
        expect(toBob['state'], 'background');
        expect(toBob.containsKey('lo'), isFalse);
      },
    );

    test('without a presence kit a pong says nothing about presence', () async {
      await startReceiver(await publishFor(_masterKey()));
      transport.sentSignals.clear();
      await receive(_ada, <String, dynamic>{'type': 'ping'});
      expect(transport.sentSignals.single.payload['type'], 'pong');
      expect(
        transport.sentSignals.single.payload.containsKey('state'),
        isFalse,
      );
    });

    test('the presence kit survives its file', () {
      const LockedPresenceKit kit = LockedPresenceKit(
        shownTo: <String>{_ada, _bob},
        lastOpenedAtMillis: 1234,
      );
      final LockedPresenceKit back = LockedPresenceKit.fromJson(
        jsonDecode(jsonEncode(kit.toJson())),
      )!;
      expect(back.shownTo, <String>{_ada, _bob});
      expect(back.lastOpenedAtMillis, 1234);
      expect(LockedPresenceKit.fromJson(<String, dynamic>{'v': 2}), isNull);
    });

    test('answers a friend\'s pings at most every few minutes and keeps '
        'no "away"', () async {
      int clock = 1000000;
      final BackgroundCapability capability = await publishFor(_masterKey());
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
        mailboxPollInterval: Duration.zero,
        now: () => clock,
      );
      await receiver.start();
      transport.sentSignals.clear();
      int pongs() => transport.sentSignals
          .where((sent) => sent.payload['type'] == 'pong')
          .length;
      await receive(_ada, <String, dynamic>{'type': 'ping'});
      expect(pongs(), 1);
      // The next ping, one interval later: no answer needed yet.
      clock += const Duration(minutes: 2, seconds: 30).inMilliseconds;
      await receive(_ada, <String, dynamic>{'type': 'ping'});
      expect(pongs(), 1);
      clock += const Duration(minutes: 2, seconds: 30).inMilliseconds;
      await receive(_ada, <String, dynamic>{'type': 'ping'});
      expect(pongs(), 2);
      expect(kLockedPongEvery, lessThan(kPresenceOfflineAfter));
      await receive(_ada, <String, dynamic>{'type': kPresenceAwayType});
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
      'without a mailbox kit mailbox duties for friends pause; mail for this '
      'phone is kept',
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
          'items': <Object>[_envelope('e0', from: _bob)],
        });
        // The mailbox is not a friend here: only friends' mail frames count.
        await receive(_ada, <String, dynamic>{
          'type': 'rly_mail',
          'items': <Object>['not an envelope', _envelope('e1', from: _bob)],
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

  group('locked receiver: one notice per message', () {
    late MemorySignalTransport transport;
    late MemoryRuntimeSystemNotificationService notices;
    late LockedReceiver receiver;
    int clock = 1000000;

    Future<void> startReceiver({
      Set<String> taken = const <String>{},
      LockedMailbox? mailbox,
      MemorySignalTransport? over,
    }) async {
      final BackgroundCapability capability = await publishFor(_masterKey());
      transport = over ?? MemorySignalTransport();
      notices = MemoryRuntimeSystemNotificationService();
      receiver = LockedReceiver(
        transport: transport,
        capability: capability,
        inbox: SealedInboxWriter(
          file: await serviceVault.inboxFile(),
          recipientPublicKey: capability.inboxPublicKey,
        ),
        notices: notices,
        mailboxPollInterval: Duration.zero,
        taken: taken,
        mailbox: mailbox,
        now: () => clock,
      );
      await receiver.start();
      transport.sentSignals.clear();
    }

    tearDown(() async {
      await receiver.stop();
    });

    Future<void> receive(String from, Map<String, dynamic> payload) async {
      await receiver.handleFrame(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: clock,
        ),
      );
    }

    List<Map<String, dynamic>> sent(
      String type, {
      String? to,
    }) => <Map<String, dynamic>>[
      for (final ({String remoteAddress, Map<String, dynamic> payload}) s
          in transport.sentSignals)
        if (s.payload['type'] == type && (to == null || s.remoteAddress == to))
          s.payload,
    ];

    test('the same message directly and then from a mailbox: kept and told '
        'once, the mailbox hears it is here', () async {
      await startReceiver();
      await receive(_ada, <String, dynamic>{
        'type': 'message',
        '_rid': 'r1',
        'text': 'Hej',
      });
      // Minutes later the mailbox (bob's phone) hands the same over.
      clock += const Duration(minutes: 5).inMilliseconds;
      await receive(_bob, <String, dynamic>{
        'type': 'rly_mail',
        'items': <Object>[_envelope('r1', from: _ada)],
      });

      expect(receiver.keptCount, 1);
      expect(notices.activeNotifications, hasLength(1));
      expect(notices.audibleAlertCount, 1);
      expect(sent('rly_mail_ack', to: _bob).single['ids'], <String>['r1']);
    });

    test('a mailbox handing the same mail over at every poll: kept and told '
        'once', () async {
      await startReceiver();
      for (int poll = 0; poll < 3; poll++) {
        await receive(_bob, <String, dynamic>{
          'type': 'rly_mail',
          'items': <Object>[_envelope('m1', from: _ada)],
        });
        clock += kLockedMailboxPollInterval.inMilliseconds;
      }
      // And the same message straight from its sender after all.
      await receive(_ada, <String, dynamic>{
        'type': 'message',
        '_rid': 'm1',
        'text': 'Hej',
      });

      expect(receiver.keptCount, 1);
      expect(notices.audibleAlertCount, 1);
      expect(sent('rly_mail_ack', to: _bob), hasLength(3));
      expect(sent('rly_ack', to: _ada).single['rid'], 'm1');
    });

    test('mail straight from a sender\'s locked outbox is confirmed to the '
        'sender, so it stops sending it again', () async {
      await startReceiver();
      final Map<String, dynamic> mail = <String, dynamic>{
        'type': 'rly_mail',
        'items': <Object>[_envelope('q1', from: _ada)],
      };
      await receive(_ada, mail);
      clock += const Duration(minutes: 10).inMilliseconds;
      await receive(_ada, mail);

      expect(receiver.keptCount, 1);
      expect(notices.audibleAlertCount, 1);
      expect(
        sent('rly_ack', to: _ada).map((Map<String, dynamic> p) => p['rid']),
        <String>['q1', 'q1'],
      );
    });

    test('what the app took before it locked is confirmed, never kept or told '
        'about again', () async {
      await startReceiver(
        taken: <String>{
          LockedMailboxKit.takenTag(_ada, 'old'),
          LockedMailboxKit.takenTag(_ada, 'older'),
        },
      );
      // The sender missed the app's confirmation and sends it again.
      await receive(_ada, <String, dynamic>{
        'type': 'message',
        '_rid': 'old',
        'text': 'Hej',
      });
      // A mailbox still had a copy of another one.
      await receive(_bob, <String, dynamic>{
        'type': 'rly_mail',
        'items': <Object>[_envelope('older', from: _ada)],
      });

      expect(receiver.keptCount, 0);
      expect(notices.activeNotifications, isEmpty);
      expect(sent('rly_ack', to: _ada).single['rid'], 'old');
      expect(sent('rly_mail_ack', to: _bob).single['ids'], <String>['older']);
    });

    test('a frame without a reliable id that comes again later is kept '
        'once', () async {
      await startReceiver();
      final Map<String, dynamic> announce = <String, dynamic>{
        'type': 'rly_announce',
        'v': 3,
        'relays': <String>[_bob],
      };
      await receive(_ada, announce);
      clock += const Duration(minutes: 2).inMilliseconds;
      await receive(_ada, announce);
      expect(receiver.keptCount, 1);
    });

    test('with a mailbox kit the phone stays a mailbox: a friend\'s sender who '
        'is no contact here leaves mail, the friend collects it', () async {
      const String self = 'me.ygg';
      final MemorySignalTransport shared = MemorySignalTransport();
      LockedMailboxKit? saved;
      final LockedMailbox mailbox = LockedMailbox(
        transport: shared,
        kit: const LockedMailboxKit(
          self: self,
          served: <String, LockedMailboxPeer>{
            _ada: LockedMailboxPeer(relays: <String>[self, _bob]),
          },
        ),
        isFriend: (String a) => a == _ada || a == _bob,
        isContact: (String a) => a == _ada || a == _bob,
        save: (LockedMailboxKit kit) async => saved = kit,
        now: () => clock,
      );
      await startReceiver(mailbox: mailbox, over: shared);

      await receive(_stranger, <String, dynamic>{
        'type': 'rly_deposit',
        'env': _envelope('d1', from: _stranger, to: _ada, now: clock),
      });
      expect(mailbox.heldFor(_ada), <String>['d1']);
      expect(saved?.held[_ada]?.keys, <String>['d1']);
      expect(sent('rly_deposit_ack', to: _stranger).single['id'], 'd1');

      await receive(_ada, <String, dynamic>{'type': 'rly_poll'});
      final List<Map<String, dynamic>> mail = sent('rly_mail', to: _ada);
      expect(mail, isNotEmpty);
      expect((mail.last['items'] as List).single['id'], 'd1');

      await receive(_ada, <String, dynamic>{
        'type': 'rly_mail_ack',
        'ids': <String>['d1'],
      });
      expect(mailbox.heldFor(_ada), isEmpty);
      expect(saved?.tombstones.keys, <String>['$_ada|d1']);
      // Nothing of it went into this phone's own inbox, nothing was told.
      expect(receiver.keptCount, 0);
      expect(notices.activeNotifications, isEmpty);
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

/// Holds and releases asked of the phone (alarms as plain timers).
/// Ada unlinked the phone at [_ada]; nothing else is known.
final class _UnlinkedAda implements AccountDeviceDirectory {
  @override
  String get ownAccount => 'ME';

  @override
  String? accountOf(String address) => null;

  @override
  List<String> addressesOf(String account) => const <String>[];

  @override
  String? contactAddressOf(String account) => null;

  @override
  String? unlinkedAccountOf(String address) => address == _ada ? 'ADA' : null;
}

final class _WakeCalls implements ZenWakePlatform {
  final List<String> calls = <String>[];

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) => const TimerWakePlatform().after(
    name,
    delay,
    fire,
    hold: hold,
    exact: exact,
    whileIdle: whileIdle,
  );

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();

  @override
  Future<void> hold(String tag, Duration duration) async =>
      calls.add('hold $tag ${duration.inSeconds}');

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async =>
      calls.add('release $tag ${after.inMilliseconds}');
}

/// Alarms as the phone would get them, rung by the test.
final class _BeatAlarms implements ZenWakePlatform {
  final List<_BeatAlarm> _alarms = <_BeatAlarm>[];

  List<WakeTimer> get live => <WakeTimer>[
    for (final _BeatAlarm a in _alarms)
      if (a.isActive) a,
  ];

  Duration delayOf(WakeTimer alarm) => (alarm as _BeatAlarm).delay;

  Future<void> ring(WakeTimer alarm) async {
    final _BeatAlarm a = alarm as _BeatAlarm;
    a.fired = true;
    await a.fire();
  }

  @override
  WakeTimer after(
    String name,
    Duration delay,
    FutureOr<void> Function() fire, {
    required Duration hold,
    required bool exact,
    bool whileIdle = true,
  }) {
    final _BeatAlarm alarm = _BeatAlarm(delay, fire);
    _alarms.add(alarm);
    return alarm;
  }

  @override
  Future<void> holdForCall(bool on) async {}

  @override
  Stream<void> get appGone => const Stream<void>.empty();

  @override
  Future<void> hold(String tag, Duration duration) async {}

  @override
  Future<void> release(String tag, {Duration after = Duration.zero}) async {}
}

final class _BeatAlarm implements WakeTimer {
  _BeatAlarm(this.delay, this.fire);

  final Duration delay;
  final FutureOr<void> Function() fire;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() => cancelled = true;
}
