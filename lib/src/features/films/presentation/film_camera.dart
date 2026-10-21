import 'package:flutter/widgets.dart';

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

  /// Lets the camera go (leaving the recorder, switching lenses).
  Future<void> close();
}

/// Makes the camera of the recorder.
typedef FilmCameraFactory = FilmCamera Function();

/// A film picked from the gallery or the disk: its path, or null when the
/// person picked nothing.
typedef FilmFilePicker = Future<String?> Function();
