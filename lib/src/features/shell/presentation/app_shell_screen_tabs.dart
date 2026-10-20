part of 'app_shell_screen.dart';

/// One destination of the vertical tab rail.
@immutable
class _ShellTab {
  const _ShellTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.glyph,
    this.group,
  });

  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// A drawn icon instead of [icon] (color, size, selected).
  final Widget Function(Color color, double size, bool selected)? glyph;

  /// `null`: a button on the rail. Otherwise the tab lives under "Więcej"
  /// (§25), in this group.
  final _MoreGroup? group;
}

/// Sections of the "Więcej" sheet for the rarely used tabs (§25).
enum _MoreGroup {
  meetings,
  community,
  other;

  String get title => switch (this) {
    _MoreGroup.meetings => t('Spotkania'),
    _MoreGroup.community => t('Wspólnota'),
    _MoreGroup.other => t('Inne'),
  };
}

/// The rail button that opens the sheet with the grouped tabs.
_ShellTab get _moreButtonTab => _ShellTab(
  id: 'more',
  label: t('Więcej'),
  icon: Icons.more_horiz_rounded,
  selectedIcon: Icons.more_horiz_rounded,
);

Widget _pyramidGlyph(Color color, double size, bool selected) =>
    PyramidGlyph(color: color, size: size, filled: selected);

/// Profile first, then conversations, the wall and invitations. Settings
/// open from the connection bar at the top (no duplicate here).
List<_ShellTab> get _shellTabs => <_ShellTab>[
  // The graph of who-knows-who is the heart of Zen, so it leads the rail.
  _ShellTab(
    id: 'graph',
    label: t('Graf znajomych'),
    icon: Icons.hub_outlined,
    selectedIcon: Icons.hub_rounded,
  ),
  _ShellTab(
    id: 'profile',
    label: t('Profil'),
    icon: Icons.person_outline_rounded,
    selectedIcon: Icons.person_rounded,
  ),
  _ShellTab(
    id: 'chats',
    label: t('Czaty'),
    icon: Icons.chat_bubble_outline_rounded,
    selectedIcon: Icons.chat_bubble_rounded,
  ),
  _ShellTab(
    id: 'feed',
    label: t('Tablica'),
    icon: Icons.newspaper_outlined,
    selectedIcon: Icons.newspaper_rounded,
  ),
  _ShellTab(
    id: 'meet',
    label: t('Spotkania'),
    icon: Icons.diversity_3_outlined,
    selectedIcon: Icons.diversity_3_rounded,
  ),
  _ShellTab(
    id: 'dating',
    label: t('Randki'),
    icon: Icons.favorite_outline_rounded,
    selectedIcon: Icons.favorite_rounded,
    group: _MoreGroup.meetings,
  ),
  _ShellTab(
    id: 'neighbors',
    label: t('Sąsiedzi'),
    icon: Icons.door_front_door_outlined,
    selectedIcon: Icons.door_front_door_rounded,
  ),
  _ShellTab(
    id: 'pyramid',
    label: t('Piramida'),
    icon: kPyramidIcon,
    selectedIcon: kPyramidIcon,
    glyph: _pyramidGlyph,
    group: _MoreGroup.community,
  ),
  // The points wallet, right before Bluetooth (§18).
  _ShellTab(
    id: 'wallet',
    label: t('Portfel'),
    icon: Icons.attach_money_rounded,
    selectedIcon: Icons.attach_money_rounded,
    group: _MoreGroup.community,
  ),
  // Bluetooth "people nearby" sits right before the invite QR (§12).
  _ShellTab(
    id: 'nearby',
    label: t('Osoby w pobliżu'),
    icon: Icons.bluetooth_searching_rounded,
    selectedIcon: Icons.bluetooth_connected_rounded,
    group: _MoreGroup.meetings,
  ),
  _ShellTab(
    id: 'invite',
    label: t('Zaproś'),
    icon: Icons.qr_code_2_rounded,
    selectedIcon: Icons.qr_code_2_rounded,
    group: _MoreGroup.other,
  ),
  _ShellTab(
    id: 'about',
    label: t('O aplikacji'),
    icon: Icons.info_outline_rounded,
    selectedIcon: Icons.info_rounded,
    group: _MoreGroup.other,
  ),
  // Last, at the bottom of the rail and in red (§16.3).
  _ShellTab(
    id: 'alarm',
    label: t('Alarm'),
    icon: Icons.campaign_outlined,
    selectedIcon: Icons.campaign_rounded,
  ),
];

/// Another part of the shell asks to show a tab (e.g. "Zaproś znajomych"
/// on the empty chats list).
final ValueNotifier<String?> _shellTabRequest = ValueNotifier<String?>(null);

/// The app opens on the conversations.
final int _startTab = _shellTabs.indexWhere((_ShellTab t) => t.id == 'chats');

/// The rail is a narrow strip of icons (§25). It can be hidden completely;
/// a small tab at the left edge brings it back.
const double _railWidth = 56;

/// The app with vertical tabs on the left (§25): a slim icon rail on
/// every screen size; it can be hidden completely.
class _TabbedShell extends ConsumerStatefulWidget {
  const _TabbedShell();

  @override
  ConsumerState<_TabbedShell> createState() => _TabbedShellState();
}

class _TabbedShellState extends ConsumerState<_TabbedShell> {
  int _index = _startTab;

  /// Rail hidden completely (the page gets the whole width).
  bool _hidden = false;

  /// Pages are built on first visit and then kept (scroll positions, state).
  final Set<int> _visited = <int>{_startTab};

  static const String _railKey = 'ui/rail_hidden';

  @override
  void initState() {
    super.initState();
    _shellTabRequest.addListener(_onTabRequest);
    // The rail remembers whether it was hidden last time.
    unawaited(
      ref
          .read(ledgerDiskProvider)
          .read(_railKey)
          .then((Uint8List? raw) {
            if (mounted && raw != null && raw.isNotEmpty) {
              setState(() => _hidden = raw.first == 1);
            }
          })
          .catchError((Object _) {}),
    );
  }

  @override
  void dispose() {
    _shellTabRequest.removeListener(_onTabRequest);
    super.dispose();
  }

  void _onTabRequest() {
    final String? id = _shellTabRequest.value;
    if (id == null) {
      return;
    }
    _shellTabRequest.value = null;
    final int i = _shellTabs.indexWhere((_ShellTab t) => t.id == id);
    // A feature switched off (A15) has no tab to go to.
    if (i >= 0 && ref.read(featureFlagsProvider).showsTab(id)) {
      _select(i);
    }
  }

  void _setHidden(bool hidden) {
    if (hidden == _hidden) {
      return;
    }
    setState(() => _hidden = hidden);
    unawaited(
      ref
          .read(ledgerDiskProvider)
          .write(_railKey, Uint8List.fromList(<int>[if (hidden) 1 else 0]))
          .catchError((Object _) {}),
    );
  }

  void _select(int index) {
    if (index == _index) {
      return;
    }
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  /// "Więcej": the rarely used tabs, grouped (§25).
  Future<void> _openMore(int current) async {
    final String? id = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) =>
          _MoreSheet(selectedId: _shellTabs[current].id),
    );
    if (id == null || !mounted) {
      return;
    }
    final int i = _shellTabs.indexWhere((_ShellTab t) => t.id == id);
    if (i >= 0) {
      _select(i);
    }
  }

  Widget _page(int index) => switch (_shellTabs[index].id) {
    // The chat list shows the last messages, dating who meets whom (S-9).
    'chats' => const SecureScreen(child: _ChatsPage(key: Key('chats-page'))),
    'feed' => const FeedScreen(),
    'meet' => const MeetHubScreen(),
    'graph' => const GraphScreen(),
    'nearby' => const NearbyScreen(),
    'about' => const AboutScreen(),
    'dating' => const SecureScreen(child: DatingScreen()),
    'neighbors' => const NeighborsScreen(),
    'alarm' => const AlarmScreen(),
    'pyramid' => const PyramidScreen(),
    'wallet' => const WalletScreen(),
    'invite' => const _MyCodeScreen(),
    _ => const ProfileScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final FeatureFlags flags = ref.watch(featureFlagsProvider);
    // The open tab's feature was just switched off: back to the start tab.
    final int index = flags.showsTab(_shellTabs[_index].id)
        ? _index
        : _startTab;
    return Scaffold(
      key: const Key('tabbed-shell'),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // Connection status stays across the top; a tap opens settings.
            const _StatusBar(),
            // This phone's clock is off (A21): a bar, tap for the report.
            const ClockSkewBanner(),
            Expanded(
              child: Row(
                children: <Widget>[
                  if (!_hidden)
                    _SideTabs(
                      index: index,
                      onSelect: _select,
                      onMore: () => unawaited(_openMore(index)),
                      onHide: () => _setHidden(true),
                    ),
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        const _CallFeedbackHost(),
                        Expanded(
                          child: Stack(
                            children: <Widget>[
                              Positioned.fill(
                                child: IndexedStack(
                                  index: index,
                                  children: <Widget>[
                                    for (int i = 0; i < _shellTabs.length; i++)
                                      // "W pobliżu" scans Bluetooth while it is
                                      // built, so it lives only while it is shown.
                                      _visited.contains(i) &&
                                              flags.showsTab(
                                                _shellTabs[i].id,
                                              ) &&
                                              (_shellTabs[i].id != 'nearby' ||
                                                  i == index)
                                          ? KeyedSubtree(
                                              key: Key(
                                                'tab-page-${_shellTabs[i].id}',
                                              ),
                                              child: _ReadableWidth(
                                                child: _page(i),
                                              ),
                                            )
                                          : const SizedBox.shrink(),
                                  ],
                                ),
                              ),
                              if (_hidden)
                                // Hidden: a small handle lies over the content
                                // (it takes no width), up top where the thumb
                                // reaches it; a swipe right on it works too.
                                Positioned(
                                  left: 0,
                                  top: 10,
                                  child: _ShowRailTab(
                                    onTap: () => _setHidden(false),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// On a wide window (desktop) a tab's page keeps a comfortable reading
/// width, centred, instead of stretching lines and cards across the screen.
class _ReadableWidth extends StatelessWidget {
  const _ReadableWidth({required this.child});

  final Widget child;

  static const double maxWidth = 920;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints c) {
        if (c.maxWidth <= maxWidth + 48) {
          return child;
        }
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: child,
          ),
        );
      },
    );
  }
}

/// The handle over the content's edge while the rail is hidden.
class _ShowRailTab extends StatelessWidget {
  const _ShowRailTab({required this.onTap});

  final VoidCallback onTap;

  static const double width = 30;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    const BorderRadius radius = BorderRadius.horizontal(
      right: Radius.circular(10),
    );
    return GestureDetector(
      onHorizontalDragEnd: (DragEndDetails d) {
        if ((d.primaryVelocity ?? 0) > 200) {
          onTap();
        }
      },
      child: Tooltip(
        message: t('Pokaż pasek'),
        // See-through: it lies over the content and should not hide it.
        child: Material(
          color: zen.surfaceSunk.withValues(alpha: 0.45),
          borderRadius: radius,
          child: InkWell(
            key: const Key('side-tabs-show'),
            borderRadius: radius,
            onTap: onTap,
            child: SizedBox(
              width: width,
              height: 56,
              child: Icon(
                Icons.keyboard_double_arrow_right_rounded,
                color: zen.textSecondary.withValues(alpha: 0.75),
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SideTabs extends ConsumerWidget {
  const _SideTabs({
    required this.index,
    required this.onSelect,
    required this.onMore,
    required this.onHide,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onMore;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final AppSecurityService security = ref.watch(appSecurityServiceProvider);
    final FeatureFlags flags = ref.watch(featureFlagsProvider);
    // The rail buttons, plus "Więcej" when something is grouped under it.
    final bool hasMore = _shellTabs.any(
      (_ShellTab t) => t.group != null && flags.showsTab(t.id),
    );
    final int visibleTabs =
        _shellTabs
            .where((_ShellTab t) => t.group == null && flags.showsTab(t.id))
            .length +
        (hasMore ? 1 : 0);
    final int unread = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState s) =>
            s.acceptedFriends.fold<int>(
              0,
              (int sum, FriendProfile f) => sum + f.unreadCount,
            ) +
            s.groupList.fold<int>(
              0,
              (int sum, GroupProfile g) => sum + g.unreadCount,
            ),
      ),
    );
    return GestureDetector(
      // Swipe the rail to the left to hide it.
      onHorizontalDragEnd: (DragEndDetails d) {
        if ((d.primaryVelocity ?? 0) < -200) {
          onHide();
        }
      },
      child: Container(
        width: _railWidth,
        decoration: BoxDecoration(
          color: zen.surfaceSunk,
          border: Border(right: BorderSide(color: zen.outlineSoft)),
        ),
        child: Column(
          children: <Widget>[
            const SizedBox(height: 4),
            // Up top, within the thumb's reach (§25).
            IconButton(
              key: const Key('side-tabs-hide'),
              tooltip: t('Ukryj pasek'),
              visualDensity: VisualDensity.compact,
              onPressed: onHide,
              icon: Icon(
                Icons.keyboard_double_arrow_left_rounded,
                color: zen.textSecondary,
                size: 20,
              ),
            ),
            // Lock now, one tap away (only once there is a password).
            ListenableBuilder(
              listenable: security,
              builder: (BuildContext context, Widget? _) =>
                  security.canQuickLock
                  ? IconButton(
                      key: const Key('side-tabs-lock'),
                      tooltip: t('Zablokuj teraz'),
                      visualDensity: VisualDensity.compact,
                      onPressed: security.lock,
                      icon: Icon(
                        Icons.lock_outline_rounded,
                        color: zen.textSecondary,
                        size: 20,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
            const SizedBox(height: 2),
            Container(width: 24, height: 1, color: zen.outlineSoft),
            const SizedBox(height: 6),
            Expanded(
              child: LayoutBuilder(
                builder: (BuildContext context, BoxConstraints c) {
                  // Every button fits on screen: on a short phone they get
                  // slimmer (down to a still comfortable tap target) instead
                  // of the last ones sliding out of sight. Only below that
                  // (a phone on its side) does the rail scroll.
                  final double extent = ((c.maxHeight - 8) / visibleTabs).clamp(
                    _sideTabMinExtent,
                    _sideTabMaxExtent,
                  );
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight),
                      child: IntrinsicHeight(
                        child: Column(
                          children: <Widget>[
                            for (int i = 0; i < _shellTabs.length; i++)
                              if (_shellTabs[i].id != 'alarm' &&
                                  _shellTabs[i].group == null &&
                                  flags.showsTab(_shellTabs[i].id))
                                _SideTabButton(
                                  tab: _shellTabs[i],
                                  extent: extent,
                                  selected: i == index,
                                  badge: _shellTabs[i].id == 'chats'
                                      ? unread
                                      : 0,
                                  onTap: () => onSelect(i),
                                ),
                            if (hasMore)
                              _SideTabButton(
                                tab: _moreButtonTab,
                                extent: extent,
                                selected: _shellTabs[index].group != null,
                                badge: 0,
                                onTap: onMore,
                              ),
                            const Spacer(),
                            for (int i = 0; i < _shellTabs.length; i++)
                              if (_shellTabs[i].id == 'alarm')
                                _SideTabButton(
                                  tab: _shellTabs[i],
                                  extent: extent,
                                  selected: i == index,
                                  badge: 0,
                                  danger: true,
                                  onTap: () => onSelect(i),
                                ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Height of one rail button (tap area included): roomy on a tall phone,
/// never below a comfortable thumb target.
const double _sideTabMaxExtent = 54;
const double _sideTabMinExtent = 32;

class _SideTabButton extends StatelessWidget {
  const _SideTabButton({
    required this.tab,
    required this.selected,
    required this.badge,
    required this.onTap,
    this.extent = _sideTabMaxExtent,
    this.danger = false,
  });

  final _ShellTab tab;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  /// Height of the whole button, outer gap included.
  final double extent;

  /// The alarm: always red.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color fg = danger
        ? zen.danger
        : selected
        ? zen.accent
        : zen.textMuted;
    final Color hue = danger ? zen.danger : zen.accent;
    final Color hue2 = danger ? zen.danger : zen.accentSecondary;
    final bool compact = extent < 46;
    final double iconSize = compact ? 22 : 24;
    // Slim buttons keep almost the whole height tappable.
    final double gap = compact ? 1 : 3;
    // extent = 2 × gap + 2 × 1 border + 2 × padding + icon.
    final double padding = ((extent - 2 * gap - 2 - iconSize) / 2).clamp(
      2.0,
      11.0,
    );
    return Semantics(
      selected: selected,
      button: true,
      label: badge > 0
          ? t('{label}, nieprzeczytane: {n}', {
              'label': tab.label,
              'n': badge > 99 ? '99+' : badge,
            })
          : tab.label,
      hint: tab.id == 'more' ? t('Pokaż pozostałe zakładki') : null,
      child: Tooltip(
        message: tab.label,
        excludeFromSemantics: true,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: gap),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              key: Key('side-tab-${tab.id}'),
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                padding: EdgeInsets.symmetric(vertical: padding),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: selected
                      ? LinearGradient(
                          colors: <Color>[
                            hue.withValues(alpha: 0.28),
                            hue2.withValues(alpha: 0.14),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        )
                      : null,
                  border: Border.all(
                    color: selected
                        ? hue.withValues(alpha: 0.35)
                        : danger
                        ? zen.danger.withValues(alpha: 0.30)
                        : Colors.transparent,
                  ),
                ),
                child: Center(
                  child: Badge(
                    isLabelVisible: badge > 0,
                    label: Text(badge > 99 ? '99+' : '$badge'),
                    child:
                        tab.glyph?.call(fg, iconSize, selected) ??
                        Icon(
                          selected ? tab.selectedIcon : tab.icon,
                          color: fg,
                          size: iconSize,
                        ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheet behind "Więcej": the rarely used tabs, grouped.
class _MoreSheet extends ConsumerWidget {
  const _MoreSheet({required this.selectedId});

  final String selectedId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final FeatureFlags flags = ref.watch(featureFlagsProvider);
    final List<_ShellTab> tabs = <_ShellTab>[
      for (final _ShellTab tab in _shellTabs)
        if (tab.group != null && flags.showsTab(tab.id)) tab,
    ];
    return SafeArea(
      child: SingleChildScrollView(
        key: const Key('more-sheet'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (final _MoreGroup group in _MoreGroup.values) ...<Widget>[
              if (tabs.any((_ShellTab t) => t.group == group))
                ZenSection(group.title, top: 4),
              for (final _ShellTab tab in tabs)
                if (tab.group == group)
                  ListTile(
                    key: Key('more-tab-${tab.id}'),
                    selected: tab.id == selectedId,
                    selectedColor: zen.accent,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                    leading:
                        tab.glyph?.call(
                          tab.id == selectedId ? zen.accent : zen.textSecondary,
                          24,
                          tab.id == selectedId,
                        ) ??
                        Icon(tab.icon),
                    title: Text(tab.label),
                    onTap: () => Navigator.of(context).pop(tab.id),
                  ),
            ],
          ],
        ),
      ),
    );
  }
}
