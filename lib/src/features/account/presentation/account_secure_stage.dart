import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/account_import_layer.dart';
import 'package:zen/src/features/account/presentation/key_backup_screen.dart';
import 'package:zen/src/features/account/presentation/name_step.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/security/app_security_service.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// The first start, right after the permissions step (or instead of the
/// password, when "Mam już konto" was said there): first "Jak
/// zaczynasz?" — a new account, or one brought back (a backup, another
/// device, the recovery circle); then, for a new account, "Zabezpiecz
/// konto": the recovery circle and the backup of the key (file or code),
/// or "later" — remembered, with a reminder in Settings until the account
/// is secured.
class AccountSecureStage extends ConsumerStatefulWidget {
  const AccountSecureStage({super.key});

  @override
  ConsumerState<AccountSecureStage> createState() => _AccountSecureStageState();
}

class _AccountSecureStageState extends ConsumerState<AccountSecureStage> {
  /// "Nowe konto" was picked (here, or before the setup).
  late bool _fresh =
      ref.read(accountStartPlanProvider).value == AccountStartPlan.fresh;

  /// The name step was answered (saved or skipped).
  bool _nameDone = false;

  /// A new account after all. Said before the setup ("Mam już konto" on
  /// the password step), the password, the setup and the permissions come
  /// first now: the gate shows them and then this stage again, at the name.
  void _startFresh() {
    ref.read(accountStartPlanProvider).value = AccountStartPlan.fresh;
    setState(() => _fresh = true);
  }

  Future<void> _answer() => ref
      .read(appSettingsControllerProvider.notifier)
      .setAccountSecureOffered(true);

  /// A way back to an existing account: the first start ends here and the
  /// way opens once the app (and the network) runs.
  void _restore(AccountStartAction action) {
    ref.read(accountStartActionProvider).value = action;
    unawaited(_answer());
  }

  Widget _start(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Scaffold(
      key: const Key('account-start-stage'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenHero(
              title: t('Jak zaczynasz?'),
              icon: Icons.waving_hand_outlined,
              text: t(
                'Pierwszy raz w Zen? Załóż nowe konto. Masz już konto? '
                'Przywróć je z kopii, z drugiego urządzenia albo z pomocą '
                'kręgu odzyskiwania.',
              ),
            ),
            FilledButton.icon(
              key: const Key('account-start-new'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              onPressed: _startFresh,
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: Text(t('Nowe konto')),
            ),
            const SizedBox(height: 12),
            Text(t('MAM JUŻ KONTO'), style: zen.label(color: zen.textMuted)),
            if (!ref.watch(appSecurityServiceProvider).hasPassword &&
                ref.watch(accountStartPlanProvider).value ==
                    AccountStartPlan.restore)
              ZenInfo(
                key: const Key('account-start-password-note'),
                icon: Icons.password_rounded,
                text: t(
                  'Hasło aplikacji wróci razem z kopią całego konta. Przy '
                  'przywracaniu z innego urządzenia albo z pomocą kręgu '
                  'ustawisz nowe.',
                ),
              ),
            AccountCopyActions(
              backup: false,
              circle: () => _restore(AccountStartAction.circle),
              onRestore: _restore,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_fresh) {
      return _start(context);
    }
    // A new account: first the name friends will see.
    if (!_nameDone &&
        !ref.watch(
          userProfileControllerProvider.select(
            (UserProfile p) => p.hasChosenName,
          ),
        )) {
      return FirstNameStep(onDone: () => setState(() => _nameDone = true));
    }
    final ZenColors zen = ZenColors.of(context);
    // Rebuilds when the person comes back from one of the screens.
    final bool secured = !ref.watch(accountSecureReminderProvider);
    // The circle needs friends and a brand-new account has none: it waits
    // (Zen reminds once there are enough, see CircleReminderCard).
    return Scaffold(
      key: const Key('account-secure-stage'),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            ZenHero(
              title: t('Zabezpiecz konto'),
              icon: Icons.shield_outlined,
              text: t(
                'Zgubiony telefon nie musi oznaczać końca konta i '
                'znajomych. Wybierz, jak chcesz je odzyskać — to chwila.',
              ),
            ),
            ZenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t('Kopia klucza (kartka lub plik)'),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t(
                      'Zapisz klucz konta w pliku z hasłem albo przepisz go '
                      'jako kod. Działa bez niczyjej pomocy, ale kto ma '
                      'plik z hasłem lub kod, ma konto.',
                    ),
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    key: const Key('account-secure-key'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => unawaited(KeyBackupScreen.open(context)),
                    icon: const Icon(Icons.history_edu_rounded),
                    label: Text(t('Zrób kopię klucza')),
                  ),
                ],
              ),
            ),
            ZenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t('Krąg odzyskiwania'),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t(
                      'Od 4 do 6 wybranych znajomych dostaje po kawałku '
                      'klucza i razem pomogą Ci wrócić na nowym telefonie — '
                      'ze znajomymi i rozmowami. Dostępny od {n} znajomych: '
                      'gdy ich dodasz, Zen Ci o nim przypomni.',
                      <String, Object?>{'n': kEmergencyThreshold},
                    ),
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 13.5,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    key: const Key('account-secure-circle'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: null,
                    icon: const Icon(Icons.groups_2_outlined),
                    label: Text(
                      t('Dostępny od {n} znajomych', <String, Object?>{
                        'n': kEmergencyThreshold,
                      }),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            if (secured)
              ZenInfo(
                icon: Icons.check_circle_outline_rounded,
                tone: zen.success,
                text: t('Konto jest zabezpieczone.'),
              ),
            TextButton(
              key: const Key('account-secure-later'),
              onPressed: () => unawaited(_answer()),
              child: Text(secured ? t('Gotowe') : t('Później')),
            ),
            if (!secured)
              Text(
                t('Przypomnimy Ci o tym w Ustawieniach.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textMuted, fontSize: 12.5),
              ),
          ],
        ),
      ),
    );
  }
}
