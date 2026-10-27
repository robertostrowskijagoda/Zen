import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_notice.dart';

/// The look at GitHub from the Android background service, so a new
/// version is announced also while the app is closed or its process gone.
///
/// It rides the service's shared beat ([ZenWake.beat]) as work that does
/// not wake the phone in Doze, so it runs on a wake that comes anyway (the
/// mailbox polls); with nothing else on the beat, its own wake comes every
/// [beatEvery] at most, and Doze puts it off to its next window. Each run
/// only reads a small file; it asks GitHub when GitHub last
/// answered [every] ago or longer, whoever asked (the app keeps the same
/// file, [UpdateNoticeStore]). Once when the service starts, too (after
/// [firstAfter]), so a service that is restarted often still checks.
final class BackgroundUpdateCheck {
  BackgroundUpdateCheck({
    required Future<RuntimeSystemNotificationService?> Function() notices,
    UpdateNoticeStore? store,
    GithubJsonFetcher? fetchJson,
    int Function()? now,
    this.currentVersion = kAppVersion,
    this.every = kGithubCheckEvery,
    this.firstAfter = const Duration(minutes: 2),
  }) : _notices = notices,
       store = store ?? FileUpdateNoticeStore(),
       _fetchJson = fetchJson ?? GithubJsonCache().call,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final Future<RuntimeSystemNotificationService?> Function() _notices;
  final UpdateNoticeStore store;
  final GithubJsonFetcher _fetchJson;
  final int Function() _now;
  final String currentVersion;

  /// How old GitHub's last answer must be before it is asked again.
  final Duration every;

  /// The first look after the service starts.
  final Duration firstAfter;

  WakeTimer? _beat;
  Timer? _first;
  Future<void>? _running;

  /// How often the work comes round on the beat: a quarter of [every], so
  /// a check falls between [every] and [every] and a quarter after the last
  /// answer. A run that is not due reads one small file and stops.
  Duration get beatEvery => every ~/ 4;

  void start() {
    if (_beat != null) {
      return;
    }
    _first = Timer(firstAfter, () => unawaited(checkIfDue()));
    _beat = ZenWake.beat(
      'update-check',
      beatEvery,
      checkIfDue,
      hold: const Duration(seconds: 30),
      whileIdle: false,
    );
  }

  void stop() {
    _first?.cancel();
    _first = null;
    _beat?.cancel();
    _beat = null;
  }

  /// Asks GitHub when the last answer is [every] old (one look at a time).
  Future<void> checkIfDue() => _running ??= _checkIfDue().whenComplete(() {
    _running = null;
  });

  Future<void> _checkIfDue() async {
    final UpdateNoticeState kept = await store.read();
    final int now = _now();
    if (!updateCheckDue(kept.checkedAtMillis, nowMillis: now, every: every)) {
      return;
    }
    final GithubRelease? release;
    try {
      release = GithubRelease.fromJson(
        await _fetchJson(kGithubLatestReleaseUri),
      );
    } on GithubStatusException catch (e) {
      if (e.statusCode == HttpStatus.notFound) {
        // No published release: an answer all the same.
        await store.update((UpdateNoticeState s) => s.answered(at: now));
      }
      logZenWarning('Sprawdzanie nowej wersji w tle: $e');
      return;
    } on Object catch (e) {
      // Not reached or no answer: the next run tries again.
      logZenWarning('Sprawdzanie nowej wersji w tle: $e');
      return;
    }
    final String? newer = release != null && release.isNewerThan(currentVersion)
        ? release.version
        : null;
    await store.update(
      (UpdateNoticeState s) => s.answered(at: now, newest: newer),
    );
    if (newer == null) {
      return;
    }
    final RuntimeSystemNotificationService? notices = await _notices();
    if (notices == null) {
      return;
    }
    await announceUpdateOnce(
      store: store,
      notices: notices,
      version: newer,
      nowMillis: now,
    );
  }
}

/// The background service's [BackgroundUpdateCheck], started; null where
/// Zen does not look at GitHub by itself (the store build, tests).
BackgroundUpdateCheck? startBackgroundUpdateCheck({
  required Future<RuntimeSystemNotificationService?> Function() notices,
}) {
  if (!githubUpdatesEnabledFor(
    storeBuild: isStoreBuild,
    web: kIsWeb,
    environment: kIsWeb ? const <String, String>{} : Platform.environment,
  )) {
    return null;
  }
  return BackgroundUpdateCheck(notices: notices)..start();
}
