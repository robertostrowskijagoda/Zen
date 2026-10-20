import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/app/theme/zen_ui.dart';
import 'package:zen/src/core/ledger/log_entry.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/friends/peer_public_profile.dart';
import 'package:zen/src/domain/profile/user_profile.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart'
    show kAudienceIcons;
import 'package:zen/src/features/feed/presentation/rich_post_body.dart';
import 'package:zen/src/features/feed/rich_text.dart';
import 'package:zen/src/features/feed/thanks_model.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/local_delete.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/profile/ledger_profile.dart';
import 'package:zen/src/features/profile/presentation/gallery_add_screen.dart';
import 'package:zen/src/features/profile/presentation/own_avatar.dart';
import 'package:zen/src/features/profile/presentation/peer_avatar.dart';
import 'package:zen/src/features/profile/presentation/profile_edit_dialog.dart';
import 'package:zen/src/features/profile/presentation/status_sheet.dart';
import 'package:zen/src/features/profile/profile_gallery.dart';
import 'package:zen/src/features/profile/user_profile_store.dart';
import 'package:zen/src/features/social/presentation/friend_nickname_prompt.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// A person's profile (§9): cover and photo, name, status and bio, then
/// their posts, their photos and videos ("Galeria") and gratitude cards.
/// Your own profile is edited here ("Edytuj profil"), not in settings; the
/// status is set from the top bar.
class ProfileScreen extends ConsumerStatefulWidget {
  /// Own profile when [address] is null, a friend's otherwise.
  const ProfileScreen({super.key, this.address});

  final String? address;

  static Future<void> open(BuildContext context, {String? address}) =>
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => ProfileScreen(address: address),
        ),
      );

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  StreamSubscription<LogEntry>? _updates;
  StreamSubscription<void>? _opened;
  LedgerNode? _node;

  /// Posts hidden by a pyramid content ban that the user chose to see.
  final Set<String> _revealed = <String>{};

  bool get _isOwn => widget.address == null;

  @override
  void initState() {
    super.initState();
    _node = ref.read(ledgerNodeProvider);
    _opened = _node?.openedChanges.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    _updates = _node?.store.added.listen((_) {
      if (mounted) {
        setState(() {});
      }
    });
    unawaited(
      _node?.start().then((_) {
        if (mounted) {
          setState(() {});
        }
      }),
    );
  }

  @override
  void dispose() {
    unawaited(_updates?.cancel());
    unawaited(_opened?.cancel());
    super.dispose();
  }

  String? get _account {
    final LedgerNode? node = _node;
    if (node == null || !node.isReady) {
      return null;
    }
    return _isOwn ? node.account : node.knownAccountOf(widget.address!);
  }

  String _nameOf(SocialHubState state, String address) {
    final FriendProfile? friend = state.friendByAddress(address);
    return friend == null ? address : state.nameFor(friend);
  }

  Future<void> _giveThanks(String account) async {
    final LedgerNode? node = _node;
    if (node == null) {
      return;
    }
    final TextEditingController field = TextEditingController();
    final String? text = await showDialog<String>(
      context: context,
      builder: (BuildContext dialog) => AlertDialog(
        title: Text(t('Podziękuj')),
        content: TextField(
          key: const Key('profile-thanks-field'),
          controller: field,
          maxLength: kMaxThanksChars,
          maxLines: 3,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            labelText: t('Za co dziękujesz?'),
            hintText: t('Np. „pomógł wnieść lodówkę”'),
            prefixIcon: const Icon(Icons.volunteer_activism_outlined),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('profile-thanks-send'),
            onPressed: () => Navigator.of(dialog).pop(field.text),
            child: Text(t('Wyślij')),
          ),
        ],
      ),
    );
    disposeLater(field);
    if (text == null) {
      return;
    }
    String? error;
    try {
      await node.publish(
        kThanksKind,
        thanksBody(account, text),
        spaceKind: 'acts',
      );
    } on ArgumentError catch (e) {
      error = e.message as String?;
    } catch (e) {
      error = t('Nie udało się: {error}', {'error': e});
    }
    if (mounted && error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  Future<void> _editNickname(FriendProfile friend) async {
    final String? nickname = await promptForFriendNickname(
      context: context,
      friend: friend.copyWith(
        displayName: ref.read(socialHubControllerProvider).nameFor(friend),
      ),
    );
    if (nickname == null || !mounted) {
      return;
    }
    await ref
        .read(socialHubControllerProvider.notifier)
        .setFriendNickname(peerAddress: friend.address, nickname: nickname);
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final SocialHubState social = watchSocialPeople(ref);
    final UserProfile me = ref.watch(userProfileControllerProvider);
    final String? address = widget.address;
    final String other = address ?? '';
    final Set<String> banned = _isOwn
        ? const <String>{}
        : bannedContentNow(ref);
    final HiddenByMe mine = ref.watch(hiddenByMeProvider);
    final FriendProfile? friend = address == null
        ? null
        : social.friendByAddress(address);
    final PeerPublicProfile? peer = address == null
        ? null
        : social.peerProfileOf(address);

    final LedgerNode? node = _node;
    final String? account = _account;
    // Someone who is not a friend: what their public profile says.
    final LedgerProfile? public = !_isOwn && node != null && account != null
        ? latestProfile(node, account)
        : null;
    String pick(String? a, String? b) => (a ?? '').isNotEmpty ? a! : (b ?? '');

    final String name = _isOwn
        ? me.displayName
        : (friend != null
              ? social.nameFor(friend)
              : pick(public?.name, address));
    final String status = _isOwn
        ? me.customStatus
        : pick(peer?.status, public?.status);
    final String bio = _isOwn ? me.bio : pick(peer?.bio, public?.bio);
    final bool canFollow = !_isOwn && friend == null && node != null;
    final bool following = canFollow && node.isFollowing(other);
    List<FeedPost> posts = const <FeedPost>[];
    List<ThanksCard> thanks = const <ThanksCard>[];
    int left = 0;
    if (node != null && account != null) {
      String names(String a) => _nameOf(social, a);
      posts = buildFeed(
        node,
        nameOf: names,
      ).where((FeedPost p) => p.account == account).toList();
      thanks = thanksFor(node, account, nameOf: names);
      if (!_isOwn) {
        left = thanksLeft(
          node,
          account,
          nowMillis: DateTime.now().millisecondsSinceEpoch,
        );
      }
    }

    final Widget avatar;
    if (_isOwn) {
      avatar = const OwnAvatar(size: 92);
    } else if (friend == null && public?.avatar != null && node != null) {
      avatar = _LedgerAvatar(node: node, ref: public!.avatar!);
    } else {
      avatar = PeerAvatar(address: other, name: name, size: 92);
    }
    // The cover: your own file, or the one in their profile entry.
    final LedgerProfile? card = !_isOwn && node != null && account != null
        ? (public ?? latestProfile(node, account))
        : null;
    final Widget cover;
    final String? coverPath = me.coverPath;
    if (_isOwn && coverPath != null && File(coverPath).existsSync()) {
      cover = Image.file(
        File(coverPath),
        key: const Key('profile-cover'),
        fit: BoxFit.cover,
      );
    } else if (card?.cover != null && node != null) {
      cover = _LedgerImage(
        key: const Key('profile-cover'),
        node: node,
        ref: card!.cover!,
      );
    } else {
      cover = const _DefaultCover();
    }
    // The gallery is its own thing: photos and videos added to the profile,
    // never the pictures from posts.
    final List<({MediaRef ref, LogEntry? entry})> media =
        <({MediaRef ref, LogEntry? entry})>[
          if (node != null && account != null)
            for (final GalleryItem g in galleryOf(
              node,
              account: _isOwn ? null : account,
            ))
              for (final MediaRef r in g.media) (ref: r, entry: g.entry),
        ];

    final Widget header = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(
              height: 188,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: 12,
                    right: 12,
                    top: 4,
                    height: 134,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(26),
                      child: Stack(
                        fit: StackFit.expand,
                        children: <Widget>[
                          cover,
                          // A soft shade at the bottom, so the photo melts
                          // into the page under the avatar.
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                stops: const <double>[0.55, 1],
                                colors: <Color>[
                                  zen.background.withValues(alpha: 0),
                                  zen.background.withValues(alpha: 0.35),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Center(child: _AvatarRing(child: avatar)),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                children: <Widget>[
                  Text(
                    name,
                    key: const Key('profile-name'),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: zen.display(
                      color: zen.textPrimary,
                      size: 24,
                      weight: FontWeight.w700,
                      height: 1.15,
                    ),
                  ),
                  if (friend != null &&
                      friend.status == FriendRelationshipStatus.accepted)
                    // What the user calls them, under their own name; their
                    // name itself comes from their profile.
                    TextButton.icon(
                      key: const Key('profile-nickname'),
                      onPressed: () => unawaited(_editNickname(friend)),
                      style: TextButton.styleFrom(
                        foregroundColor: zen.textMuted,
                        minimumSize: const Size(0, 30),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                      icon: Icon(
                        friend.hasNickname
                            ? Icons.edit_note_rounded
                            : Icons.add_rounded,
                        size: 16,
                      ),
                      label: Text(
                        friend.hasNickname
                            ? friend.nickname.trim()
                            : t('Dodaj pseudonim'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13.5,
                          fontStyle: friend.hasNickname
                              ? FontStyle.italic
                              : FontStyle.normal,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  if (_isOwn)
                    // Your status is set right here, on your profile.
                    TextButton.icon(
                      key: const Key('profile-status-button'),
                      onPressed: () => unawaited(showStatusSheet(context)),
                      style: TextButton.styleFrom(
                        backgroundColor: zen.accent.withValues(alpha: 0.10),
                        foregroundColor: zen.accent,
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: zen.accent.withValues(alpha: 0.22),
                          ),
                        ),
                      ),
                      icon: Icon(
                        status.isEmpty
                            ? Icons.add_reaction_outlined
                            : Icons.edit_rounded,
                        size: 16,
                      ),
                      label: Text(
                        status.isEmpty ? t('Ustaw status') : status,
                        key: const Key('profile-status'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: status.isEmpty ? zen.accent : zen.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    )
                  else if (status.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: zen.surfaceMuted,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: zen.outlineSoft),
                      ),
                      child: Text(
                        status,
                        key: const Key('profile-status'),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  if (bio.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        decoration: BoxDecoration(
                          color: zen.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: zen.outlineSoft),
                        ),
                        child: RichPostBody(
                          key: const Key('profile-bio'),
                          source: bio,
                          mediaCount: 0,
                          mediaBuilder: (BuildContext context, int i) =>
                              const SizedBox.shrink(),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                  if (account != null) ...<Widget>[
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: _ProfileStats(
                        posts: posts.length,
                        media: media.length,
                        thanks: thanks.length,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  if (_isOwn)
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        FilledButton.tonalIcon(
                          key: const Key('profile-edit'),
                          onPressed: () => ProfileEditDialog.show(context),
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          label: Text(t('Edytuj profil')),
                        ),
                        if (node != null)
                          FilledButton.icon(
                            key: const Key('profile-add-media'),
                            onPressed: () => unawaited(_addMedia()),
                            icon: const Icon(
                              Icons.add_photo_alternate_outlined,
                              size: 18,
                            ),
                            label: Text(t('Dodaj zdjęcie lub film')),
                          ),
                      ],
                    )
                  else if (canFollow)
                    following
                        ? FilledButton.tonalIcon(
                            key: const Key('profile-follow'),
                            onPressed: () => unawaited(
                              node.unfollow(other).then((_) {
                                if (mounted) {
                                  setState(() {});
                                }
                              }),
                            ),
                            icon: const Icon(Icons.check_rounded, size: 18),
                            label: Text(t('Obserwujesz')),
                          )
                        : FilledButton.icon(
                            key: const Key('profile-follow'),
                            onPressed: () => unawaited(
                              node.follow(other).then((_) {
                                if (mounted) {
                                  setState(() {});
                                }
                              }),
                            ),
                            icon: const Icon(
                              Icons.person_add_alt_rounded,
                              size: 18,
                            ),
                            label: Text(t('Obserwuj')),
                          )
                  else if (account != null)
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        Container(
                          padding: const EdgeInsets.only(left: 14, right: 6),
                          decoration: BoxDecoration(
                            color: zen.surface,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: zen.outline),
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<FriendLevel>(
                              key: const Key('profile-level'),
                              value: node!.levelOf(other),
                              borderRadius: BorderRadius.circular(18),
                              icon: Icon(
                                Icons.expand_more_rounded,
                                color: zen.textSecondary,
                              ),
                              style: TextStyle(
                                color: zen.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                              onChanged: (FriendLevel? level) {
                                if (level == null) {
                                  return;
                                }
                                unawaited(
                                  node.setLevel(other, level).then((_) {
                                    if (mounted) {
                                      setState(() {});
                                    }
                                  }),
                                );
                              },
                              items: <DropdownMenuItem<FriendLevel>>[
                                for (final FriendLevel l in FriendLevel.values)
                                  DropdownMenuItem<FriendLevel>(
                                    value: l,
                                    child: Text(
                                      t('Poziom: {level}', {
                                        'level': kFriendLevelLabels[l],
                                      }),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          key: const Key('profile-thanks'),
                          onPressed: left > 0
                              ? () => unawaited(_giveThanks(account))
                              : null,
                          icon: const Icon(
                            Icons.volunteer_activism_outlined,
                            size: 18,
                          ),
                          label: Text(
                            left > 0
                                ? t('Podziękuj (zostało {count})', {
                                    'count': left,
                                  })
                                : t('Limit podziękowań na ten miesiąc'),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return DefaultTabController(
      length: 3,
      child: Scaffold(
        key: const Key('profile-screen'),
        appBar: ZenSectionBar(title: _isOwn ? t('Mój profil') : t('Profil')),
        body: NestedScrollView(
          headerSliverBuilder: (BuildContext context, bool scrolled) =>
              <Widget>[
                SliverToBoxAdapter(child: header),
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _TabsHeader(
                    color: zen.background,
                    line: zen.outlineSoft,
                    tabs: TabBar(
                      isScrollable: true,
                      tabAlignment: TabAlignment.center,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 18),
                      tabs: <Widget>[
                        Tab(text: t('Posty')),
                        Tab(
                          key: const Key('profile-tab-media'),
                          text: t('Galeria'),
                        ),
                        Tab(text: t('Podziękowania')),
                      ],
                    ),
                  ),
                ),
              ],
          body: account == null
              ? ListView(
                  padding: readableInsets(context),
                  children: <Widget>[
                    ZenEmpty(
                      icon: Icons.sync_rounded,
                      title: t('Profil jeszcze się synchronizuje…'),
                      text: t(
                        'To potrwa chwilę — posty, galeria i '
                        'podziękowania pojawią się same.',
                      ),
                    ),
                  ],
                )
              : TabBarView(
                  children: <Widget>[
                    ListView(
                      key: const Key('profile-posts'),
                      padding: readableInsets(context, bottom: 32),
                      children: <Widget>[
                        if (posts.isEmpty)
                          ZenEmpty(
                            icon: Icons.article_outlined,
                            tone: zenTone(zen, 0),
                            title: t('Brak postów.'),
                            text: _isOwn
                                ? t(
                                    'Napisz coś na Tablicy — Twoje posty '
                                    'zbiorą się tutaj.',
                                  )
                                : t(
                                    'Ta osoba nie opublikowała jeszcze nic, '
                                    'co możesz zobaczyć.',
                                  ),
                          ),
                        for (final FeedPost p in posts)
                          if (isContentHidden(
                            banned,
                            p.text,
                            id: p.id,
                            revealed: _revealed,
                            mine: mine,
                          ))
                            HiddenContentPlaceholder(
                              key: Key('profile-hidden-${p.id}'),
                              byMe: !isContentBanned(banned, p.text),
                              onShow: () {
                                showHiddenAnyway(ref, id: p.id);
                                setState(() => _revealed.add(p.id));
                              },
                            )
                          else
                            _ProfilePost(
                              post: p,
                              node: node,
                              onEdit: _isOwn && node != null && p.isOwn
                                  ? () => unawaited(_editPost(node, p))
                                  : null,
                              onDelete: _isOwn && node != null && p.isOwn
                                  ? () => unawaited(_deletePost(node, p))
                                  : null,
                              onReport: _isOwn || p.isOwn
                                  ? null
                                  : () => unawaited(
                                      reportContent(
                                        context,
                                        ref,
                                        authorAddress: other,
                                        text: p.text,
                                        header: t('Post na profilu — {name}', {
                                          'name': name,
                                        }),
                                        contentId: p.id,
                                        deleteLocal:
                                            node == null || p.images.isEmpty
                                            ? null
                                            : () => deletePostMediaLocally(
                                                node,
                                                p.images,
                                              ),
                                      ),
                                    ),
                            ),
                      ],
                    ),
                    ListView(
                      key: const Key('profile-media'),
                      padding: readableInsets(context, bottom: 32),
                      children: <Widget>[
                        if (media.isEmpty)
                          ZenEmpty(
                            icon: Icons.photo_library_outlined,
                            tone: zenTone(zen, 2),
                            title: _isOwn
                                ? t('Nie masz jeszcze zdjęć ani filmów')
                                : t('Brak zdjęć i filmów.'),
                            text: _isOwn
                                ? t(
                                    'Dodaj je przyciskiem „Dodaj zdjęcie lub '
                                    'film” — domyślnie widzą je tylko '
                                    'znajomi.',
                                  )
                                : null,
                          )
                        else if (node != null)
                          ProfileMediaGrid(
                            items: media,
                            node: node,
                            onRemove: _isOwn
                                ? (LogEntry e) => unawaited(_mediaOptions(e))
                                : null,
                          ),
                      ],
                    ),
                    ListView(
                      key: const Key('profile-thanks-list'),
                      padding: readableInsets(context, bottom: 32),
                      children: <Widget>[
                        if (thanks.isEmpty)
                          ZenEmpty(
                            icon: Icons.volunteer_activism_outlined,
                            tone: zenTone(zen, 5),
                            title: t('Jeszcze nikt nie podziękował.'),
                            text: t(
                              'Podziękowania od znajomych za pomoc '
                              'i dobre gesty zbierają się tutaj.',
                            ),
                          ),
                        for (final ThanksCard c in thanks) _ThanksTile(card: c),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _editPost(LedgerNode node, FeedPost post) async {
    final bool saved = await editOwnPost(context, node, post);
    if (saved && mounted) {
      setState(() {});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t('Zapisano zmiany.'))));
    }
  }

  Future<void> _deletePost(LedgerNode node, FeedPost post) async {
    final String? error = await deleteOwnPost(context, node, post);
    if (!mounted) {
      return;
    }
    setState(() {});
    if (error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error)));
    }
  }

  /// Photos and videos go to the profile's gallery (friends only by
  /// default) — not to the wall as a post.
  Future<void> _addMedia() async {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (node == null) {
      return;
    }
    final bool added = await GalleryAddScreen.open(context, node);
    if (mounted && added) {
      setState(() {});
    }
  }

  /// Long press on your own photo or video: who sees it, or remove it.
  Future<void> _mediaOptions(LogEntry entry) async {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (node == null) {
      return;
    }
    final GalleryItem? item = galleryOf(
      node,
    ).where((GalleryItem g) => g.id == entry.id).firstOrNull;
    if (item == null) {
      return;
    }
    final Object? choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          key: const Key('gallery-item-options'),
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  t('Kto widzi to zdjęcie lub film'),
                  style: TextStyle(
                    color: ZenColors.of(context).textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            for (final Audience a in Audience.values)
              ListTile(
                key: Key('gallery-item-audience-${a.name}'),
                leading: Icon(
                  kAudienceIcons[a],
                  color: a == item.audience
                      ? ZenColors.of(context).accent
                      : ZenColors.of(context).textSecondary,
                ),
                title: Text(kGalleryAudienceLabels[a]!),
                subtitle: Text(kGalleryAudienceHints[a]!),
                trailing: a == item.audience
                    ? Icon(
                        Icons.check_circle_rounded,
                        color: ZenColors.of(context).accent,
                      )
                    : null,
                onTap: () => Navigator.of(context).pop(a),
              ),
            const Divider(),
            ListTile(
              key: const Key('gallery-item-remove'),
              leading: Icon(
                Icons.delete_outline_rounded,
                color: ZenColors.of(context).danger,
              ),
              title: Text(
                t('Usuń z galerii'),
                style: TextStyle(color: ZenColors.of(context).danger),
              ),
              onTap: () => Navigator.of(context).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) {
      return;
    }
    if (choice is Audience) {
      if (choice == item.audience) {
        return;
      }
      try {
        await changeGalleryAudience(node, item, choice);
      } on Object catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t('Nie udało się zmienić: {error}', {'error': e})),
            ),
          );
        }
      }
      if (mounted) {
        setState(() {});
      }
      return;
    }
    await _removeMedia(entry);
  }

  Future<void> _removeMedia(LogEntry entry) async {
    final LedgerNode? node = ref.read(ledgerNodeProvider);
    if (node == null) {
      return;
    }
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(t('Usunąć z galerii?')),
        content: Text(
          t(
            'Zniknie z Twojego profilu. Znajomi, którzy już to pobrali, mogą '
            'mieć kopię.',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(t('Anuluj')),
          ),
          FilledButton(
            key: const Key('gallery-remove-confirm'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(t('Usuń')),
          ),
        ],
      ),
    );
    if (yes ?? false) {
      await removeFromGallery(node, entry.id);
      if (mounted) {
        setState(() {});
      }
    }
  }
}

/// The pinned tab bar under the profile header.
class _TabsHeader extends SliverPersistentHeaderDelegate {
  _TabsHeader({required this.tabs, required this.color, required this.line});

  final TabBar tabs;
  final Color color;
  final Color line;

  @override
  double get minExtent => tabs.preferredSize.height;

  @override
  double get maxExtent => tabs.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrink, bool overlaps) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          border: Border(bottom: BorderSide(color: line)),
        ),
        child: tabs,
      );

  @override
  bool shouldRebuild(_TabsHeader old) => old.color != color || old.line != line;
}

/// The photo in a ring of the accent colours, cut out of the cover.
class _AvatarRing extends StatelessWidget {
  const _AvatarRing({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[zen.accent, zen.accentSecondary],
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: zen.accent.withValues(alpha: 0.28),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: zen.background,
        ),
        child: child,
      ),
    );
  }
}

/// The cover when there is no photo: a soft gradient with a few bubbles.
class _DefaultCover extends StatelessWidget {
  const _DefaultCover();

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    Widget bubble(double size, Color c) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: <Color>[c.withValues(alpha: 0.35), c.withValues(alpha: 0)],
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: <Color>[
            Color.alphaBlend(zen.accent.withValues(alpha: 0.45), zen.surface),
            Color.alphaBlend(
              zen.accentSecondary.withValues(alpha: 0.30),
              zen.surface,
            ),
            Color.alphaBlend(
              zen.accentTertiary.withValues(alpha: 0.22),
              zen.surface,
            ),
          ],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: <Widget>[
          Positioned(
            left: -30,
            top: -40,
            child: bubble(160, zen.accentSecondary),
          ),
          Positioned(
            right: -20,
            top: -10,
            child: bubble(130, zen.accentTertiary),
          ),
          Positioned(right: 80, bottom: -60, child: bubble(140, zen.accent)),
        ],
      ),
    );
  }
}

/// Three numbers under the name: posts, gallery, thanks.
class _ProfileStats extends StatelessWidget {
  const _ProfileStats({
    required this.posts,
    required this.media,
    required this.thanks,
  });

  final int posts;
  final int media;
  final int thanks;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    Widget stat(int value, String label, Color tone) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '$value',
              maxLines: 1,
              style: zen.display(
                color: tone,
                size: 20,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
    Widget divider() => Container(width: 1, height: 28, color: zen.outlineSoft);
    return Container(
      decoration: BoxDecoration(
        color: zen.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Row(
        children: <Widget>[
          stat(posts, t('Wpisy'), zenTone(zen, 0)),
          divider(),
          stat(media, t('W galerii'), zenTone(zen, 2)),
          divider(),
          stat(thanks, t('Dzięki'), zenTone(zen, 5)),
        ],
      ),
    );
  }
}

/// One gratitude card on the profile.
class _ThanksTile extends StatelessWidget {
  const _ThanksTile({required this.card});

  final ThanksCard card;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color tone = zenTone(zen, 5);
    return ZenCard(
      tone: tone,
      padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ZenIconBadge(
            icon: Icons.volunteer_activism_rounded,
            tone: tone,
            size: 40,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  card.text,
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontSize: 15,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  t('od: {name}', {'name': card.fromLabel}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A picture from someone's profile entry (the cover), once downloaded.
class _LedgerImage extends StatefulWidget {
  const _LedgerImage({required this.node, required this.ref, super.key});

  final LedgerNode node;
  final MediaRef ref;

  @override
  State<_LedgerImage> createState() => _LedgerImageState();
}

class _LedgerImageState extends State<_LedgerImage> {
  Uint8List? _bytes;
  StreamSubscription<String>? _done;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _done = widget.node.mediaCompleted.listen((String id) {
      if (id == widget.ref.id) {
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
      // Not a picture: the placeholder stays.
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
    return bytes == null
        ? ColoredBox(color: ZenColors.of(context).surfaceSunk)
        : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true);
  }
}

/// Photo from someone's public profile (not a friend: no profile_update).
class _LedgerAvatar extends StatefulWidget {
  const _LedgerAvatar({required this.node, required this.ref});

  final LedgerNode node;
  final MediaRef ref;

  @override
  State<_LedgerAvatar> createState() => _LedgerAvatarState();
}

class _LedgerAvatarState extends State<_LedgerAvatar> {
  Uint8List? _bytes;
  StreamSubscription<String>? _done;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _done = widget.node.mediaCompleted.listen((String id) {
      if (id == widget.ref.id) {
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
      // Not a picture: the placeholder stays.
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
    return CircleAvatar(
      key: const Key('profile-ledger-avatar'),
      radius: 46,
      backgroundImage: bytes == null ? null : MemoryImage(bytes),
      backgroundColor: ZenColors.of(context).surfaceSunk,
      child: bytes == null
          ? Icon(
              Icons.person_rounded,
              size: 40,
              color: ZenColors.of(context).textMuted,
            )
          : null,
    );
  }
}

/// A post on a profile: date, text, photos and how it was received.
class _ProfilePost extends StatelessWidget {
  const _ProfilePost({
    required this.post,
    required this.node,
    this.onEdit,
    this.onDelete,
    this.onReport,
  });

  final FeedPost post;
  final LedgerNode? node;

  /// Your own post: change it or take it down.
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  /// Someone else's post: "Zgłoś" (§21.4).
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final LedgerNode? n = node;
    final String when = postTimeLabel(post.millis, withYear: true);
    return Container(
      key: Key('profile-post-${post.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
      decoration: BoxDecoration(
        color: zen.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.schedule_rounded, size: 15, color: zen.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  post.edited ? t('{time} · edytowano', {'time': when}) : when,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: zen.textSecondary, fontSize: 12.5),
                ),
              ),
              if (post.audience != Audience.public)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    kAudienceIcons[post.audience],
                    size: 15,
                    color: zen.textMuted,
                  ),
                ),
              if (onEdit != null || onDelete != null || onReport != null)
                PopupMenuButton<String>(
                  key: Key('profile-post-menu-${post.id}'),
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
                    _ => onReport,
                  })?.call(),
                  itemBuilder: (BuildContext context) =>
                      <PopupMenuEntry<String>>[
                        if (onEdit != null)
                          PopupMenuItem<String>(
                            key: const Key('profile-post-edit'),
                            value: 'edit',
                            child: ListTile(
                              leading: const Icon(Icons.edit_outlined),
                              title: Text(t('Edytuj')),
                            ),
                          ),
                        if (onDelete != null)
                          PopupMenuItem<String>(
                            key: const Key('profile-post-delete'),
                            value: 'delete',
                            child: ListTile(
                              leading: const Icon(Icons.delete_outline_rounded),
                              title: Text(t('Usuń')),
                            ),
                          ),
                        if (onReport != null)
                          PopupMenuItem<String>(
                            key: const Key('profile-post-report'),
                            value: 'report',
                            child: ListTile(
                              leading: const Icon(Icons.flag_outlined),
                              title: Text(t('Zgłoś')),
                            ),
                          ),
                      ],
                )
              else
                const SizedBox(height: 40),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: n != null
                ? PostContent(post: post, node: n)
                : Text(
                    plainText(post.text),
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.45,
                      color: zen.textPrimary,
                    ),
                  ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              ZenPill(
                icon: Icons.favorite_rounded,
                text: '${post.likers.length}',
                tone: zen.danger,
              ),
              ZenPill(
                icon: Icons.mode_comment_rounded,
                text: '${post.comments.length}',
                tone: zen.accent,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
