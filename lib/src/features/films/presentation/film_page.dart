import 'dart:async';

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/presentation/feed_screen.dart'
    show postTimeLabel;
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/presentation/film_player.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';

/// What a page can ask the screen to do with its film.
@immutable
final class FilmPageActions {
  const FilmPageActions({
    required this.onLike,
    required this.onComments,
    required this.onReactions,
    required this.onShare,
    required this.onReply,
    required this.onMore,
    required this.onAuthor,
    required this.onOriginal,
    required this.onReplies,
    required this.onWatched,
  });

  final void Function(FilmPost film) onLike;
  final void Function(FilmPost film) onComments;
  final void Function(FilmPost film) onReactions;
  final void Function(FilmPost film) onShare;
  final void Function(FilmPost film) onReply;
  final void Function(FilmPost film) onMore;
  final void Function(FilmPost film) onAuthor;

  /// The film this one answers.
  final void Function(FilmReplyRef ref) onOriginal;

  /// The films answering this one.
  final void Function(FilmPost film) onReplies;
  final void Function(FilmPost film) onWatched;
}

/// One film of the pager, full screen: the film, a heart on a double tap,
/// a pause while held or after a tap, the author and caption at the bottom,
/// the actions on the right and the progress along the bottom edge.
class FilmPage extends StatefulWidget {
  const FilmPage({
    required this.film,
    required this.active,
    required this.preload,
    required this.muted,
    required this.player,
    required this.actions,
    super.key,
  });

  final FilmPost film;
  final bool active;
  final bool preload;
  final bool muted;
  final FilmPlayerBuilder player;
  final FilmPageActions actions;

  @override
  State<FilmPage> createState() => _FilmPageState();
}

class _FilmPageState extends State<FilmPage>
    with SingleTickerProviderStateMixin {
  final ValueNotifier<double> _progress = ValueNotifier<double>(0);
  bool _tapPaused = false;
  bool _held = false;
  Offset? _heartAt;
  late final AnimationController _heart = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );

  @override
  void didUpdateWidget(FilmPage old) {
    super.didUpdateWidget(old);
    if (!widget.active && old.active) {
      // Back on screen later: it plays again.
      _tapPaused = false;
      _held = false;
    }
  }

  @override
  void dispose() {
    _progress.dispose();
    _heart.dispose();
    super.dispose();
  }

  void _doubleTap(Offset at) {
    setState(() => _heartAt = at);
    unawaited(_heart.forward(from: 0));
    if (!widget.film.likedByMe) {
      widget.actions.onLike(widget.film);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FilmPost film = widget.film;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ZenColors zen = ZenColors.of(context);
    final Color scrim = scheme.scrim;
    final Color ink = ZenColors.foregroundFor(scrim);
    final bool paused = _tapPaused || _held;
    final TextStyle shadowed = TextStyle(
      color: ink,
      shadows: <Shadow>[
        Shadow(color: scrim.withValues(alpha: 0.8), blurRadius: 6),
      ],
    );
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        widget.player(
          context,
          FilmPlayerRequest(
            film: film,
            active: widget.active,
            preload: widget.preload,
            paused: paused,
            muted: widget.muted,
            onProgress: (double f) => _progress.value = f,
            onWatched: () => widget.actions.onWatched(film),
          ),
        ),
        // Shade at the bottom so the caption reads on any film.
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          height: 260,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: <Color>[
                    scrim.withValues(alpha: 0.65),
                    scrim.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
        GestureDetector(
          key: Key('film-surface-${film.id}'),
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _tapPaused = !_tapPaused),
          onDoubleTapDown: (TapDownDetails d) => _heartAt = d.localPosition,
          onDoubleTap: () => _doubleTap(_heartAt ?? Offset.zero),
          onLongPressStart: (_) => setState(() => _held = true),
          onLongPressEnd: (_) => setState(() => _held = false),
          onLongPressCancel: () => setState(() => _held = false),
        ),
        if (paused)
          IgnorePointer(
            child: Center(
              child: Icon(
                Icons.play_arrow_rounded,
                key: Key('film-paused-${film.id}'),
                size: 84,
                color: ink.withValues(alpha: 0.85),
              ),
            ),
          ),
        if (_heartAt != null)
          AnimatedBuilder(
            animation: _heart,
            builder: (BuildContext context, Widget? child) {
              final double v = _heart.value;
              if (v <= 0 || v >= 1) {
                return const SizedBox.shrink();
              }
              return Positioned(
                left: _heartAt!.dx - 48,
                top: _heartAt!.dy - 48 - 40 * v,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1 - v).clamp(0.0, 1.0).toDouble(),
                    child: Transform.scale(
                      scale: 0.6 + 0.8 * Curves.easeOutBack.transform(v),
                      child: Icon(
                        Icons.favorite_rounded,
                        size: 96,
                        color: zen.accent,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        Positioned(
          right: 8,
          bottom: 28,
          child: _Rail(film: film, ink: ink, actions: widget.actions),
        ),
        Positioned(
          left: 16,
          right: 88,
          bottom: 24,
          child: _Caption(film: film, style: shadowed, actions: widget.actions),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (BuildContext context, double value, Widget? child) =>
                LinearProgressIndicator(
                  key: Key('film-progress-${film.id}'),
                  value: value,
                  minHeight: 3,
                  color: zen.accent,
                  backgroundColor: ink.withValues(alpha: 0.18),
                ),
          ),
        ),
      ],
    );
  }
}

/// The actions on the right of a film.
class _Rail extends StatelessWidget {
  const _Rail({required this.film, required this.ink, required this.actions});

  final FilmPost film;
  final Color ink;
  final FilmPageActions actions;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int reacted = film.reactions.values.fold<int>(
      0,
      (int a, int b) => a + b,
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Semantics(
          button: true,
          label: film.authorLabel,
          child: GestureDetector(
            key: Key('film-author-${film.id}'),
            onTap: () => actions.onAuthor(film),
            child: FilmInitials(name: film.authorLabel, own: film.isOwn),
          ),
        ),
        const SizedBox(height: 14),
        FilmRailButton(
          key: Key('film-like-${film.id}'),
          icon: film.likedByMe
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          color: film.likedByMe ? zen.accent : ink,
          label: '${film.likeCount}',
          tooltip: film.likedByMe ? t('Cofnij polubienie') : t('Polub'),
          onTap: () => actions.onLike(film),
        ),
        FilmRailButton(
          key: Key('film-comments-${film.id}'),
          icon: Icons.mode_comment_rounded,
          color: ink,
          label: '${film.commentCount}',
          tooltip: t('Komentarze'),
          onTap: () => actions.onComments(film),
        ),
        FilmRailButton(
          key: Key('film-react-${film.id}'),
          icon: film.myReaction.isEmpty ? Icons.add_reaction_outlined : null,
          emoji: film.myReaction.isEmpty ? null : film.myReaction,
          color: ink,
          label: '$reacted',
          tooltip: t('Reakcje'),
          onTap: () => actions.onReactions(film),
        ),
        FilmRailButton(
          key: Key('film-reply-${film.id}'),
          icon: Icons.video_call_rounded,
          color: ink,
          label: film.replies.isEmpty ? '' : '${film.replies.length}',
          tooltip: t('Odpowiedz filmem'),
          onTap: () => actions.onReply(film),
        ),
        FilmRailButton(
          key: Key('film-share-${film.id}'),
          icon: Icons.send_rounded,
          color: ink,
          label: '',
          tooltip: t('Wyślij na czat'),
          onTap: () => actions.onShare(film),
        ),
        FilmRailButton(
          key: Key('film-more-${film.id}'),
          icon: Icons.more_horiz_rounded,
          color: ink,
          label: '',
          tooltip: film.isOwn ? t('Edytuj lub usuń') : t('Więcej'),
          onTap: () => actions.onMore(film),
        ),
      ],
    );
  }
}

/// A round button of the rail with a count under it.
class FilmRailButton extends StatelessWidget {
  const FilmRailButton({
    required this.color,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.icon,
    this.emoji,
    super.key,
  });

  final IconData? icon;
  final String? emoji;
  final Color color;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Color scrim = Theme.of(context).colorScheme.scrim;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 30,
          child: SizedBox(
            width: 64,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (emoji != null)
                  Text(emoji!, style: const TextStyle(fontSize: 30))
                else
                  Icon(
                    icon,
                    size: 34,
                    color: color,
                    shadows: <Shadow>[
                      Shadow(
                        color: scrim.withValues(alpha: 0.7),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                if (label.isNotEmpty)
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: color,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      shadows: <Shadow>[
                        Shadow(
                          color: scrim.withValues(alpha: 0.8),
                          blurRadius: 4,
                        ),
                      ],
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

/// Author, time, caption and the links to answers at the bottom of a film.
class _Caption extends StatelessWidget {
  const _Caption({
    required this.film,
    required this.style,
    required this.actions,
  });

  final FilmPost film;
  final TextStyle style;
  final FilmPageActions actions;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final List<String> meta = <String>[
      postTimeLabel(film.millis),
      if (film.fromFriendOfFriend)
        t('przez {names}', {'names': film.passedBy.take(2).join(', ')}),
      if (film.isOwn) kAudienceLabels[film.audience] ?? '',
    ];
    final List<MapEntry<String, int>> reactions =
        film.reactions.entries
            .where((MapEntry<String, int> e) => e.value > 0)
            .toList()
          ..sort(
            (MapEntry<String, int> a, MapEntry<String, int> b) =>
                b.value.compareTo(a.value),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (film.replyTo != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _Chip(
              key: Key('film-original-${film.id}'),
              icon: Icons.reply_rounded,
              text: t('Odpowiedź na film'),
              onTap: () => actions.onOriginal(film.replyTo!),
            ),
          ),
        Text(
          film.authorLabel,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        Text(
          meta.where((String s) => s.isNotEmpty).join(' · '),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: style.copyWith(fontSize: 12.5),
        ),
        if (film.caption.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SelectableText(
              film.caption,
              key: Key('film-caption-${film.id}'),
              maxLines: 4,
              style: style.copyWith(fontSize: 14.5, height: 1.3),
            ),
          ),
        if (reactions.isNotEmpty || film.isOwn || film.replies.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                for (final MapEntry<String, int> r in reactions.take(4))
                  Text(
                    '${r.key} ${r.value}',
                    style: style.copyWith(fontSize: 13),
                  ),
                if (film.isOwn)
                  Text(
                    tn(
                      film.views,
                      one: '{n} wyświetlenie',
                      few: '{n} wyświetlenia',
                      many: '{n} wyświetleń',
                    ),
                    key: Key('film-views-${film.id}'),
                    style: style.copyWith(fontSize: 13, color: zen.accent),
                  ),
                if (film.replies.isNotEmpty)
                  _Chip(
                    key: Key('film-replies-${film.id}'),
                    icon: Icons.video_library_rounded,
                    text: tn(
                      film.replies.length,
                      one: '{n} odpowiedź filmem',
                      few: '{n} odpowiedzi filmem',
                      many: '{n} odpowiedzi filmem',
                    ),
                    onTap: () => actions.onReplies(film),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.text,
    required this.onTap,
    super.key,
  });

  final IconData icon;
  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = ZenColors.foregroundFor(scheme.scrim);
    return Material(
      color: scheme.scrim.withValues(alpha: 0.45),
      shape: ZenLook.of(context).chipBorder(ZenColors.of(context)),
      child: InkWell(
        onTap: onTap,
        customBorder: ZenLook.of(context).chipBorder(ZenColors.of(context)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 16, color: ink),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
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

/// A round avatar with the first letter of [name], in the theme's tones.
class FilmInitials extends StatelessWidget {
  const FilmInitials({
    required this.name,
    this.own = false,
    this.size = 48,
    super.key,
  });

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
        shape: ZenLook.of(context).sharp ? BoxShape.rectangle : BoxShape.circle,
        border: Border.all(
          color: zen.onAccent.withValues(alpha: 0.9),
          width: 2,
        ),
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
