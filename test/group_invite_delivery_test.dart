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
import 'package:zen/src/features/runtime/runtime_signal_parser.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
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
        // These tests check what notifications say; hiding the text (on by
        // default, §14.1) has its own test.
        ...buildAppSettingsProviderOverrides(
          store: MemoryAppSettingsStore(),
          initialState: AppSettings(hideNotificationContent: hideContent),
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
                friends: <String, FriendProfile>{
                  ada: _friend(ada, 'Ada'),
                  bob: _friend(bob, 'Bob'),
                  cyd: _friend(cyd, 'Cyd'),
                },
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
      expect(invite['memberAddresses'], containsAll(<String>[bob, cyd]));

      await h.deliver(bob, <String, dynamic>{
        'type': 'group_invite_ack',
        'groupId': group.id,
      });
      expect(h.state.groups[group.id]!.pendingInviteAddresses, <String>[cyd]);
    });

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
      expect(
        h.state.inbox.where(
          (InboxEntry e) => e.type == InboxEntryType.groupInvite,
        ),
        isEmpty,
        reason: 'joining clears the invite card',
      );
    });

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
            friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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

    test('someone leaving is a timeline note, not a notification', () async {
      final _Harness h = _Harness(
        seed: SocialHubState.empty(lifecycle: _background).copyWith(
          friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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
        seed: SocialHubState.empty(
          lifecycle: _background,
        ).copyWith(friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')}),
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
          friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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
        seed: SocialHubState.empty(
          lifecycle: _background,
        ).copyWith(friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')}),
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
        seed: SocialHubState.empty(
          lifecycle: _visibleUnfocused,
        ).copyWith(friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')}),
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
            friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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
        seed: SocialHubState.empty(
          lifecycle: _background,
        ).copyWith(friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')}),
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
        seed: SocialHubState.empty(
          lifecycle: lifecycle,
        ).copyWith(friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')}),
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
          friends: <String, FriendProfile>{
            ada: _friend(ada, 'Ada'),
            bob: _friend(bob, 'Bob'),
          },
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
          friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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
            friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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
            friends: <String, FriendProfile>{
              ada: _friend(ada, 'Ada'),
              cyd: _friend(cyd, 'Cyd'),
            },
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
            friends: <String, FriendProfile>{ada: _friend(ada, 'Ada')},
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
        friends: <String, FriendProfile>{
          ada: _friend(ada, 'Ada'),
          bob: _friend(bob, 'Bob'),
        },
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
