part of 'app_shell_screen.dart';

/// The groups of the rail, top to bottom: you and your people, what they
/// post, meeting people, the community. Each has its own tone of the theme
/// ([ZenTone]); a thin line in that tone opens the group.
enum _RailGroup {
  people,
  posts,
  meeting,
  community;

  /// What the group is about ([ZenTone]): the same tone as its things
  /// elsewhere (people in the settings, posts in the feed…).
  ZenTone get tone => switch (this) {
    _RailGroup.people => ZenTone.people,
    _RailGroup.posts => ZenTone.media,
    _RailGroup.meeting => ZenTone.places,
    _RailGroup.community => ZenTone.money,
  };

  Color hue(ZenColors zen) => zen.tone(tone);
}

/// One destination of the vertical tab rail.
@immutable
class _ShellTab {
  const _ShellTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    this.group,
    this.tooltip,
    this.glyph,
  });

  final String id;

  /// Shown under the icon of the open tab (short: it has to fit the rail).
  final String label;

  /// The longer name for the tooltip and screen readers ([label] if null).
  final String? tooltip;

  final IconData icon;
  final IconData selectedIcon;

  /// The group on the rail; `null` for the alarm (alone, at the bottom).
  final _RailGroup? group;

  /// A drawn icon instead of [icon] (color, size, selected).
  final Widget Function(Color color, double size, bool selected)? glyph;

  String get fullLabel => tooltip ?? label;
}

Widget _pyramidGlyph(Color color, double size, bool selected) =>
    PyramidGlyph(color: color, size: size, filled: selected);

/// Every main place of Zen, one tap away, in four groups; the alarm at the
/// bottom. Nothing is hidden under "more": a vertical rail has room for all
/// of them on the smallest phone. Settings, the accounts, "Zaproś" and
/// "O aplikacji" are in the top bar.
List<_ShellTab> get _shellTabs => <_ShellTab>[
  // The graph of who-knows-who is the heart of Zen, so it leads the rail.
  _ShellTab(
    id: 'graph',
    group: _RailGroup.people,
    label: t('Graf'),
    tooltip: t('Graf znajomych'),
    icon: Icons.hub_outlined,
    selectedIcon: Icons.hub_rounded,
  ),
  _ShellTab(
    id: 'chats',
    group: _RailGroup.people,
    label: t('Czaty'),
    icon: Icons.chat_bubble_outline_rounded,
    selectedIcon: Icons.chat_bubble_rounded,
  ),
  _ShellTab(
    id: 'profile',
    group: _RailGroup.people,
    label: t('Profil'),
    icon: Icons.person_outline_rounded,
    selectedIcon: Icons.person_rounded,
  ),
  _ShellTab(
    id: 'feed',
    group: _RailGroup.posts,
    label: t('Tablica'),
    icon: Icons.newspaper_outlined,
    selectedIcon: Icons.newspaper_rounded,
  ),
  _ShellTab(
    id: 'films',
    group: _RailGroup.posts,
    label: t('Filmy'),
    icon: Icons.smart_display_outlined,
    selectedIcon: Icons.smart_display_rounded,
  ),
  _ShellTab(
    id: 'meet',
    group: _RailGroup.meeting,
    label: t('Spotkania'),
    icon: Icons.diversity_3_outlined,
    selectedIcon: Icons.diversity_3_rounded,
  ),
  _ShellTab(
    id: 'nearby',
    group: _RailGroup.meeting,
    label: t('W pobliżu'),
    tooltip: t('Osoby w pobliżu'),
    icon: Icons.bluetooth_searching_rounded,
    selectedIcon: Icons.bluetooth_connected_rounded,
  ),
  _ShellTab(
    id: 'neighbors',
    group: _RailGroup.meeting,
    label: t('Sąsiedzi'),
    icon: Icons.door_front_door_outlined,
    selectedIcon: Icons.door_front_door_rounded,
  ),
  _ShellTab(
    id: 'dating',
    group: _RailGroup.meeting,
    label: t('Randki'),
    icon: Icons.favorite_outline_rounded,
    selectedIcon: Icons.favorite_rounded,
  ),
  _ShellTab(
    id: 'pyramid',
    group: _RailGroup.community,
    label: t('Piramida'),
    icon: kPyramidIcon,
    selectedIcon: kPyramidIcon,
    glyph: _pyramidGlyph,
  ),
  _ShellTab(
    id: 'wallet',
    group: _RailGroup.community,
    label: t('Portfel'),
    icon: Icons.account_balance_wallet_outlined,
    selectedIcon: Icons.account_balance_wallet_rounded,
  ),
  // Last, at the bottom of the rail and in red.
  _ShellTab(
    id: 'alarm',
    label: t('Alarm'),
    icon: Icons.campaign_outlined,
    selectedIcon: Icons.campaign_rounded,
  ),
];

/// Whether this device can use "W pobliżu" at all: Android always (its
/// screen walks through permissions and Bluetooth), never on iPhone, iPad
/// or the web, and on a computer only with a Bluetooth LE adapter Zen can
/// use. Where it cannot, the rail has no "W pobliżu".
final Provider<bool> nearbyTabShownProvider = Provider<bool>((Ref ref) {
  if (kIsWeb || Platform.isIOS) {
    return false;
  }
  if (Platform.isAndroid) {
    return true;
  }
  // Tests do not probe the computer's Bluetooth.
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return true;
  }
  return ref.watch(nearbySupportedProvider).value ?? false;
});

/// Whether the rail shows the tab [id]: its feature is in the build and
/// works on this device.
bool _railShows(FeatureFlags flags, bool nearby, String id) =>
    flags.showsTab(id) && (id != 'nearby' || nearby);

/// Another part of the shell asks to show a tab (e.g. the Tablica asked
/// for by [openFeed]).
final ValueNotifier<String?> _shellTabRequest = ValueNotifier<String?>(null);

/// Shows the tab [id] of the rail (a link, a notification, another screen).
/// Does nothing for an unknown tab or one the build leaves out.
void openShellTab(String id) => _shellTabRequest.value = id;

/// The app opens on the conversations.
final int _startTab = _shellTabs.indexWhere((_ShellTab t) => t.id == 'chats');

/// The rail is a narrow strip of icons. It can be hidden completely (the
/// button at the left of the top bar).
const double _railWidth = 56;

/// The app with vertical tabs on the left: a slim icon rail on every
/// screen size; it can be hidden completely.
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

  late final ShellLocationController _location = ref.read(
    shellLocationProvider,
  );

  /// Where a tab's list is put back to (the place the app was closed at).
  final Map<String, ScrollRestore> _scrollRestore = <String, ScrollRestore>{};

  @override
  void initState() {
    super.initState();
    _location.startOn(_shellTabs[_startTab].id);
    _shellTabRequest.addListener(_onTabRequest);
    feedOpenRequest.addListener(_onFeedRequest);
    unawaited(_restoreLocation());
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
    feedOpenRequest.removeListener(_onFeedRequest);
    super.dispose();
  }

  /// The Tablica asked for from elsewhere ([openFeed]); it sets the filter.
  void _onFeedRequest() {
    _shellTabRequest.value = 'feed';
  }

  void _onTabRequest() {
    final String? id = _shellTabRequest.value;
    if (id == null) {
      return;
    }
    _shellTabRequest.value = null;
    final int i = _shellTabs.indexWhere((_ShellTab t) => t.id == id);
    // A feature left out of the build has no tab to go to.
    if (i >= 0 &&
        _railShows(
          ref.read(featureFlagsProvider),
          ref.read(nearbyTabShownProvider),
          id,
        )) {
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
    _location.selectTab(_shellTabs[index].id);
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  /// Goes back to where the app was closed: its tab, the list scrolled as it
  /// was, and the conversation or page that was open. Only the shell is built
  /// after the app is unlocked, so nothing shows before the lock screen. A
  /// notification or a link that opens a screen comes first, and so does
  /// anything the user did meanwhile; a page that is gone leaves the tab.
  Future<void> _restoreLocation() async {
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    bool launchIntent =
        ref.read(socialHubControllerProvider).pendingLaunchIntent != null;
    final ProviderSubscription<bool> watch = ref.listenManual<bool>(
      socialHubControllerProvider.select(
        (SocialHubState s) => s.pendingLaunchIntent != null,
      ),
      (bool? previous, bool next) => launchIntent = launchIntent || next,
    );
    final int mark = _location.changeCount;
    ShellLocation? saved;
    try {
      // The stored launch intent is part of what hydration brings back.
      final List<Object?> both = await Future.wait<Object?>(<Future<Object?>>[
        hub.whenHydrated,
        _location.restorePoint(),
      ]);
      saved = both[1] as ShellLocation?;
    } on Object {
      saved = null;
    } finally {
      watch.close();
    }
    if (!mounted ||
        saved == null ||
        launchIntent ||
        _location.changeCount != mark) {
      _location.restoreDone();
      return;
    }
    final ShellLocation last = saved;
    final int tab = _shellTabs.indexWhere((_ShellTab t) => t.id == last.tab);
    if (tab >= 0 &&
        _railShows(
          ref.read(featureFlagsProvider),
          ref.read(nearbyTabShownProvider),
          last.tab,
        )) {
      setState(() {
        _scrollRestore[last.tab] = ScrollRestore(last.tabScroll);
      });
      _select(tab);
    }
    final ShellPlace? place = last.place;
    if (place != null) {
      await _openRememberedPlace(place);
    }
    // The page asked for its own memory when it was built.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _location.restoreDone(),
    );
  }

  /// Opens the page [place] names; nothing happens when it is gone (the
  /// conversation was deleted, the group left or not joined yet).
  Future<void> _openRememberedPlace(ShellPlace place) async {
    final SocialHubState hub = ref.read(socialHubControllerProvider);
    final NavigatorState navigator = Navigator.of(context);
    final Widget page;
    switch (place.kind) {
      case ShellPlace.peerChatKind:
        final FriendProfile? friend = hub.friendByAddress(place.id);
        if (friend == null) {
          // Someone who is not a friend (a message request): there while
          // their messages are kept.
          final List<ChatMessage> thread = await ref
              .read(messageTimelineStoreProvider)
              .load(place.id);
          if (!mounted || thread.isEmpty) {
            return;
          }
        }
        page = ConversationScreen(
          peerAddress: place.id,
          title:
              friend?.displayLabel ??
              PeerShareCodec.displayNameForAddress(place.id),
        );
      case ShellPlace.groupChatKind:
        final GroupProfile? group = hub.groups[place.id];
        if (group == null || group.isInvitePending) {
          return;
        }
        page = GroupConversationScreen(
          groupId: place.id,
          groupName: group.name.trim().isNotEmpty ? group.name : t('Grupa'),
        );
      case ShellPlace.settingsKind:
        unawaited(_openSettingsScreen(context));
        return;
      default:
        return;
    }
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(builder: (BuildContext context) => page),
      ),
    );
  }

  Widget _page(int index) => switch (_shellTabs[index].id) {
    // The chat list shows the last messages, dating who meets whom.
    'chats' => const SecureScreen(child: _ChatsPage(key: Key('chats-page'))),
    'feed' => const FeedScreen(),
    'films' => const FilmsScreen(),
    'meet' => const MeetHubScreen(),
    'nearby' => const NearbyScreen(),
    'graph' => const GraphScreen(),
    'dating' => const SecureScreen(child: DatingScreen()),
    'neighbors' => const NeighborsScreen(),
    'alarm' => const AlarmScreen(),
    'pyramid' => const PyramidScreen(),
    'wallet' => const WalletScreen(),
    _ => const ProfileScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final FeatureFlags flags = ref.watch(featureFlagsProvider);
    // The open tab's feature is left out of the build: the start tab.
    final bool nearby = ref.watch(nearbyTabShownProvider);
    final int index = _railShows(flags, nearby, _shellTabs[_index].id)
        ? _index
        : _startTab;
    return Scaffold(
      key: const Key('tabbed-shell'),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            // Connection status stays across the top; a tap opens settings.
            // Its first button shows or hides the rail.
            _StatusBar(
              railHidden: _hidden,
              onToggleRail: () => _setHidden(!_hidden),
            ),
            // This phone's clock is off: a bar, tap for the report.
            const ClockSkewBanner(),
            // A newer release on GitHub, or GitHub blocked.
            const GithubUpdateBanner(),
            // A call recording that could not be stored yet.
            const UnsavedCallRecordingsBanner(),
            Expanded(
              child: Row(
                children: <Widget>[
                  if (!_hidden)
                    _SideTabs(
                      index: index,
                      onSelect: _select,
                      onHide: () => _setHidden(true),
                    ),
                  Expanded(
                    child: Column(
                      children: <Widget>[
                        const _CallFeedbackHost(),
                        Expanded(
                          child: IndexedStack(
                            index: index,
                            children: <Widget>[
                              for (int i = 0; i < _shellTabs.length; i++)
                                // "W pobliżu" scans Bluetooth while it is
                                // built, so it lives only while it is shown.
                                _visited.contains(i) &&
                                        _railShows(
                                          flags,
                                          nearby,
                                          _shellTabs[i].id,
                                        ) &&
                                        (_shellTabs[i].id != 'nearby' ||
                                            i == index)
                                    ? KeyedSubtree(
                                        key: Key(
                                          'tab-page-${_shellTabs[i].id}',
                                        ),
                                        child: _ReadableWidth(
                                          child: ScrollMemory(
                                            restore:
                                                _scrollRestore[_shellTabs[i]
                                                    .id],
                                            onScrolled: (double offset) =>
                                                _location.tabScrolled(
                                                  _shellTabs[i].id,
                                                  offset,
                                                ),
                                            child: _page(i),
                                          ),
                                        ),
                                      )
                                    : const SizedBox.shrink(),
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

/// Height of one rail button (tap area included): roomy on a tall phone,
/// never below a comfortable thumb target. The buttons take all the height
/// there is: on the smallest phone, 320x568, the twelve places get about
/// 38 dp each (56 dp wide) and still fit without scrolling; from 360x640 up
/// they are 48 dp. Only a shorter window (a phone on its side, split
/// screen) scrolls.
const double _sideTabMaxExtent = 54;
const double _sideTabMinExtent = 36;

/// The rail's own gaps above the first group and below the alarm.
const double _railTopGap = 4;
const double _railBottomGap = 4;

/// What the open tab's label adds to its button.
const double _sideTabLabelExtent = 14;

/// The line that opens a group, with its gaps.
const double _railGroupGap = 9;

/// The rail: the groups of tabs from the top, the alarm at the bottom.
/// Buttons share the height (between [_sideTabMinExtent] and
/// [_sideTabMaxExtent]); it scrolls only when even the smallest do not fit
/// (a short split-screen window).
class _SideTabs extends ConsumerWidget {
  const _SideTabs({
    required this.index,
    required this.onSelect,
    required this.onHide,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final FeatureFlags flags = ref.watch(featureFlagsProvider);
    final bool nearby = ref.watch(nearbyTabShownProvider);
    final List<int> shown = <int>[
      for (int i = 0; i < _shellTabs.length; i++)
        if (_railShows(flags, nearby, _shellTabs[i].id)) i,
    ];
    final int groups = <_RailGroup?>{
      for (final int i in shown)
        if (_shellTabs[i].group != null) _shellTabs[i].group,
    }.length;
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
    Widget button(int i, double extent) => _SideTabButton(
      tab: _shellTabs[i],
      extent: extent,
      selected: i == index,
      badge: _shellTabs[i].id == 'chats' ? unread : 0,
      danger: _shellTabs[i].id == 'alarm',
      hue: _shellTabs[i].group?.hue(zen),
      onTap: () => onSelect(i),
    );
    // Keyboard focus walks the whole rail before it moves on to the page.
    return FocusTraversalGroup(
      child: GestureDetector(
        // Swipe the rail towards its edge to hide it (to the left; to the
        // right in a right-to-left language, where the rail is on the right).
        onHorizontalDragEnd: (DragEndDetails d) {
          final double v = d.primaryVelocity ?? 0;
          final bool rtl = Directionality.of(context) == TextDirection.rtl;
          if (rtl ? v > 200 : v < -200) {
            onHide();
          }
        },
        child: Container(
          key: const Key('side-tabs'),
          width: _railWidth,
          decoration: ZenLook.of(context).railDecoration(zen),
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints c) {
              // Every button fits on screen: on a short phone they get
              // slimmer (down to a still comfortable tap target) instead of
              // the last ones sliding out of sight. The open tab is taller by
              // its label, each group by its line.
              final double extent =
                  ((c.maxHeight -
                              _railTopGap -
                              _railBottomGap -
                              _sideTabLabelExtent -
                              groups * _railGroupGap) /
                          shown.length)
                      .clamp(_sideTabMinExtent, _sideTabMaxExtent);
              final List<Widget> top = <Widget>[];
              _RailGroup? group;
              for (final int i in shown) {
                final _ShellTab tab = _shellTabs[i];
                if (tab.group == null) {
                  continue;
                }
                if (tab.group != group) {
                  group = tab.group;
                  top.add(_RailGroupLine(group: group!));
                }
                top.add(button(i, extent));
              }
              return SingleChildScrollView(
                key: const Key('side-tabs-scroll'),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: c.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: <Widget>[
                        const SizedBox(height: _railTopGap),
                        ...top,
                        const Spacer(),
                        for (final int i in shown)
                          if (_shellTabs[i].group == null) button(i, extent),
                        const SizedBox(height: _railBottomGap),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// The thin line in a group's hue that opens it on the rail.
class _RailGroupLine extends StatelessWidget {
  const _RailGroupLine({required this.group});

  final _RailGroup group;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return SizedBox(
      key: Key('side-tabs-group-${group.name}'),
      height: _railGroupGap,
      child: Center(
        child: Container(
          width: 24,
          height: 2,
          decoration: BoxDecoration(
            color: group.hue(zen).withValues(alpha: 0.55),
            borderRadius: ZenLook.of(context).br(1),
          ),
        ),
      ),
    );
  }
}

/// Icons only; the open tab also shows its short name under the icon, and
/// every button has its full name as a tooltip.
class _SideTabButton extends StatelessWidget {
  const _SideTabButton({
    required this.tab,
    required this.selected,
    required this.badge,
    required this.onTap,
    this.extent = _sideTabMaxExtent,
    this.danger = false,
    this.hue,
  });

  final _ShellTab tab;
  final bool selected;
  final int badge;
  final VoidCallback onTap;

  /// Height of the whole button, outer gap included (without the label).
  final double extent;

  /// The alarm: always red.
  final bool danger;

  /// The group's hue: the open tab's icon and name are drawn in it.
  final Color? hue;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color fg = danger
        ? zen.danger
        : selected
        ? hue ?? zen.accent
        : zen.textMuted;
    final bool compact = extent < 46;
    final double iconSize = compact ? 22 : 24;
    // Slim buttons keep almost the whole height tappable.
    final double gap = compact ? 1 : 3;
    // extent = 2 × gap + 2 × 1 border + 2 × padding + icon.
    final double padding = ((extent - 2 * gap - 2 - iconSize) / 2).clamp(
      2.0,
      11.0,
    );
    final Widget icon =
        tab.glyph?.call(fg, iconSize, selected) ??
        Icon(selected ? tab.selectedIcon : tab.icon, color: fg, size: iconSize);
    return Semantics(
      selected: selected,
      button: true,
      label: badge > 0
          ? t('{label}, nieprzeczytane: {n}', {
              'label': tab.fullLabel,
              'n': badge > 99 ? '99+' : badge,
            })
          : tab.fullLabel,
      child: Tooltip(
        message: tab.fullLabel,
        excludeFromSemantics: true,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 6, vertical: gap),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: Key('side-tab-${tab.id}'),
              borderRadius: ZenLook.of(context).br(14),
              onTap: onTap,
              child: ZenRailTabFrame(
                selected: selected,
                danger: danger,
                padding: EdgeInsets.symmetric(vertical: padding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Center(
                      child: Badge(
                        isLabelVisible: badge > 0,
                        label: Text(badge > 99 ? '99+' : '$badge'),
                        child: icon,
                      ),
                    ),
                    if (selected)
                      // The name scales down rather than being cut: the
                      // rail is narrow and some languages are long.
                      SizedBox(
                        key: Key('side-tab-label-${tab.id}'),
                        height: _sideTabLabelExtent,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: ExcludeSemantics(
                              child: Text(
                                tab.label,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  color: fg,
                                  fontSize: 10,
                                  height: 1.2,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
