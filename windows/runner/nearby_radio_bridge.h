#ifndef RUNNER_NEARBY_RADIO_BRIDGE_H_
#define RUNNER_NEARBY_RADIO_BRIDGE_H_

#include <flutter/binary_messenger.h>

// "W pobliżu" on Windows: method channel "zen/nearby_le", events on
// "zen/nearby_le/events" (desktop_nearby_radio.dart). Shows Zen's nearby
// advert as manufacturer data of company 0xFFFF (Dart gives the bytes after
// the company id: "ZN", the token, the hint) with a WinRT advertisement
// publisher, and reports the same manufacturer data of devices around from a
// watcher. Calls: state, advertise {data}, stopAdvertising, startScan,
// stopScan. Events: {type: seen, device, data, rssi}, {type: bluetooth, on}.
namespace nearby_radio_bridge {

void Register(flutter::BinaryMessenger* messenger);

}  // namespace nearby_radio_bridge

#endif  // RUNNER_NEARBY_RADIO_BRIDGE_H_
