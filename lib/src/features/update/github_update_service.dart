import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';
import 'package:zen/src/features/update/share_app_server.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_notice.dart';
import 'package:zen/src/features/update/update_service.dart';

/// What the last look at GitHub's newest release found.
enum GithubCheckState {
  /// Not checked yet.
  unknown,

  /// This build is the newest published release (or none is published).
  upToDate,

  /// A newer release is published: [GithubUpdateService.newer].
  newer,

  /// github.com could not be reached at all (no connection, DNS, TLS,
  /// timeout): possibly blocked.
  unreachable,

  /// GitHub answered, but with an error (rate limit, server error…):
  /// tried again at [GithubUpdateService.nextCheckAt].
  failed,

  /// GitHub says the project has no published release (404): before the
  /// first release, or the repository was removed, made private or
  /// blocked. Not "up to date": updates may have to come from friends.
  missing,
}

/// Where the update the person asked for is.
enum GithubInstallState {
  idle,
  downloading,
  verifying,
  installing,
  done,
  failed,
}

/// The text shown when github.com cannot be reached (the owner's words).
String get githubUnreachableMessage => t(
  'Nie mogę sprawdzić aktualizacji, strona github jest niedostępna. '
  'Możliwe, że ktoś zwalcza tę aplikację.',
);

/// Whether this build looks at GitHub for new releases by itself: not the
/// store build (its store updates it) and not under `flutter test`.
bool githubUpdatesEnabledFor({
  required bool storeBuild,
  required bool web,
  required Map<String, String> environment,
}) => !storeBuild && !web && !environment.containsKey('FLUTTER_TEST');

/// Looks at the project's newest GitHub release whenever the last look
/// (here or in the Android background service, [noticeStore]) is
/// [checkEvery] old: at start, when the app comes back, and while it runs.
/// A newer release is announced once with a system notification
/// ([notifications]). On the person's "Aktualizuj" it downloads this platform's
/// file, checks it against the release's `SHA256SUMS` and, once this build
/// knows [releaseKeys], against the maintainer's signature in
/// [kSignedSumsAssetName], and hands it to [installer] (which on Android
/// also checks the signing certificate).
///
/// Only one request to api.github.com per check, with no header but the
/// User-Agent "Zen" and `If-None-Match` (the `ETag` of the last answer:
/// an unchanged release does not count against GitHub's rate limit of 60
/// requests an hour per IP address, which people behind one mobile
/// operator's address share). A failed check is tried again sooner than
/// [checkEvery]: after the wait GitHub asks for, else after
/// [retryFirst], doubling each time up to [checkEvery].
/// Complements the friend-to-friend updates (update_service.dart), which
/// need no server at all.
final class GithubUpdateService extends ChangeNotifier {
  GithubUpdateService({
    required this.installer,
    GithubJsonFetcher? fetchJson,
    Sha256SumsFetcher? fetchSums,
    GithubDownloader? download,
    this.beforeDownload,
    bool Function()? internetWorks,
    DateTime Function()? now,
    UpdateNoticeStore? noticeStore,
    this.notifications,
    this.currentVersion = kAppVersion,
    this.releaseKeys = kReleaseMaintainers,
    this.firstCheckAfter = const Duration(seconds: 20),
    this.checkEvery = kGithubCheckEvery,
    this.confirmAfter = const Duration(minutes: 2),
    this.retryFirst = const Duration(minutes: 15),
  }) : _fetchJson = fetchJson ?? GithubJsonCache().call,
       _fetchSums = fetchSums ?? fetchSha256Sums,
       _download = download ?? downloadGithubAsset,
       _internetWorks = internetWorks ?? (() => true),
       _now = now ?? DateTime.now,
       noticeStore = noticeStore ?? MemoryUpdateNoticeStore();

  final GithubUpdateInstaller installer;
  final String currentVersion;

  /// What this and the Android background service keep about the checks:
  /// when GitHub last answered, which version was announced, which
  /// version's banner was closed.
  final UpdateNoticeStore noticeStore;

  /// Where "Jest nowa wersja Zen" is shown (once per version); null: not
  /// at all.
  final RuntimeSystemNotificationService? notifications;

  /// The maintainers' keys (hybrid ids) a release's [kSignedSumsAssetName]
  /// must be signed with. Empty (as today): only `SHA256SUMS`, which comes from the same
  /// release as the file, so it protects against damage, not against a
  /// forged release.
  final List<String> releaseKeys;
  final Duration firstCheckAfter;
  final Duration checkEvery;

  /// After a first failed attempt GitHub is tried once more this much later
  /// before the warning banner may show (a one-off hiccup says nothing).
  final Duration confirmAfter;

  /// The first wait after GitHub answered with an error (when it did not
  /// say how long to wait); doubled after each further error.
  final Duration retryFirst;

  /// Asked before anything is downloaded (Android: whether Zen may install
  /// apps, which opens the system settings when it may not). Null: go
  /// ahead; a text: nothing is downloaded and the person is told it.
  final Future<String?> Function()? beforeDownload;

  final GithubJsonFetcher _fetchJson;
  final Sha256SumsFetcher _fetchSums;
  final GithubDownloader _download;
  final bool Function() _internetWorks;
  final DateTime Function() _now;

  GithubCheckState _state = GithubCheckState.unknown;
  GithubRelease? _latest;
  String? _error;
  DateTime? _checkedAt;
  int _unreachableInARow = 0;
  int _failedInARow = 0;
  bool _rateLimited = false;
  DateTime? _nextCheckAt;
  Timer? _retry;
  bool _unreachableDismissed = false;
  String? _dismissedVersion;
  Future<void>? _checking;
  bool _asking = false;
  bool _started = false;

  /// When this isolate last asked GitHub (answered or not).
  DateTime? _triedAt;

  /// The next [checkIfDue].
  Timer? _next;

  GithubInstallState _install = GithubInstallState.idle;
  int _received = 0;
  int _total = 0;
  String? _installMessage;

  Timer? _confirm;
  bool _disposed = false;

  GithubCheckState get state => _state;

  /// What GitHub answered when [state] is [GithubCheckState.failed].
  String? get error => _error;

  DateTime? get checkedAt => _checkedAt;

  /// When a failed check ([GithubCheckState.failed]) is tried again.
  DateTime? get nextCheckAt => _nextCheckAt;

  /// Whether the last error was GitHub's rate limit.
  bool get rateLimited => _rateLimited;

  bool get checking => _checking != null;

  /// The oldest Zen the newest release still supports (`zen-min:` in its
  /// notes), when it names one.
  String? get minimumVersion => _latest?.minVersion;

  /// The published release newer than this build, if any.
  GithubRelease? get newer {
    final GithubRelease? r = _latest;
    return r != null && r.isNewerThan(currentVersion) ? r : null;
  }

  /// Whether "Aktualizuj" can download and install here (not on iOS, and
  /// only when the release has this platform's file).
  bool get canInstall {
    final String? name = installer.assetName;
    return name != null && (newer?.assets.containsKey(name) ?? false);
  }

  /// The banner "Jest nowa wersja…" (until it is closed for that version,
  /// which is kept: closed, it stays closed after a restart; the card on
  /// the updates screen still offers the version).
  bool get showNewerBanner {
    final GithubRelease? r = newer;
    final String? dismissed = _dismissedVersion;
    return r != null &&
        (dismissed == null || compareAppVersions(r.version, dismissed) > 0);
  }

  /// The banner with [githubUnreachableMessage]: only when two attempts in
  /// a row failed and the rest of the internet works (the mesh node has
  /// peers), so a phone that is simply offline is not alarmed at every
  /// start.
  bool get showUnreachableBanner =>
      _state == GithubCheckState.unreachable &&
      _unreachableInARow >= 2 &&
      !_unreachableDismissed &&
      _internetWorks();

  GithubInstallState get installState => _install;

  bool get installing =>
      _install == GithubInstallState.downloading ||
      _install == GithubInstallState.verifying ||
      _install == GithubInstallState.installing;

  /// 0..1 while downloading.
  double get progress => _total <= 0 ? 0 : (_received / _total).clamp(0, 1);

  String? get installMessage => _installMessage;

  /// Whether this build checks the author's signature of a release before
  /// installing it (false while it knows no [releaseKeys]).
  bool get verifiesAuthorSignature => releaseKeys.isNotEmpty;

  /// Takes the kept state at once, and [checkIfDue] after
  /// [firstCheckAfter]; from then on [checkIfDue] runs whenever a check is
  /// due again (and when the app comes back, see the provider).
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    unawaitedLogged(_readKept(), context: 'Reading the update check state');
    _arm(firstCheckAfter);
  }

  /// Asks GitHub when a check is due: GitHub last answered (here or in the
  /// Android background service) [checkEvery] ago or longer, or the
  /// background service has since found a version this isolate does not
  /// know yet. Not twice within [retryFirst] when GitHub did not answer
  /// (an offline phone coming back to the app now and then).
  Future<void> checkIfDue() async {
    if (_disposed) {
      return;
    }
    final UpdateNoticeState kept = await _readKept();
    final int now = _now().millisecondsSinceEpoch;
    final int? mine = _checkedAt?.millisecondsSinceEpoch;
    final int? theirs = kept.checkedAtMillis;
    final int? last = mine == null || (theirs != null && theirs > mine)
        ? theirs
        : mine;
    final String? found = kept.newestVersion;
    final bool foundElsewhere =
        found != null &&
        theirs != null &&
        (mine == null || theirs > mine) &&
        compareAppVersions(found, newer?.version ?? currentVersion) > 0;
    final DateTime? tried = _triedAt;
    final bool triedJustNow =
        tried != null && _now().difference(tried) < retryFirst;
    if (_checking == null &&
        (foundElsewhere ||
            (!triedJustNow &&
                updateCheckDue(last, nowMillis: now, every: checkEvery)))) {
      await check();
    }
    _armNext();
  }

  /// The next [checkIfDue]: when the last answer turns [checkEvery] old.
  void _armNext() {
    final DateTime? at = _checkedAt;
    final Duration left = at == null
        ? checkEvery
        : at.add(checkEvery).difference(_now());
    _arm(left < const Duration(minutes: 1) ? const Duration(minutes: 1) : left);
  }

  void _arm(Duration wait) {
    _next?.cancel();
    _next = _disposed ? null : Timer(wait, () => unawaited(checkIfDue()));
  }

  /// What is kept, with the closed banner's version taken over.
  Future<UpdateNoticeState> _readKept() async {
    final UpdateNoticeState kept = await noticeStore.read();
    final String? dismissed = kept.dismissedVersion;
    if (dismissed != null &&
        (_dismissedVersion == null ||
            compareAppVersions(dismissed, _dismissedVersion!) > 0)) {
      _dismissedVersion = dismissed;
      _notify();
    }
    return kept;
  }

  /// Closes the banner for this version, also after a restart.
  void dismissNewer() {
    final String? version = newer?.version;
    _dismissedVersion = version;
    _notify();
    if (version != null) {
      unawaitedLogged(
        noticeStore.update(
          (UpdateNoticeState s) => s.copyWith(dismissedVersion: version),
        ),
        context: 'Keeping the closed update banner',
      );
    }
  }

  void dismissUnreachable() {
    _unreachableDismissed = true;
    _notify();
  }

  /// Asks GitHub for the newest release (one check at a time).
  Future<void> check() => _checking ??= _check().whenComplete(() {
    _checking = null;
    _notify();
  });

  Future<void> _check() async {
    _triedAt = _now();
    _notify();
    try {
      final GithubRelease? release = GithubRelease.fromJson(
        await _fetchJson(kGithubLatestReleaseUri),
      );
      _reached();
      _answered();
      if (release != null) {
        _latest = release;
      }
      _state = newer != null
          ? GithubCheckState.newer
          : GithubCheckState.upToDate;
      await _keepAnswer();
    } on GithubStatusException catch (e) {
      _reached();
      if (e.statusCode == HttpStatus.notFound) {
        // No published release (yet, or any more): said so, not hidden
        // behind "up to date".
        _answered();
        _latest = null;
        _state = GithubCheckState.missing;
        await _keepAnswer();
      } else {
        _state = GithubCheckState.failed;
        _error = e.toString();
        _failedAgain(e.rateLimited, e.retryAfter);
      }
      logZenWarning('Sprawdzanie nowej wersji na GitHubie: $e');
    } on Object catch (e) {
      if (isUnreachableError(e)) {
        _state = GithubCheckState.unreachable;
        _unreachableInARow++;
        if (_unreachableInARow == 1 && !_disposed) {
          _confirm?.cancel();
          _confirm = Timer(confirmAfter, () => unawaited(check()));
        }
      } else {
        _reached();
        _state = GithubCheckState.failed;
        _error = e.toString();
        _failedAgain(false, null);
      }
      logZenWarning('Sprawdzanie nowej wersji na GitHubie: $e');
    }
  }

  /// GitHub gave a real answer: kept for the Android background service
  /// (which then waits [checkEvery] before it asks), and a newer version
  /// announced, once.
  Future<void> _keepAnswer() async {
    final int now = _now().millisecondsSinceEpoch;
    final String? found = newer?.version;
    await noticeStore.update(
      (UpdateNoticeState s) => s.answered(at: now, newest: found),
    );
    final RuntimeSystemNotificationService? notices = notifications;
    if (found != null && notices != null) {
      await announceUpdateOnce(
        store: noticeStore,
        notices: notices,
        version: found,
        nowMillis: now,
      );
    }
  }

  /// GitHub gave a real answer: no retry pending.
  void _answered() {
    _failedInARow = 0;
    _rateLimited = false;
    _nextCheckAt = null;
    _retry?.cancel();
    _retry = null;
  }

  /// GitHub answered with an error: try again after [retryAfter] (what
  /// GitHub asked for, at least a minute) or [retryFirst] doubled for each
  /// error in a row, never later than the next regular check.
  void _failedAgain(bool rateLimited, Duration? retryAfter) {
    _failedInARow++;
    _rateLimited = rateLimited;
    final int doublings = _failedInARow > 16 ? 15 : _failedInARow - 1;
    Duration wait = retryAfter != null
        ? retryAfter + const Duration(minutes: 1)
        : retryFirst * (1 << doublings);
    if (wait > checkEvery) {
      wait = checkEvery;
    }
    _nextCheckAt = _now().add(wait);
    _retry?.cancel();
    _retry = _disposed ? null : Timer(wait, () => unawaited(check()));
  }

  void _reached() {
    _checkedAt = _now();
    _unreachableInARow = 0;
    _unreachableDismissed = false;
    _error = null;
    _confirm?.cancel();
    _confirm = null;
  }

  /// "Aktualizuj": downloads this platform's file of [newer], checks it
  /// against the release's `SHA256SUMS` and the author's signature (when
  /// [verifiesAuthorSignature]) and installs it.
  Future<void> update() async {
    final GithubRelease? release = newer;
    final String? name = installer.assetName;
    if (release == null || name == null || installing || _asking) {
      return;
    }
    final int? size = release.assets[name];
    if (size == null) {
      _finish(
        GithubInstallState.failed,
        t('Wydanie {version} nie ma jeszcze pliku {file}.', {
          'version': release.version,
          'file': name,
        }),
      );
      return;
    }
    if (verifiesAuthorSignature &&
        !release.assets.containsKey(kSignedSumsAssetName)) {
      _finish(
        GithubInstallState.failed,
        t(
          'Wydanie {version} nie ma podpisu autora ({file}) — nie '
          'instaluję go.',
          {'version': release.version, 'file': kSignedSumsAssetName},
        ),
      );
      return;
    }
    final Future<String?> Function()? ask = beforeDownload;
    if (ask != null) {
      // Before the download, not after it: a refusal costs nothing.
      _asking = true;
      String? refusal;
      try {
        refusal = await ask();
      } on Object catch (e, stack) {
        logZenError('Aktualizacja z GitHuba', e, stack);
        refusal = t('Aktualizacja nie udała się: {error}', {'error': e});
      } finally {
        _asking = false;
      }
      if (refusal != null) {
        _finish(GithubInstallState.failed, refusal);
        return;
      }
    }
    _install = GithubInstallState.downloading;
    _received = 0;
    _total = size;
    _installMessage = null;
    _notify();
    File? file;
    try {
      final Directory dir = await installer.workDirectory();
      file = File('${dir.path}${Platform.pathSeparator}$name');
      if (await file.exists()) {
        await file.delete();
      }
      int shown = 0;
      await _download(
        release.assetUri(name),
        file,
        maxBytes: size,
        onProgress: (int received) {
          _received = received;
          final int percent = size <= 0 ? 0 : received * 100 ~/ size;
          if (percent != shown) {
            shown = percent;
            _notify();
          }
        },
      );
      if (await file.length() != size) {
        await file.delete();
        _finish(
          GithubInstallState.failed,
          t('Pobrany plik jest niepełny. Spróbuj jeszcze raz.'),
        );
        return;
      }
      _install = GithubInstallState.verifying;
      _notify();
      final String sums = await _fetchSums(sha256SumsUri(release.version));
      final String hex = await fileSha256Hex(file);
      if (!sha256SumsConfirm(sumsText: sums, name: name, sha256Hex: hex)) {
        await file.delete();
        _finish(
          GithubInstallState.failed,
          t(
            'Suma kontrolna pobranego pliku nie zgadza się z SHA256SUMS '
            'wydania — nie instaluję go.',
          ),
        );
        return;
      }
      if (verifiesAuthorSignature &&
          !await _signedByAuthor(release, name: name, sha256Hex: hex)) {
        await file.delete();
        _finish(
          GithubInstallState.failed,
          t(
            'Wydanie {version} nie jest podpisane kluczem autora Zen — '
            'nie instaluję go.',
            {'version': release.version},
          ),
        );
        return;
      }
      _install = GithubInstallState.installing;
      _notify();
      final GithubInstallOutcome outcome = await installer.install(
        file,
        release,
      );
      _finish(
        outcome.ok ? GithubInstallState.done : GithubInstallState.failed,
        outcome.message,
      );
    } on Object catch (e, stack) {
      logZenError('Aktualizacja z GitHuba', e, stack);
      try {
        if (file != null && await file.exists()) {
          await file.delete();
        }
      } on Object {
        // A temporary file; the next attempt replaces it.
      }
      _finish(
        GithubInstallState.failed,
        isUnreachableError(e)
            ? t(
                'Nie mogę pobrać aktualizacji, strona github jest '
                'niedostępna. Możliwe, że ktoś zwalcza tę aplikację.',
              )
            : t('Aktualizacja nie udała się: {error}', {'error': e}),
      );
    }
  }

  /// Whether the release's [kSignedSumsAssetName] is signed with one of
  /// [releaseKeys] and names [name] with [sha256Hex] in this very version.
  Future<bool> _signedByAuthor(
    GithubRelease release, {
    required String name,
    required String sha256Hex,
  }) async {
    final SignedSums? signed = SignedSums.decode(
      await _fetchSums(release.assetUri(kSignedSumsAssetName)),
    );
    return signed != null &&
        await signed.confirms(
          version: release.version,
          name: name,
          sha256Hex: sha256Hex,
          maintainers: releaseKeys,
        );
  }

  void _finish(GithubInstallState state, String message) {
    _install = state;
    _installMessage = message;
    _notify();
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _next?.cancel();
    _next = null;
    _confirm?.cancel();
    _retry?.cancel();
    super.dispose();
  }
}

/// Whether this build looks at GitHub by itself; overridden in tests.
final Provider<bool> githubUpdatesEnabledProvider = Provider<bool>(
  (Ref ref) => githubUpdatesEnabledFor(
    storeBuild: isStoreBuild,
    web: kIsWeb,
    environment: kIsWeb ? const <String, String>{} : Platform.environment,
  ),
);

/// The running GitHub release check, or null where there is none (the
/// store build, tests).
final Provider<GithubUpdateService?> githubUpdateServiceProvider =
    Provider<GithubUpdateService?>((Ref ref) {
      if (!ref.watch(githubUpdatesEnabledProvider)) {
        return null;
      }
      final GithubUpdateService service = GithubUpdateService(
        installer: SystemGithubInstaller(),
        beforeDownload: !kIsWeb && Platform.isAndroid
            ? requestInstallPermission
            : null,
        // The mesh node has peers: the internet works, only GitHub not.
        internetWorks: () {
          try {
            return ref.read(runtimeNodeSnapshotProvider).peers > 0;
          } on Object {
            return false;
          }
        },
        noticeStore: FileUpdateNoticeStore(),
        notifications: ref.read(runtimeSystemNotificationServiceProvider),
      )..start();
      // Back in the app after a while: a check when one is due.
      final AppLifecycleListener lifecycle = AppLifecycleListener(
        onResume: () => unawaited(service.checkIfDue()),
      );
      ref.onDispose(() {
        lifecycle.dispose();
        service.dispose();
      });
      return service;
    });
