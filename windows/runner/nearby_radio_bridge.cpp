// clang-format off
#include <winsock2.h>
#include <windows.h>
// clang-format on

#include "nearby_radio_bridge.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Bluetooth.Advertisement.h>
#include <winrt/Windows.Devices.Bluetooth.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>

#include <chrono>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "local_links_common.h"

// Battery: a computer runs on mains or a big battery; the publisher is the
// system's own (low duty), and the watcher runs only while Dart asks (the
// "W pobliżu" screen, the short looks around of nearby_keeper.dart).
namespace nearby_radio_bridge {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Clock = std::chrono::steady_clock;
using MethodResult = flutter::MethodResult<EncodableValue>;
namespace wf = winrt::Windows::Foundation;
namespace bt = winrt::Windows::Devices::Bluetooth;
namespace ble = winrt::Windows::Devices::Bluetooth::Advertisement;
namespace radios = winrt::Windows::Devices::Radios;

constexpr uint16_t kCompanyId = 0xFFFF;
constexpr uint8_t kMagic[2] = {0x5A, 0x4E};
// "ZN", the 16-byte token, the 4-byte hint.
constexpr size_t kAdvertBytes = 2 + 16 + 4;
// A device's advert reported at most this often.
constexpr auto kReportEvery = std::chrono::milliseconds(1000);
constexpr size_t kMaxReported = 512;

EncodableValue Text(const char* text) { return EncodableValue(std::string(text)); }

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

class Bridge {
 public:
  void Register(flutter::BinaryMessenger* messenger) {
    local_links::InitPlatformThread();
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "zen/nearby_le",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult> result) {
          HandleCall(call, std::shared_ptr<MethodResult>(std::move(result)));
        });
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "zen/nearby_le/events",
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
  void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                  std::shared_ptr<MethodResult> result) {
    const std::string& method = call.method_name();
    const EncodableValue* args = call.arguments();
    if (method == "state") {
      Answer(result, EncodableValue(EncodableMap()),
             [this]() { return EncodableValue(State()); });
    } else if (method == "advertise") {
      const std::vector<uint8_t> data = local_links::ArgBytes(args, "data");
      if (data.size() != kAdvertBytes || data[0] != kMagic[0] ||
          data[1] != kMagic[1]) {
        result->Success(EncodableValue(false));
        return;
      }
      Answer(result, EncodableValue(false),
             [this, data]() { return EncodableValue(Advertise(data)); });
    } else if (method == "stopAdvertising") {
      Answer(result, EncodableValue(), [this]() {
        StopAdvertising();
        return EncodableValue();
      });
    } else if (method == "startScan") {
      Answer(result, EncodableValue(false),
             [this]() { return EncodableValue(StartScan()); });
    } else if (method == "stopScan") {
      Answer(result, EncodableValue(), [this]() {
        StopScan();
        return EncodableValue();
      });
    } else {
      result->NotImplemented();
    }
  }

  // Runs |work| on the worker and answers with what it returns (|fallback|
  // when it throws).
  void Answer(std::shared_ptr<MethodResult> result, EncodableValue fallback,
              std::function<EncodableValue()> work) {
    worker_.Post([result, fallback, work]() {
      EncodableValue value = fallback;
      try {
        value = work();
      } catch (...) {
      }
      local_links::RunOnPlatformThread(
          [result, value]() { result->Success(value); });
    });
  }

  void Emit(EncodableMap event) {
    local_links::RunOnPlatformThread([this, event]() {
      if (sink_) {
        sink_->Success(EncodableValue(event));
      }
    });
  }

  // --- The worker -----------------------------------------------------------

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

  bool RadioOn() { return !radio_ || radio_.State() == radios::RadioState::On; }

  EncodableMap State() {
    bool present = false;
    bool powered = false;
    bool advertise = false;
    try {
      present = Adapter();
      powered = present && RadioOn();
      advertise = present && adapter_.IsPeripheralRoleSupported();
    } catch (...) {
      present = false;
    }
    return EncodableMap{
        {Text("present"), EncodableValue(present)},
        {Text("powered"), EncodableValue(powered)},
        {Text("canAdvertise"), EncodableValue(advertise)},
    };
  }

  void OnRadio(bool on) {
    if (on) {
      // The stack forgot both: shown and looked for again.
      if (!advert_.empty()) {
        try {
          Advertise(advert_);
        } catch (...) {
        }
      }
      if (scanning_) {
        try {
          StartWatcher();
        } catch (...) {
        }
      }
    }
    Emit(EncodableMap{{Text("type"), Text("bluetooth")},
                      {Text("on"), EncodableValue(on)}});
  }

  bool Advertise(const std::vector<uint8_t>& data) {
    advert_ = data;
    if (!Adapter() || !RadioOn() || !adapter_.IsPeripheralRoleSupported()) {
      return false;
    }
    StopPublisher();
    publisher_ = ble::BluetoothLEAdvertisementPublisher();
    ble::BluetoothLEManufacturerData manufacturer;
    manufacturer.CompanyId(kCompanyId);
    manufacturer.Data(local_links::ToBuffer(data.data(), data.size()));
    publisher_.Advertisement().ManufacturerData().Append(manufacturer);
    publisher_.Start();
    return true;
  }

  void StopPublisher() {
    try {
      if (publisher_ &&
          publisher_.Status() ==
              ble::BluetoothLEAdvertisementPublisherStatus::Started) {
        publisher_.Stop();
      }
    } catch (...) {
    }
    publisher_ = nullptr;
  }

  void StopAdvertising() {
    advert_.clear();
    StopPublisher();
  }

  bool StartScan() {
    scanning_ = true;
    if (!Adapter() || !RadioOn()) {
      return false;
    }
    StartWatcher();
    return true;
  }

  void StartWatcher() {
    if (!watcher_ || watcher_.Status() ==
                         ble::BluetoothLEAdvertisementWatcherStatus::Aborted) {
      watcher_ = ble::BluetoothLEAdvertisementWatcher();
      // Passive: Zen's advert is in the advertising packet itself.
      watcher_.ScanningMode(ble::BluetoothLEScanningMode::Passive);
      ble::BluetoothLEManufacturerData filter;
      filter.CompanyId(kCompanyId);
      watcher_.AdvertisementFilter().Advertisement().ManufacturerData().Append(
          filter);
      watcher_.Received(
          [this](const ble::BluetoothLEAdvertisementWatcher&,
                 const ble::BluetoothLEAdvertisementReceivedEventArgs& args) {
            OnReceived(args);
          });
    }
    if (watcher_.Status() != ble::BluetoothLEAdvertisementWatcherStatus::Started) {
      watcher_.Start();
    }
  }

  void StopScan() {
    scanning_ = false;
    try {
      if (watcher_ && watcher_.Status() ==
                          ble::BluetoothLEAdvertisementWatcherStatus::Started) {
        watcher_.Stop();
      }
    } catch (...) {
    }
  }

  // A thread-pool thread: reads the advert and hands it to Dart.
  void OnReceived(const ble::BluetoothLEAdvertisementReceivedEventArgs& args) {
    try {
      const std::string device = AddressText(args.BluetoothAddress());
      const int rssi = static_cast<int>(args.RawSignalStrengthInDBm());
      for (const auto& data :
           args.Advertisement().GetManufacturerDataByCompanyId(kCompanyId)) {
        std::vector<uint8_t> bytes = local_links::FromBuffer(data.Data());
        if (bytes.size() < kAdvertBytes || bytes[0] != kMagic[0] ||
            bytes[1] != kMagic[1]) {
          continue;
        }
        bytes.resize(kAdvertBytes);
        {
          std::lock_guard<std::mutex> lock(mutex_);
          const auto now = Clock::now();
          auto it = reported_.find(device);
          if (it != reported_.end() && now - it->second < kReportEvery) {
            return;
          }
          if (reported_.size() >= kMaxReported) {
            reported_.clear();
          }
          reported_[device] = now;
        }
        Emit(EncodableMap{{Text("type"), Text("seen")},
                          {Text("device"), EncodableValue(device)},
                          {Text("data"), EncodableValue(bytes)},
                          {Text("rssi"), EncodableValue(rssi)}});
        return;
      }
    } catch (...) {
    }
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
  ble::BluetoothLEAdvertisementPublisher publisher_{nullptr};
  ble::BluetoothLEAdvertisementWatcher watcher_{nullptr};
  std::vector<uint8_t> advert_;
  bool scanning_ = false;

  // WinRT's threads.
  std::mutex mutex_;
  std::map<std::string, Clock::time_point> reported_;
};

}  // namespace

void Register(flutter::BinaryMessenger* messenger) {
  // Lives as long as the process (WinRT callbacks may still come at exit).
  static Bridge* bridge = new Bridge();
  bridge->Register(messenger);
}

}  // namespace nearby_radio_bridge
