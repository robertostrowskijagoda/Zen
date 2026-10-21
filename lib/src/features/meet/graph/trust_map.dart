import 'package:flutter/foundation.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/ledger/space_policy.dart';
import 'package:zen/src/features/feed/thanks_model.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/met_attestation.dart';
import 'package:zen/src/features/meet/events/event_model.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// "Mapa zaufania" on a person's card: what this phone already knows about
// the trust around someone — meetings in person, gratitude cards, time in
// the pyramid, events shared. Facts only: no stars, no scores, no sums.

/// One gathering both went to.
typedef SharedEvent = ({String title, int at});

/// What is known about trust around one person.
@immutable
final class TrustMap {
  const TrustMap({
    this.metByMe,
    this.friendsWhoMet = const <String>[],
    this.thanks = 0,
    this.thanksFrom = const <String>[],
    this.pyramidSince,
    this.sharedEvents = const <SharedEvent>[],
  });

  /// The day this person attested meeting them in person.
  final int? metByMe;

  /// Friends who attested meeting them in person (names).
  final List<String> friendsWhoMet;

  /// Gratitude cards for them this phone sees, and who gave them.
  final int thanks;
  final List<String> thanksFrom;

  /// In this person's pyramid since then.
  final int? pyramidSince;

  /// Gatherings both went to, newest first.
  final List<SharedEvent> sharedEvents;

  bool get isEmpty =>
      metByMe == null &&
      friendsWhoMet.isEmpty &&
      thanks == 0 &&
      pyramidSince == null &&
      sharedEvents.isEmpty;
}

/// An entry of someone's `acts` as the trust map reads it.
typedef ActEntry = ({
  String kind,
  String space,
  String author,
  Map<String, dynamic> body,
});

/// The day (UTC midnight, ms) the author of [acts] attested meeting
/// [account] in person, or null.
int? metDayIn(Iterable<ActEntry> acts, String account) {
  int? out;
  for (final ActEntry e in acts) {
    if (e.kind != kMetKind ||
        e.space != accountSpace('acts', e.author) ||
        e.body['a'] != account) {
      continue;
    }
    final Object? d = e.body['d'];
    final DateTime? day = d is String && d.length == 10
        ? DateTime.tryParse('${d}T00:00:00Z')
        : null;
    if (day == null) {
      continue;
    }
    final int ms = day.millisecondsSinceEpoch;
    if (out == null || ms < out) {
      out = ms;
    }
  }
  return out;
}

/// [metDayIn] over ledger entries.
int? metDayOf(Iterable<LogEntry> acts, String account) => metDayIn(
  acts.map(
    (LogEntry e) =>
        (kind: e.kind, space: e.space, author: e.account, body: e.body),
  ),
  account,
);

/// The days this account met friends in person (normalised address →
/// day), for the timeline and "Dawno". Empty before the ledger is ready.
Map<String, int> metDays(LedgerNode? node) {
  if (node == null || !node.isReady) {
    return const <String, int>{};
  }
  final List<LogEntry> acts = node.entriesOf(spaceKind: 'acts');
  final Map<String, int> out = <String, int>{};
  node.friendAccounts.forEach((String address, String account) {
    final int? day = metDayOf(acts, account);
    if (day != null) {
      out[PeerShareCodec.normalizeAddress(address)] = day;
    }
  });
  return out;
}

/// The trust map of [address] from the ledger ([node]: meetings and
/// gratitude cards, this person's and friends'), the pyramid
/// ([pyramidSince]) and the gatherings this phone knows ([events]:
/// both went, already started, not cancelled; [went] tells whether
/// someone went to one).
TrustMap trustMapOf({
  required String address,
  LedgerNode? node,
  required String Function(String address) nameOf,
  int? pyramidSince,
  Iterable<MeetEvent> events = const <MeetEvent>[],
  bool Function(MeetEvent event, String? address)? went,
  int now = 0,
}) {
  final String a = PeerShareCodec.normalizeAddress(address);
  int? metByMe;
  final List<String> friendsWhoMet = <String>[];
  int thanks = 0;
  final List<String> givers = <String>[];
  final String? account = node != null && node.isReady
      ? node.knownAccountOf(a)
      : null;
  if (node != null && account != null) {
    metByMe = metDayOf(node.entriesOf(spaceKind: 'acts'), account);
    final List<MapEntry<String, String>> friends =
        node.friendAccounts.entries.toList()..sort(
          (MapEntry<String, String> x, MapEntry<String, String> y) =>
              x.key.compareTo(y.key),
        );
    for (final MapEntry<String, String> f in friends) {
      if (f.value == account) {
        continue;
      }
      final int? day = metDayOf(
        node.entriesOf(spaceKind: 'acts', ofAccount: f.value),
        account,
      );
      if (day != null) {
        friendsWhoMet.add(nameOf(f.key));
      }
    }
    final List<ThanksCard> cards = thanksFor(node, account, nameOf: nameOf);
    thanks = cards.length;
    for (final ThanksCard c in cards) {
      if (!givers.contains(c.fromLabel)) {
        givers.add(c.fromLabel);
      }
    }
  }
  final List<SharedEvent> shared = <SharedEvent>[
    if (went != null)
      for (final MeetEvent e in events)
        if (!e.cancelled &&
            (now <= 0 || e.startsAt <= now) &&
            went(e, null) &&
            went(e, a))
          (title: e.title, at: e.startsAt),
  ]..sort((SharedEvent x, SharedEvent y) => y.at.compareTo(x.at));
  return TrustMap(
    metByMe: metByMe,
    friendsWhoMet: friendsWhoMet,
    thanks: thanks,
    thanksFrom: givers,
    pyramidSince: pyramidSince != null && pyramidSince > 0
        ? pyramidSince
        : null,
    sharedEvents: shared,
  );
}
