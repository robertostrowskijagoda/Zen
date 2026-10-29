import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/realtime_attachment_transfer.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/relay/reliable_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

/// Full stack per device, as in `offline_delivery_end_to_end_test.dart`,
/// with attachments through mailboxes switched on: a photo or a file sent to
/// a friend who is offline waits (sealed, in chunks) with their friends and
/// shows up in their chat once they are back — even if the sender is gone by
/// then — and the sender learns it was delivered.

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
      return; // lost, like a datagram to a sleeping phone
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

  /// Runs the network until [done] (sealing and opening megabytes takes a
  /// moment of real time).
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

/// WebRTC is not there: the realtime path gives up at once.
final class _NoRealtimeSession implements RealtimeAttachmentTransferSession {
  @override
  ValueChanged<double>? onProgress;

  @override
  ValueChanged<Uint8List>? onComplete;

  @override
  ValueChanged<Object>? onError;

  @override
  Future<void> send({
    required Uint8List bytes,
    required String text,
    required ChatMessageType type,
    String? fileName,
    String? mimeType,
    int? attachmentSizeBytes,
    int? durationMs,
  }) async {
    throw TimeoutException('no peer connection in tests');
  }

  @override
  Future<void> acceptIncoming({
    required Map<String, dynamic> description,
    required int fileSize,
  }) async {}

  @override
  Future<void> applyRemoteAnswer(Map<String, dynamic> description) async {}

  @override
  Future<void> close() async {}
}

final class _Device implements RelayPeerSource {
  _Device(this.mesh, this.address, this.directory, List<String> friends) {
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
        supportDirectoryResolverProvider.overrideWithValue(
          () async => directory,
        ),
        realtimeAttachmentTransferFactoryProvider.overrideWithValue(
          ({required String transferId, required String remoteAddress}) =>
              _NoRealtimeSession(),
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

  Future<void> goOffline() async {
    online = false;
    await transport.stop();
  }

  Future<void> dispose() async {
    await _subscription.cancel();
    await transport.dispose();
    container.dispose();
  }
}

Future<_Mesh> _buildMesh() async {
  final _Mesh mesh = _Mesh();
  final List<String> everyone = <String>[alice, bob, carol, dave];
  for (final String address in everyone) {
    final Directory dir = await Directory.systemTemp.createTemp('zen-mbx-');
    addTearDown(() => dir.delete(recursive: true));
    final _Device device = _Device(
      mesh,
      address,
      dir,
      everyone.where((String a) => a != address).toList(),
    );
    addTearDown(device.dispose);
  }
  for (final _Device device in mesh.devices.values) {
    await device.goOnline();
  }
  // Relay sets — with the attachment capability — announced and confirmed.
  await mesh.advance(const Duration(seconds: 1));
  await mesh.advance(const Duration(seconds: 6));
  return mesh;
}

Uint8List _randomBytes(int length, int seed) {
  final Random random = Random(seed);
  return Uint8List.fromList(
    List<int>.generate(length, (_) => random.nextInt(256)),
  );
}

Future<ChatMessage?> _receivedFile(_Device device, String from) async {
  for (final ChatMessage m in await device.timelines.load(from)) {
    if (m.direction == ChatMessageDirection.incoming &&
        m.attachmentPath != null) {
      return m;
    }
  }
  return null;
}

Future<ChatMessageDeliveryState?> _stateOfOnlyMessage(
  _Device device,
  String peer,
) async {
  final List<ChatMessage> thread = await device.timelines.load(peer);
  return thread.isEmpty ? null : thread.single.deliveryState;
}

void main() {
  test('a large file sent while the recipient is offline arrives after it '
      'comes back, and the sender learns it was delivered', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    // Over the 1 MB that may go inline: a chunked transfer.
    final Uint8List file = _randomBytes(1100 * 1000, 1);

    await b.goOffline();
    await a.controller.sendLocalAttachment(
      peerAddress: bob,
      bytes: file,
      fileName: 'film.mp4',
      mimeType: 'video/mp4',
      type: ChatMessageType.video,
      sentAtMillis: mesh.now,
    );
    // No live transfer possible: the mailboxes take it over.
    await mesh.until(
      () async =>
          await _stateOfOnlyMessage(a, bob) == ChatMessageDeliveryState.sent,
      reason: 'handed to the mailboxes',
    );
    await mesh.advance(const Duration(seconds: 5)); // manifest to mailboxes
    await a.goOffline();

    await b.goOnline();
    await mesh.until(
      () async => await _receivedFile(b, alice) != null,
      reason: 'bob gets the file',
    );
    final ChatMessage received = (await _receivedFile(b, alice))!;
    // Not a real film: the media guard keeps it as a plain file.
    expect(received.fileName, contains('film'));
    expect(received.attachmentSizeBytes, file.length);
    expect(
      await b.container.read(mediaVaultProvider).read(received.attachmentPath!),
      file,
    );
    expect(
      (await b.timelines.load(
        alice,
      )).where((ChatMessage m) => m.direction == ChatMessageDirection.incoming),
      hasLength(1),
    );

    // Alice returns: bob's receipt, queued while she was away, reaches her.
    await a.goOnline();
    await mesh.advance(const Duration(seconds: 12));
    await mesh.until(
      () async =>
          await _stateOfOnlyMessage(a, bob) ==
          ChatMessageDeliveryState.delivered,
      reason: 'alice learns it was delivered',
    );
    for (final String relay in <String>[carol, dave]) {
      expect(
        (await mesh.devices[relay]!.relayStore.load()).heldBlobs[bob],
        isNull,
        reason: '$relay drops its copy',
      );
    }
  });

  test('a voice message small enough to go inline still waits in the '
      'mailboxes instead of needing both phones online', () async {
    final _Mesh mesh = await _buildMesh();
    final _Device a = mesh.devices[alice]!;
    final _Device b = mesh.devices[bob]!;
    // Well over the 48 kB a single mailbox envelope carries.
    final Uint8List photo = _randomBytes(200 * 1000, 2);

    await b.goOffline();
    await a.controller.sendLocalAttachment(
      peerAddress: bob,
      bytes: photo,
      fileName: 'glosowka.m4a',
      mimeType: 'audio/mp4',
      type: ChatMessageType.voice,
      durationMs: 90000,
      sentAtMillis: mesh.now,
    );
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5)); // cut into a blob
    await mesh.until(
      () async =>
          (await mesh.devices[carol]!.relayStore.load())
              .heldBlobs[bob]
              ?.isNotEmpty ??
          false,
      reason: 'the mailboxes hold it',
    );
    await mesh.advance(const Duration(seconds: 5)); // manifest to mailboxes
    await a.goOffline();

    await b.goOnline();
    await mesh.until(
      () async => await _receivedFile(b, alice) != null,
      reason: 'bob gets the voice message',
    );
    final ChatMessage received = (await _receivedFile(b, alice))!;
    expect(
      await b.container.read(mediaVaultProvider).read(received.attachmentPath!),
      photo,
    );

    await a.goOnline();
    await mesh.advance(const Duration(seconds: 12));
    await mesh.until(
      () async =>
          await _stateOfOnlyMessage(a, bob) ==
          ChatMessageDeliveryState.delivered,
      reason: 'alice learns it was delivered',
    );
    expect((await a.relayStore.load()).outbox, isEmpty);
  });
}
