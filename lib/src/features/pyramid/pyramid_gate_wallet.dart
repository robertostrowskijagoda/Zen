import 'package:flutter/foundation.dart';
import 'package:zen/src/features/meet/intro/gate_route.dart';
import 'package:zen/src/features/meet/intro/gate_terms.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/pyramid/pyramid_ledger.dart';
import 'package:zen/src/features/pyramid/pyramid_record.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';
import 'package:zen/src/features/pyramid/pyramid_state.dart';

/// Gates and first messages paid in the pyramid's points: a conditional
/// payment that the one paid keeps or returns (the payer takes it back by
/// themselves after [kGateHoldTime]). Read on every use, so a pyramid joined
/// later counts at once; null (switched off, not started): nothing is paid.
final class PyramidGateWallet implements GateWallet {
  PyramidGateWallet(this._pyramid, {this.proofWait = kPyrAddressProofWait});

  final PyramidService? Function() _pyramid;

  /// How long the device at an address may take to prove its key.
  final Duration proofWait;

  PyramidService? get _member {
    final PyramidService? p = _pyramid();
    return p != null && p.isMember ? p : null;
  }

  @override
  String? get myKey => _member?.myKey;

  @override
  String? keyOf(String address) {
    final PyramidState? s = _member?.state;
    if (s == null) {
      return null;
    }
    final String key = pyramidKeyForAddress(s.members.values, address);
    return key.isEmpty || !s.isMember(key) ? null : key;
  }

  @override
  Future<String?> payeeKeyOf(String address) async =>
      await _member?.provenKeyAt(address, wait: proofWait);

  @override
  int get balance => _member?.balance ?? 0;

  @override
  Future<String?> hold(String to, int amount, {required String memo}) async {
    final PyramidService? p = _member;
    if (p == null || amount <= 0 || amount > balance) {
      return null;
    }
    final PyramidRecord? order = await p.pay(
      to,
      amount,
      memo: memo,
      condBy: to,
      condUntil: p.now + kGateHoldTime.inMilliseconds,
    );
    return order?.id;
  }

  @override
  GateHold? held(String id) {
    final PyrEscrow? e = _pyramid()?.escrowOf(id);
    return e == null
        ? null
        : GateHold(
            from: e.from,
            to: e.to,
            condBy: e.condBy,
            amount: e.amount,
            until: e.until,
            settled: e.settled,
          );
  }

  @override
  Future<bool> settle(String id, {required bool keep}) async =>
      await _pyramid()?.settle(id, keep) != null;

  @override
  Listenable? get changes => _pyramid();
}

/// What writing first to [address] takes, as this person (a member) can
/// tell from the price list of that member ('inbox' by level of
/// acquaintance): free, a price, or closed. Unknown outside the pyramid or
/// when they published nothing.
DirectTerms pyramidMessageTerms(PyramidService? p, String address) {
  final PyramidState? s = p?.state;
  if (p == null || s == null || !p.isMember) {
    return const DirectTerms.unknown();
  }
  final String key = pyramidKeyForAddress(s.members.values, address);
  if (key.isEmpty || !s.isMember(key) || key == p.myKey) {
    return const DirectTerms.unknown();
  }
  final Map<String, int>? levels = s.offerLevels[key]?['inbox'];
  if (levels == null) {
    return const DirectTerms.unknown();
  }
  final String level = p.levelOfAddress(address) ?? 'stranger';
  final int? price = levels[level];
  return price == null
      ? const DirectTerms.closed()
      : DirectTerms.price(price, payable: true);
}

/// This person's first-message price as the pyramid's price list carries
/// it ('inbox' by level): friends free, friends of friends when [fof],
/// everybody else when [strangers]; a level left out may not write first.
Map<String, int> messagePriceLevels({
  required bool fof,
  required bool strangers,
  required int price,
}) => <String, int>{
  'friend': 0,
  if (fof) 'fof': price,
  if (strangers) 'stranger': price,
};

/// Publishes [levels] as this person's first-message price when they are
/// a member and the price list says otherwise. Whether it published.
Future<bool> syncMessagePrice(
  PyramidService? p,
  Map<String, int> levels,
) async {
  final String? me = p?.myKey;
  final PyramidState? s = p?.state;
  if (p == null || me == null || s == null || !p.isMember) {
    return false;
  }
  if (mapEquals(s.offerLevels[me]?['inbox'], levels)) {
    return false;
  }
  return await p.setOfferKind('inbox', levels) != null;
}
