import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zen/src/features/films/presentation/film_camera.dart';
import 'package:zen/src/features/films/presentation/film_camera_channel.dart';
import 'package:zen/src/features/films/presentation/film_camera_plugin.dart';
import 'package:zen/src/features/media/video_compressor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a computer webcam counts as the front camera', () {
    expect(
      filmLensesOf(<CameraLensDirection>[CameraLensDirection.external]),
      <int, FilmLens>{0: FilmLens.front},
    );
    expect(
      filmLensesOf(<CameraLensDirection>[
        CameraLensDirection.front,
        CameraLensDirection.external,
        CameraLensDirection.external,
      ]),
      <int, FilmLens>{0: FilmLens.front, 1: FilmLens.back},
    );
    expect(
      filmLensesOf(<CameraLensDirection>[
        CameraLensDirection.back,
        CameraLensDirection.front,
        CameraLensDirection.back,
      ]),
      <int, FilmLens>{0: FilmLens.back, 1: FilmLens.front},
    );
  });

  test('the own camera bridge: lenses, a texture, a recording', () async {
    const MethodChannel channel = MethodChannel('zen/camera-test');
    final List<String> calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          return switch (call.method) {
            'lenses' => <String>['front', 'zoom'],
            'open' => <String, Object?>{
              'textureId': 7,
              'width': 1280,
              'height': 720,
            },
            'stop' => '/tmp/zen-recording.mp4',
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final ChannelFilmCamera camera = ChannelFilmCamera(channel: channel);
    expect(await camera.lenses(), <FilmLens>[FilmLens.front]);
    expect(camera.preview(), isA<SizedBox>());
    await camera.open(FilmLens.front);
    final Widget preview = camera.preview();
    expect(preview, isA<AspectRatio>());
    expect((preview as AspectRatio).aspectRatio, closeTo(16 / 9, 0.001));
    expect(camera.hasTorch, isFalse);
    await camera.startRecording();
    expect(await camera.stopRecording(), '/tmp/zen-recording.mp4');
    await camera.close();
    expect(calls, <String>['lenses', 'open', 'start', 'stop', 'close']);
  });

  test('without the bridge there is no camera, only files', () async {
    final ChannelFilmCamera camera = ChannelFilmCamera(
      channel: const MethodChannel('zen/camera-missing'),
    );
    expect(await camera.lenses(), isEmpty);
  });

  test('the encoder bridge reports the turn and lost sound', () async {
    const MethodChannel channel = MethodChannel('zen/video-test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          return switch (call.method) {
            'isAvailable' => true,
            'compress' => <String, Object?>{
              'durationMs': 5000,
              'width': 720,
              'height': 1280,
              'bytes': 10,
              'rotation': 90,
              'audio': false,
            },
            _ => null,
          };
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    final PlatformVideoCompressor compressor = PlatformVideoCompressor(
      channel: channel,
    );
    final CompressedVideo out = await compressor.compress(
      input: '/in.mp4',
      output: '/out.mp4',
      plan: planVideoCompression(durationMs: 5000),
    );
    expect(out.rotation, 90);
    expect(out.hasAudio, isFalse);
    expect(out.durationMs, 5000);
  });
}
