#include "zen_media_player.h"

#ifdef ZEN_HAVE_GSTREAMER

#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>

#include <cstring>

#include "zen_media_codecs.h"

// One method channel for every player; each player has its own event channel
// "zen/linux_media/events/<id>" (the same split as package:video_player's own
// backends). Positions and durations travel in milliseconds.
//
// Threads: method calls and bus messages run on the GTK main thread; video
// frames arrive on GStreamer's streaming threads and are handed to Flutter's
// render thread through ZenVideoTexture under its mutex.

namespace {

constexpr char kChannelName[] = "zen/linux_media";
constexpr char kEventsPrefix[] = "zen/linux_media/events/";

// playbin's GstPlayFlags (not in a public header).
constexpr guint kPlayFlagVideo = 1 << 0;
constexpr guint kPlayFlagText = 1 << 2;

// Frames as tightly packed RGBA, square pixels, sized and turned as they
// should be shown (phones store portrait films as rotated landscape ones;
// videoflip, from gstreamer1.0-plugins-good, turns them back).
constexpr char kVideoSinkDescription[] =
    "videoconvert ! videoflip video-direction=auto ! videoscale ! "
    "appsink name=zen_sink max-buffers=2 drop=true "
    "caps=video/x-raw,format=RGBA,pixel-aspect-ratio=1/1";
// The same without videoflip.
constexpr char kPlainVideoSinkDescription[] =
    "videoconvert ! videoscale ! "
    "appsink name=zen_sink max-buffers=2 drop=true "
    "caps=video/x-raw,format=RGBA,pixel-aspect-ratio=1/1";

}  // namespace

// ---------------------------------------------------------------------------
// ZenVideoTexture: the newest decoded frame, for Flutter's render thread.

G_DECLARE_FINAL_TYPE(ZenVideoTexture,
                     zen_video_texture,
                     ZEN,
                     VIDEO_TEXTURE,
                     FlPixelBufferTexture)

struct _ZenVideoTexture {
  FlPixelBufferTexture parent_instance;

  GMutex lock;
  // The newest frame from the streaming thread, not yet shown.
  GstSample* pending;
  // The frame handed to Flutter last: it stays mapped until the next
  // copy_pixels call, because Flutter reads the pixels after that returns.
  GstSample* shown;
  GstVideoFrame frame;
  gboolean mapped;
  // A tightly packed copy when the decoder's rows are padded.
  guint8* packed;
  gsize packed_size;
  const guint8* pixels;
  guint32 width;
  guint32 height;

  // Main thread only: cleared when the texture is unregistered.
  FlTextureRegistrar* registrar;
  gint redraw_queued;
};

G_DEFINE_TYPE(ZenVideoTexture,
              zen_video_texture,
              fl_pixel_buffer_texture_get_type())

// Called with the lock held.
static void zen_video_texture_release_shown(ZenVideoTexture* self) {
  if (self->mapped) {
    gst_video_frame_unmap(&self->frame);
    self->mapped = FALSE;
  }
  g_clear_pointer(&self->shown, gst_sample_unref);
  self->pixels = nullptr;
}

static gboolean zen_video_texture_copy_pixels(FlPixelBufferTexture* texture,
                                              const uint8_t** out_buffer,
                                              uint32_t* width,
                                              uint32_t* height,
                                              GError** error) {
  ZenVideoTexture* self = ZEN_VIDEO_TEXTURE(texture);
  g_mutex_lock(&self->lock);
  GstSample* next = self->pending;
  self->pending = nullptr;
  if (next != nullptr) {
    GstCaps* caps = gst_sample_get_caps(next);
    GstBuffer* buffer = gst_sample_get_buffer(next);
    GstVideoInfo info;
    GstVideoFrame frame;
    if (caps != nullptr && buffer != nullptr &&
        gst_video_info_from_caps(&info, caps) &&
        gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) {
      zen_video_texture_release_shown(self);
      self->shown = next;
      self->frame = frame;
      self->mapped = TRUE;
      self->width = static_cast<guint32>(GST_VIDEO_FRAME_WIDTH(&self->frame));
      self->height =
          static_cast<guint32>(GST_VIDEO_FRAME_HEIGHT(&self->frame));
      const gsize row = static_cast<gsize>(self->width) * 4;
      const gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&self->frame, 0);
      const guint8* data = static_cast<const guint8*>(
          GST_VIDEO_FRAME_PLANE_DATA(&self->frame, 0));
      if (stride == static_cast<gint>(row)) {
        self->pixels = data;
      } else {
        const gsize size = row * self->height;
        if (self->packed_size < size) {
          self->packed = static_cast<guint8*>(g_realloc(self->packed, size));
          self->packed_size = size;
        }
        for (guint32 y = 0; y < self->height; y++) {
          memcpy(self->packed + y * row, data + y * stride, row);
        }
        self->pixels = self->packed;
      }
    } else {
      gst_sample_unref(next);
    }
  }
  if (self->pixels == nullptr) {
    // Nothing decoded yet (or an audio file): one transparent pixel.
    static const uint8_t kBlank[4] = {0, 0, 0, 0};
    *out_buffer = kBlank;
    *width = 1;
    *height = 1;
  } else {
    *out_buffer = self->pixels;
    *width = self->width;
    *height = self->height;
  }
  g_mutex_unlock(&self->lock);
  return TRUE;
}

static void zen_video_texture_finalize(GObject* object) {
  ZenVideoTexture* self = ZEN_VIDEO_TEXTURE(object);
  zen_video_texture_release_shown(self);
  g_clear_pointer(&self->pending, gst_sample_unref);
  g_clear_pointer(&self->packed, g_free);
  g_mutex_clear(&self->lock);
  G_OBJECT_CLASS(zen_video_texture_parent_class)->finalize(object);
}

static void zen_video_texture_class_init(ZenVideoTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      zen_video_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = zen_video_texture_finalize;
}

static void zen_video_texture_init(ZenVideoTexture* self) {
  g_mutex_init(&self->lock);
}

static gboolean zen_video_texture_redraw(gpointer data) {
  ZenVideoTexture* self = ZEN_VIDEO_TEXTURE(data);
  g_atomic_int_set(&self->redraw_queued, 0);
  if (self->registrar != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                      FL_TEXTURE(self));
  }
  return G_SOURCE_REMOVE;
}

// Streaming thread: keeps [sample] (owned) as the newest frame and asks the
// main thread to tell Flutter, at most once per pending frame.
static void zen_video_texture_push(ZenVideoTexture* self, GstSample* sample) {
  g_mutex_lock(&self->lock);
  if (self->pending != nullptr) {
    gst_sample_unref(self->pending);
  }
  self->pending = sample;
  g_mutex_unlock(&self->lock);
  if (g_atomic_int_compare_and_exchange(&self->redraw_queued, 0, 1)) {
    g_idle_add_full(G_PRIORITY_DEFAULT, zen_video_texture_redraw,
                    g_object_ref(self), g_object_unref);
  }
}

static GstFlowReturn on_new_sample(GstAppSink* sink, gpointer data) {
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample != nullptr) {
    zen_video_texture_push(ZEN_VIDEO_TEXTURE(data), sample);
  }
  return GST_FLOW_OK;
}

static GstFlowReturn on_new_preroll(GstAppSink* sink, gpointer data) {
  // The first frame, shown while paused (and after every seek).
  GstSample* sample = gst_app_sink_pull_preroll(sink);
  if (sample != nullptr) {
    zen_video_texture_push(ZEN_VIDEO_TEXTURE(data), sample);
  }
  return GST_FLOW_OK;
}

// ---------------------------------------------------------------------------
// Players.

struct ZenMediaPlugin {
  FlBinaryMessenger* messenger;
  FlTextureRegistrar* textures;
  FlMethodChannel* channel;
  GHashTable* players;  // GINT_TO_POINTER(id) -> ZenPlayer*
  gint next_id;
  // 0: not tried yet, 1: GStreamer works, -1: it does not.
  gint gst_state;
};

struct ZenPlayer {
  ZenMediaPlugin* plugin;
  gint id;
  GstElement* playbin;
  GstElement* video_sink;  // the appsink inside playbin's video bin, or null
  guint bus_watch;
  ZenVideoTexture* texture;
  FlEventChannel* events;
  gboolean listening;
  // Events sent before Dart listened (the initialized event usually is).
  GPtrArray* backlog;
  gboolean initialized;
  gboolean failed;
  gboolean looping;
  gboolean playing;    // what Dart asked for
  gboolean buffering;  // a network stream is filling its buffer
  gboolean completed;  // reached the end; cleared by play() and seeks
  gdouble speed;
};

static FlValue* event_map(const gchar* name) {
  FlValue* event = fl_value_new_map();
  fl_value_set_string_take(event, "event", fl_value_new_string(name));
  return event;
}

static void player_send_now(ZenPlayer* player, FlValue* event) {
  FlValue* name = fl_value_lookup_string(event, "event");
  if (name != nullptr && fl_value_get_type(name) == FL_VALUE_TYPE_STRING &&
      strcmp(fl_value_get_string(name), "error") == 0) {
    FlValue* message = fl_value_lookup_string(event, "message");
    fl_event_channel_send_error(
        player->events, "playback",
        message != nullptr ? fl_value_get_string(message) : "error", nullptr,
        nullptr, nullptr);
  } else {
    fl_event_channel_send(player->events, event, nullptr, nullptr);
  }
}

// Sends [event] (taken) now, or once Dart listens.
static void player_emit(ZenPlayer* player, FlValue* event) {
  if (player->listening) {
    player_send_now(player, event);
    fl_value_unref(event);
  } else {
    g_ptr_array_add(player->backlog, event);
  }
}

static void player_fail(ZenPlayer* player, const gchar* message) {
  if (player->failed) {
    return;
  }
  player->failed = TRUE;
  player->playing = FALSE;
  FlValue* event = event_map("error");
  fl_value_set_string_take(event, "message",
                           fl_value_new_string(message != nullptr
                                                   ? message
                                                   : "playback failed"));
  player_emit(player, event);
  gst_element_set_state(player->playbin, GST_STATE_NULL);
}

static void player_initialize(ZenPlayer* player) {
  player->initialized = TRUE;
  gint64 duration = 0;
  if (!gst_element_query_duration(player->playbin, GST_FORMAT_TIME,
                                  &duration) ||
      duration < 0) {
    duration = 0;
  }
  gint width = 0;
  gint height = 0;
  if (player->video_sink != nullptr) {
    GstPad* pad = gst_element_get_static_pad(player->video_sink, "sink");
    if (pad != nullptr) {
      GstCaps* caps = gst_pad_get_current_caps(pad);
      if (caps != nullptr) {
        GstVideoInfo info;
        if (gst_video_info_from_caps(&info, caps)) {
          width = GST_VIDEO_INFO_WIDTH(&info);
          height = GST_VIDEO_INFO_HEIGHT(&info);
        }
        gst_caps_unref(caps);
      }
      gst_object_unref(pad);
    }
  }
  FlValue* event = event_map("initialized");
  fl_value_set_string_take(event, "duration",
                           fl_value_new_int(duration / GST_MSECOND));
  fl_value_set_string_take(event, "width", fl_value_new_int(width));
  fl_value_set_string_take(event, "height", fl_value_new_int(height));
  player_emit(player, event);
}

static void player_seek(ZenPlayer* player, gint64 position) {
  gst_element_seek(player->playbin, player->speed, GST_FORMAT_TIME,
                   static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH |
                                             GST_SEEK_FLAG_ACCURATE),
                   GST_SEEK_TYPE_SET, position, GST_SEEK_TYPE_NONE,
                   static_cast<gint64>(GST_CLOCK_TIME_NONE));
}

static gboolean on_bus_message(GstBus* bus, GstMessage* message,
                               gpointer data) {
  ZenPlayer* player = static_cast<ZenPlayer*>(data);
  switch (GST_MESSAGE_TYPE(message)) {
    case GST_MESSAGE_ERROR: {
      GError* error = nullptr;
      gchar* debug = nullptr;
      gst_message_parse_error(message, &error, &debug);
      g_warning("Zen media player %d: %s (%s)", player->id,
                error != nullptr ? error->message : "?",
                debug != nullptr ? debug : "");
      player_fail(player, error != nullptr ? error->message : nullptr);
      g_clear_error(&error);
      g_free(debug);
      break;
    }
    case GST_MESSAGE_APPLICATION:
    case GST_MESSAGE_ELEMENT: {
      // A stream in a format Zen does not play (zen_media_codecs.cc), or
      // one no decoder is left for: the film is not played at all, not
      // only its other streams.
      const GstStructure* details = gst_message_get_structure(message);
      if (details != nullptr &&
          (gst_structure_has_name(details, kZenCodecRefused) ||
           gst_structure_has_name(details, "missing-plugin"))) {
        player_fail(player, "a format Zen does not play");
      }
      break;
    }
    case GST_MESSAGE_ASYNC_DONE:
      if (!player->initialized && !player->failed) {
        player_initialize(player);
      }
      break;
    case GST_MESSAGE_EOS:
      if (player->looping) {
        player_seek(player, 0);
      } else if (!player->completed) {
        // video_player answers with pause() and seekTo(duration), which can
        // end in another EOS: report the end only once per play().
        player->completed = TRUE;
        player->playing = FALSE;
        gst_element_set_state(player->playbin, GST_STATE_PAUSED);
        player_emit(player, event_map("completed"));
      }
      break;
    case GST_MESSAGE_BUFFERING: {
      gint percent = 100;
      gst_message_parse_buffering(message, &percent);
      if (percent < 100 && !player->buffering) {
        player->buffering = TRUE;
        if (player->playing) {
          gst_element_set_state(player->playbin, GST_STATE_PAUSED);
        }
        player_emit(player, event_map("bufferingStart"));
      } else if (percent >= 100 && player->buffering) {
        player->buffering = FALSE;
        if (player->playing) {
          gst_element_set_state(player->playbin, GST_STATE_PLAYING);
        }
        player_emit(player, event_map("bufferingEnd"));
      }
      break;
    }
    default:
      break;
  }
  return G_SOURCE_CONTINUE;
}

static FlMethodErrorResponse* on_listen(FlEventChannel* channel, FlValue* args,
                                        gpointer data) {
  ZenPlayer* player = static_cast<ZenPlayer*>(data);
  player->listening = TRUE;
  for (guint i = 0; i < player->backlog->len; i++) {
    player_send_now(player,
                    static_cast<FlValue*>(g_ptr_array_index(player->backlog, i)));
  }
  g_ptr_array_set_size(player->backlog, 0);
  return nullptr;
}

static FlMethodErrorResponse* on_cancel(FlEventChannel* channel, FlValue* args,
                                        gpointer data) {
  static_cast<ZenPlayer*>(data)->listening = FALSE;
  return nullptr;
}

static void player_free(ZenPlayer* player) {
  if (player->bus_watch != 0) {
    g_source_remove(player->bus_watch);
    player->bus_watch = 0;
  }
  // Stops (and joins) the streaming threads: no frame arrives after this.
  gst_element_set_state(player->playbin, GST_STATE_NULL);
  g_clear_pointer(&player->video_sink, gst_object_unref);
  gst_object_unref(player->playbin);
  fl_event_channel_set_stream_handlers(player->events, nullptr, nullptr,
                                       nullptr, nullptr);
  g_object_unref(player->events);
  player->texture->registrar = nullptr;
  fl_texture_registrar_unregister_texture(player->plugin->textures,
                                          FL_TEXTURE(player->texture));
  g_object_unref(player->texture);
  g_ptr_array_unref(player->backlog);
  g_free(player);
}

static gboolean ensure_gstreamer(ZenMediaPlugin* plugin) {
  if (plugin->gst_state == 0) {
    GError* error = nullptr;
    if (gst_init_check(nullptr, nullptr, &error)) {
      plugin->gst_state = 1;
    } else {
      g_warning("Zen media player: GStreamer did not start: %s",
                error != nullptr ? error->message : "?");
      g_clear_error(&error);
      plugin->gst_state = -1;
    }
  }
  return plugin->gst_state == 1;
}

static FlMethodResponse* error_response(const gchar* code,
                                        const gchar* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message, nullptr));
}

static FlMethodResponse* success_response(FlValue* result) {
  FlMethodResponse* response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  if (result != nullptr) {
    fl_value_unref(result);
  }
  return response;
}

static FlValue* arg(FlValue* args, const gchar* name) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, name);
}

static gboolean arg_int(FlValue* args, const gchar* name, gint64* out) {
  FlValue* value = arg(args, name);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return FALSE;
  }
  *out = fl_value_get_int(value);
  return TRUE;
}

static gboolean arg_double(FlValue* args, const gchar* name, gdouble* out) {
  FlValue* value = arg(args, name);
  if (value == nullptr) {
    return FALSE;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    *out = fl_value_get_float(value);
    return TRUE;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    *out = static_cast<gdouble>(fl_value_get_int(value));
    return TRUE;
  }
  return FALSE;
}

static FlMethodResponse* create_player(ZenMediaPlugin* plugin, FlValue* args) {
  FlValue* uri = arg(args, "uri");
  if (uri == nullptr || fl_value_get_type(uri) != FL_VALUE_TYPE_STRING) {
    return error_response("bad_args", "uri is missing");
  }
  if (!ensure_gstreamer(plugin)) {
    return error_response("unavailable", "GStreamer did not start");
  }
  GstElement* playbin = gst_element_factory_make("playbin", nullptr);
  if (playbin == nullptr) {
    return error_response(
        "unavailable",
        "GStreamer has no playbin (install gstreamer1.0-plugins-base)");
  }

  ZenPlayer* player = g_new0(ZenPlayer, 1);
  player->plugin = plugin;
  player->id = plugin->next_id++;
  player->playbin = GST_ELEMENT(gst_object_ref_sink(playbin));
  // Only the formats Zen itself sends are demuxed and decoded.
  zen_media_restrict_codecs(playbin);
  player->speed = 1.0;
  player->backlog =
      g_ptr_array_new_with_free_func(reinterpret_cast<GDestroyNotify>(fl_value_unref));

  player->texture =
      ZEN_VIDEO_TEXTURE(g_object_new(zen_video_texture_get_type(), nullptr));
  player->texture->registrar = plugin->textures;
  fl_texture_registrar_register_texture(plugin->textures,
                                        FL_TEXTURE(player->texture));

  guint flags = 0;
  g_object_get(playbin, "flags", &flags, nullptr);
  flags &= ~kPlayFlagText;
  GError* error = nullptr;
  GstElement* video_bin =
      gst_parse_bin_from_description(kVideoSinkDescription, TRUE, &error);
  if (video_bin == nullptr) {
    g_clear_error(&error);
    video_bin = gst_parse_bin_from_description(kPlainVideoSinkDescription,
                                               TRUE, &error);
  }
  if (video_bin != nullptr) {
    player->video_sink =
        gst_bin_get_by_name(GST_BIN(video_bin), "zen_sink");
  }
  if (video_bin != nullptr && player->video_sink != nullptr) {
    GstAppSinkCallbacks callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.new_preroll = on_new_preroll;
    callbacks.new_sample = on_new_sample;
    gst_app_sink_set_callbacks(GST_APP_SINK(player->video_sink), &callbacks,
                               player->texture, nullptr);
    g_object_set(playbin, "video-sink", video_bin, nullptr);
  } else {
    // Without videoconvert (gstreamer1.0-plugins-base) no pictures: sound
    // only, never a separate video window.
    g_warning("Zen media player: no video output: %s",
              error != nullptr ? error->message : "zen_sink missing");
    if (video_bin != nullptr) {
      gst_object_unref(video_bin);
    }
    flags &= ~kPlayFlagVideo;
  }
  g_clear_error(&error);
  g_object_set(playbin, "flags", flags, nullptr);
  // Speech stays at its pitch at 1.5x and 2x (gstreamer1.0-plugins-good).
  GstElement* tempo = gst_element_factory_make("scaletempo", nullptr);
  if (tempo != nullptr) {
    g_object_set(playbin, "audio-filter", tempo, nullptr);
  }
  g_object_set(playbin, "uri", fl_value_get_string(uri), nullptr);

  g_autofree gchar* events_name =
      g_strdup_printf("%s%d", kEventsPrefix, player->id);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  player->events = fl_event_channel_new(plugin->messenger, events_name,
                                        FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(player->events, on_listen, on_cancel,
                                       player, nullptr);

  GstBus* bus = gst_element_get_bus(playbin);
  player->bus_watch = gst_bus_add_watch(bus, on_bus_message, player);
  gst_object_unref(bus);

  g_hash_table_insert(plugin->players, GINT_TO_POINTER(player->id), player);
  // Prerolls (reads the header and the first frame); ASYNC_DONE then sends
  // "initialized". A broken file ends in an error event instead.
  if (gst_element_set_state(playbin, GST_STATE_PAUSED) ==
      GST_STATE_CHANGE_FAILURE) {
    player_fail(player, "cannot open the file");
  }

  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "playerId", fl_value_new_int(player->id));
  fl_value_set_string_take(
      result, "textureId",
      fl_value_new_int(fl_texture_get_id(FL_TEXTURE(player->texture))));
  return success_response(result);
}

static FlMethodResponse* handle_player_call(ZenMediaPlugin* plugin,
                                            const gchar* method,
                                            FlValue* args) {
  gint64 id = -1;
  if (!arg_int(args, "id", &id)) {
    return error_response("bad_args", "id is missing");
  }
  ZenPlayer* player = static_cast<ZenPlayer*>(g_hash_table_lookup(
      plugin->players, GINT_TO_POINTER(static_cast<gint>(id))));
  if (strcmp(method, "dispose") == 0) {
    if (player != nullptr) {
      g_hash_table_remove(plugin->players, GINT_TO_POINTER(player->id));
      player_free(player);
    }
    return success_response(nullptr);
  }
  if (player == nullptr) {
    return error_response("no_player", "no such player");
  }
  if (strcmp(method, "position") == 0) {
    gint64 position = 0;
    if (player->failed ||
        !gst_element_query_position(player->playbin, GST_FORMAT_TIME,
                                    &position) ||
        position < 0) {
      position = 0;
    }
    return success_response(fl_value_new_int(position / GST_MSECOND));
  }
  if (player->failed) {
    // The error event already went out; the controls just do nothing.
    return success_response(nullptr);
  }
  if (strcmp(method, "play") == 0) {
    player->playing = TRUE;
    player->completed = FALSE;
    if (!player->buffering) {
      gst_element_set_state(player->playbin, GST_STATE_PLAYING);
    }
  } else if (strcmp(method, "pause") == 0) {
    player->playing = FALSE;
    gst_element_set_state(player->playbin, GST_STATE_PAUSED);
  } else if (strcmp(method, "seekTo") == 0) {
    gint64 position = 0;
    if (!arg_int(args, "position", &position)) {
      return error_response("bad_args", "position is missing");
    }
    player_seek(player, MAX(position, 0) * GST_MSECOND);
  } else if (strcmp(method, "setVolume") == 0) {
    gdouble volume = 1.0;
    if (!arg_double(args, "volume", &volume)) {
      return error_response("bad_args", "volume is missing");
    }
    g_object_set(player->playbin, "volume", CLAMP(volume, 0.0, 1.0), nullptr);
  } else if (strcmp(method, "setSpeed") == 0) {
    gdouble speed = 1.0;
    if (!arg_double(args, "speed", &speed) || speed <= 0) {
      return error_response("bad_args", "speed must be above 0");
    }
    player->speed = speed;
    if (player->initialized) {
      gint64 position = 0;
      if (gst_element_query_position(player->playbin, GST_FORMAT_TIME,
                                     &position) &&
          position >= 0) {
        player_seek(player, position);
      }
    }
  } else if (strcmp(method, "setLooping") == 0) {
    FlValue* looping = arg(args, "looping");
    player->looping = looping != nullptr &&
                      fl_value_get_type(looping) == FL_VALUE_TYPE_BOOL &&
                      fl_value_get_bool(looping);
  } else {
    return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  return success_response(nullptr);
}

static void on_method_call(FlMethodChannel* channel, FlMethodCall* call,
                           gpointer data) {
  ZenMediaPlugin* plugin = static_cast<ZenMediaPlugin*>(data);
  const gchar* method = fl_method_call_get_name(call);
  FlValue* args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "available") == 0) {
    gboolean available = ensure_gstreamer(plugin);
    if (available) {
      GstElementFactory* factory = gst_element_factory_find("playbin");
      available = factory != nullptr;
      if (factory != nullptr) {
        gst_object_unref(factory);
      }
    }
    response = success_response(fl_value_new_bool(available));
  } else if (strcmp(method, "create") == 0) {
    response = create_player(plugin, args);
  } else {
    response = handle_player_call(plugin, method, args);
  }
  fl_method_call_respond(call, response, nullptr);
}

void zen_media_player_register(FlPluginRegistry* registry) {
  static ZenMediaPlugin* plugin = nullptr;
  if (plugin != nullptr) {
    return;
  }
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ZenMediaPlayer");
  plugin = g_new0(ZenMediaPlugin, 1);
  plugin->messenger = FL_BINARY_MESSENGER(
      g_object_ref(fl_plugin_registrar_get_messenger(registrar)));
  plugin->textures = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  plugin->players = g_hash_table_new(g_direct_hash, g_direct_equal);
  plugin->next_id = 1;
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel = fl_method_channel_new(plugin->messenger, kChannelName,
                                          FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, on_method_call,
                                            plugin, nullptr);
}

#else  // ZEN_HAVE_GSTREAMER

void zen_media_player_register(FlPluginRegistry* registry) {
  // Built without GStreamer: Dart finds no channel and plays nothing.
}

#endif  // ZEN_HAVE_GSTREAMER
