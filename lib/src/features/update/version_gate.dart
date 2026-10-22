import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_version.dart';
import 'package:zen/src/app/peer_version.dart';
import 'package:zen/src/features/update/github_update_service.dart';

/// What friends' apps said about themselves in their last ping or pong —
/// version, capabilities ([PeerVersion.caps]) and the oldest Zen they still
/// talk to ([PeerVersion.minVersion]) — by address. Kept while the app
/// runs: every ping and pong says it again.
///
/// Self-reported: for telling the person to update and for choosing what
/// to send; never a reason to trust a peer or skip a check.
final class PeerHelloBook extends Notifier<Map<String, PeerVersion>> {
  @override
  Map<String, PeerVersion> build() => const <String, PeerVersion>{};

  /// Takes what [address] said.
  void note(String address, PeerVersion hello) {
    final PeerVersion? had = state[address];
    if (had != null &&
        had.version == hello.version &&
        had.build == hello.build &&
        had.minVersion == hello.minVersion &&
        listEquals(had.caps, hello.caps)) {
      return;
    }
    state = <String, PeerVersion>{...state, address: hello};
  }

  /// What [address] said last, if anything.
  PeerVersion? of(String address) => state[address];
}

final NotifierProvider<PeerHelloBook, Map<String, PeerVersion>>
peerHelloBookProvider =
    NotifierProvider<PeerHelloBook, Map<String, PeerVersion>>(
      PeerHelloBook.new,
    );

/// This build is too old: friends' apps (or the project's newest release)
/// no longer support it.
@immutable
final class UpdateRequired {
  const UpdateRequired({required this.minimum, required this.byRelease});

  /// The oldest version still supported.
  final String minimum;

  /// Said by the newest release (else by friends' apps).
  final bool byRelease;
}

/// Whether [ours] is older than what [friends] still talk to or than the
/// newest release's [releaseMinimum]; the highest such minimum.
UpdateRequired? updateRequiredFor({
  required Iterable<PeerVersion> friends,
  String? releaseMinimum,
  String ours = kAppVersion,
}) {
  String? minimum;
  bool byRelease = false;
  if (releaseMinimum != null &&
      isValidAppVersion(releaseMinimum) &&
      compareAppVersions(ours, releaseMinimum) < 0) {
    minimum = releaseMinimum;
    byRelease = true;
  }
  for (final PeerVersion friend in friends) {
    final String? min = friend.minVersion;
    if (min == null || !friend.refuses(ours)) {
      continue;
    }
    if (minimum == null || compareAppVersions(min, minimum) > 0) {
      minimum = min;
      byRelease = false;
    }
  }
  return minimum == null
      ? null
      : UpdateRequired(minimum: minimum, byRelease: byRelease);
}

/// [updateRequiredFor] this build, from what friends said and what GitHub's
/// newest release says.
final Provider<UpdateRequired?> updateRequiredProvider =
    Provider<UpdateRequired?>((Ref ref) {
      final Map<String, PeerVersion> hellos = ref.watch(peerHelloBookProvider);
      final GithubUpdateService? github = ref.watch(
        githubUpdateServiceProvider,
      );
      if (github != null) {
        void changed() => ref.invalidateSelf();
        github.addListener(changed);
        ref.onDispose(() => github.removeListener(changed));
      }
      return updateRequiredFor(
        friends: hellos.values,
        releaseMinimum: github?.minimumVersion,
      );
    });
