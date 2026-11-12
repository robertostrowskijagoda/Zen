import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/app_data_reset.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/account/account_archive_app.dart';
import 'package:zen/src/features/account/account_holdings.dart';
import 'package:zen/src/features/account/account_recovery.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/account/presentation/accounts_ui.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/passwords/password_entry.dart';
import 'package:zen/src/features/security/hold_to_confirm_button.dart';

/// What the person chose when another account would take the place of the
/// one on this device.
enum AccountReplaceChoice {
  /// The other account goes beside this one ("Dodaj konto"): nothing here
  /// is lost and nothing of it goes to the other account.
  addBeside,

  /// This account is wiped from the device (as "Usuń dane konta" does) and
  /// the device starts like a new install, where the other account is
  /// taken.
  wipe,
}

/// The person's answer in [AccountReplaceDialog].
@immutable
final class AccountReplaceAnswer {
  const AccountReplaceAnswer(this.choice, {this.takePasswords = false});

  final AccountReplaceChoice choice;

  /// "Zabierz zapisane hasła": the saved passwords here go to the account
  /// that comes next (off unless the person ticks it).
  final bool takePasswords;
}

/// Whether the account [incoming] may be taken onto this device in place of
/// the one here, as it is now: yes on a fresh device and for the same
/// account. On a device whose account holds anything the person made or
/// received ([AccountHoldings]) it never is: the person is shown what is
/// here and what comes and chooses ([AccountReplaceDialog]) to add the
/// other account beside this one or to wipe this one first; either is done
/// here, and the caller stops. [incomingName]: the other account's name,
/// when the copy names it.
Future<bool> mayTakeAccountHere(
  BuildContext context,
  WidgetRef ref, {
  required String incoming,
  String incomingName = '',
}) async {
  final Future<AccountHoldings> Function()? read = ref.read(
    accountHoldingsProvider,
  );
  if (read == null) {
    return true;
  }
  final AccountHoldings here = await read();
  if (here.account == incoming || here.isFresh) {
    return true;
  }
  if (!context.mounted) {
    return false;
  }
  await offerAccountReplace(
    context,
    ref,
    here: here,
    incoming: incoming,
    incomingName: incomingName,
  );
  return false;
}

/// Shows [AccountReplaceDialog] for a device whose account is not fresh
/// ([here]) and does what the person chose: opens "Dodaj konto", or wipes
/// this account so the device starts like a new install. The passwords
/// the person chose to take along wait in memory for the next account
/// ([AccountPasswordCarry]).
Future<void> offerAccountReplace(
  BuildContext context,
  WidgetRef ref, {
  required AccountHoldings here,
  required String incoming,
  String incomingName = '',
}) async {
  final AccountReplaceAnswer? answer = await showDialog<AccountReplaceAnswer>(
    context: context,
    builder: (BuildContext dialog) => AccountReplaceDialog(
      here: here,
      incoming: incoming,
      incomingName: incomingName,
    ),
  );
  if (answer == null || !context.mounted) {
    return;
  }
  if (answer.takePasswords) {
    try {
      AccountPasswordCarry.instance.put(
        passwordVaultSectionOf(
          await ref.read(ledgerDiskProvider).read(kPasswordVaultKey),
        ),
      );
    } on Object catch (error) {
      logZenWarning('The saved passwords were not taken along: $error');
    }
  } else {
    AccountPasswordCarry.instance.clear();
  }
  if (!context.mounted) {
    return;
  }
  switch (answer.choice) {
    case AccountReplaceChoice.addBeside:
      unawaited(AddAccountScreen.open(context));
    case AccountReplaceChoice.wipe:
      Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
      await performZenLocalDataReset(ref);
  }
}

/// "Na tym urządzeniu jest już konto": what is here (its name, its
/// fingerprint, what it holds) and what comes, what would be lost, a backup
/// first, and the two ways on — the other account beside this one, or
/// this one wiped (held to confirm), with the saved passwords taken along
/// only when ticked.
class AccountReplaceDialog extends StatefulWidget {
  const AccountReplaceDialog({
    required this.here,
    required this.incoming,
    this.incomingName = '',
    super.key,
  });

  final AccountHoldings here;
  final String incoming;
  final String incomingName;

  @override
  State<AccountReplaceDialog> createState() => _AccountReplaceDialogState();
}

class _AccountReplaceDialogState extends State<AccountReplaceDialog> {
  bool _takePasswords = false;

  Widget _who(BuildContext context, String label, String name, String key) {
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: zen.label(color: zen.textMuted)),
        const SizedBox(height: 2),
        Text(
          name.trim().isEmpty ? t('(bez imienia)') : name.trim(),
          style: TextStyle(color: zen.textPrimary, fontWeight: FontWeight.w700),
        ),
        SelectableText(
          key.isEmpty ? '—' : accountFingerprint(key),
          style: zen.mono(color: zen.textSecondary, size: 14),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AccountHoldings here = widget.here;
    return AlertDialog(
      key: const Key('account-replace-dialog'),
      scrollable: true,
      title: Text(t('Na tym urządzeniu jest już konto')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _who(context, t('TU JEST'), here.name, here.account),
          const SizedBox(height: 6),
          for (final String line in here.describe())
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                '• $line',
                style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
              ),
            ),
          const SizedBox(height: 12),
          _who(context, t('PRZYCHODZI'), widget.incomingName, widget.incoming),
          const SizedBox(height: 12),
          ZenInfo(
            key: const Key('account-replace-loss'),
            icon: Icons.warning_amber_rounded,
            tone: zen.danger,
            text: t(
              'Gdyby to drugie konto zajęło miejsce tego, wszystko powyżej '
              'zniknie z tego urządzenia, a klucz tego konta przepadnie, '
              'jeśli nie masz go nigdzie indziej (kopia zapasowa, klucz na '
              'kartce, inne urządzenie). Nic z tego konta nie przejdzie na '
              'drugie.',
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const Key('account-replace-backup'),
            onPressed: () => unawaited(AccountBackupScreen.open(context)),
            icon: const Icon(Icons.save_alt_rounded),
            label: Text(t('Najpierw zrób kopię zapasową tego konta')),
          ),
          if (here.passwords > 0)
            CheckboxListTile(
              key: const Key('account-replace-passwords'),
              contentPadding: EdgeInsets.zero,
              value: _takePasswords,
              onChanged: (bool? value) =>
                  setState(() => _takePasswords = value ?? false),
              title: Text(t('Zabierz zapisane hasła do drugiego konta')),
              subtitle: Text(
                t(
                  'Hasła z tego konta trafią do drugiego i na jego '
                  'urządzenia. Nic innego nie przechodzi.',
                ),
              ),
            ),
          const SizedBox(height: 8),
          FilledButton.icon(
            key: const Key('account-replace-add'),
            onPressed: () => Navigator.of(context).pop(
              AccountReplaceAnswer(
                AccountReplaceChoice.addBeside,
                takePasswords: _takePasswords,
              ),
            ),
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(t('Dodaj je jako osobne konto')),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            child: Text(
              t(
                'Nic nie zginie: oba konta zostaną na tym urządzeniu. W nowym '
                'koncie otwórz kopię, link albo klucz jeszcze raz.',
              ),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            ),
          ),
          HoldToConfirmButton(
            key: const Key('account-replace-wipe'),
            idleLabel: t('Przytrzymaj, aby usunąć to konto'),
            holdingLabel: (int seconds) =>
                t('Trzymaj… jeszcze {n} s', {'n': seconds}),
            onConfirmed: () {
              unawaited(HapticFeedback.heavyImpact());
              Navigator.of(context).pop(
                AccountReplaceAnswer(
                  AccountReplaceChoice.wipe,
                  takePasswords: _takePasswords,
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t(
                'Zen zacznie od nowa jak po instalacji. Potem weź drugie konto '
                'jeszcze raz („Mam kopię”, „Dołącz do konta” albo „Przywróć '
                'klucz”).',
              ),
              style: TextStyle(color: zen.textSecondary, fontSize: 13),
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('account-replace-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Anuluj')),
        ),
      ],
    );
  }
}
