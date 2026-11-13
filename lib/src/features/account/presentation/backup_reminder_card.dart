import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/account_backup_screen.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Zrób kopię konta": shown on the chats list while [backupReminderDue]
/// says so (no backup on this device yet, or the last one is a month old),
/// until a backup is saved or "Później" waits a week.
class BackupReminderCard extends ConsumerWidget {
  const BackupReminderCard({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(backupReminderProvider)) {
      return const SizedBox.shrink();
    }
    final int last = ref.watch(
      appSettingsControllerProvider.select((s) => s.lastAccountBackupMillis),
    );
    final DateTime now = ref.watch(backupReminderClockProvider)();
    final int days = last <= 0
        ? 0
        : now.difference(DateTime.fromMillisecondsSinceEpoch(last)).inDays;
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: padding,
      child: ZenCard(
        key: const Key('backup-reminder-card'),
        tone: zen.accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenInfo(
              icon: Icons.save_alt_rounded,
              title: last <= 0
                  ? t('Nie masz jeszcze kopii konta')
                  : tn(
                      days,
                      one: 'Ostatnia kopia konta: {n} dzień temu',
                      few: 'Ostatnia kopia konta: {n} dni temu',
                      many: 'Ostatnia kopia konta: {n} dni temu',
                    ),
              text: t(
                'Z kopią i hasłem konta wrócisz do znajomych, grup i '
                'rozmów na nowym telefonie. Bez niej zostaje tylko pomoc '
                'bliskich znajomych.',
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: <Widget>[
                TextButton(
                  key: const Key('backup-reminder-later'),
                  onPressed: () => unawaited(
                    ref
                        .read(appSettingsControllerProvider.notifier)
                        .snoozeBackupReminder(),
                  ),
                  child: Text(t('Później')),
                ),
                FilledButton(
                  key: const Key('backup-reminder-open'),
                  onPressed: () => unawaited(AccountBackupScreen.open(context)),
                  child: Text(t('Zrób kopię')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
