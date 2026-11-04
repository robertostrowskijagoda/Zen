import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

import 'support/friends_world.dart';

// The protocols of several steps (an invitation and its answer, joining a
// group, a message and its acknowledgement through the mailboxes) on a
// network that loses, duplicates and reorders datagrams, on many seeds.
// Whatever the network does, once it has had time both sides must agree:
// the same friendship, the same members of a group, every message once,
// and nothing left "waiting" in a sender's outbox. A bug of one lost
// datagram (a "joined" said once, an acknowledgement that went while the
// sender was away) shows up here as a seed that never converges.
//
// ZEN_CHAOS_SEEDS=50 flutter test test/protocol_chaos_test.dart tries more.

int get _seeds =>
    int.tryParse(Platform.environment['ZEN_CHAOS_SEEDS'] ?? '') ?? 6;

const double _loss = 0.25;
const double _duplicates = 0.2;

/// The members of [group] as [phone] sees it, itself included (the creator
/// keeps itself as `self`).
Set<String> _members(FriendsPhone phone, GroupProfile group) => <String>{
  for (final String a in <String>[...group.memberAddresses, group.createdById])
    if (a.isNotEmpty)
      PeerShareCodec.normalizeAddress(a == 'self' ? phone.address : a),
  PeerShareCodec.normalizeAddress(phone.address),
};

/// From here on the network loses, duplicates and (by its random delays)
/// reorders datagrams. The world is built on a quiet network: its helpers
/// make friends in one settle, as a test's setup, not as the thing tested.
void _lossy(FriendsWorld w) {
  w.net
    ..dropRate = _loss
    ..duplicateRate = _duplicates;
}

void main() {
  for (int seed = 1; seed <= _seeds; seed++) {
    group('seed $seed', () {
      test('an invitation answered on a lossy network makes the same '
          'friendship on both sides', () async {
        final FriendsWorld w = await FriendsWorld.create(
          <String>['A', 'B'],
          allFriends: false,
          seed: seed,
        );
        _lossy(w);
        await w['A'].hub.sendFriendRequest(
          peerAddress: w['B'].address,
          knownName: 'B',
          senderDisplayName: 'A',
        );
        await w.until(
          () async =>
              w['B'].state.friendByAddress(w['A'].address)?.status ==
              FriendRelationshipStatus.pendingIncoming,
          within: const Duration(minutes: 10),
        );
        await w['B'].hub.acceptFriendRequest(
          peerAddress: w['A'].address,
          senderDisplayName: 'B',
        );
        await w.advance(const Duration(minutes: 10));
        expect(
          w['A'].state.friendByAddress(w['B'].address)?.status,
          FriendRelationshipStatus.accepted,
        );
        expect(
          w['B'].state.friendByAddress(w['A'].address)?.status,
          FriendRelationshipStatus.accepted,
        );
      });

      test('every member of a group made on a lossy network ends with the '
          'same members, and its messages reach everyone once', () async {
        final FriendsWorld w = await FriendsWorld.create(<String>[
          'A',
          'B',
          'C',
        ], seed: seed);
        _lossy(w);
        final GroupProfile made = await w['A'].hub.createGroup(
          name: 'Chaos',
          description: '',
          memberAddresses: <String>[w['B'].address, w['C'].address],
        );
        final String id = made.id;
        // Each member accepts once its invitation has come (it may take a
        // few tries on this network).
        for (final String n in <String>['B', 'C']) {
          await w.until(
            () async => w[n].state.groups[id]?.isInvitePending ?? false,
            within: const Duration(minutes: 10),
            reason: 'the invitation reaching $n',
          );
          await w[n].hub.acceptGroupInvite(
            groupId: id,
            groupName: 'Chaos',
            senderAddress: w['A'].address,
          );
        }
        await w.advance(const Duration(minutes: 10));
        final List<String> views = <String>[
          for (final String n in <String>['A', 'B', 'C'])
            (_members(w[n], w[n].state.groups[id]!).toList()..sort()).join(' '),
        ];
        expect(views.toSet(), hasLength(1), reason: '$views');
        expect(views.first.split(' '), hasLength(3));

        await w.sendGroup(w['B'], id, 'od B');
        await w.advance(const Duration(minutes: 10));
        for (final String n in <String>['A', 'C']) {
          expect(await w.groupTexts(w[n], id), <String>['od B'], reason: n);
        }
      });

      test('messages through the mailboxes on a lossy network arrive once, '
          'in order, and leave nothing waiting with the sender', () async {
        final FriendsWorld w = await FriendsWorld.create(<String>[
          'A',
          'B',
          'M1',
          'M2',
        ], seed: seed);
        await w.chooseMailboxes(w['B'], <FriendsPhone>[w['M1'], w['M2']]);
        await w.settleMailboxes();
        _lossy(w);
        await w.setOnline(w['B'], false);
        for (int i = 1; i <= 4; i++) {
          await w.send(w['A'], w['B'], 'wiadomość $i');
        }
        await w.advance(const Duration(minutes: 2));
        // The sender leaves before B is back: B's acknowledgements find
        // nobody, as on phones that are rarely on at once.
        await w.setOnline(w['A'], false);
        await w.setOnline(w['B'], true);
        await w.advance(const Duration(minutes: 10));
        await w.setOnline(w['A'], true);
        await w.advance(const Duration(hours: 1));
        expect(await w['B'].textsFrom(w['A']), <String>[
          for (int i = 1; i <= 4; i++) 'wiadomość $i',
        ]);
        expect(
          w['A'].engine.overview.value.outboxCount,
          0,
          reason: 'nothing may stay "waiting" once B has everything',
        );
      });
    });
  }
}
