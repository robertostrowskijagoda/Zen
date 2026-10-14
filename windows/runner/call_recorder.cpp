#include "call_recorder.h"

#include <windows.h>

#include <audioclient.h>
#include <audioclientactivationparams.h>
#include <mmdeviceapi.h>
#include <wrl/implements.h>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>

namespace call_recorder {
namespace {

constexpr int kRate = 48000;
constexpr int kChannels = 2;
constexpr int kBits = 16;
// Keep at most half a second waiting in either stream; older is dropped so
// the two never drift apart.
constexpr size_t kMaxBuffered = kRate * kChannels / 2;

template <typename T>
void SafeRelease(T** p) {
  if (*p) {
    (*p)->Release();
    *p = nullptr;
  }
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                              nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      out.data(), n);
  return out;
}

void WriteU32(FILE* f, uint32_t v) { fwrite(&v, 4, 1, f); }
void WriteU16(FILE* f, uint16_t v) { fwrite(&v, 2, 1, f); }

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

// Waits for ActivateAudioInterfaceAsync (process loopback has no other way
// in).
class ActivationHandler
    : public Microsoft::WRL::RuntimeClass<
          Microsoft::WRL::RuntimeClassFlags<Microsoft::WRL::ClassicCom>,
          Microsoft::WRL::FtmBase, IActivateAudioInterfaceCompletionHandler> {
 public:
  ActivationHandler() { done_ = CreateEventW(nullptr, TRUE, FALSE, nullptr); }
  ~ActivationHandler() override {
    if (done_) CloseHandle(done_);
  }

  STDMETHOD(ActivateCompleted)(
      IActivateAudioInterfaceAsyncOperation* operation) override {
    HRESULT activated = E_FAIL;
    IUnknown* unknown = nullptr;
    if (SUCCEEDED(operation->GetActivateResult(&activated, &unknown)) &&
        SUCCEEDED(activated) && unknown) {
      unknown->QueryInterface(__uuidof(IAudioClient),
                              reinterpret_cast<void**>(&client_));
    }
    SafeRelease(&unknown);
    SetEvent(done_);
    return S_OK;
  }

  // The client, or nullptr after a failure or a timeout. The caller owns it.
  IAudioClient* Wait() {
    if (WaitForSingleObject(done_, 5000) != WAIT_OBJECT_0) return nullptr;
    IAudioClient* client = client_;
    client_ = nullptr;
    return client;
  }

 private:
  HANDLE done_ = nullptr;
  IAudioClient* client_ = nullptr;
};

// Only what this app plays — the people in the call — and nothing else
// the computer plays (music, videos, other apps). Windows 10 2004+.
IAudioClient* OpenOwnAppLoopback() {
  AUDIOCLIENT_ACTIVATION_PARAMS params = {};
  params.ActivationType = AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK;
  params.ProcessLoopbackParams.ProcessLoopbackMode =
      PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE;
  params.ProcessLoopbackParams.TargetProcessId = GetCurrentProcessId();
  PROPVARIANT activation = {};
  activation.vt = VT_BLOB;
  activation.blob.cbSize = sizeof(params);
  activation.blob.pBlobData = reinterpret_cast<BYTE*>(&params);
  Microsoft::WRL::ComPtr<ActivationHandler> handler =
      Microsoft::WRL::Make<ActivationHandler>();
  if (!handler) return nullptr;
  IActivateAudioInterfaceAsyncOperation* operation = nullptr;
  if (FAILED(ActivateAudioInterfaceAsync(
          VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, __uuidof(IAudioClient),
          &activation, handler.Get(), &operation))) {
    return nullptr;
  }
  IAudioClient* client = handler->Wait();
  SafeRelease(&operation);
  return client;
}

// One WASAPI stream (what this app plays, or the microphone) converted by
// Windows to 48 kHz stereo 16-bit.
class Stream {
 public:
  bool Open(IMMDeviceEnumerator* enumerator, bool loopback) {
    HRESULT hr = S_OK;
    if (loopback) {
      client_ = OpenOwnAppLoopback();
      if (!client_) return false;
    } else {
      hr = enumerator->GetDefaultAudioEndpoint(eCapture, eCommunications,
                                               &device_);
      if (FAILED(hr)) {
        hr = enumerator->GetDefaultAudioEndpoint(eCapture, eConsole, &device_);
      }
      if (FAILED(hr)) return false;
      hr = device_->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                             reinterpret_cast<void**>(&client_));
      if (FAILED(hr)) return false;
    }
    WAVEFORMATEX format = {};
    format.wFormatTag = WAVE_FORMAT_PCM;
    format.nChannels = kChannels;
    format.nSamplesPerSec = kRate;
    format.wBitsPerSample = kBits;
    format.nBlockAlign = kChannels * kBits / 8;
    format.nAvgBytesPerSec = kRate * format.nBlockAlign;
    DWORD flags = AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                  AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    if (loopback) {
      // Process loopback wants the event mode; the loop still polls.
      flags |= AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK;
    }
    // 200 ms of buffer.
    hr = client_->Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2000000, 0,
                             &format, nullptr);
    if (FAILED(hr)) return false;
    if (loopback) {
      event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
      if (!event_ || FAILED(client_->SetEventHandle(event_))) return false;
    }
    hr = client_->GetService(__uuidof(IAudioCaptureClient),
                             reinterpret_cast<void**>(&capture_));
    if (FAILED(hr)) return false;
    return SUCCEEDED(client_->Start());
  }

  // Moves everything captured so far into |out|.
  void Drain(std::deque<int16_t>* out) {
    if (!capture_) return;
    UINT32 packet = 0;
    while (SUCCEEDED(capture_->GetNextPacketSize(&packet)) && packet > 0) {
      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      if (FAILED(capture_->GetBuffer(&data, &frames, &flags, nullptr,
                                     nullptr))) {
        return;
      }
      const size_t samples = static_cast<size_t>(frames) * kChannels;
      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) || data == nullptr) {
        out->insert(out->end(), samples, 0);
      } else {
        const int16_t* pcm = reinterpret_cast<const int16_t*>(data);
        out->insert(out->end(), pcm, pcm + samples);
      }
      capture_->ReleaseBuffer(frames);
      while (out->size() > kMaxBuffered) out->pop_front();
    }
  }

  void Close() {
    if (client_) client_->Stop();
    SafeRelease(&capture_);
    SafeRelease(&client_);
    SafeRelease(&device_);
    if (event_) {
      CloseHandle(event_);
      event_ = nullptr;
    }
  }

  bool ok() const { return capture_ != nullptr; }

 private:
  IMMDevice* device_ = nullptr;
  IAudioClient* client_ = nullptr;
  IAudioCaptureClient* capture_ = nullptr;
  HANDLE event_ = nullptr;
};

class Recorder {
 public:
  // Starts recording to |path|; false with |error| set when nothing can be
  // captured.
  bool Start(const std::string& path, std::string* error) {
    if (running_) {
      *error = "already recording";
      return false;
    }
    path_ = path;
    FILE* file = nullptr;
    if (_wfopen_s(&file, Utf8ToWide(path).c_str(), L"wb") != 0 || !file) {
      *error = "cannot create the file";
      return false;
    }
    WriteWavHeader(file, 0);
    stop_ = false;
    std::mutex ready_mutex;
    std::string start_error;
    bool started = false;
    bool done = false;
    std::condition_variable ready;
    thread_ = std::thread([this, file, &ready_mutex, &ready, &start_error,
                           &started, &done]() {
      Run(file, &ready_mutex, &ready, &start_error, &started, &done);
    });
    std::unique_lock<std::mutex> lock(ready_mutex);
    ready.wait(lock, [&done] { return done; });
    if (!started) {
      lock.unlock();
      thread_.join();
      *error = start_error;
      DeleteFileW(Utf8ToWide(path).c_str());
      return false;
    }
    running_ = true;
    return true;
  }

  // Stops and finishes the file; returns its path ("" when nothing ran).
  std::string Stop() {
    if (!running_) return std::string();
    stop_ = true;
    if (thread_.joinable()) thread_.join();
    running_ = false;
    return path_;
  }

  ~Recorder() { Stop(); }

 private:
  void Run(FILE* file, std::mutex* ready_mutex,
           std::condition_variable* ready, std::string* start_error,
           bool* started, bool* done) {
    const HRESULT co = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    IMMDeviceEnumerator* enumerator = nullptr;
    Stream speakers;
    Stream microphone;
    bool have_speakers = false;
    bool have_microphone = false;
    if (SUCCEEDED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                   CLSCTX_ALL, __uuidof(IMMDeviceEnumerator),
                                   reinterpret_cast<void**>(&enumerator)))) {
      have_speakers = speakers.Open(enumerator, true);
      have_microphone = microphone.Open(enumerator, false);
    }
    // The caller's variables live only until it is told: keep a copy.
    // Without the app's own sound there is no call to record (and the whole
    // computer's sound is never taken instead).
    const bool ok = have_speakers;
    {
      std::lock_guard<std::mutex> lock(*ready_mutex);
      *started = ok;
      if (!ok) {
        *start_error =
            "this Windows cannot record only the app's sound "
            "(Windows 10 2004 or newer is needed)";
      }
      *done = true;
      ready->notify_all();
    }
    if (!ok) {
      fclose(file);
      SafeRelease(&enumerator);
      if (SUCCEEDED(co)) CoUninitialize();
      return;
    }

    std::deque<int16_t> from_speakers;
    std::deque<int16_t> from_microphone;
    uint64_t written = 0;  // samples (both channels)
    const auto begin = std::chrono::steady_clock::now();
    std::unique_ptr<int16_t[]> chunk(new int16_t[kRate * kChannels]);
    while (true) {
      const bool last = stop_.load();
      speakers.Drain(&from_speakers);
      microphone.Drain(&from_microphone);
      // The wall clock sets the pace: the speakers deliver nothing while
      // the computer is silent, and that silence belongs in the file too.
      const double seconds = std::chrono::duration<double>(
                                 std::chrono::steady_clock::now() - begin)
                                 .count();
      uint64_t due = static_cast<uint64_t>(seconds * kRate) * kChannels;
      // Do not run ahead of a stream that is merely late.
      if (!last && have_microphone && from_microphone.size() < kChannels * 480) {
        due = std::min<uint64_t>(due, written + from_microphone.size());
      }
      while (written < due) {
        const size_t n = static_cast<size_t>(
            std::min<uint64_t>(due - written, kRate * kChannels));
        for (size_t i = 0; i < n; ++i) {
          int32_t a = 0;
          int32_t b = 0;
          if (!from_speakers.empty()) {
            a = from_speakers.front();
            from_speakers.pop_front();
          }
          if (!from_microphone.empty()) {
            b = from_microphone.front();
            from_microphone.pop_front();
          }
          chunk[i] = static_cast<int16_t>(
              std::clamp<int32_t>(a + b, INT16_MIN, INT16_MAX));
        }
        fwrite(chunk.get(), sizeof(int16_t), n, file);
        written += n;
      }
      if (last) break;
      Sleep(10);
    }
    speakers.Close();
    microphone.Close();
    SafeRelease(&enumerator);
    if (SUCCEEDED(co)) CoUninitialize();

    const uint64_t bytes = written * sizeof(int16_t);
    fseek(file, 0, SEEK_SET);
    WriteWavHeader(file, static_cast<uint32_t>(
                             std::min<uint64_t>(bytes, 0xFFFFFFF0ull)));
    fclose(file);
  }

  std::string path_;
  std::thread thread_;
  std::atomic<bool> stop_{false};
  bool running_ = false;
};

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
std::unique_ptr<Recorder> g_recorder;

}  // namespace

void Register(flutter::BinaryMessenger* messenger) {
  g_recorder = std::make_unique<Recorder>();
  g_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "zen/recorder",
      &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        if (method == "available") {
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "start") {
          const auto* args =
              std::get_if<flutter::EncodableMap>(call.arguments());
          std::string path;
          if (args) {
            auto it = args->find(flutter::EncodableValue("path"));
            if (it != args->end()) {
              if (const auto* p = std::get_if<std::string>(&it->second)) {
                path = *p;
              }
            }
          }
          if (path.empty()) {
            result->Error("bad_args", "path is required");
            return;
          }
          std::string error;
          if (!g_recorder->Start(path, &error)) {
            result->Error("start_failed", error);
            return;
          }
          result->Success(flutter::EncodableValue(true));
          return;
        }
        if (method == "stop") {
          const std::string path = g_recorder->Stop();
          if (path.empty()) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(path));
          }
          return;
        }
        result->NotImplemented();
      });
}

}  // namespace call_recorder
