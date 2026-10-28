import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/reaction_digest.dart';
import 'package:zen/src/features/feed/reaction_notifier.dart';
import 'package:zen/src/features/ledger/bridge_book.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
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
