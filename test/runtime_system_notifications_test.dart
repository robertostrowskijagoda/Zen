import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/zen_signal.dart';
import 'package:zen/src/features/runtime/runtime_route_intent.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  test(
    'background signals are mirrored into the system notification service',
    () async {
      final MemoryRuntimeSystemNotificationService service =
          MemoryRuntimeSystemNotificationService();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          ...buildAppSettingsProviderOverrides(
            store: MemoryAppSettingsStore(),
            initialState: const AppSettings(),
            hydrationEnabled: false,
          ),
          runtimeSystemNotificationServiceProvider.overrideWithValue(service),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          // Ada was invited from here: her accept completes it (an accept
          // nobody asked for would only be a request).
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.pendingOutgoing,
                ),
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: 'ada.ygg',
              displayName: 'Ada',
            ),
            receivedAtMillis: 77,
          );

      expect(service.activeNotifications, hasLength(1));
      expect(
        service.activeNotifications.single.title,
        'Ada zaakceptował(a) zaproszenie',
      );

      final String id = container
          .read(socialHubControllerProvider)
          .backgroundAlerts
          .single
          .id;
      await container
          .read(socialHubControllerProvider.notifier)
          .dismissBackgroundAlert(id);

      expect(service.activeNotifications, isEmpty);
    },
  );

  testWidgets('system notification taps queue the matching launch route', (
    WidgetTester tester,
  ) async {
    final MemoryRuntimeSystemNotificationService service =
        MemoryRuntimeSystemNotificationService();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          runtimeSystemNotificationServiceProvider.overrideWithValue(service),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          socialHubSeedProvider.overrideWithValue(SocialHubState.empty()),
        ],
        child: const MaterialApp(
          home: RuntimeSystemNotificationsBridge(child: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();

    expect(service.isInitialized, isTrue);

    await service.show(
      const RuntimeSystemNotification(
        id: 'alert-1',
        title: 'Nowa wiadomość',
        body: 'Ada napisala.',
        createdAtMillis: 1,
        routeKey: 'zen://inbox',
        category: RuntimeSystemNotificationCategory.message,
      ),
    );
    await service.simulateTap('alert-1');
    await tester.pump();

    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(RuntimeSystemNotificationsBridge)),
    );
    final RuntimeRouteIntent? intent = container
        .read(socialHubControllerProvider)
        .pendingLaunchIntent;
    expect(intent?.target, RuntimeRouteTarget.inbox);
  });

  testWidgets(
    'focused lifecycle transition clears active system notifications',
    (WidgetTester tester) async {
      final MemoryRuntimeSystemNotificationService service =
          MemoryRuntimeSystemNotificationService();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            runtimeSystemNotificationServiceProvider.overrideWithValue(service),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty(
                lifecycle: const LifecycleSnapshot(
                  visibility: AppVisibilityState.foreground,
                  generation: 1,
                  capturedAtMillis: 0,
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            home: RuntimeSystemNotificationsBridge(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();

      await service.show(
        const RuntimeSystemNotification(
          id: 'alert-2',
          title: 'Nowa wiadomość',
          body: 'Ada napisala.',
          createdAtMillis: 2,
          category: RuntimeSystemNotificationCategory.message,
        ),
      );
      expect(service.activeNotifications, hasLength(1));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(RuntimeSystemNotificationsBridge)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .setLifecycle(
            const LifecycleSnapshot(
              visibility: AppVisibilityState.foregroundFocused,
              generation: 2,
              capturedAtMillis: 3,
            ),
          );
      await tester.pump();
      await tester.pump();

      expect(service.activeNotifications, isEmpty);
    },
  );

  test('a re-ringed call keeps the notification already on screen', () async {
    final MemoryRuntimeSystemNotificationService service =
        MemoryRuntimeSystemNotificationService();

    expect(
      await service.show(
        const RuntimeSystemNotification(
          id: 'call-1',
          title: 'Połączenie od Ada',
          body: 'Ada dzwoni.',
          createdAtMillis: 1000,
          routeKey: 'zen://call/ada.ygg',
          slotKey: 'call:ada.ygg',
          category: RuntimeSystemNotificationCategory.call,
          isRingingCall: true,
        ),
      ),
      isTrue,
    );
    // The caller re-sends its invite once per second; re-posting the very same
    // entry would re-fire the ringtone and swap out the buttons under the
    // user's finger.
    expect(
      await service.show(
        const RuntimeSystemNotification(
          id: 'call-2',
          title: 'Połączenie od Ada',
          body: 'Ada dzwoni.',
          createdAtMillis: 2000,
          routeKey: 'zen://call/ada.ygg',
          slotKey: 'call:ada.ygg',
          category: RuntimeSystemNotificationCategory.call,
          isRingingCall: true,
        ),
      ),
      isTrue,
    );

    expect(service.activeNotifications, hasLength(1));
    expect(service.activeNotifications.single.id, 'call-1');

    // The missed-call follow-up is not a ringing entry, so it still replaces
    // the ring in the same slot.
    await service.show(
      const RuntimeSystemNotification(
        id: 'call-missed',
        title: 'Nieodebrane połączenie',
        body: 'Ada dzwonila.',
        createdAtMillis: 3000,
        slotKey: 'call:ada.ygg',
        category: RuntimeSystemNotificationCategory.call,
      ),
    );
    expect(service.activeNotifications.single.id, 'call-missed');
  });

  test('dismissing the call slot forgets its suppression window', () async {
    final MemoryRuntimeSystemNotificationService service =
        MemoryRuntimeSystemNotificationService();

    expect(
      await service.show(
        const RuntimeSystemNotification(
          id: 'call-offer-1',
          title: 'Połączenie od Ada',
          body: 'Ada dzwoni.',
          createdAtMillis: 1000,
          slotKey: 'call:ada.ygg',
          suppressionKey: 'call:ada.ygg',
          category: RuntimeSystemNotificationCategory.call,
          isRingingCall: true,
        ),
      ),
      isTrue,
    );
    await service.dismissSlot('call:ada.ygg');

    // The next call from the same peer lands inside the suppression window and
    // must still ring.
    expect(
      await service.show(
        const RuntimeSystemNotification(
          id: 'call-offer-2',
          title: 'Połączenie od Ada',
          body: 'Ada dzwoni.',
          createdAtMillis: 1200,
          slotKey: 'call:ada.ygg',
          suppressionKey: 'call:ada.ygg',
          category: RuntimeSystemNotificationCategory.call,
          isRingingCall: true,
        ),
      ),
      isTrue,
    );
    expect(service.activeNotifications.single.id, 'call-offer-2');
  });

  test(
    'message notification suppression window skips duplicates until cleared',
    () async {
      final MemoryRuntimeSystemNotificationService service =
          MemoryRuntimeSystemNotificationService();

      expect(
        await service.show(
          const RuntimeSystemNotification(
            id: 'alert-1',
            title: 'Nowa wiadomość',
            body: 'Pierwsza',
            createdAtMillis: 1000,
            category: RuntimeSystemNotificationCategory.message,
            suppressionKey: 'ada.ygg|msg-1',
          ),
        ),
        isTrue,
      );
      expect(
        await service.show(
          const RuntimeSystemNotification(
            id: 'alert-2',
            title: 'Nowa wiadomość',
            body: 'Duplikat',
            createdAtMillis: 1500,
            category: RuntimeSystemNotificationCategory.message,
            suppressionKey: 'ada.ygg|msg-1',
          ),
        ),
        isFalse,
      );
      expect(service.activeNotifications, hasLength(1));
      expect(service.activeNotifications.single.id, 'alert-1');

      await service.clear();

      expect(
        await service.show(
          const RuntimeSystemNotification(
            id: 'alert-3',
            title: 'Nowa wiadomość',
            body: 'Po wyczyszczeniu',
            createdAtMillis: 2000,
            category: RuntimeSystemNotificationCategory.message,
            suppressionKey: 'ada.ygg|msg-1',
          ),
        ),
        isTrue,
      );
      expect(service.activeNotifications.single.id, 'alert-3');
    },
  );

  test(
    'incoming messages with different message IDs from the same sender are not suppressed in background',
    () async {
      final MemoryRuntimeSystemNotificationService service =
          MemoryRuntimeSystemNotificationService();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          ...buildAppSettingsProviderOverrides(
            store: MemoryAppSettingsStore(),
            initialState: const AppSettings(),
            hydrationEnabled: false,
          ),
          runtimeSystemNotificationServiceProvider.overrideWithValue(service),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(),
          ),
          // Ada was invited from here: her accept completes it (an accept
          // nobody asked for would only be a request).
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ).copyWith(
              friends: const <String, FriendProfile>{
                'ada.ygg': FriendProfile(
                  address: 'ada.ygg',
                  displayName: 'Ada',
                  status: FriendRelationshipStatus.pendingOutgoing,
                ),
              },
            ),
          ),
        ],
      );
      addTearDown(container.dispose);

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.friendAccept,
              sender: 'ada.ygg',
              displayName: 'Ada',
            ),
            receivedAtMillis: 100,
          );

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.message,
              sender: 'ada.ygg',
              messageId: 'msg-1',
              content: 'Hej!',
            ),
            receivedAtMillis: 200,
          );

      await container
          .read(socialHubControllerProvider.notifier)
          .receiveSignal(
            const ZenSignal(
              type: ZenSignalType.message,
              sender: 'ada.ygg',
              messageId: 'msg-2',
              content: 'Jak tam?',
            ),
            receivedAtMillis: 205,
          );

      expect(
        service.activeNotifications.any((n) => n.body.contains('Jak tam?')),
        isTrue,
      );
    },
  );
}
