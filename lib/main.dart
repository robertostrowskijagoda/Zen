import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/i18n/zen_language_preference.dart';
import 'package:zen/src/app/single_instance_guard.dart';
import 'package:zen/src/app/start_trace.dart';
import 'package:zen/src/app/zen_bootstrap_app.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/about/go_licenses.dart';
import 'package:zen/src/features/media/linux_video_player.dart';
import 'package:zen/src/features/runtime/opened_files.dart';

void main(List<String> args) {
  ZenInstance.init(args);
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _installGlobalErrorHandlers();
      ZenStartTrace.begin();
      // The start log on disk as early as the folder is known: a start
      // that stops before its first frame still says where.
      unawaited(
        ZenInstance.instanceDirectory().then(
          ZenStartTrace.attach,
          onError: (Object error, StackTrace stackTrace) =>
              logZenError('Finding the data folder failed', error, stackTrace),
        ),
      );
      // Nothing before runApp may hang: until the first frame the system
      // keeps its launch screen (the logo) and no slow-start screen can
      // show. Each step has a short limit and is skipped past it.
      // Zen is portrait only (the manifests say so too; this covers the
      // rest, e.g. tablets that would rotate anyway).
      await ZenStartTrace.run<void>(
        ZenStartStep(
          'orientation',
          label: t('orientacja ekranu'),
          optional: true,
        ),
        () => SystemChrome.setPreferredOrientations(<DeviceOrientation>[
          DeviceOrientation.portraitUp,
        ]),
        timeout: const Duration(seconds: 3),
        fallback: () {},
        fallbackOnError: true,
      );
      // NOTICE and the Go, native and font licenses next to the Dart
      // packages' ones.
      registerGoLicenses();
      // Linux: video_player has no backend there; Zen's own on GStreamer.
      LinuxVideoPlayer.registerIfNeeded();
      // A second desktop instance cannot bind the runtime's peering port, so
      // it would run permanently offline. Hand the launch over to the instance
      // that is already running instead.
      // A test profile (--zen-profile) runs beside the others on purpose.
      if (ZenInstance.profile == null &&
          !await ZenStartTrace.run<bool>(
            ZenStartStep(
              'single-instance',
              label: t('inne okno Zen'),
              optional: true,
            ),
            () => ZenSingleInstance.acquire(
              // Windows: a file opened while Zen runs goes to the running one.
              open: Platform.isWindows ? zenOpenedFileArgument(args) : null,
            ),
            timeout: const Duration(seconds: 10),
            fallback: () => true,
            fallbackOnError: true,
          )) {
        logZenMessage('Another Zen instance is already running — exiting.');
        exit(0);
      }
      // Files opened in Zen from outside (a backup tapped in Files):
      // listening before anything else, so the one Zen starts with counts.
      ZenOpenedFiles.instance.start(args);
      // Before the first text: the person's language (or the system's).
      await ZenStartTrace.run<void>(
        ZenStartStep('language', label: t('język'), optional: true),
        loadZenLanguage,
        timeout: const Duration(seconds: 5),
        fallback: () {},
        fallbackOnError: true,
      );
      runApp(const ZenBootstrapApp());
    },
    (Object error, StackTrace stackTrace) {
      logZenError('Uncaught asynchronous error', error, stackTrace);
    },
  );
}

void _installGlobalErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    logZenError(
      'Flutter framework error',
      details.exception,
      details.stack ?? StackTrace.current,
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stackTrace) {
    logZenError('Platform dispatcher error', error, stackTrace);
    return true;
  };
}
