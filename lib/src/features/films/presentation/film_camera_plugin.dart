import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/films/presentation/film_camera_channel.dart';

/// The camera of the recorder on this platform: the `camera` plugin on
/// Android, iOS and Windows (`camera_windows`), Zen's own bridge on macOS
/// (AVFoundation) and Linux (GStreamer).
FilmCamera defaultFilmCamera() {
  if (!kIsWeb && (Platform.isMacOS || Platform.isLinux)) {
    return ChannelFilmCamera();
  }
  return PluginFilmCamera();
}

/// Which way each of [directions] looks, as the recorder knows it. A
/// computer's webcam ("external") counts as the front camera, or as the
/// back one when there already is a front one.
Map<int, FilmLens> filmLensesOf(List<CameraLensDirection> directions) {
  final Map<int, FilmLens> out = <int, FilmLens>{};
  final Set<FilmLens> taken = <FilmLens>{};
  for (int i = 0; i < directions.length; i++) {
    final FilmLens? lens = switch (directions[i]) {
      CameraLensDirection.front => FilmLens.front,
      CameraLensDirection.back => FilmLens.back,
      CameraLensDirection.external => null,
    };
    if (lens != null && taken.add(lens)) {
      out[i] = lens;
    }
  }
  for (int i = 0; i < directions.length; i++) {
    if (directions[i] != CameraLensDirection.external) {
      continue;
    }
    for (final FilmLens lens in <FilmLens>[FilmLens.front, FilmLens.back]) {
      if (taken.add(lens)) {
        out[i] = lens;
        break;
      }
    }
  }
  return out;
}

/// [FilmCamera] over the `camera` plugin (Android, iOS, Windows; elsewhere
/// it finds no camera and the recorder offers files only).
final class PluginFilmCamera implements FilmCamera {
  List<CameraDescription>? _cameras;
  CameraController? _controller;
  bool _torch = false;

  @override
  Future<List<FilmLens>> lenses() async {
    if (kIsWeb ||
        !(Platform.isAndroid || Platform.isIOS || Platform.isWindows)) {
      return const <FilmLens>[];
    }
    try {
      final List<CameraDescription> all = _cameras ??= await availableCameras();
      return filmLensesOf(<CameraLensDirection>[
        for (final CameraDescription c in all) c.lensDirection,
      ]).values.toList();
    } on Object {
      return const <FilmLens>[];
    }
  }

  @override
  Future<void> open(FilmLens lens) async {
    await close();
    final List<CameraDescription> all = _cameras ??= await availableCameras();
    final Map<int, FilmLens> lenses = filmLensesOf(<CameraLensDirection>[
      for (final CameraDescription c in all) c.lensDirection,
    ]);
    final int at = lenses.entries
        .firstWhere(
          (MapEntry<int, FilmLens> e) => e.value == lens,
          orElse: () => const MapEntry<int, FilmLens>(0, FilmLens.front),
        )
        .key;
    final CameraDescription description = all[at];
    // 720p: the film is compressed to that anyway.
    final CameraController c = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: true,
    );
    await c.initialize();
    try {
      await c.prepareForVideoRecording();
    } on Object {
      // Only iOS needs it; elsewhere it may not be there.
    }
    _controller = c;
    _torch = false;
  }

  /// A phone's back camera has a light; a computer's webcam has none.
  @override
  bool get hasTorch =>
      !Platform.isWindows &&
      _controller?.description.lensDirection == CameraLensDirection.back;

  @override
  Future<void> setTorch(bool on) async {
    final CameraController? c = _controller;
    if (c == null || on == _torch) {
      return;
    }
    await c.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    _torch = on;
  }

  @override
  Widget preview() {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) {
      return const SizedBox.expand();
    }
    return CameraPreview(c);
  }

  @override
  Future<void> startRecording() async {
    final CameraController? c = _controller;
    if (c == null) {
      throw StateError('camera closed');
    }
    await c.startVideoRecording();
  }

  @override
  Future<String> stopRecording() async {
    final CameraController? c = _controller;
    if (c == null) {
      throw StateError('camera closed');
    }
    final XFile file = await c.stopVideoRecording();
    return file.path;
  }

  @override
  Future<void> close() async {
    final CameraController? c = _controller;
    _controller = null;
    if (c != null) {
      await c.dispose();
    }
  }
}

/// A film from the gallery (phones) or a file (computers).
Future<String?> pickFilmFile() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.video,
    dialogTitle: t('Wybierz film'),
  );
  return result?.files.firstOrNull?.path;
}
