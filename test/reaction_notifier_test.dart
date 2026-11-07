import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_digest.dart';
import 'package:zen/src/features/feed/reaction_notifier.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
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

void main() {
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

  test('new reactions become one system notification per post, once', () async {
    final (LedgerNode a, LedgerNode b) = await pair();
    final List<RuntimeSystemNotification> posted =
        <RuntimeSystemNotification>[];
    bool inFront = false;
    final ReactionSystemNotifier notifier = ReactionSystemNotifier(
      node: a,
      nameOf: (String address) => address == bob ? 'Bob' : address,
      notify: (RuntimeSystemNotification n) async => posted.add(n),
      shouldNotify: () => !inFront,
      now: () => 42,
    );
    addTearDown(notifier.dispose);

    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle();
    // The first round only learns what is there.
    expect(await notifier.check(), 0);

    await b.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await b.publish(
      kCommentKind,
      commentBody(post.id, 'Super'),
      spaceKind: 'acts',
    );
    await _settle();
    expect(await notifier.check(), 1);
    final RuntimeSystemNotification n = posted.single;
    expect(n.id, 'react-${post.id}');
    expect(n.slotKey, n.id);
    expect(n.category, RuntimeSystemNotificationCategory.social);
    expect(n.createdAtMillis, 42);
    expect(n.title, 'Bob polubił(a) Twój post „Hej”');
    expect(n.body, 'Bob skomentował(a) Twój post „Hej”');
    // Announced: nothing more until something new happens.
    expect(await notifier.check(), 0);

    // While the app is in front, reactions count as seen.
    inFront = true;
    await b.publish(
      kCommentKind,
      commentBody(post.id, 'Jeszcze jedno'),
      spaceKind: 'acts',
    );
    await _settle();
    expect(await notifier.check(), 0);
    inFront = false;
    expect(await notifier.check(), 0);
    expect(posted, hasLength(1));
  });

  test('a steady trickle of reactions is told of while it lasts, not only '
      'once it calms down', () async {
    final (LedgerNode a, LedgerNode b) = await pair();
    final List<RuntimeSystemNotification> posted =
        <RuntimeSystemNotification>[];
    final ReactionSystemNotifier notifier = ReactionSystemNotifier(
      node: a,
      nameOf: (String address) => address == bob ? 'Bob' : address,
      notify: (RuntimeSystemNotification n) async => posted.add(n),
      shouldNotify: () => true,
      quiet: const Duration(milliseconds: 150),
      atMost: const Duration(milliseconds: 400),
    );
    addTearDown(notifier.dispose);
    final LogEntry post = await a.publish(kPostKind, newPostBody('Hej'));
    await _settle();
    // The first round only learns what is there.
    expect(await notifier.check(), 0);
    notifier.start();
    // A comment every 50 ms for well over a second: never 150 ms of quiet.
    for (int i = 0; i < 30 && posted.isEmpty; i++) {
      await b.publish(
        kCommentKind,
        commentBody(post.id, 'Komentarz $i'),
        spaceKind: 'acts',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(posted, isNotEmpty);
  });

  test('only reactions wake it, a check asked for during another one comes '
      'once after it, and nothing more', () async {
    final (LedgerNode a, LedgerNode b) = await pair();
    int checks = 0;
    final ReactionSystemNotifier notifier = ReactionSystemNotifier(
      node: a,
      nameOf: (String address) => address,
      notify: (RuntimeSystemNotification n) async {},
      // Asked once per check that gets as far as announcing.
      shouldNotify: () {
        checks++;
        return true;
      },
      quiet: const Duration(milliseconds: 30),
      atMost: const Duration(milliseconds: 100),
    );
    addTearDown(notifier.dispose);
    // The first round only learns what is there (and asks nothing).
    expect(await notifier.check(), 0);
    expect(checks, 0);
    expect(await notifier.check(), 0);
    expect(checks, 1);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(checks, 1, reason: 'nothing was asked for in between');

    // Two at once: the second waits for the first, then goes once.
    await Future.wait(<Future<int>>[notifier.check(), notifier.check()]);
    expect(checks, 2);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(checks, 3);

    // Started: one look now, then only what reacts to posts wakes it.
    notifier.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(checks, 4);
    final LogEntry post = await b.publish(kPostKind, newPostBody('Nowy'));
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(checks, 4, reason: 'a post is no reaction');
    await b.publish(kLikeKind, likeBody(post.id), spaceKind: 'acts');
    await _settle();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(checks, 5);
  });

  test("reactions under a friend's post are not about yours; a suspended or "
      'closed notifier tells nothing', () async {
    final (LedgerNode a, LedgerNode b) = await pair();
    final List<RuntimeSystemNotification> posted =
        <RuntimeSystemNotification>[];
    final ReactionSystemNotifier notifier = ReactionSystemNotifier(
      node: a,
      nameOf: (String address) => address == bob ? 'Bob' : address,
      notify: (RuntimeSystemNotification n) async => posted.add(n),
      shouldNotify: () => true,
    );
    addTearDown(notifier.dispose);
    final LogEntry mine = await a.publish(kPostKind, newPostBody('Mój'));
    final LogEntry his = await b.publish(kPostKind, newPostBody('Jego'));
    await _settle();
    expect(await notifier.check(), 0);
    // This phone likes the friend's post: a reaction, not under one's own.
    await a.publish(kLikeKind, likeBody(his.id), spaceKind: 'acts');
    await _settle();
    expect(await notifier.check(), 0);

    await b.publish(kLikeKind, likeBody(mine.id), spaceKind: 'acts');
    await _settle();
    final ReactionSystemNotifier closed = ReactionSystemNotifier(
      node: a,
      nameOf: (String address) => address,
      notify: (RuntimeSystemNotification n) async => posted.add(n),
      shouldNotify: () => true,
    )..dispose();
    expect(await closed.check(), 0, reason: 'closed');
    await a.suspend();
    expect(await notifier.check(), 0, reason: 'suspended');
    expect(posted, isEmpty);
  });

  test('likes alone, comments alone: the title says it, the body is general; '
      'a tap opens that post', () {
    ReactionNotice notice({int likes = 0, int comments = 0}) => ReactionNotice(
      postId: 'p1',
      excerpt: 'Hej',
      likers: <String>[if (likes > 0) 'Cela'],
      likes: likes,
      commenters: <String>[if (comments > 0) 'Dan'],
      comments: comments,
      millis: 0,
    );
    final RuntimeSystemNotification liked = reactionNotification(
      notice(likes: 1),
      createdAtMillis: 1,
    );
    expect(liked.title, contains('Cela'));
    expect(liked.body, 'Reakcje na Twoje posty');
    final RuntimeRouteIntent tap = runtimeRouteIntentFromRouteKey(
      id: 'tap',
      routeKey: liked.routeKey,
    )!;
    // One's own post in one's profile (they are not on the Tablica).
    expect(tap.target, RuntimeRouteTarget.ownPost);
    expect(tap.postId, 'p1');
    expect(
      runtimeRouteIntentFromRouteKey(id: 'x', routeKey: 'zen://post?p='),
      isNull,
    );
    final RuntimeSystemNotification commented = reactionNotification(
      notice(comments: 1),
      createdAtMillis: 1,
    );
    expect(commented.title, contains('Dan'));
    expect(commented.body, 'Reakcje na Twoje posty');
    final RuntimeSystemNotification both = reactionNotification(
      notice(likes: 1, comments: 1),
      createdAtMillis: 1,
    );
    expect(both.title, contains('Cela'));
    expect(both.body, contains('Dan'));
  });

  test('the notification title is one that the privacy setting redacts', () {
    const ReactionNotice n = ReactionNotice(
      postId: 'p1',
      excerpt: 'Hej',
      likers: <String>['Cela', 'Dan'],
      likes: 2,
      commenters: <String>[],
      comments: 0,
      millis: 0,
    );
    final RuntimeSystemNotification note = reactionNotification(
      n,
      createdAtMillis: 1,
    );
    expect(note.title, contains('Cela'));
    expect(PrivacyRedactingNotificationService.hidesTitle(note), isTrue);

    final MemoryRuntimeSystemNotificationService shade =
        MemoryRuntimeSystemNotificationService();
    final PrivacyRedactingNotificationService service =
        PrivacyRedactingNotificationService(
          shade,
          privacy: () => NotificationPrivacy.senderOnly,
        );
    final RuntimeSystemNotification hidden = service.redact(note);
    expect(hidden.title, PrivacyRedactingNotificationService.genericTitle);
    expect(hidden.body, isNot(contains('Cela')));
  });
}
