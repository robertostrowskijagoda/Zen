import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_author.dart';
import 'package:zen/src/core/ledger/ledger_store.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/feed/reaction_relay.dart';
import 'package:zen/src/features/health/health_report.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_fold.dart';
import 'package:zen/src/features/ledger/ledger_identity_store.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/profile_fields.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// What a friend's activity costs every one of their friends' phones: a
// like taken back, a bundle of reactions or a profile replaced by a newer
// one no longer count, and a fold lets every holder drop them, while what
// every screen reads stays the same, for a friend who kept the log, a new
// friend and a restored phone alike; and how much of one friend a phone
// keeps at most.

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
    if (target != null && nodes[address] == this) {
      scheduleMicrotask(
        () => target.injectIncoming(from: address, payload: payload),
      );
    }
  }
}

String _a(String s) => PeerShareCodec.normalizeAddress(s);

Future<void> _settle([int rounds = 120]) async {
  for (int i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Bytes [n] holds of [account]'s [kind] space, every log of it.
int _heldOf(LedgerNode n, String kind, String account) {
  final String space = accountSpace(kind, account);
  int bytes = 0;
  for (final String writer in n.store.heads(space).keys) {
    bytes += n.store.heldBytes(space, writer);
  }
  return bytes;
}

final class _Net {
  final Map<String, _Linked> nodes = <String, _Linked>{};

  Future<LedgerNode> node(
    String address,
    List<String> friends, {
    MemoryLedgerDisk? disk,
  }) async {
    final _Linked t = nodes[address] = _Linked(address, nodes);
    await t.start();
    final LedgerNode n = LedgerNode(
      transport: t,
      disk: disk ?? MemoryLedgerDisk(),
      friendAddresses: () => friends,
      bridges: BridgeBook(probe: (String _) async => null),
      localAddress: () => address,
      syncInterval: Duration.zero,
      helloInterval: Duration.zero,
    );
    addTearDown(n.stop);
    await n.start();
    return n;
  }

  Future<void> sync(List<LedgerNode> nodes, {int rounds = 4}) async {
    for (int round = 0; round < rounds; round++) {
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      for (final LedgerNode n in nodes) {
        await n.greetFriends();
      }
      await _settle(200);
    }
  }
}

/// What the wall shows of each post, whoever looks: who likes it, which
/// comments it has (id, writer, words) and the totals.
Map<String, String> _wall(LedgerNode n) => <String, String>{
  for (final FeedPost p in buildFeed(n, nameOf: (String a) => a))
    p.id:
        'likes ${(p.likes.map((FeedLiker l) => l.account).toList()..sort())} '
        'total ${p.likeTotal}; comments '
        '${(p.comments.map((FeedComment c) => '${c.id}/${c.account}/${c.text}').toList()..sort())} '
        'total ${p.commentTotal}',
};

void main() {
  setUp(() {
    LedgerNode.rebaseDropDelay = const Duration(milliseconds: 20);
    LedgerNode.foldDelay = const Duration(hours: 1);
  });
  tearDown(() {
    LedgerNode.rebaseDropDelay = const Duration(seconds: 30);
    LedgerNode.foldDelay = const Duration(seconds: 5);
    LedgerNode.foldOwnKeep = kFoldOwnKeep;
    LedgerNode.foldSlack = kFoldSlackBytes;
  });

  test('the kinds a fold leaves out are the features\' own', () {
    expect(kFoldLikeKind, kLikeKind);
    expect(kFoldBundleKind, kReactionsKind);
    expect(kFoldBundlePageKind, kReactionsPageKind);
    expect(kFoldProfileKinds, <String>{
      kProfileKind,
      ...kProfilePartKinds.values,
    });
  });

  test('200 taps on a heart that end with no like cost a friend a few '
      'kilobytes once the tapper\'s phone folds its log, not a megabyte for '
      'ever', () async {
    final _Net net = _Net();
    final String ada = _a('200::a');
    final String bob = _a('200::b');
    final String cel = _a('200::c');
    final LedgerNode a = await net.node(ada, <String>[bob]);
    final LedgerNode b = await net.node(bob, <String>[ada, cel]);
    await net.node(cel, <String>[bob]);
    await _settle();
    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle(200);

    const int taps = 200;
    for (int i = 0; i < taps; i++) {
      await b.publish(
        kLikeKind,
        likeBody(post.id, on: i.isEven),
        spaceKind: 'acts',
      );
    }
    await net.sync(<LedgerNode>[a, b]);
    final int before = _heldOf(a, 'acts', b.account);
    final int tapped = a
        .entriesOf(spaceKind: 'acts', ofAccount: b.account)
        .where((LogEntry e) => e.kind == kLikeKind)
        .length;

    expect(await b.foldNow('acts'), isTrue);
    await net.sync(<LedgerNode>[a, b], rounds: 3);
    final int after = _heldOf(a, 'acts', b.account);
    // ignore: avoid_print
    print(
      'Ada holds of Bob\'s $taps like taps: before the fold $before bytes '
      '($tapped likes, ${before ~/ tapped} B each), after it $after bytes',
    );
    expect(tapped, taps);
    expect(before, greaterThan(taps * 3300));
    expect(after, lessThan(32 * 1024));
    // The same as before: Bob's likes that count, on both phones.
    expect(
      likedPosts(a.entriesOf(spaceKind: 'acts', ofAccount: b.account)),
      isEmpty,
    );
    expect(likedPosts(b.entriesOf(spaceKind: 'acts')), isEmpty);
    // The tapper's own phone keeps its whole log a while longer.
    expect(
      b.entriesOf(spaceKind: 'acts').where((LogEntry e) => e.kind == kLikeKind),
      hasLength(taps),
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('after a fold the wall is the same for a friend who kept the log, a '
      'new friend and the liker\'s restored phone', () async {
    LedgerNode.foldOwnKeep = Duration.zero;
    LedgerNode.foldSlack = 4 * 1024;
    final _Net net = _Net();
    final String ada = _a('200::1a');
    final String bob = _a('200::1b');
    final String dan = _a('200::1d');
    final String bobNew = _a('200::1e');
    final MemoryLedgerDisk bobDisk = MemoryLedgerDisk();
    final LedgerNode a = await net.node(ada, <String>[bob, dan]);
    final LedgerNode b = await net.node(bob, <String>[ada], disk: bobDisk);
    await _settle();
    final List<LogEntry> posts = <LogEntry>[
      for (int i = 0; i < 3; i++)
        await a.publish(kPostKind, newPostBody('Post $i')),
    ];
    await net.sync(<LedgerNode>[a, b], rounds: 2);
    const MiniProfileTag mini = MiniProfileTag(name: 'Bob');
    // Bob likes the first post, changes his mind about the second many
    // times (ending with a like), and comments under two of them.
    await b.publish(
      kLikeKind,
      likeBody(posts[0].id, mini: mini),
      spaceKind: 'acts',
    );
    for (int i = 0; i < 21; i++) {
      await b.publish(
        kLikeKind,
        likeBody(posts[1].id, on: i.isEven, mini: mini),
        spaceKind: 'acts',
      );
    }
    await b.publish(
      kCommentKind,
      commentBody(posts[0].id, 'Pierwszy!', mini: mini),
      spaceKind: 'acts',
    );
    final LogEntry gone = await b.publish(
      kCommentKind,
      commentBody(posts[2].id, 'Pomyłka'),
      spaceKind: 'acts',
    );
    await b.publish(
      kCommentDeleteKind,
      commentDeleteBody(posts[2].id, gone.id),
      spaceKind: 'acts',
    );
    await b.publish(
      kCommentKind,
      commentBody(posts[2].id, 'Ładne'),
      spaceKind: 'acts',
    );
    // Ada's bundles for her posts are written again with every change.
    for (int round = 0; round < 3; round++) {
      await net.sync(<LedgerNode>[a, b], rounds: 1);
      await relayReactions(a, nameOf: (String x) => x);
      await a.publish(
        kLikeKind,
        likeBody(posts[round].id, on: round != 1),
        spaceKind: 'acts',
      );
    }
    await publishProfileIfChanged(b, <String, dynamic>{'name': 'Bob 1'});
    await publishProfileIfChanged(b, <String, dynamic>{'name': 'Bob 2'});
    await net.sync(<LedgerNode>[a, b], rounds: 2);
    final Map<String, String> adaBefore = _wall(a);
    final Map<String, String> bobBefore = _wall(b);
    final int heldBefore = _heldOf(a, 'acts', b.account);
    expect(adaBefore, hasLength(3));
    expect(adaBefore[posts[0].id], contains(b.account));
    expect(adaBefore[posts[1].id], contains(b.account));
    expect(adaBefore[posts[0].id], contains('Pierwszy!'));
    expect(adaBefore[posts[2].id], contains('Ładne'));
    expect(adaBefore[posts[2].id], isNot(contains('Pomyłka')));

    expect(await b.foldNow('acts'), isTrue);
    expect(await a.foldNow('acts'), isTrue);
    await b.foldNow('profile');
    await net.sync(<LedgerNode>[a, b], rounds: 3);
    // Both dropped what came before the folds, their own logs too.
    expect(
      a.store.baseOf(accountSpace('acts', b.account), b.author.writer).base,
      greaterThan(0),
    );
    expect(
      b.store.baseOf(accountSpace('acts', b.account), b.author.writer).base,
      greaterThan(0),
    );
    expect(_heldOf(a, 'acts', b.account), lessThan(heldBefore ~/ 2));
    expect(_wall(a), adaBefore);
    expect(_wall(b), bobBefore);
    expect(latestProfile(a, b.account)?.name, 'Bob 2');

    // A new friend of Ada's takes her log from her folds on.
    final LedgerNode d = await net.node(dan, <String>[ada]);
    await net.sync(<LedgerNode>[a, d], rounds: 3);
    expect(
      d.store.baseOf(accountSpace('acts', a.account), a.author.writer).base,
      greaterThan(0),
    );
    final Map<String, String> danWall = _wall(d);
    // Dan is no friend of Bob's: what Bob did comes in Ada's bundles.
    expect(danWall[posts[0].id], contains(b.account));
    expect(danWall[posts[1].id], contains(b.account));
    expect(danWall[posts[0].id], contains('Pierwszy!'));
    expect(danWall[posts[2].id], contains('Ładne'));
    expect(
      readBundles(d.entriesOf(spaceKind: 'acts', ofAccount: a.account)).map(
        (String post, PostReactions r) => MapEntry<String, String>(
          post,
          '${r.likes.map((BundleLike l) => l.account).toList()..sort()} '
          '${r.comments.map((BundleComment c) => c.id).toList()..sort()}',
        ),
      ),
      readBundles(a.entriesOf(spaceKind: 'acts')).map(
        (String post, PostReactions r) => MapEntry<String, String>(
          post,
          '${r.likes.map((BundleLike l) => l.account).toList()..sort()} '
          '${r.comments.map((BundleComment c) => c.id).toList()..sort()}',
        ),
      ),
    );

    // Bob's phone is lost; a new one gets his likes and comments back from
    // Ada alone, from the fold on.
    net.nodes.remove(bob);
    await b.stop();
    final MemoryLedgerDisk fresh = MemoryLedgerDisk();
    await LedgerIdentity.adoptAccount(
      fresh,
      (await LedgerIdentity.loadOrCreate(bobDisk)).accountKey!.seed,
    );
    final LedgerNode restored = await net.node(bobNew, <String>[
      ada,
    ], disk: fresh);
    await net.sync(<LedgerNode>[a, restored], rounds: 4);
    expect(_wall(restored), bobBefore);
    expect(latestProfile(restored, restored.account)?.name, 'Bob 2');
  }, timeout: const Timeout(Duration(minutes: 8)));

  group('a friend\'s log within its bound', () {
    late LedgerAccountSetup friend;
    late LedgerStore own;
    late LedgerAuthor author;
    late LedgerStore holder;
    const int quota = 200 * 1024;

    setUp(() async {
      friend = await LedgerAccountSetup.create();
      own = LedgerStore()..ownAccount = friend.certificate.account;
      author = LedgerAuthor(
        deviceKey: friend.deviceKey,
        certificate: friend.certificate,
        store: own,
      );
      holder = LedgerStore(
        policies: (String space) {
          final SpacePolicy? p = defaultSpacePolicy(space);
          return p is AccountSpacePolicy
              ? AccountSpacePolicy(p.owner, maxBytes: quota)
              : p;
        },
      );
    });

    Future<List<IngestResult>> pass(String space) async => <IngestResult>[
      for (final LogEntry e in own.entriesAfter(
        space,
        author.writer,
        holder.headOf(space, author.writer),
      ))
        await holder.ingest(e),
    ];

    test('posts past the bound are refused and said so; none already kept '
        'goes', () async {
      final String feed = accountSpace('feed', friend.certificate.account);
      final List<LogEntry> written = <LogEntry>[];
      for (int i = 0; i < 40; i++) {
        written.add(
          await author.append(feed, kPostKind, newPostBody('x' * 5000)),
        );
      }
      final List<IngestResult> results = await pass(feed);
      final int kept = holder.headOf(feed, author.writer);
      expect(kept, lessThan(written.length));
      expect(
        results
            .skip(kept)
            .every((IngestResult r) => r.status == IngestStatus.rejected),
        isTrue,
      );
      expect(holder.fullSpaces, contains(feed));
      expect(
        holder.entries(feed).map((LogEntry e) => e.id),
        written.take(kept).map((LogEntry e) => e.id),
      );
      expect(holder.heldBytes(feed, author.writer), lessThanOrEqualTo(quota));
      // The room notice counts the friend once.
      final LedgerRoomNotice notice = LedgerRoomNotice()
        ..update(holder.fullSpaces);
      expect(notice.full, 1);
      // "Dlaczego nie działa?" says so.
      final HealthItem? line = buildHealthReport(
        HealthInputs(net: HealthNetState.active, friendLogsFull: notice.full),
      ).item('friend_logs');
      expect(line?.level, HealthLevel.warn);
      expect(
        buildHealthReport(
          const HealthInputs(net: HealthNetState.active),
        ).item('friend_logs'),
        isNull,
      );
      // This device's own spaces are never bounded.
      holder.ownAccount = friend.certificate.account;
      await pass(feed);
      expect(holder.headOf(feed, author.writer), written.length);
    });

    test('a full log moves to its writer\'s fold, which keeps what counts, '
        'and takes new entries again', () async {
      final String acts = accountSpace('acts', friend.certificate.account);
      await author.append(acts, kLikeKind, likeBody('p-kept'));
      for (int i = 0; i < 60; i++) {
        await author.append(acts, kLikeKind, likeBody('p-tapped', on: i.isOdd));
      }
      await pass(acts);
      expect(holder.fullSpaces, contains(acts));
      final int stuck = holder.headOf(acts, author.writer);
      expect(stuck, lessThan(61));

      final List<LedgerDraft>? drafts = planFold(
        own.logView(acts, author.writer),
      );
      expect(drafts, isNotNull);
      await author.appendRun(acts, drafts!);
      await author.append(acts, kLikeKind, likeBody('p-new'));
      await pass(acts);
      expect(holder.fullSpaces, isEmpty);
      expect(
        holder.headOf(acts, author.writer),
        own.headOf(acts, author.writer),
      );
      expect(likedPosts(holder.entries(acts)), likedPosts(own.entries(acts)));
      expect(likedPosts(holder.entries(acts)), <String>{
        'p-kept',
        'p-tapped',
        'p-new',
      });
      expect(holder.heldBytes(acts, author.writer), lessThan(quota ~/ 4));
    });
  });

  test('a build before 1.17.0 sees no checkpoint in a fold and keeps the '
      'whole log; read whole, it says the same', () async {
    final LedgerAccountSetup friend = await LedgerAccountSetup.create();
    final LedgerStore own = LedgerStore();
    final LedgerAuthor author = LedgerAuthor(
      deviceKey: friend.deviceKey,
      certificate: friend.certificate,
      store: own,
    );
    final String acts = accountSpace('acts', friend.certificate.account);
    for (int i = 0; i < 30; i++) {
      await author.append(acts, kLikeKind, likeBody('p${i % 3}', on: i < 28));
    }
    await author.append(acts, kCommentKind, commentBody('p0', 'Hej'));
    final Set<String> liked = likedPosts(own.entries(acts));
    final List<LogEntry> run = await author.appendRun(
      acts,
      planFold(own.logView(acts, author.writer))!,
    );
    final LogEntry fold = run.first;
    // What builds before 1.17.0 look for: neither is there.
    expect(isLedgerCheckpoint(fold), isFalse);
    expect(rebaseCountOf(fold), isNull);
    // Everything held, the fold's kinds read as unknown: the same.
    expect(likedPosts(own.entries(acts)), liked);
    expect(
      own.entries(acts).where((LogEntry e) => e.kind == kCommentKind),
      hasLength(1),
    );
    // Dropped to the fold, the carried entries keep their ids.
    final Set<String> ids = <String>{
      for (final LogEntry e in own.entries(acts))
        if (e.kind != kLedgerFoldKind && e.kind != kLedgerCarryKind) e.id,
    };
    own.pruneBefore(acts, author.writer, fold.seq);
    expect(likedPosts(own.entries(acts)), liked);
    final Set<String> left = <String>{
      for (final LogEntry e in own.entries(acts))
        if (e.kind != kLedgerFoldKind && e.kind != kLedgerCarryKind) e.id,
    };
    expect(ids.containsAll(left), isTrue);
    expect(
      own.entries(acts).where((LogEntry e) => e.kind == kCommentKind).single,
      isA<LogEntry>().having((LogEntry e) => e.isVouched, 'vouched', isFalse),
    );
  });

  test('a year of ordinary use: what one friend costs a phone with and '
      'without folds', () async {
    // Ten acts a day: six likes that stay, a like taken back (two entries),
    // a comment, and a bundle of reactions under the friend's own post
    // written again.
    const int days = 365;
    final LedgerAccountSetup friend = await LedgerAccountSetup.create();
    final LedgerStore own = LedgerStore()
      ..ownAccount = friend.certificate.account;
    final LedgerAuthor author = LedgerAuthor(
      deviceKey: friend.deviceKey,
      certificate: friend.certificate,
      store: own,
    );
    final LedgerStore folds = LedgerStore();
    final String acts = accountSpace('acts', friend.certificate.account);
    const MiniProfileTag mini = MiniProfileTag(name: 'Ola Kowalska');
    String postId(int n) => n.toRadixString(16).padLeft(64, '0');
    int peak = 0;
    int folded = 0;
    final Stopwatch clock = Stopwatch()..start();
    for (int day = 0; day < days; day++) {
      for (int i = 0; i < 6; i++) {
        await author.append(
          acts,
          kLikeKind,
          likeBody(postId(day * 10 + i), mini: mini),
        );
      }
      await author.append(acts, kLikeKind, likeBody(postId(day * 10 + 7)));
      await author.append(
        acts,
        kLikeKind,
        likeBody(postId(day * 10 + 7), on: false),
      );
      await author.append(
        acts,
        kCommentKind,
        commentBody(postId(day * 10 + 8), 'Super zdjęcie, gratulacje!'),
      );
      await author.append(acts, kReactionsKind, <String, dynamic>{
        'post': postId(1000000 + day ~/ 3),
        'likes': <Map<String, dynamic>>[
          for (int l = 0; l < 3 + day % 3; l++)
            <String, dynamic>{'a': 'konto$l', 'n': 'Znajomy $l'},
        ],
        'comments': const <Object>[],
      });
      final List<LedgerDraft>? drafts = planFold(
        own.logView(acts, author.writer),
      );
      if (drafts != null) {
        await author.appendRun(acts, drafts);
        folded++;
      }
      for (final LogEntry e in own.entriesAfter(
        acts,
        author.writer,
        folds.headOf(acts, author.writer),
      )) {
        await folds.ingest(e);
      }
      final int? ready = folds.readyRebase(acts, author.writer);
      if (ready != null) {
        folds.pruneBefore(acts, author.writer, ready);
      }
      final int held = folds.heldBytes(acts, author.writer);
      if (held > peak) {
        peak = held;
      }
    }
    // What a phone kept before folds existed, and what one that does not
    // understand them keeps (the folds' own entries too): the whole log,
    // as the writer's own phone holds it here.
    final int whole = own
        .entries(acts)
        .where(
          (LogEntry e) =>
              e.kind != kLedgerFoldKind && e.kind != kLedgerCarryKind,
        )
        .fold<int>(0, (int s, LogEntry e) => s + e.encodedLength);
    final int older = own.heldBytes(acts, author.writer);
    final int now = folds.heldBytes(acts, author.writer);
    final LogEntry like = own
        .entries(acts)
        .firstWhere((LogEntry e) => e.kind == kLikeKind);
    // ignore: avoid_print
    print(
      'one like: ${like.encodedLength} bytes signed, '
      '${like.encodedLength - like.signature.length - 32} carried by a fold',
    );
    const int mb = 1 << 20;
    // ignore: avoid_print
    print(
      'a year of 10 acts a day from one friend: without folds $whole bytes, '
      'with folds $now bytes (at most $peak), $folded folds, on a phone '
      'that does not understand them $older bytes; for 100 such friends '
      '${whole * 100 ~/ mb} MB, ${now * 100 ~/ mb} MB (at most '
      '${peak * 100 ~/ mb} MB), ${older * 100 ~/ mb} MB '
      '(${clock.elapsed.inSeconds} s)',
    );
    expect(likedPosts(folds.entries(acts)), likedPosts(own.entries(acts)));
    expect(
      readBundles(folds.entries(acts)).keys.toSet(),
      readBundles(own.entries(acts)).keys.toSet(),
    );
    expect(
      folds.entries(acts).where((LogEntry e) => e.kind == kCommentKind),
      hasLength(days),
    );
    expect(now * 2, lessThan(whole));
    expect(peak, lessThan(kFriendActsBytes ~/ 4));
  }, timeout: const Timeout(Duration(minutes: 20)));
}
