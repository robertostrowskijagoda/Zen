import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/app/app_bootstrap.dart';
import 'package:zen/src/app/persistent_stores.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/app/zen_bootstrap_app.dart';
import 'package:zen/src/core/storage/binary_store.dart';
import 'package:zen/src/domain/signals/signal_queue_store.dart';
import 'package:zen/src/features/account/multi/account_switch.dart';
import 'package:zen/src/features/chat/attachment_transfer_store.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/social_snapshot_store.dart';

import 'support/start_harness.dart';

/// The start as the person sees it: the splash, the slow-start panel when a
/// step takes long ("Zen uruchamia się dłużej niż zwykle", the step named,
/// "Czekaj", "Zapisz dziennik", "Uruchom bez …" for a step the app can do
/// without) and never a wipe of the app's data.
void main() {
  late Directory folder;
  final List<RuntimeNodeRuntime> runtimes = <RuntimeNodeRuntime>[];

  setUp(() {
    ZenStartTrace.debugReset();
    folder = Directory.systemTemp.createTempSync('zen-start-watchdog-');
  });

  tearDown(() {
    for (final RuntimeNodeRuntime runtime in runtimes) {
      runtime.dispose();
    }
    runtimes.clear();
    ZenStartTrace.debugReset();
    try {
      folder.deleteSync(recursive: true);
    } on FileSystemException {
      // A file the test's log still holds; the system cleans up.
    }
  });

  ZenBootstrapperFactory starting({
    Future<void> Function()? prepareForegroundLaunch,
    AppSecurityCredentialsStore? secrets,
    ZenStartTimeouts timeouts = const ZenStartTimeouts(
      optional: Duration(seconds: 2),
      security: Duration(seconds: 20),
    ),
  }) {
    return ({ZenAccountOpening? opening}) => ZenBootstrapper(
      prepareForegroundLaunch: prepareForegroundLaunch,
      supportDirectoryLoader: () async => folder,
      appSecurityServiceBuilder: () =>
          MemoryAppSecurityService(credentialsStore: secrets),
      appSettingsStoreBuilder: (_) => MemoryAppSettingsStore(),
      persistentStoresBuilder:
          (
            Directory _, {
            AppSettingsStore? appSettingsStore,
            BinaryPayloadProtector? dataProtector,
          }) => ZenPersistentStores(
            signalQueueStore: MemorySignalQueueStore(),
            socialSnapshotStore: MemorySocialSnapshotStore(),
            messageTimelineStore: MemoryMessageTimelineStore(),
            attachmentTransferStore: MemoryAttachmentTransferStore(),
            appSettingsStore: appSettingsStore!,
          ),
      runtimeBuilder: ({required RuntimeSignalBootstrapConfig config}) {
        final RuntimeNodeRuntime runtime = RuntimeNodeRuntime.preview();
        runtimes.add(runtime);
        return runtime;
      },
      timeouts: timeouts,
    );
  }

  const Widget app = Directionality(
    textDirection: TextDirection.ltr,
    child: Text('app', key: Key('the-app')),
  );

  Future<void> pumpFor(WidgetTester tester, Duration total) async {
    const Duration step = Duration(milliseconds: 250);
    for (Duration gone = Duration.zero; gone < total; gone += step) {
      await tester.pump(step);
    }
  }

  // The owner's phone (1.14.0, 13:07): the app opened while the background
  // service ran the node in receive-only mode, and the start never got past
  // the logo. Nothing before the first screen may wait on the service.
  testWidgets('a start while the background service holds the node and '
      'does not answer still reaches the app', (WidgetTester tester) async {
    await tester.pumpWidget(
      ZenBootstrapApp(
        bootstrapper: starting(
          // The service never confirms anything.
          prepareForegroundLaunch: () => Completer<void>().future,
        ),
        app: app,
      ),
    );
    await pumpFor(tester, const Duration(seconds: 8));
    expect(find.byKey(const Key('the-app')), findsOneWidget);
  });

  testWidgets('a needed step that hangs: the panel names it, offers to wait '
      'and to save the log, never to skip it, and past its limit the start '
      'fails with "Spróbuj ponownie"', (WidgetTester tester) async {
    int saved = 0;
    await tester.pumpWidget(
      ZenBootstrapApp(
        bootstrapper: starting(secrets: MapSecrets()..hang = true),
        patience: const Duration(seconds: 3),
        saveLog: () async {
          saved += 1;
          return true;
        },
        app: app,
      ),
    );
    await pumpFor(tester, const Duration(seconds: 2));
    expect(find.byKey(const Key('slow-start-panel')), findsNothing);
    await pumpFor(tester, const Duration(seconds: 3));
    expect(find.byKey(const Key('slow-start-panel')), findsOneWidget);
    expect(find.text('Zen uruchamia się dłużej niż zwykle'), findsOneWidget);
    expect(find.textContaining('blokada aplikacji'), findsOneWidget);
    expect(find.byKey(const Key('slow-start-skip')), findsNothing);

    await tester.tap(find.byKey(const Key('slow-start-save-log')));
    await tester.pump();
    expect(saved, 1);
    expect(find.text('Dziennik zapisany.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('slow-start-wait')));
    await tester.pump();
    expect(find.byKey(const Key('slow-start-panel')), findsNothing);
    await pumpFor(tester, const Duration(seconds: 4));
    expect(find.byKey(const Key('slow-start-panel')), findsOneWidget);

    await pumpFor(tester, const Duration(seconds: 20));
    expect(find.byKey(const Key('the-app')), findsNothing);
    expect(find.text('Spróbuj ponownie'), findsOneWidget);
    expect(find.textContaining('blokada aplikacji'), findsOneWidget);
  });

  testWidgets('an optional step can be skipped from the panel', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ZenBootstrapApp(
        bootstrapper: starting(
          prepareForegroundLaunch: () => Completer<void>().future,
          timeouts: const ZenStartTimeouts(optional: Duration(minutes: 5)),
        ),
        patience: const Duration(seconds: 2),
        app: app,
      ),
    );
    await pumpFor(tester, const Duration(seconds: 3));
    expect(find.textContaining('usługa w tle'), findsWidgets);
    expect(find.byKey(const Key('slow-start-skip')), findsOneWidget);

    await tester.tap(find.byKey(const Key('slow-start-skip')));
    await pumpFor(tester, const Duration(seconds: 3));
    // The start went on; the next optional step that waits (here the
    // diagnostics log, whose file the test's clock never lets finish) can
    // be skipped the same way.
    for (int i = 0; i < 3; i++) {
      if (find.byKey(const Key('the-app')).evaluate().isNotEmpty) {
        break;
      }
      expect(find.textContaining('usługa w tle'), findsNothing);
      await tester.tap(find.byKey(const Key('slow-start-skip')));
      await pumpFor(tester, const Duration(seconds: 3));
    }
    expect(find.byKey(const Key('the-app')), findsOneWidget);
  });
}
