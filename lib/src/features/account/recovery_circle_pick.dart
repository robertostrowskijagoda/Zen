import 'dart:convert';

import 'package:zen/src/core/ledger/ledger_codec.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// Most people who keep pieces of one account's key.
///
/// Shamir's scheme over GF(256) would take up to 255 and a piece is a few
/// kilobytes with its signature, so neither sets the limit. The recovery
/// does: it tries at most 600 combinations of the halves that came, and
/// every 4 of 12 (the largest band, [pieceThreshold]) is 495 of them, so
/// even with some halves spoilt the right ones are always tried. Twelve
/// also keeps a hand-out (a message and an answer each) small when the
/// close friends change.
const int kMaxPieceHolders = 12;

/// Who keeps the pieces of [account]'s key: its close friends, each once,
/// at most [kMaxPieceHolders]. With more of them, an order of their own
/// for each account (not the same friends keep everyone's), stable when
/// one more is added: only the last place changes.
List<String> pieceHolders({
  required Iterable<String> close,
  required String account,
}) {
  final Set<String> seen = <String>{};
  final List<String> all = <String>[
    for (final String a in close)
      if (a.isNotEmpty && seen.add(PeerShareCodec.normalizeAddress(a)))
        PeerShareCodec.normalizeAddress(a),
  ];
  String rank(String a) => sha256Hex(utf8.encode('pieces|$account|$a'));
  all.sort((String a, String b) => rank(a).compareTo(rank(b)));
  return all.take(kMaxPieceHolders).toList();
}
