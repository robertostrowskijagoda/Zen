import CoreBluetooth
import FlutterMacOS
import Foundation

/// "W pobliżu" on a Mac: method channel `zen/nearby_le`, events on
/// `zen/nearby_le/events` (desktop_nearby_radio.dart). CoreBluetooth lets
/// an app look for manufacturer data but not show it, so a Mac only looks
/// around: it reports the manufacturer data of company 0xFFFF ("ZN", the
/// token, the hint) of devices around. `advertise` always answers false and
/// `state` says `canAdvertise: false`.
final class ZenNearbyRadioBridge: NSObject, CBCentralManagerDelegate, FlutterStreamHandler {
  static let shared = ZenNearbyRadioBridge()

  private static let companyId: UInt16 = 0xFFFF
  private static let advertBytes = 2 + 16 + 4
  private static let reportEvery: TimeInterval = 1

  private var channel: FlutterMethodChannel?
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?
  private var central: CBCentralManager?
  private var scanning = false
  private var reported: [UUID: Date] = [:]
  private var pendingState: [FlutterResult] = []

  static func register(with messenger: FlutterBinaryMessenger) {
    shared.attach(messenger)
  }

  private func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/nearby_le", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
    self.channel = channel
    let events = FlutterEventChannel(name: "zen/nearby_le/events", binaryMessenger: messenger)
    events.setStreamHandler(self)
    self.events = events
  }

  /// Made the first time it is needed: macOS asks the person then.
  private func manager() -> CBCentralManager {
    if let central = central {
      return central
    }
    let made = CBCentralManager(delegate: self, queue: nil)
    central = made
    return made
  }

  private func stateMap(_ state: CBManagerState) -> [String: Any] {
    let present = state != .unsupported && state != .unauthorized
    return [
      "present": present,
      "powered": state == .poweredOn,
      "canAdvertise": false,
    ]
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "state":
      let central = manager()
      if central.state == .unknown || central.state == .resetting {
        // The answer comes with the first state update.
        pendingState.append(result)
      } else {
        result(stateMap(central.state))
      }
    case "advertise":
      result(false)
    case "stopAdvertising":
      result(nil)
    case "startScan":
      scanning = true
      result(startScanning())
    case "stopScan":
      scanning = false
      central?.stopScan()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func startScanning() -> Bool {
    let central = manager()
    guard central.state == .poweredOn else {
      return false
    }
    central.scanForPeripherals(
      withServices: nil,
      options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    return true
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = central.state
    let waiting = pendingState
    pendingState.removeAll()
    for result in waiting {
      result(stateMap(state))
    }
    if state == .poweredOn, scanning {
      _ = startScanning()
    }
    if state == .poweredOn || state == .poweredOff {
      sink?(["type": "bluetooth", "on": state == .poweredOn])
    }
  }

  func centralManager(
    _ central: CBCentralManager,
    didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any],
    rssi RSSI: NSNumber
  ) {
    guard scanning,
      let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
      data.count >= 2 + ZenNearbyRadioBridge.advertBytes
    else {
      return
    }
    let bytes = [UInt8](data)
    // The company id comes first, little-endian.
    let company = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    guard company == ZenNearbyRadioBridge.companyId, bytes[2] == 0x5A, bytes[3] == 0x4E else {
      return
    }
    let now = Date()
    if let last = reported[peripheral.identifier],
      now.timeIntervalSince(last) < ZenNearbyRadioBridge.reportEvery
    {
      return
    }
    if reported.count > 512 {
      reported.removeAll()
    }
    reported[peripheral.identifier] = now
    let advert = Data(bytes[2..<(2 + ZenNearbyRadioBridge.advertBytes)])
    sink?([
      "type": "seen",
      "device": peripheral.identifier.uuidString,
      "data": FlutterStandardTypedData(bytes: advert),
      "rssi": RSSI.intValue,
    ])
  }

  // MARK: - FlutterStreamHandler

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }
}
