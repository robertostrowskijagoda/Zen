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
    // Screen protection and the Secure Enclave key vault (§14.1).
    SecurityBridge.register(
      with: flutterViewController.engine.binaryMessenger, window: self)

    super.awakeFromNib()
  }
}
