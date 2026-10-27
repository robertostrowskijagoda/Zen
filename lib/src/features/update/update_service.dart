import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/zen_instance.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/core/ledger/ledger_archive.dart';
import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/core/utils/mark_of_the_web.dart';
import 'package:zen/src/core/utils/windows_system_paths.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/security/exported_files.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/update/canary.dart';
import 'package:zen/src/features/update/official_info.dart';
import 'package:zen/src/features/update/release.dart';
import 'package:zen/src/features/update/store_build.dart';
import 'package:zen/src/features/update/update_book.dart';

/// What [UpdateService] needs from the ledger node (a fake in tests).
abstract interface class UpdateHost {
  LedgerDisk get disk;
  BlobStore get blobs;
  Stream<SignalTransportFrame> get frames;
  Stream<String> get greeted;
  Stream<String> get blobCompleted;
  bool isFriend(String address);
  Iterable<String> friends();
  void fetchBlob(String id, List<String> sources);
  Future<void> send(String to, Map<String, dynamic> payload);
}

final class LedgerUpdateHost implements UpdateHost {
  LedgerUpdateHost(this.node, this.friendList);

  final LedgerNode node;
  final Iterable<String> Function() friendList;

  @override
  LedgerDisk get disk => node.disk;

  @override
  BlobStore get blobs => node.blobs;

  @override
  Stream<SignalTransportFrame> get frames => node.transport.frames;

  @override
  Stream<String> get greeted => node.peerGreeted;

  @override
  Stream<String> get blobCompleted => node.mediaCompleted;

  @override
  bool isFriend(String address) => node.isFriendAddress(address);

  @override
  Iterable<String> friends() => friendList();

  @override
  void fetchBlob(String id, List<String> sources) =>
      node.replicator.fetchBlob(id, sources);

  @override
  Future<void> send(String to, Map<String, dynamic> payload) =>
      node.transport.send(remoteAddress: to, payload: payload);
}

enum UpdatePhase {
  /// This build takes no network updates (no maintainer keys in it).
  disabled,

  /// Nothing newer known.
  upToDate,

  /// A newer version is coming in from friends.
  downloading,

  /// Downloaded; the protective wait is not over yet.
  waiting,

  /// Can be installed (the person decides).
  ready,

  /// Newer version known, but not for this platform.
  otherPlatform,
}

@immutable
final class UpdateStatus {
  const UpdateStatus({
    required this.phase,
    this.release,
    this.file,
    this.progress = 0,
    this.readyAt,
    this.vetoed,
  });

  final UpdatePhase phase;
  final SignedRelease? release;
  final ReleaseFile? file;

  /// 0..1 while downloading.
  final double progress;
  final DateTime? readyAt;

  /// The newest known version was vetoed by a maintainer (shown so people
  /// know why it is not offered).
  final ReleaseRevocation? vetoed;
}

/// Brings new versions of the app from friends and passes them on:
///
/// * a friend tells us about a release (`zen_rel`); we take it only when
///   enough maintainers signed it, and fetch the file for this platform
///   from whoever told us (any friend can serve it: blobs are content
///   addressed, so a bad copy is simply rejected);
/// * we tell friends about the newest release we know when we meet them,
///   so it spreads without any server;
/// * maintainers' vetoes travel the same way and stop a release anywhere;
/// * nothing is installed without the person pressing "Zainstaluj".
final class UpdateService extends ChangeNotifier {
  UpdateService({
    required this.host,
    UpdateBook? book,
    String? platform,
    int Function()? now,
    OfficialInfo? buildInfo,
    this.announceEvery = const Duration(hours: 6),
  }) : book = book ?? UpdateBook(currentBuild: kAppBuild),
       platform = platform ?? currentReleasePlatform(),
       buildInfo = buildInfo ?? thisBuildOfficialInfo(),
       _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final UpdateHost host;
  final UpdateBook book;
  final String platform;

  /// What this build shows as donation link, author and repository.
  final OfficialInfo buildInfo;
  final Duration announceEvery;
  final int Function() _now;

  static const String _bookKey = 'update/book';

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  final Map<String, int> _announcedAt = <String, int>{};

  /// Friends that told us about a release: where its files come from.
  final Map<int, Set<String>> _sources = <int, Set<String>>{};
  Timer? _progressTimer;
  Future<void> _queue = Future<void>.value();
  bool _started = false;

  Future<void> start() async {
    if (_started) {
      return;
    }
    _started = true;
    try {
      final Uint8List? raw = await host.disk.read(_bookKey);
      if (raw != null) {
        final Object? json = jsonDecode(utf8.decode(raw));
        // A newer build's book stays as it is (saves are skipped).
        heldAsNewerOn(host.disk, _bookKey, json, current: 1);
        book.restore(json);
      }
    } on Object catch (error, stack) {
      logZenError('Odczyt aktualizacji', error, stack);
    }
    _subs
      ..add(host.frames.listen(_onFrame))
      ..add(
        host.greeted.listen((String peer) => _enqueue(() => _announce(peer))),
      )
      ..add(host.blobCompleted.listen((_) => notifyListeners()));
    _resumeDownload();
    notifyListeners();
  }

  Future<void> stop() async {
    _progressTimer?.cancel();
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  @override
  void dispose() {
    unawaited(stop());
    super.dispose();
  }

  void _enqueue(Future<void> Function() work) {
    _queue = _queue.then((_) async {
      try {
        await work();
      } on Object catch (error, stack) {
        logZenError('Aktualizacje', error, stack);
      }
    });
  }

  /// Waits for queued work (tests).
  Future<void> get idle => _queue;

  Future<void> _save() => host.disk.write(
    _bookKey,
    Uint8List.fromList(utf8.encode(jsonEncode(book.toJson()))),
  );

  // ---- status ----

  UpdateStatus get status {
    if (!book.enabled) {
      return const UpdateStatus(phase: UpdatePhase.disabled);
    }
    final SignedRelease? newest = book.newest;
    final ReleaseRevocation? vetoed = newest == null
        ? null
        : book.revocationOf(newest.manifest.build);
    final SignedRelease? release = book.candidate;
    if (release == null) {
      return UpdateStatus(phase: UpdatePhase.upToDate, vetoed: vetoed);
    }
    final ReleaseFile? file = release.manifest.fileFor(platform);
    if (file == null) {
      return UpdateStatus(
        phase: UpdatePhase.otherPlatform,
        release: release,
        vetoed: vetoed,
      );
    }
    if (!host.blobs.isComplete(file.blob)) {
      final BlobManifest? m = host.blobs.manifest(file.blob);
      final double progress = m == null || m.chunks.isEmpty
          ? 0
          : 1 - host.blobs.missingChunks(file.blob).length / m.chunks.length;
      return UpdateStatus(
        phase: UpdatePhase.downloading,
        release: release,
        file: file,
        progress: progress,
        vetoed: vetoed,
      );
    }
    final int readyAt = book.readyAt(release.manifest.build);
    return UpdateStatus(
      phase: _now() >= readyAt ? UpdatePhase.ready : UpdatePhase.waiting,
      release: release,
      file: file,
      progress: 1,
      readyAt: DateTime.fromMillisecondsSinceEpoch(readyAt),
      vetoed: vetoed,
    );
  }

  /// Which signed details this build shows differently (`donation`,
  /// `author`, `repo`): non-empty means this copy is probably modified.
  /// Empty while nothing signed is known.
  List<String> get officialDifferences {
    final OfficialInfo? signed = book.enabled ? book.signedOfficial : null;
    return signed == null
        ? const <String>[]
        : signed.differencesFrom(buildInfo);
  }

  /// The version of the newest maintainer-signed release that is newer than
  /// this build and not vetoed (null while none is known or updates are off).
  /// The book takes a release only when enough maintainers' signatures
  /// verify, so a value here is a signed fact, not a friend's claim.
  String? get signedNewerVersion =>
      book.enabled ? book.candidate?.manifest.version : null;

  /// The newest trusted canary (null while none is known or updates are
  /// off).
  SignedCanary? get canary => book.enabled ? book.canary : null;

  /// Whether [canary] was not renewed in time.
  bool get canaryExpired => canary?.isExpired(_now()) ?? false;

  // ---- network ----

  /// Sent to friends: the newest release (or, when none is newer than this
  /// build, the one with the signed donation details), vetoes and the
  /// canary.
  Map<String, dynamic> _offerPayload() {
    final SignedRelease? release = book.candidate ?? book.officialSource;
    return <String, dynamic>{
      'type': kReleaseOfferType,
      if (release != null) 'rel': release.toJson(),
      'rev': <Map<String, dynamic>>[
        for (final ReleaseRevocation r in book.revocations) r.toJson(),
      ],
      if (book.canary != null) 'can': book.canary!.toJson(),
    };
  }

  bool get _hasNews =>
      book.candidate != null ||
      book.officialSource != null ||
      book.canary != null ||
      book.revocations.isNotEmpty;

  Future<void> _announce(String peer, {bool force = false}) async {
    if (!book.enabled || !_hasNews) {
      return;
    }
    final String key = PeerShareCodec.normalizeAddress(peer);
    final int now = _now();
    final int? last = _announcedAt[key];
    if (!force && last != null && now - last < announceEvery.inMilliseconds) {
      return;
    }
    _announcedAt[key] = now;
    try {
      await host.send(peer, _offerPayload());
    } on Object catch (error) {
      logZenWarning('Wiadomość o nowej wersji do $peer: $error');
    }
  }

  /// Tells every friend (after taking in a new release or veto).
  Future<void> _announceToAll() async {
    for (final String friend in host.friends()) {
      await _announce(friend, force: true);
    }
  }

  void _onFrame(SignalTransportFrame frame) {
    if (frame.payload['type'] != kReleaseOfferType || !book.enabled) {
      return;
    }
    if (!host.isFriend(frame.from)) {
      // Strangers cannot push releases at us.
      return;
    }
    _enqueue(() => _onOffer(frame.from, frame.payload));
  }

  Future<void> _onOffer(String from, Map<String, dynamic> payload) async {
    bool changed = false;
    final Object? rev = payload['rev'];
    if (rev is List) {
      for (final Object? item in rev.take(20)) {
        final ReleaseRevocation? r = ReleaseRevocation.fromJson(item);
        if (r != null && await book.offerRevocation(r)) {
          changed = true;
        }
      }
    }
    final SignedRelease? release = SignedRelease.fromJson(payload['rel']);
    if (release != null) {
      if (await book.offerRelease(release, now: _now())) {
        changed = true;
      }
      if (await book.offerOfficial(release)) {
        changed = true;
      }
      if (book.release(release.manifest.build) != null) {
        (_sources[release.manifest.build] ??= <String>{}).add(from);
      }
    }
    final SignedCanary? canary = SignedCanary.fromJson(payload['can']);
    if (canary != null && await book.offerCanary(canary)) {
      changed = true;
    }
    if (changed) {
      await _save();
      unawaitedLogged(_announceToAll(), context: 'Przekazanie nowej wersji');
    }
    _resumeDownload();
    final int theirs = release?.manifest.build ?? 0;
    final int ours = book.candidate?.manifest.build ?? 0;
    final int theirCanary = canary?.statement.at ?? 0;
    final int ourCanary = book.canary?.statement.at ?? 0;
    if (ours > theirs ||
        ourCanary > theirCanary ||
        (changed && book.revocations.isNotEmpty)) {
      // They are behind: tell them what we know.
      await _announce(from);
    }
    notifyListeners();
  }

  /// Fetches this platform's file of the current candidate.
  void _resumeDownload() {
    final SignedRelease? release = book.candidate;
    final ReleaseFile? file = release?.manifest.fileFor(platform);
    if (release == null || file == null || host.blobs.isComplete(file.blob)) {
      _progressTimer?.cancel();
      _progressTimer = null;
      return;
    }
    final List<String> sources = <String>[
      ...?_sources[release.manifest.build],
      ...host.friends(),
    ];
    if (sources.isNotEmpty) {
      host.fetchBlob(file.blob, sources.toSet().toList());
    }
    _progressTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
      notifyListeners();
      if (host.blobs.isComplete(file.blob)) {
        _progressTimer?.cancel();
        _progressTimer = null;
      }
    });
  }

  // ---- by hand ----

  /// Loads a `.zenupdate` file (from a website, a USB stick…). Returns a
  /// message for the person.
  Future<String> importBundle(Uint8List data) async {
    if (!book.enabled) {
      return t(
        'Aktualizacje od znajomych włączą się, gdy opiekunowie projektu '
        'opublikują swoje klucze do podpisywania wydań. Do tego czasu nową '
        'wersję pobierz z GitHuba albo od znajomego przez „Podaj dalej”.',
      );
    }
    if (data.isNotEmpty && data.first == 0x7B) {
      return _importJson(data);
    }
    final ReleaseBundle? bundle = ReleaseBundle.decode(data);
    if (bundle == null) {
      return t('To nie jest plik aktualizacji Zen albo jest uszkodzony.');
    }
    final SignedRelease release = bundle.release;
    if (!await release.isTrusted(
      maintainers: book.maintainers,
      threshold: book.threshold,
    )) {
      return t(
        'Aktualizacja nie ma wymaganych podpisów opiekunów — odrzucona.',
      );
    }
    if (await book.offerOfficial(release)) {
      await _save();
      _enqueue(_announceToAll);
      notifyListeners();
    }
    if (release.manifest.build <= book.currentBuild) {
      return t('Masz już tę albo nowszą wersję.');
    }
    if (book.isRevoked(release.manifest.build)) {
      return t('Ta wersja została wycofana przez opiekuna.');
    }
    for (final MapEntry<String, Uint8List> f in bundle.files.entries) {
      await host.blobs.put(f.value, mime: releaseMime(f.key));
    }
    final bool added = await book.offerRelease(release, now: _now());
    await _save();
    _enqueue(_announceToAll);
    _resumeDownload();
    notifyListeners();
    final String v = release.manifest.version;
    return added
        ? t('Wczytano wersję {version}. Zostanie przekazana znajomym.', {
            'version': v,
          })
        : t('Wersja {version} była już znana; pliki uzupełnione.', {
            'version': v,
          });
  }

  /// A maintainer's veto (`revoke-*.json`) or a signed release without its
  /// files (the files then come from friends).
  Future<String> _importJson(Uint8List data) async {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(data));
    } on FormatException {
      return t('To nie jest plik aktualizacji Zen.');
    }
    final ReleaseRevocation? revocation = ReleaseRevocation.fromJson(json);
    if (revocation != null) {
      if (!await revocation.isValid(maintainers: book.maintainers)) {
        return t('Wstrzymanie nie jest podpisane przez opiekuna — odrzucone.');
      }
      final bool added = await book.offerRevocation(revocation);
      await _save();
      _enqueue(_announceToAll);
      notifyListeners();
      return added
          ? t(
              'Wczytano wstrzymanie wersji {build}. Zostanie '
              'przekazane znajomym.',
              {'build': revocation.build},
            )
          : t('To wstrzymanie było już znane.');
    }
    final SignedCanary? canary = SignedCanary.fromJson(json);
    if (canary != null) {
      if (!await canary.isTrusted(
        maintainers: book.maintainers,
        threshold: book.threshold,
      )) {
        return t(
          'Oświadczenie nie ma wymaganych podpisów opiekunów — odrzucone.',
        );
      }
      if (!await book.offerCanary(canary)) {
        return t('To oświadczenie było już znane albo jest starsze.');
      }
      await _save();
      _enqueue(_announceToAll);
      notifyListeners();
      return t(
        'Wczytano oświadczenie opiekunów. Zostanie przekazane '
        'znajomym.',
      );
    }
    final SignedRelease? release = SignedRelease.fromJson(json);
    if (release == null) {
      return t('To nie jest plik aktualizacji Zen.');
    }
    if (!await release.isTrusted(
      maintainers: book.maintainers,
      threshold: book.threshold,
    )) {
      return t(
        'Aktualizacja nie ma wymaganych podpisów opiekunów — odrzucona.',
      );
    }
    final bool official = await book.offerOfficial(release);
    final bool added = await book.offerRelease(release, now: _now());
    await _save();
    _enqueue(_announceToAll);
    _resumeDownload();
    notifyListeners();
    return added
        ? t('Wczytano wersję {version}; pliki przyjdą od znajomych.', {
            'version': release.manifest.version,
          })
        : official
        ? t('Wczytano podpisane dane wydania {version}.', {
            'version': release.manifest.version,
          })
        : t('Ta wersja jest już znana albo nie jest nowsza.');
  }

  /// The bytes of the candidate's file for [forPlatform] (default: this
  /// one), checked against the release.
  Future<Uint8List?> fileBytes({String? forPlatform}) async {
    final SignedRelease? release = book.candidate;
    final ReleaseFile? file = release?.manifest.fileFor(
      forPlatform ?? platform,
    );
    if (file == null) {
      return null;
    }
    final Uint8List? bytes = await host.blobs.read(file.blob);
    if (bytes == null || sha256Hex(bytes) != file.sha256) {
      return null;
    }
    return bytes;
  }

  /// Hands the downloaded version to the system installer (Android) or
  /// saves it for the person to run (computers). Only when [status] is
  /// ready. Returns a message for the person.
  Future<String> install() async {
    final UpdateStatus s = status;
    final ReleaseFile? file = s.file;
    if (s.phase != UpdatePhase.ready || file == null) {
      return t('Aktualizacja nie jest jeszcze gotowa.');
    }
    final Uint8List? bytes = await fileBytes();
    if (bytes == null) {
      return t('Plik aktualizacji jest niepełny albo uszkodzony.');
    }
    if (!kIsWeb && Platform.isAndroid) {
      final Directory dir = await getTemporaryDirectory();
      final File apk = File('${dir.path}/${file.name}');
      await apk.writeAsBytes(bytes, flush: true);
      return installApk(apk.path);
    }
    final Directory? downloads = await getDownloadsDirectory();
    final Directory dir = downloads ?? await ZenInstance.supportDirectory();
    final File out = File('${dir.path}${Platform.pathSeparator}${file.name}');
    await out.writeAsBytes(bytes, flush: true);
    // It came from friends, not from the person's own computer: Windows
    // should ask before running it as it does for any download.
    await markFileFromInternet(out.path);
    // Outside Zen's folders: the panic password finds it there.
    await rememberExportedFile(out.path);
    if (!kIsWeb && Platform.isWindows) {
      unawaited(
        Process.run(windowsExplorerPath(), <String>['/select,', out.path]),
      );
    }
    return t(
      'Zapisano {file} w {folder}. Uruchom go, żeby zaktualizować Zen.',
      {'file': file.name, 'folder': dir.path},
    );
  }
}

const MethodChannel _appUpdateChannel = MethodChannel('zen/app_update');

/// Whether Zen may install apps (Android: "install unknown apps"). Null
/// when it may; otherwise opens the system settings for the person to allow
/// it and returns what to tell them (or why that cannot be done).
Future<String?> requestInstallPermission() async {
  try {
    final bool allowed =
        await _appUpdateChannel.invokeMethod<bool>('canInstall') ?? false;
    if (allowed) {
      return null;
    }
    await _appUpdateChannel.invokeMethod<void>('openInstallSettings');
    return t(
      'Zezwól Zen na instalowanie aplikacji, wróć i naciśnij '
      '„Zainstaluj” jeszcze raz.',
    );
  } on MissingPluginException {
    return t('Instalowanie nie działa na tym urządzeniu.');
  } on PlatformException catch (error) {
    return t('Instalacja nie udała się: {reason}', {
      'reason': error.message ?? error.code,
    });
  }
}

/// Opens the system installer for [path] (Android). The person confirms in
/// the system dialog.
Future<String> installApk(String path) async {
  final String? blocked = await requestInstallPermission();
  if (blocked != null) {
    return blocked;
  }
  try {
    final String? result = await _appUpdateChannel.invokeMethod<String>(
      'install',
      <String, Object>{'path': path},
    );
    // The installer answers with one fixed (Polish) text: said here in the
    // app's language instead.
    return result == null
        ? t('Otwarto instalator systemu.')
        : t('Otwarto instalator systemu — potwierdź instalację.');
  } on MissingPluginException {
    return t('Instalowanie nie działa na tym urządzeniu.');
  } on PlatformException catch (error) {
    return t('Instalacja nie udała się: {reason}', {
      'reason': error.message ?? error.code,
    });
  }
}

/// This app's own installer file (Android: the APK it was installed from),
/// for passing on ("Podaj dalej").
Future<String?> ownApkPath() async {
  if (kIsWeb || !Platform.isAndroid) {
    return null;
  }
  try {
    return await _appUpdateChannel.invokeMethod<String>('apkPath');
  } on Object {
    return null;
  }
}

/// The running update service, or `null` while the ledger is off.
final Provider<UpdateService?> updateServiceProvider = Provider<UpdateService?>(
  (Ref ref) {
    // A store build is updated by its store.
    if (isStoreBuild) {
      return null;
    }
    final LedgerNode? node = ref.watch(ledgerNodeProvider);
    if (node == null) {
      return null;
    }
    final UpdateService service = UpdateService(
      host: LedgerUpdateHost(node, node.friendAddresses),
    );
    unawaitedLogged(
      node.start().then((_) => service.start()),
      context: 'Start aktualizacji',
    );
    ref.onDispose(service.dispose);
    return service;
  },
);
