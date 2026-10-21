import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/social/friend_display_name.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

// Gates ("bramy"): a friend F opens the way to one of F's friends — an
// introduction. F decides per friend who asks: free or for a price in
// pyramid points, and whether F's own consent is needed (by default not
// when there is a price: buying opens the gate at once, F's app answers by
// itself). Everyone also sets a price for a first message from people who
// are not friends (stranger_chats.dart); the route planner
// (gate_route.dart) picks the cheaper of the two.

/// The highest price of a gate or a first message (hundredths of a
/// point): one million points.
const int kGateMaxPrice = 100000000;

/// A gate's payment waits this long for its gate; after it the payer may
/// take it back by themselves.
const Duration kGateHoldTime = Duration(days: 7);

/// A payment that waits less than this for its answer is not taken: the
/// gatekeeper must still be able to decide and keep it once the gate opens
/// (the payer could take it back otherwise).
const Duration kGateMinHold = Duration(days: 5);

/// One step of a way waits at most this long: the payment to go through,
/// the gate to open (the gatekeeper's consent too), the next person to have
/// the introduction.
const Duration kGateStepWait = Duration(days: 1);

/// A payment that has not reached this phone yet is waited for this long.
const Duration kGatePaymentWait = Duration(days: 2);

/// How far friends pass on a gatekeeper's terms and friend list (when the
/// gatekeeper allows it), in steps. A way through gates is as long as what
/// is known this way: the planner itself has no limit of gates.
const int kGateRelayDepth = 6;

/// Passed-on gatekeepers in one card, at most (all depths together): the
/// nearest first, so a card stays small however far it reaches.
const int kGateRelayEntries = 40;

/// People listed for one passed-on gatekeeper, at most.
const int kGateRelayList = 200;

/// Friends with their own terms, at most.
const int kGateMaxExceptions = 500;

final RegExp _gateAddress = RegExp(r'^[0-9A-Za-z:._-]{1,64}$');

/// [hundredths] of a point as people read it: "5 pkt", "2,50 pkt".
String formatPoints(int hundredths) => t('{amount} pkt', {
  'amount': hundredths % 100 == 0
      ? '${hundredths ~/ 100}'
      : ZenFormat.money(hundredths),
});

/// How a gatekeeper opens a gate: for free or for [price] (hundredths of a
/// pyramid point), with or without their own consent.
@immutable
final class GateTerms {
  /// [consent] defaults to "yes" for a free gate (the friend decides each
  /// time, as before) and "no" for a priced one (buying opens it).
  const GateTerms({this.price = 0, bool? consent})
    : consent = consent ?? price <= 0;

  /// What nobody has set: free, the gatekeeper decides.
  static const GateTerms standard = GateTerms();

  final int price;

  /// The gatekeeper approves each request; otherwise their app opens the
  /// gate by itself (once paid).
  final bool consent;

  bool get free => price <= 0;

  Map<String, dynamic> toJson() => <String, dynamic>{'p': price, 'c': consent};

  static GateTerms? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final Object? p = json['p'];
    final Object? c = json['c'];
    if (p is! int || p < 0 || p > kGateMaxPrice || c is! bool) {
      return null;
    }
    return GateTerms(price: p, consent: c);
  }

  /// "za darmo", "5 pkt", "5 pkt · za zgodą".
  String get label => <String>[
    if (free) t('za darmo') else formatPoints(price),
    if (consent) t('za zgodą'),
  ].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is GateTerms && other.price == price && other.consent == consent;

  @override
  int get hashCode => Object.hash(price, consent);

  @override
  String toString() => 'GateTerms($price, consent: $consent)';
}

/// This person's own gate settings: the terms for everyone, the friends
/// with their own, and whether friends may pass the terms on.
final class GateSettings {
  GateSettings();

  /// Terms for friends without their own and for people introduced here
  /// through a friend's gate.
  GateTerms defaults = GateTerms.standard;

  /// Friends (normalised addresses) with their own terms.
  final Map<String, GateTerms> perFriend = <String, GateTerms>{};

  /// Friends may pass these terms and this person's friend list on to
  /// their friends ([kGateRelayDepth] steps): longer ways go through here.
  bool relay = false;

  GateTerms termsFor(String address) =>
      perFriend[PeerShareCodec.normalizeAddress(address)] ?? defaults;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'd': defaults.toJson(),
    if (perFriend.isNotEmpty)
      'f': <String, dynamic>{
        for (final MapEntry<String, GateTerms> e in perFriend.entries)
          e.key: e.value.toJson(),
      },
    if (relay) 'r': true,
  };

  static GateSettings fromJson(Object? json) {
    final GateSettings s = GateSettings();
    if (json is! Map) {
      return s;
    }
    s.defaults = GateTerms.fromJson(json['d']) ?? GateTerms.standard;
    final Object? f = json['f'];
    if (f is Map) {
      for (final MapEntry<dynamic, dynamic> e in f.entries.take(
        kGateMaxExceptions,
      )) {
        final GateTerms? terms = GateTerms.fromJson(e.value);
        if (e.key is String && _gateAddress.hasMatch(e.key as String)) {
          if (terms != null) {
            s.perFriend[PeerShareCodec.normalizeAddress(e.key as String)] =
                terms;
          }
        }
      }
    }
    s.relay = json['r'] == true;
    return s;
  }
}

/// How many entries and names a card may still bring (shared by the
/// whole tree while it is read).
final class _Budget {
  int entries = kGateRelayEntries;
}

/// [roots] cut to [budget] gatekeepers in all and [depth] levels, nearest
/// first (breadth-first, so no single branch eats the card): each address
/// once, never one of [exclude] (the one the card is for). A gatekeeper
/// further away is kept only under one that is kept.
List<RelayedGate> trimRelayed(
  List<RelayedGate> roots, {
  int budget = kGateRelayEntries,
  int depth = kGateRelayDepth,
  Set<String> exclude = const <String>{},
}) {
  final Set<RelayedGate> keep = Set<RelayedGate>.identity();
  final Set<String> seen = <String>{...exclude};
  List<RelayedGate> level = roots;
  int left = budget;
  for (int d = 0; d < depth && level.isNotEmpty && left > 0; d++) {
    final List<RelayedGate> next = <RelayedGate>[];
    for (final RelayedGate g in level) {
      if (left <= 0) {
        break;
      }
      if (!seen.add(g.address)) {
        continue;
      }
      keep.add(g);
      left--;
      next.addAll(g.relayed);
    }
    level = next;
  }
  RelayedGate cut(RelayedGate g) => RelayedGate(
    address: g.address,
    terms: g.terms,
    friends: g.friends,
    relayed: <RelayedGate>[
      for (final RelayedGate r in g.relayed)
        if (keep.contains(r)) cut(r),
    ],
  );
  return <RelayedGate>[
    for (final RelayedGate g in roots)
      if (keep.contains(g)) cut(g),
  ];
}

/// A gatekeeper a friend passed on: their terms for people introduced to
/// them, their friends (as the friend has the list) and the gatekeepers
/// they in turn passed on.
@immutable
final class RelayedGate {
  const RelayedGate({
    required this.address,
    required this.terms,
    this.friends = const <String, String>{},
    this.relayed = const <RelayedGate>[],
  });

  final String address;
  final GateTerms terms;

  /// Address → their own name.
  final Map<String, String> friends;
  final List<RelayedGate> relayed;

  Map<String, dynamic> toJson({int depth = kGateRelayDepth}) =>
      <String, dynamic>{
        'a': address,
        ...terms.toJson(),
        if (friends.isNotEmpty)
          'l': <List<String>>[
            for (final MapEntry<String, String> e in friends.entries)
              <String>[e.key, e.value],
          ],
        if (depth > 1 && relayed.isNotEmpty)
          'v': <Map<String, dynamic>>[
            for (final RelayedGate g in relayed) g.toJson(depth: depth - 1),
          ],
      };

  static List<RelayedGate> _list(Object? json, int depth, _Budget budget) {
    if (json is! List || depth <= 0) {
      return const <RelayedGate>[];
    }
    final List<RelayedGate> out = <RelayedGate>[];
    for (final Object? item in json) {
      if (budget.entries <= 0) {
        break;
      }
      final RelayedGate? g = _one(item, depth, budget);
      if (g != null) {
        out.add(g);
      }
    }
    return out;
  }

  static RelayedGate? _one(Object? json, int depth, _Budget budget) {
    if (json is! Map) {
      return null;
    }
    final Object? a = json['a'];
    final GateTerms? terms = GateTerms.fromJson(json);
    if (a is! String || !_gateAddress.hasMatch(a) || terms == null) {
      return null;
    }
    budget.entries--;
    final Map<String, String> friends = <String, String>{};
    final Object? l = json['l'];
    if (l is List) {
      for (final Object? e in l.take(kGateRelayList)) {
        if (e is List &&
            e.length == 2 &&
            e[0] is String &&
            _gateAddress.hasMatch(e[0] as String) &&
            e[1] is String) {
          friends[PeerShareCodec.normalizeAddress(e[0] as String)] =
              sanitizePeerName(e[1] as String);
        }
      }
    }
    return RelayedGate(
      address: PeerShareCodec.normalizeAddress(a),
      terms: terms,
      friends: friends,
      relayed: _list(json['v'], depth - 1, budget),
    );
  }
}

/// What a friend told this person about their gates: their terms for this
/// person and, when they allow it, their terms for others and the
/// gatekeepers among their friends who allow passing on.
@immutable
final class GateCard {
  const GateCard({
    required this.terms,
    this.relay = false,
    this.open,
    this.relayed = const <RelayedGate>[],
  });

  /// The friend's terms for this person.
  final GateTerms terms;

  /// The friend lets this person pass [open] and their list on.
  final bool relay;

  /// The friend's terms for people introduced to them (passed on).
  final GateTerms? open;
  final List<RelayedGate> relayed;

  Map<String, dynamic> toJson() => <String, dynamic>{
    ...terms.toJson(),
    if (relay) 'r': true,
    if (relay && open != null) 'o': open!.toJson(),
    if (relayed.isNotEmpty)
      'v': <Map<String, dynamic>>[
        for (final RelayedGate g in relayed) g.toJson(),
      ],
  };

  /// A card as it came (the frame or the store); null when malformed.
  static GateCard? fromJson(Object? json) {
    if (json is! Map) {
      return null;
    }
    final GateTerms? terms = GateTerms.fromJson(json);
    if (terms == null) {
      return null;
    }
    final bool relay = json['r'] == true;
    return GateCard(
      terms: terms,
      relay: relay,
      open: relay ? GateTerms.fromJson(json['o']) : null,
      relayed: RelayedGate._list(json['v'], kGateRelayDepth, _Budget()),
    );
  }
}

/// A payment put aside in the pyramid, as it stands now.
@immutable
final class GateHold {
  const GateHold({
    required this.from,
    required this.to,
    required this.condBy,
    required this.amount,
    required this.until,
    this.settled,
  });

  /// Pyramid keys: who paid, who gets it, who decides.
  final String from;
  final String to;
  final String condBy;
  final int amount;

  /// After this the payer may take it back by themselves.
  final int until;

  /// Kept (true), returned (false) or still waiting (null).
  final bool? settled;
}

/// The pyramid's points as gates and first messages use them. Payments go
/// only between members; without it only free gates and free first
/// messages work.
abstract interface class GateWallet {
  /// This person's key in the pyramid when a member, else null.
  String? get myKey;

  /// The key of the member at [address] (a device address), else null:
  /// that member's own word, for prices and for checking who paid.
  String? keyOf(String address);

  /// The key a payment to the device at [address] goes to: only once that
  /// device proved it holds the member's key (a member may write anybody's
  /// address into the pyramid). Null otherwise.
  Future<String?> payeeKeyOf(String address);

  /// What this person can spend now.
  int get balance;

  /// Puts [amount] aside for member [to], who keeps or returns it (the payer
  /// takes it back by themselves after [kGateHoldTime]). The payment's id,
  /// or null when it cannot go now.
  Future<String?> hold(String to, int amount, {required String memo});

  /// The payment [id] as the pyramid has it now; null while it is not in.
  GateHold? held(String id);

  /// Keeps ([keep]) or returns payment [id]. Whether it went out.
  Future<bool> settle(String id, {required bool keep});

  /// Fires when payments may have changed (null: never).
  Listenable? get changes;
}

/// Whom this person lets write first, and whom they may write to first
/// (conversations with people who are not friends): gates and paid first
/// messages open them.
abstract interface class ContactPasses {
  /// [address] may now start a conversation with this person: introduced
  /// through a friend's gate ([via]) or paid ([paid]).
  Future<void> letIn(String address, {required bool paid, String via = ''});

  /// This person may now start a conversation with [address].
  Future<void> mayWrite(String address, {required bool paid});

  /// What this person asks for a first message from [address] (hundredths;
  /// 0 = free), or null when [address] may not write first at all.
  int? priceFrom(String address);
}
