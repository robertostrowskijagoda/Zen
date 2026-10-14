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
        final String subtitle = overview.relays.isEmpty
            ? 'Dodaj znajomych, żeby wiadomości mogły na Ciebie czekać.'
            : '${overview.relays.length} '
                  '${_mailboxNoun(overview.relays.length)} · '
                  '${overview.isAutomatic ? 'wybór automatyczny' : 'wybór ręczny'}';
        return ZenTile(
          key: const Key('settings-relay-button'),
          icon: Icons.markunread_mailbox_outlined,
          tone: zenTone(zen, 5),
          title: 'Skrzynki offline',
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

String _mailboxNoun(int count) {
  if (count == 1) {
    return 'skrzynka';
  }
  final int mod10 = count % 10;
  final int mod100 = count % 100;
  return mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)
      ? 'skrzynki'
      : 'skrzynek';
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
      appBar: AppBar(title: const Text('Skrzynki offline')),
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
                      SnackBar(content: Text('Nie udało się zapisać: $error')),
                    );
                  }
                }

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: <Widget>[
                    ZenHero(
                      title: 'Wiadomości poczekają na Ciebie',
                      icon: Icons.markunread_mailbox_outlined,
                      tone: zenTone(zen, 5),
                      text:
                          'Kiedy jesteś offline, wiadomości do Ciebie czekają '
                          'u wybranych znajomych. Są zaszyfrowane Twoim '
                          'kluczem — znajomi przechowują je, ale nie mogą ich '
                          'przeczytać. Gdy wrócisz, odbierasz wszystko '
                          'od pierwszej skrzynki, która jest dostępna.',
                    ),
                    const ZenSection('Wybór skrzynek', top: 16),
                    ZenGroup(
                      children: <Widget>[
                        SwitchListTile.adaptive(
                          key: const Key('relay-auto-switch'),
                          secondary: ZenIconBadge(
                            icon: Icons.auto_awesome_rounded,
                            tone: zenTone(zen, 5),
                            size: 40,
                          ),
                          title: const Text('Wybieraj automatycznie'),
                          subtitle: Text(
                            'Najaktywniejsi znajomi, maksymalnie $max.',
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
                          ? 'Aktualne skrzynki'
                          : 'Wybierz do $max znajomych',
                      top: 16,
                    ),
                    if (friends.isEmpty)
                      ZenEmpty(
                        icon: Icons.group_outlined,
                        tone: zen.textMuted,
                        title: 'Nie masz jeszcze znajomych.',
                        text:
                            'Skrzynki prowadzą znajomi — dodaj kogoś, '
                            'a pojawi się tutaj.',
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
                                          'Możesz wybrać najwyżej $max skrzynek.',
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
                    const ZenSection('Grupy', top: 16),
                    ZenGroup(
                      children: <Widget>[
                        SwitchListTile.adaptive(
                          key: const Key('relay-share-groups-switch'),
                          secondary: ZenIconBadge(
                            icon: Icons.groups_rounded,
                            tone: zenTone(zen, 2),
                            size: 40,
                          ),
                          title: const Text('Skrzynki także dla grup'),
                          subtitle: Text(
                            overview.shareWithGroups
                                ? 'Osoby z Twoich grup, których nie masz w '
                                      'znajomych, mogą zostawiać Ci wiadomości '
                                      'grupowe w skrzynkach. Widzą wtedy, '
                                      'którzy znajomi je prowadzą.'
                                : 'Wiadomości grupowe od osób spoza '
                                      'znajomych dotrą tylko, gdy jesteś '
                                      'online.',
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
                    const ZenSection('Stan', top: 16),
                    ZenGroup(
                      children: <Widget>[
                        _RelayStatRow(
                          icon: Icons.outbox_outlined,
                          tone: zenTone(zen, 0),
                          label: 'Czeka na doręczenie',
                          value: '${overview.outboxCount}',
                        ),
                        _RelayStatRow(
                          icon: Icons.inventory_2_outlined,
                          tone: zenTone(zen, 3),
                          label: 'Przechowujesz dla znajomych',
                          value:
                              '${overview.heldEnvelopeCount} '
                              '(${overview.heldForPeerCount} os.)',
                        ),
                        if (overview.publicKeyFingerprint.isNotEmpty)
                          _RelayStatRow(
                            icon: Icons.fingerprint_rounded,
                            tone: zenTone(zen, 6),
                            label: 'Odcisk klucza',
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
        friend.isOnline ? 'online' : friend.lastActivityLabel,
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
