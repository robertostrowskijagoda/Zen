import 'dart:typed_data';

import 'package:flutter/widgets.dart';

/// A camera picture in shades of grey: one byte a pixel, row after row
/// (what a QR code is read from).
@immutable
final class LumaFrame {
  const LumaFrame({
    required this.width,
    required this.height,
    required this.bytes,
  });

  final int width;
  final int height;
  final Uint8List bytes;

  /// Whether [bytes] holds the whole picture.
  bool get isComplete =>
      width > 0 && height > 0 && bytes.length >= width * height;
}

/// Which way a camera looks.
enum FilmLens { front, back }

/// The camera the recorder uses (the `camera` plugin on phones; a fake in
/// tests). One recording at a time.
abstract interface class FilmCamera {
  /// The lenses this device has (empty: no camera, only files).
  Future<List<FilmLens>> lenses();

  /// Opens [lens] for recording with sound.
  Future<void> open(FilmLens lens);

  /// Whether the open camera can light the scene.
  bool get hasTorch;

  Future<void> setTorch(bool on);

  /// The live picture of the open camera.
  Widget preview();

  Future<void> startRecording();

  /// Stops and gives the recorded file's path.
  Future<String> stopRecording();

  /// The newest picture of the open camera in shades of grey (a QR
  /// scanner reads it), or null while there is none.
  Future<LumaFrame?> lumaFrame();

  /// Lets the camera go (leaving the recorder, switching lenses).
  Future<void> close();
}

/// Makes the camera of the recorder.
typedef FilmCameraFactory = FilmCamera Function();

/// A film picked from the gallery or the disk: its path, or null when the
/// person picked nothing.
typedef FilmFilePicker = Future<String?> Function();
