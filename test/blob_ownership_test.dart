import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/hlc.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/storage_retention.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

final class _Linked extends MemorySignalTransport {
  _Linked(this.address, this.nodes);

  final String address;
  final Map<String, _Linked> nodes;

  @override
  Future<void> send({
    required String remoteAddress,
    required Map<String, dynamic> payload,
  }) async {
    final _Linked? target =
        nodes[PeerShareCodec.normalizeAddress(remoteAddress)];
    if (target != null) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

Future<void> _settle() async {
  for (int i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const int _day = 24 * 60 * 60 * 1000;

Uint8List _bytes(int seed, [int length = 3000]) =>
    Uint8List.fromList(List<int>.generate(length, (int i) => (i + seed) % 251));

/// A complete file in [blobs] that arrived from the network (not [put]).
Future<String> _fetched(BlobStore blobs, int seed) async {
  final Uint8List data = _bytes(seed);
  final BlobManifest manifest = BlobManifest.describe(data, 'image/jpeg');
  blobs.want(manifest.id);
  expect(blobs.acceptManifest(manifest.id, manifest.toJson()), isTrue);
  expect(await blobs.acceptChunk(manifest.chunks.single, data), isTrue);
  blobs.markDone(manifest.id);
  return manifest.id;
}

void main() {
  group('who brought a file', () {
    test('the first writer whose entry asks for it is remembered', () {
      final BlobStore blobs = BlobStore();
      blobs
        ..noteFetchFor('f', 'carol')
        ..noteFetchFor('f', 'mallory');
      expect(blobs.fetchedFor['f'], 'carol');
    });

    test('a file asked for, held or made before has no writer', () async {
      final BlobStore blobs = BlobStore();
      final String made = await blobs.put(_bytes(1));
      blobs.noteFetchFor(made, 'mallory');
      expect(blobs.fetchedFor, isNot(contains(made)));

      blobs
        ..want('wanted')
        ..noteFetchFor('wanted', 'mallory');
      expect(blobs.fetchedFor, isNot(contains('wanted')));
    });

    test('only the writer who brought it can make it go', () async {
      final BlobStore blobs = BlobStore();
      final String id = await _fetched(blobs, 2);
      blobs.fetchedFor[id] = 'carol';

      expect(await blobs.dropFor(id, 'mallory'), isFalse);
      expect(blobs.isComplete(id), isTrue);
      expect(blobs.refused, isNot(contains(id)));

      expect(await blobs.dropFor(id, 'carol'), isTrue);
      expect(blobs.isComplete(id), isFalse);
      expect(blobs.refusedFor(id, 'carol'), isTrue);
    });

    test('a drop by one writer does not block the file for others', () async {
      final BlobStore blobs = BlobStore();
      final String id = await _fetched(blobs, 3);
      blobs.fetchedFor[id] = 'mallory';
      expect(await blobs.dropFor(id, 'mallory'), isTrue);

      expect(blobs.refusedFor(id, 'mallory'), isTrue);
      expect(blobs.refusedFor(id, 'carol'), isFalse);
      blobs.allowFor(id, 'mallory');
      expect(blobs.refused, contains(id));
      blobs.allowFor(id, 'carol');
      expect(blobs.refused, isNot(contains(id)));
      expect(blobs.droppedFor, isNot(contains(id)));
    });

    test(
      'a chat takes a dropped file back; the user\'s refusal stays',
      () async {
        final BlobStore blobs = BlobStore();
        final String dropped = await _fetched(blobs, 4);
        blobs.fetchedFor[dropped] = 'mallory';
        await blobs.dropFor(dropped, 'mallory');
        blobs.claim(dropped);
        expect(blobs.refused, isNot(contains(dropped)));

        final String expired = await _fetched(blobs, 5);
        blobs.fetchedFor[expired] = 'carol';
        expect(await blobs.expire(expired), isTrue);
        // The limits are nobody's to undo by naming the file again ...
        blobs.allowFor(expired, 'dave');
        expect(blobs.refusedFor(expired, 'dave'), isTrue);
        // ... but a chat that needs it may fetch it.
        blobs.claim(expired);
        expect(blobs.refused, isNot(contains(expired)));

        final String mine = await _fetched(blobs, 6);
        await blobs.refuse(mine);
        blobs
          ..claim(mine)
          ..allowFor(mine, 'carol');
        expect(blobs.refused, contains(mine));
      },
    );

    test('the limits never take a file no writer brought', () async {
      final BlobStore blobs = BlobStore();
      final String id = await blobs.put(_bytes(7));
      expect(await blobs.expire(id), isFalse);
      expect(blobs.isComplete(id), isTrue);
    });

    test('who brought what survives a restart', () async {
      final MemoryLedgerDisk disk = MemoryLedgerDisk();
      Future<(LedgerArchive, BlobStore)> open() async {
        final LedgerArchive archive = LedgerArchive(disk: disk);
        final BlobStore blobs = BlobStore(backend: DiskBlobChunkBackend(disk));
        await archive.open(LedgerStore(clock: HlcClock()), blobs);
        return (archive, blobs);
      }

      final (LedgerArchive first, BlobStore blobs) = await open();
      final String kept = await _fetched(blobs, 8);
      final String gone = await _fetched(blobs, 9);
      blobs
        ..noteFetchFor('later', 'carol')
        ..fetchedFor[kept] = 'carol'
        ..fetchedFor[gone] = 'mallory';
      await blobs.dropFor(gone, 'mallory');
      await first.flush();

      final (LedgerArchive _, BlobStore again) = await open();
      expect(again.fetchedFor[kept], 'carol');
      expect(again.fetchedFor['later'], 'carol');
      expect(again.droppedFor[gone], 'mallory');
      expect(again.refusedFor(gone, 'carol'), isFalse);
    });
  });

  group('on a real ledger', () {
    final String ada = PeerShareCodec.normalizeAddress('200::a');
    final String bob = PeerShareCodec.normalizeAddress('200::b');

    Future<(LedgerNode, LedgerNode)> pair() async {
      final Map<String, _Linked> nodes = <String, _Linked>{};
      final _Linked ta = nodes[ada] = _Linked(ada, nodes);
      final _Linked tb = nodes[bob] = _Linked(bob, nodes);
      await ta.start();
      await tb.start();
      final LedgerNode a = LedgerNode(
        transport: ta,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => <String>[bob],
        bridges: BridgeBook(probe: (String _) async => null),
      );
      final LedgerNode b = LedgerNode(
        transport: tb,
        disk: MemoryLedgerDisk(),
        friendAddresses: () => <String>[ada],
        bridges: BridgeBook(probe: (String _) async => null),
      );
      addTearDown(a.stop);
      addTearDown(b.stop);
      await a.start();
      await b.start();
      return (a, b);
    }

    test('naming somebody else\'s file in a comment and removing it '
        'leaves the file alone', () async {
      final (LedgerNode a, LedgerNode b) = await pair();
      await a.publish(kPostKind, newPostBody('Jak wam minął dzień?'));
      // A file Ada sent in a group chat: no ledger entry names it.
      final Map<String, dynamic> groupFile = await storeMedia(
        a.blobs,
        _bytes(11, 5000),
      );
      final String id = groupFile['id'] as String;
      await _settle();
      final String postId = buildFeed(b, nameOf: (_) => 'Ada').single.id;

      // Bob knows its reference from the group: he "comments" with it and
      // removes the comment at once.
      final LogEntry comment = await b.publish(
        kCommentKind,
        commentBody(postId, 'Moje', images: <Map<String, dynamic>>[groupFile]),
        spaceKind: 'acts',
        blobs: <String>[id],
      );
      await b.publish(
        kCommentDeleteKind,
        commentDeleteBody(postId, comment.id),
        spaceKind: 'acts',
      );
      await _settle();
      expect(buildFeed(a, nameOf: (_) => 'Bob').single.comments, isEmpty);

      expect(removedCommentMedia(a), isNot(contains(id)));
      expect(
        storedMediaOf(a).map((StoredMedia m) => m.id),
        isNot(contains(id)),
      );
      await enforceStorageLimits(
        a,
        nowMillis: DateTime.now().millisecondsSinceEpoch + 400 * _day,
      );
      expect(a.blobs.isComplete(id), isTrue);
      expect(a.blobs.refused, isNot(contains(id)));
    });

    test('a removed comment\'s own picture still goes', () async {
      final (LedgerNode a, LedgerNode b) = await pair();
      await a.publish(kPostKind, newPostBody('Zdjęcia?'));
      await _settle();
      final String postId = buildFeed(b, nameOf: (_) => 'Ada').single.id;
      final Map<String, dynamic> photo = await storeMedia(
        b.blobs,
        _bytes(12, 4000),
      );
      final String id = photo['id'] as String;
      final LogEntry comment = await b.publish(
        kCommentKind,
        commentBody(postId, 'Proszę', images: <Map<String, dynamic>>[photo]),
        spaceKind: 'acts',
        blobs: <String>[id],
      );
      await _settle();
      expect(a.blobs.isComplete(id), isTrue);
      expect(a.blobs.fetchedFor[id], comment.account);

      await b.publish(
        kCommentDeleteKind,
        commentDeleteBody(postId, comment.id),
        spaceKind: 'acts',
      );
      await _settle();
      expect(removedCommentFiles(a), <String, String>{id: comment.account});
      final RetentionResult result = await enforceStorageLimits(a);
      expect(result.expiredFiles, 1);
      expect(a.blobs.isComplete(id), isFalse);
      expect(a.blobs.refusedFor(id, comment.account), isTrue);
    });
  });
}
