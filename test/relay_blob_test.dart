import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/features/relay/relay_crypto.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_models.dart';
import 'package:zen/src/features/relay/relay_state_store.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Attachments through mailboxes (blobs): the relay engine on a simulated
/// mesh, like `relay_engine_test.dart`, with chunk storage switched on.

final class _SimMesh {
  int now = 1000000;
  final Map<String, _SimNode> nodes = <String, _SimNode>{};
  final Set<String> online = <String>{};
  final Queue<({String from, String to, Map<String, dynamic> payload})>
  _inFlight = Queue<({String from, String to, Map<String, dynamic> payload})>();

  Map<String, dynamic>? Function(
    String from,
    String to,
    Map<String, dynamic> p,
  )?
  interceptor;

  _SimNode add(String address, {bool blobs = true}) {
    final _SimNode node = _SimNode(this, address, blobs: blobs);
    nodes[address] = node;
    online.add(address);
    return node;
  }

  void befriendAll() {
    for (final _SimNode node in nodes.values) {
      node.friends
        ..clear()
        ..addAll(nodes.keys.where((String a) => a != node.address));
    }
  }

  Future<void> send(
    String from,
    String to,
    Map<String, dynamic> payload,
  ) async {
    if (!online.contains(from)) {
      throw StateError('$from is offline');
    }
    if (!online.contains(to)) {
      return;
    }
    Map<String, dynamic> copy =
        jsonDecode(jsonEncode(payload)) as Map<String, dynamic>;
    final Map<String, dynamic>? Function(String, String, Map<String, dynamic>)?
    hook = interceptor;
    if (hook != null) {
      final Map<String, dynamic>? replaced = hook(from, to, copy);
      if (replaced == null) {
        return;
      }
      copy = replaced;
    }
    _inFlight.add((from: from, to: to, payload: copy));
  }

  Future<void> settle({int maxSteps = 20000}) async {
    int steps = 0;
    while (_inFlight.isNotEmpty) {
      if (++steps > maxSteps) {
        fail('network did not settle');
      }
      final ({String from, String to, Map<String, dynamic> payload}) datagram =
          _inFlight.removeFirst();
      if (!online.contains(datagram.to)) {
        continue;
      }
      await nodes[datagram.to]!.receive(datagram.from, datagram.payload);
    }
  }

  Future<void> advance(Duration duration) async {
    now += duration.inMilliseconds;
    for (final _SimNode node in nodes.values) {
      if (online.contains(node.address)) {
        await node.engine.tick();
      }
    }
    await settle();
  }

  Future<void> goOffline(String address) async {
    online.remove(address);
    nodes[address]!.engine.deactivate();
  }

  Future<void> goOnline(String address) async {
    online.add(address);
    await nodes[address]!.engine.activate();
    await settle();
  }
}

final class _SimNode implements RelayPeerSource {
  _SimNode(this.mesh, this.address, {required this.blobs}) {
    engine = _build();
  }

  final _SimMesh mesh;
  final String address;
  final bool blobs;
  final MemoryRelayStateStore store = MemoryRelayStateStore();
  late RelayEngine engine;
  final List<String> friends = <String>[];
  final List<SignalTransportFrame> appFrames = <SignalTransportFrame>[];

  RelayEngine _build() => RelayEngine(
    store: store,
    blobStore: blobs ? store : null,
    peers: this,
    send: (String to, Map<String, dynamic> payload) =>
        mesh.send(address, to, payload),
    clock: () => mesh.now,
  );

  @override
  bool get isReady => true;

  @override
  String get localAddress => address;

  @override
  List<RelayFriend> groupContacts() => const <RelayFriend>[];

  @override
  List<RelayFriend> acceptedFriends() => friends
      .map(
        (String a) => RelayFriend(
          address: a,
          // Helpers look a touch more active, so automatic selection picks
          // them as mailboxes and never alice/bob.
          lastSeenAtMillis: !mesh.online.contains(a)
              ? 0
              : mesh.now - (helpers.contains(a) ? 0 : 1),
        ),
      )
      .toList();

  Future<void> receive(String from, Map<String, dynamic> payload) async {
    appFrames.addAll(
      await engine.handleIncoming(
        SignalTransportFrame(
          from: from,
          payload: payload,
          receivedAtMillis: mesh.now,
        ),
      ),
    );
  }

  void restart() {
    engine = _build();
  }

  List<Map<String, dynamic>> framesOfType(String type) => appFrames
      .where((SignalTransportFrame f) => f.payload['type'] == type)
      .map((SignalTransportFrame f) => f.payload)
      .toList();

  Future<RelayState> state() => store.load();
}

String _addr(String raw) => PeerShareCodec.normalizeAddress(raw);
final String alice = _addr('200::a');
final String bob = _addr('200::b');

/// Six helpers: exactly the mailboxes alice and bob pick (alice is never
/// one of bob's).
final List<String> helpers = <String>[
  for (int i = 1; i <= 6; i++) _addr('200::c$i'),
];

/// Everyone befriended and online, relay sets (with the mailboxes that hold
/// attachments) announced and confirmed. [bobHasBlobs] false runs bob
/// without a blob store, so he announces no such mailboxes.
Future<_SimMesh> _mesh({bool bobHasBlobs = true}) async {
  final _SimMesh mesh = _SimMesh()
    ..add(alice)
    ..add(bob, blobs: bobHasBlobs);
  for (final String helper in helpers) {
    mesh.add(helper);
  }
  mesh.befriendAll();
  for (final _SimNode node in mesh.nodes.values) {
    await node.engine.activate();
  }
  await mesh.settle();
  await mesh.advance(const Duration(seconds: 1));
  await mesh.advance(const Duration(seconds: 6));
  return mesh;
}

Uint8List _bytes(int length, {int seed = 7}) => Uint8List.fromList(
  List<int>.generate(length, (int i) => (i * 31 + seed) & 0xff),
);

const int _chunk = 64 * 1024;

/// Mailboxes that get a copy of each blob ([RelayConfig.maxBlobCopies]).
final int _copies = const RelayConfig().maxBlobCopies;

Future<bool> _sendAttachment(
  _SimMesh mesh,
  Uint8List bytes, {
  String messageId = 'm-plik',
}) {
  return mesh.nodes[alice]!.engine.submitAttachment(
    recipient: bob,
    messageId: messageId,
    meta: <String, dynamic>{
      'text': 'plik.bin',
      'messageType': 'file',
      'fileName': 'plik.bin',
      'attachmentSizeBytes': bytes.length,
      'type': 'friend_remove', // never handed on
    },
    totalBytes: bytes.length,
    chunkSize: _chunk,
    readChunk: (int i) async => Uint8List.sublistView(
      bytes,
      i * _chunk,
      (i + 1) * _chunk < bytes.length ? (i + 1) * _chunk : bytes.length,
    ),
  );
}

/// The attachment as bob's app saw it: the chunks, put back together.
Uint8List _assembled(_SimNode node, String messageId) {
  final Map<int, List<int>> chunks = <int, List<int>>{
    for (final Map<String, dynamic> p in node.framesOfType('message_chunk'))
      if (p['msgId'] == messageId)
        p['chunkIndex'] as int: base64Decode(p['chunkData'] as String),
  };
  final List<int> indexes = chunks.keys.toList()..sort();
  return Uint8List.fromList(<int>[for (final int i in indexes) ...chunks[i]!]);
}

Future<int> _heldChunkCount(_SimMesh mesh) async {
  int count = 0;
  for (final String helper in helpers) {
    final RelayState state = await mesh.nodes[helper]!.state();
    count += state.heldBlobs[bob]?.length ?? 0;
  }
  return count;
}

void main() {
  test('mailboxes that hold attachments are announced', () async {
    final _SimMesh mesh = await _mesh();
    final RelayState bobState = await mesh.nodes[bob]!.state();
    final RelayPeerInfo? seenByAlice =
        (await mesh.nodes[alice]!.state()).peers[bob];
    expect(
      seenByAlice?.blobRelays.keys.toSet(),
      bobState.currentRelays.toSet(),
    );
    expect(seenByAlice!.blobRelays.values.toSet(), <int>{
      const RelayConfig().defaultBlobQuotaBytes,
    });
    expect(
      await mesh.nodes[alice]!.engine.canSendAttachmentTo(
        bob,
        bytes: 5 * 1024 * 1024,
        chunkSize: _chunk,
      ),
      isTrue,
    );
  });

  test('an attachment sent while the recipient is offline arrives from the '
      'mailboxes after the sender left, and the copies are dropped', () async {
    final _SimMesh mesh = await _mesh();
    final Uint8List file = _bytes(600 * 1000); // 10 chunks, two windows
    await mesh.goOffline(bob);

    expect(await _sendAttachment(mesh, file), isTrue);
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5)); // manifest to mailboxes
    // Enough mailboxes hold it, so alice's own copy is gone already.
    expect(await _heldChunkCount(mesh), _copies);
    expect((await mesh.nodes[alice]!.state()).outBlobs, isEmpty);
    expect(
      mesh.nodes[alice]!.store.blobChunks.keys.where(
        (String k) => k.startsWith('o/'),
      ),
      isEmpty,
    );
    await mesh.goOffline(alice);

    await mesh.goOnline(bob);
    await mesh.advance(const Duration(seconds: 6));

    final _SimNode b = mesh.nodes[bob]!;
    final List<Map<String, dynamic>> placeholders = b.framesOfType(
      'message_placeholder',
    );
    expect(placeholders, hasLength(1));
    expect(placeholders.single['msgId'], 'm-plik');
    expect(placeholders.single['fileName'], 'plik.bin');
    expect(placeholders.single['chunkCount'], 10);
    expect(placeholders.single['attachmentTransferBytes'], file.length);
    expect(
      b
          .framesOfType('message_chunk')
          .every((Map<String, dynamic> p) => p['type'] == 'message_chunk'),
      isTrue,
      reason: 'the metadata cannot change the frame type',
    );
    expect(_assembled(b, 'm-plik'), file);
    expect(b.framesOfType('blob_manifest'), isEmpty);
    // Collected: the mailboxes drop their copies, nothing is left to pull.
    expect(await _heldChunkCount(mesh), 0);
    for (final String helper in helpers) {
      expect(
        mesh.nodes[helper]!.store.blobChunks,
        isEmpty,
        reason: '$helper keeps no chunk',
      );
    }
    expect((await b.state()).inBlobs, isEmpty);

    // Alice comes back: the manifest is acknowledged, nothing stays queued.
    await mesh.goOnline(alice);
    await mesh.advance(const Duration(minutes: 3));
    expect((await mesh.nodes[alice]!.state()).outbox, isEmpty);
    expect(b.framesOfType('message_placeholder'), hasLength(1));
  });

  test('a reliable payload too large for one envelope waits in the mailboxes '
      'as a blob and is handed over as the original', () async {
    final _SimMesh mesh = await _mesh();
    await mesh.goOffline(bob);
    final Map<String, dynamic> big = <String, dynamic>{
      'type': 'message',
      'msgId': 'big-1',
      'text': 'x' * (150 * 1024),
    };
    await mesh.nodes[alice]!.engine.submit(bob, big);
    await mesh.advance(const Duration(seconds: 5));
    await mesh.advance(const Duration(seconds: 5));
    // Not reported as direct-only: the mailboxes have it.
    expect(await mesh.nodes[alice]!.engine.takeDeliveryReports(), isEmpty);
    expect(await _heldChunkCount(mesh), _copies);
    await mesh.goOffline(alice);

    await mesh.goOnline(bob);
    await mesh.advance(const Duration(seconds: 6));
    final List<Map<String, dynamic>> messages = mesh.nodes[bob]!.framesOfType(
      'message',
    );
    expect(messages, hasLength(1));
    expect(messages.single['msgId'], 'big-1');
    expect(messages.single['text'], big['text']);
    expect(await _heldChunkCount(mesh), 0);

    // Alice's direct retry finds it delivered; the copy for the mailboxes
    // and its manifest go with it, and bob does not take it twice.
    await mesh.goOnline(alice);
    await mesh.advance(const Duration(minutes: 3));
    final RelayState aliceState = await mesh.nodes[alice]!.state();
    expect(aliceState.outbox, isEmpty);
    expect(aliceState.outBlobs, isEmpty);
    expect(mesh.nodes[bob]!.framesOfType('message'), hasLength(1));
  });

  test('a recipient without attachment mailboxes gets large payloads '
      'in parts through its mailboxes', () async {
    final _SimMesh mesh = await _mesh(bobHasBlobs: false);
    final RelayEngine engine = mesh.nodes[alice]!.engine;
    expect(
      await engine.canSendAttachmentTo(bob, bytes: 1000, chunkSize: _chunk),
      isFalse,
    );
    await mesh.goOffline(bob);
    expect(await _sendAttachment(mesh, _bytes(1000)), isFalse);
    await engine.submit(bob, <String, dynamic>{
      'type': 'message',
      'msgId': 'big-old',
      'text': 'x' * (60 * 1024),
    });
    await mesh.advance(const Duration(seconds: 6));
    // Not direct-only: cut into envelope-sized parts for its mailboxes.
    expect(await engine.takeDeliveryReports(), isEmpty);
    final RelayState state = await mesh.nodes[alice]!.state();
    expect(state.outBlobs, isEmpty);
    expect(await _heldChunkCount(mesh), 0);
    final RelayOutboxEntry parent = state.outbox.values.singleWhere(
      (RelayOutboxEntry e) => e.payload['type'] == 'message',
    );
    expect(parent.partRids, hasLength(3));
    expect(
      state.outbox.values.where(
        (RelayOutboxEntry e) => e.payload['type'] == kRelayPartType,
      ),
      hasLength(3),
    );

    await mesh.advance(const Duration(seconds: 6));
    await mesh.goOffline(alice);
    await mesh.goOnline(bob);
    await mesh.advance(const Duration(seconds: 6));
    final List<Map<String, dynamic>> messages = mesh.nodes[bob]!.framesOfType(
      'message',
    );
    expect(messages, hasLength(1));
    expect(messages.single['text'], 'x' * (60 * 1024));
  });

  test('mailboxes keep within the per-sender quota', () async {
    final _SimMesh mesh = await _mesh();
    for (final String helper in helpers) {
      await mesh.nodes[helper]!.engine.setBlobQuota(200 * 1000);
    }
    await mesh.advance(const Duration(seconds: 6));
    await mesh.advance(const Duration(seconds: 6));
    final RelayEngine engine = mesh.nodes[alice]!.engine;
    expect(
      await engine.canSendAttachmentTo(
        bob,
        bytes: 300 * 1000,
        chunkSize: _chunk,
      ),
      isFalse,
      reason: 'bigger than any mailbox takes',
    );
    await mesh.goOffline(bob);
    expect(await _sendAttachment(mesh, _bytes(300 * 1000)), isFalse);

    expect(
      await _sendAttachment(mesh, _bytes(120 * 1000), messageId: 'm-1'),
      isTrue,
    );
    await mesh.settle();
    expect(await _heldChunkCount(mesh), _copies);
    // A second one would put alice over her 200 kB with those mailboxes:
    // they refuse it, and the other three take it.
    expect(
      await _sendAttachment(
        mesh,
        _bytes(120 * 1000, seed: 3),
        messageId: 'm-2',
      ),
      isTrue,
    );
    await mesh.settle();
    expect(await _heldChunkCount(mesh), _copies * 2);
    // A third finds no mailbox with room left.
    expect(
      await _sendAttachment(
        mesh,
        _bytes(120 * 1000, seed: 5),
        messageId: 'm-3',
      ),
      isTrue,
    );
    await mesh.settle();
    expect(await _heldChunkCount(mesh), _copies * 2);
    final RelayBlobOut third =
        (await mesh.nodes[alice]!.state()).outBlobs.values.single;
    expect(third.refused.toSet(), helpers.toSet());
    for (final String helper in helpers) {
      final Iterable<RelayHeldBlob> held =
          (await mesh.nodes[helper]!.state()).heldBlobs[bob]?.values ??
          const <RelayHeldBlob>[];
      expect(
        held.fold<int>(0, (int sum, RelayHeldBlob b) => sum + b.cipherBytes),
        lessThanOrEqualTo(200 * 1000),
        reason: helper,
      );
    }

    // Mailboxes that hold nothing at all for anyone (bob has to be around
    // to hear it and tell alice).
    await mesh.goOnline(bob);
    for (final String helper in helpers) {
      await mesh.nodes[helper]!.engine.setBlobQuota(0);
    }
    await mesh.advance(const Duration(seconds: 6));
    await mesh.advance(const Duration(seconds: 6));
    expect(
      await engine.canSendAttachmentTo(bob, bytes: 1000, chunkSize: _chunk),
      isFalse,
    );
  });

  test('chunks are sealed: mailboxes hold no plaintext, and a tampered '
      'chunk is refused until a good copy comes', () async {
    final _SimMesh mesh = await _mesh();
    final Uint8List file = Uint8List.fromList(
      utf8.encode('TAJNE-ZDJECIE ' * 9000),
    );
    await mesh.goOffline(bob);
    expect(await _sendAttachment(mesh, file), isTrue);
    await mesh.advance(const Duration(seconds: 5));
    final List<Uint8List> held = <Uint8List>[
      for (final String helper in helpers)
        ...mesh.nodes[helper]!.store.blobChunks.values,
    ];
    expect(held, hasLength(_copies * 2));
    for (final Uint8List chunk in held) {
      expect(
        latin1.decode(chunk, allowInvalid: true),
        isNot(contains('TAJNE')),
      );
    }

    // Every mailbox hands out flipped bits.
    mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
      if (p['type'] == 'rly_bchunk') {
        final Uint8List data = base64Decode(p['chunkData'] as String);
        data[0] ^= 0x01;
        p['chunkData'] = base64Encode(data);
      }
      return p;
    };
    await mesh.goOnline(bob);
    await mesh.advance(const Duration(seconds: 6));
    final _SimNode b = mesh.nodes[bob]!;
    expect(b.framesOfType('message_placeholder'), hasLength(1));
    expect(b.framesOfType('message_chunk'), isEmpty);

    mesh.interceptor = null;
    await mesh.advance(const Duration(minutes: 6));
    expect(_assembled(b, 'm-plik'), file);
  });

  test('collection resumes after the recipient restarts half way', () async {
    final _SimMesh mesh = await _mesh();
    final Uint8List file = _bytes(600 * 1000, seed: 11);
    await mesh.goOffline(bob);
    expect(await _sendAttachment(mesh, file), isTrue);
    await mesh.advance(const Duration(seconds: 5));
    await mesh.goOffline(alice);

    // Bob drops off after the first window.
    int handed = 0;
    mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
      if (p['type'] == 'rly_bchunk' && ++handed > 8) {
        return null;
      }
      return p;
    };
    await mesh.goOnline(bob);
    final _SimNode b = mesh.nodes[bob]!;
    expect(b.framesOfType('message_chunk'), hasLength(8));
    await mesh.goOffline(bob);
    mesh.interceptor = null;
    b.restart();
    await mesh.goOnline(bob);
    await mesh.advance(const Duration(seconds: 30));
    await mesh.advance(const Duration(seconds: 30));
    expect(_assembled(b, 'm-plik'), file);
    expect(await _heldChunkCount(mesh), 0);
  });

  // A mailbox that is around but never confirms a chunk (a node of another
  // engine answering for its phone) got a new window of half a megabyte at
  // every sighting past the window's timeout.
  test('a mailbox that never confirms gets windows on a growing wait, not at '
      'every sighting', () async {
    final _SimMesh mesh = await _mesh();
    final Uint8List file = _bytes(600 * 1000, seed: 5);
    await mesh.goOffline(bob);
    final Map<String, int> puts = <String, int>{};
    mesh.interceptor = (String from, String to, Map<String, dynamic> p) {
      if (from == alice && p['type'] == 'rly_bput') {
        puts[to] = (puts[to] ?? 0) + 1;
      }
      if (p['type'] == 'rly_bput_ack') {
        return null; // the chunks arrive, the confirmations never do
      }
      return p;
    };
    expect(await _sendAttachment(mesh, file), isTrue);
    await mesh.settle();
    await mesh.advance(const Duration(seconds: 5));
    expect(puts, isNotEmpty);
    final String talker = puts.keys.first;
    final int firstWindow = puts[talker]!;

    // Ten minutes of the mailbox talking every six seconds.
    for (int i = 0; i < 100; i++) {
      await mesh.nodes[alice]!.receive(talker, <String, dynamic>{
        'type': 'typing',
      });
      await mesh.advance(const Duration(seconds: 6));
    }
    // A window now, after 2, then 4 minutes more (it was one per sighting
    // past the timeout, some twenty-five).
    expect(puts[talker]! ~/ firstWindow, lessThanOrEqualTo(4));
  });

  test('blob state survives a save', () {
    final RelayState state = RelayState(
      peers: <String, RelayPeerInfo>{
        bob: RelayPeerInfo(
          address: bob,
          relays: helpers,
          blobQuotaBytes: 1000,
          blobRelays: <String, int>{helpers.first: 5000},
        ),
      },
      announcedVersions: <String, int>{bob: 3},
      blobQuotaBytes: 0,
      outBlobs: <String, RelayBlobOut>{
        'b1': RelayBlobOut(
          blobId: 'b1',
          recipient: bob,
          kind: RelayBlobKind.attachment,
          manifestRid: 'r1',
          chunkCount: 3,
          cipherBytes: 300,
          createdAtMillis: 1,
          expiresAtMillis: 2,
          stored: <String, List<int>>{
            helpers.first: <int>[0, 2],
          },
          refused: <String>[helpers.last],
        ),
      },
      heldBlobs: <String, Map<String, RelayHeldBlob>>{
        bob: <String, RelayHeldBlob>{
          '$alice|b2': RelayHeldBlob(
            blobId: 'b2',
            sender: alice,
            chunkCount: 2,
            cipherBytes: 200,
            storedBytes: 100,
            arrivedAtMillis: 5,
            holdUntilMillis: 6,
            have: <int>{1},
          ),
        },
      },
      inBlobs: <String, RelayBlobIn>{
        '$alice|b3': RelayBlobIn(
          blobId: 'b3',
          sender: alice,
          kind: RelayBlobKind.payload,
          key: RelayBlobCipher.newKey(),
          chunkCount: 2,
          chunkSize: 10,
          plainBytes: 15,
          createdAtMillis: 7,
          expiresAtMillis: 8,
          digest: 'd',
          ref: 'r3',
          received: <int>{0},
        ),
      },
    );
    final RelayState loaded = RelayState.fromJsonString(state.toJsonString());
    final RelayPeerInfo peer = loaded.peers[bob]!;
    expect(peer.blobQuotaBytes, 1000);
    expect(peer.blobRelays, <String, int>{helpers.first: 5000});
    expect(loaded.blobQuotaBytes, 0);
    final RelayBlobOut out = loaded.outBlobs['b1']!;
    expect(out.kind, RelayBlobKind.attachment);
    expect(out.stored[helpers.first], <int>[0, 2]);
    expect(out.refused, <String>[helpers.last]);
    final RelayHeldBlob held = loaded.heldBlobs[bob]!['$alice|b2']!;
    expect(held.have, <int>{1});
    expect(held.storedBytes, 100);
    final RelayBlobIn incoming = loaded.inBlobs['$alice|b3']!;
    expect(incoming.kind, RelayBlobKind.payload);
    expect(incoming.received, <int>{0});
    expect(incoming.missing(5), <int>[1]);
    expect(incoming.key, state.inBlobs['$alice|b3']!.key);
    expect(loaded.announcedVersions, <String, int>{bob: 3});
  });

  test('the file store keeps blob chunks as files of their own', () async {
    final Directory dir = await Directory.systemTemp.createTemp('zen-blob-');
    addTearDown(() => dir.delete(recursive: true));
    final FileRelayStateStore store = FileRelayStateStore(
      store: FileBinaryStore(
        dir,
        codec: BinaryCodec(compressor: const _PassThroughCompressor()),
      ),
    );
    final Uint8List chunk = _bytes(70 * 1024);
    await store.writeBlobChunk('o/0123abcd/4', chunk);
    expect(await store.readBlobChunk('o/0123abcd/4'), chunk);
    await store.deleteBlobChunk('o/0123abcd/4');
    expect(await store.readBlobChunk('o/0123abcd/4'), isNull);
  });

  test('a sealed chunk opens only for its own blob, place and key', () async {
    final Uint8List key = RelayBlobCipher.newKey();
    final Uint8List plain = _bytes(1000);
    Uint8List ad(int index) => RelayBlobCipher.associatedDataFor(
      blobId: 'b',
      sender: alice,
      recipient: bob,
      index: index,
      count: 2,
    );
    final Uint8List sealed = await RelayBlobCipher.sealChunk(
      key: key,
      index: 1,
      plaintext: plain,
      associatedData: ad(1),
    );
    expect(
      await RelayBlobCipher.openChunk(
        key: key,
        index: 1,
        sealed: sealed,
        associatedData: ad(1),
      ),
      plain,
    );
    await expectLater(
      RelayBlobCipher.openChunk(
        key: key,
        index: 0,
        sealed: sealed,
        associatedData: ad(0),
      ),
      throwsA(anything),
    );
    await expectLater(
      RelayBlobCipher.openChunk(
        key: RelayBlobCipher.newKey(),
        index: 1,
        sealed: sealed,
        associatedData: ad(1),
      ),
      throwsA(anything),
    );
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
