import 'package:flutter/foundation.dart';
import 'package:zen/src/app/app_version.dart';

/// What this build can do, announced to friends in ping and pong.
///
/// Short, stable names; a new one is added when a feature changes what goes
/// over the wire, never renamed. Informational only: nothing that guards
/// security or privacy may depend on what a peer claims here.
const List<String> kZenCaps = <String>[
  'ledger1',
  'relay1',
  'group_call1',
  'disappear1',
  'meet1',
];

/// The oldest Zen this build still talks to, sent as `minv` in every ping
/// and pong. Raised only when a change breaks talking to older builds (a
/// protocol fix that cannot stay compatible); never above [kAppVersion]
/// (a test checks it). A friend whose Zen is older is told to update
/// instead of quietly missing messages.
const String kMinPeerVersion = '1.11.0';

/// Most capability names taken from one peer.
const int kMaxPeerCaps = 32;

/// Longest capability name taken from a peer.
const int kMaxPeerCapLength = 32;

final RegExp _versionPattern = RegExp(r'^\d{1,4}\.\d{1,4}\.\d{1,4}$');
final RegExp _capPattern = RegExp(r'^[a-z][a-z0-9_]*$');

/// The fields this build adds to every ping and pong it sends to an
/// accepted friend.
Map<String, dynamic> versionHello() => <String, dynamic>{
  'ver': kAppVersion,
  'build': kAppBuild,
  'caps': kZenCaps,
  'minv': kMinPeerVersion,
};

/// What a friend said about their app in a ping or pong.
///
/// Self-reported and unsigned: used only to tell the user that friends run
/// a newer Zen. Never a reason to trust, skip a check or change a protocol.
@immutable
final class PeerVersion {
  const PeerVersion({
    required this.version,
    this.build,
    this.caps = const <String>[],
    this.minVersion,
  });

  /// `major.minor.patch`.
  final String version;
  final int? build;
  final List<String> caps;

  /// The oldest Zen the peer still talks to (`minv`), when it said.
  final String? minVersion;

  bool hasCap(String cap) => caps.contains(cap);

  /// Whether the peer no longer talks to a Zen as old as [ours].
  bool refuses(String ours) {
    final String? min = minVersion;
    return min != null && compareAppVersions(ours, min) < 0;
  }

  /// Reads `ver` / `build` / `caps` from a ping or pong; `null` when the
  /// peer sent no (valid) version.
  static PeerVersion? fromPayload(Map<String, dynamic> payload) {
    final Object? ver = payload['ver'];
    if (ver is! String || !isValidAppVersion(ver)) {
      return null;
    }
    final Object? build = payload['build'];
    final Object? minv = payload['minv'];
    return PeerVersion(
      version: ver,
      build: build is int && build >= 0 && build < 1 << 31 ? build : null,
      caps: capsFromPayload(payload['caps']),
      // Never above the peer's own version (that would be nonsense).
      minVersion:
          minv is String &&
              isValidAppVersion(minv) &&
              compareAppVersions(minv, ver) <= 0
          ? minv
          : null,
    );
  }
}

/// The valid capability names in a peer's `caps` (anything else, and names
/// past [kMaxPeerCaps], is dropped).
List<String> capsFromPayload(Object? caps) => caps is List
    ? caps
          .whereType<String>()
          .where(
            (String c) =>
                c.length <= kMaxPeerCapLength && _capPattern.hasMatch(c),
          )
          .take(kMaxPeerCaps)
          .toList(growable: false)
    : const <String>[];

/// True for `major.minor.patch` (each 1-4 digits).
bool isValidAppVersion(String version) => _versionPattern.hasMatch(version);

/// Compares two `major.minor.patch` versions numerically (`1.10.0` is newer
/// than `1.9.3`). An invalid version sorts below every valid one.
int compareAppVersions(String a, String b) {
  final List<int>? left = _parts(a);
  final List<int>? right = _parts(b);
  if (left == null || right == null) {
    return left == null ? (right == null ? 0 : -1) : 1;
  }
  for (int i = 0; i < 3; i++) {
    final int c = left[i].compareTo(right[i]);
    if (c != 0) {
      return c;
    }
  }
  return 0;
}

List<int>? _parts(String version) {
  if (!isValidAppVersion(version)) {
    return null;
  }
  return version.split('.').map(int.parse).toList(growable: false);
}

/// The newest of [versions] when it is newer than [ours], else `null`.
String? newestVersionAbove(
  Iterable<String> versions, {
  String ours = kAppVersion,
}) {
  String? best;
  for (final String v in versions) {
    if (!isValidAppVersion(v) || compareAppVersions(v, ours) <= 0) {
      continue;
    }
    if (best == null || compareAppVersions(v, best) > 0) {
      best = v;
    }
  }
  return best;
}
