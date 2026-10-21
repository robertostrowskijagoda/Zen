import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/feed/presentation/post_editor_screen.dart'
    show kAudienceHints, kAudienceIcons;
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_publish.dart';
import 'package:zen/src/features/films/film_trim.dart';
import 'package:zen/src/features/ledger/audience_keys.dart';
import 'package:zen/src/features/media/mp4_probe.dart';
import 'package:zen/src/features/media/video_compressor.dart';

/// Plays the recording at [path] between the ends of [trim] (a stand-in in
/// tests).
typedef FilmPreviewBuilder =
    Widget Function(BuildContext context, String path, FilmTrim trim);

/// Publishes a draft, telling how far it got.
typedef FilmPublisher =
    Future<void> Function(FilmDraft draft, FilmPublishProgress onProgress);

/// The length of the recording at [path] in ms, or null when unknown.
typedef FilmLengthReader = Future<int?> Function(String path);

Future<int?> _probeLength(String path) async =>
    (await probeMp4File(File(path)))?.durationMs;

/// After recording: trim the start and the end, write a caption (up to
/// [kMaxFilmCaptionChars]), pick who sees it, publish.
class FilmEditorScreen extends StatefulWidget {
  const FilmEditorScreen({
    required this.path,
    required this.publish,
    required this.canTrim,
    this.recordedMs = 0,
    this.replyTo,
    this.replyToName,
    this.initialAudience = Audience.all,
    this.preview,
    this.lengthOf = _probeLength,
    super.key,
  });

  final String path;
  final int recordedMs;
  final FilmPublisher publish;

  /// Whether this device can trim (and compress) films.
  final bool canTrim;
  final FilmReplyRef? replyTo;
  final String? replyToName;
  final Audience initialAudience;
  final FilmPreviewBuilder? preview;
  final FilmLengthReader lengthOf;

  /// Opens the editor; true once the film is published.
  static Future<bool> open(
    BuildContext context, {
    required String path,
    required FilmPublisher publish,
    required bool canTrim,
    int recordedMs = 0,
    FilmReplyRef? replyTo,
    String? replyToName,
    Audience initialAudience = Audience.all,
  }) async =>
      await Navigator.of(context).push<bool>(
        MaterialPageRoute<bool>(
          builder: (BuildContext _) => FilmEditorScreen(
            path: path,
            publish: publish,
            canTrim: canTrim,
            recordedMs: recordedMs,
            replyTo: replyTo,
            replyToName: replyToName,
            initialAudience: initialAudience,
          ),
        ),
      ) ??
      false;

  @override
  State<FilmEditorScreen> createState() => _FilmEditorScreenState();
}

class _FilmEditorScreenState extends State<FilmEditorScreen> {
  final TextEditingController _caption = TextEditingController();
  int? _lengthMs;
  FilmTrim _trim = const FilmTrim(startMs: 0, endMs: 0);
  late Audience _audience = widget.initialAudience;
  bool _busy = false;
  FilmPublishStage? _stage;
  double _fraction = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_readLength());
  }

  Future<void> _readLength() async {
    int? ms;
    try {
      ms = await widget.lengthOf(widget.path);
    } on Object {
      ms = null;
    }
    ms ??= widget.recordedMs > 0 ? widget.recordedMs : null;
    if (!mounted) {
      return;
    }
    setState(() {
      _lengthMs = ms ?? 0;
      _trim = FilmTrim.initial(
        _lengthMs!,
        // Without trimming the whole film goes.
        maxMs: widget.canTrim ? kFilmDefaultMaxMs : kFilmHardMaxMs + 1000,
      );
      if (_lengthMs == 0) {
        _error = t('To nie jest film.');
      } else if (!widget.canTrim && _lengthMs! > kFilmHardMaxMs + 1000) {
        _error = tn(
          kFilmHardMaxMs ~/ 1000,
          one: 'Film jest za długi (maks. {n} sekunda).',
          few: 'Film jest za długi (maks. {n} sekundy).',
          many: 'Film jest za długi (maks. {n} sekund).',
        );
      }
    });
  }

  @override
  void dispose() {
    _caption.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final int? length = _lengthMs;
    if (_busy || length == null || length == 0) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _stage = FilmPublishStage.compressing;
      _fraction = 0;
    });
    try {
      await widget.publish(
        FilmDraft(
          path: widget.path,
          durationMs: length,
          trim: _trim,
          caption: _caption.text,
          audience: _audience,
          replyTo: widget.replyTo,
        ),
        (FilmPublishStage stage, double fraction) {
          if (mounted) {
            setState(() {
              _stage = stage;
              _fraction = fraction;
            });
          }
        },
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on ArgumentError catch (e) {
      _fail('${e.message}');
    } on VideoCompressionException catch (e) {
      _fail(
        e.cancelled
            ? t('Przerwano.')
            : t('Nie udało się zmniejszyć filmu: {error}', {'error': e}),
      );
    } on Object catch (e) {
      _fail(t('Nie udało się opublikować: {error}', {'error': e}));
    }
  }

  void _fail(String message) {
    if (mounted) {
      setState(() {
        _busy = false;
        _stage = null;
        _error = message;
      });
    }
  }

  String _stageLabel(FilmPublishStage stage) => switch (stage) {
    FilmPublishStage.compressing => t('Zmniejszanie filmu…'),
    FilmPublishStage.sealing => t('Szyfrowanie…'),
    FilmPublishStage.publishing => t('Publikowanie…'),
  };

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final int? length = _lengthMs;
    final Widget preview = (widget.preview ?? _defaultPreview)(
      context,
      widget.path,
      _trim,
    );
    return Scaffold(
      key: const Key('film-editor'),
      appBar: AppBar(
        title: Text(
          widget.replyToName == null
              ? t('Nowy film')
              : t('Odpowiedź dla: {name}', {'name': widget.replyToName}),
        ),
      ),
      body: SafeArea(
        // Everything built at once (a lazy list would leave the button out
        // until it is scrolled to).
        child: SingleChildScrollView(
          key: const Key('film-editor-scroll'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * 0.45,
                ),
                child: AspectRatio(aspectRatio: 9 / 16, child: preview),
              ),
              const SizedBox(height: 16),
              if (length == null)
                const LinearProgressIndicator()
              else if (length > 0 && widget.canTrim) ...<Widget>[
                Text(
                  t('Przytnij'),
                  style: TextStyle(
                    color: zen.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                RangeSlider(
                  key: const Key('film-editor-trim'),
                  min: 0,
                  max: length.toDouble(),
                  values: RangeValues(
                    _trim.startMs.toDouble(),
                    _trim.endMs.toDouble(),
                  ),
                  onChanged: _busy
                      ? null
                      : (RangeValues v) => setState(() {
                          final FilmTrim moved =
                              v.start.round() != _trim.startMs
                              ? _trim.withStart(v.start.round(), length)
                              : _trim;
                          _trim = v.end.round() != moved.endMs
                              ? moved.withEnd(v.end.round(), length)
                              : moved;
                        }),
                ),
                Text(
                  '${filmClock(_trim.startMs)} – ${filmClock(_trim.endMs)} '
                  '(${filmClock(_trim.lengthMs)})',
                  key: const Key('film-editor-range'),
                  style: TextStyle(color: zen.textSecondary),
                ),
                if (_trim.overDefault)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      t('Dłuższy niż minuta: będzie w gorszej jakości.'),
                      style: TextStyle(color: zen.warning, fontSize: 13),
                    ),
                  ),
              ] else if (length > 0)
                Text(
                  t('Na tym urządzeniu filmu nie da się przyciąć.'),
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('film-editor-caption'),
                controller: _caption,
                enabled: !_busy,
                maxLength: kMaxFilmCaptionChars,
                minLines: 1,
                maxLines: 3,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(labelText: t('Opis')),
              ),
              const SizedBox(height: 8),
              Text(
                t('Kto zobaczy'),
                style: TextStyle(
                  color: zen.textPrimary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final Audience a in Audience.values)
                    ChoiceChip(
                      key: Key('film-editor-audience-${a.name}'),
                      avatar: Icon(kAudienceIcons[a], size: 18),
                      label: Text(kAudienceLabels[a] ?? a.name),
                      selected: _audience == a,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _audience = a),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  kAudienceHints[_audience] ?? '',
                  style: TextStyle(color: zen.textSecondary, fontSize: 13),
                ),
              ),
              if (_audience == Audience.public)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    t(
                      'Znajomi, którym się spodoba, mogą go pokazać swoim znajomym.',
                    ),
                    style: TextStyle(color: zen.textSecondary, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 16),
              if (_stage != null) ...<Widget>[
                Text(
                  _stageLabel(_stage!),
                  key: const Key('film-editor-stage'),
                  style: TextStyle(color: zen.textSecondary),
                ),
                const SizedBox(height: 6),
                LinearProgressIndicator(
                  value: _stage == FilmPublishStage.compressing
                      ? _fraction
                      : null,
                ),
                const SizedBox(height: 12),
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _error!,
                    key: const Key('film-editor-error'),
                    style: TextStyle(color: zen.danger),
                  ),
                ),
              FilledButton.icon(
                key: const Key('film-editor-publish'),
                onPressed:
                    _busy ||
                        length == null ||
                        length == 0 ||
                        (!widget.canTrim && length > kFilmHardMaxMs + 1000)
                    ? null
                    : () => unawaited(_publish()),
                icon: const Icon(Icons.publish_rounded),
                label: Text(t('Opublikuj')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget _defaultPreview(BuildContext context, String path, FilmTrim trim) =>
    _FilePreview(path: path, trim: trim);

/// The recording played in a loop between the ends of the trim.
class _FilePreview extends StatefulWidget {
  const _FilePreview({required this.path, required this.trim});

  final String path;
  final FilmTrim trim;

  @override
  State<_FilePreview> createState() => _FilePreviewState();
}

class _FilePreviewState extends State<_FilePreview> {
  VideoPlayerController? _player;

  @override
  void initState() {
    super.initState();
    final VideoPlayerController p = VideoPlayerController.file(
      File(widget.path),
    );
    unawaited(
      p
          .initialize()
          .then((_) async {
            if (!mounted) {
              await p.dispose();
              return;
            }
            p.addListener(_loop);
            await p.seekTo(Duration(milliseconds: widget.trim.startMs));
            await p.play();
            setState(() => _player = p);
          })
          .catchError((Object _) {
            unawaited(p.dispose());
          }),
    );
  }

  @override
  void didUpdateWidget(_FilePreview old) {
    super.didUpdateWidget(old);
    if (old.trim.startMs != widget.trim.startMs) {
      unawaited(_player?.seekTo(Duration(milliseconds: widget.trim.startMs)));
    }
  }

  void _loop() {
    final VideoPlayerController? p = _player;
    if (p == null) {
      return;
    }
    final int at = p.value.position.inMilliseconds;
    if (at >= widget.trim.endMs || at < widget.trim.startMs - 500) {
      unawaited(p.seekTo(Duration(milliseconds: widget.trim.startMs)));
    }
  }

  @override
  void dispose() {
    unawaited(_player?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final VideoPlayerController? p = _player;
    return ColoredBox(
      color: scheme.scrim,
      child: p == null
          ? Center(
              child: CircularProgressIndicator(
                color: ZenColors.foregroundFor(scheme.scrim),
              ),
            )
          : Center(
              child: AspectRatio(
                aspectRatio: p.value.aspectRatio,
                child: VideoPlayer(p),
              ),
            ),
    );
  }
}
