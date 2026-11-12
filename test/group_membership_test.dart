import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/ledger/contacts_backup.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/notification_privacy.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

import 'support/friends_world.dart';

// Who is in a group must end up the same on every member's phone, whatever
// order leaving and adding reach them in: a list a step behind (its sender
// was offline when someone left) never brings a member who left back, and
// one addition is never lost because the adder's list was behind.

final String ada = PeerShareCodec.normalizeAddress('200::ada');
final String bob = PeerShareCodec.normalizeAddress('200::b0b');
final String cyd = PeerShareCodec.normalizeAddress('200::c0d');
final String dan = PeerShareCodec.normalizeAddress('200::d0d');
final String eve = PeerShareCodec.normalizeAddress('200::e0e');
final String fay = PeerShareCodec.normalizeAddress('200::f0f');

const String _gid = 'g';

FriendProfile _friend(String address) => FriendProfile(
  address: address,
  displayName: address,
  status: FriendRelationshipStatus.accepted,
);

/// This phone's view: a group Ada made, with Bob, Cyd and Dan in it.
GroupProfile _joined({
  Map<String, int> departedAt = const <String, int>{},
  String awaitingMembersFrom = '',
  List<String>? members,
}) => GroupProfile(
  id: _gid,
  name: 'Ekipa',
  createdById: ada,
  createdAtMillis: 1,
  memberAddresses: members ?? <String>[ada, bob, cyd, dan],
  departedAt: departedAt,
  awaitingMembersFrom: awaitingMembersFrom,
);

final class _Phone {
  _Phone({
    GroupProfile? group,
    List<String> rejectedGroupIds = const <String>[],
    SocialSnapshotStore? snapshots,
  }) {
    container = ProviderContainer(
      overrides: [
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: const AppSettings(),
          hydrationEnabled: false,
        ),
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(
          snapshots ?? MemorySocialSnapshotStore(),
        ),
        messageTimelineStoreProvider.overrideWithValue(
          MemoryMessageTimelineStore(),
        ),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          MemoryRuntimeSystemNotificationService(),
        ),
        socialHubAutoHydrateProvider.overrideWithValue(false),
        socialHubSeedProvider.overrideWithValue(
          SocialHubState.empty(
            lifecycle: const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 1,
              capturedAtMillis: 0,
            ),
          ).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                for (final String a in <String>[ada, bob, cyd, dan, eve, fay])
                  a: _friend(a),
              },
            ),
            groups: <String, GroupProfile>{_gid: ?group},
            rejectedGroupIds: rejectedGroupIds,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  final MemorySignalTransport transport = MemorySignalTransport();
  late final ProviderContainer container;

  SocialHubController get hub =>
      container.read(socialHubControllerProvider.notifier);

  GroupProfile get group =>
      container.read(socialHubControllerProvider).groups[_gid]!;

  Set<String> get members => group.memberAddresses.toSet();

  List<Map<String, dynamic>> sentTo(String address, String type) =>
      <Map<String, dynamic>>[
        for (final s in transport.sentSignals)
          if (PeerShareCodec.addressesEqual(s.remoteAddress, address) &&
              s.payload['type'] == type)
            s.payload,
      ];

  Future<void> deliver(
    String from,
    Map<String, dynamic> payload, {
    int at = 10000,
  }) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    expect(signal, isNotNull, reason: 'payload must parse: $payload');
    await hub.receiveSignal(signal!, receivedAtMillis: at);
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> _leave({int? at}) => <String, dynamic>{
  'type': 'group_leave',
  'groupId': _gid,
  'at': ?at,
};

/// A member-list update: a whole list as a Zen before 1.16.5 sends it, or
/// one naming the person it adds ([added], stamped [at]).
Map<String, dynamic> _members(
  List<String> members, {
  String? added,
  int? at,
  Map<String, int>? left,
}) => <String, dynamic>{
  'type': 'group_invite',
  'groupId': _gid,
  'groupName': 'Ekipa',
  'memberAddresses': members,
  'added': ?added,
  'at': ?at,
  'left': ?left,
};

/// Every order of [items].
List<List<T>> _orders<T>(List<T> items) {
  if (items.length <= 1) {
    return <List<T>>[items];
  }
  return <List<T>>[
    for (int i = 0; i < items.length; i++)
      for (final List<T> rest in _orders(<T>[
        ...items.sublist(0, i),
        ...items.sublist(i + 1),
      ]))
        <T>[items[i], ...rest],
  ];
}

bool _has(FriendsPhone p, String groupId, FriendsPhone member) {
  final GroupProfile? g = p.state.groups[groupId];
  return g != null &&
      g.memberAddresses.any(
        (String m) => PeerShareCodec.addressesEqual(m, member.address),
      );
}

Set<String> _listOf(FriendsPhone p, String groupId) => <String>{
  for (final String m in p.state.groups[groupId]!.memberAddresses)
    PeerShareCodec.normalizeAddress(m),
};

void main() {
  group('between phones', () {
    test('a member who left does not come back when the creator, offline '
        'at the time, adds someone', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
        'E',
      ]);
      final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
        w['B'],
        w['C'],
        w['D'],
      ]);
      await w.deliver();

      await w.setOnline(w['A'], false);
      await w['D'].hub.leaveGroup(groupId: id);
      await w.deliver();
      expect(_has(w['B'], id, w['D']), isFalse);
      expect(_has(w['C'], id, w['D']), isFalse);

      // Still offline, its list still has D: the creator adds E.
      await w['A'].hub.addMemberToGroup(
        groupId: id,
        memberAddress: w['E'].address,
      );
      await w.setOnline(w['A'], true);
      await w.advance(const Duration(minutes: 3));

      for (final String n in <String>['A', 'B', 'C']) {
        expect(_has(w[n], id, w['D']), isFalse, reason: '$n: D left');
        expect(_has(w[n], id, w['E']), isTrue, reason: '$n: E was added');
      }
      expect(_listOf(w['B'], id), _listOf(w['A'], id));
      expect(_listOf(w['C'], id), _listOf(w['A'], id));
    });

    test('an ordinary member a leave behind adds someone: everyone takes '
        'the newcomer, and the newcomer\'s messages arrive', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
        'E',
      ]);
      final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
        w['B'],
        w['C'],
        w['D'],
      ]);
      await w.deliver();

      await w.setOnline(w['B'], false);
      await w['D'].hub.leaveGroup(groupId: id);
      await w.deliver();
      expect(_has(w['C'], id, w['D']), isFalse);

      await w['B'].hub.addMemberToGroup(
        groupId: id,
        memberAddress: w['E'].address,
      );
      await w.setOnline(w['B'], true);
      await w.advance(const Duration(minutes: 3));
      expect(w['E'].state.groups[id], isNotNull, reason: 'E got invited');
      await w['E'].hub.acceptGroupInvite(
        groupId: id,
        groupName: 'Ekipa',
        senderAddress: w['B'].address,
      );
      await w.advance(const Duration(minutes: 2));
      await w.sendGroup(w['E'], id, 'hej, tu E');
      await w.advance(const Duration(minutes: 2));

      expect(_has(w['C'], id, w['E']), isTrue, reason: 'C knows E is in');
      expect(_has(w['A'], id, w['E']), isTrue, reason: 'A knows E is in');
      expect(await w.groupTexts(w['C'], id), contains('hej, tu E'));
      expect(await w.groupTexts(w['A'], id), contains('hej, tu E'));
      // One list on every phone, the newcomer's too: without D.
      for (final String n in <String>['A', 'B', 'C', 'E']) {
        expect(_has(w[n], id, w['D']), isFalse, reason: '$n: D left');
        expect(_listOf(w[n], id), _listOf(w['A'], id), reason: n);
      }
    });

    test('someone who left and is invited again is a member again '
        'everywhere', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'D',
      ]);
      final String id = await w.createGroup(w['A'], 'Ekipa', <FriendsPhone>[
        w['B'],
        w['C'],
        w['D'],
      ]);
      await w.deliver();
      await w['D'].hub.leaveGroup(groupId: id);
      await w.deliver();
      expect(_has(w['A'], id, w['D']), isFalse);

      await w['C'].hub.addMemberToGroup(
        groupId: id,
        memberAddress: w['D'].address,
      );
      await w.advance(const Duration(minutes: 1));
      await w['D'].hub.acceptGroupInvite(
        groupId: id,
        groupName: 'Ekipa',
        senderAddress: w['C'].address,
      );
      await w.advance(const Duration(minutes: 2));
      await w.sendGroup(w['D'], id, 'znowu jestem');
      await w.advance(const Duration(minutes: 1));

      for (final String n in <String>['A', 'B', 'C']) {
        expect(_has(w[n], id, w['D']), isTrue, reason: '$n: D is back');
        expect(await w.groupTexts(w[n], id), contains('znowu jestem'));
      }
      expect(_listOf(w['D'], id), _listOf(w['A'], id));
    });

    test(
      'two members adding someone at about the same time: the two '
      'newcomers learn of each other and see each other\'s messages',
      () async {
        final FriendsWorld w = await FriendsWorld.create(<String>[
          'A',
          'B',
          'C',
          'D',
          'E',
        ]);
        final FriendsPhone a = w['A'];
        final FriendsPhone c = w['C'];
        final FriendsPhone d = w['D'];
        final FriendsPhone e = w['E'];
        final String id = await w.createGroup(a, 'Ekipa', <FriendsPhone>[
          w['B'],
          c,
        ]);
        await w.deliver();
        // C is on a train without network; A adds D, who joins at once.
        w.partition(<FriendsPhone>[c], <FriendsPhone>[a, w['B'], d, e]);
        await a.hub.addMemberToGroup(groupId: id, memberAddress: d.address);
        await w.deliver();
        await d.hub.acceptGroupInvite(
          groupId: id,
          groupName: 'Ekipa',
          senderAddress: a.address,
        );
        await w.deliver();
        // Meanwhile C, on the train, adds E.
        await c.hub.addMemberToGroup(groupId: id, memberAddress: e.address);
        w.heal();
        await w.advance(const Duration(minutes: 3));
        await e.hub.acceptGroupInvite(
          groupId: id,
          groupName: 'Ekipa',
          senderAddress: c.address,
        );
        await w.advance(const Duration(minutes: 3));
        await w.sendGroup(d, id, 'od D');
        await w.sendGroup(e, id, 'od E');
        await w.advance(
          const Duration(hours: 6),
          step: const Duration(minutes: 5),
        );
        expect(await w.groupTexts(d, id), contains('od E'));
        expect(await w.groupTexts(e, id), contains('od D'));
        for (final String n in <String>['A', 'B', 'C', 'D', 'E']) {
          expect(_has(w[n], id, d), isTrue, reason: '$n knows D');
          expect(_has(w[n], id, e), isTrue, reason: '$n knows E');
          expect(_listOf(w[n], id), _listOf(a, id), reason: n);
        }
      },
    );

    test('a newcomer whose members\' list is still on its way puts off a '
        'third member\'s message instead of dropping it', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'E',
      ]);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      final FriendsPhone e = w['E'];
      final String id = await w.createGroup(a, 'Ekipa', <FriendsPhone>[
        b,
        w['C'],
      ]);
      await a.hub.addMemberToGroup(groupId: id, memberAddress: e.address);
      await w.deliver();
      // The inviter goes off just as E joins: its list comes later.
      await w.setOnline(a, false);
      await e.hub.acceptGroupInvite(
        groupId: id,
        groupName: 'Ekipa',
        senderAddress: a.address,
      );
      await w.deliver();
      expect(_has(e, id, b), isFalse);
      await w.sendGroup(b, id, 'Witaj E');
      await w.deliver();
      expect(await w.groupTexts(e, id), isNot(contains('Witaj E')));
      await w.setOnline(a, true);
      await w.until(
        () async => (await w.groupTexts(e, id)).contains('Witaj E'),
        within: const Duration(hours: 1),
        reason: "B's message reaching E once its list came",
      );
      expect(_has(e, id, b), isTrue);
    });

    test('someone who left is not brought back by a member a leave behind '
        'passing on what it knows', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'M',
        'N',
      ]);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      final FriendsPhone m = w['M'];
      final FriendsPhone n = w['N'];
      final String id = await w.createGroup(a, 'Ekipa', <FriendsPhone>[
        b,
        w['C'],
      ]);
      // A adds M, who joins; then M leaves while B has no network.
      await a.hub.addMemberToGroup(groupId: id, memberAddress: m.address);
      await w.deliver();
      await m.hub.acceptGroupInvite(
        groupId: id,
        groupName: 'Ekipa',
        senderAddress: a.address,
      );
      await w.deliver();
      expect(_has(b, id, m), isTrue);
      w.partition(<FriendsPhone>[b], <FriendsPhone>[a, w['C'], m, n]);
      await m.hub.leaveGroup(groupId: id);
      await w.deliver();
      // A adds N, who joins; B, back, still counts M a member for a while.
      await a.hub.addMemberToGroup(groupId: id, memberAddress: n.address);
      await w.deliver();
      await n.hub.acceptGroupInvite(
        groupId: id,
        groupName: 'Ekipa',
        senderAddress: a.address,
      );
      await w.deliver();
      w.heal();
      await w.advance(const Duration(minutes: 30));
      for (final String p in <String>['A', 'B', 'C', 'N']) {
        expect(_has(w[p], id, m), isFalse, reason: '$p: M left');
        expect(_has(w[p], id, n), isTrue, reason: '$p: N was added');
      }
      expect(m.state.groups[id], isNull);
    });
  });

  group('two members adding at about the same time', () {
    // This phone (a member) took Eve, added by Bob a moment ago.
    GroupProfile withEve() => _joined().copyWith(
      memberAddresses: <String>[ada, bob, cyd, dan, eve],
      addedAt: <String, int>{eve: DateTime.now().millisecondsSinceEpoch - 1000},
    );

    test('a member that knows of an addition the adder did not tells the '
        'newcomer of it, and the one added of the newcomer', () async {
      final _Phone p = _Phone(group: withEve());
      final int at = DateTime.now().millisecondsSinceEpoch;
      await p.deliver(cyd, _members(<String>[cyd, fay], added: fay, at: at));
      expect(p.members, contains(fay));
      final Map<String, dynamic> toFay = p.sentTo(fay, 'group_invite').single;
      expect(toFay['memberAddresses'], contains(eve));
      expect((toFay[kGroupAddsKey] as Map<String, int>).keys, <String>[eve]);
      expect(toFay.containsKey('inviteId'), isFalse);
      final Map<String, dynamic> toEve = p.sentTo(eve, 'group_invite').single;
      expect(toEve['added'], fay);
      expect(toEve['at'], at);
    });

    test('nothing is passed on when the adder knew of it', () async {
      final _Phone p = _Phone(group: withEve());
      final int at = DateTime.now().millisecondsSinceEpoch;
      await p.deliver(cyd, <String, dynamic>{
        ..._members(<String>[cyd, fay], added: fay, at: at),
        kGroupAddsKey: <String, int>{eve: withEve().addedAt[eve]!},
      });
      expect(p.members, contains(fay));
      expect(p.sentTo(fay, 'group_invite'), isEmpty);
      expect(p.sentTo(eve, 'group_invite'), isEmpty);
    });

    test('a newcomer takes the additions a member tells of, but not over a '
        'later leave, and nothing from someone outside the group', () async {
      final int now = DateTime.now().millisecondsSinceEpoch;
      final _Phone p = _Phone(
        group: _joined(departedAt: <String, int>{fay: now - 1000}),
      );
      await p.deliver(bob, <String, dynamic>{
        ..._members(<String>[bob, eve, fay]),
        kGroupAddsKey: <String, int>{eve: now - 500, fay: now - 2000},
      });
      expect(p.members, <String>{ada, bob, cyd, dan, eve});
      expect(p.group.addedAt[eve], now - 500);
      // An addition made after the leave brings them back.
      await p.deliver(bob, <String, dynamic>{
        ..._members(<String>[bob, fay]),
        kGroupAddsKey: <String, int>{fay: now},
      });
      expect(p.members, contains(fay));
      // Someone outside the group adds nobody.
      final _Phone q = _Phone(group: _joined());
      const String stranger = '200::5a';
      await q.deliver(stranger, <String, dynamic>{
        ..._members(<String>[stranger, eve]),
        kGroupAddsKey: <String, int>{eve: now},
      });
      expect(q.members, <String>{ada, bob, cyd, dan});
    });
  });

  group('clocks that run ahead', () {
    test('a leaver whose clock ran ahead can be added again at once: the '
        'addition is stamped after the leave', () async {
      final int ahead = DateTime.now().millisecondsSinceEpoch + 50 * 60000;
      final _Phone adder = _Phone(group: _joined());
      final _Phone other = _Phone(group: _joined());
      for (final _Phone p in <_Phone>[adder, other]) {
        await p.deliver(dan, _leave(at: ahead));
        expect(p.members, isNot(contains(dan)));
      }
      await adder.hub.addMemberToGroup(groupId: _gid, memberAddress: dan);
      final Map<String, dynamic> update = adder
          .sentTo(bob, 'group_invite')
          .single;
      expect(update['at'] as int, greaterThan(ahead));
      await other.deliver(cyd, update);
      expect(other.members, contains(dan));
    });

    test('someone added by a member whose clock ran ahead leaves after that '
        'addition on every phone', () async {
      final FriendsWorld w = await FriendsWorld.create(<String>[
        'A',
        'B',
        'C',
        'E',
      ]);
      final FriendsPhone a = w['A'];
      final FriendsPhone b = w['B'];
      final FriendsPhone e = w['E'];
      final String id = await w.createGroup(a, 'Ekipa', <FriendsPhone>[
        b,
        w['C'],
      ]);
      await b.hub.addMemberToGroup(groupId: id, memberAddress: e.address);
      await w.deliver();
      await e.hub.acceptGroupInvite(
        groupId: id,
        groupName: 'Ekipa',
        senderAddress: b.address,
      );
      await w.deliver();
      // B's clock ran 50 minutes ahead when it added E: what A and E were
      // told says so.
      final int ahead = DateTime.now().millisecondsSinceEpoch + 50 * 60000;
      Future<void> told(FriendsPhone p, Map<String, dynamic> payload) async {
        await p.hub.receiveSignal(
          zenSignalFromTransportPayload(sender: b.address, payload: payload)!,
          receivedAtMillis: w.now,
        );
      }

      await told(a, <String, dynamic>{
        ..._members(<String>[b.address, e.address]),
        'groupId': id,
        'added': e.address,
        'at': ahead,
      });
      await told(e, <String, dynamic>{
        ..._members(<String>[b.address, e.address]),
        'groupId': id,
        kGroupAddsKey: <String, int>{e.address: ahead},
      });
      expect(a.state.groups[id]!.addedAt[e.address], ahead);
      await e.hub.leaveGroup(groupId: id);
      await w.deliver();
      expect(_has(a, id, e), isFalse, reason: 'the leave is after the add');
    });
  });

  group('a creator who left and is added again', () {
    test('is a member like any other: a list of theirs brings in at most '
        'one newcomer', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(ada, _leave(at: 10000), at: 10000);
      await p.deliver(bob, _members(<String>[bob, ada], added: ada, at: 11000));
      expect(p.members, contains(ada));
      expect(p.group.createdById, isEmpty);
      await p.deliver(ada, _members(<String>[ada, bob, eve, fay]), at: 12000);
      expect(p.members, isNot(contains(eve)));
      expect(p.members, isNot(contains(fay)));
    });

    test('also when the group was saved by 1.16.5 with the creator still '
        'named', () async {
      final _Phone p = _Phone(
        group: _joined(
          members: <String>[bob, cyd, dan],
          departedAt: <String, int>{ada: 10000},
        ),
      );
      expect(p.group.createdById, ada);
      await p.deliver(bob, _members(<String>[bob, ada], added: ada, at: 11000));
      expect(p.group.createdById, isEmpty);
      await p.deliver(ada, _members(<String>[ada, bob, eve, fay]), at: 12000);
      expect(p.members, <String>{ada, bob, cyd, dan});
    });
  });

  group('on one phone, in any order', () {
    // D leaves; the creator, on an older Zen, sends its whole list still
    // with D (and E, whom it added); Bob adds Fay by name.
    final Map<String, (String, Map<String, dynamic>)> common =
        <String, (String, Map<String, dynamic>)>{
          'leave': (dan, _leave(at: 2000)),
          'old list': (ada, _members(<String>[ada, bob, cyd, dan, eve])),
          'add F': (bob, _members(<String>[bob, fay], added: fay, at: 3000)),
        };

    Future<void> converges(
      Map<String, (String, Map<String, dynamic>)> events,
      Set<String> expected,
    ) async {
      final List<List<String>> orders = _orders(events.keys.toList());
      for (final List<String> order in orders) {
        final _Phone p = _Phone(group: _joined());
        int at = 10000;
        for (final String name in order) {
          final (String from, Map<String, dynamic> payload) = events[name]!;
          await p.deliver(from, payload, at: at++);
        }
        expect(p.members, expected, reason: 'in the order $order');
      }
    }

    test('a leave and a list a step behind: who left stays out', () async {
      await converges(common, <String>{ada, bob, cyd, eve, fay});
    });

    test('an invitation made after the leave brings them back', () async {
      await converges(
        <String, (String, Map<String, dynamic>)>{
          ...common,
          'invite D again': (
            cyd,
            _members(<String>[cyd, dan], added: dan, at: 4000),
          ),
        },
        <String>{ada, bob, cyd, dan, eve, fay},
      );
    });

    test('an addition made before the leave does not', () async {
      await converges(
        <String, (String, Map<String, dynamic>)>{
          ...common,
          'old addition of D': (
            cyd,
            _members(<String>[cyd, dan], added: dan, at: 1500),
          ),
        },
        <String>{ada, bob, cyd, eve, fay},
      );
    });
  });

  group('who may say who left', () {
    test('a member\'s word that someone else left takes nobody out', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(
        cyd,
        _members(<String>[cyd], left: <String, int>{bob: 5}),
      );
      await p.deliver(
        ada,
        _members(<String>[ada], left: <String, int>{dan: 5}),
      );
      expect(p.members, <String>{ada, bob, cyd, dan});
      expect(p.group.departedAt, isEmpty);
    });

    test('only the leaver\'s own leave records it', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(cyd, _leave(at: 2000));
      expect(p.members, <String>{ada, bob, dan});
      expect(p.group.departedAt.keys, <String>[cyd]);
      expect(p.group.departedAt[cyd], 2000);
    });

    test('a leave from a Zen before 1.16.5 (no time) counts from when it '
        'arrived', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(dan, _leave(), at: 7000);
      expect(p.group.departedAt[dan], 7000);
      // Their stale list from an older creator does not bring D back.
      await p.deliver(ada, _members(<String>[ada, bob, cyd, dan]));
      expect(p.members, <String>{ada, bob, cyd});
    });

    test('a time far ahead counts as an hour from now at most', () async {
      final _Phone p = _Phone(group: _joined());
      final int now = DateTime.now().millisecondsSinceEpoch;
      await p.deliver(dan, _leave(at: now + 365 * 24 * 3600 * 1000));
      expect(
        p.group.departedAt[dan]!,
        lessThanOrEqualTo(now + 3600 * 1000 + 60000),
      );
    });

    test('the members\' list someone waited for after joining tells who '
        'left, and nobody\'s list brings them back later', () async {
      final _Phone p = _Phone(
        group: _joined(members: <String>[ada], awaitingMembersFrom: ada),
      );
      await p.deliver(
        ada,
        _members(<String>[ada, bob, cyd], left: <String, int>{dan: 2000}),
      );
      expect(p.members, <String>{ada, bob, cyd});
      expect(p.group.departedAt[dan], 2000);
      expect(p.group.awaitingMembersFrom, isEmpty);
      // Bob's list on an older Zen, a step behind, with D in it.
      await p.deliver(bob, _members(<String>[ada, bob, cyd, dan]));
      expect(p.members, <String>{ada, bob, cyd});
    });

    test('an update that adds someone is not the list waited for', () async {
      final _Phone p = _Phone(
        group: _joined(members: <String>[ada], awaitingMembersFrom: ada),
      );
      await p.deliver(ada, _members(<String>[ada, eve], added: eve, at: 3000));
      expect(p.members, <String>{ada, eve});
      expect(p.group.awaitingMembersFrom, ada);
    });
  });

  group('next to a Zen before 1.16.5', () {
    test('an ordinary member\'s whole list a leave behind still brings in '
        'the one newcomer', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(dan, _leave(at: 2000));
      await p.deliver(bob, _members(<String>[ada, bob, cyd, dan, eve]));
      expect(p.members, <String>{ada, bob, cyd, eve});
    });

    test(
      'an update from here lists only the adder and the newcomer, so an '
      'older phone, which merges whatever list comes, takes back nobody',
      () async {
        // This phone never heard that D left.
        final _Phone p = _Phone(group: _joined());
        await p.hub.addMemberToGroup(groupId: _gid, memberAddress: eve);
        final Map<String, dynamic> update = p
            .sentTo(bob, 'group_invite')
            .single;
        expect(update['memberAddresses'], isNot(contains(dan)));
        expect(update['memberAddresses'], contains(eve));
        expect(update['added'], eve);
        expect(update['at'], isA<int>());
        expect(update.containsKey('inviteId'), isFalse);
        // The newcomer still gets a real invitation.
        expect(p.sentTo(eve, 'group_invite').single['inviteId'], isNotNull);
      },
    );

    test('leaving says when', () async {
      final _Phone p = _Phone(group: _joined());
      await p.hub.leaveGroup(groupId: _gid);
      for (final String m in <String>[ada, bob, cyd, dan]) {
        expect(p.sentTo(m, 'group_leave').single['at'], isA<int>());
      }
    });
  });

  group('a creator who left', () {
    Map<String, dynamic> post(String id, String text) => <String, dynamic>{
      'type': 'group_message',
      'groupId': _gid,
      'msgId': id,
      'text': text,
      'timestamp': 20000,
    };

    Future<List<String>> texts(_Phone p) async => <String>[
      for (final m
          in await p.container
              .read(messageTimelineStoreProvider)
              .load('group:$_gid'))
        if (!m.isSystem) m.text,
    ];

    test('is no member: their messages, timers and calls are not taken, '
        'and a locked phone does not count them either', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(bob, post('m-bob', 'Kto jutro?'), at: 9000);
      await p.deliver(ada, _leave(at: 10000), at: 10000);
      expect(p.members, <String>{bob, cyd, dan});
      expect(p.group.departedAt.keys, <String>[ada]);

      await p.deliver(ada, post('m-ada', 'Wciąż tu jestem'), at: 20000);
      await p.deliver(ada, <String, dynamic>{
        'type': 'disappear_timer',
        'groupId': _gid,
        'seconds': 60,
        'at': 20001,
      }, at: 20001);
      expect(await texts(p), <String>['Kto jutro?']);
      expect(
        p.container
            .read(socialHubControllerProvider)
            .inbox
            .where((InboxEntry e) => e.body.contains('Wciąż tu jestem')),
        isEmpty,
      );

      final SocialHubState state = p.container.read(
        socialHubControllerProvider,
      );
      expect(speaksInGroup(p.group, ada), isFalse);
      expect(speaksInGroup(p.group, bob), isTrue);
      final LockedNoticeKit kit = lockedNoticeKitOf(
        state,
        privacy: NotificationPrivacy.generic,
      );
      expect(kit.speaksIn(_gid, ada), isFalse);
      expect(kit.speaksIn(_gid, bob), isTrue);
      final BackgroundCapabilityDraft capability = backgroundCapabilityDraftOf(
        state.copyWith(
          book: FriendshipBook.restore(profiles: <String, FriendProfile>{}),
        ),
        inboxPublicKey: Uint8List(32),
      );
      expect(capability.groupMembers, isNot(contains(ada)));
      expect(capability.groupMembers, contains(bob));
    });

    test('invited again, speaks again', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(ada, _leave(at: 10000), at: 10000);
      await p.deliver(bob, _members(<String>[bob, ada], added: ada, at: 11000));
      expect(p.members, contains(ada));
      await p.deliver(ada, post('m-ada-2', 'Wróciłam'), at: 12000);
      expect(await texts(p), <String>['Wróciłam']);
    });
  });

  group('the cap', () {
    test('a group as full as members\' phones keep takes nobody more: the '
        'adder is told, nothing is sent', () async {
      final List<String> many = <String>[
        ada,
        for (int i = 1; i < kMaxGroupMemberCount; i++) '200::1:$i',
      ];
      final _Phone p = _Phone(group: _joined(members: many));
      expect(isGroupFull(p.group), isTrue);
      await expectLater(
        p.hub.addMemberToGroup(groupId: _gid, memberAddress: fay),
        throwsA(
          isA<FormatException>().having(
            (FormatException e) => e.message,
            'message',
            'Grupa może mieć najwyżej $kMaxGroupMemberCount osób.',
          ),
        ),
      );
      expect(p.members, isNot(contains(fay)));
      expect(p.transport.sentSignals, isEmpty);
    });

    test('nor is a group made with more people than that', () async {
      final _Phone p = _Phone();
      await expectLater(
        p.hub.createGroup(
          name: 'Wszyscy',
          description: '',
          memberAddresses: <String>[
            for (int i = 1; i <= kMaxGroupMemberCount; i++) '200::1:$i',
          ],
        ),
        throwsA(isA<FormatException>()),
      );
      expect(p.container.read(socialHubControllerProvider).groups, isEmpty);
      final GroupProfile made = await p.hub.createGroup(
        name: 'Prawie wszyscy',
        description: '',
        memberAddresses: <String>[
          for (int i = 1; i < kMaxGroupMemberCount; i++) '200::1:$i',
        ],
      );
      expect(made.memberAddresses.length, lessThanOrEqualTo(256));
    });
  });

  group('who left, told again', () {
    test('a member still writing into a group this phone left is told so, '
        'once in a while', () async {
      final _Phone p = _Phone(rejectedGroupIds: <String>[_gid]);
      Map<String, dynamic> message(String id) => <String, dynamic>{
        'type': 'group_message',
        'groupId': _gid,
        'msgId': id,
        'text': 'hej',
      };
      await p.deliver(bob, message('m1'), at: 10000);
      await p.deliver(bob, message('m2'), at: 11000);
      expect(p.sentTo(bob, 'group_leave'), hasLength(1));
      await p.deliver(bob, message('m3'), at: 10000 + 7 * 3600 * 1000);
      expect(p.sentTo(bob, 'group_leave'), hasLength(2));
      // A group this phone never was in tells nothing.
      await p.deliver(cyd, <String, dynamic>{
        ...message('m4'),
        'groupId': 'unknown',
      });
      expect(p.sentTo(cyd, 'group_leave'), isEmpty);
    });
  });

  group('the record', () {
    test('goes with the copy of friends and groups the account\'s devices '
        'share: a device restored from it keeps who left out', () async {
      final _Phone p = _Phone(group: _joined());
      await p.deliver(dan, _leave(at: 2000));
      final Map<String, dynamic> copy =
          jsonDecode(
                jsonEncode(
                  contactsBackupOf(
                    p.container.read(socialHubControllerProvider),
                  ),
                ),
              )
              as Map<String, dynamic>;

      final _Phone restored = _Phone();
      await restored.hub.importContactsBackup(copy);
      expect(restored.members, <String>{ada, bob, cyd});
      expect(restored.group.departedAt, <String, int>{dan: 2000});
      // Bob's list, a leave behind, does not bring Dan back there.
      await restored.deliver(bob, _members(<String>[ada, bob, cyd, dan]));
      expect(restored.members, isNot(contains(dan)));
    });

    test('in the copy, a group at the cap with long names and as many '
        'leaves still fits a part of the ledger\'s copy', () {
      String address(int i) => PeerShareCodec.normalizeAddress(
        '201:${i.toRadixString(16)}:5a3c:9e01:77f2:c0de:beef:${i + 1}',
      );
      final List<String> members = <String>[
        for (int i = 0; i < kMaxGroupMemberCount; i++) address(i),
      ];
      final GroupProfile big = GroupProfile(
        id: _gid,
        name: 'Ekipa',
        createdById: members.first,
        createdAtMillis: 1,
        memberAddresses: members,
        memberNames: <String, String>{
          for (final String m in members) m: 'Imię Nazwisko ${m.length}',
        },
        departedAt: <String, int>{
          for (int i = 0; i < kMaxGroupMemberCount; i++)
            address(1000 + i): 1790000000000 + i,
        },
      );
      final Map<String, dynamic> copy = contactsBackupOf(
        SocialHubState.empty().copyWith(
          groups: <String, GroupProfile>{_gid: big},
        ),
      );
      final Map<String, dynamic> item =
          (copy['groups'] as List<Object?>).single as Map<String, dynamic>;
      expect(
        contactsJsonBytes(<Object?>[1, item]),
        lessThanOrEqualTo(kContactsItemBytes),
      );
      final Map<String, dynamic> left =
          item[kGroupLeftKey] as Map<String, dynamic>;
      expect(left, isNotEmpty);
      // The newest are the ones kept.
      expect(
        left.containsKey(address(1000 + kMaxGroupMemberCount - 1)),
        isTrue,
      );
      expect(() => splitContacts(copy), returnsNormally);
    });

    test('survives a restart and stays bounded', () async {
      final Directory dir = await Directory.systemTemp.createTemp(
        'zen-group-departures-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          dir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      await store.save(
        SocialHubState.empty().copyWith(
          groups: <String, GroupProfile>{
            _gid: _joined().copyWith(
              departedAt: <String, int>{dan: 2000},
              addedAt: <String, int>{eve: 3000},
            ),
          },
        ),
      );
      final GroupProfile loaded = (await store.load())!.groups[_gid]!;
      expect(loaded.departedAt, <String, int>{dan: 2000});
      expect(loaded.addedAt, <String, int>{eve: 3000});

      final GroupProfile again = GroupProfile.fromJson(loaded.toJson());
      expect(again.departedAt, <String, int>{dan: 2000});
      expect(again.addedAt, <String, int>{eve: 3000});

      final GroupProfile many = GroupProfile.fromJson(<String, dynamic>{
        ...loaded.toJson(),
        'departedAt': <String, int>{
          for (int i = 1; i <= kMaxGroupMemberCount + 50; i++) '200::$i': i,
        },
      });
      expect(many.departedAt, hasLength(kMaxGroupMemberCount));
      expect(many.departedAt.containsKey('200::1'), isFalse);
      expect(many.departedAt['200::${kMaxGroupMemberCount + 50}'], isNotNull);
    });

    test('a leave on file after many come and go stays bounded', () async {
      final _Phone p = _Phone(group: _joined());
      for (int i = 0; i < kMaxGroupMemberCount + 5; i++) {
        final String who = PeerShareCodec.normalizeAddress('201::${i + 1}');
        // Each joins by name, then leaves.
        await p.deliver(
          ada,
          _members(<String>[ada, who], added: who, at: 1000 + i),
        );
        await p.deliver(who, _leave(at: 2000 + i));
      }
      expect(
        p.group.departedAt.length,
        lessThanOrEqualTo(kMaxGroupMemberCount),
      );
      expect(p.group.addedAt.length, lessThanOrEqualTo(kMaxGroupMemberCount));
    });
  });

  group('the frames', () {
    test('an update names its newcomer and when; a list tells who left', () {
      final ZenSignal update = zenSignalFromTransportPayload(
        sender: bob,
        payload: _members(
          <String>[bob, eve],
          added: eve,
          at: 3000,
          left: <String, int>{dan: 2000},
        ),
      )!;
      expect(update.chatExtras?['added'], eve);
      expect(update.sentAtMillis, 3000);
      expect(update.chatExtras?['left'], <String, int>{dan: 2000});

      final ZenSignal leave = zenSignalFromTransportPayload(
        sender: dan,
        payload: _leave(at: 2000),
      )!;
      expect(leave.sentAtMillis, 2000);

      // Nonsense is dropped, and the list of leaves is bounded.
      final ZenSignal odd = zenSignalFromTransportPayload(
        sender: bob,
        payload: <String, dynamic>{
          ..._members(<String>[bob]),
          'added': 7,
          'at': 'jutro',
          'left': <String, dynamic>{
            dan: 'wczoraj',
            'x' * (kMaxSignalIdChars + 1): 5,
            eve: -3,
            for (int i = 0; i < 1000; i++) '200::$i': i + 1,
          },
        },
      )!;
      expect(odd.chatExtras?['added'], isNull);
      expect(odd.sentAtMillis, isNull);
      final Map<dynamic, dynamic> left = odd.chatExtras!['left'] as Map;
      expect(left, hasLength(kMaxGroupMemberCount));
      expect(left.containsKey(dan), isFalse);
      expect(left.containsKey(eve), isFalse);
    });
  });
}

final class _PassThroughCompressor implements BinaryCompressor {
  const _PassThroughCompressor();

  @override
  Future<Uint8List?> compress(Uint8List payload, int level) async => payload;

  @override
  Future<Uint8List?> decompress(Uint8List payload) async => payload;
}
