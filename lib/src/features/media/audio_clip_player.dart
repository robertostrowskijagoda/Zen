import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/media_guard.dart';
import 'package:zen/src/features/media/media_vault.dart';

/// Gives the bytes of a recording: null while it is not on this device yet.
/// May throw (a recording that is not one is never played).
typedef AudioClipLoader = Future<Uint8List?> Function();

/// One recording to play: a voice message or an audio file of a post. The
/// bytes are written to a private temporary file only while it plays, and
/// only after their container was checked ([looksLikeSafeContainer]).
class AudioClipPlayer extends StatefulWidget {
  const AudioClipPlayer({
    required this.load,
    this.title,
    this.durationMs,
    this.sizeBytes,
    this.onMissing,
    super.key,
  });

  final AudioClipLoader load;
  final String? title;
  final int? durationMs;
  final int? sizeBytes;

  /// Called when the recording is not downloaded yet (to fetch it).
  final VoidCallback? onMissing;

  @override
  State<AudioClipPlayer> createState() => _AudioClipPlayerState();
}

class _AudioClipPlayerState extends State<AudioClipPlayer> {
  VideoPlayerController? _player;
  File? _file;
  bool _loading = false;
  bool _playing = false;
  String? _problem;
  Duration _position = Duration.zero;
  late Duration _duration = Duration(milliseconds: widget.durationMs ?? 0);

  @override
  void dispose() {
    unawaited(_release());
    super.dispose();
  }

  Future<void> _release() async {
    final VideoPlayerController? player = _player;
    _player = null;
    if (player != null) {
      player.removeListener(_onPlayer);
      await player.dispose();
    }
    final File? file = _file;
    _file = null;
    if (file != null) {
      try {
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Removed with the temporary folder later.
      }
    }
  }

  void _onPlayer() {
    final VideoPlayerController? player = _player;
    if (!mounted || player == null) {
      return;
    }
    final VideoPlayerValue v = player.value;
    setState(() {
      _playing = v.isPlaying;
      _position = v.position;
      if (v.duration > Duration.zero) {
        _duration = v.duration;
      }
    });
  }

  Future<void> _toggle() async {
    final VideoPlayerController? existing = _player;
    if (existing != null) {
      if (existing.value.isPlaying) {
        await existing.pause();
        return;
      }
      if (_duration > Duration.zero && existing.value.position >= _duration) {
        await existing.seekTo(Duration.zero);
      }
      await existing.play();
      return;
    }
    setState(() {
      _loading = true;
      _problem = null;
    });
    try {
      final Uint8List? bytes = await widget.load();
      if (bytes == null) {
        widget.onMissing?.call();
        if (mounted) {
          setState(() => _problem = t('Nagranie jeszcze się pobiera…'));
        }
        return;
      }
      if (!looksLikeSafeContainer(bytes)) {
        if (mounted) {
          setState(
            () => _problem = t('Nieprawidłowy plik — nie odtworzono go.'),
          );
        }
        return;
      }
      // Random name in the temporary media folder (emptied at every start).
      final File file = await writeTemporaryMedia(
        bytes,
        extension: _extensionFor(bytes),
      );
      _file = file;
      final VideoPlayerController player = VideoPlayerController.file(file);
      player.addListener(_onPlayer);
      await player.initialize();
      if (!mounted) {
        player.removeListener(_onPlayer);
        await player.dispose();
        return;
      }
      _player = player;
      await player.play();
    } on Object catch (error) {
      logZenWarning('Odtwarzanie nagrania: $error');
      await _release();
      if (mounted) {
        setState(() => _problem = t('Nie udało się odtworzyć nagrania.'));
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  static String _extensionFor(Uint8List bytes) {
    final String mime = sniffMimeType(bytes) ?? '';
    if (mime.contains('ogg')) {
      return '.ogg';
    }
    if (mime.contains('mpeg')) {
      return '.mp3';
    }
    if (mime.contains('wav')) {
      return '.wav';
    }
    if (mime.contains('webm')) {
      return '.webm';
    }
    return '.m4a';
  }

  static String _clock(Duration d) {
    final int s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final double progress = _duration.inMilliseconds <= 0
        ? 0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);
    final List<String> meta = <String>[
      if (_duration > Duration.zero)
        _position > Duration.zero
            ? '${_clock(_position)} / ${_clock(_duration)}'
            : _clock(_duration),
      if (widget.sizeBytes != null)
        widget.sizeBytes! >= 1024 * 1024
            ? '${(widget.sizeBytes! / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(widget.sizeBytes! / 1024).round()} kB',
    ];
    return Container(
      key: const Key('audio-clip'),
      padding: const EdgeInsetsDirectional.fromSTEB(8, 8, 14, 8),
      decoration: BoxDecoration(
        color: zen.surfaceSunk,
        borderRadius: context.zenRadius(18),
        border: Border.all(color: zen.outlineSoft),
      ),
      child: Row(
        children: <Widget>[
          IconButton.filledTonal(
            key: const Key('audio-clip-play'),
            tooltip: _playing ? t('Pauza') : t('Odtwórz'),
            onPressed: _loading ? null : () => unawaited(_toggle()),
            style: IconButton.styleFrom(
              backgroundColor: zen.accent.withValues(alpha: 0.16),
              foregroundColor: zen.accent,
            ),
            icon: _loading
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: zen.accent,
                    ),
                  )
                : Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Icon(Icons.graphic_eq_rounded, size: 16, color: zen.accent),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.title ?? t('Nagranie'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: zen.textPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: context.zenRadius(999),
                  child: LinearProgressIndicator(
                    minHeight: 5,
                    value: progress,
                    backgroundColor: zen.surfaceMuted,
                    color: zen.accent,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _problem ??
                      (meta.isEmpty ? t('Nagranie audio') : meta.join(' · ')),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _problem == null ? zen.textSecondary : zen.warning,
                    fontSize: 12,
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
