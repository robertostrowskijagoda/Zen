import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';

/// "Kto może zapraszać mnie do grup": an invitation to a new group from
/// someone below the chosen level is declined at once.
class GroupInviteFromTile extends ConsumerWidget {
  const GroupInviteFromTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final GroupInviteFrom from = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.groupInviteFrom,
      ),
    );
    return Padding(
      key: const Key('group-invite-from'),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            t('Kto może zapraszać mnie do grup'),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t(
              'Zaproszenie od kogoś spoza wybranych odrzucamy od razu. '
              'Poziom znajomości ustawiasz na profilu znajomego.',
            ),
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13.5,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final GroupInviteFrom f in GroupInviteFrom.values)
                ChoiceChip(
                  key: Key('group-invite-from-${f.name}'),
                  showCheckmark: false,
                  label: Text(f.label),
                  selected: from == f,
                  onSelected: (_) => unawaited(
                    ref
                        .read(appSettingsControllerProvider.notifier)
                        .setGroupInviteFrom(f),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
