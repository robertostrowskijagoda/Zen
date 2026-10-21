// clang-format off
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
// clang-format on

#include "local_links_common.h"

#include <winrt/base.h>

#include <algorithm>
#include <deque>
#include <utility>

namespace local_links {
namespace {

constexpr UINT kRunTasks = WM_APP + 0x51;
constexpr wchar_t kWindowClass[] = L"ZenLocalLinksDispatch";

HWND g_window = nullptr;
std::mutex g_tasks_mutex;
std::deque<std::function<void()>> g_tasks;

LRESULT CALLBACK DispatchProc(HWND window, UINT message, WPARAM wparam,
                              LPARAM lparam) {
  if (message == kRunTasks) {
    std::deque<std::function<void()>> tasks;
    {
      std::lock_guard<std::mutex> lock(g_tasks_mutex);
      tasks.swap(g_tasks);
    }
    for (auto& task : tasks) {
      task();
    }
    return 0;
  }
  return DefWindowProcW(window, message, wparam, lparam);
}

void RunInApartment(const std::function<void()>& task) {
  try {
    task();
  } catch (const winrt::hresult_error& error) {
    OutputDebugStringW((L"Zen local links: " + error.message() + L"\n").c_str());
  } catch (...) {
    OutputDebugStringW(L"Zen local links: a task failed\n");
  }
}

}  // namespace

void InitPlatformThread() {
  if (g_window) {
    return;
  }
  WNDCLASSW window_class = {};
  window_class.lpfnWndProc = DispatchProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = kWindowClass;
  RegisterClassW(&window_class);
  g_window = CreateWindowExW(0, kWindowClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                             nullptr, GetModuleHandleW(nullptr), nullptr);
  static bool winsock = false;
  if (!winsock) {
    WSADATA data;
    winsock = WSAStartup(MAKEWORD(2, 2), &data) == 0;
  }
}

void RunOnPlatformThread(std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(g_tasks_mutex);
    g_tasks.push_back(std::move(task));
  }
  if (g_window) {
    PostMessageW(g_window, kRunTasks, 0, 0);
  }
}

Worker::Worker() : thread_([this]() { Run(); }) {}

Worker::~Worker() {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stopping_ = true;
  }
  wake_.notify_all();
  if (thread_.joinable()) {
    thread_.join();
  }
}

void Worker::Post(std::function<void()> task) {
  PostDelayed(std::chrono::milliseconds(0), std::move(task));
}

void Worker::PostDelayed(std::chrono::milliseconds delay,
                         std::function<void()> task) {
  {
    std::lock_guard<std::mutex> lock(mutex_);
    tasks_.emplace(std::chrono::steady_clock::now() + delay, std::move(task));
  }
  wake_.notify_all();
}

void Worker::Run() {
  winrt::init_apartment(winrt::apartment_type::multi_threaded);
  std::unique_lock<std::mutex> lock(mutex_);
  while (!stopping_) {
    if (tasks_.empty()) {
      wake_.wait(lock);
      continue;
    }
    const auto next = tasks_.begin()->first;
    if (next > std::chrono::steady_clock::now()) {
      wake_.wait_until(lock, next);
      continue;
    }
    std::function<void()> task = std::move(tasks_.begin()->second);
    tasks_.erase(tasks_.begin());
    lock.unlock();
    RunInApartment(task);
    lock.lock();
  }
  lock.unlock();
  winrt::uninit_apartment();
}

void RunDetached(std::function<void()> task) {
  std::thread([task = std::move(task)]() {
    winrt::init_apartment(winrt::apartment_type::multi_threaded);
    RunInApartment(task);
    winrt::uninit_apartment();
  }).detach();
}

std::string Hex(const uint8_t* data, size_t size) {
  static const char kDigits[] = "0123456789abcdef";
  std::string out;
  out.reserve(size * 2);
  for (size_t i = 0; i < size; i++) {
    out.push_back(kDigits[data[i] >> 4]);
    out.push_back(kDigits[data[i] & 0x0F]);
  }
  return out;
}

std::string Hex(const std::vector<uint8_t>& bytes) {
  return Hex(bytes.data(), bytes.size());
}

std::optional<std::vector<uint8_t>> Unhex(const std::string& text,
                                          size_t max_bytes) {
  if (text.empty() || text.size() % 2 != 0 || text.size() / 2 > max_bytes) {
    return std::nullopt;
  }
  auto digit = [](char c) -> int {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
  };
  std::vector<uint8_t> out(text.size() / 2);
  for (size_t i = 0; i < out.size(); i++) {
    const int high = digit(text[i * 2]);
    const int low = digit(text[i * 2 + 1]);
    if (high < 0 || low < 0) {
      return std::nullopt;
    }
    out[i] = static_cast<uint8_t>((high << 4) | low);
  }
  return out;
}

std::vector<uint8_t> RandomBytes(size_t count) {
  std::vector<uint8_t> out(count);
  if (count > 0) {
    BCryptGenRandom(nullptr, out.data(), static_cast<ULONG>(count),
                    BCRYPT_USE_SYSTEM_PREFERRED_RNG);
  }
  return out;
}

std::string RandomId() { return Hex(RandomBytes(8)); }

winrt::Windows::Storage::Streams::IBuffer ToBuffer(const uint8_t* data,
                                                   size_t size) {
  winrt::Windows::Storage::Streams::DataWriter writer;
  if (size > 0) {
    writer.WriteBytes(winrt::array_view<const uint8_t>(
        data, data + static_cast<uint32_t>(size)));
  }
  return writer.DetachBuffer();
}

std::vector<uint8_t> FromBuffer(
    const winrt::Windows::Storage::Streams::IBuffer& buffer) {
  if (!buffer) {
    return {};
  }
  std::vector<uint8_t> out(buffer.Length());
  if (!out.empty()) {
    auto reader = winrt::Windows::Storage::Streams::DataReader::FromBuffer(buffer);
    reader.ReadBytes(out);
  }
  return out;
}

const flutter::EncodableValue* Arg(const flutter::EncodableValue* arguments,
                                   const char* key) {
  const auto* map =
      arguments ? std::get_if<flutter::EncodableMap>(arguments) : nullptr;
  if (!map) {
    return nullptr;
  }
  auto it = map->find(flutter::EncodableValue(std::string(key)));
  return it == map->end() ? nullptr : &it->second;
}

std::string ArgString(const flutter::EncodableValue* arguments,
                      const char* key) {
  const auto* value = Arg(arguments, key);
  const auto* text = value ? std::get_if<std::string>(value) : nullptr;
  return text ? *text : std::string();
}

int64_t ArgInt(const flutter::EncodableValue* arguments, const char* key,
               int64_t fallback) {
  const auto* value = Arg(arguments, key);
  if (!value) {
    return fallback;
  }
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    return *narrow;
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return *wide;
  }
  return fallback;
}

bool ArgBool(const flutter::EncodableValue* arguments, const char* key) {
  const auto* value = Arg(arguments, key);
  const auto* flag = value ? std::get_if<bool>(value) : nullptr;
  return flag && *flag;
}

std::vector<uint8_t> ArgBytes(const flutter::EncodableValue* arguments,
                              const char* key) {
  const auto* value = Arg(arguments, key);
  const auto* bytes =
      value ? std::get_if<std::vector<uint8_t>>(value) : nullptr;
  return bytes ? *bytes : std::vector<uint8_t>();
}

std::shared_ptr<Loopback> Loopback::Connect(int port,
                                            const std::vector<uint8_t>& token) {
  if (port <= 0 || port > 65535 || token.size() != kTokenBytes) {
    return nullptr;
  }
  SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if (s == INVALID_SOCKET) {
    return nullptr;
  }
  BOOL no_delay = TRUE;
  setsockopt(s, IPPROTO_TCP, TCP_NODELAY, reinterpret_cast<const char*>(&no_delay),
             sizeof(no_delay));
  sockaddr_in address = {};
  address.sin_family = AF_INET;
  address.sin_port = htons(static_cast<u_short>(port));
  address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(s, reinterpret_cast<const sockaddr*>(&address),
              sizeof(address)) != 0) {
    closesocket(s);
    return nullptr;
  }
  auto loop = std::make_shared<Loopback>(static_cast<uintptr_t>(s));
  if (!loop->Send(token.data(), token.size())) {
    return nullptr;
  }
  return loop;
}

Loopback::Loopback(uintptr_t socket) : socket_(socket) {}

Loopback::~Loopback() { closesocket(static_cast<SOCKET>(socket_)); }

bool Loopback::Send(const uint8_t* data, size_t size) {
  std::lock_guard<std::mutex> lock(send_mutex_);
  size_t sent = 0;
  while (sent < size) {
    const int chunk = static_cast<int>(std::min<size_t>(size - sent, 1 << 16));
    const int n = send(static_cast<SOCKET>(socket_),
                       reinterpret_cast<const char*>(data + sent), chunk, 0);
    if (n <= 0) {
      return false;
    }
    sent += static_cast<size_t>(n);
  }
  return true;
}

int Loopback::Receive(uint8_t* buffer, int size) {
  return recv(static_cast<SOCKET>(socket_), reinterpret_cast<char*>(buffer),
              size, 0);
}

void Loopback::Shutdown() {
  shutdown(static_cast<SOCKET>(socket_), SD_BOTH);
}

}  // namespace local_links
