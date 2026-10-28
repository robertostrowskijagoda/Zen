part of 'app_shell_screen.dart';

// Ustawienia → Powiadomienia i dźwięki: the sounds (in the app, and of the
// system notifications) and one switch per kind of news ([NoticeKind]).

IconData _noticeKindIcon(NoticeKind kind) => switch (kind) {
  NoticeKind.message => Icons.chat_bubble_outline_rounded,
  NoticeKind.groupMessage => Icons.groups_2_outlined,
  NoticeKind.call => Icons.call_outlined,
  NoticeKind.mention => Icons.alternate_email_rounded,
  NoticeKind.reaction => Icons.favorite_border_rounded,
  NoticeKind.friendPost => Icons.article_outlined,
  NoticeKind.farPost => Icons.public_rounded,
  NoticeKind.invitation => Icons.person_add_alt_outlined,
  NoticeKind.update => Icons.system_update_outlined,
};

/// The key of the switch of [kind]; the friends' posts keep the key they
/// had before the switches were gathered on this page.
Key _noticeKindKey(NoticeKind kind) => kind == NoticeKind.friendPost
    ? const Key('settings-post-notifications')
    : Key('settings-notice-${kind.name}');

class _NotificationSettingsSection extends ConsumerWidget {
  const _NotificationSettingsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SettingsGroup(
          title: t('Dźwięki'),
          tiles: <Widget>[
            // iOS gives no way to tell a silenced phone: no sounds of ours.
            if (!Platform.isIOS)
              _SettingsSwitchTile(
                key: const Key('settings-in-app-sounds'),
                icon: Icons.music_note_outlined,
                tone: ZenTone.media,
                title: t('Dźwięki w aplikacji'),
                subtitle: t(
                  'Ciche dźwięki w aplikacji: wysłana i odebrana wiadomość w '
                  'otwartej rozmowie, polubienie, opublikowany post, nowy '
                  'wpis na liście powiadomień, połączenia. Nic nie gra, gdy '
                  'telefon jest wyciszony albo ma „Nie przeszkadzać”.',
                ),
                value: settings.inAppSounds,
                onChanged: (bool value) =>
                    unawaited(controller.setInAppSounds(value)),
              ),
            _SettingsSwitchTile(
              key: const Key('settings-notification-sounds'),
              icon: Icons.notifications_active_outlined,
              tone: ZenTone.communication,
              title: t('Dźwięk powiadomień'),
              subtitle: t(
                'Wyłączone: powiadomienia przychodzą po cichu, bez dźwięku i '
                'wibracji. Dzwoniące połączenie i alarm przyjaciela słychać '
                'zawsze.',
              ),
              value: settings.notificationSounds,
              onChanged: (bool value) =>
                  unawaited(controller.setNotificationSounds(value)),
            ),
          ],
        ),
        _SettingsGroup(
          title: t('Powiadamiaj o'),
          tiles: <Widget>[
            for (final NoticeKind kind in NoticeKind.values)
              _SettingsSwitchTile(
                key: _noticeKindKey(kind),
                icon: _noticeKindIcon(kind),
                tone: ZenTone.communication,
                title: kind.label,
                subtitle: kind.description,
                value: !settings.mutes(kind),
                onChanged: (bool value) =>
                    unawaited(controller.setNoticeMuted(kind, muted: !value)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        if (settings.mutes(NoticeKind.call))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: ZenInfo(
              key: const Key('settings-notice-call-warning'),
              icon: Icons.warning_amber_rounded,
              tone: zen.danger,
              text: t(
                'Połączenia są wyłączone: gdy Zen jest w tle, telefon nie '
                'zadzwoni i nikt się do Ciebie nie dodzwoni. Alarm '
                'przyjaciela nadal dzwoni.',
              ),
            ),
          ),
        ZenInfo(
          icon: Icons.notifications_none_rounded,
          tone: zen.textSecondary,
          text: t(
            'Wyłączony rodzaj nie pokazuje powiadomienia i nie gra dźwięku. '
            'Wiadomości, połączenia, zaproszenia, wzmianki i reakcje nadal '
            'są na liście powiadomień w aplikacji (dzwonek na górze).',
          ),
        ),
      ],
    );
  }
}
