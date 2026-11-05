import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/settings/app_settings.dart';

// "Zrób kopię konta": when Zen reminds that a backup of the whole account
// is missing or old.
void main() {
  final DateTime now = DateTime(2026, 11, 5, 12);
  int daysAgo(int days) =>
      now.subtract(Duration(days: days)).millisecondsSinceEpoch;

  bool due(AppSettings settings, {int friends = 3, bool ledgerOn = true}) =>
      backupReminderDue(
        ledgerOn: ledgerOn,
        friends: friends,
        settings: settings,
        now: now,
      );

  test('no backup yet: reminded once there is someone to lose', () {
    expect(due(const AppSettings()), isTrue);
    expect(due(const AppSettings(), friends: 0), isFalse);
    expect(due(const AppSettings(), ledgerOn: false), isFalse);
  });

  test('a backup younger than a month is enough; an older one is not', () {
    expect(due(AppSettings(lastAccountBackupMillis: daysAgo(10))), isFalse);
    expect(due(AppSettings(lastAccountBackupMillis: daysAgo(29))), isFalse);
    expect(due(AppSettings(lastAccountBackupMillis: daysAgo(31))), isTrue);
  });

  test('"Później" waits, and both times are kept', () {
    final AppSettings later = AppSettings(
      backupReminderAfterMillis: now
          .add(const Duration(days: 3))
          .millisecondsSinceEpoch,
    );
    expect(due(later), isFalse);
    final AppSettings back = AppSettings.fromJson(
      AppSettings(
        lastAccountBackupMillis: daysAgo(40),
        backupReminderAfterMillis: daysAgo(1),
      ).toJson(),
    );
    expect(back.lastAccountBackupMillis, daysAgo(40));
    expect(due(back), isTrue);
  });
}
