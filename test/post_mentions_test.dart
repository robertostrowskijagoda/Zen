import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_mentions.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

import 'support/ledger_mesh.dart';

// Mentions in posts and comments: who the writer is offered, the notice
// the mentioned person gets (also from beyond friends), what they check
// before saying anything, and how much a notification tells.

const List<String> _names = <String>['ada', 'bob', 'cela', 'dan'];

/// One phone's mention service and what it told of.
final class _Phone {
  _Phone(this.mesh, this.name, {this.listed = const <String, String>{}});

  final LedgerMesh mesh;
  final String name;

  /// Address → name on the friend lists friends share with this phone.
  final Map<String, String> listed;
  final List<RuntimeSystemNotification> shown = <RuntimeSystemNotification>[];
  final List<InboxEntry> inbox = <InboxEntry>[];
  bool inFront = false;
  NotificationPrivacy global = NotificationPrivacy.senderAndContent;
  final Map<String, NotificationPrivacy> own = <String, NotificationPrivacy>{};
  late final PostMentionService service = _service();

  LedgerNode get node => mesh[name];

  String nameOf(String address) {
    for (final String n in _names) {
      if (mesh.address(n) == address && node.isFriendAddress(address)) {
        return '${n[0].toUpperCase()}${n.substring(1)}';
      }
    }
    return '';
  }

  PostMentionService _service() {
    final PostMentionService s = PostMentionService(
      node: node,
      nameOf: nameOf,
      notify: (RuntimeSystemNotification n) async => shown.add(n),
      addToInbox: (InboxEntry e) async => inbox.add(e),
      shouldNotify: () => !inFront,
      privacyOf: (String address) => own[address] ?? global,
      privacy: () => global,
      friendOfFriend: (String address) => listed[address],
    )..start();
    addTearDown(s.dispose);
    return s;
  }
}

Mention _of(LedgerMesh mesh, String name) => Mention(
  address: mesh.address(name),
  account: mesh[name].account,
  name: '${name[0].toUpperCase()}${name.substring(1)}',
);

void main() {
  /// ada–bob–cela–dan: cela is a friend of ada's friend, dan is further.
  Future<LedgerMesh> world() async {
    final LedgerMesh mesh = LedgerMesh()
      ..chain(<String>['ada', 'bob', 'cela', 'dan']);
    for (final String n in _names) {
      await mesh.add(n, knowsOwnAddress: true);
    }
    await mesh.settle();
    return mesh;
  }

  Future<void> idle(List<_Phone> phones, LedgerMesh mesh) async {
    for (int i = 0; i < 3; i++) {
      await mesh.settle();
      for (final _Phone p in phones) {
        await p.service.idle;
      }
    }
  }

  group('who the writer is offered', () {
    test('a new public post: friends and the friends on their lists', () async {
      final LedgerMesh mesh = await world();
      final List<MentionCandidate> offered = postMentionCandidates(
        mesh['ada'],
        nameOf: (String a) => a == mesh.address('bob') ? 'Bob' : '',
        friendLists: <String, Map<String, String>>{
          mesh.address('bob'): <String, String>{
            mesh.address('cela'): 'Cela',
            // This phone itself is on its friend's list: never offered.
            mesh.address('ada'): 'Ada',
          },
        },
      );
      expect(
        <String, MentionReach>{
          for (final MentionCandidate c in offered) c.mention.name: c.reach,
        },
        <String, MentionReach>{
          'Bob': MentionReach.friend,
          'Cela': MentionReach.friendOfFriend,
        },
      );
    });

    test('under a post: its author and who reacted come first', () async {
      final LedgerMesh mesh = await world();
      final FeedPost post = FeedPost(
        id: 'p',
        account: mesh['cela'].account,
        authorLabel: 'Cela (znajomy znajomego)',
        authorAddress: mesh.address('cela'),
        text: 'Hej',
        millis: 1,
        isOwn: false,
        comments: <FeedComment>[
          FeedComment(
            id: 'c',
            authorLabel: 'Dan (przez Bob)',
            text: 'Też tu jestem',
            millis: 2,
            account: mesh['dan'].account,
            authorAddress: mesh.address('dan'),
          ),
        ],
        likes: <FeedLiker>[
          // Someone known only by name: no address, never offered.
          const FeedLiker(account: 'acc-eve', name: 'Ewa'),
        ],
      );
      final List<MentionCandidate> offered = postMentionCandidates(
        mesh['ada'],
        post: post,
        nameOf: (String a) => a == mesh.address('bob') ? 'Bob' : '',
      );
      expect(
        offered.map((MentionCandidate c) => (c.mention.name, c.reach)),
        <(String, MentionReach)>[
          ('Cela', MentionReach.author),
          ('Dan', MentionReach.interacted),
          ('Bob', MentionReach.friend),
        ],
      );
    });

    test('a post for an audience offers only those who can read it', () async {
      final LedgerMesh mesh = await world();
      await mesh['ada'].setLevel(mesh.address('bob'), FriendLevel.weak);
      final Map<String, Map<String, String>> lists =
          <String, Map<String, String>>{
            mesh.address('bob'): <String, String>{mesh.address('cela'): 'Cela'},
          };
      String nameOf(String a) => a == mesh.address('bob') ? 'Bob' : '';
      // "Znajomi i przyjaciele": Bob is only "Słaby znajomy".
      expect(
        postMentionCandidates(
          mesh['ada'],
          audience: Audience.mid,
          nameOf: nameOf,
          friendLists: lists,
        ),
        isEmpty,
      );
      expect(
        postMentionCandidates(
          mesh['ada'],
          audience: Audience.all,
          nameOf: nameOf,
          friendLists: lists,
        ).map((MentionCandidate c) => c.mention.name),
        <String>['Bob'],
      );
      // At publishing, a name nobody of the audience is turns plain.
      final ({String text, List<Mention> mentions}) kept = mentionsForAudience(
        mesh['ada'],
        '<@0> i <@1>',
        <Mention>[_of(mesh, 'bob'), _of(mesh, 'cela')],
        Audience.all,
      );
      expect(kept.text, '<@0> i @Cela');
      expect(kept.mentions.single.name, 'Bob');
    });
  });

  group('the mentioned person', () {
    test('a friend of a friend learns of a mention once, with a route to the '
        'post', () async {
      final LedgerMesh mesh = await world();
      final _Phone ada = _Phone(mesh, 'ada');
      final _Phone cela = _Phone(
        mesh,
        'cela',
        listed: <String, String>{mesh.address('ada'): 'Ada'},
      );
      ada.service.start();
      cela.service.start();
      final LogEntry post = await mesh['ada'].publish(
        kPostKind,
        newPostBody(
          'Pozdrowienia dla <@0>!',
          // A friend of a friend: only the address from the list is known.
          mentions: <Mention>[
            Mention(address: mesh.address('cela'), name: 'Cela'),
          ],
        ),
      );
      await idle(<_Phone>[ada, cela], mesh);
      expect(mesh.sent['ada']?[kMentionNoticeType], 1);
      final InboxEntry entry = cela.inbox.single;
      expect(entry.type, InboxEntryType.mention);
      expect(entry.title, 'Ada wspomniał(a) o Tobie');
      expect(entry.body, 'Pozdrowienia dla @Cela!');
      final RuntimeRouteIntent? route = runtimeRouteIntentFromRouteKey(
        id: entry.id,
        routeKey: entry.routeKey,
      );
      expect(route?.target, RuntimeRouteTarget.feed);
      expect(route?.postId, post.id);
      expect(route?.rawInput, FeedFilter.all.name);
      final RuntimeSystemNotification n = cela.shown.single;
      expect(n.title, 'Ada wspomniał(a) o Tobie');
      expect(n.body, 'Pozdrowienia dla @Cela!');
      expect(n.contentRedacted, isTrue);
      expect(n.routeKey, entry.routeKey);

      // The same notice again (a retry, a mailbox): nothing more.
      final Map<String, dynamic>? frame = mentionNoticeFrame(mesh['ada'], post);
      expect(
        await cela.service.handleNotice(
          SignalTransportFrame(
            from: mesh.address('ada'),
            payload: frame!,
            receivedAtMillis: 0,
          ),
        ),
        isFalse,
      );
      expect(cela.inbox, hasLength(1));
      expect(cela.shown, hasLength(1));
    });

    test(
      'someone further away is refused, until one reacted to that post',
      () async {
        final LedgerMesh mesh = await world();
        final _Phone dan = _Phone(mesh, 'dan');
        final _Phone ada = _Phone(mesh, 'ada');
        dan.service.start();
        ada.service.start();
        final LogEntry post = await mesh['dan'].publish(
          kPostKind,
          newPostBody('Hej <@0>', mentions: <Mention>[_of(mesh, 'ada')]),
        );
        await idle(<_Phone>[ada, dan], mesh);
        expect(mesh.sent['dan']?[kMentionNoticeType], 1);
        expect(ada.inbox, isEmpty);
        expect(ada.shown, isEmpty);

        // Ada comments on Dan's post: from now on he may mention her there.
        await publishComment(mesh['ada'], post.id, 'Cześć');
        final SignalTransportFrame again = SignalTransportFrame(
          from: mesh.address('dan'),
          payload: mentionNoticeFrame(mesh['dan'], post)!,
          receivedAtMillis: 0,
        );
        expect(await ada.service.handleNotice(again), isTrue);
        expect(ada.inbox.single.title, 'Ktoś wspomniał(a) o Tobie');
        expect(ada.shown, hasLength(1));
      },
    );

    test('a forged or wrong notice tells nothing', () async {
      final LedgerMesh mesh = await world();
      final _Phone ada = _Phone(mesh, 'ada');
      ada.service.start();
      // Bob's post names Cela, not Ada.
      final LogEntry other = await mesh['bob'].publish(
        kPostKind,
        newPostBody('Hej <@0>', mentions: <Mention>[_of(mesh, 'cela')]),
      );
      // A comment on a post nobody has, and a changed signature.
      final LogEntry nowhere = await mesh['bob'].publish(
        kCommentKind,
        commentBody('f' * 64, '<@0>?', mentions: <Mention>[_of(mesh, 'ada')]),
        spaceKind: 'acts',
      );
      final Map<String, dynamic> forged = mentionNoticeFrame(
        mesh['bob'],
        other,
      )!;
      (forged['e'] as Map<String, dynamic>)['body'] = <String, dynamic>{
        ...other.body,
        kMentionsKey: <Object?>[_of(mesh, 'ada').toJson()],
      };
      for (final Map<String, dynamic> payload in <Map<String, dynamic>>[
        mentionNoticeFrame(mesh['bob'], other)!,
        mentionNoticeFrame(mesh['bob'], nowhere)!,
        forged,
        <String, dynamic>{'type': kMentionNoticeType, 'e': 'x'},
      ]) {
        expect(
          await ada.service.handleNotice(
            SignalTransportFrame(
              from: mesh.address('bob'),
              payload: payload,
              receivedAtMillis: 0,
            ),
          ),
          isFalse,
        );
      }
      expect(ada.inbox, isEmpty);
    });

    test('a comment under one\'s own post counts, within a writer\'s hourly '
        'limit', () async {
      final LedgerMesh mesh = await world();
      final _Phone ada = _Phone(mesh, 'ada');
      ada.service.start();
      final LogEntry post = await mesh['ada'].publish(
        kPostKind,
        newPostBody('Mój post'),
      );
      int told = 0;
      for (int i = 0; i < kMentionNoticesPerSenderHour + 3; i++) {
        // Dan is no friend: the post is Ada's, so he may mention her.
        final LogEntry comment = await mesh['dan'].publish(
          kCommentKind,
          commentBody(
            post.id,
            '<@0> $i',
            mentions: <Mention>[_of(mesh, 'ada')],
          ),
          spaceKind: 'acts',
        );
        if (await ada.service.handleNotice(
          SignalTransportFrame(
            from: mesh.address('dan'),
            payload: mentionNoticeFrame(mesh['dan'], comment)!,
            receivedAtMillis: 0,
          ),
        )) {
          told++;
        }
      }
      expect(told, kMentionNoticesPerSenderHour);
      expect(ada.inbox, hasLength(kMentionNoticesPerSenderHour));
      expect(ada.inbox.first.body, '@Ada 0');
    });

    test('a friend\'s mention comes once although it also arrives by sync; the '
        'notification follows the privacy level', () async {
      final LedgerMesh mesh = await world();
      final _Phone ada = _Phone(mesh, 'ada')
        ..own[mesh.address('bob')] = NotificationPrivacy.senderOnly;
      final _Phone bob = _Phone(mesh, 'bob');
      ada.service.start();
      bob.service.start();
      await mesh['bob'].publish(
        kPostKind,
        newPostBody('Tajne <@0>', mentions: <Mention>[_of(mesh, 'ada')]),
      );
      await idle(<_Phone>[ada, bob], mesh);
      expect(ada.inbox, hasLength(1));
      expect(ada.inbox.single.title, 'Bob wspomniał(a) o Tobie');
      expect(ada.inbox.single.peerAddress, mesh.address('bob'));
      final RuntimeSystemNotification n = ada.shown.single;
      expect(n.title, 'Bob wspomniał(a) o Tobie');
      expect(n.body, isNot(contains('Tajne')));

      // "Tylko informacja": nobody named.
      ada.own[mesh.address('bob')] = NotificationPrivacy.generic;
      await mesh['bob'].publish(
        kPostKind,
        newPostBody('Znowu <@0>', mentions: <Mention>[_of(mesh, 'ada')]),
      );
      await idle(<_Phone>[ada, bob], mesh);
      expect(ada.shown, hasLength(2));
      expect(ada.shown.last.title, 'Ktoś wspomniał o Tobie');
      expect(
        '${ada.shown.last.title} ${ada.shown.last.body}',
        isNot(contains('Bob')),
      );

      // With the app in front: only the in-app list.
      ada.inFront = true;
      await mesh['bob'].publish(
        kPostKind,
        newPostBody('I jeszcze <@0>', mentions: <Mention>[_of(mesh, 'ada')]),
      );
      await idle(<_Phone>[ada, bob], mesh);
      expect(ada.inbox, hasLength(3));
      expect(ada.shown, hasLength(2));
    });

    test('an edit tells only the people it adds', () async {
      final LedgerMesh mesh = await world();
      final _Phone ada = _Phone(mesh, 'ada');
      final _Phone bob = _Phone(mesh, 'bob');
      ada.service.start();
      bob.service.start();
      final LogEntry post = await mesh['ada'].publish(
        kPostKind,
        newPostBody('Hej <@0>', mentions: <Mention>[_of(mesh, 'bob')]),
      );
      await idle(<_Phone>[ada, bob], mesh);
      expect(mesh.sent['ada']?[kMentionNoticeType], 1);
      expect(bob.inbox, hasLength(1));
      await mesh['ada'].publish(
        kPostEditKind,
        editPostBody(
          post.id,
          'Hej <@0> i <@1>',
          mentions: <Mention>[_of(mesh, 'bob'), _of(mesh, 'cela')],
        ),
      );
      await idle(<_Phone>[ada, bob], mesh);
      // Only Cela is new.
      expect(mesh.sent['ada']?[kMentionNoticeType], 2);
      expect(bob.inbox, hasLength(1));
    });
  });
}
