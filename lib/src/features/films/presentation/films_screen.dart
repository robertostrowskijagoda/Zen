import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/domain/friends/friend_profile.dart';
import 'package:zen/src/domain/messages/chat_message.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_controller.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_publish.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/films/presentation/film_camera_plugin.dart';
import 'package:zen/src/features/films/presentation/film_editor_screen.dart';
import 'package:zen/src/features/films/presentation/film_page.dart';
import 'package:zen/src/features/films/presentation/film_pager.dart';
import 'package:zen/src/features/films/presentation/film_player.dart';
import 'package:zen/src/features/films/presentation/film_recorder_screen.dart';
import 'package:zen/src/features/films/presentation/film_sheets.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/ledger/ledger_node.dart';
import 'package:zen/src/features/ledger/ledger_providers.dart';
import 'package:zen/src/features/moderation/content_moderation.dart';
import 'package:zen/src/features/moderation/hidden_by_me.dart';
import 'package:zen/src/features/moderation/local_delete.dart';
import 'package:zen/src/features/moderation/presentation/report_content.dart';
import 'package:zen/src/features/profile/presentation/profile_screen.dart';
import 'package:zen/src/features/relay/relay_engine.dart';
import 'package:zen/src/features/relay/relay_providers.dart';
import 'package:zen/src/features/social/social_hub_controller.dart';
import 'package:zen/src/features/social/social_hub_state.dart';

/// The "Filmy" tab: short vertical films from friends (and, when the
/// person wants, public films friends passed on), one after another full
/// screen, with a camera of its own to answer with a film.
class FilmsScreen extends ConsumerStatefulWidget {
  const FilmsScreen({
    this.backend,
    this.player,
    this.camera,
    this.pickFile,
    super.key,
  });

  /// The films (tests); the ledger's when null.
  final FilmsBackend? backend;

  /// The player of each page (tests); the real one when null.
  final FilmPlayerBuilder? player;
  final FilmCameraFactory? camera;
  final FilmFilePicker? pickFile;

  @override
  ConsumerState<FilmsScreen> createState() => _FilmsScreenState();
}

class _FilmsScreenState extends ConsumerState<FilmsScreen>
    with WidgetsBindingObserver {
  FilmsBackend? _backend;
  FilmsController? _own;
  LedgerNode? _node;
  bool _resumed = true;

  /// A sheet of this screen is open: the film keeps playing under it.
  int _sheets = 0;

  /// Films shown anyway after being hidden.
  final Set<String> _revealed = <String>{};
  Audience _audience = Audience.all;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _backend = widget.backend;
    if (_backend == null) {
      final LedgerNode? node = ref.read(ledgerNodeProvider);
      _node = node;
      if (node != null) {
        final RelayEngine? relay = ref.read(relayEngineProvider);
        final FilmsController c = FilmsController(
          node: node,
          disk: ref.read(ledgerDiskProvider),
          nameOf: _nameOf,
          mailboxes: relay?.announcedMailboxes,
        );
        _own = c;
        _backend = c;
        unawaited(c.start());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _own?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final bool resumed = state == AppLifecycleState.resumed;
    if (resumed != _resumed && mounted) {
      setState(() => _resumed = resumed);
    }
  }

  String _nameOf(String address) {
    final SocialHubState state = ref.read(socialHubControllerProvider);
    final FriendProfile? friend = state.friendByAddress(address);
    return friend == null ? address : state.nameFor(friend);
  }

  void _say(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<T> _inSheet<T>(Future<T> Function() open) async {
    setState(() => _sheets++);
    try {
      return await open();
    } finally {
      if (mounted) {
        setState(() => _sheets--);
      }
    }
  }

  // ---- actions ----

  Future<void> _like(FilmPost film) async {
    final String? error = await _backend!.toggleLike(film);
    if (error != null) {
      _say(t('Nie udało się polubić: {error}', {'error': error}));
    }
  }

  Future<void> _comments(FilmPost film) => _inSheet(
    () => showFilmComments(
      context,
      backend: _backend!,
      film: film,
      hidden: (FeedComment c) => ref.read(hiddenByMeProvider).hides(id: c.id),
      onReport: (FeedComment c) => reportContent(
        context,
        ref,
        authorAddress: c.authorAddress,
        text: c.text,
        header: t('Komentarz — {name}', {'name': c.authorLabel}),
        contentId: c.id,
      ),
    ),
  );

  Future<void> _reactions(FilmPost film) => _inSheet(
    () => showFilmReactions(
      context,
      backend: _backend!,
      film: film,
      onDone: (String? error) {
        if (error != null) {
          _say(t('Nie udało się: {error}', {'error': error}));
        }
      },
    ),
  );

  Future<void> _share(FilmPost film) async {
    if (!film.isOwn && film.audience != Audience.public) {
      // Sending the file would show it to someone outside its audience.
      _say(t('Wysłać na czat można tylko własny lub publiczny film.'));
      return;
    }
    final SocialHubState social = ref.read(socialHubControllerProvider);
    final List<FilmShareTarget> friends = <FilmShareTarget>[
      for (final FriendProfile f in social.acceptedFriends)
        (address: f.address, name: social.nameFor(f)),
    ];
    final FilmShareTarget? to = await _inSheet(
      () => showFilmShareTargets(context, friends: friends),
    );
    if (to == null || !mounted) {
      return;
    }
    final Uint8List? bytes;
    try {
      bytes = await _backend!.filmBytes(film);
    } on Object {
      _say(t('Nieprawidłowy plik filmu — nie otwarto go.'));
      return;
    }
    if (bytes == null) {
      _say(t('Film jeszcze się pobiera…'));
      return;
    }
    try {
      await ref
          .read(socialHubControllerProvider.notifier)
          .sendLocalAttachment(
            peerAddress: to.address,
            bytes: bytes,
            fileName: 'film.mp4',
            mimeType: 'video/mp4',
            displayName: to.name,
            type: ChatMessageType.video,
            durationMs: film.video.durationMs,
          );
      _say(t('Wysłano do: {name}', {'name': to.name}));
    } on Object catch (e) {
      _say(t('Nie udało się wysłać: {error}', {'error': e}));
    }
  }

  Future<void> _more(FilmPost film) async {
    final FilmMenuChoice? choice = await _inSheet(
      () => showFilmMenu(context, film: film),
    );
    if (!mounted || choice == null) {
      return;
    }
    switch (choice) {
      case FilmMenuChoice.likes:
        await _inSheet(() => showFilmLikers(context, film: film));
      case FilmMenuChoice.hide:
        await ref.read(hiddenByMeProvider.notifier).hide(<String>[
          HiddenByMe.idKey(film.id),
        ]);
        _revealed.remove(film.id);
      case FilmMenuChoice.report:
        {
          final LedgerNode? node = _node;
          await reportContent(
            context,
            ref,
            authorAddress: film.authorAddress,
            text: film.caption,
            header: t('Film — {name}', {'name': film.authorLabel}),
            contentId: film.id,
            entry: film.entry,
            deleteLocal: node == null
                ? null
                : () => deletePostMediaLocally(node, <MediaRef>[
                    film.video,
                    ?film.poster,
                  ]),
          );
        }
      case FilmMenuChoice.delete:
        {
          final bool sure =
              await showDialog<bool>(
                context: context,
                builder: (BuildContext dialog) => AlertDialog(
                  title: Text(t('Usunąć film?')),
                  actions: <Widget>[
                    TextButton(
                      onPressed: () => Navigator.of(dialog).pop(false),
                      child: Text(t('Anuluj')),
                    ),
                    FilledButton(
                      key: const Key('film-delete-confirm'),
                      onPressed: () => Navigator.of(dialog).pop(true),
                      child: Text(t('Usuń')),
                    ),
                  ],
                ),
              ) ??
              false;
          if (sure) {
            final String? error = await _backend!.delete(film);
            if (error != null) {
              _say(t('Nie udało się usunąć: {error}', {'error': error}));
            }
          }
        }
    }
    if (mounted) {
      setState(() {});
    }
  }

  void _author(FilmPost film) {
    if (film.isOwn) {
      unawaited(ProfileScreen.open(context));
    } else if (film.authorAddress.isNotEmpty) {
      unawaited(ProfileScreen.open(context, address: film.authorAddress));
    }
  }

  void _original(FilmReplyRef to) {
    if (_backend!.byId(to.id) == null) {
      _say(t('Tego filmu tu nie ma.'));
      return;
    }
    _backend!.focus(to.id);
  }

  Future<void> _replies(FilmPost film) async {
    final List<FilmPost> replies = <FilmPost>[
      for (final String id in film.replies) ?_backend!.byId(id),
    ];
    final FilmPost? pick = await _inSheet(
      () => showFilmReplies(context, replies: replies),
    );
    if (pick != null) {
      _backend!.focus(pick.id);
    }
  }

  Future<void> _record({FilmPost? replyTo}) async {
    final FilmsBackend? backend = _backend;
    if (backend == null) {
      return;
    }
    final FilmRecording? rec = await FilmRecorderScreen.open(
      context,
      camera: (widget.camera ?? defaultFilmCamera)(),
      pickFile: widget.pickFile ?? pickFilmFile,
      replyToName: replyTo?.authorLabel,
    );
    if (rec == null || !mounted) {
      return;
    }
    final bool canTrim = await backend.canCompress();
    if (!mounted) {
      return;
    }
    bool silent = false;
    final bool published = await FilmEditorScreen.open(
      context,
      path: rec.path,
      recordedMs: rec.recordedMs,
      canTrim: canTrim,
      replyTo: replyTo == null
          ? null
          : FilmReplyRef(id: replyTo.id, account: replyTo.account),
      replyToName: replyTo?.authorLabel,
      initialAudience: _audience,
      publish: (FilmDraft draft, FilmPublishProgress progress) async {
        await backend.publish(
          draft,
          onProgress: (FilmPublishStage stage, double fraction) {
            if (stage == FilmPublishStage.silent) {
              silent = true;
            }
            progress(stage, fraction);
          },
        );
        _audience = draft.audience;
      },
    );
    if (rec.recordedMs > 0) {
      // The camera's own file; a picked one stays where it was.
      unawaited(File(rec.path).delete().then((_) {}, onError: (Object _) {}));
    }
    if (published) {
      _say(
        silent
            ? t(
                'Opublikowano bez dźwięku: na tym komputerze nie ma kodera dźwięku.',
              )
            : t('Opublikowano.'),
      );
    }
  }

  Widget? _hiddenView(FilmPost film) {
    final Set<String> banned = bannedContentNow(ref);
    if (!isContentHidden(
      banned,
      film.caption,
      id: film.id,
      revealed: _revealed,
      mine: ref.read(hiddenByMeProvider),
    )) {
      return null;
    }
    return ColoredBox(
      key: Key('film-hidden-${film.id}'),
      color: ZenColors.of(context).background,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: HiddenContentPlaceholder(
            byMe: !isContentBanned(banned, id: film.id),
            onShow: () {
              showHiddenAnyway(ref, id: film.id);
              setState(() => _revealed.add(film.id));
            },
          ),
        ),
      ),
    );
  }

  Future<void> _settings() async {
    final FilmsBackend backend = _backend!;
    await _inSheet(
      () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        shape: context.zenSheetShape(),
        builder: (BuildContext sheet) => ListenableBuilder(
          listenable: backend,
          builder: (BuildContext sheet, Widget? child) => SafeArea(
            child: SwitchListTile(
              key: const Key('films-fof'),
              value: backend.friendsOfFriends,
              title: Text(t('Filmy znajomych znajomych')),
              subtitle: Text(
                t(
                  'Publiczne filmy, które polubili Twoi znajomi. Ich autorzy nie dowiedzą się, że je oglądasz.',
                ),
              ),
              onChanged: (bool on) =>
                  unawaited(backend.setFriendsOfFriends(on)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final FilmsBackend? backend = _backend;
    if (backend == null) {
      return Scaffold(
        key: const Key('films-screen'),
        body: Center(
          child: ZenEmpty(
            icon: Icons.smart_display_outlined,
            title: t('Filmy są wyłączone.'),
          ),
        ),
      );
    }
    // Watched so a report or "show anyway" rebuilds the page.
    ref.watch(hiddenByMeProvider);
    final bool visible = Visibility.of(context);
    final bool current = ModalRoute.of(context)?.isCurrent ?? true;
    final bool playing = visible && _resumed && (current || _sheets > 0);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = ZenColors.foregroundFor(scheme.scrim);
    final LedgerNode? node = _node;
    final FilmPlayerBuilder player =
        widget.player ??
        (BuildContext context, FilmPlayerRequest request) => node == null
            ? const SizedBox.expand()
            : FilmVideoView(
                key: ValueKey<String>('film-video-${request.film.id}'),
                blobs: node.blobs,
                request: request,
              );
    return Scaffold(
      key: const Key('films-screen'),
      backgroundColor: scheme.scrim,
      body: ListenableBuilder(
        listenable: backend,
        builder: (BuildContext context, Widget? child) {
          final Widget content;
          if (!backend.ready) {
            content = Center(child: CircularProgressIndicator(color: ink));
          } else if (backend.films.isEmpty) {
            content = ColoredBox(
              color: zen.background,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: ZenEmpty(
                    key: const Key('films-empty'),
                    icon: Icons.smart_display_outlined,
                    title: t('Jeszcze nie ma filmów'),
                    text: t(
                      'Nagraj pierwszy albo poczekaj, aż znajomi coś wrzucą.',
                    ),
                    action: FilledButton.icon(
                      key: const Key('films-empty-record'),
                      onPressed: () => unawaited(_record()),
                      icon: const Icon(Icons.videocam_rounded),
                      label: Text(t('Nagraj film')),
                    ),
                  ),
                ),
              ),
            );
          } else {
            content = FilmPager(
              backend: backend,
              player: player,
              playing: playing,
              onRecord: () => unawaited(_record()),
              hiddenView: _hiddenView,
              actions: FilmPageActions(
                onLike: (FilmPost f) => unawaited(_like(f)),
                onComments: (FilmPost f) => unawaited(_comments(f)),
                onReactions: (FilmPost f) => unawaited(_reactions(f)),
                onShare: (FilmPost f) => unawaited(_share(f)),
                onReply: (FilmPost f) => unawaited(_record(replyTo: f)),
                onMore: (FilmPost f) => unawaited(_more(f)),
                onAuthor: _author,
                onOriginal: _original,
                onReplies: (FilmPost f) => unawaited(_replies(f)),
                onWatched: backend.markWatched,
              ),
            );
          }
          final bool overVideo = backend.ready && backend.films.isNotEmpty;
          final Color barInk = overVideo ? ink : zen.textPrimary;
          return Stack(
            fit: StackFit.expand,
            children: <Widget>[
              content,
              SafeArea(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
                    child: Row(
                      children: <Widget>[
                        // Wraps in long languages rather than being cut.
                        Expanded(
                          child: Text(
                            t('Filmy'),
                            softWrap: true,
                            style: zen.display(color: barInk, size: 22),
                          ),
                        ),
                        IconButton(
                          key: const Key('films-sound'),
                          tooltip: backend.muted
                              ? t('Włącz dźwięk')
                              : t('Wycisz'),
                          color: barInk,
                          icon: Icon(
                            backend.muted
                                ? Icons.volume_off_rounded
                                : Icons.volume_up_rounded,
                          ),
                          onPressed: () =>
                              unawaited(backend.setMuted(!backend.muted)),
                        ),
                        IconButton(
                          key: const Key('films-settings'),
                          tooltip: t('Ustawienia'),
                          color: barInk,
                          icon: const Icon(Icons.tune_rounded),
                          onPressed: () => unawaited(_settings()),
                        ),
                        IconButton(
                          key: const Key('films-record'),
                          tooltip: t('Nagraj film'),
                          color: barInk,
                          icon: const Icon(Icons.add_a_photo_rounded),
                          onPressed: () => unawaited(_record()),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
