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
    // Where the device is (the alarm), from Core Location.
    ZenLocationBridge.register(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }
}
