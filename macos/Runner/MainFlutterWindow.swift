import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    // A phone-sized column, like the Windows runner; the Dart side
    // (desktop_window_bridge.dart) keeps the same sizes.
    self.setContentSize(NSSize(width: 430, height: 880))
    self.contentMinSize = NSSize(width: 390, height: 720)
    self.center()

    RegisterGeneratedPlugins(registry: flutterViewController)
    // Screen protection and the Secure Enclave key vault.
    SecurityBridge.register(
      with: flutterViewController.engine.binaryMessenger, window: self)
    // Bluetooth and Multipeer links with friends nearby.
    ZenLocalLinksBridge.register(with: flutterViewController.engine.binaryMessenger)
    // "W pobliżu": a Mac looks around for Zen's nearby advert (it cannot
    // show one: CoreBluetooth shows no manufacturer data).
    ZenNearbyRadioBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Where the device is (the alarm), from Core Location.
    ZenLocationBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Signs of a debugger or injected libraries (device_integrity.dart).
    ZenIntegrityBridge.register(with: flutterViewController.engine.binaryMessenger)
    // Films of the "Filmy" section compressed and trimmed (AVFoundation).
    ZenVideoBridge.register(with: flutterViewController.engine.binaryMessenger)
    // The recorder's own camera (AVCaptureSession, in ZenVideoBridge.swift).
    ZenCameraBridge.register(
      with: flutterViewController.registrar(forPlugin: "ZenCameraBridge"))

    super.awakeFromNib()
  }
}
