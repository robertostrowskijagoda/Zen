import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/calls/ongoing_group_call.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/features/calls/group_call_media.dart';
import 'package:zen/src/features/groups/presentation/group_call_screen.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

const String _groupId = 'grp-ui';
const String _bob = '200::B2';
const String _cyd = '200::C3';

const GroupProfile _group = GroupProfile(
  id: _groupId,
  name: 'Ekipa',
  createdById: _bob,
  createdAtMillis: 0,
  memberAddresses: <String>[_bob, _cyd],
  memberNames: <String, String>{_bob: 'Bartek', _cyd: 'Celina'},
);

void main() {
  testWidgets('a running call shows in the group chat and can be joined', (
    WidgetTester tester,
  ) async {
    final FakeGroupCallMedia media = FakeGroupCallMedia();
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          socialHubAutoHydrateProvider.overrideWithValue(false),
          groupCallMediaProvider.overrideWithValue(media),
          groupCallHeartbeatIntervalProvider.overrideWithValue(Duration.zero),
          groupCallReRingIntervalProvider.overrideWithValue(Duration.zero),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              groups: <String, GroupProfile>{_groupId: _group},
              groupCalls: <String, OngoingGroupCall>{
                _groupId: OngoingGroupCall(
                  groupId: _groupId,
                  callId: 'gcall-1-a',
                  kind: CallInviteKind.audio,
                  startedAtMillis: 0,
                  participants: <String, int>{
                    _bob: DateTime.now().millisecondsSinceEpoch,
                  },
                ),
              },
            ),
          ),
        ],
        child: Consumer(
          builder: (BuildContext context, WidgetRef ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(
              home: GroupConversationScreen(
                groupId: _groupId,
                groupName: 'Ekipa',
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byKey(const Key('group-running-call-banner')), findsOneWidget);
    expect(find.text('Trwa połączenie grupowe · 1 os.'), findsOneWidget);
    expect(find.text('Dołącz'), findsOneWidget);

    await tester.tap(find.byKey(const Key('group-running-call-action')));
    await tester.pump(const Duration(milliseconds: 300));

    final CallSession? call = container
        .read(socialHubControllerProvider)
        .activeCall;
    expect(call?.status, CallSessionStatus.active);
    expect(call?.id, 'gcall-1-a');
    expect(media.startCount, 1);
    expect(find.text('Jesteś w połączeniu grupowym'), findsOneWidget);
    expect(find.text('Wróć'), findsOneWidget);
  });

  testWidgets(
    'the call screen shows everyone in the room and leaves on hang-up',
    (WidgetTester tester) async {
      final FakeGroupCallMedia media = FakeGroupCallMedia();
      late ProviderContainer container;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            socialHubAutoHydrateProvider.overrideWithValue(false),
            groupCallMediaProvider.overrideWithValue(media),
            groupCallHeartbeatIntervalProvider.overrideWithValue(Duration.zero),
            groupCallReRingIntervalProvider.overrideWithValue(Duration.zero),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty().copyWith(
                groups: <String, GroupProfile>{_groupId: _group},
                activeCall: CallSession(
                  id: 'gcall-1-a',
                  peerAddress: _groupId,
                  displayName: 'Ekipa',
                  kind: CallInviteKind.audio,
                  status: CallSessionStatus.active,
                  startedAtMillis: DateTime.now().millisecondsSinceEpoch,
                  isGroup: true,
                  groupId: _groupId,
                  participantAddresses: const <String>[_bob, _cyd],
                ),
              ),
            ),
          ],
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              container = ProviderScope.containerOf(context);
              return const MaterialApp(
                home: GroupCallScreen(groupId: _groupId, groupName: 'Ekipa'),
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        container.read(socialHubControllerProvider).activeCall?.status,
        CallSessionStatus.active,
      );

      expect(find.byKey(const Key('group-call-tile-self')), findsOneWidget);
      expect(find.byKey(const Key('group-call-tile-$_bob')), findsOneWidget);
      expect(find.byKey(const Key('group-call-tile-$_cyd')), findsOneWidget);
      expect(find.text('W rozmowie: 3 os.'), findsOneWidget);
      // Non-friends are named by what they call themselves.
      expect(find.text('Bartek'), findsWidgets);
      // No media leg yet: shown as connecting, not as a broken tile.
      expect(find.text('Łączenie…'), findsNWidgets(2));

      await tester.tap(find.byKey(const Key('group-call-leave')));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));

      expect(container.read(socialHubControllerProvider).activeCall, isNull);
      expect(find.byKey(const Key('group-call-tile-self')), findsNothing);
    },
  );
}
