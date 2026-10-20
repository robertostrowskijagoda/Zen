import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// Whether the first start shows the "Zabezpiecz konto" card (§6.1, §6.3)
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

/// Whether Settings should gently remind the person to secure the account.
/// Invalidate it after the circle is set up.
final Provider<bool> accountSecureReminderProvider = Provider<bool>(
  (Ref ref) =>
      ref.watch(ledgerNodeEnabledProvider) && !accountIsSecured(ref.watch),
);
