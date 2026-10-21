// clang-format off
#include <winsock2.h>
#include <windows.h>
#include <iphlpapi.h>
#include <wlanapi.h>
// clang-format on

#include "wifi_direct_bridge.h"

#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Enumeration.h>
#include <winrt/Windows.Devices.Radios.h>
#include <winrt/Windows.Devices.WiFiDirect.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.h>

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cwctype>
#include <functional>
#include <iterator>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include "local_links_common.h"

// How it maps onto wifi_direct_local_link.dart:
//  - the "service record" is a vendor information element (OUI 5A:45:4E,
//    locally administered, type 0x4C) on the Wi-Fi Direct advertisement:
//    a flags byte, the group token (8 bytes) while this computer takes
//    friends in, then the bridge's advert;
//  - "createGroup" takes friends in from now on and publishes the token as
//    the group's name; "joinGroup" connects to the computer that published
//    that name (WiFiDirectDevice, pairing by push button accepted here, no
//    system prompt); the connection forms the Wi-Fi Direct group. Pairings
//    made here are removed again when the connection ends;
//  - "removeGroup" ends the connections and stops taking friends in;
//  - "keepClients" (the group's owner): Dart names the IPs its friends
//    linked from (the pair handshake succeeded over the group); a client
//    connected for longer than the grace time without one is let go, and
//    its device is refused for a while.
// Anyone nearby may read the token and connect, but stays only until the
// grace time is over: the bridge links only devices that prove a pair
// secret. Discovery runs only in Dart's windows; the advertisement only
// while Zen runs the link and the computer is not on a Wi-Fi network.
namespace wifi_direct_bridge {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using Clock = std::chrono::steady_clock;
using MethodResult = flutter::MethodResult<EncodableValue>;
namespace wf = winrt::Windows::Foundation;
namespace wfd = winrt::Windows::Devices::WiFiDirect;
namespace enumeration = winrt::Windows::Devices::Enumeration;
namespace radios = winrt::Windows::Devices::Radios;

constexpr uint8_t kOui[3] = {0x5A, 0x45, 0x4E};
constexpr uint8_t kOuiType = 0x4C;
constexpr uint8_t kTakesFriends = 0x01;
constexpr size_t kGroupTokenBytes = 8;
constexpr size_t kMinAdvert = 7 + 8;
// An information element holds 251 bytes after its OUI and type.
constexpr size_t kMaxAdvert = 251 - 1 - kGroupTokenBytes;
constexpr size_t kMaxClients = 4;
constexpr size_t kMaxDevices = 256;
constexpr int16_t kOwnerIntent = 14;
constexpr int16_t kJoinIntent = 1;
constexpr auto kPeerEvery = std::chrono::seconds(3);
constexpr auto kConnectWait = std::chrono::seconds(45);
constexpr auto kProbeWait = std::chrono::seconds(3);
// A client let go for making no link is not accepted again for this long.
constexpr auto kRefuseFor = std::chrono::minutes(10);
constexpr size_t kMaxRefused = 64;
constexpr wchar_t kElementsProperty[] =
    L"System.Devices.WiFiDirect.InformationElements";

EncodableValue Text(const std::string& text) { return EncodableValue(text); }

std::string Lower(std::string text) {
  for (char& c : text) {
    c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
  }
  return text;
}

std::string GuidText(const GUID& guid) {
  wchar_t text[64] = {};
  const int length = StringFromGUID2(guid, text, 64);
  std::string out;
  for (int i = 0; i + 1 < length; i++) {
    out.push_back(static_cast<char>(std::towlower(text[i])));
  }
  return out;
}

// --- The normal Wi-Fi (WLAN API) ------------------------------------------

// The WLAN station interfaces ("{guid}", lower case).
std::set<std::string> StationGuids() {
  std::set<std::string> out;
  HANDLE handle = nullptr;
  DWORD version = 0;
  if (WlanOpenHandle(2, nullptr, &version, &handle) != ERROR_SUCCESS) {
    return out;
  }
  PWLAN_INTERFACE_INFO_LIST list = nullptr;
  if (WlanEnumInterfaces(handle, nullptr, &list) == ERROR_SUCCESS && list) {
    for (DWORD i = 0; i < list->dwNumberOfItems; i++) {
      out.insert(GuidText(list->InterfaceInfo[i].InterfaceGuid));
    }
    WlanFreeMemory(list);
  }
  WlanCloseHandle(handle, nullptr);
  return out;
}

// Connected to a Wi-Fi network (a "DIRECT-" one is a Wi-Fi Direct group or
// a printer, not a network).
bool StationConnected() {
  HANDLE handle = nullptr;
  DWORD version = 0;
  if (WlanOpenHandle(2, nullptr, &version, &handle) != ERROR_SUCCESS) {
    return false;
  }
  bool connected = false;
  PWLAN_INTERFACE_INFO_LIST list = nullptr;
  if (WlanEnumInterfaces(handle, nullptr, &list) == ERROR_SUCCESS && list) {
    for (DWORD i = 0; i < list->dwNumberOfItems && !connected; i++) {
      const WLAN_INTERFACE_INFO& info = list->InterfaceInfo[i];
      if (info.isState != wlan_interface_state_connected) {
        continue;
      }
      PWLAN_CONNECTION_ATTRIBUTES attributes = nullptr;
      DWORD size = 0;
      if (WlanQueryInterface(handle, &info.InterfaceGuid,
                             wlan_intf_opcode_current_connection, nullptr,
                             &size, reinterpret_cast<PVOID*>(&attributes),
                             nullptr) == ERROR_SUCCESS &&
          attributes) {
        const DOT11_SSID& ssid = attributes->wlanAssociationAttributes.dot11Ssid;
        const std::string name(
            reinterpret_cast<const char*>(ssid.ucSSID),
            std::min<size_t>(ssid.uSSIDLength, DOT11_SSID_MAX_LENGTH));
        connected = name.rfind("DIRECT-", 0) != 0;
        WlanFreeMemory(attributes);
      } else {
        connected = true;
      }
    }
    WlanFreeMemory(list);
  }
  WlanCloseHandle(handle, nullptr);
  return connected;
}

// Windows runs Wi-Fi Direct on virtual 802.11 adapters ("Microsoft Wi-Fi
// Direct Virtual Adapter") next to the station; a driver that cannot run
// both at once has none. Told apart by type, not by (localized) name.
bool HasVirtualWifiAdapter() {
  const std::set<std::string> stations = StationGuids();
  if (stations.empty()) {
    return false;
  }
  ULONG size = 16 * 1024;
  std::vector<uint8_t> buffer;
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW;
       attempt++) {
    buffer.resize(size);
    status = GetAdaptersAddresses(
        AF_UNSPEC,
        GAA_FLAG_SKIP_UNICAST | GAA_FLAG_SKIP_ANYCAST |
            GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
        nullptr, reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data()), &size);
  }
  if (status != NO_ERROR) {
    return false;
  }
  for (auto* adapter = reinterpret_cast<PIP_ADAPTER_ADDRESSES>(buffer.data());
       adapter; adapter = adapter->Next) {
    if (adapter->IfType == IF_TYPE_IEEE80211 && adapter->AdapterName &&
        stations.count(Lower(adapter->AdapterName)) == 0) {
      return true;
    }
  }
  return false;
}

bool WifiRadioOn() {
  try {
    for (const auto& radio : radios::Radio::GetRadiosAsync().get()) {
      if (radio.Kind() == radios::RadioKind::WiFi &&
          radio.State() == radios::RadioState::On) {
        return true;
      }
    }
  } catch (...) {
  }
  return false;
}

// --- Pairing and connecting (blocking: detached threads) ------------------

// Pairs by push button, accepted here: no PIN, no system prompt.
bool Pair(const enumeration::DeviceInformationPairing& pairing,
          int16_t intent) {
  wfd::WiFiDirectConnectionParameters parameters;
  parameters.GroupOwnerIntent(intent);
  parameters.PreferenceOrderedConfigurationMethods().Append(
      wfd::WiFiDirectConfigurationMethod::PushButton);
  auto custom = pairing.Custom();
  const auto token = custom.PairingRequested(
      [](const enumeration::DeviceInformationCustomPairing&,
         const enumeration::DevicePairingRequestedEventArgs& args) {
        if (args.PairingKind() == enumeration::DevicePairingKinds::ConfirmOnly) {
          args.Accept();
        }
      });
  bool paired = false;
  try {
    auto operation = custom.PairAsync(
        enumeration::DevicePairingKinds::ConfirmOnly,
        enumeration::DevicePairingProtectionLevel::Default, parameters);
    if (operation.wait_for(kConnectWait) == wf::AsyncStatus::Completed) {
      const auto status = operation.GetResults().Status();
      paired = status == enumeration::DevicePairingResultStatus::Paired ||
               status == enumeration::DevicePairingResultStatus::AlreadyPaired;
    } else {
      operation.Cancel();
    }
  } catch (...) {
  }
  custom.PairingRequested(token);
  return paired;
}

void Unpair(const enumeration::DeviceInformation& info) {
  local_links::RunDetached([info]() { info.Pairing().UnpairAsync().get(); });
}

wfd::WiFiDirectDevice WaitForDevice(
    const wf::IAsyncOperation<wfd::WiFiDirectDevice>& operation) {
  if (operation.wait_for(kConnectWait) == wf::AsyncStatus::Completed) {
    return operation.GetResults();
  }
  operation.Cancel();
  return nullptr;
}

void Decline(const wfd::WiFiDirectConnectionRequest& request) {
  try {
    request.Close();
  } catch (...) {
  }
}

struct Accepted {
  std::string id;
  enumeration::DeviceInformation info{nullptr};
  bool paired_here = false;
  wfd::WiFiDirectDevice device{nullptr};
};

Accepted AcceptRequest(const wfd::WiFiDirectConnectionRequest& request) {
  Accepted accepted;
  try {
    auto info = request.DeviceInformation();
    accepted.id = winrt::to_string(info.Id());
    accepted.info = info;
    if (!info.Pairing().IsPaired()) {
      if (!Pair(info.Pairing(), kOwnerIntent)) {
        Decline(request);
        return accepted;
      }
      accepted.paired_here = true;
    }
    accepted.device = WaitForDevice(wfd::WiFiDirectDevice::FromIdAsync(info.Id()));
  } catch (...) {
    accepted.device = nullptr;
  }
  Decline(request);
  return accepted;
}

// |info| as the discovery found it (an association endpoint).
Accepted ConnectTo(const enumeration::DeviceInformation& info) {
  Accepted connected;
  connected.id = winrt::to_string(info.Id());
  connected.info = info;
  try {
    if (!info.Pairing().IsPaired()) {
      if (!Pair(info.Pairing(), kJoinIntent)) {
        return connected;
      }
      connected.paired_here = true;
    }
    wfd::WiFiDirectConnectionParameters parameters;
    parameters.GroupOwnerIntent(kJoinIntent);
    connected.device =
        WaitForDevice(wfd::WiFiDirectDevice::FromIdAsync(info.Id(), parameters));
  } catch (...) {
    connected.device = nullptr;
  }
  return connected;
}

// The other side's IPs of a connection (empty until it has them).
std::set<std::string> RemoteIps(const wfd::WiFiDirectDevice& device) {
  std::set<std::string> out;
  try {
    for (const auto& pair : device.GetConnectionEndpointPairs()) {
      if (pair.RemoteHostName()) {
        out.insert(Lower(winrt::to_string(pair.RemoteHostName().CanonicalName())));
      }
    }
  } catch (...) {
  }
  return out;
}

struct PeerRecord {
  std::vector<uint8_t> advert;
  std::string token;  // hex; empty unless it takes friends in
};

std::optional<PeerRecord> ParseRecord(const enumeration::DeviceInformation& info) {
  wf::Collections::IVector<wfd::WiFiDirectInformationElement> elements{nullptr};
  try {
    elements = wfd::WiFiDirectInformationElement::CreateFromDeviceInformation(info);
  } catch (...) {
    return std::nullopt;
  }
  if (!elements) {
    return std::nullopt;
  }
  for (const auto& element : elements) {
    if (element.OuiType() != kOuiType) {
      continue;
    }
    const std::vector<uint8_t> oui = local_links::FromBuffer(element.Oui());
    if (oui.size() != sizeof(kOui) || !std::equal(oui.begin(), oui.end(), kOui)) {
      continue;
    }
    const std::vector<uint8_t> value = local_links::FromBuffer(element.Value());
    if (value.empty()) {
      continue;
    }
    PeerRecord record;
    size_t offset = 1;
    if (value[0] & kTakesFriends) {
      if (value.size() < 1 + kGroupTokenBytes) {
        continue;
      }
      record.token = local_links::Hex(value.data() + 1, kGroupTokenBytes);
      offset += kGroupTokenBytes;
    }
    record.advert.assign(value.begin() + static_cast<std::ptrdiff_t>(offset),
                         value.end());
    if (record.advert.size() < kMinAdvert) {
      continue;
    }
    return record;
  }
  return std::nullopt;
}

class Bridge {
 public:
  void Register(flutter::BinaryMessenger* messenger) {
    local_links::InitPlatformThread();
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        messenger, "zen/wifi_direct",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<EncodableValue>& call,
               std::unique_ptr<MethodResult> result) {
          HandleCall(call, std::shared_ptr<MethodResult>(std::move(result)));
        });
    events_ = std::make_unique<flutter::EventChannel<EncodableValue>>(
        messenger, "zen/wifi_direct/events",
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
  struct Connection {
    std::string id;
    enumeration::DeviceInformation info{nullptr};
    wfd::WiFiDirectDevice device{nullptr};
    winrt::event_token status{};
    bool paired_here = false;
    Clock::time_point since{};
  };

  struct Peer {
    enumeration::DeviceInformation info{nullptr};
    std::string token;
    Clock::time_point reported{};
  };

  // --- Channels (platform thread) ------------------------------------------

  void HandleCall(const flutter::MethodCall<EncodableValue>& call,
                  std::shared_ptr<MethodResult> result) {
    const std::string& method = call.method_name();
    const EncodableValue* args = call.arguments();
    if (method == "requestPermissions") {
      result->Success(EncodableValue(true));
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
    } else if (method == "setAdvert") {
      auto advert = local_links::Unhex(local_links::ArgString(args, "advert"),
                                       kMaxAdvert);
      if (!advert || advert->size() < kMinAdvert) {
        result->Success(EncodableValue(false));
        return;
      }
      Answer(result, EncodableValue(false),
             [this, advert]() { return EncodableValue(SetAdvert(*advert)); });
    } else if (method == "discover") {
      const int window = static_cast<int>(std::clamp<int64_t>(
          local_links::ArgInt(args, "windowMs", 20000), 1000, 60000));
      Answer(result, EncodableValue(false),
             [this, window]() { return EncodableValue(Discover(window)); });
    } else if (method == "createGroup") {
      Answer(result, EncodableValue(false),
             [this]() { return EncodableValue(CreateGroup()); });
    } else if (method == "joinGroup") {
      const std::string name = local_links::ArgString(args, "name");
      worker_.Post([this, name, result]() { JoinGroup(name, result); });
    } else if (method == "removeGroup") {
      Answer(result, EncodableValue(false),
             [this]() { return EncodableValue(RemoveGroup()); });
    } else if (method == "keepClients") {
      std::set<std::string> linked;
      if (const auto* list = std::get_if<flutter::EncodableList>(
              local_links::Arg(args, "ips"))) {
        for (const auto& item : *list) {
          if (const auto* ip = std::get_if<std::string>(&item)) {
            linked.insert(Lower(*ip));
          }
        }
      }
      const auto grace = std::chrono::milliseconds(std::clamp<int64_t>(
          local_links::ArgInt(args, "graceMs", 60000), 5000, 600000));
      Answer(result, EncodableValue(), [this, linked, grace]() {
        KeepClients(linked, grace);
        return EncodableValue();
      });
    } else {
      result->NotImplemented();
    }
  }

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
    if (!running_) {
      return;
    }
    local_links::RunOnPlatformThread([this, event]() {
      if (sink_) {
        sink_->Success(EncodableValue(event));
      }
    });
  }

  // --- State (worker) --------------------------------------------------------

  bool Supported() {
    if (supported_) {
      return true;
    }
    // A driver without the virtual adapter: silently off.
    if (!HasVirtualWifiAdapter()) {
      return false;
    }
    supported_ = Probe();
    return supported_;
  }

  // Whether a Wi-Fi Direct advertisement starts at all (not discoverable).
  static bool Probe() {
    wfd::WiFiDirectAdvertisementPublisher publisher;
    publisher.Advertisement().ListenStateDiscoverability(
        wfd::WiFiDirectAdvertisementListenStateDiscoverability::None);
    bool started = false;
    try {
      publisher.Start();
      const auto until = Clock::now() + kProbeWait;
      while (Clock::now() < until) {
        const auto status = publisher.Status();
        if (status == wfd::WiFiDirectAdvertisementPublisherStatus::Started) {
          started = true;
          break;
        }
        if (status == wfd::WiFiDirectAdvertisementPublisherStatus::Aborted ||
            status == wfd::WiFiDirectAdvertisementPublisherStatus::Stopped) {
          break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
      }
    } catch (...) {
    }
    try {
      publisher.Stop();
    } catch (...) {
    }
    return started;
  }

  EncodableMap State() {
    const bool supported = Supported();
    return EncodableMap{
        {Text("supported"), EncodableValue(supported)},
        {Text("permitted"), EncodableValue(true)},
        {Text("enabled"), EncodableValue(supported && WifiRadioOn())},
        {Text("wifi"), EncodableValue(running_ ? wifi_ : StationConnected())},
        {Text("group"), GroupValue()},
    };
  }

  EncodableValue GroupValue() const {
    if (open_) {
      const std::string name = local_links::Hex(token_);
      return EncodableValue(EncodableMap{
          {Text("owner"), EncodableValue(true)},
          {Text("name"), Text(name)},
          {Text("passphrase"), Text(name)},
          {Text("clients"), EncodableValue(static_cast<int>(connections_.size()))},
          // Clients without a friend's link are let go ("keepClients").
          {Text("checks"), EncodableValue(true)},
      });
    }
    if (!joined_.empty() && !connections_.empty()) {
      return EncodableValue(EncodableMap{
          {Text("owner"), EncodableValue(false)},
          {Text("name"), Text(joined_)},
          {Text("passphrase"), EncodableValue()},
          {Text("clients"), EncodableValue(0)},
      });
    }
    return EncodableValue();
  }

  void EmitGroup() {
    Emit(EncodableMap{{Text("type"), Text("group")}, {Text("group"), GroupValue()}});
  }

  // --- Running ---------------------------------------------------------------

  bool Start() {
    if (running_) {
      return true;
    }
    if (!Supported()) {
      return false;
    }
    running_ = true;
    listener_ = wfd::WiFiDirectConnectionListener();
    listener_token_ = listener_.ConnectionRequested(
        [this](const wfd::WiFiDirectConnectionListener&,
               const wfd::WiFiDirectConnectionRequestedEventArgs& args) {
          wfd::WiFiDirectConnectionRequest request{nullptr};
          try {
            request = args.GetConnectionRequest();
          } catch (...) {
            return;
          }
          worker_.Post([this, request]() { OnConnectionRequested(request); });
        });
    WatchWlan();
    wifi_ = StationConnected();
    return true;
  }

  void Stop() {
    running_ = false;
    StopDiscovery();
    StopPublisher();
    if (listener_) {
      try {
        listener_.ConnectionRequested(listener_token_);
      } catch (...) {
      }
      listener_ = nullptr;
    }
    CloseAll();
    open_ = false;
    token_.clear();
    joined_.clear();
    peers_.clear();
    devices_.clear();
    refused_.clear();
    advert_.clear();
    UnwatchWlan();
  }

  void WatchWlan() {
    if (wlan_) {
      return;
    }
    HANDLE handle = nullptr;
    DWORD version = 0;
    if (WlanOpenHandle(2, nullptr, &version, &handle) != ERROR_SUCCESS) {
      return;
    }
    if (WlanRegisterNotification(handle, WLAN_NOTIFICATION_SOURCE_ACM, TRUE,
                                 &Bridge::OnWlan, this, nullptr,
                                 nullptr) != ERROR_SUCCESS) {
      WlanCloseHandle(handle, nullptr);
      return;
    }
    wlan_ = handle;
  }

  void UnwatchWlan() {
    if (!wlan_) {
      return;
    }
    WlanRegisterNotification(wlan_, WLAN_NOTIFICATION_SOURCE_NONE, TRUE,
                             nullptr, nullptr, nullptr, nullptr);
    WlanCloseHandle(wlan_, nullptr);
    wlan_ = nullptr;
  }

  static VOID WINAPI OnWlan(PWLAN_NOTIFICATION_DATA data, PVOID context) {
    if (!data || data->NotificationSource != WLAN_NOTIFICATION_SOURCE_ACM) {
      return;
    }
    const DWORD code = data->NotificationCode;
    if (code == static_cast<DWORD>(wlan_notification_acm_connection_complete) ||
        code == static_cast<DWORD>(wlan_notification_acm_disconnected)) {
      auto* bridge = static_cast<Bridge*>(context);
      bridge->worker_.Post([bridge]() { bridge->CheckWifi(); });
    }
  }

  // On a Wi-Fi network everything stops: the normal Wi-Fi comes first.
  void CheckWifi() {
    if (!running_) {
      return;
    }
    const bool connected = StationConnected();
    if (connected == wifi_) {
      return;
    }
    wifi_ = connected;
    if (wifi_) {
      StopDiscovery();
      StopPublisher();
      CloseAll();
      open_ = false;
      token_.clear();
      joined_.clear();
      EmitGroup();
    } else {
      Publish();
    }
    Emit(EncodableMap{{Text("type"), Text("wifi")},
                      {Text("connected"), EncodableValue(wifi_)}});
  }

  // --- The record ------------------------------------------------------------

  bool SetAdvert(const std::vector<uint8_t>& advert) {
    advert_ = advert;
    Publish();
    return running_ && !wifi_;
  }

  void Publish() {
    StopPublisher();
    if (!running_ || wifi_ || advert_.empty()) {
      return;
    }
    std::vector<uint8_t> value{static_cast<uint8_t>(open_ ? kTakesFriends : 0)};
    if (open_) {
      value.insert(value.end(), token_.begin(), token_.end());
    }
    value.insert(value.end(), advert_.begin(), advert_.end());
    wfd::WiFiDirectInformationElement element;
    element.Oui(local_links::ToBuffer(kOui, sizeof(kOui)));
    element.OuiType(kOuiType);
    element.Value(local_links::ToBuffer(value.data(), value.size()));
    wfd::WiFiDirectAdvertisementPublisher publisher;
    auto advertisement = publisher.Advertisement();
    advertisement.ListenStateDiscoverability(
        wfd::WiFiDirectAdvertisementListenStateDiscoverability::Normal);
    advertisement.InformationElements(
        winrt::single_threaded_vector<wfd::WiFiDirectInformationElement>(
            std::vector<wfd::WiFiDirectInformationElement>{element}));
    publisher.Start();
    publisher_ = publisher;
  }

  void StopPublisher() {
    if (!publisher_) {
      return;
    }
    try {
      publisher_.Stop();
    } catch (...) {
    }
    publisher_ = nullptr;
  }

  // --- Discovery -------------------------------------------------------------

  bool Discover(int window_ms) {
    if (!running_ || wifi_) {
      return false;
    }
    StopDiscovery();
    auto watcher = enumeration::DeviceInformation::CreateWatcher(
        wfd::WiFiDirectDevice::GetDeviceSelector(
            wfd::WiFiDirectDeviceSelectorType::AssociationEndpoint),
        winrt::single_threaded_vector<winrt::hstring>(
            std::vector<winrt::hstring>{winrt::hstring(kElementsProperty)}));
    watcher.Added([this](const enumeration::DeviceWatcher&,
                         const enumeration::DeviceInformation& info) {
      worker_.Post([this, info]() { OnDevice(info); });
    });
    watcher.Updated([this](const enumeration::DeviceWatcher&,
                           const enumeration::DeviceInformationUpdate& update) {
      worker_.Post([this, update]() {
        auto it = devices_.find(winrt::to_string(update.Id()));
        if (it != devices_.end()) {
          it->second.Update(update);
          OnDevice(it->second);
        }
      });
    });
    watcher.Removed([](const enumeration::DeviceWatcher&,
                       const enumeration::DeviceInformationUpdate&) {});
    watcher.EnumerationCompleted(
        [](const enumeration::DeviceWatcher&, const wf::IInspectable&) {});
    watcher.Start();
    watcher_ = watcher;
    const uint64_t generation = ++discover_gen_;
    worker_.PostDelayed(std::chrono::milliseconds(window_ms),
                        [this, generation]() {
                          if (generation == discover_gen_) {
                            StopDiscovery();
                          }
                        });
    return true;
  }

  void StopDiscovery() {
    ++discover_gen_;
    if (!watcher_) {
      return;
    }
    try {
      const auto status = watcher_.Status();
      if (status == enumeration::DeviceWatcherStatus::Started ||
          status == enumeration::DeviceWatcherStatus::EnumerationCompleted) {
        watcher_.Stop();
      }
    } catch (...) {
    }
    watcher_ = nullptr;
  }

  void OnDevice(const enumeration::DeviceInformation& info) {
    if (!running_ || wifi_) {
      return;
    }
    const std::string id = winrt::to_string(info.Id());
    if (devices_.size() >= kMaxDevices && devices_.count(id) == 0) {
      devices_.clear();
      peers_.clear();
    }
    devices_.insert_or_assign(id, info);
    const std::optional<PeerRecord> record = ParseRecord(info);
    if (!record) {
      return;
    }
    Peer& peer = peers_[id];
    peer.info = info;
    peer.token = record->token;
    const Clock::time_point now = Clock::now();
    if (now - peer.reported < kPeerEvery) {
      return;
    }
    peer.reported = now;
    const bool offers = !record->token.empty();
    Emit(EncodableMap{
        {Text("type"), Text("peer")},
        {Text("device"), Text(id)},
        {Text("advert"), Text(local_links::Hex(record->advert))},
        {Text("name"), offers ? Text(record->token) : EncodableValue()},
        {Text("passphrase"), offers ? Text(record->token) : EncodableValue()},
    });
  }

  // --- Groups ----------------------------------------------------------------

  bool CreateGroup() {
    if (!running_ || wifi_) {
      return false;
    }
    if (!open_) {
      open_ = true;
      token_ = local_links::RandomBytes(kGroupTokenBytes);
    }
    Publish();
    EmitGroup();
    return true;
  }

  bool RemoveGroup() {
    CloseAll();
    open_ = false;
    token_.clear();
    joined_.clear();
    Publish();
    EmitGroup();
    return true;
  }

  void OnConnectionRequested(const wfd::WiFiDirectConnectionRequest& request) {
    if (!running_ || wifi_ || !open_ ||
        connections_.size() + accepting_ >= kMaxClients || Refused(request)) {
      Decline(request);
      return;
    }
    accepting_++;
    local_links::RunDetached([this, request]() {
      const Accepted accepted = AcceptRequest(request);
      worker_.Post([this, accepted]() {
        accepting_--;
        if (!accepted.device || !running_ || wifi_ || !open_) {
          Release(accepted.info, accepted.device, accepted.paired_here);
          return;
        }
        AddConnection(accepted);
      });
    });
  }

  void JoinGroup(const std::string& name, std::shared_ptr<MethodResult> result) {
    enumeration::DeviceInformation info{nullptr};
    for (const auto& entry : peers_) {
      if (!name.empty() && entry.second.token == name) {
        info = entry.second.info;
        break;
      }
    }
    if (!running_ || wifi_ || !info || joining_ || !connections_.empty()) {
      Reply(result, EncodableValue(false));
      return;
    }
    joining_ = true;
    local_links::RunDetached([this, info, name, result]() {
      const Accepted connected = ConnectTo(info);
      worker_.Post([this, connected, name, result]() {
        joining_ = false;
        if (!connected.device || !running_ || wifi_) {
          Release(connected.info, connected.device, connected.paired_here);
          Reply(result, EncodableValue(false));
          return;
        }
        joined_ = name;
        AddConnection(connected);
        Reply(result, EncodableValue(connections_.count(connected.id) > 0));
      });
    });
  }

  // Whether the device asking was let go without a link a while ago.
  bool Refused(const wfd::WiFiDirectConnectionRequest& request) {
    const Clock::time_point now = Clock::now();
    for (auto it = refused_.begin(); it != refused_.end();) {
      it = it->second <= now ? refused_.erase(it) : std::next(it);
    }
    try {
      return refused_.count(winrt::to_string(request.DeviceInformation().Id())) >
             0;
    } catch (...) {
      return true;
    }
  }

  // The owner lets go of clients connected for at least |grace| that made no
  // link from any of their IPs: only the pair handshake shows a friend.
  void KeepClients(const std::set<std::string>& linked,
                   std::chrono::milliseconds grace) {
    if (!open_) {
      return;
    }
    const Clock::time_point now = Clock::now();
    std::vector<std::string> strangers;
    for (const auto& entry : connections_) {
      if (now - entry.second.since < grace) {
        continue;
      }
      const std::set<std::string> ips = RemoteIps(entry.second.device);
      const bool friendly = std::any_of(
          ips.begin(), ips.end(),
          [&linked](const std::string& ip) { return linked.count(ip) > 0; });
      if (!friendly) {
        strangers.push_back(entry.first);
      }
    }
    for (const std::string& id : strangers) {
      if (refused_.size() >= kMaxRefused) {
        refused_.erase(refused_.begin());
      }
      refused_[id] = now + kRefuseFor;
      Drop(id);
    }
  }

  void AddConnection(const Accepted& accepted) {
    auto previous = connections_.find(accepted.id);
    if (previous != connections_.end()) {
      Close(previous->second);
      connections_.erase(previous);
    }
    Connection connection;
    connection.id = accepted.id;
    connection.info = accepted.info;
    connection.device = accepted.device;
    connection.paired_here = accepted.paired_here;
    connection.since = Clock::now();
    const std::string id = accepted.id;
    connection.status = accepted.device.ConnectionStatusChanged(
        [this, id](const wfd::WiFiDirectDevice& changed, const wf::IInspectable&) {
          if (changed.ConnectionStatus() ==
              wfd::WiFiDirectConnectionStatus::Disconnected) {
            worker_.Post([this, id]() { Drop(id); });
          }
        });
    connections_[id] = connection;
    if (accepted.device.ConnectionStatus() ==
        wfd::WiFiDirectConnectionStatus::Disconnected) {
      Drop(id);
      return;
    }
    EmitGroup();
  }

  void Drop(const std::string& id) {
    auto it = connections_.find(id);
    if (it == connections_.end()) {
      return;
    }
    Close(it->second);
    connections_.erase(it);
    if (connections_.empty()) {
      joined_.clear();
    }
    EmitGroup();
  }

  void CloseAll() {
    for (auto& entry : connections_) {
      Close(entry.second);
    }
    connections_.clear();
  }

  static void Close(Connection& connection) {
    try {
      connection.device.ConnectionStatusChanged(connection.status);
    } catch (...) {
    }
    Release(connection.info, connection.device, connection.paired_here);
    connection.device = nullptr;
  }

  // Ends a connection and removes a pairing made for it.
  static void Release(const enumeration::DeviceInformation& info,
                      const wfd::WiFiDirectDevice& device, bool paired_here) {
    if (device) {
      try {
        device.Close();
      } catch (...) {
      }
    }
    if (paired_here && info) {
      Unpair(info);
    }
  }

  local_links::Worker worker_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
  std::unique_ptr<flutter::EventChannel<EncodableValue>> events_;
  // The platform thread only.
  std::unique_ptr<flutter::EventSink<EncodableValue>> sink_;

  // The worker only (running_ is read by Emit on it too).
  bool running_ = false;
  bool supported_ = false;
  bool wifi_ = false;
  std::vector<uint8_t> advert_;
  bool open_ = false;
  std::vector<uint8_t> token_;
  std::string joined_;
  bool joining_ = false;
  size_t accepting_ = 0;
  HANDLE wlan_ = nullptr;
  uint64_t discover_gen_ = 0;
  wfd::WiFiDirectAdvertisementPublisher publisher_{nullptr};
  wfd::WiFiDirectConnectionListener listener_{nullptr};
  winrt::event_token listener_token_{};
  enumeration::DeviceWatcher watcher_{nullptr};
  std::map<std::string, enumeration::DeviceInformation> devices_;
  std::map<std::string, Peer> peers_;
  std::map<std::string, Connection> connections_;
  // Devices let go without a link → until when they are refused.
  std::map<std::string, Clock::time_point> refused_;
};

}  // namespace

void Register(flutter::BinaryMessenger* messenger) {
  // Lives as long as the process (WinRT and WLAN callbacks may still come).
  static Bridge* bridge = new Bridge();
  bridge->Register(messenger);
}

}  // namespace wifi_direct_bridge
