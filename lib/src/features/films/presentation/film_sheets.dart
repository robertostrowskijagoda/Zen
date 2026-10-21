import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/feed_model.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart'
    show postTimeLabel;
import 'package:zen/src/features/films/film_controller.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/presentation/film_page.dart';

/// A sheet from the bottom edge in the look of the theme.
Future<T?> _sheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      shape: context.zenSheetShape(),
      builder: builder,
    );

class _SheetTitle extends StatelessWidget {
  const _SheetTitle({required this.icon, required this.title, this.count});

  final IconData icon;
  final String title;
  final int? count;

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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: zen.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (count != null) ...<Widget>[
          const SizedBox(width: 8),
          ZenPill(text: '$count'),
        ],
      ],
    );
  }
}

/// The comments of [film] (kept up to date while open) and a field to
/// write one. [onReport] reports a comment ("Zgłoś").
Future<void> showFilmComments(
  BuildContext context, {
  required FilmsBackend backend,
  required FilmPost film,
  required Future<void> Function(FeedComment comment) onReport,
  bool Function(FeedComment comment)? hidden,
}) {
  final TextEditingController field = TextEditingController();
  return _sheet<void>(context, (BuildContext sheet) {
    String? error;
    bool sending = false;
    return StatefulBuilder(
      builder: (BuildContext sheet, StateSetter setSheet) {
        return ListenableBuilder(
          listenable: backend,
          builder: (BuildContext sheet, Widget? child) {
            final ZenColors zen = ZenColors.of(sheet);
            final FilmPost now = backend.byId(film.id) ?? film;
            final List<FeedComment> shown = <FeedComment>[
              for (final FeedComment c in now.comments)
                if (!(hidden?.call(c) ?? false)) c,
            ];
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(sheet).viewInsets.bottom,
              ),
              child: SafeArea(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(sheet).height * 0.75,
                  ),
                  child: Column(
                    key: const Key('film-comments-sheet'),
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: _SheetTitle(
                          icon: Icons.mode_comment_rounded,
                          title: t('Komentarze'),
                          count: now.commentCount,
                        ),
                      ),
                      Flexible(
                        child: shown.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.all(16),
                                child: ZenEmpty(
                                  icon: Icons.forum_outlined,
                                  title: t('Jeszcze nic.'),
                                  text: t('Napisz pierwszy komentarz.'),
                                ),
                              )
                            : ListView(
                                shrinkWrap: true,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                children: <Widget>[
                                  for (final FeedComment c in shown)
                                    _CommentTile(
                                      comment: c,
                                      // Own comments carry no address.
                                      onReport: c.authorAddress.isEmpty
                                          ? null
                                          : () => unawaited(onReport(c)),
                                    ),
                                ],
                              ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Expanded(
                              child: TextField(
                                key: const Key('film-comment-field'),
                                controller: field,
                                maxLength: kMaxCommentChars,
                                minLines: 1,
                                maxLines: 4,
                                textCapitalization:
                                    TextCapitalization.sentences,
                                decoration: InputDecoration(
                                  hintText: t('Napisz komentarz'),
                                  counterText: '',
                                  errorText: error,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            IconButton.filled(
                              key: const Key('film-comment-send'),
                              tooltip: t('Wyślij'),
                              icon: const Icon(Icons.send_rounded),
                              color: zen.onAccent,
                              onPressed: sending
                                  ? null
                                  : () async {
                                      setSheet(() => sending = true);
                                      final String? failed = await backend
                                          .comment(now, field.text);
                                      if (!sheet.mounted) {
                                        return;
                                      }
                                      setSheet(() {
                                        sending = false;
                                        error = failed;
                                        if (failed == null) {
                                          field.clear();
                                        }
                                      });
                                    },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }).whenComplete(() => disposeLater(field));
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({required this.comment, this.onReport});

  final FeedComment comment;
  final VoidCallback? onReport;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return Padding(
      key: Key('film-comment-${comment.id}'),
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          FilmInitials(name: comment.authorLabel, size: 34),
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              decoration: BoxDecoration(
                color: zen.surfaceMuted,
                borderRadius: ZenLook.of(context).bubbleRadius(outgoing: false),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          comment.hiddenByAuthor
                              ? t('{name} · ukryty', {
                                  'name': comment.authorLabel,
                                })
                              : comment.authorLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: zen.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13.5,
                          ),
                        ),
                        const SizedBox(height: 3),
                        SelectableText(
                          comment.text,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.35,
                            color: zen.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          postTimeLabel(comment.millis),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: zen.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onReport != null)
                    IconButton(
                      key: Key('film-comment-report-${comment.id}'),
                      tooltip: t('Zgłoś'),
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.flag_outlined,
                        size: 18,
                        color: zen.textMuted,
                      ),
                      onPressed: onReport,
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The reactions of [film]: how many of each, and a tap to react (the
/// same one again takes it back).
Future<void> showFilmReactions(
  BuildContext context, {
  required FilmsBackend backend,
  required FilmPost film,
  required void Function(String? error) onDone,
}) {
  return _sheet<void>(context, (BuildContext sheet) {
    final ZenColors zen = ZenColors.of(sheet);
    return SafeArea(
      child: Padding(
        key: const Key('film-reactions-sheet'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _SheetTitle(icon: Icons.add_reaction_rounded, title: t('Reakcje')),
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                for (final String emoji in kFilmReactions)
                  ChoiceChip(
                    key: Key('film-reaction-$emoji'),
                    selected: film.myReaction == emoji,
                    selectedColor: zen.accentSoft,
                    label: Text(
                      '$emoji ${film.reactions[emoji] ?? 0}',
                      style: const TextStyle(fontSize: 18),
                    ),
                    onSelected: (_) async {
                      final NavigatorState nav = Navigator.of(sheet);
                      final String? error = await backend.react(film, emoji);
                      nav.pop();
                      onDone(error);
                    },
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  });
}

/// What "⋯" offers.
enum FilmMenuChoice { report, hide, delete, likes }

/// The menu of [film]: its likes, and report and hide for someone else's
/// film, delete for one's own.
Future<FilmMenuChoice?> showFilmMenu(
  BuildContext context, {
  required FilmPost film,
}) {
  return _sheet<FilmMenuChoice>(context, (BuildContext sheet) {
    return SafeArea(
      child: Column(
        key: const Key('film-menu'),
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ListTile(
            key: const Key('film-menu-likes'),
            leading: const Icon(Icons.favorite_border_rounded),
            title: Text(t('Kto lubi')),
            onTap: () => Navigator.of(sheet).pop(FilmMenuChoice.likes),
          ),
          if (!film.isOwn) ...<Widget>[
            ListTile(
              key: const Key('film-menu-hide'),
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(t('Ukryj ten film')),
              onTap: () => Navigator.of(sheet).pop(FilmMenuChoice.hide),
            ),
            ListTile(
              key: const Key('film-menu-report'),
              leading: const Icon(Icons.flag_outlined),
              title: Text(t('Zgłoś')),
              onTap: () => Navigator.of(sheet).pop(FilmMenuChoice.report),
            ),
          ],
          if (film.isOwn)
            ListTile(
              key: const Key('film-menu-delete'),
              leading: const Icon(Icons.delete_outline_rounded),
              title: Text(t('Usuń')),
              onTap: () => Navigator.of(sheet).pop(FilmMenuChoice.delete),
            ),
        ],
      ),
    );
  });
}

/// Who likes [film] (names only: this account and friends).
Future<void> showFilmLikers(BuildContext context, {required FilmPost film}) {
  return _sheet<void>(context, (BuildContext sheet) {
    final ZenColors zen = ZenColors.of(sheet);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * 0.6,
        ),
        child: ListView(
          key: const Key('film-likers'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: <Widget>[
            _SheetTitle(
              icon: Icons.favorite_rounded,
              title: t('Kto lubi'),
              count: film.likeCount,
            ),
            const SizedBox(height: 8),
            if (film.likes.isEmpty)
              Text(
                t('Jeszcze nic.'),
                style: TextStyle(color: zen.textSecondary),
              ),
            for (final FeedLiker l in film.likes)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: FilmInitials(name: l.name, size: 36),
                title: Text(
                  l.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
        ),
      ),
    );
  });
}

/// A friend to send a film to: name and address.
typedef FilmShareTarget = ({String address, String name});

/// Picks the friend to send [film] to in a chat.
Future<FilmShareTarget?> showFilmShareTargets(
  BuildContext context, {
  required List<FilmShareTarget> friends,
}) {
  return _sheet<FilmShareTarget>(context, (BuildContext sheet) {
    final ZenColors zen = ZenColors.of(sheet);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * 0.7,
        ),
        child: ListView(
          key: const Key('film-share-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: <Widget>[
            _SheetTitle(icon: Icons.send_rounded, title: t('Wyślij na czat')),
            const SizedBox(height: 8),
            if (friends.isEmpty)
              Text(
                t('Nie masz jeszcze znajomych.'),
                style: TextStyle(color: zen.textSecondary),
              ),
            for (final FilmShareTarget f in friends)
              ListTile(
                key: Key('film-share-${f.address}'),
                contentPadding: EdgeInsets.zero,
                leading: FilmInitials(name: f.name, size: 36),
                title: Text(
                  f.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(sheet).pop(f),
              ),
          ],
        ),
      ),
    );
  });
}

/// The films answering [film]; picks one to show.
Future<FilmPost?> showFilmReplies(
  BuildContext context, {
  required List<FilmPost> replies,
}) {
  return _sheet<FilmPost>(context, (BuildContext sheet) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheet).height * 0.7,
        ),
        child: ListView(
          key: const Key('film-replies-sheet'),
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: <Widget>[
            _SheetTitle(
              icon: Icons.video_library_rounded,
              title: t('Odpowiedzi filmem'),
              count: replies.length,
            ),
            const SizedBox(height: 8),
            for (final FilmPost r in replies)
              ListTile(
                key: Key('film-reply-item-${r.id}'),
                contentPadding: EdgeInsets.zero,
                leading: FilmInitials(
                  name: r.authorLabel,
                  own: r.isOwn,
                  size: 36,
                ),
                title: Text(
                  r.authorLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  r.caption.isEmpty ? postTimeLabel(r.millis) : r.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.of(sheet).pop(r),
              ),
          ],
        ),
      ),
    );
  });
}
