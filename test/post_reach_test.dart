import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';

import 'support/ledger_mesh.dart';

/// Names the tests give the phones' owners.
const Map<String, String> _people = <String, String>{
  'a': 'Ada',
  'b': 'Bob',
  'c': 'Cyryl',
  'd': 'Dorota',
  'e': 'Edek',
};

/// A chain of phones a–b–c–… with their ledgers and reach services
/// (rounds at once, no gaps between notices, asks repeated every round).
final class _World {
  final LedgerMesh mesh = LedgerMesh();
  final Map<String, PostReachService> reach = <String, PostReachService>{};

  static Future<_World> chain(List<String> names) async {
    final _World w = _World();
    w.mesh.chain(names);
    for (final String n in names) {
      final LedgerNode node = await w.mesh.add(n);
      final PostReachService service = PostReachService(
        node: node,
        delay: Duration.zero,
        minGap: Duration.zero,
        retryAfter: Duration.zero,
      );
      addTearDown(service.stop);
      await service.start();
      w.reach[n] = service;
    }
    await w.mesh.settle();
    return w;
  }

  LedgerNode operator [](String name) => mesh[name];

  String nameOf(String address) {
    for (final String n in _people.keys) {
      if (mesh.nodes.containsKey(n) && mesh.address(n) == address) {
        return _people[n]!;
      }
    }
    return '?';
  }

  /// What phone [name] shows on its wall (others' posts, newest first).
  List<FeedPost> wall(String name) => <FeedPost>[
    for (final FeedPost p in buildFeed(
      mesh[name],
      nameOf: nameOf,
      held: reach[name],
    ))
      if (!p.isOwn) p,
  ];

  FeedPost? postOn(String name, String id) {
    for (final FeedPost p in wall(name)) {
      if (p.id == id) {
        return p;
      }
    }
    return null;
  }

  /// The notices phone [name] wrote.
  List<PostAnnouncement> passedOnBy(String name) => <PostAnnouncement>[
    for (final LogEntry e in mesh[name].entriesOf(spaceKind: 'acts'))
      ...announcementsIn(e),
  ];

  /// Runs every phone's round a few times and lets the network settle.
  Future<void> rounds([int times = 3]) async {
    for (int i = 0; i < times; i++) {
      for (final MapEntry<String, PostReachService> r in reach.entries) {
        if (mesh.isOnline(r.key)) {
          await r.value.round();
        }
      }
      await mesh.settle();
    }
  }
}

Future<LogEntry> _post(
  LedgerNode node,
  String text, {
  PostReach reach = kDefaultPostReach,
  Audience audience = Audience.public,
  List<Map<String, dynamic>> images = const <Map<String, dynamic>>[],
}) async => node.publish(
  kPostKind,
  await node.seal(
    audience,
    newPostBody(text, audience: audience, images: images, reach: reach),
  ),
  blobs: mediaIds(images),
);

void main() {
  group('the reach in a post', () {
    test('a public post carries it, any other audience never goes further', () {
      expect(newPostBody('Hej')[kPostReachKey], 2);
      expect(reachOfBody(newPostBody('Hej')), PostReach.friendsOfFriends);
      expect(
        reachOfBody(newPostBody('Hej', reach: PostReach.third)),
        PostReach.third,
      );
      final Map<String, dynamic> close = newPostBody(
        'Hej',
        audience: Audience.close,
        reach: PostReach.third,
      );
      expect(close.containsKey(kPostReachKey), isFalse);
      expect(reachOfBody(close), PostReach.friends);
      // An edit keeps the reach the post was written with.
      expect(
        editPostBody('a' * 64, 'Poprawione').containsKey(kPostReachKey),
        isFalse,
      );
    });

    test('a notice outside the rules is refused', () {
      Map<String, dynamic> notice({Object? r = 2, Object? h = 2}) =>
          <String, dynamic>{
            'p': 'b' * 64,
            'a': 'konto',
            't': 1790000000000,
            'r': r,
            'h': h,
          };
      expect(PostAnnouncement.fromJson(notice()), isNotNull);
      expect(PostAnnouncement.fromJson(notice(r: 3, h: 3)), isNotNull);
      // Friends only, a step past the reach, beyond three steps.
      expect(PostAnnouncement.fromJson(notice(r: 1, h: 2)), isNull);
      expect(PostAnnouncement.fromJson(notice(r: 2, h: 3)), isNull);
      expect(PostAnnouncement.fromJson(notice(r: 4, h: 4)), isNull);
      expect(PostAnnouncement.fromJson(notice(h: 1)), isNull);
      expect(
        PostAnnouncement.fromJson(<String, dynamic>{...notice(), 'p': 'x'}),
        isNull,
      );
    });
  });

  group('a chain a–b–c–d', () {
    test(
      'reach 2: c sees the post "przez Bob", fetched from b while the author '
      'is offline, photo included; d sees nothing',
      () async {
        final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
        w.mesh.setOnline('c', false);
        final Map<String, dynamic> photo = await storeMedia(
          w['a'].blobs,
          Uint8List.fromList(List<int>.generate(3000, (int i) => i % 251)),
        );
        final LogEntry post = await _post(
          w['a'],
          'Wiosna w parku\n{{media:0}}',
          images: <Map<String, dynamic>>[photo],
        );
        await w.mesh.settle();
        await w.rounds();
        // b, a friend of the author, passed the notice on; nothing else
        // than the notice: no text, no photo.
        final PostAnnouncement notice = w.passedOnBy('b').single;
        expect(notice.post, post.id);
        expect(notice.author, w['a'].account);
        expect(notice.hops, 2);
        expect(notice.reach, PostReach.friendsOfFriends);
        expect(notice.toJson().keys, isNot(contains('text')));

        // The author goes offline; c comes back and gets it from b.
        w.mesh.setOnline('a', false);
        await w.mesh.comeBack('c');
        await w.rounds();
        final FeedPost seen = w.postOn('c', post.id)!;
        expect(seen.text, 'Wiosna w parku\n{{media:0}}');
        expect(seen.degree, 2);
        expect(seen.via, <String>['Bob']);
        expect(seen.authorLabel, 'Znajomy znajomego');
        expect(w['c'].blobs.isComplete(seen.images.single.id), isTrue);
        expect(await openMedia(w['c'].blobs, seen.images.single), isNotNull);

        // c is two steps away: it passes nothing on, d sees nothing.
        expect(w.passedOnBy('c'), isEmpty);
        expect(w.postOn('d', post.id), isNull);
        expect(announcedPosts(w['d']), isEmpty);
        expect(w.reach['d']!.heldPost(post.id), isNull);
      },
    );

    test('reach 3: d sees it "przez Cyryl", fetched from c while a and b are '
        'offline; d passes nothing on', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
      w.mesh.setOnline('d', false);
      final LogEntry post = await _post(
        w['a'],
        'Daleko',
        reach: PostReach.third,
      );
      await w.mesh.settle();
      await w.rounds();
      expect(w.postOn('c', post.id)?.via, <String>['Bob']);
      final PostAnnouncement fromC = w.passedOnBy('c').single;
      expect(fromC.hops, 3);
      expect(fromC.reach, PostReach.third);

      w.mesh
        ..setOnline('a', false)
        ..setOnline('b', false);
      await w.mesh.comeBack('d');
      await w.rounds();
      final FeedPost seen = w.postOn('d', post.id)!;
      expect(seen.text, 'Daleko');
      expect(seen.degree, 3);
      expect(seen.via, <String>['Cyryl']);
      // Three steps is as far as anything goes.
      expect(w.passedOnBy('d'), isEmpty);
    });

    test('a post for friends only, or with reach "Znajomi", goes no further, '
        'and nobody hands it out when asked', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
      final LogEntry sealed = await _post(
        w['a'],
        'Tylko dla przyjaciół',
        audience: Audience.close,
        reach: PostReach.third,
      );
      final LogEntry near = await _post(
        w['a'],
        'Tylko znajomi',
        reach: PostReach.friends,
      );
      await w.mesh.settle();
      await w.rounds();
      expect(w.passedOnBy('b'), isEmpty);
      expect(w.wall('c'), isEmpty);

      // c asks b for them anyway: no answer.
      final int answers = w.mesh.sent['b']?[kPostAnswerType] ?? 0;
      for (final LogEntry e in <LogEntry>[sealed, near]) {
        await w['c'].transport.send(
          remoteAddress: w.mesh.address('b'),
          payload: postWantFrame(e.id, w['a'].account),
        );
      }
      // Nor does the author to someone who is not a friend.
      await w['d'].transport.send(
        remoteAddress: w.mesh.address('a'),
        payload: postWantFrame(near.id, w['a'].account),
      );
      await w.mesh.settle();
      expect(w.mesh.sent['b']?[kPostAnswerType] ?? 0, answers);
      expect(w.mesh.sent['a']?[kPostAnswerType] ?? 0, 0);
    });

    test(
      'each post is passed on once, at most 10 of one author a day',
      () async {
        final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
        for (int i = 0; i < 12; i++) {
          await _post(w['a'], 'Post $i');
        }
        await w.mesh.settle();
        await w.rounds(5);
        final List<PostAnnouncement> fromB = w.passedOnBy('b');
        expect(fromB, hasLength(kMaxAnnouncedPerAuthorDay));
        expect(
          fromB.map((PostAnnouncement a) => a.post).toSet(),
          hasLength(10),
        );
        expect(w.wall('c'), hasLength(10));
        expect(w.passedOnBy('c'), isEmpty);
        expect(w.wall('d'), isEmpty);
      },
    );

    test('a reach the author did not sign goes no further', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
      final LogEntry post = await _post(w['a'], 'Dwa kroki');
      await w.mesh.settle();
      await w.rounds();
      expect(w.reach['c']!.heldPost(post.id), isNotNull);

      // b claims reach 3: c holds the post the author signed with reach 2
      // and passes nothing on.
      PostAnnouncement claim(int hops) => PostAnnouncement(
        post: post.id,
        author: w['a'].account,
        millis: post.hlc.millis,
        reach: PostReach.third,
        hops: hops,
      );
      await w['b'].publish(
        kPostAnnounceKind,
        announceBody(<PostAnnouncement>[claim(2)]),
        spaceKind: 'acts',
      );
      await w.mesh.settle();
      await w.rounds();
      expect(w.passedOnBy('c'), isEmpty);

      // c says so to d anyway: c does not hand the post out three steps
      // away, d takes nothing.
      await w['c'].publish(
        kPostAnnounceKind,
        announceBody(<PostAnnouncement>[claim(3)]),
        spaceKind: 'acts',
      );
      await w.mesh.settle();
      await w.rounds();
      expect(announcedPosts(w['d']), contains(post.id));
      expect(w.reach['d']!.heldPost(post.id), isNull);
      expect(w.wall('d'), isEmpty);
    });

    test('a removed post disappears beyond friends too', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c']);
      final LogEntry post = await _post(w['a'], 'Na chwilę');
      await w.mesh.settle();
      await w.rounds();
      expect(w.postOn('c', post.id), isNotNull);

      await w['a'].publish(kPostDeleteKind, deletePostBody(post.id));
      await w.mesh.settle();
      await w.rounds();
      expect(w.passedOnBy('b').last.removed, isTrue);
      expect(w.postOn('c', post.id), isNull);
      final HeldPost held = w.reach['c']!.heldPost(post.id)!;
      expect(held.removed, isTrue);
      expect(held.post, isNull);
    });

    test('an edit reaches friends of friends', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c']);
      final LogEntry post = await _post(w['a'], 'Pierwsza wersja');
      await w.mesh.settle();
      await w.rounds();
      expect(w.postOn('c', post.id)?.text, 'Pierwsza wersja');

      await w['a'].publish(
        kPostEditKind,
        editPostBody(post.id, 'Druga wersja'),
      );
      await w.mesh.settle();
      await w.rounds();
      final FeedPost seen = w.postOn('c', post.id)!;
      expect(seen.text, 'Druga wersja');
      expect(seen.edited, isTrue);
    });

    test('with the friend who passed it on unreachable, the post comes from '
        'the author, with the name from their public profile', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c']);
      await w['a'].publish(
        kProfileKind,
        profileBody(name: 'Ada', address: w.mesh.address('a')),
        spaceKind: 'profile',
      );
      await w.mesh.settle();
      // c's asks never reach b.
      w.mesh.drop = (String from, String to, Map<String, dynamic> payload) =>
          from == 'c' && to == 'b' && payload['type'] == kPostWantType;
      final LogEntry post = await _post(w['a'], 'Prosto od autorki');
      await w.mesh.settle();
      await w.rounds();
      expect(w.passedOnBy('b').single.authorAddress, w.mesh.address('a'));
      final FeedPost seen = w.postOn('c', post.id)!;
      expect(seen.authorLabel, 'Ada');
      expect(seen.authorAddress, w.mesh.address('a'));
      expect(seen.via, <String>['Bob']);
      expect(w.mesh.sent['a']?[kPostAnswerType], greaterThan(0));
    });

    test('a fetched post is kept on the device', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c']);
      final LogEntry post = await _post(w['a'], 'Zostaje');
      await w.mesh.settle();
      await w.rounds();
      expect(w.reach['c']!.heldPost(post.id), isNotNull);
      final PostReachService again = PostReachService(node: w['c']);
      addTearDown(again.stop);
      await again.start();
      expect(again.heldPost(post.id)?.post?.body['text'], 'Zostaje');
    });
  });

  test('a like from two steps away reaches the author through the friend '
      'who passed the post on', () async {
    final _World w = await _World.chain(<String>['a', 'b', 'c']);
    final LogEntry post = await _post(w['a'], 'Polub z daleka');
    await w.mesh.settle();
    await w.rounds();
    expect(w.postOn('c', post.id), isNotNull);
    await w['c'].publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await w.mesh.settle();
    expect(await relayReactions(w['b'], nameOf: w.nameOf), 1);
    await w.mesh.settle();
    final FeedPost own = buildFeed(
      w['a'],
      nameOf: w.nameOf,
    ).firstWhere((FeedPost p) => p.id == post.id);
    expect(own.likers, <String>['Cyryl (przez Bob)']);
  });

  test('a reshare still goes as far as people reshare it', () async {
    final _World w = await _World.chain(<String>['a', 'b', 'c', 'd', 'e']);
    final LogEntry post = await _post(
      w['a'],
      'Udostępniaj',
      reach: PostReach.friends,
    );
    await w.mesh.settle();
    LogEntry original = post;
    for (final String n in <String>['b', 'c', 'd']) {
      await w[n].publish(kReshareKind, reshareBody(original));
      await w.mesh.settle();
      // The next one reshares what came in the reshare.
      final ReshareCache cache = ReshareCache();
      final String next = String.fromCharCode(n.codeUnitAt(0) + 1);
      await cache.checkAll(w[next].entriesOf(ofAccount: w[n].account));
      final FeedPost seen = buildFeed(
        w[next],
        nameOf: w.nameOf,
        reshares: cache,
      ).firstWhere((FeedPost p) => p.id == post.id);
      expect(seen.resharedBy, <String>[_people[n]!]);
      original = seen.entry!;
    }
    // Reshares are not notices: nobody passed a notice on.
    for (final String n in <String>['a', 'b', 'c', 'd', 'e']) {
      expect(w.passedOnBy(n), isEmpty);
    }
  });
}
