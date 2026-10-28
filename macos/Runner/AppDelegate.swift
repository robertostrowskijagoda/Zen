import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }
}

/// Zen's own files opened in Zen from Finder: a backup, a key backup or an
/// update (opened_files.dart). Zen is not sandboxed, so Dart reads the file
/// where it is (a backup's other parts lie next to it). The paths wait here
/// until Dart takes them: `zen/opened_files` "take" answers them, "opened"
/// tells Dart a new one came. Only the newest waits. Links (zen://) are
/// app_links' and pass on.
final class ZenOpenedFilesBridge: NSObject, FlutterAppLifecycleDelegate {
  static let shared = ZenOpenedFilesBridge()

  private var channel: FlutterMethodChannel?
  private var waiting: [String] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zen/opened_files", binaryMessenger: registrar.messenger)
    shared.channel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "take":
        result(shared.waiting)
        shared.waiting = []
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    registrar.addApplicationDelegate(shared)
  }

  func handleOpen(_ urls: [URL]) -> Bool {
    let files = urls.filter { $0.isFileURL }
    guard let newest = files.last else {
      return false
    }
    waiting = [newest.path]
    channel?.invokeMethod("opened", arguments: nil)
    // Handled only when every address was a file.
    return files.count == urls.count
  }
}
