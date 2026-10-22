import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/app/zen_app_modules.dart';
import 'package:zen/src/app/zen_core.dart';
import 'package:zen/src/domain/calls/call_invite_kind.dart';
import 'package:zen/src/domain/calls/call_session.dart';
import 'package:zen/src/domain/runtime/lifecycle_snapshot.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/locked_receiver.dart';
import 'package:zen/src/features/runtime/runtime_lifecycle_bridge.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/security/background_keys.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  testWidgets(
    'the unlocked app keeps the node in the background; a lock hands it to '
    'the service without any key',
    (WidgetTester tester) async {
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController();
      final _FakeBackgroundVault vault = _FakeBackgroundVault();
      final Uint8List encryptionKey = Uint8List.fromList(
        List<int>.generate(32, (int index) => index + 7),
      );
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        settings: const AppSettings(),
        hasPassword: true,
        locked: false,
        encryptionKey: encryptionKey,
      );
      addTearDown(runtime.dispose);
      await runtime.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._bridgeOverrides(
              service: service,
              runtime: runtime,
              security: security,
              vault: vault,
            ),
          ],
          child: const MaterialApp(
            home: AndroidBackgroundRuntimeBridge(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(AndroidBackgroundRuntimeBridge)),
      );
      // Unlocked: what the service may receive with is published, with the
      // inbox key's public part only.
      expect(vault.published, isNotEmpty);
      expect(
        vault.published.last.inboxPublicKey,
        orderedEquals(await inboxPublicKeyFor(encryptionKey)),
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

      // In the background but unlocked: the node and the key stay here.
      expect(
        service.modes,
        orderedEquals(<AndroidBackgroundRuntimeMode>[
          AndroidBackgroundRuntimeMode.standby,
        ]),
      );
      expect(runtime.snapshot.serviceRunning, isTrue);

      security.lock();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(service.modes.last, AndroidBackgroundRuntimeMode.active);
      expect(service.activeStarts, orderedEquals(<CallSession?>[null]));
      expect(runtime.snapshot.serviceRunning, isFalse);
      for (final AndroidBackgroundBootstrapPayload payload
          in service.startedPayloads) {
        final Map<String, dynamic> data = payload.toData();
        expect(data.containsKey('encryptionKey'), isFalse);
        expect(
          data.values.whereType<String>().any(
            (String v) => v.contains(base64Encode(encryptionKey)),
          ),
          isFalse,
        );
      }

      // Back on screen, still locked: the service keeps receiving.
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
      expect(service.modes.last, AndroidBackgroundRuntimeMode.active);
      expect(service.stopCount, 0);
      expect(vault.drainCount, 0);
    },
  );

  testWidgets(
    'after unlock the app takes the node back and drains the inbox into it',
    (WidgetTester tester) async {
      // The lock screen replaced the app, so the unlocked app mounts afresh
      // on top of a service that runs the node.
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController(running: true);
      final _FakeBackgroundVault vault = _FakeBackgroundVault()
        ..records.add(
          encodeInboxFrame(
            const SignalTransportFrame(
              from: 'ada.ygg',
              payload: <String, dynamic>{
                'type': 'message',
                '_rid': 'r1',
                'text': 'kept while locked',
              },
              receivedAtMillis: 77,
            ),
          ),
        );
      final MemoryRuntimeSystemNotificationService notices =
          MemoryRuntimeSystemNotificationService();
      await notices.show(
        const RuntimeSystemNotification(
          id: 'n',
          title: 'Nowa wiadomość',
          body: '',
          createdAtMillis: 1,
          category: RuntimeSystemNotificationCategory.message,
          slotKey: kLockedMessageSlot,
        ),
      );
      final List<SignalTransportFrame> replayed = <SignalTransportFrame>[];
      final StreamSubscription<SignalTransportFrame> frames = runtime.frames
          .listen(replayed.add);
      addTearDown(frames.cancel);
      addTearDown(runtime.dispose);
      await runtime.stop();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._bridgeOverrides(
              service: service,
              runtime: runtime,
              security: MemoryAppSecurityService(),
              vault: vault,
            ),
            runtimeSystemNotificationServiceProvider.overrideWithValue(notices),
          ],
          child: const MaterialApp(
            home: AndroidBackgroundRuntimeBridge(child: SizedBox.shrink()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      expect(
        service.modes,
        orderedEquals(<AndroidBackgroundRuntimeMode>[
          AndroidBackgroundRuntimeMode.standby,
        ]),
      );
      expect(runtime.snapshot.serviceRunning, isTrue);
      expect(vault.drainCount, 1);
      expect(vault.records, isEmpty);
      expect(replayed, hasLength(1));
      expect(replayed.single.from, 'ada.ygg');
      expect(replayed.single.payload['text'], 'kept while locked');
      expect(replayed.single.receivedAtMillis, 77);
      // The generic "something came" notices are gone with it.
      expect(notices.activeNotifications, isEmpty);
    },
  );

  testWidgets('a lock forwards the active call context to the service', (
    WidgetTester tester,
  ) async {
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
    final _FakeAndroidBackgroundServiceController service =
        _FakeAndroidBackgroundServiceController();
    final MemoryAppSecurityService security = MemoryAppSecurityService(
      hasPassword: true,
      locked: false,
    );
    addTearDown(runtime.dispose);
    await runtime.start();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ..._bridgeOverrides(
            service: service,
            runtime: runtime,
            security: security,
            vault: _FakeBackgroundVault(),
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
    expect(service.activeStarts, isEmpty);

    security.lock();
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
  });

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
            ..._bridgeOverrides(
              service: service,
              runtime: runtime,
              security: MemoryAppSecurityService(),
              vault: _FakeBackgroundVault(),
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
    'a lock in the background hands the node over with frames disabled',
    (WidgetTester tester) async {
      // Flutter turns frames off *before* it dispatches hidden/paused to
      // observers, and the lock timer fires while the app is away, so the
      // handoff must not wait for a rebuild or a post-frame callback.
      final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
      final _FakeAndroidBackgroundServiceController service =
          _FakeAndroidBackgroundServiceController();
      final MemoryAppSecurityService security = MemoryAppSecurityService(
        hasPassword: true,
        locked: false,
      );
      addTearDown(runtime.dispose);
      await runtime.start();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ..._bridgeOverrides(
              service: service,
              runtime: runtime,
              security: security,
              vault: _FakeBackgroundVault(),
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
      // Unlocked: the app keeps the node.
      expect(service.modes.last, AndroidBackgroundRuntimeMode.standby);
      expect(runtime.snapshot.serviceRunning, isTrue);

      // The lock timer fires in the background.
      security.lock();
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
    'the stored bootstrap payload carries the settings and no key',
    () async {
      final AndroidBackgroundBootstrapPayload payload =
          await loadStoredAndroidBackgroundBootstrapPayload(
            settingsStore: MemoryAppSettingsStore(
              const AppSettings(inboxLimitMb: 91, autoCleanupDays: 44),
            ),
          );

      expect(payload.settings.inboxLimitMb, 91);
      expect(payload.settings.autoCleanupDays, 44);
      expect(payload.mode, AndroidBackgroundRuntimeMode.active);
      final AndroidBackgroundBootstrapPayload? back =
          AndroidBackgroundBootstrapPayload.fromData(payload.toData());
      expect(back?.settings.inboxLimitMb, 91);
      expect(payload.toData().containsKey('encryptionKey'), isFalse);
    },
  );

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

/// The bridge's providers over fakes: no real files, no real service, and
/// a core without modules.
List _bridgeOverrides({
  required _FakeAndroidBackgroundServiceController service,
  required RuntimeNodeRuntime runtime,
  required AppSecurityService security,
  required _FakeBackgroundVault vault,
  CallSession? activeCall,
}) {
  return [
    androidBackgroundRuntimeBridgeEnabledProvider.overrideWithValue(true),
    androidBackgroundServiceControllerProvider.overrideWithValue(service),
    backgroundVaultProvider.overrideWithValue(vault),
    zenCoreProvider.overrideWith((Ref ref) {
      final ZenCore core = ZenCore(
        modules: const <ZenModule>[],
        loadFlags: () async => const FeatureFlags(),
      );
      ref.onDispose(core.stop);
      return core;
    }),
    runtimeNodeRuntimeProvider.overrideWithValue(runtime),
    signalTransportProvider.overrideWithValue(runtime),
    appSecurityServiceProvider.overrideWithValue(security),
    appSettingsStoreProvider.overrideWithValue(
      MemoryAppSettingsStore(const AppSettings()),
    ),
    signalQueueStoreProvider.overrideWithValue(MemorySignalQueueStore()),
    socialSnapshotStoreProvider.overrideWithValue(MemorySocialSnapshotStore()),
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
      ).copyWith(activeCall: activeCall),
    ),
  ];
}

/// What the app published and what the service "kept", in memory.
final class _FakeBackgroundVault implements BackgroundVault {
  final List<BackgroundCapabilityDraft> published =
      <BackgroundCapabilityDraft>[];
  final List<Uint8List> records = <Uint8List>[];
  int drainCount = 0;

  @override
  Future<void> publish(BackgroundCapabilityDraft draft) async {
    published.add(draft);
  }

  @override
  Future<BackgroundCapability?> load() async => null;

  @override
  Future<bool> hasInbox() async => records.isNotEmpty;

  @override
  Future<int> drain({
    required Uint8List masterKey,
    required Future<void> Function(Uint8List record) deliver,
    Duration settle = Duration.zero,
  }) async {
    drainCount += 1;
    final List<Uint8List> kept = List<Uint8List>.of(records);
    records.clear();
    for (final Uint8List record in kept) {
      await deliver(record);
    }
    return kept.length;
  }
}
