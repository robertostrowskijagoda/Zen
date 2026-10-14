import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/calls/noop_call_media_session.dart';
import 'package:zen/src/features/groups/group_store.dart';
import 'package:zen/src/features/groups/presentation/create_group_sheet.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

void main() {
  group('GroupProfile & GroupStore', () {
    test('GroupProfile JSON serialization round-trips correctly', () {
      final GroupProfile group = const GroupProfile(
        id: 'grp-1',
        name: 'Gildia Zen',
        description: 'Kanał dyskusyjny',
        avatarPreset: 'group_game',
        createdById: 'self',
        createdAtMillis: 1000,
        memberAddresses: <String>['node-1.ygg', 'node-2.ygg'],
        lastMessagePreview: 'Hej wszystkim!',
        unreadCount: 3,
      );

      final Map<String, dynamic> json = group.toJson();
      final GroupProfile restored = GroupProfile.fromJson(json);

      expect(restored.id, 'grp-1');
      expect(restored.name, 'Gildia Zen');
      expect(restored.description, 'Kanał dyskusyjny');
      expect(restored.avatarPreset, 'group_game');
      expect(restored.memberCount, 2);
      expect(restored.hasMember('node-1.ygg'), isTrue);
      expect(restored.hasMember('node-3.ygg'), isFalse);
      expect(restored.unreadCount, 3);
    });

    test('MemoryGroupStore saves and loads groups map', () async {
      final MemoryGroupStore store = MemoryGroupStore();
      expect(await store.load(), isEmpty);

      final GroupProfile group = const GroupProfile(
        id: 'grp-test',
        name: 'Projekt Alpha',
        createdById: 'self',
        createdAtMillis: 2000,
        memberAddresses: <String>['ada.ygg'],
      );

      await store.save(<String, GroupProfile>{'grp-test': group});

      final Map<String, GroupProfile> loaded = await store.load();
      expect(loaded.length, 1);
      expect(loaded['grp-test']?.name, 'Projekt Alpha');
    });

    test('SocialHubState preview contains initial groups', () {
      final SocialHubState state = SocialHubState.preview();
      expect(state.groups, isNotEmpty);
      expect(state.groupList.first.name, 'Projekt Zen');
    });

    testWidgets(
      'CreateGroupSheet displays friend name without address, and no icon/topic picker',
      (WidgetTester tester) async {
        const FriendProfile friend = FriendProfile(
          address: '200:1111:2222:3333:4444:5555:6666:7777',
          displayName: 'Alice Secret',
          status: FriendRelationshipStatus.accepted,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              socialHubSeedProvider.overrideWithValue(
                SocialHubState.empty().copyWith(
                  friends: <String, FriendProfile>{friend.address: friend},
                ),
              ),
            ],
            child: const MaterialApp(home: Scaffold(body: CreateGroupSheet())),
          ),
        );
        await tester.pumpAndSettle();

        // Verify name input is present
        expect(
          find.byKey(const Key('create-group-name-field')),
          findsOneWidget,
        );

        // Verify icon picker & description/theme fields are NOT present
        expect(find.text('IKONA GRUPY'), findsNothing);
        expect(find.text('OPIS / TEMAT (OPCJONALNIE)'), findsNothing);

        // Verify friend displayLabel is shown, but address is NEVER shown
        expect(find.text('Alice Secret'), findsOneWidget);
        expect(
          find.text('200:1111:2222:3333:4444:5555:6666:7777'),
          findsNothing,
        );
        expect(find.textContaining('200:1111'), findsNothing);
      },
    );

    testWidgets('AppShell shows Grupy section header when groups are present', (
      WidgetTester tester,
    ) async {
      const GroupProfile group = GroupProfile(
        id: 'grp-1',
        name: 'Gildia Zen',
        createdById: 'self',
        createdAtMillis: 1000,
        memberAddresses: <String>['node-1.ygg'],
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                groups: <String, GroupProfile>{group.id: group},
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('GRUPY'), findsOneWidget);
      expect(find.text('Gildia Zen'), findsOneWidget);
    });

    testWidgets('an invitation is only an inbox card: no group, no screen', (
      WidgetTester tester,
    ) async {
      const String groupId = 'grp-123';
      const String groupName = 'Super Ekipa';
      const GroupProfile group = GroupProfile(
        id: groupId,
        name: groupName,
        createdById: 'peer-alice',
        createdAtMillis: 1000,
        memberAddresses: <String>['peer-alice'],
        isInvitePending: true,
      );
      final InboxEntry inviteEntry = InboxEntry(
        id: 'invite-1',
        type: InboxEntryType.groupInvite,
        title: 'Zaproszenie do grupy: $groupName',
        body: 'Alice zaprasza Cię do grupy.',
        createdAtMillis: 1000,
        routeKey: buildGroupRouteKey(groupId: groupId, title: groupName),
        peerAddress: 'peer-alice',
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                groups: <String, GroupProfile>{groupId: group},
                inbox: <InboxEntry>[inviteEntry],
              ),
            ),
          ],
          child: const ZenRewriteApp(),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Zaproszenie do grupy: $groupName'), findsOneWidget);
      expect(find.byKey(const Key('inbox-card-invite-1')), findsOneWidget);
      expect(find.byKey(const Key('inbox-accept-invite-1')), findsOneWidget);
      expect(find.byKey(const Key('inbox-reject-invite-1')), findsOneWidget);

      // Not a group of the user's yet: not in the list.
      expect(find.text('GRUPY'), findsNothing);

      // Tapping the card itself leads nowhere.
      await tester.tap(find.byKey(const Key('inbox-card-invite-1')));
      await tester.pumpAndSettle();
      expect(find.byType(GroupConversationScreen), findsNothing);
    });

    testWidgets(
      'Dołącz joins in place: the group shows up, no screen is pushed',
      (WidgetTester tester) async {
        const String groupId = 'grp-123';
        const String groupName = 'Super Ekipa';
        const GroupProfile group = GroupProfile(
          id: groupId,
          name: groupName,
          createdById: 'peer-alice',
          createdAtMillis: 1000,
          memberAddresses: <String>['peer-alice'],
          isInvitePending: true,
        );
        final InboxEntry inviteEntry = InboxEntry(
          id: 'invite-2',
          type: InboxEntryType.groupInvite,
          title: 'Zaproszenie do grupy: $groupName',
          body: 'Alice zaprasza Cię do grupy.',
          createdAtMillis: 1000,
          routeKey: buildGroupRouteKey(groupId: groupId, title: groupName),
          peerAddress: 'peer-alice',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              socialHubAutoHydrateProvider.overrideWithValue(false),
              socialHubSeedProvider.overrideWithValue(
                SocialHubState.empty().copyWith(
                  groups: <String, GroupProfile>{groupId: group},
                  inbox: <InboxEntry>[inviteEntry],
                ),
              ),
            ],
            child: const ZenRewriteApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Tap Dołącz button
        await tester.tap(find.byKey(const Key('inbox-accept-invite-2')));
        await tester.pumpAndSettle();

        expect(find.byType(GroupConversationScreen), findsNothing);
        expect(find.byKey(const Key('inbox-card-invite-2')), findsNothing);
        expect(find.text('GRUPY'), findsOneWidget);
        expect(find.text(groupName), findsWidgets);
        expect(find.textContaining('Dołączono do grupy „'), findsOneWidget);
      },
    );

    testWidgets(
      'Tapping Odrzuć on group invite card rejects group and dismisses invite',
      (WidgetTester tester) async {
        const String groupId = 'grp-123';
        const String groupName = 'Super Ekipa';
        const GroupProfile group = GroupProfile(
          id: groupId,
          name: groupName,
          createdById: 'peer-alice',
          createdAtMillis: 1000,
          memberAddresses: <String>['peer-alice'],
        );
        final InboxEntry inviteEntry = InboxEntry(
          id: 'invite-3',
          type: InboxEntryType.groupInvite,
          title: 'Zaproszenie do grupy: $groupName',
          body: 'Alice zaprasza Cię do grupy.',
          createdAtMillis: 1000,
          routeKey: buildGroupRouteKey(groupId: groupId, title: groupName),
          peerAddress: 'peer-alice',
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              socialHubAutoHydrateProvider.overrideWithValue(false),
              socialHubSeedProvider.overrideWithValue(
                SocialHubState.empty().copyWith(
                  groups: <String, GroupProfile>{groupId: group},
                  inbox: <InboxEntry>[inviteEntry],
                ),
              ),
            ],
            child: const ZenRewriteApp(),
          ),
        );
        await tester.pumpAndSettle();

        // Tap Odrzuć button
        await tester.tap(find.byKey(const Key('inbox-reject-invite-3')));
        await tester.pumpAndSettle();

        // Invite is gone
        expect(find.byKey(const Key('inbox-card-invite-3')), findsNothing);
        expect(find.byType(GroupConversationScreen), findsNothing);
      },
    );

    testWidgets(
      'a pending group opens read-only with a join banner, and joining '
      'unlocks the composer',
      (WidgetTester tester) async {
        const GroupProfile group = GroupProfile(
          id: 'grp-pending',
          name: 'Nowa ekipa',
          createdById: 'peer-alice',
          createdAtMillis: 1000,
          memberAddresses: <String>['peer-alice'],
          isInvitePending: true,
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              socialHubAutoHydrateProvider.overrideWithValue(false),
              socialHubSeedProvider.overrideWithValue(
                SocialHubState.empty().copyWith(
                  groups: <String, GroupProfile>{group.id: group},
                ),
              ),
            ],
            child: const MaterialApp(
              home: GroupConversationScreen(
                groupId: 'grp-pending',
                groupName: 'Nowa ekipa',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('group-invite-banner')), findsOneWidget);
        expect(
          find.byKey(const Key('group-chat-composer-field')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('group-chat-readonly-note')),
          findsOneWidget,
        );

        await tester.tap(find.byKey(const Key('group-invite-join')));
        await tester.pumpAndSettle();

        expect(find.byKey(const Key('group-invite-banner')), findsNothing);
        expect(
          find.byKey(const Key('group-chat-composer-field')),
          findsOneWidget,
        );
      },
    );

    testWidgets('leaving a group asks for confirmation first', (
      WidgetTester tester,
    ) async {
      const GroupProfile group = GroupProfile(
        id: 'grp-leave',
        name: 'Ekipa',
        createdById: 'self',
        createdAtMillis: 1000,
        memberAddresses: <String>['peer-alice'],
      );
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                groups: <String, GroupProfile>{group.id: group},
              ),
            ),
          ],
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(
                home: GroupConversationScreen(
                  groupId: 'grp-leave',
                  groupName: 'Ekipa',
                ),
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opuść grupę'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Anuluj'));
      await tester.pumpAndSettle();
      expect(
        container.read(socialHubControllerProvider).groups,
        contains('grp-leave'),
      );

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opuść grupę'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('group-leave-confirm')));
      await tester.pumpAndSettle();
      expect(
        container.read(socialHubControllerProvider).groups,
        isNot(contains('grp-leave')),
      );
    });

    test(
      'groupInvite is allowed from non-friend peer and appears in inbox',
      () async {
        final ProviderContainer container = ProviderContainer(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          ],
        );
        addTearDown(container.dispose);

        final SocialHubController controller = container.read(
          socialHubControllerProvider.notifier,
        );

        // Peer 'stranger.ygg' is not in friends list
        expect(container.read(socialHubControllerProvider).friends, isEmpty);

        const ZenSignal invite = ZenSignal(
          type: ZenSignalType.groupInvite,
          sender: 'stranger.ygg',
          groupId: 'grp-public',
          groupName: 'Nowa Grupa',
          content: 'Zapraszamy',
          memberAddresses: <String>['stranger.ygg'],
        );

        await controller.receiveSignal(invite, receivedAtMillis: 1000);

        final SocialHubState state = container.read(
          socialHubControllerProvider,
        );
        // Group was created and invite was placed into inbox
        expect(state.groups.containsKey('grp-public'), isTrue);
        expect(state.groups['grp-public']?.name, 'Nowa Grupa');
        expect(state.inbox.length, 1);
        expect(state.inbox.first.type, InboxEntryType.groupInvite);

        // Resending the invite should NOT duplicate the inbox entry
        await controller.receiveSignal(invite, receivedAtMillis: 2000);
        final SocialHubState stateAfterResend = container.read(
          socialHubControllerProvider,
        );
        expect(stateAfterResend.inbox.length, 1);
      },
    );

    test(
      'rejected group invite is not re-added on subsequent signals',
      () async {
        final ProviderContainer container = ProviderContainer(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
          ],
        );
        addTearDown(container.dispose);

        final SocialHubController controller = container.read(
          socialHubControllerProvider.notifier,
        );

        const ZenSignal invite = ZenSignal(
          type: ZenSignalType.groupInvite,
          sender: 'alice.ygg',
          groupId: 'grp-reject-test',
          groupName: 'Odrzucana Grupa',
          memberAddresses: <String>['alice.ygg'],
        );

        await controller.receiveSignal(invite, receivedAtMillis: 1000);
        expect(container.read(socialHubControllerProvider).inbox.length, 1);

        final String inboxId = container
            .read(socialHubControllerProvider)
            .inbox
            .first
            .id;
        await controller.rejectGroupInvite(
          groupId: 'grp-reject-test',
          inboxEntryId: inboxId,
          senderAddress: 'alice.ygg',
        );

        expect(container.read(socialHubControllerProvider).inbox, isEmpty);
        expect(
          container
              .read(socialHubControllerProvider)
              .groups
              .containsKey('grp-reject-test'),
          isFalse,
        );

        // Repeat signal arrives (e.g. from network or peer)
        await controller.receiveSignal(invite, receivedAtMillis: 2000);

        // It must be rejected and NOT appear in inbox or groups
        expect(container.read(socialHubControllerProvider).inbox, isEmpty);
        expect(
          container
              .read(socialHubControllerProvider)
              .groups
              .containsKey('grp-reject-test'),
          isFalse,
        );
      },
    );

    test(
      'existing group member ignores repeat group invite and does not add to inbox',
      () async {
        final ProviderContainer container = ProviderContainer(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                groups: <String, GroupProfile>{
                  'grp-already-joined': const GroupProfile(
                    id: 'grp-already-joined',
                    name: 'Grupa Istniejąca',
                    createdById: 'alice.ygg',
                    createdAtMillis: 1000,
                    memberAddresses: <String>['alice.ygg', 'self.ygg'],
                  ),
                },
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final SocialHubController controller = container.read(
          socialHubControllerProvider.notifier,
        );

        const ZenSignal invite = ZenSignal(
          type: ZenSignalType.groupInvite,
          sender: 'alice.ygg',
          groupId: 'grp-already-joined',
          groupName: 'Grupa Istniejąca',
          memberAddresses: <String>['alice.ygg', 'self.ygg'],
        );

        await controller.receiveSignal(invite, receivedAtMillis: 2000);

        // Must NOT appear in inbox because group is already joined
        expect(container.read(socialHubControllerProvider).inbox, isEmpty);
      },
    );

    test(
      'startGroupCall sets activeCall as group call and broadcasts to members',
      () async {
        final ProviderContainer container = ProviderContainer(
          overrides: [
            callMediaSessionControllerProvider.overrideWithValue(
              NoopCallMediaSessionController(),
            ),
            groupCallMediaProvider.overrideWithValue(FakeGroupCallMedia()),
            groupCallReRingIntervalProvider.overrideWithValue(Duration.zero),
            groupCallHeartbeatIntervalProvider.overrideWithValue(Duration.zero),
            socialHubAutoHydrateProvider.overrideWithValue(false),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                groups: <String, GroupProfile>{
                  'grp-call-test': const GroupProfile(
                    id: 'grp-call-test',
                    name: 'Grupa Połączenie',
                    createdById: 'self.ygg',
                    createdAtMillis: 1000,
                    memberAddresses: <String>['self.ygg', 'bob.ygg'],
                  ),
                },
              ),
            ),
          ],
        );
        addTearDown(container.dispose);

        final SocialHubController controller = container.read(
          socialHubControllerProvider.notifier,
        );

        await controller.startGroupCall(
          groupId: 'grp-call-test',
          kind: CallInviteKind.video,
        );

        final CallSession? activeCall = container
            .read(socialHubControllerProvider)
            .activeCall;
        expect(activeCall, isNotNull);
        expect(activeCall!.isGroup, isTrue);
        expect(activeCall.groupId, 'grp-call-test');
        expect(activeCall.displayName, 'Grupa Połączenie');
        // The caller is in the room at once; nobody else is yet.
        expect(activeCall.status, CallSessionStatus.active);
        expect(activeCall.participantAddresses, isEmpty);
      },
    );
  });
}
