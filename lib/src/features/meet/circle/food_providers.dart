import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/feature_flags.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/meet/circle/food_points.dart';
import 'package:zen/src/features/meet/circle/food_service.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/meet/meet_service.dart';
import 'package:zen/src/features/pyramid/pyramid_providers.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart';

/// "Za punkty" over the pyramid: the one place shared food meets the
/// wallet. Read on every use, so a pyramid joined later counts at once;
/// with the pyramid switched off nothing is offered.
final class PyramidFoodPoints implements FoodPoints {
  PyramidFoodPoints(this.ref);

  final Ref ref;

  PyramidService? get _pyr =>
      ref.read(featureFlagsProvider).isEnabled(ZenFeature.pyramid)
      ? ref.read(pyramidServiceProvider)
      : null;

  @override
  String? get myKey {
    final PyramidService? p = _pyr;
    return p != null && p.isMember ? p.myKey : null;
  }

  @override
  String? get pyramid => _pyr?.current;

  @override
  bool canPay(String key, {String? pyramid}) =>
      _pyr?.canTip(key, pyramid: pyramid) ?? false;

  @override
  Future<String?> pay(
    String key,
    int amount, {
    required String memo,
    String? pyramid,
  }) async {
    final PyramidService? p = _pyr;
    final String? me = p?.myKey;
    if (p == null || me == null || amount <= 0 || p.balance < amount) {
      return null;
    }
    return (await p.tip(key, amount, memo: memo, pyramid: pyramid))?.id;
  }

  @override
  bool received(String order, {required String from, required int amount}) {
    final String? me = myKey;
    return me != null &&
        (_pyr?.receivedPayment(order, from: from, amount: amount) ?? false);
  }

  @override
  String format(int amount) => formatMoney(amount);
}

/// "Podziel się jedzeniem" in the app.
final Provider<FoodService> foodServiceProvider = Provider<FoodService>((
  Ref ref,
) {
  final MeetService meet = ref.watch(meetServiceProvider);
  final FoodService food = FoodService(
    host: appEventHost(ref, meet),
    disk: ref.read(ledgerDiskProvider),
    circles: ref.watch(circleServiceProvider),
    points: PyramidFoodPoints(ref),
    // "Kółko i przyjaciele", "Gotuję dziś" for close friends only.
    closeFriends: meet.host.closeFriends,
  );
  unawaitedLogged(food.load(), context: 'Reading food');
  listenFrames(ref, food.handle, 'Jedzenie');
  ref.onDispose(food.dispose);
  return food;
});
