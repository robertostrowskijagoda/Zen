import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/pyramid/pyramid_cell_chat.dart';
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Routable mesh addresses (the controller only talks to those).
final String ada = PeerShareCodec.normalizeAddress('200::ada');
final String bob = PeerShareCodec.normalizeAddress('200::b0b');
final String cyd = PeerShareCodec.normalizeAddress('200::c0d');

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);
const LifecycleSnapshot _visibleUnfocused = LifecycleSnapshot(
  visibility: AppVisibilityState.foreground,
  generation: 2,
  capturedAtMillis: 0,
);
const LifecycleSnapshot _focused = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 3,
  capturedAtMillis: 0,
);

FriendProfile _friend(String address, String name) => FriendProfile(
  address: address,
  displayName: name,
  status: FriendRelationshipStatus.accepted,
);

final class _Harness {
  _Harness({
    SocialHubState? seed,
    SocialSnapshotStore? snapshotStore,
    this.autoHydrate = false,
    bool hideContent = false,
    List extraOverrides = const [],
  }) : snapshotStore = snapshotStore ?? MemorySocialSnapshotStore() {
    container = ProviderContainer(
      overrides: [
        ...extraOverrides,
        // These tests check what notifications say; hiding the text has
        // its own test.
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: AppSettings(
            notificationPrivacy: hideContent
                ? NotificationPrivacy.senderOnly
                : NotificationPrivacy.senderAndContent,
            // Every group message notifies here ("W grupach tylko
            // wzmianki" has its own tests).
            groupMentionsOnly: false,
          ),
          hydrationEnabled: false,
        ),
        signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
        socialSnapshotStoreProvider.overrideWithValue(this.snapshotStore),
        messageTimelineStoreProvider.overrideWithValue(timelines),
        attachmentTransferStoreProvider.overrideWithValue(
          MemoryAttachmentTransferStore(),
        ),
        signalTransportProvider.overrideWithValue(transport),
        runtimeSystemNotificationServiceProvider.overrideWithValue(
          notifications,
        ),
        socialHubAutoHydrateProvider.overrideWithValue(autoHydrate),
        socialHubSeedProvider.overrideWithValue(
          seed ??
              SocialHubState.empty(lifecycle: _focused).copyWith(
                book: FriendshipBook.restore(
                  profiles: <String, FriendProfile>{
                    ada: _friend(ada, 'Ada'),
                    bob: _friend(bob, 'Bob'),
                    cyd: _friend(cyd, 'Cyd'),
                  },
                ),
              ),
        ),
      ],
    );
    addTearDown(container.dispose);
  }

  final bool autoHydrate;
  final MemorySignalTransport transport = MemorySignalTransport();
  final MemoryRuntimeSystemNotificationService notifications =
      MemoryRuntimeSystemNotificationService();
  final MemoryMessageTimelineStore timelines = MemoryMessageTimelineStore();
  final SocialSnapshotStore snapshotStore;
  late final ProviderContainer container;

  SocialHubController get controller =>
      container.read(socialHubControllerProvider.notifier);

  SocialHubState get state => container.read(socialHubControllerProvider);

  List<Map<String, dynamic>> sentTo(String address, String type) => transport
      .sentSignals
      .where(
        (s) =>
            PeerShareCodec.addressesEqual(s.remoteAddress, address) &&
            s.payload['type'] == type,
      )
      .map((s) => s.payload)
      .toList();

  /// Delivers [payload] from [from] exactly like the runtime bridge does.
  Future<void> deliver(
    String from,
    Map<String, dynamic> payload, {
    int at = 1000,
  }) async {
    final ZenSignal? signal = zenSignalFromTransportPayload(
      sender: from,
      payload: payload,
    );
    expect(signal, isNotNull, reason: 'payload must parse: $payload');
    await controller.receiveSignal(signal!, receivedAtMillis: at);
    // Invite re-sync after a signal runs detached; let it finish.
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, dynamic> _invite(String groupId, List<String> members) =>
    <String, dynamic>{
      'type': 'group_invite',
      'groupId': groupId,
      'groupName': 'Wyprawa',
      'memberAddresses': members,
      'senderName': 'Ada',
    };

void main() {
  group('inviter side', () {
    test('createGroup tracks every invitee until it confirms', () async {
      final _Harness h = _Harness();

      final GroupProfile group = await h.controller.createGroup(
        name: 'Wyprawa',
        description: '',
        memberAddresses: <String>[bob, cyd, bob],
      );

      expect(group.pendingInviteAddresses, unorderedEquals(<String>[bob, cyd]));
      expect(group.memberAddresses, unorderedEquals(<String>[bob, cyd]));
      final Map<String, dynamic> invite = h.sentTo(bob, 'group_invite').single;
      expect(invite['groupId'], group.id);
      // Names, not addresses: Bob learns Cyd's address only once he joins.
      expect(invite['memberAddresses'], isNot(contains(cyd)));
      // The others' names; Bob is not shown his own.
      expect(invite['memberNames'], <String>['Cyd']);

      await h.deliver(bob, <String, dynamic>{
        'type': 'group_invite_ack',
        'groupId': group.id,
      });
      expect(h.state.groups[group.id]!.pendingInviteAddresses, <String>[cyd]);
      expect(
        h.sentTo(bob, 'group_invite'),
        hasLength(1),
        reason: 'an invitation that only arrived gets no addresses',
      );
    });

    test('who joins gets the address of every member', () async {
      final _Harness h = _Harness();
      final GroupProfile group = await h.controller.createGroup(
        name: 'Wyprawa',
        description: '',
        memberAddresses: <String>[bob, cyd],
      );
      h.transport.sentSignals.clear();

      await h.deliver(bob, <String, dynamic>{
        'type': 'group_invite_ack',
        'groupId': group.id,
        'joined': true,
      });
      final Map<String, dynamic> members = h.sentTo(bob, 'group_invite').single;
      expect(members['memberAddresses'], containsAll(<String>[bob, cyd]));
      expect(members.containsKey('inviteId'), isFalse);
    });

    test(
      'a group of one is made with nobody chosen; members come later',
      () async {
        final _Harness h = _Harness();

        final GroupProfile group = await h.controller.createGroup(
          name: 'Na później',
          description: '',
          memberAddresses: const <String>[],
        );

        expect(h.state.groups[group.id], isNotNull);
        expect(group.pendingInviteAddresses, isEmpty);
        expect(h.transport.sentSignals, isEmpty);

        await h.controller.addMemberToGroup(
          groupId: group.id,
          memberAddress: bob,
        );
        expect(h.state.groups[group.id]!.memberAddresses, contains(bob));
        expect(h.sentTo(bob, 'group_invite'), hasLength(1));
      },
    );

    test('an invitee that shows up later gets the invite again', () async {
      final _Harness h = _Harness();
      final GroupProfile group = await h.controller.createGroup(
        name: 'Wyprawa',
        description: '',
        memberAddresses: <String>[bob],
      );
      h.transport.sentSignals.clear();

      // Bob was offline; now any signal from him arrives (a read receipt).
      await h.deliver(bob, <String, dynamic>{
        'type': 'message_read',
        'msgId': 'x',
      });
      expect(h.sentTo(bob, 'group_invite'), hasLength(1));
      expect(h.sentTo(bob, 'group_invite').single['groupId'], group.id);

      // Throttled: a burst of traffic does not re-send it over and over.
      await h.deliver(bob, <String, dynamic>{
        'type': 'message_read',
        'msgId': 'y',
      });
      expect(h.sentTo(bob, 'group_invite'), hasLength(1));

      // Presence counts as a sign of life too.
      await h.controller.syncGroupInvitesToPeer(cyd);
      expect(
        h.sentTo(cyd, 'group_invite'),
        isEmpty,
        reason: 'cyd was never invited',
      );
    });

    test('a member that declines is removed and not re-invited', () async {
      final _Harness h = _Harness();
      final GroupProfile group = await h.controller.createGroup(
        name: 'Wyprawa',
        description: '',
        memberAddresses: <String>[bob, cyd],
      );
      await h.deliver(bob, <String, dynamic>{
        'type': 'group_leave',
        'groupId': group.id,
      });
      final GroupProfile after = h.state.groups[group.id]!;
      expect(after.memberAddresses, <String>[cyd]);
      expect(after.pendingInviteAddresses, <String>[cyd]);
    });

    test('adding a member syncs the new list to existing members', () async {
      final _Harness h = _Harness();
      final GroupProfile group = await h.controller.createGroup(
        name: 'Wyprawa',
        description: '',
        memberAddresses: <String>[bob],
      );
      h.transport.sentSignals.clear();

      await h.controller.addMemberToGroup(
        groupId: group.id,
        memberAddress: cyd,
      );

      expect(h.sentTo(cyd, 'group_invite'), hasLength(1));
      final List<Map<String, dynamic>> toBob = h.sentTo(bob, 'group_invite');
      expect(toBob, hasLength(1));
      expect(toBob.single['memberAddresses'], contains(cyd));
    });
  });

  group('invitee side', () {
    test('an invite is acknowledged, shown once and marked pending', () async {
      final _Harness h = _Harness();

      await h.deliver(ada, _invite('g1', <String>[ada, bob]));
      await h.deliver(ada, _invite('g1', <String>[ada, bob]), at: 1100);

      expect(h.sentTo(ada, 'group_invite_ack'), hasLength(2));
      expect(
        h.state.inbox.where(
          (InboxEntry e) => e.type == InboxEntryType.groupInvite,
        ),
        hasLength(1),
      );
      expect(h.state.groups['g1']!.isInvitePending, isTrue);

      await h.controller.acceptGroupInvite(groupId: 'g1', groupName: 'Wyprawa');
      expect(h.state.groups['g1']!.isInvitePending, isFalse);
      // The reply goes out detached.
      await Future<void>.delayed(Duration.zero);
      expect(
        h.sentTo(ada, 'group_invite_ack').last['joined'],
        isTrue,
        reason: 'joining says so, for the addresses of the members',
      );
      expect(
        h.state.inbox.where(
          (InboxEntry e) => e.type == InboxEntryType.groupInvite,
        ),
        isEmpty,
        reason: 'joining clears the invite card',
      );
    });

    test('an invitation shows the members by name until joining', () async {
      final _Harness h = _Harness();

      await h.deliver(ada, <String, dynamic>{
        ..._invite('g2', <String>[ada]),
        'inviteId': 'i1',
        'memberNames': <String>['Ola', ''],
      });
      final GroupProfile pending = h.state.groups['g2']!;
      expect(pending.inviteMemberNames, <String>['Ola', '']);
      expect(pending.memberCount, 4, reason: 'Ola, someone, Ada and me');
      expect(pending.memberAddresses, <String>[ada]);

      await h.controller.acceptGroupInvite(groupId: 'g2', groupName: 'Wyprawa');
      expect(h.state.groups['g2']!.awaitingMembersFrom, ada);
      // The members' addresses come from Ada now.
      await h.deliver(ada, _invite('g2', <String>[ada, bob, cyd]), at: 1200);
      final GroupProfile joined = h.state.groups['g2']!;
      expect(joined.inviteMemberNames, isEmpty);
      expect(joined.memberAddresses, containsAll(<String>[ada, bob, cyd]));
      expect(joined.awaitingMembersFrom, isEmpty);
    });

    test(
      'a lost "joined" is said again when the inviter shows up, until the members come',
      () async {
        final _Harness h = _Harness();
        await h.deliver(ada, <String, dynamic>{
          ..._invite('g2', <String>[ada]),
          'inviteId': 'i1',
          'memberNames': <String>['Ola'],
        });
        await h.controller.acceptGroupInvite(
          groupId: 'g2',
          groupName: 'Wyprawa',
        );
        bool joinedAck(Map<String, dynamic> p) => p['joined'] == true;
        await Future<void>.delayed(Duration.zero);
        expect(
          h.sentTo(ada, 'group_invite_ack').where(joinedAck),
          hasLength(1),
        );

        // That datagram was lost (Ada was away); she shows up again.
        await h.controller.syncGroupInvitesToPeer(ada);
        await Future<void>.delayed(Duration.zero);
        expect(
          h.sentTo(ada, 'group_invite_ack').where(joinedAck),
          hasLength(2),
          reason: 'asked again for the members',
        );

        await h.deliver(ada, _invite('g2', <String>[ada, bob, cyd]), at: 1200);
        expect(h.state.groups['g2']!.awaitingMembersFrom, isEmpty);
        expect(
          h.state.groups['g2']!.memberAddresses,
          containsAll(<String>[bob, cyd]),
        );
      },
    );

    test(
      'an invitation from an older version (with addresses) awaits nothing',
      () async {
        final _Harness h = _Harness();
        await h.deliver(ada, _invite('g2', <String>[ada, bob, cyd]));
        await h.controller.acceptGroupInvite(
          groupId: 'g2',
          groupName: 'Wyprawa',
        );
        expect(h.state.groups['g2']!.awaitingMembersFrom, isEmpty);
      },
    );

    test('a declined invite stays declined across a restart', () async {
      final MemorySocialSnapshotStore store = MemorySocialSnapshotStore();
      final _Harness first = _Harness(snapshotStore: store);
      await first.deliver(ada, _invite('g2', <String>[ada]));
      final String inviteId = first.state.inbox.single.id;
      await first.controller.rejectGroupInvite(
        groupId: 'g2',
        inboxEntryId: inviteId,
        senderAddress: ada,
      );
      expect(first.state.rejectedGroupIds, contains('g2'));

      // New process: state comes back from the snapshot.
      final _Harness second = _Harness(
        snapshotStore: store,
        autoHydrate: true,
        seed: SocialHubState.empty(lifecycle: _focused),
      );
      await second.controller.whenHydrated;
      await second.controller.hydrateFromStore();
      await second.deliver(ada, _invite('g2', <String>[ada]));

      expect(second.state.groups.containsKey('g2'), isFalse);
      expect(second.state.inbox, isEmpty);
      expect(
        second.sentTo(ada, 'group_leave'),
        isNotEmpty,
        reason: 'the inviter is told to stop re-sending',
      );
    });

    test(
      'a group invite in the background raises exactly one notification',
      () async {
        final _Harness h = _Harness(
          seed: SocialHubState.empty(lifecycle: _background).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
            ),
          ),
        );
        for (int i = 0; i < 4; i++) {
          await h.deliver(ada, _invite('g3', <String>[ada]), at: 1000 + i);
        }
        expect(h.notifications.activeNotifications, hasLength(1));
        expect(h.notifications.audibleAlertCount, 1);
        expect(
          h.notifications.activeNotifications.single.title,
          contains('Wyprawa'),
        );
      },
    );

    test(
      'a member cannot bring anyone into a managed (pyramid cell) chat',
      () async {
        final _Harness h = _Harness();
        await h.controller.syncManagedGroups(
          'pyrcell-',
          <String, ({String name, List<String> members})>{
            'pyrcell-abc': (name: 'Komórka', members: <String>[ada, bob]),
          },
        );
        expect(isManagedGroup(h.state.groups['pyrcell-abc']!), isTrue);
        // Ada (a member of the cell) syncs a list with one more person, as
        // adding someone to an ordinary group would.
        await h.deliver(ada, _invite('pyrcell-abc', <String>[ada, bob, cyd]));
        expect(
          h.state.groups['pyrcell-abc']!.memberAddresses,
          isNot(contains(cyd)),
        );
        await h.controller.addMemberToGroup(
          groupId: 'pyrcell-abc',
          memberAddress: cyd,
        );
        expect(
          h.state.groups['pyrcell-abc']!.memberAddresses,
          isNot(contains(cyd)),
        );
        expect(h.sentTo(cyd, 'group_invite'), isEmpty);
      },
    );

    test('nobody can invite to a pyramid cell chat\'s id before the cell '
        'forms', () async {
      final _Harness h = _Harness();
      expect(isManagedGroupId('${kPyrCellGroupPrefix}0123'), isTrue);
      const String cellId = 'pyrcell-0123456789abcdef01234567';
      await h.deliver(ada, _invite(cellId, <String>[ada]));
      expect(h.state.groups, isNot(contains(cellId)));
      expect(h.state.inbox, isEmpty);
      expect(h.notifications.activeNotifications, isEmpty);
    });

    test('a cell chat replaces a group of its id it finds, creator and '
        'members included', () async {
      final String dan = PeerShareCodec.normalizeAddress('200::da7');
      const String cellId = 'pyrcell-0123456789abcdef01234567';
      // An invitation an older version took in under the id the cell's chat
      // was going to have.
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _focused).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
              ada: _friend(ada, 'Ada'),
              bob: _friend(bob, 'Bob'),
              cyd: _friend(cyd, 'Cyd'),
            },
          ),
          groups: <String, GroupProfile>{
            cellId: GroupProfile(
              id: cellId,
              name: 'Wyprawa',
              createdById: ada,
              createdAtMillis: 0,
              memberAddresses: <String>[ada],
              isInvitePending: true,
            ),
          },
        ),
      );
      await h.controller.syncManagedGroups(
        'pyrcell-',
        <String, ({String name, List<String> members})>{
          cellId: (name: 'Komórka', members: <String>[bob, cyd]),
        },
      );
      final GroupProfile g = h.state.groups[cellId]!;
      expect(g.isInvitePending, isFalse);
      expect(g.createdById, 'pyrcell-');
      expect(isManagedGroup(g), isTrue);
      expect(g.memberAddresses, unorderedEquals(<String>[bob, cyd]));

      await h.deliver(ada, _invite(cellId, <String>[ada, dan]), at: 2000);
      expect(h.state.groups[cellId]!.memberAddresses, isNot(contains(dan)));
      await h.deliver(ada, <String, dynamic>{
        'type': 'group_leave',
        'groupId': cellId,
      }, at: 2001);
      await h.deliver(bob, <String, dynamic>{
        'type': 'group_leave',
        'groupId': cellId,
      }, at: 2002);
      expect(
        h.state.groups[cellId]!.memberAddresses,
        unorderedEquals(<String>[bob, cyd]),
      );

      await h.deliver(bob, <String, dynamic>{
        'type': 'group_message',
        'groupId': cellId,
        'msgId': 'bob-1',
        'text': 'głosuję przeciw',
        'senderName': 'Bob',
      }, at: 3000);
      await h.deliver(ada, <String, dynamic>{
        'type': 'msg_delete',
        'groupId': cellId,
        'msgId': 'bob-1',
        'at': 3001,
      }, at: 3001);
      final List<ChatMessage> t = await h.timelines.load('group:$cellId');
      expect(
        t.firstWhere((ChatMessage m) => m.id == 'bob-1').isDeleted,
        isFalse,
      );
      h.transport.sentSignals.clear();
      await h.controller.sendGroupMessage(groupId: cellId, text: 'tajne');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(h.sentTo(ada, 'group_message'), isEmpty);
      expect(h.sentTo(dan, 'group_message'), isEmpty);
    });

    test('someone leaving is a timeline note, not a notification', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
          groups: <String, GroupProfile>{
            'g4': GroupProfile(
              id: 'g4',
              name: 'Wyprawa',
              createdById: 'self',
              createdAtMillis: 0,
              memberAddresses: <String>[ada],
            ),
          },
        ),
      );
      for (int i = 0; i < 4; i++) {
        await h.deliver(ada, <String, dynamic>{
          'type': 'group_leave',
          'groupId': 'g4',
        }, at: 2000 + i);
      }
      expect(h.notifications.activeNotifications, isEmpty);
      expect(h.state.groups['g4']!.memberAddresses, isEmpty);
      final List<ChatMessage> timeline = await h.timelines.load('group:g4');
      expect(timeline.where((ChatMessage m) => m.isSystem), hasLength(1));
      expect(timeline.single.text, contains('opuścił'));
    });

    test('messages for a group we are not in are ignored', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
        ),
      );
      await h.deliver(ada, <String, dynamic>{
        'type': 'group_message',
        'groupId': 'left-long-ago',
        'msgId': 'm1',
        'text': 'halo?',
      });
      expect(h.notifications.activeNotifications, isEmpty);
      expect(await h.timelines.load('group:left-long-ago'), isEmpty);
    });
  });

  group('message notifications', () {
    test('a repeated group message is stored and announced once', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
          groups: <String, GroupProfile>{
            'g5': GroupProfile(
              id: 'g5',
              name: 'Wyprawa',
              createdById: ada,
              createdAtMillis: 0,
              memberAddresses: <String>[ada],
            ),
          },
        ),
      );
      final Map<String, dynamic> message = <String, dynamic>{
        'type': 'group_message',
        'groupId': 'g5',
        'groupName': 'Wyprawa',
        'msgId': 'gm-1',
        'text': 'Zbiórka o 7',
      };
      await h.deliver(ada, message, at: 3000);
      await h.deliver(ada, message, at: 3001);

      expect(await h.timelines.load('group:g5'), hasLength(1));
      expect(h.notifications.activeNotifications, hasLength(1));
    });

    test('a repeated direct message counts as unread once', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
        ),
      );
      final Map<String, dynamic> message = <String, dynamic>{
        'type': 'message',
        'msgId': 'dm-1',
        'text': 'Hej',
      };
      await h.deliver(ada, message, at: 4000);
      await h.deliver(ada, message, at: 4001);

      expect(await h.timelines.load(ada), hasLength(1));
      expect(h.notifications.audibleAlertCount, 1);
      // The sender still gets its delivery ack for the repeat.
      expect(h.sentTo(ada, 'message_ack'), hasLength(2));
    });

    test('a visible but unfocused window still notifies', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _visibleUnfocused).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
        ),
      );
      await h.deliver(ada, <String, dynamic>{
        'type': 'message',
        'msgId': 'dm-2',
        'text': 'Jesteś?',
      });
      expect(h.notifications.activeNotifications, hasLength(1));
      expect(h.notifications.activeNotifications.single.body, 'Jesteś?');
    });

    test(
      'with the privacy setting on the text stays out of the shade',
      () async {
        final _Harness h = _Harness(
          hideContent: true,
          seed: SocialHubState.empty(lifecycle: _visibleUnfocused).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
            ),
          ),
        );
        await h.deliver(ada, <String, dynamic>{
          'type': 'message',
          'msgId': 'dm-3',
          'text': 'Tajne',
        });
        expect(
          h.notifications.activeNotifications.single.body,
          'Nowa wiadomość',
        );
      },
    );

    test('a focused window does not post system notifications', () async {
      final _Harness h = _Harness();
      await h.deliver(ada, <String, dynamic>{
        'type': 'message',
        'msgId': 'dm-3',
        'text': 'Widzisz to w aplikacji',
      });
      expect(h.notifications.activeNotifications, isEmpty);
    });

    test('a burst from one chat folds into one quiet, stacked entry', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
        ),
      );
      for (int i = 1; i <= 3; i++) {
        await h.deliver(ada, <String, dynamic>{
          'type': 'message',
          'msgId': 'burst-$i',
          'text': 'wiadomość $i',
        }, at: 5000 + i * 1000);
      }
      final RuntimeSystemNotification shown =
          h.notifications.activeNotifications.single;
      expect(shown.stackCount, 3);
      expect(shown.lines, <String>[
        'wiadomość 1',
        'wiadomość 2',
        'wiadomość 3',
      ]);
      expect(h.notifications.audibleAlertCount, 1);
    });
  });

  group('a group you were invited to but have not joined', () {
    Future<_Harness> pendingHarness({
      LifecycleSnapshot lifecycle = _background,
    }) async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: lifecycle).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
        ),
      );
      await h.deliver(ada, _invite('gp', <String>[ada, bob]));
      h.transport.sentSignals.clear();
      return h;
    }

    test('cannot be written to, called or extended', () async {
      final _Harness h = await pendingHarness();

      await expectLater(
        h.controller.sendGroupMessage(groupId: 'gp', text: 'hej'),
        throwsA(isA<StateError>()),
      );
      await expectLater(
        h.controller.startGroupCall(groupId: 'gp', kind: CallInviteKind.audio),
        throwsA(isA<FormatException>()),
      );
      await h.controller.addMemberToGroup(groupId: 'gp', memberAddress: cyd);

      expect(h.transport.sentSignals, isEmpty);
      expect(await h.timelines.load('group:gp'), isEmpty);
      expect(h.state.activeCall, isNull);
      expect(h.state.groups['gp']!.memberAddresses, isNot(contains(cyd)));
    });

    test(
      'keeps incoming messages quietly and shows them after joining',
      () async {
        final _Harness h = await pendingHarness();
        await h.deliver(ada, <String, dynamic>{
          'type': 'group_message',
          'groupId': 'gp',
          'msgId': 'pre-1',
          'text': 'Witaj!',
          'senderName': 'Ada',
        }, at: 2000);

        expect(await h.timelines.load('group:gp'), hasLength(1));
        // Only the invite itself was announced.
        expect(
          h.notifications.activeNotifications.map(
            (RuntimeSystemNotification n) => n.category,
          ),
          everyElement(RuntimeSystemNotificationCategory.social),
        );

        await h.controller.acceptGroupInvite(
          groupId: 'gp',
          groupName: 'Wyprawa',
        );
        await h.controller.sendGroupMessage(groupId: 'gp', text: 'Już jestem');
        expect(await h.timelines.load('group:gp'), hasLength(2));
      },
    );

    test('stays out of the group list whatever arrives, also after a '
        'restart', () async {
      final MemorySocialSnapshotStore store = MemorySocialSnapshotStore();
      final _Harness h = _Harness(
        snapshotStore: store,
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{
              ada: _friend(ada, 'Ada'),
              bob: _friend(bob, 'Bob'),
            },
          ),
        ),
      );
      // A message can overtake the invitation on the network.
      await h.deliver(ada, <String, dynamic>{
        'type': 'group_message',
        'groupId': 'gx',
        'msgId': 'early',
        'text': 'Za wcześnie',
      });
      expect(h.state.groupList, isEmpty);
      await h.deliver(ada, _invite('gx', <String>[ada, bob]));
      for (final Map<String, dynamic> p in <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'group_message',
          'groupId': 'gx',
          'msgId': 'm1',
          'text': 'Hej!',
          'senderName': 'Ada',
        },
        _invite('gx', <String>[ada, bob, cyd]),
        <String, dynamic>{'type': 'group_invite_ack', 'groupId': 'gx'},
        <String, dynamic>{
          'type': 'group_call_invite',
          'groupId': 'gx',
          'callId': 'gcall-2-y',
          'groupName': 'Wyprawa',
          'kind': 'audio',
        },
      ]) {
        await h.deliver(ada, p, at: 3000);
        await h.deliver(bob, p, at: 3001);
      }
      expect(h.state.groups['gx']!.isInvitePending, isTrue);
      expect(h.state.groupList, isEmpty);

      final _Harness again = _Harness(
        snapshotStore: store,
        autoHydrate: true,
        seed: SocialHubState.empty(lifecycle: _focused),
      );
      await again.controller.whenHydrated;
      await again.controller.hydrateFromStore();
      expect(again.state.groups['gx']?.isInvitePending, isTrue);
      expect(again.state.groupList, isEmpty);
      expect(
        again.state.inbox.where(
          (InboxEntry e) => e.type == InboxEntryType.groupInvite,
        ),
        hasLength(1),
      );
    });

    test('does not ring for a group call', () async {
      final _Harness h = await pendingHarness();
      await h.deliver(ada, <String, dynamic>{
        'type': 'group_call_invite',
        'groupId': 'gp',
        'callId': 'gcall-1-x',
        'groupName': 'Wyprawa',
        'kind': 'audio',
      });
      expect(h.state.activeCall, isNull);
    });
  });

  group('coming back to a group', () {
    Map<String, dynamic> invitation(String inviteId) => <String, dynamic>{
      ..._invite('gb', <String>[ada, bob]),
      'inviteId': inviteId,
    };

    bool hasInviteInInbox(_Harness h) => h.state.inbox.any(
      (InboxEntry e) =>
          e.type == InboxEntryType.groupInvite &&
          (e.routeKey?.contains('gb') ?? false),
    );

    test('a new invitation after leaving brings the group back, re-sends of '
        'the old one do not', () async {
      final _Harness h = _Harness();
      await h.deliver(ada, invitation('inv-1'));
      await h.controller.acceptGroupInvite(groupId: 'gb', groupName: 'Wyprawa');
      await h.controller.leaveGroup(groupId: 'gb');
      expect(h.state.groups['gb'], isNull);

      // The old invitation, still being re-sent from somewhere.
      await h.deliver(ada, invitation('inv-1'), at: 5000);
      expect(h.state.groups['gb'], isNull);
      expect(hasInviteInInbox(h), isFalse);
      // A member-list sync (no invitation id) cannot bring it back either.
      await h.deliver(ada, _invite('gb', <String>[ada, bob, cyd]), at: 6000);
      expect(h.state.groups['gb'], isNull);

      // Someone adds the user again.
      await h.deliver(ada, invitation('inv-2'), at: 90000);
      expect(h.state.groups['gb']!.isInvitePending, isTrue);
      expect(hasInviteInInbox(h), isTrue);

      await h.controller.acceptGroupInvite(groupId: 'gb', groupName: 'Wyprawa');
      expect(h.state.groupList.map((GroupProfile g) => g.id), contains('gb'));
      expect(h.state.rejectedGroupIds, isNot(contains('gb')));
    });

    test('declining works the same way', () async {
      final _Harness h = _Harness();
      await h.deliver(ada, invitation('inv-1'));
      final InboxEntry entry = h.state.inbox.firstWhere(
        (InboxEntry e) => e.type == InboxEntryType.groupInvite,
      );
      await h.controller.rejectGroupInvite(
        groupId: 'gb',
        inboxEntryId: entry.id,
        senderAddress: ada,
      );
      await h.deliver(ada, invitation('inv-1'), at: 5000);
      expect(h.state.groups['gb'], isNull);

      await h.deliver(ada, invitation('inv-3'), at: 90000);
      expect(h.state.groups['gb']!.isInvitePending, isTrue);
    });

    test('an invitation not answered yet is not one of your groups', () async {
      final _Harness h = _Harness();
      await h.deliver(ada, invitation('inv-1'));
      expect(h.state.groups['gb'], isNotNull);
      expect(h.state.groupList, isEmpty);

      await h.controller.acceptGroupInvite(groupId: 'gb', groupName: 'Wyprawa');
      expect(h.state.groupList.single.id, 'gb');
    });

    test('the inviter gives every invitee an invitation id of its own and '
        'keeps it for re-sends', () async {
      final _Harness h = _Harness();
      final GroupProfile group = await h.controller.createGroup(
        name: 'Wyprawa',
        description: '',
        memberAddresses: <String>[bob, cyd],
      );
      final String? forBob = h.sentTo(bob, 'group_invite').single['inviteId'];
      final String? forCyd = h.sentTo(cyd, 'group_invite').single['inviteId'];
      expect(forBob, isNotNull);
      expect(forCyd, isNotNull);
      expect(forBob, isNot(forCyd));

      h.transport.sentSignals.clear();
      await h.controller.syncGroupInvitesToPeer(bob);
      expect(h.sentTo(bob, 'group_invite').single['inviteId'], forBob);

      // Bob confirms: nothing is re-sent any more.
      await h.deliver(bob, <String, dynamic>{
        'type': 'group_invite_ack',
        'groupId': group.id,
      });
      expect(h.state.groups[group.id]!.pendingInviteIds.keys, <String>[cyd]);
    });

    test(
      'adding someone sends a real invitation only to the newcomer',
      () async {
        final _Harness h = _Harness();
        final GroupProfile group = await h.controller.createGroup(
          name: 'Wyprawa',
          description: '',
          memberAddresses: <String>[bob],
        );
        h.transport.sentSignals.clear();
        await h.controller.addMemberToGroup(
          groupId: group.id,
          memberAddress: cyd,
        );
        expect(h.sentTo(cyd, 'group_invite').single['inviteId'], isNotNull);
        expect(
          h.sentTo(bob, 'group_invite').single.containsKey('inviteId'),
          isFalse,
        );
      },
    );
  });

  group('group read state', () {
    GroupProfile joined() => GroupProfile(
      id: 'gr',
      name: 'Ekipa',
      createdById: ada,
      createdAtMillis: 0,
      memberAddresses: <String>[ada, bob],
    );

    Map<String, dynamic> message(String id, {String? name}) =>
        <String, dynamic>{
          'type': 'group_message',
          'groupId': 'gr',
          'msgId': id,
          'text': 'tekst $id',
          'senderName': ?name,
        };

    test('opening the chat clears unread; while open nothing piles up or '
        'notifies', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _focused).copyWith(
          book: FriendshipBook.restore(
            profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
          ),
          groups: <String, GroupProfile>{'gr': joined()},
        ),
      );
      await h.deliver(ada, message('1'), at: 1000);
      await h.deliver(ada, message('2'), at: 2000);
      expect(h.state.groups['gr']!.unreadCount, 2);

      await h.controller.enterGroupConversation('gr');
      expect(h.state.groups['gr']!.unreadCount, 0);

      await h.deliver(ada, message('3'), at: 3000);
      expect(h.state.groups['gr']!.unreadCount, 0);
      expect(h.notifications.activeNotifications, isEmpty);

      h.controller.leaveGroupConversation('gr');
      await h.deliver(ada, message('4'), at: 4000);
      expect(h.state.groups['gr']!.unreadCount, 1);
    });

    test(
      'members who are not friends are labelled by their own name',
      () async {
        final _Harness h = _Harness(
          seed: SocialHubState.empty(lifecycle: _focused).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
            ),
            groups: <String, GroupProfile>{'gr': joined()},
          ),
        );
        await h.deliver(bob, message('b1', name: 'Bartek'));
        expect(h.state.groups['gr']!.memberNames[bob], 'Bartek');
      },
    );

    test(
      'a friend outside the group cannot post into it or join by posting',
      () async {
        final _Harness h = _Harness(
          seed: SocialHubState.empty(lifecycle: _focused).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{
                ada: _friend(ada, 'Ada'),
                cyd: _friend(cyd, 'Cyd'),
              },
            ),
            groups: <String, GroupProfile>{'gr': joined()},
          ),
        );
        await h.deliver(cyd, message('c1', name: 'Cyd'));
        await h.deliver(cyd, _invite('gr', <String>[cyd, ada]));

        expect(await h.timelines.load('group:gr'), isEmpty);
        expect(h.state.groups['gr']!.memberAddresses, isNot(contains(cyd)));
        expect(h.state.groups['gr']!.unreadCount, 0);
        expect(h.notifications.activeNotifications, isEmpty);
      },
    );

    test(
      'a late message from someone who left does not bring them back',
      () async {
        final _Harness h = _Harness(
          seed: SocialHubState.empty(lifecycle: _focused).copyWith(
            book: FriendshipBook.restore(
              profiles: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
            ),
            groups: <String, GroupProfile>{'gr': joined()},
          ),
        );
        await h.deliver(bob, <String, dynamic>{
          'type': 'group_leave',
          'groupId': 'gr',
        });
        await h.deliver(bob, message('late'), at: 5000);
        expect(h.state.groups['gr']!.memberAddresses, isNot(contains(bob)));
      },
    );
  });

  test('a call ringing out leaves other chats\' notifications alone', () async {
    final _Harness h = _Harness(
      seed: SocialHubState.empty(lifecycle: _background).copyWith(
        book: FriendshipBook.restore(
          profiles: <String, FriendProfile>{
            ada: _friend(ada, 'Ada'),
            bob: _friend(bob, 'Bob'),
          },
        ),
      ),
      extraOverrides: [
        callRingingWaitTimeoutProvider.overrideWithValue(
          const Duration(milliseconds: 60),
        ),
      ],
    );
    await h.deliver(bob, <String, dynamic>{
      'type': 'message',
      'msgId': 'from-bob',
      'text': 'Oddzwonisz?',
    });
    await h.deliver(ada, <String, dynamic>{
      'type': 'call_invite',
      'callId': 'c-1',
      'kind': 'audio',
    });
    await Future<void>.delayed(const Duration(milliseconds: 300));

    final Iterable<String> bodies = h.notifications.activeNotifications.map(
      (RuntimeSystemNotification n) => n.body,
    );
    expect(bodies, contains('Oddzwonisz?'));
    expect(
      h.notifications.activeNotifications.map(
        (RuntimeSystemNotification n) => n.title,
      ),
      contains('Nieodebrane połączenie'),
    );
  });

  group('one message id, two senders', () {
    const String id = 'grp-msg-1-g-deadbeef';
    _Harness inGroup({String creator = ''}) => _Harness(
      seed: SocialHubState.empty(lifecycle: _background).copyWith(
        book: FriendshipBook.restore(
          profiles: <String, FriendProfile>{
            ada: _friend(ada, 'Ada'),
            bob: _friend(bob, 'Bob'),
            cyd: _friend(cyd, 'Cyd'),
          },
        ),
        groups: <String, GroupProfile>{
          'g': GroupProfile(
            id: 'g',
            name: 'G',
            createdById: creator.isEmpty ? cyd : creator,
            createdAtMillis: 0,
            memberAddresses: <String>[ada, bob, cyd],
          ),
        },
      ),
    );
    Map<String, dynamic> said(String text, {String messageId = id}) =>
        <String, dynamic>{
          'type': 'group_message',
          'groupId': 'g',
          'msgId': messageId,
          'text': text,
        };
    Future<List<ChatMessage>> chat(_Harness h) async => (await h.timelines.load(
      'group:g',
    )).where((ChatMessage m) => !m.isSystem).toList();

    test('a member who sends another\'s message id first hides nothing: both '
        'messages stay, each with its sender', () async {
      final _Harness h = inGroup();
      await h.deliver(ada, said('Bob: odwołane, nie przychodźcie'), at: 1000);
      await h.deliver(bob, said('spotkanie o 18'), at: 1001);
      final List<ChatMessage> t = await chat(h);
      expect(
        t.map((ChatMessage m) => '${m.sender}: ${m.text}'),
        unorderedEquals(<String>[
          '$ada: Bob: odwołane, nie przychodźcie',
          '$bob: spotkanie o 18',
        ]),
      );
      expect(t.map((ChatMessage m) => m.id).toSet(), hasLength(2));
      expect(
        t.firstWhere((ChatMessage m) => m.sender == bob).id,
        groupMessageLocalId(id, bob),
      );
      expect(
        h.notifications.activeNotifications.map(
          (RuntimeSystemNotification n) => n.body,
        ),
        anyElement(contains('spotkanie o 18')),
      );
    });

    test('the same message again, by any way, is still one', () async {
      final _Harness h = inGroup();
      await h.deliver(ada, said('pierwsza'), at: 1000);
      await h.deliver(bob, said('druga'), at: 1001);
      final int alerts = h.notifications.audibleAlertCount;
      final int shown = h.notifications.activeNotifications.length;
      await h.deliver(bob, said('druga'), at: 1002);
      await h.deliver(ada, said('pierwsza'), at: 1003);
      expect(await chat(h), hasLength(2));
      expect(h.notifications.audibleAlertCount, alerts);
      expect(h.notifications.activeNotifications, hasLength(shown));
      // The account's other device kept them the other way round.
      await h.controller.importSyncedMessage(
        'group:g',
        ChatMessage(
          id: id,
          sender: bob,
          text: 'druga',
          sentAtMillis: 1001,
          direction: ChatMessageDirection.incoming,
        ),
      );
      await h.controller.importSyncedMessage(
        'group:g',
        ChatMessage(
          id: groupMessageLocalId(id, ada),
          sender: ada,
          text: 'pierwsza',
          sentAtMillis: 1000,
          direction: ChatMessageDirection.incoming,
        ),
      );
      final List<ChatMessage> t = await chat(h);
      expect(t, hasLength(2));
      expect(t.firstWhere((ChatMessage m) => m.sender == ada).text, 'pierwsza');
      expect(t.firstWhere((ChatMessage m) => m.sender == bob).text, 'druga');
    });

    test('an edit, a deletion of one\'s own and an id coming back reach only '
        'the sender\'s own message', () async {
      final _Harness h = inGroup();
      await h.deliver(ada, said('podróbka'), at: 1000);
      await h.deliver(bob, said('prawdziwa'), at: 1001);
      await h.deliver(bob, <String, dynamic>{
        'type': 'msg_edit',
        'groupId': 'g',
        'msgId': id,
        'text': 'prawdziwa, poprawiona',
        'at': 1002,
      }, at: 1002);
      await h.deliver(ada, <String, dynamic>{
        'type': 'msg_delete',
        'groupId': 'g',
        'msgId': id,
        'at': 1003,
      }, at: 1003);
      final List<ChatMessage> t = await chat(h);
      final ChatMessage bobs = t.firstWhere((ChatMessage m) => m.sender == bob);
      final ChatMessage adas = t.firstWhere((ChatMessage m) => m.sender == ada);
      expect(bobs.text, 'prawdziwa, poprawiona');
      expect(bobs.isDeleted, isFalse);
      expect(adas.isDeleted, isTrue);
      // A reaction to Bob's message goes out under the id everyone knows.
      h.transport.sentSignals.clear();
      await h.controller.reactToMessage(
        conversationKey: 'group:g',
        messageId: bobs.id,
        emoji: '👍',
      );
      expect(h.sentTo(bob, 'msg_react').single['msgId'], id);
    });

    Map<String, dynamic> change(
      String type, {
      String? author,
      String messageId = id,
    }) => <String, dynamic>{
      'type': type,
      'groupId': 'g',
      'msgId': messageId,
      if (type == 'msg_react') 'emoji': '👍',
      'at': 1100,
      kChangeAuthorKey: ?author,
    };
    ChatMessage of(List<ChatMessage> t, String who) =>
        t.firstWhere((ChatMessage m) => m.sender == who);

    test('a key another member\'s message took before 1.16.4 does not make '
        'the real author\'s message a copy of it', () async {
      final _Harness h = inGroup();
      final String bobsKey = groupMessageLocalId(id, bob);
      // Before 1.16.4 every id was kept as it came: Ada could send one that
      // is the key Bob's message would later need.
      await h.timelines.save('group:g', <ChatMessage>[
        ChatMessage(
          id: bobsKey,
          sender: ada,
          text: 'zajęte z góry',
          sentAtMillis: 900,
          direction: ChatMessageDirection.incoming,
        ),
      ]);
      await h.deliver(ada, said('pierwsza'), at: 1000);
      await h.deliver(bob, said('spotkanie o 18'), at: 1001);
      List<ChatMessage> t = await chat(h);
      expect(
        t.map((ChatMessage m) => '${m.sender}: ${m.text}'),
        unorderedEquals(<String>[
          '$ada: zajęte z góry',
          '$ada: pierwsza',
          '$bob: spotkanie o 18',
        ]),
      );
      expect(t.map((ChatMessage m) => m.id).toSet(), hasLength(3));
      final ChatMessage bobs = of(t, bob);
      expect(groupMessageWireId(bobs.id), id);
      // A true late copy of Bob's message is still one.
      await h.deliver(bob, said('spotkanie o 18'), at: 1002);
      await h.deliver(ada, said('pierwsza'), at: 1003);
      t = await chat(h);
      expect(t, hasLength(3));
      // A reaction naming Bob reaches his message, wherever it is kept.
      await h.deliver(cyd, change('msg_react', author: bob), at: 1004);
      t = await chat(h);
      expect(of(t, bob).reactions, <String, String>{cyd: '👍'});
      expect(
        t
            .where((ChatMessage m) => m.sender == ada)
            .expand((ChatMessage m) => m.reactions.keys),
        isEmpty,
      );
    });

    test('the creator\'s deletion names the author of its message and reaches '
        'that one, whichever holds the bare id here', () async {
      for (final bool squatFirst in <bool>[false, true]) {
        final _Harness h = inGroup();
        if (squatFirst) {
          await h.deliver(ada, said('obraźliwy tekst'), at: 1000);
          await h.deliver(bob, said('spotkanie o 18'), at: 1001);
        } else {
          await h.deliver(bob, said('spotkanie o 18'), at: 1000);
          await h.deliver(ada, said('obraźliwy tekst'), at: 1001);
        }
        await h.deliver(cyd, change('msg_delete', author: ada), at: 1002);
        final List<ChatMessage> t = await chat(h);
        expect(of(t, ada).isDeleted, isTrue, reason: 'squatFirst=$squatFirst');
        expect(of(t, bob).isDeleted, isFalse, reason: 'squatFirst=$squatFirst');
        expect(of(t, bob).text, 'spotkanie o 18');
      }
    });

    test('a deletion from Zen 1.16.4 (no author) does nothing where two '
        'members hold the id, and works where only one does', () async {
      final _Harness h = inGroup();
      await h.deliver(bob, said('spotkanie o 18'), at: 1000);
      await h.deliver(ada, said('obraźliwy tekst'), at: 1001);
      await h.deliver(cyd, change('msg_delete'), at: 1002);
      List<ChatMessage> t = await chat(h);
      expect(of(t, bob).isDeleted, isFalse);
      expect(of(t, ada).isDeleted, isFalse);
      // An id one message holds: the creator's deletion as before.
      const String alone = 'grp-msg-2-g-cafebabe';
      await h.deliver(bob, said('sam', messageId: alone), at: 1003);
      await h.deliver(cyd, change('msg_delete', messageId: alone), at: 1004);
      t = await chat(h);
      expect(t.firstWhere((ChatMessage m) => m.id == alone).isDeleted, isTrue);
      // And one's own message by its author, even where the id is shared.
      await h.deliver(ada, change('msg_delete'), at: 1005);
      t = await chat(h);
      expect(of(t, ada).isDeleted, isTrue);
      expect(of(t, bob).isDeleted, isFalse);
    });

    test('a reaction names the author of its message; one without it lands '
        'only on an id one message holds', () async {
      final _Harness h = inGroup();
      await h.deliver(ada, said('kopia'), at: 1000);
      await h.deliver(bob, said('oryginał'), at: 1001);
      // From Zen 1.16.4: two messages hold the id, so it lands on neither.
      await h.deliver(cyd, change('msg_react'), at: 1002);
      List<ChatMessage> t = await chat(h);
      expect(of(t, ada).reactions, isEmpty);
      expect(of(t, bob).reactions, isEmpty);
      await h.deliver(cyd, change('msg_react', author: bob), at: 1003);
      t = await chat(h);
      expect(of(t, bob).reactions, <String, String>{cyd: '👍'});
      expect(of(t, ada).reactions, isEmpty);
      // An author with no message of that id here: nothing.
      await h.deliver(
        ada,
        change(
          'msg_react',
          author: PeerShareCodec.normalizeAddress('200::e7e'),
        ),
        at: 1004,
      );
      t = await chat(h);
      expect(of(t, ada).reactions, isEmpty);
      expect(of(t, bob).reactions, <String, String>{cyd: '👍'});
      // An id one message holds: a reaction without an author as before.
      const String alone = 'grp-msg-2-g-cafebabe';
      await h.deliver(bob, said('sam', messageId: alone), at: 1005);
      await h.deliver(cyd, change('msg_react', messageId: alone), at: 1006);
      t = await chat(h);
      expect(
        t.firstWhere((ChatMessage m) => m.id == alone).reactions,
        <String, String>{cyd: '👍'},
      );
    });

    test('a reaction or a deletion sent from here names the author of the '
        'message', () async {
      final _Harness h = inGroup(creator: 'self');
      await h.deliver(ada, said('kopia'), at: 1000);
      await h.deliver(bob, said('oryginał'), at: 1001);
      final List<ChatMessage> t = await chat(h);
      h.transport.sentSignals.clear();
      await h.controller.reactToMessage(
        conversationKey: 'group:g',
        messageId: of(t, bob).id,
        emoji: '👍',
      );
      final Map<String, dynamic> react = h.sentTo(cyd, 'msg_react').single;
      expect(react['msgId'], id);
      expect(react[kChangeAuthorKey], bob);
      await h.controller.deleteMessageForEveryone(
        conversationKey: 'group:g',
        messageId: of(t, ada).id,
      );
      final Map<String, dynamic> delete = h.sentTo(cyd, 'msg_delete').single;
      expect(delete['msgId'], id);
      expect(delete[kChangeAuthorKey], ada);
      final List<ChatMessage> after = await chat(h);
      expect(of(after, ada).isDeleted, isTrue);
      expect(of(after, bob).isDeleted, isFalse);
    });

    test('another device of the account reacting or deleting in a group '
        'reaches the message it meant', () async {
      final _Harness h = inGroup(creator: 'self');
      await h.deliver(ada, said('kopia'), at: 1000);
      await h.deliver(bob, said('oryginał'), at: 1001);
      // From a device on 1.16.4: two messages hold the id, so neither.
      await h.controller.recordMirroredSend(ada, change('msg_react'));
      List<ChatMessage> t = await chat(h);
      expect(of(t, ada).reactions, isEmpty);
      expect(of(t, bob).reactions, isEmpty);
      await h.controller.recordMirroredSend(
        ada,
        change('msg_react', author: bob),
      );
      await h.controller.recordMirroredSend(
        bob,
        change('msg_delete', author: ada),
      );
      t = await chat(h);
      expect(of(t, bob).reactions, <String, String>{'self': '👍'});
      expect(of(t, bob).isDeleted, isFalse);
      expect(of(t, ada).reactions, isEmpty);
      expect(of(t, ada).isDeleted, isTrue);
    });

    test(
      'a reply names the message it quotes by its author: the quote '
      'shows and jumps to that one, not to whoever holds the bare id',
      () async {
        final _Harness h = inGroup();
        await h.deliver(ada, said('Bob: odwołane'), at: 1000);
        await h.deliver(bob, said('spotkanie o 18'), at: 1001);
        final String bobs = groupMessageLocalId(id, bob);
        Map<String, dynamic> reply(String replyId, Map<String, dynamic> re) =>
            <String, dynamic>{...said('ok', messageId: replyId), 're': re};
        Future<ChatReply?> quoteOf(String replyId) async => (await chat(
          h,
        )).firstWhere((ChatMessage m) => m.id == replyId).reply;

        await h.deliver(
          cyd,
          reply('r1', <String, dynamic>{'id': id, 's': bob, 't': 'spotkanie'}),
          at: 1002,
        );
        ChatReply? quote = await quoteOf('r1');
        expect(quote!.messageId, bobs);
        expect(quote.sender, bob);
        expect(quote.text, 'spotkanie');

        // Bob quoting his own message ('self' on his phone).
        await h.deliver(
          bob,
          reply('r2', <String, dynamic>{'id': id, 's': 'self'}),
          at: 1003,
        );
        quote = await quoteOf('r2');
        expect(quote!.messageId, bobs);
        expect(quote.sender, bob);

        // A replier whose phone keeps Bob's message under its second key.
        await h.deliver(
          cyd,
          reply('r3', <String, dynamic>{'id': bobs, 's': bob}),
          at: 1004,
        );
        expect((await quoteOf('r3'))!.messageId, bobs);

        // Ada's message is still hers to quote.
        await h.deliver(
          cyd,
          reply('r4', <String, dynamic>{'id': id, 's': ada}),
          at: 1005,
        );
        expect((await quoteOf('r4'))!.messageId, id);

        // An original not here yet keeps the key it will come under.
        await h.deliver(
          cyd,
          reply('r5', <String, dynamic>{'id': 'grp-msg-9-g-later', 's': bob}),
          at: 1006,
        );
        expect((await quoteOf('r5'))!.messageId, 'grp-msg-9-g-later');

        // Bob deleting his message drops the quotes of it, not of Ada's.
        await h.deliver(bob, change('msg_delete', author: bob), at: 1007);
        expect((await quoteOf('r1'))!.text, isEmpty);
        expect((await quoteOf('r4'))!.messageId, id);
      },
    );
  });

  group('snapshot', () {
    test('invite bookkeeping survives the binary snapshot', () async {
      final Directory tempDir = await Directory.systemTemp.createTemp(
        'zen-invite-snapshot-',
      );
      addTearDown(() => tempDir.delete(recursive: true));
      final FileSocialSnapshotStore store = FileSocialSnapshotStore(
        store: FileBinaryStore(
          tempDir,
          codec: BinaryCodec(compressor: const _PassThroughCompressor()),
        ),
      );
      await store.save(
        SocialHubState.empty().copyWith(
          groups: <String, GroupProfile>{
            'g': GroupProfile(
              id: 'g',
              name: 'G',
              createdById: 'self',
              createdAtMillis: 1,
              memberAddresses: <String>[bob, cyd],
              pendingInviteAddresses: <String>[cyd],
              pendingInviteIds: <String, String>{cyd: 'inv-c'},
            ),
            'h': const GroupProfile(
              id: 'h',
              name: 'H',
              createdById: 'x',
              createdAtMillis: 2,
              memberAddresses: <String>[],
              isInvitePending: true,
              receivedInviteIds: <String>['inv-h'],
            ),
          },
          rejectedGroupIds: <String>['old-1', 'old-2'],
          rejectedInviteIds: <String>['old-1|inv-9'],
        ),
      );

      final SocialHubState loaded = (await store.load())!;
      expect(loaded.groups['g']!.pendingInviteAddresses, <String>[cyd]);
      expect(loaded.groups['g']!.isInvitePending, isFalse);
      expect(loaded.groups['h']!.isInvitePending, isTrue);
      expect(loaded.rejectedGroupIds, <String>['old-1', 'old-2']);
      expect(loaded.groups['g']!.pendingInviteIds, <String, String>{
        cyd: 'inv-c',
      });
      expect(loaded.groups['h']!.receivedInviteIds, <String>['inv-h']);
      expect(loaded.rejectedInviteIds, <String>['old-1|inv-9']);
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
