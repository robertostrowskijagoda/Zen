#ifndef RUNNER_ZEN_MEDIA_PLAYER_H_
#define RUNNER_ZEN_MEDIA_PLAYER_H_

#include <flutter_linux/flutter_linux.h>

// Audio and video playback for package:video_player on Linux, which has no
// backend of its own there. GStreamer (playbin) decodes; video frames go to
// Flutter as an FlPixelBufferTexture. The Dart side is
// lib/src/features/media/linux_video_player.dart (channel "zen/linux_media").
//
// Built only when CMake finds GStreamer (ZEN_HAVE_GSTREAMER); without it this
// registers nothing and Dart falls back to "cannot play" at once.
void zen_media_player_register(FlPluginRegistry* registry);

#endif  // RUNNER_ZEN_MEDIA_PLAYER_H_
