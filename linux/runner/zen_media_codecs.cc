#include "zen_media_codecs.h"

#ifdef ZEN_HAVE_GSTREAMER

#include <cstring>
#include <mutex>
#include <utility>
#include <vector>

const char kZenCodecRefused[] = "zen-codec-refused";

namespace {

// What Zen sends: its own films are H.264 / AAC in MP4, voice messages
// AAC; films and recordings it passes on as the phone made them are MP4 /
// MOV / 3GP (H.264, or H.265 from iPhones), WebM (VP8, VP9, Opus) or Ogg
// (Opus); its own sounds are PCM in WAV. Raw audio and video need no
// decoder and never come here.
GstStaticCaps allowed_caps = GST_STATIC_CAPS(
    // Containers and tags.
    "video/quicktime; audio/x-m4a; application/x-3gp; "
    "video/webm; audio/webm; video/x-matroska; audio/x-matroska; "
    "application/ogg; audio/ogg; audio/x-wav; application/x-id3; "
    // Pictures.
    "video/x-h264; video/x-h265; video/x-vp8; video/x-vp9; "
    // Sound: AAC and MP3 are both audio/mpeg.
    "audio/mpeg; audio/x-opus");

// Decoded sound and pictures: nothing parses or decodes them any more.
// decodebin never asks about them, but decodebin3 (playbin3 of GStreamer
// 1.20) offers them to select-stream, e.g. the PCM wavparse makes of a WAV.
GstStaticCaps raw_caps =
    GST_STATIC_CAPS("audio/x-raw(ANY); video/x-raw(ANY)");

// decodebin's GstAutoplugSelectResult (not in a public header).
constexpr gint kAutoplugTry = 0;
constexpr gint kAutoplugSkip = 2;

void PostRefusal(GstElement* element, const GstCaps* caps) {
  gchar* text = gst_caps_to_string(caps);
  g_message("Zen media player: not played: %s", text != nullptr ? text : "?");
  GstStructure* details = gst_structure_new(
      kZenCodecRefused, "caps", G_TYPE_STRING, text != nullptr ? text : "",
      nullptr);
  g_free(text);
  gst_element_post_message(
      element, gst_message_new_application(GST_OBJECT(element), details));
}

// decodebin, uridecodebin and parsebin ask before they plug each demuxer,
// parser or decoder: only for a stream Zen plays. Sinks (playbin offers
// them too) are left to playbin.
gint OnAutoplugSelect(GstElement* bin, GstPad* pad, GstCaps* caps,
                      GstElementFactory* factory, gpointer data) {
  const gchar* klass =
      gst_element_factory_get_metadata(factory, GST_ELEMENT_METADATA_KLASS);
  if (klass != nullptr && strstr(klass, "Sink") != nullptr) {
    return kAutoplugTry;
  }
  if (zen_media_caps_allowed(caps)) {
    return kAutoplugTry;
  }
  PostRefusal(bin, caps);
  return kAutoplugSkip;
}

// decodebin3 (playbin3) picks its decoders itself: a stream Zen does not
// play is never selected.
gint OnSelectStream(GstElement* decodebin, GstStreamCollection* collection,
                    GstStream* stream, gpointer data) {
  GstCaps* caps = gst_stream_get_caps(stream);
  if (caps == nullptr) {
    return -1;
  }
  const gboolean allowed = zen_media_caps_allowed(caps);
  if (!allowed) {
    PostRefusal(decodebin, caps);
  }
  gst_caps_unref(caps);
  return allowed ? -1 : 0;
}

// The decoders DemoteOtherDecoders took out, with their rank before (for
// the app's own work on the user's files, see zen_media_allow_all_decoders).
std::mutex demoted_lock;
std::vector<std::pair<GstElementFactory*, guint>>& Demoted() {
  static auto* demoted = new std::vector<std::pair<GstElementFactory*, guint>>;
  return *demoted;
}

guint RankBefore(GstPluginFeature* feature) {
  for (const auto& d : Demoted()) {
    if (GST_PLUGIN_FEATURE(d.first) == feature) {
      return d.second;
    }
  }
  return gst_plugin_feature_get_rank(feature);
}

gint ByRankBefore(gconstpointer a, gconstpointer b) {
  GstPluginFeature* fa = GST_PLUGIN_FEATURE(const_cast<gpointer>(a));
  GstPluginFeature* fb = GST_PLUGIN_FEATURE(const_cast<gpointer>(b));
  const guint ra = RankBefore(fa);
  const guint rb = RankBefore(fb);
  if (ra != rb) {
    return ra > rb ? -1 : 1;
  }
  return strcmp(gst_plugin_feature_get_name(fa), gst_plugin_feature_get_name(fb));
}

// decodebin's own list (decodable, at least marginal rank), with the
// demoted decoders back at their rank before.
GValueArray* OnAutoplugFactories(GstElement* bin, GstPad* pad, GstCaps* caps,
                                 gpointer data) {
  std::lock_guard<std::mutex> guard(demoted_lock);
  GList* all = gst_element_factory_list_get_elements(
      GST_ELEMENT_FACTORY_TYPE_DECODABLE, GST_RANK_MARGINAL);
  for (const auto& d : Demoted()) {
    if (d.second >= GST_RANK_MARGINAL &&
        gst_plugin_feature_get_rank(GST_PLUGIN_FEATURE(d.first)) <
            GST_RANK_MARGINAL) {
      all = g_list_prepend(all, gst_object_ref(d.first));
    }
  }
  GList* fit = gst_element_factory_list_filter(all, caps, GST_PAD_SINK,
                                               gst_caps_is_fixed(caps));
  fit = g_list_sort(fit, ByRankBefore);
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS
  GValueArray* result = g_value_array_new(g_list_length(fit));
  for (GList* l = fit; l != nullptr; l = l->next) {
    GValue value = G_VALUE_INIT;
    g_value_init(&value, G_TYPE_OBJECT);
    g_value_set_object(&value, l->data);
    g_value_array_append(result, &value);
    g_value_unset(&value);
  }
  G_GNUC_END_IGNORE_DEPRECATIONS
  gst_plugin_feature_list_free(fit);
  gst_plugin_feature_list_free(all);
  return result;
}

// decodebin3 (playbin3) chooses among all decoders of the registry by
// rank, and may still select a stream select-stream refused: in a process
// that plays through playbin3, a decoder for none of Zen's formats is
// never chosen. Must run before its first decodebin3 lists the decoders.
gpointer DemoteOtherDecoders(gpointer data) {
  GstCaps* allowed = gst_static_caps_get(&allowed_caps);
  GList* features = gst_registry_get_feature_list(
      gst_registry_get(), GST_TYPE_ELEMENT_FACTORY);
  for (GList* l = features; l != nullptr; l = l->next) {
    GstElementFactory* factory = GST_ELEMENT_FACTORY(l->data);
    const gchar* klass =
        gst_element_factory_get_metadata(factory, GST_ELEMENT_METADATA_KLASS);
    if (klass == nullptr || strstr(klass, "Decoder") == nullptr ||
        strstr(klass, "Bin") != nullptr) {
      continue;
    }
    gboolean ours = FALSE;
    for (const GList* t = gst_element_factory_get_static_pad_templates(factory);
         t != nullptr && !ours; t = t->next) {
      GstStaticPadTemplate* pad = static_cast<GstStaticPadTemplate*>(t->data);
      if (pad->direction != GST_PAD_SINK) {
        continue;
      }
      GstCaps* caps = gst_static_caps_get(&pad->static_caps);
      ours = !gst_caps_is_any(caps) && gst_caps_can_intersect(caps, allowed);
      gst_caps_unref(caps);
    }
    if (!ours) {
      std::lock_guard<std::mutex> guard(demoted_lock);
      Demoted().emplace_back(
          GST_ELEMENT_FACTORY(gst_object_ref(factory)),
          gst_plugin_feature_get_rank(GST_PLUGIN_FEATURE(factory)));
      gst_plugin_feature_set_rank(GST_PLUGIN_FEATURE(factory), GST_RANK_NONE);
    }
  }
  gst_plugin_feature_list_free(features);
  gst_caps_unref(allowed);
  return nullptr;
}

void Watch(GstElement* element) {
  GstElementFactory* factory = gst_element_get_factory(element);
  const gchar* name =
      factory != nullptr
          ? gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory))
          : nullptr;
  if (name == nullptr) {
    return;
  }
  if (strcmp(name, "decodebin") == 0 || strcmp(name, "uridecodebin") == 0 ||
      strcmp(name, "parsebin") == 0) {
    g_signal_connect(element, "autoplug-select",
                     G_CALLBACK(OnAutoplugSelect), nullptr);
  } else if (strcmp(name, "decodebin3") == 0 &&
             g_signal_lookup("select-stream", G_OBJECT_TYPE(element)) != 0) {
    g_signal_connect(element, "select-stream", G_CALLBACK(OnSelectStream),
                     nullptr);
  }
}

void OnDeepElementAdded(GstBin* bin, GstBin* sub_bin, GstElement* element,
                        gpointer data) {
  Watch(element);
}

}  // namespace

gboolean zen_media_caps_allowed(const GstCaps* caps) {
  if (caps == nullptr || gst_caps_is_empty(caps) || gst_caps_is_any(caps)) {
    return FALSE;
  }
  GstCaps* raw = gst_static_caps_get(&raw_caps);
  GstCaps* allowed = gst_static_caps_get(&allowed_caps);
  const gboolean subset =
      gst_caps_is_subset(caps, raw) || gst_caps_is_subset(caps, allowed);
  gst_caps_unref(allowed);
  gst_caps_unref(raw);
  return subset;
}

void zen_media_restrict_codecs(GstElement* pipeline) {
  // "playbin" is playbin3 where the system or GST_PLAY_USE_PLAYBIN3 says so.
  if (g_type_from_name("GstPlayBin3") != 0 &&
      g_type_is_a(G_OBJECT_TYPE(pipeline), g_type_from_name("GstPlayBin3"))) {
    static GOnce demoted = G_ONCE_INIT;
    g_once(&demoted, DemoteOtherDecoders, nullptr);
  }
  g_signal_connect(pipeline, "deep-element-added",
                   G_CALLBACK(OnDeepElementAdded), nullptr);
}

void zen_media_allow_all_decoders(GstElement* decodebin) {
  g_signal_connect(decodebin, "autoplug-factories",
                   G_CALLBACK(OnAutoplugFactories), nullptr);
}

#endif  // ZEN_HAVE_GSTREAMER
