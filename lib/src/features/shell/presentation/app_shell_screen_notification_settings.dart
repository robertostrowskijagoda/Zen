part of 'app_shell_screen.dart';

// Ustawienia → Powiadomienia i dźwięki: everything about notifications in
// one place. What a notification says (the level of its preview), the
// sounds (in the app, and of the system notifications), one switch and one
// level of what it says per kind of news ([NoticeKind]), the people whose
// posts are muted, and whether notifications reach the phone in the
// background.

IconData _noticeKindIcon(NoticeKind kind) => switch (kind) {
  NoticeKind.message => Icons.chat_bubble_outline_rounded,
  NoticeKind.groupMessage => Icons.groups_2_outlined,
  NoticeKind.strangerMessage => Icons.mark_chat_unread_outlined,
  NoticeKind.call => Icons.call_outlined,
  NoticeKind.mention => Icons.alternate_email_rounded,
  NoticeKind.reaction => Icons.favorite_border_rounded,
  NoticeKind.friendPost => Icons.article_outlined,
  NoticeKind.farPost => Icons.public_rounded,
  NoticeKind.invitation => Icons.person_add_alt_outlined,
  NoticeKind.introduction => Icons.handshake_outlined,
  NoticeKind.meetup => Icons.event_outlined,
  NoticeKind.neighbours => Icons.apartment_outlined,
  NoticeKind.dating => Icons.favorite_outline_rounded,
  NoticeKind.question => Icons.help_outline_rounded,
  NoticeKind.pebble => Icons.landscape_outlined,
  NoticeKind.pyramid => Icons.change_history_rounded,
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
        ZenSection(t('Treść powiadomień'), top: 8),
        _Panel(
          key: const Key('settings-notification-privacy'),
          accentTone: zen.tone(ZenTone.privacy),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _SectionIntro(
                title: t('Co mówi powiadomienie'),
                caption: t(
                  'Na ekranie blokady, w zasłonce i w historii '
                  'powiadomień systemu. Rozmowa może mieć własny '
                  'poziom (menu rozmowy → Treść powiadomień).',
                ),
              ),
              const SizedBox(height: 10),
              const NotificationPrivacySettingChoice(),
            ],
          ),
        ),
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
            for (final NoticeKind kind in NoticeKind.values) ...<Widget>[
              _NoticeKindTile(
                switchKey: _noticeKindKey(kind),
                kind: kind,
                settings: settings,
                onChanged: (bool value) =>
                    unawaited(controller.setNoticeMuted(kind, muted: !value)),
              ),
              if (kind == NoticeKind.message)
                _SettingsSwitchTile(
                  key: const Key('settings-waiting-replies'),
                  icon: Icons.mark_chat_unread_outlined,
                  tone: ZenTone.communication,
                  title: t('Przypominaj o nieodpowiedzianych'),
                  subtitle: t(
                    'Na liście czatów: znajomi, których wiadomość czeka na '
                    'Twoją odpowiedź od 2 dni.',
                  ),
                  value: settings.waitingReplyReminder,
                  onChanged: (bool value) =>
                      unawaited(controller.setWaitingReplyReminder(value)),
                ),
              // Right under the group messages: whether all of them or
              // only mentions (a group can say otherwise in its menu).
              if (kind == NoticeKind.groupMessage &&
                  !settings.mutes(NoticeKind.groupMessage))
                _SettingsSwitchTile(
                  key: const Key('settings-group-mentions-only'),
                  icon: Icons.alternate_email_rounded,
                  tone: ZenTone.communication,
                  title: t('W grupach tylko wzmianki'),
                  subtitle: t(
                    'Powiadomienie tylko o wiadomości, która Cię wymienia. '
                    'Grupa może to zmienić w swoim menu → Powiadomienia.',
                  ),
                  value: settings.groupMentionsOnly,
                  onChanged: (bool value) =>
                      unawaited(controller.setGroupMentionsOnly(value)),
                ),
            ],
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
            'są na liście powiadomień w aplikacji (dzwonek na górze). '
            '„Treść” pod rodzajem mówi, co pokazuje jego powiadomienie; '
            'rozmowa może mieć jeszcze własny poziom. Alarm przyjaciela, '
            'prośba o pomoc w odzyskaniu konta i pytania o bezpieczeństwo '
            'na randce przychodzą zawsze.',
          ),
        ),
        _SettingsGroup(
          title: t('Więcej'),
          tiles: <Widget>[
            _SettingsNavTile(
              key: const Key('settings-nav-muted-post-authors'),
              icon: Icons.notifications_off_outlined,
              tone: ZenTone.communication,
              title: t('Wyciszone osoby'),
              subtitle: settings.mutedPostAuthors.isEmpty
                  ? t('Nikogo nie wyciszono')
                  : tn(
                      settings.mutedPostAuthors.length,
                      one: 'Bez powiadomień o postach: {n} osoba',
                      few: 'Bez powiadomień o postach: {n} osoby',
                      many: 'Bez powiadomień o postach: {n} osób',
                    ),
              pageTitle: t('Wyciszone osoby'),
              pageChildren: const <Widget>[_MutedPostAuthorsSection()],
            ),
            // Whether the notifications reach the phone at all while Zen is
            // in the background.
            if (Platform.isAndroid)
              _SettingsNavTile(
                key: const Key('settings-nav-delivery'),
                icon: Icons.notifications_active_outlined,
                tone: ZenTone.communication,
                title: t('Powiadomienia i praca w tle'),
                subtitle: t('Uprawnienia, dostarczanie w tle, ekran połączeń'),
                // The one page of the permissions (as "Uprawnienia i
                // Bluetooth"): notifications, no sleeping, the full screen
                // for calls, the phone maker's own battery limits.
                onTap: () => unawaited(PermissionsScreen.open(context)),
              ),
            if (Platform.isIOS)
              _SettingsNavTile(
                key: const Key('settings-nav-ios-background'),
                icon: Icons.notifications_active_outlined,
                tone: ZenTone.communication,
                title: t('Praca w tle'),
                subtitle: t('Sprawdzanie skrzynek w tle, odbieranie cały czas'),
                pageTitle: t('Praca w tle'),
                pageChildren: const <Widget>[
                  _Panel(child: IosBackgroundSection()),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

/// One kind of news: its switch, and under it what its notification says
/// ("Treść: …", a dialog). A new version of Zen is always told: its switch
/// stays on.
class _NoticeKindTile extends StatelessWidget {
  const _NoticeKindTile({
    required this.switchKey,
    required this.kind,
    required this.settings,
    required this.onChanged,
  });

  /// The key of the row with the switch (the tests tap it).
  final Key switchKey;
  final NoticeKind kind;
  final AppSettings settings;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool on = !settings.mutes(kind);
    final NotificationPrivacy? own = settings.noticePrivacy[kind];
    final String level = own == null
        ? t('Treść: jak w ustawieniach ({level})', <String, Object?>{
            'level': settings.notificationPrivacy.label,
          })
        : t('Treść: {level}', <String, Object?>{'level': own.label});
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        MergeSemantics(
          key: switchKey,
          child: InkWell(
            onTap: kind.canMute ? () => onChanged(!on) : null,
            child: _SettingsRowBody(
              icon: _noticeKindIcon(kind),
              tone: zen.tone(ZenTone.communication),
              title: kind.label,
              subtitle: kind.description,
              trailing: Switch.adaptive(
                value: on,
                onChanged: kind.canMute ? onChanged : null,
              ),
            ),
          ),
        ),
        if (kind.hasPrivacy && on)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 64, bottom: 6),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: Key('settings-notice-privacy-${kind.name}'),
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: Text(level),
                onPressed: () =>
                    unawaited(showNoticeKindPrivacyDialog(context, kind: kind)),
              ),
            ),
          ),
      ],
    );
  }
}
