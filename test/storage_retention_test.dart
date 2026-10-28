import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/features/feed/feed_memo.dart';
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
  for (int i = 0; i < 40; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const int _mb = 1024 * 1024;
const int _gb = 1024 * _mb;
const int _day = 24 * 60 * 60 * 1000;

StoredMedia _file(
  String id,
  int bytes,
  int daysAgo, {
  String account = 'bob',
  StoredMediaOwner owner = StoredMediaOwner.friend,
  int now = 1000 * _day,
}) => StoredMedia(
  id: id,
  bytes: bytes,
  account: account,
  millis: now - daysAgo * _day,
  owner: owner,
);

Set<String> _ids(Iterable<StoredMedia> files) => <String>{
  for (final StoredMedia m in files) m.id,
};

void main() {
  const int now = 1000 * _day;

  group('planStorageRetention', () {
    test('friends\' files older than 12 months go, newer ones stay', () {
      final RetentionPlan plan = planStorageRetention(<StoredMedia>[
        _file('old', _mb, 400),
        _file('edge', _mb, 364),
        _file('new', _mb, 3),
      ], nowMillis: now);
      expect(_ids(plan.expired), <String>{'old'});
      expect(plan.overPersonLimit, isEmpty);
      expect(plan.overCache, isEmpty);
    });

    test('over 2 GB of one friend the oldest go first; others are spared', () {
      final RetentionPlan plan = planStorageRetention(<StoredMedia>[
        _file('b1', gb(1), 30),
        _file('b2', gb(1), 20),
        _file('b3', gb(1), 10),
        _file('c1', gb(1), 40, account: 'cela'),
      ], nowMillis: now);
      expect(_ids(plan.overPersonLimit), <String>{'b1'});
      expect(plan.expired, isEmpty);
    });

    test('a cache over 1 GB loses its oldest files, never by age alone', () {
      final RetentionPlan plan = planStorageRetention(<StoredMedia>[
        _file('x1', 600 * _mb, 500, owner: StoredMediaOwner.cache),
        _file('x2', 600 * _mb, 100, owner: StoredMediaOwner.cache),
        _file('x3', 100 * _mb, 1, owner: StoredMediaOwner.cache),
      ], nowMillis: now);
      expect(_ids(plan.overCache), <String>{'x1'});
      expect(plan.expired, isEmpty);

      final RetentionPlan small = planStorageRetention(<StoredMedia>[
        _file('y', 10 * _mb, 900, owner: StoredMediaOwner.cache),
      ], nowMillis: now);
      expect(small.isEmpty, isTrue);
    });

    test('expired files do not count against the 2 GB', () {
      final RetentionPlan plan = planStorageRetention(<StoredMedia>[
        _file('old', gb(2), 500),
        _file('new', gb(2), 5),
      ], nowMillis: now);
      expect(_ids(plan.expired), <String>{'old'});
      expect(plan.overPersonLimit, isEmpty);
    });

    test('no limit of its own for the wall deletes nothing extra', () {
      final RetentionPlan plan = planStorageRetention(<StoredMedia>[
        _file('a', 500 * _mb, 1),
        _file('b', 500 * _mb, 2, owner: StoredMediaOwner.cache),
      ], nowMillis: now);
      expect(plan.overFeed, isEmpty);
      expect(plan.isEmpty, isTrue);
    });

    test('over the limit set for the wall the oldest go first, friends and '
        'others alike', () {
      final RetentionPlan plan = planStorageRetention(
        <StoredMedia>[
          _file('friend-old', 40 * _mb, 30),
          _file('cache-older', 30 * _mb, 60, owner: StoredMediaOwner.cache),
          _file('friend-new', 40 * _mb, 2, account: 'cela'),
          _file('cache-new', 30 * _mb, 1, owner: StoredMediaOwner.cache),
        ],
        nowMillis: now,
        feedBytes: 80 * _mb,
      );
      // 140 MB held, 80 allowed: the two oldest (70 MB) leave, 70 stay.
      expect(_ids(plan.overFeed), <String>{'cache-older', 'friend-old'});
      expect(plan.overPersonLimit, isEmpty);
      expect(plan.overCache, isEmpty);
    });

    test('what the older limits already delete is not counted twice', () {
      final RetentionPlan plan = planStorageRetention(
        <StoredMedia>[
          _file('expired', 60 * _mb, 500),
          _file('kept', 60 * _mb, 3),
        ],
        nowMillis: now,
        feedBytes: 70 * _mb,
      );
      expect(_ids(plan.expired), <String>{'expired'});
      expect(plan.overFeed, isEmpty);
    });

    test('usage tells the largest friend and the cache', () {
      final StorageUsage usage = storageUsageOf(<StoredMedia>[
        _file('a', 5 * _mb, 1),
        _file('b', 7 * _mb, 1),
        _file('c', 20 * _mb, 1, account: 'cela'),
        _file('d', 3 * _mb, 1, owner: StoredMediaOwner.cache),
      ]);
      expect(usage.largestFriendBytes, 20 * _mb);
      expect(usage.friendBytes, 32 * _mb);
      expect(usage.feedBytes, 35 * _mb);
      expect(usage.friendFiles, 3);
      expect(usage.cacheBytes, 3 * _mb);
      expect(usage.cacheFiles, 1);
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

    Future<String> postWithPhoto(LedgerNode n, String text, int seed) async {
      final Map<String, dynamic> photo = await storeMedia(
        n.blobs,
        Uint8List.fromList(
          List<int>.generate(3000, (int i) => (i + seed) % 251),
        ),
      );
      await n.publish(
        kPostKind,
        newPostBody(text, images: <Map<String, dynamic>>[photo]),
        blobs: mediaIds(<Map<String, dynamic>>[photo]),
      );
      return photo['id'] as String;
    }

    test('a year later a friend\'s photo is gone, my own never is', () async {
      final (LedgerNode a, LedgerNode b) = await pair();
      final String mine = await postWithPhoto(a, 'Moje', 1);
      final String theirs = await postWithPhoto(b, 'Jego', 2);
      await _settle();
      expect(a.blobs.isComplete(theirs), isTrue);

      // Today nothing is over any limit.
      RetentionResult result = await enforceStorageLimits(a);
      expect(result.files, 0);
      expect(a.blobs.isComplete(theirs), isTrue);

      // 13 months on: Bob's photo is deleted and not fetched again.
      final int later = DateTime.now().millisecondsSinceEpoch + 400 * _day;
      final List<StoredMedia> held = storedMediaOf(a);
      expect(_ids(held), <String>{theirs});
      expect(held.single.owner, StoredMediaOwner.friend);
      result = await enforceStorageLimits(a, nowMillis: later);
      expect(result.expiredFiles, 1);
      expect(result.bytes, greaterThan(0));
      expect(a.blobs.isComplete(theirs), isFalse);
      expect(a.blobs.refused, contains(theirs));
      expect(a.blobs.isComplete(mine), isTrue);

      // Bob's own copy is his own data: untouched on his side.
      await enforceStorageLimits(b, nowMillis: later);
      expect(b.blobs.isComplete(theirs), isTrue);
      expect(b.blobs.isComplete(mine), isFalse);
    });

    test(
      'a limit for the wall deletes the oldest friend files, not my own',
      () async {
        final (LedgerNode a, LedgerNode b) = await pair();
        final String mine = await postWithPhoto(a, 'Moje', 1);
        final String first = await postWithPhoto(b, 'Pierwsze', 2);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final String second = await postWithPhoto(b, 'Drugie', 3);
        await _settle();
        expect(a.blobs.isComplete(first), isTrue);
        expect(a.blobs.isComplete(second), isTrue);

        // No limit of its own: nothing goes.
        RetentionResult result = await enforceStorageLimits(a);
        expect(result.files, 0);

        // Room for one of the two (3000 bytes each): the older one goes.
        result = await enforceStorageLimits(a, feedLimitBytes: 4000);
        expect(result.limitFiles, 1);
        expect(a.blobs.isComplete(first), isFalse);
        expect(a.blobs.isComplete(second), isTrue);
        expect(a.blobs.isComplete(mine), isTrue);
      },
    );

    test('the wall leaves out friends\' posts older than 12 months', () async {
      final (LedgerNode a, LedgerNode b) = await pair();
      await postWithPhoto(b, 'Stary', 3);
      await _settle();
      final FeedMemo memo = FeedMemo();
      List<FeedPost> wall(int nowMillis) => memo.wallOf(
        a,
        revision: nowMillis,
        nameOf: (_) => 'Bob',
        nowMillis: nowMillis,
      );
      final int today = DateTime.now().millisecondsSinceEpoch;
      expect(wall(today), hasLength(1));
      expect(wall(today + 400 * _day), isEmpty);
    });
  });
}

int gb(int n) => n * _gb;
