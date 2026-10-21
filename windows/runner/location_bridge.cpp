// clang-format off
#include <windows.h>
// clang-format on

#include "location_bridge.h"

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <winrt/Windows.Devices.Geolocation.h>
#include <winrt/Windows.Foundation.h>

#include <algorithm>
#include <chrono>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>

#include "local_links_common.h"

namespace location_bridge {
namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;
using MethodResult = flutter::MethodResult<EncodableValue>;
namespace geo = winrt::Windows::Devices::Geolocation;

constexpr int64_t kDefaultTimeoutMs = 12000;
constexpr int64_t kMinTimeoutMs = 1000;
constexpr int64_t kMaxTimeoutMs = 120000;

std::unique_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

std::string StatusName(geo::GeolocationAccessStatus status) {
  switch (status) {
    case geo::GeolocationAccessStatus::Allowed:
      return "whileInUse";
    case geo::GeolocationAccessStatus::Denied:
      return "denied";
    default:
      return "deniedForever";
  }
}

EncodableValue ToMap(const geo::Geoposition& position) {
  const geo::Geocoordinate coordinate = position.Coordinate();
  const geo::BasicGeoposition point = coordinate.Point().Position();
  const int64_t at = std::chrono::duration_cast<std::chrono::milliseconds>(
                         winrt::clock::to_sys(coordinate.Timestamp())
                             .time_since_epoch())
                         .count();
  return EncodableValue(EncodableMap{
      {EncodableValue("lat"), EncodableValue(point.Latitude)},
      {EncodableValue("lon"), EncodableValue(point.Longitude)},
      {EncodableValue("accuracy"), EncodableValue(coordinate.Accuracy())},
      {EncodableValue("at"), EncodableValue(at)},
  });
}

// Results go back on the platform thread; the WinRT calls block, so they
// run on a thread of their own in the multi-threaded apartment.
void Reply(std::shared_ptr<MethodResult> result, EncodableValue value) {
  local_links::RunOnPlatformThread(
      [result, value = std::move(value)]() { result->Success(value); });
}

void Fail(std::shared_ptr<MethodResult> result, std::string code,
          std::string message) {
  local_links::RunOnPlatformThread(
      [result, code = std::move(code), message = std::move(message)]() {
        result->Error(code, message);
      });
}

bool Allowed() {
  return geo::Geolocator::RequestAccessAsync().get() ==
         geo::GeolocationAccessStatus::Allowed;
}

void Handle(const flutter::MethodCall<EncodableValue>& call,
            std::shared_ptr<MethodResult> result) {
  const std::string& method = call.method_name();
  if (method == "check" || method == "request") {
    // Desktop apps get no system question: the settings decide.
    local_links::RunDetached([result]() {
      std::string status = "unableToDetermine";
      try {
        status = StatusName(geo::Geolocator::RequestAccessAsync().get());
      } catch (...) {
      }
      Reply(result, EncodableValue(status));
    });
    return;
  }
  if (method == "serviceEnabled") {
    local_links::RunDetached([result]() {
      bool enabled = false;
      try {
        const geo::PositionStatus status = geo::Geolocator().LocationStatus();
        enabled = status != geo::PositionStatus::Disabled &&
                  status != geo::PositionStatus::NotAvailable;
      } catch (...) {
      }
      Reply(result, EncodableValue(enabled));
    });
    return;
  }
  if (method == "current") {
    const int64_t timeout_ms = std::clamp<int64_t>(
        local_links::ArgInt(call.arguments(), "timeoutMs", kDefaultTimeoutMs),
        kMinTimeoutMs, kMaxTimeoutMs);
    local_links::RunDetached([result, timeout_ms]() {
      try {
        if (!Allowed()) {
          Fail(result, "denied", "No location permission");
          return;
        }
        geo::Geolocator locator;
        locator.DesiredAccuracy(geo::PositionAccuracy::High);
        Reply(result, ToMap(locator
                                .GetGeopositionAsync(
                                    std::chrono::seconds(0),
                                    std::chrono::milliseconds(timeout_ms))
                                .get()));
      } catch (const winrt::hresult_error& error) {
        Fail(result, "unavailable", winrt::to_string(error.message()));
      } catch (...) {
        Fail(result, "unavailable", "No position");
      }
    });
    return;
  }
  if (method == "lastKnown") {
    local_links::RunDetached([result]() {
      try {
        if (!Allowed()) {
          Reply(result, EncodableValue());
          return;
        }
        Reply(result, ToMap(geo::Geolocator()
                                .GetGeopositionAsync(
                                    std::chrono::hours(1),
                                    std::chrono::milliseconds::zero())
                                .get()));
      } catch (...) {
        Reply(result, EncodableValue());
      }
    });
    return;
  }
  result->NotImplemented();
}

}  // namespace

void Register(flutter::BinaryMessenger* messenger) {
  local_links::InitPlatformThread();
  g_channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "zen/location", &flutter::StandardMethodCodec::GetInstance());
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<MethodResult> result) {
        Handle(call, std::shared_ptr<MethodResult>(std::move(result)));
      });
}

}  // namespace location_bridge
