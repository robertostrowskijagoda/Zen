import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/secure_clipboard.dart';
import 'package:zen/src/core/utils/system_actions.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/runtime/runtime_system_notifications.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/newer_versions.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';
import 'package:zen/src/features/update/share_app_server.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_notice.dart';
import 'package:zen/src/features/update/update_service.dart';
import 'package:zen/src/features/update/whats_new.dart';

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
/// [checkEvery] old: at start, when the app comes back, and while it runs;
/// and at once when a friend says they run a newer Zen ([hintNewer]).
/// A newer release is announced once with a system notification
/// ([notifications]), with the release's short note ([whatsNew]) when it
/// has one; a release newer still takes its place, in the notification,
/// the banner and the card alike. Once installed, its notification goes.
/// What "Aktualizuj" does depends on the installation ([route]): where Zen
/// can install itself it downloads this platform's
/// file, checks it against the release's `SHA256SUMS` and, once this build
/// knows [releaseKeys], against the maintainer's signature in
/// [kSignedSumsAssetName], and hands it to [installer] (which on Android
/// also checks the signing certificate). On iPhone and iPad it downloads
/// nothing and opens Scarlet with the release's IPA instead
/// ([openInScarlet]); in a Flatpak, and for a release without this
/// device's file, it points to the release page.
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
    Future<bool> Function(String link)? openScarlet,
    Future<bool> Function(String url)? openPage,
    Future<void> Function(String text)? copy,
    bool Function()? internetWorks,
    DateTime Function()? now,
    String Function()? language,
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
       _openScarlet = openScarlet ?? openScarletLink,
       _openPage = openPage ?? openWebLink,
       _copy = copy ?? copyWithExpiry,
       _internetWorks = internetWorks ?? (() => true),
       _now = now ?? DateTime.now,
       _language = language ?? (() => ZenI18n.code),
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

  /// Opens a `scarlet://` link (false: Scarlet is not installed).
  final Future<bool> Function(String link) _openScarlet;

  /// Opens an https page (false: it could not be opened).
  final Future<bool> Function(String url) _openPage;
  final Future<void> Function(String text) _copy;
  final bool Function() _internetWorks;
  final DateTime Function() _now;
  final String Function() _language;

  GithubCheckState _state = GithubCheckState.unknown;
  GithubRelease? _latest;

  /// The note of [newer] (null: none, or not fetched yet), and the version
  /// it was last fetched for (once per version, whatever came of it).
  WhatsNew? _whatsNew;
  String? _whatsNewTriedFor;

  /// The newest version a friend named that made this isolate ask GitHub
  /// at once ([hintNewer]).
  String? _hinted;
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

  /// The short note of [newer] (whats_new.dart), when the release has one
  /// that holds up and it was fetched.
  WhatsNew? get whatsNew {
    final WhatsNew? note = _whatsNew;
    return note != null && note.version == newer?.version ? note : null;
  }

  /// [whatsNew] in the app's language (else in English); empty without one.
  List<String> get whatsNewLines =>
      whatsNew?.linesFor(_language()) ?? const <String>[];

  /// What "Aktualizuj" does for [newer] on this installation; null without
  /// a newer release.
  GithubUpdateRoute? get route {
    final GithubRelease? release = newer;
    return release == null
        ? null
        : githubUpdateRoute(
            target: installer.target,
            release: release,
            assetName: installer.assetName,
          );
  }

  /// Whether "Aktualizuj" can download and install here (never on iOS or in
  /// a Flatpak, and only when the release has this platform's file).
  bool get canInstall => route == GithubUpdateRoute.download;

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

  /// Takes the kept state at once (and takes away the notification of a
  /// version that is installed now), and [checkIfDue] after
  /// [firstCheckAfter]; from then on [checkIfDue] runs whenever a check is
  /// due again (and when the app comes back, see the provider).
  void start() {
    if (_started || _disposed) {
      return;
    }
    _started = true;
    unawaitedLogged(_startKept(), context: 'Reading the update check state');
    _arm(firstCheckAfter);
  }

  Future<void> _startKept() async {
    final RuntimeSystemNotificationService? notices = notifications;
    if (notices != null) {
      await withdrawInstalledUpdateNotice(
        store: noticeStore,
        notices: notices,
        currentVersion: currentVersion,
      );
    }
    await _readKept();
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

  /// A friend said they run [version] (their own claim, unsigned): when it
  /// is newer than anything known here, GitHub is asked now rather than at
  /// the next due check, which tells whether that version is really
  /// published (and announces it). Once per version (a newer one asks
  /// again), never while a check runs and not within [confirmAfter] of the
  /// last attempt. [signed]: a release of [version] that enough
  /// maintainers signed came from friends (update_service.dart): already
  /// verified, it is announced at once as well.
  Future<void> hintNewer(String version, {bool signed = false}) async {
    if (_disposed ||
        !isValidAppVersion(version) ||
        compareAppVersions(version, newer?.version ?? currentVersion) <= 0) {
      return;
    }
    final RuntimeSystemNotificationService? notices = notifications;
    if (signed && notices != null) {
      await announceUpdateOnce(
        store: noticeStore,
        notices: notices,
        version: version,
        nowMillis: _now().millisecondsSinceEpoch,
      );
    }
    final String? hinted = _hinted;
    final DateTime? tried = _triedAt;
    if (_checking != null ||
        (hinted != null && compareAppVersions(version, hinted) <= 0) ||
        (tried != null && _now().difference(tried) < confirmAfter)) {
      return;
    }
    _hinted = version;
    await check();
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
  /// (which then waits before it asks), and a newer version announced,
  /// once, with its note.
  Future<void> _keepAnswer() async {
    final int now = _now().millisecondsSinceEpoch;
    final GithubRelease? release = newer;
    final String? found = release?.version;
    await noticeStore.update(
      (UpdateNoticeState s) => s.answered(at: now, newest: found),
    );
    if (release == null) {
      return;
    }
    // The banner at once; its note when it comes.
    _notify();
    await _fetchWhatsNew(release);
    final RuntimeSystemNotificationService? notices = notifications;
    if (notices != null) {
      await announceUpdateOnce(
        store: noticeStore,
        notices: notices,
        version: release.version,
        nowMillis: now,
        whatsNew: whatsNewLines,
      );
    }
  }

  /// Fetches the note of [release] once per version (a note that does not
  /// hold up is logged and left out; the banner shows the version alone).
  /// A note that could not be fetched (github.com not reached, an error
  /// answer) is asked for again at the next check.
  Future<void> _fetchWhatsNew(GithubRelease release) async {
    if (_whatsNewTriedFor == release.version) {
      return;
    }
    _whatsNew = null;
    try {
      _whatsNew = await fetchWhatsNew(
        release,
        fetchText: _fetchSums,
        maintainers: releaseKeys,
      );
      _whatsNewTriedFor = release.version;
    } on FormatException catch (e) {
      _whatsNewTriedFor = release.version;
      logZenWarning('Co nowego w wersji ${release.version}: $e');
    } on Object catch (e) {
      logZenWarning('Co nowego w wersji ${release.version}: $e');
    }
    _notify();
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
    // iPhone, iPad and Flatpak install nothing Zen downloads: never there.
    if (release == null ||
        name == null ||
        installing ||
        _asking ||
        !_downloadsUpdates(installer.target)) {
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

  /// iPhone and iPad ([GithubUpdateRoute.scarlet]): opens Scarlet with the
  /// IPA of [newer] (pinned to that version; Scarlet downloads, signs and
  /// installs it). Where Scarlet is not installed, or the release has no
  /// IPA, the iPhone install page opens instead ([openInstallPage]).
  /// Nothing is downloaded here.
  Future<void> openInScarlet() async {
    final GithubRelease? release = newer;
    if (release == null || route != GithubUpdateRoute.scarlet) {
      return;
    }
    final String? link = scarletInstallLink(release);
    if (link != null && await _openScarlet(link)) {
      _finish(
        GithubInstallState.done,
        t('Otwarto Scarlet. Potwierdź tam instalację Zen {version}.', {
          'version': release.version,
        }),
      );
      return;
    }
    await openInstallPage(noScarlet: link != null);
  }

  /// iPhone and iPad: opens the iPhone install page (Scarlet's steps);
  /// [noScarlet]: Scarlet did not open. Where no browser opens it, its
  /// address is copied.
  Future<void> openInstallPage({bool noScarlet = false}) async {
    if (await _openPage(kIphoneInstallPageUrl)) {
      _finish(
        GithubInstallState.done,
        noScarlet
            ? t(
                'Nie ma tu Scarlet, więc otwarto stronę instalacji Zen na '
                'iPhone’a.',
              )
            : t('Otwarto stronę instalacji Zen na iPhone’a.'),
      );
      return;
    }
    await _copied(kIphoneInstallPageUrl);
  }

  /// Flatpak, or a release without this device's file: opens the release
  /// page of [newer] (its address is copied where it does not open).
  Future<void> openReleasePage() async {
    final GithubRelease? release = newer;
    if (release == null) {
      return;
    }
    final String url = release.pageUri.toString();
    if (!await _openPage(url)) {
      await _copied(url);
    }
  }

  Future<void> _copied(String url) async {
    try {
      await _copy(url);
    } on Object catch (error) {
      logZenWarning('Kopiowanie adresu aktualizacji: $error');
    }
    _finish(
      GithubInstallState.failed,
      t('Nie udało się otworzyć strony. Skopiowano jej adres: {url}', {
        'url': url,
      }),
    );
  }

  /// Whether the release file of [target] is downloaded and installed by
  /// Zen itself.
  static bool _downloadsUpdates(UpdateTarget target) => switch (target) {
    UpdateTarget.android ||
    UpdateTarget.windows ||
    UpdateTarget.macos ||
    UpdateTarget.linuxTarball ||
    UpdateTarget.linuxDeb => true,
    UpdateTarget.flatpak || UpdateTarget.ios || UpdateTarget.other => false,
  };

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
      // A friend runs a newer Zen: GitHub is asked now; a release signed by
      // the maintainers that came from friends is announced at once.
      ref
        ..listen<String?>(friendsNewerVersionProvider, (_, String? version) {
          if (version != null) {
            unawaited(service.hintNewer(version));
          }
        })
        ..listen<String?>(signedNewerVersionProvider, (_, String? version) {
          if (version != null) {
            unawaited(service.hintNewer(version, signed: true));
          }
        }, fireImmediately: true);
      ref.onDispose(() {
        lifecycle.dispose();
        service.dispose();
      });
      return service;
    });
