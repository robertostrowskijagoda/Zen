import 'dart:io';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:zen/src/app/i18n/zen_i18n.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';

/// [FilmCamera] over the `camera` plugin (Android, iOS; elsewhere it finds
/// no camera and the recorder offers files only).
final class PluginFilmCamera implements FilmCamera {
  List<CameraDescription>? _cameras;
  CameraController? _controller;
  bool _torch = false;

  @override
  Future<List<FilmLens>> lenses() async {
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return const <FilmLens>[];
    }
    try {
      final List<CameraDescription> all = _cameras ??= await availableCameras();
      return <FilmLens>{
        for (final CameraDescription c in all)
          if (c.lensDirection == CameraLensDirection.front)
            FilmLens.front
          else if (c.lensDirection == CameraLensDirection.back)
            FilmLens.back,
      }.toList();
    } on Object {
      return const <FilmLens>[];
    }
  }

  @override
  Future<void> open(FilmLens lens) async {
    await close();
    final List<CameraDescription> all = _cameras ??= await availableCameras();
    final CameraLensDirection want = lens == FilmLens.front
        ? CameraLensDirection.front
        : CameraLensDirection.back;
    final CameraDescription description = all.firstWhere(
      (CameraDescription c) => c.lensDirection == want,
      orElse: () => all.first,
    );
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

  @override
  bool get hasTorch =>
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
