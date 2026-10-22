import CoreLocation
import Foundation

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

/// Where the device is (`zen/location`) on iPhone, iPad and Mac, from Core
/// Location; one file for both apps (the Mac project refers to this one).
/// The calls of ZenLocationBridge.kt, so location.dart drives both:
///
///  - `check` / `request`: "denied" (not asked yet), "deniedForever"
///    (refused or restricted), "whileInUse" or "always". `request` shows the
///    system question only while it was never answered.
///  - `serviceEnabled`: location services switched on.
///  - `current` {timeoutMs}: one fresh position (`requestLocation`), or the
///    error "timeout" / "unavailable".
///  - `lastKnown`: the position Core Location still keeps, or nil.
///
/// A position is {lat, lon, accuracy (metres), at (ms since the epoch)}.
/// Everything runs on the main thread.
final class ZenLocationBridge: NSObject, CLLocationManagerDelegate {
  static func register(with messenger: FlutterBinaryMessenger) {
    shared.attach(messenger)
  }

  private static let shared = ZenLocationBridge()

  private let manager = CLLocationManager()
  private var channel: FlutterMethodChannel?
  private var permissionWaiters: [FlutterResult] = []
  private var readings: [Int: FlutterResult] = [:]
  private var nextReading = 0

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyBest
  }

  private func attach(_ messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/location", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result)
    }
    self.channel = channel
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "check":
      result(status())
    case "request":
      guard manager.authorizationStatus == .notDetermined else {
        result(status())
        return
      }
      permissionWaiters.append(result)
      if permissionWaiters.count == 1 {
        manager.requestWhenInUseAuthorization()
      }
    case "serviceEnabled":
      // Asking on the main thread can stall it.
      DispatchQueue.global(qos: .userInitiated).async {
        let enabled = CLLocationManager.locationServicesEnabled()
        DispatchQueue.main.async { result(enabled) }
      }
    case "current":
      let arguments = call.arguments as? [String: Any]
      let timeoutMs = (arguments?["timeoutMs"] as? NSNumber)?.intValue ?? 12_000
      current(timeoutMs: min(max(timeoutMs, 1_000), 120_000), result)
    case "lastKnown":
      result(authorized() ? manager.location.map(ZenLocationBridge.toMap) : nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func status() -> String {
    switch manager.authorizationStatus {
    case .notDetermined:
      return "denied"
    case .restricted, .denied:
      return "deniedForever"
    #if os(iOS)
    case .authorizedWhenInUse:
      return "whileInUse"
    #endif
    case .authorizedAlways:
      return "always"
    @unknown default:
      return "unableToDetermine"
    }
  }

  private func authorized() -> Bool {
    let status = manager.authorizationStatus
    #if os(iOS)
    return status == .authorizedAlways || status == .authorizedWhenInUse
    #else
    // A Mac has no "while in use": Location Services allow the app or not.
    return status == .authorizedAlways
    #endif
  }

  private func current(timeoutMs: Int, _ result: @escaping FlutterResult) {
    guard authorized() else {
      result(FlutterError(code: "denied", message: "No location permission", details: nil))
      return
    }
    let id = nextReading
    nextReading += 1
    readings[id] = result
    if readings.count == 1 {
      manager.requestLocation()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) { [weak self] in
      guard let self = self, let waiting = self.readings.removeValue(forKey: id) else {
        return
      }
      waiting(FlutterError(code: "timeout", message: "No position in time", details: nil))
      if self.readings.isEmpty {
        self.manager.stopUpdatingLocation()
      }
    }
  }

  private static func toMap(_ location: CLLocation) -> [String: Any] {
    return [
      "lat": location.coordinate.latitude,
      "lon": location.coordinate.longitude,
      "accuracy": max(location.horizontalAccuracy, 0),
      "at": Int64(location.timestamp.timeIntervalSince1970 * 1000),
    ]
  }

  // MARK: CLLocationManagerDelegate

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    // Also called when the manager is made: only a real answer counts.
    guard manager.authorizationStatus != .notDetermined, !permissionWaiters.isEmpty else {
      return
    }
    let waiting = permissionWaiters
    permissionWaiters.removeAll()
    let answer = status()
    waiting.forEach { $0(answer) }
  }

  func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    guard let location = locations.last, !readings.isEmpty else {
      return
    }
    let waiting = readings
    readings.removeAll()
    let position = ZenLocationBridge.toMap(location)
    waiting.values.forEach { $0(position) }
  }

  func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    guard !readings.isEmpty else {
      return
    }
    let waiting = readings
    readings.removeAll()
    let failure = FlutterError(
      code: "unavailable", message: error.localizedDescription, details: nil)
    waiting.values.forEach { $0(failure) }
  }
}
