import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/runtime/runtime_native_signal_transport.dart';
import 'package:zen/src/features/update/github_release.dart';
import 'package:zen/src/features/update/github_update_installer.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/sha256_sums.dart';
import 'package:zen/src/features/update/share_app_server.dart';
import 'package:zen/src/features/update/store_build.dart';

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

  /// GitHub answered, but with an error (rate limit, server error…).
  failed,
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

/// Looks at the project's newest GitHub release at start and every
/// [checkEvery], and on the person's "Aktualizuj" downloads this platform's
/// file, checks it against the release's `SHA256SUMS` and, once this build
/// knows [releaseKeys], against the maintainer's signature in
/// [kSignedSumsAssetName], and hands it to [installer] (which on Android
/// also checks the signing certificate).
///
/// Only one request to api.github.com per check, with no header but the
/// User-Agent "Zen". Complements the friend-to-friend updates
/// (update_service.dart), which need no server at all.
final class GithubUpdateService extends ChangeNotifier {
  GithubUpdateService({
    required this.installer,
    GithubJsonFetcher? fetchJson,
    Sha256SumsFetcher? fetchSums,
    GithubDownloader? download,
    bool Function()? internetWorks,
    DateTime Function()? now,
    this.currentVersion = kAppVersion,
    this.releaseKeys = kReleaseMaintainers,
    this.firstCheckAfter = const Duration(seconds: 20),
    this.checkEvery = const Duration(hours: 12),
    this.confirmAfter = const Duration(minutes: 2),
  }) : _fetchJson = fetchJson ?? fetchGithubJson,
       _fetchSums = fetchSums ?? fetchSha256Sums,
       _download = download ?? downloadGithubAsset,
       _internetWorks = internetWorks ?? (() => true),
       _now = now ?? DateTime.now;

  final GithubUpdateInstaller installer;
  final String currentVersion;

  /// The maintainer keys a release's [kSignedSumsAssetName] must be signed
  /// with. Empty (as today): only `SHA256SUMS`, which comes from the same
  /// release as the file, so it protects against damage, not against a
  /// forged release.
  final List<String> releaseKeys;
  final Duration firstCheckAfter;
  final Duration checkEvery;

  /// After a first failed attempt GitHub is tried once more this much later
  /// before the warning banner may show (a one-off hiccup says nothing).
  final Duration confirmAfter;

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
  bool _unreachableDismissed = false;
  String? _dismissedVersion;
  Future<void>? _checking;

  GithubInstallState _install = GithubInstallState.idle;
  int _received = 0;
  int _total = 0;
  String? _installMessage;

  final List<Timer> _timers = <Timer>[];
  Timer? _confirm;
  bool _disposed = false;

  GithubCheckState get state => _state;

  /// What GitHub answered when [state] is [GithubCheckState.failed].
  String? get error => _error;

  DateTime? get checkedAt => _checkedAt;

  bool get checking => _checking != null;

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

  /// The banner "Jest nowa wersja…" (until "Później" for that version).
  bool get showNewerBanner {
    final GithubRelease? r = newer;
    return r != null && r.version != _dismissedVersion;
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

  /// Checks after [firstCheckAfter] and then every [checkEvery].
  void start() {
    if (_timers.isNotEmpty || _disposed) {
      return;
    }
    _timers
      ..add(Timer(firstCheckAfter, () => unawaited(check())))
      ..add(Timer.periodic(checkEvery, (_) => unawaited(check())));
  }

  void dismissNewer() {
    _dismissedVersion = newer?.version;
    _notify();
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
    _notify();
    try {
      final GithubRelease? release = GithubRelease.fromJson(
        await _fetchJson(kGithubLatestReleaseUri),
      );
      _reached();
      if (release != null) {
        _latest = release;
      }
      _state = newer != null
          ? GithubCheckState.newer
          : GithubCheckState.upToDate;
    } on GithubStatusException catch (e) {
      _reached();
      if (e.statusCode == HttpStatus.notFound) {
        // Nothing published yet.
        _state = GithubCheckState.upToDate;
      } else {
        _state = GithubCheckState.failed;
        _error = e.toString();
      }
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
      }
      logZenWarning('Sprawdzanie nowej wersji na GitHubie: $e');
    }
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
    if (release == null || name == null || installing) {
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
    for (final Timer timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    _confirm?.cancel();
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
        // The mesh node has peers: the internet works, only GitHub not.
        internetWorks: () {
          try {
            return ref.read(runtimeNodeSnapshotProvider).peers > 0;
          } on Object {
            return false;
          }
        },
      )..start();
      ref.onDispose(service.dispose);
      return service;
    });
