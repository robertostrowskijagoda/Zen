import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/update/signing_expiry.dart';

void main() {
  final DateTime now = DateTime(2026, 10, 22, 12);

  test('the warning starts two days before the signature runs out', () {
    expect(
      signingDaysLeftToWarn(now.add(const Duration(days: 5)), now),
      isNull,
    );
    expect(
      signingDaysLeftToWarn(now.add(const Duration(days: 2, hours: 1)), now),
      isNull,
    );
    expect(signingDaysLeftToWarn(now.add(const Duration(days: 2)), now), 2);
    expect(
      signingDaysLeftToWarn(now.add(const Duration(days: 1, hours: 3)), now),
      2,
    );
    expect(signingDaysLeftToWarn(now.add(const Duration(hours: 5)), now), 1);
    expect(
      signingDaysLeftToWarn(now.subtract(const Duration(hours: 1)), now),
      0,
    );
  });

  test('a refreshed build warns again', () {
    final DateTime first = now.add(const Duration(days: 1));
    final DateTime refreshed = now.add(const Duration(days: 8));
    expect(signingTipId(first), isNot(signingTipId(refreshed)));
  });
}
