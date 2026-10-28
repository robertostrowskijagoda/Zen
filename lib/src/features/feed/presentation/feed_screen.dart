import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/features/chat/presentation/animated_gif.dart';
import 'package:zen/src/features/chat/presentation/copyable_text.dart';
import 'package:zen/src/features/feed/comment_media.dart';
import 'package:zen/src/features/feed/feed_filter.dart';
import 'package:zen/src/features/feed/feed_items.dart';
import 'package:zen/src/features/feed/feed_memo.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/feed_search.dart';
import 'package:zen/src/features/feed/mini_profile_tag.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/post_mentions.dart';
import 'package:zen/src/features/feed/post_reach.dart';
import 'package:zen/src/features/feed/post_reach_service.dart';
import 'package:zen/src/features/feed/presentation/comment_composer.dart';
import 'package:zen/src/features/feed/presentation/comment_pictures.dart';
import 'package:zen/src/features/feed/presentation/mutual_friends.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart';
import 'package:zen/src/features/feed/presentation/post_reactions_sheet.dart';
import 'package:zen/src/features/feed/presentation/pyramid_feed_card.dart';
import 'package:zen/src/features/feed/presentation/rich_post_body.dart';
import 'package:zen/src/features/feed/presentation/video_autoplay.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/media/audio_clip_player.dart';
import 'package:zen/src/features/media/gif_files.dart';
import 'package:zen/src/features/media/media_stream_server.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/meet/meet_providers.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/local_delete.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/profile/follows.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/presentation/own_avatar.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/pyramid/pyramid_feed.dart';
import 'package:zen/src/features/pyramid/pyramid_service.dart'
    show PyramidService;
import 'package:zen/src/features/pyramid/pyramid_state.dart'
    show PyrMember, PyramidState;
import 'package:zen/src/features/search/search_text.dart';
import 'package:zen/src/features/settings/app_settings.dart';
import 'package:zen/src/features/settings/app_settings_controller.dart';
import 'package:zen/src/features/shell/composer_drafts.dart';
import 'package:zen/src/features/social/mentions.dart';
import 'package:zen/src/features/social/peer_share_codec.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';
import 'package:zen/src/features/sound/zen_sound_effects.dart';

/// The wall: posts of friends and followed people, newest first, and a
/// place to write. Your own posts are on your profile, not here.
/// Chronological, no algorithm, and it ends ("Jesteś na bieżąco").
/// The pyramid's posts live here too (and only here), made from its
/// records: chips „Wszystko · Znajomi · Piramida · Kraj” pick what shows.
class FeedScreen extends ConsumerStatefulWidget {
  const FeedScreen({this.pickPhotos, super.key});

  /// Overrides the photo picker of the post editor (tests).
  final PhotoSource? pickPhotos;

  @override
  ConsumerState<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends ConsumerState<FeedScreen> {
  StreamSubscription<LogEntry>? _updates;
  StreamSubscription<void>? _opened;

  /// The audience of the last post: the next one starts with it.
  /// New posts are public unless the user picks otherwise.
  Audience _audience = Audience.public;
  StreamSubscription<String>? _media;
  LedgerNode? _node;
  final ReshareCache _reshares = ReshareCache();

  /// Posts passed on beyond friends: what is fetched shows on the wall, as
  /// far as the user looks ([PostReachService.depth]).
  PostReachService? _reach;
  StreamSubscription<void>? _reachChanges;
  String? _error;

  /// Bumped whenever something [buildFeed] reads may have changed (the
  /// ledger, bodies that became readable, checked reshares): [build] walks
  /// every log again only then, not on every presence change or tap.
  int _feedRevision = 0;
  StreamSubscription<void>? _storeChanges;
  final FeedMemo _feedMemo = FeedMemo();

  /// Posts hidden by a pyramid content ban that the user chose to see.
  final Set<String> _revealed = <String>{};

  /// The pyramid whose bans and posts this screen follows (once it runs).
  PyramidService? _pyramid;

  /// The chip on: the last one picked, kept on the device.
  FeedFilter _filter = FeedFilter.all;

  /// A filter was picked (or asked for) before the stored one was read.
  bool _filterPicked = false;

  /// The post a notification asked to show ([feedPostRequest]), until its
  /// card is on screen; the card wears [_revealKey] meanwhile.
  String? _revealId;
  final GlobalKey _revealKey = GlobalKey(debugLabel: 'feed-reveal');
  final ScrollController _scroll = ScrollController();

  /// The ids of what the wall shows, as last built.
  List<String> _shownIds = const <String>[];

  /// The search field over the wall is open: only posts with the words
  /// typed (in the text, the author's name or a comment) are shown.
  bool _searching = false;
  final TextEditingController _searchText = TextEditingController();

  static const String _filterKey = 'ui/feed_filter';

  @override
  void initState() {
    super.initState();
    _node = ref.read(ledgerNodeProvider);
    _reach = ref.read(postReachProvider);
    // Asked for before this screen was first built.
    final FeedFilter? asked = feedFilterRequest.value;
    if (asked != null) {
      feedFilterRequest.value = null;
      _filterPicked = true;
      _filter = asked;
      _lookAsFar(asked);
    }
    feedFilterRequest.addListener(_onFilterRequest);
    // Asked for before this screen was first built, too.
    _onPostRequest(initial: true);
    feedPostRequest.addListener(_onPostRequest);
    unawaited(
      ref
          .read(ledgerDiskProvider)
          .read(_filterKey)
          .then((Uint8List? raw) {
            if (mounted &&
                !_filterPicked &&
                raw != null &&
                raw.isNotEmpty &&
                raw.first < FeedFilter.values.length) {
              setState(() => _filter = FeedFilter.values[raw.first]);
            }
          })
          .catchError((Object _) {}),
    );
    _reachChanges = _reach?.changes.listen((_) {
      _feedRevision++;
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(_reach?.start());
    _media = _node?.mediaCompleted.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    _opened = _node?.openedChanges.listen((_) {
      _feedRevision++;
      if (mounted) {
        setState(() {});
      }
    });
    // Every change of the ledger (entries added or dropped, blocks).
    _storeChanges = _node?.store.changed.listen((_) => _feedRevision++);
    _updates = _node?.store.added.listen((LogEntry e) {
      _feedRevision++;
      if (e.kind == kReshareKind || e.kind == kReshareDeleteKind) {
        unawaited(_checkReshares());
      }
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(
      _node?.start().then((_) async {
        _feedRevision++;
        await _checkReshares();
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  @override
  void dispose() {
    feedFilterRequest.removeListener(_onFilterRequest);
    feedPostRequest.removeListener(_onPostRequest);
    _scroll.dispose();
    _searchText.dispose();
    _pyramid?.removeListener(_onPyramid);
    unawaited(_updates?.cancel());
    unawaited(_storeChanges?.cancel());
    unawaited(_opened?.cancel());
    unawaited(_media?.cancel());
    unawaited(_reachChanges?.cancel());
    super.dispose();
  }

  void _onPyramid() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Another part of the app asked for a filter ([openFeed]).
  void _onFilterRequest() {
    final FeedFilter? asked = feedFilterRequest.value;
    if (asked == null) {
      return;
    }
    feedFilterRequest.value = null;
    _pick(asked);
  }

  /// A new post's notification asked for a post ([openFeed]): a chip under
  /// which friends' posts show, then the post itself.
  void _onPostRequest({bool initial = false}) {
    final String? id = feedPostRequest.value;
    if (id == null) {
      return;
    }
    feedPostRequest.value = null;
    if (_filter == FeedFilter.pyramid ||
        _filter == FeedFilter.national ||
        _filter == FeedFilter.close) {
      if (initial) {
        _filterPicked = true;
        _filter = FeedFilter.all;
      } else {
        _pick(FeedFilter.all);
      }
    }
    _revealId = id;
    if (!initial && mounted) {
      setState(() {});
    }
    WidgetsBinding.instance
      ..addPostFrameCallback((_) => unawaited(_reveal(id)))
      ..ensureVisualUpdate();
  }

  /// Scrolls the wall until the card of post [id] is built, then brings it
  /// into view. Cards are built lazily, so it steps down a screen at a time
  /// from the top (a new post is near it); it gives up after a while.
  Future<void> _reveal(String id) async {
    for (int step = 0; step < 80 && mounted && _revealId == id; step++) {
      final BuildContext? card = _revealKey.currentContext;
      if (card != null && card.mounted) {
        _revealId = null;
        await Scrollable.ensureVisible(
          card,
          alignment: 0.05,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
        );
        return;
      }
      if (_scroll.hasClients && _shownIds.contains(id)) {
        final ScrollPosition position = _scroll.position;
        final double next = step == 0
            ? 0
            : math.min(
                position.pixels + position.viewportDimension * 0.8,
                position.maxScrollExtent,
              );
        if (step > 0 && next <= position.pixels) {
          break;
        }
        position.jumpTo(next);
      }
      await WidgetsBinding.instance.endOfFrame;
    }
    if (_revealId == id) {
      _revealId = null;
    }
  }

  /// The device addresses of the friend who wrote [post], when it is a
  /// friend's own post (not one's own, not a reshare, not from further
  /// away): their new posts can be muted.
  List<String> _friendAddressesOf(FeedPost post) {
    final LedgerNode? node = _node;
    if (node == null ||
        post.isOwn ||
        post.resharedBy.isNotEmpty ||
        post.degree != 1) {
      return const <String>[];
    }
    return <String>[
      for (final MapEntry<String, String> e in node.friendAccounts.entries)
        if (e.value == post.account) e.key,
    ];
  }

  /// "Wycisz posty tej osoby" and back.
  Future<void> _setPostsMuted(
    FeedPost post,
    List<String> addresses, {
    required bool muted,
  }) async {
    final AppSettingsController settings = ref.read(
      appSettingsControllerProvider.notifier,
    );
    // The global switch off leaves nothing to mute: say so.
    if (!ref.read(appSettingsControllerProvider).postNotifications) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            t(
              'Powiadomienia o nowych postach znajomych są wyłączone w '
              'Ustawieniach.',
            ),
          ),
        ),
      );
      return;
    }
    for (final String address in addresses) {
      await settings.setPostAuthorMuted(address, muted: muted);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            muted
                ? t(
                    'Bez powiadomień o nowych postach: {name}. Posty nadal są '
                    'na Tablicy.',
                    {'name': post.authorLabel},
                  )
                : t('Znów powiadomimy o nowych postach: {name}.', {
                    'name': post.authorLabel,
                  }),
          ),
        ),
      );
    }
  }

  void _pick(FeedFilter filter) {
    _filterPicked = true;
    _lookAsFar(filter);
    if (mounted && filter != _filter) {
      setState(() => _filter = filter);
    }
    unawaited(
      ref
          .read(ledgerDiskProvider)
          .write(_filterKey, Uint8List.fromList(<int>[filter.index]))
          .catchError((Object _) {}),
    );
  }

  /// „Znajomi”, „2. stopień” and „3. stopień” say how far the user looks:
  /// only posts that near are fetched and shown, „Wszystko” included.
  void _lookAsFar(FeedFilter filter) {
    final int? depth = filter.depth;
    if (depth != null) {
      unawaitedLogged(
        _reach?.setDepth(depth) ?? Future<void>.value(),
        context: 'Posty dalszych znajomych',
      );
    }
  }

  /// Follows the pyramid's decisions (content bans) once it is running.
  void _followPyramid() {
    final PyramidService? pyr = runningPyramid(ref);
    if (pyr != _pyramid) {
      _pyramid?.removeListener(_onPyramid);
      _pyramid = pyr;
      pyr?.addListener(_onPyramid);
    }
  }

  /// The author's device address: a friend's or a followed person's, or
  /// the one from their profile ('' when unknown).
  String _authorAddressOf(FeedPost post) {
    final LedgerNode? node = _node;
    if (node != null) {
      for (final MapEntry<String, String> e in <MapEntry<String, String>>[
        ...node.friendAccounts.entries,
        ...node.followedAccounts.entries,
      ]) {
        if (e.value == post.account) {
          return e.key;
        }
      }
    }
    return post.authorAddress;
  }

  /// "Zgłoś" on someone's post. Once reported it is hidden here;
  /// "Usuń z mojego urządzenia" takes its photos and films off the phone
  /// (the text is a signed ledger entry that cannot be deleted, only
  /// hidden).
  Future<void> _reportPost(FeedPost post) {
    final LedgerNode? node = _node;
    return reportContent(
      context,
      ref,
      authorAddress: _authorAddressOf(post),
      text: post.text,
      header: t('Post na tablicy — {name}', {'name': post.authorLabel}),
      contentId: post.id,
      // The signed post itself goes in as evidence.
      entry: post.entry,
      deleteLocal: node == null || post.images.isEmpty
          ? null
          : () => deletePostMediaLocally(node, post.images),
    );
  }

  Future<void> _compose({bool withPhotos = false}) async {
    if (_node == null) {
      return;
    }
    final LedgerNode node = _node!;
    // A post started earlier and not published comes back as it was left.
    final ComposerDrafts drafts = ref.read(composerDraftsProvider);
    await drafts.load();
    if (!mounted) {
      return;
    }
    final ComposerDraft? draft = drafts[ComposerDrafts.newPost];
    final bool published = await PostEditorScreen.open(
      context,
      onSubmit: _publish,
      // A new post may mention friends and their friends.
      mentionCandidates: () => postMentionCandidatesFor(ref, node),
      initialText: draft?.text ?? '',
      initialMentions: draft?.mentions ?? const <Mention>[],
      initialAudience:
          Audience.values.asNameMap()[draft?.audience] ?? _audience,
      pickPhotos: widget.pickPhotos,
      pickOnOpen: withPhotos,
      drafts: drafts,
    );
    if (published && mounted) {
      // Own posts live on the profile, not on the wall.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          key: const Key('feed-published'),
          content: Text(t('Opublikowano. Twoje posty są na Twoim profilu.')),
          // With an action a snack bar stays until dismissed by default.
          persist: false,
          action: SnackBarAction(
            key: const Key('feed-published-show'),
            label: t('Pokaż'),
            onPressed: () => unawaited(ProfileScreen.open(context)),
          ),
        ),
      );
    }
  }

  /// Publishes [draft]; returns an error, or null when done.
  Future<String?> _publish(PostDraft draft) async {
    final String? error = await publishDraft(ref, draft);
    if (error == null) {
      _audience = draft.audience;
      if (mounted) {
        setState(() => _error = null);
      }
    }
    return error;
  }

  Future<void> _editPost(FeedPost post) async {
    final LedgerNode? node = _node;
    if (node != null) {
      await editOwnPost(
        context,
        node,
        post,
        mentionCandidates: () =>
            postMentionCandidatesFor(ref, node, post: post),
      );
    }
  }

  Future<void> _deletePost(FeedPost post) async {
    final LedgerNode? node = _node;
    if (node == null) {
      return;
    }
    final String? error = await deleteOwnPost(context, node, post);
    if (error != null && mounted) {
      setState(() => _error = error);
    }
  }

  void _openAuthor(FeedPost post) {
    final LedgerNode? node = _node;
    if (node == null) {
      return;
    }
    if (post.isOwn) {
      unawaited(ProfileScreen.open(context));
      return;
    }
    for (final MapEntry<String, String> e in <MapEntry<String, String>>[
      ...node.friendAccounts.entries,
      ...node.followedAccounts.entries,
    ]) {
      if (e.value == post.account) {
        unawaited(ProfileScreen.open(context, address: e.key));
        return;
      }
    }
    if (post.authorAddress.isNotEmpty) {
      unawaited(ProfileScreen.open(context, address: post.authorAddress));
    }
  }

  Future<void> _followAuthor(FeedPost post) async {
    final LedgerNode? node = _node;
    if (node == null || post.authorAddress.isEmpty) {
      return;
    }
    // A signed follow: the author learns of it, other own devices too.
    await FollowLedger.of(node).follow(post.authorAddress);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(t('Obserwujesz: {name}', {'name': post.authorLabel})),
        ),
      );
      setState(() {});
    }
  }

  Future<void> _manageFollowing() async {
    final LedgerNode? node = _node;
    if (node == null || !node.isReady) {
      return;
    }
    final TextEditingController field = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialog) => StatefulBuilder(
        builder: (BuildContext dialog, StateSetter setDialog) => AlertDialog(
          key: const Key('feed-following'),
          title: Text(t('Obserwowani')),
          content: SizedBox(
            width: 360,
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                ZenInfo(
                  icon: Icons.visibility_outlined,
                  text: t(
                    'Obserwować można każdego, bez zgody. Widzisz tylko '
                    'jego posty publiczne.',
                  ),
                ),
                const SizedBox(height: 8),
                if (node.followedAddresses.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      t('Nikogo jeszcze nie obserwujesz.'),
                      style: TextStyle(
                        color: ZenColors.of(dialog).textSecondary,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                for (final String address in node.followedAddresses.toList())
                  ListTile(
                    dense: true,
                    contentPadding: const EdgeInsetsDirectional.only(start: 4),
                    leading: Icon(
                      Icons.person_outline_rounded,
                      color: ZenColors.of(dialog).accent,
                    ),
                    title: Text(
                      address,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      key: Key('feed-unfollow-$address'),
                      tooltip: t('Przestań obserwować'),
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () async {
                        await FollowLedger.of(node).unfollow(address);
                        setDialog(() {});
                      },
                    ),
                  ),
                const SizedBox(height: 8),
                TextField(
                  key: const Key('feed-follow-field'),
                  controller: field,
                  decoration: InputDecoration(
                    labelText: t('Obserwuj kogoś nowego'),
                    hintText: t('Adres osoby do obserwowania'),
                    prefixIcon: const Icon(Icons.person_add_alt_rounded),
                  ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialog).pop(),
              child: Text(t('Zamknij')),
            ),
            FilledButton(
              key: const Key('feed-follow-add'),
              onPressed: () async {
                final String address = field.text.trim();
                if (address.isEmpty) {
                  return;
                }
                await FollowLedger.of(node).follow(address);
                field.clear();
                setDialog(() {});
              },
              child: Text(t('Obserwuj')),
            ),
          ],
        ),
      ),
    );
    disposeLater(field);
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _checkReshares() async {
    final LedgerNode? node = _node;
    if (node == null || !node.isReady) {
      return;
    }
    final List<LogEntry> feeds = <LogEntry>[
      ...node.entriesOf(),
      for (final String account in node.friendAccounts.values)
        ...node.entriesOf(ofAccount: account),
    ];
    if (await _reshares.checkAll(feeds)) {
      _feedRevision++;
      if (mounted) {
        setState(() {});
      }
    }
  }

  Future<void> _reshare(FeedPost post) async {
    final LedgerNode? node = _node;
    final LogEntry? entry = post.entry;
    if (node == null || !node.isReady || entry == null) {
      return;
    }
    try {
      await node.publish(
        kReshareKind,
        reshareBody(
          entry,
          authorProfile: latestProfileEntry(node, entry.account),
        ),
      );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(t('Udostępniono znajomym.'))));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się udostępnić: {error}', {'error': e}),
        );
      }
    }
  }

  Future<void> _toggleLike(FeedPost post) async {
    final LedgerNode? node = _node;
    if (node == null || !node.isReady) {
      return;
    }
    try {
      await node.publish(
        kLikeKind,
        likeBody(post.id, on: !post.likedByMe, mini: ownMiniProfile(node)),
        spaceKind: 'acts',
      );
      if (!post.likedByMe && mounted) {
        unawaited(ref.read(zenSoundEffectsProvider).play(ZenSound.like));
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się polubić: {error}', {'error': e}),
        );
      }
    }
  }

  void _openComments(FeedPost post) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        useSafeArea: true,
        builder: (BuildContext sheet) {
          // Own comments removed while the sheet is open.
          final Set<String> removed = <String>{};
          return StatefulBuilder(
            builder: (BuildContext sheet, StateSetter setSheet) {
              final ZenColors zen = ZenColors.of(sheet);
              return Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(sheet).viewInsets.bottom,
                ),
                child: SafeArea(
                  // The field stays at the bottom, over the keyboard; the
                  // comments scroll above it.
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Flexible(
                        child: ListView(
                          key: const Key('feed-comments'),
                          shrinkWrap: true,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          children: <Widget>[
                            _SheetTitle(
                              icon: Icons.mode_comment_rounded,
                              title: t('Komentarze'),
                              count: post.comments.length,
                            ),
                            const SizedBox(height: 8),
                            if (post.comments.isEmpty)
                              ZenEmpty(
                                icon: Icons.forum_outlined,
                                title: t('Jeszcze nic.'),
                                text: t('Napisz pierwszy komentarz.'),
                              ),
                            for (final FeedComment c in post.comments)
                              if (removed.contains(c.id))
                                const SizedBox.shrink()
                              else if (ref
                                  .read(hiddenByMeProvider)
                                  .hides(id: c.id))
                                HiddenContentPlaceholder(
                                  key: Key('feed-comment-hidden-${c.id}'),
                                  byMe: true,
                                  compact: true,
                                  onShow: () {
                                    showHiddenAnyway(ref, id: c.id);
                                    setSheet(() {});
                                  },
                                )
                              else
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      _Initials(
                                        name: c.authorLabel,
                                        own: false,
                                        size: 34,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Container(
                                          padding: const EdgeInsets.fromLTRB(
                                            14,
                                            10,
                                            14,
                                            10,
                                          ),
                                          decoration: BoxDecoration(
                                            color: zen.surfaceMuted,
                                            borderRadius: ZenLook.of(
                                              context,
                                            ).bubbleRadius(outgoing: false),
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: <Widget>[
                                              Text(
                                                c.authorLabel,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: zen.textPrimary,
                                                  fontWeight: FontWeight.w700,
                                                  fontSize: 13.5,
                                                ),
                                              ),
                                              const SizedBox(height: 3),
                                              if (c.text.trim().isNotEmpty)
                                                CopyableText(
                                                  c.text,
                                                  mentions: c.mentions,
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    height: 1.35,
                                                    color: zen.textPrimary,
                                                  ),
                                                  onReport: () => unawaited(
                                                    reportContent(
                                                      context,
                                                      ref,
                                                      // The comment's author.
                                                      authorAddress:
                                                          c.authorAddress,
                                                      text: mentionsAsPlainText(
                                                        c.text,
                                                        c.mentions,
                                                      ),
                                                      header: t(
                                                        'Komentarz — {name}',
                                                        {'name': c.authorLabel},
                                                      ),
                                                      contentId: c.id,
                                                    ).then((_) {
                                                      // The reported comment is hidden now.
                                                      if (sheet.mounted) {
                                                        setSheet(() {});
                                                      }
                                                    }),
                                                  ),
                                                ),
                                              if (_node != null)
                                                CommentPictures(
                                                  node: _node!,
                                                  comment: c,
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      if (_node != null &&
                                          canDeleteComment(_node!, c))
                                        IconButton(
                                          key: Key(
                                            'feed-comment-delete-${c.id}',
                                          ),
                                          tooltip: t('Usuń komentarz'),
                                          icon: Icon(
                                            Icons.delete_outline_rounded,
                                            color: zen.textSecondary,
                                          ),
                                          onPressed: () async {
                                            final String? failed =
                                                await confirmDeleteComment(
                                                  sheet,
                                                  _node!,
                                                  post.id,
                                                  c,
                                                );
                                            if (!sheet.mounted) {
                                              return;
                                            }
                                            if (failed == null) {
                                              setSheet(() => removed.add(c.id));
                                            } else if (failed.isNotEmpty) {
                                              ScaffoldMessenger.maybeOf(
                                                sheet,
                                              )?.showSnackBar(
                                                SnackBar(content: Text(failed)),
                                              );
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: CommentComposer(
                          fieldKey: const Key('feed-comment-field'),
                          sendKey: const Key('feed-comment-send'),
                          draftKey: ComposerDrafts.comment(post.id),
                          // "@": the post's author, those who reacted, the
                          // writer's friends and theirs.
                          mentionCandidates: _node == null
                              ? null
                              : () => postMentionCandidatesFor(
                                  ref,
                                  _node!,
                                  post: post,
                                ),
                          onSendMentioning:
                              (
                                String text,
                                List<CommentPicture> pictures,
                                List<Mention> mentions,
                              ) async {
                                final LedgerNode? node = _node;
                                final NavigatorState nav = Navigator.of(sheet);
                                try {
                                  if (node != null) {
                                    await publishComment(
                                      node,
                                      post.id,
                                      text,
                                      pictures: pictures,
                                      mentions: mentions,
                                    );
                                  }
                                  nav.pop();
                                  return null;
                                } on ArgumentError catch (e) {
                                  return '${e.message}';
                                } on Object catch (e) {
                                  return t('Nie udało się: {error}', {
                                    'error': e,
                                  });
                                }
                              },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// Who likes it: you and friends first.
  void _showLikers(FeedPost post) {
    final LedgerNode? node = _node;
    unawaited(
      showPostLikers(
        context,
        post,
        node: node,
        mutualFriends: node == null ? null : mutualFriendsLookup(ref, node),
      ),
    );
  }

  String _nameOf(SocialHubState state, String address) {
    final FriendProfile? friend = state.friendByAddress(address);
    return friend == null ? address : state.nameFor(friend);
  }

  /// Device addresses of the pyramid's members: "verified" likes.
  Set<String> _pyramidAddresses() {
    final PyramidState? s = _pyramid?.state;
    return <String>{
      if (s != null)
        for (final PyrMember m in s.members.values)
          if (s.isMember(m.key) && m.addr.isNotEmpty) m.addr,
    };
  }

  /// Others' posts on the wall, built again only when needed ([FeedMemo]).
  List<FeedPost> _feedFor(LedgerNode node, SocialHubState social) =>
      _feedMemo.wallOf(
        node,
        revision: _feedRevision,
        nameOf: (String address) => _nameOf(social, address),
        reshares: _reshares,
        held: _reach,
        pyramidAddresses: _pyramidAddresses(),
      );

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState social = watchSocialPeople(ref);
    final LedgerNode? node = _node;
    _followPyramid();
    final Set<String> banned = bannedContentNow(ref);
    final HiddenByMe mine = ref.watch(hiddenByMeProvider);
    final List<FeedPost> posts = node != null && node.isReady
        ? _feedFor(node, social)
        : const <FeedPost>[];
    final PyramidService? pyr = _pyramid;
    final PyramidFeed pyramid = pyr?.feed ?? PyramidFeed.empty;
    final List<FeedFilter> filters = feedFiltersFor(pyramid);
    // A remembered chip that is not there any more: everything.
    final FeedFilter filter = filters.contains(_filter)
        ? _filter
        : FeedFilter.all;
    final SearchQuery searched = _searching
        ? SearchQuery.parse(_searchText.text)
        : SearchQuery.empty;
    final List<FeedItem> composed = composeFeed(
      filter,
      wall: posts,
      pyramid: pyramid,
      isClose: (FeedPost p) =>
          node != null &&
          p.authorAddress.isNotEmpty &&
          node.levelOf(p.authorAddress) == FriendLevel.close,
      depth: _reach?.depth ?? kDefaultFeedDepth,
    );
    final List<FeedItem> items = searchFeed(composed, searched);
    _shownIds = <String>[for (final FeedItem i in items) i.id];
    final Set<String> mutedAuthors = ref.watch(
      appSettingsControllerProvider.select(
        (AppSettings s) => s.mutedPostAuthors,
      ),
    );
    final List<Widget> header = <Widget>[
      if (_searching)
        TextField(
          key: const Key('feed-search-field'),
          controller: _searchText,
          autofocus: true,
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            hintText: t('Szukaj w postach i komentarzach'),
            hintMaxLines: 2,
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
          ),
        )
      else
        _ComposerPrompt(
          onWrite: () => unawaited(_compose()),
          onPhoto: () => unawaited(_compose(withPhotos: true)),
        ),
      if (filters.isNotEmpty) ...<Widget>[
        const SizedBox(height: 12),
        _FilterChips(filters: filters, selected: filter, onSelect: _pick),
      ],
      if (pyr != null &&
          (filter == FeedFilter.pyramid || filter == FeedFilter.national))
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: PyramidFeedHeader(
            pyr: pyr,
            feed: pyramid,
            national: filter == FeedFilter.national,
          ),
        ),
      if (_error != null)
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: zen.danger.withValues(alpha: 0.10),
            borderRadius: context.zenRadius(18),
            border: Border.all(color: zen.danger.withValues(alpha: 0.30)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.error_outline_rounded, color: zen.danger, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _error!,
                  key: const Key('feed-error'),
                  style: TextStyle(
                    color: zen.danger,
                    fontSize: 13.5,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      const SizedBox(height: 16),
    ];

    Widget postItem(LedgerNode node, FeedPost post) {
      if (isContentHidden(
        banned,
        post.text,
        id: post.id,
        revealed: _revealed,
        mine: mine,
      )) {
        return HiddenContentPlaceholder(
          key: Key('feed-hidden-${post.id}'),
          byMe: !isContentBanned(banned, id: post.id),
          onShow: () {
            showHiddenAnyway(ref, id: post.id);
            setState(() => _revealed.add(post.id));
          },
        );
      }
      final List<String> friend = _friendAddressesOf(post);
      final bool muted = friend.any(
        (String a) => mutedAuthors.contains(PeerShareCodec.normalizeAddress(a)),
      );
      final Widget card = _PostCard(
        post: post,
        node: node,
        avatarPath: social.peerProfileOf(post.authorAddress)?.avatarPath,
        onLike: () => unawaited(_toggleLike(post)),
        onShowLikers: () => _showLikers(post),
        onComments: () => _openComments(post),
        onAuthor: () => _openAuthor(post),
        onFollow:
            !post.isOwn &&
                post.authorAddress.isNotEmpty &&
                node.knownAccountOf(post.authorAddress) == null &&
                !node.isFollowing(post.authorAddress)
            ? () => unawaited(_followAuthor(post))
            : null,
        onEdit: post.isOwn && post.resharedBy.isEmpty
            ? () => unawaited(_editPost(post))
            : null,
        onDelete: post.isOwn && post.resharedBy.isEmpty
            ? () => unawaited(_deletePost(post))
            : null,
        onReshare:
            post.isOwn ||
                post.audience != Audience.public ||
                post.resharedBy.contains(t('Ty'))
            ? null
            : () => unawaited(_reshare(post)),
        onReport: post.isOwn ? null : () => unawaited(_reportPost(post)),
        postsMuted: muted,
        onMutePosts: friend.isEmpty
            ? null
            : () => unawaited(_setPostsMuted(post, friend, muted: !muted)),
      );
      return post.id == _revealId
          ? KeyedSubtree(key: _revealKey, child: card)
          : card;
    }

    Widget card(LedgerNode node, FeedItem entry) => switch (entry) {
      FeedFriendItem(:final FeedPost post) => postItem(node, post),
      FeedPyramidItem(:final PyrFeedPost post) =>
        pyr == null
            ? const SizedBox.shrink()
            : PyramidFeedCard(pyr: pyr, post: post),
      FeedReferendumItem(:final PyrFeedReferendum referendum) =>
        PyramidReferendumCard(referendum: referendum),
      FeedAlarmItem(:final PyrFeedAlarm alarm) => PyramidAlarmBar(alarm: alarm),
    };

    Widget feedEnd() {
      if (!searched.isEmpty &&
          !items.any((FeedItem i) => i is! FeedAlarmItem)) {
        return ZenEmpty(
          key: const Key('feed-end'),
          icon: Icons.search_off_rounded,
          title: t('Na Tablicy nie ma nic z „{query}”.', {
            'query': _searchText.text.trim(),
          }),
        );
      }
      if (!items.any((FeedItem i) => i is! FeedAlarmItem)) {
        return switch (filter) {
          FeedFilter.pyramid => ZenEmpty(
            key: const Key('feed-end'),
            icon: Icons.forum_outlined,
            title: t('Cisza w linii'),
            text: t(
              'Nikt z Twojej linii ani ze szczytu jeszcze nic nie napisał.',
            ),
          ),
          FeedFilter.national => ZenEmpty(
            key: const Key('feed-end'),
            icon: Icons.flag_outlined,
            title: t('Jeszcze nic'),
            text: t('W sekcji krajowej nikt jeszcze nie pisał.'),
          ),
          FeedFilter.second || FeedFilter.third => ZenEmpty(
            key: const Key('feed-end'),
            icon: Icons.alt_route_rounded,
            title: filter == FeedFilter.second
                ? t('Nic od znajomych znajomych')
                : t('Nic z trzeciego stopnia'),
            text: t(
              'Tu są też publiczne posty, które znajomi przekazali dalej. '
              'Przy każdym widać, przez kogo dotarł.',
            ),
          ),
          FeedFilter.close => ZenEmpty(
            key: const Key('feed-end'),
            icon: Icons.favorite_outline_rounded,
            title: t('Nic od przyjaciół'),
            text: t(
              'Tu są tylko posty osób, które oznaczysz jako „Przyjaciel” '
              '(poziom znajomości w ich profilu).',
            ),
          ),
          _ => ZenEmpty(
            key: const Key('feed-end'),
            icon: Icons.newspaper_rounded,
            title: t('Nic tu jeszcze nie ma od znajomych.'),
            text: t(
              'Gdy znajomi coś opublikują, zobaczysz to tutaj — '
              'po kolei, bez algorytmu.',
            ),
          ),
        };
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Row(
          children: <Widget>[
            Expanded(child: Divider(color: zen.outlineSoft)),
            const SizedBox(width: 12),
            Icon(Icons.check_circle_rounded, size: 18, color: zen.success),
            const SizedBox(width: 6),
            Flexible(
              flex: 3,
              child: Text(
                t('Jesteś na bieżąco'),
                key: const Key('feed-end'),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(child: Divider(color: zen.outlineSoft)),
          ],
        ),
      );
    }

    return Scaffold(
      key: const Key('feed-screen'),
      appBar: ZenSectionBar(
        title: t('Tablica'),
        actions: <Widget>[
          if (node != null)
            IconButton(
              key: const Key('feed-search-button'),
              tooltip: _searching
                  ? t('Zamknij wyszukiwanie')
                  : t('Szukaj na Tablicy'),
              icon: Icon(
                _searching ? Icons.search_off_rounded : Icons.search_rounded,
              ),
              onPressed: () => setState(() {
                _searching = !_searching;
                _searchText.clear();
              }),
            ),
          if (node != null)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: IconButton(
                key: const Key('feed-open-following'),
                tooltip: t('Obserwowani'),
                icon: const Icon(Icons.person_search_rounded),
                onPressed: () => unawaited(_manageFollowing()),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: node == null
            ? Center(
                child: SingleChildScrollView(
                  child: ZenEmpty(
                    icon: Icons.newspaper_rounded,
                    title: t('Tablica jest wyłączona.'),
                  ),
                ),
              )
            : ListView.builder(
                key: const Key('feed-list'),
                controller: _scroll,
                padding: readableInsets(context, top: 12, bottom: 28),
                // Lazy: only the posts on screen are built.
                itemCount: header.length + items.length + 1,
                // Keyed items keep their state when posts above them come
                // and go, as they did in the eager list.
                findChildIndexCallback: (Key key) {
                  if (key is! ValueKey<String>) {
                    return null;
                  }
                  if (key.value == 'feed-end') {
                    return header.length + items.length;
                  }
                  const String hidden = 'feed-hidden-';
                  if (!key.value.startsWith(hidden)) {
                    return null;
                  }
                  final String id = key.value.substring(hidden.length);
                  final int at = items.indexWhere((FeedItem i) => i.id == id);
                  return at < 0 ? null : header.length + at;
                },
                itemBuilder: (BuildContext context, int index) {
                  if (index < header.length) {
                    return header[index];
                  }
                  final int at = index - header.length;
                  return at < items.length ? card(node, items[at]) : feedEnd();
                },
              ),
      ),
    );
  }
}

/// Opens the editor on your own [post] — text, photos and videos (who sees
/// it stays) — and publishes the new version. Returns true when saved.
Future<bool> editOwnPost(
  BuildContext context,
  LedgerNode node,
  FeedPost post, {
  List<MentionCandidate> Function()? mentionCandidates,
}) async {
  // The post's own files are on this device: show them in the editor.
  final List<DraftMedia> media = <DraftMedia>[];
  for (final MediaRef ref in post.images) {
    final Uint8List? bytes = await openMedia(node.blobs, ref);
    if (bytes == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              t(
                'Nie wszystkie zdjęcia tego posta są na urządzeniu — '
                'spróbuj za chwilę.',
              ),
            ),
          ),
        );
      }
      return false;
    }
    media.add(
      DraftMedia(
        bytes: bytes,
        mime: ref.mime,
        stored: mediaRefToJson(ref),
        durationMs: ref.durationMs,
      ),
    );
  }
  if (!context.mounted) {
    return false;
  }
  return PostEditorScreen.open(
    context,
    editing: true,
    initialText: post.text,
    initialMentions: post.mentions,
    mentionCandidates: mentionCandidates,
    initialMedia: media,
    initialAudience: post.audience,
    onSubmit: (PostDraft draft) async {
      try {
        final List<Map<String, dynamic>> refs = <Map<String, dynamic>>[
          for (final DraftMedia m in draft.media)
            m.stored ??
                await storeMedia(
                  node.blobs,
                  m.bytes,
                  mime: m.mime,
                  durationMs: m.durationMs,
                  stripMetadata: true,
                ),
        ];
        final ({String text, List<Mention> mentions}) said =
            mentionsForAudience(
              node,
              draft.text,
              draft.mentions,
              post.audience,
            );
        await node.publish(
          kPostEditKind,
          await node.seal(
            post.audience,
            editPostBody(
              post.id,
              said.text,
              audience: post.audience,
              images: refs,
              mentions: said.mentions,
            ),
          ),
          blobs: mediaIds(refs),
        );
        return null;
      } on ArgumentError catch (e) {
        return e.message as String? ?? t('Nie udało się zapisać.');
      } on Object catch (e) {
        return t('Nie udało się zapisać: {error}', {'error': e});
      }
    },
  );
}

/// Asks, then removes your own [post] (a signed tombstone). Returns an
/// error, or null (also when the user changed their mind).
Future<String?> deleteOwnPost(
  BuildContext context,
  LedgerNode node,
  FeedPost post,
) async {
  final bool? sure = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialog) => AlertDialog(
      scrollable: true,
      title: Text(t('Usunąć post?')),
      content: Text(
        t(
          'Post zniknie z Twojego profilu i z tablic znajomych. Post publiczny '
          'mógł już zostać skopiowany, więc usunięcie jest dla innych prośbą.',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialog).pop(false),
          child: Text(t('Anuluj')),
        ),
        FilledButton(
          key: const Key('feed-delete-confirm'),
          onPressed: () => Navigator.of(dialog).pop(true),
          child: Text(t('Usuń')),
        ),
      ],
    ),
  );
  if (sure != true) {
    return null;
  }
  try {
    await node.publish(kPostDeleteKind, deletePostBody(post.id));
    return null;
  } on Object catch (e) {
    return t('Nie udało się usunąć: {error}', {'error': e});
  }
}

/// Publishes [draft] on the wall, with photos and videos stored encrypted.
/// Returns an error, or null when done.
Future<String?> publishDraft(WidgetRef ref, PostDraft draft) async {
  final LedgerNode? node = ref.read(ledgerNodeProvider);
  if (node == null) {
    return t('Tablica jest wyłączona.');
  }
  final String text = draft.text;
  try {
    final List<Map<String, dynamic>> media = <Map<String, dynamic>>[
      for (final DraftMedia m in draft.media)
        await storeMedia(
          node.blobs,
          m.bytes,
          mime: m.mime,
          durationMs: m.durationMs,
          stripMetadata: true,
        ),
    ];
    final ({String text, List<Mention> mentions}) said = mentionsForAudience(
      node,
      text,
      draft.mentions,
      draft.audience,
    );
    final Map<String, dynamic> body = newPostBody(
      said.text,
      audience: draft.audience,
      images: media,
      mentions: said.mentions,
    );
    await node.publish(
      kPostKind,
      await node.seal(draft.audience, body),
      blobs: mediaIds(media),
    );
    unawaited(ref.read(zenSoundEffectsProvider).play(ZenSound.posted));
    return null;
  } on ArgumentError catch (e) {
    return e.message as String? ?? t('Nie udało się opublikować.');
  } on Object catch (e) {
    return t('Nie udało się opublikować: {error}', {'error': e});
  }
}

/// Who this account may mention in [post] or under it (a new post of its
/// own when `null`), see [postMentionCandidates].
List<MentionCandidate> postMentionCandidatesFor(
  WidgetRef ref,
  LedgerNode node, {
  FeedPost? post,
}) {
  final SocialHubState social = ref.read(socialHubControllerProvider);
  return postMentionCandidates(
    node,
    post: post,
    nameOf: (String address) {
      final FriendProfile? friend = social.friendByAddress(address);
      return friend == null ? '' : social.nameFor(friend);
    },
    friendLists: ref.read(meetServiceProvider).book.friendLists,
  );
}

/// Side padding that keeps a column of posts readable on wide windows.
EdgeInsets readableInsets(
  BuildContext context, {
  double top = 16,
  double bottom = 16,
  double maxWidth = 680,
}) {
  final double side = math.max(
    16,
    (MediaQuery.sizeOf(context).width - 56 - maxWidth) / 2,
  );
  return EdgeInsets.fromLTRB(side, top, side, bottom);
}

/// When a post was written, the way people say it: "przed chwilą",
/// "12 min temu", "3 godz. temu", then the date and hour.
String postTimeLabel(int millis, {bool withYear = false}) {
  final DateTime at = DateTime.fromMillisecondsSinceEpoch(millis);
  final DateTime now = DateTime.now();
  final Duration ago = now.difference(at);
  if (!ago.isNegative) {
    if (ago.inMinutes < 1) {
      return t('przed chwilą');
    }
    if (ago.inMinutes < 60) {
      return t('{count} min temu', {'count': ago.inMinutes});
    }
    if (ago.inHours < 24) {
      return t('{count} godz. temu', {'count': ago.inHours});
    }
  }
  final String time = ZenFormat.time(at);
  final String date = withYear || at.year != now.year
      ? ZenFormat.date(at)
      : ZenFormat.dayMonth(at);
  return '$date, $time';
}

/// "Co słychać?" at the top of the wall; opens the post editor.
/// „Wszystko · Znajomi · 2. stopień · 3. stopień · Przyjaciele · Piramida ·
/// Kraj” over the list.
class _FilterChips extends StatefulWidget {
  const _FilterChips({
    required this.filters,
    required this.selected,
    required this.onSelect,
  });

  final List<FeedFilter> filters;
  final FeedFilter selected;
  final ValueChanged<FeedFilter> onSelect;

  @override
  State<_FilterChips> createState() => _FilterChipsState();
}

class _FilterChipsState extends State<_FilterChips> {
  /// Where each chip is, to bring the selected one into view (the row
  /// scrolls sideways and a filter restored from before may be off screen).
  final Map<FeedFilter, GlobalKey> _chipKeys = <FeedFilter, GlobalKey>{};
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _showSelected();
  }

  @override
  void didUpdateWidget(_FilterChips oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      _showSelected();
    }
  }

  void _showSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final RenderObject? chip = _chipKeys[widget.selected]?.currentContext
          ?.findRenderObject();
      if (!mounted || chip == null || !_scroll.hasClients) {
        return;
      }
      // Only this row scrolls (not the page around it).
      final RenderAbstractViewport viewport = RenderAbstractViewport.of(chip);
      // As little as it takes for the chip to be fully in view.
      final double atStart = viewport.getOffsetToReveal(chip, 0).offset;
      final double atEnd = viewport.getOffsetToReveal(chip, 1).offset;
      final double now = _scroll.position.pixels;
      final double? target = now > atStart
          ? atStart
          : now < atEnd
          ? atEnd
          : null;
      if (target == null) {
        return;
      }
      unawaited(
        _scroll.animateTo(
          target.clamp(
            _scroll.position.minScrollExtent,
            _scroll.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  /// What the farther filters mean (a long press on the chip, and under the
  /// chips while one is chosen).
  String? _explanation(FeedFilter f) => switch (f) {
    FeedFilter.second => t(
      'Znajomi znajomych: posty dotarły do Ciebie przez jednego znajomego.',
    ),
    FeedFilter.third => t(
      'Trzeci stopień: posty dotarły do Ciebie przez dwie osoby.',
    ),
    _ => null,
  };

  String _label(FeedFilter f) => switch (f) {
    FeedFilter.all => t('Wszystko'),
    FeedFilter.friends => t('Znajomi'),
    FeedFilter.second => t('2. stopień'),
    FeedFilter.third => t('3. stopień'),
    FeedFilter.close => t('Przyjaciele'),
    FeedFilter.pyramid => t('Piramida'),
    FeedFilter.national => t('Kraj'),
  };

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String? explanation = _explanation(widget.selected);
    Widget chip(FeedFilter f) => ChoiceChip(
      key: Key('feed-filter-${f.name}'),
      label: Text(_label(f)),
      selected: f == widget.selected,
      onSelected: (bool _) => widget.onSelect(f),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SingleChildScrollView(
          key: const Key('feed-filters'),
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (final FeedFilter f in widget.filters)
                Padding(
                  key: _chipKeys.putIfAbsent(f, GlobalKey.new),
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: switch (_explanation(f)) {
                    final String hint => Tooltip(
                      message: hint,
                      triggerMode: TooltipTriggerMode.longPress,
                      child: chip(f),
                    ),
                    _ => chip(f),
                  },
                ),
            ],
          ),
        ),
        if (explanation != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              explanation,
              key: const Key('feed-filter-explanation'),
              style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
            ),
          ),
      ],
    );
  }
}

class _ComposerPrompt extends StatelessWidget {
  const _ComposerPrompt({required this.onWrite, required this.onPhoto});

  final VoidCallback onWrite;
  final VoidCallback onPhoto;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Material(
      key: const Key('feed-composer-card'),
      color: zen.surface,
      shape: RoundedRectangleBorder(
        borderRadius: context.zenRadius(24),
        side: BorderSide(color: zen.outlineSoft),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            key: const Key('feed-compose'),
            onTap: onWrite,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 10),
              child: Row(
                children: <Widget>[
                  const OwnAvatar(size: 42),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      decoration: BoxDecoration(
                        color: zen.surfaceSunk,
                        borderRadius: context.zenRadius(999),
                        border: Border.all(color: zen.outlineSoft),
                      ),
                      child: Text(
                        t('Co słychać?'),
                        style: TextStyle(
                          color: zen.textSecondary,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: _ComposerAction(
                    key: const Key('feed-compose-photo'),
                    icon: Icons.add_photo_alternate_rounded,
                    label: t('Zdjęcie'),
                    tooltip: t('Post ze zdjęciem'),
                    tone: zen.tone(ZenTone.media),
                    onTap: onPhoto,
                  ),
                ),
                Expanded(
                  child: _ComposerAction(
                    icon: Icons.edit_note_rounded,
                    label: t('Napisz post'),
                    tone: zen.accent,
                    onTap: onWrite,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ComposerAction extends StatelessWidget {
  const _ComposerAction({
    required this.icon,
    required this.label,
    required this.tone,
    required this.onTap,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final Color tone;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Widget body = InkWell(
      borderRadius: context.zenRadius(14),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 20, color: tone),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return tooltip == null ? body : Tooltip(message: tooltip, child: body);
  }
}

class _PostCard extends StatelessWidget {
  const _PostCard({
    required this.post,
    required this.node,
    required this.onLike,
    required this.onShowLikers,
    required this.onComments,
    required this.onReshare,
    this.avatarPath,
    this.onEdit,
    this.onDelete,
    this.onAuthor,
    this.onFollow,
    this.onReport,
    this.onMutePosts,
    this.postsMuted = false,
  });

  final FeedPost post;
  final LedgerNode node;

  /// The author's photo on this device, when they shared one.
  final String? avatarPath;
  final VoidCallback onLike;
  final VoidCallback onShowLikers;
  final VoidCallback onComments;
  final VoidCallback? onReshare;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onAuthor;
  final VoidCallback? onFollow;

  /// Someone else's post: "Zgłoś".
  final VoidCallback? onReport;

  /// A friend's post: "Wycisz posty tej osoby" (no notifications about
  /// their new posts), or back when [postsMuted].
  final VoidCallback? onMutePosts;
  final bool postsMuted;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String when = postTimeLabel(post.millis);
    final ImageProvider? photo = peerAvatarImage(avatarPath);
    return Container(
      key: Key('feed-post-${post.id}'),
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 14, 8, 8),
      decoration: BoxDecoration(
        color: zen.surface,
        borderRadius: context.zenRadius(24),
        border: Border.all(color: zen.outlineSoft),
        boxShadow: ZenLook.of(context).lift(zen, radius: 18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: GestureDetector(
                  key: Key('feed-author-${post.id}'),
                  behavior: HitTestBehavior.opaque,
                  onTap: onAuthor,
                  child: Row(
                    children: <Widget>[
                      if (photo != null)
                        ZenBlobAvatar(
                          name: post.authorLabel,
                          size: 42,
                          showStatus: false,
                          image: photo,
                        )
                      else
                        _Initials(name: post.authorLabel, own: post.isOwn),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              post.authorLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15.5,
                                color: zen.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: <Widget>[
                                Flexible(
                                  child: Text(
                                    post.edited
                                        ? t('{time} · edytowano', {
                                            'time': when,
                                          })
                                        : when,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: zen.textSecondary,
                                      fontSize: 12.5,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 5),
                                Icon(
                                  kAudienceIcons[post.audience],
                                  size: 13,
                                  color: zen.textMuted,
                                ),
                                if (postsMuted) ...<Widget>[
                                  const SizedBox(width: 5),
                                  Icon(
                                    Icons.notifications_off_outlined,
                                    key: Key('feed-muted-${post.id}'),
                                    size: 13,
                                    color: zen.textMuted,
                                    semanticLabel: t(
                                      'Bez powiadomień o postach tej osoby',
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (onFollow != null)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 6),
                  child: TextButton.icon(
                    key: Key('feed-follow-${post.id}'),
                    onPressed: onFollow,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      backgroundColor: zen.accent.withValues(alpha: 0.10),
                      shape: const StadiumBorder(),
                    ),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: Text(t('Obserwuj')),
                  ),
                ),
              if (onEdit != null ||
                  onDelete != null ||
                  onReport != null ||
                  onMutePosts != null)
                PopupMenuButton<String>(
                  key: Key('feed-menu-${post.id}'),
                  tooltip: onEdit != null || onDelete != null
                      ? t('Edytuj lub usuń')
                      : t('Więcej'),
                  icon: Icon(
                    Icons.more_horiz_rounded,
                    color: zen.textSecondary,
                  ),
                  onSelected: (String v) => (switch (v) {
                    'edit' => onEdit,
                    'delete' => onDelete,
                    'mute' => onMutePosts,
                    _ => onReport,
                  })?.call(),
                  itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                    if (onEdit != null)
                      PopupMenuItem<String>(
                        value: 'edit',
                        child: ListTile(
                          leading: const Icon(Icons.edit_outlined),
                          title: Text(t('Edytuj')),
                        ),
                      ),
                    if (onDelete != null)
                      PopupMenuItem<String>(
                        value: 'delete',
                        child: ListTile(
                          leading: const Icon(Icons.delete_outline_rounded),
                          title: Text(t('Usuń')),
                        ),
                      ),
                    if (onMutePosts != null)
                      PopupMenuItem<String>(
                        key: Key('feed-mute-posts-${post.id}'),
                        value: 'mute',
                        child: ListTile(
                          leading: Icon(
                            postsMuted
                                ? Icons.notifications_active_outlined
                                : Icons.notifications_off_outlined,
                          ),
                          title: Text(
                            postsMuted
                                ? t('Włącz powiadomienia o postach tej osoby')
                                : t('Wycisz posty tej osoby'),
                          ),
                        ),
                      ),
                    if (onReport != null)
                      PopupMenuItem<String>(
                        key: Key('feed-report-${post.id}'),
                        value: 'report',
                        child: ListTile(
                          leading: const Icon(Icons.flag_outlined),
                          title: Text(t('Zgłoś')),
                        ),
                      ),
                  ],
                )
              else
                const SizedBox(width: 8),
            ],
          ),
          if (post.resharedBy.isNotEmpty ||
              post.via.isNotEmpty ||
              post.audience != Audience.public)
            Padding(
              padding: const EdgeInsetsDirectional.only(top: 10, end: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: <Widget>[
                  if (post.resharedBy.isNotEmpty)
                    _Pill(
                      key: Key('feed-reshared-${post.id}'),
                      icon: Icons.repeat_rounded,
                      text: t('Udostępnił(a): {names}', {
                        'names': post.resharedBy.join(', '),
                      }),
                      tone: zen.tone(ZenTone.people),
                    ),
                  if (post.via.isNotEmpty)
                    _Pill(
                      key: Key('feed-via-${post.id}'),
                      icon: Icons.alt_route_rounded,
                      text: post.via.length <= 2
                          ? t('przez {names}', {'names': post.via.join(', ')})
                          : tn(
                              post.via.length - 1,
                              one: 'przez {name} i {n} inną osobę',
                              few: 'przez {name} i {n} inne osoby',
                              many: 'przez {name} i {n} innych osób',
                              args: <String, Object?>{'name': post.via.first},
                            ),
                      tone: zen.tone(ZenTone.people),
                      maxLines: 2,
                    ),
                  if (post.audience != Audience.public)
                    _Pill(
                      key: Key('feed-audience-${post.id}'),
                      icon: Icons.lock_outline_rounded,
                      text: kAudienceLabels[post.audience]!,
                    ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: PostContent(post: post, node: node),
          ),
          const SizedBox(height: 10),
          Divider(height: 1, endIndent: 8, color: zen.outlineSoft),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              _LikeButton(
                post: post,
                onLike: onLike,
                onShowLikers: onShowLikers,
              ),
              const SizedBox(width: 6),
              _ActionPill(
                key: Key('feed-comments-${post.id}'),
                icon: Icons.mode_comment_outlined,
                label: '${post.comments.length}',
                tooltip: t('Komentarze'),
                onTap: onComments,
              ),
              const Spacer(),
              if (onReshare != null)
                IconButton(
                  key: Key('feed-reshare-${post.id}'),
                  tooltip: t('Udostępnij znajomym'),
                  onPressed: onReshare,
                  icon: Icon(Icons.repeat_rounded, color: zen.textSecondary),
                ),
            ],
          ),
          if (likeSummary(post) case final String summary)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(4, 2, 8, 2),
              child: InkWell(
                key: Key('feed-like-summary-${post.id}'),
                borderRadius: context.zenRadius(8),
                onTap: onShowLikers,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Text(
                    switch (verifiedSummary(post)) {
                      final String verified => '$summary · $verified',
                      null => summary,
                    },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The heart and the number of likes: the heart likes, the number shows
/// who liked.
class _LikeButton extends StatelessWidget {
  const _LikeButton({
    required this.post,
    required this.onLike,
    required this.onShowLikers,
  });

  final FeedPost post;
  final VoidCallback onLike;
  final VoidCallback onShowLikers;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final bool liked = post.likedByMe;
    return Material(
      color: liked ? zen.danger.withValues(alpha: 0.12) : zen.surfaceMuted,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Tooltip(
            message: liked ? t('Cofnij polubienie') : t('Polub'),
            child: InkWell(
              key: Key('feed-like-${post.id}'),
              onTap: onLike,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(12, 9, 6, 9),
                child: Icon(
                  liked
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  size: 20,
                  color: liked ? zen.danger : zen.textSecondary,
                ),
              ),
            ),
          ),
          InkWell(
            key: Key('feed-likers-${post.id}'),
            onTap: onShowLikers,
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(4, 9, 14, 9),
              child: Text(
                '${post.likeTotal}',
                style: TextStyle(
                  color: liked ? zen.danger : zen.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A rounded action with an icon and a count (comments).
class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Widget pill = Material(
      color: zen.surfaceMuted,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 9, 14, 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 19, color: zen.textSecondary),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: zen.textSecondary,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip, child: pill);
  }
}

/// The title row of a bottom sheet: icon, title and a count.
class _SheetTitle extends StatelessWidget {
  const _SheetTitle({
    required this.icon,
    required this.title,
    required this.count,
  });

  final IconData icon;
  final String title;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Row(
      children: <Widget>[
        Icon(icon, size: 20, color: zen.accent),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(width: 8),
        ZenPill(text: '$count'),
      ],
    );
  }
}

/// Round avatar with the first letter of the name, coloured by the name.
class _Initials extends StatelessWidget {
  const _Initials({required this.name, required this.own, this.size = 42});

  final String name;
  final bool own;
  final double size;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final String letter = name.trim().isEmpty
        ? '?'
        : name.trim().characters.first.toUpperCase();
    final int hue = (name.hashCode & 0x7FFFFFFF) % 8;
    final Color a = own ? zen.accent : zenTone(zen, hue);
    final Color b = own ? zen.accentSecondary : zenTone(zen, hue + 1);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[a, b],
        ),
      ),
      child: Text(
        letter,
        style: TextStyle(
          color: ZenColors.foregroundFor(a),
          fontWeight: FontWeight.w800,
          fontSize: size * 0.42,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.icon,
    required this.text,
    this.tone,
    this.maxLines = 1,
  });

  final IconData icon;
  final String text;
  final Color? tone;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color t = tone ?? zen.accent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: t.withValues(alpha: 0.12),
        borderRadius: context.zenRadius(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 13, color: t),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              text,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: t,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A post's formatted text with its photos and videos where the author put
/// them; media the text does not mention follow as a gallery.
class PostContent extends StatelessWidget {
  const PostContent({required this.post, required this.node, super.key});

  final FeedPost post;
  final LedgerNode node;

  @override
  Widget build(BuildContext context) {
    final List<MediaRef> media = post.images;
    final Set<int> placed = referencedMedia(post.text).toSet();
    final List<MediaRef> rest = <MediaRef>[
      for (int i = 0; i < media.length; i++)
        if (!placed.contains(i) && !isAudioMime(media[i].mime)) media[i],
    ];
    // Recordings the text does not place go under it, one per line.
    final List<MediaRef> restAudio = <MediaRef>[
      for (int i = 0; i < media.length; i++)
        if (!placed.contains(i) && isAudioMime(media[i].mime)) media[i],
    ];
    final List<MediaRef> photos = <MediaRef>[
      for (final MediaRef r in media)
        if (isPhotoMime(r.mime)) r,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (post.text.trim().isNotEmpty)
          RichPostBody(
            source: post.text,
            mentions: post.mentions,
            mediaCount: media.length,
            mediaBuilder: (BuildContext context, int i) =>
                isAudioMime(media[i].mime)
                ? PostAudio(ref: media[i], node: node, entry: post.entry)
                : isVideoMime(media[i].mime)
                ? PostVideo(ref: media[i], node: node, entry: post.entry)
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 460),
                    child: AspectRatio(
                      aspectRatio: 4 / 3,
                      child: _PostImage(
                        ref: media[i],
                        node: node,
                        entry: post.entry,
                        onOpen: () => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              fullscreenDialog: true,
                              builder: (BuildContext context) => _PhotoViewer(
                                images: photos,
                                node: node,
                                initial: photos.indexOf(media[i]),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        for (final MediaRef r in restAudio)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: PostAudio(ref: r, node: node, entry: post.entry),
          ),
        if (rest.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: post.text.trim().isEmpty ? 0 : 12),
            child: PostGallery(images: rest, node: node, entry: post.entry),
          ),
      ],
    );
  }
}

/// A recording in a post (a voice message or an audio file): played on a
/// tap, never by itself.
class PostAudio extends StatelessWidget {
  const PostAudio({
    required this.ref,
    required this.node,
    this.entry,
    super.key,
  });

  final MediaRef ref;
  final LedgerNode node;
  final LogEntry? entry;

  @override
  Widget build(BuildContext context) {
    return AudioClipPlayer(
      key: Key('post-audio-${ref.id}'),
      load: () => openSafePlayable(node.blobs, ref),
      title: t('Nagranie'),
      durationMs: ref.durationMs,
      onMissing: entry == null || node.autoDownloadMedia()
          ? null
          : () => node.downloadMedia(entry!),
    );
  }
}

/// A video in a post. It starts by itself, muted, when it is the
/// topmost video on screen ([VideoAutoplay]); several videos play one after
/// another. A tap turns the sound on, the next one pauses. Decrypted to a
/// private temporary file only when needed, removed afterwards.
class PostVideo extends StatefulWidget {
  const PostVideo({
    required this.ref,
    required this.node,
    this.entry,
    super.key,
  });

  final MediaRef ref;
  final LedgerNode node;
  final LogEntry? entry;

  @override
  State<PostVideo> createState() => _PostVideoState();
}

class _PostVideoState extends State<PostVideo> {
  final VideoAutoplay _auto = VideoAutoplay.instance;
  VideoPlayerController? _player;
  File? _file;

  /// Where the stream server plays the film while it downloads.
  Uri? _streamUri;
  bool _loading = false;
  bool _muted = true;
  bool _userPaused = false;
  bool _reportedEnd = false;
  String? _error;
  ScrollPosition? _scroll;
  Timer? _poll;

  /// Not in a hidden tab, nor under another page ([mayAutoplayAt]).
  bool _onScreen = false;

  @override
  void initState() {
    super.initState();
    _auto.addListener(_onTurn);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ScrollPosition? p = Scrollable.maybeOf(context)?.position;
    if (!identical(p, _scroll)) {
      _scroll?.removeListener(_measure);
      _scroll = p?..addListener(_measure);
    }
    final bool onScreen = mayAutoplayAt(context);
    if (onScreen != _onScreen || (onScreen && _poll == null)) {
      _onScreen = onScreen;
      _syncPoll();
    }
  }

  /// Looks where the video is while it can be seen; out of sight it does
  /// not play (the next visible one may) and nothing looks.
  void _syncPoll() {
    if (!_onScreen) {
      _poll?.cancel();
      _poll = null;
      // After this build: the turn may go to another video's state.
      scheduleMicrotask(() {
        if (mounted && !_onScreen) {
          _auto.report(this, visible: 0, top: double.infinity);
        }
      });
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    // Layout can shift without scrolling (images loading): look again now
    // and then.
    _poll ??= Timer.periodic(
      const Duration(milliseconds: 800),
      (_) => _measure(),
    );
  }

  void _measure() {
    if (!mounted) {
      return;
    }
    if (!_onScreen) {
      _auto.report(this, visible: 0, top: double.infinity);
      return;
    }
    final RenderObject? box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) {
      return;
    }
    final Offset at = box.localToGlobal(Offset.zero);
    final double h = box.size.height;
    final double screen = MediaQuery.sizeOf(context).height;
    final double shown = (math.min(at.dy + h, screen) - math.max(at.dy, 0.0))
        .clamp(0.0, h)
        .toDouble();
    _auto.report(this, visible: h == 0 ? 0 : shown / h, top: at.dy);
  }

  void _onTurn() {
    final bool mine = identical(_auto.active, this);
    final VideoPlayerController? p = _player;
    if (mine && !_userPaused) {
      if (p == null) {
        unawaited(_prepare());
      } else if (!p.value.isPlaying) {
        unawaited(p.play());
      }
    } else if (!mine && p != null && p.value.isPlaying) {
      unawaited(p.pause());
    }
  }

  Future<void> _prepare() async {
    if (_loading) {
      return;
    }
    setState(() => _loading = true);
    final Uint8List? bytes;
    try {
      bytes = await openSafePlayable(widget.node.blobs, widget.ref);
    } on UnsafeMediaException {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t('Nieprawidłowy plik filmu — nie otwarto go.');
        });
      }
      return;
    }
    if (bytes == null) {
      if (widget.entry != null && !widget.node.autoDownloadMedia()) {
        widget.node.downloadMedia(widget.entry!);
      }
      // A film plays while it downloads, once its first piece is here.
      if (!await _stream() && mounted) {
        setState(() {
          _loading = false;
          _error = t('Film jeszcze się pobiera…');
        });
      }
      return;
    }
    // A random name in the temporary media folder (emptied at every
    // start), deleted when the player goes.
    final File f;
    try {
      f = await writeTemporaryMedia(bytes, extension: '.mp4');
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t('Nie udało się odtworzyć filmu: {error}', {'error': e});
        });
      }
      return;
    }
    _file = f;
    await _start(VideoPlayerController.file(f));
  }

  /// Plays the film from the phone's own stream server while the rest of
  /// it downloads; false while not even its first piece is here.
  Future<bool> _stream() async {
    final Uint8List? head;
    try {
      head = await openStreamableStart(widget.node.blobs, widget.ref);
    } on UnsafeMediaException {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t('Nieprawidłowy plik filmu — nie otwarto go.');
        });
      }
      return true;
    }
    if (head == null || !mounted) {
      return false;
    }
    final Uri uri = await MediaStreamServer.instance.publish(
      BlobMediaStream(widget.node.blobs, widget.ref, onUnsafe: _streamWentBad),
    );
    _streamUri = uri;
    await _start(VideoPlayerController.networkUrl(uri));
    if (_player == null) {
      _streamUri = null;
      await MediaStreamServer.instance.withdraw(uri);
    }
    return true;
  }

  /// A segment of the streamed film turned out to be bad: playback stops.
  void _streamWentBad() {
    final VideoPlayerController? p = _player;
    if (!mounted) {
      return;
    }
    if (p != null) {
      unawaited(p.dispose());
    }
    setState(() {
      _player = null;
      _loading = false;
      _error = t('Nieprawidłowy plik filmu — nie otwarto go.');
    });
  }

  Future<void> _start(VideoPlayerController p) async {
    try {
      await p.initialize();
      await p.setVolume(_muted ? 0 : 1);
      p.addListener(() {
        if (!mounted) {
          return;
        }
        final VideoPlayerValue v = p.value;
        final bool ended =
            v.isInitialized &&
            v.duration > Duration.zero &&
            v.position >= v.duration - const Duration(milliseconds: 200) &&
            !v.isPlaying;
        if (ended && !_reportedEnd) {
          _reportedEnd = true;
          _auto.finished(this);
        } else if (!ended) {
          _reportedEnd = false;
        }
        setState(() {});
      });
      if (!mounted) {
        await p.dispose();
        return;
      }
      setState(() {
        _player = p;
        _loading = false;
        _error = null;
      });
      _onTurn();
    } on Object catch (e) {
      unawaited(p.dispose());
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t('Nie udało się odtworzyć filmu: {error}', {'error': e});
        });
      }
    }
  }

  Future<void> _tap() async {
    final VideoPlayerController? p = _player;
    if (p == null) {
      _userPaused = false;
      await _prepare();
      return;
    }
    if (_muted && p.value.isPlaying) {
      setState(() => _muted = false);
      await p.setVolume(1);
      return;
    }
    if (p.value.isPlaying) {
      _userPaused = true;
      await p.pause();
    } else {
      _userPaused = false;
      if (p.value.position >= p.value.duration) {
        await p.seekTo(Duration.zero);
      }
      await p.play();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _scroll?.removeListener(_measure);
    _auto
      ..removeListener(_onTurn)
      ..remove(this);
    unawaited(_player?.dispose());
    final File? f = _file;
    if (f != null) {
      unawaited(f.delete().then((_) {}, onError: (Object _) {}));
    }
    final Uri? streamed = _streamUri;
    if (streamed != null) {
      unawaited(MediaStreamServer.instance.withdraw(streamed));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? p = _player;
    if (p != null && p.value.isInitialized) {
      // A screen reader says what a tap does: play or pause.
      return Semantics(
        button: true,
        label: p.value.isPlaying ? t('Pauza') : t('Odtwórz'),
        child: GestureDetector(
          key: Key('feed-video-${widget.ref.id}'),
          onTap: () => unawaited(_tap()),
          child: AspectRatio(
            aspectRatio: p.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: <Widget>[
                VideoPlayer(p),
                if (!p.value.isPlaying)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ZenFixed.photoBackdrop.withValues(alpha: 0.45),
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      size: 40,
                      color: ZenFixed.onPhoto,
                    ),
                  ),
                PositionedDirectional(
                  end: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: ZenFixed.photoScrim,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      _muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      size: 16,
                      color: ZenFixed.onPhoto,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: VideoProgressIndicator(p, allowScrubbing: true),
                ),
              ],
            ),
          ),
        ),
      );
    }
    // The poster before playback, in the colours of the theme.
    final ZenColors zen = ZenColors.of(context);
    return InkWell(
      key: Key('feed-video-${widget.ref.id}'),
      onTap: _loading ? null : () => unawaited(_tap()),
      child: Container(
        height: 200,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[zen.surfaceRaised, zen.surfaceSunk],
          ),
        ),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(12),
        child: _loading
            ? CircularProgressIndicator(color: zen.accent)
            : SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: zen.textPrimary.withValues(alpha: 0.10),
                        border: Border.all(
                          color: zen.textPrimary.withValues(alpha: 0.30),
                        ),
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: 40,
                        color: zen.textPrimary,
                      ),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: zen.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
      ),
    );
  }
}

/// The photos of a post: one wide, or a two-column grid; a tap opens them
/// full screen.
class PostGallery extends StatelessWidget {
  const PostGallery({
    required this.images,
    required this.node,
    this.entry,
    super.key,
  });

  final List<MediaRef> images;
  final LedgerNode node;
  final LogEntry? entry;

  @override
  Widget build(BuildContext context) {
    final int n = images.length;
    return ClipRRect(
      borderRadius: context.zenRadius(18),
      child: GridView.count(
        crossAxisCount: n == 1 ? 1 : 2,
        childAspectRatio: n == 1 ? 4 / 3 : (n == 2 ? 3 / 4 : 1),
        mainAxisSpacing: 4,
        crossAxisSpacing: 4,
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        physics: const NeverScrollableScrollPhysics(),
        children: <Widget>[
          for (int i = 0; i < n; i++)
            if (isAudioMime(images[i].mime))
              PostAudio(ref: images[i], node: node, entry: entry)
            else if (isVideoMime(images[i].mime))
              PostVideo(ref: images[i], node: node, entry: entry)
            else
              _PostImage(
                ref: images[i],
                node: node,
                entry: entry,
                onOpen: () => unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      fullscreenDialog: true,
                      builder: (BuildContext context) => _PhotoViewer(
                        images: <MediaRef>[
                          for (final MediaRef r in images)
                            if (isPhotoMime(r.mime)) r,
                        ],
                        node: node,
                        initial: <MediaRef>[
                          for (final MediaRef r in images)
                            if (isPhotoMime(r.mime)) r,
                        ].indexOf(images[i]),
                      ),
                    ),
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// All photos and videos of someone's posts, as a grid (the profile's
/// "Galeria"). Videos play in place; photos open full screen.
class ProfileMediaGrid extends StatelessWidget {
  const ProfileMediaGrid({
    required this.items,
    required this.node,
    this.onRemove,
    super.key,
  });

  final List<({MediaRef ref, LogEntry? entry})> items;
  final LedgerNode node;

  /// Long press removes the item (own gallery only).
  final void Function(LogEntry entry)? onRemove;

  @override
  Widget build(BuildContext context) {
    final List<MediaRef> photos = <MediaRef>[
      for (final ({MediaRef ref, LogEntry? entry}) i in items)
        if (isPhotoMime(i.ref.mime)) i.ref,
    ];
    return GridView.count(
      key: const Key('profile-media-grid'),
      crossAxisCount: 3,
      mainAxisSpacing: 6,
      crossAxisSpacing: 6,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      physics: const NeverScrollableScrollPhysics(),
      children: <Widget>[
        for (final ({MediaRef ref, LogEntry? entry}) i in items)
          GestureDetector(
            onLongPress: onRemove == null || i.entry == null
                ? null
                : () => onRemove!(i.entry!),
            child: ClipRRect(
              borderRadius: context.zenRadius(16),
              child: isAudioMime(i.ref.mime)
                  ? PostAudio(ref: i.ref, node: node, entry: i.entry)
                  : isVideoMime(i.ref.mime)
                  ? PostVideo(ref: i.ref, node: node, entry: i.entry)
                  : _PostImage(
                      ref: i.ref,
                      node: node,
                      entry: i.entry,
                      onOpen: () => unawaited(
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            fullscreenDialog: true,
                            builder: (BuildContext context) => _PhotoViewer(
                              images: photos,
                              node: node,
                              initial: photos.indexOf(i.ref),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
      ],
    );
  }
}

/// Full-screen photos: swipe between them, pinch to zoom.
class _PhotoViewer extends StatefulWidget {
  const _PhotoViewer({
    required this.images,
    required this.node,
    required this.initial,
  });

  final List<MediaRef> images;
  final LedgerNode node;
  final int initial;

  @override
  State<_PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<_PhotoViewer> {
  late final PageController _pages = PageController(
    initialPage: widget.initial,
  );
  late int _index = widget.initial;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('feed-photo-viewer'),
      backgroundColor: ZenFixed.photoBackdrop,
      appBar: AppBar(
        backgroundColor: ZenFixed.photoBackdrop,
        foregroundColor: ZenFixed.onPhoto,
        title: widget.images.length > 1
            ? Text('${_index + 1} / ${widget.images.length}')
            : null,
      ),
      body: PageView(
        controller: _pages,
        onPageChanged: (int i) => setState(() => _index = i),
        children: <Widget>[
          for (final MediaRef ref in widget.images)
            FutureBuilder<Uint8List?>(
              future: openSafeImage(widget.node.blobs, ref),
              builder: (BuildContext context, AsyncSnapshot<Uint8List?> s) {
                final Uint8List? bytes = s.data;
                if (s.hasError) {
                  return const _UnsafeMediaTile();
                }
                if (bytes == null) {
                  return const Center(
                    child: CircularProgressIndicator(color: ZenFixed.onPhoto),
                  );
                }
                return InteractiveViewer(
                  maxScale: 5,
                  child: Center(
                    child: looksLikeGif(bytes)
                        ? ZenAnimatedImage(bytes: bytes, fit: BoxFit.contain)
                        : Image.memory(bytes),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

/// A photo of a post: decrypted from the blob store once downloaded.
class _PostImage extends StatefulWidget {
  const _PostImage({
    required this.ref,
    required this.node,
    this.entry,
    this.onOpen,
  });

  final MediaRef ref;
  final LedgerNode node;
  final LogEntry? entry;
  final VoidCallback? onOpen;

  @override
  State<_PostImage> createState() => _PostImageState();
}

class _PostImageState extends State<_PostImage> {
  Uint8List? _bytes;
  bool _unsafe = false;
  StreamSubscription<String>? _done;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _done = widget.node.mediaCompleted.listen((String id) {
      if (id == widget.ref.id && _bytes == null) {
        unawaited(_load());
      }
    });
  }

  Future<void> _load() async {
    try {
      final Uint8List? bytes = await openSafeImage(
        widget.node.blobs,
        widget.ref,
      );
      if (bytes != null && mounted) {
        setState(() => _bytes = bytes);
      }
    } on UnsafeMediaException {
      if (mounted) {
        setState(() => _unsafe = true);
      }
    }
  }

  @override
  void dispose() {
    unawaited(_done?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = _bytes;
    if (_unsafe) {
      return const _UnsafeMediaTile();
    }
    if (bytes == null) {
      final bool auto = widget.node.autoDownloadMedia();
      return InkWell(
        key: Key('feed-image-loading-${widget.ref.id}'),
        onTap: auto || widget.entry == null
            ? null
            : () {
                widget.node.downloadMedia(widget.entry!);
                setState(() {});
              },
        child: Container(
          alignment: Alignment.center,
          color: ZenColors.of(context).surfaceSunk,
          padding: const EdgeInsets.all(8),
          child: auto
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(
                        Icons.download_rounded,
                        color: ZenColors.of(context).accent,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        t('Dotknij, aby pobrać'),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: ZenColors.of(context).textSecondary,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }
    if (looksLikeGif(bytes)) {
      // Plays as far as the media settings allow; otherwise its first
      // frame waits for a tap (the next tap opens it).
      return GestureDetector(
        onTap: widget.onOpen,
        child: ZenAnimatedImage(
          key: Key('feed-gif-${widget.ref.id}'),
          bytes: bytes,
          width: double.infinity,
          height: double.infinity,
          autoplay: widget.node.autoDownloadMedia(),
        ),
      );
    }
    return GestureDetector(
      onTap: widget.onOpen,
      child: Image.memory(
        bytes,
        key: Key('feed-image-${widget.ref.id}'),
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
      ),
    );
  }
}

/// In place of a picture or film that is not what it claims to be: it is
/// never shown or played.
class _UnsafeMediaTile extends StatelessWidget {
  const _UnsafeMediaTile();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      key: const Key('feed-media-unsafe'),
      alignment: Alignment.center,
      color: zen.surfaceSunk,
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.gpp_maybe_rounded, color: zen.warning),
          const SizedBox(height: 4),
          Text(
            t('Nieprawidłowy plik — nie otwarto go'),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
