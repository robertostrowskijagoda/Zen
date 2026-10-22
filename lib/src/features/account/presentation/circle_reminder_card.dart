import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/account/account_secure_providers.dart';
import 'package:zen/src/features/account/presentation/account_recovery_screen.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// "Masz już n znajomych — ustaw krąg": shown once the person has enough
/// friends for the recovery circle and has none (see [circleReminderDue]),
/// until they set it up or say "Nie teraz".
class CircleReminderCard extends ConsumerWidget {
  const CircleReminderCard({super.key, this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(circleReminderProvider)) {
      return const SizedBox.shrink();
    }
    final int friends = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState s) => s.acceptedFriends.length,
      ),
    );
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: padding,
      child: ZenCard(
        key: const Key('circle-reminder-card'),
        tone: zen.accent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ZenInfo(
              icon: Icons.groups_2_outlined,
              title: tn(
                friends,
                one: 'Masz już {n} znajomego — ustaw krąg odzyskiwania',
                few: 'Masz już {n} znajomych — ustaw krąg odzyskiwania',
                many: 'Masz już {n} znajomych — ustaw krąg odzyskiwania',
              ),
              text: t(
                'Kopia klucza zwraca samo konto. Krąg pozwala odzyskać je '
                'z pomocą znajomych, a ich kopia przywróci też znajomych, '
                'grupy i rozmowy.',
              ),
            ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              children: <Widget>[
                TextButton(
                  key: const Key('circle-reminder-later'),
                  onPressed: () => unawaited(
                    ref
                        .read(appSettingsControllerProvider.notifier)
                        .markTipSeen(kCircleReminderTip),
                  ),
                  child: Text(t('Nie teraz')),
                ),
                FilledButton(
                  key: const Key('circle-reminder-open'),
                  onPressed: () =>
                      unawaited(AccountRecoveryScreen.open(context)),
                  child: Text(t('Ustaw krąg')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
