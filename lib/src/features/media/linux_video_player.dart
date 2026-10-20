import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The `video_player` backend on Linux, where the plugin has none: the
/// runner plays through GStreamer (linux/runner/zen_media_player.cc) and
/// shows films as a texture.
///
/// When the runner has no player (built without GStreamer, or GStreamer
/// cannot start) every source fails at once with a [PlatformException], so
/// the screens show their "could not play" message instead of spinning:
/// `VideoPlayerController.initialize` would otherwise wait forever.
final class LinuxVideoPlayer extends VideoPlayerPlatform {
  LinuxVideoPlayer({
    MethodChannel channel = const MethodChannel(channelName),
    String? bundleDirectory,
  }) : _channel = channel,
       _bundleDirectory = bundleDirectory;

  /// The runner's method channel; events go to `$channelName/events/<id>`.
  static const String channelName = 'zen/linux_media';

  /// Installs it on Linux; elsewhere `video_player` has its own backends.
  static void registerIfNeeded() {
    if (!kIsWeb && Platform.isLinux) {
      VideoPlayerPlatform.instance = LinuxVideoPlayer();
    }
  }

  final MethodChannel _channel;
  final String? _bundleDirectory;

  /// Texture of each player the runner created.
  final Map<int, int> _textures = <int, int>{};

  /// Players that could not be created, with the reason; their ids are
  /// negative so they never meet the runner's.
  final Map<int, String> _failed = <int, String>{};
  int _nextFailedId = -2;

  bool _isFailed(int playerId) => _failed.containsKey(playerId);

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final String? uri = uriFor(options.dataSource);
    if (uri == null) {
      return _fail('This source cannot be played on Linux.');
    }
    try {
      final Map<Object?, Object?>? created = await _channel
          .invokeMapMethod<Object?, Object?>('create', <String, Object?>{
            'uri': uri,
          });
      final Object? playerId = created?['playerId'];
      final Object? textureId = created?['textureId'];
      if (playerId is! int || textureId is! int) {
        return _fail('The media player did not start.');
      }
      _textures[playerId] = textureId;
      return playerId;
    } on MissingPluginException {
      return _fail('This build has no media player (GStreamer).');
    } on PlatformException catch (error) {
      return _fail(error.message ?? error.code);
    }
  }

  int _fail(String reason) {
    final int id = _nextFailedId--;
    _failed[id] = reason;
    return id;
  }

  /// The URI GStreamer opens for [source], or null when there is none.
  @visibleForTesting
  String? uriFor(DataSource source) {
    switch (source.sourceType) {
      case DataSourceType.network:
      case DataSourceType.file:
        final String? uri = source.uri;
        if (uri == null || uri.isEmpty) {
          return null;
        }
        // video_player passes files as file:// URIs; a bare path is
        // accepted too.
        return uri.startsWith('/')
            ? Uri.file(uri, windows: false).toString()
            : uri;
      case DataSourceType.asset:
        final String? asset = source.asset;
        if (asset == null) {
          return null;
        }
        final String key = source.package == null
            ? asset
            : 'packages/${source.package}/$asset';
        final String bundle =
            _bundleDirectory ??
            File(Platform.resolvedExecutable).parent.absolute.path;
        return Uri.file(
          '$bundle/data/flutter_assets/$key',
          windows: false,
        ).toString();
      case DataSourceType.contentUri:
        return null;
    }
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    final String? reason = _failed[playerId];
    if (reason != null) {
      return Stream<VideoEvent>.error(
        PlatformException(code: 'unsupported', message: reason),
      );
    }
    return EventChannel(
      '$channelName/events/$playerId',
    ).receiveBroadcastStream().map(videoEventFrom);
  }

  /// One event of the runner as a [VideoEvent].
  @visibleForTesting
  static VideoEvent videoEventFrom(Object? raw) {
    final Map<Object?, Object?> event = raw is Map<Object?, Object?>
        ? raw
        : const <Object?, Object?>{};
    switch (event['event']) {
      case 'initialized':
        final int width = _int(event['width']);
        final int height = _int(event['height']);
        return VideoEvent(
          eventType: VideoEventType.initialized,
          duration: Duration(milliseconds: _int(event['duration'])),
          size: Size(width.toDouble(), height.toDouble()),
          rotationCorrection: 0,
        );
      case 'completed':
        return VideoEvent(eventType: VideoEventType.completed);
      case 'bufferingStart':
        return VideoEvent(eventType: VideoEventType.bufferingStart);
      case 'bufferingEnd':
        return VideoEvent(eventType: VideoEventType.bufferingEnd);
      default:
        return VideoEvent(eventType: VideoEventType.unknown);
    }
  }

  static int _int(Object? value) => value is int ? value : 0;

  Future<void> _call(
    String method,
    int playerId, [
    Map<String, Object?>? args,
  ]) {
    if (_isFailed(playerId)) {
      return Future<void>.value();
    }
    return _channel.invokeMethod<void>(method, <String, Object?>{
      'id': playerId,
      ...?args,
    });
  }

  @override
  Future<void> dispose(int playerId) async {
    if (_failed.remove(playerId) != null) {
      return;
    }
    _textures.remove(playerId);
    await _call('dispose', playerId);
  }

  @override
  Future<void> setLooping(int playerId, bool looping) =>
      _call('setLooping', playerId, <String, Object?>{'looping': looping});

  @override
  Future<void> play(int playerId) => _call('play', playerId);

  @override
  Future<void> pause(int playerId) => _call('pause', playerId);

  @override
  Future<void> setVolume(int playerId, double volume) =>
      _call('setVolume', playerId, <String, Object?>{'volume': volume});

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) =>
      _call('setSpeed', playerId, <String, Object?>{'speed': speed});

  @override
  Future<void> seekTo(int playerId, Duration position) => _call(
    'seekTo',
    playerId,
    <String, Object?>{'position': position.inMilliseconds},
  );

  @override
  Future<Duration> getPosition(int playerId) async {
    if (_isFailed(playerId)) {
      return Duration.zero;
    }
    final int? milliseconds = await _channel.invokeMethod<int>(
      'position',
      <String, Object?>{'id': playerId},
    );
    return Duration(milliseconds: milliseconds ?? 0);
  }

  @override
  Widget buildViewWithOptions(VideoViewOptions options) {
    final int? textureId = _textures[options.playerId];
    return textureId == null
        ? const SizedBox.shrink()
        : Texture(textureId: textureId);
  }
}
