import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/census/network_census.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The census key of an account: derived from its self key (held by the
/// account's own devices only), never the self key itself.
Uint8List censusKeyOf(Uint8List selfKey) => Uint8List.fromList(
  crypto.Hmac(
    crypto.sha256,
    selfKey,
  ).convert(utf8.encode('zen.census.key.v1')).bytes,
);

/// The network census of this phone (network_census.dart): started with
/// the ledger, it takes friends' sketches and sends its own.
final Provider<NetworkCensus> networkCensusProvider = Provider<NetworkCensus>((
  Ref ref,
) {
  final NetworkCensus census = NetworkCensus(
    disk: ref.read(ledgerDiskProvider),
    send: (String to, Map<String, dynamic> payload) => ref
        .read(signalTransportProvider)
        .send(remoteAddress: to, payload: payload),
    isFriend: (String address) =>
        ref
            .read(socialHubControllerProvider)
            .friendByAddress(address)
            ?.status ==
        FriendRelationshipStatus.accepted,
    // The account counts once its key is at hand (all its devices give
    // the same identifier).
    secret: () {
      if (!ref.read(ledgerNodeEnabledProvider)) {
        return null;
      }
      final LedgerNode? node = ref.read(ledgerNodeProvider);
      final Uint8List? selfKey = node != null && node.isReady
          ? node.identity.selfKey
          : null;
      return selfKey == null ? null : censusKeyOf(selfKey);
    },
  );
  unawaitedLogged(census.load(), context: 'Licznik sieci');
  final StreamSubscription<SignalTransportFrame> frames = ref
      .read(signalTransportProvider)
      .frames
      .listen(
        (SignalTransportFrame frame) =>
            unawaitedLogged(census.onFrame(frame), context: 'Licznik sieci'),
      );
  ref.onDispose(() {
    unawaitedLogged(frames.cancel(), context: 'Licznik sieci');
    census.dispose();
  });
  return census;
});

/// What "O aplikacji" shows about the network.
@immutable
final class NetworkCounts {
  const NetworkCounts({this.census, this.pyramidMembers});

  /// The estimate of people in the Zen network (null: the census does not
  /// run on this phone).
  final CensusView? census;

  /// Members of the pyramid this phone keeps, exactly (null: none, or the
  /// pyramid is off).
  final int? pyramidMembers;
}

/// The network numbers, from the services that already run (nothing is
/// started for them).
final Provider<NetworkCounts> networkCountsProvider = Provider<NetworkCounts>((
  Ref ref,
) {
  CensusView? census;
  if (ref.exists(networkCensusProvider)) {
    final NetworkCensus running = ref.watch(networkCensusProvider);
    void changed() => ref.invalidateSelf();
    running.addListener(changed);
    ref.onDispose(() => running.removeListener(changed));
    census = running.view;
  }
  int? pyramidMembers;
  if (ref.read(featureFlagsProvider).isEnabled(ZenFeature.pyramid) &&
      ref.exists(pyramidServiceProvider)) {
    final int? count = ref.read(pyramidServiceProvider).state?.occupant.length;
    pyramidMembers = count == null || count == 0 ? null : count;
  }
  return NetworkCounts(census: census, pyramidMembers: pyramidMembers);
});

/// [estimate] as shown: exact below 100, then to two significant digits.
int roundCensusEstimate(int estimate) {
  if (estimate < 100) {
    return estimate < 1 ? 1 : estimate;
  }
  int scale = 1;
  while (estimate ~/ scale >= 100) {
    scale *= 10;
  }
  return (estimate / scale).round() * scale;
}
