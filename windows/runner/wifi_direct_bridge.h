#ifndef RUNNER_WIFI_DIRECT_BRIDGE_H_
#define RUNNER_WIFI_DIRECT_BRIDGE_H_

#include <flutter/binary_messenger.h>

// Wi-Fi Direct between Windows computers (item 6): method channel
// "zen/wifi_direct", events on "zen/wifi_direct/events", the calls of
// ZenWifiDirectBridge.kt, so wifi_direct_local_link.dart drives both. It only
// makes a network; the bridge's LAN discovery then links friends over it.
//
// Never in the way of the normal Wi-Fi: the feature is on only where the
// driver runs Wi-Fi Direct on its own virtual adapter next to the station
// (an 802.11 adapter that is not a WLAN station interface, and a publisher
// that starts), and everything stops while the computer is connected to a
// Wi-Fi network (friends there are found over it), as on Android.
//
// Windows cannot read Android's DNS-SD service records nor publish them, and
// Android cannot read Windows' information elements: Windows links with
// Windows only.
namespace wifi_direct_bridge {

void Register(flutter::BinaryMessenger* messenger);

}  // namespace wifi_direct_bridge

#endif  // RUNNER_WIFI_DIRECT_BRIDGE_H_
