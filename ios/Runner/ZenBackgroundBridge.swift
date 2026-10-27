import AVFoundation
import BackgroundTasks
import Flutter
import UIKit
import UserNotifications

/// Time to run while Zen is off the screen (`zen/background`).
///
/// iOS freezes an app a few seconds after it leaves the screen, and Zen has
/// no server to send pushes from, so this is all an iPhone gets
/// (docs/IOS_BACKGROUND.md):
///  - leaving the screen: up to about 30 s more (`beginBackgroundTask`), so
///    what was just sent still reaches the friends' mailboxes;
///  - a background refresh (`BGAppRefreshTask`, about 30 s) whenever iOS
///    decides: a few times a day at best, never after the app was swiped
///    away, in Low Power Mode or with "Background App Refresh" off; and a
///    longer one while the phone charges (`BGProcessingTask`). Dart asks the
///    mailboxes for what they hold then (ios_background.dart);
///  - opt-in ("Cichy dźwięk — odbiór na bieżąco"): a silent sound keeps the app
///    running (the `audio` background mode) for as long as it plays;
///  - "Sprawdź wiadomości Zen", a Shortcuts action (ZenCheckIntent.swift),
///    which a Shortcuts automation can run every hour.
///
/// Dart calls `configure` {ready, keepAlive} → status, `status` → status,
/// `openSettings` (Zen's page in Settings) and `openShortcuts`. `ready`:
/// Zen can receive in the background now — the unlocked app runs, or, while
/// Zen is locked, its locked receiver (ios_background.dart); nothing runs
/// in the background otherwise. This side calls `catchUp` {seconds} → Bool
/// (false: Zen could not check).
///
/// When iOS starts Zen from scratch for a task or a Shortcuts run there is
/// no scene and so no Flutter engine: the check then runs in an engine of
/// its own without a screen (`zenIosBackgroundMain` in
/// ios_locked_receiver.dart, the locked receiver with only the background
/// key), which is stopped and let go once it is done, or as soon as Zen
/// comes to the screen. Everything runs on the main thread.
final class ZenBackgroundBridge {
  static let shared = ZenBackgroundBridge()

  /// Both are listed under BGTaskSchedulerPermittedIdentifiers (Info.plist).
  /// They need not start with the bundle id, which a re-signing changes.
  static let refreshTask = "com.roj.zen.refresh"
  static let processingTask = "com.roj.zen.catchup"

  /// What Dart may use of the ~30 s of a refresh, and of a processing task
  /// (iOS allows minutes there, and ends it early when it needs to).
  private static let refreshSeconds = 25
  private static let processingSeconds = 180

  /// The earliest next refresh; iOS usually waits much longer.
  private static let refreshEvery: TimeInterval = 15 * 60

  /// When iOS last woke Zen and how that went, for the settings page (only
  /// times and a word, nothing about messages).
  private static let lastRunAtKey = "zen.background.lastRunAt"
  private static let lastRunResultKey = "zen.background.lastRunResult"
  private static let runsKey = "zen.background.runs"
  private static let lastShortcutAtKey = "zen.background.lastShortcutAt"
  private static let shortcutRunsKey = "zen.background.shortcutRuns"

  /// The Dart entry point of a check without a screen, and its library.
  private static let headlessEntrypoint = "zenIosBackgroundMain"
  private static let headlessLibrary = "package:zen/src/features/runtime/ios_locked_receiver.dart"

  static func register(with messenger: FlutterBinaryMessenger) {
    shared.attach(messenger)
  }

  private var channel: FlutterMethodChannel?
  private var ready = false
  private var keepAliveWanted = false
  private var inBackground = false
  private var finishing: UIBackgroundTaskIdentifier = .invalid
  private let keepAlive = SilentKeepAlive()
  private var observers: [NSObjectProtocol] = []

  /// The engine without a screen while it runs a check, and who waits for
  /// its answer.
  private var headless: FlutterEngine?
  private var headlessChannel: FlutterMethodChannel?
  private var headlessWaiting: [(Bool) -> Void] = []

  private init() {}

  /// From `application(_:didFinishLaunchingWithOptions:)`: iOS takes the
  /// task handlers only until launching ends.
  func start() {
    let scheduler = BGTaskScheduler.shared
    for (identifier, seconds) in [
      (ZenBackgroundBridge.refreshTask, ZenBackgroundBridge.refreshSeconds),
      (ZenBackgroundBridge.processingTask, ZenBackgroundBridge.processingSeconds),
    ] {
      let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) {
        task in
        self.run(task, seconds: seconds)
      }
      if !registered {
        NSLog("Zen: the background task \(identifier) was not registered")
      }
    }
    let center = NotificationCenter.default
    // The scene notifications and the app ones both come; handling either
    // is idempotent.
    for name in [UIScene.didEnterBackgroundNotification, UIApplication.didEnterBackgroundNotification] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          self?.enteredBackground()
        })
    }
    for name in [
      UIScene.willEnterForegroundNotification, UIApplication.willEnterForegroundNotification,
      UIApplication.didBecomeActiveNotification,
    ] {
      observers.append(
        center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
          self?.enteredForeground()
        })
    }
  }

  private func attach(_ messenger: FlutterBinaryMessenger) {
    // The app's own engine is up: one without a screen lets go of the node.
    stopHeadless()
    let channel = FlutterMethodChannel(name: "zen/background", binaryMessenger: messenger)
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
    case "configure":
      let arguments = call.arguments as? [String: Any]
      ready = arguments?["ready"] as? Bool ?? false
      keepAliveWanted = arguments?["keepAlive"] as? Bool ?? false
      if !ready {
        // Nothing can receive now (no app, no locked receiver): let iOS
        // freeze the app now.
        endFinishing()
      }
      updateKeepAlive()
      result(status())
    case "status":
      // Whether notifications are allowed comes asynchronously.
      UNUserNotificationCenter.current().getNotificationSettings { settings in
        let notifications: String
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
          notifications = "allowed"
        case .denied:
          notifications = "denied"
        case .notDetermined:
          notifications = "notDetermined"
        @unknown default:
          notifications = "unknown"
        }
        DispatchQueue.main.async {
          var status = self.status()
          status["notifications"] = notifications
          result(status)
        }
      }
    case "openSettings":
      openLink(UIApplication.openSettingsURLString)
      result(nil)
    case "openShortcuts":
      openLink("shortcuts://")
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Leaving and coming back

  private func enteredBackground() {
    guard !inBackground else {
      return
    }
    inBackground = true
    schedule()
    beginFinishing()
    updateKeepAlive()
  }

  private func enteredForeground() {
    // A check without a screen lets go before the app's engine wants the
    // node.
    stopHeadless()
    guard inBackground else {
      return
    }
    inBackground = false
    endFinishing()
    updateKeepAlive()
  }

  /// The ~30 s iOS still gives an app that just left the screen: a message
  /// sent a moment ago gets its mailbox copies (a few seconds later).
  private func beginFinishing() {
    guard ready, finishing == .invalid else {
      return
    }
    finishing = UIApplication.shared.beginBackgroundTask(withName: "zen.finish") {
      [weak self] in
      self?.endFinishing()
    }
  }

  private func endFinishing() {
    guard finishing != .invalid else {
      return
    }
    UIApplication.shared.endBackgroundTask(finishing)
    finishing = .invalid
  }

  private func updateKeepAlive() {
    if ready && keepAliveWanted && inBackground {
      keepAlive.start()
    } else {
      keepAlive.stop()
    }
  }

  // MARK: Background tasks

  /// Asks for the next refresh and the next charging catch-up; a new request
  /// replaces the one waiting.
  private func schedule() {
    let refresh = BGAppRefreshTaskRequest(identifier: ZenBackgroundBridge.refreshTask)
    refresh.earliestBeginDate = Date(timeIntervalSinceNow: ZenBackgroundBridge.refreshEvery)
    let processing = BGProcessingTaskRequest(identifier: ZenBackgroundBridge.processingTask)
    processing.requiresNetworkConnectivity = true
    processing.requiresExternalPower = true
    for request in [refresh, processing] as [BGTaskRequest] {
      do {
        try BGTaskScheduler.shared.submit(request)
      } catch {
        // The simulator, "Background App Refresh" off, or too many requests.
        NSLog("Zen: \(request.identifier) not scheduled: \(error.localizedDescription)")
      }
    }
  }

  private func run(_ task: BGTask, seconds: Int) {
    schedule()
    var done = false
    let finish: (String, Bool) -> Void = { [weak self] outcome, success in
      guard !done else {
        return
      }
      done = true
      self?.remember(outcome)
      task.setTaskCompleted(success: success)
    }
    task.expirationHandler = { [weak self] in
      DispatchQueue.main.async {
        self?.stopHeadless()
        finish("expired", false)
      }
    }
    check(seconds: seconds) { checked in
      finish(checked ? "done" : "skipped", checked)
    }
  }

  /// One background check: in the app's engine when there is one (Dart
  /// checks unlocked, or with the locked receiver), otherwise in an engine
  /// without a screen.
  func check(seconds: Int, completion: @escaping (Bool) -> Void) {
    if let channel = channel {
      channel.invokeMethod("catchUp", arguments: ["seconds": seconds]) { result in
        completion((result as? Bool) ?? false)
      }
      return
    }
    runHeadless(seconds: seconds, completion: completion)
  }

  /// "Sprawdź wiadomości Zen" from Shortcuts: a check with time of its own,
  /// counted for the settings page.
  func checkFromShortcut(seconds: Int, completion: @escaping (Bool) -> Void) {
    let defaults = UserDefaults.standard
    defaults.set(
      Date().timeIntervalSince1970 * 1000, forKey: ZenBackgroundBridge.lastShortcutAtKey)
    defaults.set(
      defaults.integer(forKey: ZenBackgroundBridge.shortcutRunsKey) + 1,
      forKey: ZenBackgroundBridge.shortcutRunsKey)
    var extra: UIBackgroundTaskIdentifier = .invalid
    var done = false
    let finish: (Bool) -> Void = { checked in
      guard !done else {
        return
      }
      done = true
      if extra != .invalid {
        UIApplication.shared.endBackgroundTask(extra)
        extra = .invalid
      }
      completion(checked)
    }
    extra = UIApplication.shared.beginBackgroundTask(withName: "zen.shortcut") { [weak self] in
      self?.stopHeadless()
      finish(false)
    }
    check(seconds: seconds, completion: finish)
  }

  // MARK: A check without a screen

  private func runHeadless(seconds: Int, completion: @escaping (Bool) -> Void) {
    headlessWaiting.append(completion)
    guard headless == nil else {
      // One check at a time; this one shares its answer.
      return
    }
    let engine = FlutterEngine(name: "zen.background", project: nil, allowHeadlessExecution: true)
    let channel = FlutterMethodChannel(
      name: "zen/background/headless", binaryMessenger: engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "done" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let checked = (call.arguments as? [String: Any])?["checked"] as? Bool ?? false
      result(nil)
      self?.endHeadless(checked)
    }
    headless = engine
    headlessChannel = channel
    let started = engine.run(
      withEntrypoint: ZenBackgroundBridge.headlessEntrypoint,
      libraryURI: ZenBackgroundBridge.headlessLibrary,
      initialRoute: nil,
      entrypointArgs: [String(seconds)])
    guard started else {
      NSLog("Zen: the background engine did not start")
      endHeadless(false)
      return
    }
    // The plugins Dart needs there: the keychain, the files, notifications.
    GeneratedPluginRegistrant.register(with: engine)
    // Dart answers within its budget; this only covers an engine that never
    // does.
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds + 15)) {
      [weak self, weak engine] in
      guard let self = self, let engine = engine, self.headless === engine else {
        return
      }
      NSLog("Zen: the background engine did not answer in time")
      self.endHeadless(false)
    }
  }

  /// Asks the engine without a screen to let go of the node now; it answers
  /// `done` within moments (or is let go anyway).
  private func stopHeadless() {
    guard let engine = headless else {
      return
    }
    headlessChannel?.invokeMethod("stop", arguments: nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(3)) { [weak self, weak engine] in
      guard let self = self, let engine = engine, self.headless === engine else {
        return
      }
      self.endHeadless(false)
    }
  }

  private func endHeadless(_ checked: Bool) {
    let waiting = headlessWaiting
    headlessWaiting = []
    headlessChannel?.setMethodCallHandler(nil)
    headlessChannel = nil
    headless?.destroyContext()
    headless = nil
    waiting.forEach { $0(checked) }
  }

  private func openLink(_ link: String) {
    guard let url = URL(string: link) else {
      return
    }
    UIApplication.shared.open(url, options: [:]) { opened in
      if !opened {
        NSLog("Zen: \(link) did not open")
      }
    }
  }

  private func remember(_ outcome: String) {
    let defaults = UserDefaults.standard
    defaults.set(Date().timeIntervalSince1970 * 1000, forKey: ZenBackgroundBridge.lastRunAtKey)
    defaults.set(outcome, forKey: ZenBackgroundBridge.lastRunResultKey)
    defaults.set(defaults.integer(forKey: ZenBackgroundBridge.runsKey) + 1, forKey: ZenBackgroundBridge.runsKey)
  }

  private func status() -> [String: Any] {
    let refresh: String
    switch UIApplication.shared.backgroundRefreshStatus {
    case .available:
      refresh = "available"
    case .denied:
      refresh = "denied"
    case .restricted:
      refresh = "restricted"
    @unknown default:
      refresh = "unknown"
    }
    let defaults = UserDefaults.standard
    return [
      "refresh": refresh,
      "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled,
      "keepAlive": keepAlive.isPlaying,
      "lastRunAt": Int(defaults.double(forKey: ZenBackgroundBridge.lastRunAtKey)),
      "lastRunResult": defaults.string(forKey: ZenBackgroundBridge.lastRunResultKey) ?? "",
      "runs": defaults.integer(forKey: ZenBackgroundBridge.runsKey),
      "lastShortcutAt": Int(defaults.double(forKey: ZenBackgroundBridge.lastShortcutAtKey)),
      "shortcutRuns": defaults.integer(forKey: ZenBackgroundBridge.shortcutRunsKey),
    ]
  }
}

/// The opt-in keep-alive: a looping, silent sound in a session that mixes
/// with other apps' audio. iOS keeps an app that plays sound running in the
/// background; a phone call, Siri or an alarm interrupts it, and it starts
/// again when they end. A Zen call or a recording holds the session itself
/// (and keeps the app running by itself): the session is left alone then,
/// changing its category would cut the microphone.
final class SilentKeepAlive {
  private var player: AVAudioPlayer?
  private var wanted = false

  /// The session as it was before this took it, given back on [stop].
  private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private var observers: [NSObjectProtocol] = []

  var isPlaying: Bool { player?.isPlaying == true }

  init() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: raw) == .ended
        else {
          return
        }
        self?.resume()
      })
    observers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        // Every player is gone with the media services.
        self?.player = nil
        self?.previous = nil
        self?.resume()
      })
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
  }

  func start() {
    wanted = true
    resume()
  }

  func stop() {
    guard wanted || player != nil else {
      return
    }
    wanted = false
    player?.stop()
    player = nil
    let session = AVAudioSession.sharedInstance()
    // Only a session still set the way this left it is given back.
    guard let previous = previous, session.category == .playback else {
      self.previous = nil
      return
    }
    self.previous = nil
    do {
      try session.setActive(false, options: .notifyOthersOnDeactivation)
      try session.setCategory(previous.0, mode: previous.1, options: previous.2)
    } catch {
      NSLog("Zen: the audio session was not given back: \(error.localizedDescription)")
    }
  }

  private func resume() {
    guard wanted, !isPlaying else {
      return
    }
    let session = AVAudioSession.sharedInstance()
    if session.category == .playAndRecord || session.category == .record {
      return
    }
    do {
      if previous == nil {
        previous = (session.category, session.mode, session.categoryOptions)
      }
      try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
      try session.setActive(true)
      let player = try self.player ?? AVAudioPlayer(data: SilentKeepAlive.silence)
      player.numberOfLoops = -1
      player.play()
      self.player = player
    } catch {
      NSLog("Zen: the background sound did not start: \(error.localizedDescription)")
    }
  }

  /// One second of silence: 8 kHz, mono, 16-bit PCM in a WAV file.
  private static let silence: Data = {
    let rate: UInt32 = 8000
    let bytes = rate * 2
    var data = Data()
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: Array("RIFF".utf8))
    append(UInt32(36) + bytes)
    data.append(contentsOf: Array("WAVEfmt ".utf8))
    append(UInt32(16))
    append(UInt16(1))  // PCM
    append(UInt16(1))  // mono
    append(rate)
    append(rate * 2)  // bytes per second
    append(UInt16(2))  // bytes per frame
    append(UInt16(16))  // bits per sample
    data.append(contentsOf: Array("data".utf8))
    append(bytes)
    data.append(Data(count: Int(bytes)))
    return data
  }()
}
