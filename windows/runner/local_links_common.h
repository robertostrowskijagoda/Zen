#ifndef RUNNER_LOCAL_LINKS_COMMON_H_
#define RUNNER_LOCAL_LINKS_COMMON_H_

#include <flutter/encodable_value.h>
#include <winrt/Windows.Storage.Streams.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

// What the runner's local link bridges share (bluetooth_le_bridge.cpp,
// wifi_direct_bridge.cpp): the platform thread for Flutter's channels, a
// worker thread for WinRT (whose blocking calls must not run on the UI
// thread), and the loopback stream into the Go bridge's endpoint
// (local_link_stream.go: connect to 127.0.0.1:port, write the 16-byte token,
// then pump bytes both ways).
namespace local_links {

constexpr size_t kTokenBytes = 16;

// Call once on the platform thread before anything is posted.
void InitPlatformThread();

// Runs |task| on the platform thread (Flutter's channels live there).
void RunOnPlatformThread(std::function<void()> task);

// One thread in the multi-threaded apartment running tasks in order, now
// or after a delay.
class Worker {
 public:
  Worker();
  ~Worker();
  Worker(const Worker&) = delete;
  Worker& operator=(const Worker&) = delete;

  void Post(std::function<void()> task);
  void PostDelayed(std::chrono::milliseconds delay, std::function<void()> task);

 private:
  void Run();

  std::mutex mutex_;
  std::condition_variable wake_;
  std::multimap<std::chrono::steady_clock::time_point, std::function<void()>>
      tasks_;
  bool stopping_ = false;
  std::thread thread_;
};

// Runs |task| on a new detached thread in the multi-threaded apartment (for
// calls that may block for long: connecting, pairing).
void RunDetached(std::function<void()> task);

std::string Hex(const uint8_t* data, size_t size);
std::string Hex(const std::vector<uint8_t>& bytes);
std::optional<std::vector<uint8_t>> Unhex(const std::string& text,
                                          size_t max_bytes);
std::vector<uint8_t> RandomBytes(size_t count);
std::string RandomId();

winrt::Windows::Storage::Streams::IBuffer ToBuffer(const uint8_t* data,
                                                   size_t size);
std::vector<uint8_t> FromBuffer(
    const winrt::Windows::Storage::Streams::IBuffer& buffer);

// Method call arguments (a map from Dart).
const flutter::EncodableValue* Arg(const flutter::EncodableValue* arguments,
                                   const char* key);
std::string ArgString(const flutter::EncodableValue* arguments,
                      const char* key);
int64_t ArgInt(const flutter::EncodableValue* arguments, const char* key,
               int64_t fallback);
bool ArgBool(const flutter::EncodableValue* arguments, const char* key);
std::vector<uint8_t> ArgBytes(const flutter::EncodableValue* arguments,
                              const char* key);

// A TCP connection to the bridge's endpoint that got its token.
class Loopback {
 public:
  // nullptr when the endpoint is gone.
  static std::shared_ptr<Loopback> Connect(int port,
                                           const std::vector<uint8_t>& token);
  explicit Loopback(uintptr_t socket);
  ~Loopback();
  Loopback(const Loopback&) = delete;
  Loopback& operator=(const Loopback&) = delete;

  // Sends all of it; false once the bridge closed.
  bool Send(const uint8_t* data, size_t size);
  // Bytes read into |buffer|; 0 or less once closed.
  int Receive(uint8_t* buffer, int size);
  // Wakes a blocked Receive; the socket is closed with the object.
  void Shutdown();

 private:
  uintptr_t socket_;
  std::mutex send_mutex_;
};

}  // namespace local_links

#endif  // RUNNER_LOCAL_LINKS_COMMON_H_
