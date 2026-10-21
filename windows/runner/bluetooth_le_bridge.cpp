// clang-format off
#include <winsock2.h>
#include <windows.h>
// clang-format on

#include "bluetooth_le_bridge.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.GenericAttributeProfile.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "local_links_common.h"

// How a stream runs (see the header for the format):
//  - Windows as the GATT server: a client that subscribes to …0006 opens a
//    stream ("incoming" to Dart, which hands it an endpoint or rejects it);
//    its writes to …0005 go to the bridge in order (each write is answered
//    after it reached the loopback, so the client waits: ordered and
//    flow-controlled); the bridge's bytes go out as notifications of at most
//    the client's notification size, one after the other.
//  - Windows as the GATT client: connects, subscribes, then writes with
//    response in pieces of the ATT MTU - 3.
// Battery: the GATT service is advertised (connectable, with the service
// UUID) only in the windows Dart asks for, and while a stream needs it;
// scans run only in Dart's windows. Devices showing only the service UUID
// (Windows, iPhones) have their advert read over GATT at most every two
// minutes; devices without the stream characteristics are not tried again
// for ten minutes.
namespace bluetooth_le_bridge {
namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using Clock = std::chrono::steady_clock;
using MethodResult = flutter::MethodResult<EncodableValue>;
namespace wf = winrt::Windows::Foundation;
namespace bt = winrt::Windows::Devices::Bluetooth;
namespace ble = winrt::Windows::Devices::Bluetooth::Advertisement;
namespace gatt = winrt::Windows::Devices::Bluetooth::GenericAttributeProfile;
namespace radios = winrt::Windows::Devices::Radios;

const winrt::guid kService{0x5a454e00, 0x6c69, 0x6e6b,
                           {0, 0, 0, 0, 0, 0, 0, 0x01}};
const winrt::guid kAdvert{0x5a454e00, 0x6c69, 0x6e6b,
                          {0, 0, 0, 0, 0, 0, 0, 0x02}};
const winrt::guid kPsm{0x5a454e00, 0x6c69, 0x6e6b, {0, 0, 0, 0, 0, 0, 0, 0x03}};
const winrt::guid kStreamIn{0x5a454e00, 0x6c69, 0x6e6b,
                            {0, 0, 0, 0, 0, 0, 0, 0x05}};
const winrt::guid kStreamOut{0x5a454e00, 0x6c69, 0x6e6b,
                             {0, 0, 0, 0, 0, 0, 0, 0x06}};

constexpr uint16_t kCompanyId = 0xFFFF;
constexpr uint8_t kMagic[2] = {0x5A, 0x4C};
// The Bloom filter bytes Dart asks the bridge for (read over GATT, so not
// bound by the 31-byte packet).
constexpr int kAdvertBytes = 32;
constexpr size_t kMinAdvert = 7 + 8;
constexpr size_t kMaxAdvert = 7 + 1024;
constexpr size_t kMaxIncoming = 8;
constexpr size_t kMaxStreams = 16;
constexpr size_t kMaxDials = 2;
// Bytes a stream keeps while it waits for Dart's endpoint.
constexpr size_t kMaxPending = 64 * 1024;
constexpr size_t kMaxSeen = 512;
constexpr size_t kMinChunk = 20;
constexpr auto kIncomingWait = std::chrono::seconds(15);
constexpr auto kSeenEvery = std::chrono::seconds(3);
constexpr auto kGattReread = std::chrono::minutes(2);
constexpr auto kScanResponseWait = std::chrono::milliseconds(2000);
constexpr auto kNoStreamFor = std::chrono::minutes(10);

EncodableValue Text(const std::string& text) { return EncodableValue(text); }

std::string AddressText(uint64_t address) {
  char text[18];
  std::snprintf(text, sizeof(text), "%02X:%02X:%02X:%02X:%02X:%02X",
                static_cast<unsigned>((address >> 40) & 0xFF),
                static_cast<unsigned>((address >> 32) & 0xFF),
                static_cast<unsigned>((address >> 24) & 0xFF),
                static_cast<unsigned>((address >> 16) & 0xFF),
                static_cast<unsigned>((address >> 8) & 0xFF),
                static_cast<unsigned>(address & 0xFF));
  return text;
}

bool ParseAddress(const std::string& text, uint64_t* address) {
  if (text.size() != 17) {
    return false;
  }
  uint64_t value = 0;
  for (size_t i = 0; i < 6; i++) {
    if (i > 0 && text[i * 3 - 1] != ':') {
      return false;
    }
    auto byte = local_links::Unhex(text.substr(i * 3, 2), 1);
    if (!byte) {
      return false;
    }
    value = (value << 8) | (*byte)[0];
  }
  *address = value;
  return true;
}

bt::BluetoothLEDevice OpenDevice(uint64_t address,
                                 std::optional<bt::BluetoothAddressType> type) {
  if (type) {
    try {
      return bt::BluetoothLEDevice::FromBluetoothAddressAsync(address, *type)
          .get();
    } catch (...) {
      // Older Windows: without the address type.
    }
  }
  return bt::BluetoothLEDevice::FromBluetoothAddressAsync(address).get();
}

gatt::GattCharacteristic FindCharacteristic(const gatt::GattDeviceService& service,
                                            const winrt::guid& uuid) {
  auto result =
      service.GetCharacteristicsForUuidAsync(uuid, bt::BluetoothCacheMode::Uncached)
          .get();
  if (result.Status() != gatt::GattCommunicationStatus::Success ||
      result.Characteristics().Size() == 0) {
    return nullptr;
  }
  return result.Characteristics().GetAt(0);
}

// One byte stream over the stream characteristics, pumped into the
// bridge's endpoint once Dart gives one (bytes that come before wait).
class GattStream : public std::enable_shared_from_this<GattStream> {
 public:
  using SendChunk = std::function<bool(const uint8_t*, size_t)>;
  using ChunkSize = std::function<size_t()>;

  GattStream(std::string device, SendChunk send, ChunkSize chunk)
      : id_(local_links::RandomId()),
        device_(std::move(device)),
        send_(std::move(send)),
        chunk_(std::move(chunk)) {}

  const std::string& id() const { return id_; }
  const std::string& device() const { return device_; }

  // Runs once, on the thread that closes it.
  void OnClose(std::function<void()> on_close) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    on_close_ = std::move(on_close);
  }

  // Bytes from the radio, in the order they came.
  void Received(const std::vector<uint8_t>& bytes) {
    bool failed = false;
    {
      std::lock_guard<std::mutex> order(order_mutex_);
      std::shared_ptr<local_links::Loopback> loop;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (closed_) {
          return;
        }
        loop = loop_;
        if (!loop) {
          if (pending_.size() + bytes.size() > kMaxPending) {
            failed = true;
          } else {
            pending_.insert(pending_.end(), bytes.begin(), bytes.end());
          }
        }
      }
      if (loop && !loop->Send(bytes.data(), bytes.size())) {
        failed = true;
      }
    }
    if (failed) {
      Close();
    }
  }

  // Connects to the endpoint and pumps both ways; false if it is gone.
  bool Pump(int port, const std::vector<uint8_t>& token) {
    auto loop = local_links::Loopback::Connect(port, token);
    if (!loop) {
      return false;
    }
    {
      std::lock_guard<std::mutex> order(order_mutex_);
      std::vector<uint8_t> pending;
      {
        std::lock_guard<std::mutex> lock(state_mutex_);
        if (closed_) {
          return false;
        }
        pending.swap(pending_);
        loop_ = loop;
      }
      if (!pending.empty() && !loop->Send(pending.data(), pending.size())) {
        return false;
      }
    }
    auto self = shared_from_this();
    local_links::RunDetached([self, loop]() { self->ReadLoop(loop); });
    return true;
  }

  void Close() {
    std::shared_ptr<local_links::Loopback> loop;
    std::function<void()> on_close;
    {
      std::lock_guard<std::mutex> lock(state_mutex_);
      if (closed_) {
        return;
      }
      closed_ = true;
      loop = loop_;
      on_close = std::move(on_close_);
      pending_.clear();
    }
    if (loop) {
      loop->Shutdown();
    }
    if (on_close) {
      on_close();
    }
  }

  bool closed() {
    std::lock_guard<std::mutex> lock(state_mutex_);
    return closed_;
  }

 private:
  void ReadLoop(std::shared_ptr<local_links::Loopback> loop) {
    std::vector<uint8_t> buffer(8192);
    while (!closed()) {
      const int n = loop->Receive(buffer.data(), static_cast<int>(buffer.size()));
      if (n <= 0) {
        break;
      }
      const size_t total = static_cast<size_t>(n);
      size_t offset = 0;
      while (offset < total) {
        const size_t size =
            std::min(std::max(chunk_(), kMinChunk), total - offset);
        if (closed() || !send_(buffer.data() + offset, size)) {
          Close();
          return;
        }
        offset += size;
      }
    }
    Close();
  }

  const std::string id_;
  const std::string device_;
  const SendChunk send_;
  const ChunkSize chunk_;
  // Keeps the bytes in order (held while they go to the loopback).
  std::mutex order_mutex_;
  std::mutex state_mutex_;
  bool closed_ = false;
  std::vector<uint8_t> pending_;
  std::shared_ptr<local_links::Loopback> loop_;
  std::function<void()> on_close_;
};

// The WinRT objects of a stream this computer opened as the GATT client.
struct ClientLink {
  bt::BluetoothLEDevice device{nullptr};
  gatt::GattDeviceService service{nullptr};
  gatt::GattSession session{nullptr};
  gatt::GattCharacteristic in{nullptr};
  gatt::GattCharacteristic out{nullptr};
  winrt::event_token changed{};
  winrt::event_token status{};

  // Ends the stream for the server too, then lets everything go.
  void Release() {
    try {
      out.ValueChanged(changed);
      device.ConnectionStatusChanged(status);
    } catch (...) {
    }
    try {
      if (device.ConnectionStatus() == bt::BluetoothConnectionStatus::Connected) {
        in.WriteValueAsync(local_links::ToBuffer(nullptr, 0),
                           gatt::GattWriteOption::WriteWithResponse)
            .get();
        out.WriteClientCharacteristicConfigurationDescriptorAsync(
               gatt::GattClientCharacteristicConfigurationDescriptorValue::None)
            .get();
      }
    } catch (...) {
    }
    try {
      session.MaintainConnection(false);
      session.Close();
    } catch (...) {
    }
    try {
      service.Close();
    } catch (...) {
    }
    try {
      device.Close();
    } catch (...) {
    }
  }
};

struct Seen {
  uint64_t address = 0;
  std::optional<bt::BluetoothAddressType> type;
  std::vector<uint8_t> zen;  // "ZL", PSM, advert (manufacturer data)
  bool service = false;      // the Zen service UUID only
};

struct GattInfo {
  std::vector<uint8_t> advert;
  bool stream = false;
};

enum class DialOutcome { kConnected, kFailed, kNoStream };

class Bridge {
 public:
  void Register(flutter::BinaryMessenger* messenger) {
    local_links::InitPlatformThread();
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "zen/bt_link", &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult> result) {
          HandleCall(call, std::shared_ptr<MethodResult>(std::move(result)));
        });
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "zen/bt_link/events",
        &flutter::StandardMethodCodec::GetInstance());
    events_->SetStreamHandler(
        std::make_unique<flutter::StreamHandlerFunctions<EncodableValue>>(
            [this](const EncodableValue*,
                   std::unique_ptr<flutter::EventSink<EncodableValue>>&& sink)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              sink_ = std::move(sink);
              return nullptr;
            },
            [this](const EncodableValue*)
                -> std::unique_ptr<flutter::StreamHandlerError<EncodableValue>> {
              sink_ = nullptr;
              return nullptr;
            }));
  }

 private:
  // --- Channels (platform thread) ------------------------------------------

  void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                  std::shared_ptr<MethodResult> result) {
    const std::string& method = call.method_name();
    const EncodableValue* args = call.arguments();
    if (method == "requestPermissions") {
      // Desktop apps need no permission for Bluetooth.
      result->Success(EncodableValue(true));
    } else if (method == "pairedDevices") {
      // Paired devices are the Go bridge's (RFCOMM).
      result->Success(EncodableValue(EncodableList()));
    } else if (method == "state") {
      Answer(result, EncodableValue(EncodableMap()),
             [this]() { return EncodableValue(State()); });
    } else if (method == "start") {
      Answer(result, EncodableValue(false),
             [this]() { return EncodableValue(Start()); });
    } else if (method == "stop") {
      Answer(result, EncodableValue(), [this]() {
        Stop();
        return EncodableValue();
      });
    } else if (method == "advertise") {
      auto advert = local_links::Unhex(local_links::ArgString(args, "advert"),
                                       kMaxAdvert);
      const int window = static_cast<int>(std::clamp<int64_t>(
          local_links::ArgInt(args, "windowMs", 20000), 1000, 180000));
      if (!advert || advert->size() < kMinAdvert) {
        result->Success(EncodableValue(false));
        return;
      }
      Answer(result, EncodableValue(false), [this, advert, window]() {
        return EncodableValue(Advertise(*advert, window));
      });
    } else if (method == "scan") {
      const int window = static_cast<int>(std::clamp<int64_t>(
          local_links::ArgInt(args, "windowMs", 8000), 1000, 60000));
      Answer(result, EncodableValue(false),
             [this, window]() { return EncodableValue(Scan(window)); });
    } else if (method == "connect") {
      const std::string device = local_links::ArgString(args, "device");
      const int port =
          static_cast<int>(local_links::ArgInt(args, "port", 0));
      const std::vector<uint8_t> token = local_links::ArgBytes(args, "token");
      if (local_links::ArgBool(args, "classic") ||
          token.size() != local_links::kTokenBytes || port <= 0) {
        result->Success(EncodableValue(false));
        return;
      }
      worker_.Post([this, device, port, token, result]() {
        Connect(device, port, token, result);
      });
    } else if (method == "accept") {
      const std::string id = local_links::ArgString(args, "id");
      const int port =
          static_cast<int>(local_links::ArgInt(args, "port", 0));
      const std::vector<uint8_t> token = local_links::ArgBytes(args, "token");
      Answer(result, EncodableValue(false), [this, id, port, token]() {
        return EncodableValue(Accept(id, port, token));
      });
    } else if (method == "reject") {
      const std::string id = local_links::ArgString(args, "id");
      Answer(result, EncodableValue(), [this, id]() {
        Reject(id);
        return EncodableValue();
      });
    } else {
      result->NotImplemented();
    }
  }

  // Runs |work| on the worker and answers with what it returns (|fallback|
  // when it throws): every call gets an answer.
  void Answer(std::shared_ptr<MethodResult> result, EncodableValue fallback,
              std::function<EncodableValue()> work) {
    worker_.Post([result, fallback, work]() {
      EncodableValue value = fallback;
      try {
        value = work();
      } catch (...) {
      }
      Reply(result, value);
    });
  }

  static void Reply(std::shared_ptr<MethodResult> result, EncodableValue value) {
    local_links::RunOnPlatformThread(
        [result, value]() { result->Success(value); });
  }

  void Emit(EncodableMap event) {
    local_links::RunOnPlatformThread([this, event]() {
      if (sink_) {
        sink_->Success(EncodableValue(event));
      }
    });
  }

  // --- The radio (worker) --------------------------------------------------

  bool Adapter() {
    if (!adapter_) {
      adapter_ = bt::BluetoothAdapter::GetDefaultAsync().get();
      if (!adapter_) {
        return false;
      }
    }
    if (!adapter_.IsLowEnergySupported() || !adapter_.IsCentralRoleSupported()) {
      return false;
    }
    peripheral_ = adapter_.IsPeripheralRoleSupported();
    if (!radio_) {
      radio_ = adapter_.GetRadioAsync().get();
      if (radio_) {
        radio_token_ = radio_.StateChanged(
            [this](const radios::Radio& radio, const wf::IInspectable&) {
              const bool on = radio.State() == radios::RadioState::On;
              worker_.Post([this, on]() { OnRadio(on); });
            });
      }
    }
    return true;
  }

  // Without the radio object (no access to it) the adapter counts as on.
  bool RadioOn() {
    return !radio_ || radio_.State() == radios::RadioState::On;
  }

  EncodableMap State() {
    bool supported = false;
    bool enabled = false;
    try {
      supported = Adapter();
      enabled = supported && RadioOn();
    } catch (...) {
      supported = false;
    }
    return EncodableMap{
        {Text("supported"), EncodableValue(supported)},
        {Text("permitted"), EncodableValue(true)},
        {Text("enabled"), EncodableValue(enabled)},
        {Text("advertBytes"), EncodableValue(kAdvertBytes)},
        {Text("discovery"), EncodableValue(supported)},
        {Text("paired"), EncodableValue(false)},
    };
  }

  bool Start() {
    if (!Adapter() || !RadioOn()) {
      return false;
    }
    running_ = true;
    if (peripheral_ && !provider_) {
      try {
        CreateProvider();
      } catch (...) {
        // No GATT server: this computer still connects to others.
        provider_ = nullptr;
      }
    }
    return true;
  }

  void CreateProvider() {
    auto created = gatt::GattServiceProvider::CreateAsync(kService).get();
    if (created.Error() != bt::BluetoothError::Success) {
      return;
    }
    auto provider = created.ServiceProvider();
    auto service = provider.Service();

    gatt::GattLocalCharacteristicParameters advert;
    advert.CharacteristicProperties(gatt::GattCharacteristicProperties::Read);
    advert.ReadProtectionLevel(gatt::GattProtectionLevel::Plain);
    auto advert_char = service.CreateCharacteristicAsync(kAdvert, advert).get();

    gatt::GattLocalCharacteristicParameters psm;
    psm.CharacteristicProperties(gatt::GattCharacteristicProperties::Read);
    psm.ReadProtectionLevel(gatt::GattProtectionLevel::Plain);
    const uint8_t no_psm[2] = {0, 0};
    psm.StaticValue(local_links::ToBuffer(no_psm, sizeof(no_psm)));
    auto psm_char = service.CreateCharacteristicAsync(kPsm, psm).get();

    gatt::GattLocalCharacteristicParameters in;
    in.CharacteristicProperties(gatt::GattCharacteristicProperties::Write);
    in.WriteProtectionLevel(gatt::GattProtectionLevel::Plain);
    auto in_char = service.CreateCharacteristicAsync(kStreamIn, in).get();

    gatt::GattLocalCharacteristicParameters out;
    out.CharacteristicProperties(gatt::GattCharacteristicProperties::Notify);
    out.ReadProtectionLevel(gatt::GattProtectionLevel::Plain);
    out.WriteProtectionLevel(gatt::GattProtectionLevel::Plain);
    auto out_char = service.CreateCharacteristicAsync(kStreamOut, out).get();

    if (advert_char.Error() != bt::BluetoothError::Success ||
        psm_char.Error() != bt::BluetoothError::Success ||
        in_char.Error() != bt::BluetoothError::Success ||
        out_char.Error() != bt::BluetoothError::Success) {
      return;
    }
    advert_char.Characteristic().ReadRequested(
        [this](const gatt::GattLocalCharacteristic&,
               const gatt::GattReadRequestedEventArgs& args) {
          OnAdvertRead(args);
        });
    in_char.Characteristic().WriteRequested(
        [this](const gatt::GattLocalCharacteristic&,
               const gatt::GattWriteRequestedEventArgs& args) {
          OnStreamWrite(args);
        });
    out_char.Characteristic().SubscribedClientsChanged(
        [this](const gatt::GattLocalCharacteristic&, const wf::IInspectable&) {
          worker_.Post([this]() { SyncSubscribers(); });
        });
    {
      std::lock_guard<std::mutex> lock(mutex_);
      out_char_ = out_char.Characteristic();
    }
    provider_ = provider;
  }

  void OnRadio(bool on) {
    if (!on) {
      // The stack dropped the service, the adverts and the connections.
      CloseAll();
      StopScan();
      provider_ = nullptr;
      {
        std::lock_guard<std::mutex> lock(mutex_);
        out_char_ = nullptr;
      }
    }
    if (running_) {
      Emit(EncodableMap{{Text("type"), Text("radio")},
                        {Text("on"), EncodableValue(on)}});
    }
  }

  void Stop() {
    running_ = false;
    StopScan();
    advert_window_ = false;
    ++advert_gen_;
    CloseAll();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      advert_.clear();
    }
    StopAdvertising();
  }

  void CloseAll() {
    std::vector<std::shared_ptr<GattStream>> all;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (auto& entry : streams_) {
        all.push_back(entry.second);
      }
      incoming_.clear();
    }
    for (auto& stream : all) {
      stream->Close();
    }
  }

  // --- Advertising and the GATT server -------------------------------------

  bool Advertise(const std::vector<uint8_t>& advert, int window_ms) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      advert_ = advert;
    }
    if (!running_ || !provider_) {
      return false;
    }
    const auto status = provider_.AdvertisementStatus();
    if (status != gatt::GattServiceProviderAdvertisementStatus::Started) {
      gatt::GattServiceProviderAdvertisingParameters parameters;
      parameters.IsConnectable(true);
      parameters.IsDiscoverable(true);
      provider_.StartAdvertising(parameters);
    }
    advert_window_ = true;
    const uint64_t generation = ++advert_gen_;
    worker_.PostDelayed(std::chrono::milliseconds(window_ms),
                        [this, generation]() {
                          if (generation == advert_gen_) {
                            advert_window_ = false;
                            MaybeStopAdvertising();
                          }
                        });
    return true;
  }

  // Outside Dart's window the service goes away, unless a stream needs it.
  void MaybeStopAdvertising() {
    if (advert_window_) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      if (!server_.empty()) {
        return;
      }
    }
    StopAdvertising();
  }

  void StopAdvertising() {
    try {
      if (provider_ && provider_.AdvertisementStatus() ==
                           gatt::GattServiceProviderAdvertisementStatus::Started) {
        provider_.StopAdvertising();
      }
    } catch (...) {
    }
  }

  void OnAdvertRead(const gatt::GattReadRequestedEventArgs& args) {
    auto deferral = args.GetDeferral();
    try {
      auto request = args.GetRequestAsync().get();
      if (request) {
        std::vector<uint8_t> value;
        {
          std::lock_guard<std::mutex> lock(mutex_);
          value = advert_;
        }
        const uint32_t offset = request.Offset();
        if (offset > value.size()) {
          request.RespondWithProtocolError(
              gatt::GattProtocolError::InvalidOffset());
        } else {
          request.RespondWithValue(local_links::ToBuffer(
              value.data() + offset, value.size() - offset));
        }
      }
    } catch (...) {
    }
    deferral.Complete();
  }

  void OnStreamWrite(const gatt::GattWriteRequestedEventArgs& args) {
    auto deferral = args.GetDeferral();
    try {
      auto request = args.GetRequestAsync().get();
      if (request) {
        const std::string device =
            winrt::to_string(args.Session().DeviceId().Id());
        std::shared_ptr<GattStream> stream = ServerStream(device);
        if (!stream) {
          // Subscribed a moment ago: the list may not be read yet.
          stream = ServerStreamForSubscriber(device);
        }
        const std::vector<uint8_t> bytes =
            local_links::FromBuffer(request.Value());
        if (stream) {
          if (bytes.empty()) {
            stream->Close();
          } else {
            stream->Received(bytes);
          }
        }
        if (request.Option() == gatt::GattWriteOption::WriteWithResponse) {
          request.Respond();
        }
      }
    } catch (...) {
    }
    deferral.Complete();
  }

  std::shared_ptr<GattStream> ServerStream(const std::string& device) {
    std::lock_guard<std::mutex> lock(mutex_);
    auto it = server_.find(device);
    return it == server_.end() ? nullptr : it->second;
  }

  std::shared_ptr<GattStream> ServerStreamForSubscriber(
      const std::string& device) {
    gatt::GattLocalCharacteristic out{nullptr};
    {
      std::lock_guard<std::mutex> lock(mutex_);
      out = out_char_;
    }
    if (!out) {
      return nullptr;
    }
    for (const auto& client : out.SubscribedClients()) {
      if (winrt::to_string(client.Session().DeviceId().Id()) == device) {
        return OpenServerStream(device, client);
      }
    }
    return nullptr;
  }

  // Subscribers open streams; those that left close theirs.
  void SyncSubscribers() {
    gatt::GattLocalCharacteristic out{nullptr};
    {
      std::lock_guard<std::mutex> lock(mutex_);
      out = out_char_;
    }
    if (!out) {
      return;
    }
    std::map<std::string, gatt::GattSubscribedClient> now;
    for (const auto& client : out.SubscribedClients()) {
      now.emplace(winrt::to_string(client.Session().DeviceId().Id()), client);
    }
    std::vector<std::shared_ptr<GattStream>> gone;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      for (const auto& entry : server_) {
        if (now.count(entry.first) == 0) {
          gone.push_back(entry.second);
        }
      }
    }
    for (auto& stream : gone) {
      stream->Close();
    }
    for (const auto& entry : now) {
      OpenServerStream(entry.first, entry.second);
    }
  }

  // The stream of a subscribed client (made the first time); any thread.
  std::shared_ptr<GattStream> OpenServerStream(
      const std::string& device, const gatt::GattSubscribedClient& client) {
    std::shared_ptr<GattStream> stream;
    std::string id;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto known = server_.find(device);
      if (known != server_.end()) {
        if (!known->second->closed()) {
          return known->second;
        }
        // Subscribed again before the old stream was forgotten.
        server_.erase(known);
      }
      if (!running_ || incoming_.size() >= kMaxIncoming ||
          streams_.size() >= kMaxStreams) {
        stream = nullptr;
      } else {
        stream = std::make_shared<GattStream>(
            device,
            [this, client](const uint8_t* data, size_t size) {
              return Notify(client, data, size);
            },
            [client]() -> size_t { return client.MaxNotificationSize(); });
        const std::string stream_id = stream->id();
        stream->OnClose([this, client, device, stream_id]() {
          local_links::RunDetached([this, client]() { Notify(client, nullptr, 0); });
          worker_.Post([this, device, stream_id]() {
            Forget(stream_id, device);
          });
        });
        id = local_links::RandomId();
        server_[device] = stream;
        streams_[stream->id()] = stream;
        incoming_[id] = stream;
      }
    }
    if (!stream) {
      // Full: tell the client the stream is over.
      local_links::RunDetached([this, client]() { Notify(client, nullptr, 0); });
      return nullptr;
    }
    worker_.PostDelayed(kIncomingWait, [this, id]() { Reject(id); });
    Emit(EncodableMap{{Text("type"), Text("incoming")}, {Text("id"), Text(id)}});
    return stream;
  }

  bool Notify(const gatt::GattSubscribedClient& client, const uint8_t* data,
              size_t size) {
    gatt::GattLocalCharacteristic out{nullptr};
    {
      std::lock_guard<std::mutex> lock(mutex_);
      out = out_char_;
    }
    if (!out) {
      return false;
    }
    try {
      auto result =
          out.NotifyValueAsync(local_links::ToBuffer(data, size), client).get();
      return result &&
             result.Status() == gatt::GattCommunicationStatus::Success;
    } catch (...) {
      return false;
    }
  }

  void Forget(const std::string& stream_id, const std::string& server_device) {
    {
      std::lock_guard<std::mutex> lock(mutex_);
      streams_.erase(stream_id);
      if (!server_device.empty()) {
        auto it = server_.find(server_device);
        if (it != server_.end() && it->second->id() == stream_id) {
          server_.erase(it);
        }
      }
      for (auto it = incoming_.begin(); it != incoming_.end();) {
        it = it->second->id() == stream_id ? incoming_.erase(it) : std::next(it);
      }
    }
    MaybeStopAdvertising();
  }

  bool Accept(const std::string& id, int port, const std::vector<uint8_t>& token) {
    std::shared_ptr<GattStream> stream;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = incoming_.find(id);
      if (it == incoming_.end()) {
        return false;
      }
      stream = it->second;
      incoming_.erase(it);
    }
    if (!stream->Pump(port, token)) {
      stream->Close();
      return false;
    }
    return true;
  }

  void Reject(const std::string& id) {
    std::shared_ptr<GattStream> stream;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = incoming_.find(id);
      if (it == incoming_.end()) {
        return;
      }
      stream = it->second;
      incoming_.erase(it);
    }
    stream->Close();
  }

  // --- Scanning --------------------------------------------------------------

  bool Scan(int window_ms) {
    if (!running_ || !RadioOn()) {
      return false;
    }
    if (!watcher_ || watcher_.Status() ==
                         ble::BluetoothLEAdvertisementWatcherStatus::Aborted) {
      watcher_ = ble::BluetoothLEAdvertisementWatcher();
      // Active: Android puts the advert in its scan response.
      watcher_.ScanningMode(ble::BluetoothLEScanningMode::Active);
      watcher_.Received(
          [this](const ble::BluetoothLEAdvertisementWatcher&,
                 const ble::BluetoothLEAdvertisementReceivedEventArgs& args) {
            OnReceived(args);
          });
    }
    if (watcher_.Status() != ble::BluetoothLEAdvertisementWatcherStatus::Started) {
      watcher_.Start();
    }
    const uint64_t generation = ++scan_gen_;
    worker_.PostDelayed(std::chrono::milliseconds(window_ms),
                        [this, generation]() {
                          if (generation == scan_gen_) {
                            StopScan();
                          }
                        });
    return true;
  }

  void StopScan() {
    ++scan_gen_;
    try {
      if (watcher_ && watcher_.Status() ==
                          ble::BluetoothLEAdvertisementWatcherStatus::Started) {
        watcher_.Stop();
      }
    } catch (...) {
    }
  }

  // A thread-pool thread: copies what matters and hands it to the worker.
  void OnReceived(const ble::BluetoothLEAdvertisementReceivedEventArgs& args) {
    try {
      Seen seen;
      seen.address = args.BluetoothAddress();
      try {
        seen.type = args.BluetoothAddressType();
      } catch (...) {
        // Before Windows 10 2004.
      }
      const auto advertisement = args.Advertisement();
      for (const auto& data :
           advertisement.GetManufacturerDataByCompanyId(kCompanyId)) {
        std::vector<uint8_t> bytes = local_links::FromBuffer(data.Data());
        if (bytes.size() >= 4 + kMinAdvert && bytes[0] == kMagic[0] &&
            bytes[1] == kMagic[1]) {
          seen.zen = std::move(bytes);
          break;
        }
      }
      if (seen.zen.empty()) {
        for (const auto& uuid : advertisement.ServiceUuids()) {
          if (uuid == kService) {
            seen.service = true;
            break;
          }
        }
      }
      if (seen.zen.empty() && !seen.service) {
        return;
      }
      worker_.Post([this, seen]() { OnSeen(seen); });
    } catch (...) {
    }
  }

  bool NoStream(const std::string& device, Clock::time_point now) {
    auto it = no_stream_.find(device);
    return it != no_stream_.end() && now - it->second < kNoStreamFor;
  }

  void OnSeen(const Seen& seen) {
    if (!running_) {
      return;
    }
    const Clock::time_point now = Clock::now();
    if (reported_.size() >= kMaxSeen || gatt_read_.size() >= kMaxSeen) {
      reported_.clear();
      zen_seen_.clear();
      gatt_read_.clear();
      no_stream_.clear();
      types_.clear();
    }
    const std::string device = AddressText(seen.address);
    if (seen.type) {
      types_[device] = *seen.type;
    }
    if (!seen.zen.empty()) {
      // Android (and Linux): the advert is in the packet; GATT streams go to
      // the same address.
      zen_seen_[device] = now;
      auto last = reported_.find(device);
      if (last != reported_.end() && now - last->second < kSeenEvery) {
        return;
      }
      reported_[device] = now;
      const int psm = seen.zen[2] | (seen.zen[3] << 8);
      const std::vector<uint8_t> advert(seen.zen.begin() + 4, seen.zen.end());
      ReportSeen(device, advert, psm, !NoStream(device, now));
      return;
    }
    // Only the service UUID: a scan response with the advert may follow.
    if (pending_reads_.count(device) > 0) {
      return;
    }
    pending_reads_.insert(device);
    worker_.PostDelayed(kScanResponseWait,
                        [this, device]() { MaybeReadOverGatt(device); });
  }

  void ReportSeen(const std::string& device, const std::vector<uint8_t>& advert,
                  int psm, bool connectable) {
    Emit(EncodableMap{
        {Text("type"), Text("seen")},
        {Text("device"), Text(device)},
        {Text("advert"), Text(local_links::Hex(advert))},
        {Text("psm"), EncodableValue(psm)},
        {Text("connectable"), EncodableValue(connectable)},
    });
  }

  // Windows computers and Apple devices show the advert only over GATT.
  void MaybeReadOverGatt(const std::string& device) {
    pending_reads_.erase(device);
    const Clock::time_point now = Clock::now();
    auto zen = zen_seen_.find(device);
    if (!running_ || gatt_busy_ || NoStream(device, now) ||
        (zen != zen_seen_.end() && now - zen->second < kGattReread)) {
      return;
    }
    auto read = gatt_read_.find(device);
    if (read != gatt_read_.end() && now - read->second < kGattReread) {
      return;
    }
    uint64_t address = 0;
    if (!ParseAddress(device, &address)) {
      return;
    }
    gatt_busy_ = true;
    gatt_read_[device] = now;
    std::optional<bt::BluetoothAddressType> type;
    auto known = types_.find(device);
    if (known != types_.end()) {
      type = known->second;
    }
    local_links::RunDetached([this, device, address, type]() {
      std::optional<GattInfo> info;
      try {
        info = ReadOverGatt(address, type);
      } catch (...) {
      }
      worker_.Post([this, device, info]() {
        gatt_busy_ = false;
        if (!info || !running_) {
          return;
        }
        if (!info->stream) {
          // An iPhone or a Mac (L2CAP only): nothing this computer can open.
          no_stream_[device] = Clock::now();
          return;
        }
        if (info->advert.size() >= kMinAdvert &&
            info->advert.size() <= kMaxAdvert) {
          ReportSeen(device, info->advert, 0, true);
        }
      });
    });
  }

  static std::optional<GattInfo> ReadOverGatt(
      uint64_t address, std::optional<bt::BluetoothAddressType> type) {
    auto device = OpenDevice(address, type);
    if (!device) {
      return std::nullopt;
    }
    std::optional<GattInfo> info;
    try {
      auto services =
          device.GetGattServicesForUuidAsync(kService, bt::BluetoothCacheMode::Uncached)
              .get();
      if (services.Status() == gatt::GattCommunicationStatus::Success &&
          services.Services().Size() > 0) {
        auto service = services.Services().GetAt(0);
        GattInfo found;
        auto advert = FindCharacteristic(service, kAdvert);
        if (advert) {
          auto value = advert.ReadValueAsync(bt::BluetoothCacheMode::Uncached).get();
          if (value.Status() == gatt::GattCommunicationStatus::Success) {
            found.advert = local_links::FromBuffer(value.Value());
          }
        }
        found.stream = FindCharacteristic(service, kStreamIn) &&
                       FindCharacteristic(service, kStreamOut);
        service.Close();
        info = found;
      }
    } catch (...) {
    }
    device.Close();
    return info;
  }

  // --- Connecting as the GATT client -----------------------------------------

  void Connect(const std::string& device, int port,
               const std::vector<uint8_t>& token,
               std::shared_ptr<MethodResult> result) {
    uint64_t address = 0;
    size_t streams = 0;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      streams = streams_.size();
    }
    if (!running_ || !ParseAddress(device, &address) || dials_ >= kMaxDials ||
        streams >= kMaxStreams) {
      Reply(result, EncodableValue(false));
      return;
    }
    dials_++;
    std::optional<bt::BluetoothAddressType> type;
    auto known = types_.find(device);
    if (known != types_.end()) {
      type = known->second;
    }
    // A scan slows connecting down.
    StopScan();
    local_links::RunDetached([this, device, address, type, port, token, result]() {
      DialOutcome outcome = DialOutcome::kFailed;
      try {
        outcome = Dial(device, address, type, port, token);
      } catch (...) {
      }
      worker_.Post([this, device, outcome, result]() {
        dials_--;
        if (outcome == DialOutcome::kNoStream) {
          no_stream_[device] = Clock::now();
        }
        Reply(result, EncodableValue(outcome == DialOutcome::kConnected));
      });
    });
  }

  DialOutcome Dial(const std::string& device, uint64_t address,
                   std::optional<bt::BluetoothAddressType> type, int port,
                   const std::vector<uint8_t>& token) {
    auto link = std::make_shared<ClientLink>();
    link->device = OpenDevice(address, type);
    if (!link->device) {
      return DialOutcome::kFailed;
    }
    auto services = link->device
                        .GetGattServicesForUuidAsync(
                            kService, bt::BluetoothCacheMode::Uncached)
                        .get();
    if (services.Status() != gatt::GattCommunicationStatus::Success) {
      link->device.Close();
      return DialOutcome::kFailed;
    }
    if (services.Services().Size() == 0) {
      link->device.Close();
      return DialOutcome::kNoStream;
    }
    link->service = services.Services().GetAt(0);
    link->in = FindCharacteristic(link->service, kStreamIn);
    link->out = FindCharacteristic(link->service, kStreamOut);
    if (!link->in || !link->out) {
      link->service.Close();
      link->device.Close();
      return DialOutcome::kNoStream;
    }
    link->session = link->service.Session();
    link->session.MaintainConnection(true);

    const gatt::GattCharacteristic in = link->in;
    const gatt::GattSession session = link->session;
    auto stream = std::make_shared<GattStream>(
        device,
        [in](const uint8_t* data, size_t size) {
          try {
            return in.WriteValueAsync(local_links::ToBuffer(data, size),
                                      gatt::GattWriteOption::WriteWithResponse)
                       .get() == gatt::GattCommunicationStatus::Success;
          } catch (...) {
            return false;
          }
        },
        [session]() -> size_t {
          const uint16_t pdu = session.MaxPduSize();
          return pdu > 3 ? static_cast<size_t>(pdu - 3) : 0;
        });
    const std::string stream_id = stream->id();
    {
      std::lock_guard<std::mutex> lock(mutex_);
      streams_[stream_id] = stream;
    }
    stream->OnClose([this, link, stream_id]() {
      local_links::RunDetached([link]() { link->Release(); });
      worker_.Post([this, stream_id]() { Forget(stream_id, std::string()); });
    });
    std::weak_ptr<GattStream> weak = stream;
    link->changed = link->out.ValueChanged(
        [weak](const gatt::GattCharacteristic&,
               const gatt::GattValueChangedEventArgs& args) {
          auto target = weak.lock();
          if (!target) {
            return;
          }
          const std::vector<uint8_t> bytes =
              local_links::FromBuffer(args.CharacteristicValue());
          if (bytes.empty()) {
            target->Close();
          } else {
            target->Received(bytes);
          }
        });
    link->status = link->device.ConnectionStatusChanged(
        [weak](const bt::BluetoothLEDevice& changed, const wf::IInspectable&) {
          if (changed.ConnectionStatus() ==
              bt::BluetoothConnectionStatus::Disconnected) {
            if (auto target = weak.lock()) {
              target->Close();
            }
          }
        });
    const auto subscribed =
        link->out
            .WriteClientCharacteristicConfigurationDescriptorAsync(
                gatt::GattClientCharacteristicConfigurationDescriptorValue::Notify)
            .get();
    if (subscribed != gatt::GattCommunicationStatus::Success ||
        !stream->Pump(port, token)) {
      stream->Close();
      return DialOutcome::kFailed;
    }
    return DialOutcome::kConnected;
  }

  local_links::Worker worker_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  // The platform thread only.
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;

  // The worker only.
  bt::BluetoothAdapter adapter_{nullptr};
  radios::Radio radio_{nullptr};
  winrt::event_token radio_token_{};
  bool peripheral_ = false;
  gatt::GattServiceProvider provider_{nullptr};
  ble::BluetoothLEAdvertisementWatcher watcher_{nullptr};
  uint64_t scan_gen_ = 0;
  uint64_t advert_gen_ = 0;
  bool advert_window_ = false;
  bool gatt_busy_ = false;
  size_t dials_ = 0;
  std::map<std::string, Clock::time_point> reported_;
  std::map<std::string, Clock::time_point> zen_seen_;
  std::map<std::string, Clock::time_point> gatt_read_;
  std::map<std::string, Clock::time_point> no_stream_;
  std::map<std::string, bt::BluetoothAddressType> types_;
  std::set<std::string> pending_reads_;

  // Read on WinRT's threads too.
  std::atomic<bool> running_{false};
  std::mutex mutex_;
  std::vector<uint8_t> advert_;
  gatt::GattLocalCharacteristic out_char_{nullptr};
  // Streams by id, the server's by client device, the ones waiting for
  // Dart by incoming id.
  std::map<std::string, std::shared_ptr<GattStream>> streams_;
  std::map<std::string, std::shared_ptr<GattStream>> server_;
  std::map<std::string, std::shared_ptr<GattStream>> incoming_;
};

}  // namespace

void Register(flutter::BinaryMessenger* messenger) {
  // Lives as long as the process (WinRT callbacks may still come at exit).
  static Bridge* bridge = new Bridge();
  bridge->Register(messenger);
}

}  // namespace bluetooth_le_bridge
