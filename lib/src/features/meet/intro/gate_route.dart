import 'package:flutter/foundation.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';

/// What writing to someone directly takes, as this phone can tell.
@immutable
final class DirectTerms {
  /// Free, or [price] for the first message; [payable]: both are in the
  /// pyramid, so a price can be paid at all.
  const DirectTerms.price(this.price, {this.payable = false})
    : known = true,
      closed = false;

  /// They take no first message from this person.
  const DirectTerms.closed()
    : known = true,
      closed = true,
      price = 0,
      payable = false;

  /// Not known here (outside the pyramid, or nothing published).
  const DirectTerms.unknown()
    : known = false,
      closed = false,
      price = 0,
      payable = false;

  final bool known;
  final bool closed;
  final int price;
  final bool payable;

  /// Writing directly works for sure: open, and free or payable.
  bool get usable => known && !closed && (price <= 0 || payable);

  String get label => !known
      ? t('nie wiadomo')
      : closed
      ? t('nie przyjmuje wiadomości')
      : price <= 0
      ? t('za darmo')
      : formatPoints(price);

  @override
  bool operator ==(Object other) =>
      other is DirectTerms &&
      other.known == known &&
      other.closed == closed &&
      other.price == price &&
      other.payable == payable;

  @override
  int get hashCode => Object.hash(known, closed, price, payable);

  @override
  String toString() => 'DirectTerms($label)';
}

/// One gate on a way: [via] opens the way to [to] (one of [via]'s friends)
/// on [terms] (null: [via] has not said — they decide, as for a request).
@immutable
final class GateStepPlan {
  const GateStepPlan({
    required this.via,
    required this.to,
    this.toName = '',
    this.terms,
  });

  final String via;
  final String to;
  final String toName;
  final GateTerms? terms;

  int get price => terms?.price ?? 0;

  /// Waits for someone's decision (consent, or terms not known).
  bool get pending => terms == null || terms!.consent;
}

/// A way through gates, cheapest first: its price, the steps that wait for
/// someone's decision, the number of gates.
@immutable
final class GatePlan {
  const GatePlan(this.steps);

  final List<GateStepPlan> steps;

  int get price => steps.fold(0, (int s, GateStepPlan g) => s + g.price);
  int get pending => steps.where((GateStepPlan g) => g.pending).length;
  int get unknown => steps.where((GateStepPlan g) => g.terms == null).length;
  bool get isEmpty => steps.isEmpty;

  /// The people the way goes through: the friend first, then the ones
  /// each gate opens to, without the target.
  List<String> get through => <String>[
    if (steps.isNotEmpty) steps.first.via,
    for (int i = 0; i < steps.length - 1; i++) steps[i].to,
  ];
}

/// What [planReach] chose.
enum ReachChoice {
  /// Writing directly is the cheapest (or the only way).
  direct,

  /// The gates are cheaper.
  gates,

  /// Nothing known works.
  none,
}

/// Both ways to someone and the cheaper one.
@immutable
final class ReachPlan {
  const ReachPlan({
    required this.direct,
    required this.best,
    this.gates,
    this.friend = false,
  });

  /// Already a friend: just write.
  final bool friend;
  final DirectTerms direct;

  /// The cheapest way through gates, if any is known.
  final GatePlan? gates;
  final ReachChoice best;
}

/// The cost of a partial way, compared lexicographically: price, steps
/// waiting for a decision, gates.
@immutable
final class _Cost implements Comparable<_Cost> {
  const _Cost(this.price, this.pending, this.steps);

  final int price;
  final int pending;
  final int steps;

  _Cost plus(GateTerms? terms) => _Cost(
    price + (terms?.price ?? 0),
    pending + (terms == null || terms.consent ? 1 : 0),
    steps + 1,
  );

  @override
  int compareTo(_Cost o) {
    if (price != o.price) {
      return price.compareTo(o.price);
    }
    if (pending != o.pending) {
      return pending.compareTo(o.pending);
    }
    return steps.compareTo(o.steps);
  }
}

/// The cheapest way to [target] through gates, over what this phone knows:
/// this person's [friends] (no gate to them), the friend lists it holds and
/// the ones friends passed on ([friendsOf]), and each gatekeeper's terms for
/// this person ([termsOf]; null: not known — counted as waiting for a
/// decision). A priced gate counts only when [canPay] (both are in the
/// pyramid). Dijkstra: cheapest first, then fewer steps waiting for a
/// decision, then fewer gates; at most [maxSteps] gates. Empty when no way
/// is known. [self] is this person's own address (never a step).
GatePlan cheapestGates({
  required String target,
  required List<String> friends,
  required Map<String, String> Function(String person) friendsOf,
  required GateTerms? Function(String gatekeeper) termsOf,
  bool Function(String gatekeeper)? canPay,
  String self = '',
  int maxSteps = kGateMaxSteps,
}) {
  String n(String a) => PeerShareCodec.normalizeAddress(a);
  final String goal = n(target);
  final String me = self.isEmpty ? '' : n(self);
  final Set<String> mine = <String>{for (final String f in friends) n(f)};
  if (goal.isEmpty || mine.contains(goal) || goal == me) {
    return const GatePlan(<GateStepPlan>[]);
  }
  final Map<String, _Cost> best = <String, _Cost>{};
  final Map<String, GateStepPlan> stepTo = <String, GateStepPlan>{};
  final Set<String> done = <String>{};
  // A small list as the queue: ways are short and lists are bounded.
  final List<(String, _Cost, int)> queue = <(String, _Cost, int)>[];
  int seq = 0;
  void push(String at, _Cost c) => queue.add((at, c, seq++));
  for (final String f in friends) {
    final String a = n(f);
    if (a == me || best.containsKey(a)) {
      continue;
    }
    best[a] = const _Cost(0, 0, 0);
    push(a, const _Cost(0, 0, 0));
  }
  while (queue.isNotEmpty) {
    int pick = 0;
    for (int i = 1; i < queue.length; i++) {
      final int c = queue[i].$2.compareTo(queue[pick].$2);
      if (c < 0 || (c == 0 && queue[i].$3 < queue[pick].$3)) {
        pick = i;
      }
    }
    final (String at, _Cost cost, int _) = queue.removeAt(pick);
    if (!done.add(at)) {
      continue;
    }
    if (at == goal) {
      break;
    }
    if (cost.steps >= maxSteps) {
      continue;
    }
    final GateTerms? terms = termsOf(at);
    if (terms != null && !terms.free && !(canPay?.call(at) ?? false)) {
      // A price nobody here can pay: no gate through [at].
      continue;
    }
    final Map<String, String> next = friendsOf(at);
    for (final MapEntry<String, String> e in next.entries) {
      final String to = n(e.key);
      if (to.isEmpty || to == me || mine.contains(to) || done.contains(to)) {
        continue;
      }
      final _Cost c = cost.plus(terms);
      final _Cost? had = best[to];
      if (had == null || c.compareTo(had) < 0) {
        best[to] = c;
        stepTo[to] = GateStepPlan(
          via: at,
          to: to,
          toName: e.value,
          terms: terms,
        );
        push(to, c);
      }
    }
  }
  if (!stepTo.containsKey(goal)) {
    return const GatePlan(<GateStepPlan>[]);
  }
  final List<GateStepPlan> steps = <GateStepPlan>[];
  String at = goal;
  while (stepTo.containsKey(at) && steps.length <= maxSteps) {
    final GateStepPlan s = stepTo[at]!;
    steps.insert(0, s);
    at = s.via;
  }
  return GatePlan(steps);
}

/// Both ways to [target] and the cheaper one: writing directly on
/// [direct], or the cheapest gates ([cheapestGates]). On a tie writing
/// directly wins (one step, nobody in between). A direct way that is not
/// known never wins over a known gate way.
ReachPlan planReach({
  required String target,
  required List<String> friends,
  required Map<String, String> Function(String person) friendsOf,
  required GateTerms? Function(String gatekeeper) termsOf,
  bool Function(String gatekeeper)? canPay,
  DirectTerms direct = const DirectTerms.unknown(),
  String self = '',
  int maxSteps = kGateMaxSteps,
}) {
  final String goal = PeerShareCodec.normalizeAddress(target);
  if (friends.any((String f) => PeerShareCodec.normalizeAddress(f) == goal)) {
    return const ReachPlan(
      direct: DirectTerms.price(0),
      best: ReachChoice.direct,
      friend: true,
    );
  }
  final GatePlan gates = cheapestGates(
    target: target,
    friends: friends,
    friendsOf: friendsOf,
    termsOf: termsOf,
    canPay: canPay,
    self: self,
    maxSteps: maxSteps,
  );
  final GatePlan? way = gates.isEmpty ? null : gates;
  final ReachChoice best;
  if (way == null) {
    best = direct.usable ? ReachChoice.direct : ReachChoice.none;
  } else if (!direct.usable) {
    best = ReachChoice.gates;
  } else {
    best = direct.price <= way.price ? ReachChoice.direct : ReachChoice.gates;
  }
  return ReachPlan(direct: direct, gates: way, best: best);
}

// ---- a way being opened ----

/// Where one gate of a way being opened stands.
enum GateStepState {
  /// Not started (an earlier gate first).
  waiting,

  /// The payment waits for the pyramid's treasurers.
  paying,

  /// Asked; waiting for the gate to open (and for the next person to have
  /// the introduction).
  asking,

  /// Open.
  open,

  /// Did not open.
  failed;

  static GateStepState byName(Object? name) => GateStepState.values.firstWhere(
    (GateStepState s) => s.name == name,
    orElse: () => waiting,
  );
}

/// One gate of a way being opened.
final class GateRunStep {
  GateRunStep({
    required this.via,
    required this.to,
    this.toName = '',
    this.price = 0,
    this.state = GateStepState.waiting,
    this.payment,
    this.caseId,
    this.startedAt = 0,
  });

  final String via;
  final String to;
  final String toName;

  /// What the plan said it costs (hundredths).
  final int price;
  GateStepState state;

  /// The payment put aside for [via].
  String? payment;

  /// The introduction case at [via].
  String? caseId;
  int startedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': via,
    'y': to,
    if (toName.isNotEmpty) 'yn': toName,
    if (price > 0) 'p': price,
    's': state.name,
    'x': ?payment,
    'c': ?caseId,
    if (startedAt > 0) 'at': startedAt,
  };

  static GateRunStep? fromJson(Object? json) {
    if (json is! Map || json['v'] is! String || json['y'] is! String) {
      return null;
    }
    final Object? p = json['p'];
    final Object? at = json['at'];
    return GateRunStep(
      via: json['v'] as String,
      to: json['y'] as String,
      toName: json['yn'] is String ? json['yn'] as String : '',
      price: p is int && p > 0 && p <= kGateMaxPrice ? p : 0,
      state: GateStepState.byName(json['s']),
      payment: json['x'] is String ? json['x'] as String : null,
      caseId: json['c'] is String ? json['c'] as String : null,
      startedAt: at is int ? at : 0,
    );
  }
}

/// How a way being opened stands.
enum GateRunState {
  going,
  done,
  failed;

  static GateRunState byName(Object? name) => GateRunState.values.firstWhere(
    (GateRunState s) => s.name == name,
    orElse: () => failed,
  );
}

/// A way through gates this person is opening, gate after gate: each one
/// paid only when its turn comes, every payment kept by its gatekeeper only
/// when the whole way is open and returned when a later gate fails.
final class GateRun {
  GateRun({
    required this.id,
    required this.target,
    required this.targetName,
    required this.steps,
    required this.at,
    this.note = '',
    this.state = GateRunState.going,
    this.reason = '',
    int? changedAt,
  }) : changedAt = changedAt ?? at;

  final String id;
  final String target;
  final String targetName;
  final List<GateRunStep> steps;
  final int at;

  /// The asker's words for every gatekeeper and the target.
  final String note;
  GateRunState state;

  /// Why it failed, as shown.
  String reason;
  int changedAt;

  int get price => steps.fold(0, (int s, GateRunStep g) => s + g.price);

  bool get going => state == GateRunState.going;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'y': target,
    'yn': targetName,
    'st': <Map<String, dynamic>>[for (final GateRunStep s in steps) s.toJson()],
    'at': at,
    if (note.isNotEmpty) 't': note,
    's': state.name,
    if (reason.isNotEmpty) 'why': reason,
    'ch': changedAt,
  };

  static GateRun? fromJson(Object? json) {
    if (json is! Map ||
        json['id'] is! String ||
        json['y'] is! String ||
        json['at'] is! int ||
        json['st'] is! List) {
      return null;
    }
    final List<GateRunStep> steps = <GateRunStep>[
      for (final Object? s in (json['st'] as List).take(kGateMaxSteps))
        ?GateRunStep.fromJson(s),
    ];
    if (steps.isEmpty) {
      return null;
    }
    final Object? ch = json['ch'];
    return GateRun(
      id: json['id'] as String,
      target: json['y'] as String,
      targetName: json['yn'] is String ? json['yn'] as String : '',
      steps: steps,
      at: json['at'] as int,
      note: json['t'] is String ? json['t'] as String : '',
      state: GateRunState.byName(json['s']),
      reason: json['why'] is String ? json['why'] as String : '',
      changedAt: ch is int ? ch : null,
    );
  }
}
