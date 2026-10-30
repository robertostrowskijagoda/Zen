import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/runtime/zen_wake.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_service.dart';
import 'package:zen/src/features/update/latest_release.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_notice.dart';
import 'package:zen/src/features/update/whats_new.dart';

/// The look at GitHub from the Android background service, so a new
/// version is announced also while the app is closed or its process gone.
///
/// It rides the service's shared beat ([ZenWake.beat]) as work that does
/// not wake the phone in Doze, so it runs on a wake that comes anyway (the
/// mailbox polls); with nothing else on the beat, its own wake comes every
/// [beatEvery] at most, and Doze puts it off to its next window. Each run
/// only reads a small file; it asks ([LatestReleaseFinder]: the project's
/// repository's redirect first, which has no rate limit) when the last
/// answer is [every] old or older, whoever asked (the app keeps the same
/// file, [UpdateNoticeStore], and asks every [kGithubCheckEvery] while it
/// runs). A failed check is kept with its error (shown on the updates
/// screen) and tried again on the next run, a beat later, or once the
/// wait GitHub asked for is over. Once when the service starts, too (after
/// [firstAfter]), so a service that is restarted often still checks. A
/// version still to be
/// announced comes with the release's short note (whats_new.dart) in the
/// app's language, when the release has one that holds up, in the place
/// of the notification of an older one; the notification of a version
/// that is installed now is taken away.
/// The shortest round of [BackgroundUpdateCheck] on the service's beat.
const Duration kUpdateBeatAtMost = Duration(minutes: 30);

final class BackgroundUpdateCheck {
  BackgroundUpdateCheck({
    required Future<RuntimeSystemNotificationService?> Function() notices,
    UpdateNoticeStore? store,
    GithubJsonFetcher? fetchJson,
    GithubTagFetcher? fetchTag,
    Sha256SumsFetcher? fetchText,
    int Function()? now,
    String Function()? language,
    this.currentVersion = kAppVersion,
    this.releaseKeys = kReleaseMaintainers,
    this.every = kBackgroundGithubCheckEvery,
    this.firstAfter = const Duration(minutes: 2),
  }) : _notices = notices,
       store = store ?? FileUpdateNoticeStore(),
       _find = fetchJson == null
           ? LatestReleaseFinder.standard()
           : LatestReleaseFinder(fetchJson: fetchJson, fetchTag: fetchTag),
       _fetchText = fetchText ?? fetchSha256Sums,
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch),
       _language = language ?? (() => ZenI18n.code);

  final Future<RuntimeSystemNotificationService?> Function() _notices;
  final UpdateNoticeStore store;
  final LatestReleaseFinder _find;
  final Sha256SumsFetcher _fetchText;
  final int Function() _now;
  final String Function() _language;
  final String currentVersion;

  /// The keys a release's note must be signed with (as its files).
  final List<String> releaseKeys;

  /// How old GitHub's last answer must be before it is asked again.
  final Duration every;

  /// The first look after the service starts.
  final Duration firstAfter;

  WakeTimer? _beat;
  Timer? _first;
  Future<void>? _running;

  /// How often the work comes round on the beat: a quarter of [every], so
  /// a check falls soon after [every] has passed since the last answer, but
  /// never more often than every [kUpdateBeatAtMost] — it rides wakes that
  /// come anyway, and its own must not drain the battery. A run that is not
  /// due reads one small file and stops.
  Duration get beatEvery {
    final Duration quarter = every ~/ 4;
    return quarter < kUpdateBeatAtMost ? kUpdateBeatAtMost : quarter;
  }

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
    final String? announced = kept.notifiedVersion;
    if (announced != null &&
        compareAppVersions(announced, currentVersion) <= 0) {
      // Zen was updated since: its notification offers what is installed.
      final RuntimeSystemNotificationService? notices = await _notices();
      if (notices != null) {
        await withdrawInstalledUpdateNotice(
          store: store,
          notices: notices,
          currentVersion: currentVersion,
        );
      }
    }
    final int now = _now();
    if (!backgroundUpdateCheckDue(kept, nowMillis: now, every: every)) {
      return;
    }
    final GithubRelease? release;
    try {
      release = (await _find()).release;
    } on GithubStatusException catch (e) {
      if (e.statusCode == HttpStatus.notFound) {
        // No published release: an answer all the same.
        await store.update((UpdateNoticeState s) => s.answered(at: now));
      } else {
        // An error answer (a rate limit, a server error): the next run
        // tries again, after the wait GitHub asked for, if it asked.
        final Duration? wait = e.retryAfter;
        await store.update(
          (UpdateNoticeState s) => s.failed(
            at: now,
            error: e,
            retryAt: wait == null
                ? null
                : now + wait.inMilliseconds + Duration.millisecondsPerMinute,
          ),
        );
      }
      logZenWarning('Update check in the background: $e');
      return;
    } on Object catch (e) {
      // Not reached or no answer: the next run tries again.
      await store.update((UpdateNoticeState s) => s.failed(at: now, error: e));
      logZenWarning('Update check in the background: $e');
      return;
    }
    final String? newer = release != null && release.isNewerThan(currentVersion)
        ? release.version
        : null;
    final UpdateNoticeState answered = await store.update(
      (UpdateNoticeState s) => s.answered(at: now, newest: newer),
    );
    if (release == null || newer == null || !updateNoticeDue(answered, newer)) {
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
      whatsNew: await _whatsNew(release),
    );
  }

  /// The note of [release] in the app's language; none when it has none
  /// or it does not hold up.
  Future<List<String>> _whatsNew(GithubRelease release) async {
    try {
      final WhatsNew? note = await fetchWhatsNew(
        release,
        fetchText: _fetchText,
        maintainers: releaseKeys,
      );
      return note?.linesFor(_language()) ?? const <String>[];
    } on Object catch (e) {
      logZenWarning('What\'s new in ${release.version}: $e');
      return const <String>[];
    }
  }
}

/// Whether the background service asks now: the last answer is [every] old
/// ([updateCheckDue]; a failed check leaves it as it was, so the next run
/// on the beat tries again), and GitHub did not ask to wait until later
/// ([UpdateNoticeState.retryAtMillis]; a wait longer than [every] is a
/// clock set back, and ignored).
bool backgroundUpdateCheckDue(
  UpdateNoticeState state, {
  required int nowMillis,
  required Duration every,
}) {
  if (!updateCheckDue(
    state.checkedAtMillis,
    nowMillis: nowMillis,
    every: every,
  )) {
    return false;
  }
  final int? retryAt = state.retryAtMillis;
  return retryAt == null ||
      retryAt <= nowMillis ||
      retryAt - nowMillis > every.inMilliseconds;
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
