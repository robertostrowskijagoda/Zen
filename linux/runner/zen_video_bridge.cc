#include "zen_video_bridge.h"

#include <gdk-pixbuf/gdk-pixbuf.h>
#include <glib/gstdio.h>
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "zen_film_codec.h"

#ifdef ZEN_HAVE_GSTREAMER
#include <gst/app/gstappsink.h>
#include <gst/gst.h>
#include <gst/video/video.h>

#include "zen_media_codecs.h"
#endif

namespace {

constexpr char kVideoChannel[] = "zen/video";
constexpr char kCameraChannel[] = "zen/camera";

struct Plugin {
  FlMethodChannel* video = nullptr;
  FlMethodChannel* camera = nullptr;
  FlTextureRegistrar* textures = nullptr;
};

Plugin* g_plugin = nullptr;
std::atomic<bool> g_cancelled{false};
std::atomic<bool> g_busy{false};
// The ffmpeg running for the compression, to stop it on "cancel".
std::atomic<int> g_child{0};

// What Dart asked for.
struct Job {
  std::string input;
  std::string output;
  int64_t start_ms = 0;
  int64_t end_ms = -1;
  int max_short = 720;
  int video_bitrate = 2500000;
  int audio_bitrate = 128000;
  // The film as Dart read its index (0: unknown).
  int width = 0;
  int height = 0;
  int rotation = 0;
};

struct Outcome {
  int64_t duration_ms = 0;
  int width = 0;
  int height = 0;
  int64_t bytes = 0;
  bool audio = true;
};

// ---- small helpers --------------------------------------------------------

FlValue* Arg(FlValue* args, const char* name) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  return fl_value_lookup_string(args, name);
}

std::string ArgString(FlValue* args, const char* name) {
  FlValue* v = Arg(args, name);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_STRING
             ? std::string(fl_value_get_string(v))
             : std::string();
}

int64_t ArgInt(FlValue* args, const char* name, int64_t fallback) {
  FlValue* v = Arg(args, name);
  return v != nullptr && fl_value_get_type(v) == FL_VALUE_TYPE_INT
             ? fl_value_get_int(v)
             : fallback;
}

// Runs [task] on the main thread (Flutter's channels live there).
void OnMain(std::function<void()> task) {
  auto* held = new std::function<void()>(std::move(task));
  g_main_context_invoke_full(
      nullptr, G_PRIORITY_DEFAULT,
      [](gpointer data) -> gboolean {
        (*static_cast<std::function<void()>*>(data))();
        return G_SOURCE_REMOVE;
      },
      held,
      [](gpointer data) { delete static_cast<std::function<void()>*>(data); });
}

void Respond(FlMethodCall* call, FlValue* result) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_success_response_new(result));
  fl_method_call_respond(call, response, nullptr);
  if (result != nullptr) {
    fl_value_unref(result);
  }
}

void Fail(FlMethodCall* call, const std::string& code,
          const std::string& message) {
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_error_response_new(code.c_str(), message.c_str(), nullptr));
  fl_method_call_respond(call, response, nullptr);
}

void Progress(double fraction) {
  static std::atomic<int64_t> last{0};
  const int64_t now = g_get_monotonic_time();
  if (fraction < 1.0 && now - last.load() < 250000) {
    return;
  }
  last = now;
  const double f = std::min(1.0, std::max(0.0, fraction));
  OnMain([f]() {
    if (g_plugin == nullptr) {
      return;
    }
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "fraction", fl_value_new_float(f));
    fl_method_channel_invoke_method(g_plugin->video, "progress", args,
                                    nullptr, nullptr, nullptr);
  });
}

// video_compressor.dart's scaledVideoSize.
std::pair<int, int> ScaledSize(int width, int height, int max_short) {
  if (width <= 0 || height <= 0) {
    return {0, 0};
  }
  const int shortest = std::min(width, height);
  if (shortest <= max_short) {
    return {width & ~1, height & ~1};
  }
  const double scale = static_cast<double>(max_short) / shortest;
  auto even = [](double v) {
    return std::max(2, static_cast<int>(std::lround(v)) & ~1);
  };
  return {even(width * scale), even(height * scale)};
}

int64_t FileSize(const std::string& path) {
  GStatBuf st;
  return g_stat(path.c_str(), &st) == 0 ? static_cast<int64_t>(st.st_size)
                                        : 0;
}

std::string Seconds(int64_t ms) {
  char text[32];
  snprintf(text, sizeof(text), "%.3f", static_cast<double>(ms) / 1000.0);
  return text;
}

// ---- ffmpeg, when installed ------------------------------------------------

bool HasFfmpeg() {
  gchar* path = g_find_program_in_path("ffmpeg");
  const bool found = path != nullptr;
  g_free(path);
  return found;
}

struct Child {
  GPid pid = 0;
  int out = -1;
};

bool Spawn(const std::vector<std::string>& args, Child* child) {
  std::vector<gchar*> argv;
  for (const std::string& a : args) {
    argv.push_back(const_cast<gchar*>(a.c_str()));
  }
  argv.push_back(nullptr);
  GError* error = nullptr;
  const gboolean ok = g_spawn_async_with_pipes(
      nullptr, argv.data(), nullptr,
      static_cast<GSpawnFlags>(G_SPAWN_SEARCH_PATH |
                               G_SPAWN_DO_NOT_REAP_CHILD |
                               G_SPAWN_STDERR_TO_DEV_NULL),
      nullptr, nullptr, &child->pid, nullptr, &child->out, nullptr, &error);
  g_clear_error(&error);
  if (ok) {
    g_child = child->pid;
  }
  return ok;
}

// Reads exactly [size] bytes; false at the end of the stream.
bool ReadExactly(int fd, uint8_t* buffer, size_t size) {
  size_t got = 0;
  while (got < size) {
    const ssize_t n = read(fd, buffer + got, size - got);
    if (n <= 0) {
      return false;
    }
    got += static_cast<size_t>(n);
  }
  return true;
}

std::vector<uint8_t> ReadAll(int fd) {
  std::vector<uint8_t> out;
  uint8_t chunk[65536];
  while (true) {
    const ssize_t n = read(fd, chunk, sizeof(chunk));
    if (n <= 0) {
      break;
    }
    out.insert(out.end(), chunk, chunk + n);
  }
  return out;
}

// Waits for [child]; its exit status, or -1.
int Finish(Child* child) {
  if (child->out >= 0) {
    close(child->out);
    child->out = -1;
  }
  int status = 0;
  waitpid(child->pid, &status, 0);
  g_spawn_close_pid(child->pid);
  g_child = 0;
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

std::vector<std::string> FfmpegInput(const Job& job) {
  std::vector<std::string> args = {"ffmpeg", "-v", "error", "-nostdin"};
  if (job.start_ms > 0) {
    args.push_back("-ss");
    args.push_back(Seconds(job.start_ms));
  }
  if (job.end_ms >= 0) {
    args.push_back("-to");
    args.push_back(Seconds(job.end_ms));
  }
  args.push_back("-i");
  args.push_back(job.input);
  return args;
}

// The picture decoded and scaled by ffmpeg (it turns phone films upright
// by itself), encoded by Zen's encoder; the sound encoded to AAC by ffmpeg.
bool FfmpegCompress(const Job& job, Outcome* outcome, std::string* code,
                    std::string* error) {
  const bool turned = job.rotation == 90 || job.rotation == 270;
  const int shown_w = turned ? job.height : job.width;
  const int shown_h = turned ? job.width : job.height;
  const std::pair<int, int> size = ScaledSize(shown_w, shown_h, job.max_short);
  if (size.first <= 0) {
    *code = "unsupported";
    *error = "the film's size is not known";
    return false;
  }
  zen_film::H264Encoder encoder;
  if (!encoder.Open(size.first, size.second, 30, job.video_bitrate)) {
    *code = "failed";
    *error = "the H.264 encoder did not start";
    return false;
  }
  std::vector<std::string> args = FfmpegInput(job);
  const std::vector<std::string> video = {
      "-an", "-vf",
      "scale=" + std::to_string(size.first) + ":" +
          std::to_string(size.second) + ",format=yuv420p",
      "-r", "30", "-f", "rawvideo", "-"};
  args.insert(args.end(), video.begin(), video.end());
  Child child;
  if (!Spawn(args, &child)) {
    *code = "unsupported";
    *error = "ffmpeg did not start";
    return false;
  }
  const size_t w = static_cast<size_t>(size.first);
  const size_t h = static_cast<size_t>(size.second);
  std::vector<uint8_t> frame(w * h * 3 / 2);
  const double span_ms = static_cast<double>(std::max<int64_t>(
      1, (job.end_ms >= 0 ? job.end_ms : job.start_ms + 90000) -
             job.start_ms));
  int64_t index = 0;
  bool ok = true;
  while (ReadExactly(child.out, frame.data(), frame.size())) {
    if (g_cancelled.load()) {
      kill(child.pid, SIGTERM);
      ok = false;
      break;
    }
    const int64_t pts = index * 1000000 / 30;
    const uint8_t* y = frame.data();
    const uint8_t* u = y + w * h;
    const uint8_t* v = u + (w / 2) * (h / 2);
    if (!encoder.Encode(y, size.first, u, size.first / 2, v, size.first / 2,
                        pts)) {
      kill(child.pid, SIGTERM);
      ok = false;
      break;
    }
    index++;
    Progress(static_cast<double>(pts / 1000) / span_ms * 0.9);
  }
  Finish(&child);
  if (g_cancelled.load()) {
    *code = "cancelled";
    *error = "cancelled";
    return false;
  }
  if (!ok || encoder.track().samples.empty()) {
    *code = "failed";
    *error = "ffmpeg gave no picture";
    return false;
  }
  zen_film::AudioTrack audio;
  args = FfmpegInput(job);
  const std::vector<std::string> sound = {
      "-vn", "-c:a", "aac", "-b:a", std::to_string(job.audio_bitrate),
      "-f", "adts", "-"};
  args.insert(args.end(), sound.begin(), sound.end());
  if (Spawn(args, &child)) {
    const std::vector<uint8_t> adts = ReadAll(child.out);
    Finish(&child);
    // Nothing comes for a silent film: it simply has no sound track.
    zen_film::ReadAdts(adts, &audio);
  }
  if (!zen_film::WriteMp4(job.output, encoder.track(), &audio, 0, error)) {
    *code = "failed";
    return false;
  }
  outcome->width = size.first;
  outcome->height = size.second;
  outcome->duration_ms = index * 1000 / 30;
  outcome->bytes = FileSize(job.output);
  Progress(1.0);
  return true;
}

std::vector<uint8_t> FfmpegThumbnail(const std::string& input, int64_t at_ms,
                                     int max_side) {
  const std::string side = std::to_string(max_side);
  const std::vector<std::string> args = {
      "ffmpeg", "-v", "error", "-nostdin", "-ss", Seconds(at_ms),
      "-i", input, "-frames:v", "1", "-vf",
      "scale=w=" + side + ":h=" + side +
          ":force_original_aspect_ratio=decrease",
      "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "4", "-"};
  Child child;
  if (!Spawn(args, &child)) {
    return {};
  }
  std::vector<uint8_t> jpeg = ReadAll(child.out);
  if (Finish(&child) != 0) {
    jpeg.clear();
  }
  return jpeg;
}

// ---- GStreamer -------------------------------------------------------------

#ifdef ZEN_HAVE_GSTREAMER

bool GstReady() {
  static gint state = 0;
  if (g_atomic_int_get(&state) == 0) {
    g_atomic_int_set(&state,
                     gst_init_check(nullptr, nullptr, nullptr) ? 1 : -1);
  }
  return g_atomic_int_get(&state) == 1;
}

bool HasFactory(const char* name) {
  GstElementFactory* factory = gst_element_factory_find(name);
  if (factory == nullptr) {
    return false;
  }
  gst_object_unref(factory);
  return true;
}

// An AAC encoder of the system's GStreamer, or null (Zen's own bundled
// encoder, zen_film::AacEncoder, comes first; this is for a build without
// it).
const char* SystemAacEncoder() {
  for (const char* name : {"avenc_aac", "fdkaacenc", "voaacenc", "faac"}) {
    if (HasFactory(name)) {
      return name;
    }
  }
  return nullptr;
}

// Waits up to [seconds] for a state change; false when it failed.
bool Settle(GstElement* pipeline, int seconds) {
  const GstStateChangeReturn r = gst_element_get_state(
      pipeline, nullptr, nullptr, static_cast<GstClockTime>(seconds) *
                                      GST_SECOND);
  return r == GST_STATE_CHANGE_SUCCESS || r == GST_STATE_CHANGE_NO_PREROLL;
}

GstElement* Launch(const std::string& description, const std::string& input) {
  GError* error = nullptr;
  GstElement* pipeline = gst_parse_launch(description.c_str(), &error);
  if (pipeline == nullptr || error != nullptr) {
    g_clear_error(&error);
    if (pipeline != nullptr) {
      gst_object_unref(pipeline);
    }
    return nullptr;
  }
  GstElement* src = gst_bin_get_by_name(GST_BIN(pipeline), "src");
  if (src != nullptr) {
    g_object_set(src, "location", input.c_str(), nullptr);
    gst_object_unref(src);
  }
  // The user's own film: not limited to what the player plays.
  GstElement* decode = gst_bin_get_by_name(GST_BIN(pipeline), "dec");
  if (decode != nullptr) {
    zen_media_allow_all_decoders(decode);
    gst_object_unref(decode);
  }
  return pipeline;
}

std::string Flip() {
  return HasFactory("videoflip") ? "videoflip video-direction=auto ! " : "";
}

// The first decoded frame's size (upright when videoflip is there) and the
// film's length.
bool GstProbe(const std::string& input, int* width, int* height,
              gint64* duration) {
  GstElement* pipeline = Launch(
      "filesrc name=src ! decodebin name=dec ! " + Flip() +
          "videoconvert ! appsink name=sink sync=false "
          "caps=video/x-raw,format=I420",
      input);
  if (pipeline == nullptr) {
    return false;
  }
  bool ok = false;
  gst_element_set_state(pipeline, GST_STATE_PAUSED);
  if (Settle(pipeline, 20)) {
    GstElement* sink = gst_bin_get_by_name(GST_BIN(pipeline), "sink");
    GstSample* sample =
        sink != nullptr ? gst_app_sink_pull_preroll(GST_APP_SINK(sink))
                        : nullptr;
    GstVideoInfo info;
    if (sample != nullptr &&
        gst_video_info_from_caps(&info, gst_sample_get_caps(sample))) {
      *width = GST_VIDEO_INFO_WIDTH(&info);
      *height = GST_VIDEO_INFO_HEIGHT(&info);
      ok = *width > 0 && *height > 0;
    }
    if (sample != nullptr) {
      gst_sample_unref(sample);
    }
    if (sink != nullptr) {
      gst_object_unref(sink);
    }
    if (!gst_element_query_duration(pipeline, GST_FORMAT_TIME, duration)) {
      *duration = 0;
    }
  }
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(pipeline);
  return ok;
}

struct GstRun {
  zen_film::H264Encoder encoder;
  zen_film::AudioTrack audio;
  GstClockTime start = 0;
  GstClockTime end = GST_CLOCK_TIME_NONE;
  double span = 1;
  int width = 0;
  int height = 0;
  bool flip = false;
  const char* aac = nullptr;
  int audio_bitrate = 128000;
  // Zen's own AAC encoder for sound that is not AAC already; null when the
  // build has none.
  std::unique_ptr<zen_film::AacEncoder> pcm;
  std::atomic<bool> failed{false};
  bool video_linked = false;
  bool audio_linked = false;
  bool audio_lost = false;
  int64_t last_us = 0;
};

bool InRange(GstClockTime pts, GstClockTime start, GstClockTime end) {
  return GST_CLOCK_TIME_IS_VALID(pts) && pts >= start &&
         (!GST_CLOCK_TIME_IS_VALID(end) || pts <= end);
}

GstFlowReturn OnVideo(GstAppSink* sink, gpointer data) {
  GstRun* run = static_cast<GstRun*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstVideoInfo info;
  GstVideoFrame frame;
  const GstClockTime pts =
      buffer != nullptr ? GST_BUFFER_PTS(buffer) : GST_CLOCK_TIME_NONE;
  if (InRange(pts, run->start, run->end) &&
      gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
      gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) {
    const int64_t us = static_cast<int64_t>((pts - run->start) / 1000);
    if (!run->encoder.Encode(
            static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0)),
            GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
            static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 1)),
            GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1),
            static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 2)),
            GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 2), us)) {
      run->failed = true;
    }
    run->last_us = std::max(run->last_us, us);
    gst_video_frame_unmap(&frame);
    Progress(static_cast<double>(us) / 1000.0 / run->span);
  }
  gst_sample_unref(sample);
  return run->failed.load() ? GST_FLOW_ERROR : GST_FLOW_OK;
}

// AAC frames (copied, or from the system's encoder) with their config.
GstFlowReturn OnAudio(GstAppSink* sink, gpointer data) {
  GstRun* run = static_cast<GstRun*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  if (run->audio.config.empty()) {
    GstCaps* caps = gst_sample_get_caps(sample);
    GstStructure* s =
        caps != nullptr ? gst_caps_get_structure(caps, 0) : nullptr;
    const GValue* codec = s != nullptr
                              ? gst_structure_get_value(s, "codec_data")
                              : nullptr;
    gint rate = 0;
    gint channels = 0;
    if (codec != nullptr && G_VALUE_HOLDS(codec, GST_TYPE_BUFFER) &&
        gst_structure_get_int(s, "rate", &rate) &&
        gst_structure_get_int(s, "channels", &channels)) {
      GstBuffer* config = gst_value_get_buffer(codec);
      GstMapInfo map;
      if (gst_buffer_map(config, &map, GST_MAP_READ)) {
        run->audio.config.assign(map.data, map.data + map.size);
        gst_buffer_unmap(config, &map);
      }
      run->audio.sample_rate = rate;
      run->audio.channels = channels;
    }
  }
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  const GstClockTime pts =
      buffer != nullptr ? GST_BUFFER_PTS(buffer) : GST_CLOCK_TIME_NONE;
  GstMapInfo map;
  if (!run->audio.config.empty() && InRange(pts, run->start, run->end) &&
      gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    zen_film::Sample s;
    s.data.assign(map.data, map.data + map.size);
    s.pts_us = static_cast<int64_t>((pts - run->start) / 1000);
    s.key = true;
    run->audio.samples.push_back(std::move(s));
    gst_buffer_unmap(buffer, &map);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

// Decoded sound (16-bit, 48 kHz, stereo) into Zen's own AAC encoder.
GstFlowReturn OnPcm(GstAppSink* sink, gpointer data) {
  GstRun* run = static_cast<GstRun*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  const GstClockTime pts =
      buffer != nullptr ? GST_BUFFER_PTS(buffer) : GST_CLOCK_TIME_NONE;
  GstMapInfo map;
  if (run->pcm != nullptr && InRange(pts, run->start, run->end) &&
      gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    run->pcm->Encode(reinterpret_cast<const int16_t*>(map.data), map.size / 4,
                     static_cast<int64_t>((pts - run->start) / 1000));
    gst_buffer_unmap(buffer, &map);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

void OnPadAdded(GstElement* decodebin, GstPad* pad, gpointer data) {
  GstRun* run = static_cast<GstRun*>(data);
  GstCaps* caps = gst_pad_get_current_caps(pad);
  if (caps == nullptr) {
    caps = gst_pad_query_caps(pad, nullptr);
  }
  const char* name =
      caps != nullptr && gst_caps_get_size(caps) > 0
          ? gst_structure_get_name(gst_caps_get_structure(caps, 0))
          : "";
  std::string description = "fakesink sync=false";
  int kind = 0;  // 1: picture, 2: sound
  if (g_str_has_prefix(name, "video/x-raw") && !run->video_linked) {
    description = std::string(run->flip ? "videoflip video-direction=auto ! "
                                        : "") +
                  "videoconvert ! videoscale ! video/x-raw,format=I420,"
                  "width=" +
                  std::to_string(run->width) +
                  ",height=" + std::to_string(run->height) +
                  ",pixel-aspect-ratio=1/1 ! appsink name=sink sync=false";
    kind = 1;
  } else if (g_str_has_prefix(name, "audio/mpeg") && !run->audio_linked) {
    // AAC as it is (only MPEG-4 audio stops undecoded, see the caps).
    description =
        "aacparse ! audio/mpeg,stream-format=raw ! appsink name=sink "
        "sync=false";
    kind = 2;
  } else if (g_str_has_prefix(name, "audio/x-raw") && !run->audio_linked) {
    if (run->pcm != nullptr) {
      description =
          "audioconvert ! audioresample ! "
          "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,"
          "channels=2 ! appsink name=sink sync=false";
      kind = 3;
    } else if (run->aac != nullptr) {
      // The encoder picks its own sample format (avenc_aac takes planar
      // floats, others 16-bit integers): audioconvert follows it.
      description = std::string(
                        "audioconvert ! audioresample ! "
                        "audio/x-raw,channels=2 ! audioconvert ! ") +
                    run->aac + " bitrate=" +
                    std::to_string(run->audio_bitrate) +
                    " ! aacparse ! audio/mpeg,stream-format=raw ! "
                    "appsink name=sink sync=false";
      kind = 2;
    } else {
      run->audio_lost = true;
    }
  }
  if (caps != nullptr) {
    gst_caps_unref(caps);
  }
  GError* error = nullptr;
  GstElement* bin =
      gst_parse_bin_from_description(description.c_str(), TRUE, &error);
  if (bin == nullptr) {
    g_clear_error(&error);
    if (kind == 1) {
      run->failed = true;
    } else if (kind != 0) {
      run->audio_lost = true;
    }
    bin = gst_parse_bin_from_description("fakesink sync=false", TRUE, nullptr);
    kind = 0;
    if (bin == nullptr) {
      return;
    }
  }
  GstObject* parent = gst_element_get_parent(decodebin);
  if (parent == nullptr) {
    gst_object_unref(bin);
    return;
  }
  gst_bin_add(GST_BIN(parent), bin);
  if (kind != 0) {
    GstElement* sink = gst_bin_get_by_name(GST_BIN(bin), "sink");
    if (sink != nullptr) {
      GstAppSinkCallbacks callbacks = {};
      callbacks.new_sample =
          kind == 1 ? OnVideo : (kind == 3 ? OnPcm : OnAudio);
      gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, run, nullptr);
      gst_object_unref(sink);
    }
    if (kind == 1) {
      run->video_linked = true;
    } else {
      run->audio_linked = true;
    }
  }
  GstPad* sink_pad = gst_element_get_static_pad(bin, "sink");
  if (sink_pad != nullptr) {
    gst_pad_link(pad, sink_pad);
    gst_object_unref(sink_pad);
  }
  gst_element_sync_state_with_parent(bin);
  gst_object_unref(parent);
}

// The film decoded by GStreamer; false (with [code] "unsupported") when
// it cannot decode it, so ffmpeg may try.
bool GstCompress(const Job& job, Outcome* outcome, std::string* code,
                 std::string* error) {
  int shown_w = 0;
  int shown_h = 0;
  gint64 duration = 0;
  GstRun run;
  run.flip = HasFactory("videoflip");
  if (!GstProbe(job.input, &shown_w, &shown_h, &duration)) {
    *code = "unsupported";
    *error = "GStreamer cannot decode this film";
    return false;
  }
  const std::pair<int, int> size = ScaledSize(shown_w, shown_h, job.max_short);
  run.width = size.first;
  run.height = size.second;
  run.aac = SystemAacEncoder();
  {
    auto own = std::make_unique<zen_film::AacEncoder>();
    if (own->Open(48000, 2, job.audio_bitrate)) {
      run.pcm = std::move(own);
    }
  }
  run.audio_bitrate = job.audio_bitrate;
  run.start = static_cast<GstClockTime>(std::max<int64_t>(0, job.start_ms)) *
              GST_MSECOND;
  if (job.end_ms >= 0) {
    run.end = static_cast<GstClockTime>(job.end_ms) * GST_MSECOND;
  }
  const GstClockTime last = GST_CLOCK_TIME_IS_VALID(run.end)
                                ? run.end
                                : static_cast<GstClockTime>(duration);
  run.span = std::max(1.0, static_cast<double>(last > run.start
                                                   ? last - run.start
                                                   : 0) /
                               GST_MSECOND);
  if (!run.encoder.Open(run.width, run.height, 30, job.video_bitrate)) {
    *code = "failed";
    *error = "the H.264 encoder did not start";
    return false;
  }
  GstElement* pipeline = gst_pipeline_new("zen-compress");
  GstElement* src = gst_element_factory_make("filesrc", nullptr);
  GstElement* decode = gst_element_factory_make("decodebin", nullptr);
  if (src == nullptr || decode == nullptr) {
    if (src != nullptr) {
      gst_object_unref(src);
    }
    if (decode != nullptr) {
      gst_object_unref(decode);
    }
    gst_object_unref(pipeline);
    *code = "unsupported";
    *error = "GStreamer has no decodebin";
    return false;
  }
  g_object_set(src, "location", job.input.c_str(), nullptr);
  zen_media_allow_all_decoders(decode);
  GstCaps* stop = gst_caps_from_string(
      "video/x-raw(ANY); audio/x-raw(ANY); audio/mpeg, mpegversion=(int)4");
  g_object_set(decode, "caps", stop, nullptr);
  gst_caps_unref(stop);
  gst_bin_add_many(GST_BIN(pipeline), src, decode, nullptr);
  gst_element_link(src, decode);
  g_signal_connect(decode, "pad-added", G_CALLBACK(OnPadAdded), &run);

  bool ok = true;
  gst_element_set_state(pipeline, GST_STATE_PAUSED);
  if (!Settle(pipeline, 30)) {
    ok = false;
    *code = "unsupported";
    *error = "GStreamer cannot decode this film";
  } else if (job.start_ms > 0 || job.end_ms >= 0) {
    ok = gst_element_seek(
        pipeline, 1.0, GST_FORMAT_TIME,
        static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH |
                                  GST_SEEK_FLAG_ACCURATE),
        GST_SEEK_TYPE_SET, static_cast<gint64>(run.start),
        GST_CLOCK_TIME_IS_VALID(run.end) ? GST_SEEK_TYPE_SET
                                         : GST_SEEK_TYPE_NONE,
        GST_CLOCK_TIME_IS_VALID(run.end) ? static_cast<gint64>(run.end) : -1);
    if (ok) {
      ok = Settle(pipeline, 30);
    }
    if (!ok) {
      *code = "failed";
      *error = "the start of the film could not be found";
    }
  }
  if (ok) {
    gst_element_set_state(pipeline, GST_STATE_PLAYING);
    GstBus* bus = gst_element_get_bus(pipeline);
    while (true) {
      if (g_cancelled.load()) {
        ok = false;
        *code = "cancelled";
        *error = "cancelled";
        break;
      }
      GstMessage* message = gst_bus_timed_pop_filtered(
          bus, 200 * GST_MSECOND,
          static_cast<GstMessageType>(GST_MESSAGE_EOS | GST_MESSAGE_ERROR));
      if (message == nullptr) {
        continue;
      }
      const bool failed = GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR;
      if (failed) {
        GError* e = nullptr;
        gst_message_parse_error(message, &e, nullptr);
        *code = "failed";
        *error = e != nullptr ? e->message : "decoding failed";
        g_clear_error(&e);
        ok = false;
      }
      gst_message_unref(message);
      break;
    }
    gst_object_unref(bus);
  }
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(pipeline);
  if (!ok) {
    return false;
  }
  if (run.failed.load() || run.encoder.track().samples.empty()) {
    *code = "failed";
    *error = "no picture came out";
    return false;
  }
  // Without videoflip the picture stays as stored: the turn goes into
  // the index.
  const zen_film::AudioTrack& sound =
      run.audio.samples.empty() && run.pcm != nullptr ? run.pcm->track()
                                                      : run.audio;
  if (!zen_film::WriteMp4(job.output, run.encoder.track(), &sound,
                          run.flip ? 0 : job.rotation, error)) {
    *code = "failed";
    return false;
  }
  const bool turned = !run.flip && (job.rotation == 90 || job.rotation == 270);
  outcome->width = turned ? run.height : run.width;
  outcome->height = turned ? run.width : run.height;
  outcome->duration_ms = run.last_us / 1000;
  outcome->bytes = FileSize(job.output);
  outcome->audio = !(run.audio_lost && sound.samples.empty());
  Progress(1.0);
  return true;
}

std::vector<uint8_t> GstThumbnail(const std::string& input, int64_t at_ms,
                                  int max_side) {
  GstElement* pipeline = Launch(
      "filesrc name=src ! decodebin name=dec ! " + Flip() +
          "videoconvert ! appsink name=sink sync=false "
          "caps=video/x-raw,format=RGB",
      input);
  if (pipeline == nullptr) {
    return {};
  }
  std::vector<uint8_t> jpeg;
  gst_element_set_state(pipeline, GST_STATE_PAUSED);
  bool ok = Settle(pipeline, 20);
  if (ok && at_ms > 0) {
    ok = gst_element_seek_simple(
             pipeline, GST_FORMAT_TIME,
             static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH |
                                       GST_SEEK_FLAG_KEY_UNIT),
             at_ms * GST_MSECOND) &&
         Settle(pipeline, 20);
  }
  GstElement* sink =
      ok ? gst_bin_get_by_name(GST_BIN(pipeline), "sink") : nullptr;
  GstSample* sample =
      sink != nullptr ? gst_app_sink_pull_preroll(GST_APP_SINK(sink)) : nullptr;
  GstVideoInfo info;
  GstVideoFrame frame;
  if (sample != nullptr &&
      gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
      gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample),
                          GST_MAP_READ)) {
    const int w = GST_VIDEO_FRAME_WIDTH(&frame);
    const int h = GST_VIDEO_FRAME_HEIGHT(&frame);
    GdkPixbuf* view = gdk_pixbuf_new_from_data(
        static_cast<const guchar*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0)),
        GDK_COLORSPACE_RGB, FALSE, 8, w, h,
        GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0), nullptr, nullptr);
    const int longest = std::max(w, h);
    const double scale =
        longest > max_side ? static_cast<double>(max_side) / longest : 1.0;
    GdkPixbuf* small = gdk_pixbuf_scale_simple(
        view, std::max(1, static_cast<int>(w * scale)),
        std::max(1, static_cast<int>(h * scale)), GDK_INTERP_BILINEAR);
    gchar* buffer = nullptr;
    gsize length = 0;
    if (small != nullptr &&
        gdk_pixbuf_save_to_buffer(small, &buffer, &length, "jpeg", nullptr,
                                  "quality", "80", nullptr)) {
      jpeg.assign(reinterpret_cast<uint8_t*>(buffer),
                  reinterpret_cast<uint8_t*>(buffer) + length);
    }
    g_free(buffer);
    if (small != nullptr) {
      g_object_unref(small);
    }
    g_object_unref(view);
    gst_video_frame_unmap(&frame);
  }
  if (sample != nullptr) {
    gst_sample_unref(sample);
  }
  if (sink != nullptr) {
    gst_object_unref(sink);
  }
  gst_element_set_state(pipeline, GST_STATE_NULL);
  gst_object_unref(pipeline);
  return jpeg;
}

#endif  // ZEN_HAVE_GSTREAMER

bool CanDecode() {
#ifdef ZEN_HAVE_GSTREAMER
  if (GstReady() && HasFactory("decodebin")) {
    return true;
  }
#endif
  return HasFfmpeg();
}

// ---- "zen/video" -----------------------------------------------------------

void Compress(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  Job job;
  job.input = ArgString(args, "input");
  job.output = ArgString(args, "output");
  job.start_ms = ArgInt(args, "startMs", 0);
  job.end_ms = ArgInt(args, "endMs", -1);
  job.max_short = static_cast<int>(ArgInt(args, "maxShortSide", 720));
  job.video_bitrate = static_cast<int>(ArgInt(args, "videoBitrate", 2500000));
  job.audio_bitrate = static_cast<int>(ArgInt(args, "audioBitrate", 128000));
  job.width = static_cast<int>(ArgInt(args, "width", 0));
  job.height = static_cast<int>(ArgInt(args, "height", 0));
  job.rotation = static_cast<int>(ArgInt(args, "rotation", 0));
  if (job.input.empty() || job.output.empty()) {
    Fail(call, "failed", "input and output are needed");
    return;
  }
  if (g_busy.exchange(true)) {
    Fail(call, "failed", "a film is being compressed already");
    return;
  }
  g_cancelled = false;
#ifdef ZEN_HAVE_GSTREAMER
  const bool gst = GstReady() && HasFactory("decodebin");
#else
  const bool gst = false;
#endif
  const bool ffmpeg = HasFfmpeg();
  g_object_ref(call);
  std::thread([call, job, gst, ffmpeg]() {
    Outcome outcome;
    std::string code = "unsupported";
    std::string error = "no decoder: install GStreamer's plugins or ffmpeg";
    bool ok = false;
#ifdef ZEN_HAVE_GSTREAMER
    if (gst) {
      ok = GstCompress(job, &outcome, &code, &error);
    }
#else
    (void)gst;
#endif
    if (!ok && code == "unsupported" && ffmpeg && !g_cancelled.load()) {
      ok = FfmpegCompress(job, &outcome, &code, &error);
    }
    if (!ok) {
      unlink(job.output.c_str());
    }
    g_busy = false;
    OnMain([call, ok, outcome, code, error]() {
      if (ok) {
        FlValue* result = fl_value_new_map();
        fl_value_set_string_take(result, "durationMs",
                                 fl_value_new_int(outcome.duration_ms));
        fl_value_set_string_take(result, "width",
                                 fl_value_new_int(outcome.width));
        fl_value_set_string_take(result, "height",
                                 fl_value_new_int(outcome.height));
        fl_value_set_string_take(result, "bytes",
                                 fl_value_new_int(outcome.bytes));
        fl_value_set_string_take(result, "rotation", fl_value_new_int(0));
        fl_value_set_string_take(result, "audio",
                                 fl_value_new_bool(outcome.audio));
        Respond(call, result);
      } else {
        Fail(call, code, error);
      }
      g_object_unref(call);
    });
  }).detach();
}

void Thumbnail(FlMethodCall* call) {
  FlValue* args = fl_method_call_get_args(call);
  const std::string input = ArgString(args, "input");
  const int64_t at_ms = ArgInt(args, "atMs", 0);
  const int max_side = static_cast<int>(ArgInt(args, "maxSide", 480));
  if (input.empty()) {
    Respond(call, nullptr);
    return;
  }
#ifdef ZEN_HAVE_GSTREAMER
  const bool gst = GstReady() && HasFactory("decodebin");
#else
  const bool gst = false;
#endif
  g_object_ref(call);
  std::thread([call, input, at_ms, max_side, gst]() {
    std::vector<uint8_t> jpeg;
#ifdef ZEN_HAVE_GSTREAMER
    if (gst) {
      jpeg = GstThumbnail(input, at_ms, max_side);
    }
#else
    (void)gst;
#endif
    if (jpeg.empty() && HasFfmpeg()) {
      jpeg = FfmpegThumbnail(input, at_ms, max_side);
    }
    OnMain([call, jpeg]() {
      Respond(call, jpeg.empty() ? nullptr
                                 : fl_value_new_uint8_list(jpeg.data(),
                                                           jpeg.size()));
      g_object_unref(call);
    });
  }).detach();
}

void OnVideoCall(FlMethodChannel* channel, FlMethodCall* call, gpointer data) {
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "isAvailable") == 0) {
    Respond(call, fl_value_new_bool(CanDecode()));
  } else if (strcmp(method, "cancel") == 0) {
    g_cancelled = true;
    const int child = g_child.load();
    if (child > 0) {
      kill(child, SIGTERM);
    }
    Respond(call, nullptr);
  } else if (strcmp(method, "compress") == 0) {
    Compress(call);
  } else if (strcmp(method, "thumbnail") == 0) {
    Thumbnail(call);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}

}  // namespace

// ---- "zen/camera" ------------------------------------------------------------

#ifdef ZEN_HAVE_GSTREAMER

// The camera's picture for Flutter: the newest frame (RGBA), copied.
G_DECLARE_FINAL_TYPE(ZenCameraTexture,
                     zen_camera_texture,
                     ZEN,
                     CAMERA_TEXTURE,
                     FlPixelBufferTexture)

struct _ZenCameraTexture {
  FlPixelBufferTexture parent_instance;
  GMutex lock;
  // Written by the streaming thread.
  guint8* pending;
  gsize pending_size;
  gboolean fresh;
  // Read by Flutter after copy_pixels returns.
  guint8* shown;
  gsize shown_size;
  guint32 width;
  guint32 height;
  guint32 pending_width;
  guint32 pending_height;
  FlTextureRegistrar* registrar;
  gint redraw_queued;
};

G_DEFINE_TYPE(ZenCameraTexture,
              zen_camera_texture,
              fl_pixel_buffer_texture_get_type())

static gboolean zen_camera_texture_copy_pixels(FlPixelBufferTexture* texture,
                                               const uint8_t** out,
                                               uint32_t* width,
                                               uint32_t* height,
                                               GError** error) {
  ZenCameraTexture* self = ZEN_CAMERA_TEXTURE(texture);
  g_mutex_lock(&self->lock);
  if (self->fresh) {
    if (self->shown_size < self->pending_size) {
      self->shown =
          static_cast<guint8*>(g_realloc(self->shown, self->pending_size));
      self->shown_size = self->pending_size;
    }
    memcpy(self->shown, self->pending, self->pending_size);
    self->width = self->pending_width;
    self->height = self->pending_height;
    self->fresh = FALSE;
  }
  static const uint8_t kBlank[4] = {0, 0, 0, 0};
  if (self->shown == nullptr || self->width == 0) {
    *out = kBlank;
    *width = 1;
    *height = 1;
  } else {
    *out = self->shown;
    *width = self->width;
    *height = self->height;
  }
  g_mutex_unlock(&self->lock);
  return TRUE;
}

static void zen_camera_texture_finalize(GObject* object) {
  ZenCameraTexture* self = ZEN_CAMERA_TEXTURE(object);
  g_free(self->pending);
  g_free(self->shown);
  g_mutex_clear(&self->lock);
  G_OBJECT_CLASS(zen_camera_texture_parent_class)->finalize(object);
}

static void zen_camera_texture_class_init(ZenCameraTextureClass* klass) {
  FL_PIXEL_BUFFER_TEXTURE_CLASS(klass)->copy_pixels =
      zen_camera_texture_copy_pixels;
  G_OBJECT_CLASS(klass)->finalize = zen_camera_texture_finalize;
}

static void zen_camera_texture_init(ZenCameraTexture* self) {
  g_mutex_init(&self->lock);
}

static gboolean zen_camera_texture_redraw(gpointer data) {
  ZenCameraTexture* self = ZEN_CAMERA_TEXTURE(data);
  g_atomic_int_set(&self->redraw_queued, 0);
  if (self->registrar != nullptr) {
    fl_texture_registrar_mark_texture_frame_available(self->registrar,
                                                      FL_TEXTURE(self));
  }
  return G_SOURCE_REMOVE;
}

namespace {

// Recorded at this size and rate, then compressed like any other film.
constexpr int kCameraWidth = 1280;
constexpr int kCameraHeight = 720;
constexpr int kCameraBitrate = 6000000;

struct Camera {
  GstElement* pipeline = nullptr;
  ZenCameraTexture* texture = nullptr;
  std::mutex lock;
  std::unique_ptr<zen_film::H264Encoder> encoder;
  zen_film::AudioTrack audio;
  // The microphone through Zen's own AAC encoder (raw sound in), or a
  // system GStreamer encoder (AAC in [audio]).
  bool own_aac = false;
  std::unique_ptr<zen_film::AacEncoder> aac;
  bool recording = false;
  GstClockTime base = GST_CLOCK_TIME_NONE;
};

Camera* g_camera = nullptr;

GstFlowReturn OnPreview(GstAppSink* sink, gpointer data) {
  ZenCameraTexture* texture = static_cast<ZenCameraTexture*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  GstVideoInfo info;
  GstVideoFrame frame;
  if (gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
      gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample),
                          GST_MAP_READ)) {
    const guint32 w = static_cast<guint32>(GST_VIDEO_FRAME_WIDTH(&frame));
    const guint32 h = static_cast<guint32>(GST_VIDEO_FRAME_HEIGHT(&frame));
    const gsize row = static_cast<gsize>(w) * 4;
    const gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
    const guint8* src =
        static_cast<const guint8*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0));
    g_mutex_lock(&texture->lock);
    const gsize size = row * h;
    if (texture->pending_size < size) {
      texture->pending =
          static_cast<guint8*>(g_realloc(texture->pending, size));
      texture->pending_size = size;
    }
    for (guint32 y = 0; y < h; y++) {
      memcpy(texture->pending + y * row, src + y * stride, row);
    }
    texture->pending_width = w;
    texture->pending_height = h;
    texture->fresh = TRUE;
    g_mutex_unlock(&texture->lock);
    gst_video_frame_unmap(&frame);
    if (g_atomic_int_compare_and_exchange(&texture->redraw_queued, 0, 1)) {
      g_idle_add_full(G_PRIORITY_DEFAULT, zen_camera_texture_redraw,
                      g_object_ref(texture), g_object_unref);
    }
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

GstFlowReturn OnFrames(GstAppSink* sink, gpointer data) {
  Camera* camera = static_cast<Camera*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  std::lock_guard<std::mutex> hold(camera->lock);
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstVideoInfo info;
  GstVideoFrame frame;
  if (camera->recording && camera->encoder != nullptr && buffer != nullptr &&
      GST_BUFFER_PTS_IS_VALID(buffer) &&
      gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
      gst_video_frame_map(&frame, &info, buffer, GST_MAP_READ)) {
    const GstClockTime pts = GST_BUFFER_PTS(buffer);
    if (!GST_CLOCK_TIME_IS_VALID(camera->base)) {
      camera->base = pts;
    }
    if (pts >= camera->base) {
      camera->encoder->Encode(
          static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 0)),
          GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0),
          static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 1)),
          GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 1),
          static_cast<const uint8_t*>(GST_VIDEO_FRAME_PLANE_DATA(&frame, 2)),
          GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 2),
          static_cast<int64_t>((pts - camera->base) / 1000));
    }
    gst_video_frame_unmap(&frame);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

GstFlowReturn OnMicrophone(GstAppSink* sink, gpointer data) {
  Camera* camera = static_cast<Camera*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  std::lock_guard<std::mutex> hold(camera->lock);
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  if (camera->recording && buffer != nullptr &&
      GST_BUFFER_PTS_IS_VALID(buffer) &&
      GST_CLOCK_TIME_IS_VALID(camera->base) &&
      GST_BUFFER_PTS(buffer) >= camera->base) {
    if (camera->audio.config.empty()) {
      GstCaps* caps = gst_sample_get_caps(sample);
      GstStructure* s =
          caps != nullptr ? gst_caps_get_structure(caps, 0) : nullptr;
      const GValue* codec =
          s != nullptr ? gst_structure_get_value(s, "codec_data") : nullptr;
      gint rate = 0;
      gint channels = 0;
      if (codec != nullptr && G_VALUE_HOLDS(codec, GST_TYPE_BUFFER) &&
          gst_structure_get_int(s, "rate", &rate) &&
          gst_structure_get_int(s, "channels", &channels)) {
        GstBuffer* config = gst_value_get_buffer(codec);
        GstMapInfo map;
        if (gst_buffer_map(config, &map, GST_MAP_READ)) {
          camera->audio.config.assign(map.data, map.data + map.size);
          gst_buffer_unmap(config, &map);
        }
        camera->audio.sample_rate = rate;
        camera->audio.channels = channels;
      }
    }
    GstMapInfo map;
    if (!camera->audio.config.empty() &&
        gst_buffer_map(buffer, &map, GST_MAP_READ)) {
      zen_film::Sample s;
      s.data.assign(map.data, map.data + map.size);
      s.pts_us =
          static_cast<int64_t>((GST_BUFFER_PTS(buffer) - camera->base) / 1000);
      s.key = true;
      camera->audio.samples.push_back(std::move(s));
      gst_buffer_unmap(buffer, &map);
    }
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

// The microphone's raw sound into Zen's own AAC encoder while recording.
GstFlowReturn OnMicrophonePcm(GstAppSink* sink, gpointer data) {
  Camera* camera = static_cast<Camera*>(data);
  GstSample* sample = gst_app_sink_pull_sample(sink);
  if (sample == nullptr) {
    return GST_FLOW_OK;
  }
  std::lock_guard<std::mutex> hold(camera->lock);
  GstBuffer* buffer = gst_sample_get_buffer(sample);
  GstMapInfo map;
  if (camera->recording && camera->aac != nullptr && buffer != nullptr &&
      GST_BUFFER_PTS_IS_VALID(buffer) &&
      GST_CLOCK_TIME_IS_VALID(camera->base) &&
      GST_BUFFER_PTS(buffer) >= camera->base &&
      gst_buffer_map(buffer, &map, GST_MAP_READ)) {
    camera->aac->Encode(
        reinterpret_cast<const int16_t*>(map.data), map.size / 4,
        static_cast<int64_t>((GST_BUFFER_PTS(buffer) - camera->base) / 1000));
    gst_buffer_unmap(buffer, &map);
  }
  gst_sample_unref(sample);
  return GST_FLOW_OK;
}

// The cameras GStreamer finds (v4l2, libcamera, PipeWire).
GList* CameraDevices() {
  GstDeviceMonitor* monitor = gst_device_monitor_new();
  gst_device_monitor_add_filter(monitor, "Video/Source", nullptr);
  GList* devices = gst_device_monitor_get_devices(monitor);
  gst_object_unref(monitor);
  return devices;
}

void CloseCamera() {
  Camera* camera = g_camera;
  g_camera = nullptr;
  if (camera == nullptr) {
    return;
  }
  if (camera->pipeline != nullptr) {
    gst_element_set_state(camera->pipeline, GST_STATE_NULL);
    gst_object_unref(camera->pipeline);
  }
  if (camera->texture != nullptr) {
    if (g_plugin != nullptr) {
      fl_texture_registrar_unregister_texture(g_plugin->textures,
                                              FL_TEXTURE(camera->texture));
    }
    camera->texture->registrar = nullptr;
    g_object_unref(camera->texture);
  }
  delete camera;
}

void SetCallbacks(GstElement* bin, const char* name,
                  GstFlowReturn (*on_sample)(GstAppSink*, gpointer),
                  gpointer data) {
  GstElement* sink = gst_bin_get_by_name(GST_BIN(bin), name);
  if (sink == nullptr) {
    return;
  }
  GstAppSinkCallbacks callbacks = {};
  callbacks.new_sample = on_sample;
  gst_app_sink_set_callbacks(GST_APP_SINK(sink), &callbacks, data, nullptr);
  gst_object_unref(sink);
}

void OpenCamera(FlMethodCall* call) {
  CloseCamera();
  const std::string lens =
      ArgString(fl_method_call_get_args(call), "lens");
  if (!GstReady()) {
    Fail(call, "failed", "GStreamer did not start");
    return;
  }
  GList* devices = CameraDevices();
  const guint count = g_list_length(devices);
  GstDevice* device = nullptr;
  if (count > 0) {
    device = GST_DEVICE(
        g_list_nth_data(devices, lens == "back" && count > 1 ? 1 : 0));
  }
  GstElement* source =
      device != nullptr ? gst_device_create_element(device, "camera") : nullptr;
  g_list_free_full(devices, gst_object_unref);
  if (source == nullptr) {
    Fail(call, "failed", "no camera");
    return;
  }
  const std::string video =
      "videoconvert ! videoscale ! video/x-raw,format=I420,width=" +
      std::to_string(kCameraWidth) + ",height=" +
      std::to_string(kCameraHeight) +
      ",pixel-aspect-ratio=1/1 ! tee name=t "
      "t. ! queue leaky=downstream max-size-buffers=2 ! videoconvert ! "
      "video/x-raw,format=RGBA ! appsink name=preview sync=false drop=true "
      "max-buffers=1 "
      "t. ! queue max-size-buffers=120 max-size-time=0 max-size-bytes=0 ! "
      "appsink name=frames sync=false";
  GError* error = nullptr;
  GstElement* video_bin =
      gst_parse_bin_from_description(video.c_str(), TRUE, &error);
  if (video_bin == nullptr) {
    g_clear_error(&error);
    gst_object_unref(source);
    Fail(call, "failed", "the camera's GStreamer plugins are missing");
    return;
  }
  auto* camera = new Camera();
  g_camera = camera;
  camera->pipeline = gst_pipeline_new("zen-camera");
  gst_bin_add_many(GST_BIN(camera->pipeline), source, video_bin, nullptr);
  gst_element_link(source, video_bin);
  camera->texture = ZEN_CAMERA_TEXTURE(
      g_object_new(zen_camera_texture_get_type(), nullptr));
  camera->texture->registrar = g_plugin->textures;
  fl_texture_registrar_register_texture(g_plugin->textures,
                                        FL_TEXTURE(camera->texture));
  SetCallbacks(video_bin, "preview", OnPreview, camera->texture);
  SetCallbacks(video_bin, "frames", OnFrames, camera);
  // The microphone: Zen's own AAC encoder, else a system one.
  const char* aac = SystemAacEncoder();
  camera->own_aac = zen_film::AacEncoder().Open(48000, 2, 128000);
  if (camera->own_aac && HasFactory("autoaudiosrc")) {
    GstElement* sound_bin = gst_parse_bin_from_description(
        "autoaudiosrc ! queue ! audioconvert ! audioresample ! "
        "audio/x-raw,format=S16LE,layout=interleaved,rate=48000,channels=2 ! "
        "appsink name=mic sync=false",
        FALSE, nullptr);
    if (sound_bin != nullptr) {
      gst_bin_add(GST_BIN(camera->pipeline), sound_bin);
      SetCallbacks(sound_bin, "mic", OnMicrophonePcm, camera);
    }
  } else if (aac != nullptr && HasFactory("autoaudiosrc")) {
    const std::string sound =
        std::string(
            "autoaudiosrc ! queue ! audioconvert ! audioresample ! "
            "audio/x-raw,rate=48000,channels=2 ! audioconvert ! ") +
        aac +
        " bitrate=128000 ! aacparse ! audio/mpeg,stream-format=raw ! "
        "appsink name=mic sync=false";
    GstElement* sound_bin =
        gst_parse_bin_from_description(sound.c_str(), FALSE, nullptr);
    if (sound_bin != nullptr) {
      gst_bin_add(GST_BIN(camera->pipeline), sound_bin);
      SetCallbacks(sound_bin, "mic", OnMicrophone, camera);
    }
  }
  gst_element_set_state(camera->pipeline, GST_STATE_PLAYING);
  if (!Settle(camera->pipeline, 10)) {
    CloseCamera();
    Fail(call, "failed", "the camera did not start");
    return;
  }
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(
      result, "textureId",
      fl_value_new_int(fl_texture_get_id(FL_TEXTURE(camera->texture))));
  fl_value_set_string_take(result, "width", fl_value_new_int(kCameraWidth));
  fl_value_set_string_take(result, "height", fl_value_new_int(kCameraHeight));
  Respond(call, result);
}

// The newest preview picture in shades of grey, at most 640 pixels wide
// (a QR scanner reads it): {width, height, bytes}, or null.
FlValue* Luma(ZenCameraTexture* texture) {
  if (texture == nullptr) {
    return nullptr;
  }
  g_mutex_lock(&texture->lock);
  const guint32 width = texture->pending_width;
  const guint32 height = texture->pending_height;
  if (texture->pending == nullptr || width == 0 || height == 0) {
    g_mutex_unlock(&texture->lock);
    return nullptr;
  }
  const guint32 step = std::max<guint32>(1, (width + 639) / 640);
  const guint32 out_w = width / step;
  const guint32 out_h = height / step;
  std::vector<uint8_t> gray(static_cast<size_t>(out_w) * out_h);
  const gsize row = static_cast<gsize>(width) * 4;
  for (guint32 y = 0; y < out_h; y++) {
    const guint8* line = texture->pending + (y * step) * row;
    for (guint32 x = 0; x < out_w; x++) {
      const guint8* p = line + (x * step) * 4;  // RGBA
      gray[static_cast<size_t>(y) * out_w + x] =
          static_cast<uint8_t>((p[0] * 77 + p[1] * 150 + p[2] * 29) >> 8);
    }
  }
  g_mutex_unlock(&texture->lock);
  FlValue* result = fl_value_new_map();
  fl_value_set_string_take(result, "width", fl_value_new_int(out_w));
  fl_value_set_string_take(result, "height", fl_value_new_int(out_h));
  fl_value_set_string_take(result, "bytes",
                           fl_value_new_uint8_list(gray.data(), gray.size()));
  return result;
}

void OnCameraCall(FlMethodChannel* channel, FlMethodCall* call,
                  gpointer data) {
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "lenses") == 0) {
    FlValue* names = fl_value_new_list();
    if (GstReady()) {
      GList* devices = CameraDevices();
      const guint count = g_list_length(devices);
      g_list_free_full(devices, gst_object_unref);
      if (count > 0) {
        fl_value_append_take(names, fl_value_new_string("front"));
      }
      if (count > 1) {
        fl_value_append_take(names, fl_value_new_string("back"));
      }
    }
    Respond(call, names);
  } else if (strcmp(method, "open") == 0) {
    OpenCamera(call);
  } else if (strcmp(method, "setTorch") == 0) {
    Respond(call, nullptr);
  } else if (strcmp(method, "start") == 0) {
    Camera* camera = g_camera;
    if (camera == nullptr) {
      Fail(call, "failed", "camera closed");
      return;
    }
    auto encoder = std::make_unique<zen_film::H264Encoder>();
    if (!encoder->Open(kCameraWidth, kCameraHeight, 30, kCameraBitrate)) {
      Fail(call, "failed", "the H.264 encoder did not start");
      return;
    }
    std::unique_ptr<zen_film::AacEncoder> aac;
    if (camera->own_aac) {
      aac = std::make_unique<zen_film::AacEncoder>();
      if (!aac->Open(48000, 2, 128000)) {
        aac.reset();
      }
    }
    std::lock_guard<std::mutex> hold(camera->lock);
    camera->encoder = std::move(encoder);
    camera->aac = std::move(aac);
    camera->audio = zen_film::AudioTrack();
    camera->base = GST_CLOCK_TIME_NONE;
    camera->recording = true;
    Respond(call, nullptr);
  } else if (strcmp(method, "stop") == 0) {
    Camera* camera = g_camera;
    if (camera == nullptr) {
      Fail(call, "failed", "camera closed");
      return;
    }
    std::unique_ptr<zen_film::H264Encoder> encoder;
    zen_film::AudioTrack audio;
    {
      std::lock_guard<std::mutex> hold(camera->lock);
      camera->recording = false;
      encoder = std::move(camera->encoder);
      audio = camera->aac != nullptr ? std::move(camera->aac->track())
                                     : std::move(camera->audio);
      camera->aac.reset();
      camera->audio = zen_film::AudioTrack();
    }
    gchar* name = g_strdup_printf("zen-film-%08x%08x.mp4", g_random_int(),
                                  g_random_int());
    gchar* path = g_build_filename(g_get_tmp_dir(), name, nullptr);
    std::string error;
    const bool ok = encoder != nullptr &&
                    zen_film::WriteMp4(path, encoder->track(), &audio, 0,
                                       &error);
    if (ok) {
      Respond(call, fl_value_new_string(path));
    } else {
      Fail(call, "failed", error.empty() ? "nothing recorded" : error);
    }
    g_free(path);
    g_free(name);
  } else if (strcmp(method, "close") == 0) {
    CloseCamera();
    Respond(call, nullptr);
  } else if (strcmp(method, "luma") == 0) {
    Respond(call, g_camera != nullptr ? Luma(g_camera->texture) : nullptr);
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}

}  // namespace

#else  // ZEN_HAVE_GSTREAMER

namespace {

void OnCameraCall(FlMethodChannel* channel, FlMethodCall* call,
                  gpointer data) {
  // Built without GStreamer: no camera, films come from files.
  if (strcmp(fl_method_call_get_name(call), "lenses") == 0) {
    Respond(call, fl_value_new_list());
  } else {
    Fail(call, "unsupported", "built without GStreamer");
  }
}

}  // namespace

#endif  // ZEN_HAVE_GSTREAMER

void zen_video_bridge_register(FlPluginRegistry* registry) {
  if (g_plugin != nullptr) {
    return;
  }
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ZenVideoBridge");
  g_plugin = new Plugin();
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_plugin->textures = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_plugin->video =
      fl_method_channel_new(messenger, kVideoChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_plugin->video, OnVideoCall,
                                            nullptr, nullptr);
  g_plugin->camera =
      fl_method_channel_new(messenger, kCameraChannel, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_plugin->camera, OnCameraCall,
                                            nullptr, nullptr);
}
