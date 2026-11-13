import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/queued_signal.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/chat/disappearing_messages.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// A message that was deleted for everyone, disappeared or was edited
/// leaves nothing of its words behind (the in-app list of notifications,
/// the copies queued for the app's return, the shade), and a file of a
/// deleted message is not kept when it comes late: each device runs the
/// chat over the reliable queue and its mailboxes on a simulated network.

String _addr(String raw) => PeerShareCodec.normalizeAddress(raw);
final String alice = _addr('200::a1');
final String bob = _addr('200::b2');
final String carol = _addr('200::c3');

final class _Mesh {
  int now = 5000000;
  final Map<String, _Device> devices = <String, _Device>{};
  final Queue<({String from, String to, Map<String, dynamic> payload})> queue =
      Queue<({String from, String to, Map<String, dynamic> payload})>();

  bool isOnline(String address) => devices[address]?.online ?? false;

  void carry(String from, String to, Map<String, dynamic> payload) {
    if (!isOnline(from)) {
      throw StateError('$from is offline');
    }
    if (!isOnline(to)) {
      return;
    }
    queue.add((
      from: from,
      to: to,
      payload: jsonDecode(jsonEncode(payload)) as Map<String, dynamic>,
    ));
  }

  Future<void> settle() async {
    int quietRounds = 0;
    for (int round = 0; round < 2000 && quietRounds < 6; round++) {
      if (queue.isEmpty) {
        quietRounds++;
      } else {
        quietRounds = 0;
        while (queue.isNotEmpty) {
          final ({String from, String to, Map<String, dynamic> payload}) d =
              queue.removeFirst();
          devices[d.to]?.raw.inject(d.from, d.payload, now);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<void> advance(Duration duration) async {
    now += duration.inMilliseconds;
    for (final _Device device in devices.values) {
      if (device.online) {
        await device.engine.tick();
      }
    }
    await settle();
  }

  Future<void> until(Future<bool> Function() done, {String? reason}) async {
    for (int i = 0; i < 300; i++) {
      if (await done()) {
        return;
      }
      await settle();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('timed out waiting: ${reason ?? ''}');
  }
}

final class _RawSimTransport implements SignalTransport {
  _RawSimTransport(this.mesh, this.address);

  final _Mesh mesh;
  final String address;
  final StreamController<SignalTransportFrame> _frames =
      StreamController<SignalTransportFrame>.broadcast(sync: true);

  void inject(String from, Map<String, dynamic> payload, int at) {
    _frames.add(
      SignalTransportFrame(from: from, payload: payload, receivedAtMillis: at),
    );
  }

  @override
  Stream<SignalTransportFrame> get frames => _frames.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    mesh.carry(address, _addr(remoteAddress), payload);
  }

  @override
  Future<int> openRelay({
    required String callId,
    required String remoteAddress,
  }) async => 0;

  @override
  Future<void> closeRelay(String callId) async {}
}

/// Blocks kept once for everyone (what the ledger does across devices);
/// a fetch waits for [gate] while one is set, and finds nothing while
/// [missing].
final class _SharedBlocks implements ChatMediaBlocks {
  final Map<String, Uint8List> held = <String, Uint8List>{};
  Completer<void>? gate;
  bool missing = false;

  @override
  Future<Map<String, dynamic>> store(
    Uint8List bytes, {
    required String mime,
    int? durationMs,
  }) async {
    final String id = 'blk-${held.length}';
    held[id] = Uint8List.fromList(bytes);
    return <String, dynamic>{'id': id, 'mime': mime, 'n': bytes.length};
  }

  @override
  Future<Uint8List?> fetch(
    Map<String, dynamic> ref,
    List<String> sources, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    await gate?.future;
    return missing ? null : held[ref['id']];
  }
}

/// Transfers in memory; [allStale] makes every unfinished incoming one
/// count as abandoned (written to longer ago than the sweep waits).
final class _Transfers implements AttachmentTransferStore {
  final MemoryAttachmentTransferStore inner = MemoryAttachmentTransferStore();
  bool allStale = false;

  @override
  Future<OutgoingAttachmentTransfer?> loadOutgoing(String p, String id) =>
      inner.loadOutgoing(p, id);

  @override
  Future<List<OutgoingAttachmentTransfer>> loadAllOutgoing() =>
      inner.loadAllOutgoing();

  @override
  Future<void> saveOutgoing(OutgoingAttachmentTransfer transfer) =>
      inner.saveOutgoing(transfer);

  @override
  Future<void> deleteOutgoing(String p, String id) =>
      inner.deleteOutgoing(p, id);

  @override
  Future<IncomingAttachmentTransfer?> loadIncoming(String p, String id) =>
      inner.loadIncoming(p, id);

  @override
  Future<void> saveIncoming(IncomingAttachmentTransfer transfer) =>
      inner.saveIncoming(transfer);

  @override
  Future<void> deleteIncoming(String p, String id) =>
      inner.deleteIncoming(p, id);

  @override
  Future<int> countIncoming(String p) => inner.countIncoming(p);

  @override
  Future<int> deleteStaleIncoming({required int olderThanMillis}) =>
      inner.deleteStaleIncoming(
        olderThanMillis: allStale
            ? DateTime.now().millisecondsSinceEpoch + 1
            : olderThanMillis,
      );
}

final class _Device implements RelayPeerSource {
  _Device(this.mesh, this.address, this.directory, List<String> friends)
    : runtime = RuntimeNodeRuntime.live(
        bootstrap: () async => RuntimeNodeSession(
          transport: MemorySignalTransport(),
          snapshot: RuntimeTransportSnapshot.started(
            localAddress: address,
            peers: 1,
          ),
        ),
      ) {
    raw = _RawSimTransport(mesh, address);
    engine = RelayEngine(
      store: relayStore,
      blobStore: relayStore,
      peers: this,
      send: (String to, Map<String, dynamic> payload) =>
          raw.send(remoteAddress: to, payload: payload),
      clock: () => mesh.now,
    );
    transport = ReliableSignalTransport(
      delegate: raw,
      engine: engine,
      tickInterval: const Duration(days: 1),
    );
    container = ProviderContainer(
      overrides: [
        signalQueueStoreProvider.overrideWithValue(queue),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          DisappearingTimelineStore(timelines, now: () => mesh.now),
        ),
        attachmentTransferStoreProvider.overrideWithValue(transfers),
        signalTransportProvider.overrideWithValue(transport),
        relayEngineProvider.overrideWithValue(engine),
        runtimeNodeRuntimeProvider.overrideWithValue(runtime),
        supportDirectoryResolverProvider.overrideWithValue(
          () async => directory,
        ),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                for (final String friend in friends)
                  friend: FriendProfile(
                    address: friend,
                    displayName: friend,
                    status: FriendRelationshipStatus.accepted,
                  ),
              },
            ),
          ),
        ),
      ],
    );
    _subscription = transport.frames.listen((SignalTransportFrame frame) {
      final ZenSignal? signal = zenSignalFromTransportPayload(
        sender: frame.from,
        payload: frame.payload,
      );
      if (signal != null) {
        unawaited(
          controller.receiveSignal(
            signal,
            receivedAtMillis: frame.receivedAtMillis,
          ),
        );
      }
    });
    mesh.devices[address] = this;
  }

  final _Mesh mesh;
  final String address;
  final Directory directory;
  final RuntimeNodeRuntime runtime;
  final MemoryRelayStateStore relayStore = MemoryRelayStateStore();
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  final MemorySignalQueueStore queue = MemorySignalQueueStore();
  final _Transfers transfers = _Transfers();
  late final _RawSimTransport raw;
  late final RelayEngine engine;
  late final ReliableSignalTransport transport;
  late final ProviderContainer container;
  late final StreamSubscription<SignalTransportFrame> _subscription;
  bool online = false;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  /// The notifications in the shade now.
  List<RuntimeSystemNotification> get shade =>
      (container.read(runtimeSystemNotificationServiceProvider)
              as MemoryRuntimeSystemNotificationService)
          .activeNotifications;

  /// Every word this phone keeps about messages outside the chat: the
  /// in-app list, the queued copies, the shade.
  Future<List<String>> said() async => <String>[
    for (final InboxEntry e in state.inbox) 'inbox:${e.body}',
    for (final InboxEntry e in state.backgroundAlerts) 'alert:${e.body}',
    for (final QueuedSignal q in await queue.load())
      'queued:${q.signal.content}',
    for (final RuntimeSystemNotification n in shade) ...<String>[
      'shade:${n.body}',
      for (final String line in n.lines) 'shade:$line',
    ],
  ];

  @override
  bool get isReady => true;

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];

  @override
  String get localAddress => address;

  @override
  List<RelayFriend> acceptedFriends() => state.acceptedFriends
      .map((FriendProfile f) => RelayFriend(address: f.address))
      .toList();

  Future<void> goOnline() async {
    online = true;
    await transport.start();
    await mesh.settle();
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await transport.dispose();
    container.dispose();
    await runtime.stop();
  }

  /// The message [id] in [key], as kept here.
  Future<ChatMessage?> message(String key, String id) async =>
      (await timelines.load(
        key,
      )).where((ChatMessage m) => m.id == id).firstOrNull;

  /// How many files this phone keeps (the media vault among them). A file
  /// being written is renamed into place meanwhile: one gone between the
  /// listing and the look at it is not kept.
  int fileCount() =>
      directory.listSync(recursive: true).whereType<File>().where((File f) {
        try {
          return f.lengthSync() > 0;
        } on FileSystemException {
          return false;
        }
      }).length;
}

Future<_Mesh> _buildMesh() async {
  final _Mesh mesh = _Mesh();
  final List<String> everyone = <String>[alice, bob, carol];
  for (final String address in everyone) {
    final Directory dir = await Directory.systemTemp.createTemp('zen-gone-');
    addTearDown(() => dir.delete(recursive: true));
    final _Device device = _Device(
      mesh,
      address,
      dir,
      everyone.where((String a) => a != address).toList(),
    );
    addTearDown(device.dispose);
    await device.runtime.start();
    await device.controller.hydrateFromStore();
  }
  for (final _Device device in mesh.devices.values) {
    await device.goOnline();
  }
  await mesh.advance(const Duration(seconds: 1));
  await mesh.advance(const Duration(seconds: 6));
  return mesh;
}

/// A group of alice (its creator), bob and carol, joined by both.
Future<GroupProfile> _group(_Mesh mesh) async {
  final _Device a = mesh.devices[alice]!;
  final GroupProfile group = await a.controller.createGroup(
    name: 'Ekipa',
    description: '',
    memberAddresses: <String>[bob, carol],
  );
  await mesh.settle();
  for (final String member in <String>[bob, carol]) {
    await mesh.devices[member]!.controller.acceptGroupInvite(
      groupId: group.id,
      groupName: 'Ekipa',
      senderAddress: alice,
    );
  }
  await mesh.settle();
  await mesh.advance(const Duration(seconds: 5));
  return group;
}

Future<ChatMessage> _sentText(_Device device, String key, String text) async =>
    (await device.timelines.load(
      key,
    )).singleWhere((ChatMessage m) => m.isOutgoing && m.text == text);

Uint8List _bytes(int length, int seed) {
  final Random random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Matcher _mentions(String words) => anyElement(contains(words));

ZenSignal _fileChunk(String id, Uint8List data, int index, int count, int at) =>
    ZenSignal(
      type: ZenSignalType.messageChunk,
      sender: alice,
      messageId: id,
      content: 'umowa.pdf',
      messageType: ChatMessageType.file,
      fileName: 'umowa.pdf',
      mimeType: 'application/pdf',
      attachmentSizeBytes: data.length,
      attachmentTransferBytes: data.length,
      chunkIndex: index,
      chunkCount: count,
      chunkData: base64Encode(
        data.sublist(
          index * (data.length ~/ count),
          (index + 1) * (data.length ~/ count),
        ),
      ),
      sentAtMillis: at,
    );

ZenSignal _filePlaceholder(String id, Uint8List data, int count, int at) =>
    ZenSignal(
      type: ZenSignalType.message,
      sender: alice,
      messageId: id,
      content: 'umowa.pdf',
      messageType: ChatMessageType.file,
      fileName: 'umowa.pdf',
      mimeType: 'application/pdf',
      attachmentSizeBytes: data.length,
      attachmentTransferBytes: data.length,
      chunkCount: count,
      isPlaceholder: true,
      sentAtMillis: at,
    );

void main() {
  test('a message deleted for everyone leaves no words in the friend\'s '
      'notifications, their list or the queued copy', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    await a.controller.sendLocalMessage(
      peerAddress: bob,
      text: 'Haslo do wifi: tajne123',
    );
    await mesh.settle();
    expect(await b.said(), _mentions('tajne123'), reason: 'told of it first');
    expect(
      b.state.backgroundAlerts.single.messageId,
      isNotNull,
      reason: 'the entry knows its message',
    );
    final ChatMessage mine = await _sentText(a, bob, 'Haslo do wifi: tajne123');

    await a.controller.deleteMessageForEveryone(
      conversationKey: bob,
      messageId: mine.id,
    );
    await mesh.settle();

    expect((await b.message(alice, mine.id))!.isDeleted, isTrue);
    expect(await b.said(), isNot(_mentions('tajne123')));
    expect(
      b.state.friendByAddress(alice)!.lastMessagePreview,
      isNot(contains('tajne123')),
      reason: 'nor the chat list line',
    );
  });

  test('a disappeared message leaves no words in the notifications or the '
      'list', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    await a.controller.setDisappearingTimer(bob, 3600);
    await mesh.settle();
    await a.controller.sendLocalMessage(peerAddress: bob, text: 'Znikam 42');
    await mesh.settle();
    final ChatMessage mine = await _sentText(a, bob, 'Znikam 42');
    expect((await b.message(alice, mine.id))!.disappears, isTrue);
    expect(await b.said(), _mentions('Znikam 42'));

    mesh.now += const Duration(hours: 2).inMilliseconds;
    await b.controller.sweepDisappearingMessages();

    expect(await b.message(alice, mine.id), isNull);
    expect(await b.said(), isNot(_mentions('Znikam 42')));
  });

  test('an edited message: the notifications say the new words, never the '
      'old ones', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    await a.controller.sendLocalMessage(peerAddress: bob, text: 'Pin 4711');
    await mesh.settle();
    final ChatMessage mine = await _sentText(a, bob, 'Pin 4711');
    expect(await b.said(), _mentions('Pin 4711'));

    await a.controller.editMessage(
      conversationKey: bob,
      messageId: mine.id,
      text: 'Zadzwon pozniej',
    );
    await mesh.settle();

    expect((await b.message(alice, mine.id))!.text, 'Zadzwon pozniej');
    expect(await b.said(), isNot(_mentions('Pin 4711')));
    expect(
      b.state.backgroundAlerts.single.body,
      'Zadzwon pozniej',
      reason: 'the list tells of the message as it is now',
    );
  });

  test('a group message deleted by its author leaves nothing in the other '
      'members\' notifications', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device b = mesh.devices[bob]!;
    final _Device c = mesh.devices[carol]!;
    final GroupProfile group = await _group(mesh);
    final String key = 'group:${group.id}';
    await b.controller.sendGroupMessage(groupId: group.id, text: 'Kod 9911');
    await mesh.settle();
    expect(await c.said(), _mentions('Kod 9911'));
    final ChatMessage mine = await _sentText(b, key, 'Kod 9911');

    await b.controller.deleteMessageForEveryone(
      conversationKey: key,
      messageId: mine.id,
    );
    await mesh.settle();

    expect(await c.said(), isNot(_mentions('Kod 9911')));
    expect(c.state.groups[group.id]!.lastMessagePreview, isNot('Kod 9911'));
  });

  test('chunks of a file arriving after its deletion for everyone are not '
      'stored under the deleted message', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device b = mesh.devices[bob]!;
    final int t0 = mesh.now;
    const String id = 'outgoing-big-1';
    final Uint8List data = Uint8List.fromList(
      List<int>.generate(64, (int i) => i),
    );
    await b.controller.receiveSignal(
      _filePlaceholder(id, data, 2, t0),
      receivedAtMillis: t0,
    );
    expect(await b.message(alice, id), isNotNull);
    expect(await b.transfers.loadIncoming(alice, id), isNotNull);
    await b.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageDelete,
        sender: alice,
        messageId: id,
      ),
      receivedAtMillis: t0 + 1000,
    );
    expect((await b.message(alice, id))!.isDeleted, isTrue);
    expect(
      await b.transfers.loadIncoming(alice, id),
      isNull,
      reason: 'the deletion ends the transfer',
    );
    final int files = b.fileCount();
    for (int i = 0; i < 2; i++) {
      await b.controller.receiveSignal(
        _fileChunk(id, data, i, 2, t0),
        receivedAtMillis: t0 + 2000 + i,
      );
    }
    await mesh.settle();
    final ChatMessage after = (await b.message(alice, id))!;
    expect(after.isDeleted, isTrue);
    expect(after.hasAttachment, isFalse);
    expect(after.text, isEmpty);
    expect(await b.transfers.loadIncoming(alice, id), isNull);
    expect(b.fileCount(), files, reason: 'no file kept for nobody');
  });

  test('deleting one\'s own file for everyone stops its transfer', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    const String id = 'outgoing-big-2';
    final Uint8List data = _bytes(4096, 3);
    await a.timelines.append(
      bob,
      ChatMessage(
        id: id,
        sender: 'self',
        text: 'umowa.pdf',
        sentAtMillis: mesh.now,
        direction: ChatMessageDirection.outgoing,
        type: ChatMessageType.file,
        attachmentBytes: data,
        fileName: 'umowa.pdf',
        deliveryState: ChatMessageDeliveryState.sending,
      ),
    );
    await a.transfers.saveOutgoing(
      OutgoingAttachmentTransfer(
        peerAddress: bob,
        messageId: id,
        text: 'umowa.pdf',
        sentAtMillis: mesh.now,
        type: ChatMessageType.file,
        attachmentBytes: data,
        fileName: 'umowa.pdf',
        placeholderSent: true,
      ),
    );

    await a.controller.deleteMessageForEveryone(
      conversationKey: bob,
      messageId: id,
    );

    expect(await a.transfers.loadOutgoing(bob, id), isNull);
    expect((await a.message(bob, id))!.isDeleted, isTrue);
  });

  test('a deletion that comes before its message: the message never shows '
      'and tells of nothing', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device b = mesh.devices[bob]!;
    final int t0 = mesh.now;
    const String id = 'outgoing-early-1';
    await b.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageDelete,
        sender: alice,
        messageId: id,
      ),
      receivedAtMillis: t0,
    );
    await b.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.message,
        sender: alice,
        messageId: id,
        content: 'Zle wyslane: 1234',
        sentAtMillis: t0 - 1000,
      ),
      receivedAtMillis: t0 + 1000,
    );
    await mesh.settle();
    expect(await b.message(alice, id), isNull);
    expect(await b.said(), isNot(_mentions('1234')));
  });

  test('an edit that comes before its message is applied once it is '
      'here', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device b = mesh.devices[bob]!;
    final int t0 = mesh.now;
    const String id = 'outgoing-early-2';
    await b.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageEdit,
        sender: alice,
        messageId: id,
        content: 'Spotkanie o 18',
        sentAtMillis: t0,
      ),
      receivedAtMillis: t0,
    );
    await b.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.message,
        sender: alice,
        messageId: id,
        content: 'Spotkanie o 17',
        sentAtMillis: t0 - 1000,
      ),
      receivedAtMillis: t0 + 1000,
    );
    await mesh.settle();
    final ChatMessage here = (await b.message(alice, id))!;
    expect(here.text, 'Spotkanie o 18');
    expect(here.isEdited, isTrue);
    expect(await b.said(), isNot(_mentions('Spotkanie o 17')));
  });

  test(
    'a group file fetched after its message was deleted is not kept',
    () async {
      final _Mesh mesh = await _buildMesh();
      final _SharedBlocks blocks = _SharedBlocks();
      for (final _Device device in mesh.devices.values) {
        device.container.read(chatMediaBlocksHolderProvider).blocks = blocks;
      }
      final _Device b = mesh.devices[bob]!;
      final _Device c = mesh.devices[carol]!;
      final GroupProfile group = await _group(mesh);
      final String key = 'group:${group.id}';
      final int files = c.fileCount();
      blocks.gate = Completer<void>();
      await b.controller.sendGroupAttachment(
        groupId: group.id,
        bytes: _bytes(300 * 1000, 7),
        fileName: 'dane.bin',
        mimeType: 'application/octet-stream',
        type: ChatMessageType.file,
      );
      await mesh.settle();
      final ChatMessage mine = (await b.timelines.load(
        key,
      )).singleWhere((ChatMessage m) => m.isOutgoing);
      await b.controller.deleteMessageForEveryone(
        conversationKey: key,
        messageId: mine.id,
      );
      await mesh.settle();
      blocks.gate!.complete();
      blocks.gate = null;
      await mesh.settle();
      // The file is sealed into the vault on another isolate: wait until it
      // shows there (and is gone again), or long enough that it would.
      for (int i = 0; i < 100 && c.fileCount() == files; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));

      final ChatMessage there = (await c.timelines.load(
        key,
      )).singleWhere((ChatMessage m) => !m.isSystem && !m.isOutgoing);
      expect(there.isDeleted, isTrue);
      expect(there.hasAttachment, isFalse);
      expect(c.fileCount(), files, reason: 'the fetched file was deleted');
    },
  );

  test('a group file whose blocks nobody has any more says so instead of '
      '"Transfer w toku" for ever', () async {
    final _Mesh mesh = await _buildMesh();
    final _SharedBlocks blocks = _SharedBlocks()..missing = true;
    for (final _Device device in mesh.devices.values) {
      device.container.read(chatMediaBlocksHolderProvider).blocks = blocks;
    }
    final _Device b = mesh.devices[bob]!;
    final _Device c = mesh.devices[carol]!;
    final GroupProfile group = await _group(mesh);
    final String key = 'group:${group.id}';
    // Sent long before now (the simulated clock): its blocks are gone.
    await b.controller.sendGroupAttachment(
      groupId: group.id,
      bytes: _bytes(300 * 1000, 8),
      fileName: 'stare.bin',
      mimeType: 'application/octet-stream',
      type: ChatMessageType.file,
    );
    await mesh.settle();
    await mesh.until(() async {
      final ChatMessage m = (await c.timelines.load(
        key,
      )).singleWhere((ChatMessage m) => !m.isSystem && !m.isOutgoing);
      return m.pendingMedia == null;
    }, reason: 'the fetch is given up');
    final ChatMessage there = (await c.timelines.load(
      key,
    )).singleWhere((ChatMessage m) => !m.isSystem && !m.isOutgoing);
    expect(there.attachmentUnavailable, isTrue);
    expect(there.hasAttachment, isFalse);
  });

  test('after the sweep of abandoned incoming transfers their messages say '
      'the file will not come', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device b = mesh.devices[bob]!;
    final Uint8List data = _bytes(64, 5);
    final int t0 = mesh.now;
    for (int i = 0; i < kMaxConcurrentIncomingTransfersPerPeer; i++) {
      await b.controller.receiveSignal(
        _filePlaceholder('outgoing-old-$i', data, 2, t0),
        receivedAtMillis: t0 + i,
      );
    }
    b.transfers.allStale = true;
    // One more transfer: there is no room, so the abandoned ones are swept.
    await b.controller.receiveSignal(
      _filePlaceholder('outgoing-new', data, 2, t0),
      receivedAtMillis: t0 + 100,
    );
    await mesh.settle();
    for (int i = 0; i < kMaxConcurrentIncomingTransfersPerPeer; i++) {
      final ChatMessage old = (await b.message(alice, 'outgoing-old-$i'))!;
      expect(old.attachmentUnavailable, isTrue, reason: 'outgoing-old-$i');
    }
  });
}
