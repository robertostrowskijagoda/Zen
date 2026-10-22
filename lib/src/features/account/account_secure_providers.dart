import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// Whether the first start shows the "Zabezpiecz konto" card
/// after the permissions step, until it is answered. Off in tests and
/// previews; the real app turns it on (like the permissions step).
final Provider<bool> accountSecureStepRequiredProvider = Provider<bool>(
  (Ref ref) => false,
);

/// Whether the account is secured against a lost phone: the recovery
/// circle holds pieces (an account password is set) or the paper copy of
/// the key was written down. `false` while the account is still starting
/// (nothing proves it is secured).
bool accountIsSecured(T Function<T>(ProviderListenable<T> provider) watch) {
  if (watch(appSettingsControllerProvider).paperBackupDone) {
    return true;
  }
  final LedgerNode? node = watch(ledgerNodeProvider);
  return node != null && node.isReady && node.identity.hasPassword;
}

/// Whether the recovery circle holds pieces of this account (an account
/// password is set and the pieces were handed out with it).
bool accountHasCircle(T Function<T>(ProviderListenable<T> provider) watch) {
  final LedgerNode? node = watch(ledgerNodeProvider);
  return node != null && node.isReady && node.identity.hasPassword;
}

/// The id in `AppSettings.seenTips` of a dismissed circle reminder.
const String kCircleReminderTip = 'circle-reminder';

/// Whether the person should be told, once, that the circle can be set
/// up now: enough friends ([kEmergencyThreshold]) and no circle yet — also
/// when a key copy was made, since the key alone does not bring friends
/// and conversations back. Gone after "Nie teraz" or once the circle is
/// there.
bool circleReminderDue({
  required bool ledgerOn,
  required bool hasCircle,
  required int friends,
  required AppSettings settings,
}) =>
    ledgerOn &&
    !hasCircle &&
    friends >= kEmergencyThreshold &&
    !settings.seenTips.contains(kCircleReminderTip);

/// [circleReminderDue] for this account. Invalidate it after the circle
/// is set up.
final Provider<bool> circleReminderProvider = Provider<bool>(
  (Ref ref) => circleReminderDue(
    ledgerOn: ref.watch(ledgerNodeEnabledProvider),
    hasCircle: accountHasCircle(ref.watch),
    friends: ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState s) => s.acceptedFriends.length,
      ),
    ),
    settings: ref.watch(appSettingsControllerProvider),
  ),
);

/// Whether Settings should gently remind the person to secure the account.
/// Invalidate it after the circle is set up.
final Provider<bool> accountSecureReminderProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(ledgerNodeEnabledProvider) && !accountIsSecured(ref.watch),
);
