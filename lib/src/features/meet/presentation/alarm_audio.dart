import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:zen/src/app/i18n/zen_format.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/app/theme/zen_kit.dart';
import 'package:zen/src/app/theme/zen_theme.dart';
import 'package:zen/src/core/logging/zen_log.dart';
import 'package:zen/src/features/media/media_vault.dart';
import 'package:zen/src/features/meet/meet_book.dart';
import 'package:zen/src/features/meet/meet_service.dart';

/// Records sound while this person's alarm runs: pieces of
/// [clipLength], each sent to the friends who got the alarm as soon as it
/// is ready, at most [kAlarmMaxClips] of them.
final class AlarmAudioPump {
  AlarmAudioPump._();

  static const Duration clipLength = Duration(seconds: 20);

  /// Whether the microphone is recording right now (for the screen).
  static final ValueNotifier<bool> recording = ValueNotifier<bool>(false);

  static int _generation = 0;
  static bool _running = false;

  static void start(MeetService service) {
    if (_running) {
      return;
    }
    _running = true;
    final int generation = ++_generation;
    unawaitedLogged(_loop(service, generation), context: 'Nagranie alarmu');
  }

  static void stop() {
    _generation++;
    _running = false;
  }

  static Future<void> _loop(MeetService service, int generation) async {
    try {
      for (int i = 0; i < kAlarmMaxClips; i++) {
        if (generation != _generation || service.book.ownActiveAlarm == null) {
          break;
        }
        final (Uint8List, int)? clip = await recordClip(
          () =>
              generation != _generation || service.book.ownActiveAlarm == null,
        );
        if (clip == null) {
          break;
        }
        await service.addAlarmAudio(clip.$1, durationMs: clip.$2);
      }
    } finally {
      if (generation == _generation) {
        _running = false;
      }
      recording.value = false;
    }
  }

  /// One piece: the sound and how long it is, or `null` (no microphone or
  /// no permission). Also what the locked Android service records with.
  /// (the alarm kit).
  static Future<(Uint8List, int)?> recordClip(bool Function() cancelled) async {
    final AudioRecorder recorder = AudioRecorder();
    String? path;
    try {
      if (!await recorder.hasPermission()) {
        return null;
      }
      path = await newTemporaryMediaPath(
        prefix: 'zen-alarm-',
        extension: '.m4a',
      );
      // Speech-quality mono keeps a piece well under the size limit.
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 32000,
          sampleRate: 16000,
          numChannels: 1,
        ),
        path: path,
      );
      recording.value = true;
      final Stopwatch watch = Stopwatch()..start();
      while (watch.elapsed < clipLength && !cancelled()) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      final String? out = await recorder.stop();
      recording.value = false;
      final File file = File(out ?? path);
      if (!await file.exists()) {
        return null;
      }
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.isEmpty || bytes.length > kAlarmClipMaxBytes) {
        return null;
      }
      return (bytes, watch.elapsedMilliseconds);
    } on Object catch (error) {
      logZenWarning('Nagranie alarmu: $error');
      return null;
    } finally {
      recording.value = false;
      try {
        await recorder.dispose();
      } on Object {
        // already gone
      }
      if (path != null) {
        final File file = File(path);
        if (file.existsSync()) {
          try {
            await file.delete();
          } on Object {
            // the system cleans the temporary folder anyway
          }
        }
      }
    }
  }
}

String _duration(int ms) {
  final int s = (ms / 1000).round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}

/// One piece of sound from a friend's alarm, with a play button. The sound
/// is written to a temporary file only while it plays.
class AlarmClipTile extends StatefulWidget {
  const AlarmClipTile({
    required this.service,
    required this.alarmId,
    required this.clip,
    super.key,
  });

  final MeetService service;
  final String alarmId;
  final AlarmClip clip;

  @override
  State<AlarmClipTile> createState() => _AlarmClipTileState();
}

class _AlarmClipTileState extends State<AlarmClipTile> {
  VideoPlayerController? _player;
  File? _file;
  bool _loading = false;
  bool _playing = false;

  @override
  void dispose() {
    unawaited(_release());
    super.dispose();
  }

  Future<void> _release() async {
    final VideoPlayerController? player = _player;
    final File? file = _file;
    _player = null;
    _file = null;
    if (player != null) {
      player.removeListener(_onPlayer);
      await player.dispose();
    }
    if (file != null && file.existsSync()) {
      try {
        await file.delete();
      } on Object {
        // temporary anyway
      }
    }
  }

  void _onPlayer() {
    final VideoPlayerController? p = _player;
    if (p == null || !mounted) {
      return;
    }
    final bool playing = p.value.isPlaying;
    final bool ended =
        p.value.duration > Duration.zero &&
        p.value.position >= p.value.duration;
    if (playing != _playing || ended) {
      setState(() => _playing = playing && !ended);
    }
  }

  Future<void> _toggle() async {
    final VideoPlayerController? had = _player;
    if (had != null) {
      if (had.value.isPlaying) {
        await had.pause();
      } else {
        if (had.value.position >= had.value.duration) {
          await had.seekTo(Duration.zero);
        }
        await had.play();
      }
      return;
    }
    setState(() => _loading = true);
    try {
      final Uint8List? data = await widget.service.alarmAudio(
        widget.alarmId,
        widget.clip.n,
      );
      if (data == null) {
        throw StateError('Brak nagrania.');
      }
      final File file = await writeTemporaryMedia(data, extension: '.m4a');
      final VideoPlayerController player = VideoPlayerController.file(file);
      _file = file;
      _player = player;
      player.addListener(_onPlayer);
      await player.initialize();
      await player.play();
    } on Object catch (error) {
      logZenWarning('Odtwarzanie nagrania alarmu: $error');
      await _release();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(t('Nie udało się odtworzyć nagrania.'))),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ZenColors zen = ZenColors.of(context);
    final DateTime at = DateTime.fromMillisecondsSinceEpoch(widget.clip.at);
    return ZenTile(
      key: Key('alarm-clip-${widget.clip.n}'),
      icon: _playing ? Icons.graphic_eq_rounded : Icons.mic_rounded,
      tone: zen.danger,
      title: t('Nagranie {number}', {'number': widget.clip.n + 1}),
      subtitle:
          '${ZenFormat.time(at)}${widget.clip.ms > 0 ? ' · ${_duration(widget.clip.ms)}' : ''}',
      onTap: _loading ? null : () => unawaited(_toggle()),
      trailing: _loading
          ? const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              _playing ? Icons.pause_circle_rounded : Icons.play_circle_rounded,
              color: zen.danger,
              size: 30,
            ),
    );
  }
}
