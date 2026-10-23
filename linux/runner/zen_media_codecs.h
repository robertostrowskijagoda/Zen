#ifndef RUNNER_ZEN_MEDIA_CODECS_H_
#define RUNNER_ZEN_MEDIA_CODECS_H_

#ifdef ZEN_HAVE_GSTREAMER

#include <gst/gst.h>

// Films and recordings from friends are demuxed, parsed and decoded only in
// the formats Zen itself sends (MP4 / WebM / Ogg / WAV with H.264, H.265,
// VP8, VP9, AAC, MP3 or Opus), never by whatever rarely used decoder the
// system's GStreamer has (gstreamer1.0-libav, -plugins-bad, -plugins-ugly),
// where memory bugs are found every year.

// The name of the application message a pipeline posts on its bus when it
// refused a stream (its "caps" field says which).
extern const char kZenCodecRefused[];

// Whether [caps] (a stream before it is demuxed, parsed or decoded) is in
// a format Zen plays.
gboolean zen_media_caps_allowed(const GstCaps* caps);

// Restricts [pipeline] (a playbin or playbin3): every decodebin,
// uridecodebin, parsebin and decodebin3 it creates skips what
// zen_media_caps_allowed refuses, and the pipeline then posts
// kZenCodecRefused. Call before its URI is set.
void zen_media_restrict_codecs(GstElement* pipeline);

// For [decodebin] (not inside a player) working on the user's own files,
// e.g. a film from the gallery before it is sent: it may use every decoder
// of the system, also those the players' restriction demoted. Call before
// it is linked.
void zen_media_allow_all_decoders(GstElement* decodebin);

#endif  // ZEN_HAVE_GSTREAMER

#endif  // RUNNER_ZEN_MEDIA_CODECS_H_
