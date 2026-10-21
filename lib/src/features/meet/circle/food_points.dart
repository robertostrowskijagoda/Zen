/// What shared food needs from the pyramid's points ("Za punkty"). The
/// app wires it to the pyramid in one place (`food_providers.dart`); the
/// food code never touches the wallet directly.
abstract interface class FoodPoints {
  /// This person's pyramid key, when they are a member (else `null`).
  String? get myKey;

  /// The pyramid this person is in.
  String? get pyramid;

  /// Whether this person can pay [key] (a member of [pyramid]) in points
  /// now: both members, someone else, something on the account.
  bool canPay(String key, {String? pyramid});

  /// Sends [amount] points (hundredths) to [key] with [memo]. The payment
  /// order's id when it went out (the pyramid settles it), else null.
  Future<String?> pay(
    String key,
    int amount, {
    required String memo,
    String? pyramid,
  });

  /// Whether order [order] from [from] paying this person at least
  /// [amount] is in the pyramid: what "paid" means to the cook, never the
  /// taker's word.
  bool received(String order, {required String from, required int amount});

  /// [amount] (hundredths) as people read it.
  String format(int amount);
}

/// No pyramid: "Za punkty" is never offered.
final class NoFoodPoints implements FoodPoints {
  const NoFoodPoints();

  @override
  String? get myKey => null;

  @override
  String? get pyramid => null;

  @override
  bool canPay(String key, {String? pyramid}) => false;

  @override
  Future<String?> pay(
    String key,
    int amount, {
    required String memo,
    String? pyramid,
  }) async => null;

  @override
  bool received(String order, {required String from, required int amount}) =>
      false;

  @override
  String format(int amount) {
    final String cents = (amount.abs() % 100).toString().padLeft(2, '0');
    return '${amount < 0 ? '-' : ''}${amount.abs() ~/ 100},$cents';
  }
}
