// Checks zen_media_codecs.cc against the system's GStreamer: films in the
// formats Zen sends play, others are refused before any decoder of theirs
// runs, through playbin and playbin3. Cases whose encoders this system
// lacks are skipped. Built and run by .github/workflows/ci.yml (step
// "Media player: only Zen's formats") with this file,
// linux/runner/zen_media_codecs.cc, -DZEN_HAVE_GSTREAMER=1,
// -Ilinux/runner and pkg-config's gstreamer-1.0.

#include <glib/gstdio.h>
#include <gst/gst.h>

#include <cstdio>
#include <cstring>
#include <string>

#include "zen_media_codecs.h"

namespace {

int failures = 0;

void Check(bool ok, const std::string& what) {
  std::printf("%s %s\n", ok ? "ok  " : "FAIL", what.c_str());
  if (!ok) {
    failures++;
  }
}

bool CapsAllowed(const char* text) {
  GstCaps* caps = gst_caps_from_string(text);
  const bool allowed = zen_media_caps_allowed(caps);
  gst_caps_unref(caps);
  return allowed;
}

bool HasElements(const char* description) {
  GError* error = nullptr;
  GstElement* pipeline = gst_parse_launch(description, &error);
  const bool ok = pipeline != nullptr && error == nullptr;
  g_clear_error(&error);
  if (pipeline != nullptr) {
    gst_object_unref(pipeline);
  }
  return ok;
}

// Writes a file with [description] (ending in "filesink location=%s").
bool Make(const char* description, const std::string& path) {
  gchar* text = g_strdup_printf(description, path.c_str());
  if (!HasElements(text)) {
    g_free(text);
    return false;
  }
  GstElement* pipeline = gst_parse_launch(text, nullptr);
  g_free(text);
  gst_element_set_state(pipeline, GST_STATE_PLAYING);
  GstBus* bus = gst_element_get_bus(pipeline);
  GstMessage* done = gst_bus_timed_pop_filtered(
      bus, 30 * GST_SECOND,
      static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
  const bool ok = done != nullptr && GST_MESSAGE_TYPE(done) == GST_MESSAGE_EOS;
  if (done != nullptr) {
    gst_message_unref(done);
  }
  gst_object_unref(bus);
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(pipeline);
  return ok;
}

struct Outcome {
  bool prerolled = false;
  bool refused = false;
  std::string elements;
};

// Opens [path] in [player] ("playbin" or "playbin3") as the app does.
Outcome Open(const char* player, const std::string& path) {
  Outcome outcome;
  GstElement* playbin = gst_element_factory_make(player, nullptr);
  if (playbin == nullptr) {
    return outcome;
  }
  g_object_set(playbin, "video-sink",
               gst_element_factory_make("fakesink", nullptr), "audio-sink",
               gst_element_factory_make("fakesink", nullptr), nullptr);
  zen_media_restrict_codecs(playbin);
  gchar* uri = gst_filename_to_uri(path.c_str(), nullptr);
  g_object_set(playbin, "uri", uri, nullptr);
  g_free(uri);
  gst_element_set_state(playbin, GST_STATE_PAUSED);
  GstBus* bus = gst_element_get_bus(playbin);
  for (;;) {
    GstMessage* message = gst_bus_timed_pop(bus, 20 * GST_SECOND);
    if (message == nullptr) {
      break;
    }
    const GstMessageType type = GST_MESSAGE_TYPE(message);
    // As zen_media_player.cc: refused, or no decoder left for it.
    if ((type == GST_MESSAGE_APPLICATION &&
         gst_structure_has_name(gst_message_get_structure(message),
                                kZenCodecRefused)) ||
        (type == GST_MESSAGE_ELEMENT &&
         gst_structure_has_name(gst_message_get_structure(message),
                                "missing-plugin"))) {
      outcome.refused = true;
    }
    const bool end =
        type == GST_MESSAGE_ERROR || type == GST_MESSAGE_ASYNC_DONE;
    outcome.prerolled = type == GST_MESSAGE_ASYNC_DONE;
    gst_message_unref(message);
    if (end) {
      break;
    }
  }
  GstIterator* it = gst_bin_iterate_recurse(GST_BIN(playbin));
  GValue item = G_VALUE_INIT;
  while (gst_iterator_next(it, &item) == GST_ITERATOR_OK) {
    GstElementFactory* factory =
        gst_element_get_factory(GST_ELEMENT(g_value_get_object(&item)));
    if (factory != nullptr) {
      outcome.elements += " ";
      outcome.elements +=
          gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory));
    }
    g_value_reset(&item);
  }
  gst_iterator_free(it);
  gst_object_unref(bus);
  gst_element_set_state(playbin, GST_STATE_NULL);
  gst_object_unref(playbin);
  return outcome;
}

struct Case {
  const char* name;
  const char* make;
  bool plays;
  // A decoder that must never run for it (or null).
  const char* never;
};

}  // namespace

int main(int argc, char** argv) {
  gst_init(&argc, &argv);

  Check(CapsAllowed("video/x-h264, stream-format=avc"), "H.264 plays");
  Check(CapsAllowed("audio/mpeg, mpegversion=4"), "AAC plays");
  Check(CapsAllowed("audio/mpeg, mpegversion=1, layer=3"), "MP3 plays");
  Check(CapsAllowed("video/quicktime, variant=iso"), "MP4 plays");
  Check(CapsAllowed("audio/x-opus"), "Opus plays");
  // Decoded already (the PCM of a WAV): decodebin3 asks about it too.
  Check(CapsAllowed("audio/x-raw, format=S16LE, rate=48000, channels=2"),
        "raw audio plays");
  Check(CapsAllowed("video/x-raw, format=I420"), "raw video plays");
  Check(!CapsAllowed("audio/x-raw; audio/x-vorbis"), "raw or Vorbis refused");
  Check(!CapsAllowed("video/mpeg, mpegversion=4"), "MPEG-4 Part 2 refused");
  Check(!CapsAllowed("audio/x-ac3"), "AC-3 refused");
  Check(!CapsAllowed("video/x-theora"), "Theora refused");
  Check(!CapsAllowed("video/x-msvideo"), "AVI refused");
  Check(!CapsAllowed("ANY"), "ANY refused");
  Check(!CapsAllowed("EMPTY"), "EMPTY refused");

  gchar* dir = g_dir_make_tmp("zen_codecs_XXXXXX", nullptr);
  const Case cases[] = {
      {"wav", "audiotestsrc num-buffers=20 ! audioconvert ! wavenc ! "
              "filesink location=%s",
       true, nullptr},
      {"ogg-opus", "audiotestsrc num-buffers=20 ! audioconvert ! "
                   "audioresample ! opusenc ! oggmux ! filesink location=%s",
       true, nullptr},
      {"webm-vp8", "videotestsrc num-buffers=20 ! vp8enc ! webmmux ! "
                   "filesink location=%s",
       true, nullptr},
      {"ogg-theora", "videotestsrc num-buffers=20 ! theoraenc ! oggmux ! "
                     "filesink location=%s",
       false, "theoradec"},
      {"ogg-vorbis", "audiotestsrc num-buffers=20 ! audioconvert ! "
                     "vorbisenc ! oggmux ! filesink location=%s",
       false, "vorbisdec"},
      {"mp4-mpeg4", "videotestsrc num-buffers=20 ! avenc_mpeg4 ! mp4mux ! "
                    "filesink location=%s",
       false, "avdec_mpeg4"},
  };
  for (const Case& c : cases) {
    const std::string path = std::string(dir) + "/" + c.name;
    if (!Make(c.make, path)) {
      std::printf("skip %s (no encoder here)\n", c.name);
      continue;
    }
    for (const char* player : {"playbin", "playbin3"}) {
      if (!HasElements(player)) {
        continue;
      }
      const Outcome o = Open(player, path);
      const std::string what = std::string(c.name) + " in " + player + ":" +
                               o.elements;
      if (c.plays) {
        Check(o.prerolled && !o.refused, what + " plays");
      } else {
        Check(o.refused, what + " is refused");
        Check(o.elements.find(std::string(" ") + c.never) ==
                  std::string::npos,
              what + " never runs " + c.never);
      }
    }
    g_remove(path.c_str());
  }
  g_rmdir(dir);
  g_free(dir);
  std::printf("%d failure(s)\n", failures);
  return failures == 0 ? 0 : 1;
}
