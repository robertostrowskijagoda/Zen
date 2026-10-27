import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';

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
/// [depth] says how far each phone looks (2 when not named); [lists] who
/// may see each phone's friend list (as by default when not named).
final class _World {
  final LedgerMesh mesh = LedgerMesh();
  final Map<String, PostReachService> reach = <String, PostReachService>{};
  final Map<String, FriendListAudience> lists = <String, FriendListAudience>{};

  static Future<_World> chain(
    List<String> names, {
    Map<String, int> depth = const <String, int>{},
  }) async {
    final _World w = _World();
    w.mesh.chain(names);
    for (final String n in names) {
      final LedgerNode node = await w.mesh.add(n);
      final PostReachService service = PostReachService(
        node: node,
        noticeAudience: () =>
            noticeAudienceFor(w.lists[n] ?? FriendListAudience.friends),
        delay: Duration.zero,
        minGap: Duration.zero,
        retryAfter: Duration.zero,
      );
      addTearDown(service.stop);
      await service.start();
      if (depth[n] case final int d) {
        await service.setDepth(d);
      }
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

  /// Everything phone [name] could put on its wall (others' posts, newest
  /// first), whatever it looks at.
  List<FeedPost> wall(String name) => <FeedPost>[
    for (final FeedPost p in buildFeed(
      mesh[name],
      nameOf: nameOf,
      held: reach[name],
    ))
      if (!p.isOwn) p,
  ];

  /// What phone [name] shows under [filter], as far as it looks.
  List<FeedPost> shown(String name, FeedFilter filter) => <FeedPost>[
    for (final FeedItem i in composeFeed(
      filter,
      wall: wall(name),
      pyramid: PyramidFeed.empty,
      depth: reach[name]!.depth,
    ))
      if (i is FeedFriendItem) i.post,
  ];

  /// The post [id] as phone [name] shows it under [filter], or `null`.
  FeedPost? postOn(String name, String id, [FeedFilter? filter]) {
    for (final FeedPost p in shown(name, filter ?? FeedFilter.all)) {
      if (p.id == id) {
        return p;
      }
    }
    return null;
  }

  /// The notices phone [name] wrote, as [reader] can read them (its own
  /// phone when not named).
  List<PostAnnouncement> passedOnBy(String name, {String? reader}) =>
      <PostAnnouncement>[
        for (final LogEntry e in mesh[reader ?? name].entriesOf(
          spaceKind: 'acts',
          ofAccount: mesh[name].account,
        ))
          if (e.account == mesh[name].account)
            ...announcementsIn(mesh[reader ?? name], e),
      ];

  /// The notice entries phone [name] wrote.
  List<LogEntry> noticeEntriesOf(String name) => <LogEntry>[
    for (final LogEntry e in mesh[name].entriesOf(spaceKind: 'acts'))
      if (e.kind == kPostAnnounceKind && e.account == mesh[name].account) e,
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
  Audience audience = Audience.public,
  List<Map<String, dynamic>> images = const <Map<String, dynamic>>[],
}) async => node.publish(
  kPostKind,
  await node.seal(
    audience,
    newPostBody(text, audience: audience, images: images),
  ),
  blobs: mediaIds(images),
);

void main() {
  group('a post and its notice', () {
    test('a post carries no reach: only its audience decides', () {
      expect(newPostBody('Hej'), <String, dynamic>{
        'text': 'Hej',
        'aud': 'public',
      });
      expect(isPublicPost(newPostBody('Hej')), isTrue);
      expect(
        isPublicPost(newPostBody('Hej', audience: Audience.close)),
        isFalse,
      );
    });

    test('a notice outside the rules is refused', () {
      Map<String, dynamic> notice({Object? h = 2}) => <String, dynamic>{
        'p': 'b' * 64,
        'a': 'konto',
        't': 1790000000000,
        'h': h,
      };
      expect(PostAnnouncement.fromJson(notice()), isNotNull);
      expect(PostAnnouncement.fromJson(notice(h: 3)), isNotNull);
      // A friend's own post, beyond three steps.
      expect(PostAnnouncement.fromJson(notice(h: 1)), isNull);
      expect(PostAnnouncement.fromJson(notice(h: 4)), isNull);
      expect(
        PostAnnouncement.fromJson(<String, dynamic>{...notice(), 'p': 'x'}),
        isNull,
      );
      expect(notice().keys, isNot(contains('r')));
    });

    test('who may see the friend list decides who reads the notices', () {
      expect(noticeAudienceFor(FriendListAudience.all), Audience.all);
      expect(noticeAudienceFor(FriendListAudience.friends), Audience.mid);
      expect(noticeAudienceFor(FriendListAudience.close), Audience.close);
      expect(noticeAudienceFor(FriendListAudience.onRequest), isNull);
      expect(noticeAudienceFor(FriendListAudience.nobody), isNull);
    });
  });

  group('a chain a–b–c–d', () {
    test(
      'c, looking two steps far, sees the post "przez Bob", fetched from b '
      'while the author is offline, photo included; "Znajomi" leaves it out',
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
        // b, a friend of the author, passed the notice on, sealed for the
        // friends who see its friend list; nothing else than the notice:
        // no text, no photo.
        final LogEntry entry = w.noticeEntriesOf('b').single;
        expect(isSealed(entry.body), isTrue);
        expect(entry.body['aud'], Audience.mid.name);
        final PostAnnouncement notice = w.passedOnBy('b').single;
        expect(notice.post, post.id);
        expect(notice.author, w['a'].account);
        expect(notice.hops, 2);
        expect(notice.toJson().keys, isNot(contains('text')));

        // The author goes offline; c comes back and gets it from b.
        w.mesh.setOnline('a', false);
        await w.mesh.comeBack('c');
        await w.rounds();
        expect(w.reach['c']!.depth, kDefaultFeedDepth);
        final FeedPost seen = w.postOn('c', post.id, FeedFilter.second)!;
        expect(seen.text, 'Wiosna w parku\n{{media:0}}');
        expect(seen.degree, 2);
        expect(seen.via, <String>['Bob']);
        expect(seen.authorLabel, 'Znajomy znajomego');
        expect(w['c'].blobs.isComplete(seen.images.single.id), isTrue);
        expect(await openMedia(w['c'].blobs, seen.images.single), isNotNull);
        expect(w.postOn('c', post.id), isNotNull);
        expect(w.postOn('c', post.id, FeedFilter.friends), isNull);
      },
    );

    test('d, looking three steps far, sees it "przez Cyryl", fetched from c '
        'while a and b are offline; d passes nothing on', () async {
      final _World w = await _World.chain(
        <String>['a', 'b', 'c', 'd'],
        depth: <String, int>{'d': 3},
      );
      w.mesh.setOnline('d', false);
      final LogEntry post = await _post(w['a'], 'Daleko');
      await w.mesh.settle();
      await w.rounds();
      expect(w.postOn('c', post.id, FeedFilter.second)?.via, <String>['Bob']);
      final PostAnnouncement fromC = w.passedOnBy('c').single;
      expect(fromC.hops, 3);

      w.mesh
        ..setOnline('a', false)
        ..setOnline('b', false);
      await w.mesh.comeBack('d');
      await w.rounds();
      final FeedPost seen = w.postOn('d', post.id, FeedFilter.third)!;
      expect(seen.text, 'Daleko');
      expect(seen.degree, 3);
      expect(seen.via, <String>['Cyryl']);
      expect(w.postOn('d', post.id), isNotNull);
      // Three steps is as far as anything goes.
      expect(w.passedOnBy('d'), isEmpty);
    });

    test('d, looking two steps far, neither fetches nor shows it', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
      final LogEntry post = await _post(w['a'], 'Za daleko dla Doroty');
      await w.mesh.settle();
      await w.rounds();
      expect(announcedPosts(w['d'])[post.id]?.hops, 3);
      expect(w.reach['d']!.heldPost(post.id), isNull);
      expect(w.postOn('d', post.id, FeedFilter.second), isNull);
      expect(w.postOn('d', post.id), isNull);

      // Once d looks further, it comes.
      await w.reach['d']!.setDepth(3);
      await w.rounds();
      expect(w.postOn('d', post.id, FeedFilter.third)?.via, <String>['Cyryl']);
    });

    test('c, looking at friends only, fetches nothing and passes nothing on; '
        'b still tells c', () async {
      final _World w = await _World.chain(
        <String>['a', 'b', 'c', 'd'],
        depth: <String, int>{'c': 1, 'd': 3},
      );
      final LogEntry post = await _post(w['a'], 'Tylko do Boba');
      await w.mesh.settle();
      await w.rounds();
      expect(w.passedOnBy('b').single.post, post.id);
      expect(announcedPosts(w['c']), contains(post.id));
      expect(w.reach['c']!.heldPost(post.id), isNull);
      expect(w.postOn('c', post.id), isNull);
      expect(w.noticeEntriesOf('c'), isEmpty);
      expect(announcedPosts(w['d']), isEmpty);
      expect(w.wall('d'), isEmpty);
    });

    test('a friend of b who may not see b\'s friend list gets no notice', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
      // A weak acquaintance does not see the list by default.
      await w['b'].setLevel(w.mesh.address('c'), FriendLevel.weak);
      await w.mesh.settle();
      final LogEntry post = await _post(w['a'], 'Nie dla słabych znajomych');
      await w.mesh.settle();
      await w.rounds();
      expect(w.passedOnBy('b').single.post, post.id);
      expect(w.noticeEntriesOf('b'), hasLength(1));
      expect(w.passedOnBy('b', reader: 'c'), isEmpty);
      expect(announcedPosts(w['c']), isEmpty);
      expect(w.wall('c'), isEmpty);

      // b shows the list to every friend: c reads the next notice.
      w.lists['b'] = FriendListAudience.all;
      await w.rounds();
      expect(w.noticeEntriesOf('b').last.body['aud'], Audience.all.name);
      expect(w.passedOnBy('b', reader: 'c').single.post, post.id);
      expect(w.postOn('c', post.id)?.via, <String>['Bob']);
    });

    test('with the friend list shown to nobody nothing is passed on', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c']);
      w.lists['b'] = FriendListAudience.nobody;
      await _post(w['a'], 'Lista ukryta');
      await w.mesh.settle();
      await w.rounds();
      expect(w.noticeEntriesOf('b'), isEmpty);
      expect(w.wall('c'), isEmpty);

      w.lists['b'] = FriendListAudience.onRequest;
      await w.rounds();
      expect(w.noticeEntriesOf('b'), isEmpty);
    });

    test('a post for friends only goes no further, and nobody hands it out '
        'when asked', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c', 'd']);
      final LogEntry sealed = await _post(
        w['a'],
        'Tylko dla przyjaciół',
        audience: Audience.close,
      );
      final LogEntry friends = await _post(
        w['a'],
        'Wszyscy znajomi',
        audience: Audience.all,
      );
      await w.mesh.settle();
      await w.rounds();
      expect(w.noticeEntriesOf('b'), isEmpty);
      expect(w.wall('c'), isEmpty);

      // c asks b for them anyway: no answer.
      final int answers = w.mesh.sent['b']?[kPostAnswerType] ?? 0;
      for (final LogEntry e in <LogEntry>[sealed, friends]) {
        await w['c'].transport.send(
          remoteAddress: w.mesh.address('b'),
          payload: postWantFrame(e.id, w['a'].account),
        );
      }
      // Nor does the author to someone who is not a friend.
      await w['d'].transport.send(
        remoteAddress: w.mesh.address('a'),
        payload: postWantFrame(friends.id, w['a'].account),
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
        expect(w.passedOnBy('c'), hasLength(10));
        expect(w.shown('d', FeedFilter.all), isEmpty);
      },
    );

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

    test('a fetched post and how far the phone looks are kept on the '
        'device', () async {
      final _World w = await _World.chain(<String>['a', 'b', 'c']);
      final LogEntry post = await _post(w['a'], 'Zostaje');
      await w.mesh.settle();
      await w.rounds();
      expect(w.reach['c']!.heldPost(post.id), isNotNull);
      await w.reach['c']!.setDepth(3);
      final PostReachService again = PostReachService(node: w['c']);
      addTearDown(again.stop);
      expect(again.depth, kDefaultFeedDepth);
      await again.start();
      expect(again.heldPost(post.id)?.post?.body['text'], 'Zostaje');
      expect(again.depth, 3);
    });
  });

  test('nothing goes past three steps: the phone three steps away hands the '
      'post to nobody', () async {
    final _World w = await _World.chain(
      <String>['a', 'b', 'c', 'd', 'e'],
      depth: <String, int>{'c': 3, 'd': 3, 'e': 3},
    );
    final LogEntry post = await _post(w['a'], 'Trzy kroki');
    await w.mesh.settle();
    await w.rounds();
    expect(w.reach['d']!.heldPost(post.id)?.hops, 3);
    expect(w.noticeEntriesOf('d'), isEmpty);
    expect(announcedPosts(w['e']), isEmpty);
    expect(w.wall('e'), isEmpty);

    // e asks d anyway: no answer.
    final int answers = w.mesh.sent['d']?[kPostAnswerType] ?? 0;
    await w['e'].transport.send(
      remoteAddress: w.mesh.address('d'),
      payload: postWantFrame(post.id, w['a'].account),
    );
    await w.mesh.settle();
    expect(w.mesh.sent['d']?[kPostAnswerType] ?? 0, answers);
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
    final _World w = await _World.chain(
      <String>['a', 'b', 'c', 'd', 'e'],
      depth: <String, int>{'b': 1, 'c': 1, 'd': 1, 'e': 1},
    );
    // Nobody passes notices on: the reshares alone carry the post.
    for (final String n in <String>['a', 'b', 'c', 'd', 'e']) {
      w.lists[n] = FriendListAudience.nobody;
    }
    final LogEntry post = await _post(w['a'], 'Udostępniaj');
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
    await w.rounds();
    for (final String n in <String>['a', 'b', 'c', 'd', 'e']) {
      expect(w.noticeEntriesOf(n), isEmpty);
    }
  });
}
