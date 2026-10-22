import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/name_step.dart';
import 'package:zen/src/features/relay/iphone_delivery_notice.dart';
import 'package:zen/src/features/settings/app_settings.dart';

void main() {
  group('the circle reminder', () {
    test('waits for four friends', () {
      for (int n = 0; n < 4; n++) {
        expect(
          circleReminderDue(
            ledgerOn: true,
            hasCircle: false,
            friends: n,
            settings: const AppSettings(),
          ),
          isFalse,
          reason: '$n friends',
        );
      }
      expect(
        circleReminderDue(
          ledgerOn: true,
          hasCircle: false,
          friends: 4,
          settings: const AppSettings(),
        ),
        isTrue,
      );
    });

    test('comes back after a key copy, not after the circle', () {
      expect(
        circleReminderDue(
          ledgerOn: true,
          hasCircle: false,
          friends: 6,
          settings: const AppSettings(paperBackupDone: true),
        ),
        isTrue,
      );
      expect(
        circleReminderDue(
          ledgerOn: true,
          hasCircle: true,
          friends: 6,
          settings: const AppSettings(),
        ),
        isFalse,
      );
    });

    test('"Nie teraz" is remembered', () {
      final AppSettings later = AppSettings.fromJson(
        const AppSettings(seenTips: <String>{kCircleReminderTip}).toJson(),
      );
      expect(later.seenTips, contains(kCircleReminderTip));
      expect(
        circleReminderDue(
          ledgerOn: true,
          hasCircle: false,
          friends: 6,
          settings: later,
        ),
        isFalse,
      );
    });
  });

  test('the iPhone card shows once, only on an iPhone', () {
    expect(showIPhoneDeliveryNotice(const AppSettings(), iPhone: true), isTrue);
    expect(
      showIPhoneDeliveryNotice(const AppSettings(), iPhone: false),
      isFalse,
    );
    expect(
      showIPhoneDeliveryNotice(
        const AppSettings(seenTips: <String>{kIPhoneDeliveryTip}),
        iPhone: true,
      ),
      isFalse,
    );
  });

  group('the name friends see', () {
    test('is trimmed, single-spaced and not empty', () {
      expect(normalizeChosenName('  Ania   Kowalska '), 'Ania Kowalska');
      expect(normalizeChosenName('   '), isNull);
      expect(normalizeChosenName('x' * 200)!.length, lessThanOrEqualTo(60));
    });

    test('a person who chose none is never sent as "Ja"', () {
      const UserProfile none = UserProfile();
      expect(none.displayName, 'Ja', reason: 'shown on this device only');
      expect(none.publicName, isEmpty);
      expect(none.hasChosenName, isFalse);
      expect(none.customStatus, isEmpty);
      const UserProfile ania = UserProfile(displayName: 'Ania');
      expect(ania.publicName, 'Ania');
      expect(ania.hasChosenName, isTrue);
    });
  });
}
