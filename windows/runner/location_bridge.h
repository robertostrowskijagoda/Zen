#ifndef RUNNER_LOCATION_BRIDGE_H_
#define RUNNER_LOCATION_BRIDGE_H_

#include <flutter/binary_messenger.h>

// Where the computer is: method channel "zen/location", the calls of
// ZenLocationBridge.kt, so location.dart drives both. Windows' own location
// service (Windows.Devices.Geolocation), no other library:
//  - "check" / "request": "whileInUse" when the privacy settings let
//    desktop apps use the location, "denied" when they do not,
//    "deniedForever" when the system cannot say (desktop apps get no system
//    question: the settings decide);
//  - "serviceEnabled": the location service is on;
//  - "current" {timeoutMs}: one fresh position, or the error "unavailable";
//  - "lastKnown": a position the service still keeps (up to an hour old,
//    without waiting), or null.
// A position is {lat, lon, accuracy (metres), at (ms since the epoch)}.
namespace location_bridge {

void Register(flutter::BinaryMessenger* messenger);

}  // namespace location_bridge

#endif  // RUNNER_LOCATION_BRIDGE_H_
