import 'dart:async';
import 'dart:ui' show DartPluginRegistrant;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/android_background_runtime.dart';
import 'package:zen/src/features/runtime/ios_background.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings.dart';

// An iPhone's locked Zen keeps receiving like a locked Android phone
// (docs/IOS_BACKGROUND.md): the same [LockedReceiverSession] — a node with
// its identity under the background key, the locked receiver, the outbox
// and the mailbox for friends — runs whenever iOS lets Zen run while it is
// locked. In the app's own isolate when Zen is in memory
// ([IosBackgroundHost]); in a Flutter engine without a screen when iOS
// starts Zen from scratch for a background task or a Shortcuts run
// ([zenIosBackgroundMain], started by ZenBackgroundBridge.swift).

/// A locked receiver as an iPhone runs it ([LockedReceiverSession]; tests
/// put their own).
abstract interface class IosLockedSession {
  /// What the node receives.
  Stream<SignalTransportFrame> get frames;

  Future<void> start();

  /// Asks the mailboxes and sends what waits, now.
  Future<void> catchUp();

  Future<void> dispose();
}

final class _ReceiverSession implements IosLockedSession {
  _ReceiverSession(this._session);

  final LockedReceiverSession _session;

  @override
  Stream<SignalTransportFrame> get frames =>
      _session.frames ?? const Stream<SignalTransportFrame>.empty();

  @override
  Future<void> start() => _session.start();

  @override
  Future<void> catchUp() => _session.catchUp();

  @override
  Future<void> dispose() => _session.dispose();
}

/// The default account's locked receiver; `null` when another account is
/// open in this isolate (only the default one receives while locked) or
/// the app never published a capability (not unlocked since it was
/// installed or wiped).
Future<IosLockedSession?> openIosLockedSession({
  required AppSettings settings,
  required RuntimeSystemNotificationService notices,
}) async {
  if (SecureStorageCredentialsStore.activeNamespace != null) {
    return null;
  }
  final LockedReceiverSession? session =
      await LockedReceiverSession.openDefault(
        settings: settings,
        notices: notices,
      );
  return session == null ? null : _ReceiverSession(session);
}

/// One background check with a locked receiver that runs: the mailboxes
/// are asked (and the outbox sent) like [IosCatchUp] asks an unlocked app's
/// relay engine. Returns how many frames came in.
Future<int> runLockedCatchUp(
  IosLockedSession session,
  Duration budget, {
  bool Function()? cancelled,
}) {
  return IosCatchUp(
    poll: session.catchUp,
    arrivals: session.frames.map(
      (SignalTransportFrame frame) =>
          frame.payload['type'].toString().startsWith('rly_'),
    ),
    cancelled: cancelled,
  ).run(budget);
}

/// The channel between [zenIosBackgroundMain] and ZenBackgroundBridge.swift:
/// the native side calls `stop` when time is up or the app came to the
/// screen; this side calls `done` {checked} once it let go of the node.
const MethodChannel _headlessChannel = MethodChannel('zen/background/headless');

/// The entry point ZenBackgroundBridge.swift runs in an engine of its own
/// when iOS starts Zen without a screen (a background task, a Shortcuts
/// run): no app, no master key — the locked receiver for [args]' first
/// value in seconds, then `done`. Like Android's background service, it
/// reads only what the background key opens.
@pragma('vm:entry-point')
Future<void> zenIosBackgroundMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  installZenErrorLogging();
  bool stopped = false;
  _headlessChannel.setMethodCallHandler((MethodCall call) async {
    if (call.method == 'stop') {
      stopped = true;
    }
    return null;
  });
  bool checked = false;
  try {
    // The notices speak the person's language.
    await loadZenLanguage();
    try {
      await ZenDiagnosticsLog.attach(
        await ZenInstance.supportDirectory(),
        source: 'bg',
      );
    } on Object catch (error, stackTrace) {
      logZenError('Attaching the background log failed', error, stackTrace);
    }
    final int seconds = int.tryParse(args.isEmpty ? '' : args.first) ?? 25;
    final Duration budget = Duration(seconds: seconds.clamp(1, 600));
    final RuntimeSystemNotificationService notices =
        FlutterLocalRuntimeSystemNotificationService(
          canRequestPermission: false,
        );
    // A tap on a notice opens Zen; the app takes it from there.
    await notices.initialize(onOpenRoute: (String routeKey) async {});
    final AppSettings settings =
        (await loadStoredAndroidBackgroundBootstrapPayload()).settings;
    final IosLockedSession? session = await openIosLockedSession(
      settings: settings,
      notices: notices,
    );
    if (session == null) {
      logZenMessage(
        'Background check (iOS, no app) skipped: no background capability.',
      );
      return;
    }
    final Stopwatch watch = Stopwatch()..start();
    try {
      await session.start();
      final int frames = await runLockedCatchUp(
        session,
        budget,
        cancelled: () => stopped,
      );
      checked = true;
      logZenMessage(
        'Background check (iOS, no app): $frames frames in '
        '${watch.elapsed.inSeconds} s.',
      );
    } finally {
      await session.dispose();
    }
  } on Object catch (error, stackTrace) {
    logZenError('Background check (iOS, no app) failed', error, stackTrace);
  } finally {
    try {
      await _headlessChannel.invokeMethod<void>('done', <String, Object?>{
        'checked': checked,
      });
    } on Object catch (error) {
      logZenWarning('The background engine could not report back: $error');
    }
  }
}
