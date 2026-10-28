part of 'app_shell_screen.dart';

/// Opens "Skrzynki offline" (the mailbox picker) over whatever is shown.
Future<void> openRelayMailboxScreen(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const _RelayMailboxScreen(),
      ),
    );

/// A card on the chats list while one of this device's mailboxes has
/// stopped answering and nobody can take its place by itself
/// ([RelayOverview.quiet]): "Skrzynka Ola nie odpowiada od 4 dni — wybierz
/// inną", with the way to the picker.
class _RelayQuietCard extends ConsumerWidget {
  const _RelayQuietCard({this.padding = EdgeInsets.zero});

  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RelayEngine? engine = ref.watch(relayEngineProvider);
    if (engine == null) {
      return const SizedBox.shrink();
    }
    final SocialHubState social = watchSocialPeople(ref);
    return ValueListenableBuilder<RelayOverview>(
      valueListenable: engine.overview,
      builder: (BuildContext context, RelayOverview overview, Widget? _) {
        if (overview.quiet.isEmpty) {
          return const SizedBox.shrink();
        }
        final ZenColors zen = ZenColors.of(context);
        final int now = DateTime.now().millisecondsSinceEpoch;
        return Padding(
          padding: padding,
          child: ZenCard(
            key: const Key('relay-quiet-card'),
            tone: zen.warning,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (final RelayQuietMailbox q in overview.quiet)
                  ZenInfo(
                    icon: Icons.markunread_mailbox_outlined,
                    tone: zen.warning,
                    title: quietMailboxTitle(
                      friendNameFor(social, q.friend),
                      q.sinceMillis,
                      now,
                    ),
                    text: quietMailboxText(),
                  ),
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(
                    key: const Key('relay-quiet-card-pick'),
                    onPressed: () => unawaited(openRelayMailboxScreen(context)),
                    child: Text(t('Wybierz skrzynkę')),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

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
        return _WrapTile(
          key: const Key('settings-relay-button'),
          icon: Icons.markunread_mailbox_outlined,
          tone: zen.tone(ZenTone.network),
          title: t('Skrzynki offline'),
          subtitle: subtitle,
          onTap: () => unawaited(openRelayMailboxScreen(context)),
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
      body: SafeArea(
        top: false,
        child: engine == null
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
                            t('Nie udało się zapisać: {error}', {
                              'error': error,
                            }),
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
                        tone: zen.tone(ZenTone.network),
                        text: t(
                          'Kiedy jesteś offline, wiadomości do Ciebie czekają '
                          'u wybranych znajomych. Są zaszyfrowane Twoim '
                          'kluczem — znajomi przechowują je, ale nie mogą ich '
                          'przeczytać. Gdy wrócisz, odbierasz wszystko '
                          'od pierwszej skrzynki, która jest dostępna.',
                        ),
                      ),
                      if (overview.quiet.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 12),
                        for (final RelayQuietMailbox q in overview.quiet)
                          ZenInfo(
                            key: Key('relay-quiet-${q.device}'),
                            icon: Icons.markunread_mailbox_outlined,
                            tone: zen.warning,
                            title: quietMailboxTitle(
                              friendNameFor(watchSocialPeople(ref), q.friend),
                              q.sinceMillis,
                              DateTime.now().millisecondsSinceEpoch,
                            ),
                            text: overview.isAutomatic
                                ? t(
                                    'Żaden inny znajomy nie bywa online na '
                                    'tyle, żeby zastąpić ją sam. Wyłącz wybór '
                                    'automatyczny i zaznacz kogoś — najlepiej '
                                    'z komputerem albo Androidem.',
                                  )
                                : t(
                                    'Odznacz ją i zaznacz kogoś, kto bywa '
                                    'online — najlepiej z komputerem albo '
                                    'Androidem.',
                                  ),
                          ),
                      ],
                      ZenSection(t('Wybór skrzynek'), top: 16),
                      ZenGroup(
                        children: <Widget>[
                          SwitchListTile.adaptive(
                            key: const Key('relay-auto-switch'),
                            secondary: ZenIconBadge(
                              icon: Icons.auto_awesome_rounded,
                              tone: zen.tone(ZenTone.network),
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
                              automatic
                                  ? null
                                  : List<String>.of(overview.mailboxFriends),
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
                                candidate:
                                    overview
                                        .candidates[PeerShareCodec.normalizeAddress(
                                      friend.address,
                                    )],
                                selected: overview.mailboxFriends.any(
                                  (String address) =>
                                      PeerShareCodec.addressesEqual(
                                        address,
                                        friend.address,
                                      ),
                                ),
                                enabled: !overview.isAutomatic,
                                onChanged: (bool selected) {
                                  final List<String> next = overview
                                      .mailboxFriends
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
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
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
                              tone: zen.tone(ZenTone.people),
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
                      if (engine.supportsBlobs) ...<Widget>[
                        ZenSection(t('Załączniki'), top: 16),
                        ZenGroup(
                          children: <Widget>[
                            _RelayBlobQuotaTile(
                              quotaBytes: overview.blobQuotaBytes,
                              onChanged: (int bytes) =>
                                  unawaited(engine.setBlobQuota(bytes)),
                            ),
                          ],
                        ),
                      ],
                      ZenSection(t('Stan'), top: 16),
                      ZenGroup(
                        children: <Widget>[
                          _RelayStatRow(
                            icon: Icons.outbox_outlined,
                            tone: zen.tone(ZenTone.communication),
                            label: t('Czeka na doręczenie'),
                            value: '${overview.outboxCount}',
                          ),
                          _RelayStatRow(
                            icon: Icons.inventory_2_outlined,
                            tone: zen.tone(ZenTone.people),
                            label: t('Przechowujesz dla znajomych'),
                            value: t('{count} ({people} os.)', {
                              'count': overview.heldEnvelopeCount,
                              'people': overview.heldForPeerCount,
                            }),
                          ),
                          if (overview.heldBlobBytes > 0)
                            _RelayStatRow(
                              icon: Icons.attach_file_rounded,
                              tone: zen.tone(ZenTone.media),
                              label: t('Załączniki znajomych u Ciebie'),
                              value: t('{mb} MB', {
                                'mb': (overview.heldBlobBytes / (1024 * 1024))
                                    .toStringAsFixed(1),
                              }),
                            ),
                          if (overview.publicKeyFingerprint.isNotEmpty)
                            _RelayStatRow(
                              icon: Icons.fingerprint_rounded,
                              tone: zen.tone(ZenTone.privacy),
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
      ),
    );
  }
}

/// How much of friends' attachments this device keeps per sender.
class _RelayBlobQuotaTile extends StatelessWidget {
  const _RelayBlobQuotaTile({
    required this.quotaBytes,
    required this.onChanged,
  });

  final int quotaBytes;
  final ValueChanged<int> onChanged;

  static const int _mb = 1024 * 1024;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int current = quotaBytes ~/ _mb;
    final List<int> options = <int>{0, 5, 10, 20, 50, current}.toList()..sort();
    return ListTile(
      key: const Key('relay-blob-quota'),
      leading: ZenIconBadge(
        icon: Icons.attach_file_rounded,
        tone: zen.tone(ZenTone.media),
        size: 40,
      ),
      title: Text(t('Miejsce na załączniki znajomych')),
      subtitle: Text(
        t(
          'Zdjęcia i nagrania dla znajomych, dla których prowadzisz '
          'skrzynkę, czekają u Ciebie zaszyfrowane, gdy są offline — '
          'najwyżej tyle od jednej osoby. Wyłączenie nie usuwa tego, '
          'co już przechowujesz.',
        ),
        style: TextStyle(color: zen.textSecondary, height: 1.35),
      ),
      trailing: DropdownButton<int>(
        key: const Key('relay-blob-quota-dropdown'),
        value: current,
        underline: const SizedBox.shrink(),
        items: <DropdownMenuItem<int>>[
          for (final int mb in options)
            DropdownMenuItem<int>(
              value: mb,
              child: Text(mb == 0 ? t('wył.') : t('{mb} MB', {'mb': mb})),
            ),
        ],
        onChanged: (int? mb) {
          if (mb != null && mb != current) {
            onChanged(mb * _mb);
          }
        },
      ),
    );
  }
}

class _RelayFriendTile extends StatelessWidget {
  const _RelayFriendTile({
    required this.friend,
    required this.candidate,
    required this.selected,
    required this.enabled,
    required this.onChanged,
  });

  final FriendProfile friend;

  /// How good a mailbox the friend makes, as this device has seen it.
  final RelayMailboxCandidate? candidate;
  final bool selected;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  /// The friend's device kind and how often it answered: "komputer ·
  /// dostępna przez 92% czasu".
  String? _mailboxLine() {
    final RelayMailboxCandidate? c = candidate;
    if (c == null) {
      return null;
    }
    final double? share = c.answeredShare;
    final String reach = share == null
        ? t('jeszcze nie sprawdzona')
        : t('dostępna przez {percent}% czasu', {
            'percent': (share * 100).round(),
          });
    final String kind = relayDeviceKindLabel(c.deviceClass);
    return kind.isEmpty ? reach : '$kind · $reach';
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int now = DateTime.now().millisecondsSinceEpoch;
    final RelayMailboxCandidate? c = candidate;
    final String? mailbox = _mailboxLine();
    return CheckboxListTile.adaptive(
      key: Key('relay-friend-${friend.address}'),
      value: selected,
      onChanged: enabled ? (bool? value) => onChanged(value ?? false) : null,
      title: Text(
        friend.displayLabel,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            friendPresenceLine(friend, now) ?? friend.lastActivityLabel,
            style: TextStyle(
              color: switch (friend.shownPresence) {
                PeerPresence.online => zen.success,
                PeerPresence.background => zen.tone(ZenTone.network),
                _ => zen.textSecondary,
              },
            ),
          ),
          if (mailbox != null)
            Text(
              mailbox,
              key: Key('relay-friend-reach-${friend.address}'),
              style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
            ),
          if (c != null && c.quietSinceMillis > 0)
            Text(
              t('Nie odpowiada {time}', {
                'time': quietForText(c.quietSinceMillis, now),
              }),
              style: TextStyle(color: zen.danger, fontSize: 12.5),
            )
          else if (isWeakMailbox(c))
            Text(
              t('iPhone rzadko jest online — słaba skrzynka'),
              key: Key('relay-friend-weak-${friend.address}'),
              style: TextStyle(color: zen.warning, fontSize: 12.5),
            ),
        ],
      ),
      secondary: ZenBlobAvatar(
        name: friend.displayLabel,
        online: friend.shownPresence == PeerPresence.online,
        away: friend.shownPresence == PeerPresence.background,
        unknown: friend.shownPresence == PeerPresence.unknown,
        showStatus: friend.presence != PeerPresence.hidden,
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
