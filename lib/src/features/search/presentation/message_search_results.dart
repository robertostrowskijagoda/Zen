import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/groups/group_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/chat/message_timeline_store.dart';
import 'package:zen/src/features/chat/presentation/conversation_screen.dart';
import 'package:zen/src/features/chat/stranger_chats.dart';
import 'package:zen/src/features/groups/presentation/group_conversation_screen.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/search/global_message_search.dart';
import 'package:zen/src/features/search/presentation/search_highlight.dart';
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The conversations whose messages the search on the chat list reads:
/// friends (also invitations both ways), groups the person is in, and
/// conversations with people who are not friends. Blocked people's are
/// left out, as on the chat list.
List<SearchConversation> searchableConversations(
  SocialHubState hub, {
  List<StrangerChat> strangers = const <StrangerChat>[],
}) {
  final List<SearchConversation> out = <SearchConversation>[];
  final Set<String> friends = <String>{};
  for (final FriendProfile f in hub.friends.values) {
    friends.add(PeerShareCodec.normalizeAddress(f.address));
    if (f.status == FriendRelationshipStatus.blocked ||
        f.status == FriendRelationshipStatus.none) {
      continue;
    }
    out.add(SearchConversation.peer(address: f.address, title: hub.nameFor(f)));
  }
  for (final GroupProfile g in hub.groupList) {
    out.add(
      SearchConversation.group(
        groupId: g.id,
        title: g.name.trim().isEmpty ? t('Grupa') : g.name.trim(),
      ),
    );
  }
  for (final StrangerChat s in strangers) {
    if (friends.contains(PeerShareCodec.normalizeAddress(s.address))) {
      continue;
    }
    out.add(
      SearchConversation.peer(
        address: s.address,
        title: s.shownName,
        lastAtMillis: s.lastAt,
      ),
    );
  }
  return out;
}

/// Opens [conversation] at the message [messageId] (the newest match when
/// `null`) with its own search showing [query].
Future<void> openSearchResult(
  BuildContext context, {
  required SearchConversation conversation,
  required String query,
  String? messageId,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (BuildContext context) => conversation.isGroup
        ? GroupConversationScreen(
            groupId: conversation.id,
            groupName: conversation.title,
            initialMessageId: messageId,
            searchText: query,
          )
        : ConversationScreen(
            peerAddress: conversation.id,
            title: conversation.title,
            initialMessageId: messageId,
            searchText: query,
          ),
  ),
);

/// Messages of every conversation that match [query], for the chat list:
/// grouped by conversation (the one with the newest match first), the
/// newest matches of each with the words marked. A tap opens the
/// conversation at that message.
///
/// The conversations are read when a query long enough is first typed and
/// kept, folded, in memory until the field is cleared or the list closed;
/// a change in any conversation has them read again. Nothing typed here
/// leaves the device or is written down.
class MessageSearchResults extends ConsumerStatefulWidget {
  const MessageSearchResults({
    required this.query,
    this.padding = const EdgeInsets.symmetric(horizontal: 16),
    super.key,
  });

  /// What is in the chat list's search field.
  final String query;
  final EdgeInsetsGeometry padding;

  @override
  ConsumerState<MessageSearchResults> createState() =>
      _MessageSearchResultsState();
}

class _MessageSearchResultsState extends ConsumerState<MessageSearchResults> {
  static const Duration _debounce = Duration(milliseconds: 250);

  /// While conversations are read, results are put together again at most
  /// this often.
  static const Duration _refreshWhileReading = Duration(milliseconds: 300);

  /// A conversation changed: read again after this pause.
  static const Duration _reloadAfterChange = Duration(seconds: 3);

  GlobalMessageSearch? _search;
  SearchQuery _query = SearchQuery.empty;
  List<GlobalSearchGroup> _groups = const <GlobalSearchGroup>[];
  bool _loading = false;
  double _progress = 0;
  Timer? _typing;
  Timer? _reload;
  DateTime _lastRefresh = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _query = SearchQuery.parse(widget.query);
    if (_query.searchesMessages) {
      _typing = Timer(Duration.zero, _run);
    }
  }

  @override
  void didUpdateWidget(MessageSearchResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query == widget.query) {
      return;
    }
    final SearchQuery next = SearchQuery.parse(widget.query);
    if (next == _query) {
      return;
    }
    _query = next;
    _typing?.cancel();
    if (!next.searchesMessages) {
      // Cleared (or one letter): what was read is forgotten.
      _drop();
      return;
    }
    _typing = Timer(_debounce, _run);
  }

  @override
  void dispose() {
    _typing?.cancel();
    _reload?.cancel();
    _search?.dispose();
    super.dispose();
  }

  void _drop() {
    _reload?.cancel();
    _search?.dispose();
    _search = null;
    _groups = const <GlobalSearchGroup>[];
    _loading = false;
  }

  Future<void> _run() async {
    if (!mounted || !_query.searchesMessages) {
      return;
    }
    if (_search != null) {
      setState(() => _groups = _search!.search(_query));
      return;
    }
    await _load();
  }

  Future<void> _load() async {
    _search?.dispose();
    final HiddenByMe hidden = ref.read(hiddenByMeProvider);
    final GlobalMessageSearch search = GlobalMessageSearch(
      store: ref.read(messageTimelineStoreProvider),
      hidden: (ChatMessage m) => hidden.hides(id: m.id),
    );
    _search = search;
    List<StrangerChat> strangers = const <StrangerChat>[];
    try {
      final StrangerChatBook book = ref.read(strangerChatsProvider);
      await book.load();
      strangers = <StrangerChat>[...book.requests, ...book.conversations];
    } on Object catch (error, stack) {
      // Friends' and groups' messages are still searched.
      logZenError('Wyszukiwanie: rozmowy z nieznajomymi', error, stack);
    }
    if (!mounted || !identical(_search, search)) {
      return;
    }
    final List<SearchConversation> conversations = searchableConversations(
      ref.read(socialHubControllerProvider),
      strangers: strangers,
    );
    setState(() {
      _loading = true;
      _progress = 0;
    });
    await search.load(
      conversations,
      onProgress: () {
        if (!mounted || !identical(_search, search)) {
          return;
        }
        final DateTime now = DateTime.now();
        if (now.difference(_lastRefresh) < _refreshWhileReading) {
          return;
        }
        _lastRefresh = now;
        setState(() {
          _progress = search.progress;
          _groups = search.search(_query);
        });
      },
    );
    if (!mounted || !identical(_search, search)) {
      return;
    }
    setState(() {
      _loading = false;
      _progress = 1;
      _groups = search.search(_query);
    });
  }

  /// A message came, went or changed somewhere: the open results are read
  /// again once things are quiet.
  void _changed() {
    if (_search == null) {
      return;
    }
    _reload?.cancel();
    _reload = Timer(_reloadAfterChange, () {
      if (mounted && _query.searchesMessages) {
        unawaited(_load());
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(messageTimelineRevisionProvider, (_, _) => _changed());
    if (!_query.searchesMessages) {
      return const SizedBox.shrink();
    }
    final ZenColors zen = ZenColors.of(context);
    final bool waiting = _typing?.isActive ?? false;
    return Padding(
      key: const Key('message-search-results'),
      padding: widget.padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ZenSection(t('Wiadomości'), top: 12),
          if (_loading)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Semantics(
                label: t('Przeszukuję rozmowy'),
                child: LinearProgressIndicator(
                  value: _progress <= 0 ? null : _progress,
                  minHeight: 3,
                ),
              ),
            ),
          if (_groups.isEmpty && !_loading && !waiting)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                t('Nie znaleziono wiadomości z „{query}”.', {
                  'query': widget.query.trim(),
                }),
                key: const Key('message-search-empty'),
                style: TextStyle(color: zen.textSecondary),
              ),
            ),
          for (final GlobalSearchGroup group in _groups)
            _ResultGroup(
              key: ValueKey<String>(
                'message-search-${group.conversation.storeKey}',
              ),
              group: group,
              onOpen: (String? messageId) => unawaited(
                openSearchResult(
                  context,
                  conversation: group.conversation,
                  query: widget.query.trim(),
                  messageId: messageId,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One conversation's results: its name, how many messages match, the
/// newest of them, and a way to all of them in the conversation.
class _ResultGroup extends StatelessWidget {
  const _ResultGroup({required this.group, required this.onOpen, super.key});

  final GlobalSearchGroup group;
  final ValueChanged<String?> onOpen;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final SearchConversation c = group.conversation;
    final TextStyle mark = searchMarkStyle(context);
    final String count = tn(
      group.total,
      one: '{n} wiadomość',
      few: '{n} wiadomości',
      many: '{n} wiadomości',
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: zen.surfaceRaised,
          borderRadius: context.zenRadius(16),
          border: Border.all(color: zen.outlineSoft),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
              child: Row(
                children: <Widget>[
                  ExcludeSemantics(
                    child: c.isGroup
                        ? const ZenIconBadge(
                            icon: Icons.groups_rounded,
                            size: 32,
                          )
                        : PeerAvatar(
                            address: c.id,
                            name: c.title,
                            size: 32,
                            showStatus: false,
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        c.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      count,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(color: zen.textMuted, fontSize: 12.5),
                    ),
                  ),
                ],
              ),
            ),
            for (final GlobalSearchHit hit in group.hits)
              _HitTile(
                key: ValueKey<String>('message-search-hit-${hit.messageId}'),
                hit: hit,
                mark: mark,
                onTap: () => onOpen(hit.messageId),
              ),
            if (group.total > group.hits.length)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: TextButton(
                    key: ValueKey<String>('message-search-all-${c.storeKey}'),
                    onPressed: () => onOpen(
                      group.hits.isEmpty ? null : group.hits.first.messageId,
                    ),
                    child: Text(
                      t('Wszystkie w rozmowie ({count})', {
                        'count': group.total,
                      }),
                    ),
                  ),
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

class _HitTile extends StatelessWidget {
  const _HitTile({
    required this.hit,
    required this.mark,
    required this.onTap,
    super.key,
  });

  final GlobalSearchHit hit;
  final TextStyle mark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(hit.sentAtMillis);
    final String when = ZenFormat.dayMonthTime(at);
    return MergeSemantics(
      child: Semantics(
        button: true,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 12, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text.rich(
                  TextSpan(
                    style: TextStyle(color: zen.textPrimary, height: 1.35),
                    children: searchMarkedSpans(hit.snippet, hit.ranges, mark),
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  when,
                  style: TextStyle(color: zen.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
