import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

void main() {
  test(
    'initSettings loads persisted settings from the injected store',
    () async {
      final Directory supportDirectory = await Directory.systemTemp.createTemp(
        'zen-bootstrap-settings-',
      );
      addTearDown(() => supportDirectory.delete(recursive: true));
      final MemoryAppSettingsStore store = MemoryAppSettingsStore(
        const AppSettings(autoCleanupDays: 9),
      );

      final ZenBootstrapper bootstrapper = ZenBootstrapper(
        supportDirectoryLoader: () async => supportDirectory,
        appSettingsStoreBuilder: (_) => store,
      );

      final ZenBootstrapSettingsState state = await bootstrapper.initSettings();

      expect(state.supportDirectory.path, supportDirectory.path);
      expect(state.appSettingsStore, same(store));
      expect(state.settings.autoCleanupDays, 9);
    },
  );

  test('initRuntime uses the fixed signal wait timeout', () async {
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
    addTearDown(runtime.dispose);
    final ZenBootstrapper bootstrapper = ZenBootstrapper(
      runtimeBuilder: ({required RuntimeSignalBootstrapConfig config}) {
        expect(config.waitTimeout, const Duration(seconds: 30));
        return runtime;
      },
    );

    final ZenBootstrapRuntimeState state = await bootstrapper.initRuntime(
      settings: const AppSettings(),
    );

    expect(state.runtime, same(runtime));
    expect(state.runtimeConfig.waitTimeout, const Duration(seconds: 30));
  });

  test('bootstrap retries a critical step once before succeeding', () async {
    int prepareCalls = 0;
    const AppSettings settings = AppSettings(autoCleanupDays: 8);
    final MemoryAppSettingsStore store = MemoryAppSettingsStore(settings);
    final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
    addTearDown(runtime.dispose);

    final ZenBootstrapper bootstrapper = ZenBootstrapper(
      prepareForegroundLaunch: () async {
        prepareCalls += 1;
        if (prepareCalls == 1) {
          throw StateError('bootstrap race');
        }
      },
      supportDirectoryLoader: () async => Directory.systemTemp,
      appSecurityServiceBuilder: MemoryAppSecurityService.new,
      appSettingsStoreBuilder: (_) => store,
      persistentStoresBuilder:
          (
            Directory _, {
            AppSettingsStore? appSettingsStore,
            BinaryPayloadProtector? dataProtector,
          }) {
            expect(appSettingsStore, same(store));
            expect(dataProtector, isNotNull);
            return ZenPersistentStores(
              signalQueueStore: MemorySignalQueueStore(),
              socialSnapshotStore: MemorySocialSnapshotStore(),
              messageTimelineStore: MemoryMessageTimelineStore(),
              attachmentTransferStore: MemoryAttachmentTransferStore(),
              appSettingsStore: appSettingsStore!,
            );
          },
      runtimeBuilder: ({required RuntimeSignalBootstrapConfig config}) {
        expect(config.waitTimeout, settings.signalWaitTimeout);
        return runtime;
      },
    );

    final ZenBootstrapResult result = await bootstrapper.bootstrap();

    expect(prepareCalls, 2);
    expect(result.initialSettings.autoCleanupDays, 8);
    expect(result.runtimeConfig.waitTimeout, settings.signalWaitTimeout);
    expect(result.appSecurityService.isReady, isTrue);
    expect(result.stores.appSettingsStore, same(store));
  });

  group('zenStartupGatesRequired', () {
    const Map<String, String> underTest = <String, String>{
      'FLUTTER_TEST': 'true',
    };
    const Map<String, String> plain = <String, String>{'PATH': '/usr/bin'};

    test('a release build always asks, even with FLUTTER_TEST set', () {
      expect(
        zenStartupGatesRequired(
          environment: underTest,
          hasTestProfile: false,
          releaseMode: true,
          debugMode: false,
        ),
        isTrue,
      );
      expect(
        zenStartupGatesRequired(
          environment: underTest,
          hasTestProfile: true,
          releaseMode: true,
          debugMode: false,
        ),
        isTrue,
      );
    });

    test('flutter test in a debug build skips the gates', () {
      expect(
        zenStartupGatesRequired(
          environment: underTest,
          hasTestProfile: false,
          releaseMode: false,
          debugMode: true,
        ),
        isFalse,
      );
    });

    test('a test profile skips them only in a debug build', () {
      expect(
        zenStartupGatesRequired(
          environment: plain,
          hasTestProfile: true,
          releaseMode: false,
          debugMode: true,
        ),
        isFalse,
      );
      // A profile build (neither debug nor release) is a real install.
      expect(
        zenStartupGatesRequired(
          environment: plain,
          hasTestProfile: true,
          releaseMode: false,
          debugMode: false,
        ),
        isTrue,
      );
    });

    test('a normal start asks', () {
      expect(
        zenStartupGatesRequired(
          environment: plain,
          hasTestProfile: false,
          releaseMode: false,
          debugMode: true,
        ),
        isTrue,
      );
    });
  });
}
