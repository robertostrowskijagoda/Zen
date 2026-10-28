part of 'app_shell_screen.dart';

/// Thin top bar with the live connection status in terminal style (mono,
/// pulsing dot). Tapping it opens the settings screen — there is no
/// separate settings tab anymore. With the rail ([onToggleRail]) its first
/// button shows or hides the rail; the bell, "Mój kod" and, once there is a
/// password, "Zablokuj teraz" sit next to the account menu. Every button has
/// a 44 px hit box, the icons stay 20 px.
class _StatusBar extends ConsumerWidget {
  const _StatusBar({this.railHidden = false, this.onToggleRail});

  final bool railHidden;
  final VoidCallback? onToggleRail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppShellState state = ref.watch(appShellControllerProvider);
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    final VoidCallback? toggleRail = onToggleRail;
    final double width = MediaQuery.sizeOf(context).width;
    final bool offline =
        state.health == ServiceHealth.failed ||
        state.health == ServiceHealth.stopped;
    final int unreadCount = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState s) => s.acceptedFriends.fold<int>(
          0,
          (int sum, FriendProfile f) => sum + f.unreadCount,
        ),
      ),
    );
    final Widget status = state.isConnecting
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Flexible(
                child: Text(
                  t('Łączę'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              ZenAnimatedDots(color: zen.textPrimary, size: 3),
            ],
          )
        : Text(
            state.connectionLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: zen.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          );
    return Material(
      color: zen.surfaceSunk,
      // For a screen reader the bar is the settings button (its own buttons
      // — the rail, help, bell, code, lock, accounts — are read on their
      // own).
      child: Semantics(
        button: true,
        label: t('Ustawienia'),
        child: InkWell(
          key: const Key('chats-status-chip'),
          excludeFromSemantics: true,
          onTap: () => _openSettingsScreen(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: EdgeInsetsDirectional.fromSTEB(
                  toggleRail == null ? 16 : 4,
                  2,
                  4,
                  2,
                ),
                child: Row(
                  children: <Widget>[
                    if (toggleRail != null) ...<Widget>[
                      _barButton(
                        key: Key(
                          railHidden ? 'side-tabs-show' : 'side-tabs-hide',
                        ),
                        tooltip: railHidden
                            ? t('Pokaż pasek')
                            : t('Ukryj pasek'),
                        onPressed: toggleRail,
                        // Points away from the rail's edge to show it, towards
                        // it to hide it; mirrored here, not by the icon font.
                        icon: Directionality(
                          textDirection: TextDirection.ltr,
                          child: Icon(
                            railHidden ==
                                    (Directionality.of(context) ==
                                        TextDirection.ltr)
                                ? Icons.keyboard_double_arrow_right_rounded
                                : Icons.keyboard_double_arrow_left_rounded,
                            size: 20,
                            color: zen.textSecondary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                    // Offline (stopped or failed): a red dot; connecting
                    // keeps the ring. Why it does not work: "Dlaczego nie działa?" in Ustawienia
                    // (the bar opens the settings).
                    offline
                        ? SizedBox.square(
                            key: const Key('status-offline-dot'),
                            dimension: 13,
                            child: Center(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: zen.danger,
                                  shape: BoxShape.circle,
                                ),
                                child: const SizedBox.square(dimension: 7),
                              ),
                            ),
                          )
                        : ZenStatusDot(on: state.isConnected, size: 7),
                    const SizedBox(width: 8),
                    // Takes the free room; one line, cut with an ellipsis
                    // when it is not enough.
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: status,
                      ),
                    ),
                    // Left out on a narrow phone: the bell next to it counts
                    // the unread chats as well and the status label needs
                    // the room.
                    if (unreadCount > 0 && width >= 480) ...<Widget>[
                      ZenNeonFlicker(
                        color: zen.textPrimary,
                        glowRadius: 0,
                        glowAlpha: 0,
                        // Flickers when the count changes, still otherwise.
                        trigger: unreadCount,
                        child: Text(
                          tn(
                            unreadCount,
                            one: '{n} nowa',
                            few: '{n} nowe',
                            many: '{n} nowych',
                          ),
                          style: zen.mono(
                            color: zen.textPrimary,
                            size: 10,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    // Messages, invitations and reactions, newest first.
                    const _NoticesBell(),
                    // Your own code (QR and invite code), one tap away.
                    _barButton(
                      key: const Key('status-my-code'),
                      tooltip: t('Mój kod'),
                      onPressed: () => _openInviteTab(context, ref),
                      icon: Icon(
                        Icons.qr_code_2_rounded,
                        size: 20,
                        color: zen.textSecondary,
                      ),
                    ),
                    // The only place that locks now, one tap away (only once
                    // there is a password).
                    ListenableBuilder(
                      listenable: security,
                      builder: (BuildContext context, Widget? _) =>
                          security.canQuickLock
                          ? _barButton(
                              key: const Key('side-tabs-lock'),
                              tooltip: t('Zablokuj teraz'),
                              onPressed: () => _lockNow(ref, security),
                              icon: Icon(
                                Icons.lock_outline_rounded,
                                size: 20,
                                color: zen.textSecondary,
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                    // Your avatar: the account menu (switch, add).
                    const AccountMenuButton(),
                  ],
                ),
              ),
              Container(height: 1, color: zen.outlineSoft),
            ],
          ),
        ),
      ),
    );
  }
}

/// An icon button of the top bar: a 44 px hit box around the 20 px icon.
Widget _barButton({
  required Key key,
  required String tooltip,
  required VoidCallback onPressed,
  required Widget icon,
}) {
  return IconButton(
    key: key,
    tooltip: tooltip,
    visualDensity: VisualDensity.standard,
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
    padding: EdgeInsets.zero,
    onPressed: onPressed,
    icon: icon,
  );
}

/// "Zablokuj teraz": locks the app; an additional account goes back to the
/// default account's lock screen instead (its own would show that it exists).
void _lockNow(WidgetRef ref, AppSecurityService security) {
  if (!ref.read(zenAccountProvider).isDefault) {
    unawaited(returnToDefaultZenAccount(ref));
    return;
  }
  security.lock();
}

Future<void> _openSettingsScreen(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const RememberedPlace(
        place: ShellPlace.settings,
        child: _SettingsScreen(),
      ),
    ),
  );
}

/// Shows your QR code and invite code ("Mój kod" in the top bar, also "Zaproś"
/// at the top of the settings) on a page of its own.
void _openInviteTab(BuildContext context, WidgetRef ref) {
  unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => const _MyCodeScreen(),
      ),
    ),
  );
}

enum _ChatFilter { all, close, unread, online }

class _ChatsPage extends ConsumerStatefulWidget {
  const _ChatsPage({super.key});

  @override
  ConsumerState<_ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends ConsumerState<_ChatsPage> {
  /// Only the first viewport-worth of cards gets a staggered entrance —
  /// later rebuilds (search, filters, stream updates) render statically.
  static const int _staggeredEntranceItemLimit = 10;

  final TextEditingController _searchController = TextEditingController();
  _ChatFilter _selectedFilter = _ChatFilter.all;
  bool _listEntrancePlayed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _listEntrancePlayed = true;
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The conversations whose name (or the nickname given) has every word
  /// typed, with or without Polish letters.
  List<ConversationPreview> _filter(List<ConversationPreview> source) {
    final SearchQuery query = SearchQuery.parse(_searchController.text);
    if (query.isEmpty) {
      return source;
    }
    return source
        .where(
          (ConversationPreview c) => query.matches('${c.name} ${c.nickname}'),
        )
        .toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AppShellState shellState = ref.watch(appShellControllerProvider);
    final List<InboxEntry> inbox = ref.watch(
      socialHubControllerProvider.select((SocialHubState state) => state.inbox),
    );
    final bool socialDataUnreadable = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.snapshotUnreadable,
      ),
    );
    // The lists are made from the maps here: a select returning a fresh
    // list would rebuild this page on every change of the whole state.
    final SocialHubState people = watchSocialPeople(ref);
    final List<FriendProfile> pendingOutgoingFriends =
        people.pendingOutgoingFriends;
    final List<FriendProfile> acceptedFriends = people.acceptedFriends;
    final Map<String, PeerPublicProfile> peerProfiles = people.peerProfiles;
    ConversationPreview preview(FriendProfile friend) =>
        _conversationFromFriend(
          friend,
          peerProfiles[PeerShareCodec.normalizeAddress(friend.address)],
        );
    final List<ConversationPreview> pendingConversations = _filter(
      pendingOutgoingFriends.map(preview).toList(growable: false),
    );
    final List<ConversationPreview> allAcceptedConversations = _filter(
      acceptedFriends.map(preview).toList(growable: false),
    );
    final int unreadChatsCount = allAcceptedConversations
        .where((ConversationPreview c) => c.unreadCount > 0)
        .length;
    final List<ConversationPreview> conversations = switch (_selectedFilter) {
      _ChatFilter.unread =>
        allAcceptedConversations
            .where((ConversationPreview c) => c.unreadCount > 0)
            .toList(growable: false),
      _ChatFilter.online =>
        allAcceptedConversations
            .where((ConversationPreview c) => c.isOnline)
            .toList(growable: false),
      // Friends marked "Przyjaciel" (the level is private, on this device).
      _ChatFilter.close =>
        allAcceptedConversations
            .where(
              (ConversationPreview c) =>
                  ref.read(friendLevelLookupProvider).of(c.address) ==
                  FriendLevel.close,
            )
            .toList(growable: false),
      _ChatFilter.all => allAcceptedConversations,
    };
    final SearchQuery groupQuery = SearchQuery.parse(_searchController.text);
    // Long enough to look through messages too: they are listed under the
    // conversations (MessageSearchResults), which then also says when
    // nothing was found.
    final bool searchingMessages = groupQuery.searchesMessages;
    ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) => state.groups,
      ),
    );
    final List<GroupProfile> groups = ref
        .read(socialHubControllerProvider)
        .groupList
        .where(
          (GroupProfile g) => groupQuery.isEmpty || groupQuery.matches(g.name),
        )
        .where(
          (GroupProfile g) =>
              _selectedFilter != _ChatFilter.close &&
              (_selectedFilter != _ChatFilter.unread || g.unreadCount > 0),
        )
        .toList(growable: false);
    // Only what waits for an answer: invitations keep their card (with
    // Dołącz / Odrzuć). Everything else is in the notification list (bell).
    final List<InboxEntry> actionableInbox = inbox
        .where(
          (InboxEntry item) =>
              item.type == InboxEntryType.groupInvite ||
              item.type == InboxEntryType.friendRequest,
        )
        .toList(growable: false);
    return Scaffold(
      appBar: ZenSectionBar(title: t('Czaty')),
      body: Column(
        children: <Widget>[
          Expanded(
            child: ListView(
              key: const Key('chats-tab-body'),
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 16),
              // While messages are searched the whole list stays built:
              // the results at its end keep reading (and what they read)
              // also off screen. It is short then: only what matches.
              scrollCacheExtent: searchingMessages
                  ? const ScrollCacheExtent.pixels(20000)
                  : null,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      TextField(
                        key: const Key('chats-search-field'),
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        textInputAction: TextInputAction.search,
                        decoration: InputDecoration(
                          hintText: t('Szukaj rozmów i wiadomości'),
                          // Wraps rather than ending in "…" (French,
                          // Italian on a narrow phone).
                          hintMaxLines: 2,
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 20,
                          ),
                          suffixIcon: _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: t('Wyczyść'),
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                  ),
                                  color: zen.textMuted,
                                  onPressed: () {
                                    _searchController.clear();
                                    setState(() {});
                                  },
                                ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          spacing: 8,
                          children: <Widget>[
                            _FilterChip(
                              label: t('Wszystkie'),
                              isSelected: _selectedFilter == _ChatFilter.all,
                              onTap: () => setState(
                                () => _selectedFilter = _ChatFilter.all,
                              ),
                            ),
                            _FilterChip(
                              key: const Key('chats-filter-close'),
                              label: t('Przyjaciele'),
                              isSelected: _selectedFilter == _ChatFilter.close,
                              onTap: () => setState(
                                () => _selectedFilter = _ChatFilter.close,
                              ),
                            ),
                            _FilterChip(
                              label: t('Nieprzeczytane'),
                              isSelected: _selectedFilter == _ChatFilter.unread,
                              highlight: unreadChatsCount > 0,
                              onTap: () => setState(
                                () => _selectedFilter = _ChatFilter.unread,
                              ),
                            ),
                            _FilterChip(
                              label: t('Online'),
                              isSelected: _selectedFilter == _ChatFilter.online,
                              onTap: () => setState(
                                () => _selectedFilter = _ChatFilter.online,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (shellState.errorMessage != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: _RuntimeErrorNotice(
                      message: shellState.errorMessage!,
                    ),
                  ),
                if (socialDataUnreadable)
                  Padding(
                    key: const Key('social-data-unreadable-notice'),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                    child: _RuntimeErrorNotice(
                      message: t(
                        'Nie udało się odczytać zapisanej listy znajomych, '
                        'grup i rozmów. Dane na urządzeniu zostają nietknięte, '
                        'a do czasu ich odczytania Zen niczego nad nimi nie '
                        'zapisuje i nie odpowiada automatycznie znajomym. '
                        'Spróbuj uruchomić aplikację ponownie.',
                      ),
                    ),
                  ),
                // A sideloaded iPhone build: its signature runs out soon.
                const SigningExpiryBanner(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                ),
                // iPhone: receives only while Zen is open (one-time card).
                const IPhoneDeliveryNotice(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                ),
                // A mailbox stopped answering and needs replacing.
                const _RelayQuietCard(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                ),
                // Enough friends for the recovery circle and none yet.
                const CircleReminderCard(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                ),
                if (actionableInbox.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(
                            4,
                            8,
                            0,
                            6,
                          ),
                          child: Row(
                            children: <Widget>[
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  color: zen.accent,
                                  shape: BoxShape.circle,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  t('Nowe ({count})', {
                                    'count': actionableInbox.length,
                                  }),
                                  style: zen.label(color: zen.accent),
                                ),
                              ),
                              TextButton.icon(
                                key: const Key('inbox-clear-all-button'),
                                style: TextButton.styleFrom(
                                  minimumSize: const Size(0, 32),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                  ),
                                ),
                                onPressed: () {
                                  ref
                                      .read(
                                        socialHubControllerProvider.notifier,
                                      )
                                      .clearInbox();
                                },
                                icon: const Icon(
                                  Icons.clear_all_rounded,
                                  size: 16,
                                ),
                                label: Text(t('Wyczyść')),
                              ),
                            ],
                          ),
                        ),
                        for (final InboxEntry item
                            in actionableInbox) ...<Widget>[
                          _InboxCard(item: item),
                          const SizedBox(height: 10),
                        ],
                      ],
                    ),
                  ),
                // Introductions, letters and friend-list requests.
                const IntroInboxSection(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                ),
                // Conversations with people who are not friends.
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: StrangerChatsSection(),
                ),
                if (groups.isNotEmpty) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ZenSection(t('Grupy'), top: 12),
                  ),
                  for (final GroupProfile group in groups)
                    _GroupCard(group: group),
                ],
                if (pendingConversations.isNotEmpty) ...<Widget>[
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ZenSection(t('Oczekujące zaproszenia'), top: 12),
                  ),
                  for (final ConversationPreview conversation
                      in pendingConversations)
                    _ConversationCard(conversation: conversation),
                ],
                if (!searchingMessages || conversations.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: ZenSection(t('Rozmowy'), top: 12),
                  ),
                AnimatedSwitcher(
                  duration: ZenMotion.enabled && !ZenMotion.offIn(context)
                      ? const Duration(milliseconds: 240)
                      : Duration.zero,
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  child: conversations.isEmpty && searchingMessages
                      ? const SizedBox.shrink()
                      : conversations.isEmpty
                      ? _EmptyChats(
                          key: ValueKey<String>(
                            'empty-${_selectedFilter.name}-${_searchController.text.isEmpty}',
                          ),
                          filter: _selectedFilter,
                          message: _selectedFilter == _ChatFilter.unread
                              ? t('Wszystko przeczytane.')
                              : _selectedFilter == _ChatFilter.online
                              ? t('Nikt ze znajomych nie jest teraz online.')
                              : _searchController.text.isEmpty
                              ? null
                              : t('Brak wyników dla „{query}”.', {
                                  'query': _searchController.text,
                                }),
                          onShowCode: () => _openInviteTab(context, ref),
                        )
                      : Column(
                          key: ValueKey<_ChatFilter>(_selectedFilter),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            for (
                              int index = 0;
                              index < conversations.length;
                              index++
                            )
                              _conversationCardWithEntrance(
                                index,
                                conversations[index],
                              ),
                          ],
                        ),
                ),
                // Messages of every conversation with the words typed.
                MessageSearchResults(
                  key: const Key('chats-message-search'),
                  query: _searchController.text,
                ),
              ],
            ),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: zen.surface,
              border: Border(top: BorderSide(color: zen.outlineSoft)),
            ),
            child: const SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 10),
                child: _AddFriendCallout(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _conversationCardWithEntrance(
    int index,
    ConversationPreview conversation,
  ) {
    final Widget card = _ConversationCard(conversation: conversation);
    if (_listEntrancePlayed || index >= _staggeredEntranceItemLimit) {
      return card;
    }
    return ZenFadeSlide(
      duration: const Duration(milliseconds: 300),
      delay: Duration(milliseconds: 45 * index),
      child: card,
    );
  }
}

/// What the chat list shows when there is nothing to list: a short note for
/// an empty filter or search, and a proper welcome when there is nobody yet.
class _EmptyChats extends StatelessWidget {
  const _EmptyChats({
    super.key,
    required this.message,
    required this.onShowCode,
    this.filter = _ChatFilter.all,
  });

  /// Null means "no conversations at all".
  final String? message;
  final VoidCallback onShowCode;
  final _ChatFilter filter;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String? note = message;
    if (note != null) {
      return ZenEmpty(
        key: const Key('chats-empty-filtered'),
        icon: switch (filter) {
          _ChatFilter.unread => Icons.check_circle_outline_rounded,
          _ChatFilter.online => Icons.person_off_outlined,
          _ChatFilter.all || _ChatFilter.close => Icons.search_off_rounded,
        },
        tone: filter == _ChatFilter.unread ? zen.success : zen.textMuted,
        title: note,
      );
    }
    return ZenEmpty(
      key: const Key('chats-empty-welcome'),
      icon: Icons.forum_outlined,
      title: t('Nikogo tu jeszcze nie ma'),
      text: t(
        'Pokaż znajomemu swój kod albo dodaj kogoś po jego kodzie. '
        'Rozmowy pojawią się tutaj.',
      ),
      action: FilledButton.icon(
        key: const Key('chats-empty-show-code'),
        onPressed: onShowCode,
        icon: const Icon(Icons.qr_code_2_rounded, size: 18),
        label: Text(t('Zaproś znajomych')),
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    super.key,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.highlight = false,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final BorderRadius pill = ZenLook.of(context).chipRadius;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: pill,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? zen.accent : zen.surfaceRaised,
            borderRadius: pill,
            border: Border.all(
              color: isSelected
                  ? zen.accent
                  : (highlight
                        ? zen.accent.withValues(alpha: 0.6)
                        : zen.outlineSoft),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: isSelected
                  ? zen.onAccent
                  : (highlight ? zen.textPrimary : zen.textSecondary),
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsScreen extends ConsumerStatefulWidget {
  const _SettingsScreen();

  @override
  ConsumerState<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<_SettingsScreen> {
  /// Finds a setting by its name (or what is written under it).
  final TextEditingController _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  /// [sections] as they are, or, while something is typed in the search
  /// field, only the rows that match it (in their groups).
  List<Widget> _searched(List<Widget> sections) {
    final ZenColors zen = ZenColors.of(context);
    final SearchQuery query = SearchQuery.parse(_search.text);
    final Widget field = Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        key: const Key('settings-search-field'),
        controller: _search,
        onChanged: (_) => setState(() {}),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          hintText: t('Szukaj ustawienia'),
          hintMaxLines: 2,
          prefixIcon: const Icon(Icons.search_rounded, size: 20),
          suffixIcon: _search.text.isEmpty
              ? null
              : IconButton(
                  tooltip: t('Wyczyść'),
                  icon: const Icon(Icons.close_rounded, size: 18),
                  color: zen.textMuted,
                  onPressed: () {
                    _search.clear();
                    setState(() {});
                  },
                ),
        ),
      ),
    );
    if (query.isEmpty) {
      return <Widget>[field, ...sections];
    }
    final List<Widget> found = <Widget>[
      for (final _SettingsGroup group in sections.whereType<_SettingsGroup>())
        if (group.matching(query) case final _SettingsGroup shown) shown,
    ];
    return <Widget>[
      field,
      if (found.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Text(
            t('Nie ma ustawienia „{query}”.', {'query': _search.text.trim()}),
            key: const Key('settings-search-empty'),
            textAlign: TextAlign.center,
            style: TextStyle(color: zen.textSecondary),
          ),
        ),
      ...found,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final AppShellState state = ref.watch(appShellControllerProvider);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final int blockedCount = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState hub) => hub.blockedFriends.length,
      ),
    );
    return Scaffold(
      key: const Key('profile-page'),
      appBar: ZenSectionBar(title: t('Ustawienia')),
      body: SelectionArea(
        child: SafeArea(
          top: false,
          child: ListView(
            key: const Key('settings-tab-body'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: _searched(<Widget>[
              // The first-start setup again, every step, with what is set
              // now.
              FilledButton.tonalIcon(
                key: const Key('settings-rerun-setup'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () => unawaited(FirstRunSetupScreen.open(context)),
                icon: const Icon(Icons.checklist_rounded),
                label: Text(t('Ponownie przeprowadź konfigurację')),
              ),
              // Inviting someone and the app's own page come next.
              _SettingsGroup(
                title: '',
                tiles: <Widget>[
                  _SettingsNavTile(
                    key: const Key('settings-nav-invite'),
                    icon: Icons.qr_code_2_rounded,
                    tone: ZenTone.people,
                    title: t('Zaproś'),
                    subtitle: t('Twój kod QR i dodawanie znajomych'),
                    onTap: () => _openInviteTab(context, ref),
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-about'),
                    icon: Icons.info_outline_rounded,
                    tone: ZenTone.system,
                    title: t('O aplikacji'),
                    subtitle: t('Wersja, dokumenty, licencje, kontakt'),
                    onTap: () => unawaited(AboutScreen.open(context)),
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-github'),
                    icon: Icons.code_rounded,
                    tone: ZenTone.system,
                    title: t('Zen na GitHubie'),
                    subtitle: t('Kod, wydania, instrukcje i zgłaszanie błędów'),
                    onTap: () =>
                        unawaited(openOrCopyLink(context, kZenRepositoryUrl)),
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-discord'),
                    icon: Icons.forum_rounded,
                    tone: ZenTone.system,
                    title: t('Zen na Discordzie'),
                    subtitle: t('Pytania, nowości i rozmowy o Zen'),
                    onTap: () =>
                        unawaited(openOrCopyLink(context, kZenDiscordUrl)),
                  ),
                ],
              ),
              // Your profile is edited on the profile tab, not here.
              const _QuickLockPanel(),
              // Friends run a newer Zen: a quiet hint, gone otherwise.
              const FriendsNewerVersionBanner(),
              // One topic per row, each topic in one place: a setting is
              // never in two rows (docs/guide/settings-and-peers.md has the
              // map).
              _SettingsGroup(
                title: t('Konto i odzyskiwanie'),
                tiles: <Widget>[
                  if (ref.watch(ledgerNodeEnabledProvider))
                    _SettingsNavTile(
                      key: const Key('settings-nav-account'),
                      icon: Icons.key_outlined,
                      tone: ZenTone.privacy,
                      title: t('Konto i odzyskiwanie'),
                      subtitle: ref.watch(accountSecureReminderProvider)
                          ? t(
                              'Zabezpiecz konto na wypadek zgubionego telefonu: '
                              'kopia klucza albo krąg odzyskiwania',
                            )
                          : ref.watch(circleReminderProvider)
                          ? t(
                              'Masz już dość znajomych — ustaw krąg '
                              'odzyskiwania',
                            )
                          : t(
                              'Hasło konta, krąg odzyskiwania, nowe urządzenie',
                            ),
                      onTap: () =>
                          unawaited(AccountRecoveryScreen.open(context)),
                    ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-accounts'),
                    icon: Icons.manage_accounts_outlined,
                    tone: ZenTone.people,
                    title: t('Konta na tym urządzeniu'),
                    subtitle: t('ID konta, lista kont, usuwanie'),
                    onTap: () => unawaited(AccountsScreen.open(context)),
                  ),
                  if (ref.watch(ledgerNodeEnabledProvider))
                    _SettingsNavTile(
                      key: const Key('settings-nav-devices'),
                      icon: Icons.devices_rounded,
                      tone: ZenTone.network,
                      title: t('Urządzenia'),
                      subtitle: t(
                        'Konto na kilku urządzeniach, odłączanie '
                        'zgubionego',
                      ),
                      onTap: () =>
                          unawaited(AccountDevicesScreen.open(context)),
                    ),
                ],
              ),
              _SettingsGroup(
                title: t('Prywatność i bezpieczeństwo'),
                tiles: <Widget>[
                  // Passwords, the lock, the screen and the disguise.
                  _SettingsNavTile(
                    key: const Key('settings-nav-security'),
                    tone: ZenTone.privacy,
                    icon: Icons.shield_outlined,
                    title: t('Bezpieczeństwo'),
                    subtitle: t('Hasło, blokada aplikacji, szyfrowanie danych'),
                    pageTitle: t('Bezpieczeństwo'),
                    pageChildren: const <Widget>[_SettingsSecuritySection()],
                  ),
                  // Who sees what of you and who may reach you, on one page.
                  _SettingsNavTile(
                    key: const Key('settings-nav-contact'),
                    icon: Icons.visibility_outlined,
                    tone: ZenTone.privacy,
                    title: t('Kontakt i widoczność'),
                    subtitle: t(
                      'Status dla znajomych, wiadomości spoza znajomych, '
                      'zaproszenia do grup',
                    ),
                    pageTitle: t('Kontakt i widoczność'),
                    pageChildren: const <Widget>[_ContactSettingsSection()],
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-blocked-button'),
                    icon: Icons.block_outlined,
                    tone: ZenTone.safety,
                    title: t('Zablokowani'),
                    subtitle: blockedCount == 0
                        ? t('Nikogo nie blokujesz')
                        : t('Zablokowane osoby: {count}', {
                            'count': blockedCount,
                          }),
                    onTap: () => _openBlockedFriendsScreen(context),
                  ),
                ],
              ),
              _SettingsGroup(
                title: t('Wiadomości i połączenia'),
                tiles: <Widget>[
                  // Everything about notifications: what they say, the
                  // sounds, each kind, the muted people, the background.
                  _SettingsNavTile(
                    key: const Key('settings-nav-notifications'),
                    icon: Icons.notifications_outlined,
                    tone: ZenTone.communication,
                    title: t('Powiadomienia i dźwięki'),
                    subtitle: t(
                      '{privacy} · dźwięki, rodzaje powiadomień, praca w tle',
                      {'privacy': settings.notificationPrivacy.label},
                    ),
                    pageTitle: t('Powiadomienia i dźwięki'),
                    pageChildren: const <Widget>[
                      _NotificationSettingsSection(),
                    ],
                  ),
                  if (ref.watch(ledgerNodeEnabledProvider))
                    _SettingsNavTile(
                      key: const Key('settings-nav-recordings'),
                      icon: Icons.fiber_manual_record_outlined,
                      tone: ZenTone.media,
                      title: t('Nagrania rozmów'),
                      subtitle: t('Zaszyfrowane na tym urządzeniu'),
                      onTap: () =>
                          unawaited(CallRecordingsScreen.open(context)),
                    ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-gifs'),
                    icon: Icons.gif_box_outlined,
                    tone: ZenTone.media,
                    title: t('GIF-y'),
                    subtitle: !settings.gifSearch
                        ? t('Wyłączone')
                        : settings.usesOwnGifKey
                        ? t('Własny klucz API')
                        : t('Domyślny klucz aplikacji'),
                    pageTitle: t('GIF-y'),
                    pageChildren: const <Widget>[_GifSettingsSection()],
                  ),
                ],
              ),
              _SettingsGroup(
                title: t('Sieć'),
                tiles: <Widget>[
                  const _RelayNavTile(),
                  _SettingsNavTile(
                    key: const Key('settings-nav-network'),
                    icon: Icons.hub_outlined,
                    tone: ZenTone.network,
                    title: t('Sieć i usługa'),
                    subtitle: state.connectionLabel,
                    pageTitle: t('Sieć i usługa'),
                    pageChildren: const <Widget>[
                      _LiveTechInfoSection(),
                      _OfflineLinksPanel(),
                      _BridgeHostSection(),
                    ],
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-public-peers'),
                    icon: Icons.public_rounded,
                    tone: ZenTone.network,
                    title: t('Publiczne węzły'),
                    subtitle: t('Przez które węzły Zen łączy się z siecią'),
                    pageTitle: t('Publiczne węzły'),
                    pageChildren: const <Widget>[PublicPeersSection()],
                  ),
                  // How often Bluetooth looks around in the background.
                  if (Platform.isAndroid)
                    _SettingsNavTile(
                      key: const Key('settings-nav-nearby-look'),
                      icon: Icons.radar_rounded,
                      tone: ZenTone.places,
                      title: t('Rozglądanie w tle'),
                      subtitle: t('Bluetooth: jak często i jak długo'),
                      pageTitle: t('Rozglądanie w tle'),
                      pageChildren: const <Widget>[NearbyLookSettingsSection()],
                    ),
                ],
              ),
              _SettingsGroup(
                title: t('Aplikacja'),
                tiles: <Widget>[
                  _SettingsNavTile(
                    key: const Key('settings-nav-appearance'),
                    icon: Icons.palette_outlined,
                    tone: ZenTone.appearance,
                    title: t('Wygląd'),
                    subtitle: t('{palette} · {mode}', {
                      'palette': settings.palette.label,
                      'mode': settings.themeMode.label,
                    }),
                    pageTitle: t('Wygląd'),
                    pageChildren: const <Widget>[_AppearanceSection()],
                  ),
                  _SettingsNavTile(
                    key: const ValueKey<String>('settings-language-tile'),
                    icon: Icons.translate_rounded,
                    tone: ZenTone.communication,
                    title: t('Język'),
                    subtitle: ZenI18n.language.nativeName,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const LanguageScreen(),
                      ),
                    ),
                  ),
                  // Room, limits, cleaning and what downloads by itself.
                  _SettingsNavTile(
                    key: const Key('settings-nav-data'),
                    icon: Icons.storage_outlined,
                    tone: ZenTone.system,
                    title: t('Dane i pamięć'),
                    subtitle: settings.autoCleanupDays == 0
                        ? t('Zajęte miejsce, limity: {limit}', {
                            'limit': settings.inboxLimitLabel,
                          })
                        : t(
                            'Zajęte miejsce, limity: {limit} · czyszczenie po {days} dn.',
                            {
                              'limit': settings.inboxLimitLabel,
                              'days': settings.autoCleanupDays,
                            },
                          ),
                    pageTitle: t('Dane i pamięć'),
                    pageChildren: _storagePageChildren(),
                  ),
                  // The same steps as on the first start.
                  _SettingsNavTile(
                    key: const Key('settings-nav-permissions'),
                    icon: Icons.verified_user_outlined,
                    tone: ZenTone.privacy,
                    title: t('Uprawnienia i Bluetooth'),
                    subtitle: Platform.isAndroid
                        ? t('Powiadomienia, Bluetooth, praca w tle, mikrofon')
                        : t('Powiadomienia, mikrofon i kamera'),
                    onTap: () => unawaited(PermissionsScreen.open(context)),
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-updates'),
                    icon: Icons.system_update_alt_rounded,
                    tone: ZenTone.people,
                    title: t('Aktualizacje i Podaj dalej'),
                    subtitle: t('Wersja {version} · nowe wersje od znajomych', {
                      'version': kAppVersion,
                    }),
                    onTap: () => unawaited(UpdatesScreen.open(context)),
                  ),
                ],
              ),
              _SettingsGroup(
                title: t('Zaawansowane'),
                tiles: <Widget>[
                  _SettingsNavTile(
                    key: const Key('settings-nav-health'),
                    icon: Icons.health_and_safety_outlined,
                    tone: ZenTone.network,
                    title: t('Dlaczego nie działa?'),
                    subtitle: t(
                      'Sieć, praca w tle, powiadomienia, zegar, miejsce',
                    ),
                    onTap: () => unawaited(HealthScreen.open(context)),
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-diagnostics'),
                    icon: Icons.receipt_long_outlined,
                    tone: ZenTone.system,
                    title: t('Diagnostyka'),
                    subtitle: t('Dziennik zdarzeń do zgłaszania błędów'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext context) =>
                            const _DiagnosticsScreen(),
                      ),
                    ),
                  ),
                  _SettingsNavTile(
                    key: const Key('settings-nav-reset'),
                    tone: ZenTone.safety,
                    icon: Icons.delete_forever_outlined,
                    title: t('Usuń to konto z tego urządzenia'),
                    subtitle: t(
                      'Znajomi, rozmowy i klucze tego konta na tym urządzeniu',
                    ),
                    danger: true,
                    pageTitle: t('Usuń konto z urządzenia'),
                    pageChildren: const <Widget>[_ResetDataPanel()],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'Zen $kAppVersion',
                  style: TextStyle(
                    color: ZenColors.of(context).textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// A titled block of settings rows in one rounded card.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.title, required this.tiles});

  final String title;
  final List<Widget> tiles;

  /// The group with only the rows [query] matches (all of them when the
  /// group's own title does); `null` when none does.
  _SettingsGroup? matching(SearchQuery query) {
    if (title.isNotEmpty && query.matches(title)) {
      return this;
    }
    final List<Widget> shown = <Widget>[
      for (final Widget tile in tiles)
        if (query.matches(_settingsRowText(tile))) tile,
    ];
    return shown.isEmpty ? null : _SettingsGroup(title: title, tiles: shown);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenLook look = ZenLook.of(context);
    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < tiles.length; i++) {
      if (i > 0) {
        rows.add(const ZenDivider(indent: 68, endIndent: 16));
      }
      rows.add(tiles[i]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title.isEmpty)
          const SizedBox(height: 12)
        else
          ZenSection(title, top: 22),
        // The panel of the look (its fill, outline and corners).
        look.raise(
          zen,
          look.panelShape(zen),
          Material(
            color: look.panelColor(zen),
            shape: look.panelShape(zen),
            clipBehavior: Clip.antiAlias,
            child: Column(children: rows),
          ),
        ),
      ],
    );
  }
}

/// What the settings search looks at in a row: its title, what is written
/// under it and the title of the page it opens.
String _settingsRowText(Widget tile) => switch (tile) {
  _SettingsNavTile(:final String title, :final String subtitle) =>
    '$title $subtitle ${tile.pageTitle ?? ''}',
  _SettingsSwitchTile(:final String title, :final String subtitle) =>
    '$title $subtitle',
  _RelayNavTile() =>
    '${t('Skrzynki offline')} '
        '${t('Znajomi, którzy przechowają Twoje wiadomości')}',
  _ => '',
};

/// The shared layout of a settings row: badge, title, subtitle, and
/// whatever sits on the right (a chevron or a switch).
class _SettingsRowBody extends StatelessWidget {
  const _SettingsRowBody({
    required this.icon,
    required this.tone,
    required this.title,
    required this.subtitle,
    required this.trailing,
    this.danger = false,
  });

  final IconData icon;
  final Color tone;
  final String title;
  final String subtitle;
  final Widget trailing;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 68),
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 10, 12),
        child: Row(
          children: <Widget>[
            ZenIconBadge(icon: icon, tone: tone, size: 40),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  // Never cut: long titles and descriptions wrap (some
                  // languages are much longer than Polish).
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      height: 1.25,
                      color: danger ? zen.danger : zen.textPrimary,
                    ),
                  ),
                  if (subtitle.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: zen.textSecondary,
                        fontSize: 13,
                        height: 1.3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            trailing,
          ],
        ),
      ),
    );
  }
}

/// One row of the settings list: opens [onTap], or a page made of
/// [pageChildren].
class _SettingsNavTile extends StatelessWidget {
  const _SettingsNavTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.pageTitle,
    this.pageChildren,
    this.danger = false,
    this.tone = ZenTone.system,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final String? pageTitle;
  final List<Widget>? pageChildren;
  final bool danger;

  /// What the row is about: its colour in every theme.
  final ZenTone tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return InkWell(
      onTap:
          onTap ??
          () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) => _SettingsPage(
                title: pageTitle ?? title,
                children: pageChildren ?? const <Widget>[],
              ),
            ),
          ),
      child: _SettingsRowBody(
        icon: icon,
        tone: zen.tone(danger ? ZenTone.safety : tone),
        title: title,
        subtitle: subtitle,
        danger: danger,
        trailing: Padding(
          padding: const EdgeInsetsDirectional.only(end: 2),
          child: Icon(Icons.chevron_right_rounded, color: zen.textMuted),
        ),
      ),
    );
  }
}

/// A settings row with a switch, laid out exactly like [_SettingsNavTile].
class _SettingsSwitchTile extends StatelessWidget {
  const _SettingsSwitchTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
    this.tone = ZenTone.system,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// What the row is about: its colour in every theme.
  final ZenTone tone;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return MergeSemantics(
      child: InkWell(
        onTap: () => onChanged(!value),
        child: _SettingsRowBody(
          icon: icon,
          tone: zen.tone(tone),
          title: title,
          subtitle: subtitle,
          trailing: Switch.adaptive(value: value, onChanged: onChanged),
        ),
      ),
    );
  }
}

/// Ustawienia → Dane i pamięć: how much room Zen takes, the defaults for
/// the data, what downloads by itself and the limits.
List<Widget> _storagePageChildren() => <Widget>[
  const _Panel(child: StorageUsageSection()),
  const SizedBox(height: 12),
  const _DataSection(),
  const _MediaDownloadSettings(),
  const SizedBox(height: 12),
  _SectionIntro(
    title: t('Limity przechowywania'),
    caption: t('Największe dozwolone rozmiary w każdej kategorii'),
  ),
  const SizedBox(height: 8),
  const _Panel(child: StorageLimitsSection()),
];

/// Opens "Dane i pamięć" on its own (the notice that Zen took more than its
/// limit).
Future<void> openStorageSettingsPage(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => _SettingsPage(
          title: t('Dane i pamięć'),
          children: _storagePageChildren(),
        ),
      ),
    );

/// Ustawienia → Dane i pamięć: whether photos and videos of posts download
/// by themselves, and whether only over Wi-Fi.
class _MediaDownloadSettings extends ConsumerWidget {
  const _MediaDownloadSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    return _SettingsGroup(
      title: '',
      tiles: <Widget>[
        _SettingsSwitchTile(
          key: const Key('settings-auto-media'),
          icon: Icons.download_for_offline_outlined,
          tone: ZenTone.media,
          title: t('Pobieraj zdjęcia i filmy'),
          subtitle: t(
            'Media z postów pobierają się same. Wyłącz, żeby '
            'oszczędzać transfer.',
          ),
          value: settings.autoDownloadMedia,
          onChanged: (bool value) =>
              unawaited(controller.setAutoDownloadMedia(value)),
        ),
        _SettingsSwitchTile(
          key: const Key('settings-media-wifi-only'),
          icon: Icons.wifi_rounded,
          tone: ZenTone.network,
          title: t('Media tylko przez Wi-Fi'),
          subtitle: t(
            'Zdjęcia i filmy nie pobierają się same przez dane '
            'komórkowe. Można je pobrać dotknięciem.',
          ),
          value: settings.mediaOnlyOnWifi,
          onChanged: (bool value) =>
              unawaited(controller.setMediaOnlyOnWifi(value)),
        ),
      ],
    );
  }
}

/// Ustawienia → Kontakt i widoczność: what friends see of you, and who
/// may write to you or invite you without being a friend.
class _ContactSettingsSection extends ConsumerWidget {
  const _ContactSettingsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bool showLastOpened = ref.watch(
      appSettingsControllerProvider.select((AppSettings s) => s.showLastOpened),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SettingsGroup(
          title: '',
          tiles: <Widget>[
            _SettingsSwitchTile(
              key: const Key('settings-show-last-opened'),
              icon: Icons.history_toggle_off_rounded,
              tone: ZenTone.privacy,
              title: t('Pokazuj, kiedy ostatnio otwierałem aplikację'),
              subtitle: t(
                'Znajomi widzą, czy masz Zen otwarty, w tle czy '
                'offline, a przy tym, kiedy ostatnio go otwierałeś. '
                'Słabi znajomi nie widzą żadnego z tych statusów.',
              ),
              value: showLastOpened,
              onChanged: (bool value) => unawaited(
                ref
                    .read(appSettingsControllerProvider.notifier)
                    .setShowLastOpened(value),
              ),
            ),
          ],
        ),
        const _SettingsGroup(
          title: '',
          tiles: <Widget>[StrangerMessagesFromTile(), GroupInviteFromTile()],
        ),
      ],
    );
  }
}

/// A settings sub-page: the panels of one topic, nothing else.
class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: PageTitle(title)),
      body: SelectionArea(
        child: SafeArea(
          top: false,
          child: ListView(
            key: const Key('settings-page-body'),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: children,
          ),
        ),
      ),
    );
  }
}

/// The mailboxes row, with the live relay summary.
class _RelayNavTile extends ConsumerWidget {
  const _RelayNavTile();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RelayEngine? engine = ref.watch(relayEngineProvider);
    if (engine == null) {
      return _SettingsNavTile(
        key: const Key('settings-relay-button'),
        icon: Icons.markunread_mailbox_outlined,
        tone: ZenTone.network,
        title: t('Skrzynki offline'),
        subtitle: t('Znajomi, którzy przechowają Twoje wiadomości'),
        pageTitle: t('Skrzynki offline'),
        pageChildren: const <Widget>[_RelayMailboxPanel()],
      );
    }
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
        return _SettingsNavTile(
          key: const Key('settings-relay-button'),
          icon: Icons.markunread_mailbox_outlined,
          tone: ZenTone.network,
          title: t('Skrzynki offline'),
          subtitle: overview.relays.isEmpty
              ? t('Dodaj znajomych, żeby wiadomości mogły na Ciebie czekać')
              : '$mailboxes · $mode',
          onTap: () => unawaited(openRelayMailboxScreen(context)),
        );
      },
    );
  }
}

/// [_TechInfoSection] kept live on its own page.
class _LiveTechInfoSection extends ConsumerWidget {
  const _LiveTechInfoSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _TechInfoSection(state: ref.watch(appShellControllerProvider));
  }
}

/// "Łączność bez internetu": friends and own devices nearby
/// link directly (offline_links_section.dart).
class _OfflineLinksPanel extends StatelessWidget {
  const _OfflineLinksPanel();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 12),
      child: _Panel(child: OfflineLinksSection()),
    );
  }
}

/// Which Yggdrasil and Go the bridge was built with.
class _BridgeBuildInfoLine extends ConsumerWidget {
  const _BridgeBuildInfoLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final RuntimeBridgeBuildInfo? info = ref.watch(
      runtimeBridgeBuildInfoProvider,
    );
    if (info == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        t('Yggdrasil {yggdrasil} · {go}', <String, Object?>{
          'yggdrasil': info.yggdrasil,
          'go': info.go,
        }),
        key: const Key('settings-bridge-build-info'),
        style: TextStyle(
          color: ZenColors.of(context).textSecondary,
          fontSize: 12.5,
        ),
      ),
    );
  }
}

/// Whether this computer is a bridge of the mesh. Nothing on phones.
class _BridgeHostSection extends ConsumerWidget {
  const _BridgeHostSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only on a computer, where the app is a bridge by default.
    if (!isDesktopPlatform || !ref.watch(bridgeHostEnabledProvider)) {
      return const SizedBox.shrink();
    }
    final bool enabled = ref.watch(
      appSettingsControllerProvider.select((AppSettings s) => s.bridgeEnabled),
    );
    final BridgeHost? host = ref.watch(bridgeHostProvider);
    final ZenColors zen = ZenColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _Panel(
            child: SwitchListTile.adaptive(
              key: const Key('settings-bridge-switch'),
              contentPadding: EdgeInsets.zero,
              value: enabled,
              onChanged: (bool value) => unawaited(
                ref
                    .read(appSettingsControllerProvider.notifier)
                    .setBridgeEnabled(value),
              ),
              title: Text(
                t('Pomagaj innym się łączyć'),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontSize: 15.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                t(
                  'Ten komputer przekazuje zaszyfrowany ruch sieci Zen, gdy '
                  'jest włączony — dzięki temu telefony znajomych łatwiej się '
                  'łączą. Nie widzi treści.',
                ),
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
        if (host != null) _BridgeHostStatusCard(host: host),
      ],
    );
  }
}

class _BridgeHostStatusCard extends StatelessWidget {
  const _BridgeHostStatusCard({required this.host});

  final BridgeHost host;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: ValueListenableBuilder<BridgeHostStatus>(
        valueListenable: host.status,
        builder: (BuildContext context, BridgeHostStatus status, _) {
          final Color tone = switch (status.state) {
            BridgeHostState.active => zen.success,
            BridgeHostState.waiting ||
            BridgeHostState.checking ||
            BridgeHostState.noFriendsOnline => zen.accent,
            _ => zen.warning,
          };
          return _Panel(
            key: const Key('settings-bridge-card'),
            accentTone: tone,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                ZenIconBadge(
                  icon: Icons.cell_tower_rounded,
                  tone: tone,
                  size: 42,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          status.title,
                          key: const Key('settings-bridge-title'),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            height: 1.25,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        status.detail,
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 13.5,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  key: const Key('settings-bridge-retry'),
                  tooltip: t('Sprawdź teraz'),
                  visualDensity: VisualDensity.compact,
                  onPressed: status.state == BridgeHostState.checking
                      ? null
                      : () => unawaitedLogged(
                          host.runOnce(),
                          context: 'Checking the bridge failed',
                        ),
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// At the very top of the settings while there is no app password: offers
/// to set one. Once there is one, "Zablokuj teraz" is in the top bar.
class _QuickLockPanel extends ConsumerWidget {
  const _QuickLockPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    return AnimatedBuilder(
      animation: security,
      builder: (BuildContext context, Widget? child) {
        if (security.canQuickLock) {
          return const SizedBox.shrink();
        }
        final Color tone = zen.warning;
        return Container(
          decoration: BoxDecoration(
            borderRadius: context.zenRadius(26),
            gradient: LinearGradient(
              colors: <Color>[
                Color.alphaBlend(tone.withValues(alpha: 0.24), zen.surface),
                Color.alphaBlend(
                  zen.tone(ZenTone.privacy).withValues(alpha: 0.08),
                  zen.surface,
                ),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            border: Border.all(color: tone.withValues(alpha: 0.32)),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Row(
                children: <Widget>[
                  ZenIconBadge(
                    icon: Icons.lock_open_rounded,
                    tone: tone,
                    size: 46,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('Blokada aplikacji'),
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 19,
                            weight: FontWeight.w600,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t('Ustaw hasło, aby włączyć szybką blokadę.'),
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('settings-lock-now-button'),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: () async {
                  final String? password = await _showPasswordDialog(
                    context,
                    title: t('Ustaw hasło aplikacji'),
                    actionLabel: t('Ustaw hasło'),
                  );
                  if (password == null) {
                    return;
                  }
                  try {
                    await security.setPassword(password);
                  } on AppPasswordConflictException catch (error) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(
                        context,
                      ).showSnackBar(SnackBar(content: Text(error.message)));
                    }
                  }
                },
                icon: const Icon(Icons.password_rounded, size: 18),
                label: Text(t('Ustaw hasło')),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// "GIF-y": GIF search on or off (it is the one outside service,
/// klipy.com), and the own key while it is on.
class _GifSettingsSection extends ConsumerWidget {
  const _GifSettingsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final bool on = ref.watch(
      appSettingsControllerProvider.select((AppSettings s) => s.gifSearch),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SettingsGroup(
          title: '',
          tiles: <Widget>[
            _SettingsSwitchTile(
              key: const Key('settings-gif-search'),
              icon: Icons.gif_box_outlined,
              tone: ZenTone.media,
              title: t('Wyszukiwarka GIF-ów'),
              subtitle: t(
                'Przycisk GIF w czatach szuka w serwisie klipy.com — to '
                'jedyna funkcja Zen, która łączy się z zewnętrzną usługą.',
              ),
              value: on,
              onChanged: (bool value) => unawaited(
                ref
                    .read(appSettingsControllerProvider.notifier)
                    .setGifSearch(value),
              ),
            ),
          ],
        ),
        ZenInfo(
          key: const Key('settings-gif-keyboard-note'),
          icon: Icons.keyboard_outlined,
          tone: zen.tone(ZenTone.media),
          text: t(
            'GIF-y z klawiatury telefonu działają zawsze — większość klawiatur '
            'wstawia je jako zwykłe obrazki. Gdy wyszukiwarka jest wyłączona, '
            'Zen nie wysyła nic do klipy.com, a przycisku GIF nie ma.',
          ),
        ),
        if (on) ...<Widget>[const SizedBox(height: 12), const _GifKeySection()],
      ],
    );
  }
}

/// Lets the user plug in their own Klipy key; the shared key stays the
/// default and comes back when the field is cleared.
class _GifKeySection extends ConsumerStatefulWidget {
  const _GifKeySection();

  @override
  ConsumerState<_GifKeySection> createState() => _GifKeySectionState();
}

class _GifKeySectionState extends ConsumerState<_GifKeySection> {
  late final TextEditingController _field = TextEditingController(
    text: ref.read(appSettingsControllerProvider).gifApiKey,
  );
  bool _checking = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String raw = _field.text.trim();
    if (raw.isEmpty) {
      await _useDefault();
      return;
    }
    final String key = AppSettings.normalizeGifApiKey(raw);
    if (key.isEmpty) {
      setState(() {
        _error = t('To nie wygląda na klucz API (litery, cyfry, - _ .).');
        _info = null;
      });
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
      _info = null;
    });
    // Tried before it is saved, so a typo never leaves GIFs broken.
    String? error;
    try {
      await ref
          .read(gifCatalogFactoryProvider)(key)
          .loadFeatured()
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      error = t(
        'Klipy nie przyjął tego klucza albo brak internetu. '
        'Nic nie zmieniono.',
      );
    }
    if (!mounted) {
      return;
    }
    if (error == null) {
      await ref.read(appSettingsControllerProvider.notifier).setGifApiKey(key);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _checking = false;
      _error = error;
      _info = error == null
          ? t('Zapisano. GIF-y idą teraz z Twojego klucza.')
          : null;
    });
  }

  Future<void> _useDefault() async {
    await ref.read(appSettingsControllerProvider.notifier).setGifApiKey('');
    if (!mounted) {
      return;
    }
    _field.clear();
    setState(() {
      _error = null;
      _info = t('Przywrócono domyślny klucz aplikacji.');
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool ownKey = ref.watch(
      appSettingsControllerProvider.select((AppSettings s) => s.usesOwnGifKey),
    );
    final Color tone = zen.tone(ZenTone.media);
    return _Panel(
      accentTone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            icon: Icons.gif_box_outlined,
            tone: tone,
            title: t('Klucz API do GIF-ów'),
            pill: ZenPill(
              text: ownKey ? t('Własny klucz') : t('Klucz domyślny'),
              tone: ownKey ? zen.success : tone,
              icon: ownKey ? Icons.check_rounded : Icons.auto_awesome_rounded,
            ),
            caption: ownKey
                ? t('Używasz własnego klucza Klipy.')
                : t(
                    'Działa domyślny klucz aplikacji. Możesz podpiąć własny '
                    'klucz Klipy (klipy.com), jeśli domyślny się wyczerpie.',
                  ),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('settings-gif-key-field'),
            controller: _field,
            enabled: !_checking,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: AppSettings.maximumGifApiKeyLength,
            decoration: InputDecoration(
              labelText: t('Własny klucz Klipy'),
              hintText: t('Wklej klucz z klipy.com'),
              helperText: t('Zostaw puste, żeby używać klucza domyślnego.'),
              prefixIcon: const Icon(Icons.vpn_key_outlined),
              counterText: '',
            ),
            onSubmitted: (_) => _save(),
          ),
          if (_error != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.error_outline_rounded, size: 18, color: zen.danger),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _error!,
                    key: const Key('settings-gif-key-error'),
                    style: TextStyle(
                      color: zen.danger,
                      fontSize: 13.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (_info != null) ...<Widget>[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  Icons.check_circle_outline_rounded,
                  size: 18,
                  color: zen.success,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _info!,
                    key: const Key('settings-gif-key-info'),
                    style: TextStyle(
                      color: zen.success,
                      fontSize: 13.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                key: const Key('settings-gif-key-save'),
                onPressed: _checking ? null : _save,
                icon: _checking
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.check_rounded),
                label: Text(_checking ? t('Sprawdzam…') : t('Zapisz')),
              ),
              if (ownKey)
                OutlinedButton.icon(
                  key: const Key('settings-gif-key-default'),
                  onPressed: _checking ? null : _useDefault,
                  icon: const Icon(Icons.restart_alt_rounded, size: 18),
                  label: Text(t('Wróć do domyślnego')),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AppearanceSection extends ConsumerWidget {
  const _AppearanceSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    // The previews follow the chosen mode.
    final Brightness brightness = switch (settings.themeMode) {
      AppThemeMode.light => Brightness.light,
      AppThemeMode.dark => Brightness.dark,
      AppThemeMode.system => MediaQuery.platformBrightnessOf(context),
    };
    return _Panel(
      accentTone: zen.tone(ZenTone.appearance),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _SectionIntro(
            title: t('Motyw'),
            caption: t('Kolory, kształty i ruch całej aplikacji.'),
          ),
          const SizedBox(height: 12),
          // The palettes in their groups, each a live miniature.
          ZenThemePicker(
            selected: settings.palette,
            accent: settings.accentTheme,
            brightness: brightness,
            onSelect: controller.setPalette,
          ),
          const SizedBox(height: 20),
          _SectionIntro(title: t('Tryb')),
          const SizedBox(height: 10),
          Wrap(
            key: const Key('settings-theme-mode-segmented'),
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final AppThemeMode mode in const <AppThemeMode>[
                AppThemeMode.light,
                AppThemeMode.dark,
                AppThemeMode.system,
              ])
                ChoiceChip(
                  key: Key('settings-theme-${mode.name}'),
                  avatar: Icon(switch (mode) {
                    AppThemeMode.system => Icons.brightness_auto_rounded,
                    AppThemeMode.light => Icons.light_mode_rounded,
                    AppThemeMode.dark => Icons.dark_mode_rounded,
                  }, size: 18),
                  showCheckmark: false,
                  label: Text(mode.label),
                  selected: settings.themeMode == mode,
                  onSelected: (_) => controller.setThemeMode(mode),
                ),
            ],
          ),
          const SizedBox(height: 20),
          _SectionIntro(
            title: t('Animacje'),
            caption: t('Ruch teł motywów i drobnych efektów.'),
          ),
          const SizedBox(height: 10),
          const AnimationsSettingChoice(),
          // The accent is the colour of Klasyczny; the other palettes have
          // their own.
          if (settings.palette == AppPalette.classic) ...<Widget>[
            const SizedBox(height: 20),
            _SectionIntro(
              title: t('Kolor'),
              caption: t('Akcent całej aplikacji: {accent}.', {
                'accent': settings.accentTheme.label,
              }),
            ),
            const SizedBox(height: 12),
            Wrap(
              key: const Key('settings-accent-picker'),
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                for (final AppAccentTheme t in AppAccentTheme.values)
                  _AccentSwatch(
                    theme: t,
                    selected: settings.accentTheme == t,
                    onTap: () => controller.setAccentTheme(t),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.theme,
    required this.selected,
    required this.onTap,
  });

  final AppAccentTheme theme;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ZenColors c = ZenColors.resolve(theme, Theme.of(context).brightness);
    return Tooltip(
      message: theme.label,
      child: InkWell(
        key: Key('settings-accent-${theme.name}'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? zen.textPrimary : Colors.transparent,
              width: 2,
            ),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: <Color>[c.accent, c.accentSecondary],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: selected
                ? Icon(Icons.check_rounded, size: 18, color: c.onAccent)
                : null,
          ),
        ),
      ),
    );
  }
}

class _DataSection extends ConsumerStatefulWidget {
  const _DataSection();

  @override
  ConsumerState<_DataSection> createState() => _DataSectionState();
}

class _DataSectionState extends ConsumerState<_DataSection> {
  late final TextEditingController _cleanupController;
  late final FocusNode _cleanupFocusNode;

  @override
  void initState() {
    super.initState();
    _cleanupController = TextEditingController(text: '0');
    _cleanupFocusNode = FocusNode();
  }

  @override
  void dispose() {
    _cleanupController.dispose();
    _cleanupFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final AppSettings settings = ref.watch(appSettingsControllerProvider);
    final AppSettingsController controller = ref.read(
      appSettingsControllerProvider.notifier,
    );
    final String cleanupText = settings.autoCleanupDays.toString();
    if (!_cleanupFocusNode.hasFocus && _cleanupController.text != cleanupText) {
      _cleanupController.value = TextEditingValue(
        text: cleanupText,
        selection: TextSelection.collapsed(offset: cleanupText.length),
      );
    }
    final Color tone = zen.tone(ZenTone.system);
    return _Panel(
      key: const Key('settings-preferences-panel'),
      accentTone: tone,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            icon: Icons.storage_outlined,
            tone: tone,
            title: t('Dane i pamięć'),
            caption: t(
              'Domyślne wartości dla nowych rozmów. Każda rozmowa może je '
              'nadpisać lokalnie.',
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile.adaptive(
            key: const Key('settings-inbox-unlimited-switch'),
            value: settings.inboxUnlimited,
            contentPadding: EdgeInsets.zero,
            title: Text(t('Bez limitu miejsca')),
            subtitle: Text(
              t(
                'Zen nie usuwa wtedy niczego z powodu zajętego miejsca, '
                'poza osobnym limitem postów znajomych.',
              ),
              style: TextStyle(color: zen.textSecondary, height: 1.35),
            ),
            onChanged: (bool value) {
              controller.setInboxUnlimited(value);
            },
          ),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: settings.inboxUnlimited
                ? const SizedBox.shrink()
                : Container(
                    key: const Key('settings-inbox-limit-editor'),
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                    decoration: BoxDecoration(
                      color: zen.surfaceSunk,
                      borderRadius: context.zenRadius(16),
                      border: Border.all(color: zen.outlineSoft),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          t('Limit miejsca: {limit}', {
                            'limit': settings.inboxLimitLabel,
                          }),
                          key: const Key('settings-inbox-limit-label'),
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontSize: 14.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        StorageLimitSlider(
                          key: const Key('settings-inbox-limit-slider'),
                          valueMb: settings.inboxLimitMb,
                          onChanged: controller.setInboxLimitMb,
                        ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 16),
          TextFormField(
            key: const Key('settings-auto-cleanup-field'),
            controller: _cleanupController,
            focusNode: _cleanupFocusNode,
            keyboardType: TextInputType.number,
            inputFormatters: <TextInputFormatter>[
              FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              labelText: t('Auto-czyszczenie po ilu dniach'),
              hintText: t('np. 30'),
              helperText: t('0 = nigdy'),
              prefixIcon: const Icon(Icons.auto_delete_outlined),
              suffixText: t('dni'),
            ),
            onChanged: (String value) {
              controller.setAutoCleanupDays(int.tryParse(value) ?? 0);
            },
          ),
        ],
      ),
    );
  }
}

class _TechInfoSection extends StatelessWidget {
  const _TechInfoSection({required this.state});

  final AppShellState state;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color accent = _shellStatusAccent(zen, state);
    final List<Widget> metricTiles = <Widget>[
      _MetricTile(label: t('Połączeni'), value: '${state.peers}', toneIndex: 0),
      _MetricTile(
        label: t('W zasięgu'),
        value: '${state.peerPoolCount}',
        toneIndex: 2,
      ),
      _MetricTile(
        label: t('Trasy'),
        value: '${state.routingEntries}',
        toneIndex: 4,
      ),
      _MetricTile(
        label: t('Ping'),
        value: state.latencyMs > 0
            ? t('{ms} ms', {'ms': state.latencyMs})
            : '—',
        toneIndex: 6,
      ),
    ];
    return _Panel(
      key: const Key('settings-network-card'),
      accentTone: accent,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          key: const Key('settings-tech-info-tile'),
          tilePadding: EdgeInsets.zero,
          childrenPadding: const EdgeInsets.only(top: 8),
          shape: const Border(),
          collapsedShape: const Border(),
          leading: ZenIconBadge(
            icon: Icons.hub_outlined,
            tone: accent,
            size: 42,
          ),
          title: Text(
            t('Info techniczne'),
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _StatusPill(label: state.connectionLabel, tone: accent),
                const SizedBox(height: 6),
                Text(
                  state.healthSummary,
                  style: TextStyle(
                    color: zen.textSecondary,
                    fontSize: 13.5,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          children: <Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                const double spacing = 8;
                final int columns = constraints.maxWidth >= 440 ? 4 : 2;
                final double width = constraints.maxWidth.isFinite
                    ? (constraints.maxWidth - (spacing * (columns - 1))) /
                          columns
                    : 88;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: metricTiles
                      .map((Widget tile) => SizedBox(width: width, child: tile))
                      .toList(growable: false),
                );
              },
            ),
            const _BridgeBuildInfoLine(),
            if (state.errorMessage != null) ...<Widget>[
              const SizedBox(height: 12),
              _RuntimeErrorNotice(message: state.errorMessage!),
            ],
            const SizedBox(height: 14),
            _ServiceActions(state: state),
          ],
        ),
      ),
    );
  }
}

class _AddFriendCallout extends StatelessWidget {
  const _AddFriendCallout();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: FilledButton.icon(
            key: const Key('open-add-friend-sheet-button'),
            onPressed: () => showAddFriendSheet(context),
            icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
            label: Text(t('Znajomy'), textAlign: TextAlign.center),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.tonalIcon(
            key: const Key('open-create-group-sheet-button'),
            onPressed: () => CreateGroupSheet.show(context),
            icon: const Icon(Icons.group_add_rounded, size: 18),
            label: Text(t('Grupa'), textAlign: TextAlign.center),
          ),
        ),
      ],
    );
  }
}

class _GroupCard extends ConsumerStatefulWidget {
  const _GroupCard({required this.group});

  final GroupProfile group;

  @override
  ConsumerState<_GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends ConsumerState<_GroupCard> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final GroupProfile group = widget.group;
    final bool hasUnread = group.unreadCount > 0;
    final bool callRunning = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState state) =>
            state.groupCalls[group.id]?.isEmpty == false ||
            (state.activeCall?.isGroup == true &&
                state.activeCall?.groupId == group.id &&
                state.activeCall?.status != CallSessionStatus.ringing),
      ),
    );
    final BorderRadius radius = context.zenRadius(20);
    final Color tone = _groupTone(zen, group);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (BuildContext context) => GroupConversationScreen(
                  groupId: group.id,
                  groupName: group.name,
                ),
              ),
            );
          },
          onHover: (bool hovering) => setState(() => _isHovered = hovering),
          onLongPress: () {
            _showGroupActionSheet(context, group);
          },
          onSecondaryTap: () {
            _showGroupActionSheet(context, group);
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              borderRadius: radius,
              color: _isHovered
                  ? zen.surface
                  : (hasUnread
                        ? zen.accent.withValues(alpha: 0.06)
                        : Colors.transparent),
              border: Border.all(
                color: _isHovered ? zen.outlineSoft : Colors.transparent,
              ),
            ),
            child: _ChatRow(
              highlight: hasUnread,
              avatar: SizedBox.square(
                dimension: 50,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: <Widget>[
                    ZenIconBadge(
                      icon: Icons.groups_rounded,
                      tone: tone,
                      size: 50,
                    ),
                    if (callRunning)
                      PositionedDirectional(
                        end: -3,
                        bottom: -3,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            color: zen.success,
                            shape: BoxShape.circle,
                            border: Border.all(color: zen.background, width: 2),
                          ),
                          child: Icon(
                            Icons.call_rounded,
                            size: 11,
                            color: ZenColors.foregroundFor(zen.success),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              name: group.name,
              nameBadge: callRunning
                  ? _StatusPill(label: t('Trwa rozmowa'), tone: zen.success)
                  : null,
              meta: callRunning
                  ? null
                  : t('{count} os.', {'count': group.memberCount}),
              preview: Text(
                group.lastMessagePreview?.trim().isNotEmpty == true
                    ? group.lastMessagePreview!
                    : tn(
                        group.memberCount,
                        one: 'Grupa ({n} osoba)',
                        few: 'Grupa ({n} osoby)',
                        many: 'Grupa ({n} osób)',
                      ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: hasUnread ? zen.textPrimary : zen.textSecondary,
                  fontSize: 13.5,
                  fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              unreadBadge: hasUnread ? _UnreadBadge(group.unreadCount) : null,
            ),
          ),
        ),
      ),
    );
  }
}

/// A steady colour per group, so groups are told apart at a glance.
Color _groupTone(ZenColors zen, GroupProfile group) {
  int hash = 0;
  for (final int unit in group.id.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return zenTone(zen, hash % 8);
}

void _showGroupActionSheet(BuildContext context, GroupProfile group) {
  final ZenColors zen = ZenColors.of(context);
  // What follows the sheet runs from the navigator and the provider scope:
  // the card that opened it may be gone by then (see
  // _showConversationActionSheet).
  final NavigatorState navigator = Navigator.of(context);
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );

  showModalBottomSheet<void>(
    context: context,
    backgroundColor: zen.surfaceRaised,
    shape: context.zenSheetShape(),
    isScrollControlled: true,
    builder: (BuildContext sheetContext) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const _SheetHandle(),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  ZenIconBadge(
                    icon: Icons.groups_rounded,
                    tone: _groupTone(zen, group),
                    size: 52,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          group.name,
                          style: zen.display(
                            color: zen.textPrimary,
                            size: 20,
                            weight: FontWeight.w600,
                            height: 1.15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        ZenPill(
                          text: tn(
                            group.memberCount,
                            one: '{n} uczestnik',
                            few: '{n} uczestników',
                            many: '{n} uczestników',
                          ),
                          tone: _groupTone(zen, group),
                          icon: Icons.people_alt_outlined,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: zen.outlineSoft),
              const SizedBox(height: 8),
              _SheetAction(
                icon: Icons.chat_bubble_outline_rounded,
                label: t('Otwórz grupę'),
                tone: zen.accent,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  navigator.push(
                    MaterialPageRoute<void>(
                      builder: (BuildContext context) =>
                          GroupConversationScreen(
                            groupId: group.id,
                            groupName: group.name,
                          ),
                    ),
                  );
                },
              ),
              _SheetAction(
                icon: Icons.group_remove_outlined,
                label: t('Opuść i usuń grupę'),
                tone: zen.danger,
                danger: true,
                onTap: () async {
                  Navigator.of(sheetContext).pop();
                  final bool? confirmed = await showDialog<bool>(
                    context: navigator.context,
                    builder: (BuildContext dialogContext) {
                      return AlertDialog(
                        scrollable: true,
                        icon: Icon(
                          Icons.group_remove_outlined,
                          color: zen.danger,
                          size: 30,
                        ),
                        title: Text(t('Opuścić grupę?')),
                        content: Text(
                          t(
                            'Czy na pewno chcesz opuścić i usunąć grupę '
                            '{group}?',
                            {'group': group.name},
                          ),
                        ),
                        actions: <Widget>[
                          TextButton(
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(false),
                            child: Text(t('Anuluj')),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: zen.danger,
                              foregroundColor: ZenColors.foregroundFor(
                                zen.danger,
                              ),
                            ),
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: Text(t('Usuń grupę')),
                          ),
                        ],
                      );
                    },
                  );
                  if (confirmed == true) {
                    await container
                        .read(socialHubControllerProvider.notifier)
                        .leaveGroup(groupId: group.id);
                  }
                },
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _LocalCodePanel extends StatelessWidget {
  const _LocalCodePanel({required this.profile});

  final PeerShareProfile profile;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    // The QR code is always dark on white: cameras read it best that way,
    // whatever the app's theme.
    const Color qrInk = ZenFixed.qrInk;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        borderRadius: context.zenRadius(28),
        gradient: LinearGradient(
          colors: <Color>[zen.accent, zen.accentSecondary, zen.accentTertiary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: ZenLook.of(context).tinted(
          zen,
          zen.accent,
          radius: 28,
          alpha: 0.22,
          offset: const Offset(0, 10),
        ),
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 18),
        decoration: BoxDecoration(
          color: zen.surface,
          borderRadius: context.zenRadius(26),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              t('Twój kod'),
              textAlign: TextAlign.center,
              style: zen.display(
                color: zen.textPrimary,
                size: 22,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              t('Niech znajomy zeskanuje go aparatem'),
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textSecondary, fontSize: 13.5),
            ),
            const SizedBox(height: 16),
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: ZenFixed.qrPaper,
                  borderRadius: context.zenRadius(22),
                  boxShadow: ZenLook.of(
                    context,
                  ).tinted(zen, zen.accent, radius: 18, alpha: 0.18),
                ),
                child: QrImageView(
                  data: profile.qrData,
                  size: 184,
                  padding: EdgeInsets.zero,
                  backgroundColor: ZenFixed.qrPaper,
                  eyeStyle: QrEyeStyle(
                    color: qrInk,
                    eyeShape: QrEyeShape.square,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    color: qrInk,
                    dataModuleShape: QrDataModuleShape.square,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              t('Kod zaproszenia'),
              textAlign: TextAlign.center,
              style: zen.label(color: zen.textMuted),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: zen.surfaceSunk,
                borderRadius: context.zenRadius(16),
                border: Border.all(color: zen.outlineSoft),
              ),
              child: SelectionArea(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    profile.shareText,
                    key: const Key('my-invite-code'),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    style: zen.mono(
                      color: zen.textPrimary,
                      size: 17,
                      weight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            // The invitation is the person's public address (the QR shows
            // it to anyone), so it stays on the clipboard: it is pasted in
            // another messenger, often a while later.
            FilledButton.icon(
              key: const Key('my-invite-copy'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
              onPressed: () async {
                await copyPublicText(profile.inviteMessage);
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      t(
                        'Zaproszenie z linkiem skopiowane — wklej je '
                        'znajomemu w dowolnym komunikatorze.',
                      ),
                    ),
                  ),
                );
              },
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(t('Kopiuj zaproszenie')),
            ),
            TextButton(
              key: const Key('my-invite-copy-code'),
              onPressed: () async {
                await copyPublicText(profile.shareText);
                if (!context.mounted) {
                  return;
                }
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t('Kod został skopiowany.'))),
                );
              },
              child: Text(t('Kopiuj sam kod')),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Zaproś" (at the top of the settings): your QR code and invite code,
/// requests from people who just scanned it, and adding someone by their
/// code.
class _MyCodeScreen extends ConsumerWidget {
  const _MyCodeScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final PeerShareProfile? profile = PeerShareCodec.buildLocalProfile(
      address: ref.watch(
        appShellControllerProvider.select((AppShellState s) => s.localAddress),
      ),
      displayName: ref.watch(
        userProfileControllerProvider.select((UserProfile p) => p.displayName),
      ),
    );
    final SocialHubState hubState = watchSocialPeople(ref);
    // The friend list is the source of truth: an inbox entry can already be
    // gone (read, trimmed, dismissed with its notification) while the request
    // is still waiting for an answer.
    final List<FriendProfile> pendingRequests = hubState.friends.values
        .where(
          (FriendProfile friend) =>
              friend.status == FriendRelationshipStatus.pendingIncoming,
        )
        .toList(growable: false);

    return Scaffold(
      appBar: ZenSectionBar(title: t('Mój kod')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            // Someone who just scanned the code sends a request right away:
            // it shows up here, above the code, to be answered on the spot.
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              alignment: Alignment.topCenter,
              child: Column(
                key: const Key('qr-friend-requests'),
                children: <Widget>[
                  for (final FriendProfile request in pendingRequests)
                    ZenFadeSlide(
                      key: Key('qr-request-${request.address}'),
                      duration: const Duration(milliseconds: 260),
                      offset: const Offset(0, -8),
                      child: _QrScreenFriendRequestCard(
                        request: request,
                        friends: hubState.friends,
                      ),
                    ),
                ],
              ),
            ),
            if (profile != null) _LocalCodePanel(profile: profile),
            const SizedBox(height: 12),
            _WrapTile(
              key: const Key('invite-add-friend'),
              icon: Icons.person_add_alt_1_rounded,
              tone: zen.tone(ZenTone.people),
              title: t('Mam czyjś kod'),
              subtitle: t('Dodaj znajomego — wklej jego kod albo zeskanuj QR'),
              onTap: () => showAddFriendSheet(context),
            ),
            _WrapTile(
              key: const Key('invite-share-app'),
              icon: Icons.install_mobile_rounded,
              tone: zen.tone(ZenTone.people),
              title: t('Znajomy nie ma Zen?'),
              subtitle: t('Podaj dalej: aplikacja z ręki do ręki, bez sklepu'),
              onTap: () => unawaited(ShareAppScreen.open(context)),
            ),
            if (!kIsWeb && Platform.isAndroid)
              _WrapTile(
                key: const Key('invite-open-links'),
                icon: Icons.qr_code_scanner_rounded,
                tone: zen.tone(ZenTone.network),
                title: t('Kody Zen prosto do aplikacji'),
                subtitle: t(
                  'Włącz „Otwieraj obsługiwane linki”: kod zeskanowany '
                  'aparatem otworzy się od razu w Zen',
                ),
                onTap: () => unawaited(openLinkHandlingSettings()),
              ),
            const SizedBox(height: 4),
            ZenInfo(
              title: t('Jak to działa'),
              icon: Icons.help_outline_rounded,
              text: t(
                'Nie ma rejestracji ani serwera. Ten kod to Twój adres w '
                'sieci — pokaż go albo skopiuj. Kto go wklei, może wysłać '
                'Ci zaproszenie. Kod jest tylko na tym urządzeniu.',
              ),
            ),
            ZenInfo(
              key: const Key('invite-mailbox-hint'),
              title: t('Wiadomości, gdy telefony śpią'),
              icon: Icons.markunread_mailbox_outlined,
              text: t(
                'Jeden komputer z Zen w zasobniku (albo Android) = skrzynka '
                'dla całej paczki znajomych: przechowa wiadomości, gdy '
                'telefony są wyłączone. Szczególnie ważne, gdy macie '
                'iPhone’y — odbierają tylko przy otwartym Zen.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _QrScreenFriendRequestCard extends ConsumerWidget {
  const _QrScreenFriendRequestCard({
    required this.request,
    required this.friends,
  });

  final FriendProfile request;
  final Map<String, FriendProfile> friends;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final String peerAddress = request.address;
    final String title = request.displayLabel;
    final String note = request.requestMessage?.trim() ?? '';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color.alphaBlend(zen.accent.withValues(alpha: 0.18), zen.surface),
            zen.surface,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: context.zenRadius(22),
        border: Border.all(color: zen.accent.withValues(alpha: 0.5)),
        boxShadow: ZenLook.of(
          context,
        ).tinted(zen, zen.accent, radius: 20, alpha: 0.16),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ZenBlobAvatar(name: title, size: 46, showStatus: false),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      t('OTRZYMANO ZAPROSZENIE'),
                      style: zen.label(color: zen.accent),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: zen.display(
                        color: zen.textPrimary,
                        size: 18,
                        weight: FontWeight.w600,
                        height: 1.15,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (note.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              decoration: BoxDecoration(
                color: zen.surfaceSunk,
                borderRadius: context.zenRadius(14),
              ),
              child: Text(
                '„$note”',
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: <Widget>[
              Expanded(
                child: OutlinedButton(
                  key: Key('qr-reject-$peerAddress'),
                  onPressed: () async {
                    try {
                      await ref
                          .read(socialHubControllerProvider.notifier)
                          .rejectFriendRequest(peerAddress: peerAddress);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(t('Odrzucono zaproszenie.'))),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(t('Błąd: {error}', {'error': e})),
                          ),
                        );
                      }
                    }
                  },
                  child: Text(t('Odrzuć'), textAlign: TextAlign.center),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  key: Key('qr-accept-$peerAddress'),
                  onPressed: () async {
                    // The card goes once answered; the question after it
                    // needs a context that stays.
                    final NavigatorState navigator = Navigator.of(context);
                    try {
                      // They keep the name from their profile.
                      await ref
                          .read(socialHubControllerProvider.notifier)
                          .acceptFriendRequest(
                            peerAddress: peerAddress,
                            senderDisplayName: _localSenderDisplayName(ref),
                          );
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              t('Zaakceptowano znajomego: {name}', {
                                'name': title,
                              }),
                            ),
                          ),
                        );
                      }
                      if (navigator.mounted) {
                        // They just scanned this code: this side confirms
                        // the meeting too.
                        await showMetLevelPrompt(
                          navigator.context,
                          address: peerAddress,
                          name: title,
                        );
                      }
                    } catch (error) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              t('Błąd akceptacji: {error}', {'error': error}),
                            ),
                          ),
                        );
                      }
                    }
                  },
                  child: Text(t('Akceptuj'), textAlign: TextAlign.center),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Battery-optimization exemption for the background runtime.
///
/// The mesh node lives in a foreground service; without the exemption OEM
/// battery managers kill that service after the app is swiped away, and
/// Android 12+ refuses to let it restart itself from the background. The
/// result the user sees is a missed call and no notification.
/// Entry point to the shared on-device log (with the technical log's
/// lines: wakes, modes, the node's numbers, how Android ended the app).
///
/// The foreground service isolate runs with no UI and no debugger attached, so
/// when background delivery breaks this is the only way to see where. The
/// screen shows the latest [_shownEntries] entries; the saved file holds
/// them all.
class _DiagnosticsScreen extends StatefulWidget {
  const _DiagnosticsScreen();

  @override
  State<_DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

/// How many of the latest entries the screen shows.
const int _shownEntries = 500;

class _DiagnosticsScreenState extends State<_DiagnosticsScreen> {
  String? _contents;
  int _total = 0;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    final List<String> entries = await ZenDiagnosticsLog.entries();
    if (!mounted) {
      return;
    }
    final List<String> shown = entries.length > _shownEntries
        ? entries.sublist(entries.length - _shownEntries)
        : entries;
    setState(() {
      _total = entries.length;
      _contents = shown.join('\n');
    });
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final AccountBackupPlaces places = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(accountBackupPlacesProvider);
    setState(() => _saving = true);
    try {
      final AccountBackupSaved? saved = await saveDiagnosticsLog(
        places: places,
      );
      if (saved != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            key: const Key('diagnostics-saved'),
            duration: const Duration(seconds: 8),
            // With an action a snack bar stays until dismissed by default.
            persist: false,
            content: Text(
              t('Zapisano bez szyfrowania: {path}', {
                'path': saved.shown.join(', '),
              }),
            ),
            action: saved.canOpen
                ? SnackBarAction(
                    key: const Key('diagnostics-saved-open'),
                    label: t('Otwórz folder'),
                    onPressed: () => unawaited(places.open(saved)),
                  )
                : null,
          ),
        );
      }
    } on Object catch (error, stackTrace) {
      logZenError('Saving the diagnostics log failed', error, stackTrace);
      // What went wrong is in the log above, not in the snackbar.
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text(t('Nie udało się zapisać pliku.'))),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _copy() async {
    await copyWithExpiry(_contents ?? '');
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(t('Skopiowano dziennik do schowka.'))),
    );
  }

  Future<void> _clear() async {
    final bool sure =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext dialog) => AlertDialog(
            key: const Key('diagnostics-clear-dialog'),
            scrollable: true,
            title: Text(t('Wyczyścić dziennik?')),
            content: Text(
              t(
                'Wpisy znikną bezpowrotnie. Wcześniej zapisany plik '
                'zostanie.',
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(dialog).pop(false),
                child: Text(t('Anuluj')),
              ),
              FilledButton(
                key: const Key('diagnostics-clear-confirm'),
                onPressed: () => Navigator.of(dialog).pop(true),
                child: Text(t('Wyczyść')),
              ),
            ],
          ),
        ) ??
        false;
    if (!sure) {
      return;
    }
    await ZenDiagnosticsLog.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String? contents = _contents;
    return Scaffold(
      appBar: ZenSectionBar(
        title: t('Diagnostyka'),
        actions: <Widget>[
          IconButton(
            key: const Key('diagnostics-reload'),
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
            tooltip: t('Odśwież'),
          ),
          IconButton(
            key: const Key('diagnostics-clear'),
            onPressed: contents == null ? null : _clear,
            icon: const Icon(Icons.delete_outline_rounded),
            tooltip: t('Wyczyść'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: contents == null
            ? const Center(
                child: SizedBox.square(
                  dimension: 26,
                  child: CircularProgressIndicator(strokeWidth: 2.4),
                ),
              )
            : contents.isEmpty
            ? Center(
                child: SingleChildScrollView(
                  child: ZenEmpty(
                    icon: Icons.receipt_long_outlined,
                    title: t('Dziennik jest pusty.'),
                    text: t(
                      'Gdy coś się wydarzy w tle, wpisy pojawią się tutaj.',
                    ),
                    tone: zen.tone(ZenTone.system),
                  ),
                ),
              )
            : Scrollbar(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      // Said before the button, not after the snackbar.
                      ZenInfo(
                        icon: Icons.warning_amber_rounded,
                        tone: zen.warning,
                        text: t(
                          'Plik z dziennikiem zapisuje się bez szyfrowania. '
                          'Przed wysłaniem go komuś sprawdź, co zawiera.',
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: <Widget>[
                          FilledButton.icon(
                            key: const Key('diagnostics-copy'),
                            onPressed: _copy,
                            icon: const Icon(Icons.copy_all_rounded, size: 18),
                            label: Text(t('Kopiuj')),
                          ),
                          OutlinedButton.icon(
                            key: const Key('diagnostics-save'),
                            onPressed: _saving ? null : _save,
                            icon: const Icon(Icons.save_alt_rounded, size: 18),
                            label: Text(t('Zapisz plik')),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_total > _shownEntries)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            t(
                              'Ostatnie {shown} z {total} wpisów. Cały dziennik jest w zapisanym pliku.',
                              {'shown': _shownEntries, 'total': _total},
                            ),
                            style: TextStyle(color: zen.textSecondary),
                          ),
                        ),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: zen.surfaceSunk,
                          borderRadius: context.zenRadius(18),
                          border: Border.all(color: zen.outlineSoft),
                        ),
                        child: SelectableText(
                          contents,
                          style: zen.mono(
                            color: zen.textSecondary,
                            size: 11.5,
                            height: 1.45,
                            letterSpacing: 0,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

class _BackgroundDeliverySection extends StatefulWidget {
  const _BackgroundDeliverySection();

  @override
  State<_BackgroundDeliverySection> createState() =>
      _BackgroundDeliverySectionState();
}

class _BackgroundDeliverySectionState
    extends State<_BackgroundDeliverySection> {
  bool? _unrestricted;
  bool _allPermissionsGranted = false;
  bool _requestInFlight = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final bool unrestricted = await isAndroidBackgroundDeliveryUnrestricted();
    final Map<String, bool> perms = await checkAllPermissions();
    final bool fullScreen = await canUseCallFullScreenIntent();
    final bool overlays = await canDrawOverlays();
    if (!mounted) {
      return;
    }
    final bool allPerms =
        perms.isNotEmpty &&
        perms['audio'] == true &&
        perms['camera'] == true &&
        perms['notifications'] == true &&
        unrestricted &&
        fullScreen &&
        overlays;
    setState(() {
      _unrestricted = unrestricted;
      _allPermissionsGranted = allPerms;
    });
  }

  Future<void> _request() async {
    setState(() => _requestInFlight = true);
    // 1. Audio, Camera, Notifications
    await requestAllAppPermissions();
    // 2. Battery optimization exemption
    await requestAndroidBackgroundDeliveryExemption();
    // 3. Full-screen intent
    await requestCallFullScreenIntentPermission();
    // 4. Floating overlay
    final bool canOverlay = await canDrawOverlays();
    if (!canOverlay) {
      await openOverlaySettings();
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _refresh();
    if (mounted) {
      setState(() => _requestInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final bool granted = _unrestricted == true && _allPermissionsGranted;
    return SizedBox(
      width: double.infinity,
      child: _Panel(
        key: const Key('settings-background-delivery-card'),
        accentTone: granted ? zen.success : zen.warning,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _PanelHeader(
              icon: granted
                  ? Icons.verified_user_outlined
                  : Icons.notifications_paused_outlined,
              tone: granted ? zen.success : zen.warning,
              title: t('Uprawnienia i praca w tle'),
              pill: _StatusPill(
                label: granted ? t('Wszystkie aktywne') : t('Wymaga uprawnień'),
                tone: granted ? zen.success : zen.warning,
              ),
              caption: granted
                  ? t(
                      'Aplikacja ma komplet uprawnień (praca w tle, '
                      'powiadomienia, mikrofon, kamera, okno rozmowy).',
                    )
                  : t(
                      'Aby nie przegapić połączeń i wiadomości oraz móc '
                      'korzystać z rozmów i pływającego okna połączeń, '
                      'zezwól na wszystkie uprawnienia.',
                    ),
            ),
            if (!granted) ...<Widget>[
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('settings-background-delivery-request'),
                onPressed: _requestInFlight ? null : _request,
                icon: const Icon(Icons.verified_user_outlined, size: 18),
                label: Text(t('Zezwól na wszystko')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Battery optimisation on its own (the panel above folds it into "all
/// permissions"): whether Android may put Zen to sleep, the system dialog
/// that exempts it, and where phone makers hide their own battery limits.
class _BatteryOptimizationSection extends StatefulWidget {
  const _BatteryOptimizationSection();

  @override
  State<_BatteryOptimizationSection> createState() =>
      _BatteryOptimizationSectionState();
}

class _BatteryOptimizationSectionState
    extends State<_BatteryOptimizationSection>
    with WidgetsBindingObserver {
  bool? _exempt;
  bool _requestInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the system dialog or the phone maker's settings.
    if (state == AppLifecycleState.resumed) {
      unawaited(_refresh());
    }
  }

  Future<void> _refresh() async {
    final bool exempt = await isAndroidBackgroundDeliveryUnrestricted();
    if (!mounted) {
      return;
    }
    setState(() => _exempt = exempt);
  }

  Future<void> _request() async {
    setState(() => _requestInFlight = true);
    // ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS for this package: the
    // system asks the person, nothing changes without their yes.
    final bool exempt = await requestAndroidBackgroundDeliveryExemption();
    if (!mounted) {
      return;
    }
    setState(() {
      _exempt = exempt;
      _requestInFlight = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final bool? exempt = _exempt;
    final Color tone = exempt == false ? zen.warning : zen.success;
    return SizedBox(
      width: double.infinity,
      child: _Panel(
        key: const Key('settings-battery-card'),
        accentTone: exempt == null ? null : tone,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _PanelHeader(
              icon: exempt == false
                  ? Icons.battery_alert_rounded
                  : Icons.battery_charging_full_rounded,
              tone: exempt == null ? null : tone,
              title: t('Oszczędzanie baterii'),
              pill: exempt == null
                  ? null
                  : _StatusPill(
                      label: exempt
                          ? t('Zen bez ograniczeń')
                          : t('Zen jest usypiany'),
                      tone: tone,
                    ),
              caption: switch (exempt) {
                null => t('Sprawdzam, czy Android może usypiać Zen…'),
                false => t(
                  'Android może usypiać Zen przy zgaszonym ekranie. '
                  'Wiadomości, połączenia i alarmy dotrą wtedy dopiero po '
                  'otwarciu aplikacji.',
                ),
                true => t(
                  'Android nie usypia Zen, więc wiadomości, połączenia i '
                  'alarmy docierają także przy zgaszonym ekranie.',
                ),
              },
            ),
            if (exempt == false) ...<Widget>[
              const SizedBox(height: 14),
              FilledButton.icon(
                key: const Key('settings-battery-request'),
                onPressed: _requestInFlight
                    ? null
                    : () => unawaited(_request()),
                icon: const Icon(Icons.battery_saver_outlined, size: 18),
                label: Text(t('Wyłącz optymalizację baterii')),
              ),
            ],
            const SizedBox(height: 12),
            ZenInfo(
              icon: Icons.phone_android_rounded,
              tone: zen.warning,
              title: t('Telefony mają też własne „zabójce baterii”'),
              text: t(
                'Xiaomi, Samsung, Huawei czy OnePlus potrafią zamknąć Zen '
                'mimo tego ustawienia. Samsung: Ustawienia → Bateria → '
                'Limity użycia w tle — Zen nie może być na liście „Uśpione '
                'aplikacje” ani „Głęboko uśpione aplikacje”. Xiaomi: w '
                'ustawieniach aplikacji włącz „Autostart” i ustaw '
                'oszczędzanie baterii na „Bez ograniczeń”.',
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('settings-battery-app-settings'),
                onPressed: () => unawaited(openAndroidAppSettings()),
                icon: const Icon(Icons.settings_outlined, size: 18),
                label: Text(t('Otwórz ustawienia aplikacji')),
              ),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                key: const Key('settings-battery-vendor-help'),
                onPressed: () => unawaited(PermissionsScreen.open(context)),
                icon: const Icon(Icons.menu_book_outlined, size: 18),
                label: Text(t('Instrukcja dla Twojego telefonu')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Android 14 hands USE_FULL_SCREEN_INTENT only to apps the Play Store knows
/// as calling apps. Without it a ringing call never takes over a locked
/// screen, which is exactly when a missed call hurts most — so the state is
/// worth showing instead of leaving the user wondering why calls are silent.
class _FullScreenCallSection extends StatefulWidget {
  const _FullScreenCallSection();

  @override
  State<_FullScreenCallSection> createState() => _FullScreenCallSectionState();
}

class _FullScreenCallSectionState extends State<_FullScreenCallSection> {
  bool? _granted;
  bool _requestInFlight = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final bool granted = await canUseCallFullScreenIntent();
    if (!mounted) {
      return;
    }
    setState(() => _granted = granted);
  }

  Future<void> _request() async {
    setState(() => _requestInFlight = true);
    final bool granted = await requestCallFullScreenIntentPermission();
    if (!mounted) {
      return;
    }
    setState(() {
      _granted = granted;
      _requestInFlight = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isAndroid) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final bool granted = _granted == true;
    if (_granted == null || granted) {
      // Nothing to act on: either still unknown, or the system already allows
      // the ringing screen. Do not spend a settings card on a healthy state.
      return const SizedBox.shrink();
    }
    return SizedBox(
      width: double.infinity,
      child: _Panel(
        key: const Key('settings-full-screen-call-card'),
        accentTone: zen.warning,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _PanelHeader(
              icon: Icons.phone_locked_outlined,
              tone: zen.warning,
              title: t('Połączenia na ekranie blokady'),
              pill: _StatusPill(label: t('Ograniczone'), tone: zen.warning),
              caption: t(
                'System nie pozwala Zen otwierać pełnoekranowego powiadomienia o '
                'rozmowie. Połączenie przychodzące pojawi się tylko jako zwykłe '
                'powiadomienie i łatwo je przegapić przy zablokowanym ekranie.',
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              key: const Key('settings-full-screen-call-request'),
              onPressed: _requestInFlight ? null : _request,
              icon: const Icon(Icons.ring_volume_outlined, size: 18),
              label: Text(t('Zezwól na pełny ekran')),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _openBlockedFriendsScreen(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const _BlockedFriendsScreen(),
    ),
  );
}

/// The people whose new posts are not announced ("Wycisz posty tej
/// osoby"), each with a way back.
class _MutedPostAuthorsSection extends ConsumerWidget {
  const _MutedPostAuthorsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> muted = ref
        .watch(
          appSettingsControllerProvider.select(
            (AppSettings s) => s.mutedPostAuthors,
          ),
        )
        .toList(growable: false);
    final SocialHubState social = ref.watch(socialHubControllerProvider);
    if (muted.isEmpty) {
      return ZenEmpty(
        key: const Key('muted-post-authors-empty'),
        icon: Icons.notifications_none_rounded,
        title: t('Nikogo nie wyciszono'),
        text: t(
          'Osobę, której posty mają nie powiadamiać, wyciszysz w menu jej '
          'posta albo rozmowy.',
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ZenInfo(
          icon: Icons.notifications_off_outlined,
          tone: zen.textSecondary,
          text: t('Ich posty nadal są na Tablicy, tylko bez powiadomień.'),
        ),
        const SizedBox(height: 6),
        for (final String address in muted)
          ZenCard(
            key: Key('muted-post-author-$address'),
            padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    switch (social.friendByAddress(address)) {
                      final FriendProfile friend => social.nameFor(friend),
                      _ => address,
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton(
                  key: Key('muted-post-author-unmute-$address'),
                  onPressed: () => unawaited(
                    ref
                        .read(appSettingsControllerProvider.notifier)
                        .setPostAuthorMuted(address, muted: false),
                  ),
                  child: Text(t('Włącz')),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _BlockedFriendsScreen extends ConsumerWidget {
  const _BlockedFriendsScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final List<FriendProfile> blockedFriends = watchSocialPeople(
      ref,
    ).blockedFriends;
    return Scaffold(
      key: const Key('blocked-friends-screen'),
      appBar: AppBar(title: Text(t('Zablokowani użytkownicy'))),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: <Widget>[
            if (blockedFriends.isEmpty)
              ZenEmpty(
                icon: Icons.verified_user_outlined,
                tone: zen.success,
                title: t('Brak zablokowanych użytkowników.'),
                text: t(
                  'Osoby, które zablokujesz, trafią tutaj. Możesz je w każdej '
                  'chwili odblokować.',
                ),
              )
            else ...<Widget>[
              ZenInfo(
                icon: Icons.block_rounded,
                tone: zen.danger,
                text: t(
                  'Zablokowane osoby nie mogą do Ciebie pisać ani dzwonić.',
                ),
              ),
              const SizedBox(height: 6),
              for (final FriendProfile friend in blockedFriends)
                _BlockedFriendRow(friend: friend),
            ],
          ],
        ),
      ),
    );
  }
}

class _BlockedFriendRow extends ConsumerWidget {
  const _BlockedFriendRow({required this.friend});

  final FriendProfile friend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final String note = friend.blockNote?.trim() ?? '';
    return ZenCard(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 12, 12, 12),
      child: Row(
        children: <Widget>[
          ZenBlobAvatar(name: friend.displayLabel, size: 42, showStatus: false),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  friend.displayLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    note,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 13,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: Key('settings-unblock-${friend.address}'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 38),
              padding: const EdgeInsets.symmetric(horizontal: 14),
            ),
            onPressed: () {
              ref
                  .read(socialHubControllerProvider.notifier)
                  .unblockFriend(peerAddress: friend.address);
            },
            child: Text(t('Odblokuj')),
          ),
        ],
      ),
    );
  }
}

class _ResetDataPanel extends ConsumerStatefulWidget {
  const _ResetDataPanel();

  @override
  ConsumerState<_ResetDataPanel> createState() => _ResetDataPanelState();
}

class _ResetDataPanelState extends ConsumerState<_ResetDataPanel>
    with SingleTickerProviderStateMixin {
  static const Duration _holdDuration = Duration(seconds: 10);

  late final AnimationController _holdController;
  bool _confirming = false;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _holdController =
        AnimationController(
            vsync: this,
            duration: _holdDuration,
            // A safety delay, not an animation: with "remove animations" turned on
            // Android asks Flutter to shorten normal animations 20x, which made the
            // 10-second hold finish in half a second.
            animationBehavior: AnimationBehavior.preserve,
          )
          ..addListener(() {
            if (mounted) {
              setState(() {});
            }
          })
          ..addStatusListener(_handleHoldStatus);
  }

  @override
  void dispose() {
    _holdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final double progress = _running ? 1 : _holdController.value;
    final String actionLabel;
    final String helperLabel;
    if (_running) {
      actionLabel = t('Resetowanie...');
      helperLabel = t('Czyszczenie lokalnych danych jest w toku.');
    } else if (_holdController.isAnimating || _holdController.value > 0) {
      final int elapsedSeconds = (_holdController.value * 10).floor();
      final int remainingSeconds = (10 - elapsedSeconds).clamp(1, 10);
      actionLabel = t('Trzymaj jeszcze {seconds} s', {
        'seconds': remainingSeconds,
      });
      helperLabel = t(
        'Trzymaj bez przerwy przez pełne 10 sekund, zanim pojawi się '
        'potwierdzenie.',
      );
    } else {
      actionLabel = t('Przytrzymaj 10 s, aby zresetować dane');
      helperLabel = t(
        'Dopiero po pełnym 10-sekundowym przytrzymaniu pojawi się dodatkowe '
        'potwierdzenie.',
      );
    }
    return _Panel(
      accentTone: zen.danger,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _PanelHeader(
            icon: Icons.delete_forever_outlined,
            tone: zen.danger,
            title: t('Usuń to konto z tego urządzenia'),
            caption: t(
              'Usuwa z tego urządzenia rozmowy, zaproszenia, ustawienia i '
              'klucze otwartego konta, a potem uruchamia aplikację od '
              'czystego stanu. Inne konta na tym urządzeniu zostają, a to '
              'konto na innych urządzeniach działa dalej.',
            ),
          ),
          const SizedBox(height: 16),
          ClipRRect(
            borderRadius: context.zenRadius(18),
            // Raw pointer events, not a tap: a ten-second press is a long
            // press, which the page's text selection wins (the tap is then
            // cancelled and the hold stops). Holding never selects text.
            child: SelectionContainer.disabled(
              child: Listener(
                onPointerDown: (_) {
                  if (!_running && !_confirming) {
                    _startHold();
                  }
                },
                onPointerUp: (_) => _cancelHold(),
                onPointerCancel: (_) => _cancelHold(),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    key: const Key('desktop-reset-data-button'),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: zen.danger.withValues(alpha: 0.08),
                        borderRadius: context.zenRadius(18),
                        border: Border.all(
                          color: zen.danger.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(
                                  _running
                                      ? Icons.hourglass_top_rounded
                                      : Icons.delete_forever_outlined,
                                  color: zen.danger,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    actionLabel,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          color: zen.danger,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                                if (_running)
                                  const SizedBox.square(
                                    dimension: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            ClipRRect(
                              borderRadius: context.zenRadius(999),
                              child: LinearProgressIndicator(
                                key: const Key('desktop-reset-data-progress'),
                                minHeight: 8,
                                value: _running ? null : progress,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  zen.danger,
                                ),
                                backgroundColor: zen.danger.withValues(
                                  alpha: 0.12,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              helperLabel,
                              style: TextStyle(
                                color: zen.textSecondary,
                                height: 1.35,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _startHold() {
    _holdController.reset();
    _holdController.forward();
  }

  void _cancelHold() {
    if (_running || _confirming || _holdController.value == 0) {
      return;
    }
    _holdController.stop();
    _holdController.animateBack(
      0,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
    );
  }

  void _handleHoldStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _holdController.value >= 0.999) {
      _handleReset();
    }
  }

  Future<void> _handleReset() async {
    if (_confirming || _running || !mounted) {
      return;
    }
    setState(() {
      _confirming = true;
    });
    final bool confirmed = await _confirmReset();
    if (!mounted) {
      return;
    }
    setState(() {
      _confirming = false;
      _holdController.value = 0;
    });
    if (!confirmed) {
      return;
    }
    setState(() {
      _running = true;
    });
    try {
      await performZenLocalDataReset(ref);
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Dane zostały zresetowane.'))));
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t('Reset danych nie udał się: {error}', {'error': error}),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
        });
      }
    }
  }

  Future<bool> _confirmReset() async {
    // Nothing proves a way back (no key copy, no circle): say what is lost.
    final bool secured = accountIsSecured(ref.read);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        final ZenColors zen = ZenColors.of(context);
        return AlertDialog(
          scrollable: true,
          key: const Key('desktop-reset-confirm-dialog'),
          icon: Icon(Icons.warning_amber_rounded, color: zen.danger, size: 32),
          title: Text(t('Usunąć to konto z tego urządzenia?')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                t(
                  'Rozmowy, znajomi, ustawienia i klucze tego konta znikną '
                  'z tego urządzenia. Tego nie da się cofnąć.',
                ),
              ),
              if (!secured) ...<Widget>[
                const SizedBox(height: 12),
                ZenInfo(
                  key: const Key('reset-no-backup-warning'),
                  icon: Icons.report_gmailerrorred_rounded,
                  tone: zen.danger,
                  title: t('To konto nie ma kopii'),
                  text: t(
                    'Nie ma kopii klucza ani kręgu odzyskiwania. Jeśli nie '
                    'masz tego konta na innym urządzeniu ani w pliku kopii, '
                    'po usunięciu nie da się go odzyskać: znajomi zobaczą '
                    'Cię jako nową osobę, a miejsce w piramidzie przepadnie.',
                  ),
                ),
                TextButton.icon(
                  key: const Key('reset-backup-first'),
                  onPressed: () {
                    Navigator.of(context).pop(false);
                    unawaited(AccountRecoveryScreen.open(this.context));
                  },
                  icon: const Icon(Icons.shield_outlined),
                  label: Text(t('Najpierw zrób kopię')),
                ),
              ],
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(t('Anuluj')),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: ZenColors.of(context).danger,
                foregroundColor: ZenColors.foregroundFor(
                  ZenColors.of(context).danger,
                ),
              ),
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(t('Usuń')),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }
}

final class _AddFriendResult {
  const _AddFriendResult({
    required this.target,
    required this.nickname,
    this.metInPerson = false,
  });

  final PeerDialTarget target;

  /// The code came from a scanned QR: the two met in person.
  final bool metInPerson;

  /// What the user wants to call them ('' for nothing); their own name
  /// comes with their answer.
  final String nickname;
}

Future<void> showAddFriendSheet(
  BuildContext context, {
  String? initialTargetInput,
}) async {
  final _AddFriendResult? result = await showModalBottomSheet<_AddFriendResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext context) =>
        _AddFriendSheet(initialTargetInput: initialTargetInput),
  );
  if (result == null || !context.mounted) {
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        result.nickname.isEmpty
            ? t('Zaproszenie wysłane.')
            : t('Zaproszenie do {name} wysłane.', {'name': result.nickname}),
      ),
    ),
  );
  if (result.metInPerson) {
    // Met in person: how close are you? "Znajomy" when skipped.
    await showMetLevelPrompt(
      context,
      address: result.target.address,
      name: result.nickname,
    );
    if (!context.mounted) {
      return;
    }
  }
  _openConversationScreen(
    context,
    peerAddress: result.target.address,
    title: t('Kontakt Zen'),
  );
}

Future<void> _openConversationScreen(
  BuildContext context, {
  required String peerAddress,
  required String title,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) =>
          ConversationScreen(peerAddress: peerAddress, title: title),
    ),
  );
}

class _AddFriendSheet extends ConsumerStatefulWidget {
  const _AddFriendSheet({this.initialTargetInput});

  final String? initialTargetInput;

  @override
  ConsumerState<_AddFriendSheet> createState() => _AddFriendSheetState();
}

class _AddFriendSheetState extends ConsumerState<_AddFriendSheet> {
  final TextEditingController _targetController = TextEditingController();
  final TextEditingController _nicknameController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  String? _errorText;
  bool _submitting = false;

  /// The code in the field came from the camera (a QR shown in person).
  String? _scannedCode;

  @override
  void initState() {
    super.initState();
    final String? initialTargetInput = widget.initialTargetInput?.trim();
    if (initialTargetInput == null || initialTargetInput.isEmpty) {
      return;
    }
    _applyTargetInput(initialTargetInput);
  }

  @override
  void dispose() {
    _targetController.dispose();
    _nicknameController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pasteTarget() async {
    final ClipboardData? data = await Clipboard.getData('text/plain');
    final String? text = data?.text?.trim();
    if (text == null || text.isEmpty || !mounted) {
      return;
    }
    _applyTargetInput(text);
  }

  /// Shows what was pasted or scanned as the invitation code: a code says
  /// everything a link or a QR code says (no name ever comes with it).
  void _applyTargetInput(String value) {
    final String normalized = PeerShareCodec.normalizeManualInput(value);
    String nextValue = normalized;
    try {
      final PeerDialTarget target = PeerShareCodec.parseTarget(normalized);
      nextValue =
          PeerShareCodec.inviteCodeForAddress(target.address) ?? target.address;
    } on FormatException {
      // Shown as typed; submitting explains what is wrong.
    }
    setState(() {
      _targetController.text = nextValue;
      _targetController.selection = TextSelection.collapsed(
        offset: nextValue.length,
      );
      _errorText = null;
    });
  }

  Future<void> _scanTarget() async {
    final String? text = await ref.read(peerQrScannerProvider).scan(context);
    final String? normalized = text?.trim();
    if (normalized == null || normalized.isEmpty || !mounted) {
      return;
    }
    _applyTargetInput(normalized);
    _scannedCode = _targetController.text;
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _errorText = null;
    });
    try {
      final PeerDialTarget target = PeerShareCodec.parseTarget(
        _targetController.text,
      );
      final String localAddress = ref
          .read(appShellControllerProvider)
          .localAddress;
      if (localAddress.isNotEmpty &&
          PeerShareCodec.addressesEqual(target.address, localAddress)) {
        throw FormatException(t('Nie możesz dodać samego siebie.'));
      }
      final FriendProfile? existing = ref
          .read(socialHubControllerProvider)
          .friendByAddress(target.address);
      if (existing?.status == FriendRelationshipStatus.accepted) {
        throw FormatException(t('Ten peer jest już na liście znajomych.'));
      }
      if (existing?.status == FriendRelationshipStatus.pendingOutgoing) {
        throw FormatException(t('Zaproszenie do tego peera już czeka.'));
      }
      if (existing?.status == FriendRelationshipStatus.pendingIncoming) {
        throw FormatException(
          t('Masz już oczekujące zaproszenie od tego peera.'),
        );
      }
      if (existing?.status == FriendRelationshipStatus.blocked) {
        throw FormatException(
          t('Ten kontakt jest zablokowany. Odblokuj go w ustawieniach.'),
        );
      }
      final String nickname = sanitizeFriendNickname(_nicknameController.text);
      final String profileName = ref
          .read(userProfileControllerProvider)
          .publicName;
      final String? senderDisplayName =
          PeerShareCodec.buildLocalProfile(
            address: localAddress,
            displayName: profileName,
          )?.displayName ??
          (profileName.trim().isNotEmpty ? profileName.trim() : null);
      await ref
          .read(socialHubControllerProvider.notifier)
          .sendFriendRequest(
            peerAddress: target.address,
            nickname: nickname,
            senderDisplayName: senderDisplayName,
            message: _messageController.text,
          );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(
        _AddFriendResult(
          target: target,
          nickname: nickname,
          metInPerson:
              _scannedCode != null && _scannedCode == _targetController.text,
        ),
      );
    } on FormatException catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = error.message;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _errorText = t('Nie udało się wysłać zaproszenia: {error}', {
          'error': error,
        });
      });
    } finally {
      if (mounted) {
        setState(() {
          _submitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final EdgeInsets viewInsets = MediaQuery.viewInsetsOf(context);
    final PeerQrScanner qrScanner = ref.watch(peerQrScannerProvider);
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Material(
        color: zen.surfaceRaised,
        shape: context.zenSheetShape(),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const _SheetHandle(),
                const SizedBox(height: 18),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ZenIconBadge(
                      icon: Icons.person_add_alt_1_rounded,
                      tone: zen.accent,
                      size: 48,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            t('Dodaj znajomego'),
                            style: zen.display(
                              color: zen.textPrimary,
                              size: 22,
                              weight: FontWeight.w600,
                              height: 1.15,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            t('Wklej kod znajomego albo zeskanuj jego QR.'),
                            style: TextStyle(
                              color: zen.textSecondary,
                              fontSize: 13.5,
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                TextField(
                  key: const Key('add-friend-target-field'),
                  controller: _targetController,
                  autofocus: true,
                  maxLines: 1,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: zen.mono(
                    color: zen.textPrimary,
                    size: 15,
                    weight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                  inputFormatters: const <TextInputFormatter>[
                    _ShareCodeInputFormatter(),
                  ],
                  onChanged: (String value) {
                    if (_errorText != null) {
                      setState(() {
                        _errorText = null;
                      });
                    }
                  },
                  decoration: InputDecoration(
                    labelText: t('Kod lub zaproszenie'),
                    hintText: 'XXXXX-XXXXX-…',
                    helperText: t(
                      'Wielkie litery i myślniki ustawiają się same.',
                    ),
                    errorText: _errorText,
                    errorMaxLines: 3,
                    prefixIcon: const Icon(Icons.qr_code_2_rounded),
                    suffixIcon: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (qrScanner.isSupported)
                          IconButton(
                            key: const Key('add-friend-scan-button'),
                            onPressed: _submitting ? null : _scanTarget,
                            icon: const Icon(Icons.qr_code_scanner_rounded),
                            tooltip: t('Skanuj QR'),
                          ),
                        IconButton(
                          onPressed: _submitting ? null : _pasteTarget,
                          icon: const Icon(Icons.content_paste_rounded),
                          tooltip: t('Wklej ze schowka'),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('add-friend-nickname-field'),
                  controller: _nicknameController,
                  maxLength: kMaxFriendNickname,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: t('Pseudonim (opcjonalnie)'),
                    hintText: t('np. Kasia z pracy'),
                    helperText: t(
                      'Nazwa przyjdzie z profilu tej osoby. Pseudonim '
                      'widzisz tylko Ty, pod jej nazwą.',
                    ),
                    helperMaxLines: 3,
                    prefixIcon: const Icon(Icons.badge_outlined),
                  ),
                ),
                const SizedBox(height: 14),
                TextField(
                  key: const Key('add-friend-message-field'),
                  controller: _messageController,
                  minLines: 2,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: t('Notatka startowa'),
                    hintText: t(
                      'Opcjonalna wiadomość dołączona do zaproszenia',
                    ),
                    hintStyle: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: zen.textMuted.withValues(alpha: 0.75),
                      fontStyle: FontStyle.italic,
                    ),
                    prefixIcon: const Icon(Icons.edit_note_rounded),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 22),
                FilledButton.icon(
                  key: const Key('submit-add-friend-button'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  onPressed: _submitting ? null : _submit,
                  icon: _submitting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  label: Text(
                    _submitting ? t('Wysyłanie') : t('Wyślij zaproszenie'),
                  ),
                ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _submitting
                      ? null
                      : () => Navigator.of(context).pop(),
                  child: Text(t('Anuluj')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ShareCodeInputFormatter extends TextInputFormatter {
  const _ShareCodeInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final String normalized = PeerShareCodec.normalizeManualInput(
      newValue.text,
    );
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
      composing: TextRange.empty,
    );
  }
}
