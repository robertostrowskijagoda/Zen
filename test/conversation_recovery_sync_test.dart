import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/account/circle_backup.dart';
import 'package:zen/src/features/account/circle_backup_service.dart';
import 'package:zen/src/features/account/device_chat_sync.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Getting a conversation back after the account is recovered: as far as it
/// can be rebuilt from what others still hold.
///
/// * The recovery circle's copy brings back the text of the conversations
///   and the description of every file message, never the files themselves.
/// * The account's other devices bring back the history, and a file only
///   when that device still has it.
///
/// A file that does not come must leave a readable message, never a crash;
/// taking the same history twice must not double it; the order stays.

String _a(String s) => PeerShareCodec.normalizeAddress(s);

const String _peer = 'ada';

ChatMessage _msg(
  String id,
  int at, {
  String? text,
  bool mine = false,
  ChatMessageType type = ChatMessageType.text,
  String? fileName,
  String? mimeType,
  int? size,
  Uint8List? bytes,
  String? path,
}) => ChatMessage(
  id: id,
  sender: mine ? 'self' : _peer,
  text: text ?? 'tekst $id',
  sentAtMillis: at,
  direction: mine
      ? ChatMessageDirection.outgoing
      : ChatMessageDirection.incoming,
  deliveryState: mine
      ? ChatMessageDeliveryState.delivered
      : ChatMessageDeliveryState.none,
  type: type,
  fileName: fileName,
  mimeType: mimeType,
  attachmentSizeBytes: size,
  attachmentBytes: bytes,
  attachmentPath: path,
);

/// One phone: the social layer on memory stores, and the part of the
/// circle copy that puts conversations back.
final class _Phone {
  _Phone._(this.container, this.hub, this.restorer);

  final ProviderContainer container;
  final SocialHubController hub;
  final AppCircleBackupData restorer;

  static Future<_Phone> create() async {
    final Directory dir = Directory.systemTemp.createTempSync('zen-recover-');
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
        supportDirectoryResolverProvider.overrideWithValue(() async => dir),
      ],
    );
    final SocialHubController hub = container.read(
      socialHubControllerProvider.notifier,
    );
    await hub.whenHydrated;
    // Only conversations are put back in these tests: the node would be
    // used for the friends' levels, which are not in the copy here.
    final LedgerNode node = LedgerNode(
      transport: MemorySignalTransport(),
      disk: MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => _a('200::f0'),
      syncInterval: Duration.zero,
    );
    final Provider<AppCircleBackupData> restorer =
        Provider<AppCircleBackupData>(
          (Ref ref) => AppCircleBackupData(ref, node),
        );
    final _Phone phone = _Phone._(container, hub, container.read(restorer));
    addTearDown(() {
      container.dispose();
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Still open on Windows: left to the system's temp cleaning.
      }
    });
    return phone;
  }

  Future<List<ChatMessage>> messages([String key = _peer]) =>
      hub.conversationMessages(key);

  Future<List<String>> ids([String key = _peer]) async => <String>[
    for (final ChatMessage m in await messages(key)) m.id,
  ];

  Future<void> add(ChatMessage m, {Uint8List? bytes, String key = _peer}) =>
      hub.importSyncedMessage(key, m, bytes: bytes);

  /// The conversations as the circle copy keeps them.
  Future<CircleBackupContent> copyContent([
    List<String> keys = const <String>[_peer],
  ]) async => CircleBackupContent(
    chats: <String, List<Map<String, dynamic>>>{
      for (final String key in keys)
        key: <Map<String, dynamic>>[
          for (final ChatMessage m in await messages(key)) chatMessageToSync(m),
        ],
    },
  );

  Future<void> putBack(CircleBackupContent content) =>
      restorer.restore(content, (int done, int total) {});
}

/// The copy of [content] as a holder keeps it, opened by the recovered
/// account (same account key, another phone).
Future<({CircleBackupContent opened, int dropped})> _viaCircle(
  CircleBackupContent content, {
  int maxBytes = kCircleBackupMaxBytes,
}) async {
  final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
    MemoryLedgerDisk(),
  );
  final CircleBackupBuild build = await buildCircleBackup(
    content: content,
    account: me.account,
    selfKey: me.selfKey!,
    deviceKey: me.deviceKey,
    certificate: me.certificate,
    at: 1000,
    maxBytes: maxBytes,
  );
  final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
    MemoryLedgerDisk(),
    me.accountKey!.seed,
  );
  final CircleBackupOpened opened = await openCircleBackup(
    manifest: build.manifest,
    chunks: build.chunks,
    account: recovered.account,
    selfKey: recovered.selfKey!,
  );
  expect(opened.error, isNull);
  return (opened: opened.content!, dropped: build.droppedMessages);
}

Future<void> _settle([int rounds = 80]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settleServices(List<CircleBackupService> services) async {
  for (int i = 0; i < 200; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    for (final CircleBackupService s in services) {
      await s.idle;
    }
  }
}

/// What the circle service collects and where it puts a copy back.
final class _HubData implements CircleBackupData {
  _HubData({this.source, this.restoreInto});

  final _Phone? source;
  final _Phone? restoreInto;

  @override
  Future<CircleBackupContent> collect({required bool chats}) async =>
      source == null ? const CircleBackupContent() : source!.copyContent();

  @override
  Future<void> restore(
    CircleBackupContent content,
    void Function(int done, int total) progress,
  ) async {
    await restoreInto?.putBack(content);
    progress(1, 1);
  }
}

/// The device that has the history, as the sync sees it.
final class _SourceTarget implements ChatSyncTarget {
  final Map<String, List<ChatMessage>> chats = <String, List<ChatMessage>>{};

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
  }) async {}

  @override
  Future<void> forgetFriendFromOtherDevice(
    String address, {
    int atMillis = 0,
  }) async {}

  @override
  Future<void> forgetGroupFromOtherDevice(String groupId) async {}
}

/// The new phone's social layer as the sync sees it.
final class _HubTarget implements ChatSyncTarget {
  _HubTarget(this.hub, this.keys);

  final SocialHubController hub;
  final List<String> keys;

  @override
  List<String> conversationKeys() => keys;

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

/// The new phone's social layer, where the person removed some messages.
final class _RemovingTarget extends _HubTarget {
  _RemovingTarget(SocialHubController hub) : super(hub, <String>[_peer]);

  final Set<String> removed = <String>{};
  final List<String> importedAfterRemoval = <String>[];

  @override
  Future<List<ChatMessage>> conversationMessages(String key) async =>
      <ChatMessage>[
        for (final ChatMessage m in await super.conversationMessages(key))
          if (!removed.contains(m.id)) m,
      ];

  @override
  Future<void> importSyncedMessage(
    String key,
    ChatMessage message, {
    Uint8List? bytes,
    String? storedPath,
  }) {
    if (removed.contains(message.id)) {
      importedAfterRemoval.add(message.id);
    }
    return super.importSyncedMessage(
      key,
      message,
      bytes: bytes,
      storedPath: storedPath,
    );
  }
}

final class _LedgerLink extends MemorySignalTransport {
  _LedgerLink(this.address);

  static final Map<String, _LedgerLink> nodes = <String, _LedgerLink>{};

  /// The device that had the files no longer answers for them: after the
  /// first blob asked for (the history bundle) no other is delivered.
  static bool oldDeviceLostFiles = false;
  static Object? _firstWanted;

  static void reset() {
    nodes.clear();
    oldDeviceLostFiles = false;
    _firstWanted = null;
  }

  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    if (oldDeviceLostFiles && payload['type'] == 'lg_blob_want') {
      _firstWanted ??= payload['id'];
      if (payload['id'] != _firstWanted) {
        return;
      }
    }
    final _LedgerLink? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<_LedgerLink> _transport(String address) async {
  final _LedgerLink t = _LedgerLink(_a(address));
  _LedgerLink.nodes[_a(address)] = t;
  await t.start();
  return t;
}

LedgerNode _node(_LedgerLink t, {MemoryLedgerDisk? disk}) {
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    friendAddresses: () => const <String>[],
    bridges: BridgeBook(probe: (String _) async => null),
    localAddress: () => t.address,
    greetAlso: () => const <String>[],
    syncInterval: Duration.zero,
  );
  addTearDown(n.stop);
  return n;
}

/// Memory transports that deliver to each other through JSON, as the
/// network would.
final class _CircleLink extends MemorySignalTransport {
  _CircleLink(String address)
    : address = PeerShareCodec.normalizeAddress(address) {
    nodes[this.address] = this;
  }

  static final Map<String, _CircleLink> nodes = <String, _CircleLink>{};
  final String address;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    await super.send(remoteAddress: remoteAddress, payload: payload);
    final _CircleLink? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      final Map<String, dynamic> wire =
          jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: wire),
      );
    }
  }
}

void main() {
  group('the recovery circle copy brings the conversation back', () {
    test('a text conversation returns whole, in order, as it was', () async {
      final _Phone before = await _Phone.create();
      await before.add(_msg('m1', 1000, mine: true, text: 'Czesc'));
      await before.add(_msg('m2', 2000, text: 'Hej, co slychac?'));
      await before.add(
        _msg('m3', 3000, mine: true, text: 'Dobrze, a u Ciebie?'),
      );
      await before.add(_msg('m4', 4000, text: 'Tez'));
      await before.add(
        _msg('g1', 1500, mine: true, text: 'W grupie'),
        key: 'group:g1',
      );

      final got = await _viaCircle(
        await before.copyContent(<String>[_peer, 'group:g1']),
      );
      expect(got.dropped, 0);

      final _Phone after = await _Phone.create();
      await after.putBack(got.opened);

      final List<ChatMessage> restored = await after.messages();
      expect(restored.map((ChatMessage m) => m.id), <String>[
        'm1',
        'm2',
        'm3',
        'm4',
      ]);
      expect(restored.map((ChatMessage m) => m.text), <String>[
        'Czesc',
        'Hej, co slychac?',
        'Dobrze, a u Ciebie?',
        'Tez',
      ]);
      expect(restored.map((ChatMessage m) => m.direction), <Object>[
        ChatMessageDirection.outgoing,
        ChatMessageDirection.incoming,
        ChatMessageDirection.outgoing,
        ChatMessageDirection.incoming,
      ]);
      expect(restored.map((ChatMessage m) => m.sentAtMillis), <int>[
        1000,
        2000,
        3000,
        4000,
      ]);
      expect(await after.ids('group:g1'), <String>['g1']);
    });

    test(
      'what the holder no longer has does not come back, and nothing fails',
      () async {
        final _Phone before = await _Phone.create();
        await before.add(_msg('old1', 1000));
        await before.add(_msg('old2', 2000));
        // The copy is made now ...
        final CircleBackupContent copy = await before.copyContent();
        // ... and these came after it.
        await before.add(_msg('late1', 3000, mine: true));
        await before.add(_msg('late2', 4000));

        final got = await _viaCircle(copy);
        final _Phone after = await _Phone.create();
        await after.putBack(got.opened);

        expect(await after.ids(), <String>['old1', 'old2']);
      },
    );

    test('a copy over its size cap lost its oldest months: those stay gone, '
        'the rest returns in order', () async {
      final _Phone before = await _Phone.create();
      final String filler = 'x' * 400;
      final List<String> all = <String>[];
      for (int month = 0; month < 12; month++) {
        for (int i = 0; i < 20; i++) {
          final String id = 'm$month-$i';
          all.add(id);
          await before.add(
            _msg(
              id,
              DateTime.utc(2025, 1 + month, 10, i).millisecondsSinceEpoch,
              text: 'wiadomosc $id $filler',
            ),
          );
        }
      }
      final got = await _viaCircle(
        await before.copyContent(),
        maxBytes: 40 * 1024,
      );
      expect(got.dropped, greaterThan(0));

      final _Phone after = await _Phone.create();
      await after.putBack(got.opened);
      final List<String> back = await after.ids();

      expect(back.length, all.length - got.dropped);
      expect(back, all.sublist(got.dropped), reason: 'the newest remain');
      final List<ChatMessage> messages = await after.messages();
      for (int i = 1; i < messages.length; i++) {
        expect(
          messages[i].sentAtMillis,
          greaterThanOrEqualTo(messages[i - 1].sentAtMillis),
        );
      }
    });

    test('an empty copy and broken entries are skipped quietly', () async {
      final _Phone after = await _Phone.create();
      await after.putBack(const CircleBackupContent());
      await after.putBack(
        CircleBackupContent(
          chats: <String, List<Map<String, dynamic>>>{
            _peer: <Map<String, dynamic>>[
              <String, dynamic>{'id': 7, 's': 'ada', 't': 'x', 'at': 1},
              <String, dynamic>{'t': 'bez identyfikatora'},
              chatMessageToSync(_msg('ok', 5000)),
            ],
            'pusta': <Map<String, dynamic>>[],
          },
        ),
      );
      expect(await after.ids(), <String>['ok']);
      expect(await after.ids('pusta'), isEmpty);
    });

    test('files are not in the copy: the message comes back described, '
        'without a file, and does not fail', () async {
      final _Phone before = await _Phone.create();
      await before.add(
        _msg(
          'p1',
          1000,
          type: ChatMessageType.image,
          text: '',
          fileName: 'kot.jpg',
          mimeType: 'image/jpeg',
          size: 4,
        ),
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      await before.add(
        _msg(
          'f1',
          2000,
          mine: true,
          type: ChatMessageType.file,
          text: '',
          fileName: 'plan.pdf',
          mimeType: 'application/pdf',
          size: 3,
        ),
        bytes: Uint8List.fromList(<int>[7, 7, 7]),
      );
      await before.add(_msg('t1', 3000, text: 'tekst po plikach'));
      final List<ChatMessage> original = await before.messages();
      expect(original[0].hasAttachment, isTrue);
      expect(original[1].hasAttachment, isTrue);

      final got = await _viaCircle(await before.copyContent());
      final _Phone after = await _Phone.create();
      await after.putBack(got.opened);

      final List<ChatMessage> restored = await after.messages();
      expect(restored.map((ChatMessage m) => m.id), <String>['p1', 'f1', 't1']);
      expect(restored[0].type, original[0].type);
      expect(restored[0].fileName, original[0].fileName);
      expect(restored[0].hasAttachment, isFalse, reason: 'no file in a copy');
      expect(
        restored[0].attachmentUnavailable,
        isTrue,
        reason: 'the file does not come from the copy',
      );
      expect(restored[1].type, ChatMessageType.file);
      expect(restored[1].fileName, 'plan.pdf');
      expect(restored[1].attachmentSizeBytes, 3);
      expect(restored[1].hasAttachment, isFalse);
      expect(restored[1].attachmentUnavailable, isTrue);
      expect(restored[2].text, 'tekst po plikach');
      expect(restored[2].attachmentUnavailable, isFalse, reason: 'text');
    });

    test('a file the phone already has is not taken away by a copy without '
        'it, and a file that turns up later fills the message in', () async {
      final _Phone after = await _Phone.create();
      final ChatMessage described = _msg(
        'p1',
        1000,
        type: ChatMessageType.image,
        text: '',
        fileName: 'kot.jpg',
        mimeType: 'image/jpeg',
        size: 4,
      );
      // The friend sent the photo again, live: it is here with its file.
      await after.add(described, bytes: Uint8List.fromList(<int>[1, 2, 3, 4]));
      await after.putBack(
        CircleBackupContent(
          chats: <String, List<Map<String, dynamic>>>{
            _peer: <Map<String, dynamic>>[chatMessageToSync(described)],
          },
        ),
      );
      List<ChatMessage> now = await after.messages();
      expect(now, hasLength(1));
      expect(now.single.hasAttachment, isTrue);
      expect(now.single.attachmentUnavailable, isFalse);
      expect(
        await after.container
            .read(mediaVaultProvider)
            .read(now.single.attachmentPath!),
        <int>[1, 2, 3, 4],
      );

      // The other way round: described first, the file comes later.
      final ChatMessage second = _msg(
        'f2',
        2000,
        type: ChatMessageType.file,
        text: '',
        fileName: 'plan.pdf',
        size: 3,
      );
      await after.putBack(
        CircleBackupContent(
          chats: <String, List<Map<String, dynamic>>>{
            _peer: <Map<String, dynamic>>[chatMessageToSync(second)],
          },
        ),
      );
      expect((await after.messages()).last.hasAttachment, isFalse);
      expect((await after.messages()).last.attachmentUnavailable, isTrue);
      await after.add(second, bytes: Uint8List.fromList(<int>[7, 7, 7]));
      now = await after.messages();
      expect(now.map((ChatMessage m) => m.id), <String>['p1', 'f2']);
      expect(now.last.hasAttachment, isTrue);
      expect(now.last.attachmentUnavailable, isFalse);
    });

    test('a message the copy left without its file may still get it from '
        "the account's other device: its word wins while the file is "
        'missing', () async {
      final _Phone after = await _Phone.create();
      final ChatMessage photo = _msg(
        'p1',
        1000,
        type: ChatMessageType.image,
        text: '',
        fileName: 'kot.jpg',
        size: 4,
      );
      await after.putBack(
        CircleBackupContent(
          chats: <String, List<Map<String, dynamic>>>{
            _peer: <Map<String, dynamic>>[chatMessageToSync(photo)],
          },
        ),
      );
      expect((await after.messages()).single.attachmentUnavailable, isTrue);

      // The other device has the file and is sending it: on its way.
      await after.add(photo);
      expect((await after.messages()).single.attachmentUnavailable, isFalse);

      // It gave up on it after all.
      await after.add(chatMessageWithoutFile(photo));
      expect((await after.messages()).single.attachmentUnavailable, isTrue);

      // A text message is never marked.
      expect(
        chatMessageWithoutFile(_msg('t', 1)).attachmentUnavailable,
        isFalse,
      );
    });

    test('the mark travels with the message and is kept', () {
      final ChatMessage gone = chatMessageWithoutFile(
        _msg('p1', 1000, type: ChatMessageType.video, text: ''),
      );
      expect(gone.attachmentUnavailable, isTrue);
      expect(
        chatMessageFromSync(chatMessageToSync(gone))!.attachmentUnavailable,
        isTrue,
      );
      expect(
        chatMessageFromSync(
          chatMessageToSync(gone.copyWith(attachmentUnavailable: false)),
        )!.attachmentUnavailable,
        isFalse,
      );
    });

    test('taking the same copy twice does not double the messages', () async {
      final _Phone before = await _Phone.create();
      await before.add(_msg('m1', 1000));
      await before.add(_msg('m2', 2000, mine: true));
      await before.add(_msg('m3', 3000));
      final CircleBackupContent copy = (await _viaCircle(
        await before.copyContent(),
      )).opened;

      final _Phone after = await _Phone.create();
      await after.putBack(copy);
      await after.putBack(copy);
      expect(await after.ids(), <String>['m1', 'm2', 'm3']);

      // A newer copy: the old ones stay single, the new one is added.
      await before.add(_msg('m4', 4000, mine: true));
      final CircleBackupContent newer = (await _viaCircle(
        await before.copyContent(),
      )).opened;
      await after.putBack(newer);
      await after.putBack(newer);
      expect(await after.ids(), <String>['m1', 'm2', 'm3', 'm4']);
    });

    test(
      'a copy of older history goes before a message that came live first',
      () async {
        final _Phone before = await _Phone.create();
        await before.add(_msg('m1', 1000));
        await before.add(_msg('m2', 2000));
        await before.add(_msg('m3', 3000));
        final CircleBackupContent copy = (await _viaCircle(
          await before.copyContent(),
        )).opened;

        // On the new phone a friend's message arrives before the copy does.
        final _Phone after = await _Phone.create();
        await after.add(_msg('live', 9000));
        await after.putBack(copy);

        expect(await after.ids(), <String>['m1', 'm2', 'm3', 'live']);
      },
    );

    test('history taken in any order lands by send time; a message already '
        'here keeps its place', () async {
      final _Phone phone = await _Phone.create();
      await phone.add(_msg('m3', 3000));
      await phone.add(_msg('m5', 5000, mine: true));
      await phone.add(_msg('m1', 1000));
      await phone.add(_msg('m4', 4000));
      await phone.add(_msg('m2', 2000, mine: true));
      await phone.add(_msg('m6', 6000));
      // Taken again (another copy, another device): still once each.
      await phone.add(_msg('m1', 1000));
      await phone.add(_msg('m6', 6000));
      expect(await phone.ids(), <String>['m1', 'm2', 'm3', 'm4', 'm5', 'm6']);
    });
  });

  group('a file message without its file', () {
    Future<void> pump(WidgetTester tester, ChatMessage m) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ZenTheme.dark(),
            home: Scaffold(body: ChatAttachmentBody(message: m)),
          ),
        ),
      );
      await tester.pump();
    }

    for (final ChatMessageType type in <ChatMessageType>[
      ChatMessageType.image,
      ChatMessageType.file,
      ChatMessageType.voice,
      ChatMessageType.video,
    ]) {
      testWidgets(
        'is shown with its name (${type.name}), without an exception',
        (WidgetTester tester) async {
          // Exactly what the copy gives: described, never with the file.
          final ChatMessage? m = chatMessageFromSync(
            chatMessageToSync(
              _msg(
                'x1',
                1000,
                type: type,
                text: '',
                fileName: 'zalacznik.bin',
                mimeType: 'application/octet-stream',
                size: 2048,
              ),
            ),
          );
          expect(m, isNotNull);
          expect(m!.hasAttachment, isFalse);
          await pump(tester, m);
          expect(tester.takeException(), isNull);
          expect(find.text('zalacznik.bin'), findsOneWidget);
        },
      );

      testWidgets('says the file is not available when it will not come, '
          'not that it is on its way (${type.name})', (
        WidgetTester tester,
      ) async {
        await pump(
          tester,
          chatMessageWithoutFile(
            _msg(
              'x1',
              1000,
              type: type,
              text: '',
              fileName: 'stary.bin',
              size: 2048,
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(find.text('stary.bin'), findsOneWidget);
        expect(find.text('Plik niedostępny'), findsOneWidget);
        expect(find.text('Transfer w toku'), findsNothing);
      });

      testWidgets('a file still on its way says so (${type.name})', (
        WidgetTester tester,
      ) async {
        await pump(
          tester,
          _msg('x1', 1000, type: type, text: '', fileName: 'w-drodze.bin'),
        );
        expect(find.text('Transfer w toku'), findsOneWidget);
        expect(find.text('Plik niedostępny'), findsNothing);

        await pump(
          tester,
          _msg(
            'x2',
            1000,
            type: type,
            text: '',
            fileName: 'w-drodze.bin',
            size: 2048,
          ),
        );
        expect(find.text('2.0 KB'), findsOneWidget);
        expect(find.text('Plik niedostępny'), findsNothing);
      });
    }
  });

  group('the account\'s other device brings the history back', () {
    setUp(_LedgerLink.reset);

    Future<({LedgerNode first, LedgerNode second, DeviceChatSync firstSync})>
    pair(String a1, String a2, _SourceTarget source) async {
      final _LedgerLink t1 = await _transport(a1);
      final _LedgerLink t2 = await _transport(a2);
      final MemoryLedgerDisk d1 = MemoryLedgerDisk();
      final MemoryLedgerDisk d2 = MemoryLedgerDisk();
      final LedgerNode first = _node(t1, disk: d1);
      await first.start();
      final DeviceChatSync firstSync = DeviceChatSync(
        node: first,
        target: source,
      );
      await firstSync.start();
      addTearDown(firstSync.stop);
      final LedgerIdentity id1 = await LedgerIdentity.loadOrCreate(d1);
      // The recovered account: the same account key on a new device.
      await LedgerIdentity.adoptAccount(d2, id1.accountKey!.seed);
      final LedgerNode second = _node(t2, disk: d2);
      await second.start();
      return (first: first, second: second, firstSync: firstSync);
    }

    test('files come only when the other device still has them; a lost '
        'file leaves a readable message; a second sync does not double '
        'anything; the order stays', () async {
      final String a1 = _a('200::e1');
      final String a2 = _a('200::e2');
      final _SourceTarget source = _SourceTarget()
        ..chats[_peer] = <ChatMessage>[
          _msg('m1', 1000, mine: true),
          _msg(
            'm2',
            2000,
            type: ChatMessageType.image,
            text: '',
            fileName: 'jest.jpg',
            mimeType: 'image/jpeg',
            size: 3,
            bytes: Uint8List.fromList(<int>[1, 2, 3]),
          ),
          // The file of this one is gone from the device that has the
          // history (deleted, storage cleaned).
          _msg(
            'm3',
            3000,
            type: ChatMessageType.image,
            text: '',
            fileName: 'zniknal.jpg',
            mimeType: 'image/jpeg',
            size: 9,
            path: '${Directory.systemTemp.path}/zen-nie-ma-takiego-pliku.jpg',
          ),
          _msg('m4', 4000),
        ];
      final p = await pair(a1, a2, source);

      final _Phone phone = await _Phone.create();
      final _HubTarget target = _HubTarget(phone.hub, <String>[_peer]);
      DeviceChatSync sync = DeviceChatSync(node: p.second, target: target);
      await sync.start();
      addTearDown(() => sync.stop());
      await p.second.rememberDeviceAddresses(<String>[a1]);
      await _settle(200);
      await p.firstSync.idle;
      await _settle(200);
      await sync.idle;

      List<ChatMessage> got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>[
        'm1',
        'm2',
        'm3',
        'm4',
      ]);
      expect(got.map((ChatMessage m) => m.sentAtMillis), <int>[
        1000,
        2000,
        3000,
        4000,
      ]);
      expect(got[1].hasAttachment, isTrue, reason: 'the device had it');
      expect(
        await phone.container
            .read(mediaVaultProvider)
            .read(got[1].attachmentPath!),
        <int>[1, 2, 3],
      );
      expect(got[2].type, ChatMessageType.image);
      expect(got[2].fileName, 'zniknal.jpg');
      expect(got[2].hasAttachment, isFalse, reason: 'it was lost there');
      expect(got[2].attachmentUnavailable, isTrue, reason: 'it will not come');
      expect(got[1].attachmentUnavailable, isFalse);
      expect(got[0].attachmentUnavailable, isFalse, reason: 'text');
      expect(await sync.waitingFiles(), 0, reason: 'nothing to wait for');

      // The same history again (the app restarted, the sync started anew).
      await sync.stop();
      sync = DeviceChatSync(node: p.second, target: target);
      await sync.start();
      await _settle(100);
      await sync.idle;
      got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>[
        'm1',
        'm2',
        'm3',
        'm4',
      ]);
      expect(got[1].hasAttachment, isTrue);

      // A message sent meanwhile on the old device lands once, last.
      p.firstSync.onOutgoing(_peer, _msg('m5', 5000, mine: true));
      await _settle(200);
      await sync.idle;
      expect(await phone.ids(), <String>['m1', 'm2', 'm3', 'm4', 'm5']);
    });

    test('a file the old device cannot hand over now waits and the message '
        'is there; asking again changes nothing and does not fail; the file '
        'comes once the old device has it again', () async {
      final String a1 = _a('200::e3');
      final String a2 = _a('200::e4');
      final Uint8List film = Uint8List.fromList(
        List<int>.generate(200 * 1024, (int i) => i % 251),
      );
      final _SourceTarget source = _SourceTarget()
        ..chats[_peer] = <ChatMessage>[
          _msg('m1', 1000, mine: true),
          _msg(
            'v1',
            2000,
            type: ChatMessageType.video,
            text: '',
            fileName: 'film.mp4',
            mimeType: 'video/mp4',
            size: film.length,
            bytes: film,
          ),
          _msg('m2', 3000),
        ];
      final p = await pair(a1, a2, source);
      _LedgerLink.oldDeviceLostFiles = true;

      final _Phone phone = await _Phone.create();
      final DeviceChatSync sync = DeviceChatSync(
        node: p.second,
        target: _HubTarget(phone.hub, <String>[_peer]),
        fileWait: const Duration(milliseconds: 300),
      );
      await sync.start();
      addTearDown(sync.stop);
      await p.second.rememberDeviceAddresses(<String>[a1]);
      await _settle(200);
      await p.firstSync.idle;
      await _settle(200);
      await sync.idle;

      List<ChatMessage> got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>['m1', 'v1', 'm2']);
      expect(got[1].fileName, 'film.mp4');
      expect(got[1].hasAttachment, isFalse);
      expect(got[1].attachmentUnavailable, isFalse, reason: 'still may come');
      expect(await sync.waitingFiles(), 1, reason: 'remembered, not lost');

      // Asked again, still nothing: no failure, no duplicate, still waiting.
      await sync.retryWaitingFiles();
      await sync.retryWaitingFiles();
      got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>['m1', 'v1', 'm2']);
      expect(got[1].hasAttachment, isFalse);
      expect(await sync.waitingFiles(), 1);

      // The old device answers again: the file comes into the same message.
      _LedgerLink.oldDeviceLostFiles = false;
      await sync.retryWaitingFiles();
      await _settle(100);
      got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>['m1', 'v1', 'm2']);
      expect(got[1].hasAttachment, isTrue);
      expect(got[1].attachmentUnavailable, isFalse);
      expect(await sync.waitingFiles(), 0);
    });

    test('a file the old device never hands over is given up after enough '
        'tries over enough time: the message says it is not available and '
        'it is not asked for again', () async {
      final String a1 = _a('200::e5');
      final String a2 = _a('200::e6');
      final _SourceTarget source = _SourceTarget()
        ..chats[_peer] = <ChatMessage>[
          _msg('m1', 1000, mine: true),
          _msg(
            'v1',
            2000,
            type: ChatMessageType.video,
            text: '',
            fileName: 'film.mp4',
            mimeType: 'video/mp4',
            size: 3,
            bytes: Uint8List.fromList(<int>[4, 5, 6]),
          ),
          _msg('m2', 3000),
        ];
      final p = await pair(a1, a2, source);
      _LedgerLink.oldDeviceLostFiles = true;

      int now = 1000000;
      final _Phone phone = await _Phone.create();
      final DeviceChatSync sync = DeviceChatSync(
        node: p.second,
        target: _HubTarget(phone.hub, <String>[_peer]),
        fileWait: const Duration(milliseconds: 50),
        fileAttempts: 3,
        fileGiveUpAfter: const Duration(hours: 1),
        clock: () => now,
      );
      await sync.start();
      addTearDown(sync.stop);
      await p.second.rememberDeviceAddresses(<String>[a1]);
      await _settle(200);
      await p.firstSync.idle;
      await _settle(200);
      await sync.idle;
      expect(await sync.waitingFiles(), 1);

      // Many tries, but all within the hour: the old device may be off.
      for (int i = 0; i < 5; i++) {
        await sync.retryWaitingFiles();
      }
      expect(await sync.waitingFiles(), 1);
      expect((await phone.messages())[1].attachmentUnavailable, isFalse);

      // Long enough and asked often enough: given up.
      now += const Duration(hours: 2).inMilliseconds;
      await sync.retryWaitingFiles();
      expect(await sync.waitingFiles(), 0);
      List<ChatMessage> got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>['m1', 'v1', 'm2']);
      expect(got[1].hasAttachment, isFalse);
      expect(got[1].attachmentUnavailable, isTrue);
      expect(got[1].fileName, 'film.mp4');

      // Not asked for again, nothing doubled.
      _LedgerLink.oldDeviceLostFiles = false;
      await sync.retryWaitingFiles();
      await _settle(50);
      got = await phone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>['m1', 'v1', 'm2']);
      expect(got[1].hasAttachment, isFalse);
      expect(await sync.waitingFiles(), 0);
    });

    test('a waiting file whose message was removed here meanwhile is given '
        'up without bringing the message back', () async {
      final String a1 = _a('200::e7');
      final String a2 = _a('200::e8');
      final _SourceTarget source = _SourceTarget()
        ..chats[_peer] = <ChatMessage>[
          _msg(
            'v1',
            2000,
            type: ChatMessageType.video,
            text: '',
            fileName: 'film.mp4',
            size: 3,
            bytes: Uint8List.fromList(<int>[4, 5, 6]),
          ),
        ];
      final p = await pair(a1, a2, source);
      _LedgerLink.oldDeviceLostFiles = true;

      int now = 1000000;
      final _Phone phone = await _Phone.create();
      final _RemovingTarget target = _RemovingTarget(phone.hub);
      final DeviceChatSync sync = DeviceChatSync(
        node: p.second,
        target: target,
        fileWait: const Duration(milliseconds: 50),
        fileAttempts: 1,
        fileGiveUpAfter: Duration.zero,
        clock: () => now,
      );
      await sync.start();
      addTearDown(sync.stop);
      await p.second.rememberDeviceAddresses(<String>[a1]);
      await _settle(200);
      await p.firstSync.idle;
      await _settle(200);
      await sync.idle;
      expect(await sync.waitingFiles(), 1);

      target.removed.add('v1');
      now += 1;
      await sync.retryWaitingFiles();
      expect(await sync.waitingFiles(), 0);
      expect(target.importedAfterRemoval, isEmpty);
    });
  });

  group('the whole way: a friend holds the copy, a new phone asks', () {
    setUp(_CircleLink.nodes.clear);

    Future<
      ({
        CircleBackupService holder,
        CircleBackupService fresh,
        _Phone oldPhone,
        _Phone newPhone,
      })
    >
    scene({bool ownerMakesCopy = true}) async {
      final LedgerIdentity me = await LedgerIdentity.loadOrCreate(
        MemoryLedgerDisk(),
      );
      final _CircleLink tOwner = _CircleLink('200::a');
      final _CircleLink tHolder = _CircleLink('200::b');
      final _CircleLink tNew = _CircleLink('200::c');
      for (final _CircleLink t in <_CircleLink>[tOwner, tHolder, tNew]) {
        await t.start();
      }
      CircleBackupIdentity idOf(LedgerIdentity i) => CircleBackupIdentity(
        account: i.account,
        selfKey: i.selfKey!,
        deviceKey: i.deviceKey,
        certificate: i.certificate,
      );
      final _Phone oldPhone = await _Phone.create();
      await oldPhone.add(_msg('m1', 1000, mine: true));
      await oldPhone.add(_msg('m2', 2000));
      await oldPhone.add(
        _msg(
          'p1',
          3000,
          type: ChatMessageType.image,
          text: '',
          fileName: 'kot.jpg',
          size: 4,
        ),
        bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      await oldPhone.add(_msg('m3', 4000, mine: true));
      final CircleBackupService owner = CircleBackupService(
        transport: tOwner,
        disk: MemoryLedgerDisk(),
        data: _HubData(source: oldPhone),
        identity: () => idOf(me),
        holders: () => <String>[tHolder.address],
        isInCircle: (_) => false,
        restoreCandidates: () => const <String>[],
      );
      final CircleBackupService holder = CircleBackupService(
        transport: tHolder,
        disk: MemoryLedgerDisk(),
        data: _HubData(),
        identity: () => null,
        holders: () => const <String>[],
        isInCircle: (String a) => a == me.account,
        restoreCandidates: () => const <String>[],
      );
      await holder.start();
      if (ownerMakesCopy) {
        await owner.start();
        await _settleServices(<CircleBackupService>[owner, holder]);
        expect(holder.holder.kept.keys, <String>[me.account]);
      }

      final MemoryLedgerDisk newDisk = MemoryLedgerDisk();
      final LedgerIdentity recovered = await LedgerIdentity.adoptAccount(
        newDisk,
        me.accountKey!.seed,
      );
      await CircleBackupService.markRestore(
        newDisk,
        helpers: <String>[tHolder.address],
      );
      final _Phone newPhone = await _Phone.create();
      final CircleBackupService fresh = CircleBackupService(
        transport: tNew,
        disk: newDisk,
        data: _HubData(restoreInto: newPhone),
        identity: () => idOf(recovered),
        holders: () => const <String>[],
        isInCircle: (_) => false,
        restoreCandidates: () => const <String>[],
      );
      for (final CircleBackupService s in <CircleBackupService>[
        owner,
        holder,
        fresh,
      ]) {
        addTearDown(s.stop);
      }
      return (
        holder: holder,
        fresh: fresh,
        oldPhone: oldPhone,
        newPhone: newPhone,
      );
    }

    test('the conversation returns from the friend; the photo comes back '
        'as a message without its file', () async {
      final s = await scene();
      await s.fresh.start();
      await _settleServices(<CircleBackupService>[s.fresh, s.holder]);

      expect(s.fresh.restore.value.phase, CircleBackupRestorePhase.done);
      final List<ChatMessage> got = await s.newPhone.messages();
      expect(got.map((ChatMessage m) => m.id), <String>[
        'm1',
        'm2',
        'p1',
        'm3',
      ]);
      expect(got[2].fileName, 'kot.jpg');
      expect(got[2].hasAttachment, isFalse);
      expect(got[2].attachmentUnavailable, isTrue, reason: 'not on its way');
      expect(s.fresh.restoring, isFalse);
    });

    test('what came after the friend\'s last copy does not return', () async {
      final s = await scene();
      await s.oldPhone.add(_msg('m4', 5000));
      await s.oldPhone.add(_msg('m5', 6000, mine: true));
      await s.fresh.start();
      await _settleServices(<CircleBackupService>[s.fresh, s.holder]);

      expect(s.fresh.restore.value.phase, CircleBackupRestorePhase.done);
      expect(await s.newPhone.ids(), <String>['m1', 'm2', 'p1', 'm3']);
    });

    test('the friend has no copy at all: nothing returns, nothing fails, '
        'and it keeps asking', () async {
      final s = await scene(ownerMakesCopy: false);
      await s.fresh.start();
      await _settleServices(<CircleBackupService>[s.fresh, s.holder]);

      expect(s.fresh.restore.value.phase, isNot(CircleBackupRestorePhase.done));
      expect(
        s.fresh.restore.value.phase,
        isNot(CircleBackupRestorePhase.failed),
      );
      expect(s.fresh.restoring, isTrue);
      expect(await s.newPhone.ids(), isEmpty);
    });
  });
}
