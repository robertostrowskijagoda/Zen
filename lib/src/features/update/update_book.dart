import 'package:zen/src/features/update/canary.dart';
import 'package:zen/src/features/update/release.dart';

/// What this device knows about new versions (§14.2): trusted releases
/// newer than itself, when each was first seen, the maintainers' vetoes,
/// the newest signed donation details (§14.3) and the newest canary.
/// Pure bookkeeping; [UpdateService] does the network and files.
final class UpdateBook {
  UpdateBook({
    required this.currentBuild,
    this.maintainers = kReleaseMaintainers,
    this.threshold = kReleaseThreshold,
    this.embargo = kReleaseEmbargo,
  });

  final int currentBuild;
  final List<String> maintainers;
  final int threshold;
  final Duration embargo;

  /// How many newer releases are kept (the newest few).
  static const int keep = 3;

  final Map<int, SignedRelease> _releases = <int, SignedRelease>{};
  final Map<int, int> _firstSeen = <int, int>{};
  final Map<String, ReleaseRevocation> _revocations =
      <String, ReleaseRevocation>{};

  /// The newest trusted release that carries [OfficialInfo], whatever its
  /// build (also this very build or an older one).
  SignedRelease? _officialSource;
  SignedCanary? _canary;

  /// Whether network updates are possible in this build at all.
  bool get enabled => maintainers.length >= threshold;

  Iterable<SignedRelease> get releases => _releases.values;

  Iterable<ReleaseRevocation> get revocations => _revocations.values;

  bool isRevoked(int build) =>
      _revocations.values.any((ReleaseRevocation r) => r.build == build);

  ReleaseRevocation? revocationOf(int build) => _revocations.values
      .where((ReleaseRevocation r) => r.build == build)
      .firstOrNull;

  SignedRelease? release(int build) => _releases[build];

  /// The release the signed donation details come from.
  SignedRelease? get officialSource => _officialSource;

  /// The donation link, author and repository the maintainers signed.
  OfficialInfo? get signedOfficial => _officialSource?.manifest.official;

  /// The newest trusted canary.
  SignedCanary? get canary => _canary;

  /// The mirrors named by the newest signed release.
  List<String> get mirrors =>
      (newest ?? _officialSource)?.manifest.mirrors ?? const <String>[];

  /// Remembers the signed donation details of [release] when it is trusted
  /// and newer than what we have — even when the release itself is not
  /// newer than this build. Returns whether anything changed.
  Future<bool> offerOfficial(SignedRelease release) async {
    if (!enabled ||
        release.manifest.official == null ||
        (_officialSource != null &&
            _officialSource!.manifest.build >= release.manifest.build) ||
        !await release.isTrusted(
          maintainers: maintainers,
          threshold: threshold,
        )) {
      return false;
    }
    _officialSource = release;
    return true;
  }

  /// Takes [canary] when trusted and newer than the one we have.
  Future<bool> offerCanary(SignedCanary canary) async {
    if (!enabled ||
        (_canary != null && _canary!.statement.at >= canary.statement.at) ||
        !await canary.isTrusted(
          maintainers: maintainers,
          threshold: threshold,
        )) {
      return false;
    }
    _canary = canary;
    return true;
  }

  /// The newest release that is not vetoed.
  SignedRelease? get candidate {
    final List<int> builds = _releases.keys.toList()..sort();
    for (final int b in builds.reversed) {
      if (!isRevoked(b)) {
        return _releases[b];
      }
    }
    return null;
  }

  /// The newest release we know of, vetoed or not (to say it was vetoed).
  SignedRelease? get newest {
    if (_releases.isEmpty) {
      return null;
    }
    final int b = _releases.keys.reduce((int a, int b) => a > b ? a : b);
    return _releases[b];
  }

  /// When [build] may be offered for installing: [embargo] after the later
  /// of its publication and the moment this device first saw it (signers'
  /// clocks cannot shorten the wait).
  int readyAt(int build) {
    final SignedRelease? r = _releases[build];
    final int seen = _firstSeen[build] ?? 0;
    final int from = r == null
        ? seen
        : (r.manifest.publishedAt > seen ? r.manifest.publishedAt : seen);
    return from + embargo.inMilliseconds;
  }

  /// Takes [release] if trusted, newer than this build and not vetoed.
  /// Returns whether it is new here.
  Future<bool> offerRelease(SignedRelease release, {required int now}) async {
    final int build = release.manifest.build;
    if (!enabled ||
        build <= currentBuild ||
        _releases.containsKey(build) ||
        isRevoked(build)) {
      return false;
    }
    final int oldest = _releases.isEmpty
        ? 0
        : _releases.keys.reduce((int a, int b) => a < b ? a : b);
    if (_releases.length >= keep && build < oldest) {
      return false;
    }
    if (!await release.isTrusted(
      maintainers: maintainers,
      threshold: threshold,
    )) {
      return false;
    }
    _releases[build] = release;
    _firstSeen[build] = now;
    if (release.manifest.official != null &&
        (_officialSource == null || _officialSource!.manifest.build < build)) {
      _officialSource = release;
    }
    while (_releases.length > keep) {
      final int drop = _releases.keys.reduce((int a, int b) => a < b ? a : b);
      _releases.remove(drop);
      _firstSeen.remove(drop);
    }
    return true;
  }

  /// Takes a maintainer's veto; returns whether it is new here.
  Future<bool> offerRevocation(ReleaseRevocation revocation) async {
    final String key = '${revocation.build}|${revocation.key}';
    if (!enabled ||
        revocation.build <= currentBuild ||
        _revocations.containsKey(key) ||
        _revocations.length >= 50 ||
        !await revocation.isValid(maintainers: maintainers)) {
      return false;
    }
    _revocations[key] = revocation;
    return true;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': 1,
    'rel': <Map<String, dynamic>>[
      for (final MapEntry<int, SignedRelease> e in _releases.entries)
        <String, dynamic>{
          'r': e.value.toJson(),
          'seen': _firstSeen[e.key] ?? 0,
        },
    ],
    'rev': <Map<String, dynamic>>[
      for (final ReleaseRevocation r in _revocations.values) r.toJson(),
    ],
    if (_officialSource != null) 'off': _officialSource!.toJson(),
    if (_canary != null) 'can': _canary!.toJson(),
  };

  /// Puts back what was saved (our own disk: signatures were checked when
  /// it came in; releases not newer than this build are dropped).
  void restore(Object? json) {
    if (json is! Map || json['v'] != 1) {
      return;
    }
    final Object? rel = json['rel'];
    if (rel is List) {
      for (final Object? item in rel) {
        if (item is! Map) {
          continue;
        }
        final SignedRelease? r = SignedRelease.fromJson(item['r']);
        final Object? seen = item['seen'];
        if (r != null && r.manifest.build > currentBuild && seen is int) {
          _releases[r.manifest.build] = r;
          _firstSeen[r.manifest.build] = seen;
        }
      }
    }
    final Object? rev = json['rev'];
    if (rev is List) {
      for (final Object? item in rev) {
        final ReleaseRevocation? r = ReleaseRevocation.fromJson(item);
        if (r != null) {
          _revocations['${r.build}|${r.key}'] = r;
        }
      }
    }
    final SignedRelease? official = SignedRelease.fromJson(json['off']);
    if (official != null && official.manifest.official != null) {
      _officialSource = official;
    }
    _canary = SignedCanary.fromJson(json['can']) ?? _canary;
  }
}
