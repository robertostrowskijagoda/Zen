import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/recovery_providers.dart';
import 'package:zen/src/features/account/recovery_service.dart';
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

/// Whether the account's node has loaded its identity (it settled ready):
/// until then nobody can tell whether a circle or a password is there.
/// Watched, so whatever reads the identity is read again once it is.
final FutureProvider<bool> ledgerIdentityLoadedProvider = FutureProvider<bool>((
  Ref ref,
) async {
  final LedgerNode? node = ref.watch(ledgerNodeProvider);
  if (node == null) {
    return false;
  }
  await node.settled;
  return node.isReady;
});

/// Whether the account is secured against a lost phone: a copy of the key
/// was made (`paperBackupDone`: the paper code or the key file, on any of
/// the account's devices), or enough close friends confirmed their pieces
/// for a recovery (the current generation's threshold, or two of a circle
/// of 1.16.4 still valid). An account password alone, with nobody holding
/// a piece yet, is not enough. `false` while the account is still
/// starting (nothing proves it is secured).
bool accountIsSecured(T Function<T>(ProviderListenable<T> provider) watch) {
  if (watch(appSettingsControllerProvider).paperBackupDone) {
    return true;
  }
  return watch(recoveryProtectionProvider).value?.secured ?? false;
}

/// Whether the person did their part for the pieces with friends: an
/// account password is set for them (the pieces then follow the close
/// friends by themselves), or a circle of 1.16.4 is still there.
bool accountHasCircle(T Function<T>(ProviderListenable<T> provider) watch) {
  final RecoveryProtection? p = watch(recoveryProtectionProvider).value;
  if (p != null && (p.sealed || p.legacy > 0)) {
    return true;
  }
  final LedgerNode? node = watch(ledgerNodeProvider);
  return node != null && node.isReady && node.identity.hasPassword;
}

/// Whether the account's identity is loaded, as [ledgerIdentityLoadedProvider]
/// says (watched: the reminders that read the identity come back to it).
bool _identityLoaded(Ref ref) =>
    ref.watch(ledgerIdentityLoadedProvider).value ?? false;

/// The id in `AppSettings.seenTips` of a dismissed circle reminder.
const String kCircleReminderTip = 'circle-reminder';

/// Whether the person should be told, once, to set the account password
/// so that close friends keep pieces of the key: enough friends
/// ([kRecoveryCircleMinimum]) and no password for the pieces yet — also
/// when a key copy was made, since the key alone does not bring friends
/// and conversations back. Gone after "Nie teraz" or once it is set.
bool circleReminderDue({
  required bool ledgerOn,
  required bool hasCircle,
  required int friends,
  required AppSettings settings,
}) =>
    ledgerOn &&
    !hasCircle &&
    friends >= kRecoveryCircleMinimum &&
    !settings.seenTips.contains(kCircleReminderTip);

/// [circleReminderDue] for this account. Invalidate it after the circle
/// is set up.
///
/// Nothing is said until the identity is loaded: read before that, the
/// circle looked missing, and the card stayed after it was set up (nothing
/// made this read again).
final Provider<bool> circleReminderProvider = Provider<bool>(
  (Ref ref) => circleReminderDue(
    ledgerOn: ref.watch(ledgerNodeEnabledProvider) && _identityLoaded(ref),
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
      ref.watch(ledgerNodeEnabledProvider) &&
      _identityLoaded(ref) &&
      !accountIsSecured(ref.watch),
);

/// How old the last backup of the account may get before Zen reminds.
const Duration kAccountBackupReminderAge = Duration(days: 30);

/// Whether the person should be reminded to save a backup of the whole
/// account: there is something to lose (a friend at least), no backup was
/// saved on this device yet or the last one is older than
/// [kAccountBackupReminderAge], and "Później" is not waiting. Without the
/// password-less recovery (gone in 1.15.4) a backup and the circle are the
/// only ways back.
bool backupReminderDue({
  required bool ledgerOn,
  required int friends,
  required AppSettings settings,
  required DateTime now,
}) {
  final int at = now.millisecondsSinceEpoch;
  if (!ledgerOn || friends < 1 || at < settings.backupReminderAfterMillis) {
    return false;
  }
  final int last = settings.lastAccountBackupMillis;
  return last <= 0 || at - last >= kAccountBackupReminderAge.inMilliseconds;
}

/// The clock of [backupReminderProvider] (replaced in tests).
final Provider<DateTime Function()> backupReminderClockProvider =
    Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// [backupReminderDue] for this account; never at the same time as the
/// circle reminder (one card at a time).
final Provider<bool> backupReminderProvider = Provider<bool>(
  (Ref ref) =>
      // Not before the circle reminder could tell whether it shows.
      _identityLoaded(ref) &&
      !ref.watch(circleReminderProvider) &&
      backupReminderDue(
        ledgerOn: ref.watch(ledgerNodeEnabledProvider),
        friends: ref.watch(
          socialHubControllerProvider.select(
            (SocialHubState s) => s.acceptedFriends.length,
          ),
        ),
        settings: ref.watch(appSettingsControllerProvider),
        now: ref.watch(backupReminderClockProvider)(),
      ),
);
