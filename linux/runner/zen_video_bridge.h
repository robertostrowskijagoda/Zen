#ifndef RUNNER_ZEN_VIDEO_BRIDGE_H_
#define RUNNER_ZEN_VIDEO_BRIDGE_H_

#include <flutter_linux/flutter_linux.h>

// Films of the "Filmy" section on Linux (see video_compressor.dart and
// film_camera_channel.dart):
//
// "zen/video" — compressing and trimming. The picture is decoded by the
// system's GStreamer (the same plugins that play films in Zen) or, without
// a usable decoder there, by an installed ffmpeg; it is encoded by Zen's
// own H.264 encoder (OpenH264, built from source with the app) at most
// 720p at the asked bit rate, and written by Zen's own MP4 writer with the
// index in front (zen_film_codec.cc). Sound: an AAC track is copied as it
// is; other sound is encoded by a GStreamer AAC encoder (avenc_aac,
// fdkaacenc, voaacenc, faac) or ffmpeg's; with none of them the film goes
// without sound and the answer says so ("audio": false).
//  - "isAvailable": a decoder exists (GStreamer's decodebin or ffmpeg);
//  - "compress" {input, output, startMs, endMs, maxShortSide, videoBitrate,
//    audioBitrate, width, height, rotation (what Dart read from the file)}
//    → {durationMs, width, height, bytes, rotation, audio}; "progress"
//    {fraction} meanwhile;
//  - "cancel"; "thumbnail" {input, atMs, maxSide} → JPEG bytes or null.
//
// "zen/camera" — the recorder's camera: a GStreamer camera source (v4l2,
// libcamera, PipeWire: whatever GstDeviceMonitor lists) and the default
// microphone; the picture goes to Flutter as a texture and, while
// recording, through Zen's encoder into an MP4 (sound only when a GStreamer
// AAC encoder is installed).
//  - "lenses" → ["front"(, "back")]; "open" {lens} → {textureId, width,
//    height}; "setTorch" (no light: ignored); "start"; "stop" → path;
//    "close".
void zen_video_bridge_register(FlPluginRegistry* registry);

#endif  // RUNNER_ZEN_VIDEO_BRIDGE_H_
