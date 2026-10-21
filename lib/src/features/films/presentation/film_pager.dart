import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/films/film_controller.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/presentation/film_page.dart';
import 'package:zen/src/features/films/presentation/film_player.dart';

/// The films one after another, full screen: a swipe up shows the next
/// one, a swipe down the one before. The film on screen plays (looped)
/// while [playing]; the next one gets ready. After the last film an end
/// card offers to look again or to record one.
class FilmPager extends StatefulWidget {
  const FilmPager({
    required this.backend,
    required this.player,
    required this.actions,
    required this.playing,
    required this.onRecord,
    this.hiddenView,
    super.key,
  });

  final FilmsBackend backend;
  final FilmPlayerBuilder player;
  final FilmPageActions actions;

  /// The section is on screen and the app in front.
  final bool playing;
  final VoidCallback onRecord;

  /// What stands in for a film hidden after a report or banned by the
  /// pyramid; null shows it.
  final Widget? Function(FilmPost film)? hiddenView;

  @override
  State<FilmPager> createState() => FilmPagerState();
}

class FilmPagerState extends State<FilmPager> {
  late final PageController _pages = PageController(
    initialPage: widget.backend.index,
  );

  @override
  void initState() {
    super.initState();
    widget.backend.addListener(_onBackend);
  }

  @override
  void didUpdateWidget(FilmPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.backend, widget.backend)) {
      oldWidget.backend.removeListener(_onBackend);
      widget.backend.addListener(_onBackend);
    }
  }

  @override
  void dispose() {
    widget.backend.removeListener(_onBackend);
    _pages.dispose();
    super.dispose();
  }

  void _onBackend() {
    if (!mounted) {
      return;
    }
    setState(() {});
    // The film on screen moved (a new film put first, the list read again).
    final int want = widget.backend.index;
    if (_pages.hasClients && (_pages.page?.round() ?? want) != want) {
      _pages.jumpToPage(want);
    }
  }

  /// Shows the film at [index].
  void showIndex(int index) {
    if (_pages.hasClients) {
      _pages.jumpToPage(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<FilmPost> films = widget.backend.films;
    final int current = widget.backend.index;
    return PageView.builder(
      key: const Key('films-pager'),
      controller: _pages,
      scrollDirection: Axis.vertical,
      itemCount: films.length + 1,
      onPageChanged: (int i) {
        if (i < films.length) {
          widget.backend.index = i;
        }
      },
      itemBuilder: (BuildContext context, int i) {
        if (i >= films.length) {
          return _EndCard(
            onAgain: () {
              widget.backend.index = 0;
              _pages.jumpToPage(0);
            },
            onRecord: widget.onRecord,
          );
        }
        final FilmPost film = films[i];
        final Widget? hidden = widget.hiddenView?.call(film);
        if (hidden != null) {
          return hidden;
        }
        return FilmPage(
          key: ValueKey<String>('film-page-${film.id}'),
          film: film,
          active: widget.playing && i == current,
          preload: i == current + 1,
          muted: widget.backend.muted,
          player: widget.player,
          actions: widget.actions,
        );
      },
    );
  }
}

/// After the last film.
class _EndCard extends StatelessWidget {
  const _EndCard({required this.onAgain, required this.onRecord});

  final VoidCallback onAgain;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    return ColoredBox(
      key: const Key('films-end'),
      color: zen.background,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                Icons.check_circle_outline_rounded,
                size: 56,
                color: zen.accent,
              ),
              const SizedBox(height: 16),
              SelectableText(
                t('To już wszystkie filmy'),
                textAlign: TextAlign.center,
                style: zen.display(color: zen.textPrimary, size: 24),
              ),
              const SizedBox(height: 8),
              SelectableText(
                t('Nowe pojawią się tu, gdy znajomi coś nagrają.'),
                textAlign: TextAlign.center,
                style: TextStyle(color: zen.textSecondary, fontSize: 14.5),
              ),
              const SizedBox(height: 24),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  OutlinedButton.icon(
                    key: const Key('films-again'),
                    onPressed: onAgain,
                    icon: const Icon(Icons.replay_rounded),
                    label: Text(t('Od początku')),
                  ),
                  FilledButton.icon(
                    key: const Key('films-end-record'),
                    onPressed: onRecord,
                    icon: const Icon(Icons.videocam_rounded),
                    label: Text(t('Nagraj film')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
