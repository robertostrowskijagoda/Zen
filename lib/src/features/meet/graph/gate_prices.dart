import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/meet/intro/intro_providers.dart';
import 'package:zen/src/features/meet/intro/intro_service.dart';

/// What getting to someone takes.
enum GateKind {
  /// Nothing to pay, nobody to ask.
  free,

  /// A price (see [GatePrice.amount]).
  price,

  /// The person (or the one who introduces) has to agree first.
  consent,
}

/// The gate in front of one step on the graph: writing to a friend, or
/// being introduced to someone by a friend.
@immutable
final class GatePrice {
  const GatePrice.free()
    : kind = GateKind.free,
      amount = 0,
      shown = '',
      consent = false;

  /// [amount] in the smallest unit the source uses (it only orders
  /// routes); [shown] is the price as the person reads it ("5 pkt");
  /// [consent]: paid, and the one who introduces still agrees each time.
  const GatePrice.price(this.amount, {this.shown = '', this.consent = false})
    : kind = GateKind.price;

  const GatePrice.consent()
    : kind = GateKind.consent,
      amount = 0,
      shown = '',
      consent = true;

  /// A friend's gate [terms] as the graph shows them.
  factory GatePrice.of(GateTerms terms) => terms.free
      ? (terms.consent ? const GatePrice.consent() : const GatePrice.free())
      : GatePrice.price(
          terms.price,
          shown: formatPoints(terms.price),
          consent: terms.consent,
        );

  final GateKind kind;
  final int amount;
  final String shown;

  /// Someone has to agree (always for [GateKind.consent]).
  final bool consent;

  /// A short label for an edge on the graph.
  String get label => switch (kind) {
    GateKind.free => t('za darmo'),
    GateKind.consent => t('za zgodą'),
    GateKind.price =>
      (shown.isNotEmpty ? shown : '$amount') +
          (consent ? ' · ${t('za zgodą')}' : ''),
  };

  @override
  bool operator ==(Object other) =>
      other is GatePrice &&
      other.kind == kind &&
      other.amount == amount &&
      other.shown == shown &&
      other.consent == consent;

  @override
  int get hashCode => Object.hash(kind, amount, shown, consent);
}

/// Where the graph reads gate prices from (paid introductions, message
/// prices). Everything is optional: `null` means "no data", and the graph
/// then says so instead of guessing.
abstract interface class GatePriceSource {
  /// The gate to [target]: writing to them directly when [via] is `null`
  /// (a friend), else being introduced by [via] (a friend who knows them).
  /// Addresses are normalised mesh addresses.
  GatePrice? gateOf(String target, {String? via});

  /// Fires when prices change (`null`: they never do).
  Listenable? get changes;
}

/// No prices known: every gate is "brak danych", routes cost hops only.
final class NoGatePrices implements GatePriceSource {
  const NoGatePrices();

  @override
  GatePrice? gateOf(String target, {String? via}) => null;

  @override
  Listenable? get changes => null;
}

/// The real gates: writing to a friend is free; being introduced by [via]
/// costs what [via] told this person in their gate terms (or, further
/// away, what friends passed on about them). Nothing known: "brak danych".
final class IntroGatePrices implements GatePriceSource {
  const IntroGatePrices(this.intro);

  final IntroService intro;

  @override
  GatePrice? gateOf(String target, {String? via}) {
    if (via == null) {
      return intro.host.isFriend(target) ? const GatePrice.free() : null;
    }
    final GateTerms? terms = intro.gateTermsOf(via);
    return terms == null ? null : GatePrice.of(terms);
  }

  @override
  Listenable? get changes => intro;
}

/// The prices the graph shows in the "Bramy" mode and uses for the
/// cheapest route: friends' gate terms (see `meet/intro/`).
final Provider<GatePriceSource> gatePriceSourceProvider =
    Provider<GatePriceSource>(
      (Ref ref) => IntroGatePrices(ref.watch(introServiceProvider)),
    );
