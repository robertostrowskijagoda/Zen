import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/name_step.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/relay/iphone_delivery_notice.dart';
import 'package:zen/src/features/runtime/signal_transport.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/app_settings_store.dart';
import 'package:zen/src/features/social/friendship_book.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

void main() {
  group('the circle reminder', () {
    test('waits for two friends (as many as a recovery needs)', () {
      for (int n = 0; n < 2; n++) {
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
          friends: 2,
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

    test('says nothing until the account is loaded, and reads again once '
        'it is', () async {
      final Completer<bool> loaded = Completer<bool>();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          ...buildAppSettingsProviderOverrides(
            store: MemoryAppSettingsStore(),
            initialState: const AppSettings(),
            hydrationEnabled: false,
          ),
          socialHubAutoHydrateProvider.overrideWithValue(false),
          socialHubSeedProvider.overrideWithValue(
            SocialHubState.empty().copyWith(
              book: FriendshipBook.restore(
                profiles: <String, FriendProfile>{
                  for (final String a in <String>['200::a', '200::b'])
                    a: FriendProfile(
                      address: a,
                      displayName: a,
                      status: FriendRelationshipStatus.accepted,
                    ),
                },
              ),
            ),
          ),
          signalTransportProvider.overrideWithValue(MemorySignalTransport()),
          ledgerNodeEnabledProvider.overrideWithValue(true),
          ledgerNodeProvider.overrideWithValue(null),
          ledgerIdentityLoadedProvider.overrideWith((Ref ref) => loaded.future),
        ],
      );
      addTearDown(container.dispose);
      final List<bool> seen = <bool>[];
      container.listen<bool>(
        circleReminderProvider,
        (bool? _, bool now) => seen.add(now),
        fireImmediately: true,
      );
      expect(seen, <bool>[false], reason: 'the circle may well be there');
      expect(container.read(accountSecureReminderProvider), isFalse);
      expect(container.read(backupReminderProvider), isFalse);
      loaded.complete(true);
      await container.read(ledgerIdentityLoadedProvider.future);
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, isTrue, reason: 'loaded, and no circle');
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
