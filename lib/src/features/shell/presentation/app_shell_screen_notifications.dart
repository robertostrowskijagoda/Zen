part of 'app_shell_screen.dart';

// The in-app notification list: the bell in the top bar with its counter,
// and the page it opens. It gathers what used to sit in the banner on the
// chats list (background alerts), the inbox entries and the reactions under
// your own posts, newest first, a day at a time.

/// What kind of event a row tells about (only for the order of the code
/// that builds the rows; the icon comes from the entry's own type).
enum _NoticeKind { message, call, invitation, alert, reaction }

@immutable
final class _NoticeItem {
  const _NoticeItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.millis,
    this.routeKey,
    this.entry,
    this.reaction,
    this.ids = const <String>[],
  });

  /// The row of one inbox entry; [ids] are the entries it stands for (the
  /// older messages of the same chat are folded into the newest one).
  factory _NoticeItem.ofEntry(InboxEntry entry, List<String> ids) {
    return _NoticeItem(
      id: entry.id,
      kind: switch (entry.type) {
        InboxEntryType.message => _NoticeKind.message,
        InboxEntryType.callInvite => _NoticeKind.call,
        InboxEntryType.friendRequest ||
        InboxEntryType.groupInvite => _NoticeKind.invitation,
        _ => _NoticeKind.alert,
      },
      title: entry.displayTitle,
      body: entry.displayBody,
      millis: entry.createdAtMillis,
      routeKey: entry.routeKey,
      entry: entry,
      ids: ids,
    );
  }

  /// The row of the new reactions under one of your posts.
  factory _NoticeItem.ofReaction(ReactionNotice notice, int millis) {
    final String likes = noticeLikesText(notice);
    final String comments = noticeCommentsText(notice);
    return _NoticeItem(
      id: 'reaction-${notice.postId}',
      kind: _NoticeKind.reaction,
      title: likes.isNotEmpty ? likes : comments,
      body: likes.isNotEmpty ? comments : '',
      millis: millis,
      // A tap opens the Tablica, where the post and its reactions are.
      routeKey: buildFeedRouteKey(FeedFilter.all.name),
      reaction: notice,
    );
  }

  final String id;
  final _NoticeKind kind;
  final String title;
  final String body;
  final int millis;
  final String? routeKey;
  final InboxEntry? entry;
  final ReactionNotice? reaction;

  /// Every inbox entry that goes away with this row.
  final List<String> ids;

  IconData get icon {
    final InboxEntry? source = entry;
    if (source != null) {
      return _inboxIcon(source.type);
    }
    return (reaction?.likes ?? 0) > 0
        ? Icons.favorite_rounded
        : Icons.mode_comment_rounded;
  }

  Color tone(ZenColors zen) {
    final InboxEntry? source = entry;
    if (source != null) {
      return _inboxTone(zen, source.type);
    }
    return (reaction?.likes ?? 0) > 0 ? zen.danger : zen.accent;
  }
}

/// The inbox entries and background alerts worth a row, newest first.
///
/// A chat message only counts while its chat still has something unread (a
/// read one is not news any more), and a chat is one row however many
/// messages it sent. Entries with nowhere to go (receipts and the like) have
/// no row at all.
List<_NoticeItem> _noticeItemsOf(SocialHubState hub) {
  final Set<String> seenIds = <String>{};
  final Map<String, InboxEntry> newestOfChat = <String, InboxEntry>{};
  final Map<String, List<String>> idsOfChat = <String, List<String>>{};
  final List<_NoticeItem> items = <_NoticeItem>[];
  for (final InboxEntry entry in <InboxEntry>[
    ...hub.backgroundAlerts,
    ...hub.inbox,
  ]) {
    if (!seenIds.add(entry.id)) {
      continue;
    }
    if (entry.type != InboxEntryType.message) {
      items.add(_NoticeItem.ofEntry(entry, <String>[entry.id]));
      continue;
    }
    if (entry.routeKey == null || _chatIsRead(hub, entry)) {
      continue;
    }
    final String chat = entry.routeKey!;
    idsOfChat.putIfAbsent(chat, () => <String>[]).add(entry.id);
    final InboxEntry? known = newestOfChat[chat];
    if (known == null || entry.createdAtMillis > known.createdAtMillis) {
      newestOfChat[chat] = entry;
    }
  }
  for (final MapEntry<String, InboxEntry> chat in newestOfChat.entries) {
    items.add(_NoticeItem.ofEntry(chat.value, idsOfChat[chat.key]!));
  }
  items.sort((_NoticeItem a, _NoticeItem b) => b.millis.compareTo(a.millis));
  return items;
}

/// Whether the chat [entry] came from has nothing unread any more.
bool _chatIsRead(SocialHubState hub, InboxEntry entry) {
  final RuntimeRouteIntent? intent = runtimeRouteIntentFromRouteKey(
    id: entry.id,
    routeKey: entry.routeKey,
  );
  final String? peer = intent?.peerAddress;
  if (intent == null || peer == null) {
    return false;
  }
  return switch (intent.target) {
    RuntimeRouteTarget.conversation =>
      (hub.friendByAddress(peer)?.unreadCount ?? 1) == 0,
    RuntimeRouteTarget.groupConversation =>
      (hub.groups[intent.groupId ?? peer]?.unreadCount ?? 1) == 0,
    _ => false,
  };
}

/// "Powiadomienia" in the top bar: a bell with how many entries are new since
/// the list was last opened.
class _NoticesBell extends ConsumerWidget {
  const _NoticesBell();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ZenColors zen = ZenColors.of(context);
    final int seen = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.notificationsSeenMillis,
      ),
    );
    final int entries = ref.watch(
      socialHubControllerProvider.select(
        (SocialHubState s) => _noticeItemsOf(
          s,
        ).where((_NoticeItem item) => item.millis > seen).length,
      ),
    );
    final ReactionNoticesFeed? reactions = ref.watch(reactionNoticesProvider);
    Widget bell(int reactionCount) {
      final int count = entries + reactionCount;
      return IconButton(
        key: const Key('status-notices'),
        // The tooltip is also what a screen reader says: with the count.
        tooltip: count > 0
            ? tn(
                count,
                one: 'Powiadomienia: {n} nowe',
                few: 'Powiadomienia: {n} nowe',
                many: 'Powiadomienia: {n} nowych',
              )
            : t('Powiadomienia'),
        visualDensity: VisualDensity.standard,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        onPressed: () => unawaited(_openNotifications(context)),
        icon: Badge(
          isLabelVisible: count > 0,
          label: Text(
            count > 99 ? '99+' : '$count',
            key: const Key('status-notices-count'),
          ),
          child: Icon(
            count > 0
                ? Icons.notifications_active_rounded
                : Icons.notifications_none_rounded,
            size: 20,
            color: count > 0 ? zen.textPrimary : zen.textSecondary,
          ),
        ),
      );
    }

    if (reactions == null) {
      return bell(0);
    }
    return ListenableBuilder(
      listenable: reactions,
      builder: (BuildContext context, Widget? _) =>
          bell(reactions.notices.length),
    );
  }
}

Future<void> _openNotifications(BuildContext context) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => const _NotificationsScreen(),
    ),
  );
}

/// The full list: a day at a time (a day folds away), a row per event with
/// its icon, text and time. A tap opens what it is about, a swipe or the
/// cross removes it. Opening the page marks everything as seen; what was new
/// stays marked until the page is closed.
class _NotificationsScreen extends ConsumerStatefulWidget {
  const _NotificationsScreen();

  @override
  ConsumerState<_NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<_NotificationsScreen> {
  late final int _seenBefore;
  late final int _openedAtMillis;
  List<ReactionNotice> _reactions = const <ReactionNotice>[];

  /// Rows already removed (the swipe needs them gone at once, the state of
  /// the inbox follows a moment later).
  final Set<String> _gone = <String>{};
  final Set<String> _folded = <String>{};
  int _markedUpTo = 0;

  /// Removals still to be taken back with "Cofnij": the rows are hidden at
  /// once, the inbox follows when the time is up (or the page closes).
  final List<_PendingRemoval> _pending = <_PendingRemoval>[];
  late final SocialHubController _hub;

  /// How long "Cofnij" stays.
  static const Duration _undoFor = Duration(seconds: 5);

  @override
  void initState() {
    super.initState();
    _hub = ref.read(socialHubControllerProvider.notifier);
    _seenBefore = ref
        .read(appSettingsControllerProvider)
        .notificationsSeenMillis;
    _openedAtMillis = DateTime.now().millisecondsSinceEpoch;
    _markedUpTo = _seenBefore;
    // Reactions are a digest, not a log: they are taken now and then count
    // as seen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      final ReactionNoticesFeed? feed = ref.read(reactionNoticesProvider);
      if (feed != null) {
        setState(() => _reactions = feed.markSeen());
      }
    });
  }

  /// Marks the newest entry shown as seen (also for ones that arrive while
  /// the page is open).
  void _markSeen(int newest) {
    if (newest <= _markedUpTo) {
      return;
    }
    _markedUpTo = newest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      unawaited(
        ref
            .read(appSettingsControllerProvider.notifier)
            .markNotificationsSeen(newest),
      );
    });
  }

  void _open(_NoticeItem item) {
    final NavigatorState navigator = Navigator.of(context);
    final SocialHubController hub = ref.read(
      socialHubControllerProvider.notifier,
    );
    final String? routeKey = item.routeKey;
    navigator.pop();
    if (routeKey != null) {
      unawaited(hub.requestLaunchFromRouteKey(routeKey));
    }
  }

  @override
  void dispose() {
    // What was not taken back goes now.
    for (final _PendingRemoval removal in List<_PendingRemoval>.of(_pending)) {
      _commit(removal);
    }
    super.dispose();
  }

  void _dismiss(_NoticeItem item) {
    _removeWithUndo(<_NoticeItem>[item], t('Usunięto powiadomienie'));
  }

  void _clearAll(List<_NoticeItem> items) {
    _removeWithUndo(items, t('Wyczyszczono powiadomienia'), everything: true);
  }

  /// Hides [items] and offers "Cofnij" for a few seconds; the inbox is
  /// changed only after that.
  void _removeWithUndo(
    List<_NoticeItem> items,
    String message, {
    bool everything = false,
  }) {
    final _PendingRemoval removal = _PendingRemoval(
      items,
      everything: everything,
    );
    removal.timer = Timer(_undoFor, () => _commit(removal));
    _pending.add(removal);
    setState(() {
      for (final _NoticeItem item in items) {
        _gone.addAll(<String>[item.id, ...item.ids]);
      }
    });
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('notifications-undo'),
          content: Text(message),
          duration: _undoFor,
          action: SnackBarAction(
            key: const Key('notifications-undo-action'),
            label: t('Cofnij'),
            onPressed: () => _undo(removal),
          ),
        ),
      );
  }

  void _undo(_PendingRemoval removal) {
    if (!_pending.remove(removal)) {
      return;
    }
    removal.timer?.cancel();
    if (!mounted) {
      return;
    }
    setState(() {
      for (final _NoticeItem item in removal.items) {
        _gone.removeAll(<String>[item.id, ...item.ids]);
      }
    });
  }

  void _commit(_PendingRemoval removal) {
    if (!_pending.remove(removal)) {
      return;
    }
    removal.timer?.cancel();
    if (removal.everything) {
      // (The page may close with the app: no hub to tell then.)
      unawaited(_hub.clearInbox().catchError((Object _) {}));
      return;
    }
    for (final _NoticeItem item in removal.items) {
      for (final String id in item.ids) {
        unawaited(_hub.dismissInboxEntry(id).catchError((Object _) {}));
      }
    }
  }

  /// What a swiped row uncovers: shaped like the row's panel.
  Widget _swipeBackground(
    BuildContext context,
    ZenColors zen,
    AlignmentGeometry alignment,
  ) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: zen.surfaceSunk,
        borderRadius: context.zenRadius(22),
      ),
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Icon(Icons.delete_outline_rounded, color: zen.textMuted),
        ),
      ),
    );
  }

  static String _dayKey(DateTime day) => '${day.year}-${day.month}-${day.day}';

  String _dayLabel(DateTime day) {
    final DateTime now = DateTime.now();
    final int diff = DateTime(
      now.year,
      now.month,
      now.day,
    ).difference(DateTime(day.year, day.month, day.day)).inDays;
    if (diff == 0) {
      return t('Dziś');
    }
    if (diff == 1) {
      return t('Wczoraj');
    }
    return ZenFormat.date(day);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState hub = ref.watch(socialHubControllerProvider);
    final List<_NoticeItem> items =
        <_NoticeItem>[
          ..._noticeItemsOf(hub),
          for (final ReactionNotice n in _reactions)
            _NoticeItem.ofReaction(n, _openedAtMillis),
        ].where((_NoticeItem item) => !_gone.contains(item.id)).toList()..sort(
          (_NoticeItem a, _NoticeItem b) => b.millis.compareTo(a.millis),
        );
    if (items.isNotEmpty) {
      _markSeen(
        items
            .where((_NoticeItem i) => i.kind != _NoticeKind.reaction)
            .fold<int>(
              0,
              (int m, _NoticeItem i) => i.millis > m ? i.millis : m,
            ),
      );
    }
    // The rows of one day, in the order of the days.
    final Map<String, List<_NoticeItem>> days = <String, List<_NoticeItem>>{};
    for (final _NoticeItem item in items) {
      days
          .putIfAbsent(
            _dayKey(DateTime.fromMillisecondsSinceEpoch(item.millis)),
            () => <_NoticeItem>[],
          )
          .add(item);
    }
    return Scaffold(
      key: const Key('notifications-screen'),
      appBar: ZenSectionBar(title: t('Powiadomienia')),
      body: SecureScreen(
        child: SafeArea(
          top: false,
          child: items.isEmpty
              ? ZenEmpty(
                  icon: Icons.notifications_none_rounded,
                  title: t('Brak powiadomień'),
                  text: t(
                    'Nowe wiadomości, zaproszenia i reakcje pojawią się tutaj.',
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                  children: <Widget>[
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        key: const Key('notifications-clear-all'),
                        onPressed: () => _clearAll(items),
                        icon: const Icon(Icons.clear_all_rounded, size: 18),
                        label: Text(t('Wyczyść wszystko')),
                      ),
                    ),
                    for (final MapEntry<String, List<_NoticeItem>> day
                        in days.entries) ...<Widget>[
                      _NoticeDayHeader(
                        key: Key('notice-day-${day.key}'),
                        label: _dayLabel(
                          DateTime.fromMillisecondsSinceEpoch(
                            day.value.first.millis,
                          ),
                        ),
                        count: day.value.length,
                        folded: _folded.contains(day.key),
                        onTap: () => setState(() {
                          if (!_folded.remove(day.key)) {
                            _folded.add(day.key);
                          }
                        }),
                      ),
                      if (!_folded.contains(day.key))
                        for (final _NoticeItem item in day.value)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Dismissible(
                              key: Key('notice-${item.id}'),
                              onDismissed: (_) => _dismiss(item),
                              background: _swipeBackground(
                                context,
                                zen,
                                AlignmentDirectional.centerStart,
                              ),
                              secondaryBackground: _swipeBackground(
                                context,
                                zen,
                                AlignmentDirectional.centerEnd,
                              ),
                              child: _NoticeRow(
                                item: item,
                                // Reactions are a digest taken when the page
                                // opens: no real time, nothing "new".
                                isNew:
                                    item.reaction == null &&
                                    item.millis > _seenBefore,
                                onTap: () => _open(item),
                                onDismiss: () => _dismiss(item),
                              ),
                            ),
                          ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }
}

/// Rows removed from the list that "Cofnij" can still bring back.
class _PendingRemoval {
  _PendingRemoval(this.items, {required this.everything});

  final List<_NoticeItem> items;

  /// "Wyczyść wszystko": the inbox is cleared as a whole.
  final bool everything;
  Timer? timer;
}

class _NoticeDayHeader extends StatelessWidget {
  const _NoticeDayHeader({
    required this.label,
    required this.count,
    required this.folded,
    required this.onTap,
    super.key,
  });

  final String label;
  final int count;
  final bool folded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Semantics(
      button: true,
      expanded: !folded,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '$label ($count)',
                  style: zen.label(color: zen.textSecondary),
                ),
              ),
              Icon(
                folded ? Icons.expand_more_rounded : Icons.expand_less_rounded,
                size: 20,
                color: zen.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeRow extends StatelessWidget {
  const _NoticeRow({
    required this.item,
    required this.isNew,
    required this.onTap,
    required this.onDismiss,
  });

  final _NoticeItem item;
  final bool isNew;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = item.tone(zen);
    return _Panel(
      key: Key('notice-row-${item.id}'),
      accentTone: tone,
      onTap: onTap,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ZenIconBadge(icon: item.icon, tone: tone, size: 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textPrimary,
                      fontSize: 14.5,
                      fontWeight: isNew ? FontWeight.w800 : FontWeight.w600,
                      height: 1.25,
                    ),
                  ),
                ),
                if (item.body.trim().isNotEmpty) ...<Widget>[
                  const SizedBox(height: 3),
                  Text(
                    item.body,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: zen.textSecondary,
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
                // A reaction row has no time of its own (the digest knows
                // only when the post was written).
                if (item.reaction == null) ...<Widget>[
                  const SizedBox(height: 4),
                  Text(
                    ZenFormat.time(
                      DateTime.fromMillisecondsSinceEpoch(item.millis),
                    ),
                    style: zen.mono(color: zen.textMuted, size: 10.5),
                  ),
                ],
              ],
            ),
          ),
          if (isNew)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 6, end: 4),
              child: Container(
                key: Key('notice-new-${item.id}'),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: zen.accent,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          SizedBox(
            width: 44,
            height: 44,
            child: IconButton(
              key: Key('notice-dismiss-${item.id}'),
              tooltip: t('Usuń powiadomienie'),
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.standard,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              iconSize: 18,
              color: zen.textMuted,
              icon: const Icon(Icons.close_rounded),
              onPressed: onDismiss,
            ),
          ),
        ],
      ),
    );
  }
}
