import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:zen/src/features/meet/encounters.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/nearby.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// How recently a friend must have been near to be suggested.
const Duration kEatTogetherWindow = Duration(hours: 1);

/// "Ola jest niedaleko i chce coś zjeść — napisz?": a friend whose status
/// is "Chcę coś zjeść razem" and whom this phone saw nearby lately.
@immutable
final class EatTogether {
  const EatTogether({
    required this.friend,
    required this.seenAt,
    required this.status,
  });

  /// The friend's address (normalised).
  final String friend;

  /// When this phone last saw them (Bluetooth: "W pobliżu", "Mijani").
  final int seenAt;
  final IntentStatus status;
}

/// Friends to suggest eating with: their status says they want to eat
/// together ([hungry], as [MeetService.friendsWith] gives them), and this
/// phone saw them within [window] — in range now ([people]) or passed
/// ([encounters]). Worked out on this phone only: nobody's place is sent
/// anywhere. Newest sighting first; [dismissed] stay out.
List<EatTogether> eatTogetherNearby({
  required Iterable<(String, IntentStatus)> hungry,
  required Iterable<NearbyPerson> people,
  required Iterable<Encounter> encounters,
  required int now,
  Set<String> dismissed = const <String>{},
  Duration window = kEatTogetherWindow,
}) {
  final Map<String, int> seen = <String, int>{};
  void saw(String friend, int at) {
    final String a = PeerShareCodec.normalizeAddress(friend);
    seen[a] = max(seen[a] ?? 0, at);
  }

  for (final NearbyPerson p in people) {
    final String? friend = p.friend;
    if (friend != null) {
      saw(friend, p.seenAt);
    }
  }
  for (final Encounter e in encounters) {
    saw(e.friend, e.end);
  }
  final List<EatTogether> out = <EatTogether>[
    for (final (String address, IntentStatus status) in hungry)
      if (status.kind == IntentKind.eat && status.activeAt(now))
        if (seen[PeerShareCodec.normalizeAddress(address)] case final int at
            when now - at <= window.inMilliseconds &&
                at <= now + 60000 &&
                !dismissed.contains(PeerShareCodec.normalizeAddress(address)))
          EatTogether(
            friend: PeerShareCodec.normalizeAddress(address),
            seenAt: at,
            status: status,
          ),
  ];
  out.sort((EatTogether a, EatTogether b) => b.seenAt.compareTo(a.seenAt));
  return out;
}
