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
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/chat_media_blocks.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Replies, reactions, edits, deleting for everyone, forwarding and files in
/// groups, end to end: each device runs the chat over the reliable queue
/// and its mailboxes on a simulated network.

String _addr(String raw) => PeerShareCodec.normalizeAddress(raw);
final String alice = _addr('200::a1');
final String bob = _addr('200::b2');
final String carol = _addr('200::c3');
final String dave = _addr('200::d4');

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

/// Blocks kept once for everyone (what the ledger does across devices).
final class _SharedBlocks implements ChatMediaBlocks {
  final Map<String, Uint8List> held = <String, Uint8List>{};
  final List<List<String>> asked = <List<String>>[];
  int stores = 0;

  @override
  Future<Map<String, dynamic>> store(
    Uint8List bytes, {
    required String mime,
    int? durationMs,
  }) async {
    stores++;
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
    asked.add(sources);
    return held[ref['id']];
  }
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
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
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
  late final _RawSimTransport raw;
  late final RelayEngine engine;
  late final ReliableSignalTransport transport;
  late final ProviderContainer container;
  late final StreamSubscription<SignalTransportFrame> _subscription;
  bool online = false;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

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
}

Future<_Mesh> _buildMesh() async {
  final _Mesh mesh = _Mesh();
  final List<String> everyone = <String>[alice, bob, carol, dave];
  for (final String address in everyone) {
    final Directory dir = await Directory.systemTemp.createTemp('zen-chat-');
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

void main() {
  test('a reply quotes the original, a reaction toggles, an edit and a '
      'deletion reach the friend', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;

    await a.controller.sendLocalMessage(peerAddress: bob, text: 'Idziesz?');
    await mesh.settle();
    final ChatMessage original = await _sentText(a, bob, 'Idziesz?');
    final ChatMessage atBob = (await b.message(alice, original.id))!;

    // Reply.
    await b.controller.sendLocalMessage(
      peerAddress: alice,
      text: 'Pewnie',
      replyTo: b.controller.replyTo(atBob),
    );
    await mesh.settle();
    final ChatMessage reply = (await a.timelines.load(
      bob,
    )).singleWhere((ChatMessage m) => m.text == 'Pewnie');
    expect(reply.reply?.messageId, original.id);
    expect(reply.reply?.text, 'Idziesz?');
    expect(reply.reply?.sender, alice);
    expect((await _sentText(b, alice, 'Pewnie')).reply?.sender, alice);

    // Reaction, then the same again: taken back.
    await b.controller.reactToMessage(
      conversationKey: alice,
      messageId: original.id,
      emoji: '👍',
    );
    await mesh.settle();
    expect((await a.message(bob, original.id))!.reactions, <String, String>{
      bob: '👍',
    });
    expect((await b.message(alice, original.id))!.reactions, <String, String>{
      'self': '👍',
    });
    await b.controller.reactToMessage(
      conversationKey: alice,
      messageId: original.id,
      emoji: '❤️',
    );
    await mesh.settle();
    expect((await a.message(bob, original.id))!.reactions[bob], '❤️');
    await b.controller.reactToMessage(
      conversationKey: alice,
      messageId: original.id,
      emoji: '❤️',
    );
    await mesh.settle();
    expect((await a.message(bob, original.id))!.reactions, isEmpty);
    expect((await b.message(alice, original.id))!.reactions, isEmpty);

    // Edit.
    await a.controller.editMessage(
      conversationKey: bob,
      messageId: original.id,
      text: 'Idziesz jutro?',
    );
    await mesh.settle();
    final ChatMessage edited = (await b.message(alice, original.id))!;
    expect(edited.text, 'Idziesz jutro?');
    expect(edited.isEdited, isTrue);
    expect((await a.message(bob, original.id))!.isEdited, isTrue);

    // Delete for everyone.
    await a.controller.deleteMessageForEveryone(
      conversationKey: bob,
      messageId: original.id,
    );
    await mesh.settle();
    for (final ChatMessage gone in <ChatMessage>[
      (await a.message(bob, original.id))!,
      (await b.message(alice, original.id))!,
    ]) {
      expect(gone.isDeleted, isTrue);
      expect(gone.text, isEmpty);
    }
    // The reply no longer quotes its words, on either side.
    for (final ChatMessage answer in <ChatMessage>[
      (await a.timelines.load(
        bob,
      )).singleWhere((ChatMessage m) => m.text == 'Pewnie'),
      await _sentText(b, alice, 'Pewnie'),
    ]) {
      expect(answer.reply?.messageId, original.id);
      expect(answer.reply?.text, isEmpty);
    }
    // Nothing more can be done to it.
    expect(
      a.controller.canDeleteForEveryone(
        bob,
        (await a.message(bob, original.id))!,
      ),
      isFalse,
    );
    expect(
      a.controller.canEditMessage((await a.message(bob, original.id))!),
      isFalse,
    );
  });

  test('only the author edits or deletes; an edit after the window does '
      'nothing', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    await a.controller.sendLocalMessage(peerAddress: bob, text: 'Moje');
    await mesh.settle();
    final ChatMessage mine = await _sentText(a, bob, 'Moje');

    // Bob claims to change alice's message on her phone.
    await a.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageEdit,
        sender: bob,
        messageId: mine.id,
        content: 'Podmienione',
        sentAtMillis: mine.sentAtMillis,
      ),
      receivedAtMillis: mine.sentAtMillis,
    );
    await a.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageDelete,
        sender: bob,
        messageId: mine.id,
      ),
      receivedAtMillis: mine.sentAtMillis,
    );
    final ChatMessage kept = (await a.message(bob, mine.id))!;
    expect(kept.text, 'Moje');
    expect(kept.isEdited, isFalse);
    expect(kept.isDeleted, isFalse);

    // Alice herself, but two days later.
    final int twoDaysOn =
        mine.sentAtMillis + const Duration(days: 2).inMilliseconds;
    await b.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageEdit,
        sender: alice,
        messageId: mine.id,
        content: 'Za późno',
        sentAtMillis: twoDaysOn,
      ),
      receivedAtMillis: twoDaysOn,
    );
    expect((await b.message(alice, mine.id))!.text, 'Moje');
    expect(a.controller.canEditMessage(mine, nowMillis: twoDaysOn), isFalse);
    expect(a.controller.canEditMessage(mine), isTrue);
  });

  test('a forwarded message is marked; a disappearing one cannot be '
      'forwarded or quoted', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    final _Device c = mesh.devices[carol]!;
    await b.controller.sendLocalMessage(peerAddress: alice, text: 'Hasło: kot');
    await mesh.settle();
    final ChatMessage got = (await a.timelines.load(
      bob,
    )).singleWhere((ChatMessage m) => m.text == 'Hasło: kot');

    await a.controller.forwardMessage(
      fromKey: bob,
      messageId: got.id,
      toKey: carol,
    );
    await mesh.settle();
    final ChatMessage atCarol = (await c.timelines.load(
      alice,
    )).singleWhere((ChatMessage m) => m.text == 'Hasło: kot');
    expect(atCarol.forwarded, isTrue);
    expect((await _sentText(a, carol, 'Hasło: kot')).forwarded, isTrue);

    final ChatMessage fleeting = got.copyWith(
      expiresAtMillis: got.sentAtMillis + 60000,
    );
    expect(a.controller.canForwardMessage(fleeting), isFalse);
    expect(a.controller.replyTo(fleeting).text, isEmpty);
    expect(a.controller.replyTo(fleeting).messageId, got.id);
    await a.timelines.save(bob, <ChatMessage>[fleeting]);
    await expectLater(
      a.controller.forwardMessage(
        fromKey: bob,
        messageId: got.id,
        toKey: carol,
      ),
      throwsStateError,
    );
  });

  test('in a group: replies, reactions from members, and the creator '
      'deleting anyone\'s message', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    final _Device c = mesh.devices[carol]!;
    final GroupProfile group = await _group(mesh);
    final String key = 'group:${group.id}';

    await b.controller.sendGroupMessage(groupId: group.id, text: 'Pizza?');
    await mesh.settle();
    final ChatMessage pizza = await _sentText(b, key, 'Pizza?');
    final ChatMessage atCarol = (await c.message(key, pizza.id))!;

    await c.controller.sendGroupMessage(
      groupId: group.id,
      text: 'Tak!',
      replyTo: c.controller.replyTo(atCarol),
    );
    await c.controller.reactToMessage(
      conversationKey: key,
      messageId: pizza.id,
      emoji: '🍕',
    );
    await mesh.settle();
    for (final _Device member in <_Device>[a, b]) {
      final ChatMessage yes = (await member.timelines.load(
        key,
      )).singleWhere((ChatMessage m) => m.text == 'Tak!');
      expect(yes.reply?.messageId, pizza.id, reason: member.address);
      expect(
        (await member.message(key, pizza.id))!.reactions[carol],
        '🍕',
        reason: member.address,
      );
    }

    // Carol is no admin: neither here nor on the others' phones.
    expect(c.controller.canDeleteForEveryone(key, atCarol), isFalse);
    await a.controller.receiveSignal(
      ZenSignal(
        type: ZenSignalType.messageDelete,
        sender: carol,
        messageId: pizza.id,
        groupId: group.id,
      ),
      receivedAtMillis: mesh.now,
    );
    expect((await a.message(key, pizza.id))!.isDeleted, isFalse);

    // Alice made the group.
    final ChatMessage atAlice = (await a.message(key, pizza.id))!;
    expect(a.controller.canDeleteForEveryone(key, atAlice), isTrue);
    await a.controller.deleteMessageForEveryone(
      conversationKey: key,
      messageId: pizza.id,
    );
    await mesh.settle();
    for (final _Device member in <_Device>[a, b, c]) {
      final ChatMessage gone = (await member.message(key, pizza.id))!;
      expect(gone.isDeleted, isTrue, reason: member.address);
      expect(gone.reactions, isEmpty, reason: member.address);
    }
  });

  test('a small file goes to the group inline', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device b = mesh.devices[bob]!;
    final GroupProfile group = await _group(mesh);
    final String key = 'group:${group.id}';
    final Uint8List note = Uint8List.fromList(
      utf8.encode('Lista zakupów: chleb, mleko'),
    );

    await b.controller.sendGroupAttachment(
      groupId: group.id,
      bytes: note,
      fileName: 'lista.txt',
      mimeType: 'text/plain',
      type: ChatMessageType.file,
    );
    await mesh.settle();
    for (final String member in <String>[alice, carol]) {
      final _Device device = mesh.devices[member]!;
      await mesh.until(
        () async => (await device.timelines.load(
          key,
        )).any((ChatMessage m) => m.attachmentPath != null),
        reason: '$member gets the file',
      );
      final ChatMessage file = (await device.timelines.load(
        key,
      )).singleWhere((ChatMessage m) => m.attachmentPath != null);
      expect(file.type, ChatMessageType.file);
      expect(file.sender, bob);
      expect(
        await device.container
            .read(mediaVaultProvider)
            .read(file.attachmentPath!),
        note,
      );
    }
  });

  test('a larger file is sealed once as blocks the members fetch', () async {
    final _Mesh mesh = await _buildMesh();
    final _SharedBlocks blocks = _SharedBlocks();
    for (final _Device device in mesh.devices.values) {
      device.container.read(chatMediaBlocksHolderProvider).blocks = blocks;
    }
    final _Device b = mesh.devices[bob]!;
    final GroupProfile group = await _group(mesh);
    final String key = 'group:${group.id}';
    final Uint8List big = _bytes(300 * 1000, 7);

    await b.controller.sendGroupAttachment(
      groupId: group.id,
      bytes: big,
      fileName: 'dane.bin',
      mimeType: 'application/octet-stream',
      type: ChatMessageType.file,
    );
    await mesh.settle();
    expect(blocks.stores, 1, reason: 'one copy, not one per member');
    for (final String member in <String>[alice, carol]) {
      final _Device device = mesh.devices[member]!;
      await mesh.until(
        () async => (await device.timelines.load(
          key,
        )).any((ChatMessage m) => m.attachmentPath != null),
        reason: '$member fetches the file',
      );
      final ChatMessage file = (await device.timelines.load(
        key,
      )).singleWhere((ChatMessage m) => m.attachmentPath != null);
      expect(file.pendingMedia, isNull);
      expect(
        await device.container
            .read(mediaVaultProvider)
            .read(file.attachmentPath!),
        big,
      );
    }
    expect(blocks.asked, hasLength(2));
    for (final List<String> sources in blocks.asked) {
      expect(sources.first, bob, reason: 'the sender is asked first');
    }
  });

  test('changes made on another device of the account show here as '
      'one\'s own', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    await mesh.devices[bob]!.controller.sendLocalMessage(
      peerAddress: alice,
      text: 'Hej',
    );
    await a.controller.sendLocalMessage(peerAddress: bob, text: 'Cześć');
    await mesh.settle();
    final ChatMessage hej = (await a.timelines.load(
      bob,
    )).singleWhere((ChatMessage m) => m.text == 'Hej');
    final ChatMessage mine = await _sentText(a, bob, 'Cześć');

    await a.controller.recordMirroredSend(bob, <String, dynamic>{
      'type': 'msg_react',
      'msgId': hej.id,
      'emoji': '🔥',
    });
    await a.controller.recordMirroredSend(bob, <String, dynamic>{
      'type': 'msg_edit',
      'msgId': mine.id,
      'text': 'Cześć!',
      'at': mine.sentAtMillis + 1000,
    });
    expect((await a.message(bob, hej.id))!.reactions, <String, String>{
      'self': '🔥',
    });
    final ChatMessage edited = (await a.message(bob, mine.id))!;
    expect(edited.text, 'Cześć!');
    expect(edited.editedAtMillis, mine.sentAtMillis + 1000);

    await a.controller.recordMirroredSend(bob, <String, dynamic>{
      'type': 'msg_delete',
      'msgId': mine.id,
    });
    expect((await a.message(bob, mine.id))!.isDeleted, isTrue);
  });
}
