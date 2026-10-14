import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// A mesh where a device can go offline: nothing reaches it, nothing
/// leaves it.
final class _Mesh {
  final Map<String, _Linked> nodes = <String, _Linked>{};
  final Set<String> offline = <String>{};
}

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.mesh);

  final String address;
  final _Mesh mesh;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final String to = PeerShareCodec.normalizeAddress(remoteAddress);
    if (mesh.offline.contains(address) || mesh.offline.contains(to)) {
      return;
    }
    final _Linked? target = mesh.nodes[to];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle([int rounds = 60]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final String _a = PeerShareCodec.normalizeAddress('200::a');
final String _b = PeerShareCodec.normalizeAddress('200::b');
final String _c = PeerShareCodec.normalizeAddress('200::c');

List<String> _friendsOf(String me) => <String>[
  for (final String x in <String>[_a, _b, _c])
    if (x != me) x,
];

Future<LedgerNode> _node(
  _Mesh mesh,
  String address, {
  LedgerDisk? disk,
  bool autoDownload = true,
  bool startSuspended = false,
  bool createIdentity = true,
}) async {
  final _Linked t = mesh.nodes[address] ??= _Linked(address, mesh);
  await t.start();
  final LedgerNode n = LedgerNode(
    transport: t,
    disk: disk ?? MemoryLedgerDisk(),
    // Everyone is everyone's friend.
    friendAddresses: () => _friendsOf(address),
    bridges: BridgeBook(probe: (String _) async => null),
    autoDownloadMedia: () => autoDownload,
    helloInterval: Duration.zero,
    syncInterval: Duration.zero,
    startSuspended: startSuspended,
    createIdentity: createIdentity,
  );
  addTearDown(n.stop);
  if (!startSuspended) {
    await n.start();
  }
  return n;
}

Future<FeedPost> _publishWithPhoto(LedgerNode n, String text) async {
  final Map<String, dynamic> photo = await storeMedia(
    n.blobs,
    Uint8List.fromList(List<int>.generate(3000, (int i) => i % 251)),
  );
  await n.publish(
    kPostKind,
    newPostBody('$text\n{{media:0}}', images: <Map<String, dynamic>>[photo]),
    blobs: mediaIds(<Map<String, dynamic>>[photo]),
  );
  return buildFeed(n, nameOf: (_) => '').first;
}

FeedPost? _postOf(LedgerNode n, String account, String id) {
  for (final FeedPost p in buildFeed(n, nameOf: (_) => '')) {
    if (p.account == account && p.id == id) {
      return p;
    }
  }
  return null;
}

void main() {
  test('editing replaces the text and, when asked, the photos', () async {
    final _Mesh mesh = _Mesh();
    final LedgerNode a = await _node(mesh, _a);
    final FeedPost post = await _publishWithPhoto(a, 'Pierwsza wersja');
    expect(post.images, hasLength(1));

    // Text only: the photo stays.
    await a.publish(kPostEditKind, editPostBody(post.id, 'Druga {{media:0}}'));
    FeedPost now = _postOf(a, a.account, post.id)!;
    expect(now.text, 'Druga {{media:0}}');
    expect(now.images, hasLength(1));
    expect(now.edited, isTrue);

    // With images: here the photo goes, a new one comes in.
    final Map<String, dynamic> other = await storeMedia(
      a.blobs,
      Uint8List.fromList(<int>[9, 9, 9, 9]),
    );
    await a.publish(
      kPostEditKind,
      editPostBody(
        post.id,
        'Trzecia\n{{media:0}}',
        images: <Map<String, dynamic>>[other],
      ),
      blobs: mediaIds(<Map<String, dynamic>>[other]),
    );
    now = _postOf(a, a.account, post.id)!;
    expect(now.images.single.id, other['id']);

    // And the photos can go altogether.
    await a.publish(
      kPostEditKind,
      editPostBody(
        post.id,
        'Bez zdjęć',
        images: const <Map<String, dynamic>>[],
      ),
    );
    now = _postOf(a, a.account, post.id)!;
    expect(now.images, isEmpty);
    expect(now.text, 'Bez zdjęć');

    // A kept file goes back into a body unchanged.
    expect(
      mediaRefFromJson(mediaRefToJson(post.images.single))!.id,
      post.images.single.id,
    );

    // Deleting removes it.
    await a.publish(kPostDeleteKind, deletePostBody(post.id));
    expect(_postOf(a, a.account, post.id), isNull);
  });

  test(
    'a post and its photo reach a friend while the author is offline',
    () async {
      final _Mesh mesh = _Mesh();
      final LedgerNode a = await _node(mesh, _a);
      final LedgerNode b = await _node(mesh, _b);
      final LedgerNode c = await _node(mesh, _c);
      // Everyone has met once; then C goes offline.
      await _settle();
      mesh.offline.add(_c);
      final FeedPost post = await _publishWithPhoto(a, 'Wakacje');
      await _settle();
      // B (online) got the post and the photo.
      expect(_postOf(b, a.account, post.id), isNotNull);
      expect(b.blobs.isComplete(post.images.single.id), isTrue);

      // A goes offline, C comes online and catches up — from B.
      mesh.offline
        ..add(_a)
        ..remove(_c);
      // (Hellos go at most once a second.)
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await c.greetFriends();
      await _settle();
      final FeedPost? seen = _postOf(c, a.account, post.id);
      expect(seen, isNotNull);
      expect(c.blobs.isComplete(post.images.single.id), isTrue);
      expect(await openMedia(c.blobs, seen!.images.single), isNotNull);
    },
  );

  test(
    'a photo missing after a restart is fetched from whoever has it',
    () async {
      final _Mesh mesh = _Mesh();
      final MemoryLedgerDisk cDisk = MemoryLedgerDisk();
      final LedgerNode a = await _node(mesh, _a);
      final LedgerNode b = await _node(mesh, _b);
      // C does not download media on its own at first.
      final LedgerNode c = await _node(
        mesh,
        _c,
        disk: cDisk,
        autoDownload: false,
      );
      await _settle();
      final FeedPost post = await _publishWithPhoto(a, 'Ognisko');
      await _settle();
      expect(_postOf(c, a.account, post.id), isNotNull);
      expect(c.blobs.isComplete(post.images.single.id), isFalse);
      expect(b.blobs.isComplete(post.images.single.id), isTrue);
      await c.stop();
      mesh.nodes.remove(_c);

      // The author is gone; C starts again (downloads on) and gets it from B.
      mesh.offline.add(_a);
      final LedgerNode again = await _node(mesh, _c, disk: cDisk);
      await again.greetFriends();
      await _settle();
      expect(again.blobs.isComplete(post.images.single.id), isTrue);
    },
  );

  test(
    'the background copy serves and keeps posts; the app catches up',
    () async {
      final _Mesh mesh = _Mesh();
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      final LedgerNode a = await _node(mesh, _a);
      // The app: started suspended, as on Android, until the bridge says so.
      final LedgerNode app = await _node(
        mesh,
        _b,
        disk: disk,
        startSuspended: true,
      );
      unawaited(app.start());
      await _settle(10);
      expect(app.isLoaded, isFalse);
      await app.resume();
      await app.start();
      expect(app.isLoaded, isTrue);
      await _settle();

      // The app goes to the background: the service takes the ledger over.
      await app.suspend();
      final LedgerNode service = await _node(
        mesh,
        _b,
        disk: disk,
        createIdentity: false,
      );
      expect(service.account, app.account);
      final FeedPost post = await _publishWithPhoto(a, 'Z tła');
      await _settle();
      expect(_postOf(service, a.account, post.id), isNotNull);
      expect(service.blobs.isComplete(post.images.single.id), isTrue);
      await service.stop();

      // Back on screen: the app sees what came meanwhile, photo included.
      await app.resume();
      final FeedPost? seen = _postOf(app, a.account, post.id);
      expect(seen, isNotNull);
      expect(await openMedia(app.blobs, seen!.images.single), isNotNull);
    },
  );

  test('a second copy never makes an identity of its own', () async {
    final _Mesh mesh = _Mesh();
    final LedgerNode n = LedgerNode(
      transport: mesh.nodes[_a] = _Linked(_a, mesh),
      disk: MemoryLedgerDisk(),
      friendAddresses: () => const <String>[],
      bridges: BridgeBook(probe: (String _) async => null),
      createIdentity: false,
    );
    addTearDown(n.stop);
    await expectLater(n.start(), throwsStateError);
  });
}
