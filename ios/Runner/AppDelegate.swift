import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let privacyGuard = PrivacyGuard()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Notifications shown while Zen is open, and taps on them, reach the
    // plugins (flutter_local_notifications) through FlutterAppDelegate.
    UNUserNotificationCenter.current().delegate = self as? UNUserNotificationCenterDelegate
    privacyGuard.start()
    // Background refresh handlers: iOS takes them only during launch.
    ZenBackgroundBridge.shared.start()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Bluetooth and Multipeer links with friends nearby.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenLocalLinksBridge") {
      ZenLocalLinksBridge.register(with: registrar.messenger())
    }
    // Where the device is (the alarm), from Core Location.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenLocationBridge") {
      ZenLocationBridge.register(with: registrar.messenger())
    }
    // Signs of a debugger, injected libraries or a jailbreak.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenIntegrityBridge") {
      ZenIntegrityBridge.register(with: registrar.messenger())
    }
    // Films of the "Filmy" section compressed and trimmed (AVFoundation).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenVideoBridge") {
      ZenVideoBridge.register(with: registrar.messenger())
    }
    // Call recording: what the call plays and the microphone (AAC).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenCallRecorder") {
      ZenCallRecorder.register(with: registrar.messenger())
    }
    // Pictures on the clipboard ("Wklej" in chats: GIFs keyboards copy).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenMediaTransferBridge") {
      ZenMediaTransferBridge.register(with: registrar.messenger())
    }
    // Time to run off the screen: background refresh, the keep-alive.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenBackgroundBridge") {
      ZenBackgroundBridge.register(with: registrar.messenger())
    }
    // Zen's own files opened in Zen (SceneDelegate.swift).
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenOpenedFilesBridge") {
      ZenOpenedFilesBridge.register(with: registrar)
    }
    // Links: web pages (and the update's IPA) in Safari, Zen's source and
    // the update in SideStore.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "ZenSystemLinks") {
      ZenSystemLinks.register(with: registrar.messenger())
    }
  }
}

/// `zen/system` on iOS: `openUrl` {url} → Bool, the same as on Android.
/// Only https links are opened (Safari: web pages, and the release's IPA,
/// which Safari saves to Files), and of SideStore's documented links
/// exactly the one that adds Zen's source (kSideStoreSourceLink in
/// github_release.dart) and the ones that install a release's
/// Zen-unsigned.ipa of this repository (sideStoreInstallLink). False when
/// nothing opened the link, which for SideStore means it is not installed
/// (`open` needs no LSApplicationQueriesSchemes entry, unlike
/// `canOpenURL`).
enum ZenSystemLinks {
  private static var channel: FlutterMethodChannel?
  private static let sideStoreSource =
    "sidestore://source?url=https://robertostrowskijagoda.github.io/Zen/apps.json"
  private static let sideStoreInstallStart =
    "sidestore://install?url=https://github.com/robertostrowskijagoda/Zen/releases/download/"
  private static let sideStoreInstallEnd = "/Zen-unsigned.ipa"

  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "zen/system", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "openUrl" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let link = (call.arguments as? [String: Any])?["url"] as? String
      guard let link = link, let url = URL(string: link), ZenSystemLinks.allowed(link, url) else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }
    ZenSystemLinks.channel = channel
  }

  private static func allowed(_ link: String, _ url: URL) -> Bool {
    if link == sideStoreSource {
      return true
    }
    if link.hasPrefix(sideStoreInstallStart) && link.hasSuffix(sideStoreInstallEnd) {
      // Only a release tag in between (v1.2.3, v1.2.3-canary.1).
      let tag = link.dropFirst(sideStoreInstallStart.count).dropLast(sideStoreInstallEnd.count)
      return !tag.isEmpty && tag.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
    return url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
  }
}

/// Privacy on iOS:
///  - Zen's data stays out of iCloud and computer backups, as on Android
///    (`allowBackup=false`): the support folder, where every store and the
///    media vault live, is marked excluded at launch and each time the app
///    goes to the background (a wipe deletes and recreates the folder, which
///    drops the mark; backups run while the app is in the background).
///    Documents is left alone: only the copies the person saves on purpose
///    ("Zapisz kopię", exported recordings) go there, for the Files app.
///  - While the app is not active the windows are covered with the launch
///    screen, so neither the app switcher nor its snapshot shows anything.
final class PrivacyGuard {
  private static let coverTag = 0x5A454E
  private var observers: [NSObjectProtocol] = []

  func start() {
    PrivacyGuard.excludeDataFromBackup()
    let center = NotificationCenter.default
    // The scene notifications are the ones a scene-based app gets; the app
    // ones are a fallback. Both may come: covering and uncovering are
    // idempotent. queue nil: run at once, before the snapshot is taken.
    for name in [UIScene.willDeactivateNotification, UIApplication.willResignActiveNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { _ in
          PrivacyGuard.cover()
        })
    }
    for name in [UIScene.didActivateNotification, UIApplication.didBecomeActiveNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { _ in
          PrivacyGuard.uncover()
        })
    }
    for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { _ in
          PrivacyGuard.excludeDataFromBackup()
        })
    }
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  // MARK: Backups

  static func excludeDataFromBackup() {
    let files = FileManager.default
    guard let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      return
    }
    do {
      try files.createDirectory(at: support, withIntermediateDirectories: true)
    } catch {
      NSLog("Zen: the support folder is not available for the backup mark")
      return
    }
    // The mark on a folder covers everything in it; the vault (media) gets
    // its own in case it is ever moved out.
    exclude(support)
    exclude(support.appendingPathComponent("vault", isDirectory: true))
  }

  private static func exclude(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else {
      return
    }
    var target = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try target.setResourceValues(values)
    } catch {
      NSLog("Zen: excluding a folder from backups failed")
    }
  }

  // MARK: App switcher

  private static func windows() -> [UIWindow] {
    return UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
      .filter { !$0.isHidden && $0.windowLevel == .normal }
  }

  static func cover() {
    for window in windows() where window.viewWithTag(coverTag) == nil {
      // The launch screen: white with the logo (LaunchScreen.storyboard).
      let cover = UIView(frame: window.bounds)
      cover.tag = coverTag
      cover.backgroundColor = .white
      cover.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      cover.isUserInteractionEnabled = false
      if let image = UIImage(named: "LaunchImage") {
        let logo = UIImageView(image: image)
        logo.contentMode = .center
        logo.frame = cover.bounds
        logo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        cover.addSubview(logo)
      }
      window.addSubview(cover)
      window.bringSubviewToFront(cover)
    }
  }

  static func uncover() {
    for window in windows() {
      window.viewWithTag(coverTag)?.removeFromSuperview()
    }
  }
}
