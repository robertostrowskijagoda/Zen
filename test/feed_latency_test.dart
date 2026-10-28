import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_notifier.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/ledger_mesh.dart';

/// How fast the wall's news travels while everyone is online: the phones'
/// ledgers on a [LedgerMesh] with their reach services on the services' own
/// timers (as the app runs them), on a fake clock. Each test states the
/// longest a step may take, so a slower path is caught.

/// Runs [body] on a fake clock that moves on whenever [body] waits for it;
/// the phones are stopped at the end. What completes outside the fake clock
/// (some stream cancellations) gets its turn in between.
Future<void> _onFakeClock(Future<void> Function(_Wall w) body) async {
  final FakeAsync clock = FakeAsync();
  final _Wall w = _Wall(clock);
  bool done = false;
  Object? failure;
  StackTrace? trace;
  clock.run((_) {
    unawaited(() async {
      try {
        await body(w);
      } on Object catch (error, stackTrace) {
        failure = error;
        trace = stackTrace;
      }
      try {} finally {
        done = true;
      }
    }());
  });
  while (!done) {
    clock.elapse(const Duration(milliseconds: 50));
    await Future<void>.value();
  }
  if (failure case final Object error) {
    Error.throwWithStackTrace(error, trace!);
  }
}

/// Phones on a mesh with their reach services, on [clock].
final class _Wall {
  _Wall(this.clock) : _base = DateTime.now().millisecondsSinceEpoch {
    mesh.stoppedByTest = true;
  }

  final FakeAsync clock;
  final LedgerMesh mesh = LedgerMesh();
  final Map<String, PostReachService> reach = <String, PostReachService>{};
  final List<FriendPostNotifier> _notifiers = <FriendPostNotifier>[];
  final int _base;

  /// The time on the fake clock (one clock for every phone).
  int now() => _base + clock.elapsed.inMilliseconds;

  /// Lets [time] pass.
  Future<void> wait(Duration time) => Future<void>.delayed(time);

  /// Starts phones [names] (friends as set on [mesh] before), each looking
  /// as far as [depth] says (2 when not named), and lets the start settle.
  Future<void> start(
    List<String> names, {
    Map<String, int> depth = const <String, int>{},
  }) async {
    for (final String n in names) {
      final LedgerNode node = await mesh.add(n, wallClock: now);
      final PostReachService service = PostReachService(node: node, now: now);
      await service.start();
      if (depth[n] case final int d) {
        await service.setDepth(d);
      }
      reach[n] = service;
    }
    // Past the rounds of the start.
    await wait(const Duration(minutes: 3));
  }

  LedgerNode operator [](String name) => mesh[name];

  /// Lets the fake clock run until [done] holds; fails after [within].
  /// Returns how long it took.
  Future<Duration> until(
    bool Function() done, {
    required Duration within,
    required String reason,
  }) async {
    final int from = now();
    while (!done()) {
      if (now() - from > within.inMilliseconds) {
        fail('$reason took longer than $within');
      }
      await wait(const Duration(milliseconds: 250));
    }
    return Duration(milliseconds: now() - from);
  }

  /// A notifier of friends' posts on phone [name] that also announces posts
  /// of friends of friends; what it posts goes to [shown].
  FriendPostNotifier notifier(
    String name,
    List<RuntimeSystemNotification> shown,
  ) {
    final PostReachService held = reach[name]!;
    final FriendPostNotifier n = FriendPostNotifier(
      node: mesh[name],
      nameOf: (String address) => address,
      notify: (RuntimeSystemNotification note) async => shown.add(note),
      dismissSlot: (String _) async {},
      addToInbox: (InboxEntry _) async {},
      shouldNotify: () => true,
      lookingAtFeed: () => false,
      announces: (String _) => true,
      privacyOf: (String _) => NotificationPrivacy.senderAndContent,
      privacy: () => NotificationPrivacy.senderAndContent,
      announcesFar: () => true,
      farPosts: () => <FeedPost>[
        for (final FeedPost p in buildFeed(
          mesh[name],
          nameOf: (String a) => a,
          held: held,
        ))
          if (!p.isOwn && p.degree > 1) p,
      ],
      farChanges: held.changes,
      now: now,
    );
    _notifiers.add(n);
    return n;
  }

  /// Stops the notifiers, the services and the ledgers.
  Future<void> stop() async {
    for (final FriendPostNotifier n in _notifiers) {
      n.dispose();
    }
    await Future.wait(<Future<void>>[
      for (final PostReachService r in reach.values) r.stop(),
      for (final LedgerNode n in mesh.nodes.values) n.stop(),
    ]);
  }
}

Future<LogEntry> _post(LedgerNode node, String text) async => node.publish(
  kPostKind,
  await node.seal(Audience.public, newPostBody(text)),
);

/// The notice entries [node] wrote.
List<LogEntry> _noticesOf(LedgerNode node) => <LogEntry>[
  for (final LogEntry e in node.entriesOf(spaceKind: 'acts'))
    if (e.kind == kPostAnnounceKind && e.account == node.account) e,
];

bool _hasEntry(LedgerNode node, LogEntry e) =>
    node.entriesOf(ofAccount: e.account).any((LogEntry x) => x.id == e.id);

void main() {
  test(
    'a friend\'s post is on the friend\'s phone within a second',
    () => _onFakeClock((_Wall w) async {
      w.mesh.chain(<String>['a', 'b']);
      await w.start(<String>['a', 'b']);
      final LogEntry post = await _post(w['a'], 'Dzień dobry');
      await w.until(
        () => _hasEntry(w['b'], post),
        within: const Duration(seconds: 1),
        reason: 'the post reaching b',
      );
    }),
  );

  test(
    'a post reaches a friend of a friend within 10 seconds '
    '(20 to 40 before), and the next one within the gap between '
    'notices (2 minutes, 10 before)',
    () => _onFakeClock((_Wall w) async {
      w.mesh.chain(<String>['a', 'b', 'c']);
      await w.start(<String>['a', 'b', 'c']);
      final LogEntry first = await _post(w['a'], 'Pierwszy');
      await w.until(
        () => w.reach['c']!.heldPost(first.id) != null,
        within: const Duration(seconds: 10),
        reason: 'the first post reaching c',
      );
      await w.wait(const Duration(seconds: 20));
      final LogEntry second = await _post(w['a'], 'Drugi');
      await w.until(
        () => w.reach['c']!.heldPost(second.id) != null,
        within: const Duration(minutes: 2, seconds: 10),
        reason: 'the second post reaching c',
      );
      // Posts of one burst still go in one notice.
      final LogEntry third = await _post(w['a'], 'Trzeci');
      final LogEntry fourth = await _post(w['a'], 'Czwarty');
      await w.until(
        () =>
            w.reach['c']!.heldPost(third.id) != null &&
            w.reach['c']!.heldPost(fourth.id) != null,
        within: const Duration(minutes: 2, seconds: 10),
        reason: 'a burst reaching c',
      );
      expect(_noticesOf(w['b']), hasLength(3));
    }),
  );

  test(
    'a post reaches the phone three steps away within 20 seconds',
    () => _onFakeClock((_Wall w) async {
      w.mesh.chain(<String>['a', 'b', 'c', 'd']);
      await w.start(<String>['a', 'b', 'c', 'd'], depth: <String, int>{'d': 3});
      final LogEntry post = await _post(w['a'], 'Daleko');
      await w.until(
        () => w.reach['d']!.heldPost(post.id)?.hops == 3,
        within: const Duration(seconds: 20),
        reason: 'the post reaching d',
      );
    }),
  );

  test(
    'an ask lost on the way is repeated within a minute and a '
    'half, not at the next ten-minute round',
    () => _onFakeClock((_Wall w) async {
      w.mesh.chain(<String>['a', 'b', 'c']);
      await w.start(<String>['a', 'b', 'c']);
      int lost = 0;
      w.mesh.drop = (String from, String to, Map<String, dynamic> payload) =>
          from == 'c' && payload['type'] == kPostWantType && lost++ == 0;
      final LogEntry post = await _post(w['a'], 'Zgubione pytanie');
      await w.until(
        () => w.reach['c']!.heldPost(post.id) != null,
        within: const Duration(seconds: 90),
        reason: 'the post reaching c after a lost ask',
      );
      expect(lost, greaterThan(1));
    }),
  );

  test(
    'waiting for the gap between notices holds up no fetch',
    () => _onFakeClock((_Wall w) async {
      // b is a friend of a and of y; y is a friend of x. y looks at its
      // friends only, so it passes on x's posts and nothing further (no gap
      // of its own to wait for).
      w.mesh.chain(<String>['x', 'y', 'b', 'a']);
      await w.start(<String>['x', 'y', 'b', 'a'], depth: <String, int>{'y': 1});
      await _post(w['a'], 'Pierwszy od a');
      await w.until(
        () => _noticesOf(w['b']).isNotEmpty,
        within: const Duration(seconds: 10),
        reason: 'b passing a\'s post on',
      );
      // b's next notice has to wait for the gap now.
      await _post(w['a'], 'Drugi od a');
      await w.wait(const Duration(seconds: 5));
      final LogEntry far = await _post(w['x'], 'Od x');
      await w.until(
        () => w.reach['b']!.heldPost(far.id) != null,
        within: const Duration(seconds: 10),
        reason: 'x\'s post reaching b while b waits for the gap',
      );
    }),
  );

  test(
    'a post of a friend of a friend is told of within 15 seconds '
    'of being posted, with no friend posting after it',
    () => _onFakeClock((_Wall w) async {
      w.mesh.chain(<String>['a', 'b', 'c']);
      await w.start(<String>['a', 'b', 'c']);
      final List<RuntimeSystemNotification> shown =
          <RuntimeSystemNotification>[];
      w.notifier('c', shown).start();
      // The first check only learns what is there.
      await w.wait(const Duration(minutes: 1));
      expect(shown, isEmpty);
      await _post(w['a'], 'Z daleka');
      await w.until(
        () => shown.isNotEmpty,
        within: const Duration(seconds: 15),
        reason: 'the notification of the far post',
      );
      expect(shown.single.kind, NoticeKind.farPost);
    }),
  );
}
