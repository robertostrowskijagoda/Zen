import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';

// The camera of the recorder where the `camera` plugin has no backend: Zen's
// own bridges answer on the channel `zen/camera` — AVCaptureSession on macOS
// (ZenCameraBridge.swift), GStreamer with Zen's bundled H.264 encoder on Linux
// (zen_camera_bridge.cc):
//
//  - `lenses` → ["front", "back"] (what the computer has; empty: none);
//  - `open` {lens} → {textureId, width, height}: the live picture is a
//    Flutter texture;
//  - `setTorch` {on}: ignored where there is no light;
//  - `start`: records picture and sound into a temporary MP4;
//  - `stop` → the recording's path;
//  - `close`: lets the camera and microphone go.

/// [FilmCamera] over the `zen/camera` channel.
final class ChannelFilmCamera implements FilmCamera {
  ChannelFilmCamera({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('zen/camera');

  final MethodChannel _channel;
  int? _texture;
  double _aspect = 16 / 9;
  bool _torch = false;

  @override
  Future<List<FilmLens>> lenses() async {
    try {
      final List<Object?>? names = await _channel.invokeListMethod<Object?>(
        'lenses',
      );
      return <FilmLens>{
        for (final Object? n in names ?? const <Object?>[])
          if (n == 'front') FilmLens.front else if (n == 'back') FilmLens.back,
      }.toList();
    } on MissingPluginException {
      return const <FilmLens>[];
    } on PlatformException {
      return const <FilmLens>[];
    }
  }

  @override
  Future<void> open(FilmLens lens) async {
    await close();
    final Map<Object?, Object?>? info = await _channel
        .invokeMapMethod<Object?, Object?>('open', <String, Object?>{
          'lens': lens.name,
        });
    final Object? id = info?['textureId'];
    if (id is! int) {
      throw StateError('no camera picture');
    }
    final Object? w = info?['width'];
    final Object? h = info?['height'];
    if (w is num && h is num && w > 0 && h > 0) {
      _aspect = w / h;
    }
    _texture = id;
    _torch = false;
  }

  @override
  bool get hasTorch => false;

  @override
  Future<void> setTorch(bool on) async {
    if (on == _torch) {
      return;
    }
    await _channel.invokeMethod<void>('setTorch', <String, Object?>{'on': on});
    _torch = on;
  }

  @override
  Widget preview() {
    final int? id = _texture;
    if (id == null) {
      return const SizedBox.expand();
    }
    return AspectRatio(
      aspectRatio: _aspect,
      child: Texture(textureId: id),
    );
  }

  @override
  Future<void> startRecording() async {
    if (_texture == null) {
      throw StateError('camera closed');
    }
    await _channel.invokeMethod<void>('start');
  }

  @override
  Future<String> stopRecording() async {
    final String? path = await _channel.invokeMethod<String>('stop');
    if (path == null || path.isEmpty) {
      throw StateError('nothing recorded');
    }
    return path;
  }

  @override
  Future<void> close() async {
    if (_texture == null) {
      return;
    }
    _texture = null;
    try {
      await _channel.invokeMethod<void>('close');
    } on MissingPluginException {
      // Nothing was open.
    }
  }
}
