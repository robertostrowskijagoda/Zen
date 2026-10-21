import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/ledger/blob_store.dart';
import 'package:zen/src/features/feed/post_media.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/media/media_stream_server.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// What a page of the pager asks of the film player.
@immutable
final class FilmPlayerRequest {
  const FilmPlayerRequest({
    required this.film,
    required this.active,
    required this.preload,
    required this.paused,
    required this.muted,
    required this.onProgress,
    required this.onWatched,
  });

  final FilmPost film;

  /// On screen and allowed to play.
  final bool active;

  /// Next up: may get ready without playing.
  final bool preload;

  /// Held or tapped to pause.
  final bool paused;
  final bool muted;

  /// Where the film is, 0..1.
  final ValueChanged<double> onProgress;

  /// Played long enough to count as watched.
  final VoidCallback onWatched;
}

/// Builds the player of one page (the real one, or a stand-in in tests).
typedef FilmPlayerBuilder =
    Widget Function(BuildContext context, FilmPlayerRequest request);

/// How long a film must play to count as watched: 3 seconds, or half of a
/// shorter one.
Duration filmWatchedAfter(Duration length) {
  const Duration enough = Duration(seconds: 3);
  final Duration half = length ~/ 2;
  return length > Duration.zero && half < enough ? half : enough;
}

/// A film of the pager: the poster first, then the film, played while it
/// downloads (from the phone's own stream server) and looped.
class FilmVideoView extends StatefulWidget {
  const FilmVideoView({required this.blobs, required this.request, super.key});

  final BlobStore blobs;
  final FilmPlayerRequest request;

  @override
  State<FilmVideoView> createState() => _FilmVideoViewState();
}

class _FilmVideoViewState extends State<FilmVideoView> {
  VideoPlayerController? _player;
  Uri? _streamUri;
  File? _file;
  bool _preparing = false;
  bool _counted = false;
  String? _error;
  Timer? _waitHead;
  Uint8List? _poster;
  bool _posterLoading = false;

  FilmPost get _film => widget.request.film;

  @override
  void initState() {
    super.initState();
    _loadPoster();
    _sync();
  }

  /// The poster, once it is here (asked again whenever the page is built
  /// anew, e.g. after a download finished).
  void _loadPoster() {
    final MediaRef? ref = _film.poster;
    if (ref == null || _poster != null || _posterLoading) {
      return;
    }
    _posterLoading = true;
    unawaited(
      openSafeImage(widget.blobs, ref)
          .then((Uint8List? bytes) {
            if (mounted && bytes != null) {
              setState(() => _poster = bytes);
            }
          }, onError: (Object _) {})
          .whenComplete(() => _posterLoading = false),
    );
  }

  @override
  void didUpdateWidget(FilmVideoView old) {
    super.didUpdateWidget(old);
    _loadPoster();
    _sync();
  }

  bool get _wanted => widget.request.active || widget.request.preload;

  void _sync() {
    final VideoPlayerController? p = _player;
    if (!_wanted) {
      if (p != null || _streamUri != null) {
        _release();
      }
      return;
    }
    if (p == null) {
      unawaited(_prepare());
      return;
    }
    unawaited(p.setVolume(widget.request.muted ? 0 : 1));
    final bool play = widget.request.active && !widget.request.paused;
    if (play && !p.value.isPlaying) {
      unawaited(p.play());
    } else if (!play && p.value.isPlaying) {
      unawaited(p.pause());
    }
  }

  Future<void> _prepare() async {
    if (_preparing || _error != null) {
      return;
    }
    _preparing = true;
    try {
      final Uint8List? whole = await openSafePlayable(
        widget.blobs,
        _film.video,
      );
      if (!mounted || !_wanted) {
        return;
      }
      if (whole != null) {
        final File f = await writeTemporaryMedia(whole, extension: '.mp4');
        _file = f;
        await _start(VideoPlayerController.file(f));
        return;
      }
      final Uint8List? head = await openStreamableStart(
        widget.blobs,
        _film.video,
      );
      if (!mounted || !_wanted) {
        return;
      }
      if (head == null) {
        // The beginning is on its way: look again shortly.
        _waitHead?.cancel();
        _waitHead = Timer(const Duration(milliseconds: 400), () {
          if (mounted) {
            unawaited(_prepare());
          }
        });
        return;
      }
      final Uri uri = await MediaStreamServer.instance.publish(
        BlobMediaStream(widget.blobs, _film.video, onUnsafe: _unsafe),
      );
      _streamUri = uri;
      await _start(VideoPlayerController.networkUrl(uri));
    } on UnsafeMediaException {
      _unsafe();
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _error = t('Nie udało się odtworzyć filmu: {error}', {
            'error': e,
          }),
        );
      }
    } finally {
      _preparing = false;
    }
  }

  void _unsafe() {
    if (!mounted) {
      return;
    }
    _release();
    setState(() => _error = t('Nieprawidłowy plik filmu — nie otwarto go.'));
  }

  Future<void> _start(VideoPlayerController p) async {
    try {
      await p.initialize();
      await p.setLooping(true);
      await p.setVolume(widget.request.muted ? 0 : 1);
    } on Object {
      await p.dispose();
      rethrow;
    }
    if (!mounted || !_wanted) {
      await p.dispose();
      _release();
      return;
    }
    p.addListener(() => _onTick(p));
    setState(() => _player = p);
    _sync();
  }

  void _onTick(VideoPlayerController p) {
    final VideoPlayerValue v = p.value;
    if (!v.isInitialized || v.duration <= Duration.zero) {
      return;
    }
    widget.request.onProgress(
      (v.position.inMilliseconds / v.duration.inMilliseconds)
          .clamp(0.0, 1.0)
          .toDouble(),
    );
    if (!_counted &&
        widget.request.active &&
        v.position >= filmWatchedAfter(v.duration)) {
      _counted = true;
      widget.request.onWatched();
    }
  }

  void _release() {
    _waitHead?.cancel();
    final VideoPlayerController? p = _player;
    _player = null;
    if (p != null) {
      unawaited(p.dispose());
    }
    final Uri? uri = _streamUri;
    _streamUri = null;
    if (uri != null) {
      unawaited(MediaStreamServer.instance.withdraw(uri));
    }
    final File? f = _file;
    _file = null;
    if (f != null) {
      unawaited(f.delete().then((_) {}, onError: (Object _) {}));
    }
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = ZenColors.foregroundFor(scheme.scrim);
    final VideoPlayerController? p = _player;
    final Uint8List? posterBytes = _poster;
    final Widget poster = posterBytes == null
        ? const SizedBox.expand()
        : Image.memory(
            posterBytes,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            gaplessPlayback: true,
          );
    return ColoredBox(
      color: scheme.scrim,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          poster,
          if (p != null && p.value.isInitialized)
            // Upright films fill the screen, wide ones fit in it.
            FittedBox(
              fit: p.value.aspectRatio < 1 ? BoxFit.cover : BoxFit.contain,
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: 1000 * p.value.aspectRatio,
                height: 1000,
                child: VideoPlayer(p),
              ),
            )
          else if (_error == null && widget.request.active)
            Center(child: CircularProgressIndicator(color: ink)),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: ink, fontSize: 14),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
