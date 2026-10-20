import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:zen/src/features/media/linux_video_player.dart';

const MethodChannel _channel = MethodChannel(LinuxVideoPlayer.channelName);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
  });

  group('uriFor', () {
    final LinuxVideoPlayer player = LinuxVideoPlayer(
      bundleDirectory: '/opt/zen',
    );

    test('passes file and network URIs on', () {
      expect(
        player.uriFor(
          DataSource(
            sourceType: DataSourceType.file,
            uri: 'file:///home/ada/nagranie.m4a',
          ),
        ),
        'file:///home/ada/nagranie.m4a',
      );
      expect(
        player.uriFor(
          DataSource(
            sourceType: DataSourceType.network,
            uri: 'https://example.org/a.mp4',
          ),
        ),
        'https://example.org/a.mp4',
      );
    });

    test('turns a bare path into a file URI', () {
      expect(
        player.uriFor(
          DataSource(
            sourceType: DataSourceType.file,
            uri: '/home/ada/film z wakacji.mp4',
          ),
        ),
        'file:///home/ada/film%20z%20wakacji.mp4',
      );
    });

    test('finds assets in the bundle', () {
      expect(
        player.uriFor(
          DataSource(sourceType: DataSourceType.asset, asset: 'assets/a.ogg'),
        ),
        'file:///opt/zen/data/flutter_assets/assets/a.ogg',
      );
      expect(
        player.uriFor(
          DataSource(
            sourceType: DataSourceType.asset,
            asset: 'sounds/b.ogg',
            package: 'chimes',
          ),
        ),
        'file:///opt/zen/data/flutter_assets/packages/chimes/sounds/b.ogg',
      );
    });

    test('has nothing for content URIs or a missing URI', () {
      expect(
        player.uriFor(
          DataSource(
            sourceType: DataSourceType.contentUri,
            uri: 'content://media/1',
          ),
        ),
        isNull,
      );
      expect(
        player.uriFor(DataSource(sourceType: DataSourceType.file)),
        isNull,
      );
    });
  });

  test('maps the runner events to video events', () {
    final VideoEvent initialized = LinuxVideoPlayer.videoEventFrom(
      <Object?, Object?>{
        'event': 'initialized',
        'duration': 2133,
        'width': 320,
        'height': 240,
      },
    );
    expect(initialized.eventType, VideoEventType.initialized);
    expect(initialized.duration, const Duration(milliseconds: 2133));
    expect(initialized.size, const Size(320, 240));

    final VideoEvent audio = LinuxVideoPlayer.videoEventFrom(<Object?, Object?>{
      'event': 'initialized',
      'duration': 900,
    });
    expect(audio.size, Size.zero);

    expect(
      LinuxVideoPlayer.videoEventFrom(<Object?, Object?>{
        'event': 'completed',
      }).eventType,
      VideoEventType.completed,
    );
    expect(
      LinuxVideoPlayer.videoEventFrom(<Object?, Object?>{
        'event': 'bufferingStart',
      }).eventType,
      VideoEventType.bufferingStart,
    );
    expect(
      LinuxVideoPlayer.videoEventFrom(<Object?, Object?>{
        'event': 'bufferingEnd',
      }).eventType,
      VideoEventType.bufferingEnd,
    );
    expect(
      LinuxVideoPlayer.videoEventFrom('nonsense').eventType,
      VideoEventType.unknown,
    );
  });

  test('drives the runner player over the channel', () async {
    final List<MethodCall> calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'create':
          return <String, Object?>{'playerId': 7, 'textureId': 42};
        case 'position':
          return 1500;
      }
      return null;
    });
    final LinuxVideoPlayer player = LinuxVideoPlayer();
    final int? id = await player.createWithOptions(
      VideoCreationOptions(
        dataSource: DataSource(
          sourceType: DataSourceType.file,
          uri: 'file:///tmp/a.m4a',
        ),
        viewType: VideoViewType.textureView,
      ),
    );
    expect(id, 7);
    await player.setVolume(7, 0.5);
    await player.setPlaybackSpeed(7, 1.5);
    await player.setLooping(7, true);
    await player.seekTo(7, const Duration(seconds: 2));
    await player.play(7);
    await player.pause(7);
    expect(await player.getPosition(7), const Duration(milliseconds: 1500));
    final Widget view = player.buildViewWithOptions(
      const VideoViewOptions(playerId: 7),
    );
    expect(view, isA<Texture>());
    expect((view as Texture).textureId, 42);
    await player.dispose(7);

    expect(calls.map((MethodCall call) => call.method), <String>[
      'create',
      'setVolume',
      'setSpeed',
      'setLooping',
      'seekTo',
      'play',
      'pause',
      'position',
      'dispose',
    ]);
    expect(calls.first.arguments, <String, Object?>{
      'uri': 'file:///tmp/a.m4a',
    });
    expect(calls[1].arguments, <String, Object?>{'id': 7, 'volume': 0.5});
    expect(calls[2].arguments, <String, Object?>{'id': 7, 'speed': 1.5});
    expect(calls[3].arguments, <String, Object?>{'id': 7, 'looping': true});
    expect(calls[4].arguments, <String, Object?>{'id': 7, 'position': 2000});
    expect(
      player.buildViewWithOptions(const VideoViewOptions(playerId: 7)),
      isNot(isA<Texture>()),
    );
  });

  test('a runner without a player fails at once instead of hanging', () async {
    // No handler at all: MissingPluginException (built without GStreamer).
    final LinuxVideoPlayer player = LinuxVideoPlayer();
    final int? id = await player.createWithOptions(
      VideoCreationOptions(
        dataSource: DataSource(
          sourceType: DataSourceType.file,
          uri: 'file:///tmp/a.m4a',
        ),
        viewType: VideoViewType.textureView,
      ),
    );
    expect(id, isNotNull);
    expect(id, lessThan(-1));
    await expectLater(
      player.videoEventsFor(id!),
      emitsError(isA<PlatformException>()),
    );
    // The controls do nothing; nothing reaches the (missing) channel.
    await player.play(id);
    expect(await player.getPosition(id), Duration.zero);
    await player.dispose(id);
  });

  test('a runner error on create becomes a failed player', () async {
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      throw PlatformException(code: 'unavailable', message: 'no playbin');
    });
    final LinuxVideoPlayer player = LinuxVideoPlayer();
    final int? id = await player.createWithOptions(
      VideoCreationOptions(
        dataSource: DataSource(
          sourceType: DataSourceType.file,
          uri: 'file:///tmp/a.m4a',
        ),
        viewType: VideoViewType.textureView,
      ),
    );
    await expectLater(
      player.videoEventsFor(id!),
      emitsError(
        isA<PlatformException>().having(
          (PlatformException e) => e.message,
          'message',
          'no playbin',
        ),
      ),
    );
  });

  test('VideoPlayerController initializes from the runner events', () async {
    messenger.setMockMethodCallHandler(_channel, (MethodCall call) async {
      if (call.method == 'create') {
        return <String, Object?>{'playerId': 3, 'textureId': 9};
      }
      return null;
    });
    messenger.setMockStreamHandler(
      const EventChannel('${LinuxVideoPlayer.channelName}/events/3'),
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink events) {
          events.success(<String, Object?>{
            'event': 'initialized',
            'duration': 2000,
            'width': 0,
            'height': 0,
          });
        },
      ),
    );
    addTearDown(
      () => messenger.setMockStreamHandler(
        const EventChannel('${LinuxVideoPlayer.channelName}/events/3'),
        null,
      ),
    );
    final VideoPlayerPlatform previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = LinuxVideoPlayer();
    addTearDown(() => VideoPlayerPlatform.instance = previous);

    final VideoPlayerController controller = VideoPlayerController.file(
      File('/tmp/nagranie.m4a'),
    );
    await controller.initialize();
    expect(controller.value.isInitialized, isTrue);
    expect(controller.value.duration, const Duration(seconds: 2));
    await controller.dispose();
  });

  test('VideoPlayerController fails fast without a runner player', () async {
    final VideoPlayerPlatform previous = VideoPlayerPlatform.instance;
    VideoPlayerPlatform.instance = LinuxVideoPlayer();
    addTearDown(() => VideoPlayerPlatform.instance = previous);

    final VideoPlayerController controller = VideoPlayerController.file(
      File('/tmp/nagranie.m4a'),
    );
    await expectLater(
      controller.initialize(),
      throwsA(isA<PlatformException>()),
    );
    expect(controller.value.hasError, isTrue);
    await controller.dispose();
  });
}
