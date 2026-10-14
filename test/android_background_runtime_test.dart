import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/calls/call_media_session.dart';
import 'package:zen/src/features/calls/noop_call_media_session.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/runtime_lifecycle_bridge.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_crypto.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  test(
    'headless background coordinator routes transport frames into background notifications',
    () async {
      final MemorySignalTransport transport = MemorySignalTransport();
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();
      final NoopCallMediaSessionController callMedia =
          NoopCallMediaSessionController();
      final SocialHubState persistedState =
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
                status: FriendRelationshipStatus.accepted,
              ),
            },
          );
      final ProviderContainer container = ProviderContainer(
        overrides: [
          signalTransportProvider.overrideWithValue(transport),
          runtimeSystemNotificationServiceProvider.overrideWithValue(
            notifications,
          ),
          appSecurityServiceProvider.overrideWithValue(
            MemoryAppSecurityService(),
          ),
          appSettingsStoreProvider.overrideWithValue(MemoryAppSettingsStore()),
          signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
          socialSnapshotStoreProvider.overrideWithValue(
            MemorySocialSnapshotStore(persistedState),
          ),
          messageTimelineStoreProvider.overrideWithValue(
            MemoryMessageTimelineStore(),
          ),
          attachmentTransferStoreProvider.overrideWithValue(
            MemoryAttachmentTransferStore(),
          ),
          callMediaSessionControllerProvider.overrideWithValue(callMedia),
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty(
              lifecycle: const LifecycleSnapshot(
                visibility: AppVisibilityState.background,
                generation: 1,
                capturedAtMillis: 0,
              ),
            ),
          ),
        ],
      );
      final HeadlessBackgroundRuntimeCoordinator coordinator =
          HeadlessBackgroundRuntimeCoordinator(
            environment: BackgroundRuntimeEnvironment(
              container: container,
              transport: transport,
              callMediaController: callMedia,
            ),
          );
      addTearDown(() async {
        await coordinator.dispose();
      });

      await coordinator.start();
      await transport.injectIncoming(
        from: 'ada.ygg',
        payload: const <String, dynamic>{
          'type': 'friend_accept',
          'senderName': 'Ada',
        },
        receivedAtMillis: 77,
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.activeNotifications, hasLength(1));
      expect(
        notifications.activeNotifications.single.title,
        'Ada zaakceptował(a) zaproszenie',
      );
      expect(
        container.read(socialHubControllerProvider).backgroundAlerts,
        hasLength(1),
      );
    },
  );

  testWidgets(
    'Android background bridge hands runtime off to the service and restores it on foreground',
    (WidgetTester tester) async {
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController();
      final Uint8List encryptionKey = Uint8List.fromList(
        List<int>.generate(32, (int index) => index + 7),
      );
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        settings: const AppSettings(encryptionEnabled: true),
        hasPassword: true,
        locked: false,
        encryptionKey: encryptionKey,
      );
      addTearDown(runtime.dispose);
      await runtime.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            androidBackgroundRuntimeBridgeEnabledProvider.overrideWithValue(
              true,
            ),
            androidBackgroundServiceControllerProvider.overrideWithValue(
              service,
            ),
            runtimeNodeRuntimeProvider.overrideWithValue(runtime),
            signalTransportProvider.overrideWithValue(runtime),
            appSecurityServiceProvider.overrideWithValue(security),
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(
                const AppSettings(encryptionEnabled: true),
              ),
            ),
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(),
            ),
            attachmentTransferStoreProvider.overrideWithValue(
              MemoryAttachmentTransferStore(),
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
            home: AndroidBackgroundRuntimeBridge(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AndroidBackgroundRuntimeBridge)),
      );

      await container
          .read(socialHubControllerProvider.notifier)
          .setLifecycle(
            const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 2,
              capturedAtMillis: 1,
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // The service is parked from the foreground first, then handed the node.
      expect(
        service.modes,
        orderedEquals(<AndroidBackgroundRuntimeMode>[
          AndroidBackgroundRuntimeMode.standby,
          AndroidBackgroundRuntimeMode.active,
        ]),
      );
      expect(service.activeStarts, orderedEquals(<CallSession?>[null]));
      expect(service.startedPayloads.last.encryptionKey, isNotNull);
      expect(
        service.startedPayloads.last.encryptionKey,
        orderedEquals(encryptionKey),
      );
      expect(runtime.snapshot.serviceRunning, isFalse);

      await container
          .read(socialHubControllerProvider.notifier)
          .setLifecycle(
            const LifecycleSnapshot(
              visibility: AppVisibilityState.foreground,
              generation: 3,
              capturedAtMillis: 2,
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Coming back parks the service again instead of stopping it: the
      // notification channel must outlive the app being swiped away.
      expect(service.modes.last, AndroidBackgroundRuntimeMode.standby);
      expect(service.stopCount, 0);
      expect(runtime.snapshot.serviceRunning, isTrue);
    },
  );

  testWidgets(
    'Android background bridge forwards active call context to the service',
    (WidgetTester tester) async {
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController();
      addTearDown(runtime.dispose);
      await runtime.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            androidBackgroundRuntimeBridgeEnabledProvider.overrideWithValue(
              true,
            ),
            androidBackgroundServiceControllerProvider.overrideWithValue(
              service,
            ),
            runtimeNodeRuntimeProvider.overrideWithValue(runtime),
            signalTransportProvider.overrideWithValue(runtime),
            appSecurityServiceProvider.overrideWithValue(
              MemoryAppSecurityService(),
            ),
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(),
            ),
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(),
            ),
            attachmentTransferStoreProvider.overrideWithValue(
              MemoryAttachmentTransferStore(),
            ),
            socialHubSeedProvider.overrideWithValue(
              SocialHubState.empty(
                lifecycle: const LifecycleSnapshot(
                  visibility: AppVisibilityState.foreground,
                  generation: 1,
                  capturedAtMillis: 0,
                ),
              ).copyWith(
                activeCall: const CallSession(
                  id: 'call-1',
                  peerAddress: 'ada.ygg',
                  displayName: 'Ada',
                  kind: CallInviteKind.video,
                  status: CallSessionStatus.active,
                  startedAtMillis: 5,
                  isCameraEnabled: true,
                ),
              ),
            ),
          ],
          child: const MaterialApp(
            home: AndroidBackgroundRuntimeBridge(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AndroidBackgroundRuntimeBridge)),
      );
      await container
          .read(socialHubControllerProvider.notifier)
          .setLifecycle(
            const LifecycleSnapshot(
              visibility: AppVisibilityState.background,
              generation: 2,
              capturedAtMillis: 1,
            ),
          );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(service.activeStarts, hasLength(1));
      expect(service.activeStarts.single?.kind, CallInviteKind.video);
      expect(
        foregroundServiceTypesForCallSession(service.activeStarts.single),
        orderedEquals(const <ForegroundServiceTypes>[
          ForegroundServiceTypes.specialUse,
          ForegroundServiceTypes.microphone,
          ForegroundServiceTypes.camera,
        ]),
      );
    },
  );

  testWidgets(
    'foreground node waits for the service to release the shared node',
    (WidgetTester tester) async {
      // A launch on top of a service that still owns the node: the app must
      // not bring a second Yggdrasil node up on the same identity while the
      // service is still tearing its own down.
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController(
            gateStandbyAck: true,
            running: true,
          );
      addTearDown(runtime.dispose);
      // The preview runtime boots "active"; park it so the test observes the
      // real cold-start shape, where the node is down until the service frees
      // the identity.
      await runtime.stop();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            androidBackgroundRuntimeBridgeEnabledProvider.overrideWithValue(
              true,
            ),
            androidBackgroundServiceControllerProvider.overrideWithValue(
              service,
            ),
            runtimeNodeRuntimeProvider.overrideWithValue(runtime),
            signalTransportProvider.overrideWithValue(runtime),
            appSecurityServiceProvider.overrideWithValue(
              MemoryAppSecurityService(),
            ),
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(),
            ),
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(),
            ),
            attachmentTransferStoreProvider.overrideWithValue(
              MemoryAttachmentTransferStore(),
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
            home: AndroidBackgroundRuntimeBridge(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        service.modes,
        orderedEquals(<AndroidBackgroundRuntimeMode>[
          AndroidBackgroundRuntimeMode.standby,
        ]),
      );
      expect(service.pendingStandbyAcks, hasLength(1));
      expect(runtime.snapshot.serviceRunning, isFalse);

      service.releaseStandbyAck();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(runtime.snapshot.serviceRunning, isTrue);
    },
  );

  testWidgets(
    'handoff runs when Android backgrounds the app, with frames disabled',
    (WidgetTester tester) async {
      // Flutter turns frames off *before* it dispatches hidden/paused to
      // observers, so anything that waits for a rebuild or a post-frame
      // callback never runs from that point on. The handoff has to happen
      // exactly then, so it must not depend on a frame.
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController();
      addTearDown(runtime.dispose);
      await runtime.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            androidBackgroundRuntimeBridgeEnabledProvider.overrideWithValue(
              true,
            ),
            androidBackgroundServiceControllerProvider.overrideWithValue(
              service,
            ),
            runtimeNodeRuntimeProvider.overrideWithValue(runtime),
            signalTransportProvider.overrideWithValue(runtime),
            appSecurityServiceProvider.overrideWithValue(
              MemoryAppSecurityService(),
            ),
            appSettingsStoreProvider.overrideWithValue(
              MemoryAppSettingsStore(),
            ),
            signalQueueStoreProvider.overrideWithValue(
              MemorySignalQueueStore(),
            ),
            socialSnapshotStoreProvider.overrideWithValue(
              MemorySocialSnapshotStore(),
            ),
            messageTimelineStoreProvider.overrideWithValue(
              MemoryMessageTimelineStore(),
            ),
            attachmentTransferStoreProvider.overrideWithValue(
              MemoryAttachmentTransferStore(),
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
            home: RuntimeLifecycleBridge(
              child: AndroidBackgroundRuntimeBridge(child: SizedBox.shrink()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        service.modes,
        orderedEquals(<AndroidBackgroundRuntimeMode>[
          AndroidBackgroundRuntimeMode.standby,
        ]),
      );

      // The real dispatch path: this disables frames, then notifies observers.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(tester.binding.framesEnabled, isFalse);

      // Deliberately no pump() - that would force a frame the real app never
      // gets and hide the very regression this test guards.
      for (int i = 0; i < 12; i += 1) {
        await tester.idle();
      }

      expect(service.modes.last, AndroidBackgroundRuntimeMode.active);
      expect(runtime.snapshot.serviceRunning, isFalse);

      // Put the binding back so later tests start from a clean slate.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      for (int i = 0; i < 12; i += 1) {
        await tester.idle();
      }
    },
  );

  test(
    'loads persisted bootstrap payload from settings and credentials',
    () async {
      final MemorySecurityCredentialsStore credentials =
          MemorySecurityCredentialsStore();
      await credentials.write(appSecurityPasswordHashStorageKey, 'hash');

      final AndroidBackgroundBootstrapPayload payload =
          await loadStoredAndroidBackgroundBootstrapPayload(
            settingsStore: MemoryAppSettingsStore(
              const AppSettings(
                inboxLimitMb: 91,
                encryptionEnabled: true,
                notificationDelaySeconds: 44,
              ),
            ),
            credentialsStore: credentials,
          );

      expect(payload.settings.inboxLimitMb, 91);
      expect(payload.settings.encryptionEnabled, isTrue);
      expect(payload.settings.notificationDelaySeconds, 44);
      expect(payload.hasPassword, isTrue);
      expect(payload.encryptionKey, isNull);
      expect(payload.requiresUnlockedDataAccess, isTrue);
    },
  );

  test('device mode bootstrap payload carries the device master key', () async {
    final MemorySecurityCredentialsStore credentials =
        MemorySecurityCredentialsStore();
    final Uint8List deviceKey = Uint8List.fromList(
      List<int>.generate(32, (int index) => index + 1),
    );
    await credentials.write(
      appSecurityDeviceMasterKeyStorageKey,
      securityHexFromBytes(deviceKey),
    );

    final AndroidBackgroundBootstrapPayload payload =
        await loadStoredAndroidBackgroundBootstrapPayload(
          settingsStore: MemoryAppSettingsStore(const AppSettings()),
          credentialsStore: credentials,
        );

    expect(payload.hasPassword, isFalse);
    expect(payload.encryptionKey, orderedEquals(deviceKey));
    expect(payload.requiresUnlockedDataAccess, isFalse);
  });

  test(
    'the locked background runtime notice is throttled by its suppression key',
    () async {
      final MemoryRuntimeSystemNotificationService notifications =
          MemoryRuntimeSystemNotificationService();

      final bool firstShown = await showLockedBackgroundRuntimeNotice(
        notifications,
        createdAtMillis: 1000,
      );
      final bool secondShown = await showLockedBackgroundRuntimeNotice(
        notifications,
        createdAtMillis: 2000,
      );

      expect(firstShown, isTrue);
      expect(
        secondShown,
        isFalse,
        reason: 'repeat park events must not spam the notification shade',
      );
      final RuntimeSystemNotification notice =
          notifications.activeNotifications.single;
      expect(notice.category, RuntimeSystemNotificationCategory.call);
      expect(notice.slotKey, 'background-runtime-locked');
      expect(notice.title, contains('odblokowanie'));
    },
  );

  test('foreground service types follow call session state', () {
    expect(
      foregroundServiceTypesForCallSession(null),
      orderedEquals(const <ForegroundServiceTypes>[
        ForegroundServiceTypes.specialUse,
      ]),
    );
    expect(
      foregroundServiceTypesForCallSession(
        const CallSession(
          id: 'call-ringing',
          peerAddress: 'ada.ygg',
          displayName: 'Ada',
          kind: CallInviteKind.audio,
          status: CallSessionStatus.ringing,
          startedAtMillis: 1,
          isIncoming: true,
        ),
      ),
      orderedEquals(const <ForegroundServiceTypes>[
        ForegroundServiceTypes.specialUse,
      ]),
    );
    expect(
      foregroundServiceTypesForCallSession(
        const CallSession(
          id: 'call-audio',
          peerAddress: 'ada.ygg',
          displayName: 'Ada',
          kind: CallInviteKind.audio,
          status: CallSessionStatus.active,
          startedAtMillis: 1,
        ),
      ),
      orderedEquals(const <ForegroundServiceTypes>[
        ForegroundServiceTypes.specialUse,
        ForegroundServiceTypes.microphone,
      ]),
    );
    expect(
      foregroundServiceTypesForCallSession(
        const CallSession(
          id: 'call-video',
          peerAddress: 'ada.ygg',
          displayName: 'Ada',
          kind: CallInviteKind.video,
          status: CallSessionStatus.active,
          startedAtMillis: 1,
          isCameraEnabled: true,
        ),
      ),
      orderedEquals(const <ForegroundServiceTypes>[
        ForegroundServiceTypes.specialUse,
        ForegroundServiceTypes.microphone,
        ForegroundServiceTypes.camera,
      ]),
    );
  });

  test(
    'the always-on service type has no time limit where Android has one',
    () {
      // Android 15 (and 14) run it as specialUse: no 6-hour dataSync limit.
      expect(
        foregroundServiceKeepAliveType(35),
        same(ForegroundServiceTypes.specialUse),
      );
      expect(
        foregroundServiceKeepAliveType(kAndroidSpecialUseServiceSdk),
        same(ForegroundServiceTypes.specialUse),
      );
      // Android 13 and older know no specialUse (the plugin would drop it) and
      // no time limits: they keep dataSync.
      expect(
        foregroundServiceKeepAliveType(33),
        same(ForegroundServiceTypes.dataSync),
      );
      // Unknown counts as current.
      expect(
        foregroundServiceKeepAliveType(null),
        same(ForegroundServiceTypes.specialUse),
      );
      expect(
        foregroundServiceTypesForCallSession(null, androidSdkInt: 33),
        orderedEquals(const <ForegroundServiceTypes>[
          ForegroundServiceTypes.dataSync,
        ]),
      );
      expect(
        foregroundServiceTypesForCallSession(
          const CallSession(
            id: 'call-audio-13',
            peerAddress: 'ada.ygg',
            displayName: 'Ada',
            kind: CallInviteKind.audio,
            status: CallSessionStatus.active,
            startedAtMillis: 1,
          ),
          androidSdkInt: 33,
        ),
        orderedEquals(const <ForegroundServiceTypes>[
          ForegroundServiceTypes.dataSync,
          ForegroundServiceTypes.microphone,
        ]),
      );
      expect(
        foregroundServiceTypesForCallSession(null, androidSdkInt: 35),
        orderedEquals(const <ForegroundServiceTypes>[
          ForegroundServiceTypes.specialUse,
        ]),
      );
    },
  );

  test('only a stop the app did not ask for needs a notice', () {
    expect(
      backgroundStopNeedsNotice(isTimeout: true, stopRequestedByApp: false),
      isTrue,
    );
    expect(
      backgroundStopNeedsNotice(isTimeout: true, stopRequestedByApp: true),
      isTrue,
      reason: 'a time limit ends the service whatever the app wanted',
    );
    expect(
      backgroundStopNeedsNotice(isTimeout: false, stopRequestedByApp: false),
      isTrue,
    );
    expect(
      backgroundStopNeedsNotice(isTimeout: false, stopRequestedByApp: true),
      isFalse,
    );
  });

  test(
    'a service Android ended on a time limit tells the person to reopen Zen',
    () async {
      final MemoryRuntimeSystemNotificationService notices =
          MemoryRuntimeSystemNotificationService();
      final TaskHandler handler = buildAndroidBackgroundTaskHandlerForTesting(
        notices: notices,
      );

      await handler.onDestroy(DateTime.fromMillisecondsSinceEpoch(5000), true);

      expect(notices.isInitialized, isTrue);
      final RuntimeSystemNotification notice =
          notices.activeNotifications.single;
      expect(notice.title, 'Zen nie odbiera w tle');
      expect(
        notice.body,
        'Android zatrzymał działanie w tle. Dotknij, żeby wznowić.',
      );
      expect(notice.slotKey, kBackgroundRuntimeStoppedSlot);
      expect(notice.createdAtMillis, 5000);
      // Tapping opens the app, which starts the service again.
      expect(notice.routeKey, isNotNull);
    },
  );

  test(
    'a stop the app asked for stays quiet; any other stop is reported',
    () async {
      final MemoryRuntimeSystemNotificationService restartNotices =
          MemoryRuntimeSystemNotificationService();
      final TaskHandler restarted = buildAndroidBackgroundTaskHandlerForTesting(
        notices: restartNotices,
      );
      restarted.onReceiveData(<String, Object?>{
        'type': kAndroidBackgroundStopRequestType,
      });
      await restarted.onDestroy(DateTime.fromMillisecondsSinceEpoch(1), false);
      expect(
        restartNotices.activeNotifications,
        isEmpty,
        reason: 'the app restarts the service itself, nothing was lost',
      );

      final MemoryRuntimeSystemNotificationService killedNotices =
          MemoryRuntimeSystemNotificationService();
      final TaskHandler killed = buildAndroidBackgroundTaskHandlerForTesting(
        notices: killedNotices,
      );
      await killed.onDestroy(DateTime.fromMillisecondsSinceEpoch(2), false);
      expect(
        killedNotices.activeNotifications.single.slotKey,
        kBackgroundRuntimeStoppedSlot,
      );
    },
  );

  test(
    'the stop notice can be withdrawn once the service runs again',
    () async {
      final MemoryRuntimeSystemNotificationService notices =
          MemoryRuntimeSystemNotificationService();
      expect(
        await showBackgroundRuntimeStoppedNotice(notices, createdAtMillis: 10),
        isTrue,
      );
      expect(notices.activeNotifications, hasLength(1));
      await notices.dismissSlot(kBackgroundRuntimeStoppedSlot);
      expect(notices.activeNotifications, isEmpty);
    },
  );
}

final class _FakeAndroidBackgroundServiceController
    implements AndroidBackgroundServiceController {
  _FakeAndroidBackgroundServiceController({
    this.gateStandbyAck = false,
    bool running = false,
  }) : _running = running;

  /// When set, a standby request only resolves once [releaseStandbyAck] runs —
  /// the test uses it to prove the foreground node waits for the service to
  /// release the shared node identity.
  final bool gateStandbyAck;

  final List<AndroidBackgroundBootstrapPayload> startedPayloads =
      <AndroidBackgroundBootstrapPayload>[];
  final List<CallSession?> startedCalls = <CallSession?>[];
  final List<Completer<bool>> pendingStandbyAcks = <Completer<bool>>[];
  int stopCount = 0;
  bool _running;

  List<AndroidBackgroundRuntimeMode> get modes => startedPayloads
      .map((AndroidBackgroundBootstrapPayload payload) => payload.mode)
      .toList(growable: false);

  List<CallSession?> get activeStarts => <CallSession?>[
    for (int index = 0; index < startedPayloads.length; index += 1)
      if (startedPayloads[index].mode == AndroidBackgroundRuntimeMode.active)
        startedCalls[index],
  ];

  void releaseStandbyAck() {
    for (final Completer<bool> completer in pendingStandbyAcks) {
      if (!completer.isCompleted) {
        completer.complete(true);
      }
    }
    pendingStandbyAcks.clear();
  }

  int heartbeatCount = 0;

  @override
  Future<void> initialize() async {}

  @override
  void sendHeartbeat() {
    heartbeatCount += 1;
  }

  @override
  Future<bool> isRunning() async => _running;

  @override
  Future<bool> start(
    AndroidBackgroundBootstrapPayload payload, {
    CallSession? activeCall,
  }) async {
    startedPayloads.add(payload);
    startedCalls.add(activeCall);
    _running = true;
    if (gateStandbyAck &&
        payload.mode == AndroidBackgroundRuntimeMode.standby) {
      final Completer<bool> completer = Completer<bool>();
      pendingStandbyAcks.add(completer);
      return completer.future;
    }
    return true;
  }

  @override
  Future<void> stop() async {
    if (_running) {
      stopCount += 1;
    }
    _running = false;
  }
}
