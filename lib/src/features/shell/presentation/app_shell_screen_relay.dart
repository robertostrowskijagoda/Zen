part of 'app_shell_screen.dart';

/// Settings entry for the offline mailboxes (friends relaying mail).
class _RelayMailboxPanel extends ConsumerWidget {
  const _RelayMailboxPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RelayEngine? engine = ref.watch(relayEngineProvider);
    if (engine == null) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    return ValueListenableBuilder<RelayOverview>(
      valueListenable: engine.overview,
      builder: (BuildContext context, RelayOverview overview, Widget? _) {
        final String mailboxes = tn(
          overview.relays.length,
          one: '{n} skrzynka',
          few: '{n} skrzynki',
          many: '{n} skrzynek',
        );
        final String mode = overview.isAutomatic
            ? t('wybór automatyczny')
            : t('wybór ręczny');
        final String subtitle = overview.relays.isEmpty
            ? t('Dodaj znajomych, żeby wiadomości mogły na Ciebie czekać.')
            : '$mailboxes · $mode';
        return ZenTile(
          key: const Key('settings-relay-button'),
          icon: Icons.markunread_mailbox_outlined,
          tone: zenTone(zen, 5),
          title: t('Skrzynki offline'),
          subtitle: subtitle,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => const _RelayMailboxScreen(),
            ),
          ),
        );
      },
    );
  }
}

class _RelayMailboxScreen extends ConsumerWidget {
  const _RelayMailboxScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RelayEngine? engine = ref.watch(relayEngineProvider);
    final ZenColors zen = ZenColors.of(context);
    final List<FriendProfile> friends = watchSocialPeople(ref).acceptedFriends;
    return Scaffold(
      key: const Key('relay-settings-screen'),
      appBar: AppBar(title: Text(t('Skrzynki offline'))),
      body: engine == null
          ? const SizedBox.shrink()
          : ValueListenableBuilder<RelayOverview>(
              valueListenable: engine.overview,
              builder: (BuildContext context, RelayOverview overview, Widget? _) {
                final int max = engine.config.maxRelays;
                Future<void> setManual(List<String>? relays) async {
                  try {
                    await engine.setManualRelays(relays);
                  } catch (error) {
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          t('Nie udało się zapisać: {error}', {'error': error}),
                        ),
                      ),
                    );
                  }
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: <Widget>[
                    ZenHero(
                      title: t('Wiadomości poczekają na Ciebie'),
                      icon: Icons.markunread_mailbox_outlined,
                      tone: zenTone(zen, 5),
                      text: t(
                        'Kiedy jesteś offline, wiadomości do Ciebie czekają '
                        'u wybranych znajomych. Są zaszyfrowane Twoim '
                        'kluczem — znajomi przechowują je, ale nie mogą ich '
                        'przeczytać. Gdy wrócisz, odbierasz wszystko '
                        'od pierwszej skrzynki, która jest dostępna.',
                      ),
                    ),
                    ZenSection(t('Wybór skrzynek'), top: 16),
                    ZenGroup(
                      children: <Widget>[
                        SwitchListTile.adaptive(
                          key: const Key('relay-auto-switch'),
                          secondary: ZenIconBadge(
                            icon: Icons.auto_awesome_rounded,
                            tone: zenTone(zen, 5),
                            size: 40,
                          ),
                          title: Text(t('Wybieraj automatycznie')),
                          subtitle: Text(
                            t('Najaktywniejsi znajomi, maksymalnie {max}.', {
                              'max': max,
                            }),
                            style: TextStyle(color: zen.textSecondary),
                          ),
                          value: overview.isAutomatic,
                          onChanged: (bool automatic) => setManual(
                            automatic ? null : List<String>.of(overview.relays),
                          ),
                        ),
                      ],
                    ),
                    ZenSection(
                      overview.isAutomatic
                          ? t('Aktualne skrzynki')
                          : tn(
                              max,
                              one: 'Wybierz do {n} znajomego',
                              few: 'Wybierz do {n} znajomych',
                              many: 'Wybierz do {n} znajomych',
                            ),
                      top: 16,
                    ),
                    if (friends.isEmpty)
                      ZenEmpty(
                        icon: Icons.group_outlined,
                        tone: zen.textMuted,
                        title: t('Nie masz jeszcze znajomych.'),
                        text: t(
                          'Skrzynki prowadzą znajomi — dodaj kogoś, '
                          'a pojawi się tutaj.',
                        ),
                      )
                    else
                      ZenGroup(
                        children: <Widget>[
                          for (final FriendProfile friend in friends)
                            _RelayFriendTile(
                              friend: friend,
                              selected: overview.relays.any(
                                (String address) =>
                                    PeerShareCodec.addressesEqual(
                                      address,
                                      friend.address,
                                    ),
                              ),
                              enabled: !overview.isAutomatic,
                              onChanged: (bool selected) {
                                final List<String> next = overview.relays
                                    .where(
                                      (String a) =>
                                          !PeerShareCodec.addressesEqual(
                                            a,
                                            friend.address,
                                          ),
                                    )
                                    .toList();
                                if (selected) {
                                  if (next.length >= max) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          tn(
                                            max,
                                            one:
                                                'Możesz wybrać najwyżej {n} '
                                                'skrzynkę.',
                                            few:
                                                'Możesz wybrać najwyżej {n} '
                                                'skrzynki.',
                                            many:
                                                'Możesz wybrać najwyżej {n} '
                                                'skrzynek.',
                                          ),
                                        ),
                                      ),
                                    );
                                    return;
                                  }
                                  next.add(friend.address);
                                }
                                unawaited(setManual(next));
                              },
                            ),
                        ],
                      ),
                    ZenSection(t('Grupy'), top: 16),
                    ZenGroup(
                      children: <Widget>[
                        SwitchListTile.adaptive(
                          key: const Key('relay-share-groups-switch'),
                          secondary: ZenIconBadge(
                            icon: Icons.groups_rounded,
                            tone: zenTone(zen, 2),
                            size: 40,
                          ),
                          title: Text(t('Ujawniaj skrzynki członkom grup')),
                          subtitle: Text(
                            overview.shareWithGroups
                                ? t(
                                    'Członkowie Twoich grup, których nie masz '
                                    'w znajomych, dostają Twój klucz oraz '
                                    'adresy znajomych, którzy prowadzą Twoje '
                                    'skrzynki (do {max}). Dzięki temu mogą '
                                    'zostawiać Ci wiadomości grupowe, gdy '
                                    'jesteś offline — ale widzą, którzy '
                                    'znajomi są Twoimi skrzynkami.',
                                    {'max': max},
                                  )
                                : t(
                                    'Tylko znajomi znają Twoje skrzynki. '
                                    'Członkowie grup spoza znajomych nie '
                                    'dostają ani Twojego klucza, ani adresów '
                                    'skrzynek, więc ich wiadomości grupowe '
                                    'dotrą do Ciebie tylko wtedy, gdy oboje '
                                    'jesteście online. Wyłączenie nie cofa '
                                    'tego, co już od Ciebie dostali.',
                                  ),
                            style: TextStyle(
                              color: zen.textSecondary,
                              height: 1.35,
                            ),
                          ),
                          value: overview.shareWithGroups,
                          onChanged: (bool share) =>
                              unawaited(engine.setShareWithGroups(share)),
                        ),
                      ],
                    ),
                    ZenSection(t('Stan'), top: 16),
                    ZenGroup(
                      children: <Widget>[
                        _RelayStatRow(
                          icon: Icons.outbox_outlined,
                          tone: zenTone(zen, 0),
                          label: t('Czeka na doręczenie'),
                          value: '${overview.outboxCount}',
                        ),
                        _RelayStatRow(
                          icon: Icons.inventory_2_outlined,
                          tone: zenTone(zen, 3),
                          label: t('Przechowujesz dla znajomych'),
                          value: t('{count} ({people} os.)', {
                            'count': overview.heldEnvelopeCount,
                            'people': overview.heldForPeerCount,
                          }),
                        ),
                        if (overview.publicKeyFingerprint.isNotEmpty)
                          _RelayStatRow(
                            icon: Icons.fingerprint_rounded,
                            tone: zenTone(zen, 6),
                            label: t('Odcisk klucza'),
                            value: overview.publicKeyFingerprint,
                            mono: true,
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
    );
  }
}

class _RelayFriendTile extends StatelessWidget {
  const _RelayFriendTile({
    required this.friend,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final FriendProfile friend;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return CheckboxListTile.adaptive(
      key: Key('relay-friend-${friend.address}'),
      value: selected,
      onChanged: enabled ? (bool? value) => onChanged(value ?? false) : null,
      title: Text(
        friend.displayLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        friend.isOnline ? t('online') : friend.lastActivityLabel,
        style: TextStyle(
          color: friend.isOnline ? zen.success : zen.textSecondary,
        ),
      ),
      secondary: ZenBlobAvatar(
        name: friend.displayLabel,
        online: friend.isOnline,
        size: 40,
      ),
    );
  }
}

class _RelayStatRow extends StatelessWidget {
  const _RelayStatRow({
    required this.icon,
    required this.tone,
    required this.label,
    required this.value,
    this.mono = false,
  });

  final IconData icon;
  final Color tone;
  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final TextStyle valueStyle = mono
        ? zen.mono(
            color: zen.textPrimary,
            size: 12.5,
            weight: FontWeight.w600,
            letterSpacing: 0.2,
          )
        : TextStyle(
            color: zen.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: <Widget>[
          ZenIconBadge(icon: icon, tone: tone, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: mono
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        label,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                        ),
                      ),
                      const SizedBox(height: 3),
                      SelectableText(value, style: valueStyle),
                    ],
                  )
                : Text(
                    label,
                    style: TextStyle(color: zen.textSecondary, fontSize: 14),
                  ),
          ),
          if (!mono) ...<Widget>[
            const SizedBox(width: 12),
            Text(value, style: valueStyle),
          ],
        ],
      ),
    );
  }
}
