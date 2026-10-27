import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';

/// The "Treść powiadomień" question: the three levels and a line saying
/// what the chosen one shows. It holds no state, so any screen can ask it
/// (Ustawienia, the first-start setup, a conversation's menu): give it the
/// current [value] and take the answer in [onChanged].
///
/// With [global] given it is a conversation's own choice: one more option,
/// "Jak globalnie", stands for `null` (the setting, [global], applies).
class NotificationPrivacyChoice extends StatelessWidget {
  const NotificationPrivacyChoice({
    super.key,
    required this.value,
    required this.onChanged,
    this.global,
  });

  final NotificationPrivacy? value;
  final ValueChanged<NotificationPrivacy?> onChanged;
  final NotificationPrivacy? global;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final NotificationPrivacy? global = this.global;
    final NotificationPrivacy shown =
        value ?? global ?? AppSettings.defaultNotificationPrivacy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          key: const Key('notification-privacy-choice'),
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (global != null)
              ChoiceChip(
                key: const Key('notification-privacy-global'),
                showCheckmark: false,
                label: Text(t('Jak globalnie')),
                selected: value == null,
                onSelected: (_) => onChanged(null),
              ),
            for (final NotificationPrivacy level in NotificationPrivacy.values)
              ChoiceChip(
                key: Key('notification-privacy-${level.name}'),
                showCheckmark: false,
                label: Text(level.label),
                selected: value == level,
                onSelected: (_) => onChanged(level),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          global != null && value == null
              ? t('Jak w ustawieniach: {level}. {description}', {
                  'level': global.label,
                  'description': global.description,
                })
              : shown.description,
          key: const Key('notification-privacy-description'),
          style: TextStyle(
            color: zen.textSecondary,
            fontSize: 13.5,
            height: 1.35,
          ),
        ),
      ],
    );
  }
}

/// [NotificationPrivacyChoice] bound to the saved setting.
class NotificationPrivacySettingChoice extends ConsumerWidget {
  const NotificationPrivacySettingChoice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final NotificationPrivacy level = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.notificationPrivacy,
      ),
    );
    return NotificationPrivacyChoice(
      value: level,
      onChanged: (NotificationPrivacy? value) {
        if (value != null) {
          unawaited(
            ref
                .read(appSettingsControllerProvider.notifier)
                .setNotificationPrivacy(value),
          );
        }
      },
    );
  }
}

/// A conversation's own level (a friend's address or `group:<id>` as
/// [conversationKey]), asked in a dialog and saved at once.
Future<void> showConversationNotificationPrivacyDialog(
  BuildContext context, {
  required String conversationKey,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      key: const Key('conversation-notification-privacy-dialog'),
      title: Text(t('Powiadomienia z tej rozmowy')),
      scrollable: true,
      content: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final NotificationPrivacy global = ref.watch(
            appSettingsControllerProvider.select(
              (AppSettings s) => s.notificationPrivacy,
            ),
          );
          final NotificationPrivacy? own = ref.watch(
            socialHubControllerProvider.select(
              (state) => state.ownNotificationPrivacyOf(conversationKey),
            ),
          );
          return NotificationPrivacyChoice(
            value: own,
            global: global,
            onChanged: (NotificationPrivacy? value) => unawaited(
              ref
                  .read(socialHubControllerProvider.notifier)
                  .setConversationNotificationPrivacy(conversationKey, value),
            ),
          );
        },
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('conversation-notification-privacy-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Gotowe')),
        ),
      ],
    ),
  );
}
