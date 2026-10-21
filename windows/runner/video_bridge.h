#ifndef RUNNER_VIDEO_BRIDGE_H_
#define RUNNER_VIDEO_BRIDGE_H_

#include <flutter/binary_messenger.h>

// Films of the "Filmy" section made small enough to travel between friends:
// method channel "zen/video" (see video_compressor.dart), with Windows' own
// Media Foundation (Source Reader → Sink Writer, hardware encoders when the
// computer has them), no other library:
//  - "isAvailable": true when Media Foundation starts;
//  - "compress" {input, output, startMs, endMs (-1: to the end),
//    maxShortSide, videoBitrate, audioBitrate}: H.264 at most 720p at the
//    asked bit rate and AAC in an MP4, cut to the asked start and end →
//    {durationMs, width, height, bytes}; "progress" {fraction} is called
//    back meanwhile;
//  - "cancel": the running compression fails with "cancelled";
//  - "thumbnail" {input, atMs, maxSide}: one frame as JPEG bytes (turned
//    upright, through the Windows Imaging Component), or null.
namespace video_bridge {

void Register(flutter::BinaryMessenger* messenger);

}  // namespace video_bridge

#endif  // RUNNER_VIDEO_BRIDGE_H_
