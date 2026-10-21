#ifndef RUNNER_BLUETOOTH_LE_BRIDGE_H_
#define RUNNER_BLUETOOTH_LE_BRIDGE_H_

#include <flutter/binary_messenger.h>

// Bluetooth LE links on Windows (item 6): method channel "zen/bt_link",
// events on "zen/bt_link/events", the calls of ZenBluetoothLinkBridge.kt
// (state, start, stop, advertise, scan, connect, accept, reject). Windows
// gives apps no BLE L2CAP channels, so the stream is GATT: the Zen link
// service 5a454e00-6c69-6e6b-0000-000000000001 with the advert (…0002, read),
// the PSM (…0003, read, 0 here: no L2CAP), the stream to the GATT server
// (…0005, written with response, in order) and the stream from it (…0006,
// notified). An empty write or notification ends the stream. Windows runs
// the GATT server (Android and other Windows computers connect to it) and
// connects as a GATT client to devices that expose the two stream
// characteristics (Android, Windows). Paired devices over RFCOMM stay in
// the Go bridge (bluetooth_link_windows.go); Dart joins both
// (bluetooth_local_links.dart).
namespace bluetooth_le_bridge {

void Register(flutter::BinaryMessenger* messenger);

}  // namespace bluetooth_le_bridge

#endif  // RUNNER_BLUETOOTH_LE_BRIDGE_H_
