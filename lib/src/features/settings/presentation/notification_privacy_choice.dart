import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/settings/notice_kind.dart';
import 'package:zen/src/features/settings/presentation/chip_tap_target.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

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
          runSpacing: 0,
          children: <Widget>[
            if (global != null)
              ChipTapTarget(
                child: ChoiceChip(
                  key: const Key('notification-privacy-global'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(t('Jak w ustawieniach')),
                  selected: value == null,
                  onSelected: (_) => onChanged(null),
                ),
              ),
            for (final NotificationPrivacy level in NotificationPrivacy.values)
              ChipTapTarget(
                child: ChoiceChip(
                  key: Key('notification-privacy-${level.name}'),
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(level.label),
                  selected: value == level,
                  onSelected: (_) => onChanged(level),
                ),
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

/// How long "Wycisz" mutes a conversation, from now: an hour, eight
/// hours, until 8 o'clock tomorrow, a week, or until switched on again.
enum MuteFor {
  hour,
  eightHours,
  morning,
  week,
  forever;

  String get label => switch (this) {
    MuteFor.hour => t('1 godz.'),
    MuteFor.eightHours => t('8 godz.'),
    MuteFor.morning => t('Do rana'),
    MuteFor.week => t('Tydzień'),
    MuteFor.forever => t('Do odwołania'),
  };

  /// Until when, from [now].
  int untilMillis(DateTime now) => switch (this) {
    MuteFor.hour => now.add(const Duration(hours: 1)).millisecondsSinceEpoch,
    MuteFor.eightHours =>
      now.add(const Duration(hours: 8)).millisecondsSinceEpoch,
    MuteFor.morning => DateTime(
      now.year,
      now.month,
      now.day + (now.hour < 8 ? 0 : 1),
      8,
    ).millisecondsSinceEpoch,
    MuteFor.week => now.add(const Duration(days: 7)).millisecondsSinceEpoch,
    MuteFor.forever => kMutedForever,
  };
}

/// "Powiadomienia" of one conversation (a friend's address or
/// `group:<id>` as [conversationKey]), in one dialog, saved at once:
/// muting it for a while, a group's "Powiadamiaj o" (every message, only
/// mentions, or as the setting says) and the level of what a notification
/// says.
Future<void> showConversationNotificationPrivacyDialog(
  BuildContext context, {
  required String conversationKey,
}) {
  final bool group = conversationKey.startsWith('group:');
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      key: const Key('conversation-notification-privacy-dialog'),
      title: Text(t('Powiadomienia z tej rozmowy')),
      scrollable: true,
      content: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final ZenColors zen = ZenColors.of(context);
          final AppSettings settings = ref.watch(appSettingsControllerProvider);
          final SocialHubController hub = ref.read(
            socialHubControllerProvider.notifier,
          );
          final DateTime now = DateTime.now();
          final int? mutedUntil = ref.watch(
            socialHubControllerProvider.select(
              (state) => state.mutedUntilOf(
                conversationKey,
                now.millisecondsSinceEpoch,
              ),
            ),
          );
          final bool? all = ref.watch(
            socialHubControllerProvider.select(
              (state) => state.groupNotifyAll[conversationKey],
            ),
          );
          final NotificationPrivacy? own = ref.watch(
            socialHubControllerProvider.select(
              (state) => state.ownNotificationPrivacyOf(conversationKey),
            ),
          );
          final TextStyle heading = TextStyle(
            fontWeight: FontWeight.w700,
            color: zen.textPrimary,
          );
          final TextStyle note = TextStyle(
            color: zen.textSecondary,
            fontSize: 13.5,
            height: 1.35,
          );
          String until(int millis) {
            if (millis >= kMutedForever) {
              return t('Wyciszona do odwołania.');
            }
            final DateTime at = DateTime.fromMillisecondsSinceEpoch(millis);
            String two(int v) => v.toString().padLeft(2, '0');
            return t('Wyciszona do {date} {time}.', <String, Object?>{
              'date': '${two(at.day)}.${two(at.month)}',
              'time': '${two(at.hour)}:${two(at.minute)}',
            });
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(t('Wycisz'), style: heading),
              const SizedBox(height: 4),
              Wrap(
                key: const Key('conversation-mute-choice'),
                spacing: 8,
                children: <Widget>[
                  ChipTapTarget(
                    child: ChoiceChip(
                      key: const Key('conversation-mute-off'),
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      label: Text(t('Nie')),
                      selected: mutedUntil == null,
                      onSelected: (_) => unawaited(
                        hub.setConversationMutedUntil(conversationKey, null),
                      ),
                    ),
                  ),
                  for (final MuteFor m in MuteFor.values)
                    ChipTapTarget(
                      child: ChoiceChip(
                        key: Key('conversation-mute-${m.name}'),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(m.label),
                        selected: false,
                        onSelected: (_) => unawaited(
                          hub.setConversationMutedUntil(
                            conversationKey,
                            m.untilMillis(DateTime.now()),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              Text(
                mutedUntil == null
                    ? t(
                        'Wyciszona rozmowa jest na liście w aplikacji, bez '
                        'powiadomień i dźwięku. Wzmianka o Tobie przychodzi '
                        'zawsze.',
                      )
                    : until(mutedUntil),
                key: const Key('conversation-mute-state'),
                style: note,
              ),
              if (group) ...<Widget>[
                const SizedBox(height: 14),
                Text(t('Powiadamiaj o'), style: heading),
                const SizedBox(height: 4),
                Wrap(
                  key: const Key('group-notify-choice'),
                  spacing: 8,
                  children: <Widget>[
                    ChipTapTarget(
                      child: ChoiceChip(
                        key: const Key('group-notify-setting'),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(
                          settings.groupMentionsOnly
                              ? t('Jak w ustawieniach (wzmianki)')
                              : t('Jak w ustawieniach (wszystko)'),
                        ),
                        selected: all == null,
                        onSelected: (_) => unawaited(
                          hub.setGroupNotifyAll(
                            conversationKey.substring('group:'.length),
                            null,
                          ),
                        ),
                      ),
                    ),
                    ChipTapTarget(
                      child: ChoiceChip(
                        key: const Key('group-notify-all'),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(t('Każdej wiadomości')),
                        selected: all == true,
                        onSelected: (_) => unawaited(
                          hub.setGroupNotifyAll(
                            conversationKey.substring('group:'.length),
                            true,
                          ),
                        ),
                      ),
                    ),
                    ChipTapTarget(
                      child: ChoiceChip(
                        key: const Key('group-notify-mentions'),
                        materialTapTargetSize: MaterialTapTargetSize.padded,
                        label: Text(t('Tylko wzmiankach')),
                        selected: all == false,
                        onSelected: (_) => unawaited(
                          hub.setGroupNotifyAll(
                            conversationKey.substring('group:'.length),
                            false,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 14),
              Text(t('Treść powiadomień'), style: heading),
              const SizedBox(height: 4),
              NotificationPrivacyChoice(
                value: own,
                global: settings.notificationPrivacy,
                onChanged: (NotificationPrivacy? value) => unawaited(
                  hub.setConversationNotificationPrivacy(
                    conversationKey,
                    value,
                  ),
                ),
              ),
            ],
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

/// What a notification of [kind] says (Ustawienia → Powiadomienia i
/// dźwięki → "Treść" under the kind), asked in a dialog and saved at once:
/// a level of its own, or the general one.
Future<void> showNoticeKindPrivacyDialog(
  BuildContext context, {
  required NoticeKind kind,
}) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      key: Key('notice-privacy-dialog-${kind.name}'),
      title: Text(t('Treść powiadomień: {kind}', {'kind': kind.label})),
      scrollable: true,
      content: Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final AppSettings settings = ref.watch(appSettingsControllerProvider);
          return NotificationPrivacyChoice(
            value: settings.noticePrivacy[kind],
            global: settings.notificationPrivacy,
            onChanged: (NotificationPrivacy? value) => unawaited(
              ref
                  .read(appSettingsControllerProvider.notifier)
                  .setNoticePrivacy(kind, value),
            ),
          );
        },
      ),
      actions: <Widget>[
        TextButton(
          key: const Key('notice-privacy-dialog-close'),
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t('Gotowe')),
        ),
      ],
    ),
  );
}
