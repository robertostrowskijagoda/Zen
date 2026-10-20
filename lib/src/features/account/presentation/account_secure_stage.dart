import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/account/presentation/key_backup_screen.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Zabezpiecz konto" (§6.1, §6.3): the first start, right after the
/// permissions step. Offers the recovery circle and the backup of the
/// key (file or code), or "later" — remembered, with a reminder in Settings
/// until the account is secured.
class AccountSecureStage extends ConsumerWidget {
  const AccountSecureStage({super.key});

  Future<void> _answer(WidgetRef ref) => ref
      .read(appSettingsControllerProvider.notifier)
      .setAccountSecureOffered(true);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    // Rebuilds when the person comes back from one of the screens.
    final bool secured = !ref.watch(accountSecureReminderProvider);
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
                    t('Krąg zaufanych'),
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15.5,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t(
                      'Do 6 osób dostaje po kawałku klucza i razem pomogą '
                      'Ci wrócić na nowym telefonie. Potrzeba co najmniej '
                      '4 znajomych — jeśli ich jeszcze nie masz, wróć do '
                      'tego później.',
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
                    onPressed: () =>
                        unawaited(AccountRecoveryScreen.open(context)),
                    icon: const Icon(Icons.groups_2_outlined),
                    label: Text(t('Wybierz krąg zaufanych')),
                  ),
                ],
              ),
            ),
            ZenCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    t('Kopia zapasowa klucza'),
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
            const SizedBox(height: 8),
            if (secured)
              ZenInfo(
                icon: Icons.check_circle_outline_rounded,
                tone: zen.success,
                text: t('Konto jest zabezpieczone.'),
              ),
            TextButton(
              key: const Key('account-secure-later'),
              onPressed: () => unawaited(_answer(ref)),
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
