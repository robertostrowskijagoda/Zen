#include "zen_call_recorder.h"

#include <cstring>
#include <string>

#ifdef ZEN_HAVE_PULSE

#include <dlfcn.h>
#include <pulse/pulseaudio.h>
#include <sys/time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <map>
#include <memory>
#include <thread>
#include <vector>

#include "zen_call_mixer.h"

#endif  // ZEN_HAVE_PULSE

// Threads: method calls run on the GTK main thread; PulseAudio's callbacks
// on its own (threaded mainloop) thread, which the main thread enters only
// with the mainloop's lock; the file is written on a writer thread that
// takes the mix every 10 ms.

namespace {

constexpr char kChannelName[] = "zen/recorder";

#ifdef ZEN_HAVE_PULSE

constexpr int kRate = 48000;
constexpr int kChannels = 2;
constexpr int kBits = 16;
// The mix stays this far behind the clock; no source keeps more than
// kMaxBuffered seconds waiting (see zen_call_mixer.h).
constexpr double kLatency = 0.2;
constexpr double kMaxBuffered = 0.5;

// What Zen calls in libpulse; resolved with dlsym, never linked.
#define ZEN_PULSE_FUNCTIONS(X)       \
  X(pa_threaded_mainloop_new)        \
  X(pa_threaded_mainloop_free)       \
  X(pa_threaded_mainloop_start)      \
  X(pa_threaded_mainloop_stop)       \
  X(pa_threaded_mainloop_lock)       \
  X(pa_threaded_mainloop_unlock)     \
  X(pa_threaded_mainloop_wait)       \
  X(pa_threaded_mainloop_signal)     \
  X(pa_threaded_mainloop_get_api)    \
  X(pa_context_new)                  \
  X(pa_context_unref)                \
  X(pa_context_connect)              \
  X(pa_context_disconnect)           \
  X(pa_context_get_state)            \
  X(pa_context_set_state_callback)   \
  X(pa_context_set_subscribe_callback) \
  X(pa_context_subscribe)            \
  X(pa_context_get_sink_input_info)  \
  X(pa_context_get_sink_input_info_list) \
  X(pa_context_get_sink_info_by_index) \
  X(pa_context_get_client_info)      \
  X(pa_operation_unref)              \
  X(pa_stream_new)                   \
  X(pa_stream_unref)                 \
  X(pa_stream_set_monitor_stream)    \
  X(pa_stream_connect_record)        \
  X(pa_stream_disconnect)            \
  X(pa_stream_set_read_callback)     \
  X(pa_stream_peek)                  \
  X(pa_stream_drop)                  \
  X(pa_proplist_gets)

struct Pulse {
#define ZEN_PULSE_POINTER(name) decltype(&::name) name = nullptr;
  ZEN_PULSE_FUNCTIONS(ZEN_PULSE_POINTER)
#undef ZEN_PULSE_POINTER
};

// libpulse, loaded once; nullptr where it is not installed.
const Pulse* LoadPulse() {
  static const Pulse* pulse = []() -> const Pulse* {
    void* library = dlopen("libpulse.so.0", RTLD_NOW | RTLD_LOCAL);
    if (library == nullptr) {
      return nullptr;
    }
    Pulse* p = new Pulse();
    bool ok = true;
#define ZEN_PULSE_LOAD(name)                                            \
  p->name = reinterpret_cast<decltype(&::name)>(dlsym(library, #name)); \
  ok = ok && p->name != nullptr;
    ZEN_PULSE_FUNCTIONS(ZEN_PULSE_LOAD)
#undef ZEN_PULSE_LOAD
    if (!ok) {
      delete p;
      dlclose(library);
      return nullptr;
    }
    return p;
  }();
  return pulse;
}

void WriteU32(FILE* f, uint32_t v) {
  const unsigned char b[4] = {
      static_cast<unsigned char>(v), static_cast<unsigned char>(v >> 8),
      static_cast<unsigned char>(v >> 16), static_cast<unsigned char>(v >> 24)};
  fwrite(b, 1, 4, f);
}

void WriteU16(FILE* f, uint16_t v) {
  const unsigned char b[2] = {static_cast<unsigned char>(v),
                              static_cast<unsigned char>(v >> 8)};
  fwrite(b, 1, 2, f);
}

void WriteWavHeader(FILE* f, uint32_t data_bytes) {
  fwrite("RIFF", 1, 4, f);
  WriteU32(f, 36 + data_bytes);
  fwrite("WAVE", 1, 4, f);
  fwrite("fmt ", 1, 4, f);
  WriteU32(f, 16);
  WriteU16(f, 1);  // PCM
  WriteU16(f, kChannels);
  WriteU32(f, kRate);
  WriteU32(f, kRate * kChannels * kBits / 8);
  WriteU16(f, kChannels * kBits / 8);
  WriteU16(f, kBits);
  fwrite("data", 1, 4, f);
  WriteU32(f, data_bytes);
}

class Recorder;

// One stream being recorded: a playback stream of this app (through its
// monitor) or the microphone (sink_input is PA_INVALID_INDEX).
struct Capture {
  Recorder* recorder;
  uint32_t sink_input;
  uint32_t sink;
  int source;  // in the mixer
  pa_stream* stream;
};

// A question to the server about a playback stream, in flight.
struct Lookup {
  Recorder* recorder;
  uint32_t sink_input;
  uint32_t sink;
};

class Recorder {
 public:
  static bool Available() { return LoadPulse() != nullptr; }

  // Starts recording to |path|; false with |code| ("unavailable",
  // "start_failed") and |error| set when it cannot.
  bool Start(const std::string& path, std::string* code, std::string* error) {
    *code = "start_failed";
    if (running_) {
      *error = "already recording";
      return false;
    }
    pa_ = LoadPulse();
    if (pa_ == nullptr) {
      *code = "unavailable";
      *error = "libpulse (PulseAudio or PipeWire) is not installed";
      return false;
    }
    file_ = fopen(path.c_str(), "wb");
    if (file_ == nullptr) {
      *error = "cannot create the file";
      return false;
    }
    WriteWavHeader(file_, 0);
    mixer_.reset(new ZenCallMixer(kRate, kChannels, kLatency, kMaxBuffered));
    begin_ = std::chrono::steady_clock::now();
    if (!Connect(error)) {
      Disconnect();
      fclose(file_);
      file_ = nullptr;
      remove(path.c_str());
      mixer_.reset();
      return false;
    }
    path_ = path;
    stop_ = false;
    writer_ = std::thread([this]() { Write(); });
    running_ = true;
    return true;
  }

  // Stops and finishes the file; returns its path ("" when nothing ran).
  std::string Stop() {
    if (!running_) {
      return std::string();
    }
    running_ = false;
    stop_ = true;
    if (writer_.joinable()) {
      writer_.join();
    }
    Disconnect();
    std::vector<int16_t> rest;
    mixer_->Pull(Seconds(), true, &rest);
    if (!rest.empty()) {
      fwrite(rest.data(), sizeof(int16_t), rest.size(), file_);
    }
    const uint64_t bytes = mixer_->written() * sizeof(int16_t);
    fseek(file_, 0, SEEK_SET);
    WriteWavHeader(file_, static_cast<uint32_t>(
                              std::min<uint64_t>(bytes, 0xFFFFFFF0ull)));
    fclose(file_);
    file_ = nullptr;
    mixer_.reset();
    return path_;
  }

  ~Recorder() { Stop(); }

 private:
  double Seconds() const {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() -
                                         begin_)
        .count();
  }

  // On the writer thread: the mix, at the pace of the clock.
  void Write() {
    std::vector<int16_t> chunk;
    while (!stop_.load()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(10));
      chunk.clear();
      mixer_->Pull(Seconds(), false, &chunk);
      if (!chunk.empty()) {
        fwrite(chunk.data(), sizeof(int16_t), chunk.size(), file_);
      }
    }
  }

  // Connects to the sound server and starts following this app's playback
  // streams and the microphone. The mainloop's lock is taken here.
  bool Connect(std::string* error) {
    const Pulse& pa = *pa_;
    mainloop_ = pa.pa_threaded_mainloop_new();
    if (mainloop_ == nullptr) {
      *error = "cannot start the sound thread";
      return false;
    }
    pa_mainloop_api* api = pa.pa_threaded_mainloop_get_api(mainloop_);
    context_ = pa.pa_context_new(api, "Zen");
    if (context_ == nullptr) {
      *error = "cannot talk to the sound server";
      return false;
    }
    pa.pa_context_set_state_callback(context_, OnContextState, this);
    if (pa.pa_threaded_mainloop_start(mainloop_) < 0) {
      *error = "cannot start the sound thread";
      return false;
    }
    pa.pa_threaded_mainloop_lock(mainloop_);
    bool ready = false;
    if (pa.pa_context_connect(context_, nullptr, PA_CONTEXT_NOAUTOSPAWN,
                              nullptr) >= 0) {
      // Never wait for a server that does not answer for more than 5 s.
      timeval when;
      gettimeofday(&when, nullptr);
      when.tv_sec += 5;
      timed_out_ = false;
      pa_time_event* timer = api->time_new(api, &when, OnTimeout, this);
      while (true) {
        const pa_context_state_t state = pa.pa_context_get_state(context_);
        if (state == PA_CONTEXT_READY) {
          ready = true;
          break;
        }
        if (!PA_CONTEXT_IS_GOOD(state) || timed_out_) {
          break;
        }
        pa.pa_threaded_mainloop_wait(mainloop_);
      }
      if (timer != nullptr) {
        api->time_free(timer);
      }
    }
    if (ready) {
      // Playback streams that start, move or end during the call.
      pa.pa_context_set_subscribe_callback(context_, OnEvent, this);
      Done(pa.pa_context_subscribe(context_, PA_SUBSCRIPTION_MASK_SINK_INPUT,
                                   nullptr, nullptr));
      // And the ones already playing.
      Done(pa.pa_context_get_sink_input_info_list(context_, OnSinkInput,
                                                  this));
      microphone_ = Open(PA_INVALID_INDEX, PA_INVALID_INDEX, nullptr);
    }
    pa.pa_threaded_mainloop_unlock(mainloop_);
    if (!ready) {
      *error = "no PulseAudio or PipeWire sound server";
    }
    return ready;
  }

  // Stops every stream and closes the connection (no more sound arrives).
  void Disconnect() {
    const Pulse& pa = *pa_;
    if (mainloop_ != nullptr) {
      pa.pa_threaded_mainloop_lock(mainloop_);
      for (auto& capture : captures_) {
        Close(capture.second.get());
      }
      captures_.clear();
      if (microphone_) {
        Close(microphone_.get());
        microphone_.reset();
      }
      if (context_ != nullptr) {
        pa.pa_context_set_subscribe_callback(context_, nullptr, nullptr);
        pa.pa_context_set_state_callback(context_, nullptr, nullptr);
        pa.pa_context_disconnect(context_);
      }
      pa.pa_threaded_mainloop_unlock(mainloop_);
      pa.pa_threaded_mainloop_stop(mainloop_);
    }
    if (context_ != nullptr) {
      pa.pa_context_unref(context_);
      context_ = nullptr;
    }
    if (mainloop_ != nullptr) {
      pa.pa_threaded_mainloop_free(mainloop_);
      mainloop_ = nullptr;
    }
    // Questions the server never answered (cancelled with the connection).
    lookups_.clear();
  }

  void Done(pa_operation* operation) {
    if (operation != nullptr) {
      pa_->pa_operation_unref(operation);
    }
  }

  // A record stream at 48 kHz stereo: the monitor of |sink_input| on
  // |device| (the monitor source of its sink), or the default microphone.
  std::unique_ptr<Capture> Open(uint32_t sink_input, uint32_t sink,
                                const char* device) {
    const Pulse& pa = *pa_;
    pa_sample_spec spec;
    spec.format = PA_SAMPLE_S16LE;
    spec.rate = kRate;
    spec.channels = kChannels;
    const bool monitor = sink_input != PA_INVALID_INDEX;
    pa_stream* stream = pa.pa_stream_new(
        context_, monitor ? "Zen call recording" : "Zen call recording (mic)",
        &spec, nullptr);
    if (stream == nullptr) {
      return nullptr;
    }
    if (monitor && pa.pa_stream_set_monitor_stream(stream, sink_input) < 0) {
      pa.pa_stream_unref(stream);
      return nullptr;
    }
    std::unique_ptr<Capture> capture(new Capture{
        this, sink_input, sink, mixer_->AddSource(), stream});
    pa.pa_stream_set_read_callback(stream, OnRead, capture.get());
    pa_buffer_attr attr;
    attr.maxlength = static_cast<uint32_t>(-1);
    attr.tlength = static_cast<uint32_t>(-1);
    attr.prebuf = static_cast<uint32_t>(-1);
    attr.minreq = static_cast<uint32_t>(-1);
    attr.fragsize = kRate * kChannels * sizeof(int16_t) / 50;  // 20 ms
    const pa_stream_flags_t flags = static_cast<pa_stream_flags_t>(
        PA_STREAM_ADJUST_LATENCY |
        (monitor ? static_cast<int>(PA_STREAM_DONT_MOVE) : 0));
    if (pa.pa_stream_connect_record(stream, device, &attr, flags) < 0) {
      Close(capture.get());
      return nullptr;
    }
    return capture;
  }

  void Close(Capture* capture) {
    const Pulse& pa = *pa_;
    pa.pa_stream_set_read_callback(capture->stream, nullptr, nullptr);
    pa.pa_stream_disconnect(capture->stream);
    pa.pa_stream_unref(capture->stream);
    capture->stream = nullptr;
    mixer_->Finish(capture->source);
  }

  bool IsThisProcess(const pa_proplist* properties, bool* known) const {
    const char* pid =
        pa_->pa_proplist_gets(properties, PA_PROP_APPLICATION_PROCESS_ID);
    *known = pid != nullptr;
    return pid != nullptr && std::to_string(getpid()) == pid;
  }

  // ---- in PulseAudio's thread (or with its lock) --------------------------

  // A playback stream appeared or changed: is it this app's?
  void Consider(const pa_sink_input_info* info) {
    bool known = false;
    if (IsThisProcess(info->proplist, &known)) {
      Follow(info->index, info->sink);
      return;
    }
    if (!known && info->client != PA_INVALID_INDEX) {
      // The stream does not say; its client does.
      Done(pa_->pa_context_get_client_info(
          context_, info->client, OnClient, Ask(info->index, info->sink)));
    }
  }

  // Records this app's stream |sink_input| playing on |sink|.
  void Follow(uint32_t sink_input, uint32_t sink) {
    auto it = captures_.find(sink_input);
    if (it != captures_.end()) {
      if (it->second->sink == sink) {
        return;
      }
      // Moved to other speakers: its monitor is there now.
      Close(it->second.get());
      captures_.erase(it);
    }
    Done(pa_->pa_context_get_sink_info_by_index(context_, sink, OnSink,
                                                Ask(sink_input, sink)));
  }

  void Forget(uint32_t sink_input) {
    auto it = captures_.find(sink_input);
    if (it == captures_.end()) {
      return;
    }
    Close(it->second.get());
    captures_.erase(it);
  }

  void Monitor(uint32_t sink_input, uint32_t sink, uint32_t monitor_source) {
    auto it = captures_.find(sink_input);
    if (it != captures_.end() && it->second->sink == sink) {
      return;
    }
    char device[16];
    snprintf(device, sizeof(device), "%u", monitor_source);
    std::unique_ptr<Capture> capture = Open(sink_input, sink, device);
    if (capture) {
      if (it != captures_.end()) {
        Close(it->second.get());
      }
      captures_[sink_input] = std::move(capture);
    }
  }

  Lookup* Ask(uint32_t sink_input, uint32_t sink) {
    std::unique_ptr<Lookup> lookup(new Lookup{this, sink_input, sink});
    Lookup* raw = lookup.get();
    lookups_[raw] = std::move(lookup);
    return raw;
  }

  void Answered(Lookup* lookup) { lookups_.erase(lookup); }

  static void OnContextState(pa_context*, void* data) {
    auto* self = static_cast<Recorder*>(data);
    self->pa_->pa_threaded_mainloop_signal(self->mainloop_, 0);
  }

  static void OnTimeout(pa_mainloop_api*, pa_time_event*, const timeval*,
                        void* data) {
    auto* self = static_cast<Recorder*>(data);
    self->timed_out_ = true;
    self->pa_->pa_threaded_mainloop_signal(self->mainloop_, 0);
  }

  static void OnEvent(pa_context*, pa_subscription_event_type_t type,
                      uint32_t index, void* data) {
    auto* self = static_cast<Recorder*>(data);
    if ((type & PA_SUBSCRIPTION_EVENT_FACILITY_MASK) !=
        PA_SUBSCRIPTION_EVENT_SINK_INPUT) {
      return;
    }
    if ((type & PA_SUBSCRIPTION_EVENT_TYPE_MASK) ==
        PA_SUBSCRIPTION_EVENT_REMOVE) {
      self->Forget(index);
      return;
    }
    self->Done(self->pa_->pa_context_get_sink_input_info(
        self->context_, index, OnSinkInput, self));
  }

  static void OnSinkInput(pa_context*, const pa_sink_input_info* info,
                          int eol, void* data) {
    if (eol != 0 || info == nullptr) {
      return;
    }
    static_cast<Recorder*>(data)->Consider(info);
  }

  static void OnClient(pa_context*, const pa_client_info* info, int eol,
                       void* data) {
    auto* lookup = static_cast<Lookup*>(data);
    Recorder* self = lookup->recorder;
    if (eol != 0) {
      self->Answered(lookup);
      return;
    }
    bool known = false;
    if (info != nullptr && self->IsThisProcess(info->proplist, &known)) {
      self->Follow(lookup->sink_input, lookup->sink);
    }
  }

  static void OnSink(pa_context*, const pa_sink_info* info, int eol,
                     void* data) {
    auto* lookup = static_cast<Lookup*>(data);
    Recorder* self = lookup->recorder;
    if (eol != 0) {
      self->Answered(lookup);
      return;
    }
    if (info != nullptr) {
      self->Monitor(lookup->sink_input, lookup->sink, info->monitor_source);
    }
  }

  static void OnRead(pa_stream* stream, size_t, void* data) {
    auto* capture = static_cast<Capture*>(data);
    const Pulse& pa = *capture->recorder->pa_;
    while (true) {
      const void* bytes = nullptr;
      size_t size = 0;
      if (pa.pa_stream_peek(stream, &bytes, &size) < 0 || size == 0) {
        return;
      }
      // No bytes: a hole in the stream, which the clock fills with silence.
      if (bytes != nullptr) {
        capture->recorder->mixer_->Push(capture->source,
                                        static_cast<const int16_t*>(bytes),
                                        size / sizeof(int16_t));
      }
      pa.pa_stream_drop(stream);
    }
  }

  const Pulse* pa_ = nullptr;
  pa_threaded_mainloop* mainloop_ = nullptr;
  pa_context* context_ = nullptr;
  bool timed_out_ = false;
  std::map<uint32_t, std::unique_ptr<Capture>> captures_;
  std::unique_ptr<Capture> microphone_;
  std::map<Lookup*, std::unique_ptr<Lookup>> lookups_;
  std::unique_ptr<ZenCallMixer> mixer_;
  FILE* file_ = nullptr;
  std::string path_;
  std::chrono::steady_clock::time_point begin_;
  std::thread writer_;
  std::atomic<bool> stop_{false};
  bool running_ = false;
};

Recorder* g_recorder = nullptr;

bool Available() { return Recorder::Available(); }

#else  // ZEN_HAVE_PULSE

// Built without PulseAudio's headers: nothing to record with.
bool Available() { return false; }

#endif  // ZEN_HAVE_PULSE

FlMethodChannel* g_channel = nullptr;

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

std::string PathArgument(FlValue* args) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return std::string();
  }
  FlValue* path = fl_value_lookup_string(args, "path");
  return path != nullptr && fl_value_get_type(path) == FL_VALUE_TYPE_STRING
             ? std::string(fl_value_get_string(path))
             : std::string();
}

void OnCall(FlMethodChannel*, FlMethodCall* call, gpointer) {
  const gchar* method = fl_method_call_get_name(call);
  if (strcmp(method, "available") == 0) {
    Respond(call, fl_value_new_bool(Available()));
  } else if (strcmp(method, "start") == 0) {
    const std::string path = PathArgument(fl_method_call_get_args(call));
    if (path.empty()) {
      Fail(call, "bad_args", "path is required");
      return;
    }
#ifdef ZEN_HAVE_PULSE
    if (g_recorder == nullptr) {
      g_recorder = new Recorder();
    }
    std::string code;
    std::string error;
    if (!g_recorder->Start(path, &code, &error)) {
      Fail(call, code, error);
      return;
    }
    Respond(call, fl_value_new_bool(true));
#else
    Fail(call, "unavailable", "built without PulseAudio");
#endif
  } else if (strcmp(method, "stop") == 0) {
    std::string path;
#ifdef ZEN_HAVE_PULSE
    if (g_recorder != nullptr) {
      path = g_recorder->Stop();
    }
#endif
    Respond(call, path.empty() ? nullptr : fl_value_new_string(path.c_str()));
  } else {
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
    fl_method_call_respond(call, response, nullptr);
  }
}

}  // namespace

void zen_call_recorder_register(FlPluginRegistry* registry) {
  if (g_channel != nullptr) {
    return;
  }
  g_autoptr(FlPluginRegistrar) registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "ZenCallRecorder");
  FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel =
      fl_method_channel_new(messenger, kChannelName, FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, OnCall, nullptr,
                                            nullptr);
}
