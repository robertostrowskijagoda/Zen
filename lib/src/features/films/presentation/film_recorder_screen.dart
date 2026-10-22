import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/features/films/film_model.dart';
import 'package:zen/src/features/films/film_trim.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';

/// What the recorder gives back: a recording or a picked file.
@immutable
final class FilmRecording {
  const FilmRecording({required this.path, this.recordedMs = 0});

  final String path;

  /// How long the recorder ran (0 for a picked file).
  final int recordedMs;
}

/// The camera of the "Filmy" section: hold the button to record (or tap
/// to start and tap again to stop), at most [kFilmDefaultMaxMs] or, when
/// chosen, [kFilmHardMaxMs]; front and back camera, the torch, a timer of
/// 3 or 10 seconds, and a film from the gallery instead.
class FilmRecorderScreen extends StatefulWidget {
  const FilmRecorderScreen({
    required this.camera,
    required this.pickFile,
    this.replyToName,
    super.key,
  });

  final FilmCamera camera;
  final FilmFilePicker pickFile;

  /// Recording an answer to this person's film.
  final String? replyToName;

  /// Opens the recorder; the recording (or picked file), or null.
  static Future<FilmRecording?> open(
    BuildContext context, {
    required FilmCamera camera,
    required FilmFilePicker pickFile,
    String? replyToName,
  }) => Navigator.of(context).push<FilmRecording>(
    MaterialPageRoute<FilmRecording>(
      fullscreenDialog: true,
      builder: (BuildContext _) => FilmRecorderScreen(
        camera: camera,
        pickFile: pickFile,
        replyToName: replyToName,
      ),
    ),
  );

  @override
  State<FilmRecorderScreen> createState() => _FilmRecorderScreenState();
}

class _FilmRecorderScreenState extends State<FilmRecorderScreen> {
  List<FilmLens> _lenses = const <FilmLens>[];
  FilmLens _lens = FilmLens.back;
  bool _opening = true;
  bool _recording = false;
  bool _torch = false;
  bool _long = false;
  int _timer = 0;
  int? _countdown;
  String? _error;
  final Stopwatch _clock = Stopwatch();
  Timer? _tick;
  bool _closing = false;

  int get _limitMs => _long ? kFilmHardMaxMs : kFilmDefaultMaxMs;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final List<FilmLens> lenses = await widget.camera.lenses();
      if (!mounted) {
        return;
      }
      _lenses = lenses;
      if (lenses.isNotEmpty) {
        _lens = lenses.contains(FilmLens.back) ? FilmLens.back : lenses.first;
        await widget.camera.open(_lens);
      }
    } on Object catch (e) {
      _error = t('Nie udało się włączyć kamery: {error}', {'error': e});
    }
    if (mounted) {
      setState(() => _opening = false);
    }
  }

  @override
  void dispose() {
    _tick?.cancel();
    unawaited(widget.camera.close());
    super.dispose();
  }

  Future<void> _flip() async {
    if (_recording || _lenses.length < 2) {
      return;
    }
    final FilmLens next = _lens == FilmLens.back
        ? FilmLens.front
        : FilmLens.back;
    setState(() => _opening = true);
    try {
      await widget.camera.open(next);
      _lens = next;
      _torch = false;
    } on Object catch (e) {
      _error = t('Nie udało się włączyć kamery: {error}', {'error': e});
    }
    if (mounted) {
      setState(() => _opening = false);
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await widget.camera.setTorch(!_torch);
      setState(() => _torch = !_torch);
    } on Object {
      // No torch on this lens after all.
    }
  }

  /// A tap: stop, or start (after the timer).
  Future<void> _tap() async {
    if (_recording) {
      await _stop();
      return;
    }
    if (_countdown != null) {
      return;
    }
    if (_timer > 0) {
      for (int left = _timer; left > 0; left--) {
        if (!mounted) {
          return;
        }
        setState(() => _countdown = left);
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      if (!mounted) {
        return;
      }
      setState(() => _countdown = null);
    }
    await _start();
  }

  Future<void> _start() async {
    if (_recording || _opening || _lenses.isEmpty) {
      return;
    }
    try {
      await widget.camera.startRecording();
    } on Object catch (e) {
      setState(() => _error = t('Nie udało się nagrać: {error}', {'error': e}));
      return;
    }
    _clock
      ..reset()
      ..start();
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) {
        return;
      }
      if (_clock.elapsedMilliseconds >= _limitMs) {
        unawaited(_stop());
      } else {
        setState(() {});
      }
    });
    setState(() {
      _recording = true;
      _error = null;
    });
  }

  Future<void> _stop() async {
    if (!_recording || _closing) {
      return;
    }
    _closing = true;
    _tick?.cancel();
    _clock.stop();
    final int ms = _clock.elapsedMilliseconds;
    try {
      final String path = await widget.camera.stopRecording();
      if (!mounted) {
        return;
      }
      setState(() => _recording = false);
      if (ms < kFilmMinMs) {
        // A tap too short to be a film.
        setState(() => _error = t('Przytrzymaj dłużej, żeby nagrać film.'));
        return;
      }
      Navigator.of(context).pop(FilmRecording(path: path, recordedMs: ms));
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _recording = false;
          _error = t('Nie udało się nagrać: {error}', {'error': e});
        });
      }
    } finally {
      _closing = false;
    }
  }

  Future<void> _pick() async {
    if (_recording) {
      return;
    }
    final String? path = await widget.pickFile();
    if (path != null && mounted) {
      Navigator.of(context).pop(FilmRecording(path: path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ink = ZenColors.foregroundFor(scheme.scrim);
    final bool hasCamera = _lenses.isNotEmpty;
    final double done = _recording
        ? math.min(1, _clock.elapsedMilliseconds / _limitMs)
        : 0;
    return Scaffold(
      key: const Key('film-recorder'),
      backgroundColor: scheme.scrim,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (hasCamera && !_opening)
            Center(child: widget.camera.preview())
          else if (_opening)
            Center(child: CircularProgressIndicator(color: ink))
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: ZenEmpty(
                  icon: Icons.videocam_off_outlined,
                  title: t('Brak kamery'),
                  text: t('Wybierz film z galerii lub z dysku.'),
                  action: FilledButton.icon(
                    key: const Key('film-recorder-pick-empty'),
                    onPressed: () => unawaited(_pick()),
                    icon: const Icon(Icons.video_library_rounded),
                    label: Text(t('Wybierz film')),
                  ),
                ),
              ),
            ),
          if (_countdown != null)
            Center(
              child: Text(
                '$_countdown',
                key: const Key('film-recorder-countdown'),
                style: zen.display(color: ink, size: 96),
              ),
            ),
          SafeArea(
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    IconButton(
                      key: const Key('film-recorder-close'),
                      tooltip: t('Zamknij'),
                      color: ink,
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _recording
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        _recording
                            ? '${filmClock(_clock.elapsedMilliseconds)} / ${filmClock(_limitMs)}'
                            : (widget.replyToName == null
                                  ? t('Nowy film')
                                  : t('Odpowiedź dla: {name}', {
                                      'name': widget.replyToName,
                                    })),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: ink,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                    if (hasCamera && widget.camera.hasTorch)
                      IconButton(
                        key: const Key('film-recorder-torch'),
                        tooltip: t('Latarka'),
                        color: _torch ? zen.accent : ink,
                        icon: Icon(
                          _torch
                              ? Icons.flash_on_rounded
                              : Icons.flash_off_rounded,
                        ),
                        onPressed: () => unawaited(_toggleTorch()),
                      ),
                    if (hasCamera)
                      TextButton(
                        key: const Key('film-recorder-timer'),
                        onPressed: _recording
                            ? null
                            : () => setState(
                                () => _timer = switch (_timer) {
                                  0 => 3,
                                  3 => 10,
                                  _ => 0,
                                },
                              ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Icon(Icons.timer_outlined, color: ink, size: 20),
                            if (_timer > 0)
                              Text(' $_timer s', style: TextStyle(color: ink)),
                          ],
                        ),
                      ),
                  ],
                ),
                if (hasCamera)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: <Widget>[
                        ChoiceChip(
                          key: const Key('film-recorder-60'),
                          label: Text(filmClock(kFilmDefaultMaxMs)),
                          selected: !_long,
                          onSelected: _recording
                              ? null
                              : (_) => setState(() => _long = false),
                        ),
                        ChoiceChip(
                          key: const Key('film-recorder-90'),
                          label: Text(filmClock(kFilmHardMaxMs)),
                          selected: _long,
                          onSelected: _recording
                              ? null
                              : (_) => setState(() => _long = true),
                        ),
                      ],
                    ),
                  ),
                const Spacer(),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    child: Text(
                      _error!,
                      key: const Key('film-recorder-error'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ink, fontSize: 13.5),
                    ),
                  ),
                if (hasCamera)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      t('Przytrzymaj, aby nagrać'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: ink, fontSize: 13),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      IconButton(
                        key: const Key('film-recorder-pick'),
                        tooltip: t('Wybierz film'),
                        color: ink,
                        iconSize: 30,
                        icon: const Icon(Icons.video_library_rounded),
                        onPressed: _recording ? null : () => unawaited(_pick()),
                      ),
                      if (hasCamera)
                        _RecordButton(
                          recording: _recording,
                          done: done,
                          onTap: () => unawaited(_tap()),
                          onHoldStart: () {
                            if (_timer == 0 && !_recording) {
                              unawaited(_start());
                            }
                          },
                          onHoldEnd: () {
                            if (_timer == 0) {
                              unawaited(_stop());
                            }
                          },
                        ),
                      IconButton(
                        key: const Key('film-recorder-flip'),
                        tooltip: t('Zmień kamerę'),
                        color: ink,
                        iconSize: 30,
                        icon: const Icon(Icons.cameraswitch_rounded),
                        onPressed: _lenses.length < 2 || _recording
                            ? null
                            : () => unawaited(_flip()),
                      ),
                    ],
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

/// The big round button: a ring fills while it records.
class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.recording,
    required this.done,
    required this.onTap,
    required this.onHoldStart,
    required this.onHoldEnd,
  });

  final bool recording;
  final double done;
  final VoidCallback onTap;
  final VoidCallback onHoldStart;
  final VoidCallback onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final Color ink = ZenColors.foregroundFor(
      Theme.of(context).colorScheme.scrim,
    );
    return Semantics(
      button: true,
      label: recording ? t('Zatrzymaj') : t('Nagraj film'),
      child: GestureDetector(
        key: const Key('film-recorder-record'),
        onTap: onTap,
        onLongPressStart: (_) => onHoldStart(),
        onLongPressEnd: (_) => onHoldEnd(),
        child: SizedBox(
          width: 88,
          height: 88,
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: recording ? done : 0,
                  strokeWidth: 5,
                  color: zen.danger,
                  backgroundColor: ink.withValues(alpha: 0.35),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: recording ? 34 : 66,
                height: recording ? 34 : 66,
                decoration: BoxDecoration(
                  color: zen.danger,
                  // Round to record, the theme's square to stop.
                  borderRadius: recording
                      ? context.zenRadius(8)
                      : BorderRadius.circular(33),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
