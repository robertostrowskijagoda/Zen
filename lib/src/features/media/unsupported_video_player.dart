import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// The `video_player` backend where the plugin has none (Linux).
///
/// Without one, `VideoPlayerController.initialize` fails before the player
/// exists and `dispose` then waits for it forever, so a voice message or a
/// film would spin without end. This backend refuses every source at once:
/// the screens show their "could not play" message instead.
final class UnsupportedVideoPlayer extends VideoPlayerPlatform {
  /// Installs it on the platforms `video_player` does not support.
  static void registerIfNeeded() {
    if (!kIsWeb && Platform.isLinux) {
      VideoPlayerPlatform.instance = UnsupportedVideoPlayer();
    }
  }

  @override
  Future<void> init() async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async => null;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) {
    return Stream<VideoEvent>.error(
      PlatformException(
        code: 'unsupported',
        message: 'This platform has no video player.',
      ),
    );
  }

  @override
  Future<void> dispose(int playerId) async {}
}
