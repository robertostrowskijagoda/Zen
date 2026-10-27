import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_route_bridge.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

// Where a tap on a notification leads: the conversation the message is in,
// and for the locked service's notices (which cannot say from whom) the
// chats list - never whatever screen the app happened to be left on.

/// Ada's address as the friends list keeps it, and spelled out in full.
final String _ada = PeerShareCodec.normalizeAddress(
  '0200:0000:0000:0000:0000:0000:0000:00ad',
);
const String _adaLong = '0200:0000:0000:0000:0000:0000:0000:00AD';

SocialHubState _seed(LifecycleSnapshot lifecycle) =>
    SocialHubState.empty(lifecycle: lifecycle).copyWith(
      friends: <String, FriendProfile>{
        _ada: FriendProfile(
          address: _ada,
          displayName: 'Ada',
          status: FriendRelationshipStatus.accepted,
        ),
      },
    );

List _overrides({
  required LifecycleSnapshot lifecycle,
  RuntimeSystemNotificationService? notices,
}) => [
  ...buildAppSettingsProviderOverrides(
    store: MemoryAppSettingsStore(),
    initialState: const AppSettings(hideNotificationContent: false),
    hydrationEnabled: false,
  ),
  signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
  socialSnapshotStoreProvider.overrideWithValue(MemorySocialSnapshotStore()),
  messageTimelineStoreProvider.overrideWithValue(MemoryMessageTimelineStore()),
  runtimeSystemNotificationServiceProvider.overrideWithValue(
    notices ?? MemoryRuntimeSystemNotificationService(),
  ),
  socialHubSeedProvider.overrideWithValue(_seed(lifecycle)),
];

const LifecycleSnapshot _background = LifecycleSnapshot(
  visibility: AppVisibilityState.background,
  generation: 1,
  capturedAtMillis: 0,
);

const LifecycleSnapshot _focused = LifecycleSnapshot(
  visibility: AppVisibilityState.foregroundFocused,
  generation: 1,
  capturedAtMillis: 0,
);

void main() {
  test('a message notification leads to the conversation it came in, kept '
      'under the friend\'s own address', () async {
    final MemoryRuntimeSystemNotificationService notices =
        MemoryRuntimeSystemNotificationService();
    final ProviderContainer container = ProviderContainer(
      overrides: [..._overrides(lifecycle: _background, notices: notices)],
    );
    addTearDown(container.dispose);
    await container
        .read(socialHubControllerProvider.notifier)
        .receiveSignal(
          ZenSignal(
            type: ZenSignalType.message,
            sender: _ada,
            displayName: 'Ada',
            messageId: 'm-1',
            content: 'Hej',
          ),
          receivedAtMillis: 1000,
        );

    final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
      id: 'tap',
      routeKey: notices.activeNotifications.single.routeKey,
    );
    expect(intent?.target, RuntimeRouteTarget.conversation);
    final ({String address, String title}) chat = runtimeRouteConversationOf(
      intent!.peerAddress!,
      container.read(socialHubControllerProvider),
    );
    expect(chat.address, _ada);
    expect(chat.title, 'Ada');
  });

  test('a route spelling the friend\'s address another way opens the same '
      'chat; a stranger gets the share code, never the link\'s title', () {
    final SocialHubState state = _seed(_focused);
    final ({String address, String title}) friend = runtimeRouteConversationOf(
      _adaLong,
      state,
    );
    expect(friend.address, _ada);
    expect(friend.title, 'Ada');

    final RuntimeRouteIntent link = runtimeRouteIntentFromRouteKey(
      id: 'link',
      routeKey: buildConversationRouteKey(
        peerAddress: '200::beef',
        title: 'Bank',
      ),
    )!;
    final ({String address, String title}) stranger =
        runtimeRouteConversationOf(link.peerAddress!, state);
    expect(stranger.address, PeerShareCodec.normalizeAddress('200::beef'));
    expect(stranger.title, isNot('Bank'));
  });

  group('the chats list', () {
    Future<ProviderContainer> pumpApp(
      WidgetTester tester,
      GlobalKey<NavigatorState> navigator,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [..._overrides(lifecycle: _focused)],
          child: MaterialApp(
            navigatorKey: navigator,
            home: const RuntimeRouteBridge(child: Text('Czaty')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(
        tester.element(find.byType(RuntimeRouteBridge)),
      );
    }

    Future<void> tap(
      WidgetTester tester,
      ProviderContainer container,
      String routeKey,
    ) async {
      await tester.runAsync(
        () => container
            .read(socialHubControllerProvider.notifier)
            .requestLaunchFromRouteKey(routeKey),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
    }

    testWidgets('a locked notice ("Nowa wiadomość") brings the chats list '
        'back from the screen the app was left on', (
      WidgetTester tester,
    ) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      final ProviderContainer container = await pumpApp(tester, navigator);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                const Scaffold(body: Text('Pusty ekran')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Pusty ekran'), findsOneWidget);

      // The route the locked service's notices carry.
      await tap(tester, container, buildInboxRouteKey());

      expect(find.text('Pusty ekran'), findsNothing);
      expect(find.text('Czaty'), findsOneWidget);
      expect(
        container.read(socialHubControllerProvider).pendingLaunchIntent,
        isNull,
      );
    });

    testWidgets('a group this phone does not have (left, or not joined yet) '
        'leads to the chats list too', (WidgetTester tester) async {
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      final ProviderContainer container = await pumpApp(tester, navigator);
      unawaited(
        navigator.currentState!.push(
          MaterialPageRoute<void>(
            builder: (BuildContext context) =>
                const Scaffold(body: Text('Pusty ekran')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tap(
        tester,
        container,
        buildGroupRouteKey(groupId: 'grp-gone', title: 'Ekipa'),
      );

      expect(find.text('Pusty ekran'), findsNothing);
      expect(find.text('Czaty'), findsOneWidget);
    });
  });
}
