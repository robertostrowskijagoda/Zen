import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/post_notifier.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/ledger_mesh.dart';

/// What one phone's notifier posted, and the switches it reads.
final class _Phone {
  _Phone(this.mesh, this.name);

  final LedgerMesh mesh;
  final String name;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<InboxEntry> inbox = <InboxEntry>[];
  final List<String> dismissed = <String>[];
  bool inFront = false;
  bool onFeed = false;
  bool postsOn = true;
  final Set<String> muted = <String>{};
  NotificationPrivacy global = NotificationPrivacy.senderAndContent;
  final Map<String, NotificationPrivacy> own = <String, NotificationPrivacy>{};
  int? clock;

  LedgerNode get node => mesh[name];

  String nameOf(String address) {
    for (final String n in <String>['ada', 'bob', 'cela']) {
      if (mesh.address(n) == address) {
        return '${n[0].toUpperCase()}${n.substring(1)}';
      }
    }
    return address;
  }

  FriendPostNotifier notifier() {
    final FriendPostNotifier n = FriendPostNotifier(
      node: node,
      nameOf: nameOf,
      notify: (RuntimeSystemNotification note) async => shown.add(note),
      dismissSlot: (String slot) async => dismissed.add(slot),
      addToInbox: (InboxEntry entry) async {
        inbox
          ..removeWhere((InboxEntry e) => e.id == entry.id)
          ..insert(0, entry);
      },
      shouldNotify: () => !inFront,
      lookingAtFeed: () => inFront && onFeed,
      announces: (String address) => postsOn && !muted.contains(address),
      privacyOf: (String address) => own[address] ?? global,
      privacy: () => global,
      now: () => clock ?? DateTime.now().millisecondsSinceEpoch,
    );
    addTearDown(n.dispose);
    return n;
  }
}

/// [node] publishes a post; with [reaches], until that phone has it too.
Future<LogEntry> _post(
  LedgerNode node,
  String text, {
  LedgerNode? reaches,
}) async {
  final LogEntry post = await node.publish(kPostKind, newPostBody(text));
  if (reaches == null) {
    return post;
  }
  for (int i = 0; i < 400; i++) {
    if (reaches
        .entriesOf(ofAccount: node.account)
        .any((LogEntry e) => e.id == post.id)) {
      return post;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  throw StateError('The post "$text" did not arrive.');
}

void main() {
  Future<(LedgerMesh, _Phone)> world() async {
    final LedgerMesh mesh = LedgerMesh()
      ..befriend('ada', 'bob')
      ..befriend('ada', 'cela');
    await mesh.add('ada');
    await mesh.add('bob');
    await mesh.add('cela');
    await mesh.settle();
    return (mesh, _Phone(mesh, 'ada'));
  }

  group('a friend\'s new post', () {
    test('is told of once: in the shade and in the in-app list', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      // The first round only learns what is there.
      expect(await notifier.check(), 0);

      final LogEntry post = await _post(
        mesh['bob'],
        'Hej, jestem w górach',
        reaches: mesh['ada'],
      );
      await mesh.settle();
      expect(await notifier.check(), 1);
      final RuntimeSystemNotification n = ada.shown.single;
      expect(n.id, '$kPostNoticeIdPrefix${post.id}');
      expect(n.slotKey, kPostNoticeSlot);
      expect(n.category, RuntimeSystemNotificationCategory.social);
      expect(n.title, 'Nowy post od Bob');
      expect(n.body, 'Hej, jestem w górach');
      expect(n.contentRedacted, isTrue);

      final InboxEntry entry = ada.inbox.single;
      expect(entry.type, InboxEntryType.post);
      expect(entry.title, 'Nowy post od Bob');
      expect(entry.body, 'Hej, jestem w górach');
      expect(entry.peerAddress, mesh.address('bob'));
      expect(entry.routeKey, n.routeKey);

      // Announced: nothing more, not even after a restart.
      expect(await notifier.check(), 0);
      expect(await ada.notifier().check(), 0);
      expect(ada.shown, hasLength(1));
      expect(ada.inbox, hasLength(1));
    });

    test('a tap opens the Tablica at that post', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();
      final LogEntry post = await _post(
        mesh['bob'],
        'Zobacz',
        reaches: mesh['ada'],
      );
      await mesh.settle();
      await notifier.check();
      for (final String? routeKey in <String?>[
        ada.shown.single.routeKey,
        ada.inbox.single.routeKey,
      ]) {
        final RuntimeRouteIntent intent = runtimeRouteIntentFromRouteKey(
          id: 'tap',
          routeKey: routeKey,
        )!;
        expect(intent.target, RuntimeRouteTarget.feed);
        expect(FeedFilter.parse(intent.rawInput), FeedFilter.all);
        expect(intent.postId, post.id);
      }
    });

    test('several posts make one notification, updated in place', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();

      await _post(mesh['bob'], 'Pierwszy', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 1);
      final String entryId = ada.inbox.single.id;

      final LogEntry second = await _post(
        mesh['cela'],
        'Drugi',
        reaches: mesh['ada'],
      );
      await _post(mesh['bob'], 'Trzeci', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 2);
      final RuntimeSystemNotification n = ada.shown.last;
      expect(n.slotKey, kPostNoticeSlot);
      expect(n.title, '3 nowe posty');
      expect(n.body, contains('Bob'));
      expect(n.body, contains('Cela'));
      expect(n.lines, hasLength(3));
      expect(n.lines, contains('Cela: Drugi'));
      expect(n.stackCount, 3);
      // One entry in the list too, the same one, now for all three.
      expect(ada.inbox, hasLength(1));
      expect(ada.inbox.single.id, entryId);
      expect(ada.inbox.single.title, '3 nowe posty');
      expect(ada.inbox.single.peerAddress, isNull);
      expect(second.id, isNotEmpty);
    });

    test('a look at the Tablica takes it all as seen and clears the '
        'notification', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();
      await _post(mesh['bob'], 'Raz', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 1);

      ada
        ..inFront = true
        ..onFeed = true;
      notifier.minute();
      await mesh.settle();
      expect(ada.dismissed, <String>[kPostNoticeSlot]);

      // A post written while the user looks is seen, not news.
      await _post(mesh['bob'], 'Dwa', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 0);

      ada
        ..inFront = false
        ..onFeed = false;
      await _post(mesh['bob'], 'Trzy', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 1);
      // A new round: only the one after the look.
      expect(ada.shown.last.title, 'Nowy post od Bob');
      expect(ada.shown.last.body, 'Trzy');
      expect(ada.inbox, hasLength(2));
    });

    test('in front of another screen it goes to the list only, and the '
        'shade later tells of everything since the last look', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();
      ada.inFront = true;
      await _post(mesh['bob'], 'Przy otwartej aplikacji', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 1);
      expect(ada.shown, isEmpty);
      expect(ada.inbox.single.title, 'Nowy post od Bob');

      ada.inFront = false;
      await _post(mesh['cela'], 'Po wyjściu', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 1);
      expect(ada.shown.single.title, '2 nowe posty');
    });
  });

  group('what is never told of', () {
    test('one\'s own posts, edits and reshares', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      final LogEntry old = await _post(
        mesh['bob'],
        'Stary',
        reaches: mesh['ada'],
      );
      await mesh.settle();
      await notifier.check();

      await _post(mesh['ada'], 'Mój własny');
      await mesh['bob'].publish(
        kPostEditKind,
        editPostBody(old.id, 'Stary, poprawiony'),
      );
      final LogEntry celas = await _post(
        mesh['cela'],
        'Od Celi',
        reaches: mesh['ada'],
      );
      await mesh.settle();
      expect(await notifier.check(), 1);
      ada.shown.clear();
      ada.inbox.clear();

      // Bob passes Cela's post on: it is not Bob's post.
      await mesh['bob'].publish(kReshareKind, reshareBody(celas));
      await mesh['bob'].publish(
        kPostEditKind,
        editPostBody(old.id, 'Stary, poprawiony drugi raz'),
      );
      await mesh.settle();
      expect(await notifier.check(), 0);
      expect(ada.shown, isEmpty);
      expect(ada.inbox, isEmpty);
    });

    test('posts of friends of friends', () async {
      final LedgerMesh mesh = LedgerMesh()
        ..chain(<String>['ada', 'bob', 'dan']);
      await mesh.add('ada');
      await mesh.add('bob');
      await mesh.add('dan');
      await mesh.settle();
      final _Phone ada = _Phone(mesh, 'ada');
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();

      final LogEntry post = await _post(mesh['dan'], 'Dwa kroki dalej');
      await mesh.settle();
      await mesh['bob'].publish(kReshareKind, reshareBody(post));
      await mesh.settle();
      expect(await notifier.check(), 0);
      expect(ada.shown, isEmpty);
      expect(ada.inbox, isEmpty);
    });

    test('posts older than the last look at the Tablica, or than a few '
        'days', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      // The Tablica was last looked at an hour from now.
      ada.clock = DateTime.now().millisecondsSinceEpoch + 3600 * 1000;
      await notifier.check();
      await _post(
        mesh['bob'],
        'Napisany przed tym spojrzeniem',
        reaches: mesh['ada'],
      );
      await mesh.settle();
      expect(await notifier.check(), 0);

      // A week on, nothing from back then is news either.
      final (LedgerMesh later, _Phone cela) = await world();
      final FriendPostNotifier other = cela.notifier();
      await other.check();
      await _post(later['bob'], 'Sprzed tygodnia', reaches: later['ada']);
      await later.settle();
      cela.clock = DateTime.now().millisecondsSinceEpoch + 7 * 86400 * 1000;
      expect(await other.check(), 0);
      expect(ada.shown, isEmpty);
      expect(cela.shown, isEmpty);
    });

    test('with the switch off, or the friend muted', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();

      ada.postsOn = false;
      await _post(mesh['bob'], 'Cisza', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 0);
      // Turned on again, what came meanwhile is not told of after all.
      ada.postsOn = true;
      expect(await notifier.check(), 0);

      ada.muted.add(mesh.address('bob'));
      await _post(mesh['bob'], 'Wyciszony', reaches: mesh['ada']);
      await _post(mesh['cela'], 'Nie wyciszona', reaches: mesh['ada']);
      await mesh.settle();
      expect(await notifier.check(), 1);
      expect(ada.shown.single.title, 'Nowy post od Cela');
      expect(ada.inbox.single.title, 'Nowy post od Cela');
    });
  });

  group('the privacy level', () {
    test('of the setting and of the friend\'s conversation', () async {
      final (LedgerMesh mesh, _Phone ada) = await world();
      final FriendPostNotifier notifier = ada.notifier();
      await notifier.check();

      ada.global = NotificationPrivacy.senderOnly;
      await _post(mesh['bob'], 'Tajemnica', reaches: mesh['ada']);
      await mesh.settle();
      await notifier.check();
      expect(ada.shown.last.title, 'Nowy post od Bob');
      expect(ada.shown.last.body, isNot(contains('Tajemnica')));

      ada
        ..global = NotificationPrivacy.senderAndContent
        ..own[mesh.address('bob')] = NotificationPrivacy.generic;
      await _post(mesh['bob'], 'Jeszcze jedna', reaches: mesh['ada']);
      await mesh.settle();
      await notifier.check();
      // Bob's own level holds for everything told together with him.
      expect(ada.shown.last.title, '2 nowe posty');
      expect(ada.shown.last.body, isNot(contains('Bob')));
      expect(ada.shown.last.lines, isEmpty);
      // The in-app list is behind the app's lock: it tells who and what.
      expect(ada.inbox.single.body, contains('Bob'));
    });

    test('what each level says', () {
      const NewPostNotice bob = NewPostNotice(
        postId: 'p2',
        author: 'Bob',
        address: 'b',
        preview: 'Hej',
        millis: 2,
      );
      const NewPostNotice cela = NewPostNotice(
        postId: 'p1',
        author: 'Cela',
        address: 'c',
        preview: '',
        millis: 1,
      );
      RuntimeSystemNotification of(
        List<NewPostNotice> posts,
        NotificationPrivacy level,
      ) => newPostsNotification(posts, level: level, createdAtMillis: 0);

      final RuntimeSystemNotification full = of(<NewPostNotice>[
        bob,
      ], NotificationPrivacy.senderAndContent);
      expect((full.title, full.body), ('Nowy post od Bob', 'Hej'));
      final RuntimeSystemNotification sender = of(<NewPostNotice>[
        bob,
      ], NotificationPrivacy.senderOnly);
      expect(sender.title, 'Nowy post od Bob');
      expect(sender.body, isNot(contains('Hej')));
      final RuntimeSystemNotification generic = of(<NewPostNotice>[
        bob,
      ], NotificationPrivacy.generic);
      expect(generic.title, 'Nowy post');
      expect(generic.body, isNot(contains('Bob')));

      final RuntimeSystemNotification two = of(<NewPostNotice>[
        bob,
        cela,
      ], NotificationPrivacy.senderAndContent);
      expect(two.title, '2 nowe posty');
      expect(two.body, 'Od: Bob, Cela');
      expect(two.lines, <String>['Bob: Hej', 'Cela']);
      expect(two.routeKey, buildFeedRouteKey('all', postId: 'p2'));

      // Already in its final form: the central redaction leaves it be.
      final PrivacyRedactingNotificationService service =
          PrivacyRedactingNotificationService(
            MemoryRuntimeSystemNotificationService(),
            privacy: () => NotificationPrivacy.senderOnly,
          );
      final RuntimeSystemNotification passed = service.redact(
        of(<NewPostNotice>[bob], NotificationPrivacy.senderOnly),
      );
      expect(passed.title, 'Nowy post od Bob');
      expect(PrivacyRedactingNotificationService.hidesTitle(passed), isFalse);
    });

    test('a post with only a photo is told of by its label', () {
      final FeedPost photo = FeedPost(
        id: 'p',
        account: 'a',
        authorLabel: 'Bob',
        text: '',
        millis: 0,
        isOwn: false,
        images: <MediaRef>[
          MediaRef(
            id: 'x',
            key: Uint8List(32),
            nonce: Uint8List(12),
            mime: 'image/jpeg',
          ),
        ],
      );
      expect(postNoticePreview(photo), '📷 Zdjęcie');
    });
  });

  test('the switches are kept in the settings', () {
    final AppSettings settings = const AppSettings().copyWith(
      postNotifications: false,
      mutedPostAuthors: <String>{PeerShareCodec.normalizeAddress('200::1')},
    );
    final AppSettings back = AppSettings.fromJson(settings.toJson());
    expect(back.postNotifications, isFalse);
    expect(back.mutedPostAuthors, <String>{
      PeerShareCodec.normalizeAddress('200::1'),
    });
    expect(const AppSettings().postNotifications, isTrue);
    expect(const AppSettings().announcesPostsOf('200::2'), isTrue);
    expect(
      const AppSettings()
          .copyWith(mutedPostAuthors: <String>{'200::1'})
          .announcesPostsOf('200::1'),
      isFalse,
    );
  });
}
