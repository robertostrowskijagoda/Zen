import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {

}

/// Zen's own files opened in Zen: a backup, a key backup or an update from
/// Files, a mail or AirDrop (opened_files.dart). Each is copied into the
/// app's temporary folder at once (a file opened in place may be read only
/// while iOS allows it, a copy iOS made in Documents/Inbox would show in
/// Files) and waits there until Dart takes it: `zen/opened_files` "take"
/// answers the paths, "opened" tells Dart a new one came. Only the newest
/// waits. app_links passes the same file addresses on as links; the Dart
/// side leaves those alone.
final class ZenOpenedFilesBridge: NSObject, FlutterSceneLifeCycleDelegate {
  static let shared = ZenOpenedFilesBridge()

  private var channel: FlutterMethodChannel?
  private var waiting: [String] = []
  private let queue = DispatchQueue(label: "com.roj.zen.opened-files")

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "zen/opened_files", binaryMessenger: registrar.messenger())
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
    registrar.addSceneDelegate(shared)
  }

  // Zen started with a file.
  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions?
  ) -> Bool {
    if let contexts = connectionOptions?.urlContexts {
      take(contexts)
    }
    return false
  }

  // A file while Zen runs.
  func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) -> Bool {
    take(URLContexts)
    return false
  }

  private func take(_ contexts: Set<UIOpenURLContext>) {
    for context in contexts where context.url.isFileURL {
      let url = context.url
      let inPlace = context.options.openInPlace
      // A backup may be large: copied off the main thread.
      queue.async {
        guard let path = ZenOpenedFilesBridge.copy(url, inPlace: inPlace) else {
          return
        }
        DispatchQueue.main.async {
          self.waiting = [path]
          self.channel?.invokeMethod("opened", arguments: nil)
        }
      }
    }
  }

  private static func copy(_ url: URL, inPlace: Bool) -> String? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }
    let files = FileManager.default
    let folder = files.temporaryDirectory.appendingPathComponent("opened", isDirectory: true)
    do {
      try? files.removeItem(at: folder)
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      let target = folder.appendingPathComponent(url.lastPathComponent)
      try files.copyItem(at: url, to: target)
      if !inPlace {
        // iOS's own copy in Documents/Inbox: not needed twice.
        try? files.removeItem(at: url)
      }
      return target.path
    } catch {
      NSLog("Zen: copying an opened file failed")
      return nil
    }
  }
}
